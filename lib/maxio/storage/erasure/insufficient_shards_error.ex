defmodule Maxio.Storage.Erasure.InsufficientShardsError do
  @moduledoc """
  某个 block 的存活（校验和通过）分片数 < K（read quorum），无法重建。
  铁律 3：绝不静默返回错数据，直接 raise；上层（后端 get）令惰性流崩溃，handler 映射结构化 S3 5xx。
  """
  defexception [:bucket, :key, :version_id, :block_index, :present, :required, :message]

  @impl true
  def exception(opts) do
    bucket = Keyword.get(opts, :bucket)
    key = Keyword.get(opts, :key)
    version_id = Keyword.get(opts, :version_id)
    block_index = Keyword.get(opts, :block_index)
    present = Keyword.get(opts, :present)
    required = Keyword.get(opts, :required)

    msg =
      "erasure read quorum lost: bucket=#{inspect(bucket)} key=#{inspect(key)} " <>
        "version_id=#{inspect(version_id)} block=#{inspect(block_index)} " <>
        "present=#{inspect(present)} required=#{inspect(required)}"

    %__MODULE__{
      bucket: bucket,
      key: key,
      version_id: version_id,
      block_index: block_index,
      present: present,
      required: required,
      message: msg
    }
  end
end
