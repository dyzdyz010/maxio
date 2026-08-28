# MinIO Admin User S2c pinned evidence

This directory is an evidence-only input for the Maxio S2c U4/U5 implementation. It contains no Elixir code and no live credentials. The records pin upstream behavior instead of treating a moving MinIO or `mc` master as a compatibility oracle.

## Fixed provenance

- MinIO: commit `7aac2a2c5b7c882e68c1ce017d8256be2feea27f`.
- madmin-go: tag `v3.0.109`, commit `6897865311e2be91d814ea0ef4814a730d87d1cd`.
- mc: commit `77f82e18b5401a65958f1619df6ebb994634bd88`.
- mc's own madmin pin: pseudo-version commit `4b504b82db633e978a57d49443b2be75824244c3`. Its U4/U5 `user-commands.go` and request construction are byte-equivalent to the v3.0.109 paths used by the fixed MinIO server.
- mc console dependency: `github.com/minio/pkg/v3 v3.1.0`, commit `e97de32cd9d798d53115b831f4f7c0ad245c7fb2`, module sum `h1:RoR1TMXV5y4LvKPkaB1WoeuM6CO7A+I55xYb1tzrvLQ=`.

Every JSON source entry includes a SHA-256 of the canonical upstream text bytes (LF line endings, no CR conversion) and a commit-pinned GitHub URL. This avoids Windows `core.autocrlf` changing provenance. The hashes can be reproduced from a module-cache copy or by normalizing a fixed checkout to LF before hashing. They are source-provenance hashes, not hashes of the JSON fixture itself.

## What was actually executed

Two kinds of Go evidence were executed against the fixed sources:

1. A madmin v3.0.109 `httptest.Server` wire capture using Go 1.24.2 recorded the exact incoming method, request URI, semantic content length, transfer encoding, content type, and body length for U4 and U5.
2. Temporary tests were added only to a disposable fixed-MinIO upstream clone, using MinIO's existing `TestSuiteIAM`, real admin router/handlers, madmin, and a capturing `RoundTripper`. The MinIO module selected Go 1.24.8. The tests proved:
   - sequential second remove: 404 / `XMinioAdminNoSuchUser` / dynamic no-such-user message;
   - non-self ordinary admin targeting configured root for status: the same 404;
   - configured-root remove by root itself and by a different ordinary admin: the same 404.

The temporary test files were deleted after the run and the upstream clone was verified clean. The JSON records retain redacted structured excerpts and SHA-256 values computed over the listed LF-joined transcript lines with one trailing LF. They do not claim that a committed upstream test exists.

No real `mc` executable lifecycle was run while creating this pack. `mc_user_mutations.json` is a pinned source-derived stdout/stderr/exit contract. Future Maxio external smoke is responsible for producing live `mc` evidence and must not label this source evidence as a live pass.

## Important adjudications

- Sequential HTTP remove is **not idempotent**: the first completed remove is 200; a later second remove is 404. The internal store deletion swallows `errNoSuchUser`, but the HTTP handler's earlier `IsTempUser` lookup returns before that store function is reached.
- Concurrent double remove is ambiguous upstream. Both requests can pass the precheck before either deletion, allowing two 200 responses; otherwise the loser sees 404. This is separate from the deterministic sequential oracle.
- The correct fixed-commit RemoveUser handler is `cmd/admin-handlers-users.go:48-101`. A rejected review citation to `#L2271` was wrong for this commit: line 2271 is `adminLogIf(ctx, err)` in IAM ZIP export code.
- Non-self root status is 404 because root is not in `iamUsersMap`.
- Root remove is also 404 in the fixed server, despite the later explicit root/self action-not-allowed branch. `IsTempUser` runs first and reports root absent, making the root-specific 403 branch unreachable for configured root. Research originally exposed a conflict with the draft plan; the approved plan amendment has since selected MinIO-compatible root 404. This is retained only as decision history, with no unresolved 403/404 implementation choice.
- U5 changes only the regular user status and does not delete derived credentials. Ordinary inherited service accounts and internal `AssumeRole` STS are denied through parent-policy evaluation while the parent is disabled and can recover after re-enable if still active/unexpired.
- U4's fixed cascade implementation is `cmd/iam-store.go:1925-1989`. It removes group memberships, derived service accounts found in `iamUsersMap`, the mapped policy, and the regular identity. Its STS cleanup remains source-ambiguous: ordinary STS are stored in `iamSTSAccountsMap`, while this function scans `iamUsersMap` for descendants even though its inner switch contains an STS branch. The endpoint does not call `RevokeTokens`. This remains `VERIFY-AT-IMPL` and is the reason Maxio's planned permanent descendant revocation is an explicit fail-closed deviation.
- Derived-parent behavior is source-derived, not a live claim. SigV4 parsing resolves the signing access key to a full `auth.Credentials`; `validateAdminReq` returns that same signer credential to the handler. U4/U5 self checks compare the target with `cred.AccessKey`, not `cred.ParentUser`. Therefore an authorized STS signer has a distinct session access key and can target its parent without tripping the self check; normal authorization still must grant the relevant admin action.

## File guide

- `minio_u4_remove_user.json`: DELETE wire shape, handler/store flow, exact errors, cascade, root-order decision history, STS and concurrency ambiguity, and executed transcripts.
- `minio_u5_set_user_status.json`: PUT wire shape, enum/action/self/root behavior, reversible derived-credential effects, same-status write, and executed transcripts.
- `mc_user_mutations.json`: pinned `mc admin user enable|disable|remove` argv, human and JSON stdout, stderr, and exit contracts; explicitly source-derived, not live.

## Verification commands

From the `admin-user-s2c` worktree:

```powershell
$files=@(
  'test/fixtures/minio_admin_user_s2c/minio_u4_remove_user.json',
  'test/fixtures/minio_admin_user_s2c/minio_u5_set_user_status.json',
  'test/fixtures/minio_admin_user_s2c/mc_user_mutations.json'
)
foreach($file in $files) {
  $null=Get-Content -Raw -LiteralPath $file | ConvertFrom-Json
}
git diff --check
git status --porcelain=v1
```

Secret scans must reject access-key values, secret keys, session tokens, Authorization headers, and bearer/JWT material. The only credential-like strings intentionally present are field names, redaction markers, public commit hashes, and the non-secret placeholder `NAME`.
