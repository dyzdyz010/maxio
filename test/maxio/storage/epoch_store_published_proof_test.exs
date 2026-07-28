defmodule Maxio.Storage.EpochStorePublishedProofTest do
  use ExUnit.Case, async: true

  alias Maxio.Cluster.Paths
  alias Maxio.Native.PathSafety
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
end
