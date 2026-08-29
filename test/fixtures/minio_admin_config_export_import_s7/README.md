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

- `source_verified` follows directly from pinned official source and its recorded hashes.
- `local_design_expected` is an intentional Maxio contract, never an upstream or live fact.
- `live_verified` is reserved for a real pinned capture. None is claimed here.
- `VERIFY-AT-IMPL` is an honest pending observation. If it determines implementation, its named
  task gate is blocked until a pre-implementation capture closes it; Task 11 may only reverify.

The fresh Maxio archive is stored as base64 and an escaped rendering, not as a tracked text file
with physical trailing spaces. Tests must decode it and recompute exactly 89 bytes and SHA-256
`c8fe86493cce0083169223b68b59e69612ceeaff7ff45721b45eb85e7eff4141`. Its evidence class is
exactly `local_design_expected`; it is not a universal MinIO default export.

## W1-W5 gate matrix

- W1 — madmin local plaintext limits and SIO frame formula. `PASS_SOURCE_VERIFIED` before endpoint
  RED: for positive `n`, encrypted length is `41+n+16*ceil(n/16384)`.
- W2 — direct server ciphertext limits, framing, authorization precedence and errors.
  `PASS_SOURCE_AND_EXISTING_CONTRACT_VERIFIED`: a valid SIO PUT cannot reach a post-decrypt
  plaintext-over-256-KiB branch because the 262272-byte ciphertext gate limits plaintext to
  261975 bytes. A defense-in-depth plaintext guard reuses the existing TooLarge contract as
  `local_design_expected`. All other rows reuse S5/ErrorMap or pinned source. A valid identity
  denied `admin:ConfigUpdate` receives `AccessDenied`; authentication failures retain their own
  authentication error codes.
- W3 — export bytes and order. `PASS_SOURCE_VERIFIED_WITH_LOCAL_DESIGN_PAYLOAD` before Archive RED.
  A deployment-specific full MinIO default export remains a non-decisional Task 11 observation.
- W4 — import defaults, replacement, duplicates and unknown input. The upstream mechanics are
  `source_verified`; deliberate Maxio target/unknown rejection is `local_design_expected`.
- W5 — native mc dispatch, success and restart output. `VERIFY-AT-IMPL`: exact Windows child
  argv/stdin/stdout/stderr/exit needs a pre-implementation capture, so Task 8 is blocked until it
  is closed. It must not be deferred to Task 11 for the first decision.

## Security and reproducibility

No access key, caller secret, session token, Authorization value, SigV4 signature, real environment
secret, decrypted production archive or ciphertext is tracked. SIO salt and nonce are random, so
fixtures assert formula, length and decrypt/error-secret oracles instead of ciphertext bytes or a
ciphertext hash. Native captures must use a disposable synthetic alias, redact sensitive material
and destroy raw sensitive artifacts.

`raw_sha256.json` hashes exact `git cat-file blob COMMIT:PATH` bytes. Excerpt hashes retain the LF
after every inclusive source line, including the final selected line; checkout newline conversion,
trimming, BOM insertion and Unicode normalization are not part of the contract.
