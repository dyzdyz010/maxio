defmodule Maxio.ObjectLockMetadataSidecarTest do
  use Maxio.DataCase, async: false

  import Ecto.Query
  import ExUnit.CaptureLog

  alias Maxio.Buckets
  alias Maxio.Cluster.Transport.InProcess
  alias Maxio.ObjectLockMetadata
  alias Maxio.ObjectLockSidecar
  alias Maxio.Objects
  alias Maxio.Objects.Object
  alias Maxio.Repo
  alias Maxio.Storage

  @owner "arn:aws:iam:::root"
  @now ~U[2026-07-10 00:00:00Z]
  @compliance_until ~U[2090-01-01 00:00:00Z]

  setup do
    InProcess.setup!()

    previous_backend = Application.get_env(:maxio, :storage_backend)
    Application.put_env(:maxio, :storage_backend, Maxio.Storage.Distributed)

    endpoints =
      for index <- 0..2 do
        node = :"object-lock-meta-#{index}"

        drive =
          Path.join(
            System.tmp_dir!(),
            "object_lock_meta_#{index}_#{System.unique_integer([:positive])}"
          )

        {node, drive}
      end

    topology = %{
      data_shards: 2,
      parity_shards: 1,
      block_size: 1024,
      sets: %{0 => %{id: 0, endpoints: endpoints}},
      set_ids: [0]
    }

    on_exit(fn ->
      if previous_backend do
        Application.put_env(:maxio, :storage_backend, previous_backend)
      else
        Application.delete_env(:maxio, :storage_backend)
      end

      Enum.each(endpoints, fn {_node, drive} -> File.rm_rf(drive) end)
    end)

    {:ok, topology: topology}
  end

  test "sidecar retention and legal-hold updates preserve each other in both orders", %{
    topology: topology
  } do
    bucket = "lock-metadata-order"
    {:ok, _bucket} = Buckets.create(bucket, @owner)

    retention_first = "retention-first.txt"
    put_sidecar_object(bucket, retention_first, "null", topology)

    assert {:ok, _object} =
             ObjectLockMetadata.put_retention(
               bucket,
               retention_first,
               "null",
               compliance_attrs(),
               mutation_opts(topology)
             )

    assert {:ok, _object} =
             ObjectLockMetadata.put_legal_hold(
               bucket,
               retention_first,
               "null",
               %{object_lock_legal_hold: "ON"},
               mutation_opts(topology)
             )

    assert_lock_view(bucket, retention_first, "null", topology)

    legal_hold_first = "legal-hold-first.txt"
    put_sidecar_object(bucket, legal_hold_first, "null", topology)

    assert {:ok, _object} =
             ObjectLockMetadata.put_legal_hold(
               bucket,
               legal_hold_first,
               "null",
               %{object_lock_legal_hold: "ON"},
               mutation_opts(topology)
             )

    assert {:ok, _object} =
             ObjectLockMetadata.put_retention(
               bucket,
               legal_hold_first,
               "null",
               compliance_attrs(),
               mutation_opts(topology)
             )

    assert_lock_view(bucket, legal_hold_first, "null", topology)
  end

  test "sidecar write authority mutates an explicit version absent from the PG index", %{
    topology: topology
  } do
    bucket = "lock-sidecar-only"
    key = "sidecar-only.txt"
    version_id = "01J00000000000000000000000"

    {:ok, _bucket} = Buckets.create(bucket, @owner)
    put_sidecar_object(bucket, key, version_id, topology, index?: false)

    assert {:ok, %Object{version_id: ^version_id, object_lock_legal_hold: "ON"}} =
             ObjectLockMetadata.put_legal_hold(
               bucket,
               key,
               version_id,
               %{object_lock_legal_hold: "ON"},
               mutation_opts(topology)
             )

    assert {:error, :not_found} = Objects.get_version(bucket, key, version_id)

    assert %Object{version_id: ^version_id, object_lock_legal_hold: "ON"} =
             read_sidecar(bucket, key, version_id, topology)
  end

  test "sidecar write authority resolves and mutates the latest version without versionId", %{
    topology: topology
  } do
    bucket = "lock-sidecar-latest"
    key = "latest.txt"

    {:ok, _bucket} = Buckets.create(bucket, @owner)
    put_sidecar_object(bucket, key, "null", topology)

    assert {:ok, %Object{version_id: "null", object_lock_legal_hold: "ON"}} =
             ObjectLockMetadata.put_legal_hold(
               bucket,
               key,
               nil,
               %{object_lock_legal_hold: "ON"},
               mutation_opts(topology)
             )

    assert %Object{version_id: "null", object_lock_legal_hold: "ON"} =
             read_sidecar(bucket, key, nil, topology)
  end

  test "unavailable sidecar endpoints return read quorum errors for explicit and latest mutations",
       %{
         topology: topology
       } do
    bucket = "lock-sidecar-unavailable"
    explicit_key = "explicit.txt"
    latest_key = "latest.txt"
    explicit_version = "01J00000000000000000000001"

    {:ok, _bucket} = Buckets.create(bucket, @owner)
    put_sidecar_object(bucket, explicit_key, explicit_version, topology)
    put_sidecar_object(bucket, latest_key, "null", topology)

    assert {:error, :not_found} =
             ObjectLockSidecar.update(
               bucket,
               "genuinely-missing.txt",
               explicit_version,
               %{object_lock_legal_hold: "ON"},
               mutation_opts(topology)
             )

    topology.sets[0].endpoints
    |> Enum.each(fn {node, _drive} -> InProcess.set_down(node) end)

    assert {:error, :slow_down_read} =
             ObjectLockMetadata.put_legal_hold(
               bucket,
               explicit_key,
               explicit_version,
               %{object_lock_legal_hold: "ON"},
               mutation_opts(topology)
             )

    assert {:error, :slow_down_read} =
             ObjectLockMetadata.put_legal_hold(
               bucket,
               latest_key,
               nil,
               %{object_lock_legal_hold: "ON"},
               mutation_opts(topology)
             )

    assert {:error, :read_quorum} =
             ObjectLockSidecar.update(
               bucket,
               explicit_key,
               explicit_version,
               %{object_lock_legal_hold: "ON"},
               mutation_opts(topology)
             )
  end

  test "stale PG lock fields cannot authorize shortening sidecar COMPLIANCE retention", %{
    topology: topology
  } do
    bucket = "lock-compliance-stale-index"
    key = "audit.txt"
    version_id = "null"

    {:ok, _bucket} = Buckets.create(bucket, @owner)
    put_sidecar_object(bucket, key, version_id, topology)

    assert {:ok, _object} =
             ObjectLockMetadata.put_retention(
               bucket,
               key,
               version_id,
               compliance_attrs(),
               mutation_opts(topology)
             )

    assert {1, _rows} =
             from(object in Object,
               where:
                 object.bucket_name == ^bucket and object.key == ^key and
                   object.version_id == ^version_id
             )
             |> Repo.update_all(set: [object_lock_mode: nil, object_lock_retain_until: nil])

    shorter = %{
      object_lock_mode: "COMPLIANCE",
      object_lock_retain_until: ~U[2089-01-01 00:00:00Z]
    }

    assert {:error, :locked} =
             ObjectLockMetadata.put_retention(
               bucket,
               key,
               version_id,
               shorter,
               mutation_opts(topology, bypass_governance?: true)
             )

    assert %Object{
             object_lock_mode: "COMPLIANCE",
             object_lock_retain_until: @compliance_until
           } = read_sidecar(bucket, key, version_id, topology)
  end

  test "a raising PG index updater cannot fail a durable sidecar mutation", %{
    topology: topology
  } do
    bucket = "lock-index-updater-raise"
    key = "durable.txt"
    version_id = "null"
    parent = self()

    {:ok, _bucket} = Buckets.create(bucket, @owner)
    put_sidecar_object(bucket, key, version_id, topology)

    raising_updater = fn _bucket, _key, _version_id, _attrs, _generation ->
      raise "injected object lock index failure"
    end

    log =
      capture_log(fn ->
        result =
          ObjectLockMetadata.put_legal_hold(
            bucket,
            key,
            version_id,
            %{object_lock_legal_hold: "ON"},
            mutation_opts(topology, object_lock_index_updater: raising_updater)
          )

        send(parent, {:mutation_result, result})
      end)

    assert_receive {:mutation_result,
                    {:ok, %Object{version_id: ^version_id, object_lock_legal_hold: "ON"}}}

    assert log =~ "pg index object lock update failed"
    assert log =~ "injected object lock index failure"

    assert {:ok, %Object{object_lock_legal_hold: nil}} =
             Objects.get_version(bucket, key, version_id)

    assert %Object{object_lock_legal_hold: "ON"} =
             read_sidecar(bucket, key, version_id, topology)
  end

  defp put_sidecar_object(bucket, key, version_id, topology, opts \\ []) do
    body = "sidecar object lock metadata"

    assert {:ok, %{etag: etag}} =
             Storage.put(bucket, key, version_id, [body], storage_opts(topology))

    if Keyword.get(opts, :index?, true) do
      assert {:ok, _object} =
               Objects.put_version_with_id(bucket, key, version_id, %{
                 size: byte_size(body),
                 etag: etag,
                 content_type: "text/plain"
               })
    end

    :ok
  end

  defp compliance_attrs do
    %{
      object_lock_mode: "COMPLIANCE",
      object_lock_retain_until: @compliance_until
    }
  end

  defp assert_lock_view(bucket, key, version_id, topology) do
    assert %Object{
             object_lock_mode: "COMPLIANCE",
             object_lock_retain_until: @compliance_until,
             object_lock_legal_hold: "ON"
           } = read_sidecar(bucket, key, version_id, topology)
  end

  defp read_sidecar(bucket, key, version_id, topology) do
    Maxio.ObjectMeta.get(
      bucket,
      key,
      version_id,
      transport: InProcess,
      topology: topology,
      authoritative_source: [read: :sidecar],
      read_prefer_index: false
    )
  end

  defp mutation_opts(topology, extra \\ []) do
    Keyword.merge(
      [
        transport: InProcess,
        topology: topology,
        authoritative_source: [write: :sidecar],
        now: @now
      ],
      extra
    )
  end

  defp storage_opts(topology) do
    [
      transport: InProcess,
      topology: topology,
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
end
