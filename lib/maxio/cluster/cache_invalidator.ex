defmodule Maxio.Cluster.CacheInvalidator do
  @moduledoc """
  Subscribes to cluster metadata notifications and invalidates node-local caches.

  Current production Ecto stores are read-through from Postgres, so most events are no-ops today.
  The contract is still centralized here so future caches can be added without touching every S3
  handler or Console LiveView.
  """

  use GenServer

  require Logger

  alias Maxio.Auth.CredentialStore
  alias Maxio.Cluster.Notify

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, :ok, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init(:ok) do
    subscribe()
    {:ok, %{}}
  end

  @impl true
  def handle_info({:iam_changed, access_key_id}, state) when is_binary(access_key_id) do
    :ok = CredentialStore.invalidate({:access_key, access_key_id})
    {:noreply, state}
  end

  def handle_info(
        event,
        state
      )
      when tuple_size(event) in [2, 3, 4] do
    case event do
      {:principal_policy_changed, _principal_arn} -> :ok
      {:bucket_config_changed, _bucket, _kind} -> :ok
      {:bucket_policy_changed, _bucket} -> :ok
      {:bucket_metadata_changed, _bucket} -> :ok
      {:object_metadata_changed, _bucket, _key, _version_id} -> :ok
      other -> Logger.debug("ignored unknown metadata event", event: inspect(other))
    end

    {:noreply, state}
  end

  def handle_info(message, state) do
    Logger.debug("ignored cache invalidator message", message: inspect(message))
    {:noreply, state}
  end

  defp subscribe do
    if Process.whereis(Maxio.PubSub) do
      Phoenix.PubSub.subscribe(Maxio.PubSub, Notify.topic())
    end

    :ok
  catch
    :exit, _ -> :ok
  end
end
