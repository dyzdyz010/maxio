defmodule Maxio.LifecycleObjectLockSidecarTest do
  use Maxio.DataCase, async: false

  import Ecto.Query

  alias Maxio.BucketConfigs
  alias Maxio.Buckets
  alias Maxio.Cluster.Paths
  alias Maxio.Cluster.Transport.InProcess
  alias Maxio.ObjectLockSidecar
  alias Maxio.Objects
  alias Maxio.Objects.Object
  alias Maxio.Repo
  alias Maxio.Storage

  @owner "arn:aws:iam:::root"

  setup do
    InProcess.setup!()

    prev_backend = Application.get_env(:maxio, :storage_backend)
    Application.put_env(:maxio, :storage_backend, Maxio.Storage.Distributed)

    eps =
      for i <- 0..2,
          do:
            {:"lcos#{i}",
             Path.join(System.tmp_dir!(), "lcos_d#{i}_#{System.unique_integer([:positive])}")}

    topo = %{
      data_shards: 2,
      parity_shards: 1,
      block_size: 1024,
      sets: %{0 => %{id: 0, endpoints: eps}},
      set_ids: [0]
    }

    on_exit(fn ->
      if prev_backend,
        do: Application.put_env(:maxio, :storage_backend, prev_backend),
        else: Application.delete_env(:maxio, :storage_backend)

      Enum.each(eps, fn {_node, drive} -> File.rm_rf(drive) end)
    end)

    {:ok, eps: eps, topo: topo}
  end

  test "sidecar-only legal hold blocks lifecycle when PG lock fields are stale", %{
    eps: eps,
    topo: topo
  } do
    bucket = "lcoslock"
    key = "doc.txt"
    version_id = "null"
    now = ~U[2026-06-11 00:00:00Z]
    old = DateTime.add(now, -3 * 86_400, :second)
    body = "sidecar object lock is authoritative"

    {:ok, _bucket} = Buckets.create(bucket, @owner)
    {:ok, %{etag: etag}} = Storage.put(bucket, key, version_id, [body], storage_opts(topo))

    {:ok, _object} =
      Objects.put_version_with_id(bucket, key, version_id, %{
        size: byte_size(body),
        etag: etag,
        content_type: "text/plain"
      })

    assert {:ok, _generation} =
             ObjectLockSidecar.update(
               bucket,
               key,
               version_id,
               %{object_lock_legal_hold: "ON"},
               storage_opts(topo)
             )

    assert {1, _} =
             from(o in Object,
               where: o.bucket_name == ^bucket and o.key == ^key and o.version_id == ^version_id
             )
             |> Repo.update_all(
               set: [
                 inserted_at: old,
                 updated_at: old,
                 object_lock_mode: nil,
                 object_lock_retain_until: nil,
                 object_lock_legal_hold: nil
               ]
             )

    :ok =
      BucketConfigs.put(bucket, :lifecycle, [
        lifecycle_rule(%{"expiration_date" => "2026-06-10T00:00:00Z"})
      ])

    summary =
      Maxio.Lifecycle.run(
        now: now,
        transport: InProcess,
        topology: topo,
        authoritative_source: [write: :sidecar]
      )

    assert summary.objects_expired == 0
    assert summary.object_lock_protected_actions_skipped == 1
    assert summary.errors == []

    for {_node, drive} <- eps do
      assert File.regular?(sidecar_path(drive, bucket, key, version_id))
    end
  end

  test "sidecar current-version recheck skips stale PG lifecycle candidates", %{
    eps: eps,
    topo: topo
  } do
    bucket = "lcosstale"
    key = "fresh.txt"
    version_id = "null"
    now = ~U[2026-06-11 00:00:00Z]
    old = DateTime.add(now, -3 * 86_400, :second)
    body = "fresh on sidecar but stale in PG"

    {:ok, _bucket} = Buckets.create(bucket, @owner)
    {:ok, %{etag: etag}} = Storage.put(bucket, key, version_id, [body], storage_opts(topo))

    {:ok, _object} =
      Objects.put_version_with_id(bucket, key, version_id, %{
        size: byte_size(body),
        etag: etag,
        content_type: "text/plain"
      })

    assert {1, _} =
             from(o in Object,
               where: o.bucket_name == ^bucket and o.key == ^key and o.version_id == ^version_id
             )
             |> Repo.update_all(set: [inserted_at: old, updated_at: old])

    :ok =
      BucketConfigs.put(bucket, :lifecycle, [
        lifecycle_rule(%{"expiration_days" => 1})
      ])

    summary =
      Maxio.Lifecycle.run(
        now: now,
        transport: InProcess,
        topology: topo,
        authoritative_source: [write: :sidecar]
      )

    assert summary.objects_expired == 0
    assert summary.object_lock_protected_actions_skipped == 0
    assert summary.errors == []

    for {_node, drive} <- eps do
      assert File.regular?(sidecar_path(drive, bucket, key, version_id))
    end
  end

  defp storage_opts(topo) do
    [
      transport: InProcess,
      topology: topo,
      object_meta: %{
        content_type: "text/plain",
        tags: %{},
        sse: nil,
        acl_canned: "private",
        storage_class: "STANDARD",
        user_metadata: %{}
      }
    ]
  end

  defp sidecar_path(drive, bucket, key, version_id) do
    {:ok, rel} = Paths.object_rel(bucket, key, version_id)
    Path.join([drive, rel, "meta.json"])
  end

  defp lifecycle_rule(overrides) do
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
end
