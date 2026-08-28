# MinIO Admin Policy S3 pinned evidence

This directory freezes the source-derived contract for builtin policy association
mutation (P6), policy-entity projection (P7), and the corresponding `mc admin
policy` commands. It contains no credentials and makes no live-compatibility
claim.

## Fixed provenance

- MinIO commit `7aac2a2c5b7c882e68c1ce017d8256be2feea27f`.
- madmin-go tag `v3.0.109`, commit
  `6897865311e2be91d814ea0ef4814a730d87d1cd`.
- mc commit `77f82e18b5401a65958f1619df6ebb994634bd88`.
- mc's madmin pseudo-version commit
  `4b504b82db633e978a57d49443b2be75824244c3`; the relevant policy command
  structures are byte-equivalent to madmin-go v3.0.109.
- MinIO's selected `github.com/minio/pkg/v3 v3.1.3`, tag commit
  `63a2eac5884b50aede4df00b84d16060dfd6791d`, supplies the literal admin
  action strings.

All links below are commit-pinned. Line ranges describe the semantics frozen in
the JSON fixtures; a moving branch is not an oracle for this batch.

## Source index

| Repository | Symbol / lines | Frozen meaning |
| --- | --- | --- |
| MinIO | [`adminRouter` registration, `cmd/admin-router.go:257-269`](https://github.com/minio/minio/blob/7aac2a2c5b7c882e68c1ce017d8256be2feea27f/cmd/admin-router.go#L257-L269) | exact GET P7 and generic POST P6 routes |
| MinIO | [`ListPolicyMappingEntities`, `cmd/admin-handlers-users.go:1866-1903`](https://github.com/minio/minio/blob/7aac2a2c5b7c882e68c1ce017d8256be2feea27f/cmd/admin-handlers-users.go#L1866-L1903) | P7 OR auth, repeated form values, encrypted JSON response |
| MinIO | [`AttachDetachPolicyBuiltin`, `cmd/admin-handlers-users.go:1906-1991`](https://github.com/minio/minio/blob/7aac2a2c5b7c882e68c1ce017d8256be2feea27f/cmd/admin-handlers-users.go#L1906-L1991) | P6 auth, CL/CT gates, operation order, decrypt, validation, encrypted result |
| MinIO | [`validateAdminReq`, `cmd/admin-handler-utils.go:33-60`](https://github.com/minio/minio/blob/7aac2a2c5b7c882e68c1ce017d8256be2feea27f/cmd/admin-handler-utils.go#L33-L60) | action list is authorized with first-success OR semantics |
| MinIO | [`maxEConfigJSONSize`, `cmd/admin-handlers.go:69-71`](https://github.com/minio/minio/blob/7aac2a2c5b7c882e68c1ce017d8256be2feea27f/cmd/admin-handlers.go#L69-L71) | encrypted request cap is exactly 262272 bytes |
| MinIO | [`PolicyDBUpdateBuiltin`, `cmd/iam.go:2004-2080`](https://github.com/minio/minio/blob/7aac2a2c5b7c882e68c1ce017d8256be2feea27f/cmd/iam.go#L2004-L2080) | target order: group description; or temp, root, user existence |
| MinIO | [`PolicyDBUpdate`, `cmd/iam-store.go:1134-1240`](https://github.com/minio/minio/blob/7aac2a2c5b7c882e68c1ce017d8256be2feea27f/cmd/iam-store.go#L1134-L1240) | group existence/status, attach lookup, detach intersection, no-effect, changed set |
| MinIO | [`ListPolicyMappings`, `cmd/iam-store.go:2238-2519`](https://github.com/minio/minio/blob/7aac2a2c5b7c882e68c1ce017d8256be2feea27f/cmd/iam-store.go#L2238-L2519) | omission, sorting, empty-query projection, and persisted STS-user mappings |
| MinIO | [`QueryPolicyEntities`, `cmd/iam.go:994-1017`](https://github.com/minio/minio/blob/7aac2a2c5b7c882e68c1ce017d8256be2feea27f/cmd/iam.go#L994-L1017) | normalized query and one response timestamp |
| MinIO | [`ErrAdminPolicyChangeAlreadyApplied`, `cmd/api-errors.go:1389-1398`](https://github.com/minio/minio/blob/7aac2a2c5b7c882e68c1ce017d8256be2feea27f/cmd/api-errors.go#L1389-L1398) | exact no-effect and invalid-argument public codes/status/descriptions |
| madmin-go | [`PolicyEntitiesResult` types, `idp-commands.go:278-310`](https://github.com/minio/madmin-go/blob/6897865311e2be91d814ea0ef4814a730d87d1cd/idp-commands.go#L278-L310) | top-level `omitempty`; inner slices are not `omitempty` |
| madmin-go | [`PolicyAssociationReq.IsValid`, `idp-commands.go:346-383`](https://github.com/minio/madmin-go/blob/6897865311e2be91d814ea0ef4814a730d87d1cd/idp-commands.go#L346-L383) | exact request/response keys and request validation order |
| madmin-go | [`attachOrDetachPolicyBuiltin`, `policy-commands.go:234-302`](https://github.com/minio/madmin-go/blob/6897865311e2be91d814ea0ef4814a730d87d1cd/policy-commands.go#L234-L302) | request encryption, exact CT, POST path, response decryption |
| madmin-go | [`GetPolicyEntities`, `policy-commands.go:305-333`](https://github.com/minio/madmin-go/blob/6897865311e2be91d814ea0ef4814a730d87d1cd/policy-commands.go#L305-L333) | repeatable query construction and encrypted response |
| minio/pkg | [`AdminAction` constants, `policy/admin-action.go:85-153`](https://github.com/minio/pkg/blob/63a2eac5884b50aede4df00b84d16060dfd6791d/policy/admin-action.go#L85-L153) | literal P6/P7 admin action names |
| mc | [`userAttachOrDetachPolicy`, `cmd/admin-policy-attach.go:70-130`](https://github.com/minio/mc/blob/77f82e18b5401a65958f1619df6ebb994634bd88/cmd/admin-policy-attach.go#L70-L130) | argv, no-effect swallowing, original-list synthesis |
| mc | [`policyAssociationMessage`, `cmd/idp-ldap-policy-subcommands.go:119-157`](https://github.com/minio/mc/blob/77f82e18b5401a65958f1619df6ebb994634bd88/cmd/idp-ldap-policy-subcommands.go#L119-L157) | exact human labels and one-space JSON indentation |
| mc | [`mainAdminPolicyEntities`, `cmd/admin-policy-entities.go:26-99`](https://github.com/minio/mc/blob/77f82e18b5401a65958f1619df6ebb994634bd88/cmd/admin-policy-entities.go#L26-L99) | repeatable CLI filters and target arity |
| mc | [`policyEntities`, `cmd/idp-ldap-policy-subcommands.go:331-449`](https://github.com/minio/mc/blob/77f82e18b5401a65958f1619df6ebb994634bd88/cmd/idp-ldap-policy-subcommands.go#L331-L449) | JSON wrapper, two-space indentation, human rendering |
| mc | [`printMsg`, `cmd/print.go:28-50`](https://github.com/minio/mc/blob/77f82e18b5401a65958f1619df6ebb994634bd88/cmd/print.go#L28-L50) | trims an existing final LF then emits exactly one LF |

## Frozen contract adjudications

- P6 is `POST /minio/admin/v3/idp/builtin/policy/{attach|detach}`. Authorization
  is `admin:UpdatePolicyAssociation` OR legacy
  `admin:AttachUserOrGroupPolicy`.
- P6 authenticates first, then checks known `Content-Length <= 262272`, then
  exact `Content-Type: application/octet-stream`, then validates the operation.
  Unknown operations do not decrypt. A known operation with length zero reaches
  decrypt naturally.
- After decrypt/JSON decode, ordering is `PolicyAssociationReq.IsValid` -> target
  checks -> operation-specific policy/no-effect checks. Attach validates each
  net-new policy exists. Detach does not look up requested policies; it removes
  the intersection with current attachments.
- A successful P6 result contains the actual changed, de-duplicated,
  lexicographically sorted policy names and `updatedAt`. Sequential repetition
  is not a successful server idempotency response: it is
  `400 XMinioAdminPolicyChangeAlreadyApplied` with no write. Pinned mc catches
  that code and prints success synthesized from the original argv policy slice,
  preserving order and duplicates.
- P7 is `GET /minio/admin/v3/idp/builtin/policy-entities`. Authorization is
  `admin:ListGroups` OR `admin:ListUsers` OR `admin:ListUserPolicies`.
  `user`, `group`, and `policy` are repeatable and may be mixed. Duplicates are
  normalized away. Unknown/unmapped values are omitted without error.
- With no filters P7 enables only the policy-to-entity projection. If no mapping
  exists, the JSON plaintext contains only `timestamp`. Empty top-level mapping
  slices are omitted, while the non-omitempty inner `policies`, `users`, and
  `groups` slices encode as `null` when nil. All mapping records and populated
  nested lists are lexicographically sorted.
- Upstream includes persisted STS-user policy mappings in P7 policy projection
  (`iam-store.go:2378-2438`). Maxio's current model cannot represent that
  relation, so `p7-persisted-sts-user-policy-mapping` is an explicit,
  wire-visible `model_scope_deviation`, not an ordinary omission and not a full
  parity claim.
- Maxio deliberately does not reproduce the upstream bad-envelope 500 or the
  disabled-group 500: the selected structured responses are recorded in the P6
  fixture. Zero length uses the same bad-envelope 400 but should preferably reach
  decrypt naturally.

The only unresolved wire boundary in this evidence pack is malformed percent
encoding in the raw P7 query string. It remains **VERIFY-AT-IMPL**. If Maxio
chooses a structured 400 before compatible evidence is available, that behavior
must be documented as a defense deviation. No other fixture field is provisional.

## Canonical mc output

The text samples are UTF-8 with LF line endings, non-TTY/no-ANSI, and include
the exactly one trailing LF emitted by `printMsg`. `mc --json` for association
uses one-space indentation; entities uses two-space indentation. These are
source-derived expected contracts, not observed live transcripts.

## Verification

```powershell
$files = @(
  'test/fixtures/minio_admin_policy_s3/minio_p6_policy_association.json',
  'test/fixtures/minio_admin_policy_s3/minio_p7_policy_entities.json',
  'test/fixtures/minio_admin_policy_s3/mc_policy_lifecycle.json'
)
foreach ($file in $files) {
  $null = Get-Content -Raw -LiteralPath $file | ConvertFrom-Json
}
mix test test/maxio/admin/policy_association_request_test.exs test/maxio/admin/policy_entities_request_test.exs
```
