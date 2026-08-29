# MinIO Admin Config `help-config-kv` S6 设计

> 状态：待独立 design review。本文只冻结 S6 `help-config-kv` 协议与架构，
> 不改写 S5 已冻结的 get/set/reset 行为。

## 1. 目标与裁决

S6 实现 MinIO Admin v3 `help-config-kv`，使 pinned native `mc` 的以下路径得到
可用的三项 Maxio extension 帮助：

- `mc admin config get ALIAS`；
- `mc admin config reset ALIAS`；
- `mc admin config set ALIAS SUBSYSTEM [KEY]` 中未出现 `=` 的 help 分支。

采用方案 A：**Registry 是唯一有序 wire catalog，Schema 是 type/env binding 唯一真相，
新建纯 `Maxio.Admin.ConfigKV.Help` 做静态投影**。HTTP 和一方 Mix CLI 共用同一
投影与 exact encoder。

拒绝两个备选方案：

1. 独立静态 help map：会复制 Registry 的 wire/core path 和 Schema 的 type/env，无法
   从架构上防止漂移。
2. 让 Adapter/Config/Repo 生成 help：会把静态 capability catalog 错误地变成 DB/runtime
   查询，并增加 value/default/source 泄漏面。

## 2. Pinned 上游事实

协议研究固定以下身份：

- MinIO `7aac2a2c5b7c882e68c1ce017d8256be2feea27f`；
- madmin-go `4b504b82db633e978a57d49443b2be75824244c3`；
- mc `77f82e18b5401a65958f1619df6ebb994634bd88`。

已由 pinned 源码确定：

- MinIO 路由是 `GET /minio/admin/v3/help-config-kv`，route matcher 要求 `subSys`、`key`
  两个 query 名均存在；
- handler 要求 `admin:ConfigUpdate`；
- handler 返回 plaintext JSON，不使用 madmin SIO；
- madmin `Help` decoder 启用 unknown-field rejection；
- madmin 使用 GET 请求 exact `/minio/admin/v3/help-config-kv`，总是发送 `subSys`
  与 `key` query，只在 env option 为 true 时附加 `env`；
- madmin help request 以 empty-payload SHA-256
  `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855` 写入
  `X-Amz-Content-Sha256`，并发送 SigV4 `Authorization`；request 无 body、SIO、
  Content-Length、Transfer-Encoding 或 Content-Type；
- `env` 是可选 presence flag；
- 空 subsystem 返回 top-level catalog，并在 upstream 的 early-return 分支中忽略
  nonempty key；
- pinned upstream 支持 `subsystem:target`，而 Maxio S5 已明确把 target 列为 non-goal。

S6 新建自己的 pinned fixture；`test/fixtures/minio_admin_config_kv_s5/` 是历史快照，
不得修改其当时的 `help-config-kv` unsupported 结论。
新 fixture 必须对 MinIO server raw HelpKV order、madmin client struct/re-encode order、上述
request/signing/framing 事实同时记录 pinned identity、source file/symbol/range、raw source
SHA-256 与 exact excerpt SHA-256，不得仅记录二手结论。

## 3. 组件边界

### 3.1 `Maxio.Admin.ConfigKV.Registry`

Registry 继续是 Admin Config KVS 对外暴露边界。它的单一有序声明包含：

- subsystem wire name、稳定公开 description、order；
- entry wire/core subsystem/key 映射；
- entry 稳定公开 description、`optional?`、`sensitive?`、order；
- `multiple_targets?` 在本批永远为 `false`。

应从该声明派生已有 flat `entries/0`，不应再创建第二份 subsystem/key
catalog。新增 `subsystems/0` 与 `classify_subsystem/1`；保留 S5 已使用的
`entries/0`、`exposed_subsystem/1`、`classify_path/2` 语义。

Registry 必须 fail closed：

- exposed wire/core path 唯一；
- 每个 entry 恰好属于一个 subsystem；
- 每个 core path 必须存在于 `Maxio.Config.Schema`；
- hidden/forbidden 项不得出现在任何 catalog 枚举中；
- sensitive entry 不得出现在 help，即使未来其它 Config KVS surface 允许它。

### 3.2 `Maxio.Admin.ConfigKV.Help`

Help 是无状态纯模块，唯一公开查询接口为：

```elixir
@spec project(String.t(), String.t(), boolean()) ::
        {:ok,
         %{
           wire: Jason.OrderedObject.t(),
           subsystem: String.t(),
           key_count: non_neg_integer(),
           scope: :catalog | :subsystem | :key,
           env_only?: boolean()
         }}
        | {:error,
           %{
             reason: term(),
             subsystem: String.t(),
             key_count: non_neg_integer(),
             stage: :parser | :exposure
           }}
def project(sub_sys, key, env_only?)

@spec encode_line(Jason.OrderedObject.t()) :: iodata()
def encode_line(wire)

@spec describe_error(term()) :: String.t()
def describe_error(reason)
```

`encode_line/1` 输出 compact UTF-8 JSON 加恰好一个 LF。Help 不接受 repo/store/config
dependency injection option，不能 alias/call `Adapter`、`Parser`、`Request`、`Maxio.Config`、
`Maxio.Repo` 或 Ecto。

成功 evidence 的值也固定：

- top-level：`subsystem: "all"`、`scope: :catalog`、`key_count: 3`；
- subsystem：`subsystem` 为已知 safe wire name、`scope: :subsystem`、`key_count` 为实际
  `keysHelp` 数；
- direct key：`scope: :key`、`key_count: 1`；
- 已知且 nonempty subsystem 的 env-only 过滤结果：`scope: :subsystem`、
  `key_count: 0`；empty `subSys` 无论 env 是否存在都是 top-level `:catalog` 且
  `key_count: 3`；
- `env_only?` 与请求 presence 布尔值一致。

错误 evidence 的 `key_count` 固定为 0；target syntax 为 `stage: :parser`，其它 catalog/
Schema/exposure 拒绝为 `stage: :exposure`。`subsystem` 只能是已知 wire name、通过安全
identifier 判定的公开输入，或 `"unknown"`；敏感/非法原文不得进入 evidence。

### 3.3 HTTP 与 CLI

`Maxio.Admin.Plug` 只新增 exact dispatch/handler，不改 S3 Endpoint、SigV4、Authz 或 core
request pipeline。handler 负责 query presence、授权、结构化日志与 response framing；
投影及 JSON 字节由 Help 负责。

`mix maxio.admin.config.help [--env] [subsystem [key]]` 直接调用同一 Help 接口，
并把 exact JSON+LF 写到 stdout。该任务不调用 `Maxio.Config.CLI.boot/0`，因此
Postgres 不可用时仍可诊断静态 catalog。本批不实现第二套 human renderer。

## 4. Exact route、query 与 precedence

### 4.1 Route

唯一新路由：

```text
GET /minio/admin/v3/help-config-kv?subSys={subsystem}&key={key}[&env=]
```

- method/path 必须 exact；wrong method、v4、adjacent suffix 继续 501。
- `subSys` 和 `key` 两个 query 名必须都存在；空字符串是有效值。
- `env` 按 URL query 名是否存在解释，`env`、`env=`、`env=false` 都是 true。
- native madmin 只发单次 `subSys`/`key`；重复参数沿用 Plug 现有 decode 规则，
  S6 不自造 raw query parser，也不声称对非 madmin 重复参数的兼容性。

### 4.2 处理顺序

顺序必须固定为：

1. 全局 Admin authentication；anonymous 立即 403，不暴露 route/query 差异。
2. exact method/path dispatch。
3. `subSys`/`key` presence；已认证但缺任一名时 426，此时不进行
   `admin:ConfigUpdate` 判定。
4. `admin:ConfigUpdate` authorization；拒绝时不观察 subsystem/key/env 语义。
5. target syntax rejection。
6. forbidden/hidden/exposed/unknown 分类；forbidden 先于 unknown。
7. Schema type/env 投影。
8. exact encode/framing。

## 5. Exact plaintext JSON schema

madmin 会拒绝 unknown field，所以 wire 对象必须且只能包含以下字段，
且 encoder 按此顺序输出。

Top-level `Help` 字段顺序：

1. `subSys`
2. `description`
3. `multipleTargets`
4. `keysHelp`

Pinned MinIO server 的 raw `HelpKV` JSON 字段顺序是：

1. `key`
2. `type`
3. `description`
4. `optional`
5. `multipleTargets`

madmin `HelpKV` struct 的客户端 re-encode 顺序是：

1. `key`
2. `description`
3. `optional`
4. `type`
5. `multipleTargets`

Maxio 选择第二种 **madmin-client order** 作为自身 direct raw success body 的稳定
顺序。这是相对 pinned MinIO server raw bytes 的 deliberate raw-wire ordering deviation；
madmin decoder 按字段名解码，所以 native mc 不受影响。S6 fixture 必须同时冻结
server raw order 与 madmin struct/client re-encode order，测试不得把两者写成同一
claim。下文 Maxio JSON 示例使用 madmin-client order。

不得添加 `default`、`value`、`runtime`、`source`、`version`、`apply`、`envVar`、
`sensitive`、`secret` 或 Maxio extension marker 字段。

### 5.1 Top-level catalog

`subSys=&key=` 的语义对象为：

```json
{
  "subSys": "",
  "description": "",
  "multipleTargets": false,
  "keysHelp": [
    {
      "key": "s3",
      "description": "Maxio extension: configure s3.clock_skew_ms.",
      "optional": false,
      "type": "",
      "multipleTargets": false
    },
    {
      "key": "listing",
      "description": "Maxio extension: configure listing.sql_hard_limit.",
      "optional": false,
      "type": "",
      "multipleTargets": false
    },
    {
      "key": "prometheus_metrics",
      "description": "Maxio extension: configure prometheus_metrics.public.",
      "optional": false,
      "type": "",
      "multipleTargets": false
    }
  ]
}
```

实际 HTTP/CLI body 是上述对象的 compact JSON，紧随一个 LF；不包含缩进或
CRLF。`subSys=&key=anything` 返回同一 top-level catalog。

### 5.2 Subsystem 与 key catalog

公开顺序与值固定为：

1. `s3.clock_skew_ms`
   - subsystem description: `Maxio extension: configure s3.clock_skew_ms.`
   - key description: `Maximum allowed SigV4 header-signature clock skew in milliseconds; applied to the next authentication request.`
   - `optional: true`
   - type 由 `Schema.describe_type/1` 投影，exact 为 `integer in 0..3600000`
   - `multipleTargets: false`
2. `listing.sql_hard_limit`
   - subsystem description: `Maxio extension: configure listing.sql_hard_limit.`
   - key description: `Hard upper bound on rows fetched by one SQL-backed listing operation; applied to the next listing request.`
   - `optional: true`
   - exact type `integer in 1..10000000`
   - `multipleTargets: false`
3. `prometheus_metrics.public`
   - subsystem description: `Maxio extension: configure prometheus_metrics.public.`
   - key description: `Allow unauthenticated access to the Prometheus metrics endpoint; enable only behind a trusted network or proxy.`
   - `optional: true`
   - exact type `boolean`
   - `multipleTargets: false`

`subSys=s3&key=` 返回 s3 subsystem 对象与其唯一 `HelpKV`；
`subSys=s3&key=clock_skew_ms` 返回字节级相同的对象。另两个 subsystem
同理。未来 subsystem 有多个 key 时，direct-key 只留指定 `HelpKV`。

## 6. Schema、env、default、runtime 与 sensitivity

- Registry 只决定“能否暴露”、wire/core 映射、稳定公开文案和顺序。
- `type` 必须通过 Registry 中的 core atoms 调用 Schema；不对 user input 使用
  `String.to_atom/1`。
- `env` binding 必须读 `Schema.env_var/2`，不按 wire name 猜测或合成。
- Schema 已明确将 compile defaults 留在 `config/*.exs` 作唯一真相；help 不复制
  default，也不读 `Application.get_env/3`。
- help 不读 authoritative/effective/runtime value、source、version、audit 或 apply outcome。
- `sensitive?` 只是服务端 fail-closed filter，绝不进入 JSON。当前三项全部为
  false。
- `cluster.deployment_id`、root/access-key secret、SSE/KMS/MFA 密钥、Repo、
  storage/credential/policy backend 和 Schema forbidden surface 不枚举、不描述。

### 6.1 `env` deliberate deviation

当前三个 exposed Schema entry 的 `env_var` 均为 `nil`。Maxio 不会复制 pinned MinIO
的名称合成，因为这会宣称并不存在的 backend binding。固定行为：

- top-level `subSys=&key=&env=` 仍返回三 subsystem catalog；
- top-level `subSys=&key=&env=false` 也返回同一三 subsystem catalog，因为 `env`
  按 presence 而非布尔文本解释；
- subsystem `subSys=s3&key=&env=` 返回正常 s3 metadata，但 `keysHelp: []`；
- direct unbound key `subSys=s3&key=clock_skew_ms&env=` 返回 400
  `XMinioConfigError`；
- 未来只有 Registry-exposed 且 `Schema.env_var/2` 非 nil 的 entry 才能在 env-only
  subsystem/key help 中出现，其 `HelpKV.key` 是 exact env variable name。

这是明确的 compatibility repair/deviation，必须在 fixture、README 和 strict-live 结论中
如实标注。

## 7. Target 与 catalog 限制

- 任何 nonempty `subSys` 含 `:` 时，在授权后返回 400
  `XMinioAdminInvalidArgument` / `Invalid arguments specified.`
- 不 strip target，不返回 target metadata，不伪造 `enable` key。
- `multipleTargets` 在所有 Help/HelpKV 对象中固定为 false。
- catalog 恰好是三个 Maxio extension；不引入 MinIO official full catalog。

## 8. Auth 与 error contract

### 8.1 Auth

- exact action：`admin:ConfigUpdate`。
- root/static identity 只按现有 Admin authz 规则授权。
- STS/session policy、bucket policy 不能授予 Admin ConfigUpdate。
- 完整 query 但 action denied 的 error 必须与 S5 Config KVS 一致：403
  `AccessDenied` / `Access Denied.`

### 8.2 Error matrix

- anonymous：403 `AccessDenied` / `Access Denied`，走全局 concealment。
- authenticated wrong/adjacent route：501 `NotImplemented`。
- authenticated missing `subSys` or `key`：426 `XMinioAdminVersionMismatch` /
  `This 'admin' API is not supported by server in 'maxio'`。
- complete query but action denied：403 `AccessDenied` / `Access Denied.`
- target syntax：400 `XMinioAdminInvalidArgument` / `Invalid arguments specified.`
- safe unknown subsystem：400 `XMinioConfigError` / `unknown sub-system SUBSYSTEM`。
- safe unknown key：400 `XMinioConfigError` /
  `unknown key KEY for sub-system SUBSYSTEM`。
- direct env-only unbound key：与 safe unknown key 相同。
- forbidden subsystem/path：403 `AccessDenied` / `Access Denied.`
- wire-hidden/unsafe identifier：400 generic `XMinioConfigError` /
  `Configuration specified is invalid`；不回显 hidden path 或敏感标识符。
- invalid Help evidence shape、意外 exception 或 Schema-Registry invariant 失效：500
  `InternalError`，结构化日志记录
  safe stage，不向 client 序列化 exception/reason。

`ErrorMap` 可仅增加 exact `unknown key ... for sub-system ...` safe-description 模式；
key/subsystem 必须各自通过现有 safe identifier 与 sensitive-marker 过滤。不得放宽为
任意动态 message。

所有错误继续使用现有 Admin `ErrorView`：compact JSON 且恒有 `Code`、`Message`、
`Resource`、`RequestId`、`HostId` 五字段，不加 LF，不加 SIO。Error response
framing 固定为 `Content-Type: application/json; charset=utf-8`、`Content-Length` 精确等于
compact JSON 字节数、无 `Transfer-Encoding`、无 `Content-Encoding`。S6 不创建
help 专用 error renderer，不改这份现有 Admin error contract。

## 9. Request/response framing

### 9.1 Request

- GET body 为空；handler 绝不 `read_body`。
- Maxio signed endpoint test 只证明 Maxio 接受无 Content-Length、Transfer-Encoding、
  Content-Type 与 body 的 request entity matrix；它不能证明 native madmin 实际发包。
- Native madmin 实际发出无 Content-Length、Transfer-Encoding、Content-Type/body/SIO
  的 GET，由 pinned madmin source fixture 与 pinned native request capture 共同证明。
- 不要 caller signing secret，不 decrypt，不经 `ConfigKV.Request`。

### 9.2 Success response

- status 200。
- body 是 compact plaintext UTF-8 JSON + exact one LF。
- `Content-Type: application/json`。
- `Content-Length` 显式等于 JSON+LF 字节数。
- 删除 `Transfer-Encoding` 与 `Content-Encoding`。
- 不加 `x-minio-config-applied`。
- 不压缩，不加 SIO envelope。

`application/json` 和无 gzip 是 Maxio 稳定 framing deviation：不依赖 upstream
`net/http` sniffing/gzip middleware 的偶然结果。

## 10. 结构化日志

成功日志：

- message: `admin config help projected`
- `action` / `admin_action`: `admin_config_help`
- `required_action`: `admin:ConfigUpdate`
- `config_subsystem`: top-level 为 `all`，其余为安全 subsystem label
- `config_key_count`: top-level 无论 env presence 都为 3，subsystem/key 为返回
  `HelpKV` 数，已知 nonempty subsystem 的 env-only 过滤结果可为 0
- `config_changed_count`: 0
- 现有 request id、principal ARN、access key id、auth type、surface

失败日志使用 `admin config request failed`，`config_failure_stage` 只能是
`:parser` 或 `:exposure`。意外 handler exception 沿用 Config KVS boundary 并记录已允许的
safe stage。

不记录 description、wire JSON、raw query、default/value/source/env value、caller secret 或
Authorization。上述字段已在现有 metadata allowlist，本批不扩大 logger allowlist。

## 11. CLI contract

```text
mix maxio.admin.config.help [--env] [subsystem [key]]
```

- 0 positional args：top-level。
- 1 positional arg：subsystem。
- 2 positional args：direct key。
- unknown option 或 3+ positional args：`Mix.raise/1` 固定 usage。
- `--env` 映射为 `env_only? = true`。
- stdout 是与 HTTP body 相同的 compact JSON+LF；成功时无 stderr。
- usage exact 为 `usage: mix maxio.admin.config.help [--env] [subsystem [key]]`。
- error 通过 `Help.describe_error/1` 输出以下稳定、经脱敏的 Mix error：
  - invalid argument：`configuration help request is invalid`；
  - forbidden path：`configuration help path is not exposed`；
  - ConfigError/unknown/unbound env key：`configuration help entry was not found`；
  - 任何非预期 reason：`configuration help failed`。
  不输出
  `%Ecto{}`、exception 或 raw term。
- 不 boot Repo，不产生 audit/runtime mutation。

## 12. External smoke 与 strict live

### 12.1 Fake-runner 证据

human 与 JSON 模式必须使用不同 alias/scenario，精确观察 argv：

- `mc admin config get ALIAS`；
- `mc admin config reset ALIAS`；
- `mc admin config set ALIAS s3`；
- `mc admin config set ALIAS s3 clock_skew_ms`。

它必须证明 alias-only get/reset 调用 help，没有调用 get/delete mutation。human 断言
三个 subsystem 与具体 Maxio extension key 文案；JSON 断言 compact exact bytes + LF。
fake runner 只是 orchestration test，不得写成 live 兼容性结论。

### 12.2 Strict pinned live

忽略目录 `artifacts/admin-config-help-s6/2026-08-29-live/` 记录：

- native `mc` version/hash 与 pinned commit 关联；
- Maxio HEAD、endpoint、隔离 alias/config dir；
- alias-only get/reset human exact stdout/stderr/exit；
- alias-only get/reset `--json` exact stdout/stderr/exit；
- subsystem/key set-help human/JSON；
- direct signed request 的 auth/query/error precedence 与 plaintext framing；
- `env` top-level/subsystem/direct-key deviation；
- 请求实际命中 help route，未命中 get/delete；
- `runtime_configs`、`runtime_config_audits` 无变化。

缺 pinned mc、endpoint、credentials 或可观测 request capture 时，对应探针标为
`BLOCKED`，不能用 fake/fixture 代替 PASS。

活体证据的失效规则是 contract 的一部分：在 V-H1/V-H2 关闭过程中，任何
fixture 或 test 修正都使其受影响的 pinned-MinIO/native-mc capture 与比较失效，
必须重跑相应 live probe。任何 production 修正还使相关 Maxio native capture、
direct success/error framing、auth/route 与 runtime/audit no-mutation 证据失效，必须重跑并
用 replacement artifact 取代已标记 `superseded` 的旧证据。

## 13. `VERIFY-AT-IMPL`

只保留必须由直接捕获关闭的两项：

1. **V-H1 env upstream classification**：pinned MinIO handler 表面上直接读 `r.Form`，
   但该函数内未见 `ParseForm`。对 pinned MinIO 发送无 env、`env`、`env=`
   和 `env=false` 的
   直接请求，捕获 actual catalog，然后将 Maxio 行为如实分类为 match 或
   deliberate repair/deviation。无论 upstream 捕获结果如何，Maxio 不伪造当前不存在的
   env binding。
2. **V-H2 native rendering bytes**：用 pinned native mc 非 TTY/no-color 捕获 alias-only、
   subsystem、key 的 human 和 `--json` stdout/stderr/exit，冻结 tabwriter spacing、LF/Windows
   CRLF 处理和 JSON wrapper 字段顺序。fixture-derived expected transcript 不能关闭本项。

Maxio success Content-Type/CL/TE/CE 已在本设计中作为稳定 deliberate framing 固定，
不是待决策 VERIFY。

## 14. Non-goals

- 不改 S5 get/set/reset route、SIO、parser、Adapter 或 mutation semantics。
- 不实现 full config export/import、history list/clear/restore、service restart。
- 不实现 named targets、`subsystem:` 或 `subsystem:target`。
- 不实现 MinIO official full catalog。
- 不暴露 secrets、deployment identity、backend bindings 或 hidden/forbidden Schema 项。
- 不新增 env binding、default 字段或 runtime value 投影。
- 不访问 Repo，不新增 migration、transaction、lock、audit、broadcast 或多节点协调。
- 不修改 S3 Endpoint、SigV4、Authz core pipeline 或 logger metadata allowlist。
- 不在 Mix CLI 复制 mc human renderer。
- 不把 source fixture、fake runner 或 expected transcript 冒充 strict-live evidence。

## 15. 完成判据

S6 只在以下条件全部满足时完成：

- pinned fixture 与源码 hash/provenance 通过独立 research review；
- fixture research 与 ExUnit/RED test authoring 由不同 agent/context 承担；Registry/Help/
  HTTP/ErrorMap/CLI/smoke 的 RED 测试先于 production GREEN；
- 每个 implementation task 由非作者 reviewer 通过；
- protocol 与 architecture/security 两个 whole-range review 都无 Critical/Important；
- focused suites、`mix compile --warnings-as-errors`、changed-file format、`git diff --check`
  通过；
- strict pinned mc 完成 V-H1/V-H2，或对每个缺失能力给出诚实 `BLOCKED`；
- 所有 code/test/README 结论稳定后只跑一次最终 `mix precommit`；其后如修改
  code/test，旧门禁立即失效；
- STATUS 由独立 closeout lane 只按实际证据更新，并通过 STATUS-only review；
- diff 无 Parser/Adapter/Request/Envelope/Config/Schema behavior/Repo/migration/core pipeline 变更；
- clean worktree 经 `--ff-only` 集成，feature/master 两个 ref 原子 push。
