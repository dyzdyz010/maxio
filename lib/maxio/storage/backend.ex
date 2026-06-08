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
  """

  @type bucket :: String.t()
  @type key :: String.t()
  @type range :: nil | {non_neg_integer(), non_neg_integer()}
  @type put_result :: %{size: non_neg_integer(), etag: String.t()}

  @callback put(bucket(), key(), chunks :: Enumerable.t(), opts :: keyword()) ::
              {:ok, put_result()} | {:error, term()}
  @callback get(bucket(), key(), range()) ::
              {:ok, Enumerable.t()} | {:error, :enoent | term()}
  @callback stat(bucket(), key()) ::
              {:ok, %{size: non_neg_integer()}} | {:error, :enoent}
  @callback delete(bucket(), key()) :: :ok | {:error, term()}
  @callback put_bucket(bucket()) :: :ok | {:error, term()}
  @callback delete_bucket(bucket()) :: :ok | {:error, term()}
end
