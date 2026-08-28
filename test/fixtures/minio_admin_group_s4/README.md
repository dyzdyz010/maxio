# MinIO Admin Group S4 pinned evidence

This directory freezes the source-derived contract for the four MinIO Admin v3
group routes used by `mc admin group add/remove/info/list/enable/disable`. The
fixtures contain no credentials, perform no live mutation, and are not evidence
that Maxio has implemented or passed the contract.

## Fixed provenance

- MinIO commit `7aac2a2c5b7c882e68c1ce017d8256be2feea27f`.
- madmin-go tag `v3.0.109`, commit
  `6897865311e2be91d814ea0ef4814a730d87d1cd`.
- mc commit `77f82e18b5401a65958f1619df6ebb994634bd88`.
- mc's selected madmin pseudo-version commit
  `4b504b82db633e978a57d49443b2be75824244c3`. Its
  `group-commands.go`, `api.go`, and `utils.go` are byte-identical to the
  corresponding files at madmin-go v3.0.109.
- MinIO's selected `github.com/minio/pkg/v3 v3.1.3`, tag commit
  `63a2eac5884b50aede4df00b84d16060dfd6791d`, supplies the literal group
  admin action strings.
- MinIO's selected `github.com/minio/minio-go/v7 v7.0.91` supplies the sorted
  `StringSet.ToSlice` behavior used after an existing-group set mutation.

All links below are commit- or tag-pinned. A moving branch is not an oracle for
this batch.

## Source index

| Repository | Symbol / lines | Frozen meaning |
| --- | --- | --- |
| MinIO | [`adminRouter`, `cmd/admin-router.go:280-290`](https://github.com/minio/minio/blob/7aac2a2c5b7c882e68c1ce017d8256be2feea27f/cmd/admin-router.go#L280-L290) | exact four methods, paths, and required queries |
| MinIO | [`UpdateGroupMembers`, `cmd/admin-handlers-users.go:229-304`](https://github.com/minio/minio/blob/7aac2a2c5b7c882e68c1ce017d8256be2feea27f/cmd/admin-handlers-users.go#L229-L304) | AddUserToGroup action, plaintext body, member precheck, ignored `groupStatus`, empty success |
| MinIO | [`GetGroup`, `ListGroups`, `SetGroupStatus`, `cmd/admin-handlers-users.go:306-398`](https://github.com/minio/minio/blob/7aac2a2c5b7c882e68c1ce017d8256be2feea27f/cmd/admin-handlers-users.go#L306-L398) | read/status actions, JSON reads, status validation, empty status success |
| MinIO | [`validateAdminReq`, `cmd/admin-handler-utils.go:33-60`](https://github.com/minio/minio/blob/7aac2a2c5b7c882e68c1ce017d8256be2feea27f/cmd/admin-handler-utils.go#L33-L60) | multiple supplied actions are OR; these handlers each supply one action |
| MinIO | [`GroupInfo`, `newGroupInfo`, `cmd/iam-store.go:170-179`](https://github.com/minio/minio/blob/7aac2a2c5b7c882e68c1ce017d8256be2feea27f/cmd/iam-store.go#L170-L179) | fresh create preserves the raw member slice and enables the group |
| MinIO | [`AddUsersToGroup`, `cmd/iam-store.go:857-907`](https://github.com/minio/minio/blob/7aac2a2c5b7c882e68c1ce017d8256be2feea27f/cmd/iam-store.go#L857-L907) | user validation, create-or-add, existing-group set normalization, exclusive lock |
| MinIO | [`RemoveUsersFromGroup`, `cmd/iam-store.go:909-995`](https://github.com/minio/minio/blob/7aac2a2c5b7c882e68c1ce017d8256be2feea27f/cmd/iam-store.go#L909-L995) | empty-name then user-before-group precedence, set removal, delete-empty cleanup, timestamp save/cache split |
| MinIO | [`SetGroupStatus`, `GetGroupDescription`, `cmd/iam-store.go:997-1058`](https://github.com/minio/minio/blob/7aac2a2c5b7c882e68c1ce017d8256be2feea27f/cmd/iam-store.go#L997-L1058) | same-status write and exact `GroupDesc` projection |
| MinIO | [`ListGroups`, `cmd/iam-store.go:1061-1112`](https://github.com/minio/minio/blob/7aac2a2c5b7c882e68c1ce017d8256be2feea27f/cmd/iam-store.go#L1061-L1112) | group-name set projection and exclusive refresh lock |
| MinIO | [`writeResponse`, `writeSuccessResponseJSON`, `cmd/api-response.go:891-933`](https://github.com/minio/minio/blob/7aac2a2c5b7c882e68c1ce017d8256be2feea27f/cmd/api-response.go#L891-L933) | explicit JSON Content-Type/Content-Length for G1/G2 |
| MinIO | [`APIErrorResponse`, `cmd/api-errors.go:63-76`](https://github.com/minio/minio/blob/7aac2a2c5b7c882e68c1ce017d8256be2feea27f/cmd/api-errors.go#L63-L76) | Admin JSON error field names and omissions |
| MinIO | [`group errors`, `cmd/api-errors.go:1354-1398`](https://github.com/minio/minio/blob/7aac2a2c5b7c882e68c1ce017d8256be2feea27f/cmd/api-errors.go#L1354-L1398) | exact no-user/no-group/not-empty/invalid-argument public errors |
| MinIO | [`resource/group errors`, `cmd/api-errors.go:2072-2075,2137-2140`](https://github.com/minio/minio/blob/7aac2a2c5b7c882e68c1ce017d8256be2feea27f/cmd/api-errors.go#L2072-L2075) | surrounding-space resource error; reserved-character group error is at 2137-2140 |
| MinIO | [`errIAMActionNotAllowed`, `cmd/typed-errors.go:108-110`](https://github.com/minio/minio/blob/7aac2a2c5b7c882e68c1ce017d8256be2feea27f/cmd/typed-errors.go#L108-L110) | exact IAM action-not-allowed message |
| madmin-go | [`GroupAddRemove`, group client methods, `group-commands.go:31-169`](https://github.com/minio/madmin-go/blob/6897865311e2be91d814ea0ef4814a730d87d1cd/group-commands.go#L31-L169) | exact JSON keys, no `omitempty`, methods, paths, queries, status values, status-200 requirement |
| madmin-go | [`newRequest`, `api.go:502-544`](https://github.com/minio/madmin-go/blob/6897865311e2be91d814ea0ef4814a730d87d1cd/api.go#L502-L544) | no automatic request Content-Type; positive content sets exact ContentLength; SigV4 body hash |
| madmin-go | [`AdminAPIVersion`, `utils.go:38-44`](https://github.com/minio/madmin-go/blob/6897865311e2be91d814ea0ef4814a730d87d1cd/utils.go#L38-L44) | `/v3` relative API prefix |
| minio/pkg | [`AdminAction` group constants, `policy/admin-action.go:126-137`](https://github.com/minio/pkg/blob/63a2eac5884b50aede4df00b84d16060dfd6791d/policy/admin-action.go#L126-L137) | literal add/remove/get/list/enable/disable action strings |
| minio-go | [`StringSet.ToSlice`, `pkg/set/stringset.go:30-38`](https://github.com/minio/minio-go/blob/v7.0.91/pkg/set/stringset.go#L30-L38) | set conversion is lexicographically sorted |
| mc | [`groupMessage`, add command, `cmd/admin-group-add.go:32-149`](https://github.com/minio/mc/blob/77f82e18b5401a65958f1619df6ebb994634bd88/cmd/admin-group-add.go#L32-L149) | add argv, request construction, all human/JSON renderers |
| mc | [`remove`, `cmd/admin-group-remove.go:28-95`](https://github.com/minio/mc/blob/77f82e18b5401a65958f1619df6ebb994634bd88/cmd/admin-group-remove.go#L28-L95) | remove/rm argv and empty-members delete request |
| mc | [`info`, `cmd/admin-group-info.go:27-82`](https://github.com/minio/mc/blob/77f82e18b5401a65958f1619df6ebb994634bd88/cmd/admin-group-info.go#L27-L82) | exact info argv and projection into `groupMessage` |
| mc | [`list`, `cmd/admin-group-list.go:27-79`](https://github.com/minio/mc/blob/77f82e18b5401a65958f1619df6ebb994634bd88/cmd/admin-group-list.go#L27-L79) | list/ls argv and output |
| mc | [`enable/disable`, `cmd/admin-group-enable.go:28-90`](https://github.com/minio/mc/blob/77f82e18b5401a65958f1619df6ebb994634bd88/cmd/admin-group-enable.go#L28-L90) | exact status argv and output; disable command registration is in `admin-group-disable.go:24-44` |
| mc | [`setGlobalsFromContext`, `cmd/globals.go:125-139`](https://github.com/minio/mc/blob/77f82e18b5401a65958f1619df6ebb994634bd88/cmd/globals.go#L125-L139) | `--json` is compacted only for non-TTY stdout |
| mc | [`printMsg`, `cmd/print.go:28-50`](https://github.com/minio/mc/blob/77f82e18b5401a65958f1619df6ebb994634bd88/cmd/print.go#L28-L50) | optional JSON compaction, trims one existing LF, then emits exactly one LF |

## Frozen adjudications

- G1 is `GET /minio/admin/v3/groups` with only `admin:ListGroups`. G2 is
  `GET /minio/admin/v3/group?group=NAME` with only `admin:GetGroup`. Both
  responses are plaintext JSON with explicit `Content-Type: application/json`
  and exact encoded-byte `Content-Length`.
- G3 is `PUT /minio/admin/v3/update-group-members`. Add and remove both require
  only `admin:AddUserToGroup`; the defined `admin:RemoveUserFromGroup` action is
  not used by this handler. The body is plaintext `GroupAddRemove` JSON with no
  envelope. madmin sets no Content-Type and, for this positive-length body,
  sets ContentLength to the exact JSON byte length.
- G4 is `PUT /minio/admin/v3/set-group-status?group=NAME&status=enabled|disabled`.
  Enable and disable both require only `admin:EnableGroup`; the defined
  `admin:DisableGroup` action is not used. The handler does not read a body.
- G3 and G4 success paths do not call a response writer: they are implicit
  empty 200 responses with no explicit JSON Content-Type. The madmin methods
  require status 200, not 204.
- `groupStatus` has no `omitempty`. Pinned mc add/remove leave it empty, so it
  is serialized as `"groupStatus":""`. The local MinIO membership handler
  accepts any JSON string and does not apply it to group status; it survives
  only as site-replication hook data. Maxio records non-empty input as ignored
  evidence, and G4 remains the only local status writer.
- Add is create-or-add-members. A missing group is created enabled. Existing
  membership and duplicate requested members succeed. Removing an existing
  user who is not a member succeeds. Member removal down to zero does not
  delete the group; a separate remove request with an empty member array deletes
  only an already-empty group and also removes its mapped policy.
- Same-member add and same-status writes refresh `UpdatedAt`. Delete-empty is
  not sequentially idempotent: the first request succeeds and the next sees
  no group. Mutations hold the process-local IAM store exclusive lock; there is
  no request idempotency key or conditional version header.
- After authentication and the single action gate, G3 orders body read/JSON
  errors before request-order temp/root prechecks. In remove, those prechecks
  precede the empty-group error. For a non-empty group, user existence and
  service-account eligibility precede group lookup. Consequently
  missing-user plus missing-group is NoSuchUser, while empty-group plus a
  missing ordinary user is InvalidArgument. Invalid G4 status precedes missing
  group.
- G1 group names are sorted. Policy names are stored/projected in stable order.
  Upstream member order has the deliberate split recorded below.
- All group request and success payloads are plaintext at the Admin API
  application layer. TLS and SigV4 still protect/authenticate the transport;
  “plaintext” here means there is no madmin `EncryptData`/`DecryptData`
  envelope.

## Exactly four VERIFY-AT-IMPL boundaries

These are the only dynamic claims in this fixture set. Until their named live
captures exist, source inference, a fake runner, or an expected transcript must
not be reported as observed parity.

1. `set_status_actual_framing`: capture the signed request emitted by the pinned
   native mc/madmin path and record whether Content-Length is present and its
   value, or whether another Go transport framing is used. Maxio must not add a
   gate based on a speculative result.
2. `cross_node_group_race`: with two safe nodes sharing isolated persistence,
   race same-name create/add/remove and record both client results and final
   state. Process-local source locking is not a distributed CAS guarantee.
3. `absent_remove_updated_at_cross_node_reload`: on two safe pinned upstream
   nodes, remove an already-absent member and read/reload through the other node
   to determine whether old persisted or fresh cache/return `UpdatedAt` wins.
4. `dynamic_mc_fatal_output`: trigger safe missing-group, missing-user,
   invalid-status, and group-not-empty failures with pinned native mc; record
   actual stderr and exit code. Source-pinned fatal prefixes are not a complete
   dynamic transcript.

## Exactly two deliberate Maxio deviations

1. `maxio-sorted-unique-members`: upstream fresh group creation stores the raw
   request slice, preserving order and duplicates; an existing-group add/remove
   later converts through a sorted set. Maxio's unique membership relation
   cannot represent duplicate rows, so Maxio validates in request order and
   then always projects sorted unique members. This is a tested, wire-visible
   model divergence, not member-order parity.
2. `maxio-persist-fresh-absent-remove-updated-at`: upstream member removal calls
   `saveGroupInfo` before assigning fresh `gi.UpdatedAt`, then exposes the fresh
   value through return/cache. Maxio deliberately persists the fresh timestamp
   so database reload and local state agree. This stronger consistency rule is
   not exact upstream persistence parity.

The bounded Maxio G3 body reader (`262272` bytes, structured
`XMinioAdminConfigTooLarge`) is a local safety contract required by the project.
It does not imply that the pinned upstream handler, which calls `io.ReadAll`,
has the same limit, and it must not become a Content-Type gate.

## File guide

- `minio_routes_and_errors.json`: routes/actions, success transport, lifecycle,
  exact public errors, precedence, locking/idempotency, four VERIFY boundaries,
  and two deliberate deviations.
- `madmin_group_wire.json`: Go JSON types, exact request/response bytes, byte
  lengths, no-envelope decision, and source-level framing facts.
- `mc_group_human.json`: exact argv, human stdout including the empty-list LF,
  and source-pinned fatal prefixes separated from dynamic stderr.
- `mc_group_json.json`: exact non-TTY compact and TTY pretty JSON bytes, field
  order/omission, argv, and one trailing LF.

## Verification

From the `admin-group-s4` worktree:

```powershell
$files = @(
  'test/fixtures/minio_admin_group_s4/minio_routes_and_errors.json',
  'test/fixtures/minio_admin_group_s4/madmin_group_wire.json',
  'test/fixtures/minio_admin_group_s4/mc_group_human.json',
  'test/fixtures/minio_admin_group_s4/mc_group_json.json'
)
foreach ($file in $files) {
  $null = Get-Content -Raw -LiteralPath $file | ConvertFrom-Json
}
mix test test/maxio/admin/group_protocol_fixture_test.exs --exclude group_request_red
mix test test/maxio/admin/group_protocol_fixture_test.exs
```

The first Mix command must pass every source/fixture assertion. Before Task 2,
the second command must have exactly one RED failure caused by the absent
production `Maxio.Admin.GroupRequest` module; no fixture assertion may fail.
