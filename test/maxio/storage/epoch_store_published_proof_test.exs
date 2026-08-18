defmodule Maxio.Storage.EpochStorePublishedProofTest do
  use ExUnit.Case, async: true

  alias Maxio.Cluster.Paths
  alias Maxio.Native.PathSafety
  alias Maxio.Storage.{EpochStore, MutationBackup, ObjectEpoch, PublishedProof}

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

    assert_endpoint_verified(EpochStore.verify_mutation(dir, site.request))
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
      if same_path?(path, symlink.meta_path),
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

    assert_endpoint_verified(EpochStore.verify_mutation(dir, good.request))

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
    assert_endpoint_verified(EpochStore.verify_mutation(dir, site.request))

    File.rm!(site.part_path)
    assert_proof_failure(:corrupt, EpochStore.verify_mutation(dir, site.request))
  end

  test "committed replay is re-proved and claimed never counts as standalone proof", %{dir: dir} do
    committed = published_site!(dir, "committed", "payload", phase: "committed")
    assert_endpoint_verified(EpochStore.verify_mutation(dir, committed.request))

    claimed = published_site!(dir, "claimed", "payload", phase: "claimed")
    assert_proof_failure(:corrupt, EpochStore.verify_mutation(dir, claimed.request))
  end

  test "successor short-circuits before any final probe", %{dir: dir} do
    site = published_site!(dir, "successor", "payload")
    File.rm_rf!(site.final_dir)
    successor = token(2, @id_b)
    write_epoch!(dir, site.target, successor, "claimed", nil, "object", {:claim, successor})

    parent = self()
    final_prefix = Path.expand(site.final_dir)

    descendant_probe = fn path ->
      if String.starts_with?(Path.expand(path), final_prefix) do
        send(parent, {:unexpected_final_probe, path})
      end

      File.lstat(path)
    end

    reparse_probe = fn path ->
      if String.starts_with?(Path.expand(path), final_prefix) do
        send(parent, {:unexpected_final_probe, path})
      end

      PathSafety.reparse_point(path)
    end

    assert {:ok,
            {:superseded,
             %{
               "scope" => "endpoint",
               "status" => "superseded",
               "endpoint" => "local",
               "owned" => false,
               "class" => "fenced"
             }}} =
             EpochStore.verify_mutation(
               dir,
               site.request,
               lstat: descendant_probe,
               reparse_point: reparse_probe
             )

    refute_receive {:unexpected_final_probe, _path}
  end

  test "epoch target mismatch cannot impersonate a successor and probes no final descendant", %{
    dir: dir
  } do
    site = published_site!(dir, "request-target", "payload")
    other_target = target("decoded-epoch-target")
    successor = token(2, @id_b)

    overwrite_epoch_file!(
      dir,
      site.target,
      other_target,
      successor,
      "published",
      site.fingerprint
    )

    parent = self()
    final_prefix = Path.expand(site.final_dir)

    lstat = fn path ->
      if String.starts_with?(Path.expand(path), final_prefix) do
        send(parent, {:unexpected_final_probe, path})
      end

      File.lstat(path)
    end

    assert_proof_failure(
      :corrupt,
      EpochStore.verify_mutation(dir, site.request, lstat: lstat)
    )

    refute_receive {:unexpected_final_probe, _path}
  end

  test "canonical cross-key final_rel is rejected before entering an EpochStore worker", %{
    dir: dir
  } do
    site = published_site!(dir, "target-key", "payload")
    other_final_rel = final_rel("other-key")

    assert_proof_failure(
      :corrupt,
      EpochStore.verify_mutation(
        dir,
        %{site.request | final_rel: other_final_rel},
        epoch_store: :proof_must_not_enter_worker
      )
    )
  end

  test "configured drive root must be non-empty and absolute before entering a worker", %{
    dir: dir
  } do
    site = published_site!(dir, "absolute-drive-root", "payload")

    for invalid_root <- ["", "relative-drive-root"] do
      assert_proof_failure(
        :corrupt,
        EpochStore.verify_mutation(
          invalid_root,
          site.request,
          epoch_store: :proof_must_not_enter_worker
        )
      )
    end
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
      if same_path?(path, site.meta_path), do: {:error, :eacces}, else: File.lstat(path)
    end

    assert_proof_failure(
      :unavailable,
      EpochStore.verify_mutation(dir, site.request, lstat: sidecar_down)
    )

    part_down = fn path ->
      if same_path?(path, site.part_path), do: {:error, :eio}, else: File.lstat(path)
    end

    assert_proof_failure(
      :unavailable,
      EpochStore.verify_mutation(dir, site.request, lstat: part_down)
    )
  end

  test "path traversal errno values are deterministic integrity failures", %{dir: dir} do
    site = published_site!(dir, "unsafe-path-errors", "payload")

    for reason <- [:enotdir, :eloop] do
      lstat = fn path ->
        if same_path?(path, site.meta_path), do: {:error, reason}, else: File.lstat(path)
      end

      assert_proof_failure(
        :corrupt,
        EpochStore.verify_mutation(dir, site.request, lstat: lstat)
      )
    end
  end

  test "self-consistent fingerprints cannot legitimize malformed durable envelopes", %{dir: dir} do
    for {key, override} <- [
          {"wrong-format", %{"format" => "maxio/1"}},
          {"missing-sha", %{"sha256" => nil}},
          {"empty-versions", %{"versions" => []}},
          {"missing-target-version",
           %{"versions" => [%{"version_id" => "other", "type" => "object"}]}},
          {"duplicate-target-version",
           %{
             "versions" => [
               %{"version_id" => "null", "type" => "object"},
               %{"version_id" => "null", "type" => "delete_marker"}
             ]
           }}
        ] do
      site = published_site!(dir, key, "payload", core_overrides: override)
      assert_proof_failure(:corrupt, EpochStore.verify_mutation(dir, site.request))
    end
  end

  test "accepts an exact 16 MiB sidecar and rejects lstat-then-grow by one byte", %{dir: dir} do
    {core, raw_meta} = exact_limit_sidecar("exact-limit")

    exact =
      published_site!(dir, "exact-limit", "payload", core: core, raw_meta: raw_meta)

    assert byte_size(exact.raw_meta) == @sidecar_limit
    assert_endpoint_verified(EpochStore.verify_mutation(dir, exact.request))

    {grow_core, grow_raw_meta} = exact_limit_sidecar("grow-limit")

    grow =
      published_site!(dir, "grow-limit", "payload",
        core: grow_core,
        raw_meta: grow_raw_meta
      )

    tracker = start_supervised!({Agent, fn -> false end})

    lstat_then_grow = fn path ->
      result = File.lstat(path)

      if same_path?(path, grow.meta_path) and
           Agent.get_and_update(tracker, fn
             false -> {true, true}
             true -> {false, true}
           end) do
        File.write!(path, "x", [:append])
      end

      result
    end

    assert_proof_failure(
      :corrupt,
      EpochStore.verify_mutation(dir, grow.request, lstat: lstat_then_grow)
    )
  end

  test "opened-handle identity must match the lstat path", %{dir: dir} do
    site = published_site!(dir, "opened-handle", "payload")
    shadow = Path.join(dir, "shadow-meta.json")
    File.write!(shadow, site.raw_meta)
    File.touch!(shadow, System.os_time(:second) - 120)

    open_raw = fn path ->
      if same_path?(path, site.meta_path),
        do: File.open(shadow, [:read, :binary]),
        else: File.open(path, [:read, :binary])
    end

    assert_proof_failure(
      :corrupt,
      EpochStore.verify_mutation(dir, site.request, open_raw: open_raw)
    )
  end

  test "real final ancestors and sidecar leaves cannot be links", %{dir: dir} do
    if match?({:unix, _name}, :os.type()) do
      leaf = published_site!(dir, "leaf-symlink", "payload")
      target_meta = Path.join(dir, "leaf-target-meta.json")
      File.rename!(leaf.meta_path, target_meta)
      File.ln_s!(target_meta, leaf.meta_path)

      on_exit(fn ->
        assert {:ok, %File.Stat{type: :symlink}} = File.lstat(leaf.meta_path)
        File.rm!(leaf.meta_path)
        assert File.exists?(target_meta)
      end)

      assert_proof_failure(:corrupt, EpochStore.verify_mutation(dir, leaf.request))

      ancestor = published_site!(dir, "ancestor-symlink", "payload")
      target_dir = Path.join(dir, "ancestor-target")
      File.rename!(ancestor.final_dir, target_dir)
      File.ln_s!(target_dir, ancestor.final_dir)
      target_ancestor_meta = Path.join(target_dir, "meta.json")

      on_exit(fn ->
        assert {:ok, %File.Stat{type: :symlink}} = File.lstat(ancestor.final_dir)
        File.rm!(ancestor.final_dir)
        assert File.exists?(target_ancestor_meta)
      end)

      assert_proof_failure(:corrupt, EpochStore.verify_mutation(dir, ancestor.request))
    end

    if match?({:win32, _name}, :os.type()) do
      ancestor = published_site!(dir, "junction-ancestor", "payload")
      target_dir = Path.join(dir, "junction-target")
      File.rename!(ancestor.final_dir, target_dir)
      create_junction!(ancestor.final_dir, target_dir)
      target_meta = Path.join(target_dir, "meta.json")

      on_exit(fn ->
        assert_safe_link!(dir, ancestor.final_dir, target_dir)
        assert {:ok, true} = PathSafety.reparse_point(ancestor.final_dir)
        assert :ok = File.rmdir(ancestor.final_dir)
        assert File.exists?(target_meta)
      end)

      assert_proof_failure(:corrupt, EpochStore.verify_mutation(dir, ancestor.request))
    end
  end

  test "PublishedProof freezes endpoint scope and never exposes aggregate counters" do
    assert {:ok,
            {:verified,
             %{
               "scope" => "endpoint",
               "mode" => "proof",
               "endpoint" => "local",
               "status" => "verified",
               "owned" => true
             } = verified}} =
             PublishedProof.verified("local", %{phase: "published", owned: true})

    refute Enum.any?(
             ~w(required verified observed_owned unavailable degraded omitted debt),
             &Map.has_key?(verified, &1)
           )

    assert {:ok,
            {:superseded,
             %{
               "scope" => "endpoint",
               "mode" => "proof",
               "endpoint" => "ordinal:3",
               "status" => "superseded",
               "owned" => false,
               "class" => "fenced"
             }}} = PublishedProof.superseded("ordinal:3")

    assert {:error,
            {:published_proof_failed, :unavailable,
             %{
               "scope" => "endpoint",
               "mode" => "proof",
               "endpoint" => "ordinal:4",
               "status" => "failed",
               "owned" => true,
               "class" => "unavailable"
             }}} =
             PublishedProof.failed(:unavailable, "ordinal:4", %{owned: true})

    path_result = PublishedProof.failed(:corrupt, "C:\\private\\object", %{owned: true})
    assert {:error, {:published_proof_failed, :placement_drift, _summary}} = path_result
    refute inspect(path_result) =~ "private"
  end

  test "PublishedProof rejects forged endpoint votes, aggregate re-entry and identity drift" do
    verified0 = PublishedProof.verified("ordinal:0", %{owned: true})
    verified1 = PublishedProof.verified("ordinal:1", %{owned: true})

    assert {:ok,
            {:verified,
             %{
               "scope" => "aggregate",
               "mode" => "proof",
               "status" => "verified",
               "required" => 2,
               "verified" => 2,
               "observed_owned" => 2,
               "unavailable" => 0,
               "debt" => 0,
               "degraded" => [],
               "omitted" => 0
             } = aggregate}} =
             PublishedProof.classify(2, [
               {"ordinal:0", verified0},
               {"ordinal:1", verified1}
             ])

    forged_counts =
      {:ok,
       {:verified,
        %{
          "scope" => "endpoint",
          "endpoint" => "ordinal:2",
          "status" => "verified",
          "owned" => true,
          "verified" => 99
        }}}

    outcome_status_drift =
      {:ok,
       {:verified,
        %{
          "scope" => "endpoint",
          "endpoint" => "ordinal:2",
          "status" => "superseded",
          "owned" => false,
          "class" => "fenced"
        }}}

    class_drift =
      {:error,
       {:published_proof_failed, :mismatch,
        %{
          "scope" => "endpoint",
          "endpoint" => "ordinal:2",
          "status" => "failed",
          "owned" => true,
          "class" => "corrupt"
        }}}

    for observations <- [
          [{"ordinal:0", verified0}, {"ordinal:0", verified0}],
          [{"ordinal:0", verified1}],
          [{"ordinal:2", forged_counts}],
          [{"ordinal:2", outcome_status_drift}],
          [{"ordinal:2", class_drift}],
          [{"ordinal:2", {:ok, {:verified, aggregate}}}]
        ] do
      assert {:error, {:published_proof_failed, :placement_drift, _summary}} =
               PublishedProof.classify(1, observations)
    end
  end

  test "PublishedProof follows frozen D5 ordering and ignores non-owned integrity votes" do
    verified = PublishedProof.verified("ordinal:0", %{owned: true})
    unavailable = PublishedProof.failed(:unavailable, "ordinal:1", %{owned: true})
    owned_corrupt = PublishedProof.failed(:corrupt, "ordinal:2", %{owned: true})
    owned_mismatch = PublishedProof.failed(:mismatch, "ordinal:3", %{owned: true})
    non_owned_corrupt = PublishedProof.failed(:corrupt, "ordinal:4", %{owned: false})
    successor = PublishedProof.superseded("ordinal:5")
    placement = PublishedProof.failed(:placement_drift, "ordinal:6", %{owned: false})

    assert {:ok, {:superseded, %{"scope" => "aggregate"}}} =
             PublishedProof.classify(3, [
               {"ordinal:5", successor},
               {"ordinal:6", placement}
             ])

    forged =
      {:ok,
       {:verified,
        %{
          "scope" => "endpoint",
          "endpoint" => "ordinal:7",
          "status" => "verified",
          "owned" => true,
          "verified" => 9
        }}}

    assert {:error, {:published_proof_failed, :placement_drift, _summary}} =
             PublishedProof.classify(2, [
               {"ordinal:0", verified},
               {"ordinal:7", forged},
               {"ordinal:8", PublishedProof.verified("ordinal:8", %{owned: true})}
             ])

    assert {:ok, {:degraded, %{"verified" => 1, "debt" => 1}}} =
             PublishedProof.classify(1, [
               {"ordinal:0", verified},
               {"ordinal:2", owned_corrupt}
             ])

    assert {:error, {:published_proof_failed, :unavailable, _summary}} =
             PublishedProof.classify(2, [
               {"ordinal:0", verified},
               {"ordinal:1", unavailable},
               {"ordinal:2", owned_corrupt}
             ])

    assert {:error, {:published_proof_failed, :corrupt, _summary}} =
             PublishedProof.classify(4, [
               {"ordinal:0", verified},
               {"ordinal:2", owned_corrupt},
               {"ordinal:3", owned_mismatch}
             ])

    assert {:error, {:published_proof_failed, :mismatch, _summary}} =
             PublishedProof.classify(3, [
               {"ordinal:0", verified},
               {"ordinal:3", owned_mismatch},
               {"ordinal:4", non_owned_corrupt}
             ])

    assert {:error, {:published_proof_failed, :unavailable, _summary}} =
             PublishedProof.classify(2, [
               {"ordinal:0", verified},
               {"ordinal:4", non_owned_corrupt}
             ])
  end

  test "PublishedProof journal is phase-aware and validates proof/finalize sum types" do
    verified = PublishedProof.verified("local", %{owned: true})
    mismatch = PublishedProof.failed(:mismatch, "ordinal:1", %{owned: true})
    successor = PublishedProof.superseded("ordinal:2")

    {:ok, {:verified, published}} =
      PublishedProof.classify(1, [{"local", verified}])

    {:error, {:published_proof_failed, :mismatch, failure}} =
      PublishedProof.classify(2, [
        {"local", verified},
        {"ordinal:1", mismatch}
      ])

    {:ok, {:superseded, proof_superseded}} =
      PublishedProof.classify(1, [{"ordinal:2", successor}])

    finalized = PublishedProof.endpoint_finalized("ordinal:0", %{phase: "committed"})

    finalize_mismatch =
      PublishedProof.endpoint_finalize_failed(:mismatch, "ordinal:1", %{owned: true})

    finalize_cleanup =
      PublishedProof.endpoint_cleanup_pending("ordinal:1", %{phase: "committed"})

    finalize_successor = PublishedProof.endpoint_finalize_superseded("ordinal:2")

    {:error, {:published_proof_failed, :mismatch, finalize_failure}} =
      PublishedProof.classify_finalize(2, [
        {"ordinal:0", finalized},
        {"ordinal:1", finalize_mismatch}
      ])

    {:ok, {:cleanup_pending, cleanup_failure}} =
      PublishedProof.classify_finalize(1, [
        {"ordinal:0", finalized},
        {"ordinal:1", finalize_cleanup}
      ])

    {:ok, {:superseded, finalize_superseded}} =
      PublishedProof.classify_finalize(1, [{"ordinal:2", finalize_successor}])

    assert {:ok,
            %{
              "published_proof" => ^published,
              "last_failure" => ^failure
            }} = PublishedProof.journal_evidence("rollback_pending", published, failure)

    for {phase, proof, last_failure} <- [
          {"rollback_pending", nil, failure},
          {"rolled_back", nil, proof_superseded},
          {"quarantined", nil, failure},
          {"published", published, nil},
          {"metadata_committed", published, nil},
          {"finalize_pending", published, finalize_failure},
          {"finalize_pending", published, cleanup_failure},
          {"finalize_pending", published, finalize_superseded},
          {"quarantined", published, finalize_failure}
        ] do
      assert {:ok, _evidence} =
               PublishedProof.journal_evidence(phase, proof, last_failure)
    end

    evidence = %{"published_proof" => published, "last_failure" => nil}

    assert {:ok, %{"published_proof" => ^published, "last_failure" => ^cleanup_failure}} =
             PublishedProof.merge_failure("finalize_pending", evidence, cleanup_failure)

    {:ok, {:verified, endpoint}} = verified

    {:ok, {:finalized, finalized_endpoint}} = finalized

    {:ok, {:finalized, finalized_aggregate}} =
      PublishedProof.classify_finalize(1, [{"ordinal:0", finalized}])

    for {phase, proof, last_failure} <- [
          {"rollback_pending", nil, nil},
          {"claimed", nil, failure},
          {"published", nil, failure},
          {"rollback_pending", nil, finalize_failure},
          {"published", endpoint, nil},
          {"published", published, endpoint},
          {"finalize_pending", published, published},
          {"finalize_pending", published, finalized_endpoint},
          {"finalize_pending", published, finalized_aggregate},
          {"unknown", published, nil}
        ] do
      assert {:error, :invalid_proof_evidence} =
               PublishedProof.journal_evidence(phase, proof, last_failure)
    end

    for forged <- [
          %{published | "verified" => 0},
          %{published | "debt" => 1},
          %{published | "unavailable" => 1},
          Map.put(published, "class", "corrupt"),
          Map.put(published, "path", "C:\\private\\object")
        ] do
      assert {:error, :invalid_proof_evidence} =
               PublishedProof.journal_evidence("published", forged, nil)
    end

    for forged_failure <- [
          %{failure | "observed_owned" => 1},
          %{failure | "unavailable" => 1},
          %{failure | "class" => "corrupt"},
          %{failure | "class" => "fenced"}
        ] do
      assert {:error, :invalid_proof_evidence} =
               PublishedProof.journal_evidence("rollback_pending", published, forged_failure)
    end
  end

  test "PublishedProof freezes endpoint and aggregate finalize contracts" do
    finalized = PublishedProof.endpoint_finalized("ordinal:0", %{phase: "committed"})
    cleanup_pending = PublishedProof.endpoint_cleanup_pending("ordinal:1", %{phase: "committed"})

    assert {:ok,
            {:finalized,
             %{
               "scope" => "endpoint",
               "mode" => "finalize",
               "endpoint" => "ordinal:0",
               "status" => "finalized",
               "owned" => true,
               "proof_passed" => true,
               "finalized" => true
             }}} = finalized

    assert {:ok,
            {:cleanup_pending,
             %{
               "scope" => "endpoint",
               "mode" => "finalize",
               "endpoint" => "ordinal:1",
               "status" => "cleanup_pending",
               "owned" => true,
               "proof_passed" => true,
               "finalized" => false
             }}} = cleanup_pending

    assert {:ok,
            {:finalized,
             %{
               "scope" => "aggregate",
               "mode" => "finalize",
               "status" => "finalized",
               "required" => 1,
               "verified" => 1,
               "finalized" => 1,
               "debt" => 0
             }}} =
             PublishedProof.classify_finalize(1, [{"ordinal:0", finalized}])

    assert {:ok,
            {:cleanup_pending,
             %{
               "scope" => "aggregate",
               "mode" => "finalize",
               "status" => "cleanup_pending",
               "required" => 1,
               "verified" => 2,
               "finalized" => 1,
               "debt" => 1
             }}} =
             PublishedProof.classify_finalize(1, [
               {"ordinal:0", finalized},
               {"ordinal:1", cleanup_pending}
             ])

    forged_finalized =
      {:ok,
       {:finalized,
        %{
          "scope" => "endpoint",
          "endpoint" => "ordinal:2",
          "status" => "finalized",
          "owned" => true,
          "proof_passed" => true,
          "finalized" => false
        }}}

    assert {:error, {:published_proof_failed, :placement_drift, _summary}} =
             PublishedProof.classify_finalize(1, [{"ordinal:2", forged_finalized}])

    {:ok, {:finalized, aggregate}} =
      PublishedProof.classify_finalize(1, [{"ordinal:0", finalized}])

    assert aggregate["finalized"] <= aggregate["verified"]

    assert {:error, {:published_proof_failed, :placement_drift, _summary}} =
             PublishedProof.classify_finalize(1, [
               {"ordinal:0", {:ok, {:finalized, aggregate}}}
             ])

    assert {:error, {:published_proof_failed, :placement_drift, _summary}} =
             PublishedProof.endpoint_finalized("ordinal:0", :forged)

    assert {:error, {:published_proof_failed, :placement_drift, _summary}} =
             PublishedProof.endpoint_cleanup_pending("ordinal:0", :forged)
  end

  test "PublishedProof finalize orphans are explicit, bounded, and never become debt or votes" do
    finalized = PublishedProof.endpoint_finalized("ordinal:0", %{phase: "committed"})
    absent = PublishedProof.endpoint_orphan("ordinal:1", :epoch_absent)
    older = PublishedProof.endpoint_orphan("ordinal:2", :older_token)

    assert {:ok,
            {:orphan,
             %{
               "scope" => "endpoint",
               "mode" => "finalize",
               "endpoint" => "ordinal:1",
               "status" => "orphan",
               "owned" => false,
               "proof_passed" => false,
               "finalized" => false,
               "orphan_reason" => "epoch_absent"
             } = absent_summary}} = absent

    refute Map.has_key?(absent_summary, "class")

    assert {:ok,
            {:finalized,
             %{
               "mode" => "finalize",
               "verified" => 1,
               "finalized" => 1,
               "observed_owned" => 1,
               "unavailable" => 0,
               "debt" => 0,
               "orphaned" => 2,
               "orphan_hints" => orphan_hints,
               "orphan_omitted" => 0
             }}} =
             PublishedProof.classify_finalize(1, [
               {"ordinal:0", finalized},
               {"ordinal:1", absent},
               {"ordinal:2", older}
             ])

    assert Enum.map(orphan_hints, & &1["endpoint"]) == ["ordinal:1", "ordinal:2"]

    assert {:error,
            {:published_proof_failed, :unavailable,
             %{
               "verified" => 0,
               "finalized" => 0,
               "debt" => 0,
               "orphaned" => 1
             }}} = PublishedProof.classify_finalize(1, [{"ordinal:1", absent}])

    non_owned_failures =
      for {class, ordinal} <- [corrupt: 3, mismatch: 4, unavailable: 5] do
        {class,
         PublishedProof.endpoint_finalize_failed(class, "ordinal:#{ordinal}", %{owned: false})}
      end

    for {class, failure} <- non_owned_failures do
      assert {:ok,
              {:cleanup_pending,
               %{
                 "debt" => 1,
                 "orphaned" => 0,
                 "orphan_hints" => [],
                 "degraded" => [detail]
               }}} =
               PublishedProof.classify_finalize(1, [
                 {"ordinal:0", finalized},
                 {failure_endpoint(failure), failure}
               ])

      assert detail["class"] == Atom.to_string(class)
    end

    orphans =
      for ordinal <- 1..40 do
        {"ordinal:#{ordinal}", PublishedProof.endpoint_orphan(ordinal, :epoch_absent)}
      end

    assert {:ok,
            {:finalized,
             %{
               "debt" => 0,
               "degraded" => [],
               "omitted" => 0,
               "orphaned" => 40,
               "orphan_hints" => hints,
               "orphan_omitted" => 8
             }}} =
             PublishedProof.classify_finalize(
               1,
               [{"ordinal:0", finalized} | orphans]
             )

    assert length(hints) == 32
  end

  test "PublishedProof rejects forged orphan and cross-mode observations before counting" do
    finalized = PublishedProof.endpoint_finalized("ordinal:0", %{phase: "committed"})
    {:ok, {:orphan, orphan}} = PublishedProof.endpoint_orphan("ordinal:1", :epoch_absent)
    {:ok, {:verified, proof_endpoint}} = PublishedProof.verified("ordinal:1", %{owned: true})

    forged =
      [
        {:ok, {:orphan, %{orphan | "orphan_reason" => "epoch_missing"}}},
        {:ok, {:orphan, %{orphan | "owned" => true}}},
        {:ok, {:orphan, %{orphan | "proof_passed" => true}}},
        {:ok, {:orphan, %{orphan | "finalized" => true}}},
        {:ok, {:orphan, Map.put(orphan, "class", "corrupt")}},
        {:ok, {:orphan, %{orphan | "mode" => "proof"}}},
        {:ok, {:orphan, %{orphan | "endpoint" => "ordinal:2"}}},
        {:ok, {:orphan, proof_endpoint}}
      ]

    for observation <- forged do
      assert {:error,
              {:published_proof_failed, :placement_drift,
               %{
                 "mode" => "finalize",
                 "status" => "failed",
                 "verified" => 0,
                 "finalized" => 0,
                 "observed_owned" => 0,
                 "unavailable" => 0,
                 "orphaned" => 0,
                 "degraded" => [_witness]
               }}} =
               PublishedProof.classify_finalize(1, [
                 {"ordinal:0", finalized},
                 {"ordinal:1", observation}
               ])
    end

    for invalid_reason <- [:epoch_missing, :old_epoch, "epoch_absent", nil] do
      assert {:error, {:published_proof_failed, :placement_drift, _summary}} =
               PublishedProof.endpoint_orphan("ordinal:1", invalid_reason)
    end
  end

  test "PublishedProof structural drift zeroes votes and integrity failures retain witnesses" do
    verified = PublishedProof.verified("ordinal:0", %{owned: true})

    assert {:error,
            {:published_proof_failed, :placement_drift,
             %{
               "status" => "failed",
               "verified" => 0,
               "observed_owned" => 0,
               "unavailable" => 0,
               "degraded" => [drift]
             }}} =
             PublishedProof.classify(1, [
               {"ordinal:0", verified},
               {"ordinal:0", verified}
             ])

    assert drift["class"] == "placement_drift"
    assert drift["owned"] == false

    owned_corrupt = PublishedProof.failed(:corrupt, "ordinal:1", %{owned: true})

    assert {:error,
            {:published_proof_failed, :corrupt,
             %{"verified" => 0, "degraded" => details} = corrupt_failure}} =
             PublishedProof.classify(2, [{"ordinal:1", owned_corrupt}])

    assert Enum.any?(
             details,
             &(&1["class"] == "corrupt" and &1["owned"] == true)
           )

    forged_outer = %{corrupt_failure | "class" => "mismatch"}

    assert {:error, :invalid_proof_evidence} =
             PublishedProof.journal_evidence("rollback_pending", nil, forged_outer)
  end

  test "PublishedProof enforces canonical placement drift and non-owned drift witnesses" do
    verified = PublishedProof.verified("ordinal:0", %{owned: true})
    finalized = PublishedProof.endpoint_finalized("ordinal:0", %{phase: "committed"})
    {:ok, {:verified, published}} = PublishedProof.classify(1, [{"ordinal:0", verified}])

    {:error, {:published_proof_failed, :placement_drift, proof_drift}} =
      PublishedProof.classify(1, [{"ordinal:0", verified}, {"ordinal:0", verified}])

    {:error, {:published_proof_failed, :placement_drift, finalize_drift}} =
      PublishedProof.classify_finalize(1, [
        {"ordinal:0", finalized},
        {"ordinal:0", finalized}
      ])

    # 冻结 canonical zero counts：只改语义计数的 drift forgery 一律不可持久化。
    for forged <- [
          %{proof_drift | "required" => 2, "verified" => 1, "observed_owned" => 1},
          %{proof_drift | "required" => 2, "observed_owned" => 1},
          %{proof_drift | "required" => 2, "unavailable" => 1}
        ] do
      assert {:error, :invalid_proof_evidence} =
               PublishedProof.journal_evidence("rollback_pending", nil, forged)
    end

    for forged <- [
          %{finalize_drift | "required" => 2, "verified" => 1, "finalized" => 1},
          %{finalize_drift | "required" => 2, "observed_owned" => 1},
          %{finalize_drift | "required" => 2, "orphaned" => 1, "orphan_omitted" => 1}
        ] do
      assert {:error, :invalid_proof_evidence} =
               PublishedProof.journal_evidence("finalize_pending", published, forged)
    end

    # public endpoint constructor 必须拒绝 owned=true 的 placement drift。
    for result <- [
          PublishedProof.failed(:placement_drift, "ordinal:1", %{owned: true}),
          PublishedProof.endpoint_finalize_failed(:placement_drift, "ordinal:1", %{owned: true})
        ] do
      assert {:error,
              {:published_proof_failed, :placement_drift,
               %{"endpoint" => "local", "owned" => false, "code" => "invalid_evidence"}}} = result
    end

    # 不可信的 owned drift observation 必须被重建为非 owned canonical witness，
    # 而不是原样保留后让 classifier 自己的结果无法持久化。
    forged_owned_drift =
      {:error,
       {:published_proof_failed, :placement_drift,
        %{
          "scope" => "endpoint",
          "mode" => "proof",
          "endpoint" => "ordinal:1",
          "status" => "failed",
          "class" => "placement_drift",
          "owned" => true
        }}}

    {:error, {:published_proof_failed, :placement_drift, rebuilt}} =
      PublishedProof.classify(2, [{"ordinal:1", forged_owned_drift}])

    assert [rebuilt_witness] = rebuilt["degraded"]
    assert rebuilt_witness["owned"] == false
    assert rebuilt_witness["class"] == "placement_drift"
    assert {:ok, _evidence} = PublishedProof.journal_evidence("rollback_pending", nil, rebuilt)

    # constructor → classifier → phase-aware journal evidence 必须闭合。
    drift_endpoint =
      PublishedProof.failed(:placement_drift, "ordinal:1", %{
        owned: false,
        code: :placement_drift
      })

    {:error, {:published_proof_failed, :placement_drift, canonical}} =
      PublishedProof.classify(2, [{"ordinal:1", drift_endpoint}])

    assert %{"verified" => 0, "observed_owned" => 0, "unavailable" => 0} = canonical

    assert {:ok, %{"last_failure" => ^canonical}} =
             PublishedProof.journal_evidence("rollback_pending", nil, canonical)

    finalize_drift_endpoint =
      PublishedProof.endpoint_finalize_failed(:placement_drift, "ordinal:1", %{owned: false})

    {:error, {:published_proof_failed, :placement_drift, canonical_finalize}} =
      PublishedProof.classify_finalize(2, [{"ordinal:1", finalize_drift_endpoint}])

    assert %{"finalized" => 0, "orphaned" => 0, "orphan_hints" => []} = canonical_finalize

    assert {:ok, %{"last_failure" => ^canonical_finalize}} =
             PublishedProof.journal_evidence("finalize_pending", published, canonical_finalize)
  end

  test "PublishedProof enforces finalize count conservation" do
    verified = PublishedProof.verified("local", %{owned: true})
    {:ok, {:verified, published}} = PublishedProof.classify(1, [{"local", verified}])

    finalized_a = PublishedProof.endpoint_finalized("ordinal:0", %{phase: "committed"})
    finalized_b = PublishedProof.endpoint_finalized("ordinal:1", %{phase: "committed"})
    cleanup = PublishedProof.endpoint_cleanup_pending("ordinal:2", %{phase: "committed"})
    mismatch = PublishedProof.endpoint_finalize_failed(:mismatch, "ordinal:2", %{owned: true})

    {:ok, {:finalized, terminal}} =
      PublishedProof.classify_finalize(1, [{"ordinal:0", finalized_a}])

    {:ok, {:cleanup_pending, pending}} =
      PublishedProof.classify_finalize(1, [
        {"ordinal:0", finalized_a},
        {"ordinal:2", cleanup}
      ])

    {:error, {:published_proof_failed, :mismatch, failed}} =
      PublishedProof.classify_finalize(3, [
        {"ordinal:0", finalized_a},
        {"ordinal:1", finalized_b},
        {"ordinal:2", mismatch}
      ])

    # terminal 且零债务时，proof-passed endpoint 不可能凭空消失。
    assert %{"debt" => 0, "verified" => 1, "finalized" => 1, "observed_owned" => 1} = terminal

    # classifier 产出的 cleanup_pending / failed 仍必须可持久化。
    assert {:ok, %{"last_failure" => ^pending}} =
             PublishedProof.journal_evidence("finalize_pending", published, pending)

    assert {:ok, %{"last_failure" => ^failed}} =
             PublishedProof.journal_evidence("finalize_pending", published, failed)

    # 零债务、零 witness 的 cleanup_pending 是不可达状态。
    forged_zero_debt =
      terminal
      |> Map.put("status", "cleanup_pending")
      |> Map.put("finalized", 0)

    assert {:error, :invalid_proof_evidence} =
             PublishedProof.journal_evidence("finalize_pending", published, forged_zero_debt)

    # verified - finalized 必须完全落在 debt 里。
    forged_pending_gap = %{pending | "verified" => 5, "observed_owned" => 5}

    assert {:error, :invalid_proof_evidence} =
             PublishedProof.journal_evidence("finalize_pending", published, forged_pending_gap)

    forged_failed_gap = %{failed | "finalized" => 0}

    assert {:error, :invalid_proof_evidence} =
             PublishedProof.journal_evidence("finalize_pending", published, forged_failed_gap)

    # 只改 status/计数不能把 terminal finalize 结果洗成 durable evidence。
    for phase <- ["finalize_pending", "quarantined"] do
      assert {:error, :invalid_proof_evidence} =
               PublishedProof.journal_evidence(phase, published, terminal)
    end
  end

  test "PublishedProof budgets retained endpoint details across the journal wrapper" do
    proof_ok = for index <- 0..3, do: {"ordinal:#{index}", PublishedProof.verified(index, %{})}

    proof_failures =
      for index <- 4..43 do
        {"ordinal:#{index}", PublishedProof.failed(:unavailable, index, %{owned: false})}
      end

    {:ok, {:degraded, published}} = PublishedProof.classify(4, proof_ok ++ proof_failures)
    assert length(published["degraded"]) == 32
    assert published["omitted"] == 8
    assert published["debt"] == 40

    finalize_ok =
      for index <- 0..3, do: {"ordinal:#{index}", PublishedProof.endpoint_finalized(index, %{})}

    finalize_pending =
      for index <- 4..23 do
        {"ordinal:#{index}", PublishedProof.endpoint_cleanup_pending(index, %{})}
      end

    finalize_orphans =
      for index <- 24..43 do
        {"ordinal:#{index}", PublishedProof.endpoint_orphan(index, :epoch_absent)}
      end

    {:ok, {:cleanup_pending, last_failure}} =
      PublishedProof.classify_finalize(4, finalize_ok ++ finalize_pending ++ finalize_orphans)

    assert length(last_failure["degraded"]) == 20
    assert length(last_failure["orphan_hints"]) == 12
    assert last_failure["orphan_omitted"] == 8

    # 初次持久化成功 proof：最多 31 条，为未来强制 witness 预留一条。
    {:ok, first} = PublishedProof.journal_evidence("finalize_pending", published, nil)
    assert length(first["published_proof"]["degraded"]) == 31
    assert first["published_proof"]["omitted"] == 9
    assert first["published_proof"]["debt"] == 40

    {:ok, merged} = PublishedProof.merge_failure("finalize_pending", first, last_failure)

    # published proof 在 merge 中逐字节不变。
    assert merged["published_proof"] == first["published_proof"]

    assert Jason.encode!(merged["published_proof"]) ==
             Jason.encode!(first["published_proof"])

    merged_failure = merged["last_failure"]

    total_details =
      length(merged["published_proof"]["degraded"]) +
        length(merged_failure["degraded"]) + length(merged_failure["orphan_hints"])

    assert total_details == 32

    # 强制 debt witness 必须留下；debt/orphaned 总数不变，omitted 精确增加。
    assert length(merged_failure["degraded"]) == 1
    assert merged_failure["omitted"] == 19
    assert merged_failure["debt"] == 20
    assert merged_failure["orphan_hints"] == []
    assert merged_failure["orphan_omitted"] == 20
    assert merged_failure["orphaned"] == 20
    assert byte_size(Jason.encode!(merged)) <= 60 * 1024

    # failed last failure 保留的那一条必须是决定性 owned witness。
    owned_corrupt = PublishedProof.failed(:corrupt, "ordinal:44", %{owned: true})

    {:error, {:published_proof_failed, :corrupt, corrupt_failure}} =
      PublishedProof.classify(50, proof_failures ++ [{"ordinal:44", owned_corrupt}])

    {:ok, corrupt_evidence} =
      PublishedProof.journal_evidence("rollback_pending", published, corrupt_failure)

    assert [corrupt_witness] = corrupt_evidence["last_failure"]["degraded"]
    assert corrupt_witness["class"] == "corrupt"
    assert corrupt_witness["owned"] == true
    assert corrupt_evidence["last_failure"]["debt"] == corrupt_failure["debt"]

    assert corrupt_evidence["last_failure"]["omitted"] ==
             corrupt_failure["debt"] - 1

    # pre-published 的 nil-proof failure 可以独占全部 32 条预算。
    {:error, {:published_proof_failed, :unavailable, nil_proof_failure}} =
      PublishedProof.classify(50, proof_failures)

    {:ok, nil_proof_evidence} =
      PublishedProof.journal_evidence("rollback_pending", nil, nil_proof_failure)

    assert length(nil_proof_evidence["last_failure"]["degraded"]) == 32
    assert nil_proof_evidence["last_failure"]["omitted"] == 8
    assert byte_size(Jason.encode!(nil_proof_evidence)) <= 60 * 1024
  end

  test "PublishedProof bounds decimal ordinal identities" do
    huge_ordinal = Integer.pow(2, 1024)

    assert {:error,
            {:published_proof_failed, :placement_drift,
             %{"endpoint" => "local", "mode" => "proof"}}} =
             PublishedProof.superseded(huge_ordinal)

    assert {:error, {:published_proof_failed, :placement_drift, _summary}} =
             PublishedProof.endpoint_orphan(huge_ordinal, :epoch_absent)
  end

  test "invalid request failures preserve a valid frozen shard ordinal", %{dir: dir} do
    site =
      published_site!(dir, "invalid-request-ordinal", "data",
        layout: %{kind: "shard", index: 3},
        shards:
          for(
            index <- 0..3,
            do: %{
              "drive" => index,
              "shard_file_size" => 4,
              "block_hashes" => []
            }
          )
      )

    assert {:error,
            {:published_proof_failed, :corrupt, %{"endpoint" => "ordinal:3", "mode" => "proof"}}} =
             EpochStore.verify_mutation("relative-drive-root", site.request)

    assert {:error,
            {:published_proof_failed, :corrupt, %{"endpoint" => "ordinal:3", "mode" => "proof"}}} =
             EpochStore.verify_mutation(dir, %{site.request | final_rel: nil})
  end

  test "ancestor identity recheck ignores normal mutable directory metadata", %{dir: dir} do
    site = published_site!(dir, "ancestor-metadata-churn", "payload")
    counter = start_supervised!({Agent, fn -> 0 end})

    lstat = fn path ->
      case File.lstat(path) do
        {:ok, %File.Stat{type: :directory} = stat} ->
          delta = Agent.get_and_update(counter, fn value -> {value, value + 1} end)
          {:ok, %File.Stat{stat | size: stat.size + delta + 1}}

        result ->
          result
      end
    end

    assert_endpoint_verified(EpochStore.verify_mutation(dir, site.request, lstat: lstat))
  end

  test "PublishedProof binds the finalize gap to typed cleanup evidence in both directions" do
    published = published_proof!()
    finalized = PublishedProof.endpoint_finalized("ordinal:0", %{phase: "committed"})

    non_owned_mismatch =
      PublishedProof.endpoint_finalize_failed(:mismatch, "ordinal:1", %{owned: false})

    cleanup = PublishedProof.endpoint_cleanup_pending("ordinal:1", %{phase: "committed"})

    {:ok, {:cleanup_pending, mismatch_base}} =
      PublishedProof.classify_finalize(1, [
        {"ordinal:0", finalized},
        {"ordinal:1", non_owned_mismatch}
      ])

    {:ok, {:cleanup_pending, cleanup_base}} =
      PublishedProof.classify_finalize(1, [
        {"ordinal:0", finalized},
        {"ordinal:1", cleanup}
      ])

    # classifier 基准本身必须仍可持久化，确保下面的拒绝来自伪造而非 fixture 失效。
    assert %{"verified" => 1, "finalized" => 1, "debt" => 1, "omitted" => 0} = mismatch_base
    assert %{"verified" => 2, "finalized" => 1, "debt" => 1, "omitted" => 0} = cleanup_base

    for base <- [mismatch_base, cleanup_base] do
      assert {:ok, %{"last_failure" => ^base}} =
               PublishedProof.journal_evidence("finalize_pending", published, base)
    end

    # 上界：proof-passed/未 finalize 的 endpoint 只能由可见 cleanup detail 或 omitted 名额承担，
    # 不能由无关的 proof-failure debt 顶替。
    gap_without_cleanup = %{mismatch_base | "finalized" => 0}

    assert {:error, :invalid_proof_evidence} =
             PublishedProof.journal_evidence("finalize_pending", published, gap_without_cleanup)

    # 下界：可见 cleanup detail 不能被计数改写成"不存在的 gap"。
    cleanup_outside_gap = %{cleanup_base | "finalized" => 2}

    assert {:error, :invalid_proof_evidence} =
             PublishedProof.journal_evidence("finalize_pending", published, cleanup_outside_gap)
  end

  test "PublishedProof rejects an omitted slot claimed as both hidden cleanup and hidden unavailable" do
    published = published_proof!()
    finalized = PublishedProof.endpoint_finalized("ordinal:0", %{phase: "committed"})

    non_owned_mismatch =
      PublishedProof.endpoint_finalize_failed(:mismatch, "ordinal:1", %{owned: false})

    {:ok, {:cleanup_pending, base}} =
      PublishedProof.classify_finalize(1, [
        {"ordinal:0", finalized},
        {"ordinal:1", non_owned_mismatch}
      ])

    assert {:ok, _evidence} =
             PublishedProof.journal_evidence("finalize_pending", published, base)

    # hidden_cleanup = 1、hidden_unavailable = 1，二者互斥却只有一个 omitted 名额；
    # 逐项标量关系全部成立，唯有联合可实现性不成立。
    joint =
      Map.merge(base, %{
        "finalized" => 0,
        "unavailable" => 1,
        "omitted" => 1,
        "debt" => 2
      })

    assert {:error, :invalid_proof_evidence} =
             PublishedProof.journal_evidence("finalize_pending", published, joint)
  end

  test "PublishedProof rejects fallback unavailable whose hidden owned failures are not unavailable" do
    published = published_proof!()

    {:error, {:published_proof_failed, :unavailable, proof_fallback}} =
      PublishedProof.classify(3, [
        {"ordinal:1", PublishedProof.failed(:unavailable, 1, %{owned: false})}
      ])

    {:error, {:published_proof_failed, :unavailable, finalize_fallback}} =
      PublishedProof.classify_finalize(3, [
        {"ordinal:1",
         PublishedProof.endpoint_finalize_failed(:unavailable, "ordinal:1", %{owned: false})}
      ])

    # fallback unavailable 分支：verified + unavailable < required。
    assert %{"verified" => 0, "unavailable" => 1, "required" => 3} = proof_fallback
    assert %{"verified" => 0, "unavailable" => 1, "required" => 3} = finalize_fallback

    assert {:ok, _evidence} =
             PublishedProof.journal_evidence("rollback_pending", nil, proof_fallback)

    assert {:ok, _evidence} =
             PublishedProof.journal_evidence("finalize_pending", published, finalize_fallback)

    # hidden_owned_failure = 1 > hidden_unavailable = 0：至少一个隐藏 owned failure 不是
    # unavailable，classifier 只会选出更高优先级的 corrupt/mismatch，绝不会产出该 outer class。
    forged_proof =
      Map.merge(proof_fallback, %{"observed_owned" => 1, "omitted" => 1, "debt" => 2})

    forged_finalize =
      Map.merge(finalize_fallback, %{"observed_owned" => 1, "omitted" => 1, "debt" => 2})

    assert {:error, :invalid_proof_evidence} =
             PublishedProof.journal_evidence("rollback_pending", nil, forged_proof)

    assert {:error, :invalid_proof_evidence} =
             PublishedProof.journal_evidence("finalize_pending", published, forged_finalize)
  end

  test "PublishedProof validates the source aggregate before any wrapper normalization" do
    maxed = maxed_published_proof!()
    assert length(maxed["degraded"]) == 32
    assert maxed["omitted"] == 0
    assert maxed["debt"] == 32

    {:error, {:published_proof_failed, :placement_drift, drift_detail}} =
      PublishedProof.failed(:placement_drift, 32, %{owned: false})

    {:ok, {:superseded, successor_detail}} = PublishedProof.superseded("ordinal:32")

    # 优先级短路 detail 落在被裁掉的第 32 槽：裁剪绝不能把它洗成匿名 omitted debt。
    for tail_detail <- [drift_detail, successor_detail] do
      forged = Map.put(maxed, "degraded", List.replace_at(maxed["degraded"], 31, tail_detail))

      assert {:error, :invalid_proof_evidence} =
               PublishedProof.journal_evidence("published", forged, nil)
    end

    # 负 omitted 只能被拒绝，不能被裁剪算术"修好"成 0。
    negative_omitted = Map.merge(maxed, %{"omitted" => -1, "debt" => 31})

    assert {:error, :invalid_proof_evidence} =
             PublishedProof.journal_evidence("published", negative_omitted, nil)

    # 尾部重复 identity 必须在裁剪前就被拒绝。
    duplicate_tail =
      Map.put(
        maxed,
        "degraded",
        List.replace_at(maxed["degraded"], 31, Enum.at(maxed["degraded"], 0))
      )

    assert {:error, :invalid_proof_evidence} =
             PublishedProof.journal_evidence("published", duplicate_tail, nil)

    # 已持久化 31 条 proof 只剩一个名额时，cleanup summary 里的 successor 不能靠"只留第一条
    # debt detail"被洗掉。
    {:ok, persisted} = PublishedProof.journal_evidence("finalize_pending", maxed, nil)
    assert length(persisted["published_proof"]["degraded"]) == 31

    finalized = PublishedProof.endpoint_finalized("ordinal:0", %{phase: "committed"})
    cleanup = PublishedProof.endpoint_cleanup_pending("ordinal:1", %{phase: "committed"})

    {:ok, {:superseded, finalize_successor}} =
      PublishedProof.endpoint_finalize_superseded("ordinal:2")

    {:ok, {:cleanup_pending, cleanup_base}} =
      PublishedProof.classify_finalize(1, [
        {"ordinal:0", finalized},
        {"ordinal:1", cleanup}
      ])

    one_slot_cleanup =
      Map.merge(cleanup_base, %{
        "degraded" => cleanup_base["degraded"] ++ [finalize_successor],
        "debt" => 2
      })

    assert {:error, :invalid_proof_evidence} =
             PublishedProof.journal_evidence(
               "finalize_pending",
               persisted["published_proof"],
               one_slot_cleanup
             )
  end

  test "PublishedProof merge rejects a forged 32-detail already-persisted proof" do
    maxed = maxed_published_proof!()
    finalized = PublishedProof.endpoint_finalized("ordinal:0", %{phase: "committed"})
    cleanup = PublishedProof.endpoint_cleanup_pending("ordinal:1", %{phase: "committed"})

    {:ok, {:cleanup_pending, cleanup_base}} =
      PublishedProof.classify_finalize(1, [
        {"ordinal:0", finalized},
        {"ordinal:1", cleanup}
      ])

    # 合法的已持久化 wrapper（31 条 proof）仍必须可 merge，且 proof 逐字节不变。
    {:ok, persisted} = PublishedProof.journal_evidence("finalize_pending", maxed, nil)
    persisted_proof = persisted["published_proof"]

    assert {:ok, %{"published_proof" => merged_proof}} =
             PublishedProof.merge_failure("finalize_pending", persisted, cleanup_base)

    assert merged_proof == persisted_proof
    assert Jason.encode!(merged_proof) == Jason.encode!(persisted_proof)

    # 伪造的 32 条"已持久化" proof 必须被 merge 拒绝，而不是被静默裁成 31 条。
    forged = %{"published_proof" => maxed, "last_failure" => nil}

    assert {:error, :invalid_proof_evidence} =
             PublishedProof.merge_failure("finalize_pending", forged, cleanup_base)
  end

  # --- Fix round 3：universal retained priority + strict merge input ---

  @tag :task1_fix_round3
  test "round3 defect: proof failed aggregate must not launder a retained successor" do
    persisted = persisted_proof!()

    {:error, {:published_proof_failed, :corrupt, base}} =
      PublishedProof.classify(3, [
        {"ordinal:1", PublishedProof.failed(:corrupt, 1, %{owned: true})}
      ])

    {:ok, {:superseded, successor}} = PublishedProof.superseded("ordinal:2")

    # 基准本身合法且可持久化，确保拒绝来自 successor 而非坏 fixture。
    assert %{"status" => "failed", "class" => "corrupt", "omitted" => 0, "debt" => 1} = base

    assert {:ok, _evidence} =
             PublishedProof.journal_evidence("rollback_pending", persisted, base)

    # 只追加一条更高优先级的 successor：任何保留的 successor 都只能由 canonical
    # aggregate superseded 承载，绝不能被 31+1 预算把它裁成匿名 omitted debt。
    forged =
      base
      |> Map.put("degraded", base["degraded"] ++ [successor])
      |> Map.put("debt", 2)

    assert {:error, :invalid_proof_evidence} =
             PublishedProof.journal_evidence("rollback_pending", persisted, forged)
  end

  @tag :task1_fix_round3
  test "round3 defect: finalize failed aggregate must not launder a retained successor" do
    persisted = persisted_proof!()

    {:error, {:published_proof_failed, :corrupt, base}} =
      PublishedProof.classify_finalize(3, [
        {"ordinal:1",
         PublishedProof.endpoint_finalize_failed(:corrupt, "ordinal:1", %{owned: true})}
      ])

    {:ok, {:superseded, successor}} = PublishedProof.endpoint_finalize_superseded("ordinal:2")

    assert %{"status" => "failed", "class" => "corrupt", "omitted" => 0, "debt" => 1} = base

    assert {:ok, _evidence} =
             PublishedProof.journal_evidence("finalize_pending", persisted, base)

    forged =
      base
      |> Map.put("degraded", base["degraded"] ++ [successor])
      |> Map.put("debt", 2)

    assert {:error, :invalid_proof_evidence} =
             PublishedProof.journal_evidence("finalize_pending", persisted, forged)
  end

  @tag :task1_fix_round3
  test "round3 defect: merge rejects an old wrapper whose last_failure is not a durable aggregate" do
    persisted = persisted_proof!()
    cleanup_failure = cleanup_failure!()

    # 老 wrapper 的 last_failure 是 endpoint 残片，从来就不可能是持久化过的 durable 形态；
    # merge 是对可信持久态的替换，不是修复 API，必须拒绝而不是用新 failure 洗白。
    invalid_old = %{
      "published_proof" => persisted,
      "last_failure" => %{
        "scope" => "endpoint",
        "mode" => "finalize",
        "status" => "failed"
      }
    }

    assert {:error, :invalid_proof_evidence} =
             PublishedProof.merge_failure("finalize_pending", invalid_old, cleanup_failure)
  end

  @tag :task1_fix_round3
  test "round3 defect: merge rejects an old wrapper exceeding the 32 retained detail budget" do
    persisted = persisted_proof!()
    maxed_failure = maxed_failure!()

    assert length(persisted["degraded"]) == 31
    assert length(maxed_failure["degraded"]) == 32

    # 31 + 32 = 63 条 retained detail，绝不可能是本契约发出过的 durable wrapper。
    over_budget_old = %{
      "published_proof" => persisted,
      "last_failure" => maxed_failure
    }

    {:error, {:published_proof_failed, :corrupt, replacement}} =
      PublishedProof.classify(3, [
        {"ordinal:1", PublishedProof.failed(:corrupt, 1, %{owned: true})}
      ])

    assert {:error, :invalid_proof_evidence} =
             PublishedProof.merge_failure("rollback_pending", over_budget_old, replacement)
  end

  @tag :task1_fix_round3
  test "round3 control: an independently malformed truncated-tail detail is rejected before trimming" do
    maxed = maxed_published_proof!()
    tail = Enum.at(maxed["degraded"], 31)

    # 非重复、独立畸形的尾部 detail（failed 却没有 class），必须在裁剪之前被拒绝。
    malformed = Map.delete(tail, "class")

    forged = Map.put(maxed, "degraded", List.replace_at(maxed["degraded"], 31, malformed))

    assert {:error, :invalid_proof_evidence} =
             PublishedProof.journal_evidence("published", forged, nil)
  end

  @tag :task1_fix_round3
  test "round3 control: a later owned decisive witness is selected into the sole failure slot" do
    persisted = persisted_proof!()

    mismatches =
      for index <- 1..3 do
        {"ordinal:#{index}", PublishedProof.failed(:mismatch, index, %{owned: false})}
      end

    {:error, {:published_proof_failed, :corrupt, base}} =
      PublishedProof.classify(
        50,
        mismatches ++ [{"ordinal:4", PublishedProof.failed(:corrupt, 4, %{owned: true})}]
      )

    [witness | rest] = base["degraded"]
    assert witness["class"] == "corrupt" and witness["owned"] == true

    # 把决定性 owned witness 挪到列表中段，模拟公共边界上的非 classifier 顺序。
    shuffled =
      Map.put(base, "degraded", Enum.slice(rest, 0, 2) ++ [witness] ++ Enum.drop(rest, 2))

    # 唯一名额必须按语义选出 owned corrupt witness，而不是列表首位。
    {:ok, one_slot} = PublishedProof.journal_evidence("rollback_pending", persisted, shuffled)

    assert [retained] = one_slot["last_failure"]["degraded"]
    assert retained["class"] == "corrupt" and retained["owned"] == true
    assert one_slot["last_failure"]["debt"] == base["debt"]
    assert one_slot["last_failure"]["omitted"] == base["debt"] - 1

    # 预算充足时：witness 前移，其余 detail 保持稳定相对顺序。
    {:ok, full} = PublishedProof.journal_evidence("rollback_pending", nil, shuffled)

    assert Enum.map(full["last_failure"]["degraded"], & &1["endpoint"]) ==
             [witness["endpoint"] | Enum.map(rest, & &1["endpoint"])]
  end

  @tag :task1_fix_round3
  test "round3 control: canonical superseded stays valid when lower-priority drift is retained" do
    {:ok, {:superseded, base}} =
      PublishedProof.classify(1, [{"ordinal:2", PublishedProof.superseded("ordinal:2")}])

    {:error, {:published_proof_failed, :placement_drift, drift}} =
      PublishedProof.failed(:placement_drift, 3, %{owned: false})

    # successor 优先于 placement drift：保留了更低优先级 drift 的 canonical superseded
    # 依然合法，修复不得把优先级顺序反过来。
    with_drift =
      base
      |> Map.put("degraded", base["degraded"] ++ [drift])
      |> Map.put("debt", 2)

    assert {:ok, %{"last_failure" => ^with_drift}} =
             PublishedProof.journal_evidence("rollback_pending", nil, with_drift)
  end

  @tag :task1_fix_round3
  test "round3 control: a valid old wrapper merges and preserves the proof term and bytes" do
    persisted = persisted_proof!()

    {:error, {:published_proof_failed, :corrupt, old_failure}} =
      PublishedProof.classify(3, [
        {"ordinal:1", PublishedProof.failed(:corrupt, 1, %{owned: true})}
      ])

    {:ok, valid_old} =
      PublishedProof.journal_evidence("rollback_pending", persisted, old_failure)

    assert length(valid_old["published_proof"]["degraded"]) +
             length(valid_old["last_failure"]["degraded"]) <= 32

    assert {:ok, merged} =
             PublishedProof.merge_failure("finalize_pending", valid_old, cleanup_failure!())

    assert merged["published_proof"] == valid_old["published_proof"]

    assert Jason.encode!(merged["published_proof"]) ==
             Jason.encode!(valid_old["published_proof"])
  end

  defp persisted_proof!() do
    {:ok, evidence} =
      PublishedProof.journal_evidence("finalize_pending", maxed_published_proof!(), nil)

    evidence["published_proof"]
  end

  defp maxed_failure!() do
    failures =
      for index <- 1..40 do
        {"ordinal:#{index}", PublishedProof.failed(:unavailable, index, %{owned: false})}
      end

    {:error, {:published_proof_failed, :unavailable, failure}} =
      PublishedProof.classify(50, failures)

    failure
  end

  defp cleanup_failure!() do
    {:ok, {:cleanup_pending, cleanup_failure}} =
      PublishedProof.classify_finalize(1, [
        {"ordinal:0", PublishedProof.endpoint_finalized("ordinal:0", %{phase: "committed"})},
        {"ordinal:1", PublishedProof.endpoint_cleanup_pending("ordinal:1", %{phase: "committed"})}
      ])

    cleanup_failure
  end

  defp published_proof!() do
    {:ok, {:verified, published}} =
      PublishedProof.classify(1, [{"local", PublishedProof.verified("local", %{})}])

    published
  end

  defp maxed_published_proof!() do
    failures =
      for index <- 1..32 do
        {"ordinal:#{index}", PublishedProof.failed(:mismatch, index, %{owned: false})}
      end

    {:ok, {:degraded, maxed}} =
      PublishedProof.classify(1, [
        {"local", PublishedProof.verified("local", %{})} | failures
      ])

    maxed
  end

  # --- Task 2 R1：endpoint / trust-boundary RED ---

  @tag :task2_red_endpoint
  test "task2 red: Storage facade and Backend behaviour expose mandatory verify_published" do
    for module <- [
          Maxio.Storage,
          Maxio.Storage.Backend,
          Maxio.Storage.FS,
          Maxio.Storage.ErasureCoded,
          Maxio.Storage.Distributed
        ] do
      assert Code.ensure_loaded?(module)
    end

    # proof 是 backend behaviour，Commit 不得获得布局知识（design D1）。
    assert {:verify_published, 2} in Maxio.Storage.Backend.behaviour_info(:callbacks)

    # facade 是插件 trust boundary，必须经配置 backend 委派。
    assert function_exported?(Maxio.Storage, :verify_published, 2)

    for backend <- [Maxio.Storage.FS, Maxio.Storage.ErasureCoded, Maxio.Storage.Distributed] do
      assert function_exported?(backend, :verify_published, 2)
    end
  end

  @tag :task2_red_endpoint
  test "task2 red: validate_callback_result fails closed on obsolete, wrong-mode and forged results" do
    assert function_exported?(Maxio.Storage.PublishedProof, :validate_callback_result, 2)

    {:ok, {:verified, proof}} =
      PublishedProof.classify(1, [{"local", PublishedProof.verified("local", %{})}])

    {:ok, {:finalized, finalize}} =
      PublishedProof.classify_finalize(1, [
        {"ordinal:0", PublishedProof.endpoint_finalized("ordinal:0", %{})}
      ])

    {:ok, {:verified, endpoint}} = PublishedProof.verified("local", %{})

    # canonical aggregate 原样接受，绝不裁剪/重排/替换。
    assert :ok = PublishedProof.validate_callback_result(:proof, {:ok, {:verified, proof}})
    assert :ok = PublishedProof.validate_callback_result(:finalize, {:ok, {:finalized, finalize}})

    for {mode, result} <- [
          # obsolete tuple
          {:proof, {:ok, :verified}},
          {:finalize, {:ok, :finalized}},
          {:finalize, {:ok, :superseded}},
          # wrong mode
          {:proof, {:ok, {:finalized, finalize}}},
          {:finalize, {:ok, {:verified, proof}}},
          # wrong scope：endpoint summary 永远不是 aggregate callback 结果
          {:proof, {:ok, {:verified, endpoint}}},
          # forged status/class/counts
          {:proof, {:ok, {:verified, %{proof | "verified" => 99}}}},
          {:proof, {:ok, {:verified, Map.put(proof, "class", "corrupt")}}},
          {:proof, {:error, {:published_proof_failed, :fenced, proof}}},
          {:proof, :ok},
          {:proof, nil}
        ] do
      assert {:error, :invalid_proof_result} =
               PublishedProof.validate_callback_result(mode, result)
    end
  end

  @tag :task2_red_endpoint
  test "task2 red: obsolete three-field finalize request is rejected before epoch or backup mutation",
       %{dir: dir} do
    site = published_site!(dir, "t2-obsolete-request", "payload")
    backup_dir = materialize_backup!(dir, site)

    obsolete = %{target: site.target, token: site.token, mutation_id: @id_a}

    assert {:error,
            {:published_proof_failed, :corrupt,
             %{"scope" => "endpoint", "mode" => "finalize", "status" => "failed"}}} =
             EpochStore.finalize_mutation(dir, obsolete)

    assert {:ok, %ObjectEpoch{phase: "published"}} = EpochStore.read(dir, site.target)
    assert File.dir?(backup_dir)
  end

  @tag :task2_red_endpoint
  test "task2 red: nil published fingerprint fails closed before epoch or backup mutation", %{
    dir: dir
  } do
    site = published_site!(dir, "t2-nil-fingerprint", "payload")
    backup_dir = materialize_backup!(dir, site)

    assert {:error,
            {:published_proof_failed, :corrupt,
             %{"scope" => "endpoint", "mode" => "finalize", "status" => "failed"}}} =
             EpochStore.finalize_mutation(
               dir,
               finalize_request(site, expected_fingerprint: nil)
             )

    assert {:ok, %ObjectEpoch{phase: "published"}} = EpochStore.read(dir, site.target)
    assert File.dir?(backup_dir)
  end

  @tag :task2_red_endpoint
  test "task2 red: finalize re-proves published and committed endpoints before backup cleanup", %{
    dir: dir
  } do
    published = published_site!(dir, "t2-reproof-published", "payload")
    published_backup = materialize_backup!(dir, published)
    File.write!(published.meta_path, published.raw_meta <> "\n")

    assert {:error, {:published_proof_failed, :mismatch, %{"mode" => "finalize"}}} =
             EpochStore.finalize_mutation(dir, finalize_request(published))

    assert {:ok, %ObjectEpoch{phase: "published"}} = EpochStore.read(dir, published.target)
    assert File.dir?(published_backup)

    # committed 幂等重放同样必须先复验，不能直接删 backup。
    committed = published_site!(dir, "t2-reproof-committed", "payload", phase: "committed")
    committed_backup = materialize_backup!(dir, committed)
    File.rm!(committed.part_path)

    assert {:error, {:published_proof_failed, :corrupt, %{"mode" => "finalize"}}} =
             EpochStore.finalize_mutation(dir, finalize_request(committed))

    assert File.dir?(committed_backup)
  end

  @tag :task2_red_endpoint
  test "task2 red: finalize returns the endpoint union for finalized and superseded", %{dir: dir} do
    site = published_site!(dir, "t2-finalized", "payload")
    backup_dir = materialize_backup!(dir, site)

    assert {:ok,
            {:finalized,
             %{
               "scope" => "endpoint",
               "mode" => "finalize",
               "status" => "finalized",
               "owned" => true,
               "proof_passed" => true,
               "finalized" => true
             }}} = EpochStore.finalize_mutation(dir, finalize_request(site))

    assert {:ok, %ObjectEpoch{phase: "committed"}} = EpochStore.read(dir, site.target)
    refute File.exists?(backup_dir)

    superseded = published_site!(dir, "t2-superseded", "payload")
    superseded_backup = materialize_backup!(dir, superseded)
    establish_successor!(dir, superseded)

    assert {:ok,
            {:superseded,
             %{
               "scope" => "endpoint",
               "mode" => "finalize",
               "status" => "superseded",
               "owned" => false,
               "class" => "fenced"
             }}} = EpochStore.finalize_mutation(dir, finalize_request(superseded))

    assert File.dir?(superseded_backup)
  end

  @tag :task2_red_endpoint
  test "task2 red: same-token claimed is repaired only by an exact final, otherwise proof error",
       %{dir: dir} do
    debt = published_site!(dir, "t2-claimed-debt", "payload", phase: "claimed")
    debt_backup = materialize_backup!(dir, debt)
    File.write!(debt.meta_path, debt.raw_meta <> "\n")

    # heal 之前这是真实的 endpoint proof failure（same-token 故 owned=true，
    # proof_passed=false），绝不能伪装成 proof-passed 的 cleanup debt。
    assert {:error,
            {:published_proof_failed, :mismatch,
             %{
               "scope" => "endpoint",
               "mode" => "finalize",
               "status" => "failed",
               "class" => "mismatch",
               "owned" => true,
               "proof_passed" => false,
               "finalized" => false
             }}} = EpochStore.finalize_mutation(dir, finalize_request(debt))

    assert {:ok, %ObjectEpoch{phase: "claimed"}} = EpochStore.read(dir, debt.target)
    assert File.dir?(debt_backup)

    # 写回 exact final 后重试必须收敛为 finalized。
    File.write!(debt.meta_path, debt.raw_meta)

    assert {:ok, {:finalized, %{"mode" => "finalize", "finalized" => true}}} =
             EpochStore.finalize_mutation(dir, finalize_request(debt))

    assert {:ok, %ObjectEpoch{phase: "committed", fingerprint: healed_fingerprint}} =
             EpochStore.read(dir, debt.target)

    assert healed_fingerprint == debt.fingerprint
    refute File.exists?(debt_backup)

    # heal 写回 exact final 后，claimed repair 才可收敛为带 fingerprint 的 committed。
    healed = published_site!(dir, "t2-claimed-heal", "payload", phase: "claimed")
    healed_backup = materialize_backup!(dir, healed)

    assert {:ok, {:finalized, %{"mode" => "finalize", "finalized" => true}}} =
             EpochStore.finalize_mutation(dir, finalize_request(healed))

    assert {:ok, %ObjectEpoch{phase: "committed", fingerprint: fingerprint}} =
             EpochStore.read(dir, healed.target)

    assert fingerprint == healed.fingerprint
    refute File.exists?(healed_backup)
  end

  @tag :task2_red_endpoint
  test "task2 red: finalize emits bounded orphan evidence for absent and older-token epochs", %{
    dir: dir
  } do
    absent_target = target("t2-orphan-absent")
    {:ok, absent_rel} = Paths.object_rel(@bucket, "t2-orphan-absent", "null")

    absent_request = %{
      target: absent_target,
      token: token(1, @id_a),
      mutation_id: @id_a,
      final_rel: absent_rel,
      expected_fingerprint: ObjectEpoch.fingerprint("etag-absent", 0, "meta"),
      layout: %{kind: "fs"}
    }

    assert {:ok,
            {:orphan,
             %{
               "scope" => "endpoint",
               "mode" => "finalize",
               "status" => "orphan",
               "owned" => false,
               "proof_passed" => false,
               "finalized" => false,
               "orphan_reason" => "epoch_absent"
             }}} = EpochStore.finalize_mutation(dir, absent_request)

    # exact target 且 epoch token 严格更旧 → 该端点从未参与本次 mutation。
    older = published_site!(dir, "t2-orphan-older", "payload")
    older_backup = materialize_backup!(dir, older)

    newer_request =
      finalize_request(older, token: token(2, @id_b), mutation_id: @id_b)

    assert {:ok, {:orphan, %{"orphan_reason" => "older_token", "owned" => false}}} =
             EpochStore.finalize_mutation(dir, newer_request)

    # orphan 绝不授权删除。
    assert File.dir?(older_backup)
    assert File.exists?(older.part_path)
  end

  @tag :task2_red_endpoint
  test "task2 red: a same-token claimed proof failure votes as real owned debt in the aggregate",
       %{dir: dir} do
    shards = [
      %{"drive" => 0, "shard_file_size" => 7, "block_hashes" => []},
      %{"drive" => 1, "shard_file_size" => 7, "block_hashes" => []}
    ]

    claimed =
      published_site!(dir, "t2-agg-claimed", "payload",
        phase: "claimed",
        layout: %{kind: "shard", index: 1},
        shards: shards
      )

    claimed_backup = materialize_backup!(dir, claimed)
    File.rm_rf!(claimed.final_dir)

    assert {:error, {:published_proof_failed, _class, claimed_detail}} =
             claimed_result = EpochStore.finalize_mutation(dir, finalize_request(claimed))

    assert claimed_detail["endpoint"] == "ordinal:1"
    assert claimed_detail["owned"] == true
    assert claimed_detail["proof_passed"] == false
    assert {:ok, %ObjectEpoch{phase: "claimed"}} = EpochStore.read(dir, claimed.target)
    assert File.dir?(claimed_backup)

    # 没有任何健康 proof quorum 时，整体必须是 proof failure。
    assert {:error, {:published_proof_failed, _global_class, %{"verified" => 0}}} =
             PublishedProof.classify_finalize(1, [{"ordinal:1", claimed_result}])

    healthy =
      published_site!(dir, "t2-agg-healthy", "payload",
        layout: %{kind: "shard", index: 0},
        shards: shards
      )

    assert {:ok, {:finalized, _}} =
             healthy_result = EpochStore.finalize_mutation(dir, finalize_request(healthy))

    # 只有在另有真实健康 proof quorum 时，同一 owned debt 才让整体成为 cleanup_pending；
    # 票数全部来自真实 endpoint 结果，未手工伪造。
    assert {:ok,
            {:cleanup_pending,
             %{"verified" => 1, "finalized" => 1, "observed_owned" => 2, "debt" => 1}}} =
             PublishedProof.classify_finalize(1, [
               {"ordinal:0", healthy_result},
               {"ordinal:1", claimed_result}
             ])
  end

  @tag :task2_red_endpoint
  test "task2 control: endpoint proof evidence exposes no absolute path or raw sidecar", %{
    dir: dir
  } do
    site = published_site!(dir, "t2-no-leak", "payload")

    assert {:ok, {:verified, summary}} = EpochStore.verify_mutation(dir, site.request)

    refute Enum.any?(~w(path root drive node final_rel backup), &Map.has_key?(summary, &1))

    rendered = inspect(summary)
    refute rendered =~ dir
    refute rendered =~ site.raw_meta
    refute rendered =~ "part.0"
  end

  defp finalize_request(site, overrides \\ []) do
    %{
      target: site.target,
      token: site.token,
      mutation_id: @id_a,
      final_rel: site.final_rel,
      expected_fingerprint: site.fingerprint,
      # 继承该 site 的冻结 layout（fs 或 shard:N），identity 才与聚合期望一致。
      layout: site.request.layout
    }
    |> Map.merge(Map.new(overrides))
  end

  defp materialize_backup!(dir, site) do
    mutation_id = Map.get(site, :mutation_id, @id_a)
    backup_dir = Path.join(dir, MutationBackup.relative_dir(mutation_id))
    File.mkdir_p!(backup_dir)

    {:ok, manifest} =
      MutationBackup.manifest(site.target, site.token, nil, [%{"name" => "part.0"}])

    {:ok, bytes} = MutationBackup.encode(manifest)
    File.write!(Path.join(backup_dir, MutationBackup.manifest_name()), bytes)
    backup_dir
  end

  defp establish_successor!(dir, site) do
    successor = token(2, @id_b)

    {:ok, epoch} =
      ObjectEpoch.new(site.target, successor, %{
        operation: "put",
        phase: "claimed",
        value_type: "object",
        updated_at: DateTime.utc_now()
      })

    assert {:ok, :applied} = EpochStore.cas(dir, epoch, {:claim, successor})
    successor
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
      Keyword.get_lazy(opts, :core, fn ->
        %{
          "format" => "maxio/2",
          "etag" => Keyword.get(opts, :etag, "etag-#{key}"),
          "size" => core_size,
          "sha256" => String.duplicate("a", 64),
          "versions" => [
            %{
              "version_id" => "null",
              "etag" => "s3-visible-etag",
              "size" => 999,
              "type" => "object"
            }
          ]
        }
        |> maybe_put("shards", Keyword.get(opts, :shards))
        |> Map.merge(Keyword.get(opts, :core_overrides, %{}))
      end)

    raw_meta = Keyword.get(opts, :raw_meta, Jason.encode!(core))
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

  defp overwrite_epoch_file!(
         dir,
         path_target,
         decoded_target,
         tok,
         phase,
         fingerprint
       ) do
    {:ok, epoch} =
      ObjectEpoch.new(decoded_target, tok, %{
        operation: "put",
        phase: phase,
        value_type: "object",
        fingerprint: fingerprint,
        updated_at: DateTime.utc_now()
      })

    {:ok, bytes} = ObjectEpoch.encode(epoch)
    {:ok, rel} = ObjectEpoch.relative_path(path_target)
    File.write!(Path.join(dir, rel), bytes)
  end

  defp exact_limit_sidecar(key) do
    core = %{
      "format" => "maxio/2",
      "etag" => "etag-#{key}",
      "size" => 7,
      "sha256" => String.duplicate("b", 64),
      "versions" => [
        %{
          "version_id" => "null",
          "type" => "object",
          "etag" => "visible",
          "size" => 7
        }
      ],
      "padding" => ""
    }

    base = Jason.encode!(core)
    padding_size = @sidecar_limit - byte_size(base)
    padded = Map.put(core, "padding", String.duplicate("x", padding_size))
    raw = Jason.encode!(padded)
    assert byte_size(raw) == @sidecar_limit
    {padded, raw}
  end

  defp assert_proof_failure(class, result) do
    assert {:error,
            {:published_proof_failed, ^class,
             %{
               "scope" => "endpoint",
               "status" => "failed",
               "owned" => _owned,
               "endpoint" => _endpoint
             }}} = result
  end

  defp assert_endpoint_verified(result) do
    assert {:ok,
            {:verified,
             %{
               "scope" => "endpoint",
               "mode" => "proof",
               "status" => "verified",
               "owned" => true,
               "endpoint" => _endpoint
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

  defp failure_endpoint({:error, {:published_proof_failed, _class, %{"endpoint" => endpoint}}}),
    do: endpoint

  defp same_path?(left, right) do
    left = Path.expand(left)
    right = Path.expand(right)

    if match?({:win32, _name}, :os.type()),
      do: String.downcase(left) == String.downcase(right),
      else: left == right
  end

  defp create_junction!(link, target) do
    assert_safe_link!(Path.dirname(Path.dirname(link)), link, target)
    link_native = String.replace(link, "/", "\\")
    target_native = String.replace(target, "/", "\\")

    {output, status} =
      System.cmd(
        "cmd.exe",
        ["/d", "/c", "mklink", "/J", link_native, target_native],
        stderr_to_stdout: true
      )

    if status != 0 or not File.exists?(link) do
      flunk("failed to create Windows junction: status=#{status}, output=#{inspect(output)}")
    end
  end

  defp assert_safe_link!(owner, link, target) do
    owner = Path.expand(owner)
    link = Path.expand(link)
    target = Path.expand(target)

    unless strict_descendant?(link, owner) and strict_descendant?(target, owner) and
             link != target and
             not String.contains?(link <> target, ["\"", "\r", "\n", "&", "|", "<", ">", "^"]) do
      raise "unsafe test junction path"
    end

    :ok
  end

  defp strict_descendant?(path, owner) do
    relative = Path.relative_to(path, owner)

    Path.type(relative) == :relative and relative != "." and
      not String.starts_with?(relative, "..")
  end

  # --- Task 3 R1：非变异 durable validator + exact 60 KiB 尺寸门 ---
  #
  # 正式 design D6/D7 与 plan Task 3 Step 1/Step 3 要求
  # `PublishedProof.validate_durable_evidence(target_phase, evidence)` 是**只读**
  # trust boundary，返回值只能是标量 `:ok | {:error, :invalid_proof_evidence}`：不裁剪、
  # 不重排、不修 omitted，也绝不返回 replacement map。
  #
  # 【G1-FIX-R2 修订】原先把 exact-61,440 huge-counter wrapper 当作 size-positive 的断言
  # 已被批准的 durable-JSON adjudication 推翻：只改十进制位宽推到 61,440 / 61,441 byte 的
  # wrapper，其计数器十进制 token 远超 1,024 bytes，Jason 根本解不回来，因此**两者都不是
  # durable evidence**，都必须被公共 durable 边界拒绝。61,440/61,441 的**尺寸谓词**改由中性
  # 共享 helper 用 codec-roundtrippable 字符串 payload 在 `test/maxio/durable_json_test.exs`
  # 中隔离；PublishedProof 的 exact call-site profile 由独立 G1-FIX-G code review 判定，
  # 不靠脆弱的 source-regex RED。Journal 的 65,536/65,537 generic 门是另一个域，其 fixture
  # 保留在 `test/maxio/object_mutation_test.exs`。

  defp task3_durable_validator!() do
    assert Code.ensure_loaded?(PublishedProof)

    assert function_exported?(PublishedProof, :validate_durable_evidence, 2),
           "T3-R1: Maxio.Storage.PublishedProof.validate_durable_evidence/2 尚未实现" <>
             "（正式 design D7 / plan Task 3 Step 1）"
  end

  defp task3_validate_durable(target_phase, evidence) do
    task3_durable_validator!()
    PublishedProof.validate_durable_evidence(target_phase, evidence)
  end

  defp task3_success_wrapper!() do
    {:ok, wrapper} =
      PublishedProof.journal_evidence("finalize_pending", maxed_published_proof!(), nil)

    wrapper
  end

  defp task3_nil_proof_wrapper!() do
    {:error, {:published_proof_failed, :unavailable, failure}} =
      PublishedProof.classify(1, [
        {"local", PublishedProof.failed(:unavailable, "local", %{owned: true})}
      ])

    {:ok, wrapper} = PublishedProof.journal_evidence("rollback_pending", nil, failure)
    wrapper
  end

  defp task3_cleanup_wrapper!() do
    {:ok, wrapper} =
      PublishedProof.journal_evidence("finalize_pending", published_proof!(), cleanup_failure!())

    wrapper
  end

  # canonical verified aggregate proof：degraded 为空、debt/omitted/unavailable 全零，
  # observed_owned 必须恰等于 verified，required ≤ verified。计数器位宽是唯一自由维度。
  defp canonical_verified_proof(required, verified) do
    %{
      "scope" => "aggregate",
      "mode" => "proof",
      "status" => "verified",
      "required" => required,
      "verified" => verified,
      "observed_owned" => verified,
      "unavailable" => 0,
      "degraded" => [],
      "omitted" => 0,
      "debt" => 0
    }
  end

  # 按 `byte_size(Jason.encode!/1)` 精确校准到 total：固定开销实测得出，剩余字节由
  # required（1~2 位）与 verified/observed_owned（同一位宽计两次）的十进制位宽承担。
  defp canonical_wrapper_of_bytes!(total) do
    probe = %{"published_proof" => canonical_verified_proof(1, 1), "last_failure" => nil}
    overhead = byte_size(Jason.encode!(probe)) - 3
    remaining = total - overhead

    {required_digits, verified_digits} =
      if rem(remaining, 2) == 1,
        do: {1, div(remaining - 1, 2)},
        else: {2, div(remaining - 2, 2)}

    assert verified_digits >= required_digits

    required = Integer.pow(10, required_digits - 1)
    verified = Integer.pow(10, verified_digits - 1)

    wrapper = %{
      "published_proof" => canonical_verified_proof(required, verified),
      "last_failure" => nil
    }

    assert byte_size(Jason.encode!(wrapper)) == total
    wrapper
  end

  @tag :task3_red_core
  test "task3 red: durable validator accepts the exact persisted wrapper as a scalar with no replacement" do
    wrapper = task3_success_wrapper!()
    rebuilt = task3_success_wrapper!()

    # 成功 proof 初次持久化只保留 31 条 detail：合法 durable 形态。
    assert length(wrapper["published_proof"]["degraded"]) == 31
    assert is_nil(wrapper["last_failure"])

    # 返回值必须是标量 `:ok`，绝不是 `{:ok, replacement}`。
    assert task3_validate_durable("finalize_pending", wrapper) == :ok

    # 被接受的持久化 fixture 的 term 与编码字节必须与独立重建结果完全一致。
    assert wrapper == rebuilt
    assert Jason.encode!(wrapper) == Jason.encode!(rebuilt)

    # nil-proof failure wrapper 是 rollback domain 的合法 durable 形态。
    assert task3_validate_durable("rollback_pending", task3_nil_proof_wrapper!()) == :ok

    # 已 merge 的 wrapper（成功 proof + finalize last failure）同样必须原样通过。
    {:ok, merged} = PublishedProof.merge_failure("finalize_pending", wrapper, cleanup_failure!())
    assert task3_validate_durable("finalize_pending", merged) == :ok
  end

  @tag :task3_red_core
  test "task3 red: durable validator rejects malformed wrappers with the exact scalar error" do
    wrapper = task3_success_wrapper!()
    proof = wrapper["published_proof"]

    rejected = [
      # 缺 key / 多 key：canonical wrapper 精确两个 key。
      %{"published_proof" => proof},
      %{"last_failure" => nil},
      Map.put(wrapper, "extra", "x"),
      # nil/nil 从来不是合法 proof evidence。
      %{"published_proof" => nil, "last_failure" => nil},
      # 伪造的 32 条"已持久化" proof 必须拒绝，而不是被静默裁成 31 条。
      %{"published_proof" => maxed_published_proof!(), "last_failure" => nil},
      # endpoint 残片永远不是 aggregate durable 形态。
      %{
        "published_proof" => proof,
        "last_failure" => %{"scope" => "endpoint", "mode" => "finalize", "status" => "failed"}
      },
      # generic operational evidence 属另一个 domain，绝不能冒充 canonical wrapper。
      %{
        "authority_mode" => "pg",
        "stage" => "verify_published",
        "outcome" => "contract_violation",
        "mode" => "proof"
      },
      # 非 map / 非 wrapper。
      nil,
      "published"
    ]

    for evidence <- rejected do
      assert task3_validate_durable("finalize_pending", evidence) ==
               {:error, :invalid_proof_evidence}
    end
  end

  @tag :task3_red_core
  test "task3 red: durable validator phase domain is exactly the canonical wrapper phases" do
    success = task3_success_wrapper!()
    nil_proof = task3_nil_proof_wrapper!()

    # PG 成功 proof 必须存在的 phase。
    for phase <- ~w(published metadata_committed finalize_pending finalized) do
      assert task3_validate_durable(phase, success) == :ok
    end

    # rollback/quarantine domain 同时接受成功 wrapper 与 nil-proof failure wrapper。
    for phase <- ~w(rollback_pending rolled_back quarantined) do
      assert task3_validate_durable(phase, success) == :ok
      assert task3_validate_durable(phase, nil_proof) == :ok
    end

    # proof 之前的 phase、未知 phase 与一切非 binary phase 一律拒绝。
    for phase <- ["prepared", "claimed", "", "PUBLISHED", "unknown"] do
      assert task3_validate_durable(phase, success) == {:error, :invalid_proof_evidence}
    end

    for phase <- [:finalize_pending, nil, 1, ["published"]] do
      assert task3_validate_durable(phase, success) == {:error, :invalid_proof_evidence}
    end

    # nil-proof failure 在要求成功 proof 的 PG phase 上非法。
    for phase <- ~w(published metadata_committed finalize_pending finalized) do
      assert task3_validate_durable(phase, nil_proof) == {:error, :invalid_proof_evidence}
    end
  end

  @tag :task3_red_core
  test "task3 red: durable validator rejects both huge-counter wrappers as non-durable" do
    at_ceiling = canonical_wrapper_of_bytes!(61_440)
    over_ceiling = canonical_wrapper_of_bytes!(61_441)

    assert byte_size(Jason.encode!(at_ceiling)) == 61_440
    assert byte_size(Jason.encode!(over_ceiling)) == 61_441

    # 两个 fixture 只在 required 计数器的十进制位宽上不同，语义上都是 canonical verified。
    assert at_ceiling["published_proof"]["status"] == "verified"
    assert over_ceiling["published_proof"]["status"] == "verified"
    assert at_ceiling["published_proof"]["degraded"] == []
    assert over_ceiling["published_proof"]["degraded"] == []

    assert at_ceiling["published_proof"]["verified"] ==
             at_ceiling["published_proof"]["observed_owned"]

    assert over_ceiling["published_proof"]["verified"] ==
             over_ceiling["published_proof"]["observed_owned"]

    # 二者的计数器十进制 token 都远超 1,024 bytes，因此 Jason 无法把自己的编码结果解回来：
    # 它们从来就不是可持久化的 durable evidence，**都不是 size-positive**。
    for wrapper <- [at_ceiling, over_ceiling] do
      counter = wrapper["published_proof"]["verified"]
      assert byte_size(Integer.to_string(counter)) > 1_024
      assert match?({:error, _reason}, Jason.decode(Jason.encode!(wrapper)))
    end

    # 因此在全部七个 canonical phase 上都必须被公共 durable 边界拒绝。
    for phase <-
          ~w(published metadata_committed finalize_pending finalized
             rollback_pending rolled_back quarantined) do
      assert task3_validate_durable(phase, at_ceiling) == {:error, :invalid_proof_evidence},
             "exact-61,440 huge-counter wrapper 不是 durable evidence：#{phase}"

      assert task3_validate_durable(phase, over_ceiling) == {:error, :invalid_proof_evidence}
    end
  end

  @tag :task3_red_core
  test "task3 red: durable validator rejects missing witnesses, impossible slots and phase mismatches" do
    cleanup_wrapper = task3_cleanup_wrapper!()
    success = task3_success_wrapper!()

    # 起点必须是被接受的 canonical 控制，随后只改动一个具名谓词。
    assert task3_validate_durable("finalize_pending", cleanup_wrapper) == :ok

    # 1) 缺失强制 decisive/debt witness：cleanup pending 的可见 cleanup detail 被挪进
    #    匿名 omitted，debt 仍守恒，但决定性事实消失。
    failure = cleanup_wrapper["last_failure"]

    witnessless =
      Map.put(cleanup_wrapper, "last_failure", %{
        failure
        | "degraded" => [],
          "omitted" => failure["omitted"] + length(failure["degraded"])
      })

    assert task3_validate_durable("finalize_pending", witnessless) ==
             {:error, :invalid_proof_evidence}

    # 2) 不可实现的 hidden slot 分配。基线必须是 omitted=0 的最小 proof，否则多出的一个
    #    owned failure 仍可由既有隐藏名额承载，谓词就没有被真正隔离。
    {:ok, minimal} = PublishedProof.journal_evidence("finalize_pending", published_proof!(), nil)
    minimal_proof = minimal["published_proof"]

    assert minimal_proof["omitted"] == 0
    assert minimal_proof["degraded"] == []
    assert minimal_proof["observed_owned"] == minimal_proof["verified"]
    assert task3_validate_durable("finalize_pending", minimal) == :ok

    # observed_owned 超过 verified + 可见 owned failure + omitted，隐藏名额无法承载。
    impossible_slots =
      Map.put(minimal, "published_proof", %{
        minimal_proof
        | "observed_owned" => minimal_proof["verified"] + minimal_proof["omitted"] + 1
      })

    assert task3_validate_durable("finalize_pending", impossible_slots) ==
             {:error, :invalid_proof_evidence}

    # 同一条不变量在 31-detail 的成功 wrapper 上同样成立：越过其可见上界一位即非法。
    proof = success["published_proof"]
    visible_owned = Enum.count(proof["degraded"], &(&1["owned"] == true))

    assert task3_validate_durable(
             "finalize_pending",
             Map.put(success, "published_proof", %{
               proof
               | "observed_owned" => proof["verified"] + visible_owned + proof["omitted"] + 1
             })
           ) == {:error, :invalid_proof_evidence}

    # 3) phase 专属 finalize last_failure：精确接受 metadata/finalize 之后的四个 phase。
    for phase <- ~w(metadata_committed finalize_pending finalized quarantined) do
      assert task3_validate_durable(phase, cleanup_wrapper) == :ok
    end

    # 并在 published 与整个 rollback domain 上拒绝。
    for phase <- ~w(published rollback_pending rolled_back) do
      assert task3_validate_durable(phase, cleanup_wrapper) == {:error, :invalid_proof_evidence}
    end

    # 4) 非法 nil-proof / finalize 组合：nil proof 只能承载 proof-mode failure/superseded。
    nil_proof_finalize = %{"published_proof" => nil, "last_failure" => failure}

    for phase <- ~w(rollback_pending rolled_back quarantined finalize_pending) do
      assert task3_validate_durable(phase, nil_proof_finalize) ==
               {:error, :invalid_proof_evidence}
    end
  end

  @tag :task3_red_core
  test "task3 control: canonical wrapper budget and merge byte stability hold under the frozen contract" do
    wrapper = task3_success_wrapper!()
    {:ok, merged} = PublishedProof.merge_failure("finalize_pending", wrapper, cleanup_failure!())

    # 初次持久化成功 proof 最多 31 条，为后续 merge 的强制 witness 预留一条。
    assert length(wrapper["published_proof"]["degraded"]) == 31

    retained =
      length(merged["published_proof"]["degraded"]) +
        length(merged["last_failure"]["degraded"]) +
        length(Map.get(merged["last_failure"], "orphan_hints", []))

    assert retained <= 32

    # merge 保持初始 published proof 逐字节不变，并留在 60 KiB 之内。
    assert merged["published_proof"] == wrapper["published_proof"]

    assert Jason.encode!(merged["published_proof"]) ==
             Jason.encode!(wrapper["published_proof"])

    assert byte_size(Jason.encode!(merged)) <= 61_440

    # nil-proof failure 与 cleanup wrapper 亦是合法 fixture，证明 RED 失败来自缺失能力。
    assert %{"published_proof" => nil, "last_failure" => %{"mode" => "proof"}} =
             task3_nil_proof_wrapper!()

    assert %{"last_failure" => %{"mode" => "finalize", "status" => "cleanup_pending"}} =
             task3_cleanup_wrapper!()
  end

  @tag :task3_red_core
  test "task3 red: journal_evidence never persists a huge-counter wrapper at either byte width" do
    at_ceiling = canonical_wrapper_of_bytes!(61_440)
    over_ceiling = canonical_wrapper_of_bytes!(61_441)

    assert byte_size(Jason.encode!(at_ceiling)) == 61_440
    assert byte_size(Jason.encode!(over_ceiling)) == 61_441

    # 持久化入口与 durable validator 共用同一条 durable-JSON 边界：两个 huge-counter
    # wrapper 的编码字节都无法被解回，因此都不得被发出为 durable evidence。
    for wrapper <- [at_ceiling, over_ceiling] do
      assert PublishedProof.journal_evidence(
               "finalize_pending",
               wrapper["published_proof"],
               nil
             ) == {:error, :invalid_proof_evidence}
    end
  end

  # --- Task 3 / G1-FIX-R2：公共 PublishedProof durability（与共享 helper 能力独立）---
  #
  # 这些用例只行使**既有公共 PublishedProof 边界**，不触碰 `Maxio.DurableJSON`：缺失共享
  # helper 绝不能掩盖公共 PublishedProof 是否真的被行使（adjudication「独立 failure
  # signature」）。真实 transaction-scoped JSONB 往返控制需要 Repo，落在
  # `test/maxio/object_mutation_test.exs`。

  # adjudication §「clean intended-canonical wrapper」的确定性配方：所有出现的 `n` 都恰好是
  # 1,024-byte 正整数 token，32 条 retained detail 全部来自公共 endpoint constructor，
  # 且不含任何已知 over-permissive detail 字段。
  defp g1r2_huge_token_integer, do: Integer.pow(10, 1_023)

  defp g1r2_safe_label, do: String.duplicate("a", 128)

  defp g1r2_detail_identity(index) do
    "ordinal:" <>
      String.duplicate("9", 118) <> String.pad_leading(Integer.to_string(index), 2, "0")
  end

  defp g1r2_clean_degraded_proof do
    n = g1r2_huge_token_integer()

    %{
      "scope" => "aggregate",
      "mode" => "proof",
      "status" => "degraded",
      "required" => n,
      "verified" => n,
      "observed_owned" => n,
      "unavailable" => n,
      "degraded" => [],
      "omitted" => n,
      "debt" => n
    }
  end

  defp g1r2_clean_finalize_failure do
    n = g1r2_huge_token_integer()
    label = g1r2_safe_label()

    details =
      for index <- 1..32 do
        identity = g1r2_detail_identity(index)
        assert byte_size(identity) == 128

        {:error, {:published_proof_failed, :unavailable, summary}} =
          PublishedProof.endpoint_finalize_failed(:unavailable, identity, %{
            owned: false,
            code: label,
            layout: label,
            phase: label
          })

        refute Map.has_key?(summary, "orphan_reason")
        assert summary["owned"] == false
        summary
      end

    %{
      "scope" => "aggregate",
      "mode" => "finalize",
      "status" => "failed",
      "class" => "unavailable",
      "required" => n + 1,
      "verified" => n,
      "finalized" => n,
      "observed_owned" => n,
      "unavailable" => n,
      "omitted" => n,
      "debt" => n + 32,
      "orphaned" => n,
      "orphan_omitted" => n,
      "orphan_hints" => [],
      "degraded" => details
    }
  end

  # 只经公共 `journal_evidence/3` 发出，绝不手工拼装 wrapper map。
  defp g1r2_clean_large_wrapper! do
    {:ok, wrapper} =
      PublishedProof.journal_evidence(
        "finalize_pending",
        g1r2_clean_degraded_proof(),
        g1r2_clean_finalize_failure()
      )

    wrapper
  end

  @tag :task3_g1_review_red
  test "g1r2 control: a clean intended-canonical wrapper is above 32 KiB, within 60 KiB and Jason-strict" do
    wrapper = g1r2_clean_large_wrapper!()
    encoded = Jason.encode!(wrapper)

    # 实测编码尺寸严格大于 32 KiB 且不超过 60 KiB：因此把 formal ceiling 降到 32 KiB
    # 会让这个已被证明干净的 canonical wrapper 变成不必要的回归。
    assert byte_size(encoded) > 32 * 1024
    assert byte_size(encoded) <= 60 * 1024

    # 公共 durable validator 原样接受，且严格 codec 往返。
    assert PublishedProof.validate_durable_evidence("finalize_pending", wrapper) == :ok
    assert Jason.decode!(encoded) === wrapper

    # 该 fixture 的每一个整数 token 都在 1,024-byte 边界内，detail 全部来自公共 constructor。
    assert length(wrapper["last_failure"]["degraded"]) == 32
    assert wrapper["published_proof"]["degraded"] == []
    assert wrapper["last_failure"]["orphan_hints"] == []

    # 这不是一个穷尽的公共最大值声明：只是一个被四重取证的干净正控。
    assert byte_size(Integer.to_string(wrapper["published_proof"]["verified"])) == 1_024
  end

  @tag :task3_g1_review_red
  test "g1r2 red: neither huge-counter wrapper is a public PublishedProof size-positive" do
    at_ceiling = canonical_wrapper_of_bytes!(61_440)
    over_ceiling = canonical_wrapper_of_bytes!(61_441)

    assert byte_size(Jason.encode!(at_ceiling)) == 61_440
    assert byte_size(Jason.encode!(over_ceiling)) == 61_441

    # 独立于共享 helper 的公共边界断言：两者都必须被 `validate_durable_evidence/2` 拒绝。
    for wrapper <- [at_ceiling, over_ceiling] do
      assert PublishedProof.validate_durable_evidence("finalize_pending", wrapper) ==
               {:error, :invalid_proof_evidence}

      assert PublishedProof.validate_durable_evidence("rollback_pending", wrapper) ==
               {:error, :invalid_proof_evidence}
    end
  end

  # --- Task 3 / G1-FIX-G-R1：公共 durable validator 必须对任意 term 总函数化 ---
  #
  # 独立审查 I1-A：`degraded` 是外部持久化 term，`is_list/1` 只证明它是 list，**不证明它是
  # proper list**——improper list 同样满足 `is_list/1`，随后的 `length/1` 会抛
  # `ArgumentError: :erlang.length([%{} | 7])`。该异常穿过 persisted-wrapper 校验路径，
  # 一路逃逸到 `ObjectMutation.request_rollback/3`，违反「畸形外部证据必须精确
  # fail closed」的公共契约。
  #
  # 下面用**公共 constructor 产出的合法 canonical wrapper**做基线，只把目标 list 字段替换成
  # improper list，因此拒绝不可能来自任何无关的先前原因。

  defp improper_list_from(list), do: [hd(list) | 7]

  @tag :task3_g1_green_review_correction
  test "g1 correction: an improper published_proof.degraded is rejected without raising" do
    wrapper = task3_success_wrapper!()
    proof = wrapper["published_proof"]

    # 基线本身必须是被接受的 canonical wrapper。
    assert PublishedProof.validate_durable_evidence("finalize_pending", wrapper) == :ok
    assert length(proof["degraded"]) == 31

    malformed =
      Map.put(wrapper, "published_proof", %{
        proof
        | "degraded" => improper_list_from(proof["degraded"])
      })

    refute Enum.empty?(proof["degraded"])

    assert PublishedProof.validate_durable_evidence("finalize_pending", malformed) ==
             {:error, :invalid_proof_evidence}
  end

  @tag :task3_g1_green_review_correction
  test "g1 correction: improper lists in every persisted-external list field fail closed" do
    cleanup = task3_cleanup_wrapper!()
    failure = cleanup["last_failure"]

    assert PublishedProof.validate_durable_evidence("finalize_pending", cleanup) == :ok
    refute Enum.empty?(failure["degraded"])

    # 每一个可从持久化 wrapper 抵达的 list 字段都必须结构性总函数化，而不只是首个被复现的
    # `published_proof.degraded`。
    variants = [
      {"last_failure.degraded",
       Map.put(cleanup, "last_failure", %{
         failure
         | "degraded" => improper_list_from(failure["degraded"])
       })},
      {"last_failure.orphan_hints",
       Map.put(cleanup, "last_failure", %{failure | "orphan_hints" => [%{} | 7]})},
      {"published_proof.degraded",
       Map.put(cleanup, "published_proof", %{
         cleanup["published_proof"]
         | "degraded" => [%{} | 7]
       })}
    ]

    for {label, malformed} <- variants do
      assert PublishedProof.validate_durable_evidence("finalize_pending", malformed) ==
               {:error, :invalid_proof_evidence},
             "improper list 必须精确 fail closed 而不是抛异常：#{label}"
    end
  end

  @tag :task3_g1_green_review_correction
  test "g1 correction: the public durable validator is total for arbitrary hostile terms" do
    wrapper = task3_success_wrapper!()
    proof = wrapper["published_proof"]

    hostile = [
      Map.put(wrapper, "published_proof", %{proof | "degraded" => [%{} | %{}]}),
      Map.put(wrapper, "published_proof", %{proof | "degraded" => {:not, :a, :list}}),
      Map.put(wrapper, "published_proof", %{proof | "degraded" => "degraded"}),
      Map.put(wrapper, "published_proof", %{proof | "debt" => [1 | 2]})
    ]

    for {malformed, index} <- Enum.with_index(hostile) do
      assert PublishedProof.validate_durable_evidence("finalize_pending", malformed) ==
               {:error, :invalid_proof_evidence},
             "hostile term #{index} 必须精确 fail closed"
    end
  end

  @tag :task3_g1_review_red
  test "g1r2 control: an ordinary canonical wrapper is still accepted unchanged" do
    {:ok, {:verified, proof}} =
      PublishedProof.classify(1, [{"local", PublishedProof.verified("local", %{})}])

    {:ok, wrapper} = PublishedProof.journal_evidence("published", proof, nil)
    encoded = Jason.encode!(wrapper)

    assert PublishedProof.validate_durable_evidence("published", wrapper) == :ok
    assert Jason.encode!(wrapper) == encoded
    assert Jason.decode!(encoded) === wrapper
  end
end
