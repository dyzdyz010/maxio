# MinIO Admin User S2a (U3 UserInfo Only) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement only MinIO Admin v3 U3, `GET /minio/admin/v3/user-info?accessKey=N`, as an authenticated, authorized, plaintext read-only projection over maxio IAM.

**Architecture:** `Maxio.Admin.UserAdapter` is the sole UserInfo projection boundary and calls only the public `Maxio.IAM` facade. `Maxio.Admin.Plug` owns routing, `admin:GetUser` authorization, logging context, and JSON response encoding; it must not query Repo, Policy.Store, or Ecto. This batch adds no persistence callback, migration, credential-cache behavior, encryption, or IAM mutation.

**Tech Stack:** Elixir, Plug/Bandit, Phoenix JSON, Ecto-backed existing IAM facade, ExUnit, SigV4 test helpers, MinIO `mc` external smoke.

**Spec:** `docs/superpowers/specs/2026-08-20-minio-admin-user-policy-design.md` §1.1 U3, §2, §3.1–3.2, §5–§8; S1 foundation at `docs/superpowers/plans/2026-08-28-minio-admin-policy-s1.md` and current evidence in `docs/superpowers/STATUS.md`.

## Global Constraints

- Scope is exactly U3: `GET /minio/admin/v3/user-info?accessKey=N`, required action `admin:GetUser`, success `200 application/json` with plaintext `madmin.UserInfo` JSON.
- Do not implement MinIO's self-read deny-only relaxation. Reading oneself still requires a full `Maxio.Admin.Authz.authorize/3` allow for `admin:GetUser`; document this stricter V-B17 behavior in README and STATUS.
- Missing/non-binary/empty/invalid `accessKey` is rejected before IAM lookup with a structured 400. Leading/trailing Unicode whitespace or comma maps to `XMinioInvalidResource`; other invalid shapes map to `XMinioAdminInvalidArgument`.
- A valid but absent user maps to exact `XMinioAdminNoSuchUser`/404 with `The specified user does not exist.`; unknown internal reasons remain redacted `InternalError`/500.
- UserInfo always contains `status`; `active` maps to `enabled` and `inactive` to `disabled`. It conditionally contains `policyName`, `memberOf`, and `updatedAt`; it never contains `secretKey`, `userAuthInfo`, policy documents, session tokens, or maxio-private fields.
- `policyName` is a stable, comma-joined list of direct attached managed-policy names only. Direct inline, group inline, group managed, and role managed sources are omitted from the wire view, counted in structured evidence, and shown by name/ARN only in the local read-only CLI.
- Existing direct managed-policy names containing comma are omitted from `policyName` and produce a redacted warning; never emit an ambiguous comma-joined value.
- `memberOf` is the stable sorted group-name result of `Maxio.IAM.list_groups_for_user/1`.
- Non-nil `updatedAt` is exactly `DateTime.to_iso8601(user.updated_at)` in UTC; nil omits the key. Do not delegate raw `%DateTime{}` encoding to Jason.
- `credential_bearing` is evidence only, never a UserInfo wire key. After `{:ok, keys} = Maxio.IAM.list_access_keys_strict(name)`, its exact definition is `Enum.any?(keys, &(&1.access_key_id == name))`: no keys and only nonmatching keys are false; a same-name key is true.
- UserAdapter may call only public `Maxio.IAM` functions. It must not alias or call `Maxio.Repo`, `Maxio.Policy.Store`, Ecto schemas, credential stores, or cluster notification modules.
- Plug remains a thin HTTP boundary: route, authorize, attach structured metadata, render JSON/error. Projection and source accounting belong in UserAdapter.
- Root shortcut, explicit Deny precedence, STS session-policy boundary, and the rule that bucket policy cannot grant cluster admin actions remain exactly the S1 `Maxio.Admin.Authz` behavior.
- U1 `/add-user`, U2 `/list-users` including `?bucket=`, U4 `/remove-user`, and U5 `/set-user-status` remain authenticated `NotImplemented`/501. The next user-mutation batch must first land and independently review an identity-lock/versioned-credential-invalidation architecture before U4/U5 are eligible for implementation.
- External smoke creates its target through the existing IAM fixture/CLI path, runs only `mc admin user info`, and cleans through the existing IAM cleanup path. It must not depend on U4 or U5.
- No migration, new dependency, new crypto, policy evaluator change, credential-cache change, or full-suite gate before the single final precommit in Task 5.
- Every implementation and review diff is fixed to branch point `c86b51dc078459e44e7ee700ade06e7e481f3a1f` (`c86b51dc..HEAD`); do not chase a moving `origin/master`.
- Per `AGENTS.md`, planning/spec review, implementation, code review, and verification are separate lanes. The author never self-reviews.

## File and Interface Map

### Create

- `lib/maxio/admin/user_adapter.ex` — public-IAM-only UserInfo projection and safe evidence.
- `lib/mix/tasks/maxio.admin.user.show.ex` — read-only local U3 recomputation in human/JSON modes.
- `lib/maxio/compat/admin_user_fixture.ex` — repeatable local IAM user fixture with guaranteed existing-IAM cleanup.
- `test/maxio/admin/user_adapter_test.exs`
- `test/maxio/admin/user_endpoint_test.exs`
- `test/mix/tasks/maxio_admin_user_test.exs`
- `test/maxio/compat/admin_user_fixture_test.exs`

### Modify

- `lib/maxio/admin/plug.ex` — add only the U3 dispatch/authorization/response path and user log context.
- `lib/maxio/admin/error_map.ex` — map `:user_not_found` without changing policy `:not_found` behavior.
- `lib/maxio/s3/error.ex` — add the confirmed `admin_no_such_user` wire tuple.
- `config/config.exs` — allowlist only safe user projection metadata.
- `lib/maxio/compat/external_smoke.ex` — add one fixture-backed `mc admin user info` step.
- `test/maxio/compat/external_smoke_test.exs` — assert the one-step scenario, output, redaction, and cleanup paths.
- `README.md` — record U3 support, partial-view warning, V-B17, and remaining 501 routes.
- `docs/superpowers/STATUS.md` — update only after all review and verification evidence exists.

### Production Interfaces

```elixir
Maxio.Admin.UserAdapter.validate_name(term()) ::
  :ok | {:error, :invalid_argument | :invalid_resource_name}

Maxio.Admin.UserAdapter.info(term()) ::
  {:ok, %{wire: map(), evidence: map()}} | {:error, :user_not_found | term()}

Maxio.Admin.UserAdapter.project(map(), map()) ::
  {:ok, %{wire: map(), evidence: map()}} | {:error, term()}
```

`info/1` uses these already verified public facade calls only:

```elixir
Maxio.IAM.get_user(name)
Maxio.IAM.list_access_keys_strict(name)
Maxio.IAM.list_attached_user_policies(name)
Maxio.IAM.list_principal_policies(user_arn)
Maxio.IAM.list_groups_for_user(name)
Maxio.IAM.list_group_policies(group_name)
Maxio.IAM.list_attached_group_policies(group_name)
Maxio.IAM.list_attached_role_policies(user_arn)
```

The wire map is exact JSON-key data:

```elixir
%{
  "status" => "enabled" | "disabled",
  # present only when non-empty:
  "policyName" => "name-a,name-b",
  "memberOf" => ["group-a", "group-b"],
  # present only when user.updated_at is non-nil:
  "updatedAt" => "2026-08-28T12:34:56.123456Z"
}
```

Evidence contains stable counts and name/ARN lists only. It may report `credential_bearing`, `direct_managed`, `direct_inline`, `group_inline`, `group_managed`, `role_managed`, `omitted_reason`, and `minio_view_partial`; it may not retain or print documents or secrets. `credential_bearing` is consumed only by CLI/log evidence and must never be copied into `wire`.

---

### Task 1: Commit the S2a Plan and Obtain Independent Spec GO

**Files:**

- Create/commit: `docs/superpowers/plans/2026-08-28-minio-admin-user-s2.md`
- Read: `AGENTS.md`, `docs/superpowers/STATUS.md`, the spec and S1 files named above

- [ ] **Step 1: Prove the fixed base and plan-only dirty boundary**

```powershell
$expectedBase='c86b51dc078459e44e7ee700ade06e7e481f3a1f'
if ((git rev-parse HEAD) -ne $expectedBase) { throw 'unexpected starting HEAD' }
if ((git merge-base HEAD origin/master) -ne $expectedBase) { throw 'unexpected branch point' }
$expectedDirty='?? docs/superpowers/plans/2026-08-28-minio-admin-user-s2.md'
$dirty=@(git status --porcelain=v1)
if ($dirty.Count -ne 1 -or $dirty[0] -ne $expectedDirty) {
  throw "pre-plan worktree must contain only the untracked S2a plan; actual: $($dirty -join '; ')"
}
```

Expected: only this untracked plan is present. A staged/modified plan, another untracked file, or any unrelated dirty path is a hard stop.

- [ ] **Step 2: Commit the plan as the first branch commit**

```powershell
git add docs/superpowers/plans/2026-08-28-minio-admin-user-s2.md
git commit -m "docs(plan): scope admin user S2a info"
if ((git rev-parse HEAD^) -ne 'c86b51dc078459e44e7ee700ade06e7e481f3a1f') { throw 'plan is not first after fixed base' }
git diff --check c86b51dc..HEAD
if (git status --porcelain) { throw 'plan commit left a dirty tree' }
```

Expected: one docs-only commit, clean tree, no diff errors.

- [ ] **Step 3: Independent spec reviewer decides GO/NO-GO**

Reviewer reads the full spec and inspects:

```powershell
git show --stat --oneline HEAD
git show HEAD -- docs/superpowers/plans/2026-08-28-minio-admin-user-s2.md
rg -n "U3|user-info|admin:GetUser|NotImplemented|501" docs/superpowers/plans/2026-08-28-minio-admin-user-s2.md
```

Expected GO only if implementation scope is U3, U4/U5 occur only in the remaining-501/next-batch boundary, the public-IAM boundary is complete, and every protocol/error/field requirement is assigned to a test. A NO-GO returns to the planning lane; amend the docs-only commit and repeat review before implementation.

---

### Task 2: Build the Public-IAM UserInfo Adapter and User Error Mapping

**Files:**

- Create: `lib/maxio/admin/user_adapter.ex`
- Create: `test/maxio/admin/user_adapter_test.exs`
- Modify: `lib/maxio/admin/error_map.ex`
- Modify: `lib/maxio/s3/error.ex`
- Modify: `test/maxio/admin/error_map_test.exs`

**Produces:** `UserAdapter.validate_name/1`, `UserAdapter.info/1`, and `ErrorMap.from_reason(:user_not_found)`.

- [ ] **Step 1: Write adapter RED tests before production code**

Use `Maxio.DataCase, async: false` and existing IAM fixture functions. Create active and inactive users; direct attached managed policies in unsorted order; a direct inline policy; two groups with inline/managed policies; and a direct managed policy whose existing name contains comma. Assert:

- `validate_name/1` returns `:invalid_argument` for nil, empty, over-64-byte, slash/backslash, or characters outside `~r/\A[A-Za-z0-9+=.@_-]{1,64}\z/`; edge Unicode whitespace and comma return `:invalid_resource_name`;
- missing user returns `{:error, :user_not_found}`;
- active/inactive becomes exact enabled/disabled;
- `policyName` contains only sorted, comma-safe direct managed names and is omitted when empty;
- `memberOf` contains only sorted group names and is omitted when empty;
- `updatedAt == DateTime.to_iso8601(user.updated_at)`; `project/2` with a nil timestamp omits the key, while a mutation returning raw `%DateTime{}` fails;
- `secretKey`, `userAuthInfo`, documents, and private source keys never enter `wire`;
- `evidence` retains only safe name/ARN/count data, reports omitted sources and `credential_bearing`, and marks `minio_view_partial` when the wire view is incomplete;
- credential-bearing mutation matrix: a user with no keys is false; a user with only `OTHERKEY` is still false; a user whose nonmatching key precedes a same-name key is true. The tests must fail both an `Enum.any?(keys)` mutation and a first-key-only mutation, and assert `credential_bearing` is absent from `wire`.

- [ ] **Step 2: Write error RED tests**

Assert the exact new tuple and no policy regression:

```elixir
assert %{code: "XMinioAdminNoSuchUser", status: 404,
         message: "The specified user does not exist."} =
         Maxio.Admin.ErrorMap.from_reason(:user_not_found)

assert %{code: "XMinioAdminNoSuchPolicy", status: 404} =
         Maxio.Admin.ErrorMap.from_reason(:not_found)
```

- [ ] **Step 3: Run focused RED**

```powershell
Remove-Item Env:PGPORT -ErrorAction SilentlyContinue
$env:ERL_FLAGS='-kernel standard_io_encoding unicode'
$env:ELIXIR_ERL_OPTIONS='+S 2:2 +A0 +sbwt none +sbwtdcpu none +sbwtdio none'
mix test test/maxio/admin/user_adapter_test.exs test/maxio/admin/error_map_test.exs --max-failures 1
```

Expected RED: UserAdapter and the user-specific error tuple do not exist.

- [ ] **Step 4: Implement the smallest projection**

Implement the interfaces exactly as mapped. `info/1` validates first, resolves the user once through `IAM.get_user/1`, collects every source only through the listed IAM functions, immediately reduces policy maps to names/ARNs, and then builds `wire` with conditional `Map.put/3`. The adapter returns safe `evidence` separately so Plug and CLI do not reconstruct policy-source semantics.

Implement `project/2` as the `@doc false` pure projection seam receiving an already resolved user and safe source summary; production Plug/CLI call only `info/1`. Do not introduce an application-configured Repo/Store dependency.

- [ ] **Step 5: Run GREEN, compile, and dependency scans**

```powershell
Remove-Item Env:PGPORT -ErrorAction SilentlyContinue
$env:ERL_FLAGS='-kernel standard_io_encoding unicode'
$env:ELIXIR_ERL_OPTIONS='+S 2:2 +A0 +sbwt none +sbwtdcpu none +sbwtdio none'
mix test test/maxio/admin/user_adapter_test.exs test/maxio/admin/error_map_test.exs --max-failures 1
mix compile --warnings-as-errors
rg -n "Maxio\.(Repo|Policy\.Store|Auth\.|Cluster)|Ecto\." lib/maxio/admin/user_adapter.ex
```

Expected: tests and compile pass; dependency scan has zero matches.

- [ ] **Step 6: Commit the adapter slice**

```powershell
git add lib/maxio/admin/user_adapter.ex lib/maxio/admin/error_map.ex lib/maxio/s3/error.ex test/maxio/admin/user_adapter_test.exs test/maxio/admin/error_map_test.exs
git commit -m "feat(admin): project MinIO user info"
if (git status --porcelain) { throw 'Task 2 commit left a dirty tree' }
```

---

### Task 3: Route and Authorize Only U3

**Files:**

- Modify: `lib/maxio/admin/plug.ex`
- Create: `test/maxio/admin/user_endpoint_test.exs`
- Modify: `test/maxio/admin/authz_test.exs`
- Regression: `test/maxio/admin/policy_endpoint_test.exs`, `test/maxio/admin/plug_test.exs`, `test/maxio/admin/info_endpoint_test.exs`

**Consumes:** `UserAdapter.info/1` and `ErrorMap.from_reason/1` from Task 2.

- [ ] **Step 1: Write endpoint RED tests with signed requests**

Using the existing `SigV4Request.signed_conn(..., region: "")` style, assert:

1. root U3 returns strict 200, `application/json`, plaintext decoded UserInfo, exact ISO UTC `updatedAt`, omit discipline, and no secret;
2. a non-root identity with only `admin:GetUser` succeeds; no allow, explicit Deny, or an STS session policy that omits the action returns 403;
3. bucket policy alone cannot grant U3;
4. self-read without a full identity-policy allow is still 403 (V-B17), while self-read with the allow succeeds;
5. missing/empty/regex-invalid `accessKey` is `XMinioAdminInvalidArgument`/400; edge Unicode whitespace or comma is `XMinioInvalidResource`/400; a valid absent name is exact `XMinioAdminNoSuchUser`/404;
6. anonymous requests are 403 before endpoint disclosure;
7. authenticated U1/U2/U2-with-bucket/U4/U5 requests remain JSON 501;
8. existing policy/info admin routes and ordinary S3 dispatch remain unchanged.

- [ ] **Step 2: Run endpoint RED**

```powershell
Remove-Item Env:PGPORT -ErrorAction SilentlyContinue
$env:ERL_FLAGS='-kernel standard_io_encoding unicode'
$env:ELIXIR_ERL_OPTIONS='+S 2:2 +A0 +sbwt none +sbwtdcpu none +sbwtdio none'
mix test test/maxio/admin/user_endpoint_test.exs test/maxio/admin/authz_test.exs --max-failures 1
```

Expected RED: U3 still reaches the authenticated NotImplemented fallback.

- [ ] **Step 3: Add the thin U3 dispatch**

Add one exact dispatch clause:

```elixir
defp dispatch(conn, "GET", "/minio/admin/v3/user-info"), do: user_info(conn)
```

`user_info/1` must call the existing authorization helper with `admin:GetUser` and `admin_user_info`, call `UserAdapter.info(conn.query_params["accessKey"])`, send `result.wire` through the shared JSON-200 helper, and route adapter errors through `ErrorMap`. Generalize the helper's target metadata input if needed; do not put IAM source queries or wire-shaping branches in Plug.

- [ ] **Step 4: Run GREEN and adjacent regressions**

```powershell
Remove-Item Env:PGPORT -ErrorAction SilentlyContinue
$env:ERL_FLAGS='-kernel standard_io_encoding unicode'
$env:ELIXIR_ERL_OPTIONS='+S 2:2 +A0 +sbwt none +sbwtdcpu none +sbwtdio none'
mix test test/maxio/admin/user_endpoint_test.exs test/maxio/admin/authz_test.exs test/maxio/admin/policy_endpoint_test.exs test/maxio/admin/plug_test.exs test/maxio/admin/info_endpoint_test.exs --max-failures 1
mix compile --warnings-as-errors
```

Expected: all pass with zero warnings.

- [ ] **Step 5: Commit the HTTP slice**

```powershell
git add lib/maxio/admin/plug.ex test/maxio/admin/user_endpoint_test.exs test/maxio/admin/authz_test.exs
git commit -m "feat(admin): route authorized user info"
if (git status --porcelain) { throw 'Task 3 commit left a dirty tree' }
```

---

### Task 4: Add Read-Only CLI, Partial-View Evidence, Docs, and One-Step mc Smoke

**Files:**

- Create: `lib/mix/tasks/maxio.admin.user.show.ex`
- Create: `test/mix/tasks/maxio_admin_user_test.exs`
- Create: `lib/maxio/compat/admin_user_fixture.ex`
- Create: `test/maxio/compat/admin_user_fixture_test.exs`
- Modify: `config/config.exs`
- Modify: `lib/maxio/admin/plug.ex`
- Modify: `test/maxio/admin/user_endpoint_test.exs`
- Modify: `lib/maxio/compat/external_smoke.ex`
- Modify: `test/maxio/compat/external_smoke_test.exs`
- Modify: `README.md`

- [ ] **Step 1: Write CLI and log RED tests**

With `Mix.Shell.Process`, assert `mix maxio.admin.user.show NAME` and `--json` both call the same adapter projection. Human output and JSON evidence must show status, credential-bearing state, visible direct managed policies, and omitted direct/group/role source names/ARNs without any policy document, secret, or token.

Capture endpoint logs and assert safe fields: `target_user`, `credential_bearing`, `managed_policies`, `inline_policies`, `group_inherited`, `role_attached`, `minio_view_partial`, and `omitted_reason`. A partial view logs counts; a comma-name omission logs a warning; neither log contains documents or credentials.

- [ ] **Step 2: Write fixture and external-smoke RED tests**

Define the fixture contract before implementation:

```elixir
Maxio.Compat.AdminUserFixture.with_user(keyword(), (map() -> term())) ::
  {:ok, term(), %{steps: [map()], blockers: [map()]}}
  | {:error, map(), %{steps: [map()], blockers: [map()]}}
```

The first tuple element preserves the callback's primary result exactly. The cleanup component always uses the existing external-smoke step-view/blocker shape; cleanup failure is data, never a swallowed exception. Tests inject create/cleanup callbacks and prove cleanup runs after success, mc failure, and callback raise. The default path starts only the Repo prerequisites through `Maxio.Config.CLI.start_repo/0`, creates a unique active user through `Maxio.IAM.create_user/1`, and cleans through the existing `Maxio.IAM.delete_user/1` path used by `mix maxio.iam.delete_user`; it creates no key and exposes no secret.

ExternalSmoke tests require exactly one added mc step:

```text
id: admin_user_info
args: admin user info maxiocompat <fixture-user>
scenario: admin_user_info
assertion: output contains Status and enabled
```

Assert `scenario_counts.admin_user_info == 1`, fixture cleanup runs on every result, output is redacted, and there are no user enable/disable/remove commands. Add two composition tests:

1. primary user-info succeeds and fixture cleanup fails: retain the successful primary step view, produce final `blocked`, and append an `external_smoke_cleanup_failed` blocker;
2. primary user-info is already blocked and fixture cleanup also fails: retain the original primary status/step/blocker first, then append the cleanup step/blocker. The result must contain both causes and must not collapse to generic `external_smoke_failed` from `run_client/5` rescue.

Both tests are mutation-sensitive: ignoring cleanup or replacing the primary blocker with the cleanup blocker must fail.

- [ ] **Step 3: Preserve RED**

```powershell
Remove-Item Env:PGPORT -ErrorAction SilentlyContinue
$env:ERL_FLAGS='-kernel standard_io_encoding unicode'
$env:ELIXIR_ERL_OPTIONS='+S 2:2 +A0 +sbwt none +sbwtdcpu none +sbwtdio none'
mix test test/mix/tasks/maxio_admin_user_test.exs test/maxio/compat/admin_user_fixture_test.exs test/maxio/compat/external_smoke_test.exs test/maxio/admin/user_endpoint_test.exs --max-failures 1
```

Expected RED: the CLI, fixture, user evidence metadata, and user-info smoke step are absent.

- [ ] **Step 4: Implement one shared projection and one smoke step**

The CLI calls `UserAdapter.info/1` after `Maxio.Config.CLI.boot/0`; it never reconstructs policy sources. Add only the safe logger keys named in Step 1 to `config/config.exs`.

Wrap the existing mc step plan with `AdminUserFixture.with_user/2`; add only `admin_user_info`, and leave all existing S3/policy steps unchanged. Reuse the current `run_step/3`, step-view, entry-blocker, and cleanup ordering rather than inventing a second external-smoke error envelope: upgrade cleanup aggregation to return step views plus blockers instead of `Enum.each`-and-ignore, then compose the fixture cleanup outcome through that same path.

Composition is exact: primary `ok` + cleanup failure becomes `blocked`; primary `blocked`/`error` + cleanup failure keeps the primary status and blocker first and appends the cleanup blocker. Callback/cleanup exceptions are normalized inside `with_user/2` and handled by `run_minio_mc`, so neither case reaches the generic `run_client/5` rescue. Fixture setup failure remains an honest primary external-smoke blocker. This smoke is valid only when the Mix process and endpoint share the same local database.

- [ ] **Step 5: Document exact support and remaining boundaries**

README must say:

- U3 is plaintext, requires full `admin:GetUser`, and returns the exact partial UserInfo projection;
- `secretKey`/`userAuthInfo` are omitted, and security audits must use IAM Query/CLI rather than treating mc output as complete;
- V-B17 remains deliberately stricter;
- U1/U2 (including bucket variant), U4, and U5 remain authenticated 501;
- the next mutation batch is gated by prior identity-lock/versioned-credential-invalidation design and independent review.

- [ ] **Step 6: Run GREEN, format, and compile**

```powershell
Remove-Item Env:PGPORT -ErrorAction SilentlyContinue
$env:ERL_FLAGS='-kernel standard_io_encoding unicode'
$env:ELIXIR_ERL_OPTIONS='+S 2:2 +A0 +sbwt none +sbwtdcpu none +sbwtdio none'
mix test test/mix/tasks/maxio_admin_user_test.exs test/maxio/compat/admin_user_fixture_test.exs test/maxio/compat/external_smoke_test.exs test/maxio/admin/user_endpoint_test.exs --max-failures 1
mix format --check-formatted
mix compile --warnings-as-errors
```

Expected: all pass; smoke records one U3 scenario and no mutation scenario.

- [ ] **Step 7: Commit the evidence slice**

```powershell
git add lib/mix/tasks/maxio.admin.user.show.ex test/mix/tasks/maxio_admin_user_test.exs lib/maxio/compat/admin_user_fixture.ex test/maxio/compat/admin_user_fixture_test.exs config/config.exs lib/maxio/admin/plug.ex test/maxio/admin/user_endpoint_test.exs lib/maxio/compat/external_smoke.ex test/maxio/compat/external_smoke_test.exs README.md
git commit -m "feat(admin): add user info evidence"
if (git status --porcelain) { throw 'Task 4 commit left a dirty tree' }
```

---

### Task 5: Independent Review, Focused/Full Verification, and Real mc Evidence

**Files:** Review all `c86b51dc..HEAD`; implementation lane modifies only files named by accepted findings.

**Lanes:** A fresh read-only code-review lane reviews; accepted findings return to the implementation lane with RED tests; a separate verification lane owns all gates below.

- [ ] **Step 1: Independent reviewer checks the complete diff**

```powershell
if (git status --porcelain) { throw 'review requires a clean implementation tree' }
if ((git merge-base HEAD c86b51dc078459e44e7ee700ade06e7e481f3a1f) -ne 'c86b51dc078459e44e7ee700ade06e7e481f3a1f') { throw 'branch moved off fixed base' }
git diff --stat c86b51dc..HEAD
git diff c86b51dc..HEAD
```

Reviewer must check exact U3 routing/action/JSON, V-B17, error codes, UTC/omit discipline, direct-managed-only `policyName`, safe partial evidence, IAM-only adapter, no new mutation/cache/persistence behavior, 501 remaining routes, fixture cleanup, and no secret/document leakage. Every finding includes severity, file/line, reproduction, expected/actual, and architecture impact.

- [ ] **Step 2: Author resolves every accepted finding as an independent RED/fix commit**

For each accepted finding, and only one finding at a time: start from a clean tree; add a mutation-sensitive regression test; run the focused command below and capture RED; make the smallest fix; rerun the same command for GREEN; run diff check; stage the tracked finding files with `git add -u`; inspect the staged diff; commit; and prove the tree is clean before starting the next finding. Never batch two review findings in one commit. No findings means no synthetic fix commit.

```powershell
if (git status --porcelain) { throw 'finding work must start clean' }
```

After writing the one finding's regression test, run:

```powershell
Remove-Item Env:PGPORT -ErrorAction SilentlyContinue
$env:ERL_FLAGS='-kernel standard_io_encoding unicode'
$env:ELIXIR_ERL_OPTIONS='+S 2:2 +A0 +sbwt none +sbwtdcpu none +sbwtdio none'
mix test test/maxio/admin test/mix/tasks/maxio_admin_user_test.exs test/maxio/compat/admin_user_fixture_test.exs test/maxio/compat/external_smoke_test.exs --max-failures 1
```

Expected before the fix: RED for the new test. After the smallest fix, rerun the exact block and expect GREEN, then commit that one finding:

```powershell
git diff --check
git add -u
if (-not (git diff --cached --name-only)) { throw 'finding commit has no staged change' }
git diff --cached
git commit -m "fix(admin): resolve reviewed user info finding"
if (git status --porcelain) { throw 'finding commit left a dirty tree' }
```

- [ ] **Step 3: Independent reviewer rechecks the fixed range and records APPROVED HEAD**

Only after every accepted finding has its own commit and the tree is clean, the same read-only reviewer rechecks the fixed range:

```powershell
if (git status --porcelain) { throw 're-review requires a clean tree' }
git diff --stat c86b51dc..HEAD
git diff c86b51dc..HEAD
git log --oneline --decorate c86b51dc..HEAD
$approvedHead=git rev-parse HEAD
"MAXIO_S2A_APPROVED_HEAD=$approvedHead"
```

Expected: APPROVED for that exact SHA. The coordinator records the printed SHA as `MAXIO_S2A_APPROVED_HEAD`; any later code/docs change before STATUS invalidates approval and returns to Step 2/3.

- [ ] **Step 4: Verification lane runs gates only against the approved clean HEAD**

```powershell
Remove-Item Env:PGPORT -ErrorAction SilentlyContinue
$env:ERL_FLAGS='-kernel standard_io_encoding unicode'
$env:ELIXIR_ERL_OPTIONS='+S 2:2 +A0 +sbwt none +sbwtdcpu none +sbwtdio none'
if ([string]::IsNullOrWhiteSpace($env:MAXIO_S2A_APPROVED_HEAD)) { throw 'approved HEAD evidence is required' }
if ((git rev-parse HEAD) -ne $env:MAXIO_S2A_APPROVED_HEAD) { throw 'HEAD differs from independently reviewed SHA' }
if (git status --porcelain) { throw 'verification requires a clean tree' }
mix test test/maxio/admin test/mix/tasks/maxio_admin_user_test.exs test/maxio/compat/admin_user_fixture_test.exs test/maxio/compat/external_smoke_test.exs --max-failures 1
mix compile --warnings-as-errors
mix format --check-formatted
git diff --check c86b51dc..HEAD
if (git status --porcelain) { throw 'focused gates dirtied the tree' }
```

Expected: all tests pass, zero warnings, formatting and diff checks pass.

- [ ] **Step 5: Run the one and only full precommit on the same clean HEAD**

```powershell
Remove-Item Env:PGPORT -ErrorAction SilentlyContinue
$env:ERL_FLAGS='-kernel standard_io_encoding unicode'
$env:ELIXIR_ERL_OPTIONS='+S 2:2 +A0 +sbwt none +sbwtdcpu none +sbwtdio none'
if ([string]::IsNullOrWhiteSpace($env:MAXIO_S2A_APPROVED_HEAD)) { throw 'approved HEAD evidence is required' }
if ((git rev-parse HEAD) -ne $env:MAXIO_S2A_APPROVED_HEAD) { throw 'precommit HEAD differs from reviewed SHA' }
if (git status --porcelain) { throw 'precommit requires a clean tree' }
mix precommit
if ((git rev-parse HEAD) -ne $env:MAXIO_S2A_APPROVED_HEAD) { throw 'HEAD changed during precommit' }
if (git status --porcelain) { throw 'precommit dirtied the tree' }
```

Expected: complete success. Do not run a second full precommit unless the first exposes a defect that required code changes.

- [ ] **Step 6: Run real mc U3 against the dev endpoint**

Prerequisites: native `mc` in PATH, dev server at `http://127.0.0.1:9900`, root env configured, and Mix/server using the same PostgreSQL database and IAM keyring. Missing prerequisites are recorded as exact blockers, never converted into a pass.

Start the server if needed:

```powershell
Remove-Item Env:PGPORT -ErrorAction SilentlyContinue
$env:ERL_FLAGS='-kernel standard_io_encoding unicode'
$env:ELIXIR_ERL_OPTIONS='+S 2:2 +A0 +sbwt none +sbwtdcpu none +sbwtdio none'
if ((git rev-parse HEAD) -ne $env:MAXIO_S2A_APPROVED_HEAD) { throw 'live gate HEAD differs from reviewed SHA' }
if (git status --porcelain) { throw 'live gate requires a clean tree' }
mix phx.server
```

In a second PowerShell, create the target through the existing IAM CLI, run only `mc admin user info`, and clean through the existing IAM CLI even on failure:

```powershell
Remove-Item Env:PGPORT -ErrorAction SilentlyContinue
$env:ERL_FLAGS='-kernel standard_io_encoding unicode'
$env:ELIXIR_ERL_OPTIONS='+S 2:2 +A0 +sbwt none +sbwtdcpu none +sbwtdio none'
$approvedHead=$env:MAXIO_S2A_APPROVED_HEAD
if ([string]::IsNullOrWhiteSpace($approvedHead) -or (git rev-parse HEAD) -ne $approvedHead) { throw 'live client HEAD differs from reviewed SHA' }
if (git status --porcelain) { throw 'live client requires a clean tree' }
$endpoint='http://127.0.0.1:9900'
$userName="s2a-info-$([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds())"
$aliasName="s2a-root-$([guid]::NewGuid().ToString('N'))"
$failures=[System.Collections.Generic.List[string]]::new()
$userCreated=$false
$aliasCreated=$false
try {
  $aliasOutput=(& mc alias set $aliasName $endpoint $env:MAXIO_ROOT_USER $env:MAXIO_ROOT_PASSWORD 2>&1 | Out-String)
  $aliasExit=$LASTEXITCODE
  if ($aliasExit -ne 0) { throw "alias failed exit=$aliasExit output=$aliasOutput" }
  $aliasCreated=$true

  $createOutput=(& mix maxio.iam.create_user --name $userName 2>&1 | Out-String)
  $createExit=$LASTEXITCODE
  if ($createExit -ne 0) { throw "fixture create failed exit=$createExit output=$createOutput" }
  $userCreated=$true

  $infoOutput=(& mc --debug admin user info $aliasName $userName 2>&1 | Out-String)
  $infoExit=$LASTEXITCODE
  if ($infoExit -ne 0) { throw "user info failed exit=$infoExit output=$infoOutput" }
  if ($infoOutput -notmatch '(?im)Status:\s*enabled\b') { throw "user info missing enabled status: $infoOutput" }
  if ($infoOutput -match '(?i)secretKey|userAuthInfo') { throw 'user info leaked a forbidden field' }
} catch {
  $failures.Add("primary: $($_.Exception.Message)")
} finally {
  if ($userCreated) {
    $cleanupOutput=(& mix maxio.iam.delete_user --name $userName 2>&1 | Out-String)
    $cleanupExit=$LASTEXITCODE
    if ($cleanupExit -ne 0) { $failures.Add("fixture cleanup failed exit=$cleanupExit output=$cleanupOutput") }
  }
  if ($aliasCreated) {
    $aliasCleanupOutput=(& mc alias rm $aliasName 2>&1 | Out-String)
    $aliasCleanupExit=$LASTEXITCODE
    if ($aliasCleanupExit -ne 0) { $failures.Add("alias cleanup failed exit=$aliasCleanupExit output=$aliasCleanupOutput") }
  }
}
if ($failures.Count -gt 0) { throw ($failures -join [Environment]::NewLine) }
if ((git rev-parse HEAD) -ne $approvedHead -or (git status --porcelain)) { throw 'live client changed the reviewed tree' }
```

Expected: exact enabled UserInfo output and reliable cleanup; no admin mutation command is used.

- [ ] **Step 7: Run the automated external smoke**

```powershell
Remove-Item Env:PGPORT -ErrorAction SilentlyContinue
$env:ERL_FLAGS='-kernel standard_io_encoding unicode'
$env:ELIXIR_ERL_OPTIONS='+S 2:2 +A0 +sbwt none +sbwtdcpu none +sbwtdio none'
if ((git rev-parse HEAD) -ne $env:MAXIO_S2A_APPROVED_HEAD) { throw 'external smoke HEAD differs from reviewed SHA' }
if (git status --porcelain) { throw 'external smoke requires a clean tree' }
$endpoint='http://127.0.0.1:9900'
$env:MAXIO_COMPAT_ENDPOINT=$endpoint
mix maxio.compat.matrix --include-external-smoke --external-smoke-client minio_mc
if (git status --porcelain) { throw 'external smoke dirtied the tree' }
```

Expected: `minio_mc status=ok`, `admin_user_info=1`, existing `admin_policy_lifecycle=4`, and the fixture user absent afterward. If the shared-local-DB prerequisite is absent, capture that blocker exactly.

---

### Task 6: Evidence-Backed STATUS, Final Review, Integration, and Push Checkpoint

**Files:**

- Modify only now: `docs/superpowers/STATUS.md`
- Review: `README.md`, STATUS, full `c86b51dc..HEAD`

- [ ] **Step 1: Update STATUS only after every Task 5 gate has evidence**

Before editing STATUS, prove the reviewed implementation HEAD is unchanged and the tree is clean:

```powershell
if ([string]::IsNullOrWhiteSpace($env:MAXIO_S2A_APPROVED_HEAD)) { throw 'approved HEAD evidence is required before STATUS' }
if ((git rev-parse HEAD) -ne $env:MAXIO_S2A_APPROVED_HEAD) { throw 'implementation HEAD changed after review/gates' }
if (git status --porcelain) { throw 'STATUS may start only from the final clean reviewed tree' }
```

Only then edit STATUS. It records exact U3 route/action/plaintext 200 contract; UserInfo field/omit rules; IAM-only adapter; partial-view logging/CLI; V-B17; U1/U2/U4/U5 501; focused/compile/format/diff/precommit results; independent APPROVED verdict and SHA; and real mc/external-smoke pass or precise prerequisite blocker. Do not claim U3 live compatibility if either live gate was blocked.

- [ ] **Step 2: Commit STATUS as the final branch commit**

```powershell
if (git diff --cached --name-only) { throw 'unexpected staged changes before STATUS commit' }
$unstaged=@(git diff --name-only)
$untracked=@(git ls-files --others --exclude-standard)
if ($unstaged.Count -ne 1 -or $unstaged[0] -ne 'docs/superpowers/STATUS.md' -or $untracked.Count -ne 0) {
  throw "STATUS must be the only dirty path; unstaged=$($unstaged -join ','); untracked=$($untracked -join ',')"
}
git diff --check
git add docs/superpowers/STATUS.md
if (git diff --name-only) { throw 'unstaged changes remain after staging STATUS' }
$staged=@(git diff --cached --name-only)
if ($staged.Count -ne 1 -or $staged[0] -ne 'docs/superpowers/STATUS.md') { throw 'staged diff is not STATUS-only' }
git diff --cached --check
git commit -m "docs(status): record admin user S2a evidence"
git diff --check c86b51dc..HEAD
if (git status --porcelain) { throw 'STATUS commit left a dirty tree' }
```

Expected: clean tree and no diff errors.

- [ ] **Step 3: Independent final reviewer verifies claims against captured evidence**

```powershell
if ((git rev-parse HEAD^) -ne $env:MAXIO_S2A_APPROVED_HEAD) { throw 'final commit is not directly atop reviewed implementation HEAD' }
if (git status --porcelain) { throw 'final review requires a clean tree' }
git diff c86b51dc..HEAD -- README.md docs/superpowers/STATUS.md
git log --oneline --decorate c86b51dc..HEAD
git status --short --branch
```

Expected: final APPROVED; STATUS distinguishes verified passes from blockers and makes no U4/U5 claim.

- [ ] **Step 4: Fast-forward and push only with coordinator authorization**

After reporting commit list, reviewer verdict, focused/precommit/live evidence to the coordinating agent:

```powershell
$repo='C:\Users\DYZ\Documents\dev\hemifuture\maxio'
if (git -C $repo status --porcelain) { throw 'primary worktree is not clean' }
if ((git -C $repo rev-parse master) -ne 'c86b51dc078459e44e7ee700ade06e7e481f3a1f') { throw 'master moved; re-review before integration' }
git -C $repo merge --ff-only codex/admin-user-s2
git -C $repo push origin master
```

Expected: clean fast-forward with no merge commit. Do not rebase, force-push, open a PR, or publish before authorization.

## Final Acceptance Checklist

- [ ] Independent spec review GO preceded implementation; the plan is the first commit after fixed `c86b51dc`.
- [ ] Only U3 is implemented; U1/U2/U4/U5 remain authenticated JSON 501.
- [ ] U3 requires exact `admin:GetUser`, strict plaintext JSON 200, and full authorization even for self-read.
- [ ] Missing/empty/invalid input is 400; absent user is exact `XMinioAdminNoSuchUser`/404.
- [ ] UserInfo always has enabled/disabled status, conditionally has direct-managed `policyName`, sorted `memberOf`, and exact UTC ISO `updatedAt`, and never has secrets/auth info.
- [ ] Omitted policy sources are visible only as safe counts/names/ARNs in structured log/CLI evidence; no document or credential leaks.
- [ ] UserAdapter calls public Maxio.IAM only; Plug has no persistence or projection logic.
- [ ] Root/Deny/STS/bucket-policy authorization boundaries remain S1 behavior.
- [ ] One-step mc smoke uses an IAM-created target, runs only user info, and always uses the existing IAM cleanup path.
- [ ] Independent code review APPROVED; focused gate, warnings-as-errors, format, diff check, and exactly one final precommit passed.
- [ ] STATUS was updated only after evidence and accurately separates pass from blocker.
- [ ] Final clean branch was fast-forwarded and pushed only after coordinator authorization.
