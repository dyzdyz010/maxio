defmodule Maxio.Storage.ObjectCommitTest do
  use ExUnit.Case, async: true

  alias Maxio.Storage.ObjectCommit
  alias Maxio.Storage.ObjectCommit.Control

  test "default path publishes once with the caller-provided commit options" do
    parent = self()

    result =
      ObjectCommit.run(
        [],
        %{size: 3},
        [version_id: "null", object_meta: %{}],
        fn commit_opts ->
          register_publish!(commit_opts, parent)
          send(parent, {:published, Keyword.take(commit_opts, [:version_id, :object_meta])})
          {:ok, :committed}
        end,
        fn -> send(parent, :discarded) end
      )

    assert result == {:ok, :committed}
    assert_receive {:published, [version_id: "null", object_meta: %{}]}
    assert_receive {:control, :finalize, identity} when is_binary(identity)
    refute_receive :discarded
  end

  test "around callback receives prepared state and may supply final commit options" do
    parent = self()

    around = fn prepared, publish ->
      assert Map.take(prepared, [:etag, :size]) == %{etag: "etag", size: 3}
      assert is_binary(Map.fetch!(prepared, :object_commit_identity))
      assert is_pid(Map.fetch!(prepared, :object_commit_control))
      publish.(version_id: "locked-version", object_meta: %{checksum: %{}})
    end

    assert {:ok, :committed} =
             ObjectCommit.run(
               [around_object_commit: around],
               %{etag: "etag", size: 3},
               [version_id: "ignored", object_meta: %{}],
               fn commit_opts ->
                 register_publish!(commit_opts, parent)

                 send(
                   parent,
                   {:published, Keyword.take(commit_opts, [:version_id, :object_meta])}
                 )

                 {:ok, :committed}
               end,
               fn -> send(parent, :discarded) end
             )

    assert_receive {:published, [version_id: "locked-version", object_meta: %{checksum: %{}}]}
    assert_receive {:control, :finalize, identity} when is_binary(identity)
    refute_receive :discarded
  end

  test "pre-publication abort discards staging and preserves the error" do
    parent = self()
    around = fn _prepared, _publish -> {:error, :locked} end

    assert {:error, :locked} =
             ObjectCommit.run(
               [around_object_commit: around],
               %{},
               [version_id: "null", object_meta: %{}],
               fn _commit_opts -> send(parent, :published) end,
               fn -> send(parent, :discarded) end
             )

    assert_receive :discarded
    refute_receive :published
  end

  test "successful return without publish and duplicate publish fail closed" do
    parent = self()

    assert_raise ArgumentError, ~r/without publishing/, fn ->
      ObjectCommit.run(
        [around_object_commit: fn _prepared, _publish -> :ok end],
        %{},
        [version_id: "null", object_meta: %{}],
        fn _commit_opts -> send(parent, :published) end,
        fn -> send(parent, :discarded_missing) end
      )
    end

    assert_receive :discarded_missing
    refute_receive :published

    around = fn _prepared, publish ->
      assert {:ok, :committed} = publish.(version_id: "v1", object_meta: %{})
      publish.(version_id: "v2", object_meta: %{})
    end

    assert_raise ArgumentError, ~r/must be called once/, fn ->
      ObjectCommit.run(
        [around_object_commit: around],
        %{},
        [version_id: "null", object_meta: %{}],
        fn commit_opts ->
          register_publish!(commit_opts, parent)
          send(parent, {:published_once, Keyword.take(commit_opts, [:version_id, :object_meta])})
          {:ok, :committed}
        end,
        fn -> send(parent, :discarded_duplicate) end
      )
    end

    assert_receive {:published_once, [version_id: "v1", object_meta: %{}]}
    assert_receive :discarded_duplicate
    assert_receive {:control, :rollback, identity} when is_binary(identity)
    refute_receive {:published_once, [version_id: "v2", object_meta: %{}]}
    refute_receive {:control, :finalize, _identity}
  end

  test "metadata callback exception rolls published bytes back" do
    parent = self()

    around = fn _prepared, publish ->
      assert {:ok, :published} = publish.(version_id: "v1", object_meta: %{})
      raise "metadata commit failed"
    end

    assert_raise RuntimeError, "metadata commit failed", fn ->
      ObjectCommit.run(
        [around_object_commit: around],
        %{},
        [version_id: "ignored", object_meta: %{}],
        fn commit_opts ->
          register_publish!(commit_opts, parent)
          {:ok, :published}
        end,
        fn -> send(parent, :discarded_after_metadata_failure) end
      )
    end

    assert_receive {:control, :rollback, identity} when is_binary(identity)
    assert_receive :discarded_after_metadata_failure
    refute_receive {:control, :finalize, _identity}
  end

  test "mark_committed finalizes before the publisher returns" do
    parent = self()

    around = fn prepared, publish ->
      result = publish.(version_id: "v1", object_meta: %{})
      assert :ok = Control.mark_committed(Map.fetch!(prepared, :object_commit_control))
      result
    end

    assert {:ok, :published} =
             ObjectCommit.run(
               [around_object_commit: around],
               %{},
               [version_id: "ignored", object_meta: %{}],
               fn commit_opts ->
                 register_publish!(commit_opts, parent)
                 {:ok, :published}
               end,
               fn -> send(parent, :discarded_after_commit) end
             )

    assert_receive {:control, :finalize, identity} when is_binary(identity)
    refute_receive {:control, :rollback, _identity}
    refute_receive :discarded_after_commit
  end

  test "owner DOWN event waits for matching publisher DOWN before rollback" do
    parent = self()

    publisher =
      start_supervised!(%{
        id: :object_commit_waiting_publisher,
        start:
          {Task, :start_link,
           [
             fn ->
               receive do
                 :stop -> :ok
               end
             end
           ]},
        restart: :temporary
      })

    {:ok, control} = Control.start(self())
    identity = Control.identity()

    :ok =
      Control.register(
        control,
        identity,
        fn ->
          send(parent, {:owner_down_control, :rollback})
          :ok
        end,
        fn ->
          send(parent, {:owner_down_control, :finalize})
          :ok
        end
      )

    initial = :sys.get_state(control)
    publisher_ref = make_ref()

    :sys.replace_state(control, fn state ->
      %{state | publisher: publisher, publisher_ref: publisher_ref}
    end)

    control_ref = Process.monitor(control)
    send(control, {:DOWN, initial.owner_ref, :process, self(), :shutdown})

    state = :sys.get_state(control)
    assert state.owner_down?
    refute_receive {:owner_down_control, :rollback}

    send(control, {:DOWN, publisher_ref, :process, publisher, :killed})

    assert_receive {:owner_down_control, :rollback}
    assert_receive {:DOWN, ^control_ref, :process, ^control, :normal}
    refute_receive {:owner_down_control, :finalize}
  end

  test "abnormal publisher DOWN rolls back" do
    parent = self()

    publisher =
      start_supervised!(%{
        id: :abnormal_object_commit_publisher,
        start:
          {Task, :start_link,
           [
             fn ->
               receive do
                 :stop -> :ok
               end
             end
           ]},
        restart: :temporary
      })

    {:ok, control} = Control.start(self())

    # 监听必须在 control 还**确定活着**的时候建立：`arm_publisher/2` 内部对 publisher 下
    # `Process.monitor/1`，publisher 若在那一刻已经不在了，BEAM 立刻投递 `:noproc` DOWN，
    # control 随即回滚并 `:normal` 退出。若监听晚于 arm，满负载下测试进程只要被调度器挪开
    # 一下，`Process.monitor/1` 就只能拿到 `:noproc`——真实退出原因永远观测不到，下面对
    # `:normal` 的断言就不可能成立（实测：arm 之后插一次 `:erlang.yield/0`，3000/3000 全是
    # `:noproc`；把监听提到 arm 之前，3000/3000 全是 `:normal`）。
    control_ref = Process.monitor(control)
    identity = Control.identity()

    :ok =
      Control.register(
        control,
        identity,
        fn ->
          send(parent, {:publisher_down_control, :rollback})
          :ok
        end,
        fn ->
          send(parent, {:publisher_down_control, :finalize})
          :ok
        end
      )

    :ok = Control.arm_publisher(control, publisher)
    Process.exit(publisher, :publisher_failed)

    assert_receive {:publisher_down_control, :rollback}
    assert_receive {:DOWN, ^control_ref, :process, ^control, :normal}
    refute_receive {:publisher_down_control, :finalize}
  end

  test "rollback invokes the backend and every additional callback" do
    parent = self()
    {:ok, control} = Control.start(self())
    identity = Control.identity()

    :ok =
      Control.register(
        control,
        identity,
        fn ->
          send(parent, :backend_rollback)
          :ok
        end,
        fn ->
          send(parent, :backend_finalize)
          :ok
        end
      )

    :ok =
      Control.add_rollback(control, fn ->
        send(parent, :ledger_rollback)
        :ok
      end)

    :ok =
      Control.add_rollback(control, fn ->
        send(parent, :secondary_rollback)
        {:error, :secondary_failed}
      end)

    assert {:error, :secondary_failed} = Control.rollback(control)
    assert_receive :backend_rollback
    assert_receive :ledger_rollback
    assert_receive :secondary_rollback
    refute_receive :backend_finalize
  end

  test "unregistered control refuses commit and finalize" do
    {:ok, control} = Control.start(self())

    assert {:error, :not_registered} = Control.mark_committed(control)
    assert {:error, :not_registered} = Control.finalize(control)
  end

  test "successful publisher without backend registration fails closed" do
    parent = self()

    assert {:error, {:object_commit_finalize_failed, :not_registered}} =
             ObjectCommit.run(
               [],
               %{},
               [version_id: "null", object_meta: %{}],
               fn commit_opts ->
                 assert is_pid(Keyword.fetch!(commit_opts, :object_commit_control))
                 assert is_binary(Keyword.fetch!(commit_opts, :object_commit_identity))
                 send(parent, :published_without_registration)
                 {:ok, :committed}
               end,
               fn -> send(parent, :discarded_unregistered_staging) end
             )

    assert_receive :published_without_registration
    assert_receive :discarded_unregistered_staging
  end

  defp register_publish!(commit_opts, parent) do
    control = Keyword.fetch!(commit_opts, :object_commit_control)
    identity = Keyword.fetch!(commit_opts, :object_commit_identity)
    assert is_pid(control)
    assert is_binary(identity)

    assert :ok =
             Control.register(
               control,
               identity,
               fn ->
                 send(parent, {:control, :rollback, identity})
                 :ok
               end,
               fn ->
                 send(parent, {:control, :finalize, identity})
                 :ok
               end
             )

    {control, identity}
  end
end
