# MinIO Admin Config KVS S5 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在现有 MinIO Admin v3 管控面和 `Maxio.Config` Postgres 权威上实现可由真实 `mc admin config get/set/reset` 驱动的三个 Maxio 运行时配置子系统，并证明子系统批次原子性、并发协调、提交后真相、CLI 可观测性和 `prometheus_metrics.public` 的真实数据面效果。

**Architecture:** 新增 `Maxio.Admin.ConfigKV.Request/Parser/Registry/Adapter`，分别承担 transport/envelope、纯 KVS grammar、wire 暴露表和 Admin→Core 翻译；`Maxio.Admin.Plug` 只编排路由、授权、错误与响应。核心新增 `Maxio.Config.Coordinator`，让 batch 和既有单键 `set/reset` 共用 subsystem advisory lock、同一事务和一次 postcommit；PG 仍是唯一权威，`Store` digest reconcile 仍是广播丢失后的慢路径兜底。

**Tech Stack:** Elixir 1.18、Phoenix/Plug、Ecto/PostgreSQL、Jason、现有 `Maxio.Admin.Envelope`、`Maxio.S3.ControlBody`、`Maxio.Config.Schema/Store`、`Maxio.Cluster.Notify.broadcast_checked/1`、ExUnit、Mix CLI、Req、pinned native `mc`。

**Spec:** `docs/superpowers/specs/2026-08-29-minio-admin-config-kv-design.md`；该设计对旧 Admin surface spec 的 D4/D5/D10 冲突具有优先权。

## Global Constraints

- 固定起点为 `b81689759d7a6b6de933eeef5f1f5ee954e37b10`，实施分支为 `codex/admin-config-kv-s5`；不得夹带其它 worktree 或用户变更。
- 协议证据固定在 MinIO `7aac2a2c5b7c882e68c1ce017d8256be2feea27f`、madmin-go `4b504b82db633e978a57d49443b2be75824244c3`、mc `77f82e18b5401a65958f1619df6ebb994634bd88`；fixture README 必须记录 full SHA、文件、函数和 exact bytes 来源。
- 本批只暴露 `s3.clock_skew_ms`、`listing.sql_hard_limit`、`prometheus_metrics.public`；不得伪装 MinIO 官方 `api/site` catalog，不得把 `cluster.deployment_id`、secret 或 backend binding 暴露到 wire。
- Admin 依赖方向固定为 `Plug/Mix → ConfigKV.Request/Parser/Adapter → Maxio.Config → RuntimeConfig/RuntimeConfigAudit + Store + Notify`。Admin ConfigKV 层不得调用 Repo、Ecto schema或写 `:persistent_term`。
- `Maxio.Config` 是唯一配置 facade。本批不新增 config backend behaviour、第二份配置表、batch 表、全局版本、列、索引、enum 或任何 migration；若实现发现现有两张表不足，必须停止并回架构评审。
- lock SQL 固定为 `SELECT pg_advisory_xact_lock(1297638214, hashtext($1))`；transaction 中第一条协调语句必须是该 lock，之后才能读 runtime rows。batch、现有单键 `set/reset` 和新本地 KVS CLI 均不得绕过。
- 锁前只做 command/code-schema 的纯验证；任何依赖 current/effective snapshot、row existence、version、source 或未 patch sibling 的 validator 必须在 lock + authoritative read + patch 之后、mutation 之前执行。
- runtime rows 与 audits 同一 transaction；任一 validation/DB/audit 失败整批回滚。set/reset no-op 不增 version、不写 audit、不 reload、不 broadcast。
- commit 后 reload、broadcast 或 postcommit attention recorder 失败都不得把已提交操作改报 5xx。local reload 失败仍须尝试 checked broadcast；attention recorder 必须经 best-effort safe wrapper 捕获 raise、exit、transport error 与 unavailable。返回结果和结构化日志只能携带枚举化 safe reason，不能携带值或异常 inspect。
- GET 必须先同步 `Store.reconcile!/1` 并经 `Maxio.Config` facade 取 effective value；不得直接查 Repo 后自行合并，也不得在权威不可达时用旧 snapshot 假成功。
- 日志严禁 raw command、`key=value`、plaintext、ciphertext、old/new value、caller secret 或含这些内容的 `inspect(reason)`；只允许 subsystem、稳定 key 名/count、changed_count、apply modes、request_id、principal、auth type 和 postcommit 枚举结果。
- 开发中只运行任务内 focused tests、changed-file format、`mix compile --warnings-as-errors`；独立双审关闭所有 Critical/Important 后，coherent batch 只运行一次 final `mix precommit`。
- fixture/RED 作者、production 实现作者、protocol reviewer、architecture/concurrency reviewer、verification/live reviewer、STATUS reviewer必须是独立 lane；实现作者不得改写测试以迁就实现，也不得自签 approval。
- strict live 缺少 pinned native mc、隔离 PostgreSQL、两个 Maxio 节点、endpoint 或安全凭据时只能精确标记对应 probe `BLOCKED`；fixture、fake runner 和源码推导不得冒充 live PASS。

---

## Audited File Map

### Existing files to modify

- `lib/maxio/config.ex`：当前 public read/write facade；`set/4`、`reset/3` 的旧逐键事务和 `Notify.broadcast/1` 必须迁入共享 coordinator。
- `lib/maxio/config/store.ex`：已有 full load、digest reconcile、legacy三元 config event handler 和 status；增加二元 subsystem event与有界 postcommit attention，所有 recorder 调用由 coordinator 的 best-effort wrapper 隔离。
- `lib/maxio/cluster/notify.ex`：已有 `broadcast_checked/1`；扩展 event type 为 `{:config_changed, subsystem}`，保留三元 legacy event。
- `lib/maxio/cluster/cache_invalidator.ex`：显式认领二元和三元 config event 为已知 no-op。
- `lib/maxio/admin/plug.ex`：增加三条 exact v3 route、ConfigUpdate auth、caller-secret envelope 和精确 entity response。
- `lib/maxio/admin/error_map.ex`、`lib/maxio/s3/error.ex`：增加 Config generic/not-found/version-mismatch 的公共映射，不发明 `XMaxio*` code。
- `lib/maxio/s3/log.ex`、`config/config.exs`：同步增加安全 config batch/postcommit metadata allowlist。
- `lib/maxio/compat/external_smoke.ex`：在现有独立 human/JSON mc 场景上增加 config lifecycle 与 Req metrics probe。
- `test/maxio/config/config_test.exs`、`test/maxio/admin/authz_test.exs`、`test/maxio/admin/error_map_test.exs`、`test/maxio/admin/plug_test.exs`、`test/maxio/compat/external_smoke_test.exs`、`test/mix/tasks/maxio_config_test.exs`：保护既有行为并验证新共享路径。
- `README.md`：只记录已实现的三条 route、三个 Maxio extension 和 non-goals，不声称完整 catalog。

### New production files

- `lib/maxio/config/coordinator.ex`：subsystem advisory lock、authoritative candidate、atomic diff/audit 和一次 postcommit。
- `lib/maxio/admin/config_kv/registry.ex`：唯一 wire exposure/hidden/forbidden map与稳定顺序。
- `lib/maxio/admin/config_kv/parser.ex`：纯 set/reset KVS grammar、input-only fold、renderer。
- `lib/maxio/admin/config_kv/adapter.ex`：typed mapping、core mutation、authoritative GET projection、公共错误 reason。
- `lib/maxio/admin/config_kv/request.ex`：framing、payload hash、SIO decrypt/encrypt；不理解 subsystem/key。
- `lib/mix/tasks/maxio.admin.config.get.ex`、`lib/mix/tasks/maxio.admin.config.set.ex`、`lib/mix/tasks/maxio.admin.config.reset.ex`：复用 Parser/Adapter/Coordinator 的本地 KVS 调试面。

### New test/evidence files

- `test/fixtures/minio_admin_config_kv_s5/README.md`
- `test/fixtures/minio_admin_config_kv_s5/minio_routes_and_errors.json`
- `test/fixtures/minio_admin_config_kv_s5/madmin_config_kv_wire.json`
- `test/fixtures/minio_admin_config_kv_s5/mc_config_human.json`
- `test/fixtures/minio_admin_config_kv_s5/mc_config_json.json`
- `test/maxio/admin/config_kv_protocol_fixture_test.exs`
- `test/maxio/admin/config_kv_registry_test.exs`
- `test/maxio/admin/config_kv_parser_test.exs`
- `test/maxio/admin/config_kv_request_test.exs`
- `test/maxio/admin/config_kv_adapter_test.exs`
- `test/maxio/admin/config_kv_endpoint_test.exs`
- `test/maxio/config/coordinator_test.exs`
- `test/maxio/config/coordinator_concurrency_test.exs`
- `test/maxio/config/coordinator_postcommit_test.exs`
- `test/maxio/config/store_batch_event_test.exs`
- `test/mix/tasks/maxio_admin_config_test.exs`
- `test/support/config_batch_failure_repo.ex`
- `test/support/config_batch_schema.ex`：只为 coordinator 顺序测试提供两个 synthetic sibling；不得注册进 production Schema/Registry。
- `test/support/config_postcommit_store.ex`
- `test/support/config_postcommit_notify.ex`

---

## Frozen Protocol Contract

### Routes, authorization and entity framing

| Operation | Request | Action | Success response |
|---|---|---|---|
| get | `GET /minio/admin/v3/get-config-kv?key=s3`，无 CL/TE/CT/body | `admin:ConfigUpdate` | 200 SIO ciphertext；`Content-Type: application/json`；CL=exact ciphertext bytes；无 TE |
| set | `PUT /minio/admin/v3/set-config-kv`，ciphertext exact CL；无 TE/CT | `admin:ConfigUpdate` | 200；CL `0`；无 CT/TE/body；applied 时 `x-minio-config-applied: true` |
| reset | `DELETE /minio/admin/v3/del-config-kv`，ciphertext exact CL；无 TE/CT | `admin:ConfigUpdate` | 与 set 相同 |

- 完全缺失 `key` 的已认证 GET 固定为 426 `XMinioAdminVersionMismatch`；`?key=` 在 ConfigUpdate 获准后固定为 400 `XMinioConfigError`，message 为 `unknown subsystem: `。
- 认证与授权先于 query/body/decrypt。denied mutation 必须证明 body reader 调用次数为零。
- set/reset 必须恰好一个十进制 CL，不能有 TE，且 CL ≤ `262272`；缺失/重复/负数/非十进制/超限/chunked 均为 `XMinioAdminConfigTooLarge`。CL 0 进入 decrypt 后为 `XMinioAdminConfigBadJSON`。
- Content-Type 不参与 gate；缺失、任意值和多值都不能单独导致失败。
- declared/actual length 不同为 `XMinioAdminConfigBadJSON`；payload hash mismatch 为 `XAmzContentSHA256Mismatch`；wrong caller secret/decrypt failure 为 `XMinioAdminConfigBadJSON`。
- mutation success body 必须真的是零字节，不能经 JSON helper 生成 `null`、`{}` 或 LF。

### Exact KVS and client bytes

```text
s3 clock_skew_ms=900000<SP><LF>
listing sql_hard_limit=100000<SP><LF>
prometheus_metrics public=false<SP><LF>
```

- human GET 逐字保留最后一个 ASCII space 与一个 LF。
- non-TTY `--json` GET exact bytes 为 `{"status":"success","config":[{"subSystem":"s3","kv":[{"key":"clock_skew_ms","value":"900000"}]}]}<LF>`。
- non-TTY set/reset 成功 exact bytes 均为 `{"status":"success"}<LF>`，不得 pretty print 或携带未导出字段。
- set human applied 为 `Successfully applied new settings.<LF>`；header 缺失时再输出 `Please restart your server 'mc admin service restart ALIAS'.<LF>`。
- reset human applied 为 `'s3 clock_skew_ms' is successfully reset.<LF>`；header 缺失时再输出 ``Please restart your server with `mc admin service restart ALIAS`.<LF>``。

### Parser and public errors

- 单行 `s3 clock_skew_ms=1000 clock_skew_ms=2000` 的第二 token 被首个 registered marker 的 value 吸收，最终 typed validator 报 `XMinioAdminConfigBadJSON`；不得实现单行 last-write-wins 或 strict duplicate gate。
- 多行同 subsystem 的相同 key 后行覆盖前行；只为 transaction 前值→最终值写一条 audit。
- unknown suffix 进入前一个 value；unknown prefix 是 Maxio deliberate safety deviation，整批 BadJSON。不得扩张成通用扫描所有 `foo=` 的 unknown gate。
- cross-subsystem batch 是 Maxio deliberate BadJSON/零写；target (`:`) 是 `XMinioAdminInvalidArgument`。
- unknown subsystem reset 为 400 `XMinioConfigError`；已暴露 subsystem 下普通 unknown key reset 为 404 `XMinioConfigNotFoundError`；已知 wire-hidden `cluster.deployment_id` reset 为 deliberate 400 `XMinioConfigError`，绝不 BadJSON。
- same-body `s3\ns3\n`：pinned upstream whole-body `GetSubSys` 固定 400 `XMinioConfigError`；Maxio batch parser 固定 200 no-op deviation。独立 full-subsystem retry 的 Maxio 结果固定 200 且第二次零 version/audit/postcommit；不得建立 upstream 404 fixture。
- pinned MinIO 先保存 config、再保存 history 的两次写不是原子事务；Maxio runtime row + audit 同事务是 deliberate safety deviation，fixture README 必须这样标注，不能声称 storage parity。

---

## Public Interfaces to Add

```elixir
# lib/maxio/admin/config_kv/registry.ex
@type entry :: %{
  wire_subsystem: String.t(),
  wire_key: String.t(),
  core_subsystem: atom(),
  core_key: atom(),
  sensitive?: boolean(),
  order: non_neg_integer()
}
@spec entries() :: [entry()]
@spec exposed_subsystem(String.t()) :: {:ok, [entry()]} | {:error, :unknown_subsystem}
@spec classify_path(String.t(), String.t()) ::
  {:ok, entry()} | {:error, :unknown_key | :wire_hidden | :forbidden}

# lib/maxio/admin/config_kv/parser.ex
@type raw_set_batch :: %{wire_subsystem: String.t(), patches: [{String.t(), String.t()}]}
@type raw_reset_batch :: %{wire_subsystem: String.t(), reset: :all | [String.t()]}
@spec parse_set(String.t(), [Registry.entry()]) :: {:ok, raw_set_batch()} | {:error, term()}
@spec parse_reset(String.t()) :: {:ok, raw_reset_batch()} | {:error, term()}
@spec render(String.t(), [{String.t(), term()}]) :: iodata()

# lib/maxio/admin/config_kv/request.ex
@spec declared_mutation_length!(Plug.Conn.t()) :: non_neg_integer()
@spec read_mutation!(Plug.Conn.t(), SigningSecret.t(), non_neg_integer()) ::
  {Plug.Conn.t(), String.t()}
@spec encrypt_get!(SigningSecret.t(), iodata()) :: binary()

# lib/maxio/admin/config_kv/adapter.ex
@spec get(String.t(), keyword()) :: {:ok, %{plaintext: iodata(), subsystem: atom(), keys: [atom()]}} | {:error, term()}
@spec set(String.t(), keyword()) :: {:ok, Maxio.Config.batch_result()} | {:error, term()}
@spec reset(String.t(), keyword()) :: {:ok, Maxio.Config.batch_result()} | {:error, term()}
@spec describe_error(term()) :: String.t()

# lib/maxio/config.ex
@type mutation :: {:set, atom(), term()} | {:reset, atom()}
@type batch_result :: %{
  committed?: true,
  subsystem: atom(),
  changed_count: non_neg_integer(),
  changes: [map()],
  apply_modes: MapSet.t(:hot | :next_cycle | :restart),
  local_reload: :ok | :not_needed | {:error, atom()},
  broadcast: :ok | :not_needed | {:error, atom()},
  attention?: boolean()
}
@spec mutate_subsystem(atom(), [mutation()], keyword()) ::
  {:ok, batch_result()} | {:error, write_error() | term()}
@spec authoritative_effective(atom(), [atom()], keyword()) ::
  {:ok, [map()]} | {:error, {:config_store_unavailable, atom()}}

# lib/maxio/config/store.ex
@spec note_postcommit_attention(map()) :: :ok
```

`mutate_subsystem/3` opts 固定支持 `source`、`principal_arn`、`access_key_id`、`request_id`、可选 `expected_versions` map 和 candidate `validator`。production caller 不得传 test dependency；`Coordinator` 的 `repo/schema/store/notify/checkpoint` dependency injection 只用于 `test/support` 的确定性失败与时序证明。

Coordinator 内部 attention recorder 结果只允许以下安全枚举；它不加入 `batch_result`，不能覆盖已经冻结的 `local_reload`、`broadcast`、`attention?` 或 committed truth：

```elixir
@type attention_record_result ::
  :not_needed
  | :ok
  | {:error,
     :recorder_raised
     | :recorder_exited
     | :recorder_transport_failed
     | :recorder_unavailable
     | :recorder_failed}
```

---

## Ownership and Review Lanes

- **Lane A — independent fixture/RED author:** 只拥有 `test/fixtures/minio_admin_config_kv_s5/`、所有新/改 ExUnit test 和 `test/support`；先提交可复现 RED，不改 `lib/`、`config/`、README 或 STATUS。
- **Lane B — implementation author:** 只根据 Lane A 的 frozen fixture/RED 修改 production code、Mix task和 README；不得弱化断言、删除 fixture 或自审。
- **Lane C — protocol/client reviewer:** read-only 审核 route/action/error/framing/envelope/parser/mc exact bytes 和 deliberate deviations。
- **Lane D — architecture/concurrency reviewer:** read-only 审核 facade 边界、advisory lock 顺序、atomic audit/version、single-key coordination、postcommit truth、GET authority、secret-free logs 和无 migration。
- **Lane E — verification/live:** 运行 combined focused、compile、唯一 final precommit、pinned mc human/JSON 和 V-KV3 双节点活体；不修改实现。
- **Lane F — STATUS reviewer:** 只核对 STATUS 的“implemented/passed/blocked”是否有 commit/test/live artifact 支撑。

---

### Task 1: Freeze pinned protocol and mc fixtures before production work

**Files:**

- Create: `test/fixtures/minio_admin_config_kv_s5/README.md`
- Create: `test/fixtures/minio_admin_config_kv_s5/minio_routes_and_errors.json`
- Create: `test/fixtures/minio_admin_config_kv_s5/madmin_config_kv_wire.json`
- Create: `test/fixtures/minio_admin_config_kv_s5/mc_config_human.json`
- Create: `test/fixtures/minio_admin_config_kv_s5/mc_config_json.json`
- Create: `test/maxio/admin/config_kv_protocol_fixture_test.exs`

**Interfaces:**

- Consumes: three pinned repositories and approved spec.
- Produces: immutable source hashes, exact route/entity/error/parser/client bytes consumed by every later test.

- [ ] **Step 1: Lane A records provenance.** README lists each full commit, exact source file/function, SHA-256 of copied source excerpts, capture environment, non-TTY assumption and a clear label for derived fixture versus observed live packet.
- [ ] **Step 2: Encode exact route/error JSON.** Include all three routes, ConfigUpdate on GET/PUT/DELETE, missing versus empty key, fixed precedence, generic/not-found/BadJSON split, hidden reset deviation, help/export/history/target non-goals, same-body `s3\ns3\n` upstream 400 and independent retry normally 200.
- [ ] **Step 3: Encode exact entity wire JSON.** Record GET request no CL/TE/CT; mutation ciphertext exact CL/no TE/no CT; GET response ciphertext exact CL/application-json/no TE; mutation response CL0/no CT/no TE/empty; applied header true/missing branches.
- [ ] **Step 4: Encode exact human/JSON outputs.** Store strings with explicit byte lengths and Base16 copies so trailing SP/LF cannot be normalized by an editor. JSON fixture must reject pretty output and require one LF.
- [ ] **Step 5: Write fixture integrity tests.** Assert the full pin map, excerpt digests, exact byte hex, route/action matrix, error descriptions, deliberate deviation identifiers and absence of unsupported catalog claims.
- [ ] **Step 6: Run and commit the fixture gate.** Run `mix test test/maxio/admin/config_kv_protocol_fixture_test.exs`; expected PASS because this task tests evidence only. Commit only fixture/test files with `test(admin): freeze config KVS protocol`.

### Task 2: Add the exact wire registry, pure parser and renderer

**Files:**

- Create: `lib/maxio/admin/config_kv/registry.ex`
- Create: `lib/maxio/admin/config_kv/parser.ex`
- Create: `test/maxio/admin/config_kv_registry_test.exs`
- Create: `test/maxio/admin/config_kv_parser_test.exs`
- Modify: `test/maxio/config/schema_test.exs`

**Interfaces:**

- Consumes: Task 1 parser/deviation fixtures and existing `Maxio.Config.Schema.parse/3` type contract.
- Produces: ordered exposure entries, raw set/reset batches and exact plaintext renderer; no DB/Plug/envelope capability.

**Critical implementation shape:**

```elixir
@entries [
  %{wire_subsystem: "s3", wire_key: "clock_skew_ms", core_subsystem: :s3,
    core_key: :clock_skew_ms, sensitive?: false, order: 0},
  %{wire_subsystem: "listing", wire_key: "sql_hard_limit", core_subsystem: :listing,
    core_key: :sql_hard_limit, sensitive?: false, order: 0},
  %{wire_subsystem: "prometheus_metrics", wire_key: "public",
    core_subsystem: :prometheus_metrics, core_key: :public, sensitive?: false, order: 0}
]

def render(subsystem, kvs) do
  [subsystem, " ", Enum.map(kvs, fn {key, value} -> [key, "=", encode(value), " "] end), "\n"]
end
```

- [ ] **Step 1: Lane A writes registry RED.** Assert exactly three entries and order; each maps to a real `Schema.fetch/2` entry with real consumer source via existing static guard; all `sensitive?` values are false; cluster is hidden; forbidden core names classify forbidden before unknown; no string-to-atom conversion path exists.
- [ ] **Step 2: Lane A writes parser RED.** Cover LF/comments/blank lines, outer quote sanitization and raw-value preservation, single-line duplicate absorbed into value, multi-line last-line fold, invalid-first/valid-last deferred validation, unknown-only/suffix/prefix, cross-subsystem, target, reset subset/all/repeated keys, same-body repeated full reset, renderer whitespace quoting and stable final SP+LF bytes.
- [ ] **Step 3: Prove RED.** Run `mix test test/maxio/admin/config_kv_registry_test.exs test/maxio/admin/config_kv_parser_test.exs`; expected compile failure because ConfigKV modules do not exist. Lane A commits tests only with `test(admin): specify config KVS grammar`.
- [ ] **Step 4: Lane B implements Registry.** Use literal binary names and existing atoms only. `entries/0` returns an ordered list, not map enumeration. Hidden/forbidden classification compares binaries built from known Schema declarations and never interns user input.
- [ ] **Step 5: Lane B implements Parser.** Locate each distinct registered `key=` marker’s first byte index, slice values with `SplitN` semantics, sanitize outer whitespace/quotes, retain ordered multi-line patches until final fold, and implement only the two deliberate BadJSON deviations. `render/2` appends one space after every pair and one LF.
- [ ] **Step 6: Run GREEN and static boundary checks.** Run the two new suites plus `mix test test/maxio/config/schema_test.exs`; run `mix format --check-formatted` on the five changed files. Commit production files only with `feat(admin): parse config KVS grammar`.

### Task 3: Introduce the atomic subsystem coordinator and migrate single-key writers

**Files:**

- Create: `lib/maxio/config/coordinator.ex`
- Modify: `lib/maxio/config.ex`
- Create: `test/maxio/config/coordinator_test.exs`
- Create: `test/maxio/config/coordinator_concurrency_test.exs`
- Create: `test/support/config_batch_failure_repo.ex`
- Create: `test/support/config_batch_schema.ex`
- Modify: `test/maxio/config/config_test.exs`
- Modify: `test/mix/tasks/maxio_config_test.exs`

**Interfaces:**

- Consumes: `RuntimeConfig`, `RuntimeConfigAudit`, `Schema`, existing set/reset opts and Task 2 typed operations.
- Produces: `Config.mutate_subsystem/3`; existing `set/4` and `reset/3` become one-operation adapters preserving their public return/error shapes.

**Critical implementation shape:**

```elixir
repo.transaction(fn ->
  repo.query!(
    "SELECT pg_advisory_xact_lock(1297638214, hashtext($1))",
    [Atom.to_string(subsystem)]
  )

  current = lock_and_load_subsystem(repo, subsystem, schema)
  :ok = check_expected_versions(current, opts)
  candidate = apply_operations(current, operations)
  :ok = validate_candidate(candidate, opts)
  persist_diff_and_audits(repo, subsystem, current, candidate, opts)
end)

def set(subsystem, key, value, opts \\ []) do
  with {:ok, result} <- mutate_subsystem(subsystem, [{:set, key, value}], opts) do
    {:ok, single_set_result(result, key)}
  end
end
```

- [ ] **Step 1: Lane A writes atomic/version RED.** Assert multi-operation set/reset is one transaction; failed cast/candidate/audit/insert/update/delete leaves runtime and audit unchanged; same request_id appears on every actual-change audit; equal set and absent reset are no-op; reset audit uses prior version+1; a later set begins a new row at version 1.
- [ ] **Step 2: Lane A writes lock-order RED.** Use real isolated PostgreSQL connections through the repository’s established `Ecto.Adapters.SQL.Sandbox.unboxed_run/2` pattern and coordinator checkpoints, never sleep. Capture SQL/order evidence that `pg_advisory_xact_lock(1297638214, hashtext(subsystem))` precedes any runtime query; same-subsystem batch and old single-key writer serialize; different subsystems can cross the held phase.
- [ ] **Step 3: Lane A writes locked-validator RED.** `Maxio.Test.ConfigBatchSchema` exposes two synthetic keys under `:batch_fixture` only to the coordinator test. Hold writer A after advisory lock, queue writer B to change the unpatched sibling, then prove the candidate validator sees B’s authoritative value only after lock acquisition/read/patch and runs before any mutation. Verify no synthetic key enters production Registry or `Maxio.Config.Schema.entries/0`.
- [ ] **Step 4: Lane A writes old API regression RED.** Existing `Config.set/4/reset/3` still report `version/applied/changed?`, honor expected_version, use source whitelist and preserve public structured errors, but now contend on the subsystem lock. Existing Mix single-key tasks remain green after implementation.
- [ ] **Step 5: Prove RED and commit tests.** Run `mix test test/maxio/config/coordinator_test.exs test/maxio/config/coordinator_concurrency_test.exs test/maxio/config/config_test.exs test/mix/tasks/maxio_config_test.exs`; expected failures identify missing coordinator/shared lock. Commit Lane A files with `test(config): specify atomic subsystem mutations`.
- [ ] **Step 6: Lane B implements transaction order.** Inside `repo.transaction/1`, execute the advisory lock first, lock existing rows in stable key order, load fallback material, check expected_versions, apply ordered operations, call candidate validator, calculate typed diff, mutate rows, append one audit per actual change and commit once.
- [ ] **Step 7: Preserve no-op and error semantics.** Do not increment equal runtime override; absent legal reset is success; rollback uses public structured reason; only unique-row races impossible under the advisory lock may retain the existing conflict normalization as a defensive branch.
- [ ] **Step 8: Migrate public single-key APIs.** Delete the independent `write/6` transaction path from `Maxio.Config`; translate an old `expected_version` option to `%{key => expected_version}` and adapt the one-operation batch result back to the current set/reset return maps so DeploymentId, old Mix tasks and Console callers do not change API.
- [ ] **Step 9: Run GREEN.** Run all four focused suites plus `mix compile --warnings-as-errors`; commit production files only with `feat(config): coordinate subsystem mutations`.

### Task 4: Make postcommit truth, checked broadcast and reconcile observable

**Files:**

- Modify: `lib/maxio/config/coordinator.ex`
- Modify: `lib/maxio/config/store.ex`
- Modify: `lib/maxio/cluster/notify.ex`
- Modify: `lib/maxio/cluster/cache_invalidator.ex`
- Modify: `lib/maxio/s3/log.ex`
- Modify: `config/config.exs`
- Create: `test/maxio/config/coordinator_postcommit_test.exs`
- Create: `test/maxio/config/store_batch_event_test.exs`
- Create: `test/support/config_postcommit_store.ex`
- Create: `test/support/config_postcommit_notify.ex`
- Modify: `test/maxio/config/config_test.exs`
- Modify: `test/maxio/cluster/notify_test.exs`

**Interfaces:**

- Consumes: committed batch result from Task 3, `Store.load_all!/1`, `Notify.broadcast_checked/1` and existing digest reconcile.
- Produces: exactly one full local reload, one `{:config_changed, subsystem}` checked broadcast, safe result enums, attention status and legacy event compatibility. Attention-recorder failure is a log-only safe enum and cannot replace or mutate the committed `batch_result`.

**Critical implementation shape:**

```elixir
local_reload = safe_reload(store, repo, subsystem)
broadcast = safe_broadcast(notify, {:config_changed, subsystem})
attention? = match?({:error, _}, local_reload) or match?({:error, _}, broadcast)

attention_record =
  if attention? do
    safe_record_attention(store, %{
      subsystem: subsystem,
      local_reload: local_reload,
      broadcast: broadcast
    })
  else
    :not_needed
  end

log_postcommit(subsystem, local_reload, broadcast, attention?, attention_record)

%{committed?: true, local_reload: local_reload, broadcast: broadcast,
  attention?: attention?}

defp safe_record_attention(store, fields) do
  case store.note_postcommit_attention(fields) do
    :ok -> :ok
    {:error, :unavailable} -> {:error, :recorder_unavailable}
    {:error, :transport} -> {:error, :recorder_transport_failed}
    {:error, {:transport, _discarded}} -> {:error, :recorder_transport_failed}
    {:error, _discarded} -> {:error, :recorder_failed}
    _unexpected -> {:error, :recorder_failed}
  end
rescue
  _error -> {:error, :recorder_raised}
catch
  :exit, _reason -> {:error, :recorder_exited}
  _kind, _reason -> {:error, :recorder_failed}
end
```

- [ ] **Step 1: Lane A writes postcommit RED.** Assert changed batch commits before callbacks, calls full reload once then checked broadcast once, attempts broadcast after reload failure, never retries mutation, and maps injected reload/broadcast dependency raise, exit and transport errors to fixed atoms without values.
- [ ] **Step 2: Lock commit-truth cases.** Reload failure returns committed result with `local_reload: {:error, :reload_failed}`, omitted applied eligibility and visible attention; broadcast failure remains committed and does not imply restart; both failures preserve rows/audits. No-op calls neither dependency and is applied-eligible.
- [ ] **Step 3: Lock recorder-after-failure RED.** For a committed row/audit, inject reload failure followed separately by recorder raise, exit and `{:error, :unavailable}`; inject broadcast failure followed by recorder `{:error, :transport}` and `{:error, {:transport, secret_bearing_reason}}`. Every case must return the original committed result, keep HTTP-facing status eligible for 200, preserve the row/audit, avoid a second mutation, and never report a false rollback. Logs may contain only `recorder_raised|recorder_exited|recorder_unavailable|recorder_transport_failed` plus safe subsystem/request metadata. Captured log and result must not contain the injected secret-bearing reason, submitted value, plaintext, ciphertext or caller secret.
- [ ] **Step 4: Lock event/reconcile cases.** Store handles new two-tuple event with one full load, continues handling legacy three-tuple, CacheInvalidator recognizes both as no-op, and a deliberately dropped broadcast converges through digest reconcile with `last_reload_reason: :reconcile`.
- [ ] **Step 5: Prove RED and commit tests.** Run `mix test test/maxio/config/coordinator_postcommit_test.exs test/maxio/config/store_batch_event_test.exs test/maxio/config/config_test.exs test/maxio/cluster/notify_test.exs`; expected failures name the unsafe bare recorder, missing two-tuple event/postcommit result/attention and missing safe metadata. Commit Lane A files with `test(config): specify committed postcommit truth`.
- [ ] **Step 6: Lane B implements postcommit and safe recorder.** Catch reload and checked-broadcast failures independently after transaction success; when either needs attention, call `Store.note_postcommit_attention/1` only through `safe_record_attention/2`. Normalize raise, exit, transport, unavailable and all unknown returns to the frozen safe enum, log that enum, discard the underlying term, and return `attention?: true` without rewriting commit status or throwing.
- [ ] **Step 7: Extend Store, events and safe logging.** Add bounded latest attention data to Store status; never store values/reasons containing values. Handle two-tuple event with full reload and recognize it in CacheInvalidator. Keep legacy three-tuple until a later migration batch. Add only `config_attention_record` to both `Maxio.S3.Log` and Logger formatter allowlists in this task.
- [ ] **Step 8: Run GREEN and commit.** Run the exact focused command from Step 5 plus `mix compile --warnings-as-errors`; commit production files with `feat(config): report postcommit convergence`.

### Task 5: Add typed Adapter and authoritative GET projection

**Files:**

- Create: `lib/maxio/admin/config_kv/adapter.ex`
- Modify: `lib/maxio/config.ex`
- Create: `test/maxio/admin/config_kv_adapter_test.exs`
- Modify: `test/maxio/config/config_test.exs`

**Interfaces:**

- Consumes: Task 2 Parser/Registry, Task 3 Config mutation, Task 4 Store reconcile.
- Produces: safe Admin reasons, typed set/reset operations and authoritative redacted GET plaintext.

**Critical implementation shape:**

```elixir
def get(wire_subsystem, opts \\ []) do
  with {:ok, entries} <- Registry.exposed_subsystem(wire_subsystem),
       {:ok, effective} <-
         Config.authoritative_effective(
           hd(entries).core_subsystem,
           Enum.map(entries, & &1.core_key),
           opts
         ) do
    values = project_redacted(entries, effective)
    {:ok, %{plaintext: Parser.render(wire_subsystem, values),
            subsystem: hd(entries).core_subsystem,
            keys: Enum.map(entries, & &1.core_key)}}
  end
end

defp parse_value(entry, raw),
  do: Schema.parse(entry.core_subsystem, entry.core_key, raw)
```

- [ ] **Step 1: Lane A writes mapping RED.** Assert exact three projections and types; integer accepts only full decimal within 0..3,600,000 or 1..10,000,000, boolean accepts only lowercase `true|false`; hidden cluster get/set/reset is generic 400-class reason, exposed-subsystem unknown reset key is not-found reason, forbidden wins over unknown, target is invalid-argument, parser safety deviations are BadJSON-class reasons.
- [ ] **Step 2: Lane A writes mutation RED.** Multi-line fold passes ordered typed operations once to Config; all scalar parsing finishes before DB mutation; full reset expands only exposed keys; repeated full reset is 200 no-op with zero audit/version/postcommit; audit opts carry one request_id/principal/access key/source.
- [ ] **Step 3: Lane A writes authoritative GET RED.** Force local snapshot stale, invoke adapter GET, and assert synchronous reconcile before projection. PG/Store failure returns safe internal reason rather than cached plaintext. Renderer emits exact trailing SP+LF and omits all `sensitive?` entries before serialization.
- [ ] **Step 4: Prove RED and commit tests.** Run `mix test test/maxio/admin/config_kv_adapter_test.exs test/maxio/config/config_test.exs`; commit Lane A changes with `test(admin): specify config KVS adapter`.
- [ ] **Step 5: Lane B implements `Config.authoritative_effective/3`.** Call `Store.reconcile!/1`, then read through existing facade; catch DB/Store failures into `{config_store_unavailable, safe_atom}` without falling back to old snapshot.
- [ ] **Step 6: Lane B implements Adapter.** Translate strings only through Registry, parse values through `Schema.parse/3`, pass source/audit context to one `mutate_subsystem/3` call, and map core failures without logging command/value.
- [ ] **Step 7: Run GREEN and commit.** Run focused suites and changed-file format; commit production files with `feat(admin): adapt config KVS operations`.

### Task 6: Implement mutation framing, payload verification and caller-secret SIO

**Files:**

- Create: `lib/maxio/admin/config_kv/request.ex`
- Create: `test/maxio/admin/config_kv_request_test.exs`
- Modify: `test/maxio/s3/control_body_test.exs`

**Interfaces:**

- Consumes: `Plug.Conn`, authenticated `signed_payload_sha256`, `SigningSecret`, `ControlBody`, `Envelope`.
- Produces: plaintext mutation or encrypted GET bytes; no registry/parser awareness.

**Critical implementation shape:**

```elixir
{conn, ciphertext, _trailers} =
  ControlBody.read!(conn, 262_272, @too_large_message,
    too_large_error: :admin_config_too_large,
    expected_length: declared_length,
    length_mismatch_error: :admin_config_bad_json,
    verify_payload_sha256: conn.assigns.sigv4_context.signed_payload_sha256
  )

case Envelope.decrypt(caller_secret, ciphertext) do
  {:ok, plaintext} -> {conn, plaintext}
  {:error, _safe_discarded_reason} -> raise Error.new(:admin_config_bad_json)
end
```

- [ ] **Step 1: Lane A writes framing RED.** Assert one canonical decimal CL, boundary 262272, missing/duplicate/negative/nondecimal/overflow/any TE failures; CL0 reaches decrypt; actual mismatch and hash mismatch preserve exact code order; arbitrary/absent/multiple Content-Type is accepted.
- [ ] **Step 2: Lane A writes envelope RED.** Deterministic SIO vector decrypts with authenticated caller secret, wrong/root/rotated other secret returns BadJSON, ciphertext/plaintext never appears in captured log, and GET encryption round-trips with caller secret.
- [ ] **Step 3: Prove RED and commit tests.** Run `mix test test/maxio/admin/config_kv_request_test.exs test/maxio/s3/control_body_test.exs`; commit Lane A files with `test(admin): specify config KVS transport`.
- [ ] **Step 4: Lane B implements Request.** Reuse `ControlBody.read!/4` options for expected length/hash and exact error atoms; implement no Content-Type gate; use `Envelope.decrypt/2` and `encrypt/2`; discard detailed crypto reason.
- [ ] **Step 5: Run GREEN and commit.** Run focused suites and `mix compile --warnings-as-errors`; commit production file with `feat(admin): handle config KVS envelopes`.

### Task 7: Wire Admin routes, auth, public errors, headers and secret-free logs

**Files:**

- Modify: `lib/maxio/admin/plug.ex`
- Modify: `lib/maxio/admin/error_map.ex`
- Modify: `lib/maxio/s3/error.ex`
- Modify: `lib/maxio/s3/log.ex`
- Modify: `config/config.exs`
- Create: `test/maxio/admin/config_kv_endpoint_test.exs`
- Modify: `test/maxio/admin/authz_test.exs`
- Modify: `test/maxio/admin/error_map_test.exs`
- Modify: `test/maxio/admin/plug_test.exs`

**Interfaces:**

- Consumes: Task 5 Adapter, Task 6 Request and existing `authorize_and_run/signing_secret/render_error` helpers.
- Produces: exact signed HTTP surface, public JSON errors and applied-header truth.

**Critical implementation shape:**

```elixir
defp dispatch(conn, "GET", "/minio/admin/v3/get-config-kv"), do: get_config_kv(conn)
defp dispatch(conn, "PUT", "/minio/admin/v3/set-config-kv"), do: set_config_kv(conn)
defp dispatch(conn, "DELETE", "/minio/admin/v3/del-config-kv"), do: reset_config_kv(conn)

defp mutation_success(conn, result) do
  conn =
    if applied_without_restart?(result) do
      put_resp_header(conn, "x-minio-config-applied", "true")
    else
      conn
    end

  conn |> send_resp(200, "") |> halt()
end
```

- [ ] **Step 1: Lane A writes dispatch/entity RED.** Exact methods/paths leave 501; wrong method, help/export/history, v4 and adjacent paths remain existing authenticated 501. Missing GET key is authenticated 426; empty key reaches ConfigUpdate then 400. Assert every request/response CL/TE/CT/body cell from Frozen Protocol Contract.
- [ ] **Step 2: Lane A writes auth RED.** For each route cover root, exact allow, no policy, explicit deny, STS boundary and bucket-policy attempted grant. GET requires ConfigUpdate. Denied mutation with body-read probe returns AccessDenied and reads zero bytes.
- [ ] **Step 3: Lane A writes error-priority RED.** Combine auth/framing/hash/decrypt/parser/exposure/type/DB failures and assert only the first stage’s exact code/status/message/resource/request_id. Lock unknown subsystem 400, ordinary reset-key 404, hidden reset deliberate 400 and forbidden 403.
- [ ] **Step 4: Lane A writes success/postcommit RED.** Decrypt GET and compare exact plaintext; changed/no-op applied true; `:next_cycle` remains true; reload failure omits header; broadcast failure keeps true; future injected restart apply mode omits header. For both reload-failed and broadcast-failed paths, a subsequent attention recorder raise/exit/error must still produce committed HTTP 200 with the header decision derived only from apply modes + local reload. Mutation body is exactly empty.
- [ ] **Step 5: Lane A writes log redaction RED.** Capture success/failure logs and require action/subsystem/key count/changed count/request_id/principal/auth/postcommit enums plus safe `config_attention_record`, while rejecting raw command, known submitted value, plaintext, ciphertext hex, old/new maps, recorder reason and caller secret.
- [ ] **Step 6: Prove RED and commit tests.** Run endpoint/auth/error/plug tests; commit Lane A changes with `test(admin): specify config KVS endpoints`.
- [ ] **Step 7: Lane B adds public errors.** Add `admin_version_mismatch`, `config_error` and `config_not_found` entries with pinned code/status/default message; ErrorMap tuple clauses may override only safe pinned descriptions.
- [ ] **Step 8: Lane B adds thin handlers.** Missing-key route fallback does not parse body. Concrete handlers authorize ConfigUpdate first, obtain exact caller secret, call Request/Adapter once with `source: "admin_api"` plus principal/access-key/request-id audit context, and render exact response. Applied header predicate uses only apply modes + local reload, never broadcast success.
- [ ] **Step 9: Lane B updates remaining log allowlists.** Preserve Task 4 的 `config_attention_record` and add only `config_key_count`, `config_changed_count`, `config_apply_modes`, `config_local_reload`, `config_broadcast`, `config_attention` and `config_failure_stage` to both `Log` and formatter config.
- [ ] **Step 10: Run GREEN and commit.** Run `mix test test/maxio/admin/config_kv_endpoint_test.exs test/maxio/admin/authz_test.exs test/maxio/admin/error_map_test.exs test/maxio/admin/plug_test.exs`; run compile; commit production files with `feat(admin): expose config KVS endpoints`.

### Task 8: Add first-party Config KVS Mix CLI without duplicating logic

**Files:**

- Create: `lib/mix/tasks/maxio.admin.config.get.ex`
- Create: `lib/mix/tasks/maxio.admin.config.set.ex`
- Create: `lib/mix/tasks/maxio.admin.config.reset.ex`
- Create: `test/mix/tasks/maxio_admin_config_test.exs`
- Modify: `test/mix/tasks/maxio_config_test.exs`

**Interfaces:**

- Consumes: `Maxio.Config.CLI.boot/0` and Task 5 Adapter; skips HTTP/SigV4/envelope only.
- Produces: exact redacted KVS GET and safe mutation result line with `source="cli"` and fresh request_id.

**Critical implementation shape:**

```elixir
def run(args) do
  :ok = Maxio.Config.CLI.boot()
  command = Enum.join(args, " ")
  request_id = Ecto.UUID.generate()

  case Maxio.Admin.ConfigKV.Adapter.set(command, source: "cli", request_id: request_id) do
    {:ok, result} -> Mix.shell().info(format_result(result))
    {:error, reason} -> Mix.raise(Maxio.Admin.ConfigKV.Adapter.describe_error(reason))
  end
end
```

- [ ] **Step 1: Lane A writes CLI RED.** Assert quoted single argument and joined tail forms, exact get SP+LF, malformed/hidden/forbidden safe failures, full/subset reset, and no direct Repo call. Mutation output is one line: `committed=true changed_count=N apply_modes=hot local_reload=ok broadcast=ok attention=false` with no values.
- [ ] **Step 2: Lock shared-path behavior.** New KVS CLI and existing single-key CLI contend on the same subsystem lock; expected_version remains available only to existing core CLI; no-op output reports zero and produces no audit/postcommit.
- [ ] **Step 3: Prove RED and commit tests.** Run the two Mix suites; commit Lane A files with `test(cli): specify admin config KVS commands`.
- [ ] **Step 4: Lane B implements three tasks.** Boot once, join remaining argv with one space, call Adapter exactly once, format only approved result fields, and raise Mix error using safe Adapter description.
- [ ] **Step 5: Run GREEN and commit.** Run both Mix suites and changed-file format; commit production tasks with `feat(cli): operate admin config KVS`.

### Task 9: Prove the metrics toggle through independent mc smoke

**Files:**

- Modify: `lib/maxio/compat/external_smoke.ex`
- Modify: `test/maxio/compat/external_smoke_test.exs`
- Modify: `README.md`

**Interfaces:**

- Consumes: existing isolated `MC_CONFIG_DIR`, command runner, independent human/JSON state and Req dependency.
- Produces: exact mc lifecycle plus anonymous metrics 403→200→403 data-plane evidence and unconditional cleanup.

**Critical live probe shape:**

```elixir
defp anonymous_metrics_status(endpoint) do
  endpoint
  |> URI.merge("/minio/v2/metrics/cluster")
  |> to_string()
  |> Req.get!(redirect: false)
  |> Map.fetch!(:status)
end

config_args = ["admin", "config", "set", alias_name,
               "prometheus_metrics", "public=true"]
reset_args = ["admin", "config", "reset", alias_name,
              "prometheus_metrics", "public"]
```

- [ ] **Step 1: Lane A writes human smoke RED.** Fake runner observes exact argv: baseline anonymous metrics 403, get false exact SP+LF, set true exact success/no restart, get true, metrics 200, reset public, get false, metrics 403. Every command records exit/stdout/stderr and scenario id.
- [ ] **Step 2: Lane A writes JSON smoke RED.** Use a distinct alias/database state, put `--json` in the pinned global position and assert compact exact GET/set/reset bytes with one LF. Human and JSON runs may share builders but never aliases or mutations.
- [ ] **Step 3: Lane A writes cleanup/failure RED.** Inject failure after each lifecycle step. `after` always issues reset; cleanup failure is separately reported and never replaces the primary failure. Baseline must start with no runtime override and public false.
- [ ] **Step 4: Lane A writes real consumer RED.** Production default Req probe calls the real metrics endpoint anonymously; tests inject a `metrics_probe` function that records URL/headers and returns scripted statuses. Do not infer effect from config GET. Assert the three statuses in order and prove no Authorization token was injected.
- [ ] **Step 5: Prove RED and commit tests.** Run `mix test test/maxio/compat/external_smoke_test.exs`; commit Lane A changes with `test(compat): specify admin config lifecycle`.
- [ ] **Step 6: Lane B extends orchestration.** Preserve existing redaction and proxy bypass; use Req for HTTP; keep secrets only in command env/closure; label expected transcript as fixture, not live evidence.
- [ ] **Step 7: Document honest scope.** README lists the three exact v3 routes and three Maxio extension keys, atomic/no-op semantics and data-plane metrics example. It explicitly lists help/export/history/targets/official catalog/secrets/backend bindings as unsupported.
- [ ] **Step 8: Run GREEN and commit.** Run smoke tests and `mix compile --warnings-as-errors`; commit production/docs with `test(compat): exercise admin config lifecycle`.

### Task 10: Coherent-batch verification and independent dual review

**Files:** all production/test/fixture/README files changed in Tasks 1–9; no STATUS edit yet.

- [ ] **Step 1: Lane B runs author checks without precommit.** Run all focused commands above together, changed-file `mix format --check-formatted`, `mix compile --warnings-as-errors`, and `git diff --check b816897..HEAD`. Any failure returns to Lane A for a failing regression and Lane B for the minimal architecture-consistent fix.
- [ ] **Step 2: Lane C performs protocol/client review.** Audit pins/excerpt hashes, three routes/ConfigUpdate, missing-vs-empty key, exact CL/TE/CT/body, caller-secret SIO, error priority/mapping, single-line versus multi-line parser, hidden/forbidden/reset distinctions, same-body/full-retry correction, KVS trailing space, non-TTY compact JSON and help/export/history/target non-goals. Any invented duplicate/unknown gate or upstream 404 claim is Important.
- [ ] **Step 3: Lane D performs architecture/concurrency review.** Audit Admin→Adapter→Config boundary, literal registry, no atom creation, advisory lock as first transaction coordination, lock/read/patch/validator/mutation order, atomic audit/version, single-key delegation, no-op, commit-truth, checked broadcast, best-effort safe attention recorder, Store attention/reconcile, authoritative GET and log redaction. A recorder raise/exit/error that can escape after commit, any raw recorder reason in logs, direct Admin Repo access, postcommit rollback fiction, unlocked old writer or migration is Important.
- [ ] **Step 4: Lane A/B close findings.** Lane A adds a failing regression for each accepted finding; Lane B fixes production only; rerun owning focused suite and commit. Lanes C and D re-review the amended range until both report no Critical/Important.
- [ ] **Step 5: Lane E runs combined focused batch.** Run all new ConfigKV/coordinator/event/endpoint/CLI/smoke suites plus affected existing config/admin/envelope/control-body/notify/prometheus tests. Record exact commands, exits and counts for STATUS.
- [ ] **Step 6: Run the single final precommit gate.** After dual approval and clean focused/compile/format/diff evidence, Lane E runs `mix precommit` once. If later production/test code changes, the recorded gate is invalid; reopen focused review and retain only the replacement final result as completion evidence.
- [ ] **Step 7: Verify no migration and clean pre-live state.** `git diff --name-only b816897..HEAD` must contain no `priv/repo/migrations/` path, generated credential or live artifact; `git status --short` must be empty.

### Task 11: Run strict pinned mc and V-KV3 live evidence

**Files:** no tracked changes; write raw artifacts only to ignored `artifacts/admin-config-kv-s5/2026-08-29-live/`, then summarize facts in Task 12.

- [ ] **Step 1: Pin live identities.** Record native `mc --version`, binary hash/correlation to `77f82e1`, Maxio HEAD, endpoint, isolated database identity, two node ids and redacted alias paths. Different mc versions are exploratory only.
- [ ] **Step 2: Run human lifecycle.** Against clean false/no-override state, execute GET→set true→GET→reset→GET and compare stdout bytes including SP+LF; independently prove anonymous metrics 403→200→403; run cleanup even on failure.
- [ ] **Step 3: Run independent JSON lifecycle.** Use a fresh alias/state and non-TTY capture; assert each compact JSON line exactly and forbid human/restart text on applied hot path.
- [ ] **Step 4: Capture exact HTTP framing.** Record GET request no CL/TE/CT, mutation ciphertext exact CL/no TE/CT, GET ciphertext response exact CL/application-json, mutation CL0/no CT/body and applied header. Redact Authorization, caller secret and ciphertext from committed artifacts.
- [ ] **Step 5: Exercise parser/error fixtures safely.** Through signed disposable requests verify missing/empty key, single-line duplicate, multi-line overwrite, ordinary reset unknown 404, hidden reset 400 and same-body repeated full reset Maxio 200. Do not create upstream full-reset 404 evidence.
- [ ] **Step 6: Close V-KV3 on two Maxio nodes.** Inject one checked broadcast transport failure on writer node; prove commit/audit remains, writer applied header semantics are truthful, remote node is initially stale then converges within one configured digest refresh, Store status/log carries attention, and the same run performs metrics 403→200→403.
- [ ] **Step 7: Classify infrastructure gaps.** Missing pinned mc, isolated PG, two nodes, failure injection, endpoint or credentials yields a per-probe BLOCKED record with exact missing capability. Exit 0 with zero business steps is not PASS.

### Task 12: STATUS-only factual closeout

**Files:**

- Modify only: `docs/superpowers/STATUS.md`

- [ ] **Step 1: Record implementation facts.** Add exact routes/action/framing, three extension keys, parser deviations, atomic advisory-lock coordinator, single-key migration, audit/version/no-op, postcommit truth including best-effort attention recorder isolation, authoritative GET, CLI and metrics data-plane behavior.
- [ ] **Step 2: Record evidence.** Include commit range, combined focused command/count, compile/format/diff, Lane C/D verdicts, the single final precommit result, pinned human/JSON live result and V-KV3 PASS or exact BLOCKED reason.
- [ ] **Step 3: Record remaining scope.** Keep help/export/history/targets/official catalog/secrets/backend bindings/service restart explicit; do not claim full MinIO config compatibility or production readiness.
- [ ] **Step 4: Lane F reviews STATUS.** Cross-check every “implemented/passed” sentence against commits, command output and live artifact. Fixture-derived bytes must not be described as observed live when strict live was blocked.
- [ ] **Step 5: Commit only STATUS.** Verify status lists only `docs/superpowers/STATUS.md`, then commit `docs(status): record admin config KVS S5 evidence`; confirm clean worktree.

### Task 13: Fast-forward integration and atomic push

- [ ] **Step 1: Verify feature ancestry.** Record HEAD, clean status and `git merge-base --is-ancestor b81689759d7a6b6de933eeef5f1f5ee954e37b10 HEAD` success.
- [ ] **Step 2: Protect integration worktree.** Verify main worktree is clean and contains no uncommitted user changes. If dirty, stop and report exact paths; never reset, force-checkout or overwrite them.
- [ ] **Step 3: Fast-forward only.** In the clean integration worktree run `git merge --ff-only codex/admin-config-kv-s5`.
- [ ] **Step 4: Push both refs atomically.** Run `git push --atomic origin refs/heads/master:refs/heads/master refs/heads/codex/admin-config-kv-s5:refs/heads/codex/admin-config-kv-s5`. If rejected, diagnose and retry atomically; do not partially push one ref.
- [ ] **Step 5: Verify final identities.** Compare local HEAD with both remote refs, confirm both worktrees clean, and report final SHA, dual-review verdicts, final precommit and strict live PASS/BLOCKED classification.

---

## Explicit Non-Goals

- 不实现 `help-config-kv`、full config export/import、history API、`subsystem:target`、`subsystem:`、官方 MinIO config catalog 或 service restart。
- 不暴露或修改 deployment identity、root credential、access-key secret、SSE/KMS/MFA key、storage/credential/policy backend、Repo、topology 或 authoritative-source。
- 不新增 migration、batch table、global revision、outbox、config backend behaviour 或第二权威；现有 `runtime_configs` 与 `runtime_config_audits` 必须足以完成本批。
- 不让 Admin Adapter/Parser/Request 直接访问 Repo/Ecto/`:persistent_term`，不让 Request 理解 KVS，不在 Plug/Mix task 复制 parser 或 transaction。
- 不把 single-line duplicate 改成 last-write-wins，不发明 strict duplicate/unknown gate，不把 permissive unknown-prefix 成功复制为 Maxio 静默接受。
- 不声称 broadcast exactly-once；PG transaction 是提交真相，checked broadcast 是快路径，digest reconcile 是慢路径。
- 不把 fake runner、fixture、源码阅读、单节点测试或预期 transcript 冒充 pinned mc/two-node live evidence。
