defmodule Maxio.SidecarHeal do
  @moduledoc """
  ROUTE B P4 —— 把权威 canonical sidecar 写回 divergent（缺失/陈旧/损坏）端点。

  P2 `Maxio.MetaReconcile.reconcile/3` 返回的 `divergent` 是**端点索引列表**（0-based，相对该对象
  set 的有序 `endpoints`）。其 sidecar 缺失/签名不一致/无此版本——本单元用权威 canonical 完整 meta
  把它们写回（仅 sidecar 元数据；数据分片 heal 是 M6/M7 既有机制，本单元不碰）。

  ## 为什么直写 final 而非 temp-then-rename（实现取舍，对照 B1-2）

  B1-2 的 `Transport.commit_object/4`（→ `ShardServer.commit/3`）**数据先于元数据**：先原子 rename
  `part.0` 再 rename `meta.json`。sidecar-only heal 的 temp obj-dir 里**只有 meta.json、无 part.0**，
  `commit` 第一步 rename part.0 即得 `{:error, :enoent}`（enoent 不在重试白名单 :eacces/:eexist/:ebusy
  内，直接失败）——commit_object 强制要求 part.0。故 B4-1 走计划文档化的二选一**回退路径**：用
  `Transport.put_sidecar(node, final_dir, canon)` 直写 final obj-dir 的 meta.json。put_sidecar 是
  **单文件 `File.write`**（近原子；写一个 JSON 文件无撕裂半个对象的风险，与「数据先于元数据」要解决的
  part.0↔meta.json 撕裂问题正交），且数据 part.0 已由 EC/M6/M7 在该端点保有或将由数据 heal 补齐——
  此处只补齐元数据副本，不触碰数据分片。

  ## best-effort（铁律 3 不静默 + 绝不阻塞读）

  单端点 heal 失败（端点宕机、写盘错误）→ 记 `Log.warn` 并继续其他端点；返回**成功回写的端点数**。
  绝不 raise 进读路径（do_shadow 调用方已 try/rescue 兜底，本模块自身亦容错）。
  """
  alias Maxio.Cluster.Paths
  alias Maxio.S3.Log

  @doc """
  把权威 canonical 完整 meta 写回 `divergent_endpoints`（端点索引）对应端点的 sidecar。

  `info`：
    * `:canonical_meta` —— 权威完整 meta（含 versions 数组，取自 quorum 端点之一的完整 sidecar）。
    * `:divergent_endpoints` —— reconcile 返回的端点索引列表（0-based，相对 `:endpoints`）。
    * `:endpoints` —— 该对象 set 的有序 `{node, drive}` 列表。

  `opts`：`:transport`（test 注入 InProcess；缺省 `Maxio.Cluster.Transport.impl/1`）。

  返回成功回写的端点数（非负整数）。单端点失败不抛、不影响其他端点与读路径。
  """
  @spec heal_divergent(String.t(), String.t(), String.t(), map(), keyword()) ::
          non_neg_integer()
  def heal_divergent(
        bucket,
        key,
        version_id,
        %{canonical_meta: canon, divergent_endpoints: divs, endpoints: endpoints},
        opts
      )
      when is_map(canon) and is_list(divs) and is_list(endpoints) do
    transport = Keyword.get(opts, :transport, Maxio.Cluster.Transport.impl(opts))

    case Paths.object_rel(bucket, key, version_id || "null") do
      {:ok, rel} ->
        Enum.reduce(divs, 0, fn idx, acc ->
          case Enum.at(endpoints, idx) do
            {node, drive} ->
              acc + heal_one(transport, node, drive, rel, canon, bucket, key)

            _ ->
              # 索引越界/端点表与 divergent 不一致：记日志、跳过（绝不抛）。
              Log.warn("sidecar heal: divergent index out of endpoints range",
                bucket: bucket,
                key: key,
                reason: inspect(idx)
              )

              acc
          end
        end)

      {:error, reason} ->
        Log.warn("sidecar heal: invalid object path",
          bucket: bucket,
          key: key,
          reason: inspect(reason)
        )

        0
    end
  end

  # 直写 final obj-dir 的 meta.json（put_sidecar）。成功 -> 1；失败/异常 -> 记 warn 返回 0（best-effort）。
  defp heal_one(transport, node, drive, rel, canon, bucket, key) do
    final_dir = Path.join(drive, rel)

    case transport.put_sidecar(node, final_dir, canon) do
      :ok ->
        1

      other ->
        Log.warn("sidecar heal failed",
          bucket: bucket,
          key: key,
          reason: inspect({node, other})
        )

        0
    end
  rescue
    e ->
      Log.warn("sidecar heal raised",
        bucket: bucket,
        key: key,
        reason: inspect({node, e})
      )

      0
  catch
    kind, reason ->
      Log.warn("sidecar heal caught",
        bucket: bucket,
        key: key,
        reason: inspect({node, kind, reason})
      )

      0
  end
end
