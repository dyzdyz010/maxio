defmodule Maxio.S3.CopyObjectMutationTest do
  @moduledoc """
  ObjectMutation Phase 2A C3 —— CopyObject 迁入 Commit seam 的验收（FS 后端，真实
  Endpoint 驱动）。协议 §1 点名危险点「先覆盖、metadata 失败后 plain delete 丢
  unversioned 目标旧对象」消除的直接证据（§8 Copy 行落点）：

    1. 快乐路径五位一体：bytes/sidecar/PG row/journal(finalized, operation="copy")/
       epoch(committed) 同一 token + fingerprint；SSE 重加密 copy（AES256 源 → SSE-C
       目标）同断言；
    2. unversioned 目标已有旧对象 + copy 覆盖 + metadata_tx 注入失败（stale journal CAS）：
       旧 bytes/sidecar 逐字节恢复、PG 不变、journal=rolled_back、backup 清空、响应
       503 SlowDownWrite——协议 §1 原文场景直接测试；
    3. PG commit 后 kill（failpoint `:object_mutation_after_metadata_commit`）→ recovery
       drain → journal=finalized、新（拷贝）对象保留；
    4. successor 代表断言（硬性不变量 3 的 caller 级证据）：copy published 后 failpoint
       停住 → 后继协议化 put 完整走完 → 旧 copy mutation 的 restore → :superseded
       （journal=rolled_back + superseded 证据、backup 原地保留），successor
       bytes/epoch/PG 三态不变；
    5. 自拷贝路径回归（tmp_key staging 裸写不迁 seam、字节不丢）；条件 copy
       （precondition 失败）不产生 journal 行；
    6. :sidecar 写权威（D1 gate）：seam 零参与、行为与迁移前逐字节一致。

  同步纪律：崩溃/失败全部经 failpoint 注入 + 消息收发同步，收敛用 10ms receive 条件
  轮询，零 Process.sleep。
  """

  use Maxio.DataCase, async: false

  alias Maxio.{Objects, ObjectMutation, Storage}
  alias Maxio.Cluster.Paths
  alias Maxio.Cluster.Placement
  alias Maxio.Failpoint
  alias Maxio.ObjectMutation.Commit, as: ObjectMutationCommit
  alias Maxio.ObjectMutation.Journal
  alias Maxio.ObjectMutation.Recovery
  alias Maxio.S3.Endpoint
  alias Maxio.Storage.{MutationBackup, ObjectEpoch}
  alias Maxio.Test.SigV4Request

  @src_key "src.txt"
  @dst_key "dst.txt"

  setup do
    data_dir =
      Path.join(System.tmp_dir!(), "maxio_copy_mutation_#{System.unique_integer([:positive])}")

    File.rm_rf(data_dir)
    File.mkdir_p!(data_dir)

    prev_s3 = Application.get_env(:maxio, :s3)
    Application.put_env(:maxio, :s3, Keyword.put(prev_s3, :data_dir, data_dir))

    on_exit(fn ->
      Application.put_env(:maxio, :s3, prev_s3)
      Failpoint.disarm(:object_mutation_before_metadata_commit)
      Failpoint.disarm(:object_mutation_after_metadata_commit)
      File.rm_rf(data_dir)
    end)

    bucket = "cpmut-#{System.unique_integer([:positive])}"
    assert 200 == call(SigV4Request.signed_conn(:put, "/#{bucket}")).status

    %{data_dir: data_dir, bucket: bucket}
  end

  # ── 断言 1：快乐路径五位一体（operation="copy"）──

  test "快乐路径：copy 五位一体（journal operation=copy）", ctx do
    src_body = "copy source content v1"
    assert 200 == put_object(ctx.bucket, @src_key, src_body).status

    copy = copy_object(ctx.bucket, @dst_key, "/#{ctx.bucket}/#{@src_key}")
    assert copy.status == 200
    assert copy.resp_body =~ "<ETag>"

    journal = journal_for(ctx.bucket, @dst_key)
    assert journal.phase == "finalized"
    assert journal.operation == "copy"
    assert journal.authority_mode == "pg"
    assert journal.generation == 1
    assert not is_nil(journal.metadata_committed_at)
    assert not is_nil(journal.finalized_at)

    # bytes（明文 copy：目标存储字节 == 源明文）
    final = final_dir(ctx, @dst_key)
    assert File.read!(Path.join(final, "part.0")) == src_body

    # sidecar：journal published_fingerprint 与 final meta.json 实际字节精确匹配
    fingerprint = journal.published_fingerprint
    assert fingerprint["etag"] == md5_hex(src_body)
    assert fingerprint["size"] == byte_size(src_body)
    assert fingerprint["sidecar_sha256"] == sha256_hex(File.read!(Path.join(final, "meta.json")))

    # sidecar 元数据保真（C3 复审收口）：around 接管 commit_opts 后必须显式 merge
    # before_copy_object_commit extra 的 object_meta（committed_object_meta），拷贝
    # 对象 sidecar checksum 非空、与源对象一致（同字节同默认 CRC64NVME）——钉死
    # PG↔sidecar 不分裂（fingerprint 只哈希 meta.json 本身，检不出内容退化）
    dst_entry = sidecar_entry(ctx, @dst_key)
    assert %{"ChecksumCRC64NVME" => _, "ChecksumType" => "FULL_OBJECT"} = dst_entry["checksum"]
    assert dst_entry["checksum"] == sidecar_entry(ctx, @src_key)["checksum"]

    # epoch：committed + 同一 token + 同一 fingerprint
    assert {:ok, %ObjectEpoch{phase: "committed"} = epoch} =
             Storage.current_epoch(target(ctx.bucket, @dst_key))

    assert epoch.token == %{"generation" => journal.generation, "mutation_id" => journal.id}
    assert epoch.fingerprint == fingerprint

    # PG row（checksum 与 sidecar 同值——PG↔sidecar 一致的直接断言）
    assert {:ok, %Objects.Object{} = row} = Objects.get_metadata(ctx.bucket, @dst_key)
    assert row.etag == md5_hex(src_body)
    assert row.size == byte_size(src_body)
    assert row.checksum == dst_entry["checksum"]

    # finalize 已丢弃 durable backup
    assert mutation_dirs(ctx) == []
  end

  test "SSE 重加密 copy：AES256 源 → SSE-C 目标，五位一体（operation=copy）", ctx do
    plain = "re-encrypt me across sse modes"
    customer_key = :crypto.strong_rand_bytes(32)

    put =
      put_object(ctx.bucket, @src_key, plain, [{"x-amz-server-side-encryption", "AES256"}])

    assert put.status == 200
    refute File.read!(Path.join(final_dir(ctx, @src_key), "part.0")) =~ plain

    copy =
      copy_object(ctx.bucket, @dst_key, "/#{ctx.bucket}/#{@src_key}", sse_c_headers(customer_key))

    assert copy.status == 200

    journal = journal_for(ctx.bucket, @dst_key)
    assert journal.phase == "finalized"
    assert journal.operation == "copy"

    # 目标存储字节是 SSE-C 密文（重加密），fingerprint 对齐实际存储字节
    final = final_dir(ctx, @dst_key)
    stored = File.read!(Path.join(final, "part.0"))
    refute stored =~ plain

    fingerprint = journal.published_fingerprint
    assert fingerprint["etag"] == md5_hex(stored)
    assert fingerprint["sidecar_sha256"] == sha256_hex(File.read!(Path.join(final, "meta.json")))

    # sidecar 元数据保真：SSE-C 目标的 stored checksum（明文 CRC64NVME 透传）同样必须
    # 经 committed_object_meta 写进 sidecar，非空且与 PG 行一致
    dst_checksum = sidecar_entry(ctx, @dst_key)["checksum"]
    assert %{"ChecksumCRC64NVME" => _, "ChecksumType" => "FULL_OBJECT"} = dst_checksum

    assert {:ok, %ObjectEpoch{phase: "committed"} = epoch} =
             Storage.current_epoch(target(ctx.bucket, @dst_key))

    assert epoch.token == %{"generation" => journal.generation, "mutation_id" => journal.id}
    assert epoch.fingerprint == fingerprint

    # PG row（SSE-C 元数据）+ 带 SSE-C 头 GET 解密回明文（端到端可读）
    assert {:ok, %Objects.Object{sse_algorithm: "SSE-C"}} =
             Objects.get_metadata(ctx.bucket, @dst_key)

    get =
      call(
        SigV4Request.signed_conn(:get, "/#{ctx.bucket}/#{@dst_key}",
          headers: sse_c_headers(customer_key)
        )
      )

    assert get.status == 200
    assert get.resp_body == plain

    assert mutation_dirs(ctx) == []
  end

  # ── 断言 2：协议 §1 原文场景（unversioned 覆盖 + metadata 失败 → 旧对象恢复）──

  test "unversioned 目标已有旧对象 + copy 覆盖 + metadata 注入失败：旧对象逐字节恢复", ctx do
    old_body = "old destination body must survive"
    assert 200 == put_object(ctx.bucket, @dst_key, old_body).status
    assert 200 == put_object(ctx.bucket, @src_key, "new source body must not commit").status

    final = final_dir(ctx, @dst_key)
    old_bytes = File.read!(Path.join(final, "part.0"))
    old_sidecar = File.read!(Path.join(final, "meta.json"))
    assert {:ok, %Objects.Object{etag: old_etag}} = Objects.get_metadata(ctx.bucket, @dst_key)

    # publish 之后、metadata 事务之前扰动 journal（attempts+1）→ 事务内 metadata_committed
    # CAS 必然 stale → Repo.rollback → metadata_tx 返回 {:error, _}（真实 metadata_tx 失败）。
    arm_stale_metadata_perturbation(ctx.bucket, @dst_key)

    copy = copy_object(ctx.bucket, @dst_key, "/#{ctx.bucket}/#{@src_key}")
    Failpoint.disarm(:object_mutation_before_metadata_commit)

    # seam 错误映射与 do_put 同源：journal CAS 争用 → 503 SlowDownWrite（瞬时条件可重试）
    assert copy.status == 503
    assert copy.resp_body =~ "<Code>SlowDownWrite</Code>"

    # 旧 bytes/sidecar 逐字节恢复、PG 行原样——plain delete 危险点消除的直接证据
    assert File.read!(Path.join(final, "part.0")) == old_bytes
    assert File.read!(Path.join(final, "meta.json")) == old_sidecar
    assert {:ok, %Objects.Object{etag: ^old_etag}} = Objects.get_metadata(ctx.bucket, @dst_key)

    # journal 与 epoch 双双 rolled_back（gen 2 的失败 copy mutation）、backup 清空
    journal = journal_for(ctx.bucket, @dst_key)
    assert journal.phase == "rolled_back"
    assert journal.operation == "copy"
    assert journal.generation == 2

    assert {:ok, %ObjectEpoch{phase: "rolled_back"} = epoch} =
             Storage.current_epoch(target(ctx.bucket, @dst_key))

    assert epoch.token["mutation_id"] == journal.id
    assert mutation_dirs(ctx) == []
  end

  # ── 断言 3：metadata_committed 后 kill → recovery finalize、新对象保留 ──

  test "PG commit 后 kill：recovery drain 收敛 finalized、拷贝对象保留", ctx do
    old_body = "old destination before crash"
    src_body = "copied body survives pg-commit crash"
    assert 200 == put_object(ctx.bucket, @dst_key, old_body).status
    assert 200 == put_object(ctx.bucket, @src_key, src_body).status

    Failpoint.arm(:object_mutation_after_metadata_commit, {:raise, "crash after pg commit"})

    # 异常经 dispatch 兜底 500（InternalError）；metadata_committed 是回滚禁止线——
    # 字节保留、journal 停在 metadata_committed，终局收敛交 recovery。
    copy = copy_object(ctx.bucket, @dst_key, "/#{ctx.bucket}/#{@src_key}")
    Failpoint.disarm(:object_mutation_after_metadata_commit)
    assert copy.status == 500

    journal = journal_for(ctx.bucket, @dst_key)
    assert journal.phase == "metadata_committed"
    assert journal.operation == "copy"
    assert journal.generation == 2

    final = final_dir(ctx, @dst_key)
    assert File.read!(Path.join(final, "part.0")) == src_body
    assert {:ok, %Objects.Object{etag: etag}} = Objects.get_metadata(ctx.bucket, @dst_key)
    assert etag == md5_hex(src_body)
    refute mutation_dirs(ctx) == []

    # recovery 收敛（prepare 宽限 60s → now 注入越过）
    assert_eventually(fn ->
      _ = Recovery.drain(now: future(300))
      ObjectMutation.get(journal.id).phase == "finalized"
    end)

    assert File.read!(Path.join(final, "part.0")) == src_body

    assert {:ok, %ObjectEpoch{phase: "committed"} = epoch} =
             Storage.current_epoch(target(ctx.bucket, @dst_key))

    assert epoch.token == %{"generation" => journal.generation, "mutation_id" => journal.id}
    assert {:ok, %Objects.Object{etag: ^etag}} = Objects.get_metadata(ctx.bucket, @dst_key)
    assert mutation_dirs(ctx) == []
  end

  # ── 断言 4：successor fence（硬性不变量 3 的 caller 级证据）──

  test "successor：copy published 停住 → 协议化 put 走完 → copy restore :superseded", ctx do
    src_body = "copy content that must lose the race"
    assert 200 == put_object(ctx.bucket, @src_key, src_body).status

    parent = self()

    # 暂停型 failpoint：copy 在 publish 之后、metadata 事务之前向测试进程报到并阻塞。
    Failpoint.arm(
      :object_mutation_before_metadata_commit,
      {:fun,
       fn ->
         send(parent, {:paused, self()})

         receive do
           :resume -> :ok
         end
       end}
    )

    {:ok, _owner} =
      Task.start(fn ->
        resp = copy_object(ctx.bucket, @dst_key, "/#{ctx.bucket}/#{@src_key}")
        send(parent, {:copy_response, resp})
      end)

    assert_receive {:paused, copy_pid}, 5_000
    on_exit(fn -> send(copy_pid, :resume) end)
    Failpoint.disarm(:object_mutation_before_metadata_commit)

    copy_journal = journal_for(ctx.bucket, @dst_key)
    assert copy_journal.phase == "published"
    assert copy_journal.operation == "copy"

    # 后继协议化 put 完整走完（直接驱动 Storage.put + Commit.run，recovery_test successor
    # 模式同源——copy 仍持对象锁，fence 正确性由 durable token 而非锁保证）。
    successor_body = "successor protocol put content"
    assert {:ok, %{journal: b_journal}} = protocol_put(ctx.bucket, @dst_key, successor_body)
    b_journal = ObjectMutation.get(b_journal.id)
    assert b_journal.phase == "finalized"
    assert b_journal.generation == copy_journal.generation + 1

    # successor 三态基线
    final = final_dir(ctx, @dst_key)
    assert File.read!(Path.join(final, "part.0")) == successor_body

    assert {:ok, %ObjectEpoch{phase: "committed"} = b_epoch} =
             Storage.current_epoch(target(ctx.bucket, @dst_key))

    assert b_epoch.token["mutation_id"] == b_journal.id
    assert {:ok, %Objects.Object{etag: b_etag}} = Objects.get_metadata(ctx.bucket, @dst_key)
    assert b_etag == md5_hex(successor_body)

    # 扰动 copy journal（attempts+1）→ 恢复执行：metadata CAS 必然 stale → 失败路径
    # attempt_restore → restore_if_current 遇 successor token → :superseded（绝不触碰 B）。
    #
    # 保留取证的 operational CAS probe：只增加 attempts 等运维字段，逐字保留 published
    # fingerprint 与 canonical wrapper，下面的 rolled_back + restore=superseded 证据断言
    # 才成立（legacy `mark_error/4` 会替换 recovery_evidence 并使 rollback 被合法拒绝）。
    {:ok, _} =
      ObjectMutation.mark_operational_error(ObjectMutation.get(copy_journal.id), "c3_perturb")

    send(copy_pid, :resume)

    assert_receive {:copy_response, copy_resp}, 10_000
    assert copy_resp.status == 503
    assert copy_resp.resp_body =~ "<Code>SlowDownWrite</Code>"

    # copy journal：rolled_back + restore=superseded 证据、backup 原地保留可取证
    a_after = ObjectMutation.get(copy_journal.id)
    assert a_after.phase == "rolled_back"
    assert a_after.recovery_evidence["restore"] == "superseded"
    assert a_after.recovery_evidence["backup_dir"] == MutationBackup.relative_dir(copy_journal.id)

    a_backup = Path.join(ctx.data_dir, MutationBackup.relative_dir(copy_journal.id))
    assert File.regular?(Path.join(a_backup, MutationBackup.manifest_name()))

    # successor bytes/epoch/PG 三态不变
    assert File.read!(Path.join(final, "part.0")) == successor_body
    assert {:ok, ^b_epoch} = Storage.current_epoch(target(ctx.bucket, @dst_key))
    assert {:ok, %Objects.Object{etag: ^b_etag}} = Objects.get_metadata(ctx.bucket, @dst_key)
  end

  # ── 断言 5：自拷贝回归 + 条件 copy 不产生 journal 行 ──

  test "自拷贝（REPLACE）：tmp_key staging 不迁 seam、字节不丢、journal 仅 dest 的 copy", ctx do
    body = "self copy keeps bytes intact"
    key = "self.txt"
    assert 200 == put_object(ctx.bucket, key, body).status

    copy =
      call(
        SigV4Request.signed_conn(:put, "/#{ctx.bucket}/#{key}",
          headers: [
            {"x-amz-copy-source", "/#{ctx.bucket}/#{key}"},
            {"x-amz-metadata-directive", "REPLACE"},
            {"content-type", "application/octet-stream"}
          ]
        )
      )

    assert copy.status == 200

    get = call(SigV4Request.signed_conn(:get, "/#{ctx.bucket}/#{key}"))
    assert get.status == 200
    assert get.resp_body == body

    # journal 只属于 S3 可见对象 key（put + copy 两条）；自拷贝临时 key（internal
    # staging 裸写）绝不产生 journal 行
    journals =
      Repo.all(from j in Journal, where: j.bucket_name == ^ctx.bucket, order_by: j.generation)

    assert Enum.map(journals, & &1.object_key) |> Enum.uniq() == [key]
    assert Enum.map(journals, & &1.operation) == ["put", "copy"]
    assert Enum.all?(journals, &(&1.phase == "finalized"))

    # 自拷贝临时副本已清理：桶目录无 .maxio-copytmp- 残留
    entries = File.ls!(Path.join(ctx.data_dir, ctx.bucket))
    refute Enum.any?(entries, &String.contains?(&1, ".maxio-copytmp-"))
    assert mutation_dirs(ctx) == []
  end

  test "条件 copy precondition 失败：412、不产生 journal 行", ctx do
    assert 200 == put_object(ctx.bucket, @dst_key, "existing destination").status
    assert 200 == put_object(ctx.bucket, @src_key, "source body").status
    baseline = journal_count(ctx.bucket, @dst_key)

    # 目标写条件（if-none-match: * 但目标已存在）→ 412，先于任何字节 staging
    conditional =
      copy_object(ctx.bucket, @dst_key, "/#{ctx.bucket}/#{@src_key}", [{"if-none-match", "*"}])

    assert conditional.status == 412

    # 源条件（x-amz-copy-source-if-match 不匹配）→ 412，先于读源字节
    source_conditional =
      copy_object(ctx.bucket, @dst_key, "/#{ctx.bucket}/#{@src_key}", [
        {"x-amz-copy-source-if-match", "\"00000000000000000000000000000000\""}
      ])

    assert source_conditional.status == 412

    # journal 零新增（copy 的 journal 仅在锁内 staging 完成后经 Commit.run 创建）
    assert journal_count(ctx.bucket, @dst_key) == baseline
    assert File.read!(Path.join(final_dir(ctx, @dst_key), "part.0")) == "existing destination"
  end

  # ── 断言 6：:sidecar 写权威分支逐字节不变（D1 gate 回归）──

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

    test "copy：publish 即权威提交、PG index best-effort、seam 零参与", ctx do
      src_body = "sidecar authority copy source"
      assert 200 == put_object(ctx.bucket, @src_key, src_body).status

      copy = copy_object(ctx.bucket, @dst_key, "/#{ctx.bucket}/#{@src_key}")
      assert copy.status == 200
      assert copy.resp_body =~ md5_hex(src_body)

      # bytes + sidecar 已权威落盘；PG best-effort 索引已写（默认 FS 后端成功路径）
      final = final_dir(ctx, @dst_key)
      assert File.read!(Path.join(final, "part.0")) == src_body
      assert File.regular?(Path.join(final, "meta.json"))

      # :sidecar 写权威下 sidecar 即权威元数据：stored checksum 必须经
      # committed_object_meta 写进 sidecar（迁移前 default_object_commit_opts 的
      # merge 行为逐字节保持），非空且与源一致
      dst_entry = sidecar_entry(ctx, @dst_key)
      assert %{"ChecksumCRC64NVME" => _, "ChecksumType" => "FULL_OBJECT"} = dst_entry["checksum"]
      assert dst_entry["checksum"] == sidecar_entry(ctx, @src_key)["checksum"]
      assert {:ok, %Objects.Object{etag: etag}} = Objects.get_metadata(ctx.bucket, @dst_key)
      assert etag == md5_hex(src_body)

      get = call(SigV4Request.signed_conn(:get, "/#{ctx.bucket}/#{@dst_key}"))
      assert get.status == 200
      assert get.resp_body == src_body

      # seam 零参与：无 journal 行、无 epoch、无 durable backup（非协议路径逐字节不变）
      assert journal_count(ctx.bucket, @dst_key) == 0
      assert journal_count(ctx.bucket, @src_key) == 0
      assert {:ok, :absent} = Storage.current_epoch(target(ctx.bucket, @dst_key))
      assert mutation_dirs(ctx) == []
    end
  end

  # ── helpers ──

  defp call(conn), do: Endpoint.call(conn, Endpoint.init([]))

  defp put_object(bucket, key, body, headers \\ []) do
    call(SigV4Request.signed_conn(:put, "/#{bucket}/#{key}", body: body, headers: headers))
  end

  defp copy_object(bucket, dest_key, copy_source, headers \\ []) do
    call(
      SigV4Request.signed_conn(:put, "/#{bucket}/#{dest_key}",
        headers: [{"x-amz-copy-source", copy_source} | headers]
      )
    )
  end

  defp sse_c_headers(customer_key) do
    [
      {"x-amz-server-side-encryption-customer-algorithm", "AES256"},
      {"x-amz-server-side-encryption-customer-key", Base.encode64(customer_key)},
      {"x-amz-server-side-encryption-customer-key-md5",
       :crypto.hash(:md5, customer_key) |> Base.encode64()}
    ]
  end

  # 后继协议化 put：直接驱动 Storage.put + Commit.run（recovery_test successor 同源；
  # 不取对象锁——fence 正确性由 durable token 保证，锁只是请求编排关注点）。
  defp protocol_put(bucket, key, content) do
    Storage.put(bucket, key, "null", [content],
      around_object_commit: fn write_info, publish ->
        ObjectMutationCommit.run(%{
          bucket: bucket,
          key: key,
          version_id: "null",
          operation: "put",
          authority_mode: "pg",
          storage_opts: Placement.storage_opts(write_info),
          write_info: write_info,
          publish: fn extra_commit_opts ->
            publish.(Keyword.merge([version_id: "null", object_meta: %{}], extra_commit_opts))
          end,
          metadata_tx: fn journal, _published ->
            case Objects.put_version_with_id(
                   bucket,
                   key,
                   "null",
                   %{size: write_info.size, etag: write_info.etag},
                   transaction_hook: ObjectMutationCommit.transaction_hook(journal)
                 ) do
              {:ok, {%Objects.Object{} = object, :ok}} -> {:ok, object}
              {:error, _reason} = error -> error
            end
          end
        })
      end
    )
  end

  # 在 publish 之后、metadata 事务之前扰动目标 journal（attempts+1）：事务 hook 内基于
  # 请求手中旧 journal 行的 CAS 必然 stale_journal → 整个 metadata 事务回滚
  # （put_object_mutation_e2e_test / C2 同源注入手段）。
  #
  # 必须用**保留取证**的 operational CAS probe `mark_operational_error/3`（design D6
  # §3.3）：SQL update set 只含 attempts / next_attempt_at / bounded last_error /
  # updated_at，逐字保留 published 行上的 `published_fingerprint` 与 canonical successful
  # wrapper，于是随后的 `request_rollback/3` 仍有合法 durable evidence，可同步 restore 旧
  # 对象。legacy `mark_error/4` 会替换 recovery_evidence 并被 published-origin 校验合法
  # 拒绝——那是夹具违约，不是状态机回归。reason 必须是稳定 binary。
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

         {:ok, _} = ObjectMutation.mark_operational_error(journal, "c3_perturb")
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

  defp target(bucket, key) do
    {:ok, target} = ObjectEpoch.object_target(bucket, key, "null")
    target
  end

  defp final_dir(ctx, key) do
    {:ok, rel} = Paths.object_rel(ctx.bucket, key, "null")
    Path.join(ctx.data_dir, rel)
  end

  # final meta.json 的唯一 versions entry（maxio/2 sidecar；本套件对象均单 null 版本）。
  defp sidecar_entry(ctx, key) do
    meta = Jason.decode!(File.read!(Path.join(final_dir(ctx, key), "meta.json")))
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

  defp future(seconds), do: DateTime.add(DateTime.utc_now(), seconds, :second)

  # 10ms receive 轮询（零 Process.sleep）。
  defp assert_eventually(fun, timeout_ms \\ 10_000) when is_function(fun, 0) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms

    unless eventually?(fun, deadline) do
      flunk("condition not met within #{timeout_ms}ms")
    end
  end

  defp eventually?(fun, deadline) do
    if fun.() do
      true
    else
      if System.monotonic_time(:millisecond) >= deadline do
        false
      else
        receive do
        after
          10 -> eventually?(fun, deadline)
        end
      end
    end
  end
end
