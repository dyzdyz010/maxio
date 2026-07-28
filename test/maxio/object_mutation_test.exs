defmodule Maxio.ObjectMutationTest do
  use Maxio.DataCase, async: false

  alias Maxio.ObjectMutation

  @now ~U[2026-07-10 06:00:00.000000Z]

  test "normal graph reaches finalized and committed metadata can never roll back" do
    assert {:ok, row} = ObjectMutation.prepare(attrs(), now: @now)
    assert row.phase == "prepared"

    assert {:ok, row} =
             ObjectMutation.transition(
               row,
               "claimed",
               %{previous_epoch: previous_epoch()},
               now: @now
             )

    assert {:ok, row} =
             ObjectMutation.transition(
               row,
               "published",
               %{published_fingerprint: fingerprint()},
               now: @now
             )

    assert {:ok, row} = ObjectMutation.transition(row, "metadata_committed", %{}, now: @now)
    assert row.metadata_committed_at == @now

    assert {:error, {:illegal_transition, "metadata_committed", "rollback_pending"}} =
             ObjectMutation.transition(row, "rollback_pending", %{}, now: @now)

    assert {:ok, row} = ObjectMutation.transition(row, "finalize_pending", %{}, now: @now)
    assert {:ok, row} = ObjectMutation.transition(row, "finalized", %{}, now: @now)
    assert row.finalized_at == @now

    assert {:error, {:illegal_transition, "finalized", "quarantined"}} =
             ObjectMutation.quarantine(row, :late, %{"check" => "terminal"}, now: @now)
  end

  test "pre-commit failure follows the explicit rollback branch" do
    {:ok, row} = ObjectMutation.prepare(attrs(), now: @now)
    {:ok, row} = ObjectMutation.transition(row, "claimed", %{}, now: @now)

    {:ok, row} =
      ObjectMutation.transition(
        row,
        "published",
        %{published_fingerprint: fingerprint()},
        now: @now
      )

    {:ok, row} = ObjectMutation.transition(row, "rollback_pending", %{}, now: @now)
    assert {:ok, rolled_back} = ObjectMutation.transition(row, "rolled_back", %{}, now: @now)
    assert rolled_back.rolled_back_at == @now
  end

  test "transition CAS is idempotent only at the exact requested phase" do
    {:ok, prepared} = ObjectMutation.prepare(attrs(), now: @now)
    assert {:ok, claimed} = ObjectMutation.transition(prepared, "claimed", %{}, now: @now)
    assert {:ok, ^claimed} = ObjectMutation.transition(prepared, "claimed", %{}, now: @now)

    assert {:ok, published} =
             ObjectMutation.transition(
               claimed,
               "published",
               %{published_fingerprint: fingerprint()},
               now: @now
             )

    assert {:error, {:stale_journal, "published", 0}} =
             ObjectMutation.transition(prepared, "claimed", %{}, now: @now)

    assert ObjectMutation.get(prepared.id).phase == published.phase
  end

  test "mark_error fences by phase and attempts while retaining retry evidence" do
    {:ok, prepared} = ObjectMutation.prepare(attrs(), now: @now)

    assert {:ok, failed_once} =
             ObjectMutation.mark_error(
               prepared,
               :enoent,
               %{"kind" => "missing_final", "kept_backup" => true},
               now: @now,
               backoff_ms: 2_500
             )

    assert failed_once.attempts == 1
    assert failed_once.next_attempt_at == DateTime.add(@now, 2_500, :millisecond)
    assert failed_once.last_error == ":enoent"
    assert failed_once.recovery_evidence == %{"kind" => "missing_final", "kept_backup" => true}

    assert {:error, {:stale_journal, "prepared", 1}} =
             ObjectMutation.mark_error(prepared, :late, %{"kind" => "stale"}, now: @now)
  end

  test "mark_error rejects unsafe evidence before CAS and leaves the journal unchanged" do
    {:ok, prepared} = ObjectMutation.prepare(attrs(), now: @now)

    too_deep =
      Enum.reduce(1..17, "leaf", fn depth, acc -> %{"level#{depth}" => acc} end)

    invalid_evidence = [
      %{kind: "atom-key"},
      %{"blob" => String.duplicate("x", 66_000)},
      too_deep
    ]

    Enum.each(invalid_evidence, fn evidence ->
      assert {:error, changeset} =
               ObjectMutation.mark_error(prepared, :invalid_evidence, evidence, now: @now)

      assert errors_on(changeset).recovery_evidence

      unchanged = ObjectMutation.get(prepared.id)
      assert unchanged.attempts == 0
      assert unchanged.next_attempt_at == prepared.next_attempt_at
      assert is_nil(unchanged.recovery_evidence)
      assert is_nil(unchanged.last_error)
    end)
  end

  test "quarantine is terminal and preserves exact recovery evidence" do
    {:ok, row} = ObjectMutation.prepare(attrs(), now: @now)
    {:ok, row} = ObjectMutation.transition(row, "claimed", %{}, now: @now)

    evidence = %{
      "final" => "missing",
      "epoch_quorum" => false,
      "backup" => "retained"
    }

    assert {:ok, quarantined} =
             ObjectMutation.quarantine(
               row,
               :insufficient_fencing_evidence,
               evidence,
               now: @now
             )

    assert quarantined.phase == "quarantined"
    assert quarantined.quarantined_at == @now
    assert quarantined.recovery_evidence == evidence
    assert quarantined.last_error =~ "insufficient_fencing_evidence"
  end

  test "due listing and lease claim are atomic and lease expiry makes work due again" do
    {:ok, row} = ObjectMutation.prepare(attrs(), now: @now)
    assert [due] = ObjectMutation.list_due(now: @now)
    assert due.id == row.id

    assert {:ok, claimed} = ObjectMutation.claim(row, "recovery-a", now: @now, lease_ms: 1_000)
    assert claimed.lease_owner == "recovery-a"
    assert claimed.lease_expires_at == DateTime.add(@now, 1_000, :millisecond)
    assert [] == ObjectMutation.list_due(now: @now)
    assert {:error, :not_due_or_leased} = ObjectMutation.claim(row.id, "recovery-b", now: @now)

    after_expiry = DateTime.add(@now, 1_001, :millisecond)
    assert [due_again] = ObjectMutation.list_due(now: after_expiry)
    assert due_again.id == row.id
    assert {:ok, reclaimed} = ObjectMutation.claim(row.id, "recovery-b", now: after_expiry)
    assert reclaimed.lease_owner == "recovery-b"
  end

  test "an expired lease holder cannot advance a journal reclaimed by another worker" do
    {:ok, row} = ObjectMutation.prepare(attrs(), now: @now)
    {:ok, first_lease} = ObjectMutation.claim(row, "recovery-a", now: @now, lease_ms: 1_000)

    after_expiry = DateTime.add(@now, 1_001, :millisecond)
    {:ok, second_lease} = ObjectMutation.claim(row, "recovery-b", now: after_expiry)

    assert {:error, {:stale_journal, "prepared", 0}} =
             ObjectMutation.transition(first_lease, "claimed", %{}, now: after_expiry)

    assert {:ok, claimed} =
             ObjectMutation.transition(second_lease, "claimed", %{}, now: after_expiry)

    assert claimed.phase == "claimed"
    assert claimed.lease_owner == "recovery-b"
    assert claimed.lease_expires_at == second_lease.lease_expires_at
  end

  test "an expired lease holder cannot transition or overwrite evidence before reclaim" do
    {:ok, row} = ObjectMutation.prepare(attrs(), now: @now)
    {:ok, lease} = ObjectMutation.claim(row, "recovery-a", now: @now, lease_ms: 1_000)
    expired_at = DateTime.add(@now, 1_001, :millisecond)

    assert {:error, {:stale_journal, "prepared", 0}} =
             ObjectMutation.transition(lease, "claimed", %{}, now: expired_at)

    assert {:error, {:stale_journal, "prepared", 0}} =
             ObjectMutation.mark_error(
               lease,
               :late,
               %{"source" => "expired"},
               now: expired_at
             )

    current = ObjectMutation.get(row.id)
    assert current.phase == "prepared"
    assert current.attempts == 0
    assert is_nil(current.last_error)
  end

  test "target shape validation rejects ambiguous multipart identity" do
    invalid =
      attrs()
      |> Map.merge(%{
        target_kind: "multipart_part",
        version_id: "null",
        upload_id: "upload-1",
        part_number: 1
      })

    assert {:error, changeset} = ObjectMutation.prepare(invalid, now: @now)
    assert "is not valid for this target kind" in errors_on(changeset).version_id
  end

  test "journal and epoch share multipart part and object key target validation" do
    multipart_part =
      attrs()
      |> Map.merge(%{
        target_kind: "multipart_part",
        version_id: nil,
        upload_id: "upload-1",
        part_number: 42
      })

    assert {:ok, row} = ObjectMutation.prepare(multipart_part, now: @now)
    assert row.target_kind == "multipart_part"
    assert row.part_number == 42

    traversal = Map.put(attrs(), :object_key, "../escape")
    assert {:error, traversal_changeset} = ObjectMutation.prepare(traversal, now: @now)
    assert errors_on(traversal_changeset).object_key

    invalid_part = Map.put(multipart_part, :part_number, 10_001)
    assert {:error, part_changeset} = ObjectMutation.prepare(invalid_part, now: @now)
    assert errors_on(part_changeset).part_number

    blank_upload = Map.put(multipart_part, :upload_id, "   ")
    assert {:error, upload_changeset} = ObjectMutation.prepare(blank_upload, now: @now)
    assert errors_on(upload_changeset).upload_id
  end

  test "object key byte bound and blank lease owners fail before database writes" do
    oversized = Map.put(attrs(), :object_key, String.duplicate("界", 342))
    assert byte_size(oversized.object_key) > 1024
    assert {:error, changeset} = ObjectMutation.prepare(oversized, now: @now)
    assert errors_on(changeset).object_key

    {:ok, row} = ObjectMutation.prepare(attrs(), now: @now)
    assert {:error, :invalid_lease_owner} = ObjectMutation.claim(row, "   ", now: @now)
    assert is_nil(ObjectMutation.get(row.id).lease_owner)
  end

  test "nonterminal transitions retain lease and explicit renew and release are fenced" do
    {:ok, row} = ObjectMutation.prepare(attrs(), now: @now)
    {:ok, lease} = ObjectMutation.claim(row, "recovery-a", now: @now, lease_ms: 2_000)
    within_lease = DateTime.add(@now, 500, :millisecond)

    assert {:ok, claimed} = ObjectMutation.transition(lease, "claimed", %{}, now: within_lease)
    assert claimed.lease_owner == lease.lease_owner
    assert claimed.lease_expires_at == lease.lease_expires_at

    assert {:ok, renewed} =
             ObjectMutation.renew_lease(claimed,
               now: DateTime.add(@now, 600, :millisecond),
               lease_ms: 5_000
             )

    assert DateTime.compare(renewed.lease_expires_at, claimed.lease_expires_at) == :gt

    assert {:error, {:stale_journal, "claimed", 0}} =
             ObjectMutation.transition(claimed, "claimed", %{}, now: within_lease)

    assert {:ok, released} =
             ObjectMutation.release_lease(
               renewed,
               now: DateTime.add(@now, 700, :millisecond)
             )

    assert is_nil(released.lease_owner)
    assert is_nil(released.lease_expires_at)
  end

  test "mark_error retains a live lease until explicit release" do
    {:ok, row} = ObjectMutation.prepare(attrs(), now: @now)
    {:ok, lease} = ObjectMutation.claim(row, "recovery-a", now: @now, lease_ms: 2_000)

    assert {:ok, failed} =
             ObjectMutation.mark_error(
               lease,
               :retry,
               %{"final" => "unchanged"},
               now: DateTime.add(@now, 100, :millisecond),
               backoff_ms: 0
             )

    assert failed.lease_owner == "recovery-a"
    assert failed.lease_expires_at == lease.lease_expires_at

    assert {:ok, released} =
             ObjectMutation.release_lease(
               failed,
               now: DateTime.add(@now, 200, :millisecond)
             )

    assert is_nil(released.lease_owner)
  end

  test "terminal transitions clear a valid recovery lease" do
    {:ok, row} = ObjectMutation.prepare(attrs(), now: @now)
    {:ok, row} = ObjectMutation.claim(row, "recovery-a", now: @now, lease_ms: 5_000)
    {:ok, row} = ObjectMutation.transition(row, "claimed", %{}, now: @now)

    {:ok, row} =
      ObjectMutation.transition(
        row,
        "published",
        %{published_fingerprint: fingerprint()},
        now: @now
      )

    {:ok, row} = ObjectMutation.transition(row, "rollback_pending", %{}, now: @now)
    assert {:ok, terminal} = ObjectMutation.transition(row, "rolled_back", %{}, now: @now)
    assert is_nil(terminal.lease_owner)
    assert is_nil(terminal.lease_expires_at)
  end

  test "prepare rejects caller supplied protocol state" do
    injected =
      attrs()
      |> Map.merge(%{
        phase: "finalized",
        attempts: 99,
        next_attempt_at: @now,
        lease_owner: "forged",
        lease_expires_at: DateTime.add(@now, 60, :second),
        previous_epoch: %{},
        published_fingerprint: fingerprint(),
        recovery_evidence: %{},
        finalized_at: @now
      })

    assert {:error, changeset} = ObjectMutation.prepare(injected, now: @now)
    errors = errors_on(changeset)
    assert errors.phase
    assert errors.attempts
    assert errors.next_attempt_at
    assert errors.lease_owner
    assert errors.lease_expires_at
    assert errors.previous_epoch
    assert errors.published_fingerprint
    assert errors.recovery_evidence
    assert errors.finalized_at
    assert Repo.aggregate(Maxio.ObjectMutation.Journal, :count) == 0
  end

  test "sidecar publish is the authority commit line and can only finalize" do
    {:ok, row} = ObjectMutation.prepare(%{attrs() | authority_mode: "sidecar"}, now: @now)
    {:ok, row} = ObjectMutation.transition(row, "claimed", %{}, now: @now)

    {:ok, row} =
      ObjectMutation.transition(
        row,
        "published",
        %{published_fingerprint: fingerprint()},
        now: @now
      )

    assert {:error, {:illegal_transition, "published", "rollback_pending"}} =
             ObjectMutation.transition(row, "rollback_pending", %{}, now: @now)

    assert {:error, {:illegal_transition, "published", "metadata_committed"}} =
             ObjectMutation.transition(row, "metadata_committed", %{}, now: @now)

    assert {:ok, row} = ObjectMutation.transition(row, "finalize_pending", %{}, now: @now)
    assert is_nil(row.metadata_committed_at)
    assert {:ok, finalized} = ObjectMutation.transition(row, "finalized", %{}, now: @now)
    assert finalized.phase == "finalized"
  end

  test "JSON evidence requires recursive string keys and depth and size bounds" do
    atom_keyed = Map.put(attrs(), :placement_snapshot, %{endpoint: "disk-a"})
    assert {:error, atom_changeset} = ObjectMutation.prepare(atom_keyed, now: @now)
    assert errors_on(atom_changeset).placement_snapshot

    oversized =
      Map.put(attrs(), :placement_snapshot, %{"blob" => String.duplicate("x", 66_000)})

    assert {:error, size_changeset} = ObjectMutation.prepare(oversized, now: @now)
    assert errors_on(size_changeset).placement_snapshot

    too_deep =
      Enum.reduce(1..17, "leaf", fn depth, acc -> %{"level#{depth}" => acc} end)

    assert {:error, depth_changeset} =
             attrs()
             |> Map.put(:placement_snapshot, too_deep)
             |> ObjectMutation.prepare(now: @now)

    assert errors_on(depth_changeset).placement_snapshot
  end

  test "previous epoch and published fingerprint require concrete complete shapes" do
    {:ok, row} = ObjectMutation.prepare(attrs(), now: @now)

    assert {:error, previous_changeset} =
             ObjectMutation.transition(
               row,
               "claimed",
               %{previous_epoch: %{"generation" => 6}},
               now: @now
             )

    assert errors_on(previous_changeset).previous_epoch

    {:ok, row} =
      ObjectMutation.transition(
        row,
        "claimed",
        %{previous_epoch: previous_epoch()},
        now: @now
      )

    assert {:error, fingerprint_changeset} =
             ObjectMutation.transition(
               row,
               "published",
               %{published_fingerprint: %{"etag" => "abc"}},
               now: @now
             )

    assert errors_on(fingerprint_changeset).published_fingerprint
  end

  defp attrs do
    %{
      target_kind: "object_version",
      bucket_name: "mutation-test",
      object_key: "path/to/object.bin",
      version_id: "null",
      generation: 7,
      operation: "put_object",
      authority_mode: "pg",
      backend: "Maxio.Storage.FS"
    }
  end

  defp fingerprint do
    %{
      "etag" => "abc",
      "size" => 3,
      "sidecar_sha256" => String.duplicate("a", 64)
    }
  end

  defp previous_epoch do
    {:ok, target} =
      Maxio.Storage.ObjectEpoch.object_target(
        "mutation-test",
        "path/to/object.bin",
        "null"
      )

    {:ok, token} =
      Maxio.Storage.ObjectEpoch.token(6, "00000000-0000-0000-0000-000000000006")

    {:ok, epoch} =
      Maxio.Storage.ObjectEpoch.new(target, token, %{
        operation: "put_object",
        phase: "committed",
        value_type: "object",
        fingerprint: fingerprint(),
        updated_at: @now
      })

    {:ok, bytes} = Maxio.Storage.ObjectEpoch.encode(epoch)
    Jason.decode!(bytes)
  end
end
