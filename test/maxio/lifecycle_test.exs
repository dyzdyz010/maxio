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

  test "Object Lock skips unversioned current Expiration hard delete" do
    SigV4Request.signed_conn(:put, "/lclockexp") |> call()
    SigV4Request.signed_conn(:put, "/lclockexp/locked.txt", body: "locked") |> call()
    touch_latest("lclockexp", "locked.txt", @old)
    lock_version!("lclockexp", "locked.txt", "null", %{object_lock_legal_hold: "ON"})

    :ok =
      BucketConfigs.put("lclockexp", :lifecycle, [
        rule(%{"filter_prefix" => "", "expiration_days" => 1})
      ])

    summary = Maxio.Lifecycle.run(now: @now)

    assert summary.objects_expired == 0
    assert summary.object_lock_protected_actions_skipped == 1
    assert summary.errors == []

    get = SigV4Request.signed_conn(:get, "/lclockexp/locked.txt") |> call()
    assert get.status == 200
    assert get.resp_body == "locked"
  end

  test "Object Lock skips suspended current Expiration that would replace locked null version" do
    SigV4Request.signed_conn(:put, "/lclocksusp") |> call()
    :ok = Maxio.Buckets.put_versioning("lclocksusp", "Suspended", nil)
    SigV4Request.signed_conn(:put, "/lclocksusp/doc.txt", body: "null-live") |> call()
    touch_latest("lclocksusp", "doc.txt", @old)
    lock_version!("lclocksusp", "doc.txt", "null", %{object_lock_legal_hold: "ON"})

    :ok =
      BucketConfigs.put("lclocksusp", :lifecycle, [
        rule(%{"filter_prefix" => "", "expiration_days" => 1})
      ])

    summary = Maxio.Lifecycle.run(now: @now)

    assert summary.objects_expired == 0
    assert summary.object_lock_protected_actions_skipped == 1
    assert summary.errors == []

    current = SigV4Request.signed_conn(:get, "/lclocksusp/doc.txt") |> call()
    assert current.status == 200
    assert current.resp_body == "null-live"

    {:ok, object} = Objects.get_metadata("lclocksusp", "doc.txt")
    refute object.is_delete_marker
  end

  test "Object Lock does not block versioning-enabled current Expiration delete marker insertion" do
    SigV4Request.signed_conn(:put, "/lclockenabled") |> call()
    :ok = Maxio.Buckets.put_versioning("lclockenabled", "Enabled", nil)

    version_id = put_object_version!("lclockenabled", "doc.txt", "v1")
    touch_latest("lclockenabled", "doc.txt", @old)
    lock_version!("lclockenabled", "doc.txt", version_id, %{object_lock_legal_hold: "ON"})

    :ok =
      BucketConfigs.put("lclockenabled", :lifecycle, [
        rule(%{"filter_prefix" => "", "expiration_days" => 1})
      ])

    summary = Maxio.Lifecycle.run(now: @now)

    assert summary.objects_expired == 1
    assert summary.object_lock_protected_actions_skipped == 0
    assert summary.errors == []

    latest = SigV4Request.signed_conn(:get, "/lclockenabled/doc.txt") |> call()
    assert latest.status == 404

    old =
      SigV4Request.signed_conn(:get, "/lclockenabled/doc.txt",
        query: %{"versionId" => version_id}
      )
      |> call()

    assert old.status == 200
    assert old.resp_body == "v1"
  end

  test "Object Lock skips NoncurrentVersionExpiration permanent delete" do
    SigV4Request.signed_conn(:put, "/lclocknoncur") |> call()
    :ok = Maxio.Buckets.put_versioning("lclocknoncur", "Enabled", nil)

    v1 = put_object_version!("lclocknoncur", "doc.txt", "v1")
    _v2 = put_object_version!("lclocknoncur", "doc.txt", "v2")

    touch_version("lclocknoncur", "doc.txt", v1, DateTime.add(@now, -10 * 86_400, :second))
    touch_latest("lclocknoncur", "doc.txt", DateTime.add(@now, -1 * 86_400, :second))
    lock_version!("lclocknoncur", "doc.txt", v1, %{object_lock_legal_hold: "ON"})

    :ok =
      BucketConfigs.put("lclocknoncur", :lifecycle, [
        rule(%{"filter_prefix" => "", "noncurrent_days" => 1})
      ])

    summary = Maxio.Lifecycle.run(now: @now)

    assert summary.noncurrent_versions_expired == 0
    assert summary.object_lock_protected_actions_skipped == 1
    assert summary.errors == []
    assert_version_status("lclocknoncur", "doc.txt", v1, 200)
  end

  test "Object Lock active retention skips lifecycle delete and expired retention resumes it" do
    SigV4Request.signed_conn(:put, "/lclockret") |> call()
    SigV4Request.signed_conn(:put, "/lclockret/compliance.txt", body: "compliance") |> call()
    SigV4Request.signed_conn(:put, "/lclockret/governance.txt", body: "governance") |> call()
    touch_objects("lclockret", @old)

    lock_version!("lclockret", "compliance.txt", "null", %{
      object_lock_mode: "COMPLIANCE",
      object_lock_retain_until: DateTime.add(@now, 86_400, :second)
    })

    lock_version!("lclockret", "governance.txt", "null", %{
      object_lock_mode: "GOVERNANCE",
      object_lock_retain_until: DateTime.add(@now, 86_400, :second)
    })

    :ok =
      BucketConfigs.put("lclockret", :lifecycle, [
        rule(%{"filter_prefix" => "", "expiration_days" => 1})
      ])

    blocked = Maxio.Lifecycle.run(now: @now)

    assert blocked.objects_expired == 0
    assert blocked.object_lock_protected_actions_skipped == 2
    assert blocked.errors == []

    lock_version!("lclockret", "compliance.txt", "null", %{
      object_lock_mode: "COMPLIANCE",
      object_lock_retain_until: DateTime.add(@now, -86_400, :second)
    })

    lock_version!("lclockret", "governance.txt", "null", %{
      object_lock_mode: "GOVERNANCE",
      object_lock_retain_until: DateTime.add(@now, -86_400, :second)
    })

    expired = Maxio.Lifecycle.run(now: @now)

    assert expired.objects_expired == 2
    assert expired.object_lock_protected_actions_skipped == 0
    assert expired.errors == []
    assert (SigV4Request.signed_conn(:get, "/lclockret/compliance.txt") |> call()).status == 404
    assert (SigV4Request.signed_conn(:get, "/lclockret/governance.txt") |> call()).status == 404
  end

  test "Transition changes current object storage class without changing bytes or last modified" do
    SigV4Request.signed_conn(:put, "/lctrans") |> call()

    SigV4Request.signed_conn(:put, "/lctrans/cold/doc.txt",
      body: "transition me",
      headers: [{"x-amz-storage-class", "STANDARD_IA"}]
    )
    |> call()

    written_at = DateTime.add(@now, -3 * 86_400, :second)
    touch_latest("lctrans", "cold/doc.txt", written_at)

    :ok =
      BucketConfigs.put("lctrans", :lifecycle, [
        rule(%{
          "filter_prefix" => "cold/",
          "transition_days" => 1,
          "transition_storage_class" => "GLACIER_IR"
        })
      ])

    summary = Maxio.Lifecycle.run(now: @now)

    assert summary.objects_transitioned == 1
    assert summary.unsupported_rules == 0
    assert summary.errors == []

    {:ok, object} = Objects.get_metadata("lctrans", "cold/doc.txt")
    assert object.storage_class == "GLACIER_IR"
    assert DateTime.compare(object.updated_at, written_at) == :eq

    get = SigV4Request.signed_conn(:get, "/lctrans/cold/doc.txt") |> call()
    assert get.status == 200
    assert get.resp_body == "transition me"
    assert get_resp_header(get, "x-amz-storage-class") == ["GLACIER_IR"]

    again = Maxio.Lifecycle.run(now: @now)
    assert again.objects_transitioned == 0
    assert again.errors == []
  end

  test "same-day versioned expiration creates no delete marker before eligible transition" do
    SigV4Request.signed_conn(:put, "/lcprec") |> call()
    :ok = Maxio.Buckets.put_versioning("lcprec", "Enabled", nil)
    version_id = put_object_version!("lcprec", "doc.txt", "v1")
    touch_latest("lcprec", "doc.txt", @old)

    :ok =
      BucketConfigs.put("lcprec", :lifecycle, [
        rule(%{
          "expiration_days" => 1,
          "transition_days" => 1,
          "transition_storage_class" => "GLACIER_IR"
        })
      ])

    summary = Maxio.Lifecycle.run(now: @now)

    assert summary.objects_transitioned == 1
    assert summary.objects_expired == 0
    {:ok, object} = Objects.get_version("lcprec", "doc.txt", version_id)
    assert object.storage_class == "GLACIER_IR"
    assert object.is_latest
    assert object.is_delete_marker == false
  end

  test "Transition Days=0 executes for immediate Glacier-class rules" do
    SigV4Request.signed_conn(:put, "/lczero") |> call()
    SigV4Request.signed_conn(:put, "/lczero/now.txt", body: "zero") |> call()
    touch_latest("lczero", "now.txt", @now)

    :ok =
      BucketConfigs.put("lczero", :lifecycle, [
        rule(%{"transition_days" => 0, "transition_storage_class" => "GLACIER"})
      ])

    summary = Maxio.Lifecycle.run(now: @now)

    assert summary.objects_transitioned == 1
    {:ok, object} = Objects.get_metadata("lczero", "now.txt")
    assert object.storage_class == "GLACIER"
  end

  test "NoncurrentVersionTransition changes old version storage class and preserves version" do
    SigV4Request.signed_conn(:put, "/lcnct") |> call()
    :ok = Maxio.Buckets.put_versioning("lcnct", "Enabled", nil)

    v1 = put_object_version!("lcnct", "doc.txt", "v1")
    v2 = put_object_version!("lcnct", "doc.txt", "v2")
    v3 = put_object_version!("lcnct", "doc.txt", "v3")
    _v4 = put_object_version!("lcnct", "doc.txt", "v4")

    v1_written_at = DateTime.add(@now, -10 * 86_400, :second)
    touch_version("lcnct", "doc.txt", v1, v1_written_at)
    touch_version("lcnct", "doc.txt", v2, DateTime.add(@now, -5 * 86_400, :second))
    touch_version("lcnct", "doc.txt", v3, DateTime.add(@now, -2 * 86_400, :second))
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

    assert summary.unsupported_rules == 0
    assert summary.noncurrent_versions_transitioned == 1
    assert summary.noncurrent_versions_expired == 0
    assert summary.errors == []

    {:ok, transitioned} = Objects.get_version("lcnct", "doc.txt", v1)
    {:ok, retained} = Objects.get_version("lcnct", "doc.txt", v2)
    assert transitioned.storage_class == "GLACIER"
    assert DateTime.compare(transitioned.updated_at, v1_written_at) == :eq
    assert retained.storage_class == "STANDARD"
    assert_version_status("lcnct", "doc.txt", v1, 403)
    assert_version_status("lcnct", "doc.txt", v2, 200)
  end

  test "NoncurrentVersionTransition skips Object Lock protected versions" do
    SigV4Request.signed_conn(:put, "/lcnctlock") |> call()
    :ok = Maxio.Buckets.put_versioning("lcnctlock", "Enabled", nil)

    v1 = put_object_version!("lcnctlock", "doc.txt", "v1")
    _v2 = put_object_version!("lcnctlock", "doc.txt", "v2")
    touch_version("lcnctlock", "doc.txt", v1, DateTime.add(@now, -10 * 86_400, :second))
    touch_latest("lcnctlock", "doc.txt", DateTime.add(@now, -1 * 86_400, :second))

    lock_version!("lcnctlock", "doc.txt", v1, %{
      object_lock_mode: "COMPLIANCE",
      object_lock_retain_until: DateTime.add(@now, 86_400, :second)
    })

    :ok =
      BucketConfigs.put("lcnctlock", :lifecycle, [
        rule(%{
          "noncurrent_transition_days" => 1,
          "noncurrent_transition_storage_class" => "GLACIER"
        })
      ])

    summary = Maxio.Lifecycle.run(now: @now)

    assert summary.noncurrent_versions_transitioned == 0
    assert summary.object_lock_protected_actions_skipped == 1
    {:ok, object} = Objects.get_version("lcnctlock", "doc.txt", v1)
    assert object.storage_class == "STANDARD"
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

  defp lock_version!(bucket, key, version_id, attrs) do
    assert {:ok, _object} = Objects.put_object_lock(bucket, key, version_id, attrs)
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
