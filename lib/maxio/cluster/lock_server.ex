defmodule Maxio.Cluster.LockServer do
  @moduledoc """
  Per-node lease table for `Maxio.Cluster.Lock`.

  `Maxio.Cluster.Lock` acquires a quorum by asking multiple nodes to grant the same
  token. This server only owns local state, so the lock is dsync-style best effort,
  not a Raft-linearized primitive. It still closes the M7 MVP gap where lock state
  lived inside `:global.trans`: leases now have explicit tokens, monotonic expiry,
  owner-death cleanup, read/write compatibility, and admin force-unlock.
  """

  use GenServer

  @type mode :: :read | :write
  @type resource :: term()
  @type token :: term()

  @default_sweep_interval_ms 1_000
  @default_cancel_ttl_ms 60_000

  defstruct resources: %{},
            token_index: %{},
            monitors: %{},
            cancelled_tokens: %{},
            sweep_interval_ms: @default_sweep_interval_ms

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @spec acquire(resource(), token(), pid(), mode(), integer()) :: :ok | {:error, :locked}
  def acquire(resource, token, owner, mode, ttl_ms)
      when is_pid(owner) and mode in [:read, :write] and is_integer(ttl_ms) do
    GenServer.call(__MODULE__, {:acquire, resource, token, owner, mode, ttl_ms})
  end

  @spec release(token(), integer()) :: :ok
  def release(token, cancel_ttl_ms \\ @default_cancel_ttl_ms) when is_integer(cancel_ttl_ms) do
    GenServer.call(__MODULE__, {:release, token, cancel_ttl_ms})
  end

  @spec refresh(token(), integer()) :: :ok | {:error, :not_found}
  def refresh(token, ttl_ms) when is_integer(ttl_ms) do
    GenServer.call(__MODULE__, {:refresh, token, ttl_ms})
  end

  @spec force_unlock(resource()) :: :ok
  def force_unlock(resource), do: GenServer.call(__MODULE__, {:force_unlock, resource})

  @spec sweep() :: :ok
  def sweep, do: GenServer.call(__MODULE__, :sweep)

  @impl true
  def init(opts) do
    interval = Keyword.get(opts, :sweep_interval_ms, @default_sweep_interval_ms)
    schedule_sweep(interval)
    {:ok, %__MODULE__{sweep_interval_ms: interval}}
  end

  @impl true
  def handle_call({:acquire, resource, token, owner, mode, ttl_ms}, _from, state) do
    now = now_ms()
    state = sweep_expired(state, now)

    cond do
      token_cancelled?(state, token) ->
        {:reply, {:error, :cancelled}, state}

      token_known?(state, token) ->
        {:reply, :ok, refresh_holder(state, token, ttl_ms, now)}

      grantable?(state, resource, owner, mode) ->
        holder = %{
          resource: resource,
          token: token,
          owner: owner,
          mode: mode,
          deadline_ms: now + ttl_ms
        }

        {:reply, :ok, put_holder(state, holder)}

      true ->
        {:reply, {:error, :locked}, state}
    end
  end

  def handle_call({:release, token, cancel_ttl_ms}, _from, state) do
    now = now_ms()
    state = sweep_expired(state, now)

    state =
      if token_known?(state, token),
        do: drop_token(state, token),
        else: mark_cancelled(state, token, now + cancel_ttl_ms)

    {:reply, :ok, state}
  end

  def handle_call({:refresh, token, ttl_ms}, _from, state) do
    now = now_ms()
    state = sweep_expired(state, now)

    if token_known?(state, token) do
      {:reply, :ok, refresh_holder(state, token, ttl_ms, now)}
    else
      {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call({:force_unlock, resource}, _from, state) do
    {:reply, :ok, drop_resource(state, resource)}
  end

  def handle_call(:sweep, _from, state) do
    {:reply, :ok, sweep_expired(state, now_ms())}
  end

  @impl true
  def handle_info(:sweep, state) do
    schedule_sweep(state.sweep_interval_ms)
    {:noreply, sweep_expired(state, now_ms())}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    case Map.fetch(state.monitors, ref) do
      {:ok, token} -> {:noreply, drop_token(state, token)}
      :error -> {:noreply, state}
    end
  end

  defp schedule_sweep(interval_ms), do: Process.send_after(self(), :sweep, interval_ms)

  defp now_ms, do: System.monotonic_time(:millisecond)

  defp empty_resource, do: %{read: %{}, write: %{}}

  defp token_known?(state, token), do: Map.has_key?(state.token_index, token)

  defp token_cancelled?(state, token), do: Map.has_key?(state.cancelled_tokens, token)

  defp grantable?(state, resource, owner, :write) do
    resource_state = Map.get(state.resources, resource, empty_resource())
    same_owner?(resource_state.read, owner) and same_owner?(resource_state.write, owner)
  end

  defp grantable?(state, resource, owner, :read) do
    resource_state = Map.get(state.resources, resource, empty_resource())
    same_owner?(resource_state.write, owner)
  end

  defp same_owner?(holders, owner) do
    Enum.all?(holders, fn {_token, holder} -> holder.owner == owner end)
  end

  defp put_holder(state, holder) do
    ref = Process.monitor(holder.owner)
    holder = Map.put(holder, :monitor_ref, ref)
    resource_state = Map.get(state.resources, holder.resource, empty_resource())
    mode_holders = Map.put(Map.fetch!(resource_state, holder.mode), holder.token, holder)
    resource_state = Map.put(resource_state, holder.mode, mode_holders)

    %{
      state
      | resources: Map.put(state.resources, holder.resource, resource_state),
        token_index: Map.put(state.token_index, holder.token, {holder.resource, holder.mode}),
        monitors: Map.put(state.monitors, ref, holder.token),
        cancelled_tokens: Map.delete(state.cancelled_tokens, holder.token)
    }
  end

  defp refresh_holder(state, token, ttl_ms, now) do
    case holder_for(state, token) do
      nil ->
        state

      holder ->
        holder = %{holder | deadline_ms: now + ttl_ms}
        resource_state = Map.fetch!(state.resources, holder.resource)
        mode_holders = Map.put(Map.fetch!(resource_state, holder.mode), token, holder)
        resource_state = Map.put(resource_state, holder.mode, mode_holders)
        %{state | resources: Map.put(state.resources, holder.resource, resource_state)}
    end
  end

  defp drop_token(state, token) do
    case Map.fetch(state.token_index, token) do
      {:ok, {resource, mode}} ->
        holder = holder_for(state, token)
        state = demonitor_holder(state, holder)
        resource_state = Map.get(state.resources, resource, empty_resource())
        mode_holders = Map.delete(Map.fetch!(resource_state, mode), token)
        resource_state = Map.put(resource_state, mode, mode_holders)

        resources =
          if empty_resource?(resource_state),
            do: Map.delete(state.resources, resource),
            else: Map.put(state.resources, resource, resource_state)

        %{
          state
          | resources: resources,
            token_index: Map.delete(state.token_index, token),
            cancelled_tokens: Map.delete(state.cancelled_tokens, token)
        }

      :error ->
        state
    end
  end

  defp drop_resource(state, resource) do
    resource_state = Map.get(state.resources, resource, empty_resource())

    resource_state.read
    |> Map.keys()
    |> Kernel.++(Map.keys(resource_state.write))
    |> Enum.reduce(state, fn token, acc -> drop_token(acc, token) end)
  end

  defp demonitor_holder(state, nil), do: state

  defp demonitor_holder(state, %{monitor_ref: ref}) do
    Process.demonitor(ref, [:flush])
    %{state | monitors: Map.delete(state.monitors, ref)}
  end

  defp empty_resource?(%{read: read, write: write}),
    do: map_size(read) == 0 and map_size(write) == 0

  defp mark_cancelled(state, token, deadline_ms) do
    %{state | cancelled_tokens: Map.put(state.cancelled_tokens, token, deadline_ms)}
  end

  defp sweep_expired(state, now) do
    state =
      state.token_index
      |> Map.keys()
      |> Enum.reduce(state, fn token, acc ->
        case holder_for(acc, token) do
          %{deadline_ms: deadline} when deadline <= now -> drop_token(acc, token)
          _holder -> acc
        end
      end)

    cancelled_tokens =
      state.cancelled_tokens
      |> Enum.reject(fn {_token, deadline} -> deadline <= now end)
      |> Map.new()

    %{state | cancelled_tokens: cancelled_tokens}
  end

  defp holder_for(state, token) do
    with {:ok, {resource, mode}} <- Map.fetch(state.token_index, token),
         resource_state when not is_nil(resource_state) <- Map.get(state.resources, resource) do
      resource_state
      |> Map.fetch!(mode)
      |> Map.get(token)
    else
      _ -> nil
    end
  end
end
