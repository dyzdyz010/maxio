defmodule Maxio.Storage.Erasure.Meta do
  @moduledoc """
  纠删码 per-object（及 per-part）元数据 sidecar 的编解码（Jason JSON）。每盘一份，内容相同；
  heal 从任一存活副本恢复。形态见 M6 计划「盘上布局」节。
  """

  @spec encode(map()) :: binary()
  def encode(map) when is_map(map), do: Jason.encode!(map)

  @spec decode!(binary()) :: map()
  def decode!(bin) when is_binary(bin), do: Jason.decode!(bin)
end
