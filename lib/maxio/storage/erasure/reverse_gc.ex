defmodule Maxio.Storage.Erasure.ReverseGC do
  @moduledoc """
  反向 GC 脚手架（ROUTE B；实现见 B5-2 scanner）。两类孤儿：

    1. PG 索引有行但 sidecar 缺（PG 滞后 / 旧备份恢复后的幽灵行）-> 标记 / 删索引行
       （**绝不删盘上数据**）。
    2. sidecar 在但 PG 缺（best-effort 索引写失败）-> upsert 索引行（reconcile）。

  本模块当前**仅暴露接口**（脚手架；不启用、不翻权威）；周期执行经 scanner（B5-2）填实现。
  铁律 3：绝不静默删盘上数据；差异只上报，由后续单元决策。
  """

  @typedoc "扫描得到的索引/盘上分歧报告。"
  @type divergence :: %{missing_sidecar: list(), missing_index: list()}

  @doc """
  扫描一个桶，返回需 reconcile 的差异（**实现 defer 到 B5-2**）。

  当前脚手架返回空差异（`%{missing_sidecar: [], missing_index: []}`），不做任何盘上 / 索引操作。
  """
  @spec scan_divergence(String.t(), keyword()) :: {:ok, divergence()}
  def scan_divergence(_bucket, _opts \\ []),
    do: {:ok, %{missing_sidecar: [], missing_index: []}}
end
