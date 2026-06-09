defmodule Maxio.ObjectMeta do
  @moduledoc """
  ROUTE B P2 —— 对象元数据门面（dual-read SHADOW）。

  读路径：PG 仍权威（`authoritative_source(:read)` 默认 `:pg`），同时跨 N 端点读 sidecar 并
  `Maxio.MetaReconcile` 仲裁，逐字段比对 PG 与 sidecar 视图，**返回 PG 结果**（不翻权威），
  分歧 -> 结构化 `Log.warn`（铁律 3 绝不静默）。reconcile 出的 divergent 端点 -> 记 heal 钩子
  （本阶段仅日志；实际 heal 回写落 P4）。

  P4 之后把 `authoritative_source(:read)` 切 `:sidecar` 即翻转读权威（届时 reconcile 错误直接成
  read-quorum 5xx）。本阶段 reconcile 错误**不影响响应**（PG 权威），仅记日志。
  """

  alias Maxio.{Objects, Sidecar, MetaReconcile}
  alias Maxio.Cluster.{Router, Topology, Paths}
  alias Maxio.Storage.Erasure.Config
  alias Maxio.S3.Log

  @doc "读/列/写的元数据权威来源（读 config，可经 opts 覆盖 for tests）。"
  @spec authoritative_source(:read | :list | :write) :: :pg | :sidecar
  def authoritative_source(kind) do
    Application.get_env(:maxio, :authoritative_source, read: :pg)
    |> Keyword.get(kind, :pg)
  end

  @doc """
  读对象元数据。SHADOW 模式：返回 PG 权威 `%Object{}`（或 `{:error,:not_found}`），
  并 best-effort 跨端点 sidecar reconcile + 分歧日志（不影响返回值、不抛错）。
  version_id=nil 读 latest；否则读指定版本。
  """
  @spec get(String.t(), String.t(), String.t() | nil, keyword()) ::
          Objects.Object.t() | {:error, :not_found}
  def get(bucket, key, version_id \\ nil, opts \\ []) do
    pg = pg_read(bucket, key, version_id)
    shadow_check(bucket, key, version_id, pg, opts)
    pg
  end

  # PG 权威读：get_metadata/get_version 均返回 {:ok, %Object{}} | {:error, :not_found}，
  # 解包成裸 %Object{}（命中）或 {:error, :not_found}，供 handler/shadow 统一消费。
  defp pg_read(bucket, key, nil) do
    case Objects.get_metadata(bucket, key) do
      {:ok, obj} -> obj
      {:error, :not_found} -> {:error, :not_found}
    end
  end

  defp pg_read(bucket, key, vid) do
    case Objects.get_version(bucket, key, vid) do
      {:ok, obj} -> obj
      {:error, :not_found} -> {:error, :not_found}
    end
  end

  @doc """
  best-effort shadow 比对：读全 N 端点 sidecar -> reconcile -> 比对 PG。任何异常都被吞并记日志
  （shadow 绝不破坏读路径）。返回 :ok。
  """
  @spec shadow_check(String.t(), String.t(), String.t() | nil, term(), keyword()) :: :ok
  def shadow_check(bucket, key, version_id, pg, opts) do
    target = if version_id, do: {:version, version_id}, else: :latest

    try do
      do_shadow(bucket, key, version_id, target, pg, opts)
    rescue
      e -> Log.warn("metadata shadow error", bucket: bucket, key: key, reason: inspect(e))
    catch
      kind, reason ->
        Log.warn("metadata shadow caught",
          bucket: bucket,
          key: key,
          reason: inspect({kind, reason})
        )
    end

    :ok
  end

  defp do_shadow(bucket, key, version_id, target, pg, opts) do
    copies = read_endpoint_sidecars(bucket, key, version_id, opts)
    rq = read_quorum(opts)

    case MetaReconcile.reconcile(copies, rq, target) do
      {:ok, entry, divergent} ->
        if divergent != [],
          do:
            Log.warn("sidecar divergence (heal pending)",
              bucket: bucket,
              key: key,
              version_id: version_id,
              divergent: inspect(divergent)
            )

        compare(bucket, key, version_id, pg, Sidecar.to_view(bucket, key, entry))

      {:error, :read_quorum} ->
        # PG 有对象但 sidecar 不足 quorum -> 记分歧（P4 翻权威后此为 5xx，本阶段仅日志）
        case pg do
          %Objects.Object{} ->
            Log.warn("metadata divergence: sidecar read_quorum unmet while PG has object",
              bucket: bucket,
              key: key,
              version_id: version_id
            )

          _ ->
            :ok
        end
    end
  end

  # 逐字段比对 PG %Object{} 与 sidecar 视图；不一致 -> 日志（返回 :ok）
  defp compare(bucket, key, version_id, %Objects.Object{} = pg, view) do
    diffs =
      [
        field_diff(:etag, pg.etag, view.etag),
        field_diff(:size, pg.size, view.size),
        field_diff(:content_type, pg.content_type, view.content_type),
        field_diff(:is_delete_marker, pg.is_delete_marker, view.is_delete_marker),
        field_diff(:storage_class, pg.storage_class, view.storage_class)
      ]
      |> Enum.reject(&is_nil/1)

    if diffs != [],
      do:
        Log.warn("metadata divergence: PG vs sidecar",
          bucket: bucket,
          key: key,
          version_id: version_id,
          diffs: inspect(diffs)
        )

    :ok
  end

  defp compare(bucket, key, version_id, _pg_nil_or_error, _view) do
    # sidecar 有 quorum 但 PG 无 -> 分歧（PG 落后或漏写）
    Log.warn("metadata divergence: sidecar has object while PG does not",
      bucket: bucket,
      key: key,
      version_id: version_id
    )

    :ok
  end

  defp field_diff(_field, same, same), do: nil
  defp field_diff(field, pg_v, sc_v), do: {field, pg: pg_v, sidecar: sc_v}

  # 读全 N 端点 sidecar -> [%{node, drive, meta} | :missing]
  defp read_endpoint_sidecars(bucket, key, version_id, opts) do
    transport = Keyword.get(opts, :transport, Maxio.Cluster.Transport.impl(opts))
    endpoints = endpoints_for(bucket, key, opts)

    case Paths.object_rel(bucket, key, version_id || "null") do
      {:ok, rel} ->
        Enum.map(endpoints, fn {node, drive} ->
          dir = Path.join(drive, rel)

          case transport.get_sidecar(node, dir) do
            {:ok, meta} -> %{node: node, drive: drive, meta: meta}
            {:error, _} -> :missing
          end
        end)

      {:error, _} ->
        []
    end
  end

  defp endpoints_for(bucket, key, opts) do
    case Keyword.get(opts, :topology) do
      nil ->
        set_id = Router.set_for(bucket, key)
        Topology.endpoints(set_id)

      t ->
        set_id = Router.set_for(bucket, key, t)
        Topology.endpoints_from(t, set_id)
    end
  end

  defp read_quorum(opts) do
    cfg = Config.load!(Keyword.take(opts, [:drives, :data_shards, :parity_shards, :block_size]))
    cfg.read_quorum
  rescue
    _ -> Keyword.get(opts, :read_quorum, 1)
  end
end
