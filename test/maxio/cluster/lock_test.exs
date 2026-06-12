defmodule Maxio.Cluster.LockTest do
  use ExUnit.Case, async: false
  alias Maxio.Cluster.{Lock, LockServer}

  test "with_lock 跑 fun 并返回 {:ok, result}" do
    assert {:ok, 42} = Lock.with_lock({"b", "k"}, fn -> 42 end)
  end

  test "嵌套不同资源不死锁" do
    assert {:ok, :inner} =
             Lock.with_lock({"b", "k1"}, fn ->
               {:ok, r} = Lock.with_lock({"b", "k2"}, fn -> :inner end)
               r
             end)
  end

  test "quorum_with_lock 单节点（quorum=1）获锁跑 fun" do
    assert {:ok, :done} = Lock.quorum_with_lock({"b", "k"}, fn -> :done end)
  end

  test "write lock excludes another owner on the same resource" do
    resource = resource("exclusive")
    {:ok, lease} = Lock.acquire(resource, nodes: [Node.self()], refresh: false)

    task =
      Task.async(fn ->
        Lock.acquire(resource, nodes: [Node.self()], retries: 0, refresh: false)
      end)

    assert {:error, :no_quorum} = Task.await(task)

    assert :ok = Lock.release(lease)
    assert {:ok, lease2} = Lock.acquire(resource, nodes: [Node.self()], refresh: false)
    assert :ok = Lock.release(lease2)
  end

  test "read locks can coexist while write waits" do
    resource = resource("readers")
    {:ok, read_lease} = Lock.acquire(resource, mode: :read, nodes: [Node.self()], refresh: false)

    reader =
      Task.async(fn ->
        Lock.acquire(resource, mode: :read, nodes: [Node.self()], refresh: false)
      end)

    assert {:ok, other_read_lease} = Task.await(reader)

    writer =
      Task.async(fn ->
        Lock.acquire(resource, mode: :write, nodes: [Node.self()], retries: 0, refresh: false)
      end)

    assert {:error, :no_quorum} = Task.await(writer)

    assert :ok = Lock.release(read_lease)
    assert :ok = Lock.release(other_read_lease)
  end

  test "failed quorum acquisition releases partial local grants" do
    resource = resource("partial")
    missing = :"missing_lock_node@127.0.0.1"

    assert {:error, :no_quorum} =
             Lock.acquire(resource,
               nodes: [Node.self(), missing],
               retries: 0,
               refresh: false,
               timeout: 10
             )

    assert {:ok, lease} = Lock.acquire(resource, nodes: [Node.self()], refresh: false)
    assert :ok = Lock.release(lease)
  end

  test "release-before-acquire cancellation rejects a late token grant" do
    resource = resource("cancelled")
    token = {:late_token, make_ref()}

    assert :ok = LockServer.release(token, 1_000)
    assert {:error, :cancelled} = LockServer.acquire(resource, token, self(), :write, 1_000)
  end

  test "lease expiry sweep releases stale tokens" do
    resource = resource("ttl")
    {:ok, _lease} = Lock.acquire(resource, nodes: [Node.self()], ttl_ms: -1, refresh: false)

    assert :ok = LockServer.sweep()
    assert {:ok, lease2} = Lock.acquire(resource, nodes: [Node.self()], refresh: false)
    assert :ok = Lock.release(lease2)
  end

  test "refresh cannot resurrect an expired token" do
    token = {:expired_refresh, make_ref()}
    resource = resource("expired-refresh")

    assert :ok = LockServer.acquire(resource, token, self(), :write, -1)
    assert {:error, :not_found} = LockServer.refresh(token, 1_000)

    assert {:ok, lease} = Lock.acquire(resource, nodes: [Node.self()], refresh: false)
    assert :ok = Lock.release(lease)
  end

  test "force_unlock removes local resource holders" do
    resource = resource("force")
    {:ok, _lease} = Lock.acquire(resource, nodes: [Node.self()], refresh: false)

    assert :ok = Lock.force_unlock(resource, nodes: [Node.self()])
    assert {:ok, lease2} = Lock.acquire(resource, nodes: [Node.self()], refresh: false)
    assert :ok = Lock.release(lease2)
  end

  test "quorum_with_lock aborts worker when heartbeat loses its lease" do
    resource = resource("lost")
    parent = self()

    task =
      Task.async(fn ->
        Lock.quorum_with_lock(
          resource,
          fn ->
            send(parent, :entered)

            receive do
              :finish -> :finished
            after
              5_000 -> :not_aborted
            end
          end,
          nodes: [Node.self()],
          ttl_ms: 1_000,
          heartbeat_ms: 10
        )
      end)

    assert_receive :entered
    assert :ok = Lock.force_unlock(resource, nodes: [Node.self()])
    assert {:error, :no_quorum} = Task.await(task, 1_000)

    assert {:ok, lease} = Lock.acquire(resource, nodes: [Node.self()], refresh: false)
    assert :ok = Lock.release(lease)
  end

  test "owner process death releases its local lease" do
    resource = resource("down")
    parent = self()

    pid =
      spawn(fn ->
        {:ok, _lease} = Lock.acquire(resource, nodes: [Node.self()], refresh: false)
        send(parent, :locked)
      end)

    ref = Process.monitor(pid)
    assert_receive :locked
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}
    assert {:ok, lease} = eventually_acquire(resource, 20)
    assert :ok = Lock.release(lease)
  end

  defp resource(label),
    do: {"lock-#{label}", Integer.to_string(System.unique_integer([:positive]))}

  defp eventually_acquire(resource, attempts) when attempts > 0 do
    case Lock.acquire(resource, nodes: [Node.self()], retries: 0, refresh: false) do
      {:ok, lease} ->
        {:ok, lease}

      {:error, :no_quorum} ->
        receive do
        after
          10 -> eventually_acquire(resource, attempts - 1)
        end
    end
  end
end
