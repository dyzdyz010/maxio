defmodule Maxio.Cluster.Notify do
  @moduledoc """
  Cluster metadata notification facade.

  M8 uses Phoenix.PubSub as the local transport today; libcluster propagation can be layered behind
  this module without changing metadata mutation contexts.
  """

  @topic "maxio:metadata"

  @type event ::
          {:iam_changed, String.t()}
          | {:iam_credentials_changed, [String.t()]}
          | {:principal_policy_changed, String.t()}
          | {:bucket_config_changed, String.t(), atom()}
          | {:bucket_policy_changed, String.t()}
          | {:bucket_metadata_changed, String.t()}
          | {:object_metadata_changed, String.t(), String.t(), String.t() | nil}
          # 运行时配置失效（设计 §8 快路径）。新写路径使用 subsystem 级二元事件；三元事件
          # 仅保留给迁移期旧 sender。两者都由 Store full reload，周期 digest 对账负责兜底。
          | {:config_changed, atom()}
          | {:config_changed, atom(), atom()}

  @doc "Phoenix.PubSub topic used for metadata invalidation events."
  @spec topic() :: String.t()
  def topic, do: @topic

  @doc """
  Broadcast a metadata invalidation event.

  The facade is intentionally best-effort when PubSub is unavailable so CLI/bootstrap paths do not
  fail before the supervision tree is fully online.
  """
  @spec broadcast(event()) :: :ok
  def broadcast(event) do
    _result = broadcast_checked(event)
    :ok
  end

  @doc "Broadcasts an event and makes transport failure observable to mutation coordinators."
  @spec broadcast_checked(event()) ::
          :ok | {:error, :pubsub_unavailable | {:transport_exit, term()} | term()}
  def broadcast_checked(event) do
    if Process.whereis(Maxio.PubSub) do
      transport().broadcast(Maxio.PubSub, @topic, event)
    else
      {:error, :pubsub_unavailable}
    end
  rescue
    error -> {:error, {:transport_error, error.__struct__}}
  catch
    :exit, reason -> {:error, {:transport_exit, reason}}
  end

  defp transport,
    do: Application.get_env(:maxio, :cluster_notify_transport, Phoenix.PubSub)
end
