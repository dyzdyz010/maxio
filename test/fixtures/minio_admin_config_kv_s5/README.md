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

Only commit-pinned official GitHub raw source was used. Every copied excerpt
below has a separately frozen raw-file SHA-256 and copied-excerpt SHA-256 in
`minio_routes_and_errors.json`; the test freezes the complete digest map.

| ID | Repository / full SHA | Exact file, function, lines | Copied excerpt SHA-256 |
| --- | --- | --- | --- |
| `minio_router_config_kv_routes` | MinIO `7aac2a2c5b7c882e68c1ce017d8256be2feea27f` | `cmd/admin-router.go`, `adminRouter`, 202-204 | `cd7845d7e2019e47e63f5a5906c465bb160f4a9903211f0a219a705833117050` |
| `minio_del_config_kv_action_and_decrypt` | MinIO `7aac2a2c5b7c882e68c1ce017d8256be2feea27f` | `cmd/admin-handlers-config-kv.go`, `DelConfigKVHandler`, 43-69 | `7c7fd960f0e2f88fad3809b1e4900d101ec139c0e9595ea36821dea3add20307` |
| `minio_set_config_kv_action_and_decrypt` | MinIO `7aac2a2c5b7c882e68c1ce017d8256be2feea27f` | `cmd/admin-handlers-config-kv.go`, `SetConfigKVHandler`, 147-176 | `80f8af1c1a2e2dc3518e86249a9a439e546f995479be29c9f2e4d1566617acb1` |
| `minio_get_config_kv_action` | MinIO `7aac2a2c5b7c882e68c1ce017d8256be2feea27f` | `cmd/admin-handlers-config-kv.go`, `GetConfigKVHandler`, 233-247 | `c4183540d0a0395e62932d2dac4e8276790149e4c04b4775cd0eda422cd81fc3` |
| `minio_subsys_info_write_to` | MinIO `7aac2a2c5b7c882e68c1ce017d8256be2feea27f` | `internal/config/config.go`, `(*SubsysInfo).WriteTo`, 1447-1477 | `3e0c076b97d4150a5d40d17279b35c8f7e18fe0e65f7915d29f7b09c9f9cf04b` |
| `madmin_del_config_kv_wire` | madmin-go `4b504b82db633e978a57d49443b2be75824244c3` | `config-kv-commands.go`, `DelConfigKV`, 28-60 | `e5eeb324cd5281b797e0925644f4abbdec8a0153daf6750a58cf96c492afb02d` |
| `madmin_set_config_kv_wire` | madmin-go `4b504b82db633e978a57d49443b2be75824244c3` | `config-kv-commands.go`, `SetConfigKV`, 63-88 | `115e8d856da915da1a3539dc3932e3068c676dc95a1364de7a4aa4a5f86229ec` |
| `madmin_get_config_kv_wire` | madmin-go `4b504b82db633e978a57d49443b2be75824244c3` | `config-kv-commands.go`, `GetConfigKV`, 90-112 | `53d5df7f4c3a488e8df181a576c70756a64f07c6cdcb2d1fd2a2fc6f31ca1c11` |
| `madmin_new_request_entity_headers` | madmin-go `4b504b82db633e978a57d49443b2be75824244c3` | `api.go`, `newRequest`, 495-544 | `004ac16858b362fd7705774d5881af72e2d0e4a9ed9fb7f9462b34a3eff071e0` |
| `mc_print_non_tty_compaction` | mc `77f82e18b5401a65958f1619df6ebb994634bd88` | `cmd/print.go`, `printMsg`, 34-51 | `96338ddfe75ded06aeeecaa0572d236edf5904480a72492f5619382f291f4aa3` |
| `mc_config_get_rendering` | mc `77f82e18b5401a65958f1619df6ebb994634bd88` | `cmd/admin-config-get.go`, `configGetMessage`, 74-108 | `48e2f3cad229a128306ba2dd0b0f2ed9edd06ebeabee7c69b4dfa8024f3f844f` |
| `mc_config_get_help_branch` | mc `77f82e18b5401a65958f1619df6ebb994634bd88` | `cmd/admin-config-get.go`, `mainAdminConfigGet`, 118-147 | `a4797b0e56f8a74668fcd746bb34cf56de54eb9160998a06833fd3a13aaefba3` |
| `mc_config_set_rendering` | mc `77f82e18b5401a65958f1619df6ebb994634bd88` | `cmd/admin-config-set.go`, `configSetMessage`, 67-85 | `d4ded1439ba1303de5198c525123fdc8586e8546ac3a22558c40f6bd4bc6839c` |
| `mc_config_set_help_branch` | mc `77f82e18b5401a65958f1619df6ebb994634bd88` | `cmd/admin-config-set.go`, `mainAdminConfigSet`, 95-124 | `a9e49de1465f0fef984c67c06a88b0e815136c63acea9b3809453da19a22ae03` |
| `mc_config_reset_rendering` | mc `77f82e18b5401a65958f1619df6ebb994634bd88` | `cmd/admin-config-reset.go`, `configResetMessage`, 72-90 | `dd7590ee93ea4c1662462b6803dfeb1d4ea7adc307534491930405559fd94016` |
| `mc_config_reset_help_branch` | mc `77f82e18b5401a65958f1619df6ebb994634bd88` | `cmd/admin-config-reset.go`, `mainAdminConfigReset`, 100-129 | `1cec7998d65c252a6e100b46e8854b3d0460db8dbf5dc9143efc9e9665af72e6` |

## Fixture field-to-excerpt mapping

| Fixture field(s) | Source excerpt IDs |
| --- | --- |
| `minio_routes_and_errors.json.routes`, `query_branches`, `error_precedence`, `errors`, `same_body_reset`, `deliberate_deviations`, `unsupported_catalog_claims` | `minio_router_config_kv_routes`, `minio_del_config_kv_action_and_decrypt`, `minio_set_config_kv_action_and_decrypt`, `minio_get_config_kv_action` |
| `madmin_config_kv_wire.json.ciphertext_*`, `entity_matrix`, `applied_header`, `request_builder` | `madmin_del_config_kv_wire`, `madmin_set_config_kv_wire`, `madmin_get_config_kv_wire`, `madmin_new_request_entity_headers` |
| `mc_config_human.json.stdout`, `argv`, `local_help_or_rejection` | `mc_config_get_rendering`, `mc_config_set_rendering`, `mc_config_reset_rendering`, `mc_config_get_help_branch`, `mc_config_set_help_branch`, `mc_config_reset_help_branch`, `mc_print_non_tty_compaction`, `minio_subsys_info_write_to` |
| `mc_config_json.json.stdout`, `mode`, `argv` | `mc_config_get_rendering`, `mc_config_set_rendering`, `mc_config_reset_rendering`, `mc_print_non_tty_compaction`, `minio_subsys_info_write_to` |

The `get_alias_only` and `reset_alias_only` mappings intentionally remain
`help-config-kv_no_*_http`: after syntax validation, the pinned mc main
functions explicitly call `HelpConfigKV` when there is exactly one argument.
They are not config-endpoint calls.

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
