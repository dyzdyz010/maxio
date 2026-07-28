defmodule Maxio.Storage.DeleteMarker do
  @moduledoc """
  ROUTE B B5-0 —— 纯 delete-marker maxio/2 sidecar 构造（纯函数，不写盘）。

  删除是写操作；`authoritative_source(:read|:list)=:sidecar` 下，sidecar 是事实来源，故删除必须被
  **盘上权威记录**——否则 DeleteObject 后盘上旧对象 sidecar 仍在 → GET 仍 200、LIST 仍列出 =
  已删对象复活（B5-0 critical 根因）。本模块产出后端落盘的 delete-marker sidecar 形态，由
  纠删/分布式后端的 `put_delete_marker/5` 各端点写出（单次 modtime → 所有端点 `Sidecar.signature`
  逐字一致，分歧检测前提，铁律 3）。

  形态 = `%{"format"=>"maxio/2","versions"=>[entry]}`，entry：

    * `type="delete_marker"` / 给定 `version_id`
    * `modtime`（int64 纳秒，latest 排序键；单次计算，所有端点同值）
    * `generation:0` / `is_latest:true`
    * **无 part.0 字节、无 ec/shards/size/etag 耐久 core**——delete marker 无字节，合法
      （对齐 MinIO xl.meta v2 的 delete-marker version：只承载 version type，无数据分片）。

  字段对齐 `Maxio.Sidecar` 的 version_entry 形态，使读侧 `Sidecar.latest/1`（任意 type，含 marker）
  / `ObjectMeta.view_or_not_found`（latest marker→404+头）/ `Maxio.Listing`（当前版本排除 marker）
  无缝识别（B4-3/B4-4 读侧已就绪）。
  """

  @format "maxio/2"

  @doc """
  构造纯 delete-marker maxio/2 sidecar map。`entry_opts`（keyword，可选）支持 `:modtime` 覆盖
  （缺省取当前纳秒）；`:generation` 覆盖（缺省 0）。
  """
  @spec sidecar(String.t(), keyword()) :: map()
  def sidecar(version_id, entry_opts \\ []) when is_binary(version_id) do
    entry = %{
      "version_id" => version_id,
      "type" => "delete_marker",
      "is_latest" => true,
      "modtime" => Keyword.get(entry_opts, :modtime, System.os_time(:nanosecond)),
      "generation" => Keyword.get(entry_opts, :generation, 0),
      "replication_status" => Keyword.get(entry_opts, :replication_status),
      "notification_outbox" => Keyword.get(entry_opts, :notification_outbox, [])
    }

    %{
      "format" => @format,
      "versions" => [entry]
    }
  end
end
