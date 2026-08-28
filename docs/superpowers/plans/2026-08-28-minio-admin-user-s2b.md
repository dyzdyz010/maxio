# MinIO Admin User S2b (U1 Add + U2 List) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans to implement this plan task-by-task. Planning, implementation, review, and verification remain separate lanes per `AGENTS.md`.

**Goal:** Make `mc admin user add TARGET ACCESSKEY SECRETKEY` and `mc admin user list TARGET` interoperable with Maxio through MinIO Admin API v3, while reusing S2a U3 and leaving U4/U5 authenticated JSON 501.

**Architecture:** Keep `Maxio.Admin.Plug` as the route/authz/response boundary and `Maxio.Admin.UserAdapter` as a public-`Maxio.IAM`-only adapter. Add a request-scoped, redacted signing-secret capability because madmin encrypts U1 requests and U2 responses with the credential that signed the request. A dedicated `Maxio.Admin.Envelope` implements the pinned madmin-go envelope; `Maxio.Admin.UserRequest` performs bounded body reading, decrypting, and strict request projection. A new public IAM facade operation creates a new explicit user and its same-name long-term key atomically. This batch deliberately does not implement MinIO's update/re-enable interpretation of `/add-user`, because doing so would cross the identity-lock/versioned-invalidation boundary reserved for U4/U5.

**Tech Stack:** Elixir/Plug, Ecto/Postgres, `:crypto`, `argon2_elixir ~> 4.1`, Jason, ExUnit, SigV4 helpers, MinIO `mc` external smoke.

**Fixed base:** `d193301ba78b619a1a72740979ceab3392fcf5a1` (`d193301`). Every implementation/review diff is `d193301..HEAD`; do not chase a moving `origin/master`.

## Confirmed MinIO Contracts

The route/action/body/status facts and crypto selection below were independently researched; they are not `VERIFY-AT-IMPL` guesses. Task 1 backfills that separate lane's evidence pack before implementation, so neither planner nor implementer is accepted as its own proof.

- MinIO server `cmd/admin-router.go` registers PUT `/minio/admin/v3/add-user` with query `accessKey`, and GET `/minio/admin/v3/list-users`. `list-users?bucket=` is a distinct, earlier route and remains authenticated/authorized 501 here.
- U1 requires exact action `admin:CreateUser`. Its body is encrypted `madmin.AddOrUpdateUserReq`: JSON keys `secretKey,omitempty`, `policy,omitempty`, and required `status`; mc sends `status:"enabled"` and a non-empty `secretKey`. The handler does not require Content-Type. It maps semantic `ContentLength == -1` (missing/chunked) and values over exact `maxEConfigJSONSize = 262_272` to `XMinioAdminConfigTooLarge`; it decrypts with the request-signing secret, maps envelope/length/plaintext-JSON failures to `XMinioAdminConfigBadJSON`, and returns strict HTTP 200 with an empty body.
- U2 requires exact action `admin:ListUsers`. Its plaintext model is `map[string]madmin.UserInfo`, then the entire JSON is encrypted with the request-signing secret. It returns strict HTTP 200 and `application/json`; madmin decrypts before JSON decoding. Root is not included.
- U2 UserInfo uses the S2a wire shape: required `status`, optional `policyName`, `memberOf`, `updatedAt`, while `secretKey` and `userAuthInfo` are never emitted. This plan reuses `UserAdapter.project_fetched_user/1`; therefore direct managed-policy names, sorted membership, and exact ISO-8601 UTC timestamp retain the reviewed U3 semantics.
- The madmin-go v3.0.109 envelope is `salt(32) | algorithm_id(1) | nonce(8) | headerless sio-go ciphertext`. The target is secure-io/sio-go v0.3.1 with authenticated 16 KiB frames, **not** minio/sio DARE v2. IDs are 0 Argon2id/AES-256-GCM, 1 Argon2id/ChaCha20-Poly1305, and 2 PBKDF2-SHA256/AES-256-GCM. Argon2id is t=1, memory=64*1024 KiB, p=4, output=32 bytes; `argon2_elixir` uses `m_cost: 16` as the exponent for 64 MiB and returns `raw_hash` as hex that must be decoded. PBKDF2 cost is 8192. Production encryption may emit ID 0, but decryption must accept all three IDs and authenticate every frame.
- Fixed primary sources: madmin-go v3.0.109 `6897865311e2be91d814ea0ef4814a730d87d1cd`; MinIO observed master `7aac2a2c5b7c882e68c1ce017d8256be2feea27f` (its `go.mod` pins v3.0.109); mc observed master `77f82e18b5401a65958f1619df6ebb994634bd88` (madmin commit `4b504b82db63`, same envelope); secure-io/sio-go v0.3.1 `a455d2cd8fcacdfe18557d117db15c0629fb7e2c`. minio/sio v0.4.1 `3cd37344c5ae525ea0484b2906f32e0d2cb22783` is comparison evidence only and explicitly not the wire target.
- Evidence to backfill from the completed independent research: every headerless frame AAD/sequence/final-bit and nonce rule, BEAM AEAD mapping, verified `argon2_elixir` behavior, official secure-io vectors, and Go-to-Elixir plus Elixir-to-Go oracle cases at plaintext sizes 0, 1, 16,383, 16,384, 16,385, and 32,768. No crypto implementation starts before that evidence-only commit receives independent GO.

## Scope and Deliberate Deviations

- Implement only U1 add-new and U2 list. Preserve completed U3 unchanged except extracting a reusable list projection seam where tests require it.
- U4 DELETE `/remove-user` and U5 PUT `/set-user-status` remain authenticated JSON 501. U1/U2 `?bucket=` variants also remain authenticated and action-authorized JSON 501.
- U1 is **new-only** in S2b. If either the explicit IAM user name (case-insensitive) or requested access-key ID already exists, return structured 400 and change nothing. MinIO's add-or-update, re-enable, and deny-only self-password update are an explicitly documented stricter deviation. The next mutation batch must first design identity row locking plus versioned invalidation for every long-term and STS/session credential.
- U1 rejects non-empty `policy` instead of silently discarding it; policy attach/detach remains out of scope. Accept only `status:"enabled"` for new users; `disabled` creation belongs with U4 status architecture. Missing/unknown JSON fields, malformed envelope/JSON, empty secret, secret shorter than MinIO's 8-byte minimum, or invalid access key are 400.
- Access keys use the current Maxio explicit-user ceiling (64 bytes) and MinIO credential floor/reserved-character rules: 3..64 ASCII bytes, no comma, equals sign, slash, backslash, or leading/trailing whitespace. This is intentionally stricter than the existing generic IAM user schema and applies only at the MinIO admin adapter.
- No plaintext admin request/response fallback, no re-query of credential storage from Plug/UserAdapter, no external Go helper at runtime, no migration, no U4/U5 status/delete callback, and no user-ARN broadcast into the access-key invalidation slot.
- `argon2_elixir` is the only new dependency. It supplies the pinned Argon2id derivation; `:crypto` supplies PBKDF2 and AEAD. `Envelope` performs each Argon2 call synchronously in the already authenticated request process that owns `SigningSecret`; no secret enters an OTP message, process state, ETS/persistent storage, log, or inspected return value. Unlike madmin-go's internal mutex, S2b deliberately adds no BEAM-wide resource gate because that is not wire-visible functionality. Concurrent 64 MiB Argon2 admission control and control-plane DoS hardening are deferred; record that explicit risk in STATUS rather than claiming it is solved here.

## Exact Error Contract

| Reason / input | Wire code | HTTP | Exact message |
|---|---|---:|---|
| missing/ambiguous/non-ASCII/chunked semantic Content-Length, or encrypted length > 262,272 | `XMinioAdminConfigTooLarge` | 400 | `Configuration data provided exceeds the allowed maximum of 262272 bytes` |
| zero/short/mismatched length, unsupported/tampered/truncated envelope, wrong decrypting credential, malformed JSON, unknown JSON key, unsupported status, or non-empty policy | `XMinioAdminConfigBadJSON` | 400 | `JSON configuration provided is of incorrect format` |
| missing/empty or invalid `accessKey` | `XMinioAdminInvalidAccessKey` | 400 | `The access key is invalid.` |
| missing/empty or shorter-than-8-byte `secretKey` | `XMinioAdminInvalidSecretKey` | 400 | `The secret key is invalid.` |
| S2b new-only duplicate user or access-key collision | `XMaxioAdminUserAlreadyExists` | 400 | `The specified user already exists.` |
| authenticated payload hash is missing/non-concrete, or actual ciphertext SHA256 differs | `XAmzContentSHA256Mismatch` | 400 | `The provided 'x-amz-content-sha256' header does not match what was computed.` |

`XMaxioAdminUserAlreadyExists` is an intentional, stable Maxio deviation, not a claimed MinIO code. Authn/authz errors still occur before body processing through existing exact mappings. Every U1 input test must assert one row of this table; no generic `admin_invalid_argument`, `IncompleteBody`, crypto exception text, or Ecto changeset may cross the wire.

## Existing Capability Assessment

- Maxio does not hash SigV4 secrets: `Maxio.IAM.AccessKeySecret` stores a reversible, keyring-backed AES-GCM envelope because authentication must recover the original key. U1/U2 likewise need the original successful request credential; replacing it with a one-way password hash would break both SigV4 and madmin interoperability.
- `Maxio.Auth.CredentialStore.EctoStore` already unwraps long-term keys and STS/session keys before `Maxio.Auth.verify_signature/3`, but `verify_signature/3` currently retains only derived `k_signing`. Therefore the safe request-scoped wrapper is the smallest compatible handoff and avoids a second credential-store lookup.
- `Maxio.IAM.create_user/1` and `create_access_key/1` are separate Repo inserts and each broadcasts immediately. Calling them in sequence cannot provide U1 atomicity and can expose rolled-back/stale cache events. The new facade must build both changesets inside its own transaction and notify only after commit.
- There is no separate IAM write-store behaviour at this base: the established public mutation boundary is `Maxio.IAM`, which owns Repo/Ecto writes; `Maxio.Auth.CredentialStore` and `Maxio.Policy.Store` are read/runtime behaviours. S2b extends the real facade rather than inventing an adapter-to-Repo path or a fictitious callback.
- No existing dependency implements the madmin Argon2id + secure-io envelope. `:crypto` covers PBKDF2 and AEAD but not the pinned Argon2id KDF, so the independently reviewed `argon2_elixir` dependency is necessary. The admin encrypted body is bounded to 262,272 bytes and is therefore a valid limited control-plane buffer; S3 object bodies remain fully streaming.

## Security and Layer Boundaries

1. `Maxio.Auth.authenticate/1` may retain the successfully verified raw credential only as `%Maxio.Auth.SigningSecret{}` in `sigv4_context`. The struct has a custom redacted `Inspect`, no Jason encoder, and no public value accessor. Only `Maxio.Admin.Envelope` pattern-matches it in the authenticated caller process. The same context records `signed_payload_sha256: material.payload_hash`, the exact value used in the successful canonical request. Neither field is log metadata.
2. `Maxio.Admin.Envelope` owns madmin compatibility only. It pattern-matches `SigningSecret` and performs Argon2/PBKDF2 derivation synchronously in the current authenticated request process, without spawning, messaging, registering, or persisting the secret. It returns `{:ok, binary}` or a small error atom, authenticates every SIO frame before releasing plaintext, uses `:crypto.strong_rand_bytes/1` in production, and exposes deterministic salt/nonce/algorithm options only under `@doc false` for official vectors.
3. `Maxio.Admin.UserRequest` reuses the bounded `Maxio.S3.ControlBody` mechanism but maps this endpoint's errors exactly. It accepts one ASCII decimal `Content-Length` from 0 through 262,272 and requires no Content-Type. Missing/ambiguous/chunked (`-1` semantics) and 262,273+ map to `XMinioAdminConfigTooLarge`; zero, declared/read mismatch, truncated/tampered envelope, decrypt failure, and JSON failure map to `XMinioAdminConfigBadJSON`. New opt-in `ControlBody.read!/4` options receive the expected length/error and `sigv4_context.signed_payload_sha256`: after bounded read, the shared contract first rejects declared/read mismatch, then computes actual ciphertext SHA256 and compares it to the concrete authenticated value, all before returning body. Hash failure uses existing `XAmzContentSHA256Mismatch`; no Admin Plug-local hashing helper is allowed. It never logs body, ciphertext, decrypted JSON, or either secret.
4. `Maxio.Admin.UserAdapter` calls only public `Maxio.IAM` functions. U1 passes validated values to the new atomic facade. U2 begins with `Maxio.IAM.list_users/0` and projects each returned public user through the existing public-facade projection. Plug never aliases Repo/Ecto/Policy Store/CredentialStore.
5. `Maxio.IAM.create_minio_user_strict/3` owns one `Ecto.Multi` transaction. It takes an exact access key, plaintext new-user secret, and active status; acquires the existing principal/access-key advisory locks in stable order, rejects an existing case-insensitive user, inserts the explicit user, then inserts the same-name access-key envelope. The access-key unique constraint is the authoritative exact-key collision check, so a pre-existing key deterministically fails the second operation and proves the first insert rolls back. It returns public metadata without the secret. After commit, it broadcasts only `{:iam_changed, access_key_id}`. It must not call the existing public `create_user/1` or `create_access_key/1` inside the transaction because those broadcast before commit.

## File and Interface Map

### Create

- `lib/maxio/auth/signing_secret.ex` — redacted request-scoped capability.
- `lib/maxio/admin/envelope.ex` — madmin envelope/SIO implementation.
- `lib/maxio/admin/user_request.ex` — bounded U1 body and request parser.
- `lib/mix/tasks/maxio.admin.user.list.ex` — safe local U2 projection evidence.
- `lib/mix/tasks/maxio.admin.user.add.ex` — safe atomic U1 evidence; secret only via named environment variable.
- `test/fixtures/minio_admin_envelope/v3_0_109_vectors.json`, `sio_v0_3_1_vectors.json`, and `README.md` — pinned Go bidirectional and official secure-io interoperability evidence.
- `test/maxio/admin/envelope_test.exs`
- `test/maxio/admin/user_request_test.exs`
- `test/maxio/iam/minio_admin_user_test.exs`

### Modify

- `mix.exs`, `mix.lock` — add `argon2_elixir ~> 4.1`.
- `lib/maxio/auth.ex`, `lib/maxio/s3/plugs/sigv4.ex` — carry only the redacted signing-secret capability after successful verification.
- `lib/maxio/s3/control_body.ex` — opt-in verification of the concrete payload SHA256 authenticated by SigV4.
- `lib/maxio/iam.ex` — add the atomic public facade and post-commit access-key notification.
- `lib/maxio/admin/user_adapter.ex` — `add/2`, `list/0`, and reusable list projection over public IAM only.
- `lib/maxio/admin/plug.ex` — exact U1/U2 routing, actions, encrypted response, empty success.
- `lib/maxio/admin/error_map.ex`, `lib/maxio/s3/error.ex` — confirmed admin config/access-key/secret/conflict errors.
- `config/config.exs` — safe U1/U2 structured-log metadata allowlist only.
- `test/maxio/auth_test.exs`, `test/maxio/s3/plugs/sigv4_test.exs`, `test/maxio/s3/control_body_test.exs`
- `test/maxio/admin/user_adapter_test.exs`, `test/maxio/admin/user_endpoint_test.exs`, `test/maxio/admin/error_map_test.exs`
- `lib/maxio/compat/external_smoke.ex`
- `test/maxio/compat/external_smoke_test.exs`
- `test/mix/tasks/maxio_admin_user_test.exs`
- `README.md`; `docs/superpowers/STATUS.md` only at the final evidence checkpoint.

### New Production Interfaces

```elixir
Maxio.Admin.Envelope.decrypt(Maxio.Auth.SigningSecret.t(), binary()) ::
  {:ok, binary()} | {:error, :unexpected_header | :unsupported_algorithm | :not_authentic}

Maxio.Admin.Envelope.encrypt(Maxio.Auth.SigningSecret.t(), iodata()) ::
  {:ok, binary()} | {:error, term()}

Maxio.Admin.UserRequest.read_add_body!(Plug.Conn.t(), Maxio.Auth.SigningSecret.t()) ::
  {Plug.Conn.t(), %{secret_key: binary(), policy: binary(), status: "enabled"}}

Maxio.Admin.UserAdapter.add(term(), map()) ::
  {:ok, map()} | {:error, term()}

Maxio.Admin.UserAdapter.list() ::
  {:ok, %{wire: %{binary() => map()}, evidence: map()}} | {:error, term()}

Maxio.IAM.create_minio_user_strict(binary(), binary(), "active") ::
  {:ok, %{user: map(), access_key: map()}} | {:error, term()}
```

`create_minio_user_strict/3` is new by design; all other calls used by the adapter (`list_users/0`, `project_fetched_user/1`) exist at the fixed base. Never invent a Store callback: the current IAM persistence architecture is the `Maxio.IAM` facade over `Maxio.Repo`, while credential reads remain behind `Maxio.Auth.CredentialStore`.

---

### Task 1: Commit the Plan First and Obtain Independent Spec GO

**Files:** first create/commit only `docs/superpowers/plans/2026-08-28-minio-admin-user-s2b.md`; only after that commit, backfill the completed independent research lane's `test/fixtures/minio_admin_envelope/v3_0_109_vectors.json`, `sio_v0_3_1_vectors.json`, and `README.md`.

- [ ] **Step 1: Enforce the plan-only starting boundary**

```powershell
$expectedBase='d193301ba78b619a1a72740979ceab3392fcf5a1'
$head=git rev-parse HEAD
if ($LASTEXITCODE -ne 0) { throw 'git rev-parse HEAD failed' }
if ($head -ne $expectedBase) { throw 'unexpected starting HEAD' }
$branchPoint=git merge-base HEAD origin/master
if ($LASTEXITCODE -ne 0) { throw 'git merge-base failed' }
if ($branchPoint -ne $expectedBase) { throw 'unexpected branch point' }
$dirty=@(git status --porcelain=v1)
if ($LASTEXITCODE -ne 0) { throw 'git status failed' }
$expected='?? docs/superpowers/plans/2026-08-28-minio-admin-user-s2b.md'
if ($dirty.Count -ne 1 -or $dirty[0] -ne $expected) {
  throw "only the untracked S2b plan is allowed; actual: $($dirty -join '; ')"
}
```

Expected: exactly the untracked plan. Any other dirty path is a hard stop.

- [ ] **Step 2: Commit the plan as the first branch commit**

```powershell
git add docs/superpowers/plans/2026-08-28-minio-admin-user-s2b.md
if ($LASTEXITCODE -ne 0) { throw 'git add plan failed' }
git commit -m "docs(plan): scope admin user S2b add and list"
if ($LASTEXITCODE -ne 0) { throw 'plan commit failed' }
$parent=git rev-parse HEAD^
if ($LASTEXITCODE -ne 0) { throw 'git rev-parse HEAD^ failed' }
if ($parent -ne 'd193301ba78b619a1a72740979ceab3392fcf5a1') { throw 'plan is not first after fixed base' }
git diff --check d193301..HEAD
if ($LASTEXITCODE -ne 0) { throw 'plan diff check failed' }
$dirty=@(git status --porcelain)
if ($LASTEXITCODE -ne 0) { throw 'git status failed' }
if ($dirty.Count -ne 0) { throw 'plan commit left a dirty tree' }
```

- [ ] **Step 3: Independent protocol research lane backfills the crypto evidence pack**

The completed research lane is separate from both planner and future implementer. Backfill its exact commits listed in Confirmed Contracts, module sums, official secure-io vectors, Go bidirectional envelope oracles, precise SIO AAD/sequence/final-frame/nonce rules, and BEAM primitive mapping. The worktree must contain evidence data/docs only at this point—no Elixir production implementation. Any disagreement with the summary above updates this plan before implementation.

- [ ] **Step 4: Commit the independently produced evidence unchanged**

```powershell
$dirty=@(git status --porcelain=v1)
if ($LASTEXITCODE -ne 0) { throw 'git status failed' }
if ($dirty | Where-Object { $_ -notmatch '^\?\? test/fixtures/minio_admin_envelope/' }) {
  throw "research handoff contains non-evidence files: $($dirty -join '; ')"
}
git add test/fixtures/minio_admin_envelope
if ($LASTEXITCODE -ne 0) { throw 'git add research evidence failed' }
git commit -m "test(admin): pin madmin envelope evidence"
if ($LASTEXITCODE -ne 0) { throw 'research evidence commit failed' }
git diff --check d193301..HEAD
if ($LASTEXITCODE -ne 0) { throw 'research evidence diff check failed' }
$dirty=@(git status --porcelain)
if ($LASTEXITCODE -ne 0) { throw 'git status failed' }
if ($dirty.Count -ne 0) { throw 'research evidence commit left a dirty tree' }
```

Expected: an evidence-only second commit. The implementation author must not amend it to fit later code.

- [ ] **Step 5: Independent spec/crypto reviewer gives GO/NO-GO**

The reviewer reads the full admin-user spec, the pinned upstream files, and the independent research evidence pack. GO requires exact U1/U2 wire/action/status/envelope facts, explicit new-only deviation, a request-secret lifecycle threat review, all three decrypt IDs plus multi-frame cross-language vectors, atomic rollback, and U4/U5 remaining 501. Review `git diff d193301..HEAD`; a NO-GO returns to the planning/research lane for an evidence/docs-only fix and clean-tree re-review before implementation. The researcher may not be the implementation author or this reviewer.

---

### Task 2: Prove the madmin Envelope and Safe Signing-Secret Handoff

**Files:** create `lib/maxio/auth/signing_secret.ex`, `lib/maxio/admin/envelope.ex`, and `test/maxio/admin/envelope_test.exs`; read the committed vector evidence; modify `mix.exs`, `mix.lock`, `lib/maxio/auth.ex`, `lib/maxio/s3/plugs/sigv4.ex`, `test/maxio/auth_test.exs`, `test/maxio/s3/plugs/sigv4_test.exs`.

- [ ] **Step 1: Add pinned official vectors and RED tests before production code**

Consume the independently produced evidence data; the implementer does not regenerate or silently amend it. Cover IDs 0/1/2, wrong password, bit flip/truncation, official headerless secure-io cases, and Go-to-Elixir plus Elixir-to-Go cases at 0, 1, 16,383, 16,384, 16,385, and 32,768 plaintext bytes. RED tests assert byte-exact deterministic encrypt, decrypt of every vector, and no unauthenticated frame release.

Single-request mutation-sensitive tests use a sentinel signing secret across the official Argon2/PBKDF2 vectors and assert it never appears in captured Logger output, returned error terms, inspected `Envelope` results, `Application` environment, `:persistent_term`, ETS tables created by this feature, or the request process mailbox after the call. The derivation must run in the invoking `Envelope` process; a mutation that spawns a worker, sends the binary or `%SigningSecret{}` in any OTP message, stores it in process/OTP state, or includes it in an exception must fail. These are single-request secrecy/lifetime checks only; resource-governance tests are outside S2b.

Also assert `%SigningSecret{}` inspection is exactly redacted, Jason encoding fails, `sigv4_context` contains the wrapper only after a correct signature, wrong signatures return no wrapper, header and STS/session credentials retain their own correct secret, and neither auth logs nor inspected conn/context contain plaintext.

- [ ] **Step 2: Run RED**

```powershell
Remove-Item Env:PGPORT -ErrorAction SilentlyContinue
$env:ERL_FLAGS='-kernel standard_io_encoding unicode'
$env:ELIXIR_ERL_OPTIONS='+S 2:2 +A0 +sbwt none +sbwtdcpu none +sbwtdio none'
mix test test/maxio/admin/envelope_test.exs test/maxio/auth_test.exs test/maxio/s3/plugs/sigv4_test.exs --max-failures 1
if ($LASTEXITCODE -eq 0) { throw 'expected envelope/auth RED but tests passed' }
```

Expected RED: envelope and signing-secret modules/capability are absent.

- [ ] **Step 3: Implement the minimum interoperable boundary**

Add `{:argon2_elixir, "~> 4.1"}`. In `Envelope`, pattern-match `%SigningSecret{}` only inside the authenticated caller and synchronously decode `Argon2.Base.hash_password(..., format: :raw_hash, argon2_type: 2, t_cost: 1, m_cost: 16, parallelism: 4, hashlen: 32)` from hex to 32 bytes. PBKDF2 uses `:crypto.pbkdf2_hmac(:sha256, password, salt, 8192, 32)` in the same process. Do not introduce any OTP process, lock, scheduler, or cross-process handoff for derivation. This differs from madmin-go's internal Argon2 mutex but is intentionally non-wire-visible; 64 MiB-per-call concurrency admission/DoS protection is deferred hardening and must be documented as a STATUS risk.

Implement pinned headerless v0.3.1 SIO frames, authenticating a complete frame before releasing it. Production `encrypt/2` emits ID 0/AES only and random 32-byte salt/8-byte nonce; deterministic options are `@doc false` and unavailable through Plug.

Wrap the already looked-up secret inside `verify_signature/3` only after constant-time signature success. Keep existing `k_signing`, scope, and seed fields intact, and add `signed_payload_sha256: material.payload_hash`. SigV4 assigns the wrapper/hash only in the existing context; neither becomes a top-level conn assign or log metadata.

- [ ] **Step 4: Run GREEN, compile, and secret scans**

```powershell
Remove-Item Env:PGPORT -ErrorAction SilentlyContinue
$env:ERL_FLAGS='-kernel standard_io_encoding unicode'
$env:ELIXIR_ERL_OPTIONS='+S 2:2 +A0 +sbwt none +sbwtdcpu none +sbwtdio none'
mix deps.get
if ($LASTEXITCODE -ne 0) { throw 'mix deps.get failed' }
mix test test/maxio/admin/envelope_test.exs test/maxio/auth_test.exs test/maxio/s3/plugs/sigv4_test.exs
if ($LASTEXITCODE -ne 0) { throw 'envelope/auth focused tests failed' }
mix compile --warnings-as-errors
if ($LASTEXITCODE -ne 0) { throw 'warnings-as-errors compile failed' }
$unsafeSecretRefs=@(rg -n "(caller_secret|SigningSecret|secret_key).*(Log\.|Logger\.|metadata|Jason\.encode)|(Log\.|Logger\.|metadata|Jason\.encode).*(caller_secret|SigningSecret|secret_key)" lib/maxio)
if ($LASTEXITCODE -gt 1) { throw 'secret-path rg scan failed' }
if ($unsafeSecretRefs.Count -ne 0) { throw "secret-bearing log/JSON path found: $($unsafeSecretRefs -join '; ')" }
```

Expected: tests/compile pass; scan has no secret-bearing log/JSON path.

- [ ] **Step 5: Commit and require a clean tree**

```powershell
git add mix.exs mix.lock lib/maxio/auth/signing_secret.ex lib/maxio/admin/envelope.ex lib/maxio/auth.ex lib/maxio/s3/plugs/sigv4.ex test/maxio/admin/envelope_test.exs test/maxio/auth_test.exs test/maxio/s3/plugs/sigv4_test.exs
if ($LASTEXITCODE -ne 0) { throw 'git add envelope slice failed' }
git commit -m "feat(admin): add madmin envelope boundary"
if ($LASTEXITCODE -ne 0) { throw 'envelope slice commit failed' }
git diff --check d193301..HEAD
if ($LASTEXITCODE -ne 0) { throw 'envelope slice diff check failed' }
$dirty=@(git status --porcelain)
if ($LASTEXITCODE -ne 0) { throw 'git status failed' }
if ($dirty.Count -ne 0) { throw 'envelope slice left a dirty tree' }
```

---

### Task 3: Add Atomic New-Only IAM Creation and U1/U2 Adapter Projection

**Files:** modify `lib/maxio/iam.ex`, `lib/maxio/admin/user_adapter.ex`, `lib/maxio/admin/error_map.ex`, `lib/maxio/s3/error.ex`, `test/maxio/admin/user_adapter_test.exs`, `test/maxio/admin/error_map_test.exs`; create `test/maxio/iam/minio_admin_user_test.exs`.

- [ ] **Step 1: Write IAM transaction RED tests**

Assert one call creates one active explicit user and one active same-name long-term key whose stored value is an `AccessKeySecret` envelope and authenticates with the supplied secret. The return value and inspection contain no secret. Pre-create only the requested access-key row for another valid principal, call the new facade, assert the second `Ecto.Multi` insert reports conflict, and prove the just-attempted explicit user was rolled back while the old key is unchanged. Run two concurrent calls for the same name behind a deterministic barrier: exactly one succeeds, one returns conflict, and exactly one user/key pair exists. Case-only duplicate users also change nothing. Subscribe a recording test process to the existing `Maxio.Cluster.Notify.topic/0`; assert exactly one post-commit `{:iam_changed, access_key_id}` on success, none on rollback/conflict, and fail if a user ARN is sent to the access-key slot.

- [ ] **Step 2: Write adapter/error RED tests**

For `add/2`, cover access-key validation boundaries, secret byte lengths 7/8, enabled only, non-empty policy, duplicate mapping, and no secret in reason/log/result. For `list/0`, create active/inactive users, a root key without explicit user, a user without a key, and S2a policy/group fixtures. Assert exact `%{name => UserInfo}` map, stable S2a projection, root omission, empty `{}`, exact UTC/nil omission, and absence of `secretKey`, `userAuthInfo`, `credential_bearing`, policy documents, key IDs, and session data. Preserve direct-only `policyName` semantics.

Add and assert every exact code/status/message row in the Error Contract table. Map the new-only conflict only to `XMaxioAdminUserAlreadyExists`; tests must fail mutations to MinIO's no-such-user, generic invalid argument, Ecto text, or a 409. Keep `:user_not_found` and policy errors unchanged.

- [ ] **Step 3: Run RED**

```powershell
Remove-Item Env:PGPORT -ErrorAction SilentlyContinue
$env:ERL_FLAGS='-kernel standard_io_encoding unicode'
$env:ELIXIR_ERL_OPTIONS='+S 2:2 +A0 +sbwt none +sbwtdcpu none +sbwtdio none'
mix test test/maxio/iam/minio_admin_user_test.exs test/maxio/admin/user_adapter_test.exs test/maxio/admin/error_map_test.exs --max-failures 1
if ($LASTEXITCODE -eq 0) { throw 'expected IAM/adapter/error RED but tests passed' }
```

Expected RED: strict atomic facade, add/list adapter entry points, and new error mappings do not exist.

- [ ] **Step 4: Implement facade then adapter**

Build one `Ecto.Multi`, take stable advisory locks for case-folded user namespace and exact access key, re-check the user identity, insert `%User{}`, then insert `%AccessKey{}` with the existing exact-key unique constraint, and wrap the supplied secret with existing `AccessKeySecret.wrap/2`. Any later changeset/storage error rolls back earlier operations. Normalize both user and access-key unique races to one public conflict reason. Notify only after `Repo.transaction/1` returns `{:ok, result}`. Do not change generic `create_user/1`, `create_access_key/1`, schema, migration, CacheInvalidator, or STS/session code.

Implement adapter validation/projection with public IAM calls only. `list/0` may call `project_fetched_user/1` per explicit user; surface any projection failure instead of silently omitting that user. Evidence contains counts/names only and logs a partial-view warning using the existing S2a vocabulary.

- [ ] **Step 5: Run GREEN, compile, and boundary scans**

```powershell
Remove-Item Env:PGPORT -ErrorAction SilentlyContinue
$env:ERL_FLAGS='-kernel standard_io_encoding unicode'
$env:ELIXIR_ERL_OPTIONS='+S 2:2 +A0 +sbwt none +sbwtdcpu none +sbwtdio none'
mix test test/maxio/iam/minio_admin_user_test.exs test/maxio/admin/user_adapter_test.exs test/maxio/admin/error_map_test.exs
if ($LASTEXITCODE -ne 0) { throw 'IAM/adapter/error focused tests failed' }
mix compile --warnings-as-errors
if ($LASTEXITCODE -ne 0) { throw 'warnings-as-errors compile failed' }
$adapterLeaks=@(rg -n "Maxio\.(Repo|Policy\.Store|Auth\.CredentialStore|Cluster)|Ecto\." lib/maxio/admin/user_adapter.ex)
if ($LASTEXITCODE -gt 1) { throw 'adapter boundary rg scan failed' }
if ($adapterLeaks.Count -ne 0) { throw "adapter boundary violation: $($adapterLeaks -join '; ')" }
```

Expected: tests/compile pass; adapter dependency scan has zero matches.

- [ ] **Step 6: Commit and clean gate**

```powershell
git add lib/maxio/iam.ex lib/maxio/admin/user_adapter.ex lib/maxio/admin/error_map.ex lib/maxio/s3/error.ex test/maxio/iam/minio_admin_user_test.exs test/maxio/admin/user_adapter_test.exs test/maxio/admin/error_map_test.exs
if ($LASTEXITCODE -ne 0) { throw 'git add IAM/adapter slice failed' }
git commit -m "feat(admin): add atomic user creation and list projection"
if ($LASTEXITCODE -ne 0) { throw 'IAM/adapter slice commit failed' }
git diff --check d193301..HEAD
if ($LASTEXITCODE -ne 0) { throw 'IAM/adapter slice diff check failed' }
$dirty=@(git status --porcelain)
if ($LASTEXITCODE -ne 0) { throw 'git status failed' }
if ($dirty.Count -ne 0) { throw 'IAM/adapter slice left a dirty tree' }
```

---

### Task 4: Route, Authorize, Bound, Decrypt, and Encrypt U1/U2

**Files:** create `lib/maxio/admin/user_request.ex`, `test/maxio/admin/user_request_test.exs`; modify `lib/maxio/s3/control_body.ex`, `test/maxio/s3/control_body_test.exs`, `lib/maxio/admin/plug.ex`, `config/config.exs`, `test/maxio/admin/user_endpoint_test.exs`.

- [ ] **Step 1: Write request parser RED tests**

Cover every input branch in the Error Contract table. Exact Content-Length 1 and 262,272 reach hash/decrypt; 262,273, absent, duplicated, `-1`, and transfer-encoding/chunked return exact ConfigTooLarge. Zero and declared/read mismatch return exact ConfigBadJSON. Reject `+1`, Unicode digits, and surrounding whitespace without reading or mutating. A valid encrypted request succeeds with no Content-Type and with arbitrary Content-Type. Wrong secret, unknown ID, truncated/tampered SIO, malformed/unknown-key JSON, missing secret, unsupported status, and non-empty policy assert their exact table row. Assert body/ciphertext/plaintext/new secret never appears in exception inspection or captured logs.

Extend `ControlBody.read!/4` with opt-in `expected_length`, `length_mismatch_error`, and `verify_payload_sha256: expected_hex`; existing callers remain unchanged. After bounded read it checks length first, then exact lowercase 64-hex ciphertext hash, and only then returns body. Unit RED covers match, mismatch, malformed/non-concrete expected values, length-before-hash ordering, and no body return on failure. Endpoint RED uses existing `Maxio.Test.SigV4Request` `content_sha256_override` to sign the hash of different ciphertext while sending a valid encrypted U1 body. Authentication succeeds, then U1 returns exact `XAmzContentSHA256Mismatch`, never calls `Envelope.decrypt`, and creates no user/key. Mutation tests fail if comparison uses plaintext, occurs after decrypt, uses only the raw header instead of authenticated context, or masks declared/read mismatch with a hash error.

- [ ] **Step 2: Write signed endpoint RED tests**

Use existing SigV4 helpers and real envelope code. Assert:

- PUT `/minio/admin/v3/add-user?accessKey=N` requires `admin:CreateUser`, returns exact 200 empty body, creates the same IAM-visible user/key atomically, and the new credential performs a signed S3 request;
- GET `/minio/admin/v3/list-users` requires `admin:ListUsers`, returns exact 200 `application/json`, body is not plaintext JSON, decrypts with the signing credential, and decodes to the exact map; wrong secret cannot decrypt;
- root shortcut, identity allow, explicit deny, STS session-policy boundary, and bucket-policy non-grant are covered for both exact actions;
- `GET /list-users?bucket=x` authorizes `admin:ListUsers` then returns 501; U4/U5 still authenticate then return JSON 501; wrong method/path remains 501;
- malformed U1 or signed-payload hash mismatch is rejected before decrypt/IAM mutation, duplicate add leaves the old credential usable and unchanged, U3 still returns plaintext 200, and no admin route is recorded as bucket `minio` in metrics/access logs;
- response/log/error redaction scans cannot find caller secret, new-user secret, plaintext U1 JSON, or secret ciphertext snippets.

- [ ] **Step 3: Run RED**

```powershell
Remove-Item Env:PGPORT -ErrorAction SilentlyContinue
$env:ERL_FLAGS='-kernel standard_io_encoding unicode'
$env:ELIXIR_ERL_OPTIONS='+S 2:2 +A0 +sbwt none +sbwtdcpu none +sbwtdio none'
mix test test/maxio/s3/control_body_test.exs test/maxio/admin/user_request_test.exs test/maxio/admin/user_endpoint_test.exs --max-failures 1
if ($LASTEXITCODE -eq 0) { throw 'expected control-body/U1/U2 RED but tests passed' }
```

Expected RED: U1/U2 still resolve through generic 501 and the request module is absent.

- [ ] **Step 4: Implement the thin endpoint boundary**

Add exact dispatch clauses before fallback. U1 calls `authorize_and_run`, then `UserRequest.read_add_body!`; that module supplies declared length/error plus `conn.assigns.sigv4_context.signed_payload_sha256` to the unified ControlBody options, and only after verified return calls Envelope and `UserAdapter.add`. Plug does not hash. U2 authorizes, obtains adapter wire/evidence, Jason-encodes once, encrypts with `conn.assigns.sigv4_context.caller_secret`, logs safe counts, and sends encrypted bytes with JSON content type. A missing signing-secret/hash capability is a redacted 500, never a plaintext or unverified fallback. The bucket variant branches only after authorization and does not call `UserAdapter.list/0`.

- [ ] **Step 5: Run GREEN plus existing S1/S2a regression**

```powershell
Remove-Item Env:PGPORT -ErrorAction SilentlyContinue
$env:ERL_FLAGS='-kernel standard_io_encoding unicode'
$env:ELIXIR_ERL_OPTIONS='+S 2:2 +A0 +sbwt none +sbwtdcpu none +sbwtdio none'
mix test test/maxio/s3/control_body_test.exs test/maxio/admin/user_request_test.exs test/maxio/admin/user_endpoint_test.exs test/maxio/admin/user_adapter_test.exs test/maxio/admin/authz_test.exs test/maxio/admin/policy_endpoint_test.exs
if ($LASTEXITCODE -ne 0) { throw 'control-body/admin endpoint regression tests failed' }
mix compile --warnings-as-errors
if ($LASTEXITCODE -ne 0) { throw 'warnings-as-errors compile failed' }
```

- [ ] **Step 6: Commit and clean gate**

```powershell
git add lib/maxio/s3/control_body.ex test/maxio/s3/control_body_test.exs lib/maxio/admin/user_request.ex lib/maxio/admin/plug.ex config/config.exs test/maxio/admin/user_request_test.exs test/maxio/admin/user_endpoint_test.exs
if ($LASTEXITCODE -ne 0) { throw 'git add endpoint slice failed' }
git commit -m "feat(admin): serve encrypted user add and list"
if ($LASTEXITCODE -ne 0) { throw 'endpoint slice commit failed' }
git diff --check d193301..HEAD
if ($LASTEXITCODE -ne 0) { throw 'endpoint slice diff check failed' }
$dirty=@(git status --porcelain)
if ($LASTEXITCODE -ne 0) { throw 'git status failed' }
if ($dirty.Count -ne 0) { throw 'endpoint slice left a dirty tree' }
```

---

### Task 5: Add Safe CLI Evidence, Repeatable mc Read Smoke, Logs, and Docs

**Files:** create `lib/mix/tasks/maxio.admin.user.list.ex`, `lib/mix/tasks/maxio.admin.user.add.ex`; read/reuse `lib/maxio/compat/admin_user_fixture.ex`; modify `test/mix/tasks/maxio_admin_user_test.exs`, `lib/maxio/compat/external_smoke.ex`, `test/maxio/compat/external_smoke_test.exs`, `README.md`. Do not modify STATUS yet.

- [ ] **Step 1: Write CLI/smoke RED tests**

`mix maxio.admin.user.list [--json]` must call the same adapter and show exact status/direct policy/partial evidence without keys or secrets. `mix maxio.admin.user.add NAME --secret-env ENV_NAME` must reject literal secret arguments, read only the named environment variable, call the atomic facade, and never echo its value; tests restore the environment in `on_exit`.

Reuse the already reviewed `AdminUserFixture.with_user/2`: it safely creates an active user through public IAM, enters its existing callback/cleanup aggregation, and does not require U1/U4/U5. External smoke runs only real `mc admin user list` followed by existing `mc admin user info`; both must contain the exact fixture name and `enabled`, and cleanup remains the existing public-IAM path. There is **no automated `mc admin user add` command**, no positional new-user secret, and no U1 live-pass claim. U1 interoperability evidence is the pinned bidirectional Go vectors plus the real signed HTTP endpoint test with hash verification and IAM cleanup.

Add mutation-sensitive tests that enumerate captured command argv and fail on any `admin user add`, then cover prerequisites absent, list/info command failures, U2 decrypt/list assertion failure, success+cleanup-fail, primary-fail+cleanup-fail, and repeatability. Reuse the existing cleanup result aggregation so the primary result is retained and cleanup blocker appended, never replaced by generic rescue.

- [ ] **Step 2: Run RED**

```powershell
Remove-Item Env:PGPORT -ErrorAction SilentlyContinue
$env:ERL_FLAGS='-kernel standard_io_encoding unicode'
$env:ELIXIR_ERL_OPTIONS='+S 2:2 +A0 +sbwt none +sbwtdcpu none +sbwtdio none'
mix test test/mix/tasks/maxio_admin_user_test.exs test/maxio/compat/admin_user_fixture_test.exs test/maxio/compat/external_smoke_test.exs --max-failures 1
if ($LASTEXITCODE -eq 0) { throw 'expected CLI/smoke RED but tests passed' }
```

- [ ] **Step 3: Implement minimum evidence surfaces and docs**

Use stable structured fields `admin_action`, `required_action`, `target_user`, `user_count`, `enabled_count`, `disabled_count`, `minio_view_partial`, `request_id`, and `surface`; never secret/key material. README records U1 new-only and enabled-only deviations, encrypted U1/U2, U3 plaintext, root omission, public-IAM single source of truth, safe local CLI usage, and U4/U5 plus list bucket variant as 501. It explicitly records that upstream `mc admin user add TARGET ACCESSKEY SECRETKEY` necessarily places the secret in process argv; automated smoke therefore does not execute it. An operator may manually opt in outside recorded automation after accepting argv/process-list exposure, but such a run is not batch live evidence and must not be captured in artifacts/logs.

- [ ] **Step 4: Run GREEN and commit**

```powershell
Remove-Item Env:PGPORT -ErrorAction SilentlyContinue
$env:ERL_FLAGS='-kernel standard_io_encoding unicode'
$env:ELIXIR_ERL_OPTIONS='+S 2:2 +A0 +sbwt none +sbwtdcpu none +sbwtdio none'
mix test test/mix/tasks/maxio_admin_user_test.exs test/maxio/compat/admin_user_fixture_test.exs test/maxio/compat/external_smoke_test.exs
if ($LASTEXITCODE -ne 0) { throw 'CLI/smoke focused tests failed' }
mix compile --warnings-as-errors
if ($LASTEXITCODE -ne 0) { throw 'warnings-as-errors compile failed' }
```

```powershell
git add lib/mix/tasks/maxio.admin.user.list.ex lib/mix/tasks/maxio.admin.user.add.ex test/mix/tasks/maxio_admin_user_test.exs lib/maxio/compat/external_smoke.ex test/maxio/compat/external_smoke_test.exs README.md
if ($LASTEXITCODE -ne 0) { throw 'git add CLI/smoke/docs slice failed' }
git commit -m "feat(admin): add user CLI and mc read evidence"
if ($LASTEXITCODE -ne 0) { throw 'CLI/smoke/docs slice commit failed' }
git diff --check d193301..HEAD
if ($LASTEXITCODE -ne 0) { throw 'CLI/smoke/docs diff check failed' }
$dirty=@(git status --porcelain)
if ($LASTEXITCODE -ne 0) { throw 'git status failed' }
if ($dirty.Count -ne 0) { throw 'CLI/smoke/docs slice left a dirty tree' }
```

---

### Task 6: Independent Code Review and Author-Owned Finding Fixes

**Files:** review all `git diff d193301..HEAD`; accepted fixes touch only their owning files/tests.

**Required review acceptance with actual `path:line` evidence:** The review report must cite the final line number produced from the reviewed commit for every item below; function names without a line number are not sufficient.

1. `lib/maxio/admin/envelope.ex` caller-local Argon2/PBKDF2 derivation. Cite single-request official-vector and secrecy tests whose mutations spawn or message a worker, put the raw secret or `%SigningSecret{}` in OTP/process state, ETS/persistent storage, mailbox, Inspect/error output, or logs. Cite the STATUS line that records madmin's internal-mutex difference and deferred 64 MiB concurrency/DoS hardening; the reviewer rejects any resource-governance implementation/test in S2b.
2. `lib/maxio/s3/error.ex` and `lib/maxio/admin/error_map.ex` entries for all Error Contract rows. Cite exact tuple assertions and the duplicate-code mutation test proving the Maxio deviation stays `XMaxioAdminUserAlreadyExists`/400 with fixed message.
3. `lib/maxio/s3/control_body.ex` opt-in hash verification and `lib/maxio/admin/user_request.ex` call site before Envelope/IAM. Cite the `content_sha256_override` endpoint RED proving authentication succeeds but ciphertext mismatch yields zero decrypt/mutation.
4. `lib/maxio/compat/external_smoke.ex` final scenario command construction. Cite the mutation test that fails if any captured argv contains `admin user add`, plus README lines that describe manual opt-in as non-evidence.
5. Every PowerShell block in this plan. Cite the static parse/fail-fast scan result proving each `mix`, `git`, and `rg` native command is immediately followed by an explicit `$LASTEXITCODE` decision, including expected-nonzero RED and expected-no-match scans.

- [ ] **Step 1: Clean-tree handoff to independent reviewers**

```powershell
$dirty=@(git status --porcelain)
if ($LASTEXITCODE -ne 0) { throw 'git status failed' }
if ($dirty.Count -ne 0) { throw 'review requires a clean tree' }
git log --oneline --decorate d193301..HEAD
if ($LASTEXITCODE -ne 0) { throw 'review git log failed' }
git diff --check d193301..HEAD
if ($LASTEXITCODE -ne 0) { throw 'review diff check failed' }
git diff --stat d193301..HEAD
if ($LASTEXITCODE -ne 0) { throw 'review diff stat failed' }
```

Use two independent review responsibilities: protocol/crypto review (madmin-go and sio vectors, secret lifetime, authenticated decryption, size boundary) and code/architecture review (Plug thinness, public-IAM-only adapter, transaction rollback/locks, notification timing, U4/U5 boundary, error/status exactness). Critical/Important findings are blocking.

- [ ] **Step 2: Every accepted finding gets author RED -> fix -> focused GREEN -> separate commit**

The implementation author writes a mutation-sensitive failing test demonstrating each accepted finding before changing production code, runs only that focused RED, applies the smallest architectural fix, reruns focused GREEN, and commits it separately. Do not squash away evidence and do not let the reviewer author the fix.

- [ ] **Step 3: Clean-tree re-review of the fixed range**

```powershell
$dirty=@(git status --porcelain)
if ($LASTEXITCODE -ne 0) { throw 'git status failed' }
if ($dirty.Count -ne 0) { throw 're-review requires a clean tree' }
git diff --check d193301..HEAD
if ($LASTEXITCODE -ne 0) { throw 're-review diff check failed' }
git log --oneline d193301..HEAD
if ($LASTEXITCODE -ne 0) { throw 're-review git log failed' }
```

Both reviewers re-read the full fixed range and issue final `APPROVED` with no open Critical/Important. Only then proceed.

---

### Task 7: Focused Gates, One Final Precommit, Safe Live mc Read Evidence, STATUS, and Integration

**Files:** all affected tests; modify `docs/superpowers/STATUS.md` only after review and gates.

- [ ] **Step 1: Run focused functional and regression gates**

```powershell
Remove-Item Env:PGPORT -ErrorAction SilentlyContinue
$env:ERL_FLAGS='-kernel standard_io_encoding unicode'
$env:ELIXIR_ERL_OPTIONS='+S 2:2 +A0 +sbwt none +sbwtdcpu none +sbwtdio none'
mix test test/maxio/admin/envelope_test.exs test/maxio/s3/control_body_test.exs test/maxio/admin/user_request_test.exs test/maxio/iam/minio_admin_user_test.exs test/maxio/admin/user_adapter_test.exs test/maxio/admin/user_endpoint_test.exs test/maxio/admin/authz_test.exs test/maxio/admin/policy_endpoint_test.exs test/maxio/auth_test.exs test/maxio/s3/plugs/sigv4_test.exs test/mix/tasks/maxio_admin_user_test.exs test/maxio/compat/admin_user_fixture_test.exs test/maxio/compat/external_smoke_test.exs
if ($LASTEXITCODE -ne 0) { throw 'focused S2b/regression tests failed' }
mix compile --warnings-as-errors
if ($LASTEXITCODE -ne 0) { throw 'warnings-as-errors compile failed' }
mix format --check-formatted
if ($LASTEXITCODE -ne 0) { throw 'format check failed' }
```

- [ ] **Step 2: Run the batch's single full precommit**

```powershell
Remove-Item Env:PGPORT -ErrorAction SilentlyContinue
$env:ERL_FLAGS='-kernel standard_io_encoding unicode'
$env:ELIXIR_ERL_OPTIONS='+S 2:2 +A0 +sbwt none +sbwtdcpu none +sbwtdio none'
mix precommit
if ($LASTEXITCODE -ne 0) { throw 'final precommit failed' }
```

Expected: exit 0. This is the only full precommit for the batch; any fix returns through RED/focused GREEN and invalidates the review approval until re-reviewed.

- [ ] **Step 3: Run real mc list/info smoke when prerequisites exist**

Use one dev endpoint, `http://127.0.0.1:9900`, and configure `mc`, `MAXIO_ROOT_USER`, and `MAXIO_ROOT_PASSWORD` without printing secrets. Start Maxio separately, then:

```powershell
Remove-Item Env:PGPORT -ErrorAction SilentlyContinue
$env:ERL_FLAGS='-kernel standard_io_encoding unicode'
$env:ELIXIR_ERL_OPTIONS='+S 2:2 +A0 +sbwt none +sbwtdcpu none +sbwtdio none'
mix maxio.compat.matrix --include-external-smoke --external-smoke-client minio_mc
if ($LASTEXITCODE -ne 0) { throw 'external smoke process failed' }
```

Read the generated artifact, not just process exit. This real pinned-mc run is the U2 response-decryption oracle complementary to offline official/Go vectors: passing evidence requires fixture setup, `mc admin user list`, U3 info, and cleanup all `ok`, with exact enabled/name assertions. Assert the artifact's complete command list contains no `admin user add`. U1 is evidenced only by the reviewed Go vectors and signed HTTP endpoint tests; never label it real-mc verified. If mc/root env/server is absent, or cleanup fails, record live as **BLOCKED/attention, not passed** and preserve every primary and cleanup blocker. Never implement U4/U5 merely to clean up.

- [ ] **Step 4: Update STATUS only after final clean review/gate evidence**

```powershell
$dirty=@(git status --porcelain)
if ($LASTEXITCODE -ne 0) { throw 'git status failed' }
if ($dirty.Count -ne 0) { throw 'STATUS update requires a clean reviewed code tree' }
git diff --check d193301..HEAD
if ($LASTEXITCODE -ne 0) { throw 'pre-STATUS diff check failed' }
```

Record exact commits, reviewer verdicts, focused/precommit counts, dependency/vector provenance, live artifact path and `gate_status`, honest blockers/deviations, the non-wire-visible difference from madmin's internal Argon2 mutex, deferred concurrent-64-MiB admission/DoS hardening risk, and remaining U4/U5/list-bucket 501. Then commit only STATUS:

```powershell
git add docs/superpowers/STATUS.md
if ($LASTEXITCODE -ne 0) { throw 'git add STATUS failed' }
$unexpected=@(git diff --cached --name-only | Where-Object { $_ -ne 'docs/superpowers/STATUS.md' })
if ($LASTEXITCODE -ne 0) { throw 'git cached-name diff failed' }
if ($unexpected.Count -ne 0) { throw "STATUS commit would hide code dirt: $($unexpected -join ', ')" }
git commit -m "docs(status): record admin user S2b evidence"
if ($LASTEXITCODE -ne 0) { throw 'STATUS commit failed' }
git diff --check d193301..HEAD
if ($LASTEXITCODE -ne 0) { throw 'final diff check failed' }
$dirty=@(git status --porcelain)
if ($LASTEXITCODE -ne 0) { throw 'git status failed' }
if ($dirty.Count -ne 0) { throw 'final branch is not clean' }
$reviewedBaseSha='d193301ba78b619a1a72740979ceab3392fcf5a1'
$featureBaseSha=(git merge-base HEAD $reviewedBaseSha).Trim().ToLowerInvariant()
if ($LASTEXITCODE -ne 0) { throw 'feature merge-base lookup failed' }
if ($featureBaseSha -ne $reviewedBaseSha) { throw 'feature no longer descends from the fixed reviewed base; re-review the combined range' }
$featureCandidateSha=(git rev-parse HEAD).Trim().ToLowerInvariant()
if ($LASTEXITCODE -ne 0) { throw 'feature HEAD lookup failed' }
if ($featureCandidateSha -notmatch '\A[0-9a-f]{40}\z') { throw 'feature HEAD is not a full commit SHA' }
Write-Output "REVIEWED_BASE_SHA=$reviewedBaseSha"
Write-Output "FEATURE_CANDIDATE_SHA=$featureCandidateSha"
```

- [ ] **Step 5: Freeze and independently approve the exact final feature SHA**

The preceding clean-tree gate captures the immutable `FEATURE_CANDIDATE_SHA` that includes the final STATUS commit. The independent reviewers re-check `d193301..FEATURE_CANDIDATE_SHA` and record one final approval containing exact `reviewed_base_sha` and `reviewed_feature_sha`. Any accepted finding restarts author RED/fix, focused gates, the single-final-precommit rule as applicable, STATUS evidence, and review; do not integrate a SHA different from the one in that final approval.

- [ ] **Step 6: Assert both worktrees, fast-forward, atomically push both refs, and verify remote SHAs**

Run from the main worktree. Set `MAXIO_REVIEWED_FEATURE_SHA` to the exact 40-hex `reviewed_feature_sha` in the final independent approval; do not derive that trusted value from the live branch being checked.

```powershell
$reviewedBaseSha='d193301ba78b619a1a72740979ceab3392fcf5a1'
$reviewedFeatureSha=([string]$env:MAXIO_REVIEWED_FEATURE_SHA).Trim().ToLowerInvariant()
if ($reviewedFeatureSha -notmatch '\A[0-9a-f]{40}\z') { throw 'MAXIO_REVIEWED_FEATURE_SHA must be the exact final reviewed 40-hex SHA' }
$featureWorktree='C:\Users\DYZ\Documents\dev\hemifuture\maxio\.worktrees\admin-user-s2b'

$currentBranch=(git symbolic-ref --short HEAD).Trim()
if ($LASTEXITCODE -ne 0) { throw 'current branch lookup failed' }
if ($currentBranch -cne 'master') { throw 'integration must run on the exact local master branch' }
$masterRef=(git rev-parse refs/heads/master).Trim().ToLowerInvariant()
if ($LASTEXITCODE -ne 0) { throw 'local master ref lookup failed' }
if ($masterRef -ne $reviewedBaseSha) { throw 'local master ref moved from reviewed base; stop and re-review the combined range' }
$featureRef=(git rev-parse refs/heads/codex/admin-user-s2b).Trim().ToLowerInvariant()
if ($LASTEXITCODE -ne 0) { throw 'local feature ref lookup failed' }
if ($featureRef -ne $reviewedFeatureSha) { throw 'local feature ref differs from reviewed feature SHA; stop and re-review the combined range' }

$mainHead=(git rev-parse HEAD).Trim().ToLowerInvariant()
if ($LASTEXITCODE -ne 0) { throw 'main HEAD lookup failed' }
if ($mainHead -ne $reviewedBaseSha) { throw 'main HEAD moved from reviewed base; stop and re-review the combined range' }
$mainDirty=@(git status --porcelain=v1)
if ($LASTEXITCODE -ne 0) { throw 'main porcelain lookup failed' }
if ($mainDirty.Count -ne 0) { throw 'main worktree is not porcelain-empty' }

$featureHead=(git -C $featureWorktree rev-parse HEAD).Trim().ToLowerInvariant()
if ($LASTEXITCODE -ne 0) { throw 'feature HEAD lookup failed' }
if ($featureHead -ne $reviewedFeatureSha) { throw 'feature HEAD differs from reviewed feature SHA; stop and re-review the combined range' }
$featureDirty=@(git -C $featureWorktree status --porcelain=v1)
if ($LASTEXITCODE -ne 0) { throw 'feature porcelain lookup failed' }
if ($featureDirty.Count -ne 0) { throw 'feature worktree is not porcelain-empty' }
$featureBaseSha=(git -C $featureWorktree merge-base $reviewedFeatureSha $reviewedBaseSha).Trim().ToLowerInvariant()
if ($LASTEXITCODE -ne 0) { throw 'feature reviewed-base lookup failed' }
if ($featureBaseSha -ne $reviewedBaseSha) { throw 'reviewed feature does not descend from reviewed base; stop and re-review the combined range' }

git merge --ff-only codex/admin-user-s2b
if ($LASTEXITCODE -ne 0) { throw 'fast-forward merge failed' }
$mergedHead=(git rev-parse HEAD).Trim().ToLowerInvariant()
if ($LASTEXITCODE -ne 0) { throw 'post-merge HEAD lookup failed' }
if ($mergedHead -ne $reviewedFeatureSha) { throw 'post-merge main HEAD is not the reviewed feature SHA' }
$postMergeMainDirty=@(git status --porcelain=v1)
if ($LASTEXITCODE -ne 0) { throw 'post-merge main porcelain lookup failed' }
if ($postMergeMainDirty.Count -ne 0) { throw 'post-merge main worktree is not porcelain-empty' }
$postMergeFeatureDirty=@(git -C $featureWorktree status --porcelain=v1)
if ($LASTEXITCODE -ne 0) { throw 'post-merge feature porcelain lookup failed' }
if ($postMergeFeatureDirty.Count -ne 0) { throw 'post-merge feature worktree is not porcelain-empty' }

git push --atomic origin refs/heads/master:refs/heads/master refs/heads/codex/admin-user-s2b:refs/heads/codex/admin-user-s2b
if ($LASTEXITCODE -ne 0) { throw 'atomic master/feature push failed' }
$remoteRefs=@(git ls-remote --heads origin refs/heads/master refs/heads/codex/admin-user-s2b)
if ($LASTEXITCODE -ne 0) { throw 'remote ref lookup failed' }
$remoteByRef=@{}
foreach($line in $remoteRefs){
  $parts=$line -split "`t",2
  if($parts.Count -eq 2){ $remoteByRef[$parts[1]]=$parts[0].ToLowerInvariant() }
}
if ($remoteByRef['refs/heads/master'] -ne $reviewedFeatureSha) { throw 'remote master is not the reviewed feature SHA' }
if ($remoteByRef['refs/heads/codex/admin-user-s2b'] -ne $reviewedFeatureSha) { throw 'remote feature is not the reviewed feature SHA' }
$finalMainDirty=@(git status --porcelain=v1)
if ($LASTEXITCODE -ne 0) { throw 'final main porcelain lookup failed' }
if ($finalMainDirty.Count -ne 0) { throw 'final main worktree is not porcelain-empty' }
$finalFeatureDirty=@(git -C $featureWorktree status --porcelain=v1)
if ($LASTEXITCODE -ne 0) { throw 'final feature porcelain lookup failed' }
if ($finalFeatureDirty.Count -ne 0) { throw 'final feature worktree is not porcelain-empty' }
```

Expected: fixed reviewed base, exact independently reviewed feature SHA, porcelain-empty main and feature worktrees before and after the fast-forward, and both remote refs resolving to that same reviewed feature SHA. Any mismatch stops before the next state-changing command and requires independent review of the newly combined range; never merge around it or force-push. A blocked live prerequisite may be recorded and pushed only if the project owner explicitly accepts that blocker; it must never be relabeled as live pass.

## Completion Checklist

- U1 exact route/action/status/encryption passes pinned bidirectional Go vectors and signed HTTP evidence; U2 additionally passes real mc list when prerequisites exist. Automated mc add is intentionally absent because its required positional secret enters argv.
- U1 is atomic new-only, no partial row, no premature notification, no secret leak; the stricter duplicate/update deviation is documented.
- U2 lists explicit IAM users only, reuses reviewed U3 projection, omits root and all secret/private fields.
- U3 remains plaintext and passing; list bucket, U4, and U5 remain authenticated/authorized JSON 501.
- Independent protocol/crypto and code/architecture reviews approve the clean fixed range.
- Focused gates and exactly one final `mix precommit` pass; live state is either evidence-backed pass or honestly recorded blocker.
- STATUS is the final content commit and records deferred Argon2 concurrency/DoS hardening; the exact final feature SHA is independently approved, integration is fast-forward only, and local/remote master plus feature refs all finish at that SHA with both worktrees clean.
