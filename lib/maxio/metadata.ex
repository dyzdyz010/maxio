defmodule Maxio.Metadata do
  @moduledoc """
  用户自定义元数据（`x-amz-meta-*`）的大小校验（官方核验 bake-in）。

  AWS/MinIO 对单个对象的用户元数据总量设 2 KB（2048 字节）硬上限：所有 `x-amz-meta-*` 头的
  **key（去前缀后的名字）+ value 的 UTF-8 字节和**累加超 2048 → `MetadataTooLarge`(400)
  （对齐 s3-tests `test_object_set_get_metadata_overflow_*` 断言此阈值；MinIO `ErrMetadataTooLarge`）。

  本模块仅做大小闸（仿 `Maxio.Tags` 风格的纯函数校验器，无 Plug/Conn 耦合），由 PutObject /
  CopyObject(REPLACE) handler 在写任何字节/sidecar **之前**调用——失败 pre-commit、不留孤儿（铁律 3）。
  """

  # AWS 用户元数据总量上限：2 KB（2048 字节）。
  @max_size 2048

  @doc "用户元数据上限（字节），供测试/文档引用。"
  @spec max_size() :: pos_integer()
  def max_size, do: @max_size

  @doc """
  校验用户元数据（`%{name => value}`，name 已去 `x-amz-meta-` 前缀）总 UTF-8 字节和是否在上限内。
  超 2048 字节 → `raise Maxio.S3.Error.new(:metadata_too_large)`（400，铁律 3 绝不静默）；否则返回 `:ok`。
  """
  @spec validate_size!(%{optional(String.t()) => String.t()}) :: :ok
  def validate_size!(metadata) when is_map(metadata) do
    total =
      Enum.reduce(metadata, 0, fn {k, v}, acc ->
        acc + byte_size(to_string(k)) + byte_size(to_string(v))
      end)

    if total > @max_size do
      raise Maxio.S3.Error.new(:metadata_too_large)
    else
      :ok
    end
  end
end
