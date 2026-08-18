defmodule Maxio.S3.ObjectMutationError do
  @moduledoc """
  对象变更提交/恢复失败到 S3 公共错误的**唯一共享 HTTP 适配器**。

  PutObject / CopyObject（经 object handler 的写错误映射点）与 ObjectWriter 共用本模块，
  避免各自复制同一套类别策略、也避免各自保留 `inspect(reason)` 兜底。

  唯一公共函数：

      to_error(reason, resource)

  它把 reason 交给冻结的 `Maxio.ObjectMutation.ExternalError.project/1` 判定**一次**，
  只按公共类别映射：

      {:ok, :retryable, _safe_code} -> {:ok, %Maxio.S3.Error{}}  # 503 SlowDownWrite
      {:ok, :internal, _safe_code}  -> {:ok, %Maxio.S3.Error{}}  # 500 InternalError
      :unrelated                    -> :unrelated

  `:unrelated` 原样交还调用方，既有的 write quorum / epoch quorum / fence / metadata CAS /
  placement 可用性等 legacy 分类路径**一行不改**。

  ## 不变量

  1. 绝不匹配内部稳定错误信封，绝不读取、遍历、编码或回显 canonical summary；
     类别与可重试性只来自 `ExternalError` 的公共结果。
  2. 公共 message 一律取错误目录默认值：绝不接受调用方自带 message，绝不写入
     `inspect(reason)`、路径、端点、节点、盘符、token 或备份名。
  3. 纯函数：无日志、无 I/O、无配置读取、无时间/重试、无 Storage/PublishedProof/
     Commit/Recovery/StorageDisposition/journal/Repo 依赖。
  4. `resource` 逐字透传（含 `nil`），由调用方决定其取值。
  """

  alias Maxio.ObjectMutation.ExternalError
  alias Maxio.S3.Error

  @doc """
  把一个对象变更 reason 映射成 S3 公共错误；与本闸门无关的 reason 返回 `:unrelated`，
  由调用方继续走既有分类。
  """
  @spec to_error(term(), String.t() | nil) :: {:ok, Error.t()} | :unrelated
  def to_error(reason, resource) do
    case ExternalError.project(reason) do
      {:ok, :retryable, _safe_code} ->
        {:ok, Error.new(:slow_down_write, resource: resource)}

      {:ok, :internal, _safe_code} ->
        {:ok, Error.new(:internal_error, resource: resource)}

      :unrelated ->
        :unrelated
    end
  end
end
