defmodule Maxio.Test.StoragePublishedProofScriptBackend do
  @moduledoc """
  Tests-only deterministic storage backend for the Task 3 G2 proof/finalize matrices
  (handoff §4.2).

  它实现完整的当前 `Maxio.Storage.Backend` behaviour：普通操作一律委派给
  `Maxio.Storage.FS`，只有 `verify_published/2`、`finalize_if_current/2`、
  `current_epoch/2` 与 `restore_if_current/2` 四个操作受脚本控制。

  每个测试由 `start_supervised!/1` 拥有**一个**脚本进程，它持有：

    * 四个操作各自独立的 FIFO 脚本；
    * 四个操作各自独立的直接-facade 调用/上下文记录；
    * 精确的剩余条目计数。

  重要边界（合同 §4.2）：finalize 的 FIFO 与记录**只**观察 Commit 发起的直接
  `Storage.finalize_if_current/2` 调用。它既不观察也无法观察 publish 期间已经注册进
  `ObjectCommit.Control` 的、由冻结 backend 拥有的 finalize 闭包；测试不得声称相反。

  脚本进程**原子地**弹出并记录条目，但所选 action 在状态进程之外执行——因此
  raise/exit/throw 发生在调用方进程里，不会毒化脚本进程本身。

  支持的 action：

    * `:delegate` —— 委派给 FS；
    * `{:return, term}` —— 原样返回该 term；
    * `{:raise, message}` / `{:exit, reason}` / `{:throw, value}` —— 以固定 sentinel
      抛出；这里**绝不**使用不可捕获的 `Process.exit(self(), :kill)`；
    * `{:gate, owner, ref, action}` —— 先向 owner 发送一条完整的 entered 消息
      `{:script_backend_entered, %{operation:, ref:, caller:, ctx:, opts:}}`（其中
      `caller` 是执行该 callback 的调用方 pid，`ctx` 对 epoch 操作即 target），再等待精确的
      release 消息（有限超时），随后执行内层 action。release 必须发回 `caller`。

  绝不使用 `Process.sleep/1`、`Process.alive?/1`、轮询、application-env 脚本状态、
  `persistent_term`、游离进程或全局无主 supervisor。脚本状态只存在于本进程里。
  """

  @behaviour Maxio.Storage.Backend

  use Agent

  alias Maxio.Storage.FS

  @name __MODULE__
  @gate_timeout 5_000

  @operations [:verify_published, :finalize_if_current, :current_epoch, :restore_if_current]

  # --- 生命周期 ---

  @doc "启动一个测试私有的脚本进程；用 `start_supervised!/1` 保证测试间清理。"
  def start_link(opts) do
    Agent.start_link(
      fn ->
        %{
          scripts: Map.new(@operations, &{&1, []}),
          calls: Map.new(@operations, &{&1, []})
        }
      end,
      name: Keyword.get(opts, :name, @name)
    )
  end

  def child_spec(opts) do
    %{
      id: Keyword.get(opts, :name, @name),
      start: {__MODULE__, :start_link, [opts]}
    }
  end

  # --- 脚本编排 API（测试进程调用）---

  @doc "向某操作的 FIFO 追加若干 action。"
  def script(operation, actions) when operation in @operations and is_list(actions) do
    Agent.update(@name, fn state ->
      update_in(state.scripts[operation], &(&1 ++ actions))
    end)
  end

  def script(operation, action) when operation in @operations, do: script(operation, [action])

  @doc "按 FIFO 顺序返回某操作已记录的调用（每条为 `%{ctx: ctx, opts: opts}`）。"
  def calls(operation) when operation in @operations do
    Agent.get(@name, fn state -> Enum.reverse(state.calls[operation]) end)
  end

  @doc "某操作已记录的调用次数。"
  def call_count(operation) when operation in @operations, do: length(calls(operation))

  @doc "某操作 FIFO 中剩余未消费的条目数。"
  def remaining(operation) when operation in @operations do
    Agent.get(@name, fn state -> length(state.scripts[operation]) end)
  end

  @doc "所有操作的剩余条目数；断言脚本被精确消费完。"
  def remaining_all do
    Agent.get(@name, fn state ->
      Map.new(@operations, fn op -> {op, length(state.scripts[op])} end)
    end)
  end

  @doc "seam 存活控制：脚本进程可达且状态为空。"
  def seam_live? do
    Agent.get(@name, fn state -> map_size(state.scripts) == length(@operations) end)
  end

  # 原子弹出 + 记录：同一次 Agent.get_and_update 内完成，随后 action 在调用方进程执行。
  defp pop_and_record(operation, ctx, opts) do
    Agent.get_and_update(@name, fn state ->
      {action, rest} =
        case state.scripts[operation] do
          [head | tail] -> {head, tail}
          [] -> {:delegate, []}
        end

      state =
        state
        |> put_in([:scripts, operation], rest)
        |> update_in([:calls, operation], &[%{ctx: ctx, opts: opts} | &1])

      {action, state}
    end)
  end

  # action 在调用方进程执行，脚本进程不受 raise/exit/throw 影响。
  defp perform(:delegate, _operation, _ctx, _opts, fallback), do: fallback.()
  defp perform({:return, term}, _operation, _ctx, _opts, _fallback), do: term

  defp perform({:raise, message}, _operation, _ctx, _opts, _fallback),
    do: raise(RuntimeError, message: message)

  defp perform({:exit, reason}, _operation, _ctx, _opts, _fallback), do: exit(reason)
  defp perform({:throw, value}, _operation, _ctx, _opts, _fallback), do: throw(value)

  # gate 把它**本来就拥有的 callback 观察**完整暴露出去：operation、ref、callback 调用方
  # pid，以及该次 callback 捕获到的 ctx/target 与 opts。release 仍然发回 callback 调用方
  # pid（不是脚本 Agent），因为等待发生在调用方进程里。
  defp perform({:gate, owner, ref, inner}, operation, ctx, opts, fallback) do
    send(
      owner,
      {:script_backend_entered,
       %{operation: operation, ref: ref, caller: self(), ctx: ctx, opts: opts}}
    )

    receive do
      {:script_backend_release, ^ref} -> perform(inner, operation, ctx, opts, fallback)
    after
      @gate_timeout -> raise(RuntimeError, message: "script backend gate #{inspect(ref)} timeout")
    end
  end

  # --- 受脚本控制的四个操作 ---

  def verify_published(ctx, opts) do
    :verify_published
    |> pop_and_record(ctx, opts)
    |> perform(:verify_published, ctx, opts, fn -> FS.verify_published(ctx, opts) end)
  end

  def finalize_if_current(ctx, opts) do
    :finalize_if_current
    |> pop_and_record(ctx, opts)
    |> perform(:finalize_if_current, ctx, opts, fn -> FS.finalize_if_current(ctx, opts) end)
  end

  def current_epoch(target, opts) do
    :current_epoch
    |> pop_and_record(target, opts)
    |> perform(:current_epoch, target, opts, fn -> FS.current_epoch(target, opts) end)
  end

  def restore_if_current(ctx, opts) do
    :restore_if_current
    |> pop_and_record(ctx, opts)
    |> perform(:restore_if_current, ctx, opts, fn -> FS.restore_if_current(ctx, opts) end)
  end

  # --- 其余操作一律普通委派 ---

  defdelegate local_topology(opts \\ []), to: FS
  defdelegate put(bucket, key, version_id, chunks, opts), to: FS
  defdelegate get(bucket, key, version_id, range, opts), to: FS
  defdelegate stat(bucket, key, version_id, opts), to: FS
  defdelegate delete(bucket, key, version_id, opts), to: FS
  defdelegate put_bucket(bucket), to: FS
  defdelegate delete_bucket(bucket), to: FS
  defdelegate put_part(bucket, key, upload_id, part_number, chunks, opts), to: FS
  defdelegate get_part_stream(bucket, key, upload_id, part_number, opts), to: FS
  defdelegate assemble(bucket, key, upload_id, part_numbers, opts), to: FS
  defdelegate abort_upload(bucket, key, upload_id, opts), to: FS
  defdelegate put_delete_marker(bucket, key, version_id, entry_opts, opts), to: FS
  defdelegate delete_version(bucket, key, version_id, opts), to: FS
  defdelegate put_notification_ledgers(bucket, key, entries, opts), to: FS
  defdelegate list_notification_ledgers(bucket, key_filter, opts), to: FS
  defdelegate delete_notification_ledgers(bucket, key, ids, opts), to: FS
  defdelegate claim_epoch(target, token, operation, opts), to: FS
end
