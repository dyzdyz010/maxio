# MinIO Admin Policy S1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (- [ ]) syntax for tracking.

**Goal:** 让真实 mc 完整跑通 MinIO admin v3 的本地 canned policy create/list/info/remove 闭环，同时把 admin 控制面请求从 S3 bucket=minio 指标与访问日志中隔离。

**Architecture:** Maxio.Admin.Plug 只保留精确路由、逐端点授权和 HTTP/JSON 响应；新的 Maxio.Admin.PolicyRequest 负责 AddCannedPolicy 的线协议读取，新的 Maxio.Admin.PolicyAdapter 只经 Maxio.IAM 门面完成本地 path=/ managed policy 转换，新的 Maxio.Admin.ErrorMap 将 IAM reason 映射为 admin JSON 错误。AddressStyle 之后增加一次 admin surface 分类，RequestMetrics 与 AccessLogDelivery 据此跳过控制面；不移动 SigV4，也不改变普通 S3 流量的既有观测顺序。

**Tech Stack:** Elixir/OTP、Phoenix Plug/Bandit、Jason、Ecto/Postgres、Maxio.IAM、ExUnit、自签 SigV4、MinIO mc。

**Spec:** docs/superpowers/specs/2026-08-20-minio-admin-user-policy-design.md

## Global Constraints

- 开始前完整阅读仓库 AGENTS.md、上述 spec、docs/superpowers/STATUS.md 和本计划；所有实现只在隔离 worktree C:\Users\DYZ\Documents\dev\hemifuture\maxio\.worktrees\admin-policy-s1 中进行。
- 本批只做 S1：AddCannedPolicy、ListCannedPolicies、InfoCannedPolicy、RemoveCannedPolicy。不得夹带 user/group、policy attach/detach/entities、service account、admin config、madmin envelope、Argon2id、SIO、内置 canned policy seed、迁移或新密码学。
- 四条唯一实现路由及 action 必须逐字为：

~~~text
PUT    /minio/admin/v3/add-canned-policy     admin:CreatePolicy
GET    /minio/admin/v3/list-canned-policies  admin:ListUserPolicies
GET    /minio/admin/v3/info-canned-policy    admin:GetPolicy
DELETE /minio/admin/v3/remove-canned-policy  admin:DeletePolicy
~~~

- 四条成功响应必须严格为 HTTP 200；create/remove 返回空 body，list/info 返回 JSON。不得以 201、204、XML 或重定向代替。
- AddCannedPolicy body 是 raw policy JSON；不得要求 Content-Type。请求必须有唯一、仅由 ASCII 0-9 组成且严格大于 0 的 Content-Length，解析前逐字匹配 ~r/\A[0-9]+\z/，且不得是 Transfer-Encoding: chunked；Content-Length 缺失、0、负数、+1、Unicode digit、首尾 whitespace、非法、重复或 chunked 都返回现有 MissingContentLength/411。
- AddCannedPolicy body 上限精确为 20,480 bytes：20,480 必须能被有限 reader 完整读出，20,481 必须在解析/持久化前返回 XMinioAdminInvalidArgument/400。声明长度与实际长度不符返回现有 IncompleteBody/400。
- PolicyInfo v2 只发四个大驼峰键：PolicyName、Policy、CreateDate、UpdateDate；Policy 必须是 JSON object，不能是 JSON 字符串。无 v 或 v="" 返回裸 policy object；v=2 返回 PolicyInfo；任何其它非空 v 返回 XMinioAdminInvalidArgument/400。
- 当前 mc 先请求 ?name=N&v=2；只有请求成功且 PolicyName=="" 才尝试无-v回退，错误不会回退。因此 v2 必须独立正确并返回非空 PolicyName，不能把 legacy 路由当成错误兜底。
- GET /minio/admin/v3/list-canned-policies?bucket=（只要 query key 存在，包括空值）是独立未实现路由，必须经过认证后返回 NotImplemented/501；不得忽略 bucket 后返回全局列表。
- name 缺失或空字符串返回 XMinioAdminInvalidArgument/400；首尾 Unicode whitespace、逗号、任何 / 或 \、以及任何 . 或 .. path segment 必须显式拒绝为 XMinioInvalidResource/400。其余名字仍交给 Maxio.IAM 公开的 validate_managed_policy_arn/1 校验和 root-target round-trip，禁止 String.to_atom/1。
- canned name N 只映射到 Maxio.IAM.managed_policy_arn(N, "/")。create/info/remove 必须先经同一个 root_policy_target/1：公开 IAM validator 接受 ARN 后，还要验证 ARN 逐字等于 "arn:aws:iam:::policy/" <> N，保证 IAM 的 ARN parser 不会把 N 解释成 path != "/"；任何失败均在读写前拒绝。list 必须在 list_managed_policies(path_prefix: "/") 后再次严格过滤 path == "/"；不得让 /team/ops 通过 name="team/ops" 被 create/info/remove 命中。
- 同名 create 不覆盖或重置历史：已存在时调用 create_managed_policy_version_strict(arn, document, true)。版本达到 5 时实际 reason :policy_version_limit_exceeded 返回可行动 400，绝不自动删旧版本。
- remove 调用 delete_managed_policy_strict/1。已附加或存在非默认版本时返回可行动 400；绝不级联解绑、绝不静默删除版本。
- Maxio.Admin.PolicyAdapter 只能调用 Maxio.IAM 公共门面；不得 alias 或调用 Maxio.Repo、Maxio.Policy.Store、Ecto schema/query。
- 对象 body 纪律不变。这个 admin body 只能通过 Maxio.S3.ControlBody/BodyReader 的有限整读进入内存，禁止 Plug.Parsers、无界 read_body 和对象存储 handler。
- admin 控制面必须继续位于 SigV4 之后、S3 Dispatch 之前；anonymous 先返回 403，已认证的未知 admin 路由返回 501。vhost 寻址下同路径仍属于数据面，不能被 admin 认领。
- admin surface 分类必须位于 AddressStyle 和 health/metrics 保留面之后、RequestMetrics/AccessLogDelivery 之前。admin 不创建 S3 request-metric ledger，也不投递 bucket server access log；普通 S3 与 vhost 下同名对象仍保持原行为。
- 新日志只记策略名、动作、授权决定、被省略的非根 path 数量、request_id/principal 等控制面元数据；不得记录 policy document、密钥或内部路径。
- 所有实现由同一个 implementation lane 串行完成，避免并行 Mix 编译竞争；设计评审、实现、代码审查、最终验证必须是不同 subagent/lane，作者不得自审。
- 每个功能任务先保留真实 RED 输出，再写最小实现并保留 focused GREEN 输出。开发中只跑 focused test、compile、format；完整 mix precommit 只在最终独立验证执行一次。
- 每一个含 Mix 命令的 PowerShell code block 都必须在第一条 mix 之前逐字设置：Remove-Item Env:PGPORT；ERL_FLAGS='-kernel standard_io_encoding unicode'；ELIXIR_ERL_OPTIONS='+S 2:2 +A0 +sbwt none +sbwtdcpu none +sbwtdio none'。不得用跨 block 的临时变量代替。

- 测试进程使用 start_supervised!/1；禁止 Process.sleep/1。数据库测试按现有 DataCase 约定串行执行。
- 所有编辑使用 apply_patch，保留无关改动。实现计划中的 commit/push 是未来执行步骤；编写本计划时不得提交或推送。

---

## File/Interface Map

### Create

- docs/superpowers/plans/2026-08-28-minio-admin-policy-s1.md
  - 经独立 spec review 后作为本分支第一个 docs-only commit；后续 review 固定比较 c18b20b..HEAD。
- lib/maxio/s3/plugs/surface_classifier.ex
  - 在 AddressStyle 已赋值后写入 conn.assigns.maxio_surface，值只为 :admin 或 :s3。
- lib/maxio/admin/policy_request.ex
  - 唯一负责 AddCannedPolicy 的 Content-Length、chunked 拒绝、20,480-byte 有限读取。
- lib/maxio/admin/policy_adapter.ex
  - canned policy 与 Maxio.IAM managed policy 的纯适配层，只调用 Maxio.IAM。
- lib/maxio/admin/error_map.ex
  - IAM/适配 reason 到 %Maxio.S3.Error{} 的 admin JSON 契约映射。
- lib/mix/tasks/maxio.admin.policy.list.ex
- lib/mix/tasks/maxio.admin.policy.show.ex
- test/fixtures/admin/policy_s1_live.json
- test/maxio/s3/admin_surface_classification_test.exs
- test/maxio/admin/policy_request_test.exs
- test/maxio/admin/policy_adapter_test.exs
- test/maxio/admin/error_map_test.exs
- test/maxio/admin/policy_endpoint_test.exs
- test/mix/tasks/maxio_admin_policy_test.exs

### Modify

- lib/maxio/s3/endpoint.ex
  - SurfaceClassifier 插在 PrometheusMetrics 后、RequestMetrics 前；删除 admin=bucket minio 的过时说明。
- lib/maxio/s3/plugs/request_metrics.ex
  - maxio_surface=:admin 时不注册 before_send observer。
- lib/maxio/s3/plugs/access_log_delivery.ex
  - maxio_surface=:admin 时不注册 S3 access-log delivery。
- lib/maxio/admin/plug.ex
  - 使用已分类 surface；增加四条精确路由、逐 action 授权、200 响应和 ErrorMap。
- lib/maxio/s3/error.ex
  - 增加 S1 所需 admin 错误原子，复用既有 MissingContentLength/IncompleteBody。
- config/config.exs
  - logger metadata 加入 admin_action、admin_endpoint、target_policy、omitted_non_root_path_policies、surface。
- lib/maxio/compat/external_smoke.ex
- test/maxio/compat/external_smoke_test.exs
- README.md
- docs/superpowers/STATUS.md

### Frozen public interfaces

~~~elixir
Maxio.S3.Plugs.SurfaceClassifier.call(conn, opts) :: Plug.Conn.t()

Maxio.Admin.PolicyRequest.read_add_body!(conn) ::
  {Plug.Conn.t(), binary()}

Maxio.Admin.PolicyAdapter.validate_name(name) ::
  :ok | {:error, :invalid_argument | :invalid_resource_name}

Maxio.Admin.PolicyAdapter.create(name, raw_document) ::
  {:ok, map()} | {:error, term()}

Maxio.Admin.PolicyAdapter.list() ::
  {:ok,
   %{
     policies: %{String.t() => map()},
     omitted: [%{policy_arn: String.t(), policy_name: String.t(), path: String.t()}]
   }}

Maxio.Admin.PolicyAdapter.info(name) ::
  {:ok,
   %{
     "PolicyName" => String.t(),
     "Policy" => map(),
     "CreateDate" => DateTime.t(),
     "UpdateDate" => DateTime.t()
   }}
  | {:error, term()}

Maxio.Admin.PolicyAdapter.remove(name) ::
  :ok
  | {:error, {:policy_attached, map()}}
  | {:error, {:policy_has_non_default_versions, non_neg_integer()}}
  | {:error, term()}

Maxio.Admin.ErrorMap.from_reason(reason) :: Maxio.S3.Error.t()
~~~

---

## Pre-implementation Gate: Independent spec and plan review

**Files:**

- Read: AGENTS.md
- Read: docs/superpowers/specs/2026-08-20-minio-admin-user-policy-design.md
- Read: docs/superpowers/plans/2026-08-28-minio-admin-policy-s1.md
- Read: docs/superpowers/STATUS.md

**Lane:** 独立 architecture/spec-review subagent；不得由后续 implementation lane 承担。

- [ ] **Step 1: Produce a requirement matrix**

审查者逐项列出 P1-P4 route/method/action、request envelope、success body/status、name validation、v 分支、bucket 变体、IAM 调用、错误码、观测隔离、CLI 和 mc 验收，并给每项标记 “covered by Task N”。

- [ ] **Step 2: Resolve conflicts in favor of the verified protocol facts in this plan**

必须明确记录以下结论：

~~~text
AddCannedPolicy: raw JSON, no Content-Type requirement, positive Content-Length required
body max: 20,480 bytes exactly
PolicyInfo v2 keys: PolicyName/Policy/CreateDate/UpdateDate
mc fallback: only successful v2 with empty PolicyName; errors do not fall back
list-canned-policies?bucket=: authenticated 501
all four successful routes: HTTP 200
~~~

- [ ] **Step 3: Return a go/no-go verdict**

只有矩阵无缺口、无未决协议假设时才返回 GO。若是 NO-GO，修改本计划而不是让 implementation lane 猜测；修订后由同一独立 reviewer 重新给出 GO。

- [ ] **Step 4: Start one serial implementation lane**

Implementation lane 依次执行 Task 1-7，不派生并行写代码 agent。该 lane 可以运行 focused tests，但不能承担 Task 8 的独立审查或最终验证。

---

### Task 1: Classify admin as control-plane before S3 observers

**Files:**

- Create/commit first: docs/superpowers/plans/2026-08-28-minio-admin-policy-s1.md
- Create: lib/maxio/s3/plugs/surface_classifier.ex
- Create: test/maxio/s3/admin_surface_classification_test.exs
- Modify: lib/maxio/s3/endpoint.ex
- Modify: lib/maxio/s3/plugs/request_metrics.ex
- Modify: lib/maxio/s3/plugs/access_log_delivery.ex
- Modify: lib/maxio/admin/plug.ex

**Interfaces:**

- Consumes: Maxio.S3.ReservedNamespace.claimed?/2 after AddressStyle.
- Produces: conn.assigns.maxio_surface == :admin | :s3 for all requests reaching RequestMetrics.

- [ ] **Step 1: Commit the reviewed plan as the branch's first commit**

The worktree starts exactly at c18b20bce346ca8400015bc957f8c497c4659b90, which is also origin/master. After the independent spec reviewer returns GO:

~~~powershell
git add docs/superpowers/plans/2026-08-28-minio-admin-policy-s1.md
git commit -m "docs(plan): add admin policy S1 implementation plan"
$expectedBase='c18b20bce346ca8400015bc957f8c497c4659b90'
if ((git rev-parse HEAD^) -ne $expectedBase) { throw "plan commit is not first after c18b20b" }
if ((git merge-base HEAD origin/master) -ne $expectedBase) { throw "unexpected branch point" }
git diff --check c18b20b..HEAD
git status --short
~~~

Expected: the plan is committed alone, both base checks pass, diff check exits 0, and status is empty.

- [ ] **Step 2: Write the classifier RED tests**

测试必须覆盖 path-style admin、普通 S3、vhost 下 /minio/admin/... 三类，并直接检查 observer 私有标记：

~~~elixir
test "path-style admin is classified as control-plane and skips both S3 observers" do
  conn =
    :get
    |> SigV4Request.anon_conn("/minio/admin/v3/info")
    |> AddressStyle.call(AddressStyle.init([]))
    |> SurfaceClassifier.call(SurfaceClassifier.init([]))
    |> RequestMetrics.call(RequestMetrics.init([]))
    |> AccessLogDelivery.call(AccessLogDelivery.init([]))

  assert conn.assigns.maxio_surface == :admin
  refute conn.private[:maxio_request_metrics_started_at]
  refute conn.private[:maxio_access_log_started_at]
end

test "vhost object with the same path remains S3-observed" do
  conn =
    :get
    |> SigV4Request.anon_conn("/minio/admin/v3/info", host: "data.localhost")
    |> AddressStyle.call(AddressStyle.init([]))
    |> SurfaceClassifier.call(SurfaceClassifier.init([]))
    |> RequestMetrics.call(RequestMetrics.init([]))
    |> AccessLogDelivery.call(AccessLogDelivery.init([]))

  assert conn.assigns.maxio_surface == :s3
  assert is_integer(conn.private.maxio_request_metrics_started_at)
  assert %DateTime{} = conn.private.maxio_access_log_event_time
end
~~~

另加普通 path-style S3 请求断言两个 observer 仍注册，以及 SurfaceClassifier 被错误挂到 AddressStyle 前时抛 PipelineOrderError。

- [ ] **Step 3: Run the test and preserve RED**

Run:

~~~powershell
Remove-Item Env:PGPORT -ErrorAction SilentlyContinue
$env:ERL_FLAGS='-kernel standard_io_encoding unicode'
$env:ELIXIR_ERL_OPTIONS='+S 2:2 +A0 +sbwt none +sbwtdcpu none +sbwtdio none'
mix test test/maxio/s3/admin_surface_classification_test.exs
~~~

Expected: FAIL because Maxio.S3.Plugs.SurfaceClassifier does not exist and admin still registers both S3 observers.

- [ ] **Step 4: Implement the minimal classifier and observer guards**

核心实现保持单一认领表：

~~~elixir
def call(conn, _opts) do
  surface =
    if ReservedNamespace.claimed?(conn, :admin) do
      :admin
    else
      :s3
    end

  assign(conn, :maxio_surface, surface)
end
~~~

Endpoint 顺序固定为：

~~~elixir
plug Maxio.S3.Plugs.AddressStyle
plug Maxio.S3.Plugs.MinioHealth
plug Maxio.S3.Plugs.PrometheusMetrics
plug Maxio.S3.Plugs.SurfaceClassifier
plug Maxio.S3.Plugs.RequestMetrics
plug Maxio.S3.Plugs.AccessLogDelivery
~~~

RequestMetrics 与 AccessLogDelivery 各增加一个最前面的函数子句：

~~~elixir
def call(%{assigns: %{maxio_surface: :admin}} = conn, _opts), do: conn
~~~

Admin.Plug 只在 maxio_surface=:admin 时处理；若请求路径属于 admin 但 assign 缺失，抛 PipelineOrderError，防止今后管线误序。其它 :s3 请求原样返回。

- [ ] **Step 5: Run focused GREEN and existing namespace/admin regressions**

Run:

~~~powershell
Remove-Item Env:PGPORT -ErrorAction SilentlyContinue
$env:ERL_FLAGS='-kernel standard_io_encoding unicode'
$env:ELIXIR_ERL_OPTIONS='+S 2:2 +A0 +sbwt none +sbwtdcpu none +sbwtdio none'
mix test test/maxio/s3/admin_surface_classification_test.exs test/maxio/s3/reserved_namespace_test.exs test/maxio/s3/reserved_namespace_addressing_test.exs test/maxio/admin/plug_test.exs test/maxio/admin/info_endpoint_test.exs
mix compile --warnings-as-errors
~~~

Expected: all tests PASS; compile exits 0 with no warning.

- [ ] **Step 6: Commit the independently testable surface boundary**

~~~powershell
git add lib/maxio/s3/plugs/surface_classifier.ex lib/maxio/s3/endpoint.ex lib/maxio/s3/plugs/request_metrics.ex lib/maxio/s3/plugs/access_log_delivery.ex lib/maxio/admin/plug.ex test/maxio/s3/admin_surface_classification_test.exs
git commit -m "fix(admin): isolate control-plane request observers"
~~~

---

### Task 2: Define the S1 admin error contract

**Files:**

- Create: lib/maxio/admin/error_map.ex
- Create: test/maxio/admin/error_map_test.exs
- Modify: lib/maxio/s3/error.ex

**Interfaces:**

- Consumes: Maxio.S3.Error.new/2 and existing Maxio.Admin.ErrorView.
- Produces: Maxio.Admin.ErrorMap.from_reason/1 from the frozen interface map.

- [ ] **Step 1: Write exact RED assertions for wire codes**

~~~elixir
test "maps policy absence and invalid names to MinIO admin errors" do
  assert %{code: "XMinioAdminNoSuchPolicy", http_status: 404} =
           ErrorMap.from_reason(:not_found)

  assert %{code: "XMinioAdminInvalidArgument", http_status: 400} =
           ErrorMap.from_reason(:invalid_argument)

  assert %{code: "XMinioInvalidResource", http_status: 400} =
           ErrorMap.from_reason(:invalid_resource_name)

  assert %{code: "MalformedPolicy", http_status: 400} =
           ErrorMap.from_reason(:malformed_policy_document)
end

test "delete blockers are actionable without leaking policy documents" do
  attached =
    ErrorMap.from_reason(
      {:policy_attached,
       %{
         users: [%{user_name: "alice"}],
         groups: [%{group_name: "ops"}],
         roles: [%{role_name: "reader"}]
       }}
    )

  assert attached.code == "XMinioAdminInvalidArgument"
  assert attached.http_status == 400
  assert attached.message =~ "alice"
  assert attached.message =~ "ops"
  assert attached.message =~ "reader"
  assert attached.message =~ "detach"

  versions = ErrorMap.from_reason({:policy_has_non_default_versions, 2})
  assert versions.code == "XMinioAdminInvalidArgument"
  assert versions.message =~ "2"
  assert versions.message =~ "DeletePolicyVersion"
end
~~~

另断言 :policy_version_limit_exceeded 的 message 明示 5-version limit 与先删非默认版本；未知 reason 映射脱敏 InternalError/500，body 不含 inspect(reason)。

- [ ] **Step 2: Run and preserve RED**

Run:

~~~powershell
Remove-Item Env:PGPORT -ErrorAction SilentlyContinue
$env:ERL_FLAGS='-kernel standard_io_encoding unicode'
$env:ELIXIR_ERL_OPTIONS='+S 2:2 +A0 +sbwt none +sbwtdcpu none +sbwtdio none'
mix test test/maxio/admin/error_map_test.exs
~~~

Expected: FAIL because ErrorMap and the admin error atoms do not exist.

- [ ] **Step 3: Add only the S1 error entries**

在 Maxio.S3.Error 的 table 中增加：

~~~elixir
admin_no_such_policy:
  {"XMinioAdminNoSuchPolicy", 404, "The canned policy does not exist."},
admin_invalid_argument:
  {"XMinioAdminInvalidArgument", 400, "Invalid arguments specified."},
admin_resource_invalid_argument:
  {"XMinioInvalidResource", 400,
   "Policy, user or group names are not allowed to begin or end with space characters"},
malformed_policy_wire:
  {"MalformedPolicy", 400, "The policy document is malformed."}
~~~

不要重复新增 missing_content_length 或 incomplete_body；它们已存在。

- [ ] **Step 4: Implement total, redacted ErrorMap clauses**

核心映射必须精确：

~~~elixir
def from_reason(reason)

def from_reason(reason) when reason in [:not_found, :policy_not_found],
  do: Error.new(:admin_no_such_policy)

def from_reason(reason) when reason in [:invalid_argument, :malformed, :already_exists],
  do: Error.new(:admin_invalid_argument)

def from_reason(:invalid_resource_name),
  do: Error.new(:admin_resource_invalid_argument)

def from_reason(:malformed_policy_document),
  do: Error.new(:malformed_policy_wire)

def from_reason(:policy_version_limit_exceeded),
  do: Error.new(:admin_invalid_argument, message: version_limit_message())

def from_reason({:policy_attached, entities}),
  do: Error.new(:admin_invalid_argument, message: attached_message(entities))

def from_reason({:policy_has_non_default_versions, count}),
  do: Error.new(:admin_invalid_argument, message: version_delete_message(count))

def from_reason(_reason), do: Error.new(:internal_error)
~~~

消息生成器只抽取 user_name/group_name/role_name，排序后输出；不编码整个实体 map。

- [ ] **Step 5: Run GREEN and ErrorView regression**

Run:

~~~powershell
Remove-Item Env:PGPORT -ErrorAction SilentlyContinue
$env:ERL_FLAGS='-kernel standard_io_encoding unicode'
$env:ELIXIR_ERL_OPTIONS='+S 2:2 +A0 +sbwt none +sbwtdcpu none +sbwtdio none'
mix test test/maxio/admin/error_map_test.exs test/maxio/admin/plug_test.exs
mix compile --warnings-as-errors
~~~

Expected: PASS and zero warnings.

- [ ] **Step 6: Commit the wire error contract**

~~~powershell
git add lib/maxio/admin/error_map.ex lib/maxio/s3/error.ex test/maxio/admin/error_map_test.exs
git commit -m "feat(admin): define policy adapter error contract"
~~~

---

### Task 3: Build the IAM-only PolicyAdapter

**Files:**

- Create: lib/maxio/admin/policy_adapter.ex
- Create: test/maxio/admin/policy_adapter_test.exs

**Interfaces:**

- Consumes: Maxio.IAM.managed_policy_arn/2, create_managed_policy_strict/1, create_managed_policy_version_strict/3, get_managed_policy/1, list_managed_policies/1, delete_managed_policy_strict/1, list_managed_policy_entities_strict/2, list_managed_policy_versions_strict/1.
- Produces: all PolicyAdapter functions frozen in File/Interface Map.

- [ ] **Step 1: Write RED tests for explicit name validation**

~~~elixir
test "rejects empty, Unicode-edge-whitespace, comma, slash, backslash, and dot path segments" do
  assert {:error, :invalid_argument} = PolicyAdapter.validate_name("")
  assert {:error, :invalid_argument} = PolicyAdapter.validate_name(nil)

  for name <- [" policy", "policy ", "\u00A0policy", "policy\u3000", "a,b",
               ".", "..", "/ops", "team/", "team/ops", "team/../ops",
               "\\ops", "team\\", "team\\ops", "team\\..\\ops"] do
    assert {:error, :invalid_resource_name} = PolicyAdapter.validate_name(name)
  end

  assert :ok = PolicyAdapter.validate_name("p-ro")
end

test "IAM can parse a slash name as a hidden path, but adapter rejects it before lookup" do
  nested_name = unique_name("ops")
  external_name = "team/#{nested_name}"
  nested_arn = IAM.managed_policy_arn(external_name, "/")

  assert :ok = IAM.validate_managed_policy_arn(nested_arn)
  assert {:error, :invalid_resource_name} = PolicyAdapter.validate_name(external_name)
end
~~~

- [ ] **Step 2: Run the validation test and preserve RED**

Run:

~~~powershell
Remove-Item Env:PGPORT -ErrorAction SilentlyContinue
$env:ERL_FLAGS='-kernel standard_io_encoding unicode'
$env:ELIXIR_ERL_OPTIONS='+S 2:2 +A0 +sbwt none +sbwtdcpu none +sbwtdio none'
mix test test/maxio/admin/policy_adapter_test.exs:1
~~~

Expected: FAIL because PolicyAdapter does not exist.

- [ ] **Step 3: Implement name validation without atom creation**

~~~elixir
def validate_name(name) when is_binary(name) do
  segments = String.split(name, ["/", "\\"], trim: false)

  cond do
    name == "" -> {:error, :invalid_argument}
    String.trim(name) != name -> {:error, :invalid_resource_name}
    String.contains?(name, ",") -> {:error, :invalid_resource_name}
    String.contains?(name, ["/", "\\"]) -> {:error, :invalid_resource_name}
    Enum.any?(segments, &(&1 in [".", ".."])) -> {:error, :invalid_resource_name}
    true -> :ok
  end
end

def validate_name(_name), do: {:error, :invalid_argument}

defp root_policy_target(name) do
  with :ok <- validate_name(name),
       arn = IAM.managed_policy_arn(name, "/"),
       :ok <- IAM.validate_managed_policy_arn(arn) do
    resource_name = String.replace_prefix(arn, "arn:aws:iam:::policy/", "")

    if resource_name == name and
         not String.contains?(resource_name, ["/", "\\"]) and
         IAM.managed_policy_arn(resource_name, "/") == arn do
      {:ok, arn}
    else
      {:error, :invalid_resource_name}
    end
  else
    {:error, :malformed} -> {:error, :invalid_resource_name}
    {:error, reason} -> {:error, reason}
  end
end
~~~

All three named operations create/2, info/1 and remove/1 must begin with root_policy_target/1. This is the public-IAM validation/round-trip boundary; no operation may reconstruct or accept a target by a separate path.

- [ ] **Step 4: Run validation GREEN**

Run:

~~~powershell
Remove-Item Env:PGPORT -ErrorAction SilentlyContinue
$env:ERL_FLAGS='-kernel standard_io_encoding unicode'
$env:ELIXIR_ERL_OPTIONS='+S 2:2 +A0 +sbwt none +sbwtdcpu none +sbwtdio none'
mix test test/maxio/admin/policy_adapter_test.exs
~~~

Expected: validation tests PASS; lifecycle tests added next still fail for missing functions.

- [ ] **Step 5: Add RED lifecycle tests for create and version preservation**

Use Maxio.DataCase, async: false and unique names. Assert:

~~~elixir
test "create uses root path and same-name create adds a new default version" do
  name = unique_name("s1-create")
  first = policy("s3:GetObject")
  second = policy("s3:PutObject")
  arn = IAM.managed_policy_arn(name, "/")

  assert {:ok, %{policy_arn: ^arn, path: "/"}} = PolicyAdapter.create(name, first)
  assert {:ok, _updated} = PolicyAdapter.create(name, second)

  assert {:ok, %{document: document, default_version_id: default_version_id}} =
           IAM.get_managed_policy(arn)

  assert document["Statement"]["Action"] == "s3:PutObject"
  assert default_version_id == "v2"
  assert {:ok, versions} = IAM.list_managed_policy_versions_strict(arn)
  assert Enum.map(versions, & &1.version_id) |> Enum.sort() == ["v1", "v2"]
end

test "sixth same-name create reports version quota and never removes history" do
  name = unique_name("s1-quota")
  assert {:ok, _} = PolicyAdapter.create(name, policy("s3:GetObject"))

  for _version <- 2..5 do
    assert {:ok, _} = PolicyAdapter.create(name, policy("s3:GetObject"))
  end

  assert {:error, :policy_version_limit_exceeded} =
           PolicyAdapter.create(name, policy("s3:PutObject"))

  assert {:ok, versions} =
           name |> IAM.managed_policy_arn("/") |> IAM.list_managed_policy_versions_strict()

  assert length(versions) == 5
end
~~~

Implement a duplicate-create race fallback: if get returned :error but create_managed_policy_strict/1 returns :already_exists, retry create_managed_policy_version_strict/3 once. Do not use put_managed_policy/1.

- [ ] **Step 6: Implement minimal create**

~~~elixir
def create(name, raw_document) when is_binary(raw_document) do
  with {:ok, arn} <- root_policy_target(name) do
    case IAM.get_managed_policy(arn) do
      {:ok, _policy} ->
        IAM.create_managed_policy_version_strict(arn, raw_document, true)

      :error ->
        case IAM.create_managed_policy_strict(
               name: name,
               path: "/",
               document: raw_document
             ) do
          {:error, :already_exists} ->
            IAM.create_managed_policy_version_strict(arn, raw_document, true)

          result ->
            result
        end

      {:error, reason} ->
        {:error, reason}
    end
  end
end
~~~

Non-binary raw_document returns {:error, :malformed_policy_document}.

- [ ] **Step 7: Add RED tests for list and info wire projection**

Create one root policy and one /team/ policy through Maxio.IAM, then assert:

~~~elixir
assert {:ok, %{policies: policies, omitted: omitted}} = PolicyAdapter.list()
assert policies[root_name]["Statement"]["Action"] == "s3:GetObject"
refute Map.has_key?(policies, nested_name)
assert [%{policy_name: ^nested_name, path: "/team/"}] = omitted

assert {:ok, info} = PolicyAdapter.info(root_name)
assert Map.keys(info) |> Enum.sort() ==
         ["CreateDate", "Policy", "PolicyName", "UpdateDate"]
assert info["PolicyName"] == root_name
assert is_map(info["Policy"])
assert %DateTime{} = info["CreateDate"]
assert %DateTime{} = info["UpdateDate"]
assert {:error, :not_found} = PolicyAdapter.info("missing-policy")
~~~

Add mutation tests that first create an actual hidden policy at path "/team/" through Maxio.IAM, then prove every external slash/backslash spelling is rejected before mutation:

~~~elixir
test "create info and remove cannot address a hidden non-root policy through a crafted name" do
  nested_name = unique_name("hidden")
  hidden_arn = IAM.managed_policy_arn(nested_name, "/team/")
  original = policy("s3:GetObject")

  assert {:ok, _} =
           IAM.create_managed_policy_strict(
             name: nested_name,
             path: "/team/",
             document: original
           )

  for external_name <- ["team/#{nested_name}", "team\\#{nested_name}"] do
    assert {:error, :invalid_resource_name} =
             PolicyAdapter.create(external_name, policy("s3:PutObject"))

    assert {:error, :invalid_resource_name} = PolicyAdapter.info(external_name)
    assert {:error, :invalid_resource_name} = PolicyAdapter.remove(external_name)
  end

  assert {:ok, %{policy_arn: ^hidden_arn, document: document}} =
           IAM.get_managed_policy(hidden_arn)

  assert document["Statement"]["Action"] == "s3:GetObject"
end
~~~

- [ ] **Step 8: Implement root-only list and PolicyInfo**

list/0 must split strict path == "/" and return a name-to-document map plus bounded omitted metadata. info/1 must obtain its ARN only from root_policy_target/1, map IAM :error to {:error, :not_found}, and construct exactly the four string-key fields.

- [ ] **Step 9: Add RED tests for strict remove blockers**

Cover:

1. unattached single-version policy deletes and second delete is :not_found;
2. attached policy returns {:policy_attached, entities} with exact user/group/role collections and remains present;
3. two-version policy returns {:policy_has_non_default_versions, 1} and all versions remain;
4. no detach or DeletePolicyVersion is performed by remove/1.

~~~elixir
assert {:error, {:policy_has_non_default_versions, 1}} =
         PolicyAdapter.remove(versioned_name)

assert {:ok, versions} =
         versioned_name
         |> IAM.managed_policy_arn("/")
         |> IAM.list_managed_policy_versions_strict()

assert length(versions) == 2
assert Enum.count(versions, &(not &1.is_default_version)) == 1
~~~

- [ ] **Step 10: Implement enriched remove reasons**

remove/1 first obtains its ARN only from root_policy_target/1, then calls IAM.delete_managed_policy_strict/1. Only on :policy_attached call IAM.list_managed_policy_entities_strict/2; only on :policy_has_non_default_versions call IAM.list_managed_policy_versions_strict/1 and count versions where is_default_version is false. Do not inspect Repo or Store.

- [ ] **Step 11: Run full adapter GREEN and prove the architecture boundary**

Run:

~~~powershell
Remove-Item Env:PGPORT -ErrorAction SilentlyContinue
$env:ERL_FLAGS='-kernel standard_io_encoding unicode'
$env:ELIXIR_ERL_OPTIONS='+S 2:2 +A0 +sbwt none +sbwtdcpu none +sbwtdio none'
mix test test/maxio/admin/policy_adapter_test.exs
rg -n "Maxio\\.(Repo|Policy\\.Store)|Ecto\\." lib/maxio/admin/policy_adapter.ex
mix compile --warnings-as-errors
~~~

Expected: tests PASS; rg has no matches and exits 1; compile exits 0 with no warning.

- [ ] **Step 12: Commit the IAM-only adapter**

~~~powershell
git add lib/maxio/admin/policy_adapter.ex test/maxio/admin/policy_adapter_test.exs
git commit -m "feat(admin): adapt local managed policies for madmin"
~~~

---

### Task 4: Enforce AddCannedPolicy body framing and exact 20,480-byte limit

**Files:**

- Create: lib/maxio/admin/policy_request.ex
- Create: test/maxio/admin/policy_request_test.exs

**Interfaces:**

- Consumes: Maxio.S3.ControlBody.read!/4 and existing Maxio.S3.Error atoms.
- Produces: Maxio.Admin.PolicyRequest.read_add_body!/1.

- [ ] **Step 1: Write framing RED tests**

Use Plug.Test.conn/3 and manipulate request headers explicitly. Assert:

~~~elixir
test "accepts positive Content-Length without Content-Type" do
  body = ~s({"Version":"2012-10-17","Statement":[]})
  conn = Plug.Test.conn(:put, "/minio/admin/v3/add-canned-policy?name=p", body)

  refute Plug.Conn.get_req_header(conn, "content-type") != []
  assert {_conn, ^body} = PolicyRequest.read_add_body!(conn)
end

test "only a positive ASCII decimal Content-Length is accepted" do
  cases = [
    [],
    [{"content-length", "0"}],
    [{"content-length", "-1"}],
    [{"content-length", "+1"}],
    [{"content-length", " 1"}],
    [{"content-length", "1 "}],
    [{"content-length", "\t1"}],
    [{"content-length", "١"}],
    [{"content-length", "１"}],
    [{"content-length", "abc"}],
    [{"content-length", "1"}, {"content-length", "1"}],
    [{"transfer-encoding", "chunked"}]
  ]

  for headers <- cases do
    conn =
      Plug.Test.conn(:put, "/minio/admin/v3/add-canned-policy?name=p", "{}")
      |> delete_req_header("content-length")
      |> then(fn conn -> %{conn | req_headers: headers ++ conn.req_headers} end)

    assert_raise Maxio.S3.Error, fn ->
      PolicyRequest.read_add_body!(conn)
    end
  end
end
~~~

For every raised error assert code == "MissingContentLength" and http_status == 411, not merely that an exception occurred.

- [ ] **Step 2: Write exact boundary RED tests**

~~~elixir
test "reads exactly 20_480 bytes and rejects 20_481 before parsing" do
  accepted = String.duplicate(" ", 20_480)
  accepted_conn = Plug.Test.conn(:put, "/", accepted)
  assert {_conn, ^accepted} = PolicyRequest.read_add_body!(accepted_conn)

  rejected = String.duplicate(" ", 20_481)
  rejected_conn = Plug.Test.conn(:put, "/", rejected)

  error =
    assert_raise Maxio.S3.Error, fn ->
      PolicyRequest.read_add_body!(rejected_conn)
    end

  assert error.code == "XMinioAdminInvalidArgument"
  assert error.http_status == 400
end
~~~

另测试声明长度大于 20,480 时不调用 body reader，以及声明长度与实际 body 不等返回 IncompleteBody/400。

- [ ] **Step 3: Run and preserve RED**

Run:

~~~powershell
Remove-Item Env:PGPORT -ErrorAction SilentlyContinue
$env:ERL_FLAGS='-kernel standard_io_encoding unicode'
$env:ELIXIR_ERL_OPTIONS='+S 2:2 +A0 +sbwt none +sbwtdcpu none +sbwtdio none'
mix test test/maxio/admin/policy_request_test.exs
~~~

Expected: FAIL because PolicyRequest does not exist.

- [ ] **Step 4: Implement strict framing before bounded read**

~~~elixir
@max_policy_bytes 20_480

def read_add_body!(conn) do
  declared = positive_content_length!(conn)

  if declared > @max_policy_bytes do
    raise Error.new(:admin_invalid_argument,
            message: "Policy document must not exceed 20480 bytes."
          )
  end

  {conn, body, _trailers} =
    ControlBody.read!(
      conn,
      @max_policy_bytes,
      "Policy document must not exceed 20480 bytes.",
      too_large_error: :admin_invalid_argument
    )

  if byte_size(body) != declared do
    raise Error.new(:incomplete_body)
  end

  {conn, body}
end
~~~

positive_content_length!/1 必须先拒绝任何 transfer-encoding header，再要求恰好一个 content-length。解析只能走下面的 ASCII gate；不能用 \d、Unicode character class、String.trim/1 或单独 Integer.parse/1 放宽语法：

~~~elixir
defp positive_content_length!(conn) do
  case {get_req_header(conn, "transfer-encoding"), get_req_header(conn, "content-length")} do
    {[], [value]} when is_binary(value) ->
      if Regex.match?(~r/\A[0-9]+\z/, value) do
        {length, ""} = Integer.parse(value)
        if length > 0, do: length, else: raise(Error.new(:missing_content_length))
      else
        raise Error.new(:missing_content_length)
      end

    _other ->
      raise Error.new(:missing_content_length)
  end
end
~~~

不要读取或检查 content-type。

- [ ] **Step 5: Run GREEN and ControlBody regressions**

Run:

~~~powershell
Remove-Item Env:PGPORT -ErrorAction SilentlyContinue
$env:ERL_FLAGS='-kernel standard_io_encoding unicode'
$env:ELIXIR_ERL_OPTIONS='+S 2:2 +A0 +sbwt none +sbwtdcpu none +sbwtdio none'
mix test test/maxio/admin/policy_request_test.exs test/maxio/s3/control_body_test.exs test/maxio/s3/body_reader_test.exs
mix compile --warnings-as-errors
~~~

If one of the named legacy test files is absent, use rg --files test/maxio/s3 | rg "control_body|body_reader" and run the returned exact files; do not silently omit the existing reader regression.

Expected: PASS and zero warnings.

- [ ] **Step 6: Commit the bounded wire reader**

~~~powershell
git add lib/maxio/admin/policy_request.ex test/maxio/admin/policy_request_test.exs
git commit -m "feat(admin): enforce policy request body framing"
~~~

---

### Task 5: Route and authorize the four exact v3 policy endpoints

**Files:**

- Create: test/maxio/admin/policy_endpoint_test.exs
- Modify: lib/maxio/admin/plug.ex
- Modify: config/config.exs

**Interfaces:**

- Consumes: SurfaceClassifier assign, PolicyRequest.read_add_body!/1, PolicyAdapter, ErrorMap, Authz.authorize/3.
- Produces: the four exact HTTP routes and their madmin wire responses.

- [ ] **Step 1: Add a real-pipeline RED lifecycle test**

Use Maxio.DataCase, async: false; drive Maxio.S3.Endpoint with Maxio.Test.SigV4Request.signed_conn/3 and region: "". The create request must omit Content-Type while preserving positive Content-Length.

~~~elixir
test "root completes create/list/v2-info/legacy-info/remove with strict 200 responses" do
  name = unique_name("mc-policy")
  body = policy_json("s3:GetObject")

  created = signed(:put, "/minio/admin/v3/add-canned-policy",
    query: %{"name" => name},
    body: body,
    region: ""
  )

  assert created.status == 200
  assert created.resp_body == ""

  listed = signed(:get, "/minio/admin/v3/list-canned-policies", region: "")
  assert listed.status == 200
  assert is_map(Jason.decode!(listed.resp_body)[name])

  v2 = signed(:get, "/minio/admin/v3/info-canned-policy",
    query: %{"name" => name, "v" => "2"},
    region: ""
  )

  assert v2.status == 200
  assert %{
           "PolicyName" => ^name,
           "Policy" => %{},
           "CreateDate" => _,
           "UpdateDate" => _
         } = Jason.decode!(v2.resp_body)

  legacy = signed(:get, "/minio/admin/v3/info-canned-policy",
    query: %{"name" => name},
    region: ""
  )

  assert legacy.status == 200
  refute Map.has_key?(Jason.decode!(legacy.resp_body), "PolicyName")
  assert Jason.decode!(legacy.resp_body)["Statement"]["Action"] == "s3:GetObject"

  removed = signed(:delete, "/minio/admin/v3/remove-canned-policy",
    query: %{"name" => name},
    region: ""
  )

  assert removed.status == 200
  assert removed.resp_body == ""
end
~~~

- [ ] **Step 2: Run lifecycle test and preserve RED**

Run:

~~~powershell
Remove-Item Env:PGPORT -ErrorAction SilentlyContinue
$env:ERL_FLAGS='-kernel standard_io_encoding unicode'
$env:ELIXIR_ERL_OPTIONS='+S 2:2 +A0 +sbwt none +sbwtdcpu none +sbwtdio none'
mix test test/maxio/admin/policy_endpoint_test.exs
~~~

Expected: FAIL with current NotImplemented/501.

- [ ] **Step 3: Add exact dispatch clauses and one authorization wrapper**

Fetch query params once. Dispatch only exact method/path pairs. Each handler calls:

~~~elixir
authorize_and_run(conn, "admin:CreatePolicy", "admin_policy_create", fn conn ->
  {conn, body} = PolicyRequest.read_add_body!(conn)

  case PolicyAdapter.create(conn.query_params["name"], body) do
    {:ok, _policy} -> send_empty_success(conn)
    {:error, reason} -> render_error(conn, ErrorMap.from_reason(reason))
  end
end)
~~~

Use corresponding exact actions for list/info/remove. authorize_and_run/4 logs admin_action, admin_endpoint, target_policy, decision, request_id and principal_arn; deny reason stays only in logs and the response is AccessDenied/403.

- [ ] **Step 4: Add and run RED response-shape tests**

Add tests for:

- list JSON is {"name": policy-object}, never a name-to-JSON-string map；
- v=2 has exactly four capitalized keys and nonempty PolicyName；
- no-v and v="" both return the raw object；
- v=1, v=3 and v=abc return XMinioAdminInvalidArgument/400 without trying legacy；
- missing name and name="" return XMinioAdminInvalidArgument/400；
- whitespace/comma/slash/backslash/dot-segment names return XMinioInvalidResource/400；
- unknown policy info/remove return XMinioAdminNoSuchPolicy/404；
- malformed JSON returns MalformedPolicy/400；
- request without Content-Type succeeds；
- missing/0/chunked Content-Length returns MissingContentLength/411；
- create/remove body/status are exactly empty/200。

Run:

~~~powershell
Remove-Item Env:PGPORT -ErrorAction SilentlyContinue
$env:ERL_FLAGS='-kernel standard_io_encoding unicode'
$env:ELIXIR_ERL_OPTIONS='+S 2:2 +A0 +sbwt none +sbwtdcpu none +sbwtdio none'
mix test test/maxio/admin/policy_endpoint_test.exs
~~~

Expected before handler completion: one or more shape/error cases FAIL for a specific missing branch.

- [ ] **Step 5: Complete the minimal list/info/remove handlers**

Response rules:

~~~elixir
# list
send_json(conn, 200, result.policies)

# info v2
send_json(conn, 200, info)

# info no-v or empty-v
send_json(conn, 200, info["Policy"])

# create/remove
send_resp(conn, 200, "") |> halt()
~~~

When list result omitted is nonempty, Log.info with action: "admin_policy_list", omitted_non_root_path_policies: length(result.omitted), and no document body.

When query_params has key "bucket", call the authenticated NotImplemented renderer before PolicyAdapter.list/0. Do not treat an empty bucket value as absent.

- [ ] **Step 6: Add per-action authorization RED tests**

For each route, create an IAM key and an identity policy containing only its exact admin action. Assert that route succeeds and at least one other S1 route returns 403. Also cover:

~~~elixir
test "anonymous policy route is 403 before route disclosure" do
  conn =
    :get
    |> SigV4Request.anon_conn("/minio/admin/v3/list-canned-policies")
    |> Endpoint.call(Endpoint.init([]))

  assert conn.status == 403
  assert Jason.decode!(conn.resp_body)["Code"] == "AccessDenied"
end

test "authenticated bucket variant remains explicit 501" do
  conn = signed(:get, "/minio/admin/v3/list-canned-policies",
    query: %{"bucket" => ""}
  )

  assert conn.status == 501
  assert Jason.decode!(conn.resp_body)["Code"] == "NotImplemented"
end
~~~

Reuse existing Authz tests for explicit deny, STS session boundary, and bucket-policy-not-admin; add endpoint-level exact-action cases, not a duplicate evaluator unit matrix.

- [ ] **Step 7: Run endpoint GREEN and existing admin regressions**

Run:

~~~powershell
Remove-Item Env:PGPORT -ErrorAction SilentlyContinue
$env:ERL_FLAGS='-kernel standard_io_encoding unicode'
$env:ELIXIR_ERL_OPTIONS='+S 2:2 +A0 +sbwt none +sbwtdcpu none +sbwtdio none'
mix test test/maxio/admin/policy_endpoint_test.exs test/maxio/admin/policy_request_test.exs test/maxio/admin/policy_adapter_test.exs test/maxio/admin/error_map_test.exs test/maxio/admin/authz_test.exs test/maxio/admin/plug_test.exs test/maxio/admin/info_endpoint_test.exs test/maxio/s3/admin_surface_classification_test.exs
mix compile --warnings-as-errors
mix format --check-formatted
~~~

Expected: all PASS; no warnings; format exits 0.

- [ ] **Step 8: Add logger metadata and verify no sensitive payload logging**

Add only:

~~~elixir
:admin_action,
:admin_endpoint,
:target_policy,
:omitted_non_root_path_policies,
:surface
~~~

Run:

~~~powershell
rg -n "policy_document|raw_document|resp_body|secret_key" lib/maxio/admin
~~~

Expected: no Log call includes policy body or secret. Legitimate function variables are acceptable only when not passed into Log metadata; inspect each match.

- [ ] **Step 9: Commit the complete HTTP slice**

~~~powershell
git add lib/maxio/admin/plug.ex config/config.exs test/maxio/admin/policy_endpoint_test.exs
git commit -m "feat(admin): serve managed policy CRUD endpoints"
~~~

---

### Task 6: Add admin-view CLI evidence

**Files:**

- Create: lib/mix/tasks/maxio.admin.policy.list.ex
- Create: lib/mix/tasks/maxio.admin.policy.show.ex
- Create: test/mix/tasks/maxio_admin_policy_test.exs

**Interfaces:**

- Consumes: PolicyAdapter.list/0 and PolicyAdapter.info/1.
- Produces: mix maxio.admin.policy.list [--json] and mix maxio.admin.policy.show NAME [--json].

- [ ] **Step 1: Write CLI RED tests**

Use Mix.Shell.Process and reenable tasks between calls. Assert:

~~~elixir
test "list reports both visible and omitted non-root policies" do
  assert {:ok, _} = IAM.create_managed_policy_strict(
    name: "root-visible",
    path: "/",
    document: policy_json()
  )

  assert {:ok, _} = IAM.create_managed_policy_strict(
    name: "team-hidden",
    path: "/team/",
    document: policy_json()
  )

  Mix.Task.run("maxio.admin.policy.list", ["--json"])
  assert_received {:mix_shell, :info, [json]}

  output = Jason.decode!(json)
  assert output["policies"]["root-visible"]
  assert [%{"policy_name" => "team-hidden", "reason" => "non_root_path"}] =
           output["omitted"]
end

test "show emits the same four PolicyInfo keys as madmin v2" do
  Mix.Task.run("maxio.admin.policy.show", ["root-visible", "--json"])
  assert_received {:mix_shell, :info, [json]}
  assert Map.keys(Jason.decode!(json)) |> Enum.sort() ==
           ["CreateDate", "Policy", "PolicyName", "UpdateDate"]
end
~~~

Also assert missing name and unknown policy raise Mix.Error with a concise message and no internal path.

- [ ] **Step 2: Run and preserve RED**

Run:

~~~powershell
Remove-Item Env:PGPORT -ErrorAction SilentlyContinue
$env:ERL_FLAGS='-kernel standard_io_encoding unicode'
$env:ELIXIR_ERL_OPTIONS='+S 2:2 +A0 +sbwt none +sbwtdcpu none +sbwtdio none'
mix test test/mix/tasks/maxio_admin_policy_test.exs
~~~

Expected: FAIL because both Mix tasks are missing.

- [ ] **Step 3: Implement thin CLI tasks**

Both tasks call Mix.Task.run("app.start"). list/0 uses PolicyAdapter.list/0 and prints structured JSON:

~~~json
{
  "policies": {"root-visible": {"Version": "2012-10-17", "Statement": []}},
  "omitted": [
    {"policy_arn": "arn:aws:iam:::policy/team/team-hidden",
     "policy_name": "team-hidden",
     "path": "/team/",
     "reason": "non_root_path"}
  ]
}
~~~

show prints the exact PolicyInfo projection. Human mode prints one stable tagged line per visible/omitted policy and never prints secret material.

- [ ] **Step 4: Run CLI GREEN and direct commands**

Run:

~~~powershell
Remove-Item Env:PGPORT -ErrorAction SilentlyContinue
$env:ERL_FLAGS='-kernel standard_io_encoding unicode'
$env:ELIXIR_ERL_OPTIONS='+S 2:2 +A0 +sbwt none +sbwtdcpu none +sbwtdio none'
mix test test/mix/tasks/maxio_admin_policy_test.exs
mix maxio.admin.policy.list --json
mix compile --warnings-as-errors
~~~

Expected: test PASS; fresh database command emits policies={} and omitted=[]; compile has no warning.

- [ ] **Step 5: Commit CLI evidence**

~~~powershell
git add lib/mix/tasks/maxio.admin.policy.list.ex lib/mix/tasks/maxio.admin.policy.show.ex test/mix/tasks/maxio_admin_policy_test.exs
git commit -m "feat(admin): add policy inspection tasks"
~~~

---

### Task 7: Extend real-client smoke coverage and document deliberate differences

**Files:**

- Modify: lib/maxio/compat/external_smoke.ex
- Modify: test/maxio/compat/external_smoke_test.exs
- Create: test/fixtures/admin/policy_s1_live.json
- Modify: README.md

**Interfaces:**

- Consumes: existing minio_mc external-smoke client and S1 HTTP endpoints.
- Produces: repeatable mc admin policy lifecycle evidence with cleanup.

- [ ] **Step 1: Write external-smoke RED expectations**

Extend the minio_mc test to require these ordered step ids in addition to existing S3 steps:

~~~elixir
assert Enum.map(entry["steps"], & &1["id"]) ==
         [
           "make_bucket",
           "put_object",
           "stat_object",
           "get_object",
           "copy_object",
           "stat_copied_object",
           "get_copied_object",
           "admin_policy_create",
           "admin_policy_list",
           "admin_policy_info",
           "admin_policy_remove",
           "delete_copied_object",
           "delete_object",
           "delete_bucket"
         ]

assert entry["scenario_counts"]["admin_policy_lifecycle"] == 4
~~~

Assert all four commands use the existing mc alias, the generated policy name, and a generated local JSON file; cleanup contains admin_policy_remove even when a later S3 cleanup step fails.

- [ ] **Step 2: Run and preserve RED**

Run:

~~~powershell
Remove-Item Env:PGPORT -ErrorAction SilentlyContinue
$env:ERL_FLAGS='-kernel standard_io_encoding unicode'
$env:ELIXIR_ERL_OPTIONS='+S 2:2 +A0 +sbwt none +sbwtdcpu none +sbwtdio none'
mix test test/maxio/compat/external_smoke_test.exs
~~~

Expected: FAIL because mc_steps/4 has no admin policy steps.

- [ ] **Step 3: Add deterministic policy fixtures and mc commands**

with_temp_paths/3 creates:

~~~elixir
policy_name = "maxio-compat-policy-#{unique_id()}"
policy_path = Path.join(tmp_dir, "policy.json")
File.write!(policy_path, Jason.encode!(%{
  "Version" => "2012-10-17",
  "Statement" => %{
    "Effect" => "Allow",
    "Action" => "s3:GetObject",
    "Resource" => "arn:aws:s3:::maxio-compat-*/*"
  }
}))
~~~

mc steps use these exact argument lists:

~~~elixir
base = ["--config-dir", paths.mc_config_dir]

base ++ ["admin", "policy", "create", "maxiocompat", paths.policy_name, paths.policy_path]
base ++ ["admin", "policy", "ls", "maxiocompat"]
base ++ ["admin", "policy", "info", "maxiocompat", paths.policy_name]
base ++ ["admin", "policy", "rm", "maxiocompat", paths.policy_name]
~~~

list verifies output contains policy-name；info verifies output contains PolicyName and policy-name。Build cleanup_steps explicitly by id instead of relying on Enum.slice offsets.

- [ ] **Step 4: Add the committed live-test fixture with apply_patch**

Create test/fixtures/admin/policy_s1_live.json with exactly:

~~~json
{"Version":"2012-10-17","Statement":{"Effect":"Allow","Action":"s3:GetObject","Resource":"arn:aws:s3:::s1-live/*"}}
~~~

The file is public test data only; production code never reads it.

- [ ] **Step 5: Run external-smoke GREEN**

Run:

~~~powershell
Remove-Item Env:PGPORT -ErrorAction SilentlyContinue
$env:ERL_FLAGS='-kernel standard_io_encoding unicode'
$env:ELIXIR_ERL_OPTIONS='+S 2:2 +A0 +sbwt none +sbwtdcpu none +sbwtdio none'
mix test test/maxio/compat/external_smoke_test.exs
mix compile --warnings-as-errors
~~~

Expected: PASS and zero warnings.

- [ ] **Step 6: Update README support matrix and operator notes**

Document:

- exact four supported routes/commands and 200 semantics；
- empty fresh policy list, no automatic MinIO built-in seed；
- same-name create creates a new default version and can reach the five-version quota；
- remove never cascades attachments and refuses non-default versions；
- only path=/ policies are visible through mc；admin CLI exposes omitted policies；
- policy attach/detach/entities, user/group and encrypted endpoints still return 501；
- path-style endpoint requirement and admin requests not counted as S3 bucket=minio telemetry。

- [ ] **Step 7: Run focused docs/format checks and commit**

Run:

~~~powershell
Remove-Item Env:PGPORT -ErrorAction SilentlyContinue
$env:ERL_FLAGS='-kernel standard_io_encoding unicode'
$env:ELIXIR_ERL_OPTIONS='+S 2:2 +A0 +sbwt none +sbwtdcpu none +sbwtdio none'
mix test test/maxio/compat/external_smoke_test.exs test/maxio/admin/policy_endpoint_test.exs
mix format --check-formatted
git diff --check c18b20b..HEAD
~~~

Expected: PASS; no whitespace errors.

~~~powershell
git add lib/maxio/compat/external_smoke.ex test/maxio/compat/external_smoke_test.exs test/fixtures/admin/policy_s1_live.json README.md
git commit -m "test(admin): cover policy lifecycle with mc smoke"
~~~

---

### Task 8: Independent code review, verification, STATUS and handoff

**Files:**

- Review: all commits from Task 1 through Task 7
- Modify only if findings are returned: files named by the finding
- Modify after evidence exists: docs/superpowers/STATUS.md

**Lanes:** Fresh code-review subagent reviews read-only and never fixes its own findings. After approval, a second fresh verification subagent runs focused/full/live gates. Both are distinct from the spec reviewer and implementation author.

- [ ] **Step 1: Give reviewer exact review boundary**

Run:

~~~powershell
git log --oneline --decorate --max-count=12
$expectedBase='c18b20bce346ca8400015bc957f8c497c4659b90'
if ((git merge-base HEAD origin/master) -ne $expectedBase) { throw "unexpected branch point" }
git diff --stat c18b20b..HEAD
git diff c18b20b..HEAD
~~~

Record c18b20bce346ca8400015bc957f8c497c4659b90 in the review request. origin/master is used only to confirm the merge-base and may advance after the branch is created. If the assertion fails, stop and ask the coordinating agent to refresh the plan/review base; do not infer another range.

Reviewer must check:

1. all verified wire facts and exact 200/JSON/body behavior；
2. PolicyAdapter has no Repo/Store/Ecto dependency；
3. body length/framing and 20,480 boundary；
4. exact action authorization and 403-before-501；
5. root path filtering, version preservation, delete blockers；
6. control-plane telemetry isolation without vhost object hijack；
7. logs/CLI do not expose policy body or credentials；
8. tests prove behavior rather than implementation details。

- [ ] **Step 2: Return findings with severity and evidence**

Each finding contains file, line, reproduction command, expected/actual behavior and architectural impact. “No findings” is acceptable only after reviewer runs the focused gate from Task 5 Step 7 and inspects the diff.

- [ ] **Step 3: Route fixes back to the implementation lane**

Implementation author first reproduces every accepted finding with a failing focused test, then applies the architectural fix and runs the focused test green. Reviewer never edits implementation.

- [ ] **Step 4: Commit review fixes as one coherent checkpoint**

~~~powershell
$reviewFixFiles=git status --porcelain=v1 | ForEach-Object { $_.Substring(3) }
if ($reviewFixFiles.Count -eq 0) { throw "no review-fix files to commit" }
$reviewFixFiles | ForEach-Object { git add -- $_ }
git commit -m "fix(admin): address policy S1 review findings"
~~~

If there are no findings, omit this commit. Before staging, compare reviewFixFiles with the accepted-finding file list and stop on any extra path; never run git add -A.

- [ ] **Step 5: Reviewer rechecks the final diff**

Reviewer reruns only the affected focused tests plus:

~~~powershell
Remove-Item Env:PGPORT -ErrorAction SilentlyContinue
$env:ERL_FLAGS='-kernel standard_io_encoding unicode'
$env:ELIXIR_ERL_OPTIONS='+S 2:2 +A0 +sbwt none +sbwtdcpu none +sbwtdio none'
mix test test/maxio/admin test/maxio/s3/admin_surface_classification_test.exs test/mix/tasks/maxio_admin_policy_test.exs test/maxio/compat/external_smoke_test.exs
git diff --check c18b20b..HEAD
~~~

Expected: PASS and final verdict APPROVED with no unresolved finding.

- [ ] **Step 6: Verification lane runs the coherent focused gate**

~~~powershell
Remove-Item Env:PGPORT -ErrorAction SilentlyContinue
$env:ERL_FLAGS='-kernel standard_io_encoding unicode'
$env:ELIXIR_ERL_OPTIONS='+S 2:2 +A0 +sbwt none +sbwtdcpu none +sbwtdio none'
mix test test/maxio/admin test/maxio/s3/admin_surface_classification_test.exs test/mix/tasks/maxio_admin_policy_test.exs test/maxio/compat/external_smoke_test.exs
mix compile --warnings-as-errors
mix format --check-formatted
git diff --check c18b20b..HEAD
~~~

Expected: every command exits 0; compile has zero warnings.

- [ ] **Step 7: Run full precommit exactly once**

~~~powershell
Remove-Item Env:PGPORT -ErrorAction SilentlyContinue
$env:ERL_FLAGS='-kernel standard_io_encoding unicode'
$env:ELIXIR_ERL_OPTIONS='+S 2:2 +A0 +sbwt none +sbwtdcpu none +sbwtdio none'
mix precommit
~~~

Expected: exits 0. Do not rerun it unless a subsequent fix changes code; if code changes, rerun focused tests first, then one replacement final precommit.

- [ ] **Step 8: Start maxio and configure a real mc alias**

Use the repository’s documented local Postgres setup. Start the server in one PowerShell:

~~~powershell
Remove-Item Env:PGPORT -ErrorAction SilentlyContinue
$env:ERL_FLAGS='-kernel standard_io_encoding unicode'
$env:ELIXIR_ERL_OPTIONS='+S 2:2 +A0 +sbwt none +sbwtdcpu none +sbwtdio none'
mix phx.server
~~~

Expected: the endpoint listens on the configured local port and remains running. In a second PowerShell:

~~~powershell
mc alias set maxio http://127.0.0.1:9000 $env:MAXIO_ROOT_USER $env:MAXIO_ROOT_PASSWORD
mc --debug admin info maxio
~~~

Expected: alias succeeds and existing admin info returns JSON-backed output. If required environment variables are absent, report a BLOCKED live gate with their names; do not invent credentials.

- [ ] **Step 9: Run the real mc S1 lifecycle**

Use a policy JSON fixture added with apply_patch under test/fixtures/admin/policy_s1_live.json for this gate, then run:

~~~powershell
$policyName="s1-live-$([DateTimeOffset]::UtcNow.ToUnixTimeSeconds())"
$policyFile=(Resolve-Path -LiteralPath "test/fixtures/admin/policy_s1_live.json").Path
mc --debug admin policy create maxio $policyName $policyFile
mc --debug admin policy ls maxio
mc --debug admin policy info maxio $policyName
mc --debug admin policy rm maxio $policyName
~~~

Expected:

- create/ls/info/rm all exit 0；
- list contains policyName；
- info displays nonempty PolicyName plus Policy/CreateDate/UpdateDate；
- server logs show the four admin actions and never policy body；
- maxio.admin.policy.list/show agree with mc before removal；
- request metrics/access-log evidence contains no admin row attributed to bucket minio。

The fixture contains only a public test policy document and is committed with Task 7; do not generate a live fixture with a shell write command.

- [ ] **Step 10: Run the automated external smoke**

With MAXIO_COMPAT_ENDPOINT、MAXIO_COMPAT_ACCESS_KEY、MAXIO_COMPAT_SECRET_KEY configured:

~~~powershell
Remove-Item Env:PGPORT -ErrorAction SilentlyContinue
$env:ERL_FLAGS='-kernel standard_io_encoding unicode'
$env:ELIXIR_ERL_OPTIONS='+S 2:2 +A0 +sbwt none +sbwtdcpu none +sbwtdio none'
mix maxio.compat.matrix --include-external-smoke --external-smoke-client minio_mc
~~~

Expected: minio_mc status=ok and scenario_counts.admin_policy_lifecycle=4. If mc or required env is unavailable, record the exact blocker; unit/endpoint green is not a substitute for claiming live compatibility.

- [ ] **Step 11: Update and commit STATUS only after all review and verification evidence**

Implementation lane may edit docs/superpowers/STATUS.md only after: independent review is APPROVED (Steps 1-5), focused verification is green (Step 6), precommit is green (Step 7), and live mc plus external smoke have either passed or produced exact external blockers (Steps 8-10). Add:

- completed S1 routes/actions；
- verified Content-Length/20,480/v2/no-v/bucket-501 facts；
- root-path/version/delete deliberate semantics；
- control-plane telemetry fix；
- focused test、compile、format、precommit result；
- real mc/external-smoke evidence or exact live blocker；
- remaining 501 families and next recommended envelope/user-policy batch。

Do not mark live mc complete when Steps 8-10 are blocked. Commit the evidence-backed status:

~~~powershell
git add docs/superpowers/STATUS.md
git commit -m "docs(status): record admin policy S1 evidence"
~~~

- [ ] **Step 12: Independently review the committed STATUS and full branch range**

The independent reviewer checks the committed STATUS against captured commands and the fixed branch range:

~~~powershell
git diff c18b20b..HEAD -- docs/superpowers/STATUS.md
git diff --check c18b20b..HEAD
git status --short
~~~

Expected: STATUS claims exactly the captured evidence, range check exits 0, and status is empty. If wording needs correction, the implementation lane uses apply_patch, commits a docs-only correction, and the same reviewer reruns this fixed-range check.

- [ ] **Step 13: Final clean-tree and push checkpoint**

Run:

~~~powershell
git status --short --branch
git log --oneline --decorate --max-count=12
git remote -v
~~~

Expected: branch is codex/admin-policy-s1 and worktree is clean. Present commit list, independent review verdict, focused/full verification and live evidence to the coordinating/root agent.

Only after the coordinating agent authorizes publication:

~~~powershell
git push -u origin codex/admin-policy-s1
~~~

Expected: push succeeds to origin and the reported remote branch is codex/admin-policy-s1. Do not merge, rebase, force-push or open a PR unless separately authorized.

---

## Final acceptance checklist

- [ ] Independent spec reviewer returned GO before implementation.
- [ ] Four exact v3 policy routes use exact actions and strict HTTP 200 success.
- [ ] AddCannedPolicy accepts raw JSON without Content-Type and enforces positive Content-Length.
- [ ] 0/missing/chunked lengths produce MissingContentLength/411.
- [ ] 20,480 bytes are read; 20,481 bytes fail before IAM mutation.
- [ ] v2 emits exactly PolicyName/Policy/CreateDate/UpdateDate with nonempty PolicyName.
- [ ] no-v/v="" emits a raw JSON policy object; unknown nonempty v is 400.
- [ ] list-canned-policies?bucket= is authenticated 501.
- [ ] Empty, Unicode-edge-whitespace, comma and dot path-segment names are explicitly rejected.
- [ ] list only exposes path=/ policies and CLI reports omitted non-root policies.
- [ ] Same-name create preserves history through a new default version.
- [ ] The sixth version returns :policy_version_limit_exceeded and version inspection uses is_default_version.
- [ ] Attached/versioned remove fails without cascading permission or deleting versions.
- [ ] Public IAM validation plus root-target round-trip prevents create/info/remove from addressing hidden non-root policies through slash or backslash names.
- [ ] PolicyAdapter has no Repo/Store/Ecto dependency.
- [ ] Admin control-plane creates neither S3 metric nor bucket access-log attribution to minio.
- [ ] Ordinary S3 and vhost same-path objects retain existing observation/routing.
- [ ] Independent code reviewer returned APPROVED with no unresolved finding.
- [ ] The reviewed plan is the first commit after c18b20b and every review/diff uses c18b20b..HEAD.
- [ ] Focused gate, warnings-as-errors, format, diff check and one final mix precommit pass.
- [ ] Real mc lifecycle and external smoke pass, or STATUS records a precise external blocker without claiming live completion.
- [ ] STATUS is written only after review, focused verification, precommit and live/smoke evidence; final commits are reviewed and push occurs only after authorization.
