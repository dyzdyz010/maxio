defmodule Maxio.Test.TransportProofRecorder do
  @moduledoc """
  Task 2 G3 专用的 Transport 记录/脚本 seam（仅测试）。

  它是 `Maxio.Cluster.Transport.InProcess` 的**透明包装**：除 proof/finalize 两个 mutation
  端点原语外全部原样委派。对这两个原语，它

    * 把每次调用（op + 请求捕获的 `layout.index`）记入 test-owned 的受监督进程，用于证明
      「preflight 漂移零 RPC」以及「结果按捕获 ordinal 归位而非完成顺序」；
    * 允许按**捕获 ordinal** 注入确定性剧本（**一次性**：命中即从剧本中弹出，后续调用回落
      到 `:delegate`）：

      | action | 语义 |
      | --- | --- |
      | `:delegate` | 原样委派 InProcess（默认） |
      | `{:return, term}` | 原样返回任意 wire term（伪造 endpoint 信封、aggregate 重入、完全畸形的外层返回） |
      | `:raise` / `:exit` / `:throw` | call-time 异常（会被 `Transport.guarded_call/1` 收敛） |
      | `:kill` | 真正的 `Process.exit(self(), :kill)`——不可捕获，直击后端 fan-out 的 worker-死亡分支 |
      | `{:gate, owner, ref, next}` | `send(owner, {:entered, ref, ordinal, self()})` → 阻塞等 `{:release, ref}`（**有限**超时兜底） → 执行 `next` → `send(owner, {:completed, ref, ordinal, self()})` |
      | `{:notify, owner, ref, next}` | 执行 `next` 后 `send(owner, {:completed, ref, ordinal, self()})` |

      `:gate` / `:notify` 提供**无 sleep、无轮询**的确定性乱序完成屏障。每条消息都带调用方
      生成的唯一 `ref`（杜绝跨断言窗口串消息），阻塞等待带有限超时（断言失败时 worker 不会
      被永久挂住），并回传 worker pid，供测试经 `Process.info(pid, :links)` 观察其
      call-scoped supervisor 生命周期。

  状态只存在于 `start_supervised!/1` 的具名进程中：不用 Application env、不用
  `persistent_term`、不用 `Process.sleep/1`，生产配置也绝不引用本模块。
  """
  @behaviour Maxio.Cluster.Transport

  alias Maxio.Cluster.Transport.InProcess

  @name __MODULE__.State

  @doc "供 `start_supervised!/1` 使用：启动 test-owned 的调用记录/剧本进程。"
  def child_spec(_arg) do
    %{
      id: __MODULE__,
      start: {Agent, :start_link, [fn -> %{calls: [], script: %{}} end, [name: @name]]}
    }
  end

  @doc "按捕获 ordinal 注入**一次性**剧本。action 见 moduledoc。"
  @spec script(non_neg_integer(), term()) :: :ok
  def script(ordinal, action) when is_integer(ordinal) and ordinal >= 0 do
    Agent.update(@name, fn state -> put_in(state.script[ordinal], action) end)
  end

  @doc "按调用先后返回 `{op, ordinal}` 列表。"
  @spec calls() :: [{:verify_mutation | :finalize_mutation, term()}]
  def calls, do: Agent.get(@name, & &1.calls) |> Enum.reverse()

  @doc "本次断言窗口内的 mutation proof/finalize 调用总数。"
  @spec call_count() :: non_neg_integer()
  def call_count, do: length(calls())

  @doc "清空调用记录（保留剧本）。"
  @spec reset_calls() :: :ok
  def reset_calls, do: Agent.update(@name, fn state -> %{state | calls: []} end)

  defp record_and_run(op, request, delegate) do
    ordinal = captured_ordinal(request)

    # 剧本是一次性的：`Map.pop` 保证同一 ordinal 的后续调用自动回落 `:delegate`，
    # 使多轮断言互不污染。
    action =
      Agent.get_and_update(@name, fn state ->
        {action, script} = Map.pop(state.script, ordinal, :delegate)
        {action, %{state | script: script, calls: [{op, ordinal} | state.calls]}}
      end)

    run(action, ordinal, delegate)
  end

  defp run(:delegate, _ordinal, delegate), do: delegate.()
  defp run({:return, term}, _ordinal, _delegate), do: term
  defp run(:raise, _ordinal, _delegate), do: raise("scripted proof transport failure")
  defp run(:exit, _ordinal, _delegate), do: exit(:scripted_transport_exit)
  defp run(:throw, _ordinal, _delegate), do: throw(:scripted_transport_throw)

  # 真正的不可捕获 worker 死亡：`Transport.guarded_call/1` 接不到它，后端 fan-out 必须
  # 自己把这个 worker 的死亡收敛为该捕获 ordinal 的 canonical unavailable。
  defp run(:kill, _ordinal, _delegate), do: Process.exit(self(), :kill)

  # 有限兜底超时：断言失败时 worker 仍会自行前进并退出，绝不永久挂住 scoped supervisor。
  @gate_timeout 5_000

  defp run({:gate, owner, ref, next}, ordinal, delegate) do
    send(owner, {:entered, ref, ordinal, self()})

    receive do
      {:release, ^ref} -> :ok
    after
      @gate_timeout -> :ok
    end

    result = run(next, ordinal, delegate)
    send(owner, {:completed, ref, ordinal, self()})
    result
  end

  defp run({:notify, owner, ref, next}, ordinal, delegate) do
    result = run(next, ordinal, delegate)
    send(owner, {:completed, ref, ordinal, self()})
    result
  end

  defp captured_ordinal(%{layout: %{kind: "shard", index: index}}), do: index
  defp captured_ordinal(%{layout: %{kind: "fs"}}), do: :local
  defp captured_ordinal(_request), do: :invalid

  @impl true
  def verify_mutation(node, drive_root, request) do
    record_and_run(:verify_mutation, request, fn ->
      InProcess.verify_mutation(node, drive_root, request)
    end)
  end

  @impl true
  def finalize_mutation(node, drive_root, request) do
    record_and_run(:finalize_mutation, request, fn ->
      InProcess.finalize_mutation(node, drive_root, request)
    end)
  end

  @impl true
  defdelegate put_shard(node, dir, j, shard, shard_len), to: InProcess

  @impl true
  defdelegate get_shard(node, dir, j, shard_len), to: InProcess

  @impl true
  defdelegate put_sidecar(node, dir, meta), to: InProcess

  @impl true
  defdelegate get_sidecar(node, dir), to: InProcess

  @impl true
  defdelegate stat_shard(node, dir), to: InProcess

  @impl true
  defdelegate stat_shard_info(node, dir), to: InProcess

  @impl true
  defdelegate delete_shard(node, dir), to: InProcess

  @impl true
  defdelegate move_shard(node, source_dir, destination_dir, opts), to: InProcess

  @impl true
  defdelegate delete_part_file(node, dir), to: InProcess

  @impl true
  defdelegate quarantine_layout_roots(node, drive_root, bucket_names, quarantine_id, marker),
    to: InProcess

  @impl true
  defdelegate purge_quarantine_root(node, drive_root, quarantine_id, expected_marker),
    to: InProcess

  @impl true
  defdelegate preflight_quarantine_purge_root(node, drive_root, quarantine_id, expected_marker),
    to: InProcess

  @impl true
  defdelegate heal_shard(node, dir, block_map, shard_len, meta), to: InProcess

  @impl true
  defdelegate begin_tmp(node, drive_root), to: InProcess

  @impl true
  defdelegate commit_object(node, tmp_dir, final_obj_dir, opts), to: InProcess

  @impl true
  defdelegate list_dir(node, drive_dir, opts), to: InProcess

  @impl true
  defdelegate read_epoch(node, drive_root, target), to: InProcess

  @impl true
  defdelegate cas_epoch(node, drive_root, request), to: InProcess

  @impl true
  defdelegate restore_mutation(node, drive_root, request), to: InProcess

  @impl true
  defdelegate put_mutation_manifest(node, drive_root, request), to: InProcess

  @impl true
  defdelegate probe_drive(node, drive_root), to: InProcess

  @impl true
  defdelegate probe_drive_identity(node, drive_root, opts), to: InProcess

  @impl true
  defdelegate drive_hardware_evidence(node, drive_root, opts), to: InProcess

  @impl true
  defdelegate drive_stats(node, drive_root, opts), to: InProcess

  @impl true
  defdelegate pressure_snapshot(node, opts), to: InProcess
end
