defmodule Maxio.LifecycleTest do
  use Maxio.DataCase, async: false

  import Ecto.Query
  import Plug.Conn

  alias Maxio.BucketConfigs
  alias Maxio.Multipart
  alias Maxio.Multipart.Upload
  alias Maxio.Objects
  alias Maxio.Objects.Object
  alias Maxio.Repo
  alias Maxio.S3.Endpoint
  alias Maxio.Test.SigV4Request

  @data_dir Path.join(System.tmp_dir!(), "maxio_lifecycle_exec")
  @now ~U[2026-06-11 00:00:00Z]
  @old DateTime.add(@now, -3 * 86_400, :second)

  setup do
    File.rm_rf(@data_dir)
    File.mkdir_p!(@data_dir)
    prev = Application.get_env(:maxio, :s3)
    Application.put_env(:maxio, :s3, Keyword.put(prev, :data_dir, @data_dir))

    on_exit(fn ->
      Application.put_env(:maxio, :s3, prev)
      File.rm_rf(@data_dir)
    end)

    :ok
  end

  defp call(conn), do: Endpoint.call(conn, Endpoint.init([]))

  test "Expiration deletes only old current objects matching prefix and tag filters" do
    SigV4Request.signed_conn(:put, "/lcexp") |> call()

    SigV4Request.signed_conn(:put, "/lcexp/logs/delete.txt",
      body: "old",
      headers: [{"x-amz-tagging", "class=tmp"}]
    )
    |> call()

    SigV4Request.signed_conn(:put, "/lcexp/logs/keep.txt",
      body: "old",
      headers: [{"x-amz-tagging", "class=keep"}]
    )
    |> call()

    touch_objects("lcexp", @old)

    :ok =
      BucketConfigs.put("lcexp", :lifecycle, [
        rule(%{
          "filter_prefix" => "logs/",
          "filter_tags" => [%{"key" => "class", "value" => "tmp"}],
          "expiration_days" => 1
        })
      ])

    summary = Maxio.Lifecycle.run(now: @now)

    assert summary.objects_expired == 1
    assert summary.errors == []

    deleted = SigV4Request.signed_conn(:get, "/lcexp/logs/delete.txt") |> call()
    assert deleted.status == 404

    kept = SigV4Request.signed_conn(:get, "/lcexp/logs/keep.txt") |> call()
    assert kept.status == 200
    assert kept.resp_body == "old"
  end

  test "Expiration in a versioning-enabled bucket adds a delete marker and preserves old version" do
    SigV4Request.signed_conn(:put, "/lcversioned") |> call()
    :ok = Maxio.Buckets.put_versioning("lcversioned", "Enabled", nil)

    put =
      SigV4Request.signed_conn(:put, "/lcversioned/doc.txt", body: "v1")
      |> call()

    [version_id] = get_resp_header(put, "x-amz-version-id")
    touch_objects("lcversioned", @old)

    :ok =
      BucketConfigs.put("lcversioned", :lifecycle, [
        rule(%{"filter_prefix" => "", "expiration_days" => 1})
      ])

    summary = Maxio.Lifecycle.run(now: @now)

    assert summary.objects_expired == 1
    assert summary.errors == []

    latest = SigV4Request.signed_conn(:get, "/lcversioned/doc.txt") |> call()
    assert latest.status == 404

    old =
      SigV4Request.signed_conn(:get, "/lcversioned/doc.txt", query: %{"versionId" => version_id})
      |> call()

    assert old.status == 200
    assert old.resp_body == "v1"

    {:ok, marker} = Objects.get_metadata("lcversioned", "doc.txt")
    assert marker.is_delete_marker
    assert marker.version_id != version_id
  end

  test "NoncurrentVersionExpiration deletes versions after they became noncurrent" do
    SigV4Request.signed_conn(:put, "/lcnoncur") |> call()
    :ok = Maxio.Buckets.put_versioning("lcnoncur", "Enabled", nil)

    v1 = put_object_version!("lcnoncur", "doc.txt", "v1")
    v2 = put_object_version!("lcnoncur", "doc.txt", "v2")
    _v3 = put_object_version!("lcnoncur", "doc.txt", "v3")

    touch_version("lcnoncur", "doc.txt", v1, DateTime.add(@now, -10 * 86_400, :second))
    touch_version("lcnoncur", "doc.txt", v2, DateTime.add(@now, -5 * 86_400, :second))
    touch_latest("lcnoncur", "doc.txt", DateTime.add(@now, -1 * 86_400, :second))

    :ok =
      BucketConfigs.put("lcnoncur", :lifecycle, [
        rule(%{"filter_prefix" => "", "noncurrent_days" => 3})
      ])

    summary = Maxio.Lifecycle.run(now: @now)

    assert summary.noncurrent_versions_expired == 1
    assert summary.errors == []

    assert_version_status("lcnoncur", "doc.txt", v1, 404)
    assert_version_status("lcnoncur", "doc.txt", v2, 200)

    latest = SigV4Request.signed_conn(:get, "/lcnoncur/doc.txt") |> call()
    assert latest.status == 200
    assert latest.resp_body == "v3"
  end

  test "NoncurrentVersionExpiration with NewerNoncurrentVersions keeps the requested history" do
    SigV4Request.signed_conn(:put, "/lcretain") |> call()
    :ok = Maxio.Buckets.put_versioning("lcretain", "Enabled", nil)

    v1 = put_object_version!("lcretain", "docs/retain.txt", "v1")
    v2 = put_object_version!("lcretain", "docs/retain.txt", "v2")
    v3 = put_object_version!("lcretain", "docs/retain.txt", "v3")
    _v4 = put_object_version!("lcretain", "docs/retain.txt", "v4")

    touch_version("lcretain", "docs/retain.txt", v1, DateTime.add(@now, -10 * 86_400, :second))
    touch_version("lcretain", "docs/retain.txt", v2, DateTime.add(@now, -8 * 86_400, :second))
    touch_version("lcretain", "docs/retain.txt", v3, DateTime.add(@now, -6 * 86_400, :second))
    touch_latest("lcretain", "docs/retain.txt", DateTime.add(@now, -1 * 86_400, :second))

    :ok =
      BucketConfigs.put("lcretain", :lifecycle, [
        rule(%{
          "filter_prefix" => "docs/",
          "noncurrent_days" => 1,
          "newer_noncurrent_versions" => 1
        })
      ])

    summary = Maxio.Lifecycle.run(now: @now)

    assert summary.noncurrent_versions_expired == 1
    assert summary.errors == []

    assert_version_status("lcretain", "docs/retain.txt", v1, 404)
    assert_version_status("lcretain", "docs/retain.txt", v2, 200)
    assert_version_status("lcretain", "docs/retain.txt", v3, 200)

    latest = SigV4Request.signed_conn(:get, "/lcretain/docs/retain.txt") |> call()
    assert latest.status == 200
    assert latest.resp_body == "v4"
  end

  test "MFA Delete bucket skips NoncurrentVersionExpiration permanent deletes" do
    SigV4Request.signed_conn(:put, "/lcmfanoncur") |> call()
    :ok = Maxio.Buckets.put_versioning("lcmfanoncur", "Enabled", "Enabled")

    v1 = put_object_version!("lcmfanoncur", "doc.txt", "v1")
    _v2 = put_object_version!("lcmfanoncur", "doc.txt", "v2")

    touch_version("lcmfanoncur", "doc.txt", v1, DateTime.add(@now, -10 * 86_400, :second))
    touch_latest("lcmfanoncur", "doc.txt", DateTime.add(@now, -1 * 86_400, :second))

    :ok =
      BucketConfigs.put("lcmfanoncur", :lifecycle, [
        rule(%{"filter_prefix" => "", "noncurrent_days" => 1})
      ])

    summary = Maxio.Lifecycle.run(now: @now)

    assert summary.noncurrent_versions_expired == 0
    assert summary.mfa_delete_protected_actions_skipped == 1
    assert summary.errors == []
    assert_version_status("lcmfanoncur", "doc.txt", v1, 200)
  end

  test "MFA Delete suspended bucket skips current Expiration that would replace null version" do
    SigV4Request.signed_conn(:put, "/lcmfasuspexp") |> call()
    :ok = Maxio.Buckets.put_versioning("lcmfasuspexp", "Suspended", "Enabled")

    put = SigV4Request.signed_conn(:put, "/lcmfasuspexp/doc.txt", body: "null-live") |> call()
    assert put.status == 200

    touch_latest("lcmfasuspexp", "doc.txt", @old)

    :ok =
      BucketConfigs.put("lcmfasuspexp", :lifecycle, [
        rule(%{"filter_prefix" => "", "expiration_days" => 1})
      ])

    summary = Maxio.Lifecycle.run(now: @now)

    assert summary.objects_expired == 0
    assert summary.mfa_delete_protected_actions_skipped == 1
    assert summary.errors == []

    current = SigV4Request.signed_conn(:get, "/lcmfasuspexp/doc.txt") |> call()
    assert current.status == 200
    assert current.resp_body == "null-live"
  end

  test "NoncurrentVersionTransition is counted unsupported and never deletes versions" do
    SigV4Request.signed_conn(:put, "/lcnct") |> call()
    :ok = Maxio.Buckets.put_versioning("lcnct", "Enabled", nil)

    v1 = put_object_version!("lcnct", "doc.txt", "v1")
    _v2 = put_object_version!("lcnct", "doc.txt", "v2")

    touch_version("lcnct", "doc.txt", v1, DateTime.add(@now, -10 * 86_400, :second))
    touch_latest("lcnct", "doc.txt", DateTime.add(@now, -1 * 86_400, :second))

    :ok =
      BucketConfigs.put("lcnct", :lifecycle, [
        rule(%{
          "noncurrent_transition_days" => 1,
          "noncurrent_transition_newer_noncurrent_versions" => 1,
          "noncurrent_transition_storage_class" => "GLACIER"
        })
      ])

    summary = Maxio.Lifecycle.run(now: @now)

    assert summary.unsupported_rules == 1
    assert summary.noncurrent_versions_expired == 0
    assert summary.errors == []
    assert_version_status("lcnct", "doc.txt", v1, 200)
  end

  test "NoncurrentVersionExpiration ordering ignores mutable metadata updated_at" do
    SigV4Request.signed_conn(:put, "/lcstable") |> call()
    :ok = Maxio.Buckets.put_versioning("lcstable", "Enabled", nil)

    v1 = put_object_version!("lcstable", "doc.txt", "v1")
    v2 = put_object_version!("lcstable", "doc.txt", "v2")
    _v3 = put_object_version!("lcstable", "doc.txt", "v3")

    touch_version("lcstable", "doc.txt", v1, DateTime.add(@now, -10 * 86_400, :second))
    touch_version("lcstable", "doc.txt", v2, DateTime.add(@now, -5 * 86_400, :second))
    touch_latest("lcstable", "doc.txt", DateTime.add(@now, -1 * 86_400, :second))

    :ok = Objects.put_tags("lcstable", "doc.txt", [{"edited", "yes"}], v2)

    :ok =
      BucketConfigs.put("lcstable", :lifecycle, [
        rule(%{"filter_prefix" => "", "noncurrent_days" => 3})
      ])

    summary = Maxio.Lifecycle.run(now: @now)

    assert summary.noncurrent_versions_expired == 1
    assert summary.errors == []
    assert_version_status("lcstable", "doc.txt", v1, 404)
    assert_version_status("lcstable", "doc.txt", v2, 200)
  end

  test "Expiration Days rounds up to the next UTC midnight" do
    SigV4Request.signed_conn(:put, "/lcmidnight") |> call()
    SigV4Request.signed_conn(:put, "/lcmidnight/edge.txt", body: "edge") |> call()

    written_at = ~U[2026-06-10 10:30:00Z]
    touch_objects("lcmidnight", written_at)

    :ok =
      BucketConfigs.put("lcmidnight", :lifecycle, [
        rule(%{"expiration_days" => 1})
      ])

    early = Maxio.Lifecycle.run(now: ~U[2026-06-11 23:59:59Z])
    assert early.objects_expired == 0
    assert (SigV4Request.signed_conn(:get, "/lcmidnight/edge.txt") |> call()).status == 200

    due = Maxio.Lifecycle.run(now: ~U[2026-06-12 00:00:00Z])
    assert due.objects_expired == 1
    assert (SigV4Request.signed_conn(:get, "/lcmidnight/edge.txt") |> call()).status == 404
  end

  test "NoncurrentVersionExpiration Days rounds successor time up to UTC midnight" do
    SigV4Request.signed_conn(:put, "/lcncmidnight") |> call()
    :ok = Maxio.Buckets.put_versioning("lcncmidnight", "Enabled", nil)

    v1 = put_object_version!("lcncmidnight", "doc.txt", "v1")
    _v2 = put_object_version!("lcncmidnight", "doc.txt", "v2")

    touch_version("lcncmidnight", "doc.txt", v1, ~U[2026-06-01 00:00:00Z])
    touch_latest("lcncmidnight", "doc.txt", ~U[2026-06-10 10:30:00Z])

    :ok =
      BucketConfigs.put("lcncmidnight", :lifecycle, [
        rule(%{"filter_prefix" => "", "noncurrent_days" => 1})
      ])

    early = Maxio.Lifecycle.run(now: ~U[2026-06-11 23:59:59Z])
    assert early.noncurrent_versions_expired == 0
    assert_version_status("lcncmidnight", "doc.txt", v1, 200)

    due = Maxio.Lifecycle.run(now: ~U[2026-06-12 00:00:00Z])
    assert due.noncurrent_versions_expired == 1
    assert_version_status("lcncmidnight", "doc.txt", v1, 404)
  end

  test "ExpiredObjectDeleteMarker removes only-marker tombstones" do
    SigV4Request.signed_conn(:put, "/lceodm") |> call()
    :ok = Maxio.Buckets.put_versioning("lceodm", "Enabled", nil)

    delete = SigV4Request.signed_conn(:delete, "/lceodm/ghost.txt") |> call()
    assert delete.status == 204
    {:ok, marker} = Objects.get_metadata("lceodm", "ghost.txt")
    assert marker.is_delete_marker

    :ok =
      BucketConfigs.put("lceodm", :lifecycle, [
        rule(%{"expired_object_delete_marker" => true})
      ])

    summary = Maxio.Lifecycle.run(now: @now)

    assert summary.delete_markers_removed == 1
    assert summary.errors == []
    assert {:error, :not_found} = Objects.get_metadata("lceodm", "ghost.txt")
  end

  test "MFA Delete bucket skips ExpiredObjectDeleteMarker cleanup" do
    SigV4Request.signed_conn(:put, "/lcmfamarker") |> call()
    :ok = Maxio.Buckets.put_versioning("lcmfamarker", "Enabled", "Enabled")

    delete = SigV4Request.signed_conn(:delete, "/lcmfamarker/ghost.txt") |> call()
    assert delete.status == 204
    {:ok, marker} = Objects.get_metadata("lcmfamarker", "ghost.txt")
    assert marker.is_delete_marker

    :ok =
      BucketConfigs.put("lcmfamarker", :lifecycle, [
        rule(%{"expired_object_delete_marker" => true})
      ])

    summary = Maxio.Lifecycle.run(now: @now)

    assert summary.delete_markers_removed == 0
    assert summary.mfa_delete_protected_actions_skipped == 1
    assert summary.errors == []
    assert {:ok, _marker} = Objects.get_metadata("lcmfamarker", "ghost.txt")
  end

  test "AbortIncompleteMultipartUpload removes old pending upload sessions" do
    SigV4Request.signed_conn(:put, "/lcmpu") |> call()
    {:ok, upload} = Multipart.initiate("lcmpu", "parts/old.bin", %{owner: "arn:aws:iam:::root"})
    touch_upload(upload.upload_id, @old)

    :ok =
      BucketConfigs.put("lcmpu", :lifecycle, [
        rule(%{"filter_prefix" => "parts/", "abort_days_after_initiation" => 1})
      ])

    summary = Maxio.Lifecycle.run(now: @now)

    assert summary.multipart_uploads_aborted == 1
    assert summary.errors == []
    assert {:error, :not_found} = Multipart.get_upload("lcmpu", "parts/old.bin", upload.upload_id)
  end

  test "runner ignores zero-day expiration rules from direct config instead of deleting immediately" do
    SigV4Request.signed_conn(:put, "/lczero") |> call()
    SigV4Request.signed_conn(:put, "/lczero/old.txt", body: "old") |> call()
    touch_objects("lczero", @old)

    :ok =
      BucketConfigs.put("lczero", :lifecycle, [
        rule(%{"expiration_days" => 0})
      ])

    summary = Maxio.Lifecycle.run(now: @now)

    assert summary.objects_expired == 0
    assert summary.errors == []

    get = SigV4Request.signed_conn(:get, "/lczero/old.txt") |> call()
    assert get.status == 200
    assert get.resp_body == "old"
  end

  test "runner ignores zero-day or parse-error MPU abort rules from direct config" do
    SigV4Request.signed_conn(:put, "/lcmpusafe") |> call()

    {:ok, zero} =
      Multipart.initiate("lcmpusafe", "parts/zero.bin", %{owner: "arn:aws:iam:::root"})

    {:ok, parse_error} =
      Multipart.initiate("lcmpusafe", "parts/parse.bin", %{owner: "arn:aws:iam:::root"})

    touch_upload(zero.upload_id, @old)
    touch_upload(parse_error.upload_id, @old)

    :ok =
      BucketConfigs.put("lcmpusafe", :lifecycle, [
        rule(%{"filter_prefix" => "parts/zero", "abort_days_after_initiation" => 0}),
        rule(%{
          "filter_prefix" => "parts/parse",
          "abort_days_after_initiation" => 1,
          "parse_errors" => ["invalid_filter_tag"]
        })
      ])

    summary = Maxio.Lifecycle.run(now: @now)

    assert summary.multipart_uploads_aborted == 0
    assert summary.errors == []
    assert {:ok, _} = Multipart.get_upload("lcmpusafe", "parts/zero.bin", zero.upload_id)
    assert {:ok, _} = Multipart.get_upload("lcmpusafe", "parts/parse.bin", parse_error.upload_id)
  end

  test "dry-run reports eligible actions without mutating objects" do
    SigV4Request.signed_conn(:put, "/lcdry") |> call()
    SigV4Request.signed_conn(:put, "/lcdry/old.txt", body: "old") |> call()
    touch_objects("lcdry", @old)

    :ok =
      BucketConfigs.put("lcdry", :lifecycle, [
        rule(%{"expiration_days" => 1})
      ])

    summary = Maxio.Lifecycle.run(now: @now, dry_run: true)

    assert summary.objects_expired == 1
    get = SigV4Request.signed_conn(:get, "/lcdry/old.txt") |> call()
    assert get.status == 200
  end

  defp rule(overrides) do
    Map.merge(
      %{
        "id" => nil,
        "status" => "Enabled",
        "prefix" => nil,
        "filter_prefix" => nil,
        "filter_tags" => [],
        "filter_size_gt" => nil,
        "filter_size_lt" => nil,
        "has_filter" => true,
        "expiration_days" => nil,
        "expiration_date" => nil,
        "expired_object_delete_marker" => nil,
        "noncurrent_days" => nil,
        "newer_noncurrent_versions" => nil,
        "abort_days_after_initiation" => nil,
        "transition_days" => nil,
        "transition_date" => nil,
        "transition_storage_class" => nil,
        "noncurrent_transition_days" => nil,
        "noncurrent_transition_newer_noncurrent_versions" => nil,
        "noncurrent_transition_storage_class" => nil,
        "parse_errors" => []
      },
      overrides
    )
  end

  defp put_object_version!(bucket, key, body) do
    conn = SigV4Request.signed_conn(:put, "/#{bucket}/#{key}", body: body) |> call()
    assert conn.status == 200
    [version_id] = get_resp_header(conn, "x-amz-version-id")
    version_id
  end

  defp assert_version_status(bucket, key, version_id, status) do
    conn =
      SigV4Request.signed_conn(:get, "/#{bucket}/#{key}", query: %{"versionId" => version_id})
      |> call()

    assert conn.status == status
  end

  defp touch_objects(bucket, at) do
    from(o in Object, where: o.bucket_name == ^bucket)
    |> Repo.update_all(set: [inserted_at: at, updated_at: at])
  end

  defp touch_version(bucket, key, version_id, at) do
    from(o in Object,
      where: o.bucket_name == ^bucket and o.key == ^key and o.version_id == ^version_id
    )
    |> Repo.update_all(set: [inserted_at: at, updated_at: at])
  end

  defp touch_latest(bucket, key, at) do
    from(o in Object,
      where: o.bucket_name == ^bucket and o.key == ^key and o.is_latest == true
    )
    |> Repo.update_all(set: [inserted_at: at, updated_at: at])
  end

  defp touch_upload(upload_id, at) do
    from(u in Upload, where: u.upload_id == ^upload_id)
    |> Repo.update_all(set: [inserted_at: at, updated_at: at])
  end
end
