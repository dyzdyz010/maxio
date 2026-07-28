# ObjectMutation final fingerprint gate Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task.

**Goal:** Close `P1-CLOSEOUT-B` by proving the actual published final value before PG metadata commit and before backup cleanup across FS, ErasureCoded, and Distributed backends.

**Architecture:** `Commit` orchestrates a backend-level `verify_published/2` contract. Each endpoint performs the A+ proof—exact raw sidecar fingerprint plus physical `part.0`/shard shape—under the existing epoch fence. The initial proof runs before the journal becomes `published`; finalize repeats the same proof before committing epoch/cleaning backup. Proof failure and quorum-proven cleanup debt have distinct durable and HTTP semantics.

**Tech Stack:** Elixir/OTP, Phoenix/Plug, Ecto/Postgres, local filesystem, `PartitionSupervisor`, `Task.async_stream`, distributed transport/`:erpc`, ExUnit.

**Design:** `docs/superpowers/specs/2026-07-28-object-mutation-final-fingerprint-gate-design.md`

## Global Constraints

- Read repository `AGENTS.md`, the design above, and the full task brief before editing.
- Implement with TDD: capture a genuine RED caused by the missing behavior, then the focused GREEN. Do not write implementation before RED.
- Never buffer object bytes. This batch does not full-read payloads; it reads bounded raw sidecar bytes and file stats only.
- `Commit` and `Recovery` know only the backend proof contract; layout/placement knowledge stays behind `Maxio.Storage.Backend`.
- A journal may become `published` only after the initial proof succeeds.
- Exact comparison is `request/journal fingerprint == epoch fingerprint == ObjectEpoch.fingerprint(top-level core etag, top-level core size, raw final meta.json bytes)`.
- Endpoint wire observations and backend aggregate summaries are separate domains. Every summary
  carries `"scope"` and `"mode" => "proof" | "finalize"`, every endpoint summary carries a
  stable `"endpoint"`, and quorum aggregation accepts unique
  `{expected_identity, endpoint_result}` pairs only. No wire count is trusted.
- Never use a `versions` entry for durable core ETag/size. Zero-byte objects still require zero-length `part.0`.
- The final sidecar must nevertheless be a valid ordinary-object `maxio/2` envelope, including
  top-level SHA256 and exactly one object entry for the target version. Duplicate same-version
  entries, including object/delete-marker conflicts, are corrupt. SSE/multipart-visible
  ETag/size may legitimately differ from the durable core.
- EC/Distributed proof success requires verified endpoints `>= epoch_quorum`; minority failure is bounded degraded evidence and keeps its backup.
- Distributed proof/finalize resolves endpoints only from the frozen journal placement snapshot.
- Successor/fence short-circuits before reading or touching final/backup; successor observed during endpoint proof triggers global re-adjudication, never minority degradation.
- Before metadata, proof failure rolls back and cannot return 200. After metadata, proof failure never rolls back and cannot return 200. Quorum-proven cleanup/degraded debt may leave `finalize_pending` while returning success.
- Use exactly these callback contracts:

```elixir
verify_published(ctx, opts) ::
  {:ok, {:verified | :degraded | :superseded, proof_summary}}
  | {:error, {:published_proof_failed, proof_class, evidence}}

finalize_if_current(ctx, opts) ::
  {:ok, {:finalized | :cleanup_pending | :superseded, proof_summary}}
  | {:error, {:published_proof_failed, proof_class, evidence}}
```

- A `finalized` journal requires all currently observable same-token participants clean, no unresolved endpoint, and finalized quorum. A same-token `claimed` endpoint is finalized only by exact-final claimed repair after metadata commit; absent/old-token manifest-only debris is never destructive authority and gets a finalize-only explicit orphan hint for later GC. Orphans do not vote, do not add debt, do not block a separately proven finalized quorum, and never authorize deletion.
- Raw sidecars are `lstat`-checked; symlinks/non-regular files are rejected; reads are hard-limited to 16 MiB and never read object/shard contents.
- `request.target`, decoded epoch target, and canonical `final_rel` are one identity. Check the
  absolute drive root and every final-directory ancestor before/after proof; reject links,
  junctions/reparse points and non-directory components. On Windows, use the native Rust-std
  reparse detector rather than trusting OTP `lstat`; a missing native detector fails closed.
  Read the sidecar through an opened handle with fstat/path-lstat identity rechecks and a
  `limit + 1` read. Ancestor snapshots compare stable identity plus type/reparse only, never
  mutable directory size/time/link metadata.
- Journal proof evidence is phase-aware and uses
  `%{"published_proof" => success_summary_or_nil, "last_failure" => failure_or_nil}`.
  Pre-published failures alone may use a nil published proof; published and later phases require
  a successful aggregate proof. Bounded endpoint details total at most 32, the wrapper is at most
  60 KiB, and the existing Journal 64 KiB JSON gate remains authoritative.
- S3 XML uses stable public messages; never expose `inspect(reason)`, drive paths, backup paths, body, credentials, or SSE envelope.
- No migration, Phase2A caller migration, delete/meta-only work, placement-durability work, participant bitmap, orphan GC implementation, or scrub/heal expansion.
- No `Process.sleep/1` in tests. Use `start_supervised!/1` for processes.
- Use `apply_patch` for edits. Preserve unrelated work.
- During tasks run focused tests/compile/format only. Do not run `mix precommit`; the final independent verifier runs it once.
- Tasks 2 and 3 are one coherent implementation/review batch. The same implementation lane
  completes both in sequence; the Task 2 commit is only a non-release internal checkpoint.
  Do not claim that checkpoint is semantically runnable or full-suite green, and do not add
  legacy tuple/`nil` fingerprint compatibility shims to make it appear standalone.
- The independent code-review boundary for that batch is the reviewed Task 1 commit through
  the completed Task 3 commit. Its focused gate includes endpoint, all backend mutation,
  Commit/Recovery, PutObject e2e/CLI, compile, format, and diff checks together.
- Every Mix command on Windows must clear `PGPORT` and set low-scheduler Unicode `ERL_FLAGS`:

```powershell
Remove-Item Env:PGPORT -ErrorAction SilentlyContinue
$env:ERL_FLAGS="+S 4:4 +SDcpu 2 +SDio 2 -kernel standard_io_encoding unicode"
```

---

## Task 1: Define the proof contract and local endpoint primitive

**Files:**

- Create: `lib/maxio/storage/published_proof.ex`
- Modify: `lib/maxio/sidecar.ex`
- Create: `lib/maxio/native.ex`
- Create: `lib/maxio/native/path_safety.ex`
- Modify: `lib/maxio/native/erasure_coding.ex`
- Modify: `native/maxio_native/src/lib.rs`
- Modify: `lib/maxio/storage/epoch_store.ex`
- Modify: `lib/maxio/cluster/shard_server.ex`
- Modify: `lib/maxio/cluster/transport.ex`
- Modify: `test/support/transport_in_process.ex`
- Create: `test/maxio/storage/epoch_store_published_proof_test.exs`
- Modify: `test/maxio/sidecar_test.exs`
- Create: `test/maxio/native/path_safety_test.exs`
- Modify: `test/maxio/cluster/shard_server_mutation_test.exs`
- Modify: `test/maxio/cluster/transport_in_process_test.exs`

### Step 1: Write genuine failing endpoint tests

Cover:

- exact epoch + raw sidecar + regular FS part succeeds;
- same decoded core but any raw sidecar byte change fails;
- request fingerprint differs from epoch even when final matches epoch;
- missing/malformed/symlink/non-regular/over-16-MiB sidecar;
- missing/non-regular/wrong-size part;
- shard layout selects the unique exact `shards[index]`, rejecting missing/duplicate/invalid ordinal metadata and wrong shard size;
- zero-byte object requires an empty regular part;
- committed replay verifies;
- standalone proof does not count `claimed`; finalize can repair same-token claimed only after actual final exactly matches expected;
- successor returns before a final probe;
- invalid `final_rel`, fingerprint, value type and request shape fail closed.
- forged endpoint counts, endpoint/aggregate scope confusion, duplicate or mismatched identities,
  outcome/status/class inconsistencies, and non-owned integrity observations;
- proof/finalize mode confusion, outer/detail class forgery, and a failed aggregate whose
  forged counts meet quorum;
- finalized quorum plus explicit `epoch_absent`/`older_token` orphan stays finalized with zero
  debt; invalid orphan reason/flags or any arbitrary non-owned failure can never become orphan;
- proof/finalize `last_failure` variants and the complete phase matrix for nil/non-nil
  `published_proof`;
- oversized integer ordinal identities, relative-root shard failure retaining its frozen
  ordinal, and duplicate identities failing before any vote is counted;
- aggregate detail truncation plus exact omitted counts and a proof wrapper never exceeding
  60 KiB;
- request/epoch target mismatch and a lexically-safe cross-key/version `final_rel`;
- real leaf/ancestor symlinks plus deterministic file-op races between lstat/open/read;
- sibling-key directory mutation between ancestor snapshots does not cause a false corrupt result;
- Windows real mount-point junction/name-surrogate rejection, normal-directory acceptance and
  native-not-loaded fail-closed behavior;
- OS-specific raw errno mapping never treats Linux `ETIME` as `ELOOP`;
- exact 16 MiB acceptance and lstat-then-grow-to-limit+1 rejection;
- self-consistent fingerprint over a malformed/non-`maxio/2` sidecar;
- nil/invalid `final_rel` and ERPC local apply exception/exit are normalized into bounded endpoint
  failures rather than escaping.

Use temporary drive roots and public EpochStore/ShardServer APIs. RED must be caused by missing `verify_mutation`, not a test typo.

### Step 2: Implement `Maxio.Storage.PublishedProof`

This single module owns:

- distinct endpoint-proof, aggregate-proof, endpoint-finalize and aggregate-finalize return types
  and constructors;
- proof-class predicates;
- global quorum classification helpers;
- phase-aware JSON-safe evidence and merge helpers;
- a maximum of 32 total degraded/orphan endpoint details plus separate omitted counts;
- endpoint identities only as `"local"` / frozen `"ordinal:N"` labels, never node-only or
  absolute drive/backup paths;
- `%{"published_proof" => ..., "last_failure" => ...}` journal evidence.

Do not nest modules. Validate all public constructors so invalid evidence cannot bypass Journal’s 64 KiB gate.
Every summary carries an exact proof/finalize mode. Endpoint summaries carry no aggregate counters
and never accept `:degraded`; the local classifier
derives each 0/1 vote from the validated tuple/status/owned/class relationship. Aggregate
classification prevalidates the whole input set and rejects invalid/duplicate expected identities,
response identity drift, mode/scope drift, aggregate re-entry and tuple/status/class inconsistency
before counting. A structural failure emits a canonical placement-drift aggregate with zero vote
counts. Successor has highest priority among structurally valid observations; only same-token owned
corrupt/mismatch participates in deterministic integrity selection, and integrity failures retain a
same-class owned decisive witness.
Use `classify(required, [{expected_identity, endpoint_result}])`; aggregate results are not valid
inputs. Add `endpoint_finalized/2`, `endpoint_cleanup_pending/2`, explicit
`endpoint_orphan/2`, and
`classify_finalize(required, [{expected_identity, endpoint_finalize_result}])` with the frozen
finalize result types now, while leaving disk-mutating finalize wiring to Task 2.
Reject forged endpoint-finalized results unless `status=finalized`, `owned=true`,
`proof_passed=true`, `finalized=true`, and class is absent; aggregate `finalized` must never
exceed `verified`. Orphan accepts only `epoch_absent`/`older_token`, all ownership/proof/finalized
flags false, contributes no vote/debt, and cannot by itself satisfy quorum. Decimal ordinal
identities must satisfy the same 128-byte bound as binary identities.

`journal_evidence/3` and `merge_failure/3` validate the target phase. Published proof is either a
verified/degraded aggregate proof success or nil; nil is legal only with a proof-mode
failed/superseded last failure in a pre-published rollback path. Last failure accepts only exact
aggregate proof failed/superseded or aggregate finalize failed/cleanup_pending/superseded. Reject
endpoint summaries, cross-mode summaries, proof successes in last failure, finalize finalized,
and `nil/nil`. Keep the wrapper at or below 60 KiB before Journal's 64 KiB gate.

Both proof and finalize failed aggregates require `verified < required`; fenced is never a failed
class, corrupt/mismatch retains an owned same-class endpoint witness, and placement drift uses
canonical zero counts plus a retained drift witness. Both proof and finalize superseded aggregates
have no outer class, retain a strict endpoint `superseded/fenced/owned=false` witness, and normalize
`verified/observed_owned/unavailable` to zero (including finalize `finalized/orphaned`). The witness
is retained in `degraded`, so `debt == length(degraded) + omitted >= 1`. Durable evidence validation
re-derives these relations from retained bounded details.

### Step 3: Implement standalone `EpochStore.verify_mutation/3`

Validate the D4 request. In the existing serialized closure:

1. read epoch;
2. compare the decoded epoch target with the canonical request target; target mismatch is corrupt
   and can never impersonate a successor;
3. compare token and short-circuit a real successor;
4. validate phase/value type/request-vs-epoch fingerprint;
5. prove absolute-root/canonical-final containment and snapshot every ancestor without following
   a symlink or junction; scan every configured-root prefix as well as every canonical-final
   prefix. Ancestor pre/post comparison uses stable identity and repeated type/reparse checks only,
   never mutable size/time/link/mode metadata. On Windows call the DirtyIo Rust-std reparse detector
   and reject every reparse point;
6. pre-lstat, raw-open, fstat/path-lstat identity-check, bounded-read exact raw sidecar, then
   repeat handle/path/ancestor checks;
7. decode the ordinary-object `maxio/2` envelope through one non-raising `Maxio.Sidecar`
   function and reconstruct the actual fingerprint from its top-level durable core;
8. compare request/epoch/actual;
9. `lstat` the exact FS/shard part and validate its size.

Factor one private proof function for Task 2’s finalize reuse. Task 1 does not change the existing finalize request/return contract yet, so intermediate callers remain coherent.
Expose low-level file operations behind a narrow deterministic test seam. Move the existing
Rustler registration to a neutral `Maxio.Native` loader; ErasureCoding and `PathSafety` wrappers
delegate to it. The static detector adds no Rust dependency and its absence is unavailable,
never safe. Standard APIs still lack cross-platform `openat2/O_NOFOLLOW` and held Windows
reparse handles, so document the controlled-data-drive threat boundary; do not claim protection
against a hostile local ABA writer.

Classify low-level errors exactly as design D6; Rust raw errno mapping is target-OS-specific and
unknown/transient values are unavailable, never corrupt. Invalid request fields must return a
structured endpoint failure rather than raise. A shard request that fails before opening its root
still retains its frozen ordinal identity.

### Step 4: Expose the primitive

Add `ShardServer.verify_mutation/3`, the `Transport` callback/facade, `Erpc` implementation, and InProcess implementation. RPC responses contain bounded pure data only.
Transport success and outage evidence use the same frozen `"ordinal:N"` identity; never use
node-only or drive-root labels. Both remote calls and local `apply` execute inside the same
exception/exit normalization boundary.

### Step 5: Focused verification and commit

```powershell
mix test test/maxio/sidecar_test.exs test/maxio/native/path_safety_test.exs test/maxio/native/erasure_coding_test.exs test/maxio/storage/epoch_store_published_proof_test.exs test/maxio/cluster/shard_server_mutation_test.exs test/maxio/cluster/transport_in_process_test.exs
mix compile --warnings-as-errors
mix format --check-formatted
git diff --check
```

Commit subject: `feat(storage): prove published endpoint state`

---

## Task 2: Wire all backend proof and proof-aware finalize paths

**Files:**

- Modify: `lib/maxio/storage/backend.ex`
- Modify: `lib/maxio/storage.ex`
- Modify: `lib/maxio/storage/fs.ex`
- Modify: `lib/maxio/storage/erasure_coded.ex`
- Modify: `lib/maxio/storage/distributed.ex`
- Modify: `lib/maxio/storage/epoch_store.ex`
- Modify: every path returned by `rg -l "@behaviour Maxio.Storage.Backend" lib test`
- Modify: `test/maxio/storage/fs_mutation_test.exs`
- Modify: `test/maxio/storage/erasure_coded_mutation_test.exs`
- Modify: `test/maxio/storage/distributed_mutation_test.exs`
- Create a focused facade/quorum test only if existing mutation files cannot express a case cleanly

### Step 1: Write genuine failing backend/finalize tests

Cover:

- `Storage.verify_published/2` delegates through the configured backend;
- FS verified proof and every proof error;
- EC/Distributed all endpoints, exact quorum, below quorum, minority mismatch/unavailable, sidecar divergence, ordinal mismatch and topology drift;
- deterministic global order: successor; verified quorum; recoverable unavailable quorum; global mismatch/corrupt; unavailable fallback;
- successor appearing between global pre-adjudication and endpoint proof causes global superseded;
- exact callback outcome tuples and bounded summaries;
- finalize distinguishes proof failure, cleanup pending, finalized and superseded;
- committed replay re-proves before backup cleanup;
- degraded quorum stays cleanup-pending until every currently observed owned endpoint is safe;
- same-token claimed + missing/mismatched final stays cleanup-pending; after simulated heal writes the exact final, finalize promotes it to fingerprinted committed and cleans backup;
- absent/old-token manifest-only debris is not deleted and yields only a bounded orphan hint;
- finalized quorum remains terminal in the presence of valid orphan hints, while orphan-only or
  arbitrary non-owned failure cannot satisfy quorum;
- no absolute path/raw sidecar is returned.

### Step 2: Add the mandatory backend callback and facade

Add `verify_published/2` to the mandatory `Maxio.Storage.Backend` behaviour and `Maxio.Storage` facade. Update all production and test behaviour implementers in this task. Test fakes delegate to FS unless a test explicitly injects proof behavior. `compile --warnings-as-errors` must remain clean.

### Step 3: Implement backend verification

FS constructs an endpoint request with `layout: %{kind: "fs"}`.

EC enumerates immutable drive ordinals. Distributed enumerates the frozen placement endpoint order and calls Transport; it never falls back to current routing. Both apply the design’s global classification order and require `verified >= epoch_quorum`.

Do not recompute payload/block hashes. Do not use an unvalidated ordinal lookup.

### Step 4: Make finalize proof-aware

Refactor `EpochStore.finalize_mutation` to require the full proof request and reuse Task 1’s private proof function in the same serialized closure:

- `published` and `committed` both re-prove;
- same-token `claimed` is a finalize-only repair case: exact actual final match writes a fingerprinted committed epoch and may then clean backup; otherwise it remains cleanup debt;
- only a clean absent epoch read, or an exact-target strictly older token, returns explicit
  endpoint orphan; target mismatch, corrupt epoch, IO failure and same-token claimed never do;
- proof failure leaves epoch/backup untouched;
- proof success precedes committed epoch write and backup discard;
- epoch write/discard errors become proof-passed cleanup debt.

Apply the exact `finalize_if_current/2` union in all backends. Aggregate verified, finalized, cleanup-failed, observed-owned, unavailable, absent/old-token and orphan hints separately. Return:

- `finalized` only for the design’s provable terminal set;
- `cleanup_pending` when proof quorum passed but debt remains;
- `superseded` when any endpoint proof observes a greater token;
- proof error when global proof fails.

During protocol publish derive `%{ctx | published_fingerprint: fingerprint}` and capture it in the Control finalize closure. Restore remains fingerprint-independent and keeps the same token/placement.

Control adapts all three successful finalize outcomes to callback `:ok`; proof errors remain callback errors.

### Step 5: Internal focused checkpoint and commit

```powershell
mix test test/maxio/storage/epoch_store_published_proof_test.exs test/maxio/storage/fs_mutation_test.exs test/maxio/storage/erasure_coded_mutation_test.exs test/maxio/storage/distributed_mutation_test.exs
mix compile --warnings-as-errors
mix format --check-formatted
git diff --check
```

Commit subject: `feat(storage): gate backend publish with final proof`

This commit is not a release or independent-review boundary. Continue directly to Task 3
in the same implementation lane. The old Commit/Recovery semantics are intentionally removed
only when the coherent batch is complete; do not run or cite a full-suite verdict here.

## Task 3: Complete the coherent batch with proof ordering, Recovery and S3 semantics

**Files:**

- Modify: `lib/maxio/object_mutation/commit.ex`
- Modify: `lib/maxio/object_mutation/recovery.ex`
- Modify: `lib/maxio/object_mutation.ex`
- Modify: `lib/maxio/object_mutation/log.ex`
- Modify: `lib/maxio/s3/handlers/object.ex`
- Modify: `config/config.exs`
- Modify: `lib/mix/tasks/maxio.object_mutations.status.ex`
- Modify: `test/maxio/object_mutation_test.exs`
- Modify: `test/maxio/object_mutation/commit_test.exs`
- Modify: `test/maxio/object_mutation/recovery_test.exs`
- Modify: `test/maxio/s3/put_object_mutation_e2e_test.exs`
- Modify: `test/mix/tasks/maxio_object_mutations_test.exs` if CLI rendering changes

### Step 1: Write genuine failing orchestration tests

Cover:

- exact order `publish → verify_published → journal published → metadata_tx → finalize`;
- initial proof failure restores old bytes, writes no PG object and never transitions published;
- initial proof failure atomically persists
  `%{"published_proof" => nil, "last_failure" => proof_failure}` with rollback phase and a nil
  fingerprint;
- journal fingerprint/proof evidence becomes durable only after proof;
- fresh journal rehydrates the synchronous finalize context;
- pre-metadata successor rolls back/supersedes without published/metadata and returns retryable error;
- post-metadata successor never rolls back, terminally records evidence and returns retryable error;
- post-metadata global mismatch/corrupt quarantines, retains backup and returns error;
- post-metadata unavailable remains finalize-pending, returns retryable error and Recovery retries;
- cleanup/degraded pending returns request success, preserves `finalize_pending`, and Recovery converges;
- `accelerate_mark_committed/2` is not called on post-metadata proof error;
- Recovery calls the same backend callback and merges `"last_failure"` without erasing `"published_proof"`.

### Step 2: Refactor Commit ordering

After publish returns `epoch_fingerprint`:

1. enrich temporary context;
2. hit new failpoint `:object_mutation_after_publish_before_proof`;
3. call `Storage.verify_published/2`;
4. on verified/degraded success transition to `published` with fingerprint and `%{"published_proof" => summary, "last_failure" => nil}`;
5. reconstruct context from the fresh journal before metadata/finalize;
6. on proof failure/superseded atomically transition to rollback pending with phase-valid evidence
   and a nil fingerprint, then return the structured error.

Refactor finalize to return an explicit request outcome:

- `finalized`: transition terminal and succeed;
- `cleanup_pending`: merge error/debt evidence, keep pending and succeed;
- proof unavailable: mark retryable, keep pending and return error;
- global mismatch/corrupt/placement drift: quarantine and return error;
- superseded after metadata: terminal evidence, no rollback, return retryable error.

The rollback guard stays armed. Call `accelerate_mark_committed/2` only for finalized/cleanup-pending success, never for proof error.

### Step 3: Refactor Recovery

Recovery first calls `Storage.verify_published/2`, then calls proof-aware finalize. It:

- retries unavailable;
- quarantines globally adjudicated mismatch/corrupt/placement drift;
- treats healthy-quorum minority mismatch as cleanup debt;
- terminally records superseded;
- retries cleanup pending;
- preserves initial proof evidence while updating `"last_failure"`.

It contains no layout/shard proof logic.

All `mark_error`/quarantine paths use the phase-aware evidence helper; they never hand-build or
overwrite `"published_proof"`. Structured proof logging adds only bounded class/count metadata
to the formatter whitelist, never a raw evidence map.

### Step 4: Add safe HTTP mappings and deterministic e2e faults

Map:

- unavailable/fenced/superseded → default-message `SlowDownWrite` 503;
- mismatch/corrupt/placement drift → default-message `InternalError` 500.

Never pass internal reason to `Error.new/2`.

Use `:object_mutation_after_publish_before_proof` with `{:fun, fun}` to corrupt initial final deterministically. Reuse existing `:object_mutation_finalize` with `{:fun, fun}` for post-metadata drift. Do not rely on file-permission races or sleeps.

At real Bandit level cover ordinary signed PUT and existing self-signed aws-chunked PUT. Assert status/XML, old/new bytes, PG/journal/epoch/backup outcomes and absence of path/reason leakage.

### Step 5: Focused verification and commit

```powershell
mix test test/maxio/storage/epoch_store_published_proof_test.exs test/maxio/cluster/shard_server_mutation_test.exs test/maxio/cluster/transport_in_process_test.exs
mix test test/maxio/storage/fs_mutation_test.exs test/maxio/storage/erasure_coded_mutation_test.exs test/maxio/storage/distributed_mutation_test.exs
mix test test/maxio/object_mutation/commit_test.exs test/maxio/object_mutation/recovery_test.exs
mix test test/maxio/s3/put_object_mutation_e2e_test.exs test/mix/tasks/maxio_object_mutations_test.exs
mix compile --warnings-as-errors
mix format --check-formatted
git diff --check
```

Commit subject: `feat(object-mutation): require final proof before commit`

Generate one combined review package from the independently approved Task 1 commit through
this Task 3 commit. The reviewer must inspect the Task 2 and Task 3 diff as one unit, with
special attention to all backend behaviour implementations, fresh published context,
error propagation, cleanup debt, Recovery convergence, frozen placement, and evidence
redaction.

---

## Task 4: Close documentation and verification evidence

**Entry gate:** The controller first completes the Task 1 review, the combined Task 2+3
independent review, the whole-code independent review, and the one allowed full
`mix precommit` verification for Tasks 1–3. Start this documentation task only after those
reports and exact command/count/exit evidence exist.

**Files:**

- Modify: `docs/superpowers/STATUS.md`
- Modify: `docs/superpowers/TODO.md`
- Modify: `docs/superpowers/plans/2026-07-10-object-mutation-protocol.md` only with a superseding note at the broad finalize-success wording
- Modify: `docs/superpowers/plans/2026-07-11-object-mutation-phase1-impl.md` only with a historical-plan correction note
- Modify implementation moduledocs/comments whose old “all finalize errors succeed” statement remains

### Step 1: Update single-source status accurately

Record:

- `P1-CLOSEOUT-B` scope and exact A+ capability;
- focused commands/counts and independent review verdicts;
- the final verifier’s `mix precommit` result after it is available;
- same-length bitrot and manifest-only orphan-GC residual boundaries;
- next pointer `P1-CLOSEOUT-C`;
- no claim that Phase 1/global writes/MinIO compatibility are complete.

### Step 2: Static contradiction audit

```powershell
rg -n "finalize.*请求.*成功|request still succeeds|finalize failure|fingerprint gate|P1-CLOSEOUT-B" lib test docs/superpowers
git diff --check
```

Resolve only contradictions caused by this batch. Do not rewrite historical evidence or unrelated specs.

### Step 3: Commit documentation

Commit subject: `docs: close final fingerprint gate`

The documentation lane does not run `mix precommit`. It records the already completed independent verifier’s exact evidence, then an independent docs reviewer and the controller run `git diff --check`.
