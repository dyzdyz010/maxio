# MinIO Admin Config Help S6 pinned evidence

This directory freezes source-derived evidence for S6 `GET /minio/admin/v3/help-config-kv`.
It is not a live interoperability capture and it does not claim implementation of MinIO's full
configuration catalog.

Pinned upstream identities:

- MinIO: `7aac2a2c5b7c882e68c1ce017d8256be2feea27f`
- madmin-go: `4b504b82db633e978a57d49443b2be75824244c3`
- mc: `77f82e18b5401a65958f1619df6ebb994634bd88`

The three commits were fetched directly from the official GitHub repositories. Each JSON claim
references one or more source records. `raw_source_sha256` is SHA-256 over the exact Git blob bytes
at the pinned commit. `excerpt_sha256` is SHA-256 over the exact inclusive line range, starting at
the first byte of the first line and ending after the LF of the last line. No checkout newline
conversion, trimming, or Unicode normalization is applied. A reviewer can recompute a record with
`git cat-file blob COMMIT:PATH`, select the recorded inclusive lines while retaining LF, and hash
both byte sequences.

Classification:

- `source_derived` means the value follows directly from the pinned source and the frozen Maxio S6
  catalog input.
- `source_derived_expected_on_wire` means Go request construction determines the expected HTTP
  entity shape, but a native request capture is still required before calling it live evidence.
- `verify_at_impl` is deliberately unresolved live evidence. V-H1 must capture pinned MinIO's
  actual `env`, `env=`, and `env=false` handling because the handler reads `r.Form` without calling
  `ParseForm`. V-H2 must capture pinned native mc in redirected non-TTY/no-color human and global
  `--json` modes. Its result may replace these expected transcript bytes.

The mc transcript inputs are only the three ordered Maxio extension entries defined by the S6
design. They are not MinIO's official catalog. Human spacing is derived from mc's pinned template
and `tabwriter` settings; JSON order is derived from pinned mc/madmin structs and non-TTY compaction.
All expected stdout values use UTF-8 and exactly one LF. No credentials, access keys, secret keys,
session tokens, Authorization values, or real signatures are stored here.
