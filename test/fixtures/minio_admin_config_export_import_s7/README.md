# MinIO Admin Config archive S7 pinned evidence

This directory freezes the Task 1 source and local-design contract for full configuration export
and import over `GET` and `PUT /minio/admin/v3/config`. It does not claim compatibility with
MinIO's full configuration catalog: Maxio S7 exposes only three already-designed extension keys.

## Files and schemas

- `minio_config_archive_wire.json` — `maxio.minio_config_archive_wire.v1`; route, action,
  authorization, HTTP/SIO framing, export codec, import replacement, persistence and the exact
  bounded Maxio payload.
- `madmin_config_archive_limits.json` — `maxio.madmin_config_archive_limits.v1`; client plaintext
  limit, SIO formula and boundary vectors.
- `mc_config_archive_dispatch.json` — `maxio.mc_config_archive_dispatch.v1`; native mc command,
  stdin/file behavior and source-derived output.
- `raw_sha256.json` — `maxio.raw_sha256.v1`; immutable source identities, raw Git-blob hashes,
  inclusive-LF excerpt hashes and claim mappings.

Pinned identities are MinIO `7aac2a2c5b7c882e68c1ce017d8256be2feea27f`, madmin-go
`4b504b82db633e978a57d49443b2be75824244c3`, mc
`77f82e18b5401a65958f1619df6ebb994634bd88`, and the madmin-selected secure-io/sio-go `v0.3.1`
at `a455d2cd8fcacdfe18557d117db15c0629fb7e2c`.

## Evidence classes

- `source_verified` follows directly from pinned official source and its recorded raw/excerpt
  hashes. An upstream compatibility claim may use this class or `live_verified`, never a local
  class.
- `live_verified` is reserved for a real pre-implementation native-process capture with pinned
  binary identity, OS/command, redacted artifact hash and observed result. W5 uses this class only
  for the Windows `mc.exe` process boundary and its stdout/stderr/exit behavior. Its controlled HTTP
  peer is separately labelled `fake_observed`; no real Maxio endpoint behavior is claimed.
- `existing_contract_verified` is behavior already shipped and independently reviewed before S7,
  with a named S5/S6 fixture, test, error symbol or immutable closeout reference. Each Task 6 JSON
  boundary uses a structured `kind: baseline` reference that resolves to a real repository file and
  test id or symbol. It proves only a Maxio contract, not upstream parity, and Task 6 RED must
  re-lock every reused row before Task 7.
- `local_design_expected` is an intentional S7 Maxio choice or repair with a named design/contract
  reference. Each Task 6 JSON boundary uses a structured `kind: design` reference that resolves to
  a real S7 design section. It is never an upstream or live fact, and Task 6 RED plus an independent
  RED review must lock it before Task 7 production starts.
- `VERIFY-AT-IMPL` is an honest pending observation. If it determines implementation, its named
  task gate is blocked until a pre-implementation capture closes it; Task 11 may only reverify.

For Task 6, `task6_entry_gate.decision_documents` names every fixture and JSON-pointer root consumed
by the RED, including the complete W1 limits document, the full W2 condition/precedence matrices,
`precedence_assertion`, ErrorMap `reuse_rule`, and the fresh-archive roots. Every
decision leaf inherits the nearest ancestor `evidence_class`. A list member with no inherited class must declare
its own. The integrity test recursively rejects a missing class, an unknown class and any
`VERIFY-AT-IMPL` below those roots. It also resolves the structured `contract_reference` at every
explicit `existing_contract_verified` or `local_design_expected` boundary. This rule covers the
entire error-condition matrix and every precedence row; an empty `unresolved` array cannot certify
itself. `task6_entry_gate.source_claims` is keyed by explicit `fixture.json#/JSON/pointer` boundary;
each binding has non-empty `claim_ids` and `source_ids` that resolve through
`raw_sha256.json.claim_sources` to immutable pinned raw URLs and verifiable raw/excerpt hashes.
Because the W1 limits document root also asserts MinIO server boundary outcomes, its root binding
includes both the W1 madmin/SIO claim and the W2 MinIO handler/ciphertext-limit claim; child vector
bindings do not substitute for the nearest root boundary.

`PASS_PROVENANCE_COMPLETE_FOR_TASK_6_RED` means only that the fixture is complete enough for the
independent Task 6 test author to write RED. It is not a live or endpoint behavior PASS. Task 7
remains blocked until a separate reviewer confirms that Task 6 RED table-locks every precedence
priority, condition id and named local transport decision.

The fresh Maxio archive is stored as base64 and an escaped rendering, not as a tracked text file
with physical trailing spaces. Tests must decode it and recompute exactly 89 bytes and SHA-256
`c8fe86493cce0083169223b68b59e69612ceeaff7ff45721b45eb85e7eff4141`. Its evidence class is
exactly `local_design_expected`; it is not a universal MinIO default export.

## W1-W5 gate matrix

- W1 — madmin local plaintext limits and SIO frame formula. `PASS_SOURCE_VERIFIED` before endpoint
  RED: for positive `n`, encrypted length is `41+n+16*ceil(n/16384)`.
- W2 — direct server ciphertext limits, framing, authorization precedence and errors.
  `PASS_PROVENANCE_COMPLETE_FOR_TASK_6_RED`: a valid SIO PUT cannot reach a post-decrypt
  plaintext-over-256-KiB branch because the 262272-byte ciphertext gate limits plaintext to
  261975 bytes. A defense-in-depth plaintext guard reuses the existing TooLarge contract as
  `local_design_expected`. Other rows are individually classified as pinned-source facts or
  reviewed existing Maxio contracts. The twelve-stage precedence, auth-before-body ordering,
  postcommit outcome and exact archive response framing are local design contracts that Task 6 RED
  must lock. Anonymous `403/AccessDenied/Access Denied` and path-style Admin `no-transform` are
  separately anchored existing contracts. Unknown-subsystem public/log contracts may retain a safe
  subsystem token but must omit the submitted scalar and plaintext. A valid identity denied
  `admin:ConfigUpdate` receives `AccessDenied`; authentication failures retain their own codes.
- W3 — export bytes and order. `PASS_SOURCE_VERIFIED_WITH_LOCAL_DESIGN_PAYLOAD` before Archive RED.
  A deployment-specific full MinIO default export remains a non-decisional Task 11 observation.
- W4 — import defaults, replacement, duplicates and unknown input. The upstream mechanics are
  `source_verified`; deliberate Maxio target/unknown rejection is `local_design_expected`.
- W5 — native mc dispatch, success, errors and restart output.
  `PASS_SOURCE_AND_WINDOWS_NATIVE_CLIENT_VERIFIED`: pinned source and a native Windows capture close
  the Task 8 entry gate for exact argv, stdin-only import, no file argument, human/JSON stream and
  exit placement, the unconditional restart branch, and canonical root-prefix `--json`. The
  process used a controlled fake HTTP peer, so HTTP request observations are `fake_observed` and
  Task 11 must reverify against the disposable Maxio endpoint without making a first decision.

The W5 binary was built from official mc commit
`77f82e18b5401a65958f1619df6ebb994634bd88` with official Go `1.24.9` for
`windows/amd64`. `mc --version` reported `DEVELOPMENT.2025-11-06T16-25-29Z`; the native binary is
31,587,328 bytes with SHA-256
`f13d5a27903fdb17a9708a8d634c9840eaa65c92c5a1b9f8288d4d530e41e38a`. The tracked redacted
capture is `w5_entry_gate/native_windows_fake_capture.json` (33,919 bytes, SHA-256
`87dd14c2683c6c8004c87bb269cf037409ec75aa2a49ca44b6596f8849f3ec65`). Its tracked runner and
fake-server source hashes are respectively
`07283a77d161ffa5d7a6068d608a80fc5b8811ad38fbe6f2dc03eff83e9afcb7` and
`aa6d8548837afa63719604395630fd0815a6b6a3734e7a44db60a8d72147b023`.

The exact PowerShell build and capture sequence uses only official pinned source/toolchain inputs.
The angle-bracket variables are paths, not additional inputs; generated executables remain outside
the repository:

```powershell
$go = '<GO_1.24.9_ROOT>\bin\go.exe'
$goZip = '<TEMP>\go1.24.9.windows-amd64.zip'
$mcSource = '<TEMP>\maxio-s7-mc-77f82e18b540'
$worktree = '<WORKTREE>'
$bin = '<TEMP>\maxio-s7-mc-bin'
$mc = "$bin\mc.exe"
$fake = "$bin\w5-fake-server-v2.exe"
$runner = "$bin\w5-capture-runner-v2.exe"
$runnerSource = "$worktree\test\fixtures\minio_admin_config_export_import_s7\w5_entry_gate\capture_runner.go"
$fakeSource = "$worktree\test\fixtures\minio_admin_config_export_import_s7\w5_entry_gate\fake_server.go"

Set-Location $mcSource
$ldflags = & $go run .\buildscripts\gen-ldflags.go
& $go build -trimpath -tags kqueue -ldflags $ldflags -o $mc .
& $go build -o $fake $fakeSource
& $go build -o $runner $runnerSource
& $go version -m $mc
git rev-parse HEAD
git rev-parse 'HEAD^{tree}'
git status --porcelain
& $runner $mc $fake $runnerSource $fakeSource $mcSource $go $goZip
```

The final runner command emits one normalized JSON document for all 14 cases. It generates the
alias credentials internally, writes no credential to its argv, and emits no server log or raw
transcript. The tracked artifact was promoted from that successful stdout using `apply_patch`.
For non-fast-exit cases the runner parses the actual WMI `CommandLine` with Windows
`CommandLineToArgvW`, normalizes it independently from the direct `os/exec` array, and aborts on any
difference. The SIO length/plaintext records are built from the unique safe fake-server event for
each case and checked against the pinned frame formula; they are not copied from the case table.

## Security and reproducibility

No access key, caller secret, session token, Authorization value, SigV4 signature, real environment
secret, decrypted production archive or ciphertext is tracked. SIO salt and nonce are random, so
fixtures assert formula, length and decrypt/error-secret oracles instead of ciphertext bytes or a
ciphertext hash. The W5 runner generated credentials only in memory, isolated every
`MC_CONFIG_DIR`, confirmed the generated credential was absent before validated cleanup, and
retained neither raw streams nor encrypted request/response bytes. Dynamic request IDs are replaced
in memory with `<REQUEST_ID>` and the usage default path with `<MC_CONFIG_DIR>` before safe stream
base64, byte lengths and SHA-256 values are recorded. Windows process/stdout/stderr/exit evidence is
`live_verified`; the controlled peer remains `fake_observed`, and Task 11 alone reverifies the real
disposable Maxio endpoint. The recursive configuration scan propagates walk and read failures and
therefore cannot report a successful isolation check after a partial scan.

`raw_sha256.json` hashes exact `git cat-file blob COMMIT:PATH` bytes. Excerpt hashes retain the LF
after every inclusive source line, including the final selected line; checkout newline conversion,
trimming, BOM insertion and Unicode normalization are not part of the contract.
