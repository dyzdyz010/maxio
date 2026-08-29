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
- `live_verified` is reserved for a real pre-implementation capture with pinned binary/server
  identity, OS/command, redacted artifact hash and observed result. None is claimed here.
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
- W5 — native mc dispatch, success and restart output. `VERIFY-AT-IMPL`: exact Windows child
  argv/stdin/stdout/stderr/exit needs a pre-implementation capture, so Task 8 is blocked until it
  is closed. It must not be deferred to Task 11 for the first decision, and it does not block
  Task 6.

## Security and reproducibility

No access key, caller secret, session token, Authorization value, SigV4 signature, real environment
secret, decrypted production archive or ciphertext is tracked. SIO salt and nonce are random, so
fixtures assert formula, length and decrypt/error-secret oracles instead of ciphertext bytes or a
ciphertext hash. Native captures must use a disposable synthetic alias, redact sensitive material
and destroy raw sensitive artifacts.

`raw_sha256.json` hashes exact `git cat-file blob COMMIT:PATH` bytes. Excerpt hashes retain the LF
after every inclusive source line, including the final selected line; checkout newline conversion,
trimming, BOM insertion and Unicode normalization are not part of the contract.
