# MinIO Admin Policy S3 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在现有 MinIO Admin v3 管控面上实现 `attach-policy`、`detach-policy` 与 `policy-entities`，使当前 `mc admin policy` 的人类输出和 JSON 输出生命周期可以通过真实 SigV4、madmin envelope 与 S3 数据面取证，同时保持 IAM 插件边界、批量原子性和身份代际安全。

**Architecture:** `Maxio.Admin.Plug` 只负责协议、鉴权、加解密与错误呈现，`PolicyAdapter` 只依赖 `Maxio.IAM` 公共门面；批量关联和实体聚合分别作为 `Maxio.Policy.Store` behaviour 的原子写回调与一致性读回调，由 EctoStore 实现。写路径在单事务内锁定身份与按稳定顺序锁定策略，提交后仅广播一次；读路径用单个一致性快照构造双向映射，绝不由 HTTP 层做 N+1 拼装。

**Tech Stack:** Elixir 1.18、Phoenix/Plug、Ecto/PostgreSQL、Jason、现有 `Maxio.Admin.Envelope`、`Maxio.Admin.Authz`、`Maxio.Policy.Store`、ExUnit、Mix CLI、真实 `mc`/aws-cli 外部 smoke。

**Spec:** `docs/superpowers/specs/2026-08-20-minio-admin-user-policy-design.md`；本计划中的 P6/P7 协议裁决与官方固定源码证据优先于该设计输入中尚未落实批量事务或当前 wire 细节的描述。

## Global Constraints

- 固定起点必须是 `fb6244a568ee1b649a9394c72d11e6061910e00b`；实施分支为 `codex/admin-policy-s3`，不得夹带其它工作树变更。
- 协议证据固定在 MinIO `7aac2a2c5b7c882e68c1ce017d8256be2feea27f`、madmin-go `6897865311e2be91d814ea0ef4814a730d87d1cd`、mc `77f82e18b5401a65958f1619df6ebb994634bd88`。实现前把定位到的文件、符号、行义与 SHA 写入 fixture README；不得用浮动 `master` 或记忆替代。
- 标为 `VERIFY-AT-IMPL` 的惊讶边界必须先由固定源码或真实兼容服务器取证，再把精确 fixture/test 写红；在证据固定前不得猜测字符串、字段缺省或排序。
- Admin 层不得直接访问 Repo、Ecto schema 或具体 Store 后端；`PolicyAdapter` 不得绕过 `Maxio.IAM` 公共门面。
- `POST` body 必须 exact `application/octet-stream`、已知且 `<= 262_272` bytes 的 `Content-Length`，并通过现有 madmin envelope 用调用者 signing secret 解密；零长度按 upstream 自然进入 decrypt 并得到 bad-envelope 结构化 400，不在 transport gate 发明另一种外部错误。错误响应保持明文结构化 Admin JSON，成功响应加密。
- P6 的多个 policy 是一个命令、一个事务、一个结果：不得循环调用现有单策略 attach/detach 后再补偿；任一身份、策略、quota、状态或持久化失败必须零写入。
- 锁顺序固定为身份代际/身份行、principal quota 域、按 ARN 排序的 managed-policy 行；任何入口不得以请求顺序拿策略锁。
- 用户写必须复用 `Maxio.IAM.UserIdentity` generation-safe snapshot/lock；组写必须以不可变 group id 快照并在锁内复核 name/id，避免删除重建后写到新实体。Maxio 不复刻 upstream user TOCTOU。
- Store 聚合 backend 回调及其 `_without_notify` facade 不得自行广播；只有 IAM 门面在 backend 事务成功返回后广播一次 `{:principal_policy_changed, principal_arn}`。rollback/no-effect 不广播，通知不得先于提交。
- P7 必须在一个 DB 一致性快照内产生所有方向；不得先查用户再查组/策略而允许跨查询漂移。
- P7 对 upstream 持久化 STS-user policy mapping 存在一项明确、wire-visible 的 model-scope deviation：Maxio 当前模型不表示该映射，因此本批不投影它。fixture README、根 README、STATUS、自动测试、strict live 预期和独立 review 都必须显式登记；不得把它静默归入普通过滤或宣称完全等价。
- 不复刻 upstream 的 bad-envelope 500 和 disabled-group 500：前者沿用 `400 XMinioAdminConfigBadJSON`；后者使用 `400 XMinioAdminInvalidArgument` 与稳定安全消息 `The specified group is disabled and cannot receive policy association updates.`，并在兼容性文档与 STATUS 记录有意偏差。
- 所有新日志使用既有结构化日志，至少包含 `request_id`、`admin_action`、`required_actions`、`authorized_action`、principal kind/name、operation、requested/changed policy count；不得记录 secret、envelope 明文或完整 policy 文档。
- 开发期只跑聚焦测试、`mix compile --warnings-as-errors` 和必要的格式检查。独立 review 通过且最后修复完成后只跑一次最终 `mix precommit`；最终门禁后若代码再变，先聚焦验证，再用一次替代性的最终 `mix precommit`，不得累计宣称旧结果。
- 实现作者、规范审查者、代码审查者、验证者必须是不同 lane；作者不得自审。严格 live 因缺少原生 `mc`、兼容服务器或凭据可标记 `BLOCKED`，但必须记录精确 blocker，绝不能把未运行的 mc 输出写成已通过。

---

## Frozen Wire Contract

### P6: policy association mutation

- 路由：`POST /minio/admin/v3/idp/builtin/policy/attach` 与 `POST /minio/admin/v3/idp/builtin/policy/detach`；同一 v3 route family 的 unknown `{operation}` 必须先经过 exact Content-Type 与 Content-Length gates，再返回 `400 XMinioAdminInvalidArgument`，不能落入 501。v4 与其它路径不回落。
- 鉴权是 OR，不是 AND：`admin:UpdatePolicyAssociation` 或 `admin:AttachUserOrGroupPolicy` 任一允许即可；日志同时记录候选 action 与实际通过的 action。
- 请求解密后的 JSON 结构为 `policies` 加且仅加一个 `user`/`group`。`policies` 必须为非空字符串数组；拒绝空数组、非法项、两种主体都给、两种都不给及错误 JSON 类型。对额外 JSON 字段的处理严格跟随 pinned madmin/MinIO fixture，不额外发明防御规则。重复 policy 在事务前去重，规范化结果按 policy name/ARN 排序。
- `Content-Type` 必须逐字节等于 `application/octet-stream`；`Content-Length` 必须已知且 `<= 262_272`。chunked、缺失或超限在读 body/decrypt 前拒绝；`Content-Length: 0` 跟随 upstream 进入 envelope decrypt，自然得到 `400 XMinioAdminConfigBadJSON`。若实现因共享 ControlBody 限制必须前置拒绝零长度，也只能返回同一 code/status，并作为 bad-envelope 防御偏差写入 fixture README/README/STATUS；优先采用自然 decrypt，避免新增偏差。
- 成功为 `200`、`Content-Type: application/json`、加密 madmin envelope；attach 明文含 `policiesAttached`，detach 明文含 `policiesDetached`，值为**实际发生变化**的 policy name 升序数组，并含 `updatedAt`。
- 服务端 no-effect 固定返回 `400 XMinioAdminPolicyChangeAlreadyApplied`，不写库、不广播；pinned mc 明确吞并该错误，并按**原始请求 policy 列表**合成成功展示，保留调用顺序和重复项，而不是采用服务端去重/排序结果。精确 message 和 human/JSON envelope 必须写入 fixture。
- P6 校验/错误优先级冻结为：解密 JSON 的 `IsValid` → target 校验 → operation-specific policy/no-effect。user target 顺序为 temporary-user 限制 → root-user 限制 → user exists；group target 顺序为 group exists → group disabled。attach 随后验证每个请求 policy 存在，再判 no-effect；detach **不验证请求 policy 是否存在**，只计算当前 attachment 与请求集的交集，交集非空即成功删除实际交集，交集为空才 no-effect。
- 组合错误矩阵必须锁定：非法 request 压过 target/policy；target error 压过 missing-policy/no-effect；attach missing policy 压过 no-effect 且整个批次零写；detach 中不存在/未附加项在存在实际交集时被忽略并成功，只在整个交集为空时返回 no-effect。不存在的用户/组、非根路径 managed policy、quota 超限、disabled group、bad envelope 均是结构化错误；bad envelope 映射 `XMinioAdminConfigBadJSON`，disabled group 映射上文固定的 `XMinioAdminInvalidArgument`。

### P7: policy entities projection

- 路由：`GET /minio/admin/v3/idp/builtin/policy-entities`。
- 鉴权是 OR：`admin:ListGroups`、`admin:ListUsers`、`admin:ListUserPolicies` 任一允许即可。
- 从原始 query string 解析重复 `user`、`group`、`policy` 键，不允许 `Plug.Conn.fetch_query_params/1` 折叠重复值；值去重后升序传入 IAM。malformed percent encoding 的 upstream 行为尚未由 pinned 证据固定，保持 `VERIFY-AT-IMPL`；若 Maxio 选择结构化 400，必须登记为防御偏差，不能伪装成 pinned parity。
- 成功为 `200`、`Content-Type: application/json`、加密 madmin envelope，并含一次快照的 `timestamp`。
- 用户过滤器对应 user mappings（直接 policy 与 `memberOfMappings`），组过滤器对应 group mappings，policy 过滤器对应 policy mappings 的 users/groups。仅投影 root-path managed policy attachment；不混入 inline policy、role、permissions boundary、OIDC、LDAP。upstream 持久化 STS-user policy mapping 按上文 model-scope deviation 明确不投影。
- unknown/unmapped filter 值从映射结果省略。空 query 启用全量 root managed-policy projection；若没有任何 mapping，顶层 `policyMappings` 因 `omitempty` 也省略，响应可以只有 `timestamp`。所有顶层 mapping 数组在空时省略；映射对象内部没有 `omitempty` 的 slice 字段在无值时按 pinned JSON 编码为 `null`。顶层 mapping 记录及每个内部 name/policy/member/users/groups 列表全部使用稳定字典序；不得依赖 DB 返回顺序。

## Public Interfaces to Add

```elixir
# lib/maxio/admin/policy_association_request.ex
@spec validate_transport!(Plug.Conn.t()) :: non_neg_integer()

@spec read!(Plug.Conn.t(), Maxio.Auth.SigningSecret.t(), non_neg_integer()) ::
        {Plug.Conn.t(), %{policies: [String.t()], principal: {:user | :group, String.t()}}}

# lib/maxio/admin/policy_entities_request.ex
@spec parse!(binary()) :: %{
        users: [String.t()],
        groups: [String.t()],
        policies: [String.t()],
        requested: MapSet.t(:user | :group | :policy)
      }

# lib/maxio/iam.ex
@spec update_managed_policy_associations_strict(
        :attach | :detach,
        {:user | :group, String.t()},
        [String.t()]
      ) ::
        {:ok, %{changed_policy_arns: [String.t()], updated_at: DateTime.t()}}
        | {:error, term()}

@spec query_builtin_policy_entities(%{
        required(:users) => [String.t()],
        required(:groups) => [String.t()],
        required(:policy_arns) => [String.t()],
        required(:requested) => MapSet.t(:user | :group | :policy)
      }) :: {:ok, map()} | {:error, term()}

# lib/maxio/policy/store.ex behaviour and facade
@callback update_builtin_managed_policy_associations(
            :user | :group,
            principal_arn :: String.t(),
            :attach | :detach,
            policy_arns :: [String.t()]
          ) ::
            {:ok, %{changed_policy_arns: [String.t()], updated_at: DateTime.t()}}
            | {:error, term()}

@spec update_builtin_managed_policy_associations_without_notify(
        :user | :group,
        String.t(),
        :attach | :detach,
        [String.t()]
      ) ::
        {:ok, %{changed_policy_arns: [String.t()], updated_at: DateTime.t()}}
        | {:error, term()}

@callback query_builtin_managed_policy_entities(%{
            required(:users) => [String.t()],
            required(:groups) => [String.t()],
            required(:policy_arns) => [String.t()],
            required(:requested) => MapSet.t(:user | :group | :policy)
          }) :: {:ok, map()} | {:error, term()}

# lib/maxio/admin/authz.ex
@spec authorize_any(map(), [String.t()], map()) ::
        {:ok, authorized_action :: String.t()} | {:error, term()}
```

The two new Store callbacks are required for a configured backend that advertises Admin builtin policy support. The Store `_without_notify` facade must return `{:error, :not_supported}` when an older/plugin backend does not export them; it must not silently emulate atomicity by looping singular callbacks. `Maxio.IAM` owns the single post-commit notification.

## Ownership and Review Lanes

- **Lane A — spec reviewer (read-only):** validates Tasks 1–2 fixtures and this wire/transaction contract against the three pinned repositories before any production implementation.
- **Lane B — implementation author:** writes RED tests then minimal production code and owns all fixes; never issues the independent approval.
- **Lane C — code/architecture reviewer (read-only):** audits adapter boundaries, transaction/lock order, generation safety, response omission rules, secrets and notification timing after the coherent batch.
- **Lane D — verification/live evidence (read-only except generated ignored artifacts):** runs focused suites, compile/format, one final precommit and strict external smoke; does not repair failures.
- **Lane E — STATUS reviewer (read-only):** checks final facts and blocker wording before the STATUS-only commit.

## Task 1: Freeze upstream protocol fixtures before production code

**Files:**

- Create: `test/fixtures/minio_admin_policy_s3/README.md`
- Create: `test/fixtures/minio_admin_policy_s3/minio_p6_policy_association.json`
- Create: `test/fixtures/minio_admin_policy_s3/minio_p7_policy_entities.json`
- Create: `test/fixtures/minio_admin_policy_s3/mc_policy_lifecycle.json`
- Test: `test/maxio/admin/policy_association_request_test.exs`
- Test: `test/maxio/admin/policy_entities_request_test.exs`

- [ ] **Step 1: Inspect pinned source and capture exact evidence.** Record repository, full SHA, source path/function and the source-derived byte/string/value for content type, length cap, route/method, unknown-operation gate order, zero-length decrypt behavior, action alternatives, P6 validation/error precedence, attach-vs-detach policy lookup, encrypted response keys, exact no-effect code/message, mc no-effect synthesis preserving request order/duplicates, query repetition, `omitempty`/inner-null behavior, stable sorting, unknown/unmapped omission, upstream STS-user policy mapping and mc human/JSON rendering. Resolve malformed-percent handling if pinned code proves it；otherwise keep that one boundary explicitly `VERIFY-AT-IMPL` or identify the chosen Maxio defense deviation.
- [ ] **Step 2: Write fixture-shape RED tests.** Tests load the JSON fixtures and assert pinned SHA, exact wire samples, P6 combination-error matrix, P7 empty/no-mapping/unknown/inner-null cases, and a named `maxio_model_scope_deviations` entry for omitted upstream persisted STS-user mappings so drift or silent hand edits fail loudly.
- [ ] **Step 3: Run RED narrowly.** Run `mix test test/maxio/admin/policy_association_request_test.exs test/maxio/admin/policy_entities_request_test.exs`; expected failure is missing request modules, not malformed fixtures.
- [ ] **Step 4: Lane A reviews source evidence.** No production work starts until the independent reviewer confirms OR auth, unknown-operation/zero-length gates, frozen P6 error order, attach/detach asymmetry, server no-effect versus mc synthesis, exact P7 omission/null/sort behavior, malformed-percent classification, upstream STS mapping and the explicit Maxio model-scope deviation directly against pinned source.
- [ ] **Step 5: Commit fixture contract.** `git add test/fixtures/minio_admin_policy_s3 test/maxio/admin/policy_association_request_test.exs test/maxio/admin/policy_entities_request_test.exs && git commit -m "test(admin): pin policy association protocol"`.

## Task 2: Add strict P6/P7 request parsing and OR authorization

**Files:**

- Create: `lib/maxio/admin/policy_association_request.ex`
- Create: `lib/maxio/admin/policy_entities_request.ex`
- Modify: `lib/maxio/admin/authz.ex`
- Modify: `lib/maxio/admin/error_map.ex`
- Modify: `lib/maxio/s3/error.ex`
- Test: `test/maxio/admin/policy_association_request_test.exs`
- Test: `test/maxio/admin/policy_entities_request_test.exs`
- Test: `test/maxio/admin/authz_test.exs`
- Test: `test/maxio/admin/error_map_test.exs`

- [ ] **Step 1: Extend RED matrices.** Cover exact media type, missing/negative-equivalent/oversize length, zero length naturally reaching decrypt and returning `XMinioAdminConfigBadJSON`, bounded multi-chunk reads, payload-hash integrity, decrypt/authentication failure, malformed JSON, fixture-defined extra-key behavior, empty policies, dedupe/sort, exactly-one principal and `IsValid` precedence. For P7 cover repeated/bare/percent-encoded keys, duplicates, absent filters and fixture-defined unrelated-query behavior；malformed percent gets only the pinned behavior or a clearly named Maxio defense-deviation assertion.
- [ ] **Step 2: Add OR-auth RED tests.** Assert first allowed action is returned, fallback action succeeds, all-denied returns access denied, evaluator/storage error is not converted to an allow, and action order is deterministic for logging.
- [ ] **Step 3: Implement request modules by reusing `Maxio.Admin.ControlBody` and `Maxio.Admin.Envelope`.** `PolicyAssociationRequest.validate_transport!/1` owns exact CT/CL and returns the parsed non-negative length so generic routing can reject unknown operation after those gates；`read!/3` consumes that length exactly once, then decrypts/decodes/validates. P7 `parse!/1` consumes the raw query string and returns normalized filters plus the requested-dimension set.
- [ ] **Step 4: Implement `Authz.authorize_any/3` and exact errors.** Add structured mappings for bad encrypted/config JSON, no-effect, no-such-group and disabled-group without exposing exception text. Lock exact MinIO codes/status/messages to fixtures where upstream is intentionally followed; name/document Maxio compatibility deviations where it is not.
- [ ] **Step 5: Run focused GREEN.** `mix test test/maxio/admin/policy_association_request_test.exs test/maxio/admin/policy_entities_request_test.exs test/maxio/admin/authz_test.exs test/maxio/admin/error_map_test.exs`.
- [ ] **Step 6: Commit protocol primitives.** `git add lib/maxio/admin/policy_association_request.ex lib/maxio/admin/policy_entities_request.ex lib/maxio/admin/authz.ex lib/maxio/admin/error_map.ex lib/maxio/s3/error.ex test/maxio/admin && git commit -m "feat(admin): parse policy association requests"`.

## Task 3: Add atomic Store mutation contract

**Files:**

- Modify: `lib/maxio/policy/store.ex`
- Modify: `lib/maxio/policy/store/ecto_store.ex`
- Modify: `lib/maxio/iam.ex`
- Test: `test/maxio/policy/store_optional_callbacks_test.exs`
- Test: `test/maxio/policy/store/ecto_store_test.exs`
- Create: `test/maxio/iam/minio_admin_policy_test.exs`
- Test: `test/maxio/iam/credential_invalidation_test.exs`

- [ ] **Step 1: Write Store behaviour RED tests.** Assert unsupported plugin backends return `{:error, :not_supported}` without singular-callback fallback; backend 与 Store `_without_notify` facade 均不发通知。
- [ ] **Step 2: Write Ecto atomicity RED tests.** Exercise multi-policy attach/detach, partial existing state returning only changed ARNs, all-existing/all-absent no-effect, duplicate inputs, attach with one missing policy rolling back, detach with missing/unattached names plus a non-empty intersection succeeding, detach with an empty intersection returning no-effect, quota overflow computed on the final attach set, disabled group, and rollback after a later validation error. Add the full combination matrix proving target errors precede attach missing-policy/no-effect and detach never requires policy existence. After every failure assert the complete attachment set is unchanged.
- [ ] **Step 3: Write race and lock-order tests without sleeps.** Use transaction barriers/messages and `Task`/monitors to prove request-order inversion cannot deadlock because policy locks are ARN-sorted; prove delete/recreate user cannot accept the stale generation; prove delete/recreate group cannot redirect the stale mutation; prove concurrent quota contenders cannot both exceed 10 attachments.
- [ ] **Step 4: Implement the backend transaction.** Normalize requested root policy names, take the identity snapshot, enter one transaction, and reproduce the frozen target order: user temporary/root/existence or group existence/disabled. For attach, serialize quota then lock every requested policy row in stable ARN order, fail atomically if any is missing, derive delta, then no-effect/quota/write. For detach, lock only current matching attachment/policy rows in stable order without requiring requested policies to exist, derive the intersection, return no-effect only when it is empty, and delete only that intersection. Revalidate immutable principal identity before write, use conflict/row-count checks, and return one DB-derived `updated_at`.
- [ ] **Step 5: Implement the no-notify Store facade.** The Ecto callback completes the transaction before returning; the facade preserves actual changed ARNs and rejects backend results that violate the callback shape, but never broadcasts.
- [ ] **Step 6: Implement the IAM strict public mutation and notification timing.** Map `{kind, name}` to generation-safe identity handling, reject non-root paths, preserve typed errors, and expose no Repo/backend details. Broadcast exactly once only after the no-notify Store call returns success; typed error/no-effect paths broadcast nothing. Existing singular attach/detach APIs remain behaviorally unchanged.
- [ ] **Step 7: Lock current cache behavior.** `CacheInvalidator` currently has no identity-policy cache to evict, so do not add a speculative cache. Assert the committed event reaches the existing invalidation subscriber and that an immediate policy evaluation observes attach/detach; document the event as the future cache hook.
- [ ] **Step 8: Run focused GREEN.** `mix test test/maxio/policy/store_optional_callbacks_test.exs test/maxio/policy/store/ecto_store_test.exs test/maxio/iam/minio_admin_policy_test.exs test/maxio/iam/credential_invalidation_test.exs`.
- [ ] **Step 9: Commit atomic mutation.** `git add lib/maxio/policy/store.ex lib/maxio/policy/store/ecto_store.ex lib/maxio/iam.ex test/maxio/policy test/maxio/iam/minio_admin_policy_test.exs test/maxio/iam/credential_invalidation_test.exs && git commit -m "feat(iam): update policy associations atomically"`.

## Task 4: Add consistent policy-entities projection

**Files:**

- Modify: `lib/maxio/policy/store.ex`
- Modify: `lib/maxio/policy/store/ecto_store.ex`
- Modify: `lib/maxio/iam.ex`
- Test: `test/maxio/policy/store_optional_callbacks_test.exs`
- Test: `test/maxio/policy/store/ecto_store_test.exs`
- Test: `test/maxio/iam/minio_admin_policy_test.exs`

- [ ] **Step 1: Write projection RED tests.** Cover user direct-policy mappings, user `memberOfMappings`, group mappings, reverse policy users/groups, multiple repeated filters, duplicate filters, unknown/unmapped values omitted, all top-level empty arrays omitted, empty query enabling policy projection, empty query with no mapping yielding timestamp-only, inner non-omitempty empty slices encoding as `null`, and stable lexicographic order for every mapping and nested list.
- [ ] **Step 2: Prove scope and deviation boundaries.** Seed non-root managed policies, inline policies, roles, boundaries, disabled users/groups, memberships and STS/OIDC-adjacent rows. Assert only pinned builtin semantics appear；add an explicit assertion and fixture reference that Maxio omits the upstream persisted STS-user policy mapping because its model cannot represent that relation, and label this as `model_scope_deviation` rather than ordinary parity. Lock disabled-identity read behavior independently from the intentional disabled-group mutation error.
- [ ] **Step 3: Prove snapshot consistency.** Introduce a deterministic transaction barrier and mutate membership/attachment from another connection between would-be phases; assert one P7 response is entirely before or entirely after the mutation, never mixed. Do not use `Process.sleep/1`.
- [ ] **Step 4: Implement one aggregate read callback.** Run under a documented PostgreSQL repeatable-read transaction or an equivalent single-statement snapshot, prefetch the bounded relation set without N+1 queries, omit unknown/unmapped filters, generate one timestamp for that snapshot, and sort every outer record and nested string list lexicographically. Empty query means all root policy mappings, not “no dimensions requested”. Do not fabricate STS mappings absent from the Maxio model.
- [ ] **Step 5: Implement IAM facade projection.** Normalize names to builtin ARNs, carry requested dimensions separately from empty value lists, return typed backend errors and keep all wire-key naming in Admin adapter code.
- [ ] **Step 6: Run focused GREEN.** `mix test test/maxio/policy/store_optional_callbacks_test.exs test/maxio/policy/store/ecto_store_test.exs test/maxio/iam/minio_admin_policy_test.exs`.
- [ ] **Step 7: Commit consistent projection.** `git add lib/maxio/policy/store.ex lib/maxio/policy/store/ecto_store.ex lib/maxio/iam.ex test/maxio/policy test/maxio/iam/minio_admin_policy_test.exs && git commit -m "feat(iam): query builtin policy entities"`.

## Task 5: Wire P6 through PolicyAdapter and Admin Plug

**Files:**

- Modify: `lib/maxio/admin/policy_adapter.ex`
- Modify: `lib/maxio/admin/plug.ex`
- Test: `test/maxio/admin/policy_adapter_test.exs`
- Test: `test/maxio/admin/policy_endpoint_test.exs`
- Test: `test/maxio/admin/plug_test.exs`

- [ ] **Step 1: Write adapter RED tests.** Assert policy names become root-path ARNs, actual changed ARNs become sorted policy names, `updatedAt` is formatted exactly, and all typed IAM errors pass to `ErrorMap`. Add a boundary test that fails if Adapter directly calls Store/Repo.
- [ ] **Step 2: Write endpoint RED tests.** For both attach and detach cover valid user/group requests, multiple policies, partial-change success body, exact `400 XMinioAdminPolicyChangeAlreadyApplied`, missing targets, frozen user/group target precedence, attach missing-policy precedence, detach ignoring missing policies when an intersection exists, disabled group, bad envelope 400, zero-length natural decrypt, exact content gates, missing signing secret, encrypted response decryptability and plaintext-error behavior.
- [ ] **Step 3: Add authorization and dispatch RED tests.** Each action alone must authorize; neither must deny. Authenticated P6 routes must no longer return 501. A POST to `/minio/admin/v3/idp/builtin/policy/unknown` with invalid CL/CT must fail its content gate, while valid CL/CT must return `400 XMinioAdminInvalidArgument` without falling to 501；wrong method, unrelated path and v4 retain existing classification. Anonymous requests remain 403 before route disclosure.
- [ ] **Step 4: Implement thin adapter and endpoint.** Add one generic POST dispatch for `/minio/admin/v3/idp/builtin/policy/{operation}`: authenticate, validate exact CT/CL, then reject an unknown operation with `XMinioAdminInvalidArgument` before envelope decrypt；known attach/detach continues through decrypt/`IsValid` and calls the adapter once. `Plug` encrypts the adapter result and logs requested/changed counts. Do not reconstruct changed policy names from the request. With valid CT and `Content-Length: 0`, unknown operation returns operation-invalid while known operation naturally reaches decrypt and returns config-bad-JSON.
- [ ] **Step 5: Assert notification and data-plane outcomes.** Endpoint tests subscribe to the notification path and prove one event after commit; use the real policy evaluator to prove attachment grants and detach revokes without cache-stale acceptance.
- [ ] **Step 6: Run focused GREEN.** `mix test test/maxio/admin/policy_adapter_test.exs test/maxio/admin/policy_endpoint_test.exs test/maxio/admin/plug_test.exs test/maxio/s3/identity_policy_authz_test.exs`.
- [ ] **Step 7: Commit P6 endpoint.** `git add lib/maxio/admin/policy_adapter.ex lib/maxio/admin/plug.ex test/maxio/admin test/maxio/s3/identity_policy_authz_test.exs && git commit -m "feat(admin): attach and detach builtin policies"`.

## Task 6: Wire P7 through PolicyAdapter and Admin Plug

**Files:**

- Modify: `lib/maxio/admin/policy_adapter.ex`
- Modify: `lib/maxio/admin/plug.ex`
- Test: `test/maxio/admin/policy_adapter_test.exs`
- Test: `test/maxio/admin/policy_endpoint_test.exs`
- Test: `test/maxio/admin/plug_test.exs`

- [ ] **Step 1: Write adapter wire RED tests.** Project IAM structs/maps to exact madmin field names and timestamp encoding；prove unknown/unmapped records are omitted, every top-level empty mapping array is omitted, empty query enables policy projection but may encode only `timestamp` when there are no mappings, inner non-omitempty empty slices encode as `null`, and every outer/nested collection is stable lexicographic order. Assert no STS mapping is fabricated and tag the expectation with the fixture’s model-scope deviation id.
- [ ] **Step 2: Write endpoint RED tests.** Cover each filter, repeated mixed filters, empty query with/without mappings, unknown entity omission, encoded names, encrypted response and missing signing secret. Malformed-percent behavior must use the pinned fixture result or explicitly assert/document the selected structured-400 defense deviation. Decrypt endpoint bodies and compare semantic JSON plus exact fixture fields.
- [ ] **Step 3: Write OR auth/501 RED tests.** Each of `ListGroups`, `ListUsers`, `ListUserPolicies` independently succeeds; all denied fails. Authenticated exact GET leaves 501, wrong methods/v4 stay 501, anonymous remains 403.
- [ ] **Step 4: Implement P7 endpoint.** Preserve `conn.query_string` before generic query-param normalization, call IAM exactly once, encode/encrypt once, and log requested filter counts without names if names are sensitive under current logging policy.
- [ ] **Step 5: Run focused GREEN.** `mix test test/maxio/admin/policy_adapter_test.exs test/maxio/admin/policy_endpoint_test.exs test/maxio/admin/plug_test.exs`.
- [ ] **Step 6: Commit P7 endpoint.** `git add lib/maxio/admin/policy_adapter.ex lib/maxio/admin/plug.ex test/maxio/admin && git commit -m "feat(admin): expose builtin policy entities"`.

## Task 7: Add first-party CLI observability

**Files:**

- Create: `lib/mix/tasks/maxio.admin.policy.attach.ex`
- Create: `lib/mix/tasks/maxio.admin.policy.detach.ex`
- Create: `lib/mix/tasks/maxio.admin.policy.entities.ex`
- Create: `test/mix/tasks/maxio_admin_policy_association_test.exs`
- Modify: `test/mix/tasks/maxio_admin_policy_test.exs`

- [ ] **Step 1: Write CLI RED tests.** Require `--user` xor `--group`, one-or-more policy names for mutations, repeatable `--user/--group/--policy` for entities, stable human output, machine-readable `--json`, nonzero exit/structured stderr for no-effect and typed errors, and no secrets in argv/output.
- [ ] **Step 2: Implement tasks only through public IAM.** Tasks start the application using existing Mix conventions, share normalization/formatting where justified, print operation, principal, sorted actual changes and timestamp, and never call EctoStore directly.
- [ ] **Step 3: Add log-capture assertions.** Confirm structured events expose operation/counts/request correlation available to local diagnosis while omitting secret and policy document data.
- [ ] **Step 4: Run focused GREEN.** `mix test test/mix/tasks/maxio_admin_policy_association_test.exs test/mix/tasks/maxio_admin_policy_test.exs`.
- [ ] **Step 5: Commit CLI.** `git add lib/mix/tasks/maxio.admin.policy.attach.ex lib/mix/tasks/maxio.admin.policy.detach.ex lib/mix/tasks/maxio.admin.policy.entities.ex test/mix/tasks && git commit -m "feat(cli): inspect policy associations"`.

## Task 8: Extend independent human and JSON external smoke lifecycles

**Files:**

- Modify: `lib/maxio/compat/admin_user_fixture.ex`
- Modify: `lib/maxio/compat/external_smoke.ex`
- Modify: `test/maxio/compat/admin_user_fixture_test.exs`
- Modify: `test/maxio/compat/external_smoke_test.exs`
- Modify: `test/fixtures/admin/policy_s1_live.json`
- Modify: `test/fixtures/minio_admin_policy_s3/mc_policy_lifecycle.json`
- Modify: `README.md`

- [ ] **Step 1: Write fixture RED tests.** Add an option such as `initial_list_buckets_policy: false` so the smoke-created user starts without the bootstrap ListBuckets grant. Change the dedicated smoke managed policy to `s3:ListAllMyBuckets` on `*`; assert this fixture is only for association data-plane proof and does not weaken general test identities.
- [ ] **Step 2: Write exact human-mode lifecycle RED tests.** With a fake external runner, assert command order and exact source-pinned stdout/stderr expectations: `mc admin policy create ALIAS POLICY FILE`, create an unprivileged user, baseline `mc ls ALIAS` denied, `mc admin policy attach ALIAS POLICY --user USER`, S3 list succeeds, repeat attach with an intentionally ordered/duplicated policy argv and assert mc swallows server `XMinioAdminPolicyChangeAlreadyApplied` then synthesizes success from the original order/duplicates, query `mc admin policy entities ALIAS --user USER --policy POLICY` using repeated filters, detach, S3 list denied, reattach, run the existing disable/enable user lifecycle, remove user, then remove policy. Assert cleanup detaches/deletes user before policy removal after every injected failure.
- [ ] **Step 3: Write exact JSON-mode lifecycle RED tests.** Run a completely independent alias/user/policy fixture with the same commands plus `--json` in the pinned mc-supported position and assert parsed JSON objects/codes/fields for every step, including no-effect synthesis order/duplicates and P7 omission/null/sort behavior. Do not reuse artifacts or database state from human mode, and do not accept human text in JSON mode.
- [ ] **Step 4: Implement orchestration.** Keep credentials in environment/stdin-safe plumbing, preserve redaction, include command/exit/status evidence, and ensure a failed detach/cleanup never masks the primary failure. Treat mc no-effect output according to the fixed mc fixture, not generic exit-code assumptions.
- [ ] **Step 5: Document the supported Admin endpoints and intentional deviations.** Update README’s compatibility table for exact P6/P7 routes, encrypted responses, OR auth, atomic batch semantics, the three intentional bug non-reproductions, malformed-percent/zero-length defense deviation only if actually chosen, and the wire-visible omission of upstream persisted STS-user policy mapping due to Maxio’s model scope. Label any unexecuted live transcript as expected contract, not verification evidence.
- [ ] **Step 6: Run focused GREEN.** `mix test test/maxio/compat/admin_user_fixture_test.exs test/maxio/compat/external_smoke_test.exs`.
- [ ] **Step 7: Commit smoke/docs.** `git add lib/maxio/compat test/maxio/compat test/fixtures/admin/policy_s1_live.json test/fixtures/minio_admin_policy_s3/mc_policy_lifecycle.json README.md && git commit -m "test(compat): exercise policy association lifecycle"`.

## Task 9: Coherent-batch verification and independent review

**Files:** all production/test/docs files changed in Tasks 1–8; no STATUS edit yet.

- [ ] **Step 1: Lane B runs low-cost author checks.** Run changed-file `mix format --check-formatted`, all focused commands from Tasks 2–8, and `mix compile --warnings-as-errors`. Fix failures in the owning task’s code and commit each coherent fix; do not run `mix precommit` yet.
- [ ] **Step 2: Lane C performs read-only architecture review.** Audit the entire `fb6244a..HEAD` diff for Admin→Adapter→IAM→Store boundaries, unknown-operation/zero-length gates, OR auth, no plaintext success, frozen P6 target/policy/no-effect precedence, attach/detach asymmetry, mc synthesis fixture, atomicity, stable lock order, identity generation, quota serialization, consistent snapshot, exact P7 omitempty/null/sort semantics, malformed-percent classification, explicit STS model-scope deviation in fixture/README/tests, post-commit notification and secret-free logs. Any silent STS exclusion or unpinned percent claim is an Important blocker.
- [ ] **Step 3: Lane B fixes every accepted finding.** Add a regression test first for each behavior defect, make the smallest architecture-consistent correction, rerun its focused suite and commit. Lane C then re-reviews the amended diff; unresolved high/medium findings block progression.
- [ ] **Step 4: Lane D runs the verification matrix.** Run all changed focused suites together, `mix compile --warnings-as-errors`, `mix format --check-formatted`, `git diff --check fb6244a..HEAD`, and the repository’s policy/IAM/Admin regression suites. Preserve command, exit code and concise result for STATUS.
- [ ] **Step 5: Run exactly one final precommit.** After review approval and all fixes, Lane D runs `mix precommit` once. If anything changes afterward, invalidate that result, run focused verification for the change, then run one replacement final `mix precommit` and record only the replacement as the final gate.
- [ ] **Step 6: Commit verification-only fixes if any.** No generated output or credentials are committed. The branch must be clean before live validation.

## Task 10: Strict native mc and data-plane live evidence

**Files:** no source changes; ignored evidence directory only, followed later by STATUS facts.

- [ ] **Step 1: Pin tools at runtime.** Record native `mc --version`, its SHA/release correlation to `77f82e1`, server commit, endpoint and redacted alias configuration. A different mc build is exploratory only and cannot satisfy the strict gate.
- [ ] **Step 2: Run strict human lifecycle.** Against an isolated live Maxio database, execute the exact human flow from Task 8 and compare output to pinned fixtures, including mc’s no-effect synthesis preserving input order/duplicates and P7 stable omission/null output. Capture encrypted Admin request success through mc plus the denied→allowed→denied S3 transition.
- [ ] **Step 3: Run strict JSON lifecycle independently.** Reset/use a distinct isolated identity and policy, execute `--json` flow, validate every JSON line/schema/code, confirm timestamp-only P7 is possible on an empty isolated mapping set, and repeat the data-plane transition. Explicitly record that upstream persisted STS-user policy mappings are outside Maxio’s current model and therefore absent from expected Maxio wire output；do not score that absence as full upstream parity. Do not infer JSON pass from human pass.
- [ ] **Step 4: Exercise group and concurrency probes.** Attach/detach multiple policies to a real group, query user/group/policy mappings, verify no-effect 400, disabled-group structured 400, and run concurrent reversed-order batches to show no deadlock/partial state.
- [ ] **Step 5: Classify unavailable live infrastructure honestly.** If the pinned native mc, PostgreSQL, server endpoint or safe credentials are unavailable, mark strict live `BLOCKED` with the exact missing prerequisite and list which automated/fake-runner evidence did pass. Never paste an expected transcript as an observed one.

## Task 11: STATUS-only closeout commit

**Files:**

- Modify only: `docs/superpowers/STATUS.md`

- [ ] **Step 1: Update factual status after all gates.** Record implemented P6/P7 routes, precise P6 precedence/no-effect+mc behavior, precise P7 omission/null/sort contract, atomic/snapshot guarantees, tests and final precommit command/result, review conclusion, strict human/JSON live PASS or exact BLOCKED reason, fixed upstream SHAs, intentional deviations (user TOCTOU, bad-envelope 500, disabled-group 500, persisted STS-user policy mapping model scope, and malformed-percent/zero-length only if implementation chose a defense deviation), remaining unsupported boundaries and commit range.
- [ ] **Step 2: Lane E reviews STATUS against evidence.** Confirm every “passed/implemented” statement is backed by command output or live artifact, no unverified mc output is presented as live, and remaining work is explicit.
- [ ] **Step 3: Commit only STATUS.** Verify `git status --short` lists only `docs/superpowers/STATUS.md`, then run `git add docs/superpowers/STATUS.md && git commit -m "docs(status): record admin policy S3 evidence"`.
- [ ] **Step 4: Confirm clean branch.** `git status --short` must be empty; `git diff --name-only fb6244a..HEAD` must contain only planned implementation/test/docs paths.

## Task 12: Fast-forward integration and atomic push

- [ ] **Step 1: Revalidate identities and ancestry.** In the feature worktree record `git rev-parse HEAD`, `git status --short`, `git merge-base --is-ancestor fb6244a568ee1b649a9394c72d11e6061910e00b HEAD`; confirm clean and expected commits.
- [ ] **Step 2: Fast-forward the clean main worktree only.** In the repository’s integration worktree verify no user changes, then run `git merge --ff-only codex/admin-policy-s3`. Never reset, force-checkout or merge over a dirty worktree.
- [ ] **Step 3: Push both refs atomically.** Run `git push --atomic origin refs/heads/master:refs/heads/master refs/heads/codex/admin-policy-s3:refs/heads/codex/admin-policy-s3`. If remote policy rejects one ref, nothing should publish; diagnose rather than falling back to non-atomic pushes.
- [ ] **Step 4: Verify remote and local state.** Compare local HEAD with both remote refs, confirm both worktrees are clean, and report final SHA, review result, one final precommit result and live PASS/BLOCKED status.

## Explicit Non-Goals

- 不实现 Admin v4、旧 `/set-user-or-group-policy`、policy create/list/info/remove 的新版本或任何 Console UI。
- 不实现 inline policy、role attachment、permissions boundary、STS session policy、service account、LDAP/OIDC/AD/外部 IDP 的 policy-entities 映射。upstream persisted STS-user policy mapping 的缺失必须作为 wire-visible model-scope deviation 单独登记，不能被这条 non-goal 静默吸收。
- 不新增或修改数据库 migration；现有 user/group managed-policy attachment schema 与注释足以承载本批次。若实施发现 schema 不足，停止并回到架构审查，不在本批次临时加列。
- 不把单策略 API 循环包装成“批量原子”，不使用补偿删除，不在 endpoint 内拼事务或缓存失效。
- 不复制 upstream 已知缺陷：user TOCTOU、bad envelope 500、disabled group 500；偏差必须稳定、结构化并有测试/文档。
- 不声称对未固定版本的 mc 兼容，不把 fake runner、源码推断或预期输出冒充严格 live 成功。
