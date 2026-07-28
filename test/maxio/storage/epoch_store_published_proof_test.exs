defmodule Maxio.Storage.EpochStorePublishedProofTest do
  use ExUnit.Case, async: true

  alias Maxio.Cluster.Paths
  alias Maxio.Storage.{EpochStore, ObjectEpoch, PublishedProof}

  @bucket "epoch-proof-test"
  @id_a "00000000-0000-0000-0000-00000000000a"
  @id_b "00000000-0000-0000-0000-00000000000b"
  @sidecar_limit 16 * 1024 * 1024

  setup do
    dir = Path.join(System.tmp_dir!(), "maxio_epoch_proof_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    {:ok, dir: dir}
  end

  test "exact published epoch, raw sidecar and regular FS part verify", %{dir: dir} do
    site = published_site!(dir, "fs-exact", "payload")

    assert {:ok,
            {:verified,
             %{
               "status" => "verified",
               "required" => 1,
               "verified" => 1,
               "observed_owned" => 1,
               "unavailable" => 0,
               "degraded" => []
             }}} = EpochStore.verify_mutation(dir, site.request)
  end

  test "raw sidecar byte changes fail even when decoded durable core is unchanged", %{dir: dir} do
    site = published_site!(dir, "raw-divergence", "payload")
    File.write!(site.meta_path, site.raw_meta <> "\n")

    assert_proof_failure(:mismatch, EpochStore.verify_mutation(dir, site.request))
  end

  test "request fingerprint must match epoch even when final still matches epoch", %{dir: dir} do
    site = published_site!(dir, "request-epoch-divergence", "payload")
    different = ObjectEpoch.fingerprint("different-etag", byte_size(site.part), site.raw_meta)

    assert_proof_failure(
      :mismatch,
      EpochStore.verify_mutation(dir, %{site.request | expected_fingerprint: different})
    )
  end

  test "missing, malformed, symlink, non-regular and oversized sidecars fail closed", %{dir: dir} do
    missing = published_site!(dir, "meta-missing", "payload")
    File.rm!(missing.meta_path)
    assert_proof_failure(:corrupt, EpochStore.verify_mutation(dir, missing.request))

    malformed = published_site!(dir, "meta-malformed", "payload")
    File.write!(malformed.meta_path, "{not-json")
    assert_proof_failure(:corrupt, EpochStore.verify_mutation(dir, malformed.request))

    malformed_core = published_site!(dir, "meta-malformed-core", "payload")
    File.write!(malformed_core.meta_path, Jason.encode!(%{"format" => "maxio/2"}))
    assert_proof_failure(:corrupt, EpochStore.verify_mutation(dir, malformed_core.request))

    non_regular = published_site!(dir, "meta-directory", "payload")
    File.rm!(non_regular.meta_path)
    File.mkdir_p!(non_regular.meta_path)
    assert_proof_failure(:corrupt, EpochStore.verify_mutation(dir, non_regular.request))

    symlink = published_site!(dir, "meta-symlink", "payload")

    lstat = fn path ->
      if path == symlink.meta_path,
        do: {:ok, %File.Stat{type: :symlink}},
        else: File.lstat(path)
    end

    assert_proof_failure(
      :corrupt,
      EpochStore.verify_mutation(dir, symlink.request, lstat: lstat)
    )

    oversized = published_site!(dir, "meta-oversized", "payload")
    File.write!(oversized.meta_path, :binary.copy("x", @sidecar_limit + 1))
    assert_proof_failure(:corrupt, EpochStore.verify_mutation(dir, oversized.request))
  end

  test "missing, non-regular and wrong-size FS parts fail closed", %{dir: dir} do
    missing = published_site!(dir, "part-missing", "payload")
    File.rm!(missing.part_path)
    assert_proof_failure(:corrupt, EpochStore.verify_mutation(dir, missing.request))

    non_regular = published_site!(dir, "part-directory", "payload")
    File.rm!(non_regular.part_path)
    File.mkdir_p!(non_regular.part_path)
    assert_proof_failure(:corrupt, EpochStore.verify_mutation(dir, non_regular.request))

    truncated = published_site!(dir, "part-truncated", "payload")
    File.write!(truncated.part_path, "short")
    assert_proof_failure(:mismatch, EpochStore.verify_mutation(dir, truncated.request))

    extended = published_site!(dir, "part-extended", "payload")
    File.write!(extended.part_path, truncated.part <> "extra")
    assert_proof_failure(:mismatch, EpochStore.verify_mutation(dir, extended.request))
  end

  test "shard proof selects one exact ordinal and validates its physical size", %{dir: dir} do
    good =
      published_site!(dir, "shard-exact", "abc",
        layout: %{kind: "shard", index: 0},
        shards: [
          %{"drive" => 0, "shard_file_size" => 3, "block_hashes" => []},
          %{"drive" => 1, "shard_file_size" => 4, "block_hashes" => []}
        ]
      )

    assert {:ok, {:verified, _summary}} = EpochStore.verify_mutation(dir, good.request)

    missing =
      published_site!(dir, "shard-missing-ordinal", "abc",
        layout: %{kind: "shard", index: 0},
        shards: [%{"drive" => 1, "shard_file_size" => 3, "block_hashes" => []}]
      )

    assert_proof_failure(:corrupt, EpochStore.verify_mutation(dir, missing.request))

    duplicate =
      published_site!(dir, "shard-duplicate-ordinal", "abc",
        layout: %{kind: "shard", index: 0},
        shards: [
          %{"drive" => 0, "shard_file_size" => 3, "block_hashes" => []},
          %{"drive" => 0, "shard_file_size" => 3, "block_hashes" => []}
        ]
      )

    assert_proof_failure(:corrupt, EpochStore.verify_mutation(dir, duplicate.request))

    invalid =
      published_site!(dir, "shard-invalid-ordinal", "abc",
        layout: %{kind: "shard", index: 0},
        shards: [%{"drive" => "0", "shard_file_size" => 3, "block_hashes" => []}]
      )

    assert_proof_failure(:corrupt, EpochStore.verify_mutation(dir, invalid.request))

    reordered =
      published_site!(dir, "shard-reordered", "abc",
        layout: %{kind: "shard", index: 0},
        shards: [
          %{"drive" => 1, "shard_file_size" => 3, "block_hashes" => []},
          %{"drive" => 0, "shard_file_size" => 3, "block_hashes" => []}
        ]
      )

    assert_proof_failure(:corrupt, EpochStore.verify_mutation(dir, reordered.request))

    wrong_size =
      published_site!(dir, "shard-wrong-size", "abc",
        layout: %{kind: "shard", index: 0},
        shards: [%{"drive" => 0, "shard_file_size" => 4, "block_hashes" => []}]
      )

    assert_proof_failure(:mismatch, EpochStore.verify_mutation(dir, wrong_size.request))
  end

  test "zero-byte object still requires an empty regular part", %{dir: dir} do
    site = published_site!(dir, "zero-byte", "")
    assert {:ok, {:verified, _summary}} = EpochStore.verify_mutation(dir, site.request)

    File.rm!(site.part_path)
    assert_proof_failure(:corrupt, EpochStore.verify_mutation(dir, site.request))
  end

  test "committed replay is re-proved and claimed never counts as standalone proof", %{dir: dir} do
    committed = published_site!(dir, "committed", "payload", phase: "committed")
    assert {:ok, {:verified, _summary}} = EpochStore.verify_mutation(dir, committed.request)

    claimed = published_site!(dir, "claimed", "payload", phase: "claimed")
    assert_proof_failure(:corrupt, EpochStore.verify_mutation(dir, claimed.request))
  end

  test "successor short-circuits before any final probe", %{dir: dir} do
    site = published_site!(dir, "successor", "payload")
    File.rm_rf!(site.final_dir)
    successor = token(2, @id_b)
    write_epoch!(dir, site.target, successor, "claimed", nil, "object", {:claim, successor})

    assert {:ok, {:superseded, %{"status" => "superseded", "required" => 1, "verified" => 0}}} =
             EpochStore.verify_mutation(dir, site.request)
  end

  test "invalid final path, fingerprint, value type and request shape fail closed", %{dir: dir} do
    site = published_site!(dir, "invalid-request", "payload")

    for request <- [
          %{site.request | final_rel: "../escape"},
          %{site.request | expected_fingerprint: %{"etag" => "bad"}},
          Map.delete(site.request, :layout),
          Map.put(site.request, :unexpected, true),
          %{site.request | target: %{}},
          %{site.request | mutation_id: @id_b},
          %{site.request | layout: %{kind: "shard", index: -1}}
        ] do
      assert_proof_failure(:corrupt, EpochStore.verify_mutation(dir, request))
    end

    delete_marker =
      published_site!(dir, "invalid-value-type", "payload", value_type: "delete_marker")

    assert_proof_failure(:corrupt, EpochStore.verify_mutation(dir, delete_marker.request))
  end

  test "transient sidecar and part lstat failures are unavailable, not integrity failures", %{
    dir: dir
  } do
    site = published_site!(dir, "transient-lstat", "payload")

    sidecar_down = fn path ->
      if path == site.meta_path, do: {:error, :eacces}, else: File.lstat(path)
    end

    assert_proof_failure(
      :unavailable,
      EpochStore.verify_mutation(dir, site.request, lstat: sidecar_down)
    )

    part_down = fn path ->
      if path == site.part_path, do: {:error, :eio}, else: File.lstat(path)
    end

    assert_proof_failure(
      :unavailable,
      EpochStore.verify_mutation(dir, site.request, lstat: part_down)
    )
  end

  test "PublishedProof deterministically classifies quorum and bounds journal evidence" do
    verified = PublishedProof.verified("node-a:0", %{phase: "published", owned: true})
    {:ok, {:verified, verified_summary}} = verified
    unavailable = PublishedProof.failed(:unavailable, "node-b:1", %{owned: true})
    mismatch = PublishedProof.failed(:mismatch, "node-c:2", %{owned: true})
    successor = PublishedProof.superseded("node-d:3")

    assert {:ok, {:degraded, %{"verified" => 1, "required" => 1}}} =
             PublishedProof.classify(1, [mismatch, verified])

    assert {:error, {:published_proof_failed, :unavailable, _}} =
             PublishedProof.classify(2, [mismatch, unavailable, verified])

    assert {:error, {:published_proof_failed, :mismatch, _}} =
             PublishedProof.classify(2, [mismatch, verified])

    assert {:ok, {:superseded, _}} =
             PublishedProof.classify(1, [verified, successor, unavailable])

    degraded =
      for ordinal <- 0..39 do
        PublishedProof.failed(:mismatch, "node:#{ordinal}", %{owned: true})
      end

    assert {:error,
            {:published_proof_failed, :mismatch,
             %{"degraded" => entries, "omitted" => 8} = failure}} =
             PublishedProof.classify(41, degraded)

    assert length(entries) == 32

    assert {:ok,
            %{
              "published_proof" => %{"status" => "verified"},
              "last_failure" => ^failure
            }} =
             PublishedProof.journal_evidence(verified_summary, failure)

    refute inspect(failure) =~ System.tmp_dir!()

    assert {:error, :invalid_proof_evidence} =
             PublishedProof.journal_evidence(
               Map.put(verified_summary, "path", "C:\\private\\object"),
               nil
             )

    path_result = PublishedProof.failed(:corrupt, "C:\\private\\object", %{owned: true})
    refute inspect(path_result) =~ "private"
  end

  defp published_site!(dir, key, part, opts \\ []) do
    target = target(key)
    final_rel = final_rel(key)
    final_dir = Path.join(dir, final_rel)
    part_path = Path.join(final_dir, "part.0")
    meta_path = Path.join(final_dir, "meta.json")
    layout = Keyword.get(opts, :layout, %{kind: "fs"})
    core_size = Keyword.get(opts, :core_size, byte_size(part))

    core =
      %{
        "format" => "maxio/2",
        "etag" => Keyword.get(opts, :etag, "etag-#{key}"),
        "size" => core_size,
        "versions" => [
          %{"etag" => "s3-visible-etag", "size" => 999, "type" => "object"}
        ]
      }
      |> maybe_put("shards", Keyword.get(opts, :shards))

    raw_meta = Jason.encode!(core)
    fingerprint = ObjectEpoch.fingerprint(core["etag"], core["size"], raw_meta)
    tok = token(1, @id_a)

    File.mkdir_p!(final_dir)
    File.write!(part_path, part)
    File.write!(meta_path, raw_meta)

    write_epoch!(
      dir,
      target,
      tok,
      Keyword.get(opts, :phase, "published"),
      fingerprint,
      Keyword.get(opts, :value_type, "object"),
      {:claim, tok}
    )

    request = %{
      target: target,
      token: tok,
      mutation_id: @id_a,
      final_rel: final_rel,
      expected_fingerprint: fingerprint,
      layout: layout
    }

    %{
      target: target,
      final_rel: final_rel,
      final_dir: final_dir,
      part: part,
      part_path: part_path,
      raw_meta: raw_meta,
      meta_path: meta_path,
      fingerprint: fingerprint,
      token: tok,
      request: request
    }
  end

  defp write_epoch!(dir, target, tok, phase, fingerprint, value_type, expect) do
    {:ok, epoch} =
      ObjectEpoch.new(target, tok, %{
        operation: "put",
        phase: phase,
        value_type: value_type,
        fingerprint: fingerprint,
        updated_at: DateTime.utc_now()
      })

    assert {:ok, :applied} = EpochStore.cas(dir, epoch, expect)
  end

  defp assert_proof_failure(class, result) do
    assert {:error,
            {:published_proof_failed, ^class,
             %{
               "status" => "failed",
               "required" => 1,
               "verified" => 0,
               "degraded" => [_endpoint]
             }}} = result
  end

  defp target(key) do
    {:ok, target} = ObjectEpoch.object_target(@bucket, key, "null")
    target
  end

  defp final_rel(key) do
    {:ok, rel} = Paths.object_rel(@bucket, key, "null")
    rel
  end

  defp token(generation, id) do
    {:ok, tok} = ObjectEpoch.token(generation, id)
    tok
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
