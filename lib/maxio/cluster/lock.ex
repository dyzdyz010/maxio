defmodule Maxio.Cluster.Lock do
  @moduledoc """
  对象级分布式锁（M7）。MVP：:global.trans/4（全 mesh 互斥，单资源无死锁；OTP25+ 防重叠分区）。
  升级路径：dsync 式 quorum 锁（n/2+1 节点多数即可获锁，更抗节点宕机），见 quorum_with_lock/3。
  铁律 3：获锁失败 -> {:error, :locked}/{:error, :no_quorum}，绝不静默继续（并发 PUT/heal 互踩 → 撕裂对象）。

  单节点 dev/test：:global.trans 在 nodes()==[Node.self()] 下退化为本地锁，同一代码路径。
  锁键约定：{bucket, key} 对象级；{bucket, ""} 桶级（与 with_lock 的 resource 一致）。
  """

  @type resource :: {String.t(), String.t()}

  @doc """
  以全 mesh 互斥锁运行 fun。:global.trans 内部 set_lock(retries) + 失败回退重试；
  retries 用尽返回 :aborted -> {:error, :locked}。lock id 含 self() 作 requester（owner）。
  """
  @spec with_lock(resource(), (-> result), non_neg_integer()) :: {:ok, result} | {:error, :locked}
        when result: var
  def with_lock(resource, fun, retries \\ 5) do
    lock_id = {{:maxio_obj, resource}, self()}

    case :global.trans(lock_id, fn -> {:ok, fun.()} end, Maxio.Cluster.nodes(), retries) do
      :aborted -> {:error, :locked}
      result -> result
    end
  end

  @doc """
  dsync 式 quorum 锁（升级路径）：向集群 N 个节点并行 set_lock，多数（n/2+1）成功即获锁，
  跑 fun 后释放全部已获锁；未达多数 -> 释放已获的 + {:error, :no_quorum}（调用方 semi-random 退避后重试）。
  比 :global.trans 更抗宕机：只需多数节点在线即可获锁。
  """
  @spec quorum_with_lock(resource(), (-> result), keyword()) ::
          {:ok, result} | {:error, :no_quorum}
        when result: var
  def quorum_with_lock(resource, fun, opts \\ []) do
    nodes = Maxio.Cluster.nodes()
    quorum = div(length(nodes), 2) + 1
    lock_id = {:maxio_obj, resource}
    timeout = Keyword.get(opts, :timeout, 3_000)

    positive =
      nodes
      |> Enum.filter(fn node -> try_set_lock(node, lock_id, timeout) end)

    release = fn ->
      Enum.each(positive, fn node -> try_del_lock(node, lock_id, timeout) end)
    end

    if length(positive) >= quorum do
      try do
        {:ok, fun.()}
      after
        release.()
      end
    else
      release.()
      {:error, :no_quorum}
    end
  end

  # 在单个 node 上以 retries=0（立即返回）尝试 set_lock，只锁该 node 自己（scope=[node]）。
  defp try_set_lock(node, lock_id, timeout) do
    erpc_bool(node, :set_lock, [{lock_id, self()}, [node], 0], timeout)
  end

  defp try_del_lock(node, lock_id, timeout) do
    _ = erpc_bool(node, :del_lock, [{lock_id, self()}, [node]], timeout)
    :ok
  end

  defp erpc_bool(node, fun, args, timeout) do
    if node == Node.self() do
      apply(:global, fun, args) == true
    else
      try do
        :erpc.call(node, :global, fun, args, timeout) == true
      catch
        :error, _reason -> false
        :exit, _reason -> false
        :throw, _reason -> false
      end
    end
  end
end
