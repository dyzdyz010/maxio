# MinIO Admin User S2c (U4 Remove + U5 Status) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. Planning, implementation, protocol review, and code review remain separate lanes per `AGENTS.md`.

**Goal:** Make `mc admin user enable|disable|rm` interoperate with Maxio through MinIO Admin API v3 while making user status/removal linearizable with long-term key and STS issuance and immediately invalidating every affected credential.

**Architecture:** Add one internal `Maxio.IAM.UserIdentity` transaction boundary: a case-folded advisory identity lock handles absent/create races, a `FOR UPDATE` row lock pins the concrete `iam_users.id`, and final long-term/STS persistence revalidates the same owner under that lock. Every production writer that can create, delete, rename, or attach state to a local IAM-user identity uses that boundary; the unsafe DB credential-store write entry point is closed. Public `Maxio.IAM` strict facades own U4/U5 transactions and return safe affected counts; internal exact credential IDs flow only to `Maxio.IAM.CredentialInvalidation` after commit. Invalidation attempts every local exact ID, one typed batch, and every legacy event even after an earlier failure, returning structured failure evidence. `Maxio.Admin.Plug` stays route/authz/response-only, and `UserAdapter` calls only public IAM facades.

**Tech Stack:** Elixir/Plug, Ecto/Postgres advisory and row locks, Phoenix.PubSub, ETS-backed `MemoryStore`, DB-backed `EctoStore`, ExUnit, SigV4 helpers, MinIO `mc` external smoke.

**Spec:** `docs/superpowers/specs/2026-08-20-minio-admin-user-policy-design.md`; completed S2a/S2b contracts in `docs/superpowers/plans/2026-08-28-minio-admin-user-s2.md` and `docs/superpowers/plans/2026-08-28-minio-admin-user-s2b.md`.

**Fixed base:** `8dc75b4c6acd57e30ba768782598bdb4ee5774fe` (`8dc75b4`). Every implementation/review diff is `8dc75b4..HEAD`; do not chase a moving `origin/master`.

## Global Constraints

- Scope is exactly design-spec U4 remove plus U5 status. U1/U2/U3 remain unchanged; user bucket variants and all unimplemented service-account/group/policy surfaces keep their reviewed authenticated JSON 501 behavior.
- No migration and no new crypto. A persistent credential epoch is deferred until Maxio adds a production credential cache whose correctness cannot be obtained from authoritative DB reads.
- No object body path changes. U4/U5 have empty request/response bodies and require no request `Content-Type`; Plug must not call a body reader or Envelope.
- Adapter never aliases `Maxio.Repo`, Ecto schemas, credential stores, or policy stores. It only validates the MinIO projection and calls public `Maxio.IAM` facades.
- Never broadcast a user/principal ARN in an access-key invalidation slot. Every invalidation payload is a deduplicated exact access-key ID from `access_keys.access_key_id` or `sts_sessions.access_key_id`.
- `SigningSecretKeyring` is encryption-at-rest machinery, not a credential cache. U4/U5 do not rotate, unwrap, rewrite, or delete keyring material.
- Development uses focused RED/GREEN only; independent review precedes exactly one final `mix precommit`.
- Every PowerShell native command checks `$LASTEXITCODE` immediately. Any dirty tree, SHA mismatch, blocker disguised as pass, or unreviewed fix is a hard stop.

## Confirmed MinIO Wire Contract

**Pinned primary sources:** MinIO `7aac2a2c5b7c882e68c1ce017d8256be2feea27f`; madmin-go v3.0.109 `6897865311e2be91d814ea0ef4814a730d87d1cd`; mc `77f82e18b5401a65958f1619df6ebb994634bd88`, whose observed madmin pin is `4b504b82db63`. Task 1 stores the independent lane's exact source paths/lines and httptest/live transcripts against these commits; later upstream movement does not silently change this batch's contract.

| Operation | Exact request | Action | Success | Target behavior |
|---|---|---|---|---|
| U4 remove | `DELETE /minio/admin/v3/remove-user?accessKey=N` | `admin:DeleteUser` | 200, empty body | pinned request has `Content-Length: 0`, no transfer-encoding, zero body, and no Content-Type; an initially absent regular user is 404 |
| U5 status | `PUT /minio/admin/v3/set-user-status?accessKey=N&status=enabled|disabled` | always `admin:EnableUser`, including disable | 200, empty body | pinned httptest sends semantic `ContentLength=-1`, chunked transfer, zero body, and no Content-Type; handler ignores the body; same-status update still advances `UpdatedAt` |

Authentication and authorization finish before target lookup/mutation. Root, STS, bucket-policy, and explicit IAM admin authorization retain the S1/S2a behavior; this batch does **not** add MinIO's U3 deny-only self-read relaxation.

U5 forbids changing the exact signing credential's own status with 400 `XMinioAdminInvalidArgument`. A subordinate long-term credential is action-not-allowed; a temporary/session target is reported as absent. Because self is the exact caller access key, an authorized STS caller may manage its parent: Maxio compares the target only to the signing credential, never to a derived credential's owner. U5 changes only `iam_users.status` (`active`/`inactive` ↔ `enabled`/`disabled`): it does not delete or revoke long-term keys or STS rows. Existing user-derived credentials reject immediately while inactive and become usable again after re-enable if their own row is still active/unexpired.

U4 forbids root, the exact signing credential, temporary/session credentials, and subordinate long-term credentials with 403 `XMinioIAMActionNotAllowed`. It deletes the regular user's identity, inline/direct policy mappings, group memberships, MFA devices, certificates, SSH keys, managed-policy attachments, and all long-term keys, while retaining groups and their policies. It permanently revokes every descendant STS session and retains those revoked rows so their exact IDs stay reserved by `CredentialNamespace` for audit and cannot be reused.

MinIO's persistent STS cleanup path has an upstream source ambiguity. Maxio deliberately chooses the fail-closed rule above: U5 is reversible and does not revoke descendants; U4 recursively revokes every user-derived session in the same transaction and never makes it usable again. Task 1 records this compatibility/safety deviation and requires a pinned real-server oracle; the implementation must not copy an apparent upstream persistence bug.

Independent adjudication has now closed the two disputed cells against the fixed MinIO commit with a temporary server-suite plus pinned madmin: sequential second remove is 404, and an ordinary non-self admin targeting configured root for status is also 404; both return `XMinioAdminNoSuchUser` with dynamic message `The specified user does not exist. (Specified user does not exist)`. Exact-self root status remains 400. A concurrent MinIO double-remove can pass both prechecks and may produce two 200 responses; Maxio deliberately gives the stronger linearizable result of exactly one 200 and one 404. Task 1 must commit the raw provenance/transcript and independent reviewer correction (the earlier claimed handler line `#L2271` was an IAM-export line at the fixed commit) before implementation starts.

## Exact Error Contract

| Input / facade reason | Wire code | HTTP | Exact message |
|---|---|---:|---|
| missing/empty `accessKey`, missing/empty/unknown `status`, equals/slash/backslash/path/invalid MinIO access-key shape | `XMinioAdminInvalidArgument` | 400 | `Invalid arguments specified.` |
| leading/trailing Unicode whitespace or comma in target | `XMinioInvalidResource` | 400 | `Policy, user or group names are not allowed to begin or end with space characters` |
| U5 exact signing-credential self target | `XMinioAdminInvalidArgument` | 400 | `Invalid arguments specified.` |
| initially absent regular user; sequential second U4 remove; U5 temporary/session target; U5 configured-root targeted by a different authorized signer | `XMinioAdminNoSuchUser` | 404 | `The specified user does not exist. (Specified user does not exist)` |
| U5 subordinate long-term target; U4 root/self/temporary/subordinate target | `XMinioIAMActionNotAllowed` | 403 | `Specified IAM action is not allowed` |
| unexpected transaction/store failure | `InternalError` | 500 | existing fixed S3 message; no Ecto/SQL/secret detail crosses the wire |

Authn/authz denial remains existing `AccessDenied`/403 and occurs before this table. Same-status U5 is a successful write, not a no-op error. Error tests assert JSON `Code`, `Message`, `Resource`, and non-empty `RequestId` exactly.

The missing-query row is an intentional Maxio deviation: pinned MinIO's mux miss falls through to the admin version-mismatch response (426), while Maxio's explicit dispatcher returns structured 400 `XMinioAdminInvalidArgument`; an empty `accessKey` often reaches MinIO lookup and returns 404, while Maxio rejects it as invalid input before lookup. This follows the reviewed project spec and must be documented rather than misreported as exact upstream behavior. Similarly, Maxio has no first-class MinIO service-account model; an extra long-term key is classified only as a subordinate Maxio credential for safe target rejection, not exposed as a claimed service account.

## Local Architecture Evidence and Decisions

1. Current `Maxio.IAM.delete_user/1` reads the user, enumerates key IDs, and calls `revoke_user_sessions/2` before its delete transaction. It can miss a concurrently issued key/session and currently broadcasts `user.user_arn` through `{:iam_changed, binary}`, which `CacheInvalidator` interprets as an access-key ID. U4 must not call it as-is. AWS Query `delete_user_strict/1` also fetches/checks/deletes outside the shared boundary and must be refactored onto the same lock while retaining AWS blocker semantics.
2. Current `Maxio.STS.issue_session/1`, `assume_role/3`, and `assume_role_with_web_identity/3` all end at `persist_session/1`, which locks only the new exact session ID. A status/delete/revoke transaction can commit between earlier validation and final insert. Final persistence must resolve the issuer chain, lock/revalidate its owning user or web-identity terminal and every active/unexpired session row, then reserve the new exact ID and insert.
3. `EctoStore` is authoritative and performs a DB read plus recursive user/issuer usability checks on every authentication; `invalidate/1` is intentionally a no-op. Therefore current production correctness does not depend on PubSub delivery. `MemoryStore` is ETS-backed and deletes only `{:access_key, id}`; tests must prove both long-term and session entries are removed and that an ARN mutation would fail.
4. `CredentialNamespace.reserve_exact/2` already serializes a target ID across long-term and every STS status. It remains responsible only for exact credential IDs. The new user identity module uses a distinct advisory namespace and concrete `iam_users.id`; do not overload `CredentialNamespace` with user names.
5. `STSSession` has no FK to `User` or `AccessKey`. Descendants are found by a fixed-point traversal: seed every user long-term key plus legacy sessions whose `principal_arn` is the user ARN; repeatedly add rows whose `issuer_access_key_id` is in the frontier. U5 collects all IDs; U4 locks those rows and sets every non-revoked row to `revoked` with `revoked_at`. A web-identity row (`issuer_access_key_id: nil` plus its web-identity fields) is a user-independent terminal; a later role chain issued from it remains independent and is excluded from any unrelated IAM user's descendant set.
6. Target classification is exact and facade-owned: first apply U4/U5 exact-signing-key self semantics; then classify the configured root key; then inspect an exact `STSSession` target; then inspect an exact `AccessKey` target and reject it when it is not the same-name primary credential for the user; finally lock the explicit `User` by case-insensitive name. A plain explicit user without a same-name key remains manageable because S2a defined `iam_users` as the authority collection. Any ambiguous legacy collision fails closed as action-not-allowed and mutates nothing. Owner ARN is never substituted for exact signer identity.
7. `EctoStore.put_access_key/1` is a low-level production write bypass; it directly upserts `access_keys` without the IAM identity or credential-namespace locks. S2c makes DB `put_access_key/1` return `{:error, :read_only_store}` and migrates its three direct DB tests to public IAM creation. The behaviour callback and `MemoryStore.put_access_key/1` remain fixture/dev seams. Configured-root bootstrap is the only direct DB credential write exception: it is configuration bootstrap, root cannot be a U4/U5 regular-user target, and its existing exact-key conflict behavior receives a regression test.
8. `principal_policies` and `mfa_devices` are ARN-owned and have no FK to `iam_users`. Every Ecto user-policy put/delete and every user-owned MFA create/activate/enable/resync/consuming verify/disable/delete mutation must enter `UserIdentity` (root/group/role operations retain their existing boundary). U4 explicitly deletes both row families under the same locked transaction. User-owned policy/MFA creation rechecks that the concrete user still exists after locking, so delete followed by same-name recreate cannot inherit a late orphan.

## File and Interface Map

### Create

- `lib/maxio/iam/user_identity.ex` — transaction-only user identity lock, concrete row lookup, credential-owner/STS-lineage resolution, and descendant enumeration.
- `lib/maxio/iam/credential_invalidation.ex` — deduplicated post-commit local invalidation plus typed/legacy cluster publication.
- `lib/mix/tasks/maxio.admin.user.remove.ex` — safe U4 CLI over `UserAdapter.remove/2`.
- `lib/mix/tasks/maxio.admin.user.status.ex` — safe U5 CLI over `UserAdapter.status/3`.
- `test/maxio/iam/user_identity_test.exs`
- `test/maxio/iam/credential_invalidation_test.exs`
- `test/maxio/auth/credential_store/ecto_store_test.exs`
- `test/maxio/policy/store/ecto_store_test.exs`
- `test/mix/tasks/maxio_admin_user_mutation_test.exs`

### Modify

- `lib/maxio/iam.ex` — public strict U4/U5 facades; refactor generic/U1/access-key/AWS Query delete, policy, MFA, status, and remove paths onto the shared identity transaction boundary; post-commit exact-ID invalidation.
- `lib/maxio/sts.ex` — final insert-time issuer-lineage lock/revalidation for all three issuance paths: `issue_session/1`, `assume_role/3`, and `assume_role_with_web_identity/3`; web-identity is a user-independent terminal but its later role chains still revalidate every session row.
- `lib/maxio/auth/credential_store/ecto_store.ex`, `lib/maxio/auth/credential_store.ex` — close/document the DB backend's low-level `put_access_key/1` write bypass while preserving the behaviour for `MemoryStore` fixtures.
- `lib/maxio/policy/store.ex`, `lib/maxio/policy/store/ecto_store.ex` — document/enforce the user-owned writer contract and lock/recheck every local user principal-policy put/delete, including direct Store/backend calls.
- `lib/maxio/cluster/notify.ex`, `lib/maxio/cluster/cache_invalidator.ex` — observable checked broadcast, typed credential-ID batch event, backward-compatible legacy exact-ID handling, and best-effort failure aggregation.
- `lib/maxio/admin/user_adapter.ex` — U4/U5 validation and public IAM calls only.
- `lib/maxio/admin/plug.ex` — exact routes, actions, signing-access-key extraction, empty 200, and safe logs.
- `lib/maxio/admin/error_map.ex`, `lib/maxio/s3/error.ex` — exact action-not-allowed mapping.
- `config/config.exs` — safe status/removal log metadata only; never IDs beyond target/affected counts and never secrets/tokens.
- `test/maxio/iam/minio_admin_user_test.exs`, `test/maxio/iam_test.exs`, `test/maxio/iam/mfa_device_test.exs`, `test/maxio/sts_test.exs`
- `test/maxio/cluster/notify_test.exs`, `test/maxio/auth/credential_store/memory_store_test.exs`
- `test/maxio/admin/user_adapter_test.exs`, `test/maxio/admin/user_endpoint_test.exs`, `test/maxio/admin/error_map_test.exs`
- `lib/maxio/compat/admin_user_fixture.ex`, `test/maxio/compat/admin_user_fixture_test.exs`
- `lib/maxio/compat/external_smoke.ex`, `test/maxio/compat/external_smoke_test.exs`
- `README.md`; `docs/superpowers/STATUS.md` only after review and all gates.

### Production Interfaces

```elixir
Maxio.IAM.update_minio_user_status_strict(name, "active" | "inactive", actor_access_key_id) ::
  {:ok, %{user: map(), affected: %{credentials: non_neg_integer()},
          invalidation: %{attempted: map(), failures: [map()]}}} | {:error, term()}

Maxio.IAM.delete_minio_user_strict(name, actor_access_key_id) ::
  {:ok, %{user: map(), affected: %{access_keys_deleted: non_neg_integer(),
                                  sessions_revoked: non_neg_integer(),
                                  principal_policies_deleted: non_neg_integer(),
                                  memberships_deleted: non_neg_integer(),
                                  mfa_devices_deleted: non_neg_integer()},
          invalidation: %{attempted: map(), failures: [map()]}}}
  | {:error, term()}

Maxio.IAM.UserIdentity.snapshot(module(), binary()) ::
  {:existing, Ecto.UUID.t()} | :missing

Maxio.IAM.UserIdentity.lock_snapshot(module(), binary(),
  {:existing, Ecto.UUID.t()} | :missing) ::
  {:ok, Maxio.IAM.User.t() | :missing} | {:error, :user_not_found | :identity_changed}

Maxio.IAM.UserIdentity.local_user_name(binary()) :: {:ok, binary()} | :not_local_user

Maxio.IAM.UserIdentity.lock_and_validate_issuer(module(), binary(), DateTime.t()) ::
  {:ok, :root | :web_identity | Maxio.IAM.User.t()} | {:error, :issuer_access_key_not_found}

Maxio.IAM.UserIdentity.descendant_credential_ids(module(), Maxio.IAM.User.t()) ::
  %{long_term: [binary()], sessions: [binary()]}

Maxio.IAM.CredentialInvalidation.after_commit([binary()], [Maxio.Cluster.Notify.event()]) ::
  %{attempted: %{local_ids: non_neg_integer(), typed_batches: non_neg_integer(),
                legacy_events: non_neg_integer()}, failures: [map()]}

Maxio.Cluster.Notify.broadcast_checked(Maxio.Cluster.Notify.event()) ::
  :ok | {:error, :pubsub_unavailable | {:transport_exit, term()} | term()}

Maxio.Auth.CredentialStore.invalidate(term()) :: :ok | {:error, term()}

Maxio.Admin.UserAdapter.status(binary(), "enabled" | "disabled", binary()) ::
  {:ok, map()} | {:error, term()}

Maxio.Admin.UserAdapter.remove(term(), binary()) :: {:ok, map()} | {:error, term()}
```

`actor_access_key_id` is the exact credential that signed the request: long-term/root principal `:access_key`, or session principal `:session_access_key`. Plug extracts it from the already authenticated principal and passes it to the adapter; the adapter never looks up caller credentials. Local Mix tasks obtain the configured **root access-key ID** from `Application.fetch_env!(:maxio, :s3) |> Keyword.fetch!(:root_user)` via the existing CLI config boot path and pass that same public actor contract. They never fetch, pass, print, or inspect `root_password`.

---

### Task 1: Commit the Plan First and Obtain Independent Protocol/Architecture GO

**Files:** first commit only `docs/superpowers/plans/2026-08-28-minio-admin-user-s2c.md`; the independent upstream research lane may then add exactly `test/fixtures/minio_admin_user_s2c/README.md`, `test/fixtures/minio_admin_user_s2c/minio_u4_remove_user.json`, `test/fixtures/minio_admin_user_s2c/minio_u5_set_user_status.json`, and `test/fixtures/minio_admin_user_s2c/mc_user_mutations.json`.

**Interfaces:** Consumes fixed base and the S2a/S2b public surface. Produces an immutable reviewed contract before any implementation.

- [ ] **Step 1: Enforce the plan-only starting boundary**

```powershell
$expectedBase='8dc75b4c6acd57e30ba768782598bdb4ee5774fe'
$head=(git rev-parse HEAD).Trim().ToLowerInvariant()
if ($LASTEXITCODE -ne 0) { throw 'git rev-parse HEAD failed' }
if ($head -ne $expectedBase) { throw 'unexpected starting HEAD' }
$branch=(git symbolic-ref --short HEAD).Trim()
if ($LASTEXITCODE -ne 0) { throw 'git branch lookup failed' }
if ($branch -cne 'codex/admin-user-s2c') { throw 'unexpected feature branch' }
$dirty=@(git status --porcelain=v1)
if ($LASTEXITCODE -ne 0) { throw 'git status failed' }
$expected='?? docs/superpowers/plans/2026-08-28-minio-admin-user-s2c.md'
if ($dirty.Count -ne 1 -or $dirty[0] -ne $expected) {
  throw "only the untracked S2c plan is allowed; actual: $($dirty -join '; ')"
}
```

- [ ] **Step 2: Commit the plan as the first branch commit**

```powershell
git add docs/superpowers/plans/2026-08-28-minio-admin-user-s2c.md
if ($LASTEXITCODE -ne 0) { throw 'git add plan failed' }
git commit -m "docs(plan): define admin user S2c mutations"
if ($LASTEXITCODE -ne 0) { throw 'plan commit failed' }
$parent=(git rev-parse HEAD^).Trim().ToLowerInvariant()
if ($LASTEXITCODE -ne 0) { throw 'git parent lookup failed' }
if ($parent -ne '8dc75b4c6acd57e30ba768782598bdb4ee5774fe') { throw 'plan is not first after fixed base' }
git diff --check 8dc75b4..HEAD
if ($LASTEXITCODE -ne 0) { throw 'plan diff check failed' }
$dirty=@(git status --porcelain=v1)
if ($LASTEXITCODE -ne 0) { throw 'git status failed' }
if ($dirty.Count -ne 0) { throw 'plan commit left a dirty tree' }
```

- [ ] **Step 3: Backfill, independently review, and commit the bounded upstream evidence pack**

The research lane records the fixed MinIO `7aac2a2c5b7c882e68c1ce017d8256be2feea27f`, madmin-go v3.0.109 `6897865311e2be91d814ea0ef4814a730d87d1cd`, mc `77f82e18b5401a65958f1619df6ebb994634bd88`, and mc-observed madmin `4b504b82db63` commits plus exact source paths/lines for: router query matching; both actions; U4 remove zero-length and U5 status chunked/`ContentLength=-1` request shapes; empty-body 200; same-status `UpdatedAt`; exact-caller self semantics; root/temp/subordinate target classification; derived caller parent-management semantics; action-not-allowed code/message; group/policy retention; service-account deletion; reversible status; and the persistent-STS deletion ambiguity. It also preserves the fixed-commit temporary server-suite plus madmin transcript proving sequential second remove 404 and non-self root status 404 with code `XMinioAdminNoSuchUser` and message `The specified user does not exist. (Specified user does not exist)`, while correcting the rejected `handler#L2271` citation with the actual handler source range. Concurrent double-remove ambiguity is recorded separately from the sequential oracle. Finally it records exact mc human success text, JSON success `{status:"success",accessKey:NAME}`, stdout/stderr placement, and error exit 1. The researcher writes no Elixir production code.

All evidence records are redacted of credentials/tokens before entering git while retaining request method/path/status/code/message and source provenance. The spec reviewer checks every JSON evidence record against the pinned source checkout and private raw transcript, checks the Exact Error Contract and both explicit Maxio stronger-linearizability/descendant-STS deviations, and verifies U1/U2/U3 remain unchanged. Reviewer, researcher, and future implementation author are separate lanes. Only after an APPROVED verdict may the implementation coordinator commit the exact allowlist and prove the pack's parent/hash/diff/clean boundary:

```powershell
$allowedEvidence=@(
  'test/fixtures/minio_admin_user_s2c/README.md',
  'test/fixtures/minio_admin_user_s2c/mc_user_mutations.json',
  'test/fixtures/minio_admin_user_s2c/minio_u4_remove_user.json',
  'test/fixtures/minio_admin_user_s2c/minio_u5_set_user_status.json'
)
$dirty=@(git status --porcelain=v1)
if ($LASTEXITCODE -ne 0) { throw 'evidence precommit status failed' }
$dirtyPaths=@($dirty | ForEach-Object { $_.Substring(3).Replace('\','/') } | Sort-Object -Unique)
if (@(Compare-Object $allowedEvidence $dirtyPaths).Count -ne 0) { throw "unexpected evidence paths: $($dirty -join '; ')" }
$evidenceParent=(git rev-parse HEAD).Trim().ToLowerInvariant()
if ($LASTEXITCODE -ne 0) { throw 'evidence parent lookup failed' }
git add -- $allowedEvidence
if ($LASTEXITCODE -ne 0) { throw 'git add evidence pack failed' }
$cached=@(git diff --cached --name-only | ForEach-Object { $_.Replace('\','/') } | Sort-Object)
if ($LASTEXITCODE -ne 0) { throw 'cached evidence lookup failed' }
if (@(Compare-Object $allowedEvidence $cached).Count -ne 0) { throw 'cached evidence allowlist mismatch' }
git commit -m "test(fixtures): pin admin user S2c protocol evidence"
if ($LASTEXITCODE -ne 0) { throw 'evidence commit failed' }
$evidenceSha=(git rev-parse HEAD).Trim().ToLowerInvariant()
if ($LASTEXITCODE -ne 0) { throw 'evidence SHA lookup failed' }
$evidenceDiff=@(git diff --name-only "$evidenceParent..$evidenceSha" | ForEach-Object { $_.Replace('\','/') } | Sort-Object)
if ($LASTEXITCODE -ne 0) { throw 'evidence diff lookup failed' }
if (@(Compare-Object $allowedEvidence $evidenceDiff).Count -ne 0) { throw 'evidence commit contains unexpected paths' }
git diff --check "$evidenceParent..$evidenceSha"
if ($LASTEXITCODE -ne 0) { throw 'evidence diff check failed' }
$dirty=@(git status --porcelain=v1)
if ($LASTEXITCODE -ne 0) { throw 'evidence final status failed' }
if ($dirty.Count -ne 0) { throw 'evidence commit left a dirty tree' }
Write-Output "EVIDENCE_PARENT=$evidenceParent EVIDENCE_SHA=$evidenceSha"
```

---

### Task 2: Put Every User-Owned Writer Behind One Identity Boundary

**Files:** create `lib/maxio/iam/user_identity.ex`, `test/maxio/iam/user_identity_test.exs`, `test/maxio/auth/credential_store/ecto_store_test.exs`, `test/maxio/policy/store/ecto_store_test.exs`; modify `lib/maxio/iam.ex`, `lib/maxio/sts.ex`, `lib/maxio/auth/credential_store.ex`, `lib/maxio/auth/credential_store/ecto_store.ex`, `lib/maxio/policy/store.ex`, `lib/maxio/policy/store/ecto_store.ex`, `test/maxio/iam/minio_admin_user_test.exs`, `test/maxio/iam/mfa_device_test.exs`, `test/maxio/iam_test.exs`, `test/maxio/sts_test.exs`, `test/maxio/policy/store_test.exs`.

**Interfaces:** Produces the three `UserIdentity` functions above. `Maxio.IAM` and `Maxio.STS` use them only inside a caller-owned `Repo.transaction`; Admin modules never call this internal module.

- [ ] **Step 1: Write deterministic RED concurrency tests**

Add tests with `Ecto.Adapters.SQL.Sandbox.unboxed_run/2`, `Repo.checkout/1`, `Task.async/1`, `assert_receive`, and `Task.await/2`; never use timer-based synchronization and never treat a completed query callback as evidence that a competing query is blocked. The losing task first queries `SELECT pg_backend_pid()` on its checked-out connection and reports that PID, then enters the public writer. The test transaction already holds the advisory/row lock and polls `pg_stat_activity`/`pg_locks` with a bounded monotonic deadline until that exact PID reports `wait_event_type = 'Lock'` on the expected advisory or row lock. Only then may the winner mutate/commit and release the loser. A helper failure prints the observed backend state rather than sleeping.

```elixir
test "disable wins before final STS insert and stale issuer cannot commit"
test "remove wins before final STS insert and no descendant or orphan commits"
test "an STS insert that wins first is visible to status/remove"
test "generic and strict user-bound access-key create/update/delete serialize with remove"
test "same-name generic create, U1 create, AWS strict delete, and U4 serialize on case-folded identity"
test "DB EctoStore put_access_key is read-only and cannot bypass IAM locks"
test "all three STS writers revalidate active unexpired lineage at final insert"
test "role-chained session resolves and locks its ultimate IAM user"
test "web-identity is a user-independent terminal and its later role chain locks and revalidates session rows"
test "user policy writer snapshot of old UUID cannot attach after remove plus same-name recreate"
test "every user-owned MFA writer snapshot of old UUID fails after remove plus same-name recreate"
test "removing identity lock calls makes the deterministic blocked-state races fail"
```

The table covers every production write entry point that could otherwise resurrect or change user-owned state: `create_user/1`, `update_user_name_strict/2`, `create_minio_user_strict/3` (U1), generic/strict access-key create/update/delete, all three STS issuers, AWS Query `delete_user_strict/1`, U4 remove, U5 status, Ecto user-owned principal-policy put/delete, and every user-owned MFA create/activate/enable/resync/consuming-verify/disable/delete writer. For each existing-user writer, schedule delete plus same-name recreate while it waits and assert the old UUID snapshot cannot mutate the replacement. FK-backed memberships, managed attachments, certificates, and SSH keys retain database FK serialization and are covered by U4 cascade races; root bootstrap is the documented root-only exception. Mutation expectations are explicit: removing the boundary from any listed writer, resolving self from owner ARN, skipping locked session active/expiry revalidation, or treating web identity as an unrelated user makes at least one named test fail.

- [ ] **Step 2: Run RED and prove the current races**

```powershell
Remove-Item Env:PGPORT -ErrorAction SilentlyContinue
$env:ERL_FLAGS='-kernel standard_io_encoding unicode'
$env:ELIXIR_ERL_OPTIONS='+S 2:2 +A0 +sbwt none +sbwtdcpu none +sbwtdio none'
mix test test/maxio/iam/user_identity_test.exs test/maxio/iam/minio_admin_user_test.exs test/maxio/iam/mfa_device_test.exs test/maxio/iam_test.exs test/maxio/sts_test.exs test/maxio/auth/credential_store/ecto_store_test.exs test/maxio/policy/store/ecto_store_test.exs test/maxio/policy/store_test.exs
if ($LASTEXITCODE -eq 0) { throw 'identity/issuance RED unexpectedly passed' }
```

Expected: failures show the stale `persist_session/1` commit, policy/MFA orphan, low-level DB write bypass, or transaction-external delete enumeration—not setup/timeouts.

- [ ] **Step 3: Implement the minimum shared boundary**

`UserIdentity` acquires locks in one stable order: sorted case-folded advisory user names (old then new name for rename/rebind), concrete `User.id` rows `FOR UPDATE`, lineage `STSSession` rows in stable ancestor-to-child ID order, then exact credential namespace for a newly allocated key/session. Any operation aimed at an existing generation snapshots the immutable `iam_users.id` before waiting, then `lock_snapshot/3` requires the same UUID after the name lock; a missing/create operation snapshots `:missing` and requires it still be absent. This prevents an old policy/MFA/key/status/remove request from landing on a same-name recreated user. Issuer resolution first traces an optimistic chain to determine its terminal, then takes the applicable identity lock and re-walks the chain under row locks. A long-term root or IAM-user key is the normal terminal. A row with `issuer_access_key_id: nil` and valid web-identity fields is an explicit user-independent terminal; a role-chain row that points to it remains user-independent but every lineage row is still locked and rechecked for `status == "active"` and `expires_at > now`. A nil issuer without the web-identity marker, cycle, missing row, changed lineage, inactive row, or expired row fails closed as `:issuer_access_key_not_found`.

Refactor every listed writer onto caller-owned transactions and private non-transactional insert/update/delete helpers, avoiding nested `Repo.transaction/1`. Generic `create_user/1`, rename, U1, generic/strict key create/update/delete, AWS strict delete, U4, and U5 all acquire/recheck the same identity. Every access-key notification moves outside the successful transaction and uses its exact ID. AWS Query delete preserves its blocker conflict result but evaluates blockers only after the locked row is fixed; it never delegates to U4's MinIO cascade. Generic user creation collects exact pre-existing legacy credential IDs whose usability changes when an explicit active row appears and invalidates them only after commit—never by broadcasting the user ARN through the credential slot.

Close the production bypass rather than trying to infer an IAM identity from arbitrary credential-store attributes: `Maxio.Auth.CredentialStore.EctoStore.put_access_key/1` always returns `{:error, :read_only_store}` and its module docs direct writes to public `Maxio.IAM`. Keep the behaviour callback and `MemoryStore` implementation for tests/dev, move the three existing direct Ecto write tests to public IAM fixtures, and add a mutation test proving a restored upsert fails the lock/race suite. Root bootstrap remains a separately tested configured-root path.

For `principal_policies`, update the Store contract and make EctoStore itself parse local user ARNs into the shared identity name, so calls through `Maxio.IAM`, `Maxio.Policy.Store`, or the backend cannot bypass the lock. It snapshots the concrete UUID before waiting, locks/rechecks that same generation for put, and locks the captured name/generation for delete even if the policy row has disappeared; root/group/role policies retain current behavior. A user-policy put after U4 therefore returns a stable not-found/identity-changed result instead of creating an orphan on a recreated user. For MFA, IAM wraps create/activate/enable/resync/consuming verify/disable/delete in the same boundary whenever the current or target principal is a local user; it snapshots/rechecks the owning UUID, and enable/rebind locks both old and target identities in sorted order and rechecks both generations. Root MFA is unchanged. U4 later deletes all user-owned policy and MFA rows inside its transaction.

All three STS paths call the new final persistence function with issuer and `now`: direct session and role assume follow their lineage; web-identity assume uses the explicit web terminal. `persist_session/1` performs locked lineage revalidation immediately before `CredentialNamespace.reserve_exact/2` and insert. Notify/invalidation remains post-commit.

- [ ] **Step 4: Run GREEN and commit the identity slice**

```powershell
Remove-Item Env:PGPORT -ErrorAction SilentlyContinue
$env:ERL_FLAGS='-kernel standard_io_encoding unicode'
$env:ELIXIR_ERL_OPTIONS='+S 2:2 +A0 +sbwt none +sbwtdcpu none +sbwtdio none'
mix test test/maxio/iam/user_identity_test.exs test/maxio/iam/minio_admin_user_test.exs test/maxio/iam/mfa_device_test.exs test/maxio/iam_test.exs test/maxio/sts_test.exs test/maxio/auth/credential_store/ecto_store_test.exs test/maxio/policy/store/ecto_store_test.exs test/maxio/policy/store_test.exs
if ($LASTEXITCODE -ne 0) { throw 'identity/issuance GREEN failed' }
mix format --check-formatted
if ($LASTEXITCODE -ne 0) { throw 'identity slice format failed' }
git add lib/maxio/iam/user_identity.ex lib/maxio/iam.ex lib/maxio/sts.ex lib/maxio/auth/credential_store.ex lib/maxio/auth/credential_store/ecto_store.ex lib/maxio/policy/store.ex lib/maxio/policy/store/ecto_store.ex test/maxio/iam/user_identity_test.exs test/maxio/iam/minio_admin_user_test.exs test/maxio/iam/mfa_device_test.exs test/maxio/iam_test.exs test/maxio/sts_test.exs test/maxio/auth/credential_store/ecto_store_test.exs test/maxio/policy/store/ecto_store_test.exs test/maxio/policy/store_test.exs
if ($LASTEXITCODE -ne 0) { throw 'git add identity slice failed' }
git commit -m "refactor(iam): linearize user credential issuance"
if ($LASTEXITCODE -ne 0) { throw 'identity slice commit failed' }
git diff --check 8dc75b4..HEAD
if ($LASTEXITCODE -ne 0) { throw 'identity slice diff check failed' }
$dirty=@(git status --porcelain=v1)
if ($LASTEXITCODE -ne 0) { throw 'identity slice status failed' }
if ($dirty.Count -ne 0) { throw 'identity slice left a dirty tree' }
```

---

### Task 3: Add Exact Best-Effort Invalidation and Reversible U5 Status

**Files:** create `lib/maxio/iam/credential_invalidation.ex`, `test/maxio/iam/credential_invalidation_test.exs`; modify `lib/maxio/iam.ex`, `lib/maxio/auth/credential_store.ex`, `lib/maxio/cluster/notify.ex`, `lib/maxio/cluster/cache_invalidator.ex`, `test/maxio/cluster/notify_test.exs`, `test/maxio/auth/credential_store/memory_store_test.exs`, `test/maxio/iam/minio_admin_user_test.exs`.

**Interfaces:** Produces `Notify.broadcast_checked/1`, `CredentialInvalidation.after_commit/2`, and `IAM.update_minio_user_status_strict/3`. Consumes Task 2 locks and descendant enumeration.

- [ ] **Step 1: Write RED status/invalidation tests**

```elixir
test "status updates and same-status writes advance updated_at under the row lock"
test "disable rejects every long-term and direct/role-chained STS credential immediately"
test "enable restores still-active and unexpired long-term and STS credentials"
test "status never changes access-key/session rows and never unwraps or rewrites keyring ciphertext"
test "commit returns all exact IDs and invalidation occurs only after commit"
test "rollback publishes no typed or legacy event and performs no local invalidation"
test "recording invalidator receives long-term and descendant STS IDs, never a user ARN"
test "MemoryStore removes preloaded long-term and session ETS entries by exact ID"
test "typed batch event and legacy exact-ID events remain observable by existing listeners"
test "first local invalidation failure does not skip later IDs or any publication"
test "typed broadcast failure does not skip every legacy exact-ID event"
test "checked Notify exposes unavailable and exit failures while legacy broadcast remains compatible"
test "failure evidence is structured and contains no access-key ID, ARN, secret, or session token"
```

Use an injected recording credential-store backend plus a subscribed observer. Seed a same-name primary key, a second long-term key, direct STS, role-chained STS, a revoked STS, and an unrelated user's credentials. Assert the exact deduplicated affected set and that the unrelated IDs survive. The mutation test deliberately replaces one ID with `user.user_arn`; it must fail both recording-store and mailbox assertions.

Use a recording backend whose first ID returns an error and whose second exits, plus a recording PubSub transport whose typed event fails. Assert every later local ID, typed batch, every legacy `{:iam_changed, id}`, and any principal-policy legacy event is still attempted exactly once and failures retain only safe stage/reason categories and counts. This is mutation-sensitive: changing `Enum.map`/reduction to fail-fast or routing an ARN through an ID slot must fail. For authoritative behavior, temporarily configure `EctoStore`, authenticate each credential before disable, assert `:error`/invalid-token while disabled, re-enable, and assert successful secret lookup again for active/unexpired rows. Separately configure `MemoryStore`, preload the same exact IDs, and assert post-commit invalidation removes stale ETS bytes; do not claim `MemoryStore` can reconstruct deleted bytes, because it is a standalone store rather than a DB read-through cache.

- [ ] **Step 2: Run focused RED**

```powershell
Remove-Item Env:PGPORT -ErrorAction SilentlyContinue
$env:ERL_FLAGS='-kernel standard_io_encoding unicode'
$env:ELIXIR_ERL_OPTIONS='+S 2:2 +A0 +sbwt none +sbwtdcpu none +sbwtdio none'
mix test test/maxio/iam/credential_invalidation_test.exs test/maxio/iam/minio_admin_user_test.exs test/maxio/cluster/notify_test.exs test/maxio/auth/credential_store/memory_store_test.exs
if ($LASTEXITCODE -eq 0) { throw 'U5/invalidation RED unexpectedly passed' }
```

- [ ] **Step 3: Implement U5 and the observable compatibility-safe invalidation seam**

Inside one `Repo.transaction`, U5 locks/classifies the target, rejects exact self/subordinate/temp/missing as the table requires, returns the fixed non-self configured-root 404, obtains the complete descendant ID set, and uses `Ecto.Changeset.force_change(:status, status)` so same-status calls update `updated_at`. It returns an internal public-user-plus-IDs result; only the outer successful transaction calls `CredentialInvalidation.after_commit/2`, then strips IDs and exposes safe affected counts plus failure evidence.

Widen the credential-store invalidation callback/facade result to `:ok | {:error, term()}` so failures are observable without breaking existing stores. Add `Notify.broadcast_checked/1`, which reports `:pubsub_unavailable`, transport errors, and caught exits as a safe `{:error, reason}`; retain `broadcast/1` as the documented legacy best-effort wrapper for existing callers. `after_commit/2` validates/deduplicates binaries, attempts `CredentialStore.invalidate({:access_key, id})` separately for **every** local ID, then one typed `{:iam_credentials_changed, ids}` broadcast, then every legacy event (one `{:iam_changed, id}` per exact ID plus caller-supplied non-credential legacy events). It catches/records each stage independently and never short-circuits later attempts. `CacheInvalidator` accepts both forms and likewise continues across every typed-batch ID even if an earlier backend invalidation errors/exits; duplicate local invalidation is explicitly idempotent.

Every caller may pass credential IDs only from `access_keys.access_key_id`/`sts_sessions.access_key_id` selected inside the transaction. A principal ARN is allowed only in its typed `{:principal_policy_changed, arn}` legacy event, never in `{:iam_changed, value}`. The result reports attempted counts and structured failure categories, not raw IDs/reasons that may include secrets. Post-commit failures are logged as `admin_user_invalidation_partial` and returned as evidence because the DB mutation has already committed; they are never misreported as rollback or hidden by `Notify.broadcast/1`. Current production `EctoStore` correctness remains DB-authoritative.

- [ ] **Step 4: Run GREEN and commit U5/invalidation**

```powershell
Remove-Item Env:PGPORT -ErrorAction SilentlyContinue
$env:ERL_FLAGS='-kernel standard_io_encoding unicode'
$env:ELIXIR_ERL_OPTIONS='+S 2:2 +A0 +sbwt none +sbwtdcpu none +sbwtdio none'
mix test test/maxio/iam/credential_invalidation_test.exs test/maxio/iam/minio_admin_user_test.exs test/maxio/cluster/notify_test.exs test/maxio/auth/credential_store/memory_store_test.exs
if ($LASTEXITCODE -ne 0) { throw 'U5/invalidation GREEN failed' }
git add lib/maxio/iam/credential_invalidation.ex lib/maxio/iam.ex lib/maxio/auth/credential_store.ex lib/maxio/cluster/notify.ex lib/maxio/cluster/cache_invalidator.ex test/maxio/iam/credential_invalidation_test.exs test/maxio/iam/minio_admin_user_test.exs test/maxio/cluster/notify_test.exs test/maxio/auth/credential_store/memory_store_test.exs
if ($LASTEXITCODE -ne 0) { throw 'git add U5/invalidation failed' }
git commit -m "feat(iam): add reversible user status invalidation"
if ($LASTEXITCODE -ne 0) { throw 'U5/invalidation commit failed' }
git diff --check 8dc75b4..HEAD
if ($LASTEXITCODE -ne 0) { throw 'U5/invalidation diff check failed' }
$dirty=@(git status --porcelain=v1)
if ($LASTEXITCODE -ne 0) { throw 'U5/invalidation status failed' }
if ($dirty.Count -ne 0) { throw 'U5/invalidation left a dirty tree' }
```

---

### Task 4: Add Atomic Linearizable U4 Cascade and Permanent Descendant Revocation

**Files:** modify `lib/maxio/iam.ex`, `test/maxio/iam/minio_admin_user_test.exs`, `test/maxio/iam/mfa_device_test.exs`, `test/maxio/iam_test.exs`, `test/maxio/sts_test.exs`, `test/maxio/policy/store/ecto_store_test.exs`.

**Interfaces:** Produces `IAM.delete_minio_user_strict/2`. Refactors old `delete_user/1` to the same locked cascade core while preserving its maintenance-helper idempotency; keeps AWS Query `delete_user_strict/1` conflict semantics.

- [ ] **Step 1: Write RED atomic-delete and interleaving tests**

```elixir
test "U4 removes the locked user identity and all local subordinate resources atomically"
test "U4 removes memberships but retains groups and group policies"
test "U4 deletes user principal policies and MFA devices that have no user FK"
test "U4 revokes every direct and role-chained STS row and reserves each exact ID"
test "deleted-user credentials never recover after a same-name user is recreated"
test "initially missing and sequential second U4 return exact dynamic no-such-user without invalidation"
test "two concurrent U4 removes linearize to one 200 and one exact dynamic no-such-user 404"
test "root, exact self, temporary, and subordinate long-term targets are action_not_allowed"
test "rollback leaves identity/resources/session status unchanged and emits no invalidation"
test "concurrent key/session issuance either wins before delete and is removed/revoked, or loses after delete"
test "concurrent policy or MFA writer either wins and is deleted or loses with not-found"
test "same-name recreate cannot inherit a policy mapping, membership, or MFA device"
test "principal-policy invalidation is post-commit and never replaces exact credential invalidation"
test "delete result preserves every affected row count and invalidation failure summary"
```

Seed inline policy, managed attachment, two group memberships, two MFA states, certificate, SSH key, multiple long-term keys, direct STS, role chain, revoked descendant, and unrelated/web-identity sessions. Assert no orphan user-owned row after success, group/managed-policy survival, unrelated web-identity chain survival, every deleted/revoked exact ID invalidated, no ARN in an ID event, and `CredentialNamespace.reserve_exact/2` rejects reuse of retained revoked session IDs. Force a late failure after all deletes/revokes to prove rollback restores policy/MFA rows too. The double-remove test uses the Task 2 backend-PID/`pg_stat_activity` blocked-state barrier; merely awaiting query completion is forbidden. Removing the name/row lock must allow two successes and fail this mutation test.

- [ ] **Step 2: Run focused RED**

```powershell
Remove-Item Env:PGPORT -ErrorAction SilentlyContinue
$env:ERL_FLAGS='-kernel standard_io_encoding unicode'
$env:ELIXIR_ERL_OPTIONS='+S 2:2 +A0 +sbwt none +sbwtdcpu none +sbwtdio none'
mix test test/maxio/iam/minio_admin_user_test.exs test/maxio/iam/mfa_device_test.exs test/maxio/iam_test.exs test/maxio/sts_test.exs test/maxio/policy/store/ecto_store_test.exs
if ($LASTEXITCODE -eq 0) { throw 'U4 RED unexpectedly passed' }
```

- [ ] **Step 3: Implement one locked cascade core**

The transaction acquires the case-folded advisory identity lock, selects the exact `User` by immutable UUID `FOR UPDATE`, classifies forbidden targets, collects/locks every user long-term key and fixed-point descendant STS row, revokes descendants with one transaction timestamp, explicitly deletes no-FK `principal_policies` and `mfa_devices`, deletes certificates/SSH keys/access keys, and deletes the `User`. Existing FKs cascade memberships and managed attachments; capture their before/delete counts inside the transaction and prove groups and managed policy rows remain. A sequential caller after the commit sees the adjudicated dynamic no-such-user error; a simultaneously blocked second caller rechecks under the name lock and produces the same 404, giving Maxio exactly one 200 plus one 404 even though fixed MinIO can expose two 200s.

The internal transaction result contains public deleted user, user ARN, exact affected IDs, revoked session IDs, and row counts for each subordinate family. Only after commit call exact credential invalidation and publish `{:principal_policy_changed, user_arn}` through the checked best-effort path. The public facade strips exact IDs but preserves every safe affected count and invalidation failure summary; `UserAdapter.remove/2` returns that result unchanged so CLI/log evidence cannot silently collapse it to `:ok`. Never substitute an ARN-shaped `{:iam_changed, user_arn}` event.

The old maintenance `delete_user/1` delegates to this same core with `missing: :ok` and no actor classification. U4 uses `missing: :error`. AWS Query `delete_user_strict/1` already entered the same identity boundary in Task 2 but retains conflict-on-subordinates behavior and must not call this cascade. Do not retain the old get/enumerate/revoke-before-transaction sequence and do not add adapter-level get+delete.

- [ ] **Step 4: Run GREEN and commit U4**

```powershell
Remove-Item Env:PGPORT -ErrorAction SilentlyContinue
$env:ERL_FLAGS='-kernel standard_io_encoding unicode'
$env:ELIXIR_ERL_OPTIONS='+S 2:2 +A0 +sbwt none +sbwtdcpu none +sbwtdio none'
mix test test/maxio/iam/minio_admin_user_test.exs test/maxio/iam/mfa_device_test.exs test/maxio/iam_test.exs test/maxio/sts_test.exs test/maxio/iam/credential_invalidation_test.exs test/maxio/policy/store/ecto_store_test.exs
if ($LASTEXITCODE -ne 0) { throw 'U4 GREEN failed' }
git add lib/maxio/iam.ex test/maxio/iam/minio_admin_user_test.exs test/maxio/iam/mfa_device_test.exs test/maxio/iam_test.exs test/maxio/sts_test.exs test/maxio/policy/store/ecto_store_test.exs
if ($LASTEXITCODE -ne 0) { throw 'git add U4 failed' }
git commit -m "feat(iam): atomically remove MinIO users"
if ($LASTEXITCODE -ne 0) { throw 'U4 commit failed' }
git diff --check 8dc75b4..HEAD
if ($LASTEXITCODE -ne 0) { throw 'U4 diff check failed' }
$dirty=@(git status --porcelain=v1)
if ($LASTEXITCODE -ne 0) { throw 'U4 git-status check failed' }
if ($dirty.Count -ne 0) { throw 'U4 left a dirty tree' }
```

---

### Task 5: Expose U4/U5 Through Adapter, Endpoint, CLI, Logs, Docs, and Safe mc Smoke

**Files:** create the two Mix tasks/tests listed in the file map; modify Admin Plug/Adapter/errors/config, `test/maxio/iam/minio_admin_user_test.exs`, endpoint/adapter/error tests, fixture/smoke/tests, and README.

**Interfaces:** Consumes Task 3/4 public IAM facades. Produces exact U4/U5 HTTP and CLI surfaces without direct persistence access.

- [ ] **Step 1: Write RED adapter/error/endpoint tests**

Add table-driven mutation-name validation that preserves the completed S2b `MinioAccessKey` domain: internal ASCII space, `!`, `#`, and `:` are legal; missing/empty, equals, slash/backslash, path, non-ASCII/out-of-range, Unicode-boundary whitespace, and comma follow the Exact Error Contract. Percent-encode the space/`#` query fixtures so router parsing, not a malformed URL, is exercised. Add exact reason mapping for every error row and signed endpoint tests for route, action, authz-first ordering, actor credential extraction, no body read/encryption, strict empty 200, adjudicated sequential second-remove/root-status 404 message, same-status success, and U1/U2/U3 regression.

```elixir
test "U4 remove uses admin:DeleteUser and returns strict empty 200"
test "U5 status uses admin:EnableUser for both enabled and disabled"
test "U5 exact signing credential self-target is invalid argument"
test "U4 root/self/session/subordinate targets are action-not-allowed"
test "U5 session and non-self configured-root targets are exact dynamic no-such-user"
test "IAM facades use exact STS actor ID and permit U5-status/U4-remove of its parent"
test "real signed STS Admin requests U5-status and U4-remove the parent when policies allow"
test "exact signer comparison allows parent mutation while owner-based self comparison fails"
test "facades and endpoints manage S2b names containing internal space, !, #, or : through U4 and U5"
test "authorization denial happens before target classification or mutation"
test "U4/U5 never invoke ControlBody or Envelope and ignore Content-Type"
test "wrong methods and remaining routes stay authenticated JSON 501"
```

Do not fake the STS actor at adapter level: mint a real signed session credential, attach only the required admin action to its effective identity, send real SigV4 Admin requests, and prove the exact session access key—not its parent owner ARN—is passed as actor. A mutation that substitutes owner access key must fail the parent-management test. Add a fake body reader/envelope probe that raises if invoked. For status, authenticate target S3 access before disable, call U5, assert its next signed S3 request is rejected, re-enable through a different admin, and assert the same long-term/direct STS/role-chain credentials work again. For remove, assert the same credentials remain rejected after same-name recreation and retained descendant STS status is revoked.

- [ ] **Step 2: Run endpoint RED**

```powershell
Remove-Item Env:PGPORT -ErrorAction SilentlyContinue
$env:ERL_FLAGS='-kernel standard_io_encoding unicode'
$env:ELIXIR_ERL_OPTIONS='+S 2:2 +A0 +sbwt none +sbwtdcpu none +sbwtdio none'
mix test test/maxio/iam/minio_admin_user_test.exs test/maxio/admin/user_adapter_test.exs test/maxio/admin/error_map_test.exs test/maxio/admin/user_endpoint_test.exs
if ($LASTEXITCODE -eq 0) { throw 'Admin U4/U5 RED unexpectedly passed' }
```

- [ ] **Step 3: Implement the thin HTTP/CLI surfaces and safe evidence**

Add exact Plug dispatch entries before the 501 fallback. Both call `authorize_and_run/5`; Plug extracts the exact signing access key from the authenticated principal, calls the adapter, maps reason atoms, and uses `send_empty_success/1`. U4 remove accepts the pinned explicit-zero body without reading it; U5 status accepts the pinned chunked/unknown-length empty request without reading it. Logs contain `admin_action`, `required_action`, `target_user`, requested status, each safe affected count, invalidation failure count, decision, principal ARN, auth type, request ID, and surface—but never secrets, session tokens, policy documents, keyring bytes, exact affected-ID lists, or unsafe transport reasons.

Add a mutation-only adapter validator that first preserves the existing boundary-whitespace/comma `:invalid_resource_name` distinction and otherwise delegates to public `IAM.validate_minio_access_key/1`, mapping failure to `:invalid_argument`. Use it only for U4/U5. Do not broaden S2a U3 `validate_name/1` in this batch; the endpoint tests explicitly prove internal space/`!`/`#`/`:` names created by completed S2b are manageable through mutations without changing UserInfo's reviewed validation surface.

Add read-safe CLI commands:

```text
mix maxio.admin.user.status NAME enabled|disabled
mix maxio.admin.user.remove NAME --confirm NAME
```

They boot through `Maxio.Config.CLI`, read only configured `root_user` as `actor_access_key_id`, call `UserAdapter`, print target/status/safe affected counts/invalidation-attention outcome, and require exact remove confirmation. Tests install a distinct root ID and secret and prove only the ID reaches the facade/argv/output/log while the secret remains absent. The actor contract is identical to Plug's exact signing-key argument; CLI is local evidence, not a substitute for admin authz.

Extend `AdminUserFixture` to create a temporary U1-style regular user and same-name key through the safe public IAM API, attach a minimal inline policy granting only `s3:ListAllMyBuckets` for the live authorization probe, and clean up through the public locked maintenance facade. The callback receives the public user plus a zero-argument `s3_probe` closure; that closure alone captures the secret and performs the header-signed `GET /` with existing SigV4 primitives and `Req`. It returns only status/code evidence, has a redacted `Inspect` boundary by being a function capability, and no map/argv/artifact ever contains the secret. Automated smoke must never execute `mc admin user add`, whose positional secret would enter argv.

Run **two independent fixture users**, never a mode branch. Human mode executes and immediately captures/asserts exact exit/stdout/stderr for `mc admin user info`, disable ("Disabled user `NAME` successfully."), info/status, enable ("Enabled user `NAME` successfully."), info/status, and remove ("Removed user `NAME` successfully."); success stderr must be empty. JSON mode independently executes info plus the pinned mc `--json` argv form for disable/enable/remove, decodes every line, and asserts exact `{status:"success", accessKey: NAME}`, empty unexpected stderr, and exit 0. Both lifecycles run S3 probe success → disabled reject → re-enabled success and each enters reliable cleanup immediately after resource creation. Human mode additionally executes the adjudicated sequential second remove and requires exit 1 plus exact dynamic no-such-user code/message; the deterministic concurrent one-200/one-404 proof remains an ExUnit test, not a flaky mc race. Reuse the existing `ExternalSmoke` ordered primary/cleanup result aggregation: each command captures exit/output before the next command; success+cleanup-failure and primary+cleanup-failure retain ordered causes, and generic rescue cannot overwrite either.

- [ ] **Step 4: Test CLI/smoke failure composition and docs**

Add tests proving both human and JSON users always execute, exact stdout/stderr/exit assertions fail closed, success+cleanup failure and primary failure+cleanup failure preserve ordered causes, disabled-info is covered, no secret occurs in argv/log/artifact, repeated smoke creates independent users, and `finally` cleanup never converts failure to pass. README documents design-spec U4 remove/U5 status actions/wire, exact dynamic 404, stronger concurrent-remove linearization, reversible status, permanent descendant revocation/ID reservation deviation, production EctoStore authority and closed write bypass, MemoryStore limitation, no migration/keyring change, and deferred durable epoch for future production caches.

- [ ] **Step 5: Run GREEN and commit the surface slice**

```powershell
Remove-Item Env:PGPORT -ErrorAction SilentlyContinue
$env:ERL_FLAGS='-kernel standard_io_encoding unicode'
$env:ELIXIR_ERL_OPTIONS='+S 2:2 +A0 +sbwt none +sbwtdcpu none +sbwtdio none'
mix test test/maxio/iam/minio_admin_user_test.exs test/maxio/admin/user_adapter_test.exs test/maxio/admin/error_map_test.exs test/maxio/admin/user_endpoint_test.exs test/mix/tasks/maxio_admin_user_mutation_test.exs test/maxio/compat/admin_user_fixture_test.exs test/maxio/compat/external_smoke_test.exs
if ($LASTEXITCODE -ne 0) { throw 'Admin/CLI/smoke GREEN failed' }
mix compile --warnings-as-errors
if ($LASTEXITCODE -ne 0) { throw 'Admin/CLI/smoke compile failed' }
git add lib/maxio/admin/user_adapter.ex lib/maxio/admin/plug.ex lib/maxio/admin/error_map.ex lib/maxio/s3/error.ex config/config.exs lib/mix/tasks/maxio.admin.user.status.ex lib/mix/tasks/maxio.admin.user.remove.ex test/maxio/iam/minio_admin_user_test.exs test/maxio/admin/user_adapter_test.exs test/maxio/admin/error_map_test.exs test/maxio/admin/user_endpoint_test.exs test/mix/tasks/maxio_admin_user_mutation_test.exs lib/maxio/compat/admin_user_fixture.ex test/maxio/compat/admin_user_fixture_test.exs lib/maxio/compat/external_smoke.ex test/maxio/compat/external_smoke_test.exs README.md
if ($LASTEXITCODE -ne 0) { throw 'git add Admin/CLI/smoke slice failed' }
git commit -m "feat(admin): add user status and remove endpoints"
if ($LASTEXITCODE -ne 0) { throw 'Admin/CLI/smoke commit failed' }
git diff --check 8dc75b4..HEAD
if ($LASTEXITCODE -ne 0) { throw 'Admin/CLI/smoke diff check failed' }
$dirty=@(git status --porcelain=v1)
if ($LASTEXITCODE -ne 0) { throw 'Admin/CLI/smoke status failed' }
if ($dirty.Count -ne 0) { throw 'Admin/CLI/smoke slice left a dirty tree' }
```

---

### Task 6: Independent Review, Author RED/Fix, Focused Gates, and One Precommit

**Files:** review all `git diff 8dc75b4..HEAD`; accepted fixes touch only owning files/tests.

**Interfaces:** Produces an independently approved clean candidate before live/STATUS/integration.

- [ ] **Step 1: Clean-tree dual review handoff**

```powershell
$dirty=@(git status --porcelain=v1)
if ($LASTEXITCODE -ne 0) { throw 'review status failed' }
if ($dirty.Count -ne 0) { throw 'review requires a clean tree' }
git diff --check 8dc75b4..HEAD
if ($LASTEXITCODE -ne 0) { throw 'review diff check failed' }
git log --oneline 8dc75b4..HEAD
if ($LASTEXITCODE -ne 0) { throw 'review log failed' }
git diff --stat 8dc75b4..HEAD
if ($LASTEXITCODE -ne 0) { throw 'review stat failed' }
```

Protocol reviewer cites pinned source/oracle `path:line` evidence for route/action/status/error/body, corrected handler provenance, sequential-repeat/root-target dynamic 404, concurrent-remove ambiguity, and both human/JSON mc command behavior. Architecture reviewer cites final `path:line` evidence for: stable lock order and PostgreSQL blocked-state test; generic/U1/key/AWS-delete/U4/U5 plus all three STS writer coverage; closed EctoStore bypass; locked no-FK policy/MFA writers; web-identity terminal and web-identity role-chain revalidation; direct/user-role descendant traversal; U5 reversible auth; U4 permanent revoke/ID reservation and stronger concurrent linearization; all-attempted commit-only invalidation with observable Notify failures; exact IDs/no ARN; safe affected-result preservation; CLI root access-key ID actor; EctoStore/MemoryStore/keyring treatment; adapter public-facade-only; and remaining 501 boundaries. Critical/Important findings block.

- [ ] **Step 2: Accepted findings use author RED → fix → focused GREEN → separate commit**

The implementation author writes a mutation-sensitive failing test for each accepted finding, runs that one RED, makes the smallest architectural fix, reruns focused GREEN, and commits separately. Reviewer never authors the fix. Every fix invalidates the prior approval.

- [ ] **Step 3: Re-review the final clean fixed range**

```powershell
$dirty=@(git status --porcelain=v1)
if ($LASTEXITCODE -ne 0) { throw 're-review status failed' }
if ($dirty.Count -ne 0) { throw 're-review requires a clean tree' }
git diff --check 8dc75b4..HEAD
if ($LASTEXITCODE -ne 0) { throw 're-review diff check failed' }
git log --oneline 8dc75b4..HEAD
if ($LASTEXITCODE -ne 0) { throw 're-review log failed' }
```

Both reviewers issue final APPROVED with no open Critical/Important before gates.

- [ ] **Step 4: Run focused tests/compile/format**

```powershell
Remove-Item Env:PGPORT -ErrorAction SilentlyContinue
$env:ERL_FLAGS='-kernel standard_io_encoding unicode'
$env:ELIXIR_ERL_OPTIONS='+S 2:2 +A0 +sbwt none +sbwtdcpu none +sbwtdio none'
mix test test/maxio/iam/user_identity_test.exs test/maxio/iam/credential_invalidation_test.exs test/maxio/iam/minio_admin_user_test.exs test/maxio/iam/mfa_device_test.exs test/maxio/iam_test.exs test/maxio/sts_test.exs test/maxio/cluster/notify_test.exs test/maxio/auth/credential_store/ecto_store_test.exs test/maxio/auth/credential_store/memory_store_test.exs test/maxio/policy/store/ecto_store_test.exs test/maxio/policy/store_test.exs test/maxio/admin/user_adapter_test.exs test/maxio/admin/error_map_test.exs test/maxio/admin/user_endpoint_test.exs test/maxio/admin/authz_test.exs test/maxio/admin/policy_endpoint_test.exs test/mix/tasks/maxio_admin_user_test.exs test/mix/tasks/maxio_admin_user_mutation_test.exs test/maxio/compat/admin_user_fixture_test.exs test/maxio/compat/external_smoke_test.exs
if ($LASTEXITCODE -ne 0) { throw 'focused S2c/regression tests failed' }
mix compile --warnings-as-errors
if ($LASTEXITCODE -ne 0) { throw 'warnings-as-errors compile failed' }
mix format --check-formatted
if ($LASTEXITCODE -ne 0) { throw 'format check failed' }
```

- [ ] **Step 5: Run the batch's single final precommit**

```powershell
Remove-Item Env:PGPORT -ErrorAction SilentlyContinue
$env:ERL_FLAGS='-kernel standard_io_encoding unicode'
$env:ELIXIR_ERL_OPTIONS='+S 2:2 +A0 +sbwt none +sbwtdcpu none +sbwtdio none'
mix precommit
if ($LASTEXITCODE -ne 0) { throw 'single final precommit failed' }
```

Any fix after this step requires author RED/GREEN, renewed independent review, focused gates, and a replacement single-final-precommit evidence run. Never accumulate multiple runs as if all were final.

---

### Task 7: Real mc Lifecycle, STATUS, Final SHA Review, Fast-Forward, and Atomic Push

**Files:** live artifact only (gitignored); modify/commit `docs/superpowers/STATUS.md` only after final clean evidence.

**Interfaces:** Consumes the approved candidate and produces the exact reviewed/pushed feature SHA.

- [ ] **Step 1: Run the real safe lifecycle when prerequisites exist**

Use one endpoint `http://127.0.0.1:9900`, a pinned `mc`, root env without printing it, a separately running Maxio server, and the shared DB/keyring configuration required by the fixture.

```powershell
Remove-Item Env:PGPORT -ErrorAction SilentlyContinue
$env:ERL_FLAGS='-kernel standard_io_encoding unicode'
$env:ELIXIR_ERL_OPTIONS='+S 2:2 +A0 +sbwt none +sbwtdcpu none +sbwtdio none'
mix maxio.compat.matrix --include-external-smoke --external-smoke-client minio_mc
if ($LASTEXITCODE -ne 0) { throw 'external smoke process failed' }
```

Read the artifact rather than trusting process exit. Passing requires **both** independently named fixtures: human lifecycle and JSON lifecycle. Each must show immediate captured exit/stdout/stderr for info → signed S3 baseline success → disable → info exactly disabled → signed S3 reject → enable → info exactly enabled → signed S3 success → remove, followed by cleanup `ok`; human output must equal the pinned success strings with empty stderr, while every JSON mutation must decode to exact `status=success,accessKey=NAME` with empty unexpected stderr. Human mode also proves sequential second remove exit 1 and the exact dynamic no-such-user code/message. The artifact must show distinct users, no mode shortcut, no `admin user add`, no secret in argv/log/artifact, and exact endpoint. Separately run the pinned real-MinIO oracle for persistent-STS ambiguity and retain its evidence; Maxio's chosen U4 revoke behavior remains documented even if upstream exposes the bug. Missing `mc`, env, server, shared persistence, either fixture, any assertion failure, or cleanup failure is **BLOCKED/attention**, never pass. A live blocker may ship only with explicit owner acceptance.

- [ ] **Step 2: Update STATUS only after final clean review/gates/live evidence**

```powershell
$dirty=@(git status --porcelain=v1)
if ($LASTEXITCODE -ne 0) { throw 'pre-STATUS status failed' }
if ($dirty.Count -ne 0) { throw 'STATUS update requires a clean reviewed code tree' }
git diff --check 8dc75b4..HEAD
if ($LASTEXITCODE -ne 0) { throw 'pre-STATUS diff check failed' }
```

Record exact commits, pinned upstream evidence and corrected provenance, both reviewer verdicts, test/precommit counts, both live fixture modes or accepted blocker, reversible U5 proof, permanent U4 descendant revocation/ID reservation and concurrent-linearization deviations, closed EctoStore write bypass, policy/MFA writer coverage, production EctoStore authority, MemoryStore/keyring evidence, invalidation partial-failure result contract, deferred epoch/cache hardening, and remaining authenticated 501 routes. Then commit only STATUS:

```powershell
git add docs/superpowers/STATUS.md
if ($LASTEXITCODE -ne 0) { throw 'git add STATUS failed' }
$cached=@(git diff --cached --name-only)
if ($LASTEXITCODE -ne 0) { throw 'cached path lookup failed' }
if ($cached.Count -ne 1 -or $cached[0] -ne 'docs/superpowers/STATUS.md') { throw "STATUS commit contains unexpected paths: $($cached -join ', ')" }
git commit -m "docs(status): record admin user S2c evidence"
if ($LASTEXITCODE -ne 0) { throw 'STATUS commit failed' }
git diff --check 8dc75b4..HEAD
if ($LASTEXITCODE -ne 0) { throw 'final diff check failed' }
$dirty=@(git status --porcelain=v1)
if ($LASTEXITCODE -ne 0) { throw 'final feature status failed' }
if ($dirty.Count -ne 0) { throw 'feature is not clean after STATUS' }
$featureCandidateSha=(git rev-parse HEAD).Trim().ToLowerInvariant()
if ($LASTEXITCODE -ne 0) { throw 'feature candidate SHA lookup failed' }
if ($featureCandidateSha -notmatch '\A[0-9a-f]{40}\z') { throw 'feature candidate is not a full SHA' }
Write-Output "FEATURE_CANDIDATE_SHA=$featureCandidateSha"
```

- [ ] **Step 3: Freeze and independently approve the exact final SHA**

Both independent reviewers re-check `8dc75b4..FEATURE_CANDIDATE_SHA` including STATUS and record exact `reviewed_base_sha=8dc75b4c6acd57e30ba768782598bdb4ee5774fe` and `reviewed_feature_sha`. Any accepted finding restarts author RED/fix, review, gates, final precommit, live evidence as affected, and STATUS; never integrate a different SHA.

- [ ] **Step 4: Assert both worktrees, fast-forward master, atomically push both refs, and verify remote SHAs**

Run from the main worktree. Set `MAXIO_REVIEWED_FEATURE_SHA` from the independent approval, never from the live branch.

```powershell
$reviewedBaseSha='8dc75b4c6acd57e30ba768782598bdb4ee5774fe'
$reviewedFeatureSha=([string]$env:MAXIO_REVIEWED_FEATURE_SHA).Trim().ToLowerInvariant()
if ($reviewedFeatureSha -notmatch '\A[0-9a-f]{40}\z') { throw 'MAXIO_REVIEWED_FEATURE_SHA must be exact 40-hex' }
$featureWorktree='C:\Users\DYZ\Documents\dev\hemifuture\maxio\.worktrees\admin-user-s2c'

$currentBranch=(git symbolic-ref --short HEAD).Trim()
if ($LASTEXITCODE -ne 0) { throw 'current branch lookup failed' }
if ($currentBranch -cne 'master') { throw 'integration must run on exact local master' }
$masterRef=(git rev-parse refs/heads/master).Trim().ToLowerInvariant()
if ($LASTEXITCODE -ne 0) { throw 'master ref lookup failed' }
if ($masterRef -ne $reviewedBaseSha) { throw 'master moved from reviewed base; re-review combined range' }
$featureRef=(git rev-parse refs/heads/codex/admin-user-s2c).Trim().ToLowerInvariant()
if ($LASTEXITCODE -ne 0) { throw 'feature ref lookup failed' }
if ($featureRef -ne $reviewedFeatureSha) { throw 'feature ref differs from reviewed SHA' }
$mainHead=(git rev-parse HEAD).Trim().ToLowerInvariant()
if ($LASTEXITCODE -ne 0) { throw 'main HEAD lookup failed' }
if ($mainHead -ne $reviewedBaseSha) { throw 'main HEAD moved from reviewed base' }
$mainDirty=@(git status --porcelain=v1)
if ($LASTEXITCODE -ne 0) { throw 'main status failed' }
if ($mainDirty.Count -ne 0) { throw 'main worktree is not clean' }
$featureHead=(git -C $featureWorktree rev-parse HEAD).Trim().ToLowerInvariant()
if ($LASTEXITCODE -ne 0) { throw 'feature HEAD lookup failed' }
if ($featureHead -ne $reviewedFeatureSha) { throw 'feature HEAD differs from reviewed SHA' }
$featureDirty=@(git -C $featureWorktree status --porcelain=v1)
if ($LASTEXITCODE -ne 0) { throw 'feature status failed' }
if ($featureDirty.Count -ne 0) { throw 'feature worktree is not clean' }
$featureBase=(git -C $featureWorktree merge-base $reviewedFeatureSha $reviewedBaseSha).Trim().ToLowerInvariant()
if ($LASTEXITCODE -ne 0) { throw 'feature merge-base lookup failed' }
if ($featureBase -ne $reviewedBaseSha) { throw 'reviewed feature does not descend from reviewed base' }

git merge --ff-only codex/admin-user-s2c
if ($LASTEXITCODE -ne 0) { throw 'fast-forward merge failed' }
$mergedHead=(git rev-parse HEAD).Trim().ToLowerInvariant()
if ($LASTEXITCODE -ne 0) { throw 'post-merge HEAD lookup failed' }
if ($mergedHead -ne $reviewedFeatureSha) { throw 'post-merge HEAD is not reviewed SHA' }
$postMergeDirty=@(git status --porcelain=v1)
if ($LASTEXITCODE -ne 0) { throw 'post-merge status failed' }
if ($postMergeDirty.Count -ne 0) { throw 'post-merge main is not clean' }
$postMergeFeatureDirty=@(git -C $featureWorktree status --porcelain=v1)
if ($LASTEXITCODE -ne 0) { throw 'post-merge feature status failed' }
if ($postMergeFeatureDirty.Count -ne 0) { throw 'post-merge feature is not clean' }

git push --atomic origin refs/heads/master:refs/heads/master refs/heads/codex/admin-user-s2c:refs/heads/codex/admin-user-s2c
if ($LASTEXITCODE -ne 0) { throw 'atomic master/feature push failed' }
$remoteRefs=@(git ls-remote --heads origin refs/heads/master refs/heads/codex/admin-user-s2c)
if ($LASTEXITCODE -ne 0) { throw 'remote ref lookup failed' }
$remoteByRef=@{}
foreach($line in $remoteRefs){
  $parts=$line -split "`t",2
  if($parts.Count -eq 2){ $remoteByRef[$parts[1]]=$parts[0].ToLowerInvariant() }
}
if ($remoteByRef['refs/heads/master'] -ne $reviewedFeatureSha) { throw 'remote master is not reviewed SHA' }
if ($remoteByRef['refs/heads/codex/admin-user-s2c'] -ne $reviewedFeatureSha) { throw 'remote feature is not reviewed SHA' }
$finalMainDirty=@(git status --porcelain=v1)
if ($LASTEXITCODE -ne 0) { throw 'final main status failed' }
if ($finalMainDirty.Count -ne 0) { throw 'final main is not clean' }
$finalFeatureDirty=@(git -C $featureWorktree status --porcelain=v1)
if ($LASTEXITCODE -ne 0) { throw 'final feature status failed' }
if ($finalFeatureDirty.Count -ne 0) { throw 'final feature is not clean' }
```

## Completion Checklist

- Design-spec U4 remove and U5 status exact routes/actions/errors/empty 200 pass pinned protocol evidence and both real `mc` lifecycle modes, or live is honestly owner-accepted BLOCKED.
- Status is reversible: all existing user-derived long-term and STS credentials reject while inactive and active/unexpired rows recover after re-enable.
- Remove is permanent: user resources are atomically removed, descendants stay revoked, retained STS IDs stay reserved, and no orphan/new post-delete credential exists.
- Every generic/U1/key/AWS-delete/U4/U5 and three-STS writer plus user-owned policy/MFA writer shares the reviewed identity boundary; the DB credential-store bypass is closed; no adapter-level Repo/store access and no pre-commit notification remains.
- EctoStore, MemoryStore, checked Notify, all-attempted typed/legacy PubSub, safe failure aggregation, and keyring non-involvement each have separate mutation-sensitive proof; no ARN enters an exact-ID invalidation slot.
- Independent protocol and architecture/code reviewers approve the clean fixed range; focused gates and exactly one final precommit pass.
- STATUS is the final content commit; integration is exact-SHA, fast-forward only, and both remote refs resolve to the reviewed SHA with both worktrees clean.
