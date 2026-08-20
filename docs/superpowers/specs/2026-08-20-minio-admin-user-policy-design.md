# MinIO 管控面第三批设计 —— `mc admin policy` / `mc admin user` 适配层

> 日期：2026-08-20
> 状态：设计草案，待评审后进入 RED 阶段
> 作者 lane：architect / planner（本文不含实现代码）
> 上位准则：`AGENTS.md` §3 架构铁律、§4 工程方法；`CLAUDE.md`
> 前置设计：`docs/superpowers/specs/2026-08-18-minio-admin-surface-design.md`（骨架 + config store + ServerInfo，含文末实现批次回写）
> 当前状态：`docs/superpowers/STATUS.md`

---

## TL;DR

1. **V-A4 消解，答案是「混合」且切分反直觉**：`mc admin policy` 全家（create/ls/info/rm）与 `mc admin group` 全家、以及 `user-info` / `remove-user` / `set-user-status` **全是明文 JSON**；但 `add-user`（请求）、`list-users`（响应）、`policy attach/detach`（双向）、service account 全家**走 madmin 的 argon2id + sio.Stream 信封**。
   → 本批**不是**密码学互操作批次，但它也**做不了 `mc admin user add` / `mc admin user ls`**。
2. **本批 = 明文适配层**：S-1 `mc admin policy create/ls/info/rm`（硬底线）+ S-2 `mc admin user info/enable/disable/rm` + S-3 `mc admin group ls/info/add/rm/enable/disable`。全部是对既有 `Maxio.IAM` 门面的翻译，**唯一的后端新增是两个 status setter**（`update_user_status_strict/2`、`update_group_status_strict/2`——列已存在，只是没有改它的路径）。
3. **最危险的语义鸿沟是 user 模型**：MinIO 的 user **就是**一把 access key；maxio 是「`iam_users` 行 + 若干 `access_keys` 行」两级。裁决：**`iam_users` 是唯一权威 user 集合**，MinIO 视图与 IAM Query 视图同源，绝不产生两套互不可见的用户。
4. **三处"宁可不做也不错映射"**：service account（需新后端概念，不做）；`/set-user-or-group-policy`（语义是 replace 非 attach 且无真实客户端，不做）；内置 canned policy（maxio 没有，**绝不 seed 一个含 `admin:*` 的 `consoleAdmin`**）。
5. **两处刻意偏离 MinIO 并写进 README**：删除已附加/多版本策略时**照实报错、绝不级联解绑权限**；不实现 MinIO 的两处自助放宽（偏离方向是更严，fail-closed）。

---

## 0. 本文范围与前置事实

### 0.1 已完成（不重复）

| 批次 | 交付 | 活体取证 |
|---|---|---|
| 第一批 | `/minio/health/{live,ready}` 匿名 200；`Maxio.Admin.Plug`（SigV4 之后、Dispatch 之前）截住 `/minio/admin/*`，未实现端点统一 **501 JSON**；`Maxio.Admin.Authz`；`Maxio.Admin.ErrorView`（复用 `%Maxio.S3.Error{}`）；`minio` 成保留桶名；认领要求 path-style | madmin 能解码 501/403 JSON |
| 第二批 | 运行时配置存储（`Maxio.Config` + `runtime_configs` + persistent_term + 广播 + 周期对账）；`/minio/admin/v3/info` 真实 ServerInfo | **`mc admin info` 出真实内容** |

由此得到的**零成本接入面**（本批不需要动任何管线）：

- `Maxio.S3.ReservedNamespace` 的 `@claims` 已含 `{:admin, :prefix, "/minio/admin/"}`（`lib/maxio/s3/reserved_namespace.ex:53`）。**整个前缀已被认领**，新增端点 = 在 `Maxio.Admin.Plug.dispatch/3` 的兜底子句之前加一个模式匹配子句，**其余一行不改**。
- `Maxio.Admin.Authz.authorize/3`（`lib/maxio/admin/authz.ex`）对 action 字符串完全通用，resource 恒 `arn:aws:s3:::*`，identity-policy only，root 短路，STS session policy 边界仍生效。**新 action 名直接可用**，policy 层零改动（`Maxio.Policy.Statement` 已为 `admin:*` 无 `Resource` 的 identity statement 开了补 `Resource: "*"` 的口子）。
- `Maxio.Admin.ErrorView.render/1` 恒发 `Code / Message / Resource / RequestId / HostId` 五键 JSON。
- 签名层零改动（madmin 空 region scope 已实测通过）。

### 0.2 本文交付什么

1. **消解 V-A4**（第二批设计 §12 标注的、决定本批性质的最大未知）：`/list-users` 等端点是明文 JSON 还是 madmin 的加密封装。
2. 在 V-A4 结论之上，给出 `mc admin policy *` / `mc admin user *`（及相邻的 `mc admin group *`）的**端点清单 → maxio 能力映射**。
3. 语义对齐裁决：MinIO 的 IAM 模型与 maxio 的 AWS IAM 模型不能干净对应处，**一律标注"本批不做"而不是强行映射**。
4. 分批边界与真实 mc 活体验收清单。

**本文不涵盖**：具体 Elixir 代码；madmin 加密封装的实现（本文只做可行性与工作量评估，落地是独立批次）；service account（`mc admin user svcacct`）的业务语义；`mc admin config`。

---

# 第一部分：V-A4 —— madmin 加密封装边界（本批性质的决定项）

## 1. 结论：**混合**，而且切分方式反直觉

第二批设计里 V-A4 的原文假设是"其余端点大概率也是明文"。**这个假设是错的**。真实的切分规律是：

> **凡是携带 secret key、或批量列举凭据/策略映射的端点，body 走 madmin 的 `EncryptData` 信封；策略文档本身与单用户元数据是明文 JSON。**

### 1.1 逐端点结论表（路径相对 `/minio/admin/v3`）

「加密」列：**REQ** = 请求体经 `madmin.EncryptData(secretKey, json)`；**RESP** = 响应体经 `EncryptData`。密钥是**调用方自己的 SigV4 secret key**（服务端 `cred.SecretKey`，客户端 `adm.getSecretKey()`）。

| # | 端点 | 方法 | query | 请求体 | 响应体 | 加密 | 证据 |
|---|---|---|---|---|---|---|---|
| U1 | `/add-user` | PUT | `accessKey` | `madmin.AddOrUpdateUserReq` | 空 | **REQ** | `cmd/admin-handlers-users.go` `AddUser`：`madmin.DecryptData(password, io.LimitReader(r.Body, r.ContentLength))` |
| U2 | `/list-users` | GET | —（另注册一条 `bucket` 变体 → `ListBucketUsers`） | — | `map[string]madmin.UserInfo` | **RESP** | 同文件 `ListUsers`：`econfigData, _ := madmin.EncryptData(password, data)` → `writeSuccessResponseJSON` |
| U3 | `/user-info` | GET | `accessKey` | — | `madmin.UserInfo` | **明文** | `GetUserInfo`：`writeSuccessResponseJSON(w, data)`，无 `EncryptData` |
| U4 | `/remove-user` | DELETE | `accessKey` | — | 空 | **无 body** | —— |
| U5 | `/set-user-status` | PUT | `accessKey`, `status` | — | 空 | **无 body** | 状态经 query 传，`enabled` / `disabled` |
| G1 | `/groups` | GET | — | — | `[]string` | **明文** | —— |
| G2 | `/group` | GET | `group` | — | `madmin.GroupDesc` | **明文** | —— |
| G3 | `/update-group-members` | PUT | — | `madmin.GroupAddRemove` | 空 | **明文** | —— |
| G4 | `/set-group-status` | PUT | `group`, `status` | — | 空 | **无 body** | —— |
| P1 | `/add-canned-policy` | PUT | `name` | 原始 IAM policy JSON | 空 | **明文** | `AddCannedPolicy`：`io.ReadAll(io.LimitReader(r.Body, r.ContentLength))` |
| P2 | `/list-canned-policies` | GET | —（另注册一条 `bucket` 变体 → `ListBucketPolicies`） | — | `map[string]json.RawMessage` | **明文** | `ListCannedPolicies`：`json.NewEncoder(w).Encode(...)`；客户端 `ListCannedPolicies(ctx) (map[string]json.RawMessage, error)` |
| P3 | `/info-canned-policy` | GET | `name`，可选 `v=2` | — | `v=2` → `madmin.PolicyInfo`；无 `v` → 裸 policy JSON | **明文** | `InfoCannedPolicy`：按 `r.Form.Get("v")` 分流 |
| P4 | `/remove-canned-policy` | DELETE | `name` | — | 空 | **无 body** | —— |
| P5 | `/set-user-or-group-policy` | PUT | `policyName`, `userOrGroup`, `isGroup` | — | 空 | **无 body** | **当前 mc 不再调用**（见 §3.4） |
| P6 | `/idp/builtin/policy/{attach\|detach}` | POST | — | `madmin.PolicyAssociationReq` | `madmin.PolicyAssociationResp` | **REQ + RESP** | 且**强制** `Content-Type: application/octet-stream`，否则 `ErrBadRequest` |
| P7 | `/idp/builtin/policy-entities` | GET | `user`/`group`/`policy`（均可重复） | — | `madmin.PolicyEntitiesResult` | **RESP** | —— |
| S1 | `/add-service-account` | PUT | — | `AddServiceAccountReq` | `AddServiceAccountResp` | **REQ + RESP** | —— |
| S2 | `/update-service-account` | POST | `accessKey` | `UpdateServiceAccountReq` | 204 空 | **REQ** | —— |
| S3 | `/info-service-account` | GET | `accessKey` | — | `InfoServiceAccountResp` | **RESP** | —— |
| S4 | `/list-service-accounts` | GET | `user` | — | `ListServiceAccountsResp` | **RESP** | —— |
| S5 | `/delete-service-account` | DELETE | `accessKey` | — | 204 空 | **无 body** | —— |

> **注意 `writeSuccessResponseJSON` 在 body 是加密二进制时仍然发 `Content-Type: application/json`**。服务端**不得**在加密响应上改发 `application/octet-stream`（客户端不检查，但对齐真实实现是铁律 5）。请求方向相反：P6 的请求**必须**是 `application/octet-stream`。

**路由匹配语义（对 Plug 重实现至关重要）**：MinIO 用 gorilla-mux 的 `.Queries("k","{k:...}")`，含义是**该 query 参数必须存在，路由才匹配**，值经 `mux.Vars(r)` 取（不是只从 query string 读）。由此：

- `/list-users` 与 `/list-canned-policies` 各注册**两条**路由，带 `?bucket=` 的变体先匹配，走的是**另一个 handler**（`ListBucketUsers` / `ListBucketPolicies`，语义是"对该桶有权限的用户/策略"）。
  **裁决**：maxio **不实现**桶维度变体，且收到 `?bucket=` 时必须落 **501**，**绝不**忽略该参数后返回全量列表——运维问的是"哪些用户能访问桶 X"，回一个全量列表是**一个错误的答案**，比未实现危险得多（铁律 3）。
- `add-canned-policy` / `info-canned-policy` / `remove-canned-policy` 缺 `name`、`user-info` / `remove-user` 缺 `accessKey`、`set-user-status` 缺 `accessKey` 或 `status`、`group` 缺 `group`、`set-group-status` 缺 `group` 或 `status` 时，MinIO 侧**路由根本不匹配**（落到 admin 的兜底）。maxio 侧对应行为是返回 **400 `XMinioAdminInvalidArgument`**（我们没有"路由不匹配"这一层，用参数缺失的结构化错误表达，比 501 更准确）。
- `POST /idp/builtin/policy/{operation}` 的 `attach|detach` 是**路径变量**，不是 query。

### 1.2 版本前缀（顺带实锤，修正第二批的一处记录）

- `madmin-go` **main 分支已是 `/v4` 模块**，`AdminAPIVersion` 默认 `"v4"`（可被 `MADMIN_API_VERSION=v3` 环境变量压回 v3）。
- **但** MinIO OSS server master 仍依赖 `madmin-go/v3`，`mc` master 也仍依赖 `/v3`。`cmd/admin-router.go` 的 `adminAPIVersion = madmin.AdminAPIVersion` 在 v3 依赖下解析为 `"v3"`。
- 因此**当前真实 mc 的线上前缀就是 `/minio/admin/v3/`**，与第二批实测一致。
- madmin **v4** 的 `executeMethod` 在收到 **HTTP 426** 时会把 `relPath` 里的 `/v4` 换成 `/v3` 重试。

> **对第二批 §9.2 #6 的回写建议**：第二批把 `/minio/admin/v4/*` 落 501 而非 426，理由是"当前 mc 硬编码 v3，426 分支无法活体验证"。这条理由**依然成立**（mc 仍是 v3），但现在我们知道 426 回落**确实存在于 madmin v4 的 `executeMethod` 里**，不是推测。**本批仍不实现 426**——判据不变：没有会发 v4 的客户端，就无法取证。改判触发条件写明为：**当本机 mc 升级到依赖 madmin v4，或用 `MADMIN_API_VERSION` 之外的方式观察到真实 v4 请求时**，把 `/minio/admin/v4/*` 改为 426 并实测回落。记为 **V-B1**。

### 1.3 加密封装的算法（供后续独立批次使用，本批不实现）

> 来源：`madmin-go` 的 `encrypt.go` 与 `secure-io/sio-go` 的 `sio.go` / `writer.go` **全文读取**取证。本节是信封批次的规格说明，**本批不实现**。

madmin 的信封**不是** DARE 2.0，而是 `github.com/secure-io/sio-go` 的 `sio.Stream`（DARE 的 STREAM 式后继），外包一个 41 字节自定义头。

**线格式布局**：

```
salt(32) | AEAD-ID(1) | nonce(8) | sio.Stream 密文流
```

- **salt**：32 字节随机。
- **AEAD-ID**：`0x00` = argon2id + AES-256-GCM；`0x01` = argon2id + ChaCha20-Poly1305；`0x02` = pbkdf2 + AES-256-GCM（FIPS 模式）。**解密方必须三种都支持**——不得硬编码 AES。
- **KDF**：`argon2.IDKey(password, salt, time=1, memory=64*1024 KiB, threads=4, keyLen=32)`。`password` 就是调用方的 SigV4 secret key 的字节串。FIPS 分支为 `pbkdf2.Key(password, salt, 8192, 32, sha256)`。
- **nonce**：8 字节随机（`Stream.NonceSize() = cipher.NonceSize() - 4 = 12 - 4 = 8`）。
- **sio.Stream 分帧**：明文按 `BufSize = 1 << 14`（16384 B）切块；每块的 12 字节 AEAD nonce = `nonce8 || LE32(seqNum)`。
  - **seq 0 不承载数据**：写入方先构造 `associatedData := make([]byte, 1+cipher.Overhead())`（17 字节），置 `associatedData[0] = 0x00`，然后 `Seal(associatedData[1:1], nonce_seq0, nil, userAAD)`——即第 1..16 字节是对用户 AAD（madmin 传 `nil`）做空明文 seal 得到的 tag，作为**头绑定**。
  - **数据块从 seq 1 开始**，每块 `Seal(plaintext_chunk, nonce_seq_n, aad=associatedData)`。
  - **最后一块**在 seal 前把 `associatedData[0]` 改成 `0x80`（流终止标记）。非末块恒 `0x00`。
- **总长**：`32 + 1 + 8 + len(data) + 16*ceil(len(data)/16384)`（空明文也有一个 16 字节 tag）。
- `IsEncrypted(data)` 的嗅探条件：`len(data) > 32 && data[32] ∈ {0x00, 0x01, 0x02}`。

### 1.4 Elixir 侧可行性与工作量

| 组件 | 可行性 | 说明 |
|---|---|---|
| AES-256-GCM | ✅ 零成本 | `:crypto.crypto_one_time_aead(:aes_256_gcm, key, nonce, data, aad, tag_len, flag)` |
| ChaCha20-Poly1305 | ✅ 零成本 | `:crypto` 的 `:chacha20_poly1305` |
| PBKDF2-SHA256 | ✅ 零成本 | `:crypto.pbkdf2_hmac/5` |
| **argon2id(t=1, m=64MiB, p=4, len=32)** | ⚠️ **需要 NIF** | 纯 Elixir 实现不可接受（64 MiB × 4 线程的内存硬函数）。候选：`:argon2_elixir`（Comeonin 系，NIF 包 argon2 参考实现）——但它的公开 API 是 PHC 字符串风格，**必须核实它能否以显式参数产出裸 32 字节 raw hash**（`Argon2.Base.hash_password/3` 的 `:format => :raw_hash` 选项）。若不能，退路是按 `AGENTS.md` §2 已规划的 Rustler 路线写一个薄 NIF（`argon2` crate），这与"计算热点走 Rustler"的既有架构方向一致，不是新增架构面。 |
| sio.Stream 分帧 | ✅ 纯 Elixir | 逻辑简单但**逐字节敏感**：seq0 头绑定、末块 `0x80`、LE32 序号写在 nonce 尾 4 字节。必须用**官方测试向量**逐字节验证，不靠猜。 |

**性能**：argon2id(64 MiB, t=1, p=4) 每次调用约 30–80 ms 且占 64 MiB 峰值内存。加密端点是**低频管控面**，可接受；但必须：
1. **限制并发**（如经一个有界池/信号量串行化），否则 N 个并发 `mc admin user ls` 会瞬间吃掉 N×64 MiB；
2. **绝不缓存派生密钥**跨请求（salt 每次随机是安全前提，缓存会破坏它）；
3. 请求体大小硬上限（对齐 MinIO 的 `maxEConfigJSONSize`），并**拒绝 chunked**（MinIO `AddUser` 显式拒绝 `ContentLength == -1`）。

**工作量估计**：一个独立批次。构成 = argon2id NIF 接线（含 `mix.exs` 依赖决策）+ 信封编解码模块 + 测试向量取证（用真实 mc/MinIO 抓一组密文，或用一段 Go 程序生成向量落进 `test/support/fixtures/`）+ 与 admin plug 的接线。**它是密码学互操作批次，不是适配批次**——混进本批会同时拖慢两件事，且违反 `AGENTS.md` §5.3 的批次内聚要求。

### 1.5 由 V-A4 直接推出的分批

这张表就是本批范围的推导过程：

| mc 命令 | 依赖端点 | 需要信封？ | 落哪一批 |
|---|---|---|---|
| `mc admin policy create` / `add` | P1 | ❌ | **本批** |
| `mc admin policy ls` / `list` | P2 | ❌ | **本批** |
| `mc admin policy info` | P3 | ❌ | **本批** |
| `mc admin policy rm` / `remove` | P4 | ❌ | **本批** |
| `mc admin user info` | U3（+ G2 取 `memberOf`） | ❌ | **本批** |
| `mc admin user rm` / `remove` | U4 | ❌ | **本批** |
| `mc admin user enable` / `disable` | U5 | ❌ | **本批** |
| `mc admin group info` / `ls` | G1 / G2 | ❌ | 本批（相邻，见 §4.2） |
| `mc admin group add` / `rm` | G3 | ❌ | 本批（相邻，见 §4.2） |
| `mc admin group enable` / `disable` | G4 | ❌ | 本批（相邻，见 §4.2） |
| `mc admin user add` | U1 | ✅ REQ | **信封批次之后** |
| `mc admin user ls` / `list` | U2 | ✅ RESP | **信封批次之后** |
| `mc admin policy attach` / `detach` | P6 | ✅ REQ+RESP | **信封批次之后** |
| `mc admin policy entities` | P7 | ✅ RESP | **信封批次之后** |
| `mc admin user svcacct *` | S1–S5 | ✅ | 需要**新后端概念**，见 §3.6，**不做** |

> **关键取舍说明**：本批做不了 `mc admin user add`（U1 加密），因此本批的 user 面**只有读与状态变更**。这不是缺陷而是诚实的边界——用户创建仍走 `mix maxio.iam.create_user` + `mix maxio.iam.create_key`（已存在），而 `mc admin user info/enable/disable/rm` 能对这些用户正确工作，这恰好是**双向可见性**（§3.1）最强的活体证明：经 IAM/CLI 建的用户，MinIO 客户端看得见、管得了。

---

# 第二部分：端点 → maxio 能力映射

## 2. 授权 action

`Maxio.Admin.Authz.authorize(conn, principal, action)` 直接可用。下表的 action 名与**每个 handler 实际校验的常量**均已从 `minio/cmd/admin-handlers-users.go` 的 `validateAdminReq` / `IsAllowed` 调用与 `minio/pkg/v3@v3.1.3` 的 `policy/admin-action.go` 逐字取证：

| 端点 | MinIO handler 实际校验的 action | maxio 采用 |
|---|---|---|
| P1 `/add-canned-policy` | `CreatePolicyAdminAction = "admin:CreatePolicy"` | 同 |
| P2 `/list-canned-policies` | `ListUserPoliciesAdminAction = "admin:ListUserPolicies"` | 同 |
| P3 `/info-canned-policy` | `GetPolicyAdminAction = "admin:GetPolicy"` | 同 |
| P4 `/remove-canned-policy` | `DeletePolicyAdminAction = "admin:DeletePolicy"` | 同 |
| U3 `/user-info` | `GetUserAdminAction = "admin:GetUser"` | 同（**但不复制"查自己时只做 deny 检查"的放宽**，见下） |
| U4 `/remove-user` | `DeleteUserAdminAction = "admin:DeleteUser"` | 同 |
| U5 `/set-user-status` | **只校验 `EnableUserAdminAction = "admin:EnableUser"`**——无论 `status` 是 enabled 还是 disabled | 同 |
| G1 `/groups` | `ListGroupsAdminAction = "admin:ListGroups"` | 同 |
| G2 `/group` | `GetGroupAdminAction = "admin:GetGroup"` | 同 |
| G3 `/update-group-members` | **只校验 `AddUserToGroupAdminAction = "admin:AddUserToGroup"`**——无论 `isRemove` 真假 | 同 |
| G4 `/set-group-status` | `EnableGroupAdminAction = "admin:EnableGroup"` | 同 |
| P5 `/set-user-or-group-policy` | `AttachPolicyAdminAction = "admin:AttachUserOrGroupPolicy"` | 本批不做 |
| P6 `/idp/builtin/policy/{op}` | **两个**：`UpdatePolicyAssociationAction = "admin:UpdatePolicyAssociation"` + `AttachPolicyAdminAction` | 信封批次 |
| P7 `/idp/builtin/policy-entities` | **三个**：`ListGroupsAdminAction` + `ListUsersAdminAction` + `ListUserPoliciesAdminAction` | 信封批次 |

**三条必须逐字继承的反直觉事实**：

1. **`admin:DisableUser` / `admin:DisableGroup` 常量存在，但 `set-user-status` / `set-group-status` 的 handler 从不校验它们**——只校验 `Enable*`。maxio **照抄**：一个 action 名，enable/disable 都用它。
   **为什么不"改进"成按 status 分流**：那会让一份在真实 MinIO 上能同时 enable/disable 的 policy（只含 `admin:EnableUser`）在 maxio 上只能 enable——**同一份 policy 在两个实现上给出不同的授权结果**，这正是铁律 5 要防的兼容性漂移。若运维需要更细粒度，正确做法是向上游提，不是在适配层单方面加严。
2. **`G3` 的 add 与 remove 共用 `admin:AddUserToGroup`**，`RemoveUserFromGroupAdminAction` 常量同样存在但此 handler 不用。同上照抄。
3. **`AttachPolicyAdminAction` 的字符串是 `"admin:AttachUserOrGroupPolicy"`，不是 `"admin:AttachPolicy"`**——常量名与字符串不同名，极易写错。

**一处刻意的**不**对齐（更严，fail-closed）**：MinIO 的 `GetUserInfo` 在 `accessKey == 调用者自己` 时只做 deny-only 检查（即用户总能读自己的信息），`AddUser` 亦有 `implicitPerm` 自助改密路径。maxio **本批不实现这两处放宽**，一律走完整 `admin:GetUser` 判定。理由：`Maxio.Admin.Authz.authorize/3` 目前只有"完整判定"一种形态，加一个"deny-only"变体是**授权语义的扩展**，属于安全敏感改动，必须独立设计与独立复审，不能夹带在适配批次里。**偏离方向是更严（拒绝多于放行），不会造成越权**，且必须写进 README。记为 **V-B17**。

**裁决（铁律 3 + 铁律 5）**：任何 action 名未经源码实锤的端点，**一律落 501**，不用"看起来合理"的名字凑数。授权 action 名错了的后果是**授权判定错误**——比未实现严重得多。本批表内各项均已实锤，无待定项。

## 3. `mc admin policy *` → maxio

底座：`Maxio.Policy.ManagedPolicy`（表 `managed_policies`）+ `Maxio.Policy.ManagedPolicyVersion` + `Maxio.Policy.Store.EctoStore`，门面是 `Maxio.IAM`。

| 端点 | maxio 调用（精确到模块+函数） | 备注 |
|---|---|---|
| P1 `PUT /add-canned-policy?name=N`（body = policy JSON） | 新建：`Maxio.IAM.create_managed_policy_strict(policy_name: N, path: "/", document: body)`；已存在：`Maxio.IAM.create_managed_policy_version_strict(arn, body, true)` | 见 §3.3 的版本裁决 |
| P2 `GET /list-canned-policies` | `Maxio.IAM.list_managed_policies(path_prefix: "/")`，**再按 `path == "/"` 二次过滤** | `list_managed_policies/1` 用的是 `String.starts_with?(path, prefix)`，`"/"` 会匹配 `/team/` 等所有路径，必须显式收窄，见 §3.3 |
| P3 `GET /info-canned-policy?name=N[&v=2]` | `Maxio.IAM.get_managed_policy(arn)`；`arn = Maxio.IAM.managed_policy_arn(N, "/")` | 返回 `%{document:, inserted_at:, updated_at:, ...}` → `PolicyInfo` |
| P4 `DELETE /remove-canned-policy?name=N` | `Maxio.IAM.delete_managed_policy_strict(arn)` | 见 §3.3 的删除阻塞裁决 |
| P5 `/set-user-or-group-policy` | —— | **本批不做**，见 §3.4 |
| P6 `/idp/builtin/policy/{attach,detach}` | （未来）`Maxio.IAM.attach_user_policy_strict/2` / `detach_user_policy_strict/2` / `attach_group_policy_strict/2` / `detach_group_policy_strict/2` | 加密，信封批次之后 |
| P7 `/idp/builtin/policy-entities` | （未来）`Maxio.IAM.list_managed_policy_entities_strict/2` + `list_attached_user_policies_strict/2` + `list_attached_group_policies_strict/2` | 加密，信封批次之后 |

**响应 schema 要点（均已从 madmin-go v3.0.109 与 MinIO handler 取证）**：

- P2 客户端签名是 `ListCannedPolicies(ctx) (map[string]json.RawMessage, error)`——值是**未解释的原始 JSON**，因此线格式发 `{"<policyName>": <policy document object>, ...}` 即可，maxio 的 `document`（已解码 map）直接编码。
  `mc admin policy ls` **只打印名字**（`userPolicyMessage.String()` 的 `"list"` 分支只渲染 `u.Policy` = 名字），**每行一个，无表头**。所以文档内容正确与否 mc 屏幕上看不出来——**验收必须另取证据**（见 §7.2 A-3）。
- P3 的 `madmin.PolicyInfo` **没有 json tag**：
  ```go
  type PolicyInfo struct {
      PolicyName string
      Policy     json.RawMessage
      CreateDate time.Time `json:",omitempty"`
      UpdateDate time.Time `json:",omitempty"`
  }
  ```
  → 线上键名是 **`PolicyName` / `Policy` / `CreateDate` / `UpdateDate`（大驼峰）**。其余 madmin struct 全是小驼峰 json tag，这是**唯一的例外，也是本批最易写错的一点**。
- P3 的服务端分流（逐字）：`v=2` → `json.MarshalIndent(policyDoc)`（`PolicyInfo`）；`v` **为空** → `json.MarshalIndent(policyDoc.Policy)`（**裸 policy 文档**）；`v` 是**其它任何值** → 报错 `invalid version parameter 'v' supplied`。三条分支都要实现，第三条必须是 400 而不是当成 v2。
- mc 的 `admin policy info` 先调 `InfoCannedPolicyV2`（发 `v=2`），失败才回落 `InfoCannedPolicy`（不发 `v`）。**两条都要实现**，否则回落路径会拿到 501。
  `mc admin policy info` 的屏幕输出是 `json.MarshalIndent(PolicyInfo)`——**运维看到的就是 `PolicyName`/`Policy`/`CreateDate`/`UpdateDate` 四个大驼峰键**，键名错了肉眼可见。
- P1 成功输出：`Created policy \`<name>\` successfully.`；P4：`Removed policy \`<name>\` successfully.`

## 3.1 语义裁决 D-A：MinIO user ⇔ maxio「IAM user + 同名 access key」

**事实差**：

| | MinIO | maxio |
|---|---|---|
| user 是什么 | **就是一个 access key**（`accessKey` 即用户名，`secretKey` 即密码） | 两级：`iam_users` 行（`user_name` / `user_arn` / `status` / `tags` / `permissions_boundary_policy_arn`）+ 若干 `access_keys` 行（`access_key_id` / 加密封装的 `secret_key` / `principal_arn` / `type` / `status`） |
| 一个 user 能有几把凭据 | 1（额外凭据叫 service account） | N（`@access_key_quota_per_principal = 2`，仅 `create_access_key_strict/1` 强制） |
| 禁用 | `status: "disabled"` | `iam_users.status = "inactive"` **和** `access_keys.status = "inactive"` 两个独立字段 |

**裁决 D-A1（映射规则）**：**MinIO 的 user 名 ≡ maxio 的 `iam_users.user_name`**。

- `mc admin user info alice` → `Maxio.IAM.get_user("alice")`。
- `mc admin user rm alice` → `Maxio.IAM.delete_user("alice")`（**宽松版**，级联清理 principal policies / access keys / signing certs / SSH keys / STS sessions；MinIO 的 `RemoveUser` 正是这种级联语义。**不用** `delete_user_strict/1`——它在有下属实体时报 `:delete_conflict`，而 MinIO 的语义是删干净）。
- 未来 `mc admin user add alice PW` → 单事务内 `Maxio.IAM.create_user(user_name: "alice")` + `Maxio.IAM.create_access_key(access_key_id: "alice", secret_key: "PW", type: "iam_user", user_name: "alice")`。**`create_access_key/1` 已支持调用方指定 ak+sk**（`lib/maxio/iam.ex:355-357`，`mix maxio.iam.create_key --access-key --secret` 就是它的既有 CLI 证据），所以这条路是通的，只是被 U1 的加密挡在本批之外。

**为什么用 `iam_users` 而不是 `access_keys` 做权威 user 集合**：

1. **双向一致是硬要求**（第二批设计 §10 已写死："经 admin API 建的用户要能被 IAM Query API 看到，反之亦然，否则会出现两套互不可见的用户视图——那是最恶劣的静默失败"）。`iam_users` 是 IAM Query API（`ListUsers` / `GetUser` / `DeleteUser`）的权威表，也是授权链的权威（`Maxio.Policy.Store.EctoStore.principal_policies/1` 对 `u.status != "active"` 直接返回 `[]`，`Maxio.IAM.iam_user_principal_usable?/2` 是登录门）。选它，两个视图天然是同一份数据。
2. 若改用 `access_keys` 做 user 集合，`AKIA...` 这类**自动生成的密钥**会作为"用户"出现在 `mc admin user ls` 里，而它们在 IAM 语义下只是某个用户的凭据——那是**凭空造出一批 IAM 里不存在的用户**，是伪造。
3. root 凭据（`minioadmin`）也会被当成 user——MinIO 自己**不把 root 列进 ListUsers**。

**裁决 D-A2（不代表的东西，绝不编造）**：

- `iam_users` 行**没有**同名 access key 时（例如经 IAM Query `CreateUser` 建的用户），`mc admin user info` 仍返回它的真实 `status` / `policyName` / `memberOf`。**`UserInfo` 的 `secretKey` 字段一律不填**（MinIO 的 `GetUserInfo` / `ListUsers` 也从不回 secret）。
  - MinIO 模型隐含"user 必有凭据"，maxio 可能没有。`UserInfo` **没有**任何字段能表达"此用户暂无凭据"。**不得**为此编造字段值，也**不得**因此把该用户从视图里抹掉（抹掉 = 对 admin 工具隐藏真实 principal，运维会以为名字可用而去创建，撞上 `EntityAlreadyExists`）。
  - **诚实出路走 CLI + 日志**（`CLAUDE.md` 强制的 CLI 优先）：新增 `mix maxio.admin.user.show <name>`（见 §6）明确打印"是否有同名 access key"，并在 admin 面响应时对无凭据用户打一条结构化 `Log.info`（`credential_bearing: false`）。
- maxio 里**不属于任何 `iam_users` 行的 access key**（`AKIA...`、root、legacy self-ARN 密钥）**一律不出现在 user 视图**。它们语义上最接近 MinIO 的 **service account**，而 service account 是 S1–S5 的加密端点族且需要新后端概念（§3.6），**本批不做**。

**裁决 D-A3（status 唯一事实来源）**：`mc admin user enable/disable` **只写 `iam_users.status`**，不碰 `access_keys.status`。

- 理由：`iam_users.status = "inactive"` 已经足以让该用户的所有凭据失效（`EctoStore.get_secret/2` → `access_key_principal_usable?/1` → `IAM.iam_user_principal_usable?/2` 要求用户行存在且 `"active"`；`principal_policies/1` 对非 active 用户返回 `[]`）。**同时写两个字段会造出两个可以互相矛盾的开关**——运维经 IAM Query 把 key 设回 Active，用户仍被 user 级 status 挡住，于是"我明明启用了却还是 403"。一个语义一个开关（铁律 3 的明确状态设计）。
- `mc admin user info` 的 `status` 也**只读 `iam_users.status`**，映射 `active → "enabled"` / `inactive → "disabled"`（`madmin.AccountStatus` 的合法取值就这两个：`AccountEnabled = "enabled"` / `AccountDisabled = "disabled"`）。收到其它 `status` 值一律 **400**，绝不静默当成 disable。
- **禁止改自己的状态（逐字继承 MinIO）**：`SetUserStatus` 在 `accessKey == creds.AccessKey` 时直接 `errInvalidArgument`。maxio 照抄——这既是兼容性也是一条真实的安全性质（防止管理员把自己锁在门外，以及防止一次误操作制造不可恢复状态）。

**`madmin.UserInfo` 的线格式（v3.0.109 逐字）**：

```go
type UserInfo struct {
    AuthInfo   *UserAuthInfo `json:"userAuthInfo,omitempty"`
    SecretKey  string        `json:"secretKey,omitempty"`
    PolicyName string        `json:"policyName,omitempty"`
    Status     AccountStatus `json:"status"`
    MemberOf   []string      `json:"memberOf,omitempty"`
    UpdatedAt  time.Time     `json:"updatedAt,omitempty"`
}
```

maxio 的逐字段裁决（延续第二批 §10.5 的 omit 纪律）：

| 字段 | maxio 数据源 | 裁决 |
|---|---|---|
| `status` | `iam_users.status` → `enabled`/`disabled` | 真实；**唯一无 omitempty 的字段，必发** |
| `policyName` | 已附加 managed policy 的名字逗号连接（§3.2） | 真实但**是偏序视图**，见 D-B |
| `memberOf` | `Maxio.IAM.list_groups_for_user/1` 的组名 | 真实 |
| `updatedAt` | `iam_users.updated_at` | 真实 |
| `secretKey` | —— | **恒 omit**（MinIO 的 `GetUserInfo` 也从不回 secret） |
| `userAuthInfo` | maxio 无外部 IdP 认证元数据概念 | **omit**（指针 + omitempty，安全）。`mc admin user info` 的 `Authentication:` 行随之不出现 |

`mc admin user info` 的屏幕输出形如 `AccessKey: / Status: / PolicyName: / MemberOf:`（`userMessage.String()` 的 `"info"` 分支），`Authentication:` 仅在 `userAuthInfo` 存在时出现。

**裁决 D-A4（唯一的非适配层新增）**：`Maxio.IAM` **目前没有 user/group 的 status setter**（全仓 `grep "def update_user_status|def update_group_status"` 零命中；`create_user/1` 只在创建时接受 `:status`）。

- 本批需要新增 `Maxio.IAM.update_user_status_strict/2`（与 `update_user_name_strict/2` 并列，走同一 changeset、同一 `Notify.broadcast({:iam_changed, arn})` 失效通路）。
- **这是本批唯一一处"新增后端能力"**，且它只是既有列的 setter，不是新概念、不改 schema、不改授权语义。明确标注在此，避免与"本批是纯适配层"的定位冲突。
- 配套 CLI：`mix maxio.iam.update_user --name N --status active|inactive`（`AGENTS.md` §4.4 强制）。
- **若评审认为这一点也应移出本批**，退路是：本批不做 U5，`mc admin user enable/disable` 落 501，其余不变。本文推荐做——理由是这个 setter 的缺失本身就是既有 schema 的一个缺口（列存在、没有改它的路径），补上它对 IAM 面也是净收益。

## 3.2 语义裁决 D-B：`UserInfo.policyName` —— 只报**已附加的 managed policy**

**事实差**：MinIO 每个 user 只有**一条 policy mapping**，值是**逗号分隔的 canned policy 名列表**。maxio 的一个用户的有效策略来自**五个来源**（`EctoStore.principal_policies/1`，`lib/maxio/policy/store/ecto_store.ex:72-84`）：

1. 用户 inline principal policies
2. 用户 attached managed policies
3. 组继承的 inline policies
4. 组继承的 managed policies
5. role attached managed policies

**裁决**：`UserInfo.policyName` = 来源 2 的**策略名**逗号连接（从 ARN 末段取名），**其余四类一律不进这个字段**。

**为什么不把 inline policy 也塞进去**：`policyName` 在 MinIO 的语义里是**可被 `mc admin policy attach/detach` 操纵的名字集合**。塞进一个 inline policy 名，会让运维执行 `mc admin policy detach --user alice --policy p`，而 detach 对 inline policy 无效——**一个看起来能用、实际不生效的控制面**，正是 `AGENTS.md` §3 铁律 3 最忌讳的形态。

**为什么不把组继承的也塞进去**：MinIO 的 `UserInfo` 用 `memberOf` 表达组关系，组的策略由 `mc admin group info` 显示。把组策略提升到 user 的 `policyName` 会让 detach 语义同样错位。

**"少报"的诚实性补偿（必须做，否则就是静默隐藏权限）**：

1. 当被列出的用户存在来源 1/3/4/5 的策略时，服务端打**结构化 `Log.info`**：`action: "admin_user_info"`, `user_name:`, `managed_policies: n`, `inline_policies: n`, `group_inherited: n`, `role_attached: n`, `minio_view_partial: true`。
2. 新增 `mix maxio.admin.user.show <name>`：**完整**打印五类来源，并明确标出哪些能在 MinIO 视图里看到、哪些看不到。
3. 在 `Maxio.Admin` 相关模块 moduledoc + README 写死一句：**MinIO admin 面是 maxio IAM 的一个偏序视图；任何安全审计必须用 IAM Query API / `mix maxio.iam.*` CLI，不得以 `mc admin user info` 的输出为准**。

**名字含 `,` 的 managed policy**：maxio 的 `@managed_policy_name_pattern = ~r/\A[A-Za-z0-9+=,.@_-]+\z/` **允许逗号**，而 MinIO 的 `AddCannedPolicy` 显式拒绝名字含 `,`（因为它自己的 mapping 就是逗号连接）。裁决：

- P1 收到含 `,` 的 `name` → **拒绝**，`400`，消息对齐 MinIO 的检查（同时也拒绝首尾空格，虽然 maxio 的字符集本就不含空格）。
- 已存在的、经 IAM Query 建的含 `,` 名字策略：P2 里**照常列出**（map key 是独立 JSON 字符串，无歧义），但**从任何 `policyName` 逗号连接中排除**并打 `Log.warn`。绝不产出一个会被客户端切成两半的名字。

## 3.3 语义裁决 D-C：canned policy ⇔ maxio managed policy

**事实差**：

| | MinIO canned policy | maxio managed policy |
|---|---|---|
| 标识 | 扁平 name | ARN `arn:aws:iam:::policy/<path><name>` |
| path | 无 | 有（`validate_managed_policy_path/1`，默认 `/`） |
| 版本 | 无 | 有（`managed_policy_versions`，`@versions_per_policy_quota = 5`，一个 default） |
| description / tags | 无 | 有 |
| 更新 | `add-canned-policy` 同名即覆盖 | `CreatePolicyVersion` + `SetDefaultPolicyVersion`（无 `UpdatePolicy`） |
| 删除时已被附加 | MinIO 允许（并清理 mapping） | `EctoStore.delete_managed_session_policy/1` **拒绝**：`{:error, :policy_attached}` |
| 删除时有非默认版本 | 不适用 | **拒绝**：`{:error, :policy_has_non_default_versions}` |

**裁决 D-C1（命名空间）**：canned name `N` ⇔ `arn:aws:iam:::policy/N`（即 **path 恒 `/`**）。

- P2 必须在 `list_managed_policies(path_prefix: "/")` 之后**再按 `path == "/"` 过滤**。`list_managed_policies/1` 的实现是 `String.starts_with?(&1.path, path_prefix)`（`lib/maxio/iam.ex:1708`），`"/"` 会匹配 `/team/` 等**全部**路径，不收窄就会把 `/team/ops` 这类策略以 name `ops` 列出——而 `mc admin policy info ops` 会去查 `arn:aws:iam:::policy/ops`（不存在）→ 404。**一个列得出、查不到的名字**是典型的静默不一致。
- 被过滤掉的非 `/` path 策略：打结构化 `Log.info`（`omitted_non_root_path_policies: n`），并在 `mix maxio.admin.policy.list` CLI 里显式列出被省略者与原因。**不隐瞒**。
- **V-B5**：核实 maxio 是否真的允许经任何路径创建非 `/` path 的 managed policy（`Maxio.IAM.QueryPlug` 对 **user** 的 path 只允许 `/`，policy 的 path 处理需逐条确认）。若实际上不可能存在非 `/` path 策略，本条退化为一句防御性断言。

**裁决 D-C2（同名再次创建 = 新建默认版本，不是原地覆盖）**：

P1 对已存在的 name → `Maxio.IAM.create_managed_policy_version_strict(arn, body, true)`。

- **为什么不用 `Maxio.IAM.put_managed_policy/1`**：它是 upsert 且**会把版本历史重置成单个 v1**（其文档明写"tests/seed/STS fixtures only"）。从生产管控面调它，等于让一次 `mc admin policy create` **静默销毁**别人经 IAM Query 建立的 v1..vN 历史。销毁审计痕迹是不可接受的（铁律 3）。
- **版本配额（5）耗尽时**：返回结构化 400，message 必须**可执行**——写明"该策略已有 5 个版本（AWS 上限），请先删除一个非默认版本：`mix maxio.iam.managed_policy.*` 或 IAM Query `DeletePolicyVersion`"。**绝不**自动删除最老版本（那是在运维背后销毁数据）。
- 这与 AWS 一致（AWS 的 `CreatePolicyVersion` 在 5 版本时报 `LimitExceeded`），与 MinIO 不一致（MinIO 无版本概念）。**这是一处已知偏离，必须写进 README**。

**裁决 D-C3（删除阻塞照实报，绝不级联解绑）**：

P4 直接用 `delete_managed_policy_strict/1`，其两种拒绝原因**原样映射成结构化错误**：

| 底层 reason | HTTP | 消息要求 |
|---|---|---|
| `:policy_attached` | 400 | 列出**阻塞的实体**（users/groups/roles，取自 `Maxio.IAM.list_managed_policy_entities_strict/2`），并指出用 `mix maxio.iam.detach_user_policy` 等先解绑 |
| `:policy_has_non_default_versions` | 400 | 写明版本数，并指出先 `DeletePolicyVersion` |

- **为什么不级联解绑**：解绑是**权限变更**。把它藏在一次 `mc admin policy rm` 后面，等于让一条删除命令静默地改掉 N 个 principal 的权限边界。这与 MinIO 的行为不同，但 MinIO 的行为在这里是更危险的一方；`AGENTS.md` 铁律 5 要求"对齐真实实现"，但铁律 3 要求"绝不静默"——两者冲突时以**不静默改权限**为准，并把偏离写进文档。
- 直接后果：`mc admin policy create X` 两次之后 `mc admin policy rm X` 会失败。**这必须写进验收清单作为期望行为**（§7 A-6），否则实现者会误当 bug 去"修"。

**裁决 D-C4（description / tags / 版本对 MinIO 不可见）**：`PolicyInfo` 无对应字段 → **omit**，不塞进 `Policy` 文档里，不编造。`CreateDate` / `UpdateDate` 用真实的 `inserted_at` / `updated_at`。

**裁决 D-C5（内置 canned policy：maxio 没有，不伪造）**：

真实 MinIO 开箱自带**恰好 5 个**（`minio/pkg/v3@v3.1.3` 的 `policy/constants.go` 的 `DefaultPolicies`，由 `minio/cmd/iam.go` 的 `setDefaultCannedPolicies/1` 装入，且**删除时被守护**）：

| 名字 | 文档（逐字语义） |
|---|---|
| `readwrite` | Allow `s3:*` on `arn:aws:s3:::*` |
| `readonly` | Allow `s3:GetBucketLocation`, `s3:GetObject` on `*` |
| `writeonly` | Allow `s3:PutObject` on `*` |
| `diagnostics` | Allow `admin:Profiling`, `admin:ServerTrace`, `admin:ConsoleLog`, `admin:ServerInfo`, `admin:TopLocksInfo`, `admin:OBDInfo`(HealthInfo), `admin:BandwidthMonitor`, `admin:Prometheus` on `*` |
| `consoleAdmin` | 三条 statement：`admin:*`（空 resource 集）、`kms:*`（空 resource 集）、`s3:*` on `*` |

maxio **一个都没有**（全仓无 canned/内置策略概念；`list_managed_policies(scope: "AWS")` 刻意返回 `[]`）。

- 裁决：**本批不做自动 seed**。全新 maxio 上 `mc admin policy ls` 输出**空**，这是真话。
- **绝不**为了"看起来像 MinIO"而预置同名策略。尤其 `consoleAdmin` 含 `admin:*`——**在一个全新部署里凭空创建一个 `admin:*` 策略是一次实打实的安全姿态变更**，绝不能作为适配批次的副作用发生。
- 上表的文档已足够精确，可以在文档里给出一份**可选的、逐条写明内容的** `mix maxio.iam.managed_policy.create` 配方，让运维**自己决定**是否建立 MinIO 兼容名的策略。是否内置进产品（以及 `kms:*` 在 maxio 下的确切含义）作为独立决策批次 **B-LATER-P1**。
- 另一处必须记住的差异：MinIO **禁止删除**这 5 个内置策略。maxio 没有内置策略，因此也没有这条保护——`mc admin policy rm readwrite` 在 maxio 上会返回 404 `XMinioAdminNoSuchPolicy`（真话），而不是 MinIO 的"内置策略不可删"。若将来 seed 了它们，必须同时补上删除守护，否则会出现"能删掉自己的内置策略"的不一致。

## 3.4 语义裁决 D-D：attach 语义 / `/set-user-or-group-policy` 不做

- MinIO 现在的 attach/detach 走 P6（`PolicyAssociationReq{User|Group, Policies[]}`，**集合并/差语义**，返回 `policiesAttached` / `policiesDetached`）。这与 AWS/maxio 的 `AttachUserPolicy`（每对一行，天然集合语义）**语义上是对齐的**——差别只在批量与返回值。因此信封批次之后，P6 → `Maxio.IAM.attach_user_policy_strict/2` 逐条调用即可，**无语义鸿沟**。需注意 maxio 有 `@user_managed_policy_attachment_quota = 10`（MinIO 无），超限须返回结构化 400 而不是部分成功——**部分成功必须避免**，整批 attach 走单事务，全成或全败。
- P5 `/set-user-or-group-policy` 是**明文**的（query-only，无 body），技术上本批就能做。**裁决：不做。** 理由三条：
  1. 它的语义是 **replace**（整体替换 mapping），不是 attach。用它冒充 attach 会让语义错位。
  2. 当前 `mc` 的 `admin policy set/unset/update` 已 `deprecatedError` + `Hidden: true`，**没有任何真实客户端会调它**——按第二批 §9.2 #6 已确立的判据（"不实现无法活体验证的分支"），实现它只会多出一段没人走过、却宣称支持某种语义的代码。
  3. 它落进 501 兜底，运维看到的是诚实的"未实现"。
  若将来出现真实调用方（老版本 mc / 第三方工具），再单独开分支并实测，记为 **V-B6**。

## 3.5 语义裁决 D-E：group

- `Maxio.IAM.Group`（`iam_groups`）有 `group_name` / `group_arn` / `status` / `tags`。
- **组 status 确实被授权链强制**：`EctoStore.inherited_group_policy_statements/1` 与 `inherited_group_managed_policy_statements/1` 的 where 子句都含 `g.status == "active"`（`lib/maxio/policy/store/ecto_store.ex:1040, 1082`）。所以 `mc admin group enable/disable` **不是空开关**，映射是诚实的。
  - 但同 D-A4：`Maxio.IAM` 也**没有 group status setter**，需要 `update_group_status_strict/2`。若评审要求把新增 setter 全部移出本批，则 G4 一并落 501。
  - G4 的 action 已实锤为 `EnableGroupAdminAction = "admin:EnableGroup"`（enable/disable 共用，同 §2 的反直觉事实 1）。
- G3 `/update-group-members`（明文）→ `Maxio.IAM.add_user_to_group_strict/2` / `remove_user_from_group_strict/2`，按 `GroupAddRemove.isRemove` 分流；`members` 是列表 → 单事务批量，全成或全败。
  - `GroupAddRemove` 逐字为 `{group, members, groupStatus, isRemove}`。**`groupStatus` 是 `GroupStatus` 类型（`"enabled"`/`"disabled"`），在这个端点上 MinIO 能顺带设状态**。
    **V-B7**：核实真实 `mc admin group add/rm` 是否会填 `groupStatus`（推测为零值空串）。裁决：**空串 = 不改状态**；**非空则必须一并处理或明确 400 报错**，绝不静默忽略一个客户端明确表达了的意图（铁律 3）。
  - MinIO 侧还有 `ErrAdminGroupNotEmpty`（`XMinioAdminGroupNotEmpty`, 400, `The specified group is not empty - cannot remove it.`）——`isRemove` 且 `members` 为空表示**删组**，组非空时拒绝。maxio 的 `delete_group_strict/1` 有同构的 `:delete_conflict` 语义，直接映射到这个码。
- G2 `GroupDesc` 逐字为：
  ```go
  type GroupDesc struct {
      Name      string    `json:"name"`
      Status    string    `json:"status"`
      Members   []string  `json:"members"`
      Policy    string    `json:"policy"`
      UpdatedAt time.Time `json:"updatedAt,omitempty"`
  }
  ```
  maxio 映射：`name` ← `iam_groups.group_name`；`status` ← `iam_groups.status`（active→`enabled`）；`members` ← `Maxio.IAM.list_users_in_group/1` 的 `user_name`；`policy` ← **组已附加 managed policy 的名字逗号连接**（与 §3.2 D-B 对 user 的裁决同构：**组的 inline policy 不进这个字段**，同样打结构化日志 + CLI 全量对照）；`updatedAt` ← `iam_groups.updated_at`。
  → **V-B8 已消解，G2 本批可做。**
- `mc admin user info` 的 `memberOf` → `Maxio.IAM.list_groups_for_user/1`（只取组名）。不依赖 `GroupDesc`，**本批就能做**。

## 3.6 语义裁决 D-F：service account —— **本批不做，且需要新后端概念**

MinIO 的 service account = 挂在某个 parent user 之下的**第二把凭据**，可携带一份**内嵌 session policy**（`AddServiceAccountReq.Policy`），有 name / description / expiration。

maxio 侧：

- 「一个用户多把 access key」**已有**（`access_keys.principal_arn` 指向同一 user ARN，配额 2）。
- 「凭据级内嵌 session policy」**没有**——maxio 的 session policy 只存在于 STS session（`sts_sessions`），长期 access key 没有这个字段。
- name / description / expiration 在 `access_keys` 上**都没有列**。

**裁决**：service account 需要**新增后端概念 + schema 迁移**，按本批"纯适配层"的定位与 `AGENTS.md` §5.3 的批次内聚要求，**移出本批**，且**不在信封批次里顺手做**。它是一个独立的 IAM 能力批次（记为 **B-LATER-S1**）。在此之前 S1–S5 全部落 501。

**绝不做的事**：把 maxio 已有的、属于某用户的额外 access key 直接冒充成 service account 返回。它们**没有** name/description/expiration/embedded policy，硬填空值或编造值会让运维以为 maxio 支持一套它并不支持的凭据模型。

---

# 第三部分：范围、验收、清单

## 4. 本批范围

### 4.1 最小可信范围（判据：让具体的 `mc admin` 命令真正跑通）

**核心切片 S-1「policy CRUD 闭环」** —— 零加密、零新后端能力、纯适配：

| 端点 | action | 判据命令 |
|---|---|---|
| P1 `PUT /minio/admin/v3/add-canned-policy?name=N` | `admin:CreatePolicy` | `mc admin policy create maxio p-ro ./p.json` |
| P2 `GET /minio/admin/v3/list-canned-policies` | `admin:ListUserPolicies` | `mc admin policy ls maxio` |
| P3 `GET /minio/admin/v3/info-canned-policy?name=N[&v=2]` | `admin:GetPolicy` | `mc admin policy info maxio p-ro` |
| P4 `DELETE /minio/admin/v3/remove-canned-policy?name=N` | `admin:DeletePolicy` | `mc admin policy rm maxio p-ro` |

这四条构成一个**完整可闭环、可反复执行的活体回路**，是本批的**硬底线**。

**核心切片 S-2「user 读 + 状态」** —— 零加密，含 §3.1-D-A4 的一个 setter：

| 端点 | action | 判据命令 |
|---|---|---|
| U3 `GET /user-info?accessKey=N` | `admin:GetUser` | `mc admin user info maxio alice` |
| U5 `PUT /set-user-status?accessKey=N&status=enabled\|disabled` | `admin:EnableUser` / `admin:DisableUser` | `mc admin user enable/disable maxio alice` |
| U4 `DELETE /remove-user?accessKey=N` | `admin:DeleteUser` | `mc admin user rm maxio alice` |

**S-2 的价值不只是三条端点**：它是「经 `mix maxio.iam.*` 建的用户，MinIO 客户端看得见、管得了、禁用后 S3 请求真的 403」这一**双向一致性**的活体证明——这正是第二批设计点名的最恶劣风险（两套互不可见的用户视图）的反证。

**相邻切片 S-3「group 读 + 成员变更」** —— 零加密，`memberOf` 的必要支撑：

| 端点 | action | 判据命令 | 前置 |
|---|---|---|---|
| G1 `GET /groups` | `admin:ListGroups` | `mc admin group ls maxio` | —— |
| G2 `GET /group?group=N` | `admin:GetGroup` | `mc admin group info maxio g1` | —— |
| G3 `PUT /update-group-members` | `admin:AddUserToGroup`（add/rm 共用） | `mc admin group add/rm maxio g1 alice` | V-B7（`groupStatus` 字段） |
| G4 `PUT /set-group-status?group=N&status=...` | `admin:EnableGroup`（enable/disable 共用） | `mc admin group enable/disable maxio g1` | 依赖 `update_group_status_strict/2`（同 D-A4） |

### 4.2 建议的收口方式

- **S-1 必须做**（本批存在的理由）。
- **S-2 建议做**（含 `update_user_status_strict/2` 一个 setter；若评审否决新增 setter，则 U5 落 501，S-2 退化为 U3+U4）。
- **S-3 建议做 G1 + G2 + G3 + `memberOf`**（G1/G2 纯读、G3 复用既有 strict 函数）；G4 与 U5 同进退（都依赖新增一个 status setter）。
- 三个切片共享同一套适配骨架（同一 dispatch 表、同一错误映射、同一 CLI 家族），合并为**一个 coherent batch** 收口一次 `mix precommit`。
- **统一落 501 的项（必须逐条有测试）**：U1 `/add-user`、U2 `/list-users`（含 `?bucket=` 变体）、P2 的 `?bucket=` 变体、P5 `/set-user-or-group-policy`、P6 `/idp/builtin/policy/{op}`、P7 `/idp/builtin/policy-entities`、S1–S5 service account、`/list-access-keys-bulk`、`/accountinfo`、`/minio/admin/v4/*`。

### 4.3 明确**不在**本批

| 项 | 理由 |
|---|---|
| `mc admin user add` / `ls` | U1/U2 加密（§1.1），依赖信封批次 |
| `mc admin policy attach` / `detach` / `entities` | P6/P7 加密 |
| `mc admin user svcacct *` | 需新后端概念 + 迁移（§3.6），B-LATER-S1 |
| madmin 信封（argon2id + sio.Stream） | 独立密码学互操作批次（§1.4），需官方测试向量 |
| P5 `/set-user-or-group-policy` | 语义是 replace 非 attach，且当前 mc 不调用（§3.4） |
| `/minio/admin/v4/*` → 426 | 无 v4 客户端可取证（§1.2，V-B1） |
| 内置 canned policy seed | 独立决策批次 B-LATER-P1（§3.3 D-C5） |
| `mc admin config get/set` | 仍依赖信封（第二批 D10） |

### 4.4 后续批次边界

```
本批（S-1/S-2/S-3）  →  明文适配层，零加密
        ↓
批次 E（信封）        →  argon2id NIF + sio.Stream 编解码 + 官方向量
        ↓
批次 F（加密适配）    →  U1/U2（user add/ls）、P6/P7（attach/detach/entities）
        ↓
批次 G（B-LATER-S1）  →  service account：access_keys 加 name/description/expiration/embedded policy 列 + 迁移 + IAM 面 + CLI，然后 S1–S5
```

`mc admin heal / trace / console`（第二批设计 §11 第三批）与本链条正交，互不阻塞。

## 5. 错误契约

**复用 `%Maxio.S3.Error{}` + `Maxio.Admin.ErrorView`，不新建错误体系**（第二批 D11 已确立）。本批只需给 `Maxio.S3.Error` 的 `@table` **追加 admin 专用码**——表里已有先例 `bucket_quota_exceeded → {"XMinioAdminBucketQuotaExceeded", 400, ...}`。

`Maxio.IAM` 的错误原子 → admin 线错误的映射（新增一个 `Maxio.Admin.ErrorMap`，与 `Maxio.IAM.QueryError` 的 `error_from_reason/1` **平行而非共用**——一个是 Query XML 契约，一个是 admin JSON 契约，共用会让两套线格式互相牵制）：

**需要追加进 `Maxio.S3.Error` 的 `@table` 的 admin 码（已从 `minio/cmd/api-errors.go` 逐字取证，Code / HTTP / Description 原文）**：

| 原子 | Code | HTTP | Description（逐字） |
|---|---|---|---|
| `admin_no_such_user` | `XMinioAdminNoSuchUser` | 404 | `The specified user does not exist.` |
| `admin_no_such_group` | `XMinioAdminNoSuchGroup` | 404 | `The specified group does not exist.` |
| `admin_no_such_policy` | `XMinioAdminNoSuchPolicy` | 404 | `The canned policy does not exist.` |
| `admin_invalid_argument` | `XMinioAdminInvalidArgument` | 400 | `Invalid arguments specified.` |
| `admin_group_not_empty` | `XMinioAdminGroupNotEmpty` | 400 | `The specified group is not empty - cannot remove it.` |
| `admin_resource_invalid_argument` | `XMinioInvalidResource` | 400 | `Policy, user or group names are not allowed to begin or end with space characters` |
| `malformed_policy_wire` | `MalformedPolicy` | 400 | 来自 `toAPIError` 对 `policy.Error` 的 type switch（不是 `@table` 常量），Description 是解析错误原文 |

（信封批次才会用到、本批**不追加**：`XMinioAdminPolicyChangeAlreadyApplied` 400、`XMinioPolicyAlreadyAttached` 409、`XMinioPolicyNotAttached` 404、`XMinioAdminNoSuchAccessKey` 404、`XMinioInvalidIAMCredentials` 403/404。其中 `XMinioAdminPolicyChangeAlreadyApplied` 尤其关键：`mc admin policy attach` 显式容忍这一个错误码（`if e != nil && madmin.ToErrorResponse(e).Code != errCodeChangeAlreadyApplied`），**重复 attach 不回这个码 mc 就会硬失败**。）

**`Maxio.IAM` 错误原子 → admin 线错误的映射**（新增 `Maxio.Admin.ErrorMap`，与 `Maxio.IAM.QueryError` 的 `error_from_reason/1` **平行而非共用**——一个是 Query XML 契约、一个是 admin JSON 契约，共用会让两套线格式互相牵制）：

| `Maxio.IAM` reason | admin Code | HTTP | 备注 |
|---|---|---|---|
| `get_user/1` 返回 `:error` | `XMinioAdminNoSuchUser` | 404 | —— |
| `get_group/1` 返回 `:error` | `XMinioAdminNoSuchGroup` | 404 | —— |
| `get_managed_policy/1` 返回 `:error` / `:not_found` | `XMinioAdminNoSuchPolicy` | 404 | —— |
| `:already_exists` | `XMinioAdminInvalidArgument` | 400 | MinIO 的 `AddCannedPolicy` 是覆盖语义，无 already-exists；maxio 走 §3.3 D-C2 的新版本路径，只有真正的冲突才落这里 |
| `:malformed_policy_document` | `MalformedPolicy` | 400 | message 带解析原因 |
| `:policy_limit_exceeded` / `:limit_exceeded` | `XMinioAdminInvalidArgument` | 400 | message 必须写明是哪个配额（版本数 / 附加数 / 账户策略总数）与解法 |
| `:policy_attached` | `XMinioAdminInvalidArgument` | 400 | message 列出阻塞实体（§3.3 D-C3） |
| `:policy_has_non_default_versions` | `XMinioAdminInvalidArgument` | 400 | message 含版本数与解法（§3.3 D-C3） |
| `:delete_conflict`（删组时组非空） | `XMinioAdminGroupNotEmpty` | 400 | —— |
| 名字含 `,` / 首尾空格 | `XMinioInvalidResource` | 400 | 逐字对齐 MinIO 的同名检查（§3.2） |
| `:malformed`（参数形状）、缺失必需 query 参数 | `XMinioAdminInvalidArgument` | 400 | 缺参数在 MinIO 侧是"路由不匹配"，maxio 用这个码表达 |
| 授权拒绝 | `AccessDenied` | 403 | 已有；deny reason **只进日志不进 body** |
| 未实现端点 | `NotImplemented` | 501 | 已有 |
| 其它异常 | `InternalError` | 500 | `Admin.Plug` 的既有 try/rescue，内部路径/密钥绝不外泄 |

> **纪律**：以上 Code 串**全部来自实锤**。任何将来新增的 admin 错误，若其 Code 串未从 `minio/cmd/api-errors.go` 取证，**一律回落到已实锤的 `XMinioAdminInvalidArgument` / `AccessDenied` / `NotImplemented` / `InternalError`，绝不自造 `XMinio*` 串**——mc 会把未知 Code 原样打给运维，一个编造的 Code 会污染排障。
>
> **V-B18（残留）**：`toAdminAPIErr` / `toAdminAPIErrCode` 的函数体未取到（`cmd/admin-handlers.go` 过大，WebFetch 截断）。它们在 `toAPIErrorCode` 之上可能还加了额外分支。影响面：某些内部错误的最终 Code 可能与上表不同。**缓解**：上表覆盖的是我们自己会主动产生的错误，不依赖 MinIO 的兜底链；实测阶段用真实 mc 对照即可发现差异。

**参数校验（在打到 `Maxio.IAM` 之前）**：

- `name` / `accessKey` / `group` 缺失或空 → 400，不落到 `Maxio.IAM` 让它返回 `:malformed`（早失败，错误消息更准）。
- P1 的 body：`Content-Length` 必须 > 0 且 ≤ 上限（对齐 MinIO 的 `maxEConfigJSONSize`，**V-B10** 取其确切值）；**拒绝 chunked**（`Content-Length == -1`），与 MinIO `AddUser` 的检查同构。
- **铁律 4（body 绝不进内存）**：admin 面的 body 全是小 JSON，走**带上限的整读**（与 `CompleteMultipartUpload` / `Delete` 同类），**绝不**挂 `Plug.Parsers`，**绝不**无上限 `read_body`。上限必须硬失败（413/400），不得截断后继续解析。

## 6. CLI + 结构化日志（`AGENTS.md` §4.4 强制）

**每个 admin 端点都要有一个不经 HTTP、不经签名的本地复算对照**（延续 `mix maxio.admin.info` 已确立的模式：`Maxio.Config.CLI.boot()` → 直接调聚合层 → `--json`）。它把排障空间对半砍：CLI 正常 = 问题在 HTTP/签名/线格式；CLI 就报错 = 数据源坏了。

| 任务 | 作用 |
|---|---|
| `mix maxio.admin.policy.list [--json]` | 本地复算 P2 的响应体；**额外**列出被 path 过滤掉的策略与原因（§3.3 D-C1） |
| `mix maxio.admin.policy.show <name> [--json]` | 本地复算 P3（含 `v=2` 与裸文档两种形态） |
| `mix maxio.admin.user.show <name> [--json]` | 本地复算 U3；**额外**打印：是否有同名 access key、五类策略来源的完整清单、哪些在 MinIO 视图里不可见（§3.1 D-A2 / §3.2 D-B 的诚实性补偿） |
| `mix maxio.iam.update_user --name N --status active\|inactive` | D-A4 新增 setter 的 CLI 面 |
| `mix maxio.iam.update_group --name N --status active\|inactive` | D-E（若 S-3 含 G4） |

**结构化日志字段**（须加入 `config/config.exs` 的 logger metadata 白名单，否则被静默丢弃——已有 ObjectMutation 的前车之鉴）：
`:admin_action`、`:admin_endpoint`、`:target_user`、`:target_group`、`:target_policy`、`:minio_view_partial`、`:omitted_reason`。

每个 admin 端点的日志必须含：`action` / `required_action` / `decision` / `method` / `resource` / `auth_type` / `principal_arn`（对齐 `Maxio.Admin.Plug.server_info/1` 已有的 deny 日志形状），成功路径同样打一条 info。

## 7. 测试与验收

### 7.0 前置：真实 mc 基线抓包（先于任何编码）

按第二批 T0 的成功模式，先用真实 mc 抓一份「mc 到底发了什么」：

```
mc --debug admin policy ls   maxio
mc --debug admin policy create maxio p-ro ./p.json
mc --debug admin policy info maxio p-ro
mc --debug admin policy rm   maxio p-ro
mc --debug admin user  info  maxio alice
mc --debug admin user  disable maxio alice
mc --debug admin group ls    maxio
```

**产出物**：每条命令的完整 method / path / query / 请求头 / 请求体十六进制（用来独立复核 §1.1 的加密判定）/ 响应期望。**这份取证直接消解 V-B4 / V-B7 / V-B13**，并为 §1.1、§2、§5 的源码结论提供一份独立的活体交叉验证。

**必须逐条核对的抓包断言**：

1. `mc admin policy *` 四条的请求体/响应体**是可读 JSON**（不是 `salt|id|nonce|ciphertext` 的二进制）——独立证实"policy 类全明文"。
2. `mc admin user info` 的响应**是可读 JSON**；而 `mc admin user ls` 的响应**是二进制**且第 33 字节 ∈ `{0x00,0x01,0x02}`——独立证实 §1.1 那个反直觉的非对称。
3. 所有请求的 credential scope 的 region 段为空（`.../<date>//s3/aws4_request`），与第二批实测一致。
4. `mc admin policy info` 的第一次请求确实带 `&v=2`。

### 7.1 本机运行环境（Windows + Docker）

- maxio dev 默认绑 `127.0.0.1:9900`（`config/dev.exs:99`）。容器里的 mc 连不上，必须用 `MAXIO_S3_IP=0.0.0.0` 运行时覆盖（`config/runtime.exs:290`，会硬校验字面 IP，非法值 raise 不静默回落）。
- 跑 mix 前必设 `$env:ERL_FLAGS="-kernel standard_io_encoding unicode"`（`CLAUDE.md`）。
- mc 经 Docker，endpoint 用 `http://host.docker.internal:9900`（Windows Docker Desktop 不支持 `--network host`）。
- **必须起隔离实例**：另一个 lane 可能在跑全量测试，共用 dev DB/端口会互相污染。

### 7.2 活体验收清单（"不是假绿"的判据）

每一条都要求：**真实 mc 的真实输出** + **服务端结构化日志** + **`mix maxio.admin.*` CLI 的对照输出三者一致**。只有 mc 退出码 0 不算通过（mc 对某些错误也会 0 退出并只打一行文字）。

| # | 命令 | 期望 | 防假绿的额外证据 |
|---|---|---|---|
| A-1 | `mc admin policy ls maxio`（全新库） | **无任何输出行**、退出 0、不报错（真实 MinIO 此处会打 5 行内置策略，maxio 打 0 行——**这是刻意的真话**，§3.3 D-C5） | 同时 `mix maxio.admin.policy.list --json` 输出 `{}`；证明"空"是真空而不是解析失败 |
| A-2 | `mc admin policy create maxio p-ro ./ro.json` | `Created policy \`p-ro\` successfully.` | `mix maxio.iam.managed_policy.get --arn arn:aws:iam:::policy/p-ro` 能取到**逐字节相同**的文档；`managed_policy_versions` 恰好一行 `v1` 且 `is_default` |
| A-3 | `mc admin policy ls maxio` | 打印一行 `p-ro`（**mc 只渲染名字，看不到文档**） | 因此**必须**另取证据：`curl` 直接打 `/list-canned-policies` 看响应体是 `{"p-ro": {<完整文档对象>}}`——**不是** `{"p-ro": "{\"Version\"...}"` 这种字符串化形态（值类型错了 mc 屏幕上看不出来，但 Console/其它客户端会炸） |
| A-4 | `mc admin policy info maxio p-ro` | 打印缩进 JSON，**顶层键恰好是 `PolicyName` / `Policy` / `CreateDate` / `UpdateDate`（大驼峰）** | 抓包确认 mc 先发 `?name=p-ro&v=2`；另测 `?name=p-ro`（无 `v`）返回**裸策略文档**、`?name=p-ro&v=9` 返回 **400** |
| A-5 | `mc admin policy info maxio nope` | 404 结构化错误，**不是 501、不是 500** | 响应体是 JSON 五键；服务端日志有一条 warn |
| A-6 | `mc admin policy create maxio p-ro ./ro2.json` 后 `mc admin policy rm maxio p-ro` | **失败**，消息含"非默认版本"与解决办法 | **这是期望行为不是 bug**（§3.3 D-C3）；`mix maxio.iam.managed_policy.get` 显示 `default_version_id == "v2"` |
| A-7 | 删掉 v1 后 `mc admin policy rm maxio p-ro` | 成功 | `mc admin policy ls` 不再有它；DB 里 `managed_policies` 无该行 |
| A-8 | 建策略 → attach 给用户 → `mc admin policy rm` | **失败**，消息列出阻塞实体 | 证明不级联解绑；`iam_user_managed_policy_attachments` 行仍在 |
| A-9 | `mix maxio.iam.create_user --name alice` + `create_key --access-key alice --secret <32B>` → `mc admin user info maxio alice` | 显示 enabled、真实策略与组 | **双向可见性**的核心证据 |
| A-10 | `mc admin user disable maxio alice` → 用 alice 凭据跑 `aws s3 ls --endpoint-url ...` | S3 请求 **403** | 证明 disable 不是空开关；`mc admin user info` 同步显示 disabled |
| A-11 | `mc admin user enable maxio alice` → 同样的 S3 请求 | 恢复正常 | 可逆 |
| A-12 | 给 alice 附加一个 managed policy + 一条 inline policy → `mc admin user info maxio alice` | `policyName` **只含 managed 的那个** | 服务端日志有 `minio_view_partial: true`；`mix maxio.admin.user.show alice` 打印全部五类来源 |
| A-13 | `mc admin user rm maxio alice` | 成功，级联清理 | `mix maxio.iam.list_users` / `list_keys` 里都没有了；alice 的 S3 请求变 403 |
| A-14 | 匿名 `curl http://.../minio/admin/v3/list-canned-policies` | **403 JSON**（不是 501） | 鉴权先于路由（`Admin.Plug` 既有纪律） |
| A-15 | 无 admin policy 的普通 IAM 用户跑 `mc admin policy ls` | **403** | 授权真的生效 |
| A-16 | identity policy `{"Effect":"Allow","Action":"admin:GetPolicy"}`（**无 Resource**） | `mc admin policy info` 通，`mc admin policy ls` **仍 403** | 证明 per-endpoint action 粒度真实，不是一把梭 |
| A-17 | `mc admin user add maxio bob pw` | **501 结构化 JSON** | 未实现就说未实现（不是 404、不是假成功） |
| A-18 | `mc admin policy attach maxio p-ro --user alice` | **501** | 同上 |
| A-19 | `mc admin info maxio` | **仍正常** | 本批未破坏第二批（回归） |
| A-20 | `mc ls maxio` / `mc cp` | **仍正常** | 未破坏 S3 数据面（`/minio/admin/` 认领无外溢） |
| A-21 | `curl 'http://.../minio/admin/v3/list-canned-policies?bucket=b1'`（已签名） | **501**，**不是**返回全量策略 | 证明 `?bucket=` 变体没有被静默当成无参变体（§1.1 路由匹配语义） |
| A-22 | `mc admin user disable maxio <当前 alias 自己的 access key>` | **400 `XMinioAdminInvalidArgument`** | 逐字继承 MinIO 的"不能禁用自己"（§3.1 D-A3） |
| A-23 | `mc admin group info maxio g1`（g1 有成员 + 附加策略 + 一条 inline policy） | `members` 完整；`policy` **只含 managed 的名字** | 与 A-12 同构的偏序视图证据；`mix maxio.admin.user.show` 的组视角对照 |
| A-24 | `mc admin group enable/disable maxio g1` → 组成员用自己的凭据跑受该组策略授权的 S3 操作 | disable 后 **403**，enable 后恢复 | 证明组 status 真的进授权链（`ecto_store.ex:1040,1082` 的 `g.status == "active"`） |
| A-25 | 给 `admin:EnableUser` 的 identity policy 的用户执行 `mc admin user disable` | **成功** | 逐字继承 MinIO：disable 也只校验 `admin:EnableUser`（§2 反直觉事实 1）。**这一条是防"好心加严"回归的主防线** |

### 7.3 ExUnit 层（自签 SigV4，region 段为空）

延续第二批 T2 的手法（`Maxio.Test.SigV4Request.signed_conn/3` + `Maxio.S3.Endpoint.call/2`）：

- 每个端点：root 通过 / 精确 action 的 identity policy 通过 / 无 policy 403 / 显式 Deny 覆盖 root / bucket policy 授予同名 action **仍 403**（identity-policy only）/ 匿名 403 / STS session policy 边界生效。
- 线格式逐字段断言（键名大小写、`PolicyInfo` 的大驼峰、错误体五键）。
- **表驱动的 omit 纪律回归**（延续第二批 T3 的主防线）：对每个"maxio 无此概念"的字段，断言 JSON 里**键不存在**。
- 语义回归：D-A3（只写 `iam_users.status`，`access_keys.status` 不变）、D-B（inline policy 不进 `policyName`）、D-C1（非 `/` path 策略不出现在 list）、D-C3（两种删除阻塞各自的错误码与消息）。
- 未实现端点：U1/U2/P6/P7/S1–S5 逐条断言 **501**（不是 404）。

### 7.4 `Maxio.Compat.ExternalSmoke` 扩展

仓库已有 `lib/maxio/compat/external_smoke.ex`（`minio_mc` client spec + `mc-config` 临时目录 + `step(name, exe, args, opts, expectation, scenario:, assertion:)`）与 `mix maxio.compat.matrix --include-external-smoke --external-smoke-client minio_mc`。**在这里扩展，不另起炉灶**，新增 `admin_policy_lifecycle` / `admin_user_lifecycle` 两个 scenario，断言用 `{:output_contains, [...]}`。

> ⚠️ 该 harness 通过 `System.find_executable("mc")` 找**本机原生 mc**。若本机 mc 只经 Docker 提供，需要在 PATH 上放一个 shim 把 `--config-dir <host path>` 映射成 `docker run -v` 挂载。**这是一个已知的环境适配点，记为 V-B11**——在解决前，§7.2 的验收以**手工 Docker mc + 记录完整输出**为准，不因 harness 限制降低取证标准。

## 8. VERIFY-AT-IMPL 清单

**规则同前两批**：未核实前，实现代码里必须带 `# VERIFY-AT-IMPL V-Bxx` 注释；核实后结论写进 STATUS.md。**任何一项未核实就声称"`mc admin policy/user` 支持"，都是 overclaim。**

### 已在设计阶段消解（记录以便后续批次不再重查）

| ID | 结论 |
|---|---|
| ~~V-A4~~ | **已消解**：加密边界见 §1.1 逐端点表（policy/group 全明文；`user-info` 明文而 `list-users` 加密；add-user / svcacct / idp-policy 加密） |
| ~~V-B2~~ | `list-canned-policies` 校验 `ListUserPoliciesAdminAction = "admin:ListUserPolicies"`（CONFIRMED） |
| ~~V-B3~~ | `set-group-status` 校验 `EnableGroupAdminAction = "admin:EnableGroup"`（CONFIRMED），enable/disable 共用 |
| ~~V-B8~~ | `madmin.GroupDesc = {name, status, members, policy, updatedAt}`（CONFIRMED，v3.0.109） |
| ~~V-B9~~ | admin 错误 Code/状态/描述已逐字取证，见 §5 |
| ~~V-B12~~ | 客户端签名是 `ListCannedPolicies(ctx) (map[string]json.RawMessage, error)`（CONFIRMED）——发合法 policy 文档对象即可 |
| ~~V-B14~~ | `madmin.AccountStatus` 只有 `"enabled"` / `"disabled"`；`GroupStatus` 同（CONFIRMED） |

### 协议 / 线格式（仍需实测）

| ID | 事项 | 核实方法 | 未核实时的行为 |
|---|---|---|---|
| **V-B4** | `madmin.PolicyInfo` 的大驼峰键名在真实 mc 上确实被正确解出（源码已 CONFIRMED 无 json tag，但它**有自定义 `MarshalJSON`**，需确认 Unmarshal 侧无对称的自定义逻辑） | 真实 `mc admin policy info` 实测 | 按大驼峰实现，A-4 立刻验证 |
| **V-B10** | P1 body 上限（MinIO `maxEConfigJSONSize` 的确切值）与"拒绝 chunked"的确切条件 | 读 `minio/cmd/admin-handlers-users.go` 的常量定义 | 用 maxio 自己的保守上限，硬失败（不截断） |
| **V-B13** | `mc admin policy info` 的 `v=2` → 无 `v` 回落触发条件（第一次失败要返回什么才会重试） | 抓包：故意让 `v=2` 返回 400/501 看 mc 是否重试 | 两条分支都实现，回落自然不会被触发 |
| **V-B7** | `mc admin group add/rm` 是否会在 `GroupAddRemove` 里填非空 `groupStatus` | 抓包 | 空 = 不改状态；**非空则明确 400**，不静默忽略 |
| **V-B1** | `/minio/admin/v4/*` 的 426 回落端到端行为（madmin v4 的 `executeMethod` 确有该分支，但 OSS mc 仍是 v3） | 需要一个依赖 madmin v4（AIStor 线）的客户端 | **维持 501**（无客户端可取证，判据同第二批 §9.2 #6） |
| **V-B18** | `toAdminAPIErr` / `toAdminAPIErrCode` 在 `toAPIErrorCode` 之上的额外分支（源文件过大未取到） | 分段读 `minio/cmd/admin-handlers.go` | 只影响 MinIO 的兜底链，不影响 maxio 主动产生的错误；实测对照发现差异即补 |
| **V-B17** | maxio **不实现** MinIO 的两处自助放宽（`GetUserInfo` 查自己时 deny-only、`AddUser` 的 `implicitPerm` 自助改密），偏离方向是更严 | 实测确认 mc 在被拒时的报错可读 | 维持更严 + 写进 README |

### maxio 侧

| ID | 事项 | 核实方法 |
|---|---|---|
| **V-B5** | maxio 是否真能经任何路径创建非 `/` path 的 managed policy（决定 D-C1 的过滤是实需还是防御） | 通读 `Maxio.IAM.create_managed_policy_strict/1` 与 `QueryPlug` 的 `CreatePolicy` 参数处理 |
| **V-B6** | 是否存在仍会调用 P5 `/set-user-or-group-policy` 的真实客户端 | 老版本 mc / 第三方工具实测 |
| **V-B11** | Docker-only mc 与 `ExternalSmoke`（依赖原生可执行 + host 路径 `--config-dir`）的适配方案 | 实机验证 shim 或改造 harness |
| **V-B15** | `:argon2_elixir` 能否以显式参数（t=1, m=64MiB, p=4, len=32, 32B salt）产出**裸 32 字节** raw hash | 读其 `Argon2.Base` 文档/源码；不行则走 Rustler（**信封批次的前置**） |
| **V-B16** | `mc admin user info` 对一个**无同名 access key** 的 maxio IAM 用户的渲染是否正常（不 panic、不误导） | 实测（A-9 的变体） |

## 9. 与架构铁律的对照

| 铁律 | 本设计如何契合 |
|---|---|
| **1. 统一数据契约** | 适配层只调 `Maxio.IAM` 门面（它已是 IAM Query API 的同一入口），**不新建第二条 IAM 写路径**；错误仍是唯一的 `%Maxio.S3.Error{}`，XML/JSON 两个 view；user 集合的权威只有 `iam_users` 一处，MinIO 视图与 IAM Query 视图同源 |
| **2. 后端即插件** | 适配层不碰 `Maxio.Policy.Store` behaviour 的实现细节，只经 `Maxio.IAM` 门面；`EctoStore` 之外若接入新 policy 后端，本批代码一行不改 |
| **3. 明确状态设计 + 绝不静默失败** | 未实锤的 action 名/错误码一律落 501 而非猜；删除阻塞照实报且**绝不级联解绑权限**；版本配额耗尽报错且**绝不自动删旧版本**；`policyName` 少报时打结构化日志 + CLI 全量对照；status 只有一个开关；未实现端点 501 不是 404；非 `/` path 策略被过滤时明说 |
| **4. body 绝不进内存** | admin body 全是小 JSON，走**带上限的整读**（同 `CompleteMultipartUpload`），不挂 `Plug.Parsers`，上限硬失败不截断；`Admin.Plug` 在 `Dispatch` 之前 halt，不触碰对象流 |
| **5. 行为对齐真实实现** | 加密边界、路由、struct、KDF/AEAD/分帧参数全部引自 `minio/minio`、`madmin-go`、`minio/pkg`、`mc` 源码；无法实锤的一律进 §8，**不凭记忆编造 madmin schema**；与 MinIO 的两处刻意偏离（删除不级联解绑、版本配额）都写明理由并进 README |

## 10. 参考来源

- MinIO admin 路由：<https://github.com/minio/minio/blob/master/cmd/admin-router.go>
- MinIO user/policy handler（加密边界的一手证据）：<https://github.com/minio/minio/blob/master/cmd/admin-handlers-users.go>
- MinIO 错误表：<https://github.com/minio/minio/blob/master/cmd/api-errors.go>
- admin action 常量：<https://github.com/minio/pkg/blob/main/policy/admin-action.go>
- madmin user/policy/idp/group commands：<https://github.com/minio/madmin-go/blob/main/user-commands.go>、<https://github.com/minio/madmin-go/blob/main/policy-commands.go>、<https://github.com/minio/madmin-go/blob/main/idp-commands.go>、<https://github.com/minio/madmin-go/blob/main/group-commands.go>
- madmin 信封：<https://github.com/minio/madmin-go/blob/main/encrypt.go>
- madmin 版本与 426 回落：<https://github.com/minio/madmin-go/blob/main/utils.go>、<https://github.com/minio/madmin-go/blob/main/api.go>
- sio-go STREAM 分帧：<https://github.com/secure-io/sio-go/blob/master/sio.go>、<https://github.com/secure-io/sio-go/blob/master/writer.go>
- mc 子命令：<https://github.com/minio/mc/tree/master/cmd>（`admin-user-*.go`、`admin-policy-*.go`）
- maxio 侧：`lib/maxio/iam.ex`、`lib/maxio/policy/store/ecto_store.ex`、`lib/maxio/admin/{plug,authz,error_view,server_info}.ex`、`lib/maxio/s3/reserved_namespace.ex`、`lib/maxio/compat/external_smoke.ex`
