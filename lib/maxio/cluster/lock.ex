defmodule Maxio.Cluster.Lock do
  @moduledoc """
  Distributed object lock facade.

  The public M7 API is preserved (`with_lock/2,3` and `quorum_with_lock/2,3`),
  but the implementation now goes through `Maxio.Cluster.LockServer` on each node.
  A caller receives the lock only after enough nodes grant the same lease token.

  This is a dsync-style quorum lease, not a Raft-linearized lock. Node restarts can
  forget local leases, so future fencing tokens are still required before using this
  as a hard write epoch. Within that boundary it improves the M7 `:global.trans`
  MVP by adding explicit release, refresh, force unlock, read/write modes, owner
  death cleanup, and monotonic lease expiry.
  """

  @type resource :: term()
  @type lease :: %{
          resource: resource(),
          token: term(),
          mode: :read | :write,
          nodes: [node()],
          granted: [node()],
          quorum: pos_integer(),
          ttl_ms: integer(),
          timeout: integer(),
          heartbeat_pid: pid() | nil
        }

  @default_ttl_ms 15_000
  @default_timeout_ms 3_000

  @doc """
  Run `fun` under a write lock.

  The third argument remains the legacy retry count. Failures keep the established
  return shape: `{:error, :locked}`.
  """
  @spec with_lock(resource(), (-> result), non_neg_integer()) :: {:ok, result} | {:error, :locked}
        when result: var
  def with_lock(resource, fun, retries \\ 5) when is_function(fun, 0) do
    case acquire(resource, mode: :write, retries: retries) do
      {:ok, lease} ->
        run_with_lease(lease, fun, {:error, :locked})

      {:error, :no_quorum} ->
        {:error, :locked}
    end
  end

  @doc """
  Acquire a quorum lease.

  Options:

    * `:mode` - `:write` (default) or `:read`;
    * `:nodes` - node list to contact, default `Maxio.Cluster.nodes/0`;
    * `:ttl_ms` - lease TTL, default 15 seconds;
    * `:refresh` - start a heartbeat refresher, default true;
    * `:retries` - retry attempts after the first try, default 0;
    * `:timeout` - per-node `:erpc` timeout, default 3 seconds.
  """
  @spec acquire(resource(), keyword()) :: {:ok, lease()} | {:error, :no_quorum}
  def acquire(resource, opts \\ []) do
    opts = normalize_opts(opts)
    token = {Node.self(), self(), make_ref()}
    do_acquire(resource, token, opts.retries, opts)
  end

  @doc "Release a quorum lease from every node that granted it."
  @spec release(lease()) :: :ok
  def release(%{nodes: nodes, token: token, timeout: timeout, ttl_ms: ttl_ms} = lease) do
    stop_heartbeat(lease)
    release_all(nodes, token, timeout, ttl_ms)
    :ok
  end

  @doc "Refresh a quorum lease on its granted nodes."
  @spec refresh(lease()) :: :ok | {:error, :no_quorum}
  def refresh(%{granted: granted, token: token, ttl_ms: ttl_ms, timeout: timeout, quorum: quorum}) do
    ok =
      Enum.count(granted, fn node ->
        call_node(node, :refresh, [token, ttl_ms], timeout) == :ok
      end)

    if ok >= quorum, do: :ok, else: {:error, :no_quorum}
  end

  @doc "Force-unlock a resource on all target nodes."
  @spec force_unlock(resource(), keyword()) :: :ok
  def force_unlock(resource, opts \\ []) do
    opts = normalize_opts(opts)
    Enum.each(opts.nodes, &call_node(&1, :force_unlock, [resource], opts.timeout))
    :ok
  end

  @doc "Run `fun` under a quorum lock and return `{:error, :no_quorum}` on acquisition failure."
  @spec quorum_with_lock(resource(), (-> result), keyword()) ::
          {:ok, result} | {:error, :no_quorum}
        when result: var
  def quorum_with_lock(resource, fun, opts \\ []) when is_function(fun, 0) do
    case acquire(resource, opts) do
      {:ok, lease} ->
        run_with_lease(lease, fun, {:error, :no_quorum})

      {:error, :no_quorum} ->
        {:error, :no_quorum}
    end
  end

  defp normalize_opts(opts) do
    nodes = Keyword.get(opts, :nodes, Maxio.Cluster.nodes())
    mode = Keyword.get(opts, :mode, :write)

    %{
      nodes: Enum.uniq(nodes),
      mode: mode,
      ttl_ms: Keyword.get(opts, :ttl_ms, @default_ttl_ms),
      refresh: Keyword.get(opts, :refresh, true),
      retries: Keyword.get(opts, :retries, 0),
      timeout: Keyword.get(opts, :timeout, @default_timeout_ms),
      heartbeat_ms: Keyword.get(opts, :heartbeat_ms)
    }
  end

  defp do_acquire(resource, token, retries_left, opts) do
    granted =
      Enum.filter(opts.nodes, fn node ->
        call_node(node, :acquire, [resource, token, self(), opts.mode, opts.ttl_ms], opts.timeout) ==
          :ok
      end)

    quorum = quorum(length(opts.nodes), opts.mode)

    if length(granted) >= quorum do
      lease = %{
        resource: resource,
        token: token,
        mode: opts.mode,
        nodes: opts.nodes,
        granted: granted,
        quorum: quorum,
        ttl_ms: opts.ttl_ms,
        timeout: opts.timeout,
        heartbeat_pid: nil
      }

      {:ok, maybe_start_heartbeat(lease, opts)}
    else
      release_all(opts.nodes, token, opts.timeout, opts.ttl_ms)

      if retries_left > 0 do
        wait_before_retry(retries_left)
        do_acquire(resource, token, retries_left - 1, opts)
      else
        {:error, :no_quorum}
      end
    end
  end

  defp quorum(0, _mode), do: 1
  defp quorum(n, :write), do: div(n, 2) + 1
  defp quorum(n, :read), do: div(n + 1, 2)

  defp release_all(nodes, token, timeout, ttl_ms) do
    Enum.each(nodes, &call_node(&1, :release, [token, cancel_ttl_ms(ttl_ms)], timeout))
  end

  defp maybe_start_heartbeat(lease, %{refresh: false}), do: lease

  defp maybe_start_heartbeat(lease, opts) do
    interval = opts.heartbeat_ms || max(div(opts.ttl_ms, 3), 100)
    parent = self()

    pid =
      spawn_link(fn ->
        ref = Process.monitor(parent)
        heartbeat_loop(parent, ref, lease, interval)
      end)

    %{lease | heartbeat_pid: pid}
  end

  defp stop_heartbeat(%{heartbeat_pid: nil}), do: :ok

  defp stop_heartbeat(%{heartbeat_pid: pid}) when is_pid(pid) do
    send(pid, :stop)
    :ok
  end

  defp heartbeat_loop(parent, ref, lease, interval) do
    receive do
      :stop ->
        Process.demonitor(ref, [:flush])
        :ok

      {:DOWN, ^ref, :process, ^parent, _reason} ->
        :ok
    after
      interval ->
        case refresh(lease) do
          :ok -> heartbeat_loop(parent, ref, lease, interval)
          {:error, :no_quorum} -> send(parent, {:maxio_lock_lost, lease.token, lease.resource})
        end
    end
  end

  defp run_with_lease(lease, fun, lock_lost_error) do
    parent = self()

    {worker, ref} =
      spawn_monitor(fn ->
        result =
          try do
            {:ok, fun.()}
          catch
            kind, reason ->
              {:caught, kind, reason, __STACKTRACE__}
          end

        send(parent, {:maxio_lock_result, self(), result})
      end)

    try do
      wait_for_result(lease, worker, ref, lock_lost_error)
    after
      release(lease)
    end
  end

  defp wait_for_result(lease, worker, ref, lock_lost_error) do
    receive do
      {:maxio_lock_result, ^worker, {:ok, result}} ->
        Process.demonitor(ref, [:flush])
        {:ok, result}

      {:maxio_lock_result, ^worker, {:caught, kind, reason, stacktrace}} ->
        Process.demonitor(ref, [:flush])
        :erlang.raise(kind, reason, stacktrace)

      {:maxio_lock_lost, token, _resource} when token == lease.token ->
        Process.exit(worker, :kill)
        wait_for_worker_down(worker, ref)
        lock_lost_error

      {:DOWN, ^ref, :process, ^worker, reason} ->
        exit(reason)

      _other ->
        wait_for_result(lease, worker, ref, lock_lost_error)
    end
  end

  defp wait_for_worker_down(worker, ref) do
    receive do
      {:DOWN, ^ref, :process, ^worker, _reason} -> :ok
    after
      1_000 -> :ok
    end
  end

  defp wait_before_retry(retries_left) do
    receive do
    after
      min(25 * retries_left, 100) -> :ok
    end
  end

  defp call_node(node, fun, args, timeout) do
    try do
      if node == Node.self() do
        apply(Maxio.Cluster.LockServer, fun, args)
      else
        :erpc.call(node, Maxio.Cluster.LockServer, fun, args, timeout)
      end
    catch
      :error, _reason -> {:error, :unavailable}
      :exit, _reason -> {:error, :unavailable}
      :throw, _reason -> {:error, :unavailable}
    end
  end

  defp cancel_ttl_ms(ttl_ms), do: max(ttl_ms * 2, 60_000)
end
