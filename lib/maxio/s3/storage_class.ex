defmodule Maxio.S3.StorageClass do
  @moduledoc """
  S3 `x-amz-storage-class` 请求头解析与校验。

  maxio 当前仍是单一后端配置；这里先实现 S3 可见元数据语义：PutObject /
  CreateMultipartUpload / CopyObject 可指定 storage class，未指定则按 AWS 默认 `STANDARD`。
  """

  alias Maxio.S3.Error

  @valid MapSet.new([
           "STANDARD",
           "REDUCED_REDUNDANCY",
           "STANDARD_IA",
           "ONEZONE_IA",
           "INTELLIGENT_TIERING",
           "GLACIER",
           "DEEP_ARCHIVE",
           "OUTPOSTS",
           "GLACIER_IR",
           "SNOW",
           "EXPRESS_ONEZONE",
           "FSX_OPENZFS",
           "FSX_ONTAP"
         ])

  @doc "返回支持的 storage class API 值。"
  @spec valid_values() :: [String.t()]
  def valid_values, do: @valid |> MapSet.to_list() |> Enum.sort()

  @doc """
  解析 `x-amz-storage-class` 请求头值；nil/空白按 S3 默认 `STANDARD`。

  非支持值抛 `InvalidStorageClass`，保证失败发生在任何对象字节写入之前。
  """
  @spec parse!(String.t() | nil) :: String.t()
  def parse!(nil), do: "STANDARD"

  def parse!(value) when is_binary(value) do
    value = value |> String.trim() |> String.upcase()

    cond do
      value == "" ->
        "STANDARD"

      MapSet.member?(@valid, value) ->
        value

      true ->
        raise Error.new(:invalid_storage_class)
    end
  end
end
