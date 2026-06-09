defmodule Maxio.Storage.Backend do
  @moduledoc """
  对象字节存储后端契约（behaviour）。上层 handler 只认本契约，对实现无感
  （AGENTS.md 铁律 1/2：后端即插件，换 FS→纠删码→分布式 核心管线一行不改）。

  约定：
    * put/4 的 `chunks` 是一个产出二进制块的 Enumerable（来自 read_body 流式拉取），
      实现必须**边消费边落盘 / 边算哈希，绝不把整对象读进内存**（铁律 4）。
    * get/3 的 range 为 nil（全量）或 {first_byte, last_byte}（含端点，0-based），
      返回产出二进制块的 Enumerable（供 send_chunked 流式发出）。
    * ETag 形态：单次 PUT 对象 = MD5(对象内容) 的小写 hex（**不含引号**，引号由 XML/HTTP 层加）。

  ## put/5 的 `:object_meta`（ROUTE B B4-5）

  `opts[:object_meta]`（可选 map）携带 GET/HEAD/LIST 所需的全部 S3 富元数据，使纠删/分布式后端
  写出**完整 maxio/2 sidecar**（携带 `format:"maxio/2"` + 单元素 `versions` 数组）——盘上 sidecar
  即事实来源（Route B），故写路径**必须**自描述这些字段，否则 `authoritative_source(:read|:list)=:sidecar`
  下对真实对象 reconcile 取不到 versioned entry（v1 扁平 meta → `Sidecar.latest/find_version` 返回 nil）
  → GET 503 / LIST 丢对象。形状（缺省 `%{}`，缺省字段由 `Maxio.Sidecar.migrate_v1/2` 兜底）：

      %{
        content_type: String.t(),
        tags: %{String.t() => String.t()},
        sse: nil | %{"algo" => "AES256", "envelope" => map()},
        acl_canned: String.t(),
        storage_class: String.t(),
        user_metadata: %{String.t() => String.t()}
      }

  `sse` 形状必须匹配 `Sidecar.to_view/3` 读 `e["sse"]["algo"]` / `e["sse"]["envelope"]`（信封随读视图携带，
  否则 SSE 对象 GET 解密 `unwrap_dek(nil)` 炸 500）。FS 后端无多端点拓扑（读权威永不命中 FS），可忽略
  本 opt——耐久核心字节不变（铁律 5：默认 :pg 路径字节级可回滚）。
  """

  @type bucket :: String.t()
  @type key :: String.t()
  @type range :: nil | {non_neg_integer(), non_neg_integer()}
  @type put_result :: %{size: non_neg_integer(), etag: String.t(), sha256: String.t()}
  @type object_meta :: %{optional(atom()) => term()}

  @callback put(
              bucket(),
              key(),
              version_id :: String.t(),
              chunks :: Enumerable.t(),
              opts :: [{:object_meta, object_meta()} | {atom(), term()}]
            ) ::
              {:ok, put_result()} | {:error, term()}
  @callback get(bucket(), key(), version_id :: String.t(), range()) ::
              {:ok, Enumerable.t()} | {:error, :enoent | term()}
  @callback stat(bucket(), key(), version_id :: String.t()) ::
              {:ok, %{size: non_neg_integer()}} | {:error, :enoent}
  @callback delete(bucket(), key(), version_id :: String.t()) :: :ok | {:error, term()}
  @callback put_bucket(bucket()) :: :ok | {:error, term()}
  @callback delete_bucket(bucket()) :: :ok | {:error, term()}

  # ── 分段上传 parts 回调（M2-4，追加在既有回调之后；铁律 1/2：part 字节也只走本契约）──

  @type upload_id :: String.t()
  @type part_number :: pos_integer()
  @type part_put_result :: %{size: non_neg_integer(), etag: String.t(), md5_raw: binary()}

  @doc "流式写入一个 part 的字节，返回该 part 的 size、MD5 hex etag（无引号）与 16 字节原始 MD5。"
  @callback put_part(
              bucket(),
              key(),
              upload_id(),
              part_number(),
              chunks :: Enumerable.t(),
              opts :: keyword()
            ) ::
              {:ok, part_put_result()} | {:error, term()}

  @doc "流式读取一个 part 的字节（组装时按 part number 升序拼接用）。"
  @callback get_part_stream(bucket(), key(), upload_id(), part_number(), opts :: keyword()) ::
              {:ok, Enumerable.t()} | {:error, :enoent | term()}

  @doc "按给定 part number 升序把各 part 字节拼成最终对象（落到对象路径），返回总大小。"
  @callback assemble(
              bucket(),
              key(),
              upload_id(),
              part_numbers :: [part_number()],
              opts :: keyword()
            ) ::
              {:ok, %{size: non_neg_integer()}} | {:error, term()}

  @doc "删除该 upload 的所有 part 字节与临时目录（Abort / Complete 后清理）。幂等。"
  @callback abort_upload(bucket(), key(), upload_id(), opts :: keyword()) ::
              :ok | {:error, term()}
end
