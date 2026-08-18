defmodule Maxio.S3.ReplicationDeliveryMutationTest do
  @moduledoc """
  ObjectMutation Phase 2A C5 —— `Maxio.S3.ReplicationDelivery.put_replica_object/3`
  迁入 Commit seam 的验收（FS 后端，真实 Endpoint 驱动 source 写入 + 直接驱动 drain）：

    1. 快乐路径五位一体：dest bytes/sidecar/PG row/journal(finalized,
       operation="replicate", version_id=源版本)/epoch(committed) 同一 token +
       fingerprint；replica sidecar checksum 钉死断言（C3 复审 High 防再漏检模式）：
       sidecar entry checksum 非空且 == 源对象 PG checksum == dest PG row checksum；
       SSE 源字段（algo/envelope）透传 sidecar + 端到端可读；
    2. metadata_tx 注入失败（stale journal CAS）：dest 无残留可见对象（PG 无行、GET 404）、
       journal=rolled_back、epoch=rolled_back、backup 清空、outbox 事件 failed 可重试；
       重试成功 = 新 mutation_id、更高 generation 的全新 claim（R6 幂等断言，绝不复用
       旧 journal 行）——原 L270-276 plain delete 危险点消除的直接证据；
    3. :sidecar 写权威（D1 gate）：seam 零参与（无 journal、epoch absent）、
       put_version_with_id 致命提交值语义与迁移前一致。

  同步纪律：失败全部经 failpoint 注入（锁内 fun 在 spawn_monitor worker 进程执行，
  shared sandbox 下 Repo 可达），零 Process.sleep。
  """

  use Maxio.DataCase, async: false

  alias Maxio.{Objects, ObjectMutation, Storage}
  alias Maxio.Cluster.Paths
  alias Maxio.Failpoint
  alias Maxio.ObjectMutation.Journal
  alias Maxio.S3.{Endpoint, ReplicationDelivery, ReplicationOutbox}
  alias Maxio.Storage.ObjectEpoch
  alias Maxio.Test.SigV4Request

  @key "logs/replica.txt"

  setup do
    data_dir =
      Path.join(System.tmp_dir!(), "maxio_repl_mutation_#{System.unique_integer([:positive])}")

    File.rm_rf(data_dir)
    File.mkdir_p!(data_dir)

    prev_s3 = Application.get_env(:maxio, :s3)
    prev_auth = Application.get_env(:maxio, :authoritative_source)
    Application.put_env(:maxio, :s3, Keyword.put(prev_s3, :data_dir, data_dir))
    Application.put_env(:maxio, :authoritative_source, read: :pg, list: :pg, write: :pg)

    on_exit(fn ->
      Application.put_env(:maxio, :s3, prev_s3)
      restore_env(:authoritative_source, prev_auth)
      Failpoint.disarm(:object_mutation_before_metadata_commit)
      Failpoint.disarm(:object_mutation_after_metadata_commit)
      File.rm_rf(data_dir)
    end)

    suffix = System.unique_integer([:positive])
    source = "repmut-src-#{suffix}"
    dest = "repmut-dst-#{suffix}"

    assert 200 == call(SigV4Request.signed_conn(:put, "/#{source}")).status
    assert 200 == call(SigV4Request.signed_conn(:put, "/#{dest}")).status
    assert 200 == enable_versioning(source).status
    assert 200 == enable_versioning(dest).status
    assert 200 == put_replication(source, dest).status

    %{data_dir: data_dir, source: source, dest: dest}
  end

  # ── 断言 1：快乐路径五位一体（operation="replicate"，version_id=源版本）──

  test "快乐路径：replica 五位一体 + sidecar checksum 钉死断言", ctx do
    body = "replicate me durably"
    version_id = put_source_object(ctx.source, @key, body)

    assert {:ok, %{claimed: 1, completed: 1, failed: 0}} = ReplicationDelivery.drain(limit: 10)

    # journal：operation=replicate、version_id=源版本（外部确定直接入 plan）
    journal = journal_for(ctx.dest, @key)
    assert journal.phase == "finalized"
    assert journal.operation == "replicate"
    assert journal.authority_mode == "pg"
    assert journal.version_id == version_id
    assert journal.generation == 1
    assert not is_nil(journal.metadata_committed_at)
    assert not is_nil(journal.finalized_at)

    # dest bytes
    final = final_dir(ctx, ctx.dest, @key, version_id)
    assert File.read!(Path.join(final, "part.0")) == body

    # sidecar：journal published_fingerprint 与 dest meta.json 实际字节精确匹配
    fingerprint = journal.published_fingerprint
    assert fingerprint["etag"] == md5_hex(body)
    assert fingerprint["size"] == byte_size(body)
    assert fingerprint["sidecar_sha256"] == sha256_hex(File.read!(Path.join(final, "meta.json")))

    # replica sidecar 元数据保真（C3 复审 High 防再漏检模式）：around 接管 commit_opts 后
    # object_meta 必须显式传 publish——replica sidecar checksum 非空（对空 map 必失败）、
    # 与源对象 PG checksum 一致（fingerprint 只哈希 meta.json 本身，检不出内容退化）
    {:ok, %Objects.Object{checksum: source_checksum}} =
      Objects.get_version(ctx.source, @key, version_id)

    entry = sidecar_entry(final)
    assert %{"ChecksumCRC64NVME" => _, "ChecksumType" => "FULL_OBJECT"} = entry["checksum"]
    assert entry["checksum"] == source_checksum

    # epoch：committed + 同一 token + 同一 fingerprint
    assert {:ok, %ObjectEpoch{phase: "committed"} = epoch} =
             Storage.current_epoch(target(ctx.dest, @key, version_id))

    assert epoch.token == %{"generation" => journal.generation, "mutation_id" => journal.id}
    assert epoch.fingerprint == fingerprint

    # PG row：REPLICA + checksum 与 sidecar 同值（PG↔sidecar 一致的直接断言）
    assert {:ok, %Objects.Object{} = row} = Objects.get_version(ctx.dest, @key, version_id)
    assert row.replication_status == "REPLICA"
    assert row.etag == md5_hex(body)
    assert row.checksum == entry["checksum"]

    # 端到端可读 + finalize 已丢弃 durable backup
    replica = call(SigV4Request.signed_conn(:get, "/#{ctx.dest}/#{@key}"))
    assert replica.status == 200
    assert replica.resp_body == body
    assert mutation_dirs(ctx) == []
  end

  test "SSE 源字段透传：AES256 envelope 进 replica sidecar、端到端可读", ctx do
    plain = "encrypted source replicated as ciphertext"

    put =
      call(
        SigV4Request.signed_conn(:put, "/#{ctx.source}/#{@key}",
          body: plain,
          headers: [{"x-amz-server-side-encryption", "AES256"}]
        )
      )

    assert put.status == 200
    [version_id] = Plug.Conn.get_resp_header(put, "x-amz-version-id")

    assert {:ok, %{claimed: 1, completed: 1, failed: 0}} = ReplicationDelivery.drain(limit: 10)

    journal = journal_for(ctx.dest, @key)
    assert journal.phase == "finalized"
    assert journal.operation == "replicate"

    # dest 存储字节是源密文（Storage.get 透传密文），sse algo/envelope 经
    # committed_object_meta 进 replica sidecar（源字段透传钉死断言）
    final = final_dir(ctx, ctx.dest, @key, version_id)
    stored = File.read!(Path.join(final, "part.0"))
    refute stored =~ plain

    entry = sidecar_entry(final)
    assert %{"algo" => "AES256", "envelope" => envelope} = entry["sse"]
    assert is_map(envelope) and map_size(envelope) > 0

    assert {:ok, %Objects.Object{sse_algorithm: "AES256"}} =
             Objects.get_version(ctx.dest, @key, version_id)

    replica = call(SigV4Request.signed_conn(:get, "/#{ctx.dest}/#{@key}"))
    assert replica.status == 200
    assert replica.resp_body == plain
    assert mutation_dirs(ctx) == []
  end

  # ── 断言 2：metadata 注入失败 → dest 无残留可见对象 + outbox 可重试且重试成功 ──

  test "metadata 注入失败：dest 不可见、journal=rolled_back、outbox 重试成功（R6 幂等）", ctx do
    body = "replica payload survives retry"
    version_id = put_source_object(ctx.source, @key, body)

    # publish 之后、metadata 事务之前扰动 dest journal（attempts+1）→ 事务内
    # metadata_committed CAS 必然 stale → Repo.rollback → metadata_tx {:error, _}。
    arm_stale_metadata_perturbation(ctx.dest, @key)

    assert {:ok, %{claimed: 1, completed: 0, failed: 1}} =
             ReplicationDelivery.drain(limit: 10, failure_backoff_ms: 0)

    Failpoint.disarm(:object_mutation_before_metadata_commit)

    # dest 无残留可见对象：PG 无行、端到端 404（fresh 版本化 replica 的 rollback——
    # 已发布字节 API 不可见，plain delete 危险点消除的直接证据）
    assert {:error, :not_found} = Objects.get_version(ctx.dest, @key, version_id)
    assert 404 == call(SigV4Request.signed_conn(:get, "/#{ctx.dest}/#{@key}")).status

    # journal 与 epoch 双双 rolled_back、backup 清空（fresh manifest entries=[]）
    failed_journal = journal_for(ctx.dest, @key)
    assert failed_journal.phase == "rolled_back"
    assert failed_journal.operation == "replicate"

    assert {:ok, %ObjectEpoch{phase: "rolled_back"} = epoch} =
             Storage.current_epoch(target(ctx.dest, @key, version_id))

    assert epoch.token["mutation_id"] == failed_journal.id
    assert mutation_dirs(ctx) == []

    # outbox 事件可重试（at-least-once：failed + attempts=1 + 错误取证在案）
    assert [%{status: "failed", attempts: 1, source_version_id: ^version_id}] =
             ReplicationOutbox.list(status: "failed")

    # 重试成功：全新 mutation（新 mutation_id、更高 generation，R6 绝不复用旧 journal 行）
    assert {:ok, %{claimed: 1, completed: 1, failed: 0}} =
             ReplicationDelivery.drain(limit: 10, failure_backoff_ms: 0)

    retried_journal = journal_for(ctx.dest, @key)
    assert retried_journal.phase == "finalized"
    assert retried_journal.id != failed_journal.id
    assert retried_journal.generation == failed_journal.generation + 1

    # 重试后的终态：dest 可见可读、epoch committed 指向新 mutation、backup 清空
    assert {:ok, %Objects.Object{replication_status: "REPLICA"}} =
             Objects.get_version(ctx.dest, @key, version_id)

    replica = call(SigV4Request.signed_conn(:get, "/#{ctx.dest}/#{@key}"))
    assert replica.status == 200
    assert replica.resp_body == body

    assert {:ok, %ObjectEpoch{phase: "committed"} = committed_epoch} =
             Storage.current_epoch(target(ctx.dest, @key, version_id))

    assert committed_epoch.token == %{
             "generation" => retried_journal.generation,
             "mutation_id" => retried_journal.id
           }

    assert [%{status: "completed"}] = ReplicationOutbox.list(status: "completed")
    assert mutation_dirs(ctx) == []
  end

  # ── 断言 3：:sidecar 写权威分支值语义不变（D1 gate 回归）──

  describe ":sidecar 写权威（D1 gate）" do
    test "replica 投递 seam 零参与、put_version_with_id 致命提交值语义不变", ctx do
      body = "sidecar authority replica"
      version_id = put_source_object(ctx.source, @key, body)

      prev_auth = Application.get_env(:maxio, :authoritative_source)

      Application.put_env(
        :maxio,
        :authoritative_source,
        Keyword.put(prev_auth || [], :write, :sidecar)
      )

      on_exit(fn -> Application.put_env(:maxio, :authoritative_source, prev_auth) end)

      assert {:ok, %{claimed: 1, completed: 1, failed: 0}} = ReplicationDelivery.drain(limit: 10)

      # bytes + sidecar 已权威落盘；PG 行仍为致命提交（迁移前值语义）
      final = final_dir(ctx, ctx.dest, @key, version_id)
      assert File.read!(Path.join(final, "part.0")) == body

      # sidecar 权威下 replica sidecar 即权威元数据：checksum 透传同样钉死
      entry = sidecar_entry(final)
      assert %{"ChecksumCRC64NVME" => _} = entry["checksum"]

      assert {:ok, %Objects.Object{replication_status: "REPLICA"}} =
               Objects.get_version(ctx.dest, @key, version_id)

      # seam 零参与：dest 无 journal 行、无 epoch、无 durable backup
      assert journal_count(ctx.dest, @key) == 0
      assert {:ok, :absent} = Storage.current_epoch(target(ctx.dest, @key, version_id))
      assert mutation_dirs(ctx) == []
    end
  end

  # ── helpers ──

  defp call(conn), do: Endpoint.call(conn, Endpoint.init([]))

  defp enable_versioning(bucket) do
    call(
      SigV4Request.signed_conn(:put, "/#{bucket}",
        query: %{"versioning" => ""},
        body: "<VersioningConfiguration><Status>Enabled</Status></VersioningConfiguration>"
      )
    )
  end

  defp put_replication(source, dest) do
    body = """
    <ReplicationConfiguration xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
      <Role>arn:aws:iam::000000000000:role/replication</Role>
      <Rule>
        <ID>logs</ID>
        <Priority>10</Priority>
        <Filter><Prefix>logs/</Prefix></Filter>
        <Status>Enabled</Status>
        <DeleteMarkerReplication><Status>Disabled</Status></DeleteMarkerReplication>
        <Destination><Bucket>arn:aws:s3:::#{dest}</Bucket></Destination>
      </Rule>
    </ReplicationConfiguration>
    """

    call(
      SigV4Request.signed_conn(:put, "/#{source}",
        query: %{"replication" => ""},
        body: body,
        headers: [{"content-md5", :crypto.hash(:md5, body) |> Base.encode64()}]
      )
    )
  end

  defp put_source_object(bucket, key, body) do
    put = call(SigV4Request.signed_conn(:put, "/#{bucket}/#{key}", body: body))
    assert put.status == 200
    [version_id] = Plug.Conn.get_resp_header(put, "x-amz-version-id")
    version_id
  end

  # 在 publish 之后、metadata 事务之前扰动目标 journal（attempts+1）：事务 hook 内基于
  # 请求手中旧 journal 行的 CAS 必然 stale_journal → 整个 metadata 事务回滚
  # （C2/C3 同源注入手段；fun 在锁 worker 进程执行，shared sandbox 下 Repo 可达）。
  #
  # 必须用**保留取证的** operational CAS probe `mark_operational_error/3`（design D6 §3.3）：
  # 它只更新 attempts / next_attempt_at / bounded last_error / updated_at，逐字保留 PG
  # published 行上已持久化的 `published_fingerprint` 与 canonical successful PublishedProof
  # wrapper，随后 `request_rollback/3` 的 published-origin 证据校验才有合法 durable evidence。
  # legacy `mark_error/4` 会**替换** recovery_evidence 并被 `{:error, :invalid_rollback_evidence}`
  # 合法拒绝。reason 必须是稳定 binary（非 binary 一律 {:error, :invalid_operational_reason}）。
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

         {:ok, _} = ObjectMutation.mark_operational_error(journal, "c5_perturb")
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

  defp final_dir(ctx, bucket, key, version_id) do
    {:ok, rel} = Paths.object_rel(bucket, key, version_id)
    Path.join(ctx.data_dir, rel)
  end

  # dest final meta.json 的唯一 versions entry（maxio/2 sidecar；replica 单版本）。
  defp sidecar_entry(final) do
    meta = Jason.decode!(File.read!(Path.join(final, "meta.json")))
    [entry] = meta["versions"]
    entry
  end

  # durable mutation backup 根下的残留目录（不存在视为空；File.ls 判空，B2 审查项 1）。
  defp mutation_dirs(ctx) do
    case File.ls(Path.join(ctx.data_dir, ".maxio-object-mutations")) do
      {:ok, entries} -> entries
      {:error, :enoent} -> []
    end
  end

  defp md5_hex(content), do: :crypto.hash(:md5, content) |> Base.encode16(case: :lower)
  defp sha256_hex(content), do: :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)

  defp restore_env(key, nil), do: Application.delete_env(:maxio, key)
  defp restore_env(key, value), do: Application.put_env(:maxio, key, value)
end
