defmodule Maxio.Cluster.RebalanceRunnerMutationTest do
  @moduledoc """
  ObjectMutation Phase 2A C5 —— `Maxio.Cluster.Rebalance.Runner.copy_object/4`
  （destination copy）迁入 Commit seam 的验收（Distributed 后端 + InProcess transport，
  既有 runner 测试同款 harness；placement 迁移语义 D4）：

    1. 快乐路径：dest 字节 + placement PG 行 + journal(finalized,
       operation="rebalance_copy") + dest epoch(committed) 同一 token；is_latest/
       updated_at 不动（placement 迁移非新 logical value）；源 placement 字节仍在
       （source cleanup 零接触证据）；delete marker 路径行为与现状一致（不迁 seam，
       零 journal 行）；
    2. 事务原子性（§8 rebalance 行「placement 与 journal 同事务」2A 半边落点）：注入
       journal CAS 失败 → placement 行未更新（同事务整体回滚）、journal=rolled_back、
       dest epoch=rolled_back；新 job 重试 = 全新 mutation 收敛（R6）；
    3. update_placement_if_current stale → seam 回滚：旧 placement 不变、dest
       epoch=rolled_back、report 口径与迁移前一致（skipped）；
    4. notification/replication outbox 在 rebalance metadata_tx 中零参与（断言全库
       零 outbox 行）；
    5. :sidecar 写权威（D1 gate）：seam 零参与（无 journal、dest epoch absent）、
       placement 更新值语义与迁移前一致。

  同步纪律：失败全部经 failpoint 注入（锁内 fun 在 spawn_monitor worker 进程执行，
  shared sandbox 下 Repo 可达），零 Process.sleep。
  """

  use Maxio.DataCase, async: false

  alias Maxio.{Buckets, Objects, ObjectMutation, Storage}
  alias Maxio.Cluster.{Placement, Rebalance.Jobs, Rebalance.Runner, Topology}
  alias Maxio.Cluster.Transport.InProcess
  alias Maxio.Failpoint
  alias Maxio.ObjectMutation.Journal
  alias Maxio.Objects.Object
  alias Maxio.S3.NotificationOutbox
  alias Maxio.S3.ReplicationOutbox
  alias Maxio.Storage.Distributed
  alias Maxio.Storage.ObjectEpoch

  @owner "arn:aws:iam:::root"
  @key "rebalance/moved.txt"
  @marker_key "rebalance/deleted.txt"
  @body "rebalance destination copy body"

  setup do
    InProcess.setup!()
    previous_backend = Application.get_env(:maxio, :storage_backend)
    Application.put_env(:maxio, :storage_backend, Distributed)

    base =
      Path.join(
        System.tmp_dir!(),
        "maxio_rebalance_mutation_#{System.unique_integer([:positive])}"
      )

    endpoints0 = for i <- 0..1, do: {Node.self(), Path.join(base, "s0d#{i}")}
    endpoints1 = for i <- 0..1, do: {Node.self(), Path.join(base, "s1d#{i}")}

    topology =
      Topology.parse_and_validate!(
        data_shards: 1,
        parity_shards: 1,
        block_size: 1024,
        allow_colocated_endpoints: true,
        pools: [
          %{id: 0, sets: [%{id: 0, endpoints: endpoints0}, %{id: 1, endpoints: endpoints1}]}
        ]
      )

    on_exit(fn ->
      Application.put_env(:maxio, :storage_backend, previous_backend)
      Failpoint.disarm(:object_mutation_before_metadata_commit)
      Failpoint.disarm(:object_mutation_after_metadata_commit)
      File.rm_rf(base)
    end)

    bucket = "rebmut-#{System.unique_integer([:positive])}"
    {:ok, _bucket} = Buckets.create(bucket, @owner)
    opts = [topology: topology, transport: InProcess]
    :ok = Distributed.put_bucket(bucket, opts)

    %{topology: topology, bucket: bucket, opts: opts}
  end

  # ── 断言 1 + 3 + 4：快乐路径五位一体 + source 零接触 + delete marker 现状 + 零 outbox ──

  test "快乐路径：dest 字节/placement 行/journal/epoch 同一 token；源字节仍在；marker 零 journal", ctx do
    source_opts = Keyword.put(ctx.opts, :placement_set_id, 0)
    destination_opts = Keyword.put(ctx.opts, :placement_set_id, 1)

    {:ok, object} = seed_object(ctx, @key, "v1", @body)
    seed_delete_marker(ctx, @marker_key, "dm1")

    {:ok, job} = Jobs.start_decommission(0, topology: ctx.topology, include_drive_stats: false)

    assert {:ok, report} =
             Runner.run_once(job.id,
               destination_set_id: 1,
               topology: ctx.topology,
               transport: InProcess
             )

    assert report.status == :ok
    assert report.moved == 2
    assert report.errors == 0

    # journal：operation=rebalance_copy、finalized、metadata_committed_at 在案
    journal = journal_for(ctx.bucket, @key)
    assert journal.phase == "finalized"
    assert journal.operation == "rebalance_copy"
    assert journal.authority_mode == "pg"
    assert journal.version_id == "v1"
    assert journal.generation == 1
    assert not is_nil(journal.metadata_committed_at)
    assert not is_nil(journal.finalized_at)

    # placement PG 行：切到 set 1；is_latest/updated_at 不动（placement 迁移非新 logical value）
    assert {:ok, %Object{} = moved} = Objects.get_version(ctx.bucket, @key, "v1")
    assert moved.placement_set_id == 1
    assert moved.is_latest == object.is_latest
    assert moved.updated_at == object.updated_at
    assert moved.etag == object.etag

    # dest 字节 + dest epoch（committed，同一 token/fingerprint；写钉扎端点集）
    assert {:ok, stream} = Distributed.get(ctx.bucket, @key, "v1", nil, destination_opts)
    assert IO.iodata_to_binary(Enum.to_list(stream)) == @body

    assert {:ok, %ObjectEpoch{phase: "committed"} = epoch} =
             Storage.current_epoch(target(ctx.bucket, @key, "v1"), destination_opts)

    assert epoch.token == %{"generation" => journal.generation, "mutation_id" => journal.id}
    assert epoch.fingerprint == journal.published_fingerprint

    # 源 placement 字节仍在（source cleanup 零接触，2C）；源端点 epoch 不参与（absent）
    assert {:ok, source_stream} = Distributed.get(ctx.bucket, @key, "v1", nil, source_opts)
    assert IO.iodata_to_binary(Enum.to_list(source_stream)) == @body
    assert {:ok, :absent} = Storage.current_epoch(target(ctx.bucket, @key, "v1"), source_opts)

    # delete marker 路径行为与现状一致：moved 但零 journal 行（copy_delete_marker 不迁，2B）
    assert {:ok, %Object{placement_set_id: 1}} =
             Objects.get_version(ctx.bucket, @marker_key, "dm1")

    assert journal_count(ctx.bucket, @marker_key) == 0

    # notification/replication outbox 零参与（placement 迁移不挂 outbox）
    assert Repo.aggregate(NotificationOutbox.Event, :count) == 0
    assert Repo.aggregate(ReplicationOutbox.Event, :count) == 0

    assert {:ok, %{status: "complete"}} = Jobs.get(job.id)
  end

  # ── 断言 2：journal CAS 注入失败 → placement 行未更新（同事务原子性）+ 新 job 重试收敛 ──

  test "journal CAS 注入失败：placement 行未更新（同事务回滚）、epoch=rolled_back；重试收敛", ctx do
    source_opts = Keyword.put(ctx.opts, :placement_set_id, 0)
    destination_opts = Keyword.put(ctx.opts, :placement_set_id, 1)

    {:ok, _object} = seed_object(ctx, @key, "v1", @body)

    # publish 之后、metadata 事务之前扰动 journal（attempts+1）→ 事务内 metadata_committed
    # CAS 必然 stale → repo.rollback → placement UPDATE 同事务整体回滚。
    arm_stale_metadata_perturbation(ctx.bucket, @key)

    {:ok, job} = Jobs.start_decommission(0, topology: ctx.topology, include_drive_stats: false)

    assert {:ok, report} =
             Runner.run_once(job.id,
               destination_set_id: 1,
               topology: ctx.topology,
               transport: InProcess
             )

    Failpoint.disarm(:object_mutation_before_metadata_commit)

    assert report.status == :failed
    assert report.errors == 1
    assert {:ok, %{status: "failed"}} = Jobs.get(job.id)

    # 事务原子性（§8 rebalance 行半边落点）：journal 未 metadata_committed ⇒ placement
    # 行未更新——同一事务无半提交
    assert {:ok, %Object{placement_set_id: 0}} = Objects.get_version(ctx.bucket, @key, "v1")

    failed_journal = journal_for(ctx.bucket, @key)
    assert failed_journal.phase == "rolled_back"
    assert failed_journal.operation == "rebalance_copy"

    # dest epoch=rolled_back（fresh dest：epoch 翻转、placement 仍指旧 placement、读不受影响）
    assert {:ok, %ObjectEpoch{phase: "rolled_back"} = epoch} =
             Storage.current_epoch(target(ctx.bucket, @key, "v1"), destination_opts)

    assert epoch.token["mutation_id"] == failed_journal.id

    # 源 placement 字节不受影响
    assert {:ok, source_stream} = Distributed.get(ctx.bucket, @key, "v1", nil, source_opts)
    assert IO.iodata_to_binary(Enum.to_list(source_stream)) == @body

    # 重试（新 job）= 全新 mutation、更高 generation（R6，绝不复用旧 journal 行）
    {:ok, retry_job} =
      Jobs.start_decommission(0, topology: ctx.topology, include_drive_stats: false)

    assert {:ok, retry_report} =
             Runner.run_once(retry_job.id,
               destination_set_id: 1,
               topology: ctx.topology,
               transport: InProcess
             )

    assert retry_report.status == :ok
    assert retry_report.moved == 1

    retried_journal = journal_for(ctx.bucket, @key)
    assert retried_journal.phase == "finalized"
    assert retried_journal.id != failed_journal.id
    assert retried_journal.generation == failed_journal.generation + 1

    assert {:ok, %Object{placement_set_id: 1}} = Objects.get_version(ctx.bucket, @key, "v1")

    assert {:ok, %ObjectEpoch{phase: "committed"}} =
             Storage.current_epoch(target(ctx.bucket, @key, "v1"), destination_opts)
  end

  # ── 断言 2 后半：update_placement_if_current stale → seam 回滚、旧 placement 不变 ──

  test "placement stale：seam 回滚、旧 placement 不变、dest epoch=rolled_back、口径=skipped", ctx do
    destination_opts = Keyword.put(ctx.opts, :placement_set_id, 1)

    {:ok, _object} = seed_object(ctx, @key, "v1", @body)

    # publish 之后、metadata 事务之前扰动 PG 行（placement_topology_hash）→ 条件 UPDATE
    # 守卫不再匹配 → {:error, :stale} → metadata_tx {:placement_stale, :stale} → seam 回滚。
    bucket = ctx.bucket

    Failpoint.arm(
      :object_mutation_before_metadata_commit,
      {:fun,
       fn ->
         {1, _} =
           Repo.update_all(
             from(o in Object,
               where: o.bucket_name == ^bucket and o.key == ^@key and o.version_id == "v1"
             ),
             set: [placement_topology_hash: "c5-perturbed"]
           )
       end}
    )

    {:ok, job} = Jobs.start_decommission(0, topology: ctx.topology, include_drive_stats: false)

    assert {:ok, report} =
             Runner.run_once(job.id,
               destination_set_id: 1,
               topology: ctx.topology,
               transport: InProcess
             )

    Failpoint.disarm(:object_mutation_before_metadata_commit)

    # 迁移前口径一致：stale → skipped（非错误）
    assert report.status == :ok
    assert report.moved == 0
    assert report.skipped == 1

    # 旧 placement 不变（set 0 + 扰动痕迹）、journal 与 dest epoch 双双 rolled_back
    assert {:ok, %Object{placement_set_id: 0, placement_topology_hash: "c5-perturbed"}} =
             Objects.get_version(ctx.bucket, @key, "v1")

    journal = journal_for(ctx.bucket, @key)
    assert journal.phase == "rolled_back"
    assert journal.operation == "rebalance_copy"

    assert {:ok, %ObjectEpoch{phase: "rolled_back"} = epoch} =
             Storage.current_epoch(target(ctx.bucket, @key, "v1"), destination_opts)

    assert epoch.token["mutation_id"] == journal.id
  end

  # ── 断言 5：:sidecar 写权威分支值语义不变（D1 gate 回归）──

  describe ":sidecar 写权威（D1 gate）" do
    setup do
      prev_auth = Application.get_env(:maxio, :authoritative_source)

      Application.put_env(
        :maxio,
        :authoritative_source,
        Keyword.put(prev_auth || [], :write, :sidecar)
      )

      on_exit(fn -> Application.put_env(:maxio, :authoritative_source, prev_auth) end)
      :ok
    end

    test "destination copy seam 零参与、placement 更新值语义不变", ctx do
      destination_opts = Keyword.put(ctx.opts, :placement_set_id, 1)

      {:ok, _object} = seed_object(ctx, @key, "v1", @body)

      {:ok, job} = Jobs.start_decommission(0, topology: ctx.topology, include_drive_stats: false)

      assert {:ok, report} =
               Runner.run_once(job.id,
                 destination_set_id: 1,
                 topology: ctx.topology,
                 transport: InProcess,
                 # runner 只强制 read/list 为 :pg（write 权威不在其门内）
                 authoritative_source: [read: :pg, list: :pg]
               )

      assert report.status == :ok
      assert report.moved == 1

      # placement 已切、dest 字节可读——与迁移前行为一致
      assert {:ok, %Object{placement_set_id: 1}} = Objects.get_version(ctx.bucket, @key, "v1")
      assert {:ok, stream} = Distributed.get(ctx.bucket, @key, "v1", nil, destination_opts)
      assert IO.iodata_to_binary(Enum.to_list(stream)) == @body

      # seam 零参与：无 journal 行、dest epoch absent
      assert journal_count(ctx.bucket, @key) == 0

      assert {:ok, :absent} =
               Storage.current_epoch(target(ctx.bucket, @key, "v1"), destination_opts)
    end
  end

  # ── helpers ──

  defp seed_object(ctx, key, version_id, body) do
    source_opts = Keyword.put(ctx.opts, :placement_set_id, 0)

    {:ok, write_result} =
      Distributed.put(
        ctx.bucket,
        key,
        version_id,
        [body],
        Keyword.put(source_opts, :object_meta, %{content_type: "text/plain"})
      )

    Objects.put_version_with_id(
      ctx.bucket,
      key,
      version_id,
      %{size: byte_size(body), etag: write_result.etag, content_type: "text/plain"}
      |> Map.merge(Placement.attrs_from_result(write_result))
    )
  end

  defp seed_delete_marker(ctx, key, version_id) do
    source_opts = Keyword.put(ctx.opts, :placement_set_id, 0)
    :ok = Distributed.put_delete_marker(ctx.bucket, key, version_id, [], source_opts)
    marker_attrs = Placement.attrs_for_write(ctx.bucket, key, source_opts)

    {:ok, _marker} =
      Objects.insert_delete_marker_with_id(ctx.bucket, key, version_id, marker_attrs)
  end

  # 在 publish 之后、metadata 事务之前扰动目标 journal（attempts+1）：事务 hook 内基于
  # 请求手中旧 journal 行的 CAS 必然 stale_journal → 整个 metadata 事务（含 placement
  # UPDATE）回滚（C2/C3 同源注入手段；fun 在锁 worker 进程执行，shared sandbox 下可达）。
  defp arm_stale_metadata_perturbation(bucket, key) do
    Failpoint.arm(
      :object_mutation_before_metadata_commit,
      {:fun,
       fn ->
         journal =
           Repo.one!(
             from j in Journal,
               where: j.bucket_name == ^bucket and j.object_key == ^key and j.phase == "published"
           )

         {:ok, _} = ObjectMutation.mark_error(journal, :c5_perturb, %{"stage" => "test"})
       end}
    )
  end

  defp journal_for(bucket, key) do
    Repo.one!(
      from j in Journal,
        where: j.bucket_name == ^bucket and j.object_key == ^key,
        order_by: [desc: j.generation],
        limit: 1
    )
  end

  defp journal_count(bucket, key) do
    Repo.aggregate(
      from(j in Journal, where: j.bucket_name == ^bucket and j.object_key == ^key),
      :count
    )
  end

  defp target(bucket, key, version_id) do
    {:ok, target} = ObjectEpoch.object_target(bucket, key, version_id)
    target
  end
end
