# MinIO Admin Config Export/Import S7 设计

> 日期：2026-08-29
>
> 状态：冻结设计，供后续独立测试、实现与审查 lane 使用
>
> 基线：`50f322a`
>
> 上位准则：`AGENTS.md`、`CLAUDE.md`、`docs/superpowers/STATUS.md`
> 前置能力：S5 Config KVS get/set/reset、S6 Config help

---

## 0. 决策摘要

S7 在既有 `Maxio.Config` Postgres 权威存储之上增加完整配置导出/导入，但“完整”仅指
`Maxio.Admin.ConfigKV.Registry` 当前登记的三个公开 Maxio 扩展键：

- `s3.clock_skew_ms`
- `listing.sql_hard_limit`
- `prometheus_metrics.public`

冻结决策如下：

1. 暴露 `GET /minio/admin/v3/config` 与 `PUT /minio/admin/v3/config`。
2. GET 成功体和 PUT 请求体使用已认证调用者 secret 的 madmin SIO envelope；secret 不进入归档领域层。
3. PUT 明文上限为 256 KiB（262144 bytes），密文上限为 262272 bytes；只接受明确、唯一的
   `Content-Length`，拒绝 `Transfer-Encoding`。
4. Registry 是唯一 wire exposure source。Schema、数据库行和 runtime aggregate 均不得反向扩张导出目录。
5. import 是 Registry 公开域的 replacement：遗漏公开键生成 `reset`。
6. 显式导入值即使等于当前 fallback，也物化为 override；只有遗漏才表达 reset。
7. target、unknown、hidden、forbidden 和 orphan 均不可导入，且永不导出。
8. 导出通过一次 authoritative snapshot 获得三个公开键的一致视图。
9. 导入先完成全量纯验证，再在一个 DB transaction 中按稳定顺序取得全部 subsystem advisory locks，
   然后读、验证、写和审计；禁止逐 subsystem 调现有 API。
10. changed count 为零时不 reload、不 broadcast、不写 audit、不递增版本；大于零时 commit 后恰好一次
    `Store.load_all!` 和一次 checked batch broadcast。
11. post-commit reload/broadcast 失败不回滚已提交事务，也不伪造“未提交”错误；写入安全 attention。
12. 不新增 migration。沿用 `runtime_configs` 与 `runtime_config_audits` 的逐键 set/reset 模型。
13. history、service restart、named targets、完整官方 MinIO catalog、secret/backend 导出均不属于 S7。
14. mutation `source` 沿用数据库字符串枚举：`"admin_api" | "cli" | "console" | "system"`；不得传 atom。
15. wire raw scalar 先经 `Schema.parse/3`；Coordinator 收到 typed operation 后仍经 `Schema.cast/3` 防御性规范化。
16. batch `expected_versions` 使用 path-keyed map，validator 使用 per-subsystem map；legacy wrapper 无损转换旧 shape。
17. batch invalidation 携带 Store origin identity 与 request epoch；本节点同步 reload 后必须忽略 PubSub 回环，远端按
    `{origin, epoch}` 去重。

---

## 1. 官方协议依据与证据边界

前置 S5/S6 已固定下列上游源码身份：

- MinIO `7aac2a2c5b7c882e68c1ce017d8256be2feea27f`
- madmin-go `4b504b82db633e978a57d49443b2be75824244c3`
- mc `77f82e18b5401a65958f1619df6ebb994634bd88`

S7 研究 lane 已确认：

- route 是 `GET/PUT /minio/admin/v3/config`；
- 两条 route 均处于 `admin:ConfigUpdate` 管理权限边界；
- madmin export/import 使用 caller-secret SIO；
- madmin PUT 明文上限为 256 KiB；server 读取密文上限为 262272 bytes；
- export 由 HelpSubSysMap、默认 target 与 KVS 的稳定顺序产生；
- import 从默认配置 `config.New()` 开始，因此遗漏配置回默认；
- 重复行按出现顺序 patch；未知项使整次 import 失败；
- 上游 handler 先 parse、全量 validate，再保存；不会热加载；
- pinned mc 对 import 总是给出 restart 提示。

上述结论必须在独立 S7 fixture 中记录源码路径、行级摘录摘要和 commit identity，不能只引用本设计文字。

研究 lane 还固定了以下边界：

- madmin PUT 明文为空时在客户端本地返回 EOF，不发 HTTP；1..262144 bytes 会发请求；262145 bytes 及以上
  在客户端本地返回 ErrTooLarge，不发 HTTP；
- direct server request 的 ciphertext Content-Length 为 `-1` 或大于 262272 时返回 TooLarge；长度为 0 时进入
  decrypt 并返回 BadJSON；Maxio 延续 S5 更严格的唯一显式 Content-Length 安全边界；
- export codec 每个 subsystem 行以一个 ASCII 空格再 LF 结束；
- blank/comment-only import 是全默认 replacement，不是 no-op；
- duplicate line 依出现顺序 last-write-wins；
- unknown-prefix 延续 Maxio 安全拒绝，不模仿可能暴露 catalog 的宽松行为；
- 官方 current/history 存在无锁和 partial-commit 窗口，Maxio 明确采用单事务/全锁序的强安全偏差；
- Maxio 三键 hot apply，但 PUT wire 仍为 HTTP 200 空体且不发送 `x-minio-config-applied`，使 pinned mc 保持
  官方 restart 提示。

以下细节在本文撰写时尚未固定，先标记为 `VERIFY-AT-IMPL`：

- GET 成功响应的精确 Content-Type、随机 SIO framing/length（不包括固定 ciphertext bytes）；
- pinned mc restart 文案的精确 human/JSON bytes；
- archive 引号与转义的精确字节；
- malformed envelope、超限明文、unknown/target/duplicate 等错误的精确 HTTP status、Code、Description
  和优先级；
- GET 是否携带任何 entity header，以及 proxy/Bandit 对响应 framing 的实际影响；
- Windows 原生 mc 对 stdin、stdout 或临时文件的确切命令形式。

`VERIFY-AT-IMPL` 不是实现者自由选择项。凡会决定 RED/production 的细节，协议 lane 必须在对应测试/实现开始前
用 pinned source 或 pre-implementation live 固化为 fixture；Windows mc argv/stdin 与 ErrorMap 也适用。最终
strict-live 只复验已冻结契约，不能首次决定实现。实现 lane 只能满足已审查 fixture。

---

## 2. 交付范围与诚实兼容声明

S7 完成后可声明：

> Maxio 支持 MinIO Admin v3 config export/import 的 route、SigV4、caller-secret SIO 和 native mc 调用路径，
> 导出/替换范围严格限定为三个已注册的 Maxio 公开运行时配置键。

不得声明：

- 完整 MinIO config catalog 兼容；
- 支持 MinIO 官方 `api`、`site`、`notify_*`、`logger_*`、`identity_*` 等 subsystem；
- 配置 history list/clear/restore；
- named target 或 `subsystem:target`；
- service restart endpoint 或真实重启编排；
- secret、root credential、KMS/SSE/MFA 材料或 backend/behaviour 绑定可导出；
- import 是异步 job、具有 durable job id 或全局配置 epoch。

官方 import 不热加载，而 S7 当前三个公开键已经具备 Maxio hot apply consumer。为保证功能优先且保持现有统一
Config 语义，S7 在 DB commit 后执行一次本地 reload 和一次集群 invalidation。native mc 的 restart 提示按固定
客户端兼容，不代表 Maxio 实际执行或要求 service restart；Maxio 不新增 restart 能力，也不把提示写成服务端
成功承诺。

---

## 3. 可复用边界与新增模块

### 3.1 直接复用

- `Maxio.Admin.ConfigKV.Registry`
  - 唯一公开目录、固定顺序、wire 名到 core atom 的静态映射。
  - 继续承担 forbidden/hidden 分类，不允许 user input 生成 atom。
- `Maxio.Config.Schema`
  - 只承担 core type cast、stored encode/decode、fallback/apply mode 与 validator。
  - 不是 wire catalog，不得被导出逻辑枚举。
- `Maxio.Admin.ConfigKV.Parser`
  - 复用 S5 KVS scanner、quote/escape 与 render 规则。
  - 需要抽出跨 subsystem document parser，不能复制第二套 KVS grammar。
- `Maxio.Admin.ConfigKV.Request`、`Maxio.S3.ControlBody`、`Maxio.Admin.Envelope`
  - 复用有界读取、payload hash 复验与 caller-secret SIO。
- `Maxio.Config.Coordinator`
  - 保留版本、逐键 audit、no-op 和 post-commit 安全语义。
  - 扩展为多 subsystem 的唯一事务算法；现有单 subsystem API 反向委托它。
- `Maxio.Config.Store` 与 `Maxio.Cluster.Notify`
  - full reload、checked broadcast、digest reconcile 和安全 attention。
- `Maxio.Admin.Plug`、`Maxio.Admin.Authz`、`Maxio.Admin.ErrorMap`
  - 沿用 Admin authentication-first、identity-only action 与结构化错误边界。
- `Maxio.S3.Plugs.ResponseTransformPolicy`
  - 已覆盖 path-style Admin surface 的 `Cache-Control: no-transform`；预计只增加回归测试，不改实现。

### 3.2 新增归档领域模块

新增 `Maxio.Admin.ConfigKV.Archive`，建议公开接口：

```elixir
@type path :: {atom(), atom()}
@type operation :: {:set, atom(), term()} | {:reset, atom()}
@type operation_group :: {atom(), [operation()]}

@spec export(keyword()) :: {:ok, binary()} | {:error, term()}
@spec decode_and_plan(binary()) :: {:ok, [operation_group()]} | {:error, term()}
@spec import_config(binary(), keyword()) :: {:ok, map()} | {:error, term()}
```

职责分割：

- `export/1` 从 Registry 得到 path，调用 `Maxio.Config.authoritative_snapshot/2`，再交纯 encoder。
- `decode_and_plan/1` 完成 UTF-8 后的 document parse、exposure、wire raw `Schema.parse/3`、顺序 patch 和 omitted
  reset 计划。
- `import_config/2` 只调用 `decode_and_plan/1` 与 `Maxio.Config.mutate_many/2`。
- Archive 不调用 Repo、Store、Notify、Application env，也不接触 caller secret。

如果实现后单文件职责明显过大，可把纯 codec 拆为
`Maxio.Admin.ConfigKV.Archive.Codec`；不得在一个 `.ex` 文件嵌套定义多个模块。

### 3.3 Config facade 新接口

```elixir
@spec authoritative_snapshot([path()], keyword()) ::
        {:ok, %{required(path()) => %{value: term(), source: :runtime | :fallback,
                                     version: non_neg_integer() | nil}}}
        | {:error, term()}

@spec mutate_many([operation_group()], keyword()) :: {:ok, map()} | {:error, term()}
```

`authoritative_snapshot/2` 只接受调用者已知的 atom path。它以一个 SQL statement 读取全部选定 override，
在同一个数据库 snapshot 上解码，再与 Schema fallback 合并。Archive encoder 只消费 `value`，不能把 source/version
写进 wire。

`mutate_many/2` 与 `mutate_subsystem/3` 都委托 Coordinator 的同一个 private transaction engine；
`mutate_subsystem/3` 不能直接调用 public `mutate_many/2` 的 batch post-commit adapter。内部 engine 只返回
committed plan，不 reload、不 broadcast：

- public `mutate_many/2` 对 committed plan 调 batch finisher，使用 batch reload reason 和一条 origin-aware batch event；
- public `mutate_subsystem/3` 对同一个 committed plan 调 legacy finisher，保持 S5
  `{:write, subsystem, changed_keys}` reload reason、一条 `{:config_changed, subsystem}` event 与
  `%{subsystem:, changed_keys:, outcomes: %{key => outcome}}` result；
- 两个 finisher 互斥，任何 mutation 绝不能先走 batch finisher 再补 legacy event，也不能双 reload/双 broadcast；
- post-commit mode 只能由两个 public wrapper 的私有调用路径决定，不得成为 caller 可伪造的公开 option。

这样 transaction/lock/version/audit 算法只有一份，同时保证 S5 observable event 完全兼容。

---

## 4. 公开归档模型

### 4.1 唯一暴露源

Archive 必须按 `Registry.entries/0` 返回顺序工作，不得：

- `Schema.entries/0` 全量枚举；
- 查询所有 `runtime_configs` 行后动态输出；
- 从 Store aggregate 推导 catalog；
- 输出 unknown/orphan 行；
- 根据当前是否存在 override 决定是否输出键。

导出永远包含三个公开 effective value，包括没有 runtime row、仅来自 fallback 的键。

Registry 必须具有 fail-closed invariant：任何准备导出的 entry 都必须是 public、非 sensitive、非 forbidden、
具有静态 core atom 映射。未来有人把 `sensitive?: true` 的 entry 放入公开顺序时，export 应明确失败并由测试阻止，
不能静默省略造成不可恢复的“完整”归档。

### 4.2 稳定顺序与文本

逻辑顺序冻结为 Registry 顺序，并保持默认 target；每行固定为尾随一个 ASCII 空格再 LF：

```text
s3 clock_skew_ms=<typed-rendered-value>␠LF
listing sql_hard_limit=<typed-rendered-value>␠LF
prometheus_metrics public=<typed-rendered-value>␠LF
```

建议的 fresh Maxio archive exact bytes 是一项 **`local_design_expected`**，不是 upstream MinIO raw fact：

```text
s3 clock_skew_ms=900000␠LF
listing sql_hard_limit=100000␠LF
prometheus_metrics public=false␠LF
```

上面用可见的 `␠LF` 表示一个 ASCII space byte 后跟一个 LF byte；它不是 wire 中的五个文字字符。对应 raw
payload 的候选长度为 89 bytes，候选 SHA-256 为
`c8fe86493cce0083169223b68b59e69612ceeaff7ff45721b45eb85e7eff4141`。实现测试必须从 literal bytes
重新计算并确认长度/SHA，不能仅复制本文数字；fixture 字段必须明确写
`evidence_class: "local_design_expected"`。quote/escape 的未覆盖字节在 Archive RED 开始前必须关闭
`VERIFY-AT-IMPL`，否则阻塞实现。不得按 map 枚举顺序或数据库返回顺序输出。

### 4.3 永不导出、不可导入

- hidden：例如 `cluster.deployment_id`；
- forbidden：storage/credential/policy backend、authoritative/topology source、Repo、SSE/KMS/MFA、root 或
  access secret 等 Schema 禁止目录；
- orphan：数据库存在但当前 Schema/Registry 不认识的行；
- target：包括任何 `subsystem:target` 或显式非默认 target；
- unknown：不在 Registry 公开项中的任意 subsystem/key。

import 遇到以上内容必须在事务前 fail closed。不得把 forbidden/hidden 降格为普通 typo 后在日志或错误里回显
敏感值；只允许安全 closed vocabulary、stage、subsystem/key count 等证据。

---

## 5. Import replacement 与显式 fallback

Archive 首先用 Registry 三键建立默认 replacement plan，然后按输入出现顺序应用 patch：

1. 初始时三个公开键均标记为 omitted/reset。
2. 每个合法输入键的 wire raw scalar 先调用 `Schema.parse(subsystem, key, raw)` 得到 typed value，并覆盖该 path
   之前的 patch；Archive 不得直接对 raw string 调 `Schema.cast/3`。
3. 重复行最后一次出现的值生效。
4. 文档解析结束后，出现过的 path 生成 `set`；没有出现的公开 path 生成 `reset`。
5. 按 subsystem 和 Registry path 稳定顺序分组交给 Coordinator。

显式导入值等于当前 fallback 时仍生成 `set`：

- absent override + explicit fallback value：创建 v1 runtime row 和 `set` audit；
- same override + same explicit value：no-op；
- different override + explicit fallback value：更新 override，不删除它；
- omitted + existing override：删除 row 并写 `reset` audit；
- omitted + absent override：no-op。

这是 snapshot 可移植性要求。若把显式 fallback 优化成 reset，之后环境 fallback 改变就会悄然改变已经导入的
快照。首次 export→import 可能物化三个默认值，第二次相同 import 必须成为全局 no-op。

空文档或仅含 blank/comment 的文档语义固定为 reset 全部三个公开键，不能解释成 no-op patch。madmin 不会把
零字节明文送到服务端，但 direct signed HTTP 和本地 CLI 仍应按 replacement 领域语义测试；HTTP 的零字节
ciphertext 则在 Archive 之前因 SIO decrypt 失败为 BadJSON。

---

## 6. 一次 authoritative snapshot

导出不能按三个 subsystem 分别调用 `Config.authoritative_effective/3`。并发 import/set 可能落在三次不同 MVCC
快照，产生从未真实存在过的组合。

`Config.authoritative_snapshot/2` 的顺序为：

1. 验证 path 均是静态 atom tuple 且 Schema 已知；调用者仍负责 Registry exposure。
2. 用一次按 path 过滤的 SELECT 读取 `runtime_configs`，稳定按 subsystem/key 排序。
3. 对已知 stored value 调 `Schema.decode_stored/3`；腐坏已注册值 fail closed。
4. 对缺失 path 从 Application config/Schema fallback 构造 typed effective value。
5. 返回 path map；同时可带内部 source/version 供测试和诊断，但 wire encoder只能取 `value`。

该读取不需要 advisory lock；单条 PostgreSQL statement 已提供一致 snapshot。不得为导出取得长事务锁，也不得调用
Store 造成 reload side effect。fallback 是进程启动配置，S7 不处理并发修改 Application env 的测试注入；生产
fallback 变更只能通过受控重启/部署。

---

## 7. 跨 subsystem 单事务与锁序

### 7.1 事务前纯验证

在进入 Repo transaction 前完成：

- SIO decrypt 后 UTF-8；
- plaintext 256 KiB 上限；
- document lexical/syntax parse；
- target/unknown/hidden/forbidden/orphan exposure 拒绝；
- 重复行顺序 patch；
- 所有 wire raw scalar `Schema.parse/3`；
- omitted reset 计划；
- source 枚举与调用者元数据的安全规范化。

Archive 与 Coordinator 之间的 operation 必须已经是 typed value。Coordinator 的 normalize boundary 仍对每个 typed
set operation 调 `Schema.cast/3`，确保 CLI、S5 wrapper 或内部调用者绕过 Archive 时不能把未经规范化的值带入事务。
事务内仍需在锁内的新鲜权威状态上执行 candidate/cross-key validator，不能把事务前验证当成 TOCTOU 安全依据。

### 7.2 Batch option 契约

`mutate_many/2` 的并发与 validator option 固定为：

```elixir
expected_versions: %{
  {:s3, :clock_skew_ms} => 3,
  {:prometheus_metrics, :public} => nil
},
validators: %{
  s3: fn candidate_by_key -> :ok | {:error, term()} end,
  prometheus_metrics: fn candidate_by_key -> :ok | {:error, term()} end
}
```

- `expected_versions` 的 key 必须是 `{subsystem, key}`，version 为非负整数或 `nil`；裸 key 在 batch API 中无效。
- `validators` 的 key 必须是受影响 subsystem，value 为 arity-1 function；每个 validator 只看到自己的
  `candidate_by_key`，且在锁内恰好调用一次。
- 必须先构造并验证全部 subsystem candidate，之后才允许第一笔 row/audit write。
- `mutate_subsystem/3` 保持 legacy `expected_version:`、`expected_versions: %{key => version}` 与
  `validator: fun`，wrapper 在进入 batch core 前无损转换成 path-keyed/per-subsystem shape。
- 结果 wrapper 也必须把 tuple-keyed outcomes 无损转换回 S5 key-keyed shape；同名 key 位于不同 subsystem 时不能
  冲突或相互覆盖。

### 7.3 唯一锁序

`Coordinator.mutate_many/2` 必须使用以下不可交换顺序：

1. 规范化全部 operation group，合并重复 subsystem，并以 subsystem 的 UTF-8/binary 名称排序。
2. 开启一个 `Repo.transaction`。
3. 按上述排序取得**全部** `pg_advisory_xact_lock(1297638214, hashtext(subsystem))`。
4. 在全部 advisory locks 成功后，才执行任何 runtime row SELECT。
5. 按 `{subsystem, key}` binary 顺序 `FOR UPDATE` 读取涉及的 Schema 行。
6. 解码 current override、合并 fallback、应用 final operations。
7. 按 subsystem 稳定顺序调用 `validators[subsystem]`；任一失败 `repo.rollback/1`，未配置 validator 的 subsystem
   明确视为 `:ok`。
8. 先形成全部 diff plan，再按稳定 path 顺序写 row/delete 与 audit。
9. 任意 row/audit 写入失败回滚整个 import。

必须先锁完再读。若边锁边读，两个交叉 batch 会形成反序等待。不存在的 runtime row 没有行锁，因此单键 writer 也
必须委托同一 advisory coordinator；不能只为 import 新增锁。

batch core 的测试 checkpoint 可使用 `{:after_advisory_lock, subsystem}` 与 `:before_first_row_read`。现有 S5
`mutate_subsystem/3` 调用者若传 legacy checkpoint callback，wrapper 必须把本 subsystem 的 structured lock event
映射回原有 `:after_advisory_lock`，并屏蔽 legacy callback 从未承诺的新 batch-only phase；既有 callback 调用次数/
顺序不得改变。必须有 wrapper compatibility test，不能为并发测试直接破坏 S5 injection contract。

### 7.4 结果契约

batch 结果建议固定为：

```elixir
%{
  committed?: true,
  touched_subsystems: [:listing, :prometheus_metrics, :s3],
  changed_subsystems: [:prometheus_metrics, :s3],
  changed_count: non_neg_integer(),
  changed_paths: [{atom(), atom()}],
  outcomes: %{{atom(), atom()} => map()},
  local_reload: :ok | :not_needed | {:error, :reload_failed},
  broadcast: :ok | :not_needed | {:error, :broadcast_failed},
  attention?: boolean()
}
```

`touched_subsystems` 是输入 operation group 覆盖的全部 subsystem，包括最终 no-op；`changed_subsystems` 只从
`changed_paths` 推导。reload reason、attention 和 broadcast event 只能使用 `changed_subsystems`，不能广播纯 no-op
subsystem。所有列表必须稳定排序；不得放 plaintext value、ciphertext 或 caller secret。单 subsystem facade 可
适配成既有 S5 shape，但内部只保留一个算法。

---

## 8. 版本、审计、no-op

S7 不新增 import audit operation。每个真正变化的键沿用：

- `set`：insert/update runtime row，版本按 Coordinator 既有规则前进，写一条 set audit；
- `reset`：删除存在的 runtime row，写一条 reset audit；
- no-op：不写 row、不写 audit、不推进版本。

同一 import 的 changed audit 共享：

- `source: "admin_api"`；本地 CLI 使用字符串 `"cli"`；
- principal；
- access key；
- request id；
- committed transaction identity 所隐含的原子性。

不增加 batch/history 表，也不把整个明文 archive 写入 audit。日志仅记录 route、action、request_id、changed path
名称/count、事务结果与 post-commit 状态。

如果三个 subsystem 中任一 validator、row write 或 audit insert 失败，数据库必须看不到本次 import 的任何
版本、row 或 audit。

---

## 9. Post-commit、广播与集群收敛

### 9.1 no-op

`changed_count == 0` 时返回 committed no-op：

- `local_reload: :not_needed`
- `broadcast: :not_needed`
- `attention?: false`
- 不调用 Store、Notify 或 PubSub。

### 9.2 changed import

`changed_count > 0` 且 DB transaction 已 commit 后：

1. 调用一次 `Store.load_all!(repo: repo, reason: {:write_batch, changed_paths})`；
2. 获取本地 Store boot instance token，生成单调正整数 request epoch，调用一次：

   ```elixir
   Notify.broadcast_checked(
     {:config_changed_batch,
      %{
        origin: %{node: node(), instance: store_instance_token},
        epoch: request_epoch,
        subsystems: sorted_changed_subsystems
      }}
   )
   ```

3. 本地 Store 已同步 reload，收到相同 `origin.instance` 的 PubSub 回环时必须忽略，不得第二次 reload；
4. 远端 Store 收到不同 origin 的 batch event 后 full reload 一次，并在有界 recent-event cache 中记住
   `{origin, epoch}`；同一 event 重投必须忽略；
5. 若任一步失败，返回 committed success 加安全 post-commit 状态，写 attention，不回滚、不自动重试、不诱导调用者
   盲目重放 import；
6. 周期 digest reconcile 继续作为广播丢失、旧节点不认识 batch event 时的正确性兜底。

本节只适用于 public `mutate_many/2`/Archive import 的 batch finisher。单 subsystem public writer 复用同一 transaction
engine 后必须走 legacy finisher：恰好一次 legacy reload、恰好一次
`Notify.broadcast_checked({:config_changed, subsystem})`，不产生 batch event。反之 batch writer 恰好一次 batch reload、
恰好一次 origin-aware batch event，不产生 legacy event。共享 engine 本身严禁调用 Store/Notify。

新增带 origin/epoch 的 batch event 比借用 `{:config_changed, arbitrary_subsystem}` 更诚实，也避免每 subsystem
广播造成 N 次 full reload。origin instance token 只用于进程启动期事件身份，不是 credential；不得使用 caller
identity、secret 或 archive hash。recent-event cache 必须有界，不能随请求永久增长。滚动升级期间，旧节点会忽略新
tuple，最多延迟到 reconcile interval；strict-live 必须证明最终收敛，并在 STATUS 诚实记录本地 PubSub/跨节点
transport 的现状。

attention record 由单一 `subsystem` 扩为安全的排序 `subsystems`/`changed_paths`，只包含 Registry 短名称与
`local_reload`/`broadcast` 枚举结果，禁止值和 exception message 原样进入持久状态。

单元/集成测试不能只注入 Notify fake：必须启动真实 `Phoenix.PubSub` 和真实订阅 Store，证明本节点一次同步 reload
加 PubSub self-delivery 仍总计只 reload 一次；还要用不同 origin 事件证明首次 reload、相同 `{origin, epoch}` replay
去重。fake 只保留 transport failure/exception 的确定性测试。

### 9.3 mc restart 提示

Maxio 内部 hot reload 与 pinned mc 固定 restart 提示可以同时存在：

- server 不实现 restart，也不在日志/响应中宣称已重启；
- PUT 成功固定为 HTTP 200 空体且无 `x-minio-config-applied`；
- native mc transcript 必须按真实客户端输出验证，不得为了让文本“更合理”而私改客户端可见 header；
- strict-live 还要通过 `prometheus_metrics.public` 等数据面效果证明 Maxio 实际 hot apply。

---

## 10. HTTP、SIO 与有界 body

### 10.1 管线顺序

两条 route 沿用：

```text
SurfaceClassifier -> SigV4 -> Admin.Plug route -> Admin.Authz(admin:ConfigUpdate)
```

PUT 的顺序必须是：

1. route/authentication；
2. `admin:ConfigUpdate` authorization；
3. 从认证上下文取得 caller secret；
4. Content-Length/Transfer-Encoding 检查；
5. `ControlBody.read!` 有界整读并检查实际长度；
6. 对 ciphertext 复验 SigV4 payload SHA256；
7. `Envelope.decrypt(caller_secret, ciphertext)`；
8. UTF-8 和 plaintext 262144-byte 上限；
9. Archive parse/exposure/type/all-candidate validation；
10. 单事务 mutation；
11. post-commit reload/broadcast；
12. exact success response。

无权限请求即使携带畸形/超大 body，也只能看到 AccessDenied，且 body reader 不应被调用。

### 10.2 大小与 framing

- madmin local plaintext policy：空输入本地 EOF；`1..262144` 通过客户端大小检查；`262145+` 本地
  ErrTooLarge；
- server ciphertext policy：`Content-Length <= 262272` 才可进入读取/decrypt；
- SIO frame 长度冻结为：

  ```text
  encrypted_length(n) = 41 + n + 16 * ceil(n / 16384)
  ```

- 因此 end-to-end 可达最大明文是 261975 bytes：其密文恰为 262272；
- 261976-byte 明文的密文为 262273，server 在 decrypt 前 TooLarge；
- 262144-byte 明文虽然通过 madmin local policy，但密文为 262441，发出后被 server TooLarge；
- decrypt 后仍保留 `plaintext <= 262144` 的防御检查，但不能把它误写成经 SIO/server 可达上限；
- 拒绝缺失、重复、负数、非十进制 Content-Length；
- 拒绝任何 Transfer-Encoding/chunked；
- 实际读取字节必须等于声明长度；
- GET 导出明文必须先检查 256 KiB，再加密并检查 262272-byte 密文上限；
- Content-Type 不应被用作 madmin 兼容性的额外拒绝门，除非 fixture 明确证明，否则保持 S5 行为。

madmin 客户端“accepted”只表示通过本地 plaintext check 并尝试发请求，不表示 server 接受。direct upstream
server 对 ciphertext 的 `Content-Length == -1` 或 `> 262272` 返回 TooLarge，`Content-Length == 0` 则进入
decrypt 后返回 BadJSON。Maxio 要求恰好一个显式 Content-Length，因而对手写 raw HTTP 更严格；这是继承 S5 的
deliberate framing safety deviation，不得误报为逐字节 upstream parser 等价。

SIO salt/nonce 随机，因此测试禁止固定 encrypted bytes 或 ciphertext SHA。正确 oracle 是：加密结果长度符合上式、
framing 可解析、使用同一 caller secret 能解回 exact plaintext、错误 caller secret 失败、HTTP headers 与 server
limit 正确。89-byte fixture 只固定 plaintext local design，不固定某次 SIO ciphertext。

这是小型 Admin control body 的有界整读，不放宽 PutObject/UploadPart 大对象必须流式的铁律。

`Request` 可把 S5 mutation-specific 私有命名泛化为 `read_encrypted!/2`、`encrypt!/2` 等，同时保留旧 delegate，
避免 S5 route 回归。不得新建第二套 SIO reader。

### 10.3 响应与压缩

上游 GET 可能被 gzhttp 压缩；Maxio 的 `ResponseTransformPolicy` 必须继续只对 path-style Admin 增加/合并
`Cache-Control: no-transform`，确保 Bandit/proxy 不压缩或改写 SIO bytes。测试必须断言 exact Content-Length、
无 Transfer-Encoding、无 Content-Encoding。这是 deliberate transport repair，不应伪装成上游 raw server
必然具有同样 framing。

GET Content-Type/framing 和错误映射中尚未固定的精确值必须由 pre-implementation fixture 关闭
`VERIFY-AT-IMPL` 后才可写 endpoint RED/production。实现不得猜测新的 `XMaxio*` error code。

---

## 11. CLI 与可观测性

新增第一方本地任务：

```text
mix maxio.admin.config.export
mix maxio.admin.config.import PATH
mix maxio.admin.config.import -
```

精确 Windows argv/stdin 形式必须在 CLI/smoke RED 前由 native mc source/live fixture 关闭 `VERIFY-AT-IMPL`。原则是：

- 本地 CLI 直接调用 Archive，与 HTTP 共享 parser、exposure、snapshot 和 Coordinator；不走环回 HTTP/SIO。
- export 默认把 exact plaintext archive 写 stdout，诊断写 stderr。
- import 从指定文件或 stdin 有界读取，先检查 256 KiB；不得无界 `File.read!` 任意大文件。
- mutation success 只输出 changed count/path 名和 reload/broadcast 状态，不输出值。
- CLI source 使用现有字符串 `"cli"`；Admin HTTP 使用字符串 `"admin_api"`；principal/request id 采用项目既有
  安全约定。
- 抽取共享 `Maxio.Admin.ConfigKV.CLI` formatter，兼容 S5 单 subsystem 与 S7 batch result，避免各 Mix task
  复制并泄漏 outcomes。

结构化日志至少提供：

- `action=config_export|config_import`
- `request_id`
- `config_subsystems` 或安全 changed path count
- `changed_count`
- `committed`
- `local_reload`
- `broadcast`
- 稳定错误 stage/code

不得记录 plaintext archive、单值、ciphertext、caller secret、Authorization、完整 exception inspect 或任意
可能含 secret 的用户 token。

### 11.1 CLI stdin/file 的有界累计读取

stdin 不能用一次 `IO.binread(:stdio, limit + 1)` 假设一次调用等于 EOF。实现必须用固定小 chunk 累计读取，直到：

- `:eof`：返回已累计 binary；第一次就是 `:eof` 时返回 `{:ok, <<>>}`，这是合法空 archive，语义为 reset-all；
- 累计达到 262145-byte sentinel：立即返回 TooLarge，最多保留/分配 limit+1 bytes；
- `{:error, reason}`：返回安全 IO error，不调用 Archive；
- short read：继续读，不能把它当 EOF 或截断成功。

文件路径先做 size 快速拒绝，但为防 stat/read TOCTOU，实际文件 IO 也使用同一累计 sentinel reader。测试必须用可控
reader fake 覆盖多次 short reads、empty EOF、exact limit、limit+1 和中途 error。

### 11.2 ExternalSmoke 的破坏性边界

`Maxio.Compat.ExternalSmoke` 的 native mc export/import 生命周期只允许显式 opt-in 的 disposable、known-baseline
环境。禁止把 export plaintext 当成可无损恢复材料：export 只含 effective values，不含 override/fallback provenance，
重新 import 会把 fallback 值物化为 override，也会增加 audit/version。

冻结策略：

- smoke 开始前要求 explicit destructive/disposable flag，并证明三个公开键处于已知 baseline；
- 同进程/同数据库测试环境在 `after` cleanup 中直接调用 `Maxio.Config.mutate_many/2` reset 三个公开 path，source
  使用字符串 `"system"`；
- 外部远端只能使用可销毁隔离环境，完成后销毁/重建环境；没有直接 Config/DB cleanup 能力时不得对任意持久远端
  运行 import smoke；
- exported plaintext 可用于断言 export 和业务 roundtrip，但不得作为“无痕恢复”步骤或承诺；
- cleanup 仍单独报告 blocker，且 STATUS 必须说明 smoke 会留下 audit history，除非整个隔离数据库被销毁。

除 transcript 外还要验证数据面：导入 public=false/true 后 metrics 鉴权效果变化，遗漏键 reset 后恢复 fallback，
第二次相同 import 无新增 audit/version。

---

## 12. 数据库与 migration 判定

S7 不需要 migration：

- `runtime_configs` 已能保存三个公开键的 override 与逐键 version；
- `runtime_config_audits` 已能记录 set/reset、old/new value、from/to version、source、principal、access key 和
  request id；
- import 只是多个既有 mutation 的一个原子协调边界，不是新持久化实体；
- batch id、archive blob、history target、restart request、配置 epoch 和 job state 均非目标。

实现范围不得修改 `priv/repo/migrations/`。若实现者发现必须迁移，须停止并重新做设计审查，不能顺手加表。

---

## 13. 预计文件边界

新增：

- `lib/maxio/admin/config_kv/archive.ex`
- `lib/maxio/admin/config_kv/cli.ex`
- `lib/mix/tasks/maxio.admin.config.export.ex`
- `lib/mix/tasks/maxio.admin.config.import.ex`
- `test/fixtures/minio_admin_config_export_import_s7/README.md`
- `test/fixtures/minio_admin_config_export_import_s7/*.json`
- `test/maxio/admin/config_kv_archive_test.exs`
- `test/maxio/admin/config_export_import_protocol_fixture_test.exs`
- `test/maxio/admin/config_export_import_endpoint_test.exs`
- `test/maxio/config/coordinator_batch_test.exs`
- `test/maxio/config/coordinator_batch_concurrency_test.exs`
- `test/mix/tasks/maxio_admin_config_export_import_test.exs`

修改：

- `lib/maxio/admin/config_kv/parser.ex`
- `lib/maxio/admin/config_kv/registry.ex`
- `lib/maxio/admin/config_kv/adapter.ex`
- `lib/maxio/admin/config_kv/request.ex`
- `lib/maxio/config.ex`
- `lib/maxio/config/coordinator.ex`
- `lib/maxio/config/store.ex`
- `lib/maxio/cluster/notify.ex`
- `lib/maxio/admin/plug.ex`
- `lib/maxio/admin/authz.ex`
- `lib/maxio/admin/error_map.ex`
- `lib/maxio/compat/external_smoke.ex`
- `test/maxio/config/store_batch_event_test.exs`
- `test/maxio/admin/config_kv_request_test.exs`
- `test/maxio/admin/plug_test.exs`
- `test/maxio/admin/authz_test.exs`
- `test/maxio/admin/error_map_test.exs`
- `test/maxio/compat/external_smoke_test.exs`
- `test/mix/tasks/maxio_admin_config_test.exs`（仅共享 formatter 回归需要时）
- `docs/superpowers/STATUS.md`（仅最终证据 closeout）

预计不改：

- `lib/maxio/config/runtime_config.ex`
- `lib/maxio/config/runtime_config_audit.ex`
- `lib/maxio/config/schema.ex`（除非只增加不改变目录的 invariant helper；优先不改）
- `lib/maxio/s3/plugs/response_transform_policy.ex`
- `priv/repo/migrations/*`

---

## 14. 测试与验证分解

### 14.1 协议 fixture

- 固定 route、action、source commit、SIO、256 KiB/262272、稳定顺序、omitted/default、duplicate patch、unknown
  failure 和 mc restart 分支。
- 所有会决定 RED 或 production 的 `VERIFY-AT-IMPL` 必须在对应 RED/实现 task 开始前由 pinned source 或
  pre-implementation live fixture 关闭；尤其包括 Windows native mc argv/stdin 和每个 ErrorMap status/code/message/
  priority。无法关闭时阻塞相应实现，不能延后到最终 strict-live 首次决定。
- 最终 strict-live 只复验已经冻结的 fixture 和报告环境偏差，不承担首次选择 production contract。
- source-derived、fixture-expected、fake-observed、live-pass 必须明确区分。

### 14.2 Archive 纯测试

- exact 三键、稳定 bytes/order、默认 target；
- hidden/forbidden/orphan 永不输出；
- target/unknown/hidden/forbidden/orphan import fail closed；
- 重复行顺序 patch；
- omitted→reset；
- explicit fallback→set override；
- wire raw scalar 必须经 `Schema.parse/3`，Coordinator typed operation 再经 `Schema.cast/3`；
- invalid UTF-8/raw parse 在 Repo 前失败，per-subsystem validator 在全锁/全读/全 candidate 后且首写前失败；
- sensitive Registry invariant fail closed。

### 14.3 Snapshot 与 Coordinator

- 一次 SELECT 得到一致三键 view；并发 mutation 不产生混合 export；
- corrupt registered stored value fail closed，orphan 不进入结果；
- 全部 advisory lock 早于任何 row read；锁序稳定；
- path-keyed expected_versions 防止同名 key 冲突；per-subsystem validators 恰好一次；legacy wrapper 无损转换；
- 后一 subsystem validator/row/audit 失败时前面所有变化回滚；
- import 与单键 set/reset 串行化，无 lost update；
- 两个反序 batch 无 deadlock；测试用 checkpoint/message，不用 sleep；
- hidden/forbidden/orphan row 保持不变；
- changed 逐键 version/audit/source/principal/request_id；
- no-op 零 DB 写、零 reload、零 broadcast；
- touched/changed subsystem 集合分离，broadcast 只含 changed；
- changed 恰好一次同步 reload、一次 batch checked broadcast、真实 PubSub self-loop 不二次 reload、重复远端 event
  去重、失败 attention 无值。

### 14.4 HTTP/SIO/安全

- denied request 不读 body；
- caller A 签名只能用 caller A secret 解/加密，不能回退 root secret；
- SIO 公式与 261975 PASS、261976 server TooLarge、262144 client-pass/server-reject 精确边界；
- 随机 SIO 只断言 decrypt oracle/framing/length，不固定 ciphertext bytes/SHA；
- CL 缺失/重复/错误、TE、实际短读、hash mismatch、decrypt、UTF-8、parse 的错误优先级；
- exact route、framing、Content-Length、无 TE/CE、no-transform；
- adjacent unsupported Admin route 仍走既有结构化 501/安全边界；
- 日志、ErrorMap、attention、CLI 无 plaintext/ciphertext/secret/value。

### 14.5 CLI、smoke 与集群

- 本地 export exact stdout，import 文件/stdin 有界；
- stdin 累计读到 EOF/262145 sentinel，覆盖 empty EOF、short reads、error；
- safe batch formatter 与 S5 formatter 回归；
- pinned native mc human/JSON export/import 仅在 disposable known-baseline；cleanup 直接 Config reset 或销毁隔离环境，
  不用 export plaintext 冒充 provenance restore；
- data-plane hot effect、omitted reset、第二次 no-op；
- 真实本地 PubSub self-loop/different-origin replay 功能测试必须 PASS；可用真实两节点环境时另证一次 remote batch
  reload，环境缺失则该 live probe 单独 BLOCKED；
- 丢广播或旧 event consumer 最迟在 digest interval 内收敛。

---

## 15. 风险与防线

1. **协议细节仍有 live 空白。** 所有会决定实现的空白必须由 pre-implementation fixture 关闭，未关闭即阻塞；最终
   strict-live 只复验。
2. **逐 subsystem 调用造成部分提交。** Archive 只能调用 `Config.mutate_many/2`。
3. **锁序死锁。** 全部 advisory lock 必须在任何 row read 前按 binary subsystem 序取得。
4. **导出混合快照。** 只允许一次 authoritative SELECT，不循环调用现有单 subsystem read。
5. **暴露面漂移。** Registry 是唯一 catalog，并对 sensitive/hidden/forbidden 建 invariant 测试。
6. **显式默认值被错误折叠。** explicit fallback 必须 set；只有 omitted reset。
7. **post-commit 被误报为事务失败。** committed 与 applied/attention 分开，禁止回滚/自动重试。
8. **本地 PubSub 回环或远端 replay 重复 full reload。** batch event 携带 origin/epoch，本地忽略 self-origin，远端
   使用有界 cache 去重，并由真实 PubSub test 证明。
9. **滚动升级旧节点忽略 batch event。** digest reconcile 兜底并做 strict-live；STATUS 记录延迟边界。
10. **caller secret 或配置值泄漏。** secret 留在请求进程，closed vocabulary 日志，扫描所有失败路径和 CLI。
11. **控制体无界内存或 stdin short-read 截断。** ciphertext/plaintext 双上限，文件/stdin 累计读取到 EOF 或
    limit+1 sentinel，不把 short read 当 EOF。
12. **mc restart 文案与 Maxio hot apply 混淆。** transcript 按真实客户端，数据面另行证明实际效果，不实现 restart。

---

## 16. 完成判据

S7 只有同时满足以下条件才可完成：

- 独立 protocol fixture review 在每个对应 RED/implementation task 前关闭全部会影响实现的
  `VERIFY-AT-IMPL`；Windows mc argv/stdin 和 ErrorMap 不能留到最终 live；
- 测试 lane 先提交 RED，生产实现 lane 与 reviewer 均为不同上下文；
- 所有 task review 无 Critical/Important；
- focused batch、compile warnings-as-errors、format 和 diff gates 通过；
- pinned native mc 与 direct signed HTTP strict-live 对已冻结 contract 给出明确 PASS 或诚实 BLOCKED；
- 真实本地 Phoenix.PubSub self-loop/remote-origin 功能测试必须 PASS；真实两节点环境存在时提供 live 证据，环境缺失
  可诚实记录 BLOCKED，但不能把 fake/单节点结果升级为两节点 PASS；
- 两个独立 whole-range reviewer 均给出零 Critical/Important；
- coherent batch 末只运行一次最终成功 `mix precommit`；
- 最终只用 `docs/superpowers/STATUS.md` 记录事实和证据；
- feature/master 仅 ff-only 集成，并以一次 atomic push 更新两个远端 ref；
- 无 migration、无 secret/backend/orphan 暴露、无 tracked live credential/artifact。
