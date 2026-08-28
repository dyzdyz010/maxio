# MinIO Admin Config KVS 设计修订 —— 原子子系统批次与 Maxio 运行时配置投影

> 日期：2026-08-29
>
> 状态：已选方案 A 的冻结设计；本文只定义设计，不含实现计划或实现代码
>
> 基线：`fa79864836379607e632d109c302387cb0a8f523`
>
> 上位准则：`AGENTS.md`、`CLAUDE.md`
>
> 修订对象：`2026-08-18-minio-admin-surface-design.md`

---

## 0. 本修订的权威范围

本文冻结 `mc admin config get/set/reset` 的第一批可交付契约。它采用方案 A：

1. 对 madmin 的 v3 路由、SigV4、SIO envelope、成功响应和 `mc` 输出做逐字节兼容；
2. 在 `Maxio.Config` 现有逐键 Postgres 权威之上增加**子系统级原子批次**，不另建配置权威；
3. 只投影已经真实接入 `Maxio.Config` 且确有数据面消费者的三个 Maxio 扩展键；
4. 不把 Maxio 私有语义伪装成 MinIO 的 `api`、`site` 等官方子系统。

### 0.1 对旧设计的显式 supersede

本文仅在 Admin Config KVS 范围内取代旧 spec 的下列裁决；旧 spec 其余部分继续有效：

- **取代 D4 的“每次只写一个键”事务模型**：一次 `mc admin config set/reset` 可携带多个键，
  所有键必须在同一事务里全成或全败；单键入口也必须进入同一写协调器。
- **取代 D5 的“跨键并发无需协调”**：同一子系统的 batch 与单键写必须共用事务级 advisory
  lock；否则不存在行的首写、批量 reset 与单键 set 会产生部分覆盖。
- **取代 D10 的“本批不做 madmin 加密封装”**：`Maxio.Admin.Envelope` 已经存在并经过前序
  Admin 批次互操作验证，本批明确实现加密的 get/set/del Config KVS 三端点。

若本文与上述 D4/D5/D10 有冲突，以本文为准。

### 0.2 兼容性声明

本批完成后可以诚实声明：

> Maxio 支持 `mc admin config get/set/reset` 的 MinIO v3 传输协议，以及三个 Maxio 运行时配置
> 子系统。

不得声明“完整 MinIO config catalog 兼容”。当前三个键没有官方 MinIO KVS 等价项；硬映射成
`api` 或 `site` 会让成功响应承诺一个并不存在的语义，违反“绝不静默失败”。

---

## 1. 固定上游证据

协议以固定 commit 为准，不引用会漂移的 `master`：

- MinIO：`7aac2a2c5b7c882e68c1ce017d8256be2feea27f`
  - `cmd/admin-router.go`
  - `cmd/admin-handlers-config-kv.go`
  - `cmd/admin-handler-utils.go`
  - `cmd/handler-utils.go`
  - `cmd/api-errors.go`
  - `internal/config/config.go`
- madmin-go：`4b504b82db633e978a57d49443b2be75824244c3`
  - `config-kv-commands.go`
  - `parse-config.go`
  - `api.go`
- mc：`77f82e18b5401a65958f1619df6ebb994634bd88`
  - `cmd/admin-config-get.go`
  - `cmd/admin-config-set.go`
  - `cmd/admin-config-reset.go`
  - `cmd/print.go`

固定源码表明：

- 三条端点都使用 `admin:ConfigUpdate`，包括 GET；没有自造只读 action 的空间。
- set/delete 的 body 是以调用者 secret access key 为 password 的 madmin SIO ciphertext。
- GET 的成功 body 同样是 ciphertext，解密后才是 Config KVS 文本。
- madmin 的 `api.go` 只设置 `Content-Length`、`X-Amz-Content-Sha256` 和 SigV4 头，**不设置
  `Content-Type`**。因此本批不得复制其他 Admin 请求的 `application/octet-stream` 门禁。
- MinIO `SubsysInfo.WriteTo` 在最后一个 `key=value` 后仍写一个 ASCII space，再写 LF；mc human
  输出保留该尾空格。
- mc 非 TTY `--json` 经 `printMsg` compact 后只输出单行 JSON + LF，不输出 `MarshalIndent` 的
  pretty 形态。
- `x-minio-config-applied: true` 的含义是“不需要重启”；缺失或任何其他值都被 madmin 解释为
  `restart == true`。
- MinIO 先保存配置、再保存 history，两次对象写不是一个原子事务。Maxio 不复制这个安全缺口，
  见 §7.8。

实现批必须把上述源码、哈希和活体抓包固化到独立 fixture；本文不把未固定的最新版行为当事实。

---

## 2. 交付范围与非目标

### 2.1 本批必须完成

- `GET /minio/admin/v3/get-config-kv?key=...`
- `PUT /minio/admin/v3/set-config-kv`
- `DELETE /minio/admin/v3/del-config-kv`
- 三端点的 `admin:ConfigUpdate` 授权、caller-secret envelope、长度与 payload hash 校验
- 三个扩展子系统的 get/set/reset
- 同一命令内的全量校验、原子提交、逐键审计、一次 reload、一次 checked broadcast
- 管理 GET 的权威读取、稳定 KVS 输出、敏感信息隔离
- 与 HTTP 共用 parser/adapter/coordinator 的本地 Mix CLI
- `Maxio.Compat.ExternalSmoke` 的真实 mc 生命周期与数据面效果取证

### 2.2 明确非目标

- `GET /minio/admin/v3/help-config-kv`
- `GET/PUT /minio/admin/v3/config` 全量 export/import
- config history list/clear/restore API
- `subsystem:target` 命名 target，以及 `subsystem:` 默认 target 拼写
- MinIO 官方 `api`、`site`、`notify_*`、`logger_*`、`identity_*` 等 catalog
- 任何 secret、root credential、KMS/SSE/MFA key、backend/behaviour 绑定的读写
- 完整环境变量注释投影
- `mc admin service restart` 端点
- 新建配置后端 behaviour、第二份配置表、全局配置版本或数据库迁移

这些非目标不得被伪造成功。已认证、已授权的未实现 Admin 路由沿用现有结构化 501；客户端在
本地就拒绝的语法则保持 mc 自己的行为。

### 2.3 help 分流必须被写进测试

固定 mc 的命令分流如下：

- `mc admin config get ALIAS` 调 `help-config-kv`，不调 get；
- `mc admin config set ALIAS SUBSYSTEM` 或任意不含 `=` 的输入调 help，不调 set；
- `mc admin config reset ALIAS` 调 help，不调 delete；
- reset 的任一 tail 参数含 `=` 时由 mc 本地报错，不发 HTTP。

因此本批的可用形态必须带明确 subsystem/key，help 路径仍是 non-goal/501，不能把它误判成
get/set/reset 失败。

---

## 3. 精确 HTTP、鉴权与 envelope 契约

### 3.1 路由表

| 操作 | Method | Path / query | 请求明文 | 成功明文 |
|---|---|---|---|---|
| get | GET | `/minio/admin/v3/get-config-kv?key={subsystem}` | 无 body | 一行 KVS 文本 |
| set | PUT | `/minio/admin/v3/set-config-kv` | `subsystem key=value ...` | 空 body |
| reset | DELETE | `/minio/admin/v3/del-config-kv` | `subsystem [key ...]` | 空 body |

固定 router 的 `.Queries("key", "{key:.*}")` 使缺失与空值走不同路径，必须分别冻结：

- `GET /minio/admin/v3/get-config-kv`（完全没有 `key` 参数）不匹配 handler，落 Admin
  `NotFoundHandler`：HTTP 426、Code `XMinioAdminVersionMismatch`、Description 模板
  `This 'admin' API is not supported by server in '<mode>'`。
- `GET /minio/admin/v3/get-config-kv?key=` 的参数存在且 `.*` 接受空串，会进入 handler；获准
  `admin:ConfigUpdate` 后，空 subsystem 返回 HTTP 400、Code `XMinioConfigError`、Description
  `unknown subsystem: `（冒号后保留一个空格）。

Maxio 继续遵守既有“未认证先 403、不向匿名方暴露路由”的全局 Admin 安全裁决。因此上述 426 是
**已认证请求**的结果；固定 MinIO 的 NotFound route 本身不进入 `validateAdminReq`。这是既有 Admin
surface 的 deliberate security deviation，不是本批新造的 parser 偏差。两种 query 都不能回退
到 help，也不能交给 S3 object dispatch。

### 3.2 鉴权与授权

三条路由都沿用现有 Admin 管线：SurfaceClassifier → SigV4 → Admin.Plug → Admin.Authz。

- 未认证请求先得到 Admin JSON `AccessDenied`，不暴露路由实现状态。
- 认证成功后，三条路由都要求 identity policy action `admin:ConfigUpdate`；root 沿用现有短路。
- Authz 必须先于 query/body/decrypt/parser。无权限调用者即使发送畸形 ciphertext，也只能看到
  `AccessDenied`。
- envelope password 必须是本次 SigV4 已认证 credential 的 caller secret，即
  `conn.assigns.sigv4_context.caller_secret`；不得从 root 配置、环境变量或 access key 再查一份
  可能漂移的 secret。

### 3.3 set/reset framing

固定 MinIO handler 读取 Go 已解析的 `r.ContentLength`，只显式拒绝 `> 262272` 或 `-1`；固定
madmin 总是发送一个 concrete Content-Length。Maxio 在两者交集上再沿用现有控制体安全边界：

1. 必须恰好一个十进制 `Content-Length`；缺失、重复、负值、非十进制、存在
   `Transfer-Encoding` 或值大于 `262272`，都返回 `XMinioAdminConfigTooLarge`。
2. `Content-Length == 0` 可进入读取与解密，随后因 envelope 无效返回
   `XMinioAdminConfigBadJSON`；不能把零长度提前改写成其他错误。
3. 实读字节数必须等于声明长度；不一致映射为 `XMinioAdminConfigBadJSON`。
4. 必须用 SigV4 已认证上下文里的 `signed_payload_sha256` 对 ciphertext 复验；不匹配返回现有
   `XAmzContentSHA256Mismatch`。
5. **不检查 Content-Type**。缺失、任意值或多值都不能仅因 Content-Type 被拒绝。
6. body 是至多 262272 字节的小控制体，可经 `Maxio.S3.ControlBody` 有界整读；这不放宽对象
   body 必须流式的铁律。

“必须恰好一个显式 Content-Length”比固定 Go handler 对手写 raw HTTP 的可见行为更严格，是
一项**deliberate framing safety deviation**；它不影响 madmin/mc。缺失/重复 length 的 upstream
与 Maxio 结果必须纳入 protocol fixture，不能被描述成完全相同的上游 parser 行为。

### 3.4 envelope 与响应

- set/reset：有界读取 ciphertext → 校验 payload hash → `Envelope.decrypt(caller_secret, body)` →
  把明文交 parser。
- get：先构造明文 KVS → `Envelope.encrypt(caller_secret, plaintext)` → 返回 ciphertext。
- 解密失败统一为 `XMinioAdminConfigBadJSON`，日志只能记失败阶段和错误类别，不能记 ciphertext、
  plaintext 或 caller secret。
- get 成功为 HTTP 200，body 是 ciphertext，兼容 madmin 直接 `DecryptData(resp.Body)`。
- set/reset 成功为 HTTP 200、空 body。正常动态应用时设置
  `x-minio-config-applied: true`；需要重启或本地 postcommit reload 失败时省略该头。禁止发送
  `false` 冒充另一种稳定协议值。

固定 madmin/MinIO 的 entity framing 必须逐 header 测试，不能只断言 body：

| 流向 | Content-Length | Transfer-Encoding | Content-Type | Body |
|---|---|---|---|---|
| GET request | header 缺失 | header 缺失 | header 缺失 | 0 bytes |
| PUT/DELETE request | 十进制 ciphertext 精确 byte size | header 缺失 | header 缺失 | ciphertext exact bytes |
| GET 200 response | ciphertext 精确 byte size | header 缺失 | `application/json` | ciphertext exact bytes |
| PUT/DELETE 200 response | `0` | header 缺失 | header 缺失 | 0 bytes |

这里的“缺失”是 header 不存在，不是存在且值为空。SigV4、Host、User-Agent 等非 entity header
照常存在。GET request 即使 `http.NewRequest` 内部使用 empty reader，固定 Go transport 的 wire
结果仍是不发送 CL/TE/CT；实现与 fixture 以 wire 为准。mutation success 不能由 JSON helper
发送 `null`、`{}`、换行或默认 Content-Type。

### 3.5 固定错误优先级

一次**已经匹配具体 handler**的请求同时包含多个错误时，必须按以下顺序只报告第一个：

1. Admin surface 是否已认证；
2. 路由是否匹配以及 `admin:ConfigUpdate` 是否获准；
3. GET 的必需 query，或 set/reset 的 Content-Length/Transfer-Encoding framing；
4. set/reset 的实读长度；
5. ciphertext 的 SigV4 payload hash；
6. SIO envelope 解密；
7. Config KVS 词法/语法；
8. subsystem/key 暴露边界；
9. 锁前 scalar 类型、静态范围校验；
10. 权威存储事务内的 lock/read/apply、跨键语义校验与 mutation；
11. postcommit reload/broadcast。

第 11 步发生时事务已经提交，不能再返回一个暗示“配置未写入”的错误，详见 §8。
缺失 `key` 因根本不匹配 get handler，按 §3.1 的 route fallback 处理，不套用本列表。

### 3.6 公共错误映射

| 原因 | HTTP / Code | 约束 |
|---|---|---|
| 未认证/未授权 | 403 `AccessDenied` | 先于 body/query 细节 |
| 非具体长度、超限、chunked | 400 `XMinioAdminConfigTooLarge` | 复用现有精确 message |
| envelope 解密失败、实读长度不符 | 400 `XMinioAdminConfigBadJSON` | 默认 message：`JSON configuration provided is of incorrect format` |
| payload hash 不符 | 400 `XAmzContentSHA256Mismatch` | 复用现有错误表 |
| 明确请求 target | 400 `XMinioAdminInvalidArgument` | 本批不支持 target 的显式偏差 |
| get/set/reset 的 unknown subsystem、set unknown-only/语法 generic error | 400 `XMinioConfigError` | Description 逐字使用 `config.ErrConfigGeneric.Error()`；固定 `toAdminAPIErr` 映射 |
| set 最终 typed/cross-key validator 失败 | 400 `XMinioAdminConfigBadJSON` | handler 的 `badConfigErr` 分支；Description 使用安全 validator message |
| Maxio cross-subsystem / unknown-prefix safety deviation | 400 `XMinioAdminConfigBadJSON` | §4.2/§4.4 明确列举的本地防静默验证；不能泛化成 duplicate/unknown gate |
| reset 已暴露 subsystem 下的普通 unknown key | 404 `XMinioConfigNotFoundError` | Description 逐字使用 `config.ErrConfigNotFound.Error()`；这是 reset 独有的 key-not-found 分支 |
| get/set 请求 wire-hidden path（含 `cluster.deployment_id`） | 400 `XMinioConfigError` | exposure registry 在进入 core 前把它投影为不可用，不泄露内部可写 schema |
| reset 请求 wire-hidden path（含 `cluster.deployment_id`） | 400 `XMinioConfigError` | **deliberate exposure deviation**：不同于已暴露 subsystem 下普通 unknown key reset 的 404；只用于阻断已知 hidden core path，绝不映射为 `XMinioAdminConfigBadJSON` |
| 命中 Maxio secret/backend 禁止清单 | 403 `AccessDenied` | 禁止判定先于 unknown，避免把根信任材料伪装成普通 typo |
| commit 前 Repo/事务不可用 | 500 `InternalError` | 详细原因只进结构化日志 |
| commit 后 reload/broadcast 异常 | 200 committed | 不回滚、不诱导盲重试；见 §8 |

这些映射已由固定源码冻结，不再列 VERIFY：`config.ErrConfigGeneric` → 400 `XMinioConfigError`，
`config.ErrConfigNotFound` → 404 `XMinioConfigNotFoundError`，只有 handler 包装的 `badConfigErr` →
400 `XMinioAdminConfigBadJSON`。其中已暴露 subsystem 下普通 unknown key 的 reset 必须保留 404；
unknown subsystem 的 reset 仍随 `config.ErrConfigGeneric` 返回 400。已知 wire-hidden path
的 reset 由 Maxio exposure registry 有意改成 400 `XMinioConfigError`，是本地暴露边界偏差，不能
反推为 upstream 通用映射。unknown token 的位置敏感例外仍按 §4.4，不能用本表抹平；不得把
所有 parser/validator 错误笼统改写成 ConfigBadJSON，也不得新增猜测的 `XMaxio*` code。

固定源码中可直接确定的 Description 也进入 fixture，不再等待活体猜测：

- GET unknown：`unknown subsystem: <subsystem>`；空 `key` 即 `unknown subsystem: `；
- set/reset unknown subsystem：`unknown sub-system <完整明文输入>`；
- set 没有任何 registered marker：`sub-system '<subsystem>' cannot have empty keys`；
- reset 不存在的单键：`key <key> doesn't exist`。

错误 JSON 可以回显调用者自己提交的非敏感输入，但 forbidden secret/backend 分支必须在此之前
截断为 AccessDenied，不能把 secret value 拼进 Description 或日志。

---

## 4. KVS 语法与解析语义

### 4.1 mc 如何构造输入

固定 mc 对 alias 后全部参数执行 `strings.Join(args.Tail(), " ")`。服务端收到的是一条普通
UTF-8 字符串，不再知道 shell 原始 argv 边界。因此 parser 的输入契约是 KVS 明文，不是参数
数组。

### 4.2 set 的行模型

支持形态：

```text
s3 clock_skew_ms=900000
listing sql_hard_limit=100000
prometheus_metrics public=true
```

语义：

- scanner 按 LF 逐行处理，跳过空行和以 `#` 开头的 comment line；每个非 comment line 的第一个
  空格前是 subsystem，其后至少要找到一个该 subsystem 的 registered `key=` marker。
- 本批是 subsystem batch：所有非 comment line 必须声明同一个 subsystem。固定 MinIO
  `ReadConfig` 技术上会顺序读取多 subsystem 行，但随后只以 `GetSubSys` 取出的首 subsystem 驱动
  validation/dynamic apply；复制这个不对称会让后续行绕过其自身验证。Maxio 因此对跨 subsystem
  envelope 做**deliberate safety deviation**：ConfigBadJSON、全批零落库。fixture 必须并列记录两边。
- 每一行都是 patch；未出现的键保持上一状态。多行在同一个内存候选配置上按出现顺序应用，
  全部行完成后才做最终 validator 和原子 DB mutation。
- 固定 MinIO 的 `kvFields` 不是通用 shell tokenizer：它在整行中定位**不同 registered key** 的
  首次 `key=` 下标，以这些下标切片，再对每片只 `SplitN("=", 2)`。值最后经 madmin
  `SanitizeValue` 去除外层空白及单/双引号。
- 值转换还必须通过现有 `Maxio.Config.Schema.parse/3`：boolean 只接收 `true|false`，integer 必须
  完整十进制且在声明范围内。这里的严格来自真实类型契约，不是 parser 随意加码。

多行时 raw value 先写入候选配置，只对**最后折叠结果**做 typed validation。因而第一行非法值若
被同 subsystem 后一行同 key 的合法值覆盖，固定 MinIO 与 Maxio 都以最终合法值成功；不能在第一
行提前失败。§4.4 的 unknown-prefix safety deviation 除外，它拒绝的是会被 tokenizer 静默丢弃的
语法，不是候选 value。

本批三个 subsystem 各自只有一个 exposed key，因此固定 tokenizer 的边界尤其明确：该 key 首次
`key=` 之后直到行尾的全部内容都是它的 value。

### 4.3 单行重复键与多行覆盖必须分开

**单行同名重复不是 last-write-wins。** 例如：

```text
s3 clock_skew_ms=1000 clock_skew_ms=2000
```

固定 MinIO 只为 registered `clock_skew_ms` 记录第一个下标，得到 value
`1000 clock_skew_ms=2000`；随后由 subsystem validator 决定失败。Maxio 必须走同一路径：把完整
value 交 integer parser，最终 validator 经 `badConfigErr` 得到 400 `XMinioAdminConfigBadJSON`。
不得预扫描 duplicate 后创造一个新的
“duplicate key”错误，也不得把第二个 token 当成覆盖。

**多行重复才是后行覆盖前行。** 例如 envelope plaintext：

```text
s3 clock_skew_ms=1000
s3 clock_skew_ms=2000
```

固定 MinIO 的 `ReadConfig` 顺序调用两次 `SetKVS`，第二行在候选 config 中覆盖第一行。Maxio
必须得到一个最终 typed mutation `clock_skew_ms=2000`，事务只写一次 current row、只写一条从
事务前值到 2000 的 audit；request_id 仍关联整个多行命令。

### 4.4 unknown token 的固定行为与安全偏差

unknown subsystem 由固定 MinIO `GetSubSys` 直接拒绝。unknown key token 的行为取决于它在行内
相对 registered marker 的位置，不能概括成一个额外 duplicate/unknown gate：

- 一行完全没有 registered `key=`：固定 MinIO 得到 empty fields 并报配置错误；Maxio 相同。
- unknown token 位于 registered marker **之后**：它属于前一个 registered key 的 value，随后由
  typed validator 决定；Maxio 相同。
- unknown token 位于第一个 registered marker **之前**：固定 `kvFields` 从第一个 registered
  marker 才开始切片，前缀可能被忽略。

最后一种“unknown prefix 被忽略后成功”违反 Maxio 的绝不静默失败铁律，故本批采用一项明确的
**deliberate safety deviation**：若首个 registered marker 前除 subsystem/空白外还有 token，整条
batch 返回 ConfigBadJSON，零落库。实现不得把它泛化为“扫描所有 `foo=` 并拒绝 unknown”的新
grammar；只检查固定 tokenizer 原本会丢弃的前缀。fixture 必须同时保存 upstream 的 permissive
结果与 Maxio 的拒绝结果，并在 README 标注偏差理由。

另有一项更窄的安全优先规则：若 subsystem/key 精确命中现有
`Maxio.Config.Schema.forbidden_keys/0` 或 `forbidden_subsystems/0`，在 unknown-prefix 丢弃前返回
AccessDenied。这只认代码中已有的 secret/backend 禁止集合，不扫描或猜测任意 unknown 名；它延续
core schema 的“forbidden 先于 unknown”，同样要以 deliberate safety deviation fixture 固定。

除本节的跨 subsystem 安全偏差、§4.4 的 unknown-prefix 安全偏差、target 不支持和真实 Schema
类型外，不得额外拒绝 fixed parser 接受的 key 顺序、前后空白、外层引号或同 subsystem 多行覆盖。

### 4.5 reset

支持形态：

```text
s3
s3 clock_skew_ms
listing sql_hard_limit
```

- 只有 subsystem：原子删除该 subsystem 的全部 Admin-exposed runtime overrides，回到
  env/application fallback。
- 带 key 列表：只原子 reset 指定 exposed keys。
- reset 一个 schema 中存在但当前没有 runtime override 的 key 是成功 no-op；它已经处于默认/
  env 状态。no-op 不造审计行、不造版本，但命令整体仍返回 200。
- reset 以 whitespace fields 读取 key；同一 key 重复出现时第一次已恢复 fallback，后续重复是
  同一候选配置上的幂等操作，不创造 duplicate 错误。
- 已暴露 subsystem 下的普通 wire-unknown key 返回 404 `XMinioConfigNotFoundError`；这是 `DelKVS` 的
  `config.ErrConfigNotFound` 分支。精确命中 exposure registry 已知但 wire-hidden 的 core key（首批只有
  `cluster.deployment_id`）则在进入 core reset 前返回 400 `XMinioConfigError`。后者是 deliberate
  exposure deviation，绝不改写成 `XMinioAdminConfigBadJSON`。命中 secret/backend 禁止清单返回
  AccessDenied。任一失败都不能在同批里先 reset 其他合法键。

固定 MinIO 的 `DelKVS` 是“恢复 registered default 或删除目标”，Maxio 删除 runtime override 后
回到 env/application fallback，与其运维语义同构。

**完整 subsystem reset 采用更强的幂等契约，但不能建立在错误的 upstream 404 前提上。** 固定
MinIO handler 在 `DelFrom`/`DelKVS` 前先对**整个 plaintext body**调用一次
`GetSubSys(string(kvBytes))`。因此同一 envelope 明文 `s3\ns3\n` 不会被解释成两次合法 reset；整个
字符串被当作 subsystem，命中 `config.ErrConfigGeneric`，固定结果是 400 `XMinioConfigError`，不会
到达“第二次删除”的 not-found 分支。Maxio 的 batch parser 会逐行处理同 subsystem reset，并把第二行
定义为 no-op；因此对该 exact body 返回 200 是明确的 parser/idempotency deviation，fixture 必须锁住
upstream 400 与 Maxio 200，而不是虚构 upstream 404。

独立 HTTP retry 会重新读取 authoritative config；固定 MinIO 的 merge/default 构造通常恢复 default
target，所以再次发送 `s3` 通常仍返回 200。目前没有已取证的输入既通过 whole-body `GetSubSys` 又在
后续重复删除中稳定得到 upstream 404，故本批不建立此类 upstream fixture。Maxio 则作出更强且稳定的
本地保证：完整 subsystem reset 及其独立 retry 一律成功；若没有 runtime override，就是 200 no-op，
不增 version、不写 audit、不 reload、不 broadcast，并返回 `x-minio-config-applied: true`、
`Content-Length: 0`、无 Content-Type、空 body。独立 retry fixture 只锁 Maxio 的 200 与零副作用；
不得声称固定 MinIO 在该场景返回 404。

### 4.6 get

本批只接收精确 subsystem 名：

```text
s3
listing
prometheus_metrics
```

固定 MinIO 支持三种 key：`subsystem:target`、`subsystem:`、`subsystem`。Maxio 第一批只有默认
单 target 模型，因此任何包含 `:` 的输入都明确返回 `XMinioAdminInvalidArgument`。这是有意的
**严格偏差**，理由是接受后忽略 target 会制造“读到了指定 target”的假象。普通
`mc admin config get ALIAS s3` 不受影响。

### 4.7 其他 parser 偏差纪律

固定 madmin 的 `ParseServerConfigOutput` 对 subsystem 名没有 catalog 白名单，所以 `s3`、
`listing`、`prometheus_metrics` 扩展名可被 mc JSON 模式正常解析。服务端仍必须用自己的映射表
确认它们真实存在。

除 §4.2 的跨 subsystem、§4.4 的 unknown-prefix、target 不支持和真实 Schema 类型/暴露边界外，
本批不新增下列 strict 行为：

- 不把单行 duplicate 预解析成专用错误或 last-write-wins；
- 不拒绝固定语义下合法的多行后写覆盖；
- 不要求字典序输入；
- 不要求 `Content-Type`；
- 不把合法空白/引号形态收窄为简单 `String.split/2`；
- 不扫描所有疑似 `foo=` token 后发明通用 unknown-key grammar。

Maxio 绝不保存 unknown key；在固定 tokenizer 把 unknown 后缀归入 value 的位置保持 validator
行为，只对 upstream 会静默丢弃的 unknown 前缀采用 §4.4 的显式全批拒绝。

---

## 5. Maxio extension mapping 与敏感边界

### 5.1 唯一允许投影的键

| Wire subsystem | Wire key | Core schema | 类型/范围 | Apply | 真实消费者 |
|---|---|---|---|---|---|
| `s3` | `clock_skew_ms` | `{:s3, :clock_skew_ms}` | integer 0..3,600,000 | hot | SigV4 header 时钟偏移校验 |
| `listing` | `sql_hard_limit` | `{:listing, :sql_hard_limit}` | integer 1..10,000,000 | hot | LIST SQL 取数硬上限 |
| `prometheus_metrics` | `public` | `{:prometheus_metrics, :public}` | boolean | hot | metrics plug 匿名访问判定 |

映射应位于独立的 Admin Config KVS schema/registry，不把 wire 协议元数据塞进核心
`Maxio.Config.Schema`。静态测试必须逐项证明：

- wire entry 指向一个真实 core schema entry；
- core entry 的消费者经 `Maxio.Config` 读取；
- 首批每项 `sensitive? == false`；
- 输出顺序由 registry 明确声明，不依赖 map 枚举顺序。

### 5.2 明确隐藏

- `{:cluster, :deployment_id}` 即使当前属于 runtime schema，也不投影。它是部署稳定身份；允许
  `mc admin config set` 修改会使审计、复制和 ServerInfo 身份发生语义漂移。get/set 请求固定返回
  400 `XMinioConfigError`；reset 请求也固定返回 400 `XMinioConfigError`，这是相对已暴露 subsystem
  下普通 unknown key reset 返回 404 `XMinioConfigNotFoundError` 的 deliberate exposure deviation。该规则只识别 registry 中
  已知的 wire-hidden key，不扫描或猜测其他 unknown 名称，且绝不返回 `XMinioAdminConfigBadJSON`。
- `Maxio.Config.Schema.forbidden_keys/0` 与 `forbidden_subsystems/0` 的全部 key 都隐藏且不可写。
- root user/password、access-key secret、SSE/KMS/MFA key、storage/credential/policy backend、
  Repo、topology/authoritative-source 等绝不进入 registry。

### 5.3 敏感值纪律

当前 `runtime_config_audits` 可保存 old/new value，因此首批禁止引入 sensitive mapping。将来若要
支持敏感配置，必须先完成 at-rest 加密、审计脱敏和日志证明，再单独修订设计。

GET renderer 即使首批没有 secret，也必须以 registry 的 `sensitive?` 为唯一判定来源，保留
“敏感 entry 整项省略”的显式分支；不得返回固定替代值、不得根据 key 名猜 secret。任何 secret
都不能出现在：

- GET 明文或 JSON projection；
- audit old/new 明文；
- error message；
- structured log metadata；
- Mix CLI debug 输出。

---

## 6. 组件与插件边界

职责边界冻结如下；具体文件拆分可在实现计划中调整，但依赖方向不可反转：

```text
Admin.Plug / Mix task
        │
        ▼
Admin.ConfigKV.Request  ── framing、payload hash、Envelope
        │
        ▼
Admin.ConfigKV.Parser   ── 纯 KVS 文本 ↔ typed batch
        │
        ▼
Admin.ConfigKV.Adapter  ── wire registry、projection、错误翻译
        │
        ▼
Maxio.Config public API ── 唯一 mutation/read facade
        │
        ├── Repo: runtime_configs + runtime_config_audits
        ├── Store: authoritative snapshot/reconcile
        └── Cluster.Notify: checked invalidation
```

硬边界：

- Admin adapter 不得直接调用 Repo、Ecto schema或写 `:persistent_term`。
- Parser/renderer 是纯函数，不依赖 DB、Plug 或 caller secret。
- Request 层不理解 subsystem/key 业务语义。
- `Maxio.Config` 继续是配置后端边界；本批不为一个尚不存在的第二 backend 提前新增 behaviour。
- 将来若确有配置 backend plugin 需求，behaviour 放在 `Maxio.Config` 后面，Admin 层零改动。

---

## 7. 原子子系统 batch、并发、审计与版本

### 7.1 公共 mutation 契约

核心增加一个 batch/subsystem mutation 公共入口。输入至少包含：

- subsystem；
- 规范化后的 set map 或 reset key set；
- `source`（Admin 固定 `admin_api`，Mix 固定 `cli`）；
- principal/access key/request_id 审计上下文；
- 可选 per-key `expected_version`，仅供现有本地单键入口使用。

Admin/mc 线协议没有 version 参数，不能伪造 If-Match 或私有 query。

### 7.2 验证分层：纯输入可锁前，依赖快照必须锁内

只有不读取可变权威状态的验证可以在拿 DB lock 前完成：

- envelope 解密后的 KVS 词法/行结构；
- wire subsystem/key mapping 与 forbidden/hidden 边界；
- 多行 input-only 折叠；
- 最终 scalar 的类型与静态范围；
- 只依赖 command + code schema 的约束。

任何依赖“未出现在 patch 中的当前键”、effective/current snapshot、row 是否存在、version 或 source
的跨键 validator，**禁止**在锁前读旧快照后作决定。它必须在同一 transaction 内：拿 subsystem
advisory lock → 权威读取 → 把 patch 应用到候选 snapshot → 验证完整候选 → mutation。否则 validator
通过到实际 UPDATE 之间存在 TOCTOU 窗口。

锁前纯验证失败时不启动 mutation、不写 runtime/audit、不 reload、不 broadcast；锁内候选验证失败
时 transaction 整体回滚，同样无 postcommit 副作用。

### 7.3 advisory lock

进入事务后，第一条协调动作是调用
`pg_advisory_xact_lock(1297638214, hashtext(subsystem))` 获取该 subsystem 的 transaction-scoped
PostgreSQL advisory lock，然后才查询当前行。`1297638214` 是本项目 Config coordinator 的固定
namespace（十六进制 `0x4D584346`，即 `MXCF`）；第二个 int 由同一 PG 权威计算。hash 碰撞最多
造成无害的过度串行，不能导致错误共享数据。

锁必须覆盖：

- Admin set/reset batch；
- 现有 `Maxio.Config.set/4` 与 `reset/3` 单键入口；
- 新 Mix KVS CLI；
- 以后任何写 `runtime_configs` 的正式入口。

禁止保留一条绕过锁的“旧单键快路径”。`SELECT FOR UPDATE` 锁不住尚不存在的行，仅靠唯一索引
不能保证 batch 与首次单键写的整体顺序。

不同 subsystem 可并发；同 subsystem 事务串行。

### 7.4 单事务步骤

拿到 advisory lock 后：

1. 按 wire registry 的稳定 key 顺序权威读取该 subsystem 完整候选所需的 rows，并对已有 row
   `FOR UPDATE`；同时读取 env/application fallback 所需的稳定材料；
2. 再次核对本地 CLI 提供的 expected versions；任一冲突则整批回滚；
3. 在权威 snapshot 上按原始多行顺序应用已解析 patch/reset，构造完整候选 snapshot；
4. 运行所有依赖 snapshot 的跨键 validator；失败则在 mutation 前整批回滚；
5. 仅在候选验证通过后计算实际 diff；对 set insert/update，对 reset delete runtime override；
6. 每个**实际变化**的键插入一条 `runtime_config_audits`；
7. 所有 audit 共用本次 HTTP/request command 的同一个 `request_id`、principal 与 source；
8. 一次 transaction commit。

任何 insert/update/delete/audit 失败都回滚整批，不存在“前两个键成功、第三个失败”。

### 7.5 no-op

set 为与当前 typed runtime override 精确相等的值，或 reset 一个没有 runtime override 的合法键，
都是成功 no-op：

- 不增 version；
- 不写 audit；
- 不需要 reload/broadcast；
- batch 结果仍报告 committed，附 `changed_count == 0` 供日志/CLI 取证。

若同一 batch 有其他实际变化，只为变化键写 audit，postcommit 仍只执行一次。

### 7.6 version 语义

保留当前 per-key row version，不新增 subsystem/global version：

- 首次 runtime override version = 1；
- 更新同一 row 时 version +1；
- reset 删除 row；audit 的 `to_version` 记录被删除 incarnation 的下一版本；
- reset 后未来重新 set 是新的 row incarnation，从 version 1 开始；
- 完整历史由 audit + request_id 表达，不能把当前 row version 当全局单调 revision。

周期 reconcile 继续比较权威内容 digest，而非只比较 `MAX(version)`，因此删除与 version 重启仍可被
检测。Admin 因无 expected_version，重叠 batch 在锁下串行，后提交的 patch 对重叠键获胜；不重叠
键不丢失。现有本地单键 CLI 的 expected_version 仍可得到 `config_version_conflict`。

### 7.7 audit

每条变化 audit 至少保留：subsystem/key、old/new typed value、from/to version、apply mode、source、
principal ARN、access key id、request_id、timestamp。首批均非敏感；日志仍禁止打印 old/new value。

同一 request_id 是一次 batch 的审计关联键。本批不加 batch 表或 migration；查询方按 request_id
聚合即可。事务内写 audit 保证当前值与历史不分叉。

### 7.8 与 MinIO 非原子 history 的有意安全偏差

固定 MinIO `setConfigKV` 先 `saveServerConfig`，再 `saveServerConfigHistory`；后者失败可能出现
“配置已保存但 API 报错/history 缺失”。Maxio 已有关系型权威和 audit 表，故明确偏离：

- runtime rows 与 audits 在同一个 DB transaction；
- audit 失败即 runtime rows 回滚；
- 不复制 upstream 的两次对象写窗口。

这是一项更强的原子安全保证，不改变 mc 的成功 wire contract，必须在 fixture README 标注为
intentional safety deviation。

---

## 8. Postcommit、广播与 restart 真相

### 8.1 commit 是不可撤销事实

Repo transaction 返回成功后，配置已经提交。此后本地 cache reload 或 PubSub broadcast 失败，
不能把 HTTP 改成 500/503，让 mc 误以为可安全重试。否则一次重试可能再次改变 version/audit，且
错误响应与 DB 真相矛盾。

核心 mutation 结果必须区分：

```text
committed?        true | false
changed_count     non-negative integer
apply_modes       set(:hot | :next_cycle | :restart)
local_reload      :ok | :not_needed | {:error, safe_reason}
broadcast         :ok | :not_needed | {:error, safe_reason}
attention?        boolean
```

任何 safe_reason 只能是枚举/类别，不能携带配置值。

### 8.2 postcommit 次数与顺序

有实际变化时：

1. 恰好一次本节点权威 full reload；
2. 恰好一次 subsystem-level checked broadcast；
3. 即使第 1 步失败，也必须尝试第 2 步；两项结果分别记录。

新事件冻结为 `{:config_changed, subsystem}`。Store 收到后做一次 full reload；CacheInvalidator
将其认领为已知 no-op。旧 `{:config_changed, subsystem, key}` 在迁移期继续可识别，但所有正式
旧单键写也进入新 coordinator，不能再逐键广播。

### 8.3 checked broadcast 与 reconcile

新 coordinator 使用 `Maxio.Cluster.Notify.broadcast_checked/1`，不得调用吞掉 transport 错误的
legacy `broadcast/1`。广播仍是快路径而非事务正确性依赖：PG 是权威，Store 的周期 content digest
reconcile 是慢路径兜底。

- broadcast 失败：commit 仍成功；结构化 warning + Store/status attention；远端节点最迟在一个
  reconcile 周期收敛。
- local reload 失败：commit 仍成功；结构化 error + attention；本节点不能声称已动态生效。
- reconcile 发现 digest 漂移：full reload 并记录 `last_reload_reason`；不得静默忽略。

### 8.4 `x-minio-config-applied`

设置为 `true` 当且仅当：

- batch 的所有变化键 apply mode 都是 `:hot` 或 `:next_cycle`；且
- 本节点 postcommit reload 成功。

成功 no-op 没有变化键，也不需要 reload/broadcast，直接设置 true；它明确不需要重启。

`broadcast_checked` 失败不等于“需要重启”，因为周期 reconcile 能收敛，所以它本身不撤销 true；
但必须进入 attention 日志/status。若任一键是 `:restart`，或本地 reload 失败，则省略 header，mc
会给出 restart 提示。

当前三项 exposed key 都是 `:hot`，正常路径设置 true。`next_cycle` 表示无需进程重启，不表示在
同一微秒已经执行下一轮；madmin 这个 header 只回答 restart，不是同步可见性 barrier。

### 8.5 日志

成功日志包含：action、authorized action、subsystem、稳定 key 名列表或 key count、changed_count、
apply modes、request_id、principal ARN、auth type、local_reload、broadcast、attention。失败日志包含
失败阶段与安全错误类别。

严禁记录 raw command、`key=value`、plaintext、ciphertext、old/new values、caller secret 或包含
它们的 `inspect(reason)`。

---

## 9. 权威 GET、格式化与 redaction

### 9.1 GET 必须先确认权威快照

管理 GET 不得在错过广播时把最长 30 秒的旧 snapshot 当权威回答。handler 在 projection 前必须
同步执行 Store 的权威 reconcile/load，并且仅在 PG digest 与本地 snapshot 一致后继续。

- 成功：经 `Maxio.Config` facade 读取 effective value 与 source；不直接 Repo query 后自行合并。
- commit 前 PG/Store 不可用：返回结构化 InternalError，而不是用可能过期的 cache 假成功。
- reconcile 可能触发一次 full reload；GET 本身不广播。

### 9.2 明文输出

每个请求的明文恰好一条配置行。固定 `SubsysInfo.WriteTo` 在**每个 KV 后写一个 ASCII space**，
再写 LF；因此单键响应也必须保留尾空格。用可见字节标记表达三个精确结果：

```text
s3 clock_skew_ms=900000<SP><LF>
listing sql_hard_limit=100000<SP><LF>
prometheus_metrics public=false<SP><LF>
```

规则：

- subsystem 与 key 使用 wire registry 名；
- key 按 registry 稳定顺序；
- integer 用无分隔十进制，boolean 用小写 `true|false`；
- 值含空白时用双引号，规则与 madmin `KV.String()` 一致；
- 每个 `key=value` 后恰好一个 ASCII space，包括最后一个；其后恰好一个 LF；
- 首批无 exposed env var，因此不输出 `# MINIO_*` 注释；不得伪造 envOverride；
- 默认 target 不加 `:`，这样 madmin JSON parser 输出省略 `target`。

### 9.3 redaction

GET 是 reporting API，不是 secret export。renderer 在任何值序列化前执行 registry redaction；即使
未来误把 sensitive entry 加入，也不能依赖 caller 有 ConfigUpdate 权限而返回 secret。首批的
静态断言应使 sensitive entry 数为零。

---

## 10. 非 TTY `mc` 可见输出

测试统一设置隔离 `MC_CONFIG_DIR`、`--no-color`、stdout 非 TTY，并分别验证 human 与 `--json`；
不得把彩色 ANSI 或本机 alias 状态混入 fixture。固定 mc 的非 TTY `--json` 经过 compact 输出，
所有 JSON 都是**单行无多余空白 + 一个 LF**，不允许 pretty JSON。

### 10.1 get

Human stdout 是解密后的服务器文本逐字输出。单键 exact bytes 为：

```text
s3 clock_skew_ms=900000<SP><LF>
```

`--json` 经 `madmin.ParseServerConfigOutput` 后的 exact stdout 为：

```json
{"status":"success","config":[{"subSystem":"s3","kv":[{"key":"clock_skew_ms","value":"900000"}]}]}
```

即上述单行后紧跟一个 LF，无前导/尾随空格。

默认 target 的 `target` 字段省略。首批没有 `envOverride`。

### 10.2 set

有 applied header：

```text
Successfully applied new settings.
```

header 缺失时第二行是：

```text
Please restart your server 'mc admin service restart ALIAS'.
```

JSON 成功只含导出字段 `status`；`targetAlias` 与 `restart` 在 mc struct 中未导出，因此不出现：

```json
{"status":"success"}
```

Exact bytes：`{"status":"success"}<LF>`。

### 10.3 reset

有 applied header：

```text
's3 clock_skew_ms' is successfully reset.
```

header 缺失时第二行是：

```text
Please restart your server with `mc admin service restart ALIAS`.
```

JSON exact stdout 同样 compact：

```json
{"status":"success"}
```

Exact bytes：`{"status":"success"}<LF>`。

输入回显是 mc join 后的完整 string，不只是 subsystem。

错误输出由 mc 的 `fatalIf` 包装，不属于成功 stdout；fixture 必须分别断言 exit status、stdout 与
stderr，不能只 grep 一段文字。

---

## 11. 本地 CLI 与可观测调试面

现有 `mix maxio.config.get/set/reset` 是单键 core CLI，不能覆盖 madmin KVS grammar 与 batch
atomicity。本批增加三条名称冻结的 subsystem CLI：

```text
mix maxio.admin.config.get "s3"
mix maxio.admin.config.set "s3 clock_skew_ms=900000"
mix maxio.admin.config.reset "s3 clock_skew_ms"
```

要求：

- 调用同一 Parser、Adapter 与 `Maxio.Config` coordinator；不得复制业务逻辑；
- 不经过 HTTP/SigV4/envelope，但 source 固定 `cli` 并生成 request_id；
- get 输出与 envelope 内的 KVS plaintext 完全一致；
- mutation 输出 committed、changed_count、apply modes、reload/broadcast attention；
- 默认不打印 value；需要 get 才显示已通过 redaction 的 projection；
- existing single-key CLI 继续可用，但内部写路径迁移到同一 advisory-lock coordinator。

---

## 12. 测试与 external smoke 取证

### 12.1 协议 fixture

固定 MinIO/madmin/mc commit、源码片段 hash、路由、action、Content-Type 缺失、envelope、header 和
non-TTY 输出。测试应证明：

- GET/PUT/DELETE exact path/method/query；
- GET 也要求 `admin:ConfigUpdate`；
- 缺失 `key` 的 authenticated 426 与 `?key=` 的 authorized 400 `XMinioConfigError` 分支；
- GET request 无 CL/TE/CT，PUT/DELETE request 为 ciphertext exact CL 且无 TE/CT；
- GET ciphertext 200 response 为 exact CL，mutation 200 response 为 CL0/no CT/empty body；
- applied header 的 true/缺失分支；
- 固定源码的 `XMinioConfigError` / `XMinioConfigNotFoundError` /
  `XMinioAdminConfigBadJSON` 分流；尤其锁住 unknown subsystem reset 的 400、已暴露 subsystem 下普通
  unknown key reset 的 404、wire-hidden reset 的 deliberate 400 exposure deviation，以及后者绝不落到
  BadJSON；
- get human 的 `<SP><LF>`、compact JSON，以及 set/reset compact
  `{"status":"success"}<LF>` stdout 与 exit status。

### 12.2 parser/renderer

覆盖合法空白/quote、单行 duplicate 被 value 吸收后由 validator 决定、同 subsystem 多行重复后写覆盖、
首行非法 raw value 被后行合法值覆盖后只验证最终值、
unknown-only/unknown-suffix 的固定行为、unknown-prefix deliberate deviation、合法 reset no-op、reset
subset/full subsystem、unknown subsystem reset 的 400、已暴露 subsystem 下普通 unknown key reset 的
404、wire-hidden reset 的 deliberate 400 exposure deviation、
同一 body `s3\ns3\n` 的 upstream 400/Maxio 200 parser deviation、独立 full-subsystem retry 的 Maxio
200/零 version/零 audit/零 postcommit 保证（不设 upstream 404 fixture）、跨 subsystem deliberate
deviation、target 显式拒绝、稳定顺序、尾 `<SP><LF>`、
boolean/integer 格式、redaction 静态断言。

### 12.3 核心事务与并发

使用真实非 sandbox 隔离 PG 连接做确定性并发测试，不用 `Process.sleep/1`：

- 多键 set 任一校验/DB/audit 失败时零 runtime/audit 变化；
- 同 batch audit 共用 request_id，版本逐键正确；
- reset 删除 row，未来 set 从 version 1 新 incarnation 开始；
- single-key writer 与 batch writer 同 subsystem 串行，不丢不重叠键；
- 用锁内改变未 patch sibling key 的并发 writer 证明跨键 validator 在 lock + authoritative read +
  patch 之后运行，不接受锁前旧 snapshot；
- 不同 subsystem 可并发；
- no-op 不增 version/audit；
- 一个 batch 恰好一次 reload、一次 checked broadcast。

同步使用 barrier、事务锁、monitor 或 `:sys.get_state/1`，禁止 sleep 猜时序。

### 12.4 postcommit fault injection

- DB commit 后 local reload 失败：HTTP 200、无 applied header、DB/audit 已存在、attention 可见；
- local reload 失败时仍尝试 broadcast；
- broadcast_checked 失败：HTTP 200、不否认 commit、status/log attention；
- 丢广播后周期 digest reconcile 在一个 refresh 周期内收敛；
- postcommit 重试不会自动发生，避免重复 mutation。

### 12.5 endpoint

覆盖 root、policy allow、无 policy/explicit deny、错误优先级、GET 缺失/空 key 的路由差异、
缺失/重复/超限 length、chunked、
实读长度不符、payload hash mismatch、wrong caller secret、malformed KVS、unknown/hidden/forbidden、
encrypted GET、四类 exact entity framing、full reset retry、empty success body 与 applied header。
每类错误断言 JSON code/status/message/resource，
并捕获日志证明没有 plaintext/ciphertext/value。

### 12.6 external smoke 与数据面效果

扩展现有 `Maxio.Compat.ExternalSmoke`，继续使用独立 `MC_CONFIG_DIR`、精确 argv、独立 human/JSON
断言和 `try/after` 清理。活体 profile 必须使用隔离 DB，预置
`prometheus_metrics.public == false` 且没有 runtime override：

1. 匿名请求 metrics → 403；
2. `mc admin config get ALIAS prometheus_metrics` → human exact
   `prometheus_metrics public=false<SP><LF>`，`--json` 为 compact 单行 + LF；
3. `mc admin config set ALIAS prometheus_metrics public=true` → 成功且无 restart 行；
4. get human 以 `<SP><LF>`、JSON 以 compact + LF 精确读到 true；
5. 匿名请求 metrics → 200，证明不是只写 DB 无消费者；
6. `mc admin config reset ALIAS prometheus_metrics public`；
7. get 回到 false，匿名 metrics 再次 403；
8. `after` 中无条件再执行 reset，清理失败单独报告，不能覆盖主失败。

这条 403→200→403 是本批最强的功能证据；仅做 config round-trip 不足以证明运行时生效。

---

## 13. VERIFY-AT-IMPL

mc compact JSON、KVS 尾空格、固定错误映射和 route/framing 均已由固定源码冻结，属于普通 protocol
fixture，不再列 VERIFY。只保留一项必须用 Maxio 活体消解的分布式事实：

### V-KV3 —— Maxio checked broadcast 故障与数据面热应用

在至少两个 Maxio 节点上注入一次 broadcast transport failure，证明写节点 commit/audit 与 header
语义、远端周期 digest reconcile、attention 状态均符合 §8；同一活体同时执行
`prometheus_metrics.public` 的 403→200→403 smoke，证明 get/set/reset 不只是控制面回显。

---

## 14. 完成判据与审查边界

实现批只有在以下证据齐全时才可完成：

- 固定协议 fixture 与 V-KV3 均消解；
- parser、事务、并发、fault injection、endpoint、CLI、external smoke 全部通过；
- `mix compile --warnings-as-errors` 与相关 focused tests 通过；
- coherent batch 收口时只跑一次完整 `mix precommit`；
- 独立测试/审查 lane 确认无 secret/value 日志、无部分提交、无虚假 MinIO subsystem 声明；
- `docs/superpowers/STATUS.md` 更新真实通过证据与仍未支持的 non-goals。

作者 lane 不自审实现。本文也不授权顺手实现 help/export/history/targets 或官方 catalog；发现这些
需求时必须另开设计批次。

---

## 15. 固定参考 URL

- <https://raw.githubusercontent.com/minio/minio/7aac2a2c5b7c882e68c1ce017d8256be2feea27f/cmd/admin-router.go>
- <https://raw.githubusercontent.com/minio/minio/7aac2a2c5b7c882e68c1ce017d8256be2feea27f/cmd/admin-handlers-config-kv.go>
- <https://raw.githubusercontent.com/minio/minio/7aac2a2c5b7c882e68c1ce017d8256be2feea27f/cmd/admin-handler-utils.go>
- <https://raw.githubusercontent.com/minio/minio/7aac2a2c5b7c882e68c1ce017d8256be2feea27f/cmd/handler-utils.go>
- <https://raw.githubusercontent.com/minio/minio/7aac2a2c5b7c882e68c1ce017d8256be2feea27f/cmd/api-errors.go>
- <https://raw.githubusercontent.com/minio/minio/7aac2a2c5b7c882e68c1ce017d8256be2feea27f/internal/config/config.go>
- <https://raw.githubusercontent.com/minio/madmin-go/4b504b82db633e978a57d49443b2be75824244c3/config-kv-commands.go>
- <https://raw.githubusercontent.com/minio/madmin-go/4b504b82db633e978a57d49443b2be75824244c3/parse-config.go>
- <https://raw.githubusercontent.com/minio/madmin-go/4b504b82db633e978a57d49443b2be75824244c3/api.go>
- <https://raw.githubusercontent.com/minio/mc/77f82e18b5401a65958f1619df6ebb994634bd88/cmd/admin-config-get.go>
- <https://raw.githubusercontent.com/minio/mc/77f82e18b5401a65958f1619df6ebb994634bd88/cmd/admin-config-set.go>
- <https://raw.githubusercontent.com/minio/mc/77f82e18b5401a65958f1619df6ebb994634bd88/cmd/admin-config-reset.go>
- <https://raw.githubusercontent.com/minio/mc/77f82e18b5401a65958f1619df6ebb994634bd88/cmd/print.go>
