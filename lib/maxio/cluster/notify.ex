defmodule Maxio.Cluster.Notify do
  @moduledoc """
  Cluster metadata notification facade.

  M8 uses Phoenix.PubSub as the local transport today; libcluster propagation can be layered behind
  this module without changing metadata mutation contexts.
  """

  @topic "maxio:metadata"

  @type event ::
          {:iam_changed, String.t()}
          | {:principal_policy_changed, String.t()}
          | {:bucket_config_changed, String.t(), atom()}
          | {:bucket_policy_changed, String.t()}
          | {:bucket_metadata_changed, String.t()}
          | {:object_metadata_changed, String.t(), String.t(), String.t() | nil}

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
    if Process.whereis(Maxio.PubSub) do
      Phoenix.PubSub.broadcast(Maxio.PubSub, @topic, event)
    end

    :ok
  catch
    :exit, _ -> :ok
  end
end
