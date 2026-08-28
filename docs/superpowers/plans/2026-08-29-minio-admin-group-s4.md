# MinIO Admin Group S4 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在现有 MinIO Admin v3 管控面上完整实现 `mc admin group add/remove/info/list/enable/disable`，使组创建、成员变更、空组删除、状态切换、策略继承与 human/JSON 客户端生命周期都可通过真实 SigV4 和 S3 数据面取证。

**Architecture:** `Maxio.Admin.Plug` 只负责精确路由、鉴权、bounded body 读取、JSON/错误呈现与结构化日志；新增 `Maxio.Admin.GroupRequest` 和 `Maxio.Admin.GroupAdapter` 只调用 `Maxio.IAM` 公共门面。所有 MinIO group 写语义集中在专用 `Maxio.IAM.AdminGroupLifecycle` 中，固定 `GroupIdentity → stable UserIdentity → membership` 锁序并让既有 singular membership writers 委托共享 helper；G2 则由该模块的一条 aggregate SQL statement 生成单快照 `GroupDesc`，不在 Adapter 中拼 N 次查询。

**Tech Stack:** Elixir 1.18、Phoenix/Plug、Ecto/PostgreSQL、Jason、现有 `Maxio.Admin.Authz`/`ErrorMap`/`ControlBody`、`Maxio.IAM.GroupIdentity`/`UserIdentity`、ExUnit、Mix CLI、真实 pinned `mc` external smoke。

**Spec:** `docs/superpowers/specs/2026-08-20-minio-admin-user-policy-design.md`；本计划的 S4 wire、错误顺序、mc 输出与事务裁决以本文的 pinned fixture contract 为准，优先于旧设计输入中尚未落地或已经被协议 lane 修正的描述。

## Global Constraints

- 固定起点必须是 `a83a92bd18652ef685d7bfee14970f99b5c0ac62`，实施分支为 `codex/admin-group-s4`；不得夹带其它工作树或用户变更。
- 协议证据固定在 MinIO `7aac2a2c5b7c882e68c1ce017d8256be2feea27f`、madmin-go `6897865311e2be91d814ea0ef4814a730d87d1cd`、mc `77f82e18b5401a65958f1619df6ebb994634bd88`。fixture README 必须记录 full SHA、文件、函数/类型和逐字节输出来源，不得引用浮动分支。
- Admin 层不得直接调用 Repo、Ecto schema、`Maxio.Policy.Store` 或具体 persistence backend；调用链固定为 `Admin Plug → GroupRequest/GroupAdapter → Maxio.IAM → AdminGroupLifecycle/Repo + existing Policy.Store`。
- 不新增 IAM identity Store 的半套 behaviour。当前 group aggregate 的权威写路径本就由 `Maxio.IAM` 协调 Repo；若未来要把全部 IAM identity backend 插件化，必须另开基础设施批次，不得只给 S4 加一个虚假的 callback。
- G3 是一个请求、一个事务、一个结果；不得循环调用现有 singular add/remove 后补偿。任一 group generation、user generation、成员验证或持久化失败必须零写入。
- 锁序固定为 `GroupIdentity` generation lock，然后按 case-folded user name 稳定排序的 `UserIdentity` generation locks，最后才读写 membership rows。等待 user lock 前不得持有 membership row lock；锁内必须从 immutable UUID 对应行重新取得 canonical ARN。
- 既有 `add_user_to_group[_strict]/2` 和 `remove_user_from_group[_strict]/2` 必须委托共享 transaction helper，避免 Console/CLI/IAM Query 相邻入口绕开锁协议；调用者原有 strict/idempotent 返回语义分别保持。
- G3 delete-empty 只以 membership 为 blocker；成功删除时在同一事务内清理该 group 的 inline policy mapping 与 managed-policy attachments，但不删除 managed policy definitions。IAM Query `DeleteGroup` 继续使用原 strict blocker 集合，旧语义不得被 S4 改写。
- 每次成功 G3/G4 都写 fresh `updated_at`，包括 duplicate add、already-absent remove 与 same-status no-op；HTTP 仍为 empty `200`。这些 no-op 因 timestamp 是真实持久变更，仍走一次 post-commit best-effort notification，不得当成零写入。
- notification 只可在 Repo commit 返回后发；rollback 零通知。当前 PubSub 没有 outbox，计划只承诺每次 facade 调用构造去重后的 best-effort event set，不声称崩溃意义上的 exactly-once。
- G2 必须由单条 PostgreSQL aggregate statement 在一个 statement MVCC snapshot 内返回 group、members、direct managed-policy names 和 inline-policy omission evidence；禁止 `get_group + list_users + list_policies` 多阶段拼装，也禁止逐成员/逐策略 N+1。
- group policy wire 只显示 root-path direct managed policy names，按字典序逗号连接；inline policy 不进入 `GroupDesc.policy`，但必须进入安全 evidence、CLI 与结构化日志，绝不记录 policy document。
- G3 `groupStatus` 任意 JSON string 都按 pinned Go shape 接收；pinned mc add/rm 发送空串。MinIO 主本地成员 handler 不应用该字段，Maxio 也不得发明 400 或改变 local status；非空值需记录 `group_status_ignored: true` 的结构化 parity 证据，G4 才是唯一 group status writer。
- G3 bounded plaintext JSON 读取复用 `ControlBody`，固定 `@max_group_request_bytes 262_272`；超限硬失败为 `400 XMinioAdminConfigTooLarge`，不截断、不挂 `Plug.Parsers`、不使用 Envelope。不得把 upstream 对 body 的宽松读取改写成未经取证的 exact Content-Type/Content-Length gate。
- 仅 G4 `set-group-status` 的真实 mc request `Content-Length`、跨节点同名 group race 的动态行为、以及错误时 mc `fatalIf` 动态 stderr/exit 形状保留 `VERIFY-AT-IMPL`；在 fixture/live 取证前不得把推测写成 parity。G4 服务端不得读取 request body。
- 所有新日志至少含 `request_id`、`admin_action`、`required_action`、`target_group`、requested member count、changed member count、requested/actual status、ignored group status、decision 和 affected counts；不得记录 secret、policy document、完整 request body 或 credential material。
- 开发期只跑聚焦测试、`mix compile --warnings-as-errors` 与必要的 changed-file format。独立 review 全部关闭后只运行一次 final `mix precommit`；若 final gate 后代码变化，则旧结果失效，修复后只记录一次 replacement final precommit。
- 实现作者、protocol evidence reviewer、架构/竞态 reviewer、验证/live reviewer、STATUS reviewer必须是独立 lane；作者不得自审。
- strict live 因缺少 pinned native mc、隔离 PostgreSQL、server endpoint 或安全凭据可标记 `BLOCKED`，但必须给出精确 blocker；fake runner、源码推导和预期 transcript 不得冒充 live passed。

---

## Frozen Wire Contract

### G1: list groups

- `GET /minio/admin/v3/groups`，鉴权 action 为 `admin:ListGroups`。
- 无 request body；成功为 `200 application/json` 明文 JSON string array。服务端结果和 Maxio projection 均稳定字典序；空集编码 `[]`。
- pinned mc human 输出为每个 group name 一行，最后一行带 trailing LF；JSON 输出使用 `groupMessage` 的 `status="success"` 与 `groups` 字段并带单个 trailing LF。

### G2: group info

- `GET /minio/admin/v3/group?group=NAME`，鉴权 action 为 `admin:GetGroup`。
- 成功为 `200 application/json` 明文 `madmin.GroupDesc`：

```json
{
  "name": "g1",
  "status": "enabled",
  "members": ["alice", "bob"],
  "policy": "p-read,p-write",
  "updatedAt": "2026-08-29T00:00:00Z"
}
```

- `name` 来自 canonical local group；`active|inactive` 映射为 `enabled|disabled`；members 和 policy names 均稳定字典序；`policy` 只含 root-path direct managed policies，inline policy有意不进 wire。
- pinned mc human success 必须逐字为四行加 trailing LF：`Group: g1\nStatus: enabled\nPolicy: p-read,p-write\nMembers: alice,bob\n`。JSON 使用 `status/groupName/members/groupStatus/groupPolicy` 且只包含非空 `omitempty` 字段，最后单个 trailing LF；`updatedAt` 被 mc client 解码但不显示。

### G3: update group members

- `PUT /minio/admin/v3/update-group-members`，add 与 remove 都只鉴权 `admin:AddUserToGroup`；不得改用 `admin:RemoveUserFromGroup`。
- request 是 plaintext JSON `madmin.GroupAddRemove`：`group` string、`members` string array、`groupStatus` string、`isRemove` boolean。Go `encoding/json` 的 unknown-field/duplicate-key/zero-value行为由 pinned fixture锁定；Maxio 不额外发明 strict-key 拒绝。
- `isRemove=false`：group 不存在则以 enabled 状态创建并添加全部成员；已存在则添加成员。duplicate member 或已经存在的 membership 成功，fresh `updatedAt` 仍写入。
- `isRemove=true,members!=[]`：从既有 group 移除请求成员；已经不在组中的成员按 pinned no-op 成功，fresh `updatedAt` 仍写入。missing group/user、temp user、root user的精确错误按下方优先级。
- `isRemove=true,members=[]`：请求删除 group。只有 membership 非空才返回 `400 XMinioAdminGroupNotEmpty`；空组删除时原子清理 group row、inline mapping 与 managed attachment，policy definitions 保留。
- `groupStatus` 不改变本地 status；空串是 pinned mc 正常值，非空任意 string 同样被 handler接受但只具有 upstream replication payload证据。Maxio 无 site-replication group payload，因此保持 local no-op并记结构化 parity 日志。
- 成功一律 empty `200`，无成功 JSON body。pinned mc human add：``Added members `alice,bob` to group `g1` successfully.\n``；remove members：`Removed members {alice,bob} from group g1 successfully.\n`；remove group：`Removed group g1 successfully.\n`。
- JSON add/remove 使用 `status="success"`、`groupName`、非空时的 `members`，最后单个 trailing LF；remove-empty 省略 members。

### G4: set group status

- `PUT /minio/admin/v3/set-group-status?group=NAME&status=enabled|disabled`，enable 与 disable 都只鉴权 `admin:EnableGroup`；不得改用 `admin:DisableGroup`。
- 无语义 request body，服务端不得读取 body；成功 empty `200`。status 值在调用 group lookup/setter 前校验，因此 invalid status 压过 missing group。
- enabled/disabled 分别写 `active/inactive`；same-status 仍 fresh `updatedAt`、post-commit notification和 empty `200`。
- pinned mc human：``Enabled group `g1` successfully.\n`` / ``Disabled group `g1` successfully.\n``。JSON 使用 `status/groupName/groupStatus`，最后单个 trailing LF。
- pinned mc 的实际 `Content-Length` header仍为 `VERIFY-AT-IMPL`；Maxio 不基于未经取证的 header 值增加 transport gate。

### Frozen validation and error precedence

1. 所有 endpoint 都是认证优先；anonymous 返回 Admin JSON 403，不泄露 route support。
2. 每条 exact route先完成其单一 admin action授权；deny压过参数、body和 target错误，且 denied G3 body必须完全未读。
3. G3 授权后：bounded body read错误 → JSON unmarshal/type错误 → 按 request member顺序执行 temp-user检查与root-user检查 → 分支语义。
4. G3 add 分支：成员限制 → existing/missing group判断 → 仅 missing group的首尾空格检查 → user existence/canonical generation → atomic create-or-add。existing group不重新套用“新组首尾空格”规则。
5. G3 remove-members：成员限制 → group existence → user existence/generation → atomic remove。任一 target错误压过 no-op，整个批次零写。
6. G3 delete-empty：合法 JSON/成员限制（空列表） → group existence → membership blocker；只有非空 membership返回 `XMinioAdminGroupNotEmpty`，policy mapping不是 blocker。
7. G4：授权 → status enum → group existence/generation → same-status或change成功。invalid status对missing group固定返回 invalid argument。
8. exact route缺必需 query参数在Maxio中授权后映射 `400 XMinioAdminInvalidArgument`；wrong method、v4和不相关Admin path继续 authenticated 501。
9. `XMinioAdminNoSuchGroup`、`XMinioAdminNoSuchUser`、`XMinioAdminGroupNotEmpty`、`XMinioInvalidResource`、`XMinioAdminInvalidArgument` 的 code/status/message必须来自 pinned fixture。动态 `fatalIf` stderr只在 strict live验证，未验证前不硬编码成 observed evidence。

## Public Interfaces to Add

```elixir
# lib/maxio/admin/group_request.ex
@spec read_update_body!(Plug.Conn.t()) ::
        {Plug.Conn.t(), %{
          group: String.t(),
          members: [String.t()],
          group_status: String.t(),
          remove?: boolean()
        }}

# lib/maxio/admin/group_adapter.ex
@spec list() :: {:ok, %{wire: [String.t()], evidence: map()}} | {:error, term()}
@spec info(term()) :: {:ok, %{wire: map(), evidence: map()}} | {:error, term()}
@spec update_members(map()) :: {:ok, map()} | {:error, term()}
@spec status(term(), term()) :: {:ok, map()} | {:error, term()}

# lib/maxio/iam.ex public facade
@spec list_minio_group_names() :: {:ok, [String.t()]} | {:error, term()}
@spec get_minio_group_description_strict(String.t()) :: {:ok, map()} | {:error, term()}
@spec update_minio_group_members_strict(
        String.t(),
        [String.t()],
        boolean(),
        String.t()
      ) :: {:ok, map()} | {:error, term()}
@spec update_minio_group_status_strict(String.t(), "active" | "inactive") ::
        {:ok, map()} | {:error, term()}

# lib/maxio/iam/admin_group_lifecycle.ex internal coordinator
@spec update_members(String.t(), [String.t()], boolean(), String.t()) ::
        {:ok, %{
          group: map() | nil,
          operation: :create_or_add | :remove_members | :delete_empty,
          changed_member_arns: [String.t()],
          affected_member_arns: [String.t()],
          affected: map(),
          updated_at: DateTime.t(),
          group_status_ignored?: boolean()
        }}
        | {:error, term()}

@spec set_status(String.t(), "active" | "inactive") ::
        {:ok, %{group: map(), affected_member_arns: [String.t()], updated_at: DateTime.t()}}
        | {:error, term()}

@spec describe(String.t()) ::
        {:ok, %{
          group_name: String.t(),
          status: "active" | "inactive",
          member_names: [String.t()],
          managed_policy_names: [String.t()],
          inline_policy_names: [String.t()],
          updated_at: DateTime.t()
        }}
        | {:error, term()}
```

`update_minio_group_members_strict/4` 的第四参数保留原始 wire `groupStatus` 仅用于 evidence；它不得调用 status setter。既有 singular facade使用同一 coordinator但适配回原返回类型，不能把 S4 rich result泄露给旧调用者。

## Ownership and Review Lanes

- **Lane A — protocol fixture reviewer（read-only）：** 在任何 production code前逐项核对三仓 pinned SHA、route/action/body、错误顺序、mc success human/JSON/trailing LF，并明确三项 `VERIFY-AT-IMPL`。
- **Lane B — implementation author：** 严格 RED→GREEN，拥有实现和修复 commit；不签发独立 approval，不运行最终 live verdict。
- **Lane C — architecture/concurrency reviewer（read-only）：** 审核 Admin→Adapter→IAM边界、单事务、共享锁序、generation safety、delete-empty、通知和G2 snapshot。
- **Lane D — protocol/client reviewer（read-only）：** 审核 exact endpoint、错误矩阵、mc human/JSON fake-runner与真实 live差异，防止预期输出冒充实测。
- **Lane E — verification/live reviewer（read-only，除 ignored artifacts）：** 汇总 focused gates、运行唯一 final precommit和 strict live；不修代码。
- **Lane F — STATUS reviewer（read-only）：** 只在代码/live事实冻结后审核 STATUS措辞。

## Task 1: Freeze pinned protocol and mc rendering fixtures

**Files:**

- Create: `test/fixtures/minio_admin_group_s4/README.md`
- Create: `test/fixtures/minio_admin_group_s4/minio_routes_and_errors.json`
- Create: `test/fixtures/minio_admin_group_s4/madmin_group_wire.json`
- Create: `test/fixtures/minio_admin_group_s4/mc_group_human.json`
- Create: `test/fixtures/minio_admin_group_s4/mc_group_json.json`
- Create: `test/maxio/admin/group_protocol_fixture_test.exs`

**Interfaces:**

- Consumes: the three full pinned SHAs in Global Constraints.
- Produces: immutable fixture ids and exact bytes consumed by every later request/endpoint/CLI/smoke test.

- [ ] **Step 1: Record pinned MinIO evidence.** Read `cmd/admin-router.go`, `cmd/admin-handlers-users.go`, the IAM group store implementation reached by `AddUsersToGroup/RemoveUsersFromGroup/SetGroupStatus/GetGroupDescription/ListGroups`, and exact admin error table entries. Record method/path/query route requirements, action constants, body read/unmarshal order, member restriction order, create-or-add/remove/delete-empty behavior, membership-only delete blocker, policy mapping cleanup, fresh updatedAt on no-op, and empty 200.
- [ ] **Step 2: Record pinned madmin wire evidence.** From `group-commands.go`, capture `GroupAddRemove` JSON keys/types, `GroupDesc`, `GroupStatus`, relative paths, methods and response decode rules. Include one exact add, member-remove, group-delete, info, list, enable and disable request/response sample.
- [ ] **Step 3: Record pinned mc success rendering.** From the six `cmd/admin-group-*.go` files and shared `printMsg`, save exact argv, human bytes, JSON bytes, field omission/order and exactly one trailing LF. The add fixture must prove mc sends `groupStatus:""`; a nonempty `groupStatus` fixture must prove server acceptance without local status mutation.
- [ ] **Step 4: Register only the three live verification boundaries.** Fixture README labels `set_status_actual_content_length`, `cross_node_group_race`, and `dynamic_mc_fatal_output` as `VERIFY-AT-IMPL`, each with capture command and the rule “no observed claim until live evidence exists.” No other frozen behavior may be weakened to VERIFY.
- [ ] **Step 5: Write fixture RED tests.** Tests load all JSON files and assert full SHAs, exact route/action matrix, error precedence list, `groupStatus` parity, no-op timestamp rule, cleanup semantics, human/JSON strings and trailing LF. Expected initial failure is absent fixture data or production GroupRequest, never malformed fixture JSON.
- [ ] **Step 6: Lane A reviews fixtures.** The reviewer compares every frozen value to pinned source, confirms there is no floating URL and signs off the three—and only three—VERIFY boundaries.
- [ ] **Step 7: Commit protocol evidence.** Run `git add test/fixtures/minio_admin_group_s4 test/maxio/admin/group_protocol_fixture_test.exs && git commit -m "test(admin): pin group lifecycle protocol"`.

## Task 2: Add bounded plaintext GroupRequest parsing

**Files:**

- Create: `lib/maxio/admin/group_request.ex`
- Create: `test/maxio/admin/group_request_test.exs`
- Modify: `test/maxio/admin/group_protocol_fixture_test.exs`

**Interfaces:**

- Consumes: exact G3 JSON behavior from Task 1.
- Produces: `GroupRequest.read_update_body!/1` returning normalized field names without applying IAM semantics.

- [ ] **Step 1: Write transport/body RED tests.** Cover multi-chunk bounded plaintext read, empty/truncated/oversize body, invalid UTF-8/JSON, wrong field types, missing fields using pinned Go zero values, unknown fields, duplicate keys and exact `members` ordering/duplicates. Assert no Envelope or signing secret is touched.
- [ ] **Step 2: Write authorization-order probe support.** Reuse the existing body read probe adapter so later endpoint tests can assert a denied G3 request consumes zero body bytes; do not add sleeps.
- [ ] **Step 3: Run RED.** Run `mix test test/maxio/admin/group_request_test.exs test/maxio/admin/group_protocol_fixture_test.exs`; expected failure is undefined `Maxio.Admin.GroupRequest`.
- [ ] **Step 4: Implement minimal parser.** Use `ControlBody.read!` with `@max_group_request_bytes 262_272` and `:admin_config_too_large`, decode with Jason behavior matching the pinned Go fixture, validate only the frozen JSON types, and return `%{group:, members:, group_status:, remove?:}`. Preserve request member order for validation/error precedence; dedupe happens only inside IAM after validation.
- [ ] **Step 5: Run GREEN and format.** Run the Task 2 tests and `mix format --check-formatted lib/maxio/admin/group_request.ex test/maxio/admin/group_request_test.exs`.
- [ ] **Step 6: Commit request boundary.** Run `git add lib/maxio/admin/group_request.ex test/maxio/admin/group_request_test.exs test/maxio/admin/group_protocol_fixture_test.exs && git commit -m "feat(admin): parse group lifecycle requests"`.

## Task 3: Implement atomic AdminGroupLifecycle mutations

**Files:**

- Create: `lib/maxio/iam/admin_group_lifecycle.ex`
- Modify: `lib/maxio/iam.ex`
- Create: `test/maxio/iam/admin_group_lifecycle_test.exs`
- Create: `test/maxio/iam/admin_group_lifecycle_concurrency_test.exs`
- Create: `test/support/iam_identity_barrier.ex`

**Interfaces:**

- Consumes: existing `GroupIdentity`, `UserIdentity`, Group/GroupMembership schemas, inline and managed attachment rows.
- Produces: `Maxio.IAM.update_minio_group_members_strict/4` and `update_minio_group_status_strict/2` with the result maps declared above.

- [ ] **Step 1: Write core semantic RED tests.** Cover add creating enabled group, add to existing disabled group without changing status, multiple members, duplicate request members, already-attached no-op with fresh updatedAt, remove subset, already-absent remove with fresh updatedAt, delete empty, reject nonempty, and nonempty `groupStatus` accepted/logged but ignored.
- [ ] **Step 2: Write atomic failure RED tests.** A batch containing one missing user, temp/root-forbidden member, invalid canonical identity or forced membership insert error must leave group, all memberships, policies and timestamp unchanged. Assert the frozen error precedence and no partial group creation.
- [ ] **Step 3: Write delete cleanup RED tests.** Seed an empty group with inline policy and root/non-root managed attachments. Assert membership alone blocks delete; once empty, group row, inline mapping and all group attachments are removed in one transaction while managed policy definitions and unrelated groups/users remain.
- [ ] **Step 4: Write no-op timestamp RED tests.** Freeze DB time or compare monotonic persisted timestamps without sleeping; prove duplicate add, absent-member remove and same-status update persist a fresh `updated_at` and return that exact instant.
- [ ] **Step 5: Write deterministic generation RED tests.** Use monitored tasks plus telemetry/barrier handshakes to pause after snapshots, then exercise group delete/recreate, group rename, user delete/recreate and user rename. Assert the old request returns typed not-found/identity-changed and never mutates the replacement UUID. Do not use `Process.sleep/1` or `Process.alive?/1`.
- [ ] **Step 6: Write lock-order/deadlock RED tests.** Start reversed user-order batches and concurrent group status/delete operations; assert both finish under a bounded monitor protocol and final state is one valid serial outcome. Barrier events must expose `GroupIdentity` acquisition before case-fold sorted `UserIdentity` acquisition and before membership mutation.
- [ ] **Step 7: Run RED.** Run `mix test test/maxio/iam/admin_group_lifecycle_test.exs test/maxio/iam/admin_group_lifecycle_concurrency_test.exs`; expected failures are missing facade/module and unsafe current singular behavior.
- [ ] **Step 8: Implement transaction coordinator.** Capture UUID snapshots before the transaction; acquire group generation first, user generations in case-folded stable order, then derive canonical ARNs and perform set-based insert/delete. Use one transaction for group create/member diff/status timestamp/delete cleanup; never call public singular functions in a loop.
- [ ] **Step 9: Implement status mutation.** Validate only `active|inactive`, lock group generation, collect current member ARNs for invalidation, force a fresh row timestamp even for same status, and return typed missing-group errors.
- [ ] **Step 10: Run focused GREEN.** Run both Task 3 suites, then `mix compile --warnings-as-errors`.
- [ ] **Step 11: Commit atomic lifecycle.** Run `git add lib/maxio/iam/admin_group_lifecycle.ex lib/maxio/iam.ex test/maxio/iam test/support/iam_identity_barrier.ex && git commit -m "feat(iam): add atomic admin group lifecycle"`.

## Task 4: Route existing singular writers through the shared lock protocol

**Files:**

- Modify: `lib/maxio/iam.ex`
- Modify: `test/maxio/iam_test.exs`
- Modify: `test/maxio/iam/query_api_test.exs`
- Modify: `test/maxio_web/live/group_live_test.exs`
- Modify: `test/mix/tasks/maxio_iam_user_group_test.exs`
- Modify: `test/maxio/iam/admin_group_lifecycle_concurrency_test.exs`

**Interfaces:**

- Consumes: Task 3 coordinator internal single-member operations.
- Produces: generation-safe legacy idempotent/strict facades without changing their public return contracts.

- [ ] **Step 1: Write delegation RED tests.** For each of `add_user_to_group/2`, `add_user_to_group_strict/2`, `remove_user_from_group/2`, and `remove_user_from_group_strict/2`, reproduce delete/recreate barriers and assert the shared GroupIdentity→UserIdentity order is observed.
- [ ] **Step 2: Lock legacy semantics.** Existing idempotent add/remove still return success on duplicate/absent membership; strict variants still return not-found for missing target/non-membership. Their notifications may now be deduplicated/post-commit, but external return types remain unchanged.
- [ ] **Step 3: Preserve IAM Query strict delete.** Seed membership, inline policy and managed attachment independently and assert Query `DeleteGroup` returns `DeleteConflict` for each exactly as before. S4 delete-empty must not be wired into Query Plug.
- [ ] **Step 4: Preserve Console and Mix task behavior.** Run create/select/add/remove/delete LiveView outcomes through public IAM and assert existing DOM ids/flash behavior. Existing operator `mix maxio.iam.delete_group` keeps cascading semantics; the new Admin CLI uses MinIO delete-empty instead.
- [ ] **Step 5: Implement delegation.** Replace direct singular membership Repo writes with coordinator calls/adapters; do not duplicate locks or create a second membership mutation path.
- [ ] **Step 6: Run focused GREEN.** Run `mix test test/maxio/iam_test.exs test/maxio/iam/query_api_test.exs test/maxio_web/live/group_live_test.exs test/mix/tasks/maxio_iam_user_group_test.exs test/maxio/iam/admin_group_lifecycle_concurrency_test.exs`.
- [ ] **Step 7: Commit shared writer convergence.** Run `git add lib/maxio/iam.ex test/maxio/iam_test.exs test/maxio/iam/query_api_test.exs test/maxio_web/live/group_live_test.exs test/mix/tasks/maxio_iam_user_group_test.exs test/maxio/iam/admin_group_lifecycle_concurrency_test.exs && git commit -m "fix(iam): share group membership locks"`.

## Task 5: Add the single-statement GroupDesc projection

**Files:**

- Modify: `lib/maxio/iam/admin_group_lifecycle.ex`
- Modify: `lib/maxio/iam.ex`
- Create: `test/maxio/iam/admin_group_projection_test.exs`
- Modify: `test/maxio/iam/admin_group_lifecycle_concurrency_test.exs`

**Interfaces:**

- Consumes: existing group, membership, user, inline policy, group managed attachment and managed policy tables.
- Produces: `list_minio_group_names/0` and `get_minio_group_description_strict/1` with stable typed projection.

- [ ] **Step 1: Write projection RED tests.** Assert group status/timestamp, canonical member names, only root-path direct managed policy names, explicit omission evidence for inline and non-root-path policies, empty arrays, and stable bytewise lexical ordering independent of insertion order.
- [ ] **Step 2: Write missing/race RED tests.** Missing group returns the group error domain, not policy/user not-found. Rename/delete between an initial caller lookup and statement execution must return one canonical generation or missing, never a mixed name/ARN projection.
- [ ] **Step 3: Write single-statement snapshot RED test.** Instrument Repo query telemetry and assert G2 projection executes exactly one aggregate SQL statement. Use a deterministic phase-drift barrier/mutation from another sandbox connection to prove response is entirely before or after membership/policy change; no mixed members/policies/status is allowed.
- [ ] **Step 4: Write G1 query-count RED test.** List names in one query, sorted and including active/inactive groups; no per-group description/policy query.
- [ ] **Step 5: Implement aggregate SQL.** Use one parameterized PostgreSQL statement with CTE/JSON aggregates for group, sorted member names, sorted root-path managed-policy names and safe inline/non-root counts/names. Normalize SQL `NULL` aggregates to empty lists inside IAM, not in Plug.
- [ ] **Step 6: Run focused GREEN.** Run `mix test test/maxio/iam/admin_group_projection_test.exs test/maxio/iam/admin_group_lifecycle_concurrency_test.exs` and `mix compile --warnings-as-errors`.
- [ ] **Step 7: Commit consistent projection.** Run `git add lib/maxio/iam/admin_group_lifecycle.ex lib/maxio/iam.ex test/maxio/iam/admin_group_projection_test.exs test/maxio/iam/admin_group_lifecycle_concurrency_test.exs && git commit -m "feat(iam): project admin group snapshot"`.

## Task 6: Add GroupAdapter wire projection

**Files:**

- Create: `lib/maxio/admin/group_adapter.ex`
- Create: `test/maxio/admin/group_adapter_test.exs`

**Interfaces:**

- Consumes: four public IAM facade functions from Tasks 3 and 5.
- Produces: exact G1/G2 wire maps and G3/G4 adapter results consumed by Plug and local CLI.

- [ ] **Step 1: Write name/status RED tests.** Lock missing/empty names, new-group leading/trailing spaces, existing-group compatibility, `enabled|disabled ↔ active|inactive`, invalid status, comma/UTF-8 behavior and the exact protocol precedence. Read and mutation validation must not silently hide IAM groups from G1.
- [ ] **Step 2: Write G1/G2 wire RED tests.** Compare list/info maps to Task 1 fixtures, including status, `updatedAt`, members, comma-joined managed policies, empty policy string and stable ordering. Assert inline/non-root policies appear only in evidence.
- [ ] **Step 3: Write G3/G4 adapter RED tests.** Assert GroupRequest fields are passed once to the IAM batch facade, raw `groupStatus` is preserved only as evidence, G4 maps status exactly, and every IAM typed error reaches ErrorMap unchanged.
- [ ] **Step 4: Add a boundary test.** Static/source assertion or injected facade proves `GroupAdapter` references `Maxio.IAM` only and does not alias Repo/schema/Policy.Store/AdminGroupLifecycle directly.
- [ ] **Step 5: Run RED.** Run `mix test test/maxio/admin/group_adapter_test.exs`; expected failure is undefined adapter.
- [ ] **Step 6: Implement minimal adapter.** Keep wire keys/status/timestamp formatting here; keep transactions, SQL and notifications in IAM. Construct evidence counts/names without policy documents or secrets.
- [ ] **Step 7: Run GREEN and commit.** Run the focused suite, then `git add lib/maxio/admin/group_adapter.ex test/maxio/admin/group_adapter_test.exs && git commit -m "feat(admin): adapt group lifecycle"`.

## Task 7: Wire four Admin routes, auth, errors, logs and notifications

**Files:**

- Modify: `lib/maxio/admin/plug.ex`
- Modify: `lib/maxio/admin/error_map.ex`
- Modify: `lib/maxio/s3/error.ex`
- Modify: `config/config.exs`
- Create: `test/maxio/admin/group_endpoint_test.exs`
- Modify: `test/maxio/admin/authz_test.exs`
- Modify: `test/maxio/admin/error_map_test.exs`
- Modify: `test/maxio/admin/plug_test.exs`
- Modify: `test/support/blocking_notify_transport.ex`

**Interfaces:**

- Consumes: GroupRequest/GroupAdapter and the frozen route/action/error fixtures.
- Produces: authenticated exact G1-G4 HTTP surface and post-commit best-effort invalidation evidence.

- [ ] **Step 1: Write dispatch/shape RED tests.** Exact four methods/paths leave 501; wrong method, v4, malformed adjacent path and unrelated route remain 501. Missing `group`/`status` maps to authorized 400. All success content-types/bodies match fixture: G1/G2 plaintext JSON and G3/G4 empty 200.
- [ ] **Step 2: Write auth matrix RED tests.** Per endpoint cover root, exact identity-policy action, wrong action, explicit Deny, STS session boundary, bucket-policy-only attempted grant and anonymous. Assert G3 remove uses AddUserToGroup and G4 disable uses EnableGroup.
- [ ] **Step 3: Prove auth-before-body.** Denied G3 with a probe body returns 403 and reads zero bytes; authorized malformed G3 reads then returns the pinned structured error.
- [ ] **Step 4: Write frozen error matrix RED tests.** Cover malformed JSON, temp/root member, missing user/group, new group surrounding spaces, nonempty delete, invalid status+missing group precedence, delete cleanup failure and internal redaction. Add exact `admin_group_not_empty` code/status/message to `S3.Error` and typed mappings to ErrorMap.
- [ ] **Step 5: Write notification RED tests.** With blocking transport, prove DB commit and fresh timestamp are visible before the first broadcast. Assert rollback emits none; duplicate/no-op success emits one deduplicated logical event set after commit; member changes notify actual affected users and group metadata; status/delete invalidates current/former member principals. Transport failure is logged as best-effort failure and does not pretend the committed DB transaction rolled back.
- [ ] **Step 6: Implement exact routes.** Add four dispatch clauses and thin handlers using `authorize_and_run`. Only G3 calls GroupRequest; G4 ignores body. Log counts/status and nonempty ignored G3 groupStatus without request body values beyond the safe status string.
- [ ] **Step 7: Update formatter allowlist.** Add only safe group lifecycle metadata keys such as `target_group`, requested/changed member counts, affected member count, requested/actual group status, `group_status_ignored`, cleanup counts and notification failure count.
- [ ] **Step 8: Run focused GREEN.** Run `mix test test/maxio/admin/group_endpoint_test.exs test/maxio/admin/authz_test.exs test/maxio/admin/error_map_test.exs test/maxio/admin/plug_test.exs test/maxio/iam/admin_group_lifecycle_test.exs`.
- [ ] **Step 9: Commit HTTP surface.** Run `git add lib/maxio/admin/plug.ex lib/maxio/admin/error_map.ex lib/maxio/s3/error.ex config/config.exs test/maxio/admin test/support/blocking_notify_transport.ex && git commit -m "feat(admin): expose group lifecycle"`.

## Task 8: Prove group status changes real S3 authorization

**Files:**

- Modify: `test/maxio/s3/identity_policy_authz_test.exs`
- Modify: `test/maxio/policy/store_test.exs`
- Modify: `test/maxio/admin/group_endpoint_test.exs`

**Interfaces:**

- Consumes: G3 membership and G4 status endpoints plus existing group inherited inline/managed policy evaluator.
- Produces: data-plane correctness proof used by external smoke and STATUS.

- [ ] **Step 1: Write managed-policy data-plane RED test.** Create a credential-bearing user with no direct ListBuckets grant, create group through G3, attach a root-path managed policy to group through the existing Admin Policy surface, and prove S3 ListBuckets changes deny→allow.
- [ ] **Step 2: Write status lifecycle RED test.** Through signed G4 disable then enable, prove allow→403→allow for the same user credential; verify G2 status/timestamp after each step.
- [ ] **Step 3: Write remove/delete RED test.** Remove membership through G3 and prove immediate deny; detach/clean policy mapping, delete empty group, and prove policy definition and user remain.
- [ ] **Step 4: Write inline/non-root projection boundary test.** Both policy classes can affect or exist in IAM according to current semantics but do not leak into G2 `policy`; safe evidence reports the deliberate partial view.
- [ ] **Step 5: Run focused GREEN and commit.** Run `mix test test/maxio/s3/identity_policy_authz_test.exs test/maxio/policy/store_test.exs test/maxio/admin/group_endpoint_test.exs`, then commit with `git add ... && git commit -m "test(admin): prove group authorization lifecycle"`.

## Task 9: Add first-party group CLI observability

**Files:**

- Create: `lib/mix/tasks/maxio.admin.group.list.ex`
- Create: `lib/mix/tasks/maxio.admin.group.show.ex`
- Create: `lib/mix/tasks/maxio.admin.group.update.ex`
- Create: `lib/mix/tasks/maxio.admin.group.status.ex`
- Create: `test/mix/tasks/maxio_admin_group_test.exs`

**Interfaces:**

- Consumes: GroupAdapter/public IAM facade; no HTTP, Repo or concrete store access.
- Produces: local human/`--json` recomputation for G1-G4 plus full safe omission evidence.

- [ ] **Step 1: Write CLI RED tests.** Lock exact argv, required group/member/status options, repeated members, add/remove/delete-empty modes, strict unknown-switch rejection, stable human output and one JSON object. Show command must print wire view plus inline/non-root omissions and counts without documents.
- [ ] **Step 2: Write no-op/error RED tests.** Duplicate add/absent remove/same status succeed and expose fresh timestamp; missing targets and nonempty delete fail with safe public messages and nonzero task error.
- [ ] **Step 3: Implement tasks through public boundaries.** Boot with `Maxio.Config.CLI`, call GroupAdapter or public IAM exactly once per operation, preserve member ordering only where evidence requires it, and never expose credentials or policy documents.
- [ ] **Step 4: Run focused GREEN.** Run `mix test test/mix/tasks/maxio_admin_group_test.exs` and changed-file format.
- [ ] **Step 5: Commit CLI.** Run `git add lib/mix/tasks/maxio.admin.group.*.ex test/mix/tasks/maxio_admin_group_test.exs && git commit -m "feat(cli): inspect admin groups"`.

## Task 10: Extend independent human and JSON external smoke

**Files:**

- Modify: `lib/maxio/compat/admin_user_fixture.ex`
- Modify: `lib/maxio/compat/external_smoke.ex`
- Modify: `test/maxio/compat/admin_user_fixture_test.exs`
- Modify: `test/maxio/compat/external_smoke_test.exs`
- Modify: `test/fixtures/minio_admin_group_s4/mc_group_human.json`
- Modify: `test/fixtures/minio_admin_group_s4/mc_group_json.json`
- Modify: `README.md`

**Interfaces:**

- Consumes: exact pinned mc fixtures and existing secret-safe temporary user/policy smoke capabilities.
- Produces: independent human/JSON group lifecycle evidence with creator-aware cleanup and data-plane transitions.

- [ ] **Step 1: Write human-plan RED test.** Fake runner must see exact ordered commands: create policy, create unprivileged temporary user fixture, baseline S3 deny, `group add`, policy attach to group, `group ls`, `group info`, S3 allow, `group disable`, S3 deny, `group enable`, S3 allow, remove member, S3 deny, detach mapping if still present, remove empty group, remove policy/user. Assert every exact success line and trailing LF from fixture.
- [ ] **Step 2: Write JSON-plan RED test.** Use a distinct alias/user/group/policy namespace and `--json` in the pinned global position. Assert exact JSON bytes/fields/omissions/trailing LF for add/list/info/disable/enable/remove-member/remove-group; human output is forbidden in JSON mode.
- [ ] **Step 3: Write failure/cleanup RED tests.** Inject failure after each creator. Cleanup runs only for resources whose creator succeeded, in dependency order: detach policy mapping → remove members → delete group → delete user/policy. Retry ids are deduplicated and cleanup failure never hides the primary blocker.
- [ ] **Step 4: Implement orchestration.** Keep secrets in environment/closure capabilities, retain existing artifact redaction, record commands/exit/duration/assertion, and compute scenario counts from actual steps. Human and JSON modes may share pure builders but never live state.
- [ ] **Step 5: Document supported scope.** README lists the four exact endpoints/actions, plaintext/empty responses, atomic create-or-add/remove/delete-empty behavior, G3 ignored groupStatus parity, G4 real authorization effect, single-statement info snapshot, delete cleanup and remaining 501 routes. Expected transcripts are labelled fixtures, not live evidence.
- [ ] **Step 6: Run focused GREEN.** Run `mix test test/maxio/compat/admin_user_fixture_test.exs test/maxio/compat/external_smoke_test.exs`.
- [ ] **Step 7: Commit smoke/docs.** Run `git add lib/maxio/compat test/maxio/compat test/fixtures/minio_admin_group_s4 README.md && git commit -m "test(compat): exercise admin group lifecycle"`.

## Task 11: Coherent-batch focused verification and independent reviews

**Files:** all code/test/README files changed in Tasks 1-10; no STATUS edit yet.

- [ ] **Step 1: Lane B runs author checks.** Run every focused command above together, changed-file `mix format --check-formatted`, `mix compile --warnings-as-errors`, and `git diff --check a83a92b..HEAD`. Fix failures test-first in the owning component and commit coherent fixes; do not run precommit.
- [ ] **Step 2: Lane C performs read-only architecture review.** Audit `a83a92b..HEAD` for Admin→Adapter→IAM boundary, no singular loop, GroupIdentity→stable UserIdentity→membership order, generation barriers, create rollback, membership-only delete blocker plus policy mapping cleanup, shared singular writer delegation, Query strict delete regression, timestamped no-op, post-commit best-effort notifications, G2 one-statement snapshot and secret-free logs.
- [ ] **Step 3: Lane D performs read-only protocol/client review.** Audit exact four routes/actions, plaintext/empty response shape, G3 arbitrary string groupStatus accepted/ignored, frozen error precedence, exact mc human/JSON/trailing LF, and the three VERIFY boundaries. Any invented 400 for groupStatus or unverified fatal/Content-Length claim is an Important blocker.
- [ ] **Step 4: Lane B fixes accepted findings.** Add a failing regression first, make the architecture-consistent correction, rerun its focused suite and commit. Lanes C/D re-review the amended diff until no Critical/Important remains.
- [ ] **Step 5: Lane E runs the combined focused matrix.** Run all new Admin Group/IAM concurrency/projection/S3/CLI/smoke suites plus affected existing IAM Query/Console/Admin Policy/User suites, compile, changed-file format and diff-check. Record exact command, exit and count for STATUS.
- [ ] **Step 6: Run exactly one final precommit.** Only after independent approvals and all fixes, Lane E runs `mix precommit` once. If later code changes, discard that evidence, run focused tests for the change, then run one replacement final precommit and record only the replacement.
- [ ] **Step 7: Confirm pre-live clean state.** No generated artifact or credential is committed; `git status --short` is empty.

## Task 12: Strict pinned mc live evidence and VERIFY closures

**Files:** no tracked source changes; ignored artifact directory only, followed later by STATUS facts.

- [ ] **Step 1: Pin runtime identities.** Record native `mc --version`/binary hash correlation to `77f82e1`, Maxio HEAD, endpoint, isolated database identity and redacted alias config. A different mc is exploratory only.
- [ ] **Step 2: Run independent human lifecycle.** Execute Task 10 human flow against live Maxio and compare stdout bytes including trailing LF; prove S3 deny→allow→deny→allow→deny around group attach/status/member removal and complete cleanup.
- [ ] **Step 3: Run independent JSON lifecycle.** Use a distinct group/user/policy and assert each JSON document exactly; do not infer JSON pass from human pass or reuse its state.
- [ ] **Step 4: Close `set_status_actual_content_length`.** Capture signed request headers from the pinned mc path and record actual Content-Length without changing server behavior merely to match a speculative value.
- [ ] **Step 5: Probe `cross_node_group_race`.** If two safe live nodes sharing the isolated DB are available, race same-name create/add/remove and record observed client/error/final state; automated generation tests remain the correctness gate. If not available, leave only this probe BLOCKED without weakening the implemented transaction guarantee.
- [ ] **Step 6: Close `dynamic_mc_fatal_output`.** Trigger safe missing-group, missing-user, invalid-status and group-not-empty failures; record real stderr/exit and compare with Admin JSON errors. Do not hardcode localization/trace text into normal success fixtures unless observed stable at pinned mc.
- [ ] **Step 7: Classify unavailable infrastructure honestly.** Missing pinned mc, isolated PostgreSQL, two-node setup, endpoint or credentials yields exact per-probe BLOCKED entries. A process exit 0 with zero live steps is not a business pass.

## Task 13: STATUS-only closeout commit

**Files:**

- Modify only: `docs/superpowers/STATUS.md`

- [ ] **Step 1: Write factual closeout.** Record exact G1-G4 support/actions/wire, atomic lifecycle and lock order, G3 groupStatus parity, timestamped no-op, delete cleanup versus preserved Query strict delete, G2 single SQL snapshot, notification contract, focused/final precommit evidence, review verdicts, strict human/JSON live PASS or exact BLOCKED reasons, and outcome of each of the three VERIFY probes.
- [ ] **Step 2: Record remaining scope.** Keep v4, service accounts, external IdP groups, Console status UI and other unsupported Admin routes explicit; do not claim complete MinIO Admin parity or production readiness.
- [ ] **Step 3: Lane F reviews STATUS.** Compare each “implemented/passed” statement with commit/test/live artifacts. Expected mc fixture text must never be described as observed live output.
- [ ] **Step 4: Commit only STATUS.** Verify `git status --short` lists only `docs/superpowers/STATUS.md`, then run `git add docs/superpowers/STATUS.md && git commit -m "docs(status): record admin group S4 evidence"`.
- [ ] **Step 5: Confirm clean branch.** `git status --short` is empty and `git diff --name-only a83a92b..HEAD` contains only planned implementation/test/docs paths.

## Task 14: Fast-forward integration and atomic push

- [ ] **Step 1: Verify ancestry and identities.** In the feature worktree record `git rev-parse HEAD`, `git status --short`, and `git merge-base --is-ancestor a83a92bd18652ef685d7bfee14970f99b5c0ac62 HEAD`; require clean state.
- [ ] **Step 2: Fast-forward a clean integration worktree.** Verify the main worktree has no user changes, then run `git merge --ff-only codex/admin-group-s4`. Never reset, force-checkout or merge over a dirty worktree.
- [ ] **Step 3: Push both refs atomically.** Run `git push --atomic origin refs/heads/master:refs/heads/master refs/heads/codex/admin-group-s4:refs/heads/codex/admin-group-s4`. If either ref is rejected, diagnose and retry atomically; do not fall back to partial pushes.
- [ ] **Step 4: Verify remote/local state.** Compare local HEAD with both remote refs, confirm both worktrees clean, and report final SHA, independent review verdicts, the one final precommit result and strict live PASS/BLOCKED classification.

## Explicit Non-Goals

- 不实现 Admin v4/426、service account、LDAP/OIDC/AD/external IdP group、跨账户或多账户 IAM。
- 不新增 migration、表、列、索引或 enum；现有 group/membership/policy attachment schema足以承载 S4。若实施发现 schema 不足，停止并回架构评审，不得临时扩表。
- 不实现 Console group status toggle、视觉改版、审批流或完整 Admin UI；只保留现有 Console通过共享 writer 的回归。
- 不改变 IAM Query `DeleteGroup` 的 strict blocker集合，也不改变 operator `delete_group/1` 的 cascading语义。
- 不把 G3 `groupStatus` 变成 status writer，不因非空值发明 400；只按 pinned upstream 接收/忽略并记录证据。
- 不在 Adapter/Plug 中循环 singular member APIs、拼事务、查 Repo、组装跨时点 GroupDesc或发送 notification。
- 不引入 durable outbox、跨节点 exactly-once notification或完整 IAM identity Store behaviour重构。
- 不把 inline/non-root managed policy塞进 `GroupDesc.policy`，不记录 policy document、secret、session token或 request body。
- 不把 fake-runner、fixture、源码推导或单节点并发测试冒充真实 native mc/跨节点 live证据。
