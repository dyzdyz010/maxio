# maxio Session Notes

## Priority Context

- Active goal: 请你读取项目现状然后继续开发，目标是完整复刻一个minio，具备所有功能。

## Working Memory

- 2026-06-12 22:10 Asia/Shanghai: Current slice implements M8 orphan shard guarded cleanup. Scanner still defaults to report-only evidence for `part.0` without `meta.json` and delete-marker residual `part.0`; opt-in cleanup is exposed via `cleanup_orphan_shards` / `--cleanup-orphan-shards`, dry-run via `orphan_cleanup_dry_run` / `--orphan-cleanup-dry-run`, with age gate and max delete budget.
- Safety gates implemented: sidecar write authority required (force does not enable byte cleanup), all endpoints reachable by default, object lock, revalidation under lock, unchanged `part.0` stat, min age, run-scoped max delete budget, delete only `part.0` and never dirs/meta.json.
- Reviewer `019eba55-c501-7601-b888-72fc2abea16a` (gpt-5.5) found HIGH bug: max delete budget was per bucket. Fixed by carrying `orphan_cleanup_used` across bucket scans and adding a two-bucket regression with `orphan_cleanup_max_deletes: 1`.
- Final verification before handoff commit: focused cleanup suite `mix test test/maxio/storage/scanner_test.exs test/mix/tasks/maxio_reconcile_index_test.exs test/mix/tasks/maxio_scan_test.exs` -> 36 passed; `mix precommit` -> 1108 passed, 4 excluded. gpt-5.5 re-review APPROVED; residual note: separate concurrent scanner invocations each have their own per-run budget.
- Handoff commit created locally. Push attempt failed because `git remote -v` is empty / no configured push destination. Configure a remote (`git remote add origin <url>`) then push `master`.
- Active goal for next machine: 请你读取项目现状然后继续开发，目标是完整复刻一个minio，具备所有功能。
- 2026-06-12 handoff checkpoint: Started the next M8 scanner/scrubber slice for token-bucket object throttling. Current edits are in `config/config.exs`, `lib/maxio/cluster/scrubber.ex`, `lib/maxio/cluster/scrubber/throttle.ex`, and `lib/mix/tasks/maxio.scan.ex`.
- Current slice state: `Scrubber.Throttle` now has stateful disabled/fixed/token-bucket modes, `Scrubber.run_once/1` threads throttle state across bucket/object scans, `mix maxio.scan` accepts `--max-objects-per-sec`, `--object-burst`, and `--sleep-between-batches-ms`, and config defaults `object_burst: 1`.
- Not yet completed: focused tests for the token-bucket behavior and scan CLI, `mix compile --warnings-as-errors`, `mix precommit`, independent gpt-5.5 review, README/STATUS update for this slice.
- Remote note: `git remote -v` was empty before this checkpoint, so pushing will fail until an `origin` or other push remote is configured.
- 2026-06-12 22:28 Asia/Shanghai stop checkpoint: user requested progress recording, commit/push attempt, and then no further work. Commit this WIP as a handoff snapshot; keep the active goal unchanged and continue from tests/docs/review on the next machine.
