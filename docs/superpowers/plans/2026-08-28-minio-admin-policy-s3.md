# MinIO Admin Policy S3 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** 在现有 MinIO Admin v3 管控面上实现 `attach-policy`、`detach-policy` 与 `policy-entities`，使当前 `mc admin policy` 的人类输出和 JSON 输出生命周期可以通过真实 SigV4、madmin envelope 与 S3 数据面取证，同时保持 IAM 插件边界、批量原子性和身份代际安全。

**Architecture:** `Maxio.Admin.Plug` 只负责协议、鉴权、加解密与错误呈现，`PolicyAdapter` 只依赖 `Maxio.IAM` 公共门面；批量关联和实体聚合分别作为 `Maxio.Policy.Store` behaviour 的原子写回调与一致性读回调，由 EctoStore 实现。写路径在单事务内锁定身份与按稳定顺序锁定策略，提交后仅广播一次；读路径用单个一致性快照构造双向映射，绝不由 HTTP 层做 N+1 拼装。

**Tech Stack:** Elixir 1.18、Phoenix/Plug、Ecto/PostgreSQL、Jason、现有 `Maxio.Admin.Envelope`、`Maxio.Admin.Authz`、`Maxio.Policy.Store`、ExUnit、Mix CLI、真实 `mc`/aws-cli 外部 smoke。

**Spec:** `docs/superpowers/specs/2026-08-20-minio-admin-user-policy-design.md`；本计划中的 P6/P7 协议裁决与官方固定源码证据优先于该设计输入中尚未落实批量事务或当前 wire 细节的描述。

## Global Constraints

- 固定起点必须是 `fb6244a568ee1b649a9394c72d11e6061910e00b`；实施分支为 `codex/admin-policy-s3`，不得夹带其它工作树变更。
- 协议证据固定在 MinIO `7aac2a2c5b7c882e68c1ce017d8256be2feea27f`、madmin-go `6897865311e2be91d814ea0ef4814a730d87d1cd`、mc `77f82e18b5401a65958f1619df6ebb994634bd88`。实现前把定位到的文件、符号、行义与 SHA 写入 fixture README；不得用浮动 `master` 或记忆替代。
- 标为 `VERIFY-AT-IMPL` 的惊讶边界必须先由固定源码或真实兼容服务器取证，再把精确 fixture/test 写红；在证据固定前不得猜测字符串、字段缺省或排序。
- Admin 层不得直接访问 Repo、Ecto schema 或具体 Store 后端；`PolicyAdapter` 不得绕过 `Maxio.IAM` 公共门面。
- `POST` body 必须 exact `application/octet-stream`、已知且为正的 `Content-Length`、请求 body 上限 `262_272` bytes，并通过现有 madmin envelope 用调用者 signing secret 解密；错误响应保持明文结构化 Admin JSON，成功响应加密。
- P6 的多个 policy 是一个命令、一个事务、一个结果：不得循环调用现有单策略 attach/detach 后再补偿；任一身份、策略、quota、状态或持久化失败必须零写入。
- 锁顺序固定为身份代际/身份行、principal quota 域、按 ARN 排序的 managed-policy 行；任何入口不得以请求顺序拿策略锁。
- 用户写必须复用 `Maxio.IAM.UserIdentity` generation-safe snapshot/lock；组写必须以不可变 group id 快照并在锁内复核 name/id，避免删除重建后写到新实体。Maxio 不复刻 upstream user TOCTOU。
- Store 聚合 backend 回调及其 `_without_notify` facade 不得自行广播；只有 IAM 门面在 backend 事务成功返回后广播一次 `{:principal_policy_changed, principal_arn}`。rollback/no-effect 不广播，通知不得先于提交。
- P7 必须在一个 DB 一致性快照内产生所有方向；不得先查用户再查组/策略而允许跨查询漂移。
- 不复刻 upstream 的 bad-envelope 500 和 disabled-group 500：前者沿用 `400 XMinioAdminConfigBadJSON`；后者使用 `400 XMinioAdminInvalidArgument` 与稳定安全消息 `The specified group is disabled and cannot receive policy association updates.`，并在兼容性文档与 STATUS 记录有意偏差。
- 所有新日志使用既有结构化日志，至少包含 `request_id`、`admin_action`、`required_actions`、`authorized_action`、principal kind/name、operation、requested/changed policy count；不得记录 secret、envelope 明文或完整 policy 文档。
- 开发期只跑聚焦测试、`mix compile --warnings-as-errors` 和必要的格式检查。独立 review 通过且最后修复完成后只跑一次最终 `mix precommit`；最终门禁后若代码再变，先聚焦验证，再用一次替代性的最终 `mix precommit`，不得累计宣称旧结果。
- 实现作者、规范审查者、代码审查者、验证者必须是不同 lane；作者不得自审。严格 live 因缺少原生 `mc`、兼容服务器或凭据可标记 `BLOCKED`，但必须记录精确 blocker，绝不能把未运行的 mc 输出写成已通过。

## Frozen Wire Contract

### P6: policy association mutation

- 路由：`POST /minio/admin/v3/idp/builtin/policy/attach` 与 `POST /minio/admin/v3/idp/builtin/policy/detach`；其它 operation 仍走结构化未实现/无效参数裁决，v4 不回落。
- 鉴权是 OR，不是 AND：`admin:UpdatePolicyAssociation` 或 `admin:AttachUserOrGroupPolicy` 任一允许即可；日志同时记录候选 action 与实际通过的 action。
- 请求解密后的 JSON 结构为 `policies` 加且仅加一个 `user`/`group`。`policies` 必须为非空字符串数组；拒绝空数组、非法项、两种主体都给、两种都不给及错误 JSON 类型。对额外 JSON 字段的处理严格跟随 pinned madmin/MinIO fixture，不额外发明防御规则。重复 policy 在事务前去重，规范化结果按 policy name/ARN 排序。
- `Content-Type` 必须逐字节等于 `application/octet-stream`；`Content-Length` 必须已知、`> 0` 且 `<= 262_272`。chunked/缺失/零长度/超限在读 body 或解密前拒绝。
- 成功为 `200`、`Content-Type: application/json`、加密 madmin envelope；attach 明文含 `policiesAttached`，detach 明文含 `policiesDetached`，值为**实际发生变化**的 policy name 升序数组，并含 `updatedAt`。
- 所有目标已处于期望状态时返回 `400 XMinioAdminPolicyChangeAlreadyApplied`，不返回伪成功、不写库、不广播。精确 upstream message 与 mc 对此码的容错展示为 `VERIFY-AT-IMPL`，须从固定 SHA 固化后测试。
- 不存在的用户/组/策略、非根路径 managed policy、quota 超限、disabled group、bad envelope 均是结构化错误；bad envelope 映射 `XMinioAdminConfigBadJSON`，disabled group 映射上文固定的 `XMinioAdminInvalidArgument`。其它错误优先级由锁内校验顺序固定并以测试锁定。

### P7: policy entities projection

- 路由：`GET /minio/admin/v3/idp/builtin/policy-entities`。
- 鉴权是 OR：`admin:ListGroups`、`admin:ListUsers`、`admin:ListUserPolicies` 任一允许即可。
- 从原始 query string 解析重复 `user`、`group`、`policy` 键，不允许 `Plug.Conn.fetch_query_params/1` 折叠重复值；百分号解码错误返回结构化 400。值去重后升序传入 IAM。
- 成功为 `200`、`Content-Type: application/json`、加密 madmin envelope，并含一次快照的 `timestamp`。
- 用户过滤器对应 user mappings（直接 policy 与 `memberOfMappings`），组过滤器对应 group mappings，policy 过滤器对应 policy mappings 的 users/groups。仅投影 root-path managed policy attachment；不混入 inline policy、role、permissions boundary、STS、OIDC、LDAP。
- 空 query 只返回 `policyMappings` 与 `timestamp`；未请求的过滤维度字段完全省略，不输出空占位数组。请求了但不存在的实体如何呈现、映射对象字段名和排序是 `VERIFY-AT-IMPL`，由固定 madmin/MinIO 源码 fixture 决定。

## Public Interfaces to Add

```elixir
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

- [ ] **Step 1: Inspect pinned source and capture exact evidence.** Record repository, full SHA, source path/function and the source-derived byte/string/value for content type, length cap, route/method, action alternatives, encrypted response keys, no-effect code/message, query repetition, omission tags, timestamp formatting, mappings and mc human/JSON rendering. Resolve every `VERIFY-AT-IMPL` item needed by subsequent tests; keep unresolved live-only presentation explicitly labelled as unverified, never as pass evidence.
- [ ] **Step 2: Write fixture-shape RED tests.** Tests load the JSON fixtures and assert pinned SHA, exact wire samples and required cases so drift or hand-edited guesses fail loudly.
- [ ] **Step 3: Run RED narrowly.** Run `mix test test/maxio/admin/policy_association_request_test.exs test/maxio/admin/policy_entities_request_test.exs`; expected failure is missing request modules, not malformed fixtures.
- [ ] **Step 4: Lane A reviews source evidence.** No production work starts until the independent reviewer confirms OR auth, exact body gates, success/no-effect semantics, empty-query omission, missing-entity behavior and mc rendering directly against pinned source.
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

- [ ] **Step 1: Extend RED matrices.** Cover exact media type, missing/zero/negative-equivalent/oversize length, bounded multi-chunk reads, payload-hash integrity, decrypt/authentication failure, malformed JSON, fixture-defined extra-key behavior, empty policies, dedupe/sort, and exactly-one principal. For P7 cover repeated/bare/percent-encoded keys, duplicates, absent filters, invalid percent encoding and fixture-defined unrelated-query behavior.
- [ ] **Step 2: Add OR-auth RED tests.** Assert first allowed action is returned, fallback action succeeds, all-denied returns access denied, evaluator/storage error is not converted to an allow, and action order is deterministic for logging.
- [ ] **Step 3: Implement request modules by reusing `Maxio.Admin.ControlBody` and `Maxio.Admin.Envelope`.** Keep the P6 read/decrypt/decode pipeline in one module; P7 consumes the raw query string and returns normalized filters plus the requested-dimension set.
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
- [ ] **Step 2: Write Ecto atomicity RED tests.** Exercise multi-policy attach/detach, partial existing state returning only changed ARNs, all-existing/all-absent no-effect, duplicate inputs, missing one policy, quota overflow computed on the final set, disabled group, and rollback after a later validation error. After every failure assert the complete attachment set is unchanged.
- [ ] **Step 3: Write race and lock-order tests without sleeps.** Use transaction barriers/messages and `Task`/monitors to prove request-order inversion cannot deadlock because policy locks are ARN-sorted; prove delete/recreate user cannot accept the stale generation; prove delete/recreate group cannot redirect the stale mutation; prove concurrent quota contenders cannot both exceed 10 attachments.
- [ ] **Step 4: Implement the backend transaction.** Resolve and normalize root managed-policy ARNs, take identity snapshot, enter one transaction, lock/revalidate the immutable principal identity, serialize its quota domain, lock policy rows in sorted ARN order, validate all targets, calculate the final set once, apply inserts/deletes with conflict/row-count checks, and return a single DB-derived `updated_at`. Roll back with typed reasons on any mismatch or no-effect.
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

- [ ] **Step 1: Write projection RED tests.** Cover user direct-policy mappings, user `memberOfMappings`, group mappings, reverse policy users/groups, multiple repeated filters, deterministic object/list order, duplicate filters, empty query returning all root managed policy mappings only, requested-but-missing entity behavior from the fixture, and omission of unrequested dimensions.
- [ ] **Step 2: Prove exclusion boundaries.** Seed non-root managed policies, inline policies, roles, boundaries, disabled users/groups, memberships and STS/OIDC-adjacent rows. Assert only pinned builtin semantics appear; specifically lock the source-derived disabled-identity read behavior independently from the intentional disabled-group mutation error.
- [ ] **Step 3: Prove snapshot consistency.** Introduce a deterministic transaction barrier and mutate membership/attachment from another connection between would-be phases; assert one P7 response is entirely before or entirely after the mutation, never mixed. Do not use `Process.sleep/1`.
- [ ] **Step 4: Implement one aggregate read callback.** Run under a documented PostgreSQL repeatable-read transaction or an equivalent single-statement snapshot, prefetch the bounded relation set without N+1 queries, generate one timestamp for that snapshot, and sort all mappings by pinned wire keys.
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
- [ ] **Step 2: Write endpoint RED tests.** For both attach and detach cover valid user/group requests, multiple policies, partial-change success body, no-effect 400, missing targets, disabled group, bad envelope 400, exact content gates, missing signing secret, encrypted response decryptability and plaintext-error behavior.
- [ ] **Step 3: Add authorization and dispatch RED tests.** Each action alone must authorize; neither must deny. Authenticated P6 routes must no longer return 501, wrong method and v4 must retain the existing classification. Anonymous requests remain 403 before route disclosure.
- [ ] **Step 4: Implement thin adapter and endpoint.** `Plug` obtains the caller secret, invokes request parser, calls adapter once, encrypts the adapter result and logs requested/changed counts. Do not reconstruct changed policy names from the request.
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

- [ ] **Step 1: Write adapter wire RED tests.** Project IAM structs/maps to exact madmin field names, timestamp encoding and sorted mappings; prove missing dimensions are omitted rather than encoded as empty arrays, while empty query includes only `policyMappings` plus `timestamp`.
- [ ] **Step 2: Write endpoint RED tests.** Cover each filter, repeated mixed filters, empty query, missing entity, encoded names, invalid query, encrypted response and missing signing secret. Decrypt endpoint bodies and compare semantic JSON plus exact fixture fields.
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
- [ ] **Step 2: Write exact human-mode lifecycle RED tests.** With a fake external runner, assert command order and exact source-pinned stdout/stderr expectations: `mc admin policy create ALIAS POLICY FILE`, create an unprivileged user, baseline `mc ls ALIAS` denied, `mc admin policy attach ALIAS POLICY --user USER`, S3 list succeeds, `mc admin policy entities ALIAS --user USER --policy POLICY` using repeated flags where multiple filters are seeded, `mc admin policy detach ALIAS POLICY --user USER`, S3 list denied, reattach, run the existing disable/enable user lifecycle, remove user, then remove policy. Assert cleanup detaches/deletes user before policy removal after every injected failure.
- [ ] **Step 3: Write exact JSON-mode lifecycle RED tests.** Run a completely independent alias/user/policy fixture with the same commands plus `--json` in the pinned mc-supported position and assert parsed JSON objects/codes/fields for every step. Do not reuse artifacts or database state from human mode, and do not accept human text in JSON mode.
- [ ] **Step 4: Implement orchestration.** Keep credentials in environment/stdin-safe plumbing, preserve redaction, include command/exit/status evidence, and ensure a failed detach/cleanup never masks the primary failure. Treat mc no-effect output according to the fixed mc fixture, not generic exit-code assumptions.
- [ ] **Step 5: Document the supported Admin endpoints and intentional deviations.** Update README’s compatibility table for exact P6/P7 routes, encrypted responses, OR auth, atomic batch semantics and the three intentional bug non-reproductions. Label any unexecuted live transcript as expected contract, not verification evidence.
- [ ] **Step 6: Run focused GREEN.** `mix test test/maxio/compat/admin_user_fixture_test.exs test/maxio/compat/external_smoke_test.exs`.
- [ ] **Step 7: Commit smoke/docs.** `git add lib/maxio/compat test/maxio/compat test/fixtures/admin/policy_s1_live.json test/fixtures/minio_admin_policy_s3/mc_policy_lifecycle.json README.md && git commit -m "test(compat): exercise policy association lifecycle"`.

## Task 9: Coherent-batch verification and independent review

**Files:** all production/test/docs files changed in Tasks 1–8; no STATUS edit yet.

- [ ] **Step 1: Lane B runs low-cost author checks.** Run changed-file `mix format --check-formatted`, all focused commands from Tasks 2–8, and `mix compile --warnings-as-errors`. Fix failures in the owning task’s code and commit each coherent fix; do not run `mix precommit` yet.
- [ ] **Step 2: Lane C performs read-only architecture review.** Audit the entire `fb6244a..HEAD` diff for Admin→Adapter→IAM→Store boundaries, exact wire gates, OR auth, no plaintext success, atomicity, stable lock order, identity generation, quota serialization, consistent snapshot, omission semantics, error deviations, post-commit notification and secret-free logs. Report findings with file/line evidence.
- [ ] **Step 3: Lane B fixes every accepted finding.** Add a regression test first for each behavior defect, make the smallest architecture-consistent correction, rerun its focused suite and commit. Lane C then re-reviews the amended diff; unresolved high/medium findings block progression.
- [ ] **Step 4: Lane D runs the verification matrix.** Run all changed focused suites together, `mix compile --warnings-as-errors`, `mix format --check-formatted`, `git diff --check fb6244a..HEAD`, and the repository’s policy/IAM/Admin regression suites. Preserve command, exit code and concise result for STATUS.
- [ ] **Step 5: Run exactly one final precommit.** After review approval and all fixes, Lane D runs `mix precommit` once. If anything changes afterward, invalidate that result, run focused verification for the change, then run one replacement final `mix precommit` and record only the replacement as the final gate.
- [ ] **Step 6: Commit verification-only fixes if any.** No generated output or credentials are committed. The branch must be clean before live validation.

## Task 10: Strict native mc and data-plane live evidence

**Files:** no source changes; ignored evidence directory only, followed later by STATUS facts.

- [ ] **Step 1: Pin tools at runtime.** Record native `mc --version`, its SHA/release correlation to `77f82e1`, server commit, endpoint and redacted alias configuration. A different mc build is exploratory only and cannot satisfy the strict gate.
- [ ] **Step 2: Run strict human lifecycle.** Against an isolated live Maxio database, execute the exact human flow from Task 8 and compare output to pinned fixtures. Capture encrypted Admin request success through mc plus the denied→allowed→denied S3 transition.
- [ ] **Step 3: Run strict JSON lifecycle independently.** Reset/use a distinct isolated identity and policy, execute `--json` flow, validate every JSON line/schema/code and repeat the data-plane transition. Do not infer JSON pass from human pass.
- [ ] **Step 4: Exercise group and concurrency probes.** Attach/detach multiple policies to a real group, query user/group/policy mappings, verify no-effect 400, disabled-group structured 400, and run concurrent reversed-order batches to show no deadlock/partial state.
- [ ] **Step 5: Classify unavailable live infrastructure honestly.** If the pinned native mc, PostgreSQL, server endpoint or safe credentials are unavailable, mark strict live `BLOCKED` with the exact missing prerequisite and list which automated/fake-runner evidence did pass. Never paste an expected transcript as an observed one.

## Task 11: STATUS-only closeout commit

**Files:**

- Modify only: `docs/superpowers/STATUS.md`

- [ ] **Step 1: Update factual status after all gates.** Record implemented P6/P7 routes, precise contract, atomic/snapshot guarantees, tests and final precommit command/result, review conclusion, strict human/JSON live PASS or exact BLOCKED reason, fixed upstream SHAs, intentional deviations (user TOCTOU, bad-envelope 500, disabled-group 500), remaining unsupported boundaries and commit range.
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
- 不实现 inline policy、role attachment、permissions boundary、STS session policy、service account、LDAP/OIDC/AD/外部 IDP 的 policy-entities 映射。
- 不新增或修改数据库 migration；现有 user/group managed-policy attachment schema 与注释足以承载本批次。若实施发现 schema 不足，停止并回到架构审查，不在本批次临时加列。
- 不把单策略 API 循环包装成“批量原子”，不使用补偿删除，不在 endpoint 内拼事务或缓存失效。
- 不复制 upstream 已知缺陷：user TOCTOU、bad envelope 500、disabled group 500；偏差必须稳定、结构化并有测试/文档。
- 不声称对未固定版本的 mc 兼容，不把 fake runner、源码推断或预期输出冒充严格 live 成功。
