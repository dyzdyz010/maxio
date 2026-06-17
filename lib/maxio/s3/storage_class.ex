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

  @lifecycle_transition_valid MapSet.new([
                                "STANDARD_IA",
                                "ONEZONE_IA",
                                "INTELLIGENT_TIERING",
                                "GLACIER",
                                "DEEP_ARCHIVE",
                                "GLACIER_IR"
                              ])

  @doc "返回支持的 storage class API 值。"
  @spec valid_values() :: [String.t()]
  def valid_values, do: @valid |> MapSet.to_list() |> Enum.sort()

  @doc "返回 S3 Lifecycle Transition 支持的目标 storage class。"
  @spec lifecycle_transition_values() :: [String.t()]
  def lifecycle_transition_values,
    do: @lifecycle_transition_valid |> MapSet.to_list() |> Enum.sort()

  @doc "判断值是否为 Lifecycle Transition 支持的目标 storage class。"
  @spec lifecycle_transition_valid?(term()) :: boolean()
  def lifecycle_transition_valid?(value) when is_binary(value) do
    value = value |> String.trim() |> String.upcase()
    MapSet.member?(@lifecycle_transition_valid, value)
  end

  def lifecycle_transition_valid?(_value), do: false

  @doc "判断 current-version lifecycle Transition 的 Days 是否符合目标 storage class 约束。"
  @spec lifecycle_transition_days_valid?(term(), term()) :: boolean()
  def lifecycle_transition_days_valid?(storage_class, days)
      when is_binary(storage_class) and is_integer(days) do
    case storage_class |> String.trim() |> String.upcase() do
      target when target in ["STANDARD_IA", "ONEZONE_IA"] ->
        days >= 30

      target when target in ["INTELLIGENT_TIERING", "GLACIER_IR", "GLACIER", "DEEP_ARCHIVE"] ->
        days >= 0

      _other ->
        false
    end
  end

  def lifecycle_transition_days_valid?(_storage_class, _days), do: false

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
