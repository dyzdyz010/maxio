defmodule Maxio.Test.StorageDeleteProbeBackend do
  @moduledoc """
  Tests-only 删除探针后端（Task 3 C1）。

  单模块同时承担 `Agent` 生命周期与完整 `Maxio.Storage.Backend` behaviour：

    * 除 `delete/4` 外，全部 callback **逐字委派** `Maxio.Storage.FS`；
    * `delete/4` 先在测试私有 Agent 中**原子记录** `%{bucket:, key:, version_id:, opts:}`，
      再委派 FS——记录先于委派，因此「字节是否被删」与「探针是否被调用」永远一致；
    * 暴露 `calls/0` 与 `call_count/0` 供断言。

  它与 G2/G3 的 published-proof script backend 是**正交**的测试职责：本探针只回答
  「current-delete 是否在元数据事务失败后仍然删除了对象字节」，绝不脚本化任何
  proof / finalize / epoch 结果。

  纪律：`start_supervised!/1` 拥有进程；状态只存在于该进程里——禁止用 application env
  存 pid、禁止 `persistent_term`、禁止 `Process.sleep/1`、禁止游离进程。
  """

  @behaviour Maxio.Storage.Backend

  use Agent

  alias Maxio.Storage.FS

  @name __MODULE__

  # --- 生命周期 ---

  @doc "启动测试私有探针进程；用 `start_supervised!/1` 保证测试间清理。"
  def start_link(opts) do
    Agent.start_link(fn -> [] end, name: Keyword.get(opts, :name, @name))
  end

  def child_spec(opts) do
    %{
      id: Keyword.get(opts, :name, @name),
      start: {__MODULE__, :start_link, [opts]}
    }
  end

  # --- 探针查询 API ---

  @doc "按 FIFO 顺序返回已记录的 `delete/4` 调用。"
  def calls, do: Agent.get(@name, &Enum.reverse/1)

  @doc "已记录的 `delete/4` 调用次数。"
  def call_count, do: length(calls())

  # --- 唯一受观察的 callback ---

  @impl true
  def delete(bucket, key, version_id, opts) do
    Agent.update(
      @name,
      &[%{bucket: bucket, key: key, version_id: version_id, opts: opts} | &1]
    )

    FS.delete(bucket, key, version_id, opts)
  end

  # --- 其余 callback 一律逐字委派 FS ---

  @impl true
  defdelegate put(bucket, key, version_id, chunks, opts), to: FS

  @impl true
  defdelegate get(bucket, key, version_id, range, opts), to: FS

  @impl true
  defdelegate stat(bucket, key, version_id, opts), to: FS

  @impl true
  defdelegate put_bucket(bucket), to: FS

  @impl true
  defdelegate delete_bucket(bucket), to: FS

  @impl true
  defdelegate put_part(bucket, key, upload_id, part_number, chunks, opts), to: FS

  @impl true
  defdelegate get_part_stream(bucket, key, upload_id, part_number, opts), to: FS

  @impl true
  defdelegate assemble(bucket, key, upload_id, part_numbers, opts), to: FS

  @impl true
  defdelegate abort_upload(bucket, key, upload_id, opts), to: FS

  @impl true
  defdelegate put_delete_marker(bucket, key, version_id, entry_opts, opts), to: FS

  @impl true
  defdelegate delete_version(bucket, key, version_id, opts), to: FS

  @impl true
  defdelegate put_notification_ledgers(bucket, key, entries, opts), to: FS

  @impl true
  defdelegate list_notification_ledgers(bucket, key_filter, opts), to: FS

  @impl true
  defdelegate delete_notification_ledgers(bucket, key, ids, opts), to: FS

  @impl true
  defdelegate claim_epoch(target, token, operation, opts), to: FS

  @impl true
  defdelegate current_epoch(target, opts), to: FS

  @impl true
  defdelegate restore_if_current(ctx, opts), to: FS

  @impl true
  defdelegate verify_published(ctx, opts), to: FS

  @impl true
  defdelegate finalize_if_current(ctx, opts), to: FS

  defdelegate local_topology(opts \\ []), to: FS
end
