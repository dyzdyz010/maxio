defmodule Maxio.S3.CurrentDeleteTransactionSafetyTest do
  @moduledoc """
  Task 3 C1 —— current-delete 元数据事务安全门。

  `Maxio.Objects.delete_metadata/3` 带 `:transaction_hook` 时的公开返回和是
  `map() | {map(), term()} | {:error, term()}`。handler 的 PG 分支若先匹配**任意**二元组，
  真实可达的 `{:error, reason}` 就会被误认作成功，随后仍调用 `Storage.delete/4`——PG 行保留、
  对象字节被删，权威元数据与字节分叉。

  三格：

    * R0a：正常成功二元组契约（禁止把成功误判成事务错误）；
    * R0b：`repo.rollback/1` 错误形状真实可达（不是手工伪造的值）；
    * R1：live Endpoint 破坏性顺序——元数据事务失败后绝不删字节、绝不发通知、绝不 204。

  全程 `start_supervised!/1`、零 `Process.sleep/1`、env/failpoint/临时目录精确恢复。
  """

  use Maxio.DataCase, async: false

  alias Maxio.Buckets
  alias Maxio.Failpoint
  alias Maxio.Objects
  alias Maxio.S3.Endpoint
  alias Maxio.S3.NotificationOutbox
  alias Maxio.Test.SigV4Request
  alias Maxio.Test.StorageDeleteProbeBackend, as: DeleteProbe

  @rollback_sentinel {:c1_rollback_sentinel, "c1-current-delete-rollback-9f4be2"}

  @failpoint :current_delete_metadata_before_notification_enqueue

  @remove_config """
  <NotificationConfiguration xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
    <QueueConfiguration>
      <Id>c1-removed</Id>
      <Queue>arn:aws:sqs:us-east-1:000000000000:c1-removed</Queue>
      <Event>s3:ObjectRemoved:Delete</Event>
    </QueueConfiguration>
  </NotificationConfiguration>
  """

  setup do
    data_dir =
      Path.join(
        System.tmp_dir!(),
        "maxio_c1_current_delete_#{System.unique_integer([:positive])}"
      )

    File.rm_rf(data_dir)
    File.mkdir_p!(data_dir)

    prev_s3 = Application.get_env(:maxio, :s3)
    prev_backend = Application.get_env(:maxio, :storage_backend)
    prev_authoritative_source = Application.get_env(:maxio, :authoritative_source)
    prev_notification_delivery = Application.get_env(:maxio, :notification_delivery)

    prev_notification_destination_validator =
      Application.get_env(:maxio, :notification_destination_validator)

    Application.put_env(:maxio, :s3, Keyword.put(prev_s3, :data_dir, data_dir))
    Application.put_env(:maxio, :authoritative_source, read: :pg, list: :pg, write: :pg)
    Application.delete_env(:maxio, :notification_delivery)
    Application.delete_env(:maxio, :notification_destination_validator)

    on_exit(fn ->
      restore_env(:s3, prev_s3)
      restore_env(:storage_backend, prev_backend)
      restore_env(:authoritative_source, prev_authoritative_source)
      restore_env(:notification_delivery, prev_notification_delivery)

      restore_env(
        :notification_destination_validator,
        prev_notification_destination_validator
      )

      Failpoint.disarm(@failpoint)
      File.rm_rf(data_dir)
    end)

    bucket = "c1del-#{System.unique_integer([:positive])}"

    %{data_dir: data_dir, bucket: bucket}
  end

  # =====================================================================
  # R0a —— 成功二元组契约
  # =====================================================================

  test "r0a: a successful transaction hook yields {map target, hook result} and deletes the PG row",
       ctx do
    key = "r0a/contract.txt"
    {:ok, _bucket} = Buckets.create(ctx.bucket, "arn:aws:iam:::root")
    {:ok, _object} = put_pg_object(ctx.bucket, key, "r0a body")

    assert {:ok, %Objects.Object{}} = Objects.get_metadata(ctx.bucket, key)

    result =
      Objects.delete_metadata(ctx.bucket, key,
        transaction_hook: fn _repo, target -> {:hook_ok, target.version_id} end
      )

    # 成功形状必须以 **map target** 为证——handler 不得再用任意 `{left, right}` 判定成功。
    assert {%{} = target, {:hook_ok, version_id}} = result
    assert target.version_id === "null"
    assert version_id === "null"

    # 这条断言锁死「不得把正常成功二元组误判为事务错误」。
    refute match?({:error, _reason}, result)

    assert {:error, :not_found} = Objects.get_metadata(ctx.bucket, key)
  end

  # =====================================================================
  # R0b —— rollback 错误形状真实可达
  # =====================================================================

  test "r0b: a rolled-back transaction hook yields {:error, sentinel} and leaves the PG row intact",
       ctx do
    key = "r0b/contract.txt"
    {:ok, _bucket} = Buckets.create(ctx.bucket, "arn:aws:iam:::root")
    {:ok, _object} = put_pg_object(ctx.bucket, key, "r0b body")

    assert {:ok, %Objects.Object{} = before} = Objects.get_metadata(ctx.bucket, key)

    result =
      Objects.delete_metadata(ctx.bucket, key,
        transaction_hook: fn repo, _target -> repo.rollback(@rollback_sentinel) end
      )

    # handler 必须消费的错误形状**真实可达**，不是手工伪造的值。
    assert result === {:error, @rollback_sentinel}

    # PG 行/ETag/size/version_id 与调用前快照逐字一致。
    assert {:ok, %Objects.Object{} = current} = Objects.get_metadata(ctx.bucket, key)
    assert current.etag === before.etag
    assert current.size === before.size
    assert current.version_id === before.version_id
  end

  # =====================================================================
  # R1 —— live Endpoint 破坏性顺序不变量
  # =====================================================================

  test "r1: a failed current-delete metadata transaction never deletes bytes, notifies, or returns 204",
       ctx do
    key = "r1/live.txt"
    body = "c1 live body #{System.unique_integer([:positive])}"

    start_supervised!(DeleteProbe)
    Application.put_env(:maxio, :storage_backend, DeleteProbe)

    assert create_bucket(ctx.bucket).status === 200
    assert put_object(ctx.bucket, key, body).status === 200

    # Put 后的权威快照。
    assert {:ok, %Objects.Object{} = snapshot} = Objects.get_metadata(ctx.bucket, key)

    # 真实匹配 `s3:ObjectRemoved:Delete` 的 stored notification + 同步 tests-only deliverer：
    # 这样 outbox/delivery 断言才有意义（而不是因为「本来就没有配置」而空）。
    assert put_notification(ctx.bucket, @remove_config).status === 200
    enable_notification_delivery!()

    assert NotificationOutbox.list() === []

    baseline_deletes = DeleteProbe.call_count()

    # 专用 failpoint 位于 PG current-delete 的事务 hook 内、notification enqueue 之前：
    # 先记录精确命中，再在**当前事务进程**里 rollback 稳定 sentinel。
    #
    # 命中计数刻意用**独立的 supervised Agent**而不是给测试进程发消息：单对象 DELETE 经
    # `Maxio.Cluster.Lock` 在 worker 进程里执行，父测试进程此刻正阻塞在 `wait_for_result/4`
    # 的 selective receive 里，而该 receive 有 `_other -> wait_for_result(...)` 兜底子句，
    # 会把任何非预期消息直接吞掉。Agent 状态与消息投递正交，因此命中证据不受影响。
    hits = start_supervised!({Agent, fn -> 0 end}, id: :c1_failpoint_hits)

    Failpoint.arm(
      @failpoint,
      {:fun,
       fn ->
         Agent.update(hits, &(&1 + 1))
         Maxio.Repo.rollback(@rollback_sentinel)
       end}
    )

    resp = delete_object(ctx.bucket, key)

    # --- 精确命中一次（证明失败确实发生在被裁定的挂点上）---
    assert Agent.get(hits, & &1) === 1,
           "T3-C1: 专用 failpoint 必须恰好命中一次"

    # --- 公共错误：500 / InternalError / 目录默认 message / resource ---
    assert resp.status === 500
    assert resp.resp_body =~ "<Code>InternalError</Code>"
    assert resp.resp_body =~ "<Message>An internal error occurred. Try again.</Message>"
    assert resp.resp_body =~ "<Resource>/#{ctx.bucket}/#{key}</Resource>"

    # --- 公共面零泄漏：内部 reason / sentinel / 通知配置细节绝不进 XML ---
    for leak <- [
          "c1-current-delete-rollback-9f4be2",
          "c1_rollback_sentinel",
          "c1-removed",
          ctx.data_dir,
          body
        ] do
      refute String.contains?(resp.resp_body, leak),
             "T3-C1: 公共 XML 泄漏了内部材料 #{leak}"
    end

    # --- 破坏性顺序：字节绝不被删 ---
    assert DeleteProbe.call_count() === 0

    assert DeleteProbe.call_count() === baseline_deletes,
           "T3-C1: 元数据事务失败后绝不允许调用 Storage.delete/4"

    assert DeleteProbe.calls() === []

    # --- 通知：outbox 空、无投递 ---
    assert NotificationOutbox.list() === []
    refute_receive {:maxio_notification, _event}, 50

    # --- PG 权威行原样保留 ---
    assert {:ok, %Objects.Object{} = current} = Objects.get_metadata(ctx.bucket, key)
    assert current.etag === snapshot.etag
    assert current.size === snapshot.size
    assert current.version_id === snapshot.version_id

    # --- 对象仍可完整读取，字节逐字等于原 body ---
    get_resp = get_object(ctx.bucket, key)
    assert get_resp.status === 200
    assert get_resp.resp_body === body
  end

  # --- helpers ---

  defp restore_env(key, nil), do: Application.delete_env(:maxio, key)
  defp restore_env(key, value), do: Application.put_env(:maxio, key, value)

  defp put_pg_object(bucket, key, body) do
    Objects.put_version(bucket, key, "Unversioned", %{
      size: byte_size(body),
      etag: :crypto.hash(:md5, body) |> Base.encode16(case: :lower)
    })
  end

  defp call(conn), do: Endpoint.call(conn, Endpoint.init([]))

  defp signed(method, path, opts \\ []), do: SigV4Request.signed_conn(method, path, opts)

  defp create_bucket(bucket), do: signed(:put, "/#{bucket}") |> call()

  defp put_object(bucket, key, body),
    do: signed(:put, "/#{bucket}/#{key}", body: body) |> call()

  defp get_object(bucket, key), do: signed(:get, "/#{bucket}/#{key}") |> call()

  defp delete_object(bucket, key), do: signed(:delete, "/#{bucket}/#{key}") |> call()

  defp put_notification(bucket, body) do
    signed(:put, "/#{bucket}",
      query: %{"notification" => ""},
      body: body,
      headers: [{"x-amz-skip-destination-validation", "true"}]
    )
    |> call()
  end

  defp enable_notification_delivery!(pid \\ self()) do
    Application.put_env(
      :maxio,
      :notification_delivery,
      deliverer: {Maxio.Test.NotificationDeliverer, pid},
      async?: false
    )
  end
end
