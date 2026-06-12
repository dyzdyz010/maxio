defmodule Maxio.Lock do
  @moduledoc """
  请求编排层的对象锁门面（ROUTE B B1-1）。把「字节写 + 元数据提交」整段纳入同一对象级互斥锁，
  消灭并发同 key 写的「字节-元数据交错分歧」（静默 ETag/bytes 分歧）。底层复用
  Maxio.Cluster.Lock.with_lock/2（quorum lease；单节点退化本地 LockServer，同一代码路径）。

  铁律 3：获锁失败 -> {:error, :locked}，调用方（handler）映射 S3 503 RequestTimeout，
  绝不静默并发写同对象。
  铁律 2：锁是请求编排关注点 —— 字节后端（Distributed/EC/FS）不再自持对象锁；锁责任收敛到本门面单点。
  """
  alias Maxio.Cluster.Lock

  @type resource :: {String.t(), String.t()}

  @doc "在对象级互斥锁内运行 fun（横跨字节+元数据提交）。获锁失败 -> {:error, :locked}。"
  @spec with_object_lock(resource(), (-> result)) :: {:ok, result} | {:error, :locked}
        when result: var
  def with_object_lock({_bucket, _key} = resource, fun) when is_function(fun, 0) do
    Lock.with_lock(resource, fun)
  end
end
