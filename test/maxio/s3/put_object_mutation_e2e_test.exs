defmodule Maxio.S3.PutObjectMutationE2ETest do
  @moduledoc """
  ObjectMutation Phase 1 B7 —— 真实 Bandit 端到端收口（协议 §6 Phase 1 验收的 e2e 版）：

    1. 普通签名 PUT 快乐路径：bytes / sidecar / PG row / journal(finalized) /
       epoch(committed) 五位一体同一 token + fingerprint；
    2. `STREAMING-AWS4-HMAC-SHA256` aws-chunked PUT 同断言；
    3. failpoint `:object_mutation_after_metadata_commit` = `:kill_self`（真实 socket 中断）
       → recovery 收敛 finalized、**新字节保留**（Phase 1 验收 1 的 e2e 版）；
    4. failpoint `:object_mutation_before_metadata_commit` = `:kill_self` → recovery 收敛
       rolled_back、**旧字节恢复**（Phase 1 验收 2 的 e2e 版）；
    5. journal metadata CAS 争用（stale_journal）→ 503 SlowDownWrite 结构化响应 +
       旧字节恢复（B5 审查项 3 的端到端断言）；
    6. 日志字段审计（协议 §7）：formatter 白名单真实放行全部固定字段；日志绝不携带对象
       body；SSE envelope 经 schema redact 不可经 inspect/reason 通道泄露。

  同步纪律：崩溃用 failpoint + 真实连接中断信号，收敛用条件轮询（10ms receive），
  零 `Process.sleep`。
  """

  use Maxio.DataCase, async: false

  import ExUnit.CaptureLog
  import Plug.Conn, only: [read_body: 1]

  require Logger

  alias Maxio.{Objects, ObjectMutation, Storage}
  alias Maxio.Cluster.Paths
  alias Maxio.Failpoint
  alias Maxio.ObjectMutation.Journal
  alias Maxio.ObjectMutation.Recovery
  alias Maxio.Storage.ObjectEpoch
  alias Maxio.Test.SigV4Request

  setup do
    data_dir =
      Path.join(
        System.tmp_dir!(),
        "maxio_put_mutation_e2e_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(data_dir)
    previous_s3 = Application.get_env(:maxio, :s3, [])
    Application.put_env(:maxio, :s3, Keyword.put(previous_s3, :data_dir, data_dir))

    bandit =
      start_supervised!(
        {Bandit,
         plug: Maxio.S3.Endpoint, scheme: :http, ip: {127, 0, 0, 1}, port: 0, startup_log: false}
      )

    {:ok, {_address, port}} = ThousandIsland.listener_info(bandit)

    on_exit(fn ->
      Application.put_env(:maxio, :s3, previous_s3)
      File.rm_rf(data_dir)
    end)

    {:ok, port: port, data_dir: data_dir}
  end

  # ── 1/2：快乐路径五位一体（普通签名 + aws-chunked）──

  test "ordinary signed PUT：bytes/sidecar/PG/journal/epoch 五位一体同一 token", ctx do
    bucket = "mutordinary"
    key = "plain.bin"
    body = :crypto.strong_rand_bytes(64 * 1024 + 7)

    create_bucket(ctx.port, bucket)

    put =
      signed_request(ctx.port, SigV4Request.signed_conn(:put, "/#{bucket}/#{key}", body: body))

    assert put.status == 200
    assert_five_way_consistency(ctx, bucket, key, body, generation: 1)
  end

  test "aws-chunked（STREAMING-AWS4-HMAC-SHA256）PUT：五位一体同一 token", ctx do
    bucket = "mutchunked"
    key = "chunked.bin"
    body = :crypto.strong_rand_bytes(96 * 1024 + 31)

    create_bucket(ctx.port, bucket)

    put =
      signed_request(
        ctx.port,
        SigV4Request.signed_chunked_conn(:put, "/#{bucket}/#{key}", body, chunk_size: 16_391)
      )

    assert put.status == 200
    assert_five_way_consistency(ctx, bucket, key, body, generation: 1)
  end

  # ── 3：PG commit 后 kill → recovery finalize、新字节保留（Phase 1 验收 1）──

  test "PG commit 后 kill（真实 socket 中断）：recovery 收敛 finalized、新字节保留", ctx do
    bucket = "mutcrashfinal"
    key = "crash.bin"
    old_body = "old committed body"
    new_body = "new body survives pg-commit crash"

    create_bucket(ctx.port, bucket)
    assert 200 == put_object(ctx.port, bucket, key, old_body).status

    Failpoint.arm(:object_mutation_after_metadata_commit, :kill_self)
    on_exit(fn -> Failpoint.disarm(:object_mutation_after_metadata_commit) end)

    # 协议执行进程在 PG 事务提交后被硬杀（协议序列在对象锁 worker 内执行；owner 连带
    # exit）——客户端观察到真实失败（Bandit 崩溃式 500 空 body 或连接中断），绝无成功响应。
    assert_crashed(
      signed_result(
        ctx.port,
        SigV4Request.signed_conn(:put, "/#{bucket}/#{key}", body: new_body)
      )
    )

    Failpoint.disarm(:object_mutation_after_metadata_commit)

    journal = journal_for(bucket, key)
    assert journal.phase == "metadata_committed"
    assert journal.generation == 2

    # crash 时刻三态：新字节已发布、epoch=published、PG 行已提交（分裂窗口输入）
    assert File.read!(Path.join(final_dir(ctx, bucket, key), "part.0")) == new_body
    assert {:ok, %ObjectEpoch{phase: "published"}} = Storage.current_epoch(target(bucket, key))
    assert {:ok, %Objects.Object{etag: etag}} = Objects.get_metadata(bucket, key)
    assert etag == md5_hex(new_body)
    refute mutation_dirs(ctx) == []

    # recovery 收敛（prepare 宽限 60s → now 注入越过；对象锁释放存在异步窗口 → 条件轮询）
    assert_eventually(fn ->
      _ = Recovery.drain(now: future(300))
      ObjectMutation.get(journal.id).phase == "finalized"
    end)

    assert File.read!(Path.join(final_dir(ctx, bucket, key), "part.0")) == new_body

    assert {:ok, %ObjectEpoch{phase: "committed"} = epoch} =
             Storage.current_epoch(target(bucket, key))

    assert epoch.token == %{"generation" => journal.generation, "mutation_id" => journal.id}
    assert {:ok, %Objects.Object{etag: ^etag}} = Objects.get_metadata(bucket, key)
    assert mutation_dirs(ctx) == []
  end

  # ── 4：metadata 前 kill → recovery rollback、旧字节恢复（Phase 1 验收 2）──

  test "metadata 前 kill（真实 socket 中断）：recovery 收敛 rolled_back、旧字节恢复", ctx do
    bucket = "mutcrashroll"
    key = "crash.bin"
    old_body = "old body must be restored"
    new_body = "TOP-SECRET-OBJECT-BODY-DO-NOT-LOG"

    create_bucket(ctx.port, bucket)
    assert 200 == put_object(ctx.port, bucket, key, old_body).status
    assert {:ok, %Objects.Object{etag: old_etag}} = Objects.get_metadata(bucket, key)

    Failpoint.arm(:object_mutation_before_metadata_commit, :kill_self)
    on_exit(fn -> Failpoint.disarm(:object_mutation_before_metadata_commit) end)

    # 日志审计（协议 §7 禁项）：整个 crash + 收敛期间的日志绝不携带对象 body。
    log =
      capture_log(fn ->
        assert_crashed(
          signed_result(
            ctx.port,
            SigV4Request.signed_conn(:put, "/#{bucket}/#{key}", body: new_body)
          )
        )

        Failpoint.disarm(:object_mutation_before_metadata_commit)

        journal = journal_for(bucket, key)
        assert journal.generation == 2

        # Control guard（owner DOWN）best-effort 回滚与 recovery drain 竞争收敛：
        # 全部动作 CAS 幂等，终局唯一（rolled_back + 旧字节）。
        assert_eventually(fn ->
          _ = Recovery.drain(now: future(300))
          ObjectMutation.get(journal.id).phase == "rolled_back"
        end)
      end)

    refute log =~ new_body

    journal = journal_for(bucket, key)
    assert journal.phase == "rolled_back"
    assert File.read!(Path.join(final_dir(ctx, bucket, key), "part.0")) == old_body
    assert {:ok, %ObjectEpoch{phase: "rolled_back"}} = Storage.current_epoch(target(bucket, key))
    assert {:ok, %Objects.Object{etag: ^old_etag}} = Objects.get_metadata(bucket, key)
    assert mutation_dirs(ctx) == []
  end

  test "fresh metadata 前 kill：recovery 后 HTTP/PG 不可见且 final 物理不存在", ctx do
    bucket = "mutcrashfresh"
    key = "fresh.bin"
    body = "fresh body must be physically removed"

    create_bucket(ctx.port, bucket)

    Failpoint.arm(:object_mutation_before_metadata_commit, :kill_self)
    on_exit(fn -> Failpoint.disarm(:object_mutation_before_metadata_commit) end)

    assert_crashed(
      signed_result(ctx.port, SigV4Request.signed_conn(:put, "/#{bucket}/#{key}", body: body))
    )

    Failpoint.disarm(:object_mutation_before_metadata_commit)
    journal = journal_for(bucket, key)

    assert_eventually(fn ->
      _ = Recovery.drain(now: future(300))
      ObjectMutation.get(journal.id).phase == "rolled_back"
    end)

    journal = ObjectMutation.get(journal.id)
    assert journal.phase == "rolled_back"
    assert {:error, :not_found} = Objects.get_metadata(bucket, key)

    get = signed_request(ctx.port, SigV4Request.signed_conn(:get, "/#{bucket}/#{key}"))
    assert get.status == 404
    assert get.body =~ "<Code>NoSuchKey</Code>"

    assert {:ok, %ObjectEpoch{phase: "rolled_back"}} = Storage.current_epoch(target(bucket, key))
    assert mutation_dirs(ctx) == []
    refute File.exists?(final_dir(ctx, bucket, key))
  end

  # ── 5：journal metadata CAS 争用 → 503 SlowDownWrite（B5 审查项 3 端到端）──

  test "journal metadata CAS 争用（stale_journal）：503 SlowDownWrite + 旧字节恢复", ctx do
    bucket = "mutstale"
    key = "stale.bin"
    old_body = "old body before stale journal"
    new_body = "new body must not commit"

    create_bucket(ctx.port, bucket)
    assert 200 == put_object(ctx.port, bucket, key, old_body).status
    assert {:ok, %Objects.Object{etag: old_etag}} = Objects.get_metadata(bucket, key)

    # 在 publish 之后、metadata 事务之前扰动 journal（attempts+1）→ 事务内
    # metadata_committed CAS 必然 stale_journal → Repo.rollback → 结构化 503。
    Failpoint.arm(
      :object_mutation_before_metadata_commit,
      {:fun,
       fn ->
         journal =
           Repo.one!(
             from j in Journal,
               where: j.bucket_name == ^bucket and j.object_key == ^key and j.phase == "published"
           )

         {:ok, _} = ObjectMutation.mark_error(journal, :e2e_perturb, %{"stage" => "e2e"})
       end}
    )

    on_exit(fn -> Failpoint.disarm(:object_mutation_before_metadata_commit) end)

    {resp, log} =
      with_log(fn ->
        signed_request(
          ctx.port,
          SigV4Request.signed_conn(:put, "/#{bucket}/#{key}", body: new_body)
        )
      end)

    Failpoint.disarm(:object_mutation_before_metadata_commit)

    assert resp.status == 503
    assert resp.body =~ "<Code>SlowDownWrite</Code>"

    # 回滚在响应前同步完成：journal=rolled_back、旧字节/旧 PG 行原样、PG 无半提交
    journal = journal_for(bucket, key)
    assert journal.phase == "rolled_back"
    assert journal.last_error =~ "e2e_perturb"
    assert File.read!(Path.join(final_dir(ctx, bucket, key), "part.0")) == old_body
    assert {:ok, %Objects.Object{etag: ^old_etag}} = Objects.get_metadata(bucket, key)
    assert {:ok, %ObjectEpoch{phase: "rolled_back"}} = Storage.current_epoch(target(bucket, key))

    # 日志字段审计（协议 §7 关键事件真实携带固定字段；warn 级在 test logger level 下可见）
    assert log =~ "action=object_mutation_metadata_commit"
    assert log =~ "action=object_mutation_rollback_requested"
    assert log =~ "action=object_mutation_rollback_result"
    assert log =~ "mutation_id=#{journal.id}"
    assert log =~ "mutation_generation=#{journal.generation}"
    assert log =~ "mutation_operation=put"
    assert log =~ "mutation_phase="
    assert log =~ "authority_mode=pg"
    assert log =~ "backend=Maxio.Storage.FS"
    assert log =~ "bucket=#{bucket}"
    assert log =~ "key=#{key}"
    assert log =~ "version_id=null"
    assert log =~ "outcome="
    # 绝不记录对象 body（协议 §7 禁项）
    refute log =~ new_body
    refute log =~ old_body
  end

  # ── 6：日志字段白名单与脱敏（B5 审查项 1/2）──

  describe "日志字段审计（协议 §7）" do
    test "logger default_formatter 放行协议 §7 全部固定字段（B5 审查项 1）" do
      log =
        capture_log(fn ->
          Logger.warning("maxio object mutation log whitelist probe",
            action: :probe_action,
            request_id: "req-probe-1",
            mutation_id: "mid-probe-1",
            mutation_generation: 42,
            mutation_operation: "put",
            mutation_phase: "published",
            authority_mode: "pg",
            backend: "Maxio.Storage.FS",
            bucket: "probe-bucket",
            key: "probe-key",
            version_id: "probe-version",
            placement_set_id: 7,
            outcome: "probe-ok",
            reason: "probe-reason"
          )
        end)

      for fragment <- [
            "action=probe_action",
            "request_id=req-probe-1",
            "mutation_id=mid-probe-1",
            "mutation_generation=42",
            "mutation_operation=put",
            "mutation_phase=published",
            "authority_mode=pg",
            "backend=Maxio.Storage.FS",
            "bucket=probe-bucket",
            "key=probe-key",
            "version_id=probe-version",
            "placement_set_id=7",
            "outcome=probe-ok",
            "reason=probe-reason"
          ] do
        assert log =~ fragment
      end
    end

    test "sse_envelope 经 schema redact 不可经 inspect/reason 通道泄露（B5 审查项 2）" do
      secret = "SECRET-WRAPPED-DEK-MATERIAL"

      refute inspect(%Maxio.Objects.Object{sse_envelope: %{"key" => secret}}) =~ secret
      refute inspect(%Maxio.Multipart.Upload{sse_envelope: %{"key" => secret}}) =~ secret

      # changeset inspect（错误日志的 reason 通道形态）同样被 redact
      changeset =
        Maxio.Objects.Object.changeset(%Maxio.Objects.Object{}, %{
          sse_envelope: %{"key" => secret}
        })

      refute inspect(changeset) =~ secret
    end
  end

  # ── helpers ──

  defp create_bucket(port, bucket) do
    assert %{status: 200} = signed_request(port, SigV4Request.signed_conn(:put, "/#{bucket}"))
  end

  defp put_object(port, bucket, key, body) do
    signed_request(port, SigV4Request.signed_conn(:put, "/#{bucket}/#{key}", body: body))
  end

  defp signed_request(port, conn) do
    case signed_result(port, conn) do
      {:ok, response} -> response
      {:error, error} -> flunk("request failed: #{inspect(error)}")
    end
  end

  # kill_self 命中协议执行进程后的客户端观测：连接中断（transport error）或 Bandit 崩溃式
  # 500（空 body + connection: close）。二者都证明请求以真实进程崩溃告终——绝不接受任何
  # 成功响应或结构化 S3 错误（结构化错误意味着 handler 仍在正常收敛，非 crash 语义）。
  defp assert_crashed({:error, _transport_error}), do: :ok
  defp assert_crashed({:ok, %Req.Response{status: 500, body: ""}}), do: :ok
  defp assert_crashed(other), do: flunk("expected crashed request, got: #{inspect(other)}")

  # 复用 SigV4Request 的自签 conn，改经真实 socket 发出（bandit_put_object_test 同源模式）；
  # 崩溃注入场景返回 {:error, transport_error}（真实连接中断，而非 HTTP 响应）。
  defp signed_result(port, conn) do
    {:ok, body, _conn} = read_body(conn)
    method = conn.method |> String.downcase() |> String.to_existing_atom()

    path =
      case conn.query_string do
        "" -> conn.request_path
        query -> conn.request_path <> "?" <> query
      end

    Req.request(
      method: method,
      url: "http://127.0.0.1:#{port}" <> path,
      headers: [{"host", "localhost"} | conn.req_headers],
      body: body,
      retry: false,
      receive_timeout: 15_000
    )
  end

  # 五位一体断言：bytes / sidecar fingerprint / PG row / journal(finalized) /
  # epoch(committed) 同一 token（协议 §8 测试矩阵第一行）。
  defp assert_five_way_consistency(ctx, bucket, key, body, generation: generation) do
    journal = journal_for(bucket, key)
    assert journal.phase == "finalized"
    assert journal.generation == generation
    assert journal.authority_mode == "pg"
    assert journal.operation == "put"
    assert not is_nil(journal.metadata_committed_at)
    assert not is_nil(journal.finalized_at)

    # bytes
    final = final_dir(ctx, bucket, key)
    assert File.read!(Path.join(final, "part.0")) == body

    # sidecar：journal published_fingerprint 与 final meta.json 实际字节精确匹配
    fingerprint = journal.published_fingerprint
    assert fingerprint["etag"] == md5_hex(body)
    assert fingerprint["size"] == byte_size(body)
    assert fingerprint["sidecar_sha256"] == sha256_hex(File.read!(Path.join(final, "meta.json")))

    # PG row
    assert {:ok, %Objects.Object{} = row} = Objects.get_metadata(bucket, key)
    assert row.etag == md5_hex(body)
    assert row.size == byte_size(body)

    # epoch：committed + 同一 token + 同一 fingerprint
    assert {:ok, %ObjectEpoch{phase: "committed"} = epoch} =
             Storage.current_epoch(target(bucket, key))

    assert epoch.token == %{"generation" => journal.generation, "mutation_id" => journal.id}
    assert epoch.fingerprint == fingerprint

    # durable backup 已随 finalize 丢弃
    assert mutation_dirs(ctx) == []
  end

  defp journal_for(bucket, key) do
    Repo.one!(
      from j in Journal,
        where: j.bucket_name == ^bucket and j.object_key == ^key,
        order_by: [desc: j.generation],
        limit: 1
    )
  end

  defp target(bucket, key) do
    {:ok, target} = ObjectEpoch.object_target(bucket, key, "null")
    target
  end

  defp final_dir(ctx, bucket, key) do
    {:ok, rel} = Paths.object_rel(bucket, key, "null")
    Path.join(ctx.data_dir, rel)
  end

  # durable mutation backup 根下的残留目录（File.ls 判空，B2 审查项 1 同源 idiom）。
  defp mutation_dirs(ctx) do
    case File.ls(Path.join(ctx.data_dir, ".maxio-object-mutations")) do
      {:ok, entries} -> entries
      {:error, :enoent} -> []
    end
  end

  defp md5_hex(body), do: :crypto.hash(:md5, body) |> Base.encode16(case: :lower)
  defp sha256_hex(body), do: :crypto.hash(:sha256, body) |> Base.encode16(case: :lower)

  defp future(seconds), do: DateTime.add(DateTime.utc_now(), seconds, :second)

  # 10ms receive 轮询（零 Process.sleep）：crash 后对象锁释放 / Control 收口存在异步窗口。
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
