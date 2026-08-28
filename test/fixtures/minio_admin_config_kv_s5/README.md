# MinIO Admin Config KVS S5 pinned evidence

This directory freezes the source-pinned protocol evidence required before the
Config KVS implementation work starts. It is an integrity gate, not proof that
Maxio implements the protocol or that a MinIO server was contacted.

## Evidence classes and capture boundary

All four JSON files are `source-pinned-derived-not-live-observed`. No packet in
this directory was captured from a live MinIO or Maxio server. The concrete
opaque SIO byte sample in `madmin_config_kv_wire.json` is a deterministic
fixture sentinel for framing assertions only; it is explicitly **not** an
observed packet and must not be used to claim a stable SIO ciphertext (real
encryption uses fresh randomness).

The mc stdout fixtures are derived from the pinned mc renderers under this
capture environment: Windows 11, PowerShell 7, UTF-8, `MC_CONFIG_DIR` isolated,
`--no-color`, stdout non-TTY. Non-TTY is material: `printMsg` compacts JSON and
then emits exactly one LF. Every human/JSON stdout byte is represented both as
a JSON string and Base16 with an explicit UTF-8 length.

## Fixed provenance

| Repository | Full commit |
| --- | --- |
| MinIO | `7aac2a2c5b7c882e68c1ce017d8256be2feea27f` |
| madmin-go | `4b504b82db633e978a57d49443b2be75824244c3` |
| mc | `77f82e18b5401a65958f1619df6ebb994634bd88` |

Only commit-pinned official GitHub raw source was used. Source excerpts are
identified in `minio_routes_and_errors.json` by file, symbol/line range, full
raw-file SHA-256, and copied-excerpt SHA-256. The fixture test freezes the
complete excerpt digest map so a changed record is a visible contract change.

| Source file / function | Copied excerpt SHA-256 |
| --- | --- |
| `cmd/admin-router.go:202-204`, config KVS routes | `cd7845d7e2019e47e63f5a5906c465bb160f4a9903211f0a219a705833117050` |
| `cmd/admin-handlers-config-kv.go:43-69`, `DelConfigKVHandler` | `7c7fd960f0e2f88fad3809b1e4900d101ec139c0e9595ea36821dea3add20307` |
| `cmd/admin-handlers-config-kv.go:147-176`, `SetConfigKVHandler` | `80f8af1c1a2e2dc3518e86249a9a439e546f995479be29c9f2e4d1566617acb1` |
| `cmd/admin-handlers-config-kv.go:233-247`, `GetConfigKVHandler` | `c4183540d0a0395e62932d2dac4e8276790149e4c04b4775cd0eda422cd81fc3` |
| `madmin-go/config-kv-commands.go:28-112`, `DelConfigKV`/`SetConfigKV`/`GetConfigKV` | recorded in the routes fixture |
| `madmin-go/api.go:495-544`, `newRequest` | `004ac16858b362fd7705774d5881af72e2d0e4a9ed9fb7f9462b34a3eff071e0` |
| `mc/cmd/print.go:34-51`, `printMsg` | `96338ddfe75ded06aeeecaa0572d236edf5904480a72492f5619382f291f4aa3` |
| `mc/cmd/admin-config-*.go`, get/set/reset renderers | recorded in the routes fixture |

## Deliberate Maxio deviations

- The pre-existing Admin surface returns unauthenticated Admin requests as 403
  `AccessDenied` rather than exposing the upstream authenticated-only 426 route
  fallback.
- Mutation framing requires exactly one explicit decimal Content-Length and no
  Transfer-Encoding, a stricter safety boundary than the pinned Go handler.
- A reset of the known hidden path `cluster.deployment_id` maps to generic
  `XMinioConfigError` 400, rather than the ordinary exposed-key reset 404.
- The same-body `s3\ns3\n` upstream 400 duplicate behavior is intentionally
  replaced by a successful Maxio full-subsystem reset; an independent retry is
  normally 200 and no-op.
- Maxio commits runtime rows and audit rows atomically, rather than mirroring
  MinIO's separate config/history writes.

## File guide

- `minio_routes_and_errors.json`: route/action/query behavior, precedence,
  public errors, deviations, and unsupported catalog claims.
- `madmin_config_kv_wire.json`: entity-header contracts and opaque byte-length
  framing samples.
- `mc_config_human.json`: non-TTY human stdout and help/local-rejection split.
- `mc_config_json.json`: non-TTY compact JSON stdout, exact LF, and pretty JSON
  rejection.

Run only the evidence gate for this task:

```powershell
mix test test/maxio/admin/config_kv_protocol_fixture_test.exs
```
