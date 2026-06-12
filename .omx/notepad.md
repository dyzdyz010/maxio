# maxio Session Notes

## Priority Context

- Active goal: 请你读取项目现状然后继续开发，目标是完整复刻一个minio，具备所有功能。

## Working Memory

- 2026-06-12 22:10 Asia/Shanghai: Current slice implements M8 orphan shard guarded cleanup. Scanner still defaults to report-only evidence for `part.0` without `meta.json` and delete-marker residual `part.0`; opt-in cleanup is exposed via `cleanup_orphan_shards` / `--cleanup-orphan-shards`, dry-run via `orphan_cleanup_dry_run` / `--orphan-cleanup-dry-run`, with age gate and max delete budget.
- Safety gates implemented: sidecar write authority required (force does not enable byte cleanup), all endpoints reachable by default, object lock, revalidation under lock, unchanged `part.0` stat, min age, run-scoped max delete budget, delete only `part.0` and never dirs/meta.json.
- Reviewer `019eba55-c501-7601-b888-72fc2abea16a` (gpt-5.5) found HIGH bug: max delete budget was per bucket. Fixed by carrying `orphan_cleanup_used` across bucket scans and adding a two-bucket regression with `orphan_cleanup_max_deletes: 1`.
- Final verification before handoff commit: focused cleanup suite `mix test test/maxio/storage/scanner_test.exs test/mix/tasks/maxio_reconcile_index_test.exs test/mix/tasks/maxio_scan_test.exs` -> 36 passed; `mix precommit` -> 1108 passed, 4 excluded. gpt-5.5 re-review APPROVED; residual note: separate concurrent scanner invocations each have their own per-run budget.
- Handoff commit created locally. Push attempt failed because `git remote -v` is empty / no configured push destination. Configure a remote (`git remote add origin <url>`) then push `master`.
