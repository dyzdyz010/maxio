# MinIO Admin Config Export/Import S7 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 实现 MinIO Admin v3 config export/import，使 caller-secret SIO 与 native mc 可互通，同时只原子替换 Registry 三个公开 Maxio 运行时配置键。

**Architecture:** `Maxio.Admin.ConfigKV.Archive` 负责纯归档 projection/parser/planner，所有权威读取和写入分别通过 `Maxio.Config.authoritative_snapshot/2` 与统一的 `mutate_many/2`。导入在事务前全量验证，在一个 PostgreSQL transaction 中先按稳定顺序取得全部 subsystem advisory locks，再读/验证/写/审计；commit 后至多一次 Store reload 和一次 checked batch broadcast。

**Tech Stack:** Elixir/OTP、Phoenix Plug、Bandit、Ecto/PostgreSQL、SigV4、madmin SIO、ExUnit、Mix tasks、native mc、Req（仅 HTTP 客户端需要时）。

**Spec:** `docs/superpowers/specs/2026-08-29-minio-admin-config-export-import-s7-design.md`

## Global Constraints

- 基线为 `50f322a`；所有 whole-range 检查使用 `50f322a..HEAD`，除非集成控制者记录了经审查的新基线。
- 固定 route：`GET /minio/admin/v3/config`、`PUT /minio/admin/v3/config`，action 为 `admin:ConfigUpdate`。
- GET/PUT 使用 authenticated caller secret 的 SIO；secret 不离开请求进程，不进入 Archive、日志、audit 或测试 artifact。
- PUT plaintext 最大 262144 bytes，ciphertext 最大 262272 bytes；Maxio 继续要求唯一显式 Content-Length 并拒绝 Transfer-Encoding。
- SIO 长度公式为 `41+n+16*ceil(n/16384)`；end-to-end 最大 plaintext 261975，261976 起 server TooLarge；
  262144 只通过 madmin 本地检查，不可到达 server decrypt。
- 只导出/替换 Registry 三键；遗漏 reset；显式 fallback 仍物化 override。
- target/unknown/hidden/forbidden/orphan 不可导入且永不导出；Registry 是唯一 wire catalog。
- blank/comment-only 是全默认 replacement；duplicate line 按出现顺序 last-write-wins。
- import 必须单事务、全部 advisory lock 先于任何 row read、稳定 subsystem/path 顺序。
- changed=0 无 audit/version/reload/broadcast；changed>0 恰好一次 reload 和一次 checked batch broadcast。
- source 必须是字符串 `"admin_api" | "cli" | "console" | "system"`，不是 atom。
- wire raw scalar 先 `Schema.parse/3`；Coordinator typed operation 再 `Schema.cast/3`。
- batch expected versions 固定为 `%{{subsystem, key} => version}`，validators 固定为 `%{subsystem => fun}`；legacy
  single-subsystem wrapper 无损转换。
- batch event 携带 `%{origin: %{node:, instance:}, epoch:, subsystems: changed_subsystems}`；本地 Store 忽略 self-loop，
  远端用有界 `{origin, epoch}` cache 去重。
- PUT 成功固定为空 HTTP 200、无 `x-minio-config-applied`；Maxio 三键仍 hot apply，mc restart 提示不代表实现 restart。
- 不新增 migration；不实现 history、restart、targets、full official catalog、secret/backend/archive job。
- 不得由生产作者自写完成审查。Lane R=协议/fixture，Lane T=RED 测试，Lane B=生产实现，Lane C=task reviewer，Lane D/E=独立 whole-range reviewers，Lane F=验证，Lane G=strict-live，Lane H=STATUS，Lane I=集成。
- 开发中只跑 focused tests、compile 和必要 format；在所有实现/review/live 收口后只跑一次最终成功 `mix precommit`。
- 所有决定 RED/production 的 `VERIFY-AT-IMPL` 必须由 Task 1 或相应实现前的 fixture gate 关闭；Windows mc argv/stdin
  与 ErrorMap 也必须先冻结。Task 11 只复验，不能首次选择实现行为。
- 任何 accepted finding 都先由 Lane T 增加可失败回归，再由 Lane B 修复，再由 Lane C/对应 reviewer 复审。
- 禁止跟踪 live credential、Authorization、caller secret、mc alias 文件、raw ciphertext 或未脱敏 transcript。

---

## File Structure

### New production files

- `lib/maxio/admin/config_kv/archive.ex` — Registry-only archive encode/decode/plan 与 Config facade orchestration。
- `lib/maxio/admin/config_kv/cli.ex` — 有界 stdin/file 读取和不泄值的单/batch CLI result formatter。
- `lib/mix/tasks/maxio.admin.config.export.ex` — 本地 exact plaintext export。
- `lib/mix/tasks/maxio.admin.config.import.ex` — 本地 bounded archive import。

### Modified production files

- `lib/maxio/admin/config_kv/parser.ex` — 抽取跨 subsystem `parse_document/2`，S5 parser 继续叠加单 subsystem 限制。
- `lib/maxio/admin/config_kv/registry.ex` — public/non-sensitive invariant 与 ordered public paths helper。
- `lib/maxio/admin/config_kv/adapter.ex` — HTTP-facing export/import 错误证据与 Archive 调用，不访问 Repo。
- `lib/maxio/admin/config_kv/request.ex` — 泛化 caller-secret encrypted body/response helper，保留 S5 delegate。
- `lib/maxio/config.ex` — `authoritative_snapshot/2`、batch `mutate_many/2` 与 legacy `mutate_subsystem/3` facade；两者只共享 private transaction engine，各自选择互斥 finisher。
- `lib/maxio/config/coordinator.ex` — 唯一 lock/read/validate/persist transaction 算法，以及互斥的 legacy/batch post-commit finisher。
- `lib/maxio/config/store.ex` — batch invalidation、一次 full reload、安全 batch attention。
- `lib/maxio/cluster/notify.ex` — 带 origin/epoch/changed subsystem 的 batch event type。
- `lib/maxio/admin/plug.ex` — GET/PUT exact route、auth-first、SIO/framing、空 200。
- `lib/maxio/admin/authz.ex` — 两条 route 的 ConfigUpdate action 映射。
- `lib/maxio/admin/error_map.ex` — 只添加 fixture 证明需要的窄映射。
- `lib/maxio/compat/external_smoke.ex` — native mc export/import 生命周期和 cleanup。

### New test/fixture files

- `test/fixtures/minio_admin_config_export_import_s7/README.md`
- `test/fixtures/minio_admin_config_export_import_s7/minio_config_archive_wire.json`
- `test/fixtures/minio_admin_config_export_import_s7/madmin_config_archive_limits.json`
- `test/fixtures/minio_admin_config_export_import_s7/mc_config_archive_dispatch.json`
- `test/fixtures/minio_admin_config_export_import_s7/raw_sha256.json`
- `test/maxio/admin/config_export_import_protocol_fixture_test.exs`
- `test/maxio/admin/config_kv_archive_test.exs`
- `test/maxio/admin/config_export_import_endpoint_test.exs`
- `test/maxio/config/coordinator_batch_test.exs`
- `test/maxio/config/coordinator_batch_concurrency_test.exs`
- `test/mix/tasks/maxio_admin_config_export_import_test.exs`

### Modified tests

- `test/maxio/admin/config_kv_parser_test.exs`
- `test/maxio/admin/config_kv_registry_test.exs`
- `test/maxio/admin/config_kv_request_test.exs`
- `test/maxio/admin/plug_test.exs`
- `test/maxio/admin/authz_test.exs`
- `test/maxio/admin/error_map_test.exs`
- `test/maxio/config/config_test.exs`
- `test/maxio/config/coordinator_test.exs`
- `test/maxio/config/coordinator_postcommit_test.exs`
- `test/maxio/config/coordinator_concurrency_test.exs`
- `test/maxio/config/store_batch_event_test.exs`
- `test/mix/tasks/maxio_admin_config_test.exs`
- `test/maxio/compat/external_smoke_test.exs`

### Intentionally unchanged

- `lib/maxio/config/runtime_config.ex`
- `lib/maxio/config/runtime_config_audit.ex`
- `priv/repo/migrations/*`
- `lib/maxio/s3/plugs/response_transform_policy.ex`（只做回归测试，除非 RED 证明既有 Admin no-transform 已坏）

---

### Task 1: Freeze S7 protocol and native-client fixtures

**Owner:** Lane R protocol researcher. **Reviewer:** Lane C fixture reviewer，不能参与 fixture 编写。

**Files:**

- Create: `test/fixtures/minio_admin_config_export_import_s7/README.md`
- Create: `test/fixtures/minio_admin_config_export_import_s7/minio_config_archive_wire.json`
- Create: `test/fixtures/minio_admin_config_export_import_s7/madmin_config_archive_limits.json`
- Create: `test/fixtures/minio_admin_config_export_import_s7/mc_config_archive_dispatch.json`
- Create: `test/fixtures/minio_admin_config_export_import_s7/raw_sha256.json`
- Create: `test/maxio/admin/config_export_import_protocol_fixture_test.exs`

**Interfaces:**

- Consumes: pinned MinIO `7aac2a2...`、madmin-go `4b504b8...`、mc `77f82e1...` 源码与 Lane R raw captures。
- Produces: W1–W5 的 immutable source/live facts，供所有后续 RED 使用；所有会影响实现的字段在离开 Task 1 前已
  `source_verified` 或 `live_verified`，不产生 production behavior。

- [ ] **Step 1: Write fixture provenance.** README 逐项记录 commit、source file/function、capture OS、命令、
  source-derived/live 分类、脱敏规则和 raw artifact SHA-256。W1–W5 固定为：W1 madmin local plaintext limits/SIO
  frame formula；
  W2 direct server ciphertext/framing；W3 export bytes/order；W4 import default/LWW/unknown；W5 native mc dispatch/
  success/restart output。无法 live 的 W 项必须写 `VERIFY-AT-IMPL` 与缺失能力，不能写 PASS。

- [ ] **Step 2: Encode the known fixed payload.** `minio_config_archive_wire.json` 至少包含 exact UTF-8/base64、
  byte length 和 SHA：

  ```text
  s3 clock_skew_ms=900000 \n
  listing sql_hard_limit=100000 \n
  prometheus_metrics public=false \n
  ```

  期望 89 bytes，SHA-256
  `c8fe86493cce0083169223b68b59e69612ceeaff7ff45721b45eb85e7eff4141`；fixture test 必须从 decoded bytes
  重算两者。该条 evidence class 必须是 `local_design_expected`，不能写 upstream/source/live fact。

- [ ] **Step 3: Encode limits and replacement facts.** `madmin_config_archive_limits.json` 固定
  `encrypted_length(n)=41+n+16*ceil(n/16384)`、empty plaintext→local EOF/zero request、1..262144 通过 local check、
  262145+ local ErrTooLarge/zero request；server ciphertext CL -1 或 >262272→TooLarge，CL 0→decrypt→BadJSON；
  plaintext 261975→ciphertext 262272/end-to-end PASS，261976→262273/server TooLarge，262144→262441/local accepted
  but server rejected。`minio_config_archive_wire.json` 固定 blank/comment-only→full defaults、duplicate→LWW、unknown→
  whole import failure、PUT 200 empty/no applied header。

- [ ] **Step 4: Close native mc and ErrorMap decisions before RED.** `mc_config_archive_dispatch.json` 记录 export/import
  exact Windows argv、stdin/file transport、human/JSON stdout/stderr/exit 和固定 restart 分支。另在 wire fixture 固定
  每个会进入 Task 6/7 的 status/code/message/priority。若 pinned source 不能决定 Windows 或 error parser 行为，Lane R
  必须在 Task 2/6 前运行 pre-implementation live capture；仍为 `VERIFY-AT-IMPL` 时对应 RED/production task BLOCKED。

- [ ] **Step 5: Write fixture integrity tests.** 测试必须读取 JSON、验证 pinned hashes、禁止 mutable branch URL，
  重算每个 raw plaintext payload SHA/length，并断言所有 implementation-decision 字段是 `source_verified` 或
  `live_verified`；只允许不决定 RED/production 的 observation 保留带原因 `VERIFY-AT-IMPL`。SIO salt/nonce 随机，
  fixture/test 只断言 frame length、decrypt plaintext 和错误-secret oracle，不固定 ciphertext bytes/SHA。

  ```elixir
  assert byte_size(payload) == 89
  assert Base.encode16(:crypto.hash(:sha256, payload), case: :lower) ==
           "c8fe86493cce0083169223b68b59e69612ceeaff7ff45721b45eb85e7eff4141"
  assert fixture["put_success"]["applied_header"] == "absent"
  assert fixture["fresh_archive"]["evidence_class"] == "local_design_expected"
  assert sio_length.(261_975) == 262_272
  assert sio_length.(261_976) == 262_273
  ```

- [ ] **Step 6: Run fixture GREEN.** Run:

  ```powershell
  mix test test/maxio/admin/config_export_import_protocol_fixture_test.exs
  git diff --check -- test/fixtures/minio_admin_config_export_import_s7 test/maxio/admin/config_export_import_protocol_fixture_test.exs
  ```

- [ ] **Step 7: Commit fixture checkpoint.** Run:

  ```powershell
  git add test/fixtures/minio_admin_config_export_import_s7 test/maxio/admin/config_export_import_protocol_fixture_test.exs
  git commit -m "test(compat): freeze config export import protocol"
  ```

- [ ] **Step 8: Independent fixture review and decision gate.** Lane C checks every fact against pinned source/raw SHA，重点拒绝把
  local-design/source-derived/fake transcript 写成 upstream/live。Review 必须列出零个仍会决定后续实现的 VERIFY，包含
  Windows mc argv/stdin 和 ErrorMap；否则不允许进入相应 task。Accepted fixture correction commits as
  `test(compat): correct config archive fixtures`，随后重新审查。

### Task 2: Specify Archive, Registry and document parsing with RED tests

**Owner:** Lane T test author. **Reviewer:** Lane C. Lane B 不参与 RED 编写。

**Files:**

- Create: `test/maxio/admin/config_kv_archive_test.exs`
- Modify: `test/maxio/admin/config_kv_parser_test.exs`
- Modify: `test/maxio/admin/config_kv_registry_test.exs`

**Interfaces:**

- Consumes: Task 1 exact bytes and semantic fixtures。
- Produces: required APIs `Registry.public_paths/0`、`Parser.parse_document/2`、`Archive.export/1`、
  `Archive.decode_and_plan/1`、`Archive.import_config/2` 的 RED contract。

- [ ] **Step 1: Write Registry RED.** 断言 ordered paths 精确为：

  ```elixir
  assert Registry.public_paths() == [
           {:s3, :clock_skew_ms},
           {:listing, :sql_hard_limit},
           {:prometheus_metrics, :public}
         ]
  assert Enum.all?(Registry.entries(), &(&1.sensitive? == false))
  ```

  增加 injected sensitive/hidden/forbidden entry 的 fail-closed invariant 测试，不允许静默过滤。

- [ ] **Step 2: Write document parser RED.** 用多行、blank、comment、quoted value、重复 subsystem line 和
  duplicate key 覆盖 `parse_document/2`；返回值固定为输入顺序的 line maps：

  ```elixir
  {:ok,
   [
     %{line: 1, wire_subsystem: "s3", patches: [{"clock_skew_ms", "1"}]},
     %{line: 2, wire_subsystem: "s3", patches: [{"clock_skew_ms", "2"}]}
   ]}
  ```

  S5 `parse_set_detailed/2` 仍拒绝 cross-subsystem，证明 scanner refactor 不改变 S5。

- [ ] **Step 3: Write Archive export RED.** 注入 Config facade fake snapshot，断言只请求
  `Registry.public_paths/0` 一次、输出 Task 1 的 89 exact bytes/order/tail-space/LF，并证明 hidden/forbidden/orphan
  即使存在 fake snapshot 也不进入 wire。

- [ ] **Step 4: Write import planner RED.** 断言 wire raw scalar 必须先通过 `Schema.parse/3` 生成 typed set、遗漏生成
  reset、explicit fallback 仍 set、blank/comment-only 三键全 reset、duplicate LWW、target/unknown/hidden/forbidden/orphan
  fail before config fake mutation。固定 operation groups 为 binary subsystem order；加入 raw string 可 parse、但若直接
  当 typed value 交 `Schema.cast/3` 会暴露边界错误的回归向量。

  ```elixir
  assert {:ok,
          [
            {:listing, [{:reset, :sql_hard_limit}]},
            {:prometheus_metrics, [{:set, :public, true}]},
            {:s3, [{:set, :clock_skew_ms, 900_000}]}
          ]} = Archive.decode_and_plan(plaintext)
  ```

- [ ] **Step 5: Write purity/redaction RED.** invalid UTF-8、`Schema.parse/3` invalid raw scalar、sensitive prefix 都在
  mutation fake 被调用前失败；错误 evidence 只有 closed-vocabulary safe `reason` 加 stage/subsystem/key_count，绝不含
  submitted value 或 dynamic secret；`reason` 映射必须消费 Task 1 已冻结矩阵。

- [ ] **Step 6: Run tests and confirm RED.** Run:

  ```powershell
  mix test test/maxio/admin/config_kv_registry_test.exs test/maxio/admin/config_kv_parser_test.exs test/maxio/admin/config_kv_archive_test.exs
  ```

  Expected: FAIL only because new helpers/module or required semantics are absent；既有 S5 assertions 仍通过。

- [ ] **Step 7: Commit RED checkpoint.** Run:

  ```powershell
  git add test/maxio/admin/config_kv_registry_test.exs test/maxio/admin/config_kv_parser_test.exs test/maxio/admin/config_kv_archive_test.exs
  git commit -m "test(admin): specify public config archives"
  ```

- [ ] **Step 8: Independent RED review.** Lane C 核对测试断言的是公开结果而非私有函数调用，确认没有扩大 catalog、
  没有在测试中复制 parser implementation。

### Task 3: Specify authoritative snapshot and atomic multi-subsystem mutation with RED tests

**Owner:** Lane T. **Reviewer:** Lane C.

**Files:**

- Create: `test/maxio/config/coordinator_batch_test.exs`
- Create: `test/maxio/config/coordinator_batch_concurrency_test.exs`
- Modify: `test/maxio/config/config_test.exs`
- Modify: `test/maxio/config/coordinator_test.exs`
- Modify: `test/maxio/config/coordinator_postcommit_test.exs`
- Modify: `test/maxio/config/coordinator_concurrency_test.exs`
- Modify: `test/maxio/config/store_batch_event_test.exs`
- Modify: `test/support/config_batch_schema.ex`

**Interfaces:**

- Consumes: existing Coordinator dependency injection/checkpoint、RuntimeConfig/Audit schemas、Store/Notify fakes。
- Produces: RED contract for `Config.authoritative_snapshot/2`、`Config.mutate_many/2`、
  `Coordinator.mutate_many/2` and origin-aware batch invalidation。

- [ ] **Step 1: Write one-snapshot RED.** Attach telemetry to the real Repo and capture normalized SQL、ordered params and result
  `num_rows`。Assert one authoritative SELECT, sorted explicit path params, typed fallback/runtime/source/version map, corrupt
  registered value fails closed and orphan is neither requested nor returned。

  ```elixir
  assert {:ok, snapshot} = Config.authoritative_snapshot(Registry.public_paths(), repo: repo)
  assert_receive {:authoritative_select, requested_paths}
  refute_receive {:authoritative_select, _second_query}
  assert snapshot[{:s3, :clock_skew_ms}].source in [:runtime, :fallback]
  ```

- [ ] **Step 2: Write lock-order RED.** Use real Repo telemetry to capture each advisory-lock SQL/ordered lock param、subsequent
  SELECT/FOR UPDATE SQL/params and result `num_rows`；assert all sorted subsystem lock params precede the first row read。Add checkpoints
  `{:after_advisory_lock, subsystem}` and `:before_first_row_read` to make ordering observable。另断言 legacy
  `mutate_subsystem/3` checkpoint callback 仍只收到原有 `:after_advisory_lock` 调用且次数/顺序不变；batch-only phase 不得
  泄漏给 legacy callback。

- [ ] **Step 3: Write all-or-nothing RED.** Seed three override rows；make the last subsystem validator, runtime insert and audit
  insert fail in separate tests；after each failure assert all rows/versions/audits equal pre-state。

- [ ] **Step 4: Write semantic and option-shape RED.** Cover explicit fallback absent→v1 set audit、omitted existing→reset audit、
  same set and absent reset no-op、shared string source `"admin_api"`/principal/access_key/request_id、stable changed_paths/outcomes
  and hidden/orphan preservation。Batch `expected_versions` 必须是 `%{{subsystem, key} => version_or_nil}`；在
  `test/support/config_batch_schema.ex` 定义两个 subsystem 都合法注册的同名 key，并用它证明 path-keyed versions/outcomes
  无冲突。`validators` 必须是 `%{subsystem => fun}`，每个只收到本 subsystem candidate 且恰好
  一次。Legacy expected_version/key-map/validator wrapper 必须无损转换并保留 S5 result shape；atom source 必须拒绝。

- [ ] **Step 5: Write concurrency RED without sleeps.** Use coordinator checkpoints/messages and `Task.async` to hold the first
  transaction after advisory locks；start overlapping single set/reset and reversed batch，release via message，assert no deadlock、
  no lost update and final result matches serialization。Use `Task.yield/2`/monitor, never `Process.sleep/1`。

- [ ] **Step 6: Write result/post-commit RED.** Assert shared transaction engine returns committed plan without Store/Notify calls。
  Assert result separates `touched_subsystems` from
  `changed_subsystems`；broadcast/reload reason only use changed set。Global no-op invokes zero callbacks；changed batch invokes one
  sync `Store.load_all!` and one checked event：

  ```elixir
  {:config_changed_batch,
   %{origin: %{node: node_name, instance: instance_token},
     epoch: positive_integer,
     subsystems: sorted_changed_subsystems}}
  ```

  Reload/broadcast failure returns committed result plus safe attention containing names/status only。

  In separate legacy assertions，`mutate_subsystem/3` using the same engine must invoke exactly one legacy reload reason and exactly
  one `broadcast_checked({:config_changed, subsystem})`，with zero batch events。Batch `mutate_many/2` must emit exactly one new event
  and zero legacy events；neither path may double reload/broadcast。

- [ ] **Step 7: Write real PubSub loopback/dedupe RED.** Use `start_supervised!/1` to run real `Phoenix.PubSub` and subscribed
  real Store，execute a changed batch and assert local synchronous reload plus PubSub self-delivery totals exactly one reload。Send a
  different-origin event twice；assert first reloads once and identical `{origin, epoch}` replay is ignored。Inspect a bounded dedupe
  state/status，not a Notify fake。Transport failure tests may continue using fake。

- [ ] **Step 8: Preserve S5 shape RED.** Existing `mutate_subsystem/3` and `Config.set/reset` tests must still observe scalar
  subsystem、key-keyed outcomes and exactly one legacy event；single-subsystem and batch facades share only the private transaction
  engine，then select legacy and batch finishers respectively，never delegate one public facade to the other。

- [ ] **Step 9: Run and confirm RED.** Run:

  ```powershell
  mix test test/maxio/config/config_test.exs test/maxio/config/coordinator_batch_test.exs test/maxio/config/coordinator_batch_concurrency_test.exs test/maxio/config/coordinator_test.exs test/maxio/config/coordinator_postcommit_test.exs test/maxio/config/coordinator_concurrency_test.exs test/maxio/config/store_batch_event_test.exs
  ```

  Expected: new batch/snapshot assertions FAIL for missing APIs/events；unrelated S5 assertions pass。

- [ ] **Step 10: Commit RED checkpoint.** Run:

  ```powershell
  git add test/maxio/config/config_test.exs test/maxio/config/coordinator_batch_test.exs test/maxio/config/coordinator_batch_concurrency_test.exs test/maxio/config/coordinator_test.exs test/maxio/config/coordinator_postcommit_test.exs test/maxio/config/coordinator_concurrency_test.exs test/maxio/config/store_batch_event_test.exs test/support/config_batch_schema.ex
  git commit -m "test(config): specify atomic multi subsystem mutations"
  ```

- [ ] **Step 11: Independent RED review.** Lane C 特别检查“全部 advisory locks 先于任何 read”、path-key expected version、
  per-subsystem validator、legacy option/checkpoint wrapper、字符串 source、不存在行的首写、rollback 后 audit 归零、
  touched/changed 分离、真实 PubSub self-loop 去重、无 sleep、postcommit 不被误当 transaction failure。

### Task 4: Implement the unified Config transaction and cluster invalidation

**Owner:** Lane B core implementer. **Reviewer:** Lane C，且不得是 Task 3 测试作者上下文。

**Files:**

- Modify: `lib/maxio/config.ex`
- Modify: `lib/maxio/config/coordinator.ex`
- Modify: `lib/maxio/config/store.ex`
- Modify: `lib/maxio/cluster/notify.ex`

**Interfaces:**

- Consumes: Task 3 RED contracts。
- Produces:

  ```elixir
  Config.authoritative_snapshot(paths, opts)
  Config.mutate_many([{subsystem, operations}], opts)
  Coordinator.mutate_many([{subsystem, operations}], opts)
  {:config_changed_batch,
   %{origin: %{node: node(), instance: binary()}, epoch: pos_integer(),
     subsystems: sorted_changed_subsystems}}
  ```

- [ ] **Step 1: Implement one-statement snapshot.** Validate atom path tuples，build one Ecto query over exact subsystem/key
  pairs，decode with Schema and merge fallback。Do not call `Store.reconcile!` or loop `authoritative_effective/3`。

  ```elixir
  def authoritative_snapshot(paths, opts \\ []) when is_list(paths) do
    Coordinator.authoritative_snapshot(paths, opts)
  end
  ```

  If query ownership fits a focused internal helper，keep it inside Coordinator/Config rather than creating a second storage
  authority。

- [ ] **Step 2: Normalize batch input and options.** Reject malformed/unknown/forbidden operations before transaction，merge repeated
  groups，sort by `Atom.to_string(subsystem)`，and call `Schema.cast/3` on every already-typed set value。Validate source once as a
  RuntimeConfig string，reject atoms。Require batch `expected_versions` path keys and `validators` subsystem keys before transaction。

- [ ] **Step 3: Implement exact transaction order.** Inside one Repo transaction acquire every advisory lock first，emit batch test
  checkpoints，then lock/load sorted rows。Build all candidate maps and validate every candidate before `persist_plans` writes the
  first row/audit。

  ```elixir
  sorted_groups
  |> Enum.each(fn {subsystem, _ops} -> acquire_advisory_lock!(repo, subsystem) end)

  checkpoint(dependencies, :before_first_row_read)
  current = lock_and_load_groups(repo, sorted_groups, schema)
  ```

  For each subsystem compare path-keyed expected versions，then invoke only its validator once。The legacy single-subsystem wrapper
  converts `expected_version:`/bare-key expected map/`validator:` to batch shape，maps its structured lock checkpoint back to the old
  atom callback，and hides batch-only checkpoints。

- [ ] **Step 4: Separate transaction engine from post-commit.** Refactor the shared private engine to stop after Repo returns the
  committed plan；it must not call Store or Notify。`mutate_many/2` and `mutate_subsystem/3` each call that engine and then select a
  private, non-caller-controlled finisher。Return tuple-keyed outcomes、sorted `touched_subsystems`、`changed_subsystems` derived only
  from changed_paths and no values；legacy wrapper converts the same plan back to S5 shape。
  `mutate_subsystem/3` delegates to one group and converts outcomes back to the exact S5 shape。

- [ ] **Step 5: Implement the batch finisher once with origin.** Global no-op exits before callbacks。Changed batch obtains a stable
  node-local Store instance token and monotonic request epoch，calls one full reload with `{:write_batch, changed_paths}`，then one
  checked origin-aware batch broadcast containing only changed_subsystems。Extend Store attention to bounded known path/subsystem
  names，never values。This finisher never sends `{:config_changed, subsystem}`。

- [ ] **Step 6: Preserve the legacy finisher and handle batch self-loop.** `mutate_subsystem/3` uses the committed plan but keeps
  exactly one S5 reload reason `{:write, subsystem, changed_keys}` and exactly one checked
  `{:config_changed, subsystem}` event；it never invokes the batch finisher。For batch events，extend Notify type and Store
  `handle_info` to validate the event map。Store ignores
  its own origin instance after synchronous reload；for a different origin it reloads once and remembers `{origin, epoch}` in a bounded
  recent cache，then ignores replay。Malformed event maps fall through safely；origin contains no caller identity/secret/value。

- [ ] **Step 7: Run focused GREEN.** Run:

  ```powershell
  mix test test/maxio/config/config_test.exs test/maxio/config/coordinator_batch_test.exs test/maxio/config/coordinator_batch_concurrency_test.exs test/maxio/config/coordinator_test.exs test/maxio/config/coordinator_postcommit_test.exs test/maxio/config/coordinator_concurrency_test.exs test/maxio/config/store_batch_event_test.exs
  mix compile --warnings-as-errors
  mix format --check-formatted lib/maxio/config.ex lib/maxio/config/coordinator.ex lib/maxio/config/store.ex lib/maxio/cluster/notify.ex test/maxio/config
  ```

- [ ] **Step 8: Commit implementation checkpoint.** Run:

  ```powershell
  git add lib/maxio/config.ex lib/maxio/config/coordinator.ex lib/maxio/config/store.ex lib/maxio/cluster/notify.ex
  git commit -m "feat(config): add atomic multi subsystem mutations"
  ```

- [ ] **Step 9: Independent task review.** Lane C audits SQL snapshot count、lock/read order、single-writer delegation、rollback、
  no-op、postcommit 和 rolling-node reconcile。Accepted findings use Lane T RED first，then commit
  `fix(config): correct batch mutation semantics` and re-review。

### Task 5: Implement the Registry-only Archive domain

**Owner:** Lane B Archive implementer，fresh context from Task 4 preferred. **Reviewer:** Lane C.

**Files:**

- Create: `lib/maxio/admin/config_kv/archive.ex`
- Modify: `lib/maxio/admin/config_kv/parser.ex`
- Modify: `lib/maxio/admin/config_kv/registry.ex`

**Interfaces:**

- Consumes: Task 1 fixture、Task 2 RED、Task 4 Config APIs。
- Produces: stable 89-byte fresh codec、full replacement plan and shared multi-line parser；no transport/SIO logic。

- [ ] **Step 1: Add ordered public paths invariant.** Implement `Registry.public_paths/0` from static entries and a checked
  export-entry helper that errors when any entry is sensitive/hidden/forbidden or lacks static atoms。Do not dynamically create atoms。

- [ ] **Step 2: Extract `Parser.parse_document/2`.** Reuse existing scanner/tokenizer；return ordered line maps。Rewrite
  `parse_set_detailed/2` as a thin same-subsystem restriction over the shared document output，preserving every S5 error/result。

- [ ] **Step 3: Implement pure encode.** Iterate Registry entries，fetch typed snapshot values，use existing KVS renderer rules and
  append exact ASCII space+LF。Do not enumerate a map。

  ```elixir
  entries
  |> Enum.map(fn entry ->
    path = {entry.core_subsystem, entry.core_key}
    render_entry(entry, Map.fetch!(snapshot, path).value)
  end)
  |> IO.iodata_to_binary()
  ```

- [ ] **Step 4: Implement pure decode/plan.** Seed every Registry path as omitted，apply ordered parsed patches LWW，call
  `Schema.parse/3` on each wire raw scalar to obtain typed values，then emit set for seen and reset for omitted。Coordinator will
  independently `Schema.cast/3` these typed operations。Blank/comment-only therefore returns three resets。Reject target/unknown/
  hidden/forbidden before Config mutation。

- [ ] **Step 5: Implement facade orchestration.** `export/1` requests exactly `Registry.public_paths/0` once；
  `import_config/2` calls `decode_and_plan/1` then `Config.mutate_many/2`。Return safe error evidence only。

- [ ] **Step 6: Run Archive GREEN and S5 parser regression.** Run:

  ```powershell
  mix test test/maxio/admin/config_export_import_protocol_fixture_test.exs test/maxio/admin/config_kv_registry_test.exs test/maxio/admin/config_kv_parser_test.exs test/maxio/admin/config_kv_archive_test.exs test/maxio/admin/config_kv_adapter_test.exs
  mix compile --warnings-as-errors
  mix format --check-formatted lib/maxio/admin/config_kv/archive.ex lib/maxio/admin/config_kv/parser.ex lib/maxio/admin/config_kv/registry.ex test/maxio/admin/config_kv_archive_test.exs test/maxio/admin/config_kv_parser_test.exs test/maxio/admin/config_kv_registry_test.exs
  ```

- [ ] **Step 7: Commit implementation checkpoint.** Run:

  ```powershell
  git add lib/maxio/admin/config_kv/archive.ex lib/maxio/admin/config_kv/parser.ex lib/maxio/admin/config_kv/registry.ex
  git commit -m "feat(admin): add public config archive domain"
  ```

- [ ] **Step 8: Independent task review.** Lane C audits Registry-only exposure、exact bytes、blank replacement、LWW、explicit
  fallback set、no Repo/Store/SIO dependency。Accepted fixes commit as `fix(admin): correct config archive projection` after RED。

### Task 6: Specify Admin route, SIO, framing and errors with RED tests

**Owner:** Lane T. **Reviewer:** Lane C.

**Files:**

- Create: `test/maxio/admin/config_export_import_endpoint_test.exs`
- Modify: `test/maxio/admin/config_kv_request_test.exs`
- Modify: `test/maxio/admin/plug_test.exs`
- Modify: `test/maxio/admin/authz_test.exs`
- Modify: `test/maxio/admin/error_map_test.exs`

**Interfaces:**

- Consumes: Task 1 wire/error fixture、Task 5 Archive API。
- Produces: RED contract for exact GET/PUT routes、caller-secret SIO、auth precedence、dual limits、empty 200/no applied header。

**Entry gate:** Task 1 must have zero unresolved implementation-decision fields for HTTP errors/framing/SIO；每个 ErrorMap
status/code/message/priority must be source/live verified before this RED task starts。

- [ ] **Step 1: Write route/auth RED.** Assert anonymous and action-denied calls fail before Archive/body reader；root and authorized
  identity use `admin:ConfigUpdate`。Adjacent unsupported methods/paths keep existing structured Admin fallback。

- [ ] **Step 2: Write caller-secret RED.** Two credentials with distinct secrets prove GET ciphertext decrypts only with the caller
  secret and PUT ciphertext encrypted with another/root secret fails。No test logs raw secret。

- [ ] **Step 3: Write bounded request/SIO RED.** Cover unique CL、duplicate/missing/nondecimal/negative、TE、declared/actual
  mismatch、payload hash、decrypt、UTF-8。Assert formula `41+n+16*ceil(n/16384)` and exact boundaries：plaintext 261975→
  ciphertext 262272 accepted/decrypted；261976→262273 rejected before decrypt；262144→262441 and therefore only client-local
  accepted/server rejected；262145+ madmin local reject。Random salt/nonce means assertions use length/framing/decrypt oracle，never
  exact ciphertext bytes/SHA。Assert fixture error priority。

- [ ] **Step 4: Write GET response RED.** Decrypt randomized response and compare exact plaintext archive；assert ciphertext length
  by formula、exact CL、no TE/CE、
  Admin `Cache-Control` contains `no-transform`。Treat upstream gzhttp compression difference as deliberate Maxio repair。

- [ ] **Step 5: Write PUT success RED.** Valid import returns HTTP 200、zero body、Content-Length 0 or fixture-proven equivalent、
  no TE/CE and absent `x-minio-config-applied`；Archive mutation result still proves one hot postcommit path。

- [ ] **Step 6: Write safe failure/log RED.** target/unknown-prefix/hidden/forbidden、DB rollback、postcommit attention and every
  fixture error mapping must omit plaintext value、ciphertext 和 secret。Do not assert invented `XMaxio*` codes。

- [ ] **Step 7: Run and confirm RED.** Run:

  ```powershell
  mix test test/maxio/admin/config_export_import_endpoint_test.exs test/maxio/admin/config_kv_request_test.exs test/maxio/admin/plug_test.exs test/maxio/admin/authz_test.exs test/maxio/admin/error_map_test.exs
  ```

  Expected: new routes/helpers FAIL；existing Admin/S5 assertions pass。

- [ ] **Step 8: Commit RED checkpoint.** Run:

  ```powershell
  git add test/maxio/admin/config_export_import_endpoint_test.exs test/maxio/admin/config_kv_request_test.exs test/maxio/admin/plug_test.exs test/maxio/admin/authz_test.exs test/maxio/admin/error_map_test.exs
  git commit -m "test(admin): specify config archive transport"
  ```

- [ ] **Step 9: Independent RED review.** Lane C checks auth-before-body、caller identity isolation、all byte boundaries、empty 200/
  no applied、no-transform 与安全错误证据。

### Task 7: Implement Admin config export/import transport

**Owner:** Lane B transport implementer. **Reviewer:** Lane C.

**Files:**

- Modify: `lib/maxio/admin/config_kv/adapter.ex`
- Modify: `lib/maxio/admin/config_kv/request.ex`
- Modify: `lib/maxio/admin/plug.ex`
- Modify: `lib/maxio/admin/authz.ex`
- Modify: `lib/maxio/admin/error_map.ex`

**Interfaces:**

- Consumes: Task 5 Archive API and Task 6 RED。
- Produces: authenticated GET/PUT `/minio/admin/v3/config` with exact bounded caller-secret SIO。

- [ ] **Step 1: Generalize encrypted request helpers.** Add archive-neutral bounded read/encrypt helpers while keeping S5 method
  delegates。Before decrypt reject ciphertext >262272；after decrypt retain defense `byte_size(plaintext) <= 262_144`，but document
  reachable maximum 261975 from the frozen SIO formula。Before GET encrypt check plaintext local policy and actual randomized
  ciphertext length；never predict/fix salt/nonce bytes。

- [ ] **Step 2: Add Adapter methods.** Implement `export_config(opts)` and `import_config(plaintext, opts)` as error-evidence
  boundaries around Archive；stage values limited to `:parser | :exposure | :type | :database | :postcommit`，never include value。
  HTTP mutation opts use source string `"admin_api"`。

- [ ] **Step 3: Add exact Plug routes.** Route GET/PUT before generic Admin fallback，authorize ConfigUpdate before reading body，
  extract caller secret/access key from authenticated SigV4 context and pass only secret to Request envelope functions。

  ```elixir
  {"GET", "/minio/admin/v3/config"} -> handle_config_export(conn)
  {"PUT", "/minio/admin/v3/config"} -> handle_config_import(conn)
  ```

- [ ] **Step 4: Render exact success.** GET returns fixture-proven SIO response framing。PUT always returns empty 200 and must not
  set `x-minio-config-applied`，even when internal result says local reload `:ok`。Do not return JSON `null`/`{}`/LF。

- [ ] **Step 5: Add only fixture-backed errors.** Reuse existing Admin codes/messages where fixture proves mapping；keep unknown-prefix
  safety rejection and forbidden AccessDenied ordering。No broad ErrorMap clause。

- [ ] **Step 6: Add safe structured logs.** Log action/request_id/known subsystem names/count/committed/postcommit status；do not log
  Archive plaintext、values、ciphertext、caller secret or full unsafe exception inspect。

- [ ] **Step 7: Run transport GREEN and adjacent regressions.** Run:

  ```powershell
  mix test test/maxio/admin/config_export_import_endpoint_test.exs test/maxio/admin/config_kv_request_test.exs test/maxio/admin/config_kv_endpoint_test.exs test/maxio/admin/plug_test.exs test/maxio/admin/authz_test.exs test/maxio/admin/error_map_test.exs test/maxio/admin/envelope_test.exs
  mix compile --warnings-as-errors
  mix format --check-formatted lib/maxio/admin/config_kv/adapter.ex lib/maxio/admin/config_kv/request.ex lib/maxio/admin/plug.ex lib/maxio/admin/authz.ex lib/maxio/admin/error_map.ex test/maxio/admin
  ```

- [ ] **Step 8: Commit implementation checkpoint.** Run:

  ```powershell
  git add lib/maxio/admin/config_kv/adapter.ex lib/maxio/admin/config_kv/request.ex lib/maxio/admin/plug.ex lib/maxio/admin/authz.ex lib/maxio/admin/error_map.ex
  git commit -m "feat(admin): add config export import endpoints"
  ```

- [ ] **Step 9: Independent task review.** Lane C audits auth/query/body priority、caller secret、bounds、SIO/framing、no applied、
  error/log redaction and no S3 surface regression。Accepted fixes follow RED-first and commit
  `fix(admin): correct config archive transport`。

### Task 8: Specify local CLI and native mc smoke with RED tests

**Owner:** Lane T. **Reviewer:** Lane C.

**Files:**

- Create: `test/mix/tasks/maxio_admin_config_export_import_test.exs`
- Modify: `test/mix/tasks/maxio_admin_config_test.exs`
- Modify: `test/maxio/compat/external_smoke_test.exs`

**Interfaces:**

- Consumes: Task 1 native client fixture、Task 5 Archive、Task 7 HTTP。
- Produces: RED contract for bounded local file/stdin tasks、safe formatter、native mc human/JSON lifecycle/cleanup。

**Entry gate:** Task 1 must have source/live verified Windows native mc argv、stdin/file transport and human/JSON dispatch。These
cannot remain `VERIFY-AT-IMPL` when Task 8 begins。

- [ ] **Step 1: Write Mix export RED.** Start supervised Repo/Store dependencies；assert no-arg task writes exact plaintext archive
  and only plaintext to stdout。Invalid argv exits usage without DB mutation。

- [ ] **Step 2: Write Mix import RED.** Cover path and `-` stdin with a reader fake that yields empty `:eof`、multiple short reads、
  exact 262144 total、262145 sentinel、and midstream `{:error, reason}`。Empty EOF must return `<<>>` and reset all；short read must
  continue to EOF；limit+1/error must not call Archive。Also cover blank/comment-only、explicit fallback materialization、second
  identical no-op and file-not-found。Mutation summary excludes submitted values。

- [ ] **Step 3: Write formatter regression RED.** Shared CLI formatter accepts S5 scalar and S7 tuple-keyed batch result，sorts paths，
  emits committed/reload/broadcast attention without inspecting outcomes values。Existing get/set/reset outputs remain exact。

- [ ] **Step 4: Write fake-runner ExternalSmoke RED.** Require explicit disposable/known-baseline opt-in；without it import probes
  must be BLOCKED before native command。Assert frozen native mc argv/global `--json` position、binary archive capture、import
  stdin/file transport、restart transcript、metrics 403/200 transition、second no-op and cleanup by direct Config reset or disposable
  environment teardown。Assert exported plaintext is never used as provenance restore。Use separate alias/config dir per flow。

- [ ] **Step 5: Write failure/cleanup RED.** Primary import/data-plane failure remains primary blocker；direct Config reset or isolated
  teardown cleanup always runs and cleanup failure is separately recorded。Assert smoke never promises arbitrary remote no-trace and
  records audit-history residue unless database is destroyed。Fake/source evidence fields must never say live PASS。

- [ ] **Step 6: Run and confirm RED.** Run:

  ```powershell
  mix test test/mix/tasks/maxio_admin_config_export_import_test.exs test/mix/tasks/maxio_admin_config_test.exs test/maxio/compat/external_smoke_test.exs
  ```

  Expected: missing tasks/formatter/smoke steps FAIL；existing CLI/smoke lifecycle remains green。

- [ ] **Step 7: Commit RED checkpoint.** Run:

  ```powershell
  git add test/mix/tasks/maxio_admin_config_export_import_test.exs test/mix/tasks/maxio_admin_config_test.exs test/maxio/compat/external_smoke_test.exs
  git commit -m "test(compat): specify config archive workflows"
  ```

- [ ] **Step 8: Independent RED review.** Lane C 检查 stdout/stderr、值泄漏、Windows binary stdin、primary/cleanup blockers、
  fake/live labels和数据面断言。

### Task 9: Implement local CLI and ExternalSmoke workflows

**Owner:** Lane B CLI/smoke implementer. **Reviewer:** Lane C.

**Files:**

- Create: `lib/maxio/admin/config_kv/cli.ex`
- Create: `lib/mix/tasks/maxio.admin.config.export.ex`
- Create: `lib/mix/tasks/maxio.admin.config.import.ex`
- Modify: `lib/mix/tasks/maxio.admin.config.set.ex`
- Modify: `lib/mix/tasks/maxio.admin.config.reset.ex`
- Modify: `lib/maxio/compat/external_smoke.ex`

**Interfaces:**

- Consumes: Task 8 RED、Archive APIs and exact native mc fixture。
- Produces: first-party local observability and strict-live-capable native mc lifecycle。

- [ ] **Step 1: Implement bounded cumulative CLI input.** For files inspect size before read，but use the same bounded reader to
  defend stat/read races。For stdin/file, repeatedly read at most a fixed chunk until EOF、262145 sentinel or error；continue after short
  reads。Use binary mode and preserve LF bytes。

  ```elixir
  @max_plaintext 262_144

  defp read_bounded(io, chunks, total) do
    remaining = @max_plaintext + 1 - total

    case IO.binread(io, min(16_384, remaining)) do
      :eof -> {:ok, chunks |> Enum.reverse() |> IO.iodata_to_binary()}
      {:error, reason} -> {:error, {:config_io_failed, safe_io_reason(reason)}}
      data when total + byte_size(data) > @max_plaintext -> {:error, :config_too_large}
      data -> read_bounded(io, [data | chunks], total + byte_size(data))
    end
  end
  ```

  The initial `:eof` returns `{:ok, <<>>}` and is a legal reset-all archive；do not translate it to madmin client's local EOF rule，
  because this is the first-party Mix CLI domain contract。

- [ ] **Step 2: Implement Mix tasks.** Boot app/Repo according to existing admin config tasks，export uses Archive exact stdout，
  import uses Archive with source string `"cli"`。Usage accepts only fixture-reviewed argv；no loopback HTTP/SIO。

- [ ] **Step 3: Extract safe formatter.** Move single mutation formatting from set/reset to
  `Maxio.Admin.ConfigKV.CLI` without changing S5 bytes；add batch changed path/count/postcommit formatting and never interpolate values。

- [ ] **Step 4: Implement destructive-safe native mc lifecycle.** Require explicit disposable known-baseline before import。Export
  may be asserted but never used to restore provenance。For same-process test DB，cleanup calls `Config.mutate_many/2` resets with
  source string `"system"` in `after`；for external remote，require an isolated disposable environment and teardown it。If neither
  cleanup authority exists，return BLOCKED without import。Human/JSON flows use distinct aliases/config dirs and creator-aware temp
  cleanup。

- [ ] **Step 5: Preserve blocker semantics.** Any business failure is primary；cleanup always executes and is secondary。Record exact argv、
  exit、redacted stdout/stderr hash，never raw ciphertext/credentials。`fixture_expected` and `fake_observed` are not `live_pass`。

- [ ] **Step 6: Run CLI/smoke GREEN.** Run:

  ```powershell
  mix test test/mix/tasks/maxio_admin_config_export_import_test.exs test/mix/tasks/maxio_admin_config_test.exs test/maxio/compat/external_smoke_test.exs
  mix compile --warnings-as-errors
  mix format --check-formatted lib/maxio/admin/config_kv/cli.ex lib/mix/tasks/maxio.admin.config.export.ex lib/mix/tasks/maxio.admin.config.import.ex lib/mix/tasks/maxio.admin.config.set.ex lib/mix/tasks/maxio.admin.config.reset.ex lib/maxio/compat/external_smoke.ex test/mix/tasks test/maxio/compat/external_smoke_test.exs
  ```

- [ ] **Step 7: Commit implementation checkpoint.** Run:

  ```powershell
  git add lib/maxio/admin/config_kv/cli.ex lib/mix/tasks/maxio.admin.config.export.ex lib/mix/tasks/maxio.admin.config.import.ex lib/mix/tasks/maxio.admin.config.set.ex lib/mix/tasks/maxio.admin.config.reset.ex lib/maxio/compat/external_smoke.ex
  git commit -m "feat(compat): add config archive workflows"
  ```

- [ ] **Step 8: Independent task review.** Lane C audits bounded binary IO、exact archive stdout、no value leakage、native mc argv、
  cleanup and data-plane outcomes。Accepted fixes commit `fix(compat): correct config archive workflows` after RED。

### Task 10: Run the coherent focused batch

**Owner:** Lane F verification runner；不得是 Task 4/5/7/9 生产作者。**Reviewer:** Lane C verifies evidence identity。

**Files:** all S7 production/tests/fixtures；不修改 STATUS。

**Interfaces:**

- Consumes: all task-reviewed commits Tasks 1–9。
- Produces: one coherent focused/compile/format/diff evidence set；不运行 precommit，不提交。

- [ ] **Step 1: Run S7 plus affected S5/S6 tests in one command.** Run:

  ```powershell
  mix test test/maxio/admin/config_export_import_protocol_fixture_test.exs test/maxio/admin/config_kv_archive_test.exs test/maxio/admin/config_export_import_endpoint_test.exs test/maxio/admin/config_kv_protocol_fixture_test.exs test/maxio/admin/config_kv_help_protocol_fixture_test.exs test/maxio/admin/config_kv_registry_test.exs test/maxio/admin/config_kv_parser_test.exs test/maxio/admin/config_kv_adapter_test.exs test/maxio/admin/config_kv_request_test.exs test/maxio/admin/config_kv_endpoint_test.exs test/maxio/admin/config_kv_help_test.exs test/maxio/admin/plug_test.exs test/maxio/admin/authz_test.exs test/maxio/admin/error_map_test.exs test/maxio/admin/envelope_test.exs test/maxio/config/config_test.exs test/maxio/config/coordinator_batch_test.exs test/maxio/config/coordinator_batch_concurrency_test.exs test/maxio/config/coordinator_test.exs test/maxio/config/coordinator_postcommit_test.exs test/maxio/config/coordinator_concurrency_test.exs test/maxio/config/store_batch_event_test.exs test/mix/tasks/maxio_admin_config_export_import_test.exs test/mix/tasks/maxio_admin_config_test.exs test/maxio/compat/external_smoke_test.exs
  ```

  Record exact exit、test/exclusion counts and HEAD in ignored evidence。

  Completion requires the real Phoenix.PubSub self-loop/different-origin replay tests to execute and PASS；an excluded test or a
  Notify fake result does not satisfy this gate。

- [ ] **Step 2: Run cheap static gates.** Run:

  ```powershell
  mix compile --warnings-as-errors
  mix format --check-formatted lib/maxio/admin/config_kv lib/maxio/config.ex lib/maxio/config/coordinator.ex lib/maxio/config/store.ex lib/maxio/cluster/notify.ex lib/maxio/admin/plug.ex lib/maxio/admin/authz.ex lib/maxio/admin/error_map.ex lib/mix/tasks/maxio.admin.config.export.ex lib/mix/tasks/maxio.admin.config.import.ex lib/maxio/compat/external_smoke.ex test/maxio/admin test/maxio/config test/mix/tasks/maxio_admin_config_export_import_test.exs test/maxio/compat/external_smoke_test.exs
  git diff --check 50f322a..HEAD
  ```

- [ ] **Step 3: Audit scope and secrets.** Run:

  ```powershell
  git diff --name-status 50f322a..HEAD
  git diff 50f322a..HEAD -- priv/repo/migrations lib/maxio/config/runtime_config.ex lib/maxio/config/runtime_config_audit.ex
  git grep -n -i -E "caller_secret|authorization|plaintext|ciphertext|secret_access_key" -- docs/superpowers/STATUS.md test/fixtures/minio_admin_config_export_import_s7
  ```

  Expected: no migration/runtime schema diff；grep hits only explanatory/redacted field names，never credential/value artifacts。

- [ ] **Step 4: Route failures through ownership.** Any failure reopens Lane T RED→Lane B fix→Lane C review，then Lane F reruns
  the affected focused command and this whole coherent batch。Do not run `mix precommit` here。

### Task 11: Run strict-live native mc, direct HTTP and cluster convergence evidence

**Owner:** Lane G strict-live operator. Raw artifacts are ignored and redacted；无 tracked commit。

**Files:**

- Write only ignored: `artifacts/admin-config-export-import-s7/2026-08-29-live/`
- Optionally update ignored: `.superpowers/sdd/2026-08-29-minio-admin-config-export-import-s7/progress.md`

**Interfaces:**

- Consumes: reviewed GREEN HEAD、pinned mc、disposable Maxio endpoint/credentials、optional two-node environment。
- Produces: W1–W5 live closure、native/client bytes、data-plane/audit/no-op、broadcast/reconcile evidence。

- [ ] **Step 1: Record identities before probes.** Capture Maxio HEAD、`mc --version` and binary SHA correlated to
  `77f82e1`、endpoint、redacted access-key identity、isolated `MC_CONFIG_DIR` and fixture SHA。Different mc is exploratory only。

- [ ] **Step 2: Run strict ExternalSmoke.** Only against a disposable known-baseline，set the explicit
  `MAXIO_EXTERNAL_SMOKE_CONFIG_ARCHIVE_DISPOSABLE=1` opt-in through the operator environment，and with no shell echo of secrets run:

  ```powershell
  mix maxio.compat.matrix --include-external-smoke --no-internal-suites --external-smoke-client minio_mc --strict --json --artifact artifacts/admin-config-export-import-s7/2026-08-29-live/matrix.json
  ```

  Provide endpoint/access/secret through the project-supported environment/config channel rather than command-line history。
  Assert export/import human and global `--json` branches, fixed restart output、data-plane transition and direct Config reset or
  isolated-environment teardown cleanup。Do not import the exported plaintext as a provenance restore，and do not run this flow against
  an arbitrary persistent remote。

- [ ] **Step 3: Reverify native stdin/argv fixture.** Compare actual argv/stdin/file transport and stdout/stderr bytes with the
  already source/live-verified `mc_config_archive_dispatch.json`。Task 11 cannot choose these semantics for the first time。If the live
  environment differs，stop、classify fixture drift，then reopen Lane R→T→B→C and invalidate prior evidence。

- [ ] **Step 4: Capture direct signed HTTP matrix.** Use disposable signed requests to prove GET/PUT action、caller A/B secret
  isolation、exact plaintext archive after decrypt、randomized SIO length/framing oracle、CL/TE/CE/no-transform、PUT empty 200/no
  applied、auth-before-body and ciphertext boundaries 0、262272、262273。Never compare fixed ciphertext bytes/SHA；capture only
  redacted headers、length and decrypted-plaintext hash。

- [ ] **Step 5: Reverify madmin/SIO boundaries.** Demonstrate formula `41+n+16*ceil(n/16384)`、empty plaintext local EOF/zero
  request、261975→262272 end-to-end PASS、261976→262273 server TooLarge、262144→262441 client-local accepted but server rejected、
  262145 local ErrTooLarge/zero request。Correlate server request count/request ids without retaining ciphertext。

- [ ] **Step 6: Prove replacement and no-op state.** Record runtime row/audit versions before/after explicit fallback import、
  blank/comment-only reset、duplicate LWW、unknown whole failure and second identical import。Assert no partial rows/audits and no
  hidden/orphan changes。

- [ ] **Step 7: Prove concurrency.** Launch overlapping import and single set/reset using the test checkpoint build or controlled DB
  lock；show stable serialization、no deadlock、no lost update。Do not use timing-only evidence。

- [ ] **Step 8: Prove two-node convergence when available.** The Task 10 real local PubSub self-loop/replay functional test is a hard
  PASS prerequisite。Separately, on a real node A import a changed archive；node B must full reload once from
  the batch event。Then suppress/drop broadcast and prove node B converges within configured digest interval。Record node ids、event
  count and safe fingerprint only。If a real two-node environment is unavailable，mark this probe `BLOCKED: two_node_environment_missing`；
  focused simulated tests cannot be promoted to live PASS。

- [ ] **Step 9: Reconcile upstream transport deviation.** Record that upstream GET may be gzhttp-compressed while Maxio Admin
  no-transform yields exact CL/no CE/TE。Classify as deliberate repair，不把两者写成 raw-wire identical。

- [ ] **Step 10: Invalidate stale evidence.** Fixture/test change invalidates affected W/native comparisons；production change invalidates
  all affected Maxio direct/native/state captures and Task 10 batch。Mark old artifacts `superseded`，never edit them into PASS。

- [ ] **Step 11: Classify each probe.** Every W1–W5、native human/JSON、direct HTTP、data-plane、audit/no-op、concurrency、two-node
  probe is independently PASS or exact BLOCKED。A BLOCKED result may record missing real two-node/live capability，but it cannot leave
  a production decision unresolved；those were gated before Tasks 2–9。Exit 0 with zero business probes is not PASS。

### Task 12: Perform independent dual whole-range review

**Owner:** Lane D protocol/client reviewer and Lane E architecture/security reviewer，separate contexts，均只读。

**Range:** `50f322a..HEAD`

**Files:** read every tracked file in range plus redacted Task 10/11 evidence；review-only 不提交。

**Interfaces:**

- Consumes: task-reviewed commits、coherent focused evidence、strict-live results。
- Produces: two severity-ranked verdicts；完成要求两者均零 Critical/Important。

- [ ] **Step 1: Establish exact range independently.** Both run:

  ```powershell
  git diff --stat 50f322a..HEAD
  git diff --name-status 50f322a..HEAD
  git log --oneline --decorate 50f322a..HEAD
  ```

- [ ] **Step 2: Lane D protocol/client review.** Audit pinned identities、GET/PUT route/action、caller-secret SIO、madmin local and
  server direct bounds、SIO formula/261975/261976/262144 split、random ciphertext oracle、exact plaintext tail-space/LF/order、
  blank replacement、LWW、unknown、empty 200/no applied、gzhttp/no-transform deviation、mc human/JSON/restart/argv/stdin and
  local-design/source/fake/live labels。Confirm no implementation decision was first made in Task 11。

- [ ] **Step 3: Lane E architecture/security review.** Audit Registry-only exposure、single snapshot、explicit fallback override、
  raw parse then typed cast、path-key expected versions、per-subsystem validators、legacy option/checkpoint wrappers、all-locks-before-
  read、single transaction/all validators before writes、string source、touched/changed split、per-key version/audit/no-op、one sync
  reload plus origin-aware broadcast/self-loop/replay dedupe、safe attention、digest reconciliation、bounded cumulative stdin、
  disposable smoke cleanup、caller-secret/value redaction、no migration/backend/history/restart。

- [ ] **Step 4: Issue evidence-backed verdicts.** Each reviewer lists severity、file/contract/evidence。A bare “looks good” is invalid。
  Zero Critical/Important is required；Minor may remain only with explicit acceptance and no correctness/security impact。

- [ ] **Step 5: Close findings through original lanes.** Lane T adds failing regression，Lane B implements architecture-consistent fix，
  Lane C task-reviews，commit all accepted review fixes as：

  ```powershell
  git commit -m "fix(admin): close config archive review findings"
  ```

  Then Lane F reruns Task 10，Lane G reruns invalidated Task 11 probes，Lane D/E both re-review the amended whole range。

### Task 13: Run final verification and the single final precommit

**Owner:** Lane F，after Task 12 dual approval and all invalidated live evidence rerun。

**Files:** no intentional changes。

**Interfaces:**

- Consumes: immutable reviewed implementation HEAD、Task 10/11 evidence、Lane D/E approvals。
- Produces: sole final successful precommit evidence identity；不提交。

- [ ] **Step 1: Re-run Task 10 exactly.** Record final HEAD、focused counts/exits、compile、format、diff/scope/secret gates。

- [ ] **Step 2: Confirm tracked cleanliness and migration absence.** Run:

  ```powershell
  git status --short
  git diff 50f322a..HEAD -- priv/repo/migrations
  git diff --check 50f322a..HEAD
  ```

- [ ] **Step 3: Run the one final gate.** Run once:

  ```powershell
  mix precommit
  ```

  Record exact exit、test/exclusion counts and warnings classification。If it fails，reopen RED-first implementation/review，rerun
  invalidated focused/live/review gates，and treat only the replacement successful execution as final；不得在 slice 阶段反复调用。

- [ ] **Step 4: Freeze evidence identity.** Record HEAD、Task 10 result、Task 11 per-probe PASS/BLOCKED、Lane D/E verdict and final
  precommit result in ignored progress。任何后续 production/test/fixture change 都使本 Task 无效。

### Task 14: Write STATUS-only factual closeout

**Owner:** Lane H STATUS author. **Reviewer:** another Lane H/C context，不能是 author。

**Files:**

- Modify only: `docs/superpowers/STATUS.md`

**Interfaces:**

- Consumes: frozen Task 13 evidence identity。
- Produces: one evidence-backed STATUS-only commit；不改变 implementation/spec/test。

- [ ] **Step 1: Record implemented facts.** 写 route/action/SIO、三个公开键、exact archive bytes/order、limits、replacement/
  explicit fallback、single snapshot/transaction/lock order、version/audit/no-op、one reload/broadcast、empty 200/no applied、CLI/
  native mc 和 deliberate safety deviations。

- [ ] **Step 2: Record evidence honestly.** 写 commit range、focused counts、compile/format/diff、single final precommit、Lane D/E
  verdict，以及每个 strict-live PASS 或 exact BLOCKED。Fixture/fake 不能写 live PASS。

- [ ] **Step 3: Preserve remaining non-goals.** 明列 history、restart、targets、full catalog、secret/backend、archive job/global epoch；
  不声称完整 MinIO config compatibility。

- [ ] **Step 4: Independent STATUS-only review.** Run:

  ```powershell
  git status --short
  git diff --name-only HEAD
  git diff --check -- docs/superpowers/STATUS.md
  ```

  Expected: only STATUS differs；reviewer逐项对应 immutable evidence。

- [ ] **Step 5: Commit only STATUS.** Run:

  ```powershell
  git add docs/superpowers/STATUS.md
  git commit -m "docs(status): record config export import S7 evidence"
  git status --short
  ```

  Expected: clean。STATUS-only docs commit 不需要重跑 precommit。

### Task 15: Fast-forward integration and atomic push

**Owner:** Lane I integration controller。

**Files:** no content changes；only verified refs move。

**Interfaces:**

- Consumes: clean reviewed feature HEAD and clean master integration worktree。
- Produces: local/remote `master` and `codex/admin-config-export-import-s7` at the same final SHA；no merge commit。

- [ ] **Step 1: Verify feature identity and ancestry.** Run in feature worktree:

  ```powershell
  git status --short
  git rev-parse HEAD
  git merge-base --is-ancestor 50f322a HEAD
  git fetch origin
  ```

- [ ] **Step 2: Protect integration worktree.** Locate it with `git worktree list`，verify master worktree clean。If any user change
  exists，stop and report paths；never reset、stash、force checkout or overwrite。

- [ ] **Step 3: Require remote stability.** Verify `origin/master` is still equal to or an ancestor of reviewed feature HEAD。If master
  advanced independently，stop for deliberate rebase plus invalidated review/verification；never force push。

- [ ] **Step 4: Fast-forward only.** In clean master worktree run:

  ```powershell
  git merge --ff-only codex/admin-config-export-import-s7
  ```

- [ ] **Step 5: Push both refs atomically.** Run:

  ```powershell
  git push --atomic origin refs/heads/master:refs/heads/master refs/heads/codex/admin-config-export-import-s7:refs/heads/codex/admin-config-export-import-s7
  ```

  On rejection diagnose and retry atomically；never partially push one ref and never use `--force`。

- [ ] **Step 6: Verify remote identities.** Fetch and compare local master/feature with both origin refs，confirm both worktrees clean，
  report final SHA、dual-review verdicts、single final precommit and strict-live PASS/BLOCKED classifications。

---

## Explicit Non-Goals

- 不实现 Config history list/clear/restore、archive history 或 durable import job。
- 不实现 `mc admin service restart` 或任何 service restart orchestration。
- 不支持 named targets、`subsystem:target` 或 target merge。
- 不伪造 MinIO 官方 catalog；只支持 Registry 三个 Maxio 扩展键。
- 不导出或导入 deployment identity、root/access secret、SSE/KMS/MFA、storage/credential/policy/backend/source/topology/Repo。
- 不枚举/修复/删除 orphan runtime rows；它们只由既有 Store 诊断，Archive 永不触碰。
- 不新增 migration、batch table、global config version/epoch 或第二配置权威源。
- 不把 Admin 小型有界整读规则扩展到 PutObject/UploadPart。
- 不把 upstream 无锁/partial commit、gzhttp 压缩或 no-hot-reload 安全缺口复制到 Maxio。
- 不把 export effective plaintext 当成 override/fallback provenance 备份，也不对任意持久远端承诺 smoke 无痕恢复。
- 不把 pinned source、fixture expectation、fake runner 或 BLOCKED probe 冒充 strict-live PASS。

---

## Plan Self-Review Checklist

- Spec coverage：route/SIO/limits/exposure/replacement/explicit fallback/snapshot/transaction/lock/audit/no-op/postcommit/CLI/live/
  migration/non-goals 均映射到具体 Task。
- Placeholder scan：所有决定实现的 `VERIFY-AT-IMPL` 均在相应 RED/production 前由 Task 1 fixture gate 关闭；Task 11
  只复验；无无人负责的实现空白。
- Type consistency：Archive raw `Schema.parse/3`、Coordinator typed `Schema.cast/3`、string source、path-key expected versions、
  per-subsystem validators、legacy wrappers、origin-aware batch event、touched/changed result shape 在 Tasks 2–9 一致。
- Lane isolation：fixture、RED、production、task review、whole-range review、verification、STATUS、integration 均为独立 owner。
- Batch discipline：Tasks 1–9 只 focused；Task 10 coherent batch；Task 13 唯一 final precommit。
- Cluster evidence：真实本地 PubSub self-loop/replay test 必须 PASS；真实两节点缺环境可 BLOCKED，但不改变前者硬门槛。
- Delivery discipline：Task 14 STATUS-only；Task 15 ff-only + atomic two-ref push。
