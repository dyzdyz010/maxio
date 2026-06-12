defmodule Maxio.Metadata do
  @moduledoc """
  用户自定义元数据（`x-amz-meta-*` / `x-minio-meta-*`）的解析与大小校验（官方核验 bake-in）。

  AWS/MinIO 对 PUT 请求头总量设 8 KB（8192 字节）硬上限，对单个对象的用户元数据总量设
  2 KB（2048 字节）硬上限：所有用户元数据头的**完整 key（含前缀）+ value 的 UTF-8
  字节和**累加超 2048 → `MetadataTooLarge`(400)。
  权威：AWS UsingMetadata.html（user-defined metadata 限 2 KB / 每 key+value 的 UTF-8 字节和）；
  minio/minio `cmd/generic-handlers.go` `isHTTPHeaderSizeTooLarge`（`maxHeaderSize = 8*1024`，
  `maxUserDataSize = 2*1024`，逐头 `length = len(fullHeaderKey) + len(value)`，
  `usersize > maxUserDataSize || size > maxHeaderSize` → `ErrMetadataTooLarge`）。

  本模块仅做大小闸（仿 `Maxio.Tags` 风格的纯函数校验器，无 Plug/Conn 耦合），由 PutObject /
  CopyObject(REPLACE) handler 及 S3 request-limit plug 在写任何字节/sidecar **之前**调用——失败
  pre-commit、不留孤儿（铁律 3）。
  """

  # AWS/MinIO 请求头总量上限：8 KB（8192 字节）。
  @max_header_size 8 * 1024

  # AWS 用户元数据总量上限：2 KB（2048 字节）。
  @max_size 2048

  @amz_meta_prefix "x-amz-meta-"
  @minio_meta_prefix "x-minio-meta-"
  @user_metadata_prefixes [@amz_meta_prefix, @minio_meta_prefix]

  # `x-amz-meta-` 前缀字节数（11）。历史 handler-level `validate_size!/1` 入参已剥去前缀，
  # 因此保留 AWS 前缀计量兼容既有调用；入口级 `validate_headers!/1` 按原始 header key 精确计量。
  @meta_prefix_size byte_size(@amz_meta_prefix)

  @doc """
  从请求头解析用户自定义元数据：`x-amz-meta-<name>` / `x-minio-meta-<name>` → `%{name => value}`
  （去掉前缀，name 小写；空 name 跳过；重复 name 保留首次出现）。

  这是 PutObject / CopyObject(REPLACE) / CreateMultipartUpload 三处写路径的**单一**用户元数据
  解析器（铁律 2：同源，绝不各自手搓），保证三条入口对用户元数据头的提取语义完全一致。
  入参为 Plug.Conn 的 `req_headers`（`[{name, value}]`，name 可能任意大小写）。
  """
  @spec parse_headers([{String.t(), String.t()}]) :: %{optional(String.t()) => String.t()}
  def parse_headers(req_headers) when is_list(req_headers) do
    Enum.reduce(req_headers, %{}, fn {k, v}, acc ->
      case user_metadata_name(k) do
        nil -> acc
        name -> Map.put_new(acc, name, v)
      end
    end)
  end

  @doc "请求头总量上限（字节），供 Plug/测试/文档引用。"
  @spec max_header_size() :: pos_integer()
  def max_header_size, do: @max_header_size

  @doc "用户元数据上限（字节），供测试/文档引用。"
  @spec max_size() :: pos_integer()
  def max_size, do: @max_size

  @doc """
  校验原始请求头是否满足 MinIO 的入口级限制：

    * 所有请求头完整 key + value 总量 ≤ 8 KiB。
    * `x-amz-meta-*` / `x-minio-meta-*` 用户元数据完整 key + value 总量 ≤ 2 KiB。

  该函数不读取 body；用于 S3 endpoint 入口，在鉴权/分发前早拒超限请求。
  """
  @spec validate_headers!([{String.t(), String.t()}]) :: :ok
  def validate_headers!(req_headers) when is_list(req_headers) do
    {header_size, user_metadata_size} =
      Enum.reduce(req_headers, {0, 0}, fn {k, v}, {size, user_size} ->
        length = byte_size(to_string(k)) + byte_size(to_string(v))
        size = size + length

        user_size =
          if user_metadata_header?(k), do: user_size + length, else: user_size

        {size, user_size}
      end)

    if header_size > @max_header_size or user_metadata_size > @max_size do
      raise Maxio.S3.Error.new(:metadata_too_large)
    else
      :ok
    end
  end

  @doc """
  校验用户元数据（`%{name => value}`，name 已去 `x-amz-meta-` 前缀）总 UTF-8 字节和是否在上限内。
  每条按 MinIO `isHTTPHeaderSizeTooLarge` 计**完整 header key**：`byte_size("x-amz-meta-")`
  （= #{@meta_prefix_size}）+ `byte_size(name)` + `byte_size(value)`，累加严格超 2048 →
  `raise Maxio.S3.Error.new(:metadata_too_large)`（400，铁律 3 绝不静默）；否则返回 `:ok`。

  新代码优先用 `validate_headers!/1` 对原始请求头做入口级校验；该函数保留给已有 handler-level
  防线和纯 map 调用。
  """
  @spec validate_size!(%{optional(String.t()) => String.t()}) :: :ok
  def validate_size!(metadata) when is_map(metadata) do
    total =
      Enum.reduce(metadata, 0, fn {k, v}, acc ->
        acc + @meta_prefix_size + byte_size(to_string(k)) + byte_size(to_string(v))
      end)

    if total > @max_size do
      raise Maxio.S3.Error.new(:metadata_too_large)
    else
      :ok
    end
  end

  defp user_metadata_name(key) do
    key = String.downcase(to_string(key))

    Enum.find_value(@user_metadata_prefixes, fn prefix ->
      if String.starts_with?(key, prefix) do
        name = String.replace_prefix(key, prefix, "")
        if name == "", do: nil, else: name
      end
    end)
  end

  defp user_metadata_header?(key) do
    key = String.downcase(to_string(key))

    Enum.any?(@user_metadata_prefixes, fn prefix ->
      String.starts_with?(key, prefix)
    end)
  end
end
