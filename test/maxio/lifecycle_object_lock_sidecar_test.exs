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

  test "sidecar write authority lifecycle transition updates sidecar before PG index", %{
    topo: topo
  } do
    bucket = "lcostrans"
    key = "cold.txt"
    version_id = "null"
    now = ~U[2026-06-11 00:00:00Z]
    old = DateTime.add(now, -3 * 86_400, :second)
    body = "sidecar lifecycle transition"

    {:ok, _bucket} = Buckets.create(bucket, @owner)

    {:ok, %{etag: etag}} =
      Storage.put(
        bucket,
        key,
        version_id,
        [body],
        storage_opts(topo, %{modtime: DateTime.to_unix(old, :nanosecond)})
      )

    {:ok, _object} =
      Objects.put_version_with_id(bucket, key, version_id, %{
        size: byte_size(body),
        etag: etag,
        content_type: "text/plain",
        storage_class: "STANDARD"
      })

    assert {1, _} =
             from(o in Object,
               where: o.bucket_name == ^bucket and o.key == ^key and o.version_id == ^version_id
             )
             |> Repo.update_all(set: [inserted_at: old, updated_at: old])

    :ok =
      BucketConfigs.put(bucket, :lifecycle, [
        lifecycle_rule(%{"transition_days" => 1, "transition_storage_class" => "GLACIER_IR"})
      ])

    summary =
      Maxio.Lifecycle.run(
        now: now,
        transport: InProcess,
        topology: topo,
        authoritative_source: [write: :sidecar]
      )

    assert summary.objects_transitioned == 1
    assert summary.errors == []

    assert %Object{storage_class: "GLACIER_IR"} =
             Maxio.ObjectMeta.get(
               bucket,
               key,
               version_id,
               transport: InProcess,
               topology: topo,
               authoritative_source: [read: :sidecar],
               read_prefer_index: false
             )

    {:ok, indexed} = Objects.get_version(bucket, key, version_id)
    assert indexed.storage_class == "GLACIER_IR"
  end

  # 覆盖 `transition_current_object/6` 锁窗口内的重校验：候选来自 PG 快照，
  # 权威当前版本来自 sidecar；两者版本不一致时必须按 `:skipped` 计（既不迁移、也不报错），
  # 而不是把竞态当成失败或悄悄迁移一个已经不是当前版本的对象（AGENTS.md §3）。
  test "sidecar current-version recheck skips stale PG transition candidates", %{topo: topo} do
    bucket = "lcosstaletrans"
    key = "stale-cold.txt"
    sidecar_version_id = "null"
    now = ~U[2026-06-11 00:00:00Z]
    old = DateTime.add(now, -3 * 86_400, :second)
    body = "stale transition candidate"

    {:ok, _bucket} = Buckets.create(bucket, @owner)

    {:ok, %{etag: etag}} =
      Storage.put(
        bucket,
        key,
        sidecar_version_id,
        [body],
        storage_opts(topo, %{modtime: DateTime.to_unix(old, :nanosecond)})
      )

    {:ok, _object} =
      Objects.put_version_with_id(bucket, key, sidecar_version_id, %{
        size: byte_size(body),
        etag: etag,
        content_type: "text/plain",
        storage_class: "STANDARD"
      })

    # 把 PG 索引行改成另一个 version_id：候选与 sidecar 上的权威当前版本就此错开。
    assert {1, _} =
             from(o in Object,
               where:
                 o.bucket_name == ^bucket and o.key == ^key and
                   o.version_id == ^sidecar_version_id
             )
             |> Repo.update_all(
               set: [version_id: "stale-pg-version", inserted_at: old, updated_at: old]
             )

    :ok =
      BucketConfigs.put(bucket, :lifecycle, [
        lifecycle_rule(%{"transition_days" => 1, "transition_storage_class" => "GLACIER_IR"})
      ])

    summary =
      Maxio.Lifecycle.run(
        now: now,
        transport: InProcess,
        topology: topo,
        authoritative_source: [write: :sidecar]
      )

    assert summary.objects_transitioned == 0
    assert summary.errors == []

    assert %Object{storage_class: "STANDARD"} =
             Maxio.ObjectMeta.get(
               bucket,
               key,
               sidecar_version_id,
               transport: InProcess,
               topology: topo,
               authoritative_source: [read: :sidecar],
               read_prefer_index: false
             )
  end

  # `current_transition_candidate_still_eligible?/5` 把权威读的 `{:error, :not_found}`
  # 归一成 `{:error, :stale_candidate}`——这正是调用方不再重复一层 `:not_found` 的依据。
  # 索引里有行、sidecar 上却没有对象时，必须按候选失效跳过，而不是记成 lifecycle 错误。
  test "sidecar authority treats index-only transition candidates as stale", %{topo: topo} do
    bucket = "lcosorphan"
    key = "index-only.txt"
    now = ~U[2026-06-11 00:00:00Z]
    old = DateTime.add(now, -3 * 86_400, :second)

    {:ok, _bucket} = Buckets.create(bucket, @owner)

    # 只写 PG 索引行，不落任何 sidecar/存储对象。
    {:ok, _object} =
      Objects.put_version_with_id(bucket, key, "null", %{
        size: 12,
        etag: "d41d8cd98f00b204e9800998ecf8427e",
        content_type: "text/plain",
        storage_class: "STANDARD"
      })

    assert {1, _} =
             from(o in Object, where: o.bucket_name == ^bucket and o.key == ^key)
             |> Repo.update_all(set: [inserted_at: old, updated_at: old])

    :ok =
      BucketConfigs.put(bucket, :lifecycle, [
        lifecycle_rule(%{"transition_days" => 1, "transition_storage_class" => "GLACIER_IR"})
      ])

    summary =
      Maxio.Lifecycle.run(
        now: now,
        transport: InProcess,
        topology: topo,
        authoritative_source: [write: :sidecar]
      )

    assert summary.objects_transitioned == 0
    assert summary.errors == []

    {:ok, indexed} = Objects.get_version(bucket, key, "null")
    assert indexed.storage_class == "STANDARD"
  end

  # `transition_noncurrent_version/6` 的同款重校验：PG 索引认为 v1 已是历史版本，
  # 但 sidecar 上的权威当前版本仍然是 v1 —— 候选已经失效，必须按 `:skipped` 计。
  test "sidecar current-version recheck skips stale PG noncurrent transition candidates", %{
    topo: topo
  } do
    bucket = "lcosstalenc"
    key = "versioned-cold.txt"
    now = ~U[2026-06-11 00:00:00Z]
    old = DateTime.add(now, -5 * 86_400, :second)
    body = "stale noncurrent transition candidate"

    {:ok, _bucket} = Buckets.create(bucket, @owner)

    {:ok, %{etag: etag}} =
      Storage.put(
        bucket,
        key,
        "v1",
        [body],
        storage_opts(topo, %{modtime: DateTime.to_unix(old, :nanosecond)})
      )

    {:ok, _v1} =
      Objects.put_version_with_id(bucket, key, "v1", %{
        size: byte_size(body),
        etag: etag,
        content_type: "text/plain",
        storage_class: "STANDARD"
      })

    # 只往 PG 写第二个版本行：sidecar 上依然只有 v1，且 v1 仍是权威当前版本。
    {:ok, _v2} =
      Objects.put_version_with_id(bucket, key, "v2", %{
        size: byte_size(body),
        etag: etag,
        content_type: "text/plain",
        storage_class: "STANDARD"
      })

    assert {2, _} =
             from(o in Object, where: o.bucket_name == ^bucket and o.key == ^key)
             |> Repo.update_all(set: [inserted_at: old, updated_at: old])

    :ok =
      BucketConfigs.put(bucket, :lifecycle, [
        lifecycle_rule(%{
          "noncurrent_transition_days" => 1,
          "noncurrent_transition_storage_class" => "GLACIER_IR"
        })
      ])

    summary =
      Maxio.Lifecycle.run(
        now: now,
        transport: InProcess,
        topology: topo,
        authoritative_source: [write: :sidecar]
      )

    assert summary.noncurrent_versions_transitioned == 0
    assert summary.errors == []

    assert %Object{storage_class: "STANDARD"} =
             Maxio.ObjectMeta.get(
               bucket,
               key,
               "v1",
               transport: InProcess,
               topology: topo,
               authoritative_source: [read: :sidecar],
               read_prefer_index: false
             )
  end

  defp storage_opts(topo, meta_overrides \\ %{}) do
    [
      transport: InProcess,
      topology: topo,
      object_meta:
        Map.merge(
          %{
            content_type: "text/plain",
            tags: %{},
            sse: nil,
            acl_canned: "private",
            storage_class: "STANDARD",
            user_metadata: %{}
          },
          meta_overrides
        )
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
