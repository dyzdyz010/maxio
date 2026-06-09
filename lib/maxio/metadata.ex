defmodule Maxio.Metadata do
  @moduledoc """
  用户自定义元数据（`x-amz-meta-*`）的大小校验（官方核验 bake-in）。

  AWS/MinIO 对单个对象的用户元数据总量设 2 KB（2048 字节）硬上限：所有 `x-amz-meta-*` 头的
  **完整 key（含 `x-amz-meta-` 前缀）+ value 的 UTF-8 字节和**累加超 2048 → `MetadataTooLarge`(400)。
  权威：AWS UsingMetadata.html（user-defined metadata 限 2 KB / 每 key+value 的 UTF-8 字节和）；
  minio/minio `cmd/generic-handlers.go` `isHTTPHeaderSizeTooLarge`（`maxUserDataSize = 2*1024`，
  逐头 `length = len(fullHeaderKey) + len(value)`，`fullHeaderKey` 含 `x-amz-meta-` 前缀，
  `usersize > maxUserDataSize` → `ErrMetadataTooLarge`）。

  本模块仅做大小闸（仿 `Maxio.Tags` 风格的纯函数校验器，无 Plug/Conn 耦合），由 PutObject /
  CopyObject(REPLACE) handler 在写任何字节/sidecar **之前**调用——失败 pre-commit、不留孤儿（铁律 3）。
  """

  # AWS 用户元数据总量上限：2 KB（2048 字节）。
  @max_size 2048

  # `x-amz-meta-` 前缀字节数（11）。MinIO `isHTTPHeaderSizeTooLarge` 按**完整 header key**
  # （含此前缀）计量；`parse_headers/1` 已剥去前缀，故 `validate_size!/1` 求和时须为每条
  # entry 加回此常量，使边界与 MinIO `len(fullHeaderKey)+len(value)` 字节一致。
  @meta_prefix_size byte_size("x-amz-meta-")

  @doc """
  从请求头解析用户自定义元数据：`x-amz-meta-<name>` → `%{name => value}`
  （去掉 `x-amz-meta-` 前缀，name 小写；空 name 跳过）。

  这是 PutObject / CopyObject(REPLACE) / CreateMultipartUpload 三处写路径的**单一**用户元数据
  解析器（铁律 2：同源，绝不各自手搓），保证三条入口对 `x-amz-meta-*` 的提取语义完全一致。
  入参为 Plug.Conn 的 `req_headers`（`[{name, value}]`，name 可能任意大小写）。
  """
  @spec parse_headers([{String.t(), String.t()}]) :: %{optional(String.t()) => String.t()}
  def parse_headers(req_headers) when is_list(req_headers) do
    req_headers
    |> Enum.flat_map(fn {k, v} ->
      case String.downcase(k) do
        "x-amz-meta-" <> name when name != "" -> [{name, v}]
        _ -> []
      end
    end)
    |> Map.new()
  end

  @doc "用户元数据上限（字节），供测试/文档引用。"
  @spec max_size() :: pos_integer()
  def max_size, do: @max_size

  @doc """
  校验用户元数据（`%{name => value}`，name 已去 `x-amz-meta-` 前缀）总 UTF-8 字节和是否在上限内。
  每条按 MinIO `isHTTPHeaderSizeTooLarge` 计**完整 header key**：`byte_size("x-amz-meta-")`
  （= #{@meta_prefix_size}）+ `byte_size(name)` + `byte_size(value)`，累加严格超 2048 →
  `raise Maxio.S3.Error.new(:metadata_too_large)`（400，铁律 3 绝不静默）；否则返回 `:ok`。
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
end
