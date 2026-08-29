# MinIO Admin Config `help-config-kv` S6 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 实现 plaintext MinIO Admin v3 `help-config-kv`，以三项有序 Maxio extension catalog
打通 pinned native mc alias-only get/reset 与 set-help，同时保持 help 投影零 Config DB、
零 secret、零 target/
official-catalog 扩张。

**Architecture:** `ConfigKV.Registry` 是唯一有序 wire catalog，`Config.Schema` 是 type/env
binding 唯一真相；新建纯 `ConfigKV.Help` 投影并编码 exact madmin JSON+LF。
Admin Plug 只做 exact route/query/auth/log/framing，Mix CLI 与 ExternalSmoke 共用该边界；
Parser/Adapter/Request/Envelope/Config/Schema/migrations 不改。strict-live 发现并经独立评审接受的唯一
S3 Endpoint transport exception，是在 `SurfaceClassifier` 后接入 Admin-only
`ResponseTransformPolicy`，为 path-style `:admin` 响应合并 `Cache-Control: no-transform`，防止
Bandit post-Plug 压缩 Admin JSON/SIO。

**Tech Stack:** Elixir, Plug/Bandit, Phoenix endpoint tests, Jason ordered JSON, ExUnit, Mix tasks,
pinned MinIO/madmin-go/mc source fixtures, native `mc` strict live.

**Spec:** `docs/superpowers/specs/2026-08-29-minio-admin-config-help-s6-design.md`

## Global Constraints

- Base 必须为 `124dc3bac2dca72f228ea9ae39077032b4d3580f`，feature branch 必须为
  `codex/admin-config-help-s6`。
- 必须完整遵守 `AGENTS.md`；fixture research、RED tests、GREEN production、task review、
  whole-range review、verification、STATUS 各用独立 lane。代码作者不得自审。
- Pinned identities：MinIO `7aac2a2c5b7c882e68c1ce017d8256be2feea27f`，madmin-go
  `4b504b82db633e978a57d49443b2be75824244c3`，mc
  `77f82e18b5401a65958f1619df6ebb994634bd88`。
- 唯一新 HTTP surface 是 `GET /minio/admin/v3/help-config-kv`；`subSys` 和 `key`
  query 名都必须存在，`env` 按 presence 解释，action 是 `admin:ConfigUpdate`。
- success 是 plaintext compact madmin Help JSON + exact LF，`application/json`，exact CL，
  no TE/CE/SIO/apply header；madmin unknown fields 为硬错。
- pinned MinIO server raw HelpKV order 是 `key,type,description,optional,multipleTargets`；
  madmin struct/client re-encode order 是 `key,description,optional,type,multipleTargets`。Maxio direct
  raw body 选择后者，并明确标为 raw-wire ordering deviation。
- Catalog exact order：`s3.clock_skew_ms`、`listing.sql_hard_limit`、
  `prometheus_metrics.public`；description/type/optional/multipleTargets 严格按 spec。
- Registry 是 wire/core/description/order/sensitivity 唯一声明；Schema 是 type/env 唯一真相。
  不复制 default，不读 runtime/current/source/version/value。
- `env` deliberate deviation：empty `subSys` 的 top-level 无论 env 是否存在都返回
  3-item catalog；当前已知 nonempty subsystem 经 env 过滤后返回空 keys，direct
  unbound key 返回 generic ConfigError；不伪造 env binding。
- `subsystem:target` 授权后 400 InvalidArgument；所有 `multipleTargets` 为 false。
- 不暴露 secret/deployment identity/backend binding/hidden/forbidden/full Schema/official MinIO
  catalog。
- 不修改 `ConfigKV.Parser`、`Adapter`、`Request`、Envelope、Config/Schema behavior/defaults、
  Coordinator、Store、Repo、migration 或 logger metadata allowlist。唯一允许的 S3 Endpoint transport
  exception 是 `SurfaceClassifier` 后的 `ResponseTransformPolicy`：只命中 path-style `:admin`，普通
  S3、vhost 同路径、IAM/STS、health/metrics 以及 SigV4/Authz/dispatch 业务语义必须保持不变。
- 开发中只跑 focused tests/compile/changed-file format/diff check；整个 coherent batch 在最终
  只跑一次 `mix precommit`。
- S5 fixture 是历史快照，不得改写它当时的 help unsupported 记录。
- fake runner/source fixture 不得写为 live PASS；strict live 缺能力时按探针诚实标
  `BLOCKED`。

---

## File Structure

### New files

- `lib/maxio/admin/config_kv/help.ex`：纯 catalog projection、safe evidence 与 exact JSON+LF encoder。
- `lib/mix/tasks/maxio.admin.config.help.ex`：DB-free 一方协议诊断 CLI。
- `test/maxio/admin/config_kv_help_test.exs`：纯 Registry/Schema projection、env、target、secret
  与 encoder 契约。
- `test/maxio/admin/config_kv_help_protocol_fixture_test.exs`：pinned source/fixture 完整性门禁。
- `test/fixtures/minio_admin_config_help_s6/README.md`：身份、摘录边界、hash/provenance。
- `test/fixtures/minio_admin_config_help_s6/minio_help_route.json`：route/query/action/handler/env/target
  claims。
- `test/fixtures/minio_admin_config_help_s6/madmin_help_wire.json`：MinIO server raw/madmin client
  HelpKV 双顺序，以及 madmin GET/path/query/SigV4/empty-payload/request-entity/plaintext decoder
  源码事实。
- `test/fixtures/minio_admin_config_help_s6/mc_help_dispatch.json`：alias-only get/reset、set-help 的
  exact argv/branch/human/JSON expectations。

### Modified files

- `lib/maxio/admin/config_kv/registry.ex`：单一有序 subsystem/entry help metadata 声明。
- `lib/maxio/admin/plug.ex`：exact dispatch/query/auth/log/framing。
- `lib/maxio/admin/error_map.ex`：只增 safe unknown-key description 校验。
- `lib/maxio/compat/external_smoke.ex`：native mc help orchestration。
- `test/maxio/admin/config_kv_registry_test.exs`：Registry 唯一性/顺序/Schema invariant。
- `test/maxio/admin/config_kv_endpoint_test.exs`：HTTP entity/auth/error/framing/log/no-Config-DB 矩阵。
- `test/maxio/admin/plug_test.exs`：exact method/path/fallback/anonymous concealment。
- `test/maxio/admin/error_map_test.exs`：dynamic safe-description 脱敏门禁。
- `test/mix/tasks/maxio_admin_config_test.exs`：CLI arity/env/bytes/no boot/error。
- `test/maxio/compat/external_smoke_test.exs`：fake human/JSON argv/transcript/failure 分类。
- `README.md`：当前 Config KVS 支持面、env/target 偏差、CLI 与剩余 non-goals。
- `docs/superpowers/STATUS.md`：只在所有门禁后由 STATUS lane 单独更新。

## Lane Ownership

- **Lane R — fixture research author:** 只读 pinned 上游并创建 source-derived JSON/README
  fixtures；不写任何 ExUnit 或 production。
- **Lane T — RED test author:** 只消费已经独立 review 的 fixtures 并写失败测试；
  必须是与 Lane R 不同的 agent/context，不写 production。
- **Lane B — implementation author:** 只按已提交 RED 实现 GREEN，不审自己的代码。
- **Lane C — task reviewer:** 每个 GREEN task 后独立做 spec/code/test review，不修改文件。
- **Lane D — protocol reviewer:** 对整段 range 核对 pinned MinIO/madmin/mc 与 exact bytes。
- **Lane E — architecture/security reviewer:** 对整段 range 核对边界、Help/CLI 的 Config-DB-free、
  secret 和错误脱敏。
- **Lane F — verification runner:** 串行运行 combined focused 和唯一 final precommit，不写功能。
- **Lane G — strict-live operator:** 管理 isolated alias/artifacts 并运行 pinned native mc/direct probes。
- **Lane H — STATUS author/reviewer:** 一个上下文只写 STATUS，另一上下文只审 STATUS。
- **Lane I — integration:** 仅在 clean worktrees 执行 ff-only 和 atomic push。

Lane B 在 task review 中收到可接受 finding 时，必须先让 Lane T 增加能复现的
失败测试，再做最小架构一致修复；Lane C 重审。

---

### Task 0: Independent design/plan review gate

**Owner:** design author for fixes; an independent design reviewer for verdict.

**Files:**

- Add: `docs/superpowers/specs/2026-08-29-minio-admin-config-help-s6-design.md`
- Add: `docs/superpowers/plans/2026-08-29-minio-admin-config-help-s6.md`

**Interfaces:**

- Consumes: base `124dc3b`, S5 design/plan/status, pinned research synthesis.
- Produces: reviewed immutable S6 contract and executable lane-separated plan.

- [ ] **Step 1: Reviewer fully reads and diffs both untracked documents.** Ordinary `git diff -- FILE`
  cannot show an untracked file and is therefore forbidden as the sole review evidence. Run:

  ```powershell
  git status --short
  Get-Content -Raw -Encoding UTF8 docs/superpowers/specs/2026-08-29-minio-admin-config-help-s6-design.md
  Get-Content -Raw -Encoding UTF8 docs/superpowers/plans/2026-08-29-minio-admin-config-help-s6.md
  git diff --no-index -- /dev/null docs/superpowers/specs/2026-08-29-minio-admin-config-help-s6-design.md
  git diff --no-index -- /dev/null docs/superpowers/plans/2026-08-29-minio-admin-config-help-s6.md
  ```

  Expected: each no-index diff exits 1 because the complete new file is present; reviewer reads the complete
  contents, not a truncated terminal excerpt. Until staged, the only worktree changes are the two untracked
  S6 docs; there is no code/test/README/STATUS change.

- [ ] **Step 2: Review exactness and scope.** Reviewer must explicitly approve route/query/action/plaintext
  fields/order/descriptions/type/env/target/error/framing/CLI/smoke/non-goals and confirm that only V-H1/V-H2
  require direct capture.

- [ ] **Step 3: Author closes accepted findings in the two docs.** Search for unresolved placeholders:

  ```powershell
  rg -n "T[B]D|T[O]DO|implement lat[e]r|fill i[n]" docs/superpowers/specs/2026-08-29-minio-admin-config-help-s6-design.md docs/superpowers/plans/2026-08-29-minio-admin-config-help-s6.md
  rg -n "VERIFY[-]AT[-]IMPL" docs/superpowers/specs/2026-08-29-minio-admin-config-help-s6-design.md docs/superpowers/plans/2026-08-29-minio-admin-config-help-s6.md
  ```

  Expected: no placeholder; only the two named V-H1/V-H2 occurrences are permitted VERIFY items.

- [ ] **Step 4: Commit reviewed design artifacts.** Run:

  ```powershell
  git add docs/superpowers/specs/2026-08-29-minio-admin-config-help-s6-design.md docs/superpowers/plans/2026-08-29-minio-admin-config-help-s6.md
  git commit -m "docs: design admin config help S6"
  ```

### Task 1: Freeze pinned protocol/client evidence

**Owner:** Lane R fixture research. **Reviewer:** a fresh Lane C context that did not author fixtures.

**Files:**

- Create: `test/fixtures/minio_admin_config_help_s6/README.md`
- Create: `test/fixtures/minio_admin_config_help_s6/minio_help_route.json`
- Create: `test/fixtures/minio_admin_config_help_s6/madmin_help_wire.json`
- Create: `test/fixtures/minio_admin_config_help_s6/mc_help_dispatch.json`

**Interfaces:**

- Consumes: the three pinned upstream identities in Global Constraints.
- Produces: immutable source-derived claims keyed to raw/excerpt hashes; a different Lane T later writes all
  ExUnit gates and RED tests against them.

- [ ] **Step 1: Capture MinIO claims.** `minio_help_route.json` must encode exact method/path, required
  `subSys`/`key`, ConfigUpdate action, plaintext encoder, empty-subsystem early return, target handling and
  the apparent `r.Form` env branch. Every claim contains source file, symbol/range, excerpt SHA-256 and
  pinned commit.

- [ ] **Step 2: Capture madmin request and wire claims.** `madmin_help_wire.json` must encode these exact
  source-pinned facts, each with pinned commit, source file/symbol/range, raw source SHA-256 and excerpt
  SHA-256:

  ```json
  {
    "help_fields": ["subSys", "description", "multipleTargets", "keysHelp"],
    "minio_server_raw_key_fields": ["key", "type", "description", "optional", "multipleTargets"],
    "madmin_client_key_fields": ["key", "description", "optional", "type", "multipleTargets"],
    "method": "GET",
    "path": "/minio/admin/v3/help-config-kv",
    "required_query": ["subSys", "key"],
    "optional_presence_query": "env",
    "payload_sha256": "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
    "required_headers": ["X-Amz-Content-Sha256", "Authorization"],
    "request_absent": ["Content-Length", "Transfer-Encoding", "Content-Type", "body", "SIO"],
    "response_transport": "plaintext_json_one_lf",
    "unknown_fields": "rejected"
  }
  ```

  `subSys` 与 `key` 无论值是否为空都由 madmin 发送；`env` 只在布尔 option
  为 true 时发送。`X-Amz-Content-Sha256` 值必须是上述 empty payload SHA-256，
  `Authorization` 必须是 SigV4；fixture 不存放任何真实 credential/signature。

- [ ] **Step 3: Capture mc dispatch claims.** `mc_help_dispatch.json` must distinguish exact client
  branches:

  ```json
  {
    "get_alias_only": ["help-config-kv", "subSys=", "key="],
    "reset_alias_only": ["help-config-kv", "subSys=", "key="],
    "set_subsystem_without_equals": ["help-config-kv", "subSys=s3", "key="],
    "set_key_without_equals": ["help-config-kv", "subSys=s3", "key=clock_skew_ms"]
  }
  ```

  Also freeze expected non-TTY human/JSON fixture bytes while labeling them source-derived, not live.

- [ ] **Step 4: Validate fixture syntax and provenance without ExUnit.** Run:

  ```powershell
  Get-Content -Raw -Encoding UTF8 test/fixtures/minio_admin_config_help_s6/minio_help_route.json | ConvertFrom-Json | Out-Null
  Get-Content -Raw -Encoding UTF8 test/fixtures/minio_admin_config_help_s6/madmin_help_wire.json | ConvertFrom-Json | Out-Null
  Get-Content -Raw -Encoding UTF8 test/fixtures/minio_admin_config_help_s6/mc_help_dispatch.json | ConvertFrom-Json | Out-Null
  Get-FileHash -Algorithm SHA256 test/fixtures/minio_admin_config_help_s6/*.json
  ```

  Expected: JSON parsing succeeds and recorded raw/excerpt hashes can be independently recomputed. The
  research lane runs no Mix/ExUnit command.

- [ ] **Step 5: Commit fixture evidence.** Run:

  ```powershell
  git add test/fixtures/minio_admin_config_help_s6
  git commit -m "test(admin): freeze config help protocol evidence"
  ```

- [ ] **Step 6: Independent fixture review.** Lane C re-fetches/reads pinned source, recomputes raw/excerpt
  hashes, checks both HelpKV orders and request signing/framing claims, and verifies no source-derived
  transcript is called live. Findings return to Lane R; accepted corrections use
  commit `test(admin): correct config help protocol evidence` and are re-reviewed.

### Task 2: Write all S6 RED behavior tests before production

**Owner:** Lane T RED test author, in a different agent/context from Lane R. No fixture or production file
may change in this task.

**Files:**

- Create: `test/maxio/admin/config_kv_help_protocol_fixture_test.exs`
- Modify: `test/maxio/admin/config_kv_registry_test.exs`
- Create: `test/maxio/admin/config_kv_help_test.exs`
- Modify: `test/maxio/admin/config_kv_endpoint_test.exs`
- Modify: `test/maxio/admin/plug_test.exs`
- Modify: `test/maxio/admin/error_map_test.exs`
- Modify: `test/mix/tasks/maxio_admin_config_test.exs`
- Modify: `test/maxio/compat/external_smoke_test.exs`

**Interfaces:**

- Consumes: Task 1 fixtures and spec exact values.
- Produces: failing executable requirements for `Registry`, `Help.project/3`, `Help.encode_line/1`, HTTP,
  Mix task and ExternalSmoke.

- [ ] **Step 0: Write and run the fixture integrity gate.** Test pinned ids, raw/excerpt SHA-256,
  source-id coverage, always-present `subSys`/`key`, conditional env, GET/path, empty-payload hash,
  `X-Amz-Content-Sha256`/SigV4 Authorization, absent CL/TE/CT/body/SIO, both distinct HelpKV orders, exact
  mc branch matrix and unchanged S5 fixture files. Run:

  ```powershell
  mix test test/maxio/admin/config_kv_help_protocol_fixture_test.exs
  ```

  Expected: PASS without any production `Help` module.

- [ ] **Step 1: Write Registry/Help RED.** Assert exact catalog order/descriptions, Schema-derived types,
  top-level/subsystem/key ordered wire, one LF, empty-subsystem/nonempty-key early return, env filtering,
  target rejection, forbidden-before-unknown, hidden/sensitive redaction and invalid evidence. Core assertions
  must include:

  ```elixir
  assert {:ok, %{scope: :catalog, key_count: 3, wire: wire}} = Help.project("", "", false)
  assert IO.iodata_to_binary(Help.encode_line(wire)) == @top_level_json <> "\n"

  assert {:ok, %{key_count: 0, wire: env_wire}} = Help.project("s3", "", true)
  decoded = Jason.decode!(IO.iodata_to_binary(Help.encode_line(env_wire)))
  assert decoded["keysHelp"] == []

  assert {:error, %{reason: :invalid_argument, stage: :parser}} =
           Help.project("s3:target", "", false)
  ```

- [ ] **Step 2: Write ErrorMap RED.** Safe `unknown key clock_skew_ms for sub-system s3` must survive;
  unsafe/sensitive-marker variants must collapse to generic `Configuration specified is invalid`.

- [ ] **Step 3: Write endpoint/Plug RED.** Replace only the current help-501 case. Cover exact entity,
  missing-vs-empty query, anonymous concealment, ConfigUpdate denial, root success, STS/bucket-policy boundary,
  target/unknown/forbidden/hidden/env, no caller secret, zero body read, no SIO/apply header, exact log metadata,
  and zero runtime/audit mutation. Success asserts Maxio's deliberate madmin-client HelpKV order. Every error
  asserts `application/json; charset=utf-8`, exact compact-body CL, no TE/CE/LF/SIO. Keep config/export/history
  and wrong help methods/paths at 501.

- [ ] **Step 4: Write CLI RED.** Exercise 0/1/2 args, `--env`, exact stdout JSON+LF, unknown option/3 args,
  safe error and prove the task does not invoke the injected/observable Config CLI boot path.

- [ ] **Step 5: Write ExternalSmoke RED.** In separate human/JSON scenarios, assert exact argv and fixture
  transcript for alias-only get/reset plus subsystem/key set-help. Assert help stages perform no cleanup
  mutation and a help failure is classified as the primary blocker.

- [ ] **Step 6: Prove focused RED without full precommit.** Run separately so each missing behavior is visible:

  ```powershell
  mix test test/maxio/admin/config_kv_registry_test.exs test/maxio/admin/config_kv_help_test.exs test/maxio/admin/error_map_test.exs
  mix test test/maxio/admin/config_kv_endpoint_test.exs test/maxio/admin/plug_test.exs test/maxio/admin/authz_test.exs
  mix test test/mix/tasks/maxio_admin_config_test.exs
  mix test test/maxio/compat/external_smoke_test.exs
  ```

  Expected: FAIL for missing Help metadata/module/route/task/smoke stages, not syntax or fixture errors.

- [ ] **Step 7: Commit tests only.** Verify `git diff --name-only` contains only the eight test files, then:

  ```powershell
  git add test/maxio/admin/config_kv_help_protocol_fixture_test.exs test/maxio/admin/config_kv_registry_test.exs test/maxio/admin/config_kv_help_test.exs test/maxio/admin/config_kv_endpoint_test.exs test/maxio/admin/plug_test.exs test/maxio/admin/error_map_test.exs test/mix/tasks/maxio_admin_config_test.exs test/maxio/compat/external_smoke_test.exs
  git commit -m "test(admin): specify config help behavior"
  ```

### Task 3: GREEN the Registry/Schema help projection

**Owner:** Lane B implementation author. **Reviewer:** fresh Lane C context.

**Files:**

- Modify: `lib/maxio/admin/config_kv/registry.ex`
- Create: `lib/maxio/admin/config_kv/help.ex`
- Modify: `lib/maxio/admin/error_map.ex`

**Interfaces:**

- Consumes: `Schema.fetch/2`, `Schema.describe_type/1`, `Schema.env_var/2`, current forbidden sets.
- Produces:

  ```elixir
  Registry.subsystems() :: [map()]
  Registry.classify_subsystem(String.t()) :: {:ok, map()} | {:error, :forbidden | :unknown_subsystem}
  Help.project(String.t(), String.t(), boolean()) :: {:ok, map()} | {:error, map()}
  Help.encode_line(Jason.OrderedObject.t()) :: iodata()
  Help.describe_error(term()) :: String.t()
  ```

- [ ] **Step 1: Convert Registry to one ordered declaration.** Use nested subsystem entries with the exact
  descriptions from the spec; derive the existing flat `entries/0` result. Do not change the three wire/core
  mappings or introduce user-input atom conversion.

- [ ] **Step 2: Implement safe classification.** Forbidden subsystem/path wins over unknown; hidden paths
  return `:wire_hidden`; `classify_subsystem/1` never enumerates sensitive entries.

- [ ] **Step 3: Implement projection control flow.** The core branch must remain visibly small:

  ```elixir
  cond do
    sub_sys == "" -> project_catalog(env_only?)
    String.contains?(sub_sys, ":") -> error(:invalid_argument, sub_sys, :parser)
    key == "" -> project_subsystem(sub_sys, env_only?)
    true -> project_key(sub_sys, key, env_only?)
  end
  ```

  Top-level intentionally ignores nonempty key and remains the 3-item catalog for every env presence. A known
  nonempty subsystem in env-only mode filters by `Schema.env_var/2`; direct unbound env key returns the same
  safe unknown-key ConfigError evidence.

- [ ] **Step 4: Build exact ordered wire.** Use `Jason.OrderedObject.new/1` for both Help and HelpKV in the
  madmin-client field order from the spec, deliberately not the pinned MinIO server raw order.
  `encode_line/1` must be equivalent to:

  ```elixir
  [Jason.encode_to_iodata!(wire), "\n"]
  ```

- [ ] **Step 5: Extend ErrorMap narrowly.** Accept only
  `unknown key KEY for sub-system SUBSYSTEM` where both pieces pass existing identifier and sensitive-marker
  filters. Do not add a generic interpolation escape hatch.

- [ ] **Step 6: Run core GREEN.** Run:

  ```powershell
  mix test test/maxio/admin/config_kv_registry_test.exs test/maxio/admin/config_kv_help_test.exs test/maxio/admin/error_map_test.exs
  mix test test/maxio/admin/config_kv_adapter_test.exs test/maxio/admin/config_kv_parser_test.exs test/maxio/admin/config_kv_request_test.exs
  mix compile --warnings-as-errors
  ```

  Expected: all listed suites PASS; S5 Adapter/Parser/Request remain unchanged.

- [ ] **Step 7: Commit core production.** Run:

  ```powershell
  git add lib/maxio/admin/config_kv/registry.ex lib/maxio/admin/config_kv/help.ex lib/maxio/admin/error_map.ex
  git commit -m "feat(admin): add config help catalog projection"
  ```

- [ ] **Step 8: Independent task review.** Lane C reviews Task 2 RED commit through this commit for exact
  order/descriptions, no duplicate Schema values, no Config/Repo calls, no sensitive enumeration and narrow
  ErrorMap. Accepted findings follow the Lane T RED → Lane B fix loop and commit
  `fix(admin): harden config help projection`; Lane C re-reviews.

### Task 4: GREEN the exact Admin HTTP surface

**Owner:** Lane B implementation author. **Reviewer:** a new Lane C context, not Task 3's author.

**Files:**

- Modify: `lib/maxio/admin/plug.ex`

**Interfaces:**

- Consumes: `Help.project/3`, `Help.encode_line/1`, `ErrorMap.from_reason/1`, existing
  `authorize_and_run/4`, Config KVS boundary and safe metadata.
- Produces: exact `GET /minio/admin/v3/help-config-kv` handler with plaintext response.

- [ ] **Step 1: Add exact dispatch and raw-query classification.** Add only:

  ```elixir
  defp dispatch(conn, "GET", "/minio/admin/v3/help-config-kv"), do: help_config_kv(conn)
  defp raw_query_route?("GET", "/minio/admin/v3/help-config-kv"), do: true
  ```

  Wrong methods/versions/suffixes continue through existing 501 fallback.

- [ ] **Step 2: Implement missing-query and auth precedence.** Inside the existing Config KVS rescue
  boundary, fetch query params, require both names with `Map.has_key?/2`, then authorize ConfigUpdate:

  ```elixir
  if Map.has_key?(conn.query_params, "subSys") and Map.has_key?(conn.query_params, "key") do
    authorize_and_run(conn, @config_update_action, "admin_config_help", fn conn ->
      help_config_kv_authorized(conn, conn.query_params["subSys"], conn.query_params["key"])
    end)
  else
    render_error(conn, ErrorMap.from_reason(:admin_version_mismatch))
  end
  ```

- [ ] **Step 3: Project without caller secret/body/Repo.** Compute env with
  `Map.has_key?(conn.query_params, "env")`, obtain only the exact actor access-key id needed for safe logs,
  call Help and route evidence through a shared Config KVS evidence renderer. Do not call signing-secret,
  Request, Adapter or `read_body`.

- [ ] **Step 4: Generalize failure rendering without changing S5 semantics.** Extract a private
  `render_config_evidence_error(conn, action, evidence)` used by the old adapter wrapper and help. Preserve
  existing S5 action/reason/status/log bytes; add `config_action(:help)` and include help in dotted Config KVS
  AccessDenied handling.

- [ ] **Step 5: Add exact response helper.** It must perform:

  ```elixir
  body = Help.encode_line(result.wire)

  conn
  |> delete_resp_header("transfer-encoding")
  |> delete_resp_header("content-encoding")
  |> delete_resp_header("x-minio-config-applied")
  |> put_resp_header("content-type", "application/json")
  |> put_resp_header("content-length", Integer.to_string(IO.iodata_length(body)))
  |> send_resp(200, body)
  |> halt()
  ```

- [ ] **Step 6: Log only frozen metadata.** Success message/action/count fields must match the spec. Failure
  stage is only parser/exposure; no raw query, wire, description or value reaches logs.

- [ ] **Step 7: Run HTTP GREEN and S5 regression.** Run:

  ```powershell
  mix test test/maxio/admin/config_kv_endpoint_test.exs test/maxio/admin/plug_test.exs test/maxio/admin/authz_test.exs
  mix test test/maxio/admin/config_kv_request_test.exs test/maxio/admin/envelope_test.exs
  mix compile --warnings-as-errors
  ```

- [ ] **Step 8: Commit HTTP production.** Run:

  ```powershell
  git add lib/maxio/admin/plug.ex
  git commit -m "feat(admin): expose config help endpoint"
  ```

- [ ] **Step 9: Independent task review.** Lane C audits authentication → query presence → action →
  target/exposure precedence, exact headers/body, authorization 后 help handler 零 body read/SIO/Config Repo,
  dotted AccessDenied and S5 helper
  preservation. Accepted findings use RED-first fixes and `fix(admin): correct config help endpoint`, then
  re-review.

### Task 5: GREEN the DB-free Mix help CLI

**Owner:** Lane B implementation author. **Reviewer:** fresh Lane C context.

**Files:**

- Create: `lib/mix/tasks/maxio.admin.config.help.ex`

**Interfaces:**

- Consumes: `Help.project/3`, `Help.encode_line/1`, `Help.describe_error/1`.
- Produces: `mix maxio.admin.config.help [--env] [subsystem [key]]`.

- [ ] **Step 1: Parse exact options and arity.** Use `OptionParser.parse/2` with strict `[env: :boolean]` and
  no aliases. Map positional args exactly:

  ```elixir
  [] -> {"", ""}
  [subsystem] -> {subsystem, ""}
  [subsystem, key] -> {subsystem, key}
  _other -> Mix.raise(@usage)
  ```

  Unknown/invalid options also raise the same fixed usage.

- [ ] **Step 2: Call the pure boundary only.** On success use `IO.write(Help.encode_line(result.wire))`;
  on error use `Mix.raise(Help.describe_error(evidence.reason))`. Do not call `Mix.Task.run("app.start")`,
  `Maxio.Config.CLI.boot/0`, Adapter, Repo or Ecto.

- [ ] **Step 3: Run CLI GREEN.** Run:

  ```powershell
  mix test test/mix/tasks/maxio_admin_config_test.exs
  mix maxio.admin.config.help
  mix maxio.admin.config.help s3 clock_skew_ms
  mix maxio.admin.config.help --env s3
  ```

  Expected: test PASS and each manual command emits one compact JSON line; no DB connection is required.

- [ ] **Step 4: Commit CLI.** Run:

  ```powershell
  git add lib/mix/tasks/maxio.admin.config.help.ex
  git commit -m "feat(cli): add admin config help task"
  ```

- [ ] **Step 5: Independent task review.** Lane C checks exact bytes/arity/env/error redaction and searches
  for boot/Repo/Ecto dependencies. Accepted findings use RED-first fixes and
  `fix(cli): harden admin config help task`, then re-review.

### Task 6: GREEN native mc help orchestration

**Owner:** Lane B implementation author. **Reviewer:** fresh Lane C context.

**Files:**

- Modify: `lib/maxio/compat/external_smoke.ex`

**Interfaces:**

- Consumes: existing isolated alias/config-dir runner and Task 1 human/JSON fixture expectations.
- Produces: fake-observable and strict-live-ready alias-only get/reset and set-help stages.

- [ ] **Step 1: Add read-only help stages before the existing mutation lifecycle.** In both human and JSON
  modes enqueue exact native commands:

  ```elixir
  ["admin", "config", "get", alias_name]
  ["admin", "config", "reset", alias_name]
  ["admin", "config", "set", alias_name, "s3"]
  ["admin", "config", "set", alias_name, "s3", "clock_skew_ms"]
  ```

  Preserve the existing global position of `--json`, proxy bypass, redaction and isolated aliases.

- [ ] **Step 2: Preserve failure semantics.** A failed help stage is the primary blocker with exact stage id,
  exit/stdout/stderr evidence. Because help is read-only, it does not add reset cleanup; the pre-existing
  config lifecycle cleanup remains unconditional and secondary.

- [ ] **Step 3: Label evidence honestly.** Fake-runner result fields say `fixture_expected`/`fake_observed`,
  never `live_pass`. Do not infer server route from an expected transcript; record argv so tests prove which
  native client branch was used.

- [ ] **Step 4: Run smoke GREEN.** Run:

  ```powershell
  mix test test/maxio/compat/external_smoke_test.exs
  mix compile --warnings-as-errors
  ```

- [ ] **Step 5: Commit smoke production.** Run:

  ```powershell
  git add lib/maxio/compat/external_smoke.ex
  git commit -m "test(compat): exercise native config help paths"
  ```

- [ ] **Step 6: Independent task review.** Lane C checks exact argv/global JSON position, human/JSON state
  isolation, no help mutation/cleanup, primary-vs-cleanup error handling and fake/live labels. Accepted
  findings use RED-first fixes and `fix(compat): correct config help smoke`, then re-review.

### Task 7: Document the implemented surface

**Owner:** Lane B documentation author after Tasks 3–6 are GREEN. **Reviewer:** Lane C.

**Files:**

- Modify: `README.md`

**Interfaces:**

- Consumes: reviewed production behavior and spec.
- Produces: current user-facing Config KVS capability statement; does not claim strict-live PASS prematurely.

- [ ] **Step 1: Update the route list.** Add `GET /minio/admin/v3/help-config-kv` with required
  `subSys`/`key`, optional presence `env`, plaintext JSON and ConfigUpdate action. Keep the three encrypted
  get/set/reset routes unchanged.

- [ ] **Step 2: Document exact catalog and deviations.** List the three ordered Maxio keys, alias-only
  get/reset/set-help behavior, no target, empty `subSys` + env 仍为 3-item catalog、已知 nonempty
  subsystem env-only 过滤后 `keysHelp: []`、no fabricated binding, and no
  defaults/current values/secrets in help.

- [ ] **Step 3: Add the CLI example.** Include:

  ```text
  mix maxio.admin.config.help
  mix maxio.admin.config.help s3 clock_skew_ms
  mix maxio.admin.config.help --env s3
  ```

- [ ] **Step 4: Correct remaining non-goals.** Remove help from the current unsupported list while retaining
  export/import/history/targets/full official catalog/secrets/backend bindings/service restart.

- [ ] **Step 5: Check and commit README only.** Run:

  ```powershell
  git diff --check -- README.md
  git add README.md
  git commit -m "docs: document admin config help support"
  ```

- [ ] **Step 6: Independent docs review.** Lane C cross-checks every claim against tests/production and
  rejects fixture/fake wording presented as live. Accepted corrections commit as
  `docs: correct admin config help scope` and are re-reviewed.

### Task 8: Run the combined focused batch before live

**Owner:** Lane F verification runner. No production author may self-certify this gate.

**Files:** all S6 production/test/fixture/README files; no STATUS change.

**Interfaces:**

- Consumes: all task-reviewed commits from Tasks 1–7.
- Produces: one recorded combined focused/compile/format/diff evidence set; no commit and no completion claim.

- [ ] **Step 1: Run all S6 and affected S5 tests together.** Run:

  ```powershell
  mix test test/maxio/admin/config_kv_help_protocol_fixture_test.exs test/maxio/admin/config_kv_protocol_fixture_test.exs test/maxio/admin/config_kv_registry_test.exs test/maxio/admin/config_kv_help_test.exs test/maxio/admin/config_kv_parser_test.exs test/maxio/admin/config_kv_adapter_test.exs test/maxio/admin/config_kv_request_test.exs test/maxio/admin/config_kv_endpoint_test.exs test/maxio/admin/error_map_test.exs test/maxio/admin/plug_test.exs test/maxio/admin/authz_test.exs test/maxio/admin/envelope_test.exs test/mix/tasks/maxio_admin_config_test.exs test/maxio/compat/external_smoke_test.exs
  ```

  Record exact exit and test/exclusion counts in ignored progress/evidence.

- [ ] **Step 2: Run cheap static gates, not precommit.** Run:

  ```powershell
  mix compile --warnings-as-errors
  mix format --check-formatted lib/maxio/admin/config_kv/registry.ex lib/maxio/admin/config_kv/help.ex lib/maxio/admin/error_map.ex lib/maxio/admin/plug.ex lib/mix/tasks/maxio.admin.config.help.ex lib/maxio/compat/external_smoke.ex test/maxio/admin/config_kv_help_protocol_fixture_test.exs test/maxio/admin/config_kv_registry_test.exs test/maxio/admin/config_kv_help_test.exs test/maxio/admin/config_kv_endpoint_test.exs test/maxio/admin/plug_test.exs test/maxio/admin/error_map_test.exs test/mix/tasks/maxio_admin_config_test.exs test/maxio/compat/external_smoke_test.exs
  git diff --check 124dc3bac2dca72f228ea9ae39077032b4d3580f..HEAD
  ```

- [ ] **Step 3: Audit forbidden paths.** Run:

  ```powershell
  git diff --name-only 124dc3bac2dca72f228ea9ae39077032b4d3580f..HEAD
  git diff 124dc3bac2dca72f228ea9ae39077032b4d3580f..HEAD -- lib/maxio/admin/config_kv/parser.ex lib/maxio/admin/config_kv/adapter.ex lib/maxio/admin/config_kv/request.ex lib/maxio/config.ex lib/maxio/config/schema.ex priv/repo/migrations
  ```

  Expected: second command has no diff; no credential/live artifact is tracked.

- [ ] **Step 4: Route failures back through RED-first ownership.** Lane T adds regression, Lane B fixes,
  Lane C reviews; Lane F reruns only affected focused commands and then this combined batch. Do not run
  `mix precommit` here.

### Task 9: Run strict pinned mc and direct HTTP evidence

**Owner:** Lane G strict-live operator. Raw artifacts stay ignored.

**Files:**

- Write only ignored: `artifacts/admin-config-help-s6/2026-08-29-live/`
- Optionally update ignored: `.superpowers/sdd/2026-08-29-minio-admin-config-help-s6/progress.md`

**Interfaces:**

- Consumes: reviewed GREEN server, pinned native mc, isolated endpoint/credentials/alias dir.
- Produces: V-H1/V-H2 and Maxio exact framing/auth/no-mutation evidence for whole-range reviewers.

- [ ] **Step 1: Pin identities.** Record native `mc --version`, binary hash/correlation to `77f82e1`, Maxio
  HEAD, endpoint, redacted credential identity and isolated `MC_CONFIG_DIR`. A different mc is exploratory.

  Use these exact native command positions; `NO_COLOR` and redirected stdout/stderr provide non-TTY capture:

  ```powershell
  $env:NO_COLOR = "1"
  & $env:MAXIO_MC_BIN admin config get $env:MAXIO_MC_ALIAS
  & $env:MAXIO_MC_BIN admin config reset $env:MAXIO_MC_ALIAS
  & $env:MAXIO_MC_BIN --json admin config get $env:MAXIO_MC_ALIAS
  & $env:MAXIO_MC_BIN --json admin config reset $env:MAXIO_MC_ALIAS
  & $env:MAXIO_MC_BIN admin config set $env:MAXIO_MC_ALIAS s3
  & $env:MAXIO_MC_BIN admin config set $env:MAXIO_MC_ALIAS s3 clock_skew_ms
  & $env:MAXIO_MC_BIN --json admin config set $env:MAXIO_MC_ALIAS s3
  & $env:MAXIO_MC_BIN --json admin config set $env:MAXIO_MC_ALIAS s3 clock_skew_ms
  ```

- [ ] **Step 2: Capture alias-only human bytes.** Run get and reset against a fresh alias in non-TTY/no-color
  mode. Record argv, exit, stdout/stderr bytes and assert all three subsystem descriptions identify their
  concrete Maxio keys.

- [ ] **Step 3: Capture alias-only JSON bytes independently.** Use a separate alias/config state and pinned
  global `--json` placement. Assert compact one-line mc wrapper, one LF, no human headings and no mutation.

- [ ] **Step 4: Capture set-help branches.** Run `mc admin config set ALIAS s3` and
  `mc admin config set ALIAS s3 clock_skew_ms` in human and JSON modes; assert detailed type/description and
  that neither invokes set-config-kv.

- [ ] **Step 5: Capture direct Maxio HTTP matrix.** With disposable signed requests prove request has no
  body/CL/TE/CT; response is plaintext JSON+LF/application-json/exact CL/no TE/CE/SIO/apply header. Capture
  anonymous, missing one/both queries, empty query, action denied, target, safe unknown, forbidden, hidden and
  top/subsystem/direct env behavior. Assert Maxio raw HelpKV order is the deliberate madmin-client order,
  distinct from pinned MinIO server raw order. Every error capture must prove
  `application/json; charset=utf-8`, exact compact-body CL and no TE/CE/LF/SIO. Redact Authorization and
  credentials.

- [ ] **Step 6: Prove route and state effects.** Server evidence must show help route hits and no get/delete
  calls for alias-only commands. Compare `runtime_configs` and `runtime_config_audits` before/after: unchanged.

- [ ] **Step 7: Close V-H1.** Probe pinned MinIO directly with no env, `env`, `env=` and `env=false`; record
  whether its apparent `r.Form` behavior observes presence. Classify Maxio honestly as match or deliberate
  repair/deviation; never add fake env bindings to chase upstream output.

- [ ] **Step 8: Close V-H2.** Compare pinned native human/JSON bytes to Task 1 fixture. If spacing/order differs,
  Lane R corrects source fixtures, Lane T corrects fixture/RED tests, Lane B changes production only if the
  Maxio contract is wrong, Lane C reviews, and Lane F reruns focused batch. Do not normalize beyond the
  repository's explicit Windows CRLF rule.

- [ ] **Step 9: Invalidate and rerun every affected live capture.** Any correction made while closing V-H1,
  V-H2, a fixture or a test invalidates the relevant prior pinned-MinIO/native-mc capture and comparison;
  rerun that affected live probe even when production did not change. Any production change invalidates all
  affected Maxio native captures plus direct auth/error/success framing and runtime/audit no-mutation evidence;
  rerun those direct probes and state comparisons before recording a replacement result. Mark old artifacts
  `superseded` rather than silently editing them. A corrected fixture/test/production commit with no affected
  native/live rerun cannot pass Task 9.

- [ ] **Step 10: Classify blockers.** Missing pinned mc, endpoint, credentials or request capture produces a
  per-probe `BLOCKED` record naming the missing capability. Exit 0 with zero business probes is not PASS.

- [ ] **Step 11: Keep live work uncommitted.** No live artifact, alias file, credential file or transcript is
  added to git; Task 9 has no commit. Only redacted factual summaries may later enter STATUS.

### Task 10: Independent dual whole-range review

**Owner:** Lane D and Lane E in separate contexts. Both are read-only reviewers.

**Range:** `124dc3bac2dca72f228ea9ae39077032b4d3580f..HEAD`

**Files:** read-only review of every tracked file in the range plus ignored redacted Task 9 evidence.

**Interfaces:**

- Consumes: task-reviewed commits, combined focused evidence and strict-live PASS/BLOCKED records.
- Produces: two independent severity-ranked verdicts. No review-only commit; only accepted fixes create the
  explicitly named fix commit below.

- [ ] **Step 0: Establish the exact review range.** Both reviewers run:

  ```powershell
  git diff --stat 124dc3bac2dca72f228ea9ae39077032b4d3580f..HEAD
  git diff --name-status 124dc3bac2dca72f228ea9ae39077032b4d3580f..HEAD
  git log --oneline --decorate 124dc3bac2dca72f228ea9ae39077032b4d3580f..HEAD
  ```

- [ ] **Step 1: Lane D protocol/client review.** Audit pinned hashes, exact route/query presence/action,
  missing-vs-empty and auth precedence, Help/HelpKV fields/order/zero values/descriptions/types, one LF,
  request/response framing, no SIO, env and target deviations, madmin unknown-field compatibility, native
  get/reset/set-help human/JSON argv/bytes and fake-vs-live labels.

- [ ] **Step 2: Lane E architecture/security review.** Audit Registry as single ordered exposure source,
  Schema-only type/env, no defaults/runtime values, fail-closed sensitive/forbidden/hidden handling, no atom
  creation, Help purity/no Repo/Config, narrow ErrorMap, safe structured logs, zero body read and unchanged
  Parser/Adapter/Request/Envelope/Config/Schema/migrations. Also audit the live-discovered transport exception:
  `ResponseTransformPolicy` is immediately after `SurfaceClassifier`, adds/merges
  `Cache-Control: no-transform` only for path-style `:admin`, and leaves ordinary S3, vhost same-path requests,
  IAM/STS and health/metrics unchanged.

- [ ] **Step 3: Both reviewers issue severity-ranked verdicts.** Completion requires zero Critical/Important.
  A review that only says “looks good” without file/contract evidence is invalid.

- [ ] **Step 4: Close accepted findings through owning lanes.** Lane T first adds failing regression; Lane B
  makes architecture-consistent fix and runs owning focused suite; commit all review fixes with:

  ```powershell
  git commit -m "fix(admin): close config help review findings"
  ```

  Lane C task-reviews the fix, then both Lane D/E re-review the amended whole range.
  The only accepted S3 Endpoint transport correction may touch `lib/maxio/s3/endpoint.ex` and
  `lib/maxio/s3/plugs/response_transform_policy.ex`; it must remain the classifier-gated Admin-only policy
  above and must not move help projection/auth/framing into the S3 request pipeline.

- [ ] **Step 5: Invalidate stale evidence correctly.** Any fixture/test/V-H1/V-H2 correction after Task 9
  invalidates and must rerun the affected pinned-MinIO/native-mc live probe and comparison. Any production
  change additionally invalidates direct Maxio success/error framing, route and runtime/audit state evidence;
  rerun them plus the Task 8 combined batch before proceeding. Superseded captures cannot support STATUS.

### Task 11: Final verification and the single `mix precommit`

**Owner:** Lane F, after Tasks 8–10 and both whole-range approvals.

**Files:** no intentional changes.

**Interfaces:**

- Consumes: amended Task 8 evidence, Task 9 live classification and zero-Critical/Important Lane D/E verdicts.
- Produces: the sole final successful precommit evidence identity; Task 11 has no commit unless a failure
  reopens RED-first implementation/review work.

- [ ] **Step 1: Re-run the Task 8 combined focused command.** Record exact counts/exits for STATUS.

- [ ] **Step 2: Re-run compile/format/diff gates.** Run the exact Task 8 Step 2/3 commands and confirm clean
  tracked state, no forbidden paths and no generated/live artifacts.

- [ ] **Step 3: Run the one final gate.** Run once:

  ```powershell
  mix precommit
  ```

  Record exit, test/exclusion count and pre-existing warning classification. If it fails, fix through
  RED-first lanes and treat only the replacement successful run as the final gate; do not report multiple
  slice-level precommits.

- [ ] **Step 4: Freeze the implementation evidence identity.** Record HEAD, dual-review verdicts, combined
  focused result, final precommit result and each strict-live PASS/BLOCKED result in ignored progress. No
  further production/test/README change is allowed without invalidating this gate.

### Task 12: STATUS-only factual closeout

**Owner:** Lane H STATUS author. **Reviewer:** a different Lane H context.

**Files:**

- Modify only: `docs/superpowers/STATUS.md`

**Interfaces:**

- Consumes: immutable implementation HEAD, final verification counts, dual-review verdicts and live
  PASS/BLOCKED evidence.
- Produces: one evidence-backed STATUS-only commit; it changes no implementation claim or protocol contract.

- [ ] **Step 1: Record implementation facts.** Add exact route/query/action/plaintext schema/framing, three
  ordered descriptions/types, env/target deviations, no secret/default/runtime/Config DB, CLI and native mc
  branches. 全局 Admin authentication 仍按现有 credential backend 工作，不得误写为整个
  HTTP request 无任何 DB 访问。

- [ ] **Step 2: Record evidence.** Include commit range, focused commands/counts, compile/format/diff, Lane
  D/E verdicts, the single final precommit and strict-live V-H1/V-H2 PASS or exact BLOCKED reasons.

- [ ] **Step 3: Record remaining scope.** Keep export/import/history/targets/full official catalog/secrets/
  backend bindings/service restart explicit. Do not claim full MinIO Config compatibility or live PASS from
  fixtures/fake runner.

- [ ] **Step 4: Independent STATUS-only review.** Reviewer checks every implemented/passed sentence against
  committed files and recorded evidence. Verify:

  ```powershell
  git status --short
  git diff --name-only HEAD
  git diff --check -- docs/superpowers/STATUS.md
  ```

  Expected: only STATUS differs and its facts are evidence-backed.

- [ ] **Step 5: Commit only STATUS.** Run:

  ```powershell
  git add docs/superpowers/STATUS.md
  git commit -m "docs(status): record admin config help S6 evidence"
  git status --short
  ```

  Expected: clean worktree. The docs-only STATUS commit does not require rerunning precommit.

### Task 13: Fast-forward integration and atomic push

**Owner:** Lane I integration controller.

**Files:** no file content changes; only verified git refs may move.

**Interfaces:**

- Consumes: clean reviewed feature HEAD and clean master integration worktree.
- Produces: master and `codex/admin-config-help-s6` pointing at the same final SHA on local and origin; no new
  commit is created by ff-only integration.

- [ ] **Step 1: Verify feature ancestry and identity.** Run:

  ```powershell
  git status --short
  git rev-parse HEAD
  git merge-base --is-ancestor 124dc3bac2dca72f228ea9ae39077032b4d3580f HEAD
  git fetch origin
  ```

  Expected: feature worktree clean and ancestry succeeds.

- [ ] **Step 2: Protect the integration worktree.** Locate the main worktree with `git worktree list`, then
  verify its master is clean. If it has any user change, stop and report exact paths; never reset, force
  checkout, stash or overwrite them.

- [ ] **Step 3: Require remote/master stability.** Confirm `origin/master` still equals or is an ancestor of
  feature HEAD. If master advanced independently, stop for deliberate rebase/review; do not force push.

- [ ] **Step 4: Fast-forward only.** In the clean integration worktree run:

  ```powershell
  git merge --ff-only codex/admin-config-help-s6
  ```

- [ ] **Step 5: Push both refs atomically.** Run:

  ```powershell
  git push --atomic origin refs/heads/master:refs/heads/master refs/heads/codex/admin-config-help-s6:refs/heads/codex/admin-config-help-s6
  ```

  On rejection, diagnose and retry atomically; never partially push one ref and never use `--force`.

- [ ] **Step 6: Verify final remote identities.** Fetch, compare local master/feature with both remote refs,
  confirm both worktrees clean, and report final SHA, dual-review verdicts, final precommit and each strict-live
  PASS/BLOCKED classification.

---

## Explicit Non-Goals

- 不修改 S5 get/set/reset 的 method/path/query/SIO/framing/parser/mutation 合约。
- 不实现 full config export/import、history API、service restart、named targets 或 official MinIO
  catalog。
- 不暴露 deployment identity、root/access-key secret、SSE/KMS/MFA 密钥、Repo/topology/
  authoritative-source/storage/credential/policy backend。
- 不新增 env binding、default/runtime/current/source/version/value 字段或动态 help catalog。
- 不新增 migration、Repo query、transaction、advisory lock、audit、broadcast、reconcile 或多节点
  state machine。
- 不让 Help/Plug/Mix 复制 Parser/Adapter/Request/Config 逻辑，不对 user input 造 atom。
- 除 `SurfaceClassifier` 后接入 Admin-only `ResponseTransformPolicy` 的 transport exception 外，不修改
  S3 Endpoint/SigV4/Authz 的业务路由或语义；普通 S3、vhost 同路径、IAM/STS、health/metrics
  保持不变，也不修改 logger metadata allowlist。
- 不实现 Mix human renderer，不把 fake/source-derived transcript 冒充 pinned live evidence。
