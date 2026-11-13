# AGENTS.md — maxio（Elixir/Phoenix S3 兼容对象存储）

> 本文件是本仓库**跨工具的工程准则单一来源**——**只保留约束性铁律与索引**。任何 AI 代理（Claude Code / Codex / 其它）在本仓库工作前必读。
> 工程背景、技术栈、命令、结构、工具链、编码约定等较长参考内容已迁出，按需查阅：
> - 工程背景 / 技术栈 / 仓库结构 / 常用命令 / 本机工具链 / 编码约定 → [`docs/reference/engineering/project-engineering-guide.md`](docs/reference/engineering/project-engineering-guide.md)
> - Phoenix 1.8 / `phx.new` / LiveView / Ecto 专项规则 → [`docs/reference/engineering/phoenix-phx-new-guidelines.md`](docs/reference/engineering/phoenix-phx-new-guidelines.md)
> - 项目“此刻为真”的进度、批次证据与已固化决策 → [`docs/superpowers/STATUS.md`](docs/superpowers/STATUS.md)
> - 设计 spec → [`docs/superpowers/specs/`](docs/superpowers/specs/)；实现计划 → [`docs/superpowers/plans/`](docs/superpowers/plans/)

## 1. 项目与当前焦点

**maxio** 用 Elixir/Phoenix 复刻 [MinIO](https://github.com/minio/minio) 的全功能、**Amazon S3 兼容**对象存储：对外暴露 S3 REST API（aws-cli / boto3 / mc / 各语言 SDK 直连）与 MinIO Admin API 子集（`mc admin`），对内做 SigV4 鉴权、IAM / bucket policy 授权、对象 / 桶 / 分段上传管理、可插拔存储后端（单机 FS → 纠删码 → 多节点分布式），并提供 MinIO Console 式的 LiveView 管理控制台。

**开发平台**：本机 Windows 11 原生开发与测试（工具链与已知坑见工程参考）。

**当前焦点与里程碑**（M0–M8、路线 B、ObjectMutation 各 Phase、MinIO Admin 切片）以 STATUS.md 的里程碑表与顶部最新批次为准；本文件不复述进度。

## 2. 架构铁律

1. **统一数据契约**：所有 S3 请求 normalize 成内部 `Maxio.S3.Request` / `Response` 契约；**存储后端、凭据后端、策略后端均经 behaviour 抽象**，上层（handler / 编排）只认契约与 behaviour，对后端实现无感。
2. **后端即插件**：新存储后端（FS / 纠删码 / 分布式）、新凭据 / 策略后端 = 实现对应 behaviour + 注册，**核心请求管线一行不改**。
3. **明确状态设计 + 绝不静默失败**：鉴权失败、授权拒绝、流式分块签名 / 哈希校验失败、分片不足、持久化写入失败，**必须返回结构化 S3 错误（XML + 正确 HTTP 状态）并打结构化日志，绝不静默放行、静默落盘或返回错字节**。流式 / 多步操作（分块上传、流式签名、对象变更协议）用**显式状态机**驱动。
4. **body 绝不进内存**：PutObject / UploadPart 的对象字节（可达数 GB）**绝不挂 `Plug.Parsers`、绝不全缓冲**，必须 `read_body` 流式拉取交存储层；只有小 XML（CompleteMultipartUpload / Delete 等）走带上限的整读。
5. **S3 / MinIO 行为对齐真实实现**：错误码 / HTTP 状态、XML 元素与命名空间、ETag / Range / 条件头语义、签名规范、Admin API 线格式，**以 AWS 官方文档、SDK 测试向量与钉版 MinIO / madmin 源码为准**，不凭记忆。不确定处标 `VERIFY-AT-IMPL`，实现前核验并冻结证据。
6. **S3 与 Console 双 Endpoint 物理隔离**：S3 走独立 `Maxio.S3.Endpoint`（Bandit，不挂 `Plug.Parsers`），Console 走 `MaxioWeb.Endpoint`；不得让一侧的管线、解析器或会话机制渗入另一侧。
7. **动作分发用判定表**：S3 是 RPC-over-query，动作由 `Maxio.S3.Dispatcher` 判定表（level × method × query keys）决定，不用 Router 表达；未实现的动作显式返回 `NotImplemented`。

### 2.1 架构设计指导思想（系统正交，最高纲领）

1. **系统正交**：每个系统只负责一件清晰的事；系统间只走**稳定契约**，不共享可变的隐式假设。改 A 莫名弄坏概念上无关的 B，就是隐藏耦合，是设计缺陷。
2. **自维护不变量**：一个系统对外承诺的**所有**不变量（**含活性 / 续租 / 超时 / 重连 / 锁持有等时间性不变量**）必须由它**自己持续维护**；绝不让别的系统的正确性悄悄依赖一个**没人维护**的假设。警惕「一次性建立、之后没人管」的资源（锁、lease、连接、缓存、订阅、outbox 游标）静默失效。
3. **显式契约 > 隐式假设**：跨系统依赖要么**承诺方强制维护契约**，要么**依赖方对破坏鲁棒（自愈）**。默认选前者；依赖方自愈只在契约破坏属于已验证的失败模型时才引入，并按 §2.2 第 7 条写清边界与退出条件。

> 诊断 bug 先排除红鲱鱼：先问「这故障跟我以为的原因真有因果吗」，再动手修。

### 2.2 通用设计纪律（所有代码与文档适用）

> 下列纪律与本节架构铁律共同生效。所谓“极简”，是把必要复杂度集中在唯一 owner、信任边界和不变量构造入口，删除内部链路上的重复防御与偶然复杂度。

1. **极简哲学**：只引入完成当前已批准目标所需的最少概念、状态、分支、配置和层级；同等正确的方案优先删除、复用与直接组合。任何新增抽象必须有当前调用方、明确职责和可验证收益。
2. **DRY（语义去重）**：同一业务规则、契约、常量、状态所有权或算法只定义一次；其他位置必须调用、导入、生成或链接到权威定义，禁止复制后各自演化。不要把表面相似误判为同一语义：生命周期或变化原因不同的代码不得为消除文本重复而强行共用抽象。
3. **唯一事实源（SSOT）**：每项对外有意义的事实必须明确唯一 owner 与 canonical source；文档摘要、CLI、缓存、视图和兼容表示只能是可追溯的派生物，并具备生成、同步或失效机制。发生冲突时以权威源为准并修复派生物，禁止从多个来源猜测、拼接或按“哪个可用就用哪个”决定真值。
4. **高内聚、低耦合**：数据、行为、入口校验和不变量构造应由同一职责模块完整拥有；模块只暴露类型化合法状态、显式失败结果与完成协作所需的最小稳定契约。禁止共享可变内部状态、穿透内部 worker、依赖全局执行顺序，或让调用方拼装本应由模块维护的正确性。
5. **功能模块正交**：不同功能应成为可独立理解、测试、替换和演化的变化轴，只在明确的组合根或编排边界协作。修改 A 若迫使概念上无关的 B 同步修改，先视为隐藏耦合并修正边界，不用额外开关、条件分支或同步补丁掩盖。
6. **信任边界校验一次**：外部输入（S3 / Admin 请求、签名、XML、query）、持久化加载、网络 / 节点边界、权限与安全、并发提交，以及不变量构造入口，必须由负责接纳数据的权威模块完成一次必要校验，并把结果构造成类型化合法状态或显式失败。合法状态进入内部可信链路后，后续模块必须直接消费该契约，禁止重复同一校验、二次解析原始数据、全量扫描状态、增设兜底分支或层层 `fail-closed`。只有数据再次跨越新的信任边界时才重新验证；下游可以处理契约显式返回的失败状态，并只校验自己新构造的不变量，但不得重新推断或复核上游已保证的不变量。
7. **不过度设计、不过度兜底**：没有当前需求或失败证据，不预建扩展点、通用框架、兼容层、第二实现、自动重试、自愈或降级路径。兜底只在产品契约或已验证失败模型明确要求时存在，并由对应 owner 在明确边界内实现，同时写清触发条件、语义边界、可观测性、测试和退出条件；否则显式失败。禁止下游以“以防万一”为由追加重复门禁、状态扫描或备用真值路径；禁止用宽泛 `rescue` 把自身 bug 伪装成外部失败。
8. **证据优先决策，禁止凭空发明**：凡影响架构、算法、协议、数据模型、模块边界、正确性、安全、并发、性能或运行行为的实质性技术决策，实施前必须查证已有最佳实践。依据优先级：AWS S3 API Reference / SigV4 规范 / AWS SDK 官方测试向量 / 钉版 MinIO 与 madmin 源码 / Elixir、Phoenix、Bandit、Plug、saxy、Ecto、Rustler 官方文档 → 同行评审论文 / 经典专业著作 → 成熟工业系统的工程文档 / 技术报告 / 事故复盘；官方文档检索不便时可经 Context Hub（`chub`）获取，再以 web 搜索兜底；二手文章只能作为检索线索，禁止仅凭模型记忆、个人偏好或“看起来合理”决策。采用依据时必须说明来源、适用条件、与本项目约束的对应关系及取舍，并记入最近的既有 spec、plan、STATUS 批次或 fixture README，不为小改动另造文档。确无可适用实践而必须创造时，须标记为“原创决策”，并在实施前向用户报告检索范围、现有方案不适用的原因、创造理由、风险、不变量与验证方式。
9. **自然数据流**：批次、组、队列、mailbox、outbox 与生产者 / 消费者只承担运输与调度，决定“什么时候、按什么顺序到达”；它们不得成为第二真值，不得附带自己的正确性协议，也不得让分组边界改变单元语义（如 aws-chunked 分块边界、分段上传的 part 边界、纠删码条带边界不得改变对象字节语义）。输入的合法性由唯一 owner 在构造边界一次性冻结为不可变、类型化的合法状态与确定顺序，内部消费者此后只按同一种自然单元线性推进，不为“最后一个”“跨批的那个”“特别大的那个”另设特殊事务、合并放大或第二条流水。派生结论（覆盖、进度、凭证、索引）必须从该唯一序列与既有 fence 推导，不复制成可写状态。验收阈值、测试门禁与观测指标只属于测试与验收侧，禁止反向编译进生产路径变成重复扫描、层层检查、兜底或备用路径。若某个不可分割单元的成本本身超标，修复点在产生该单元的上游划分，不在消费侧加补丁。

## 3. 工程方法约束（强制，违反即返工）

1. **CLI + 结构化日志优先**：任何后端功能都要能经 **CLI（`mix maxio.*` 任务 / IEx 辅助）+ 结构化日志**完整观测调试，无 GUI 也能闭环（如 `mix maxio.sigv4.debug` 复算 canonical request / string-to-sign / 各级 HMAC，定位“签名不匹配”）。关键管线阶段留结构化日志（含 `request_id` / `bucket` / `key` / `auth_type` / `action` 等元数据）；日志不写凭据、签名密钥与对象字节。新功能与其 CLI 同批交付。验收优先用 CLI / 日志 / 真实客户端取证，不以截图作为唯一依据。
2. **先定义可观测面再实现**：新增或修改运行时逻辑前，先明确调试时需要从 CLI / 日志直接读到哪些状态、输入、输出、错误原因，再实现功能本身。
3. **Console 浏览器端可调试**：管理控制台用浏览器自动化工具调试与验证（导航 / 截图 / 读 console / 读 network / 执行 JS）；前端输出带标签结构化 console 日志（如 `[maxio][Console]`）。
4. **观察产物可复现、易清理**：取证与观察产物写入已被 gitignore 的 `artifacts/` 或 `tmp/`（或显式配置目录）；需要入库的协议证据放 `test/fixtures/<切片>/` 并附 README 与哈希清单。不得提交构建出的二进制、真实凭据或本机绝对路径。
5. **功能必须可验证、可测试、可操作，三入口覆盖**：不能只实现底层核心而让用户无法触发、无法观察、无法判断是否正确。对外功能必须同时具备真实客户端入口（aws-cli / boto3 / mc / Console）、自动化测试入口、CLI / 日志验证入口，并在最终验收中覆盖。
6. **禁止补丁式修复**：遇到 bug 先委派独立代理系统化调试、定位根因和边界归属，修复方案从整体架构出发并说明如何契合 §2 铁律；不要用局部 hack、吞错、硬编码等待、临时绕路掩盖问题。S3 兼容问题（签名不匹配、XML 不被 SDK 接受、错误码不符）必须对照官方文档 / 测试向量 / MinIO 源码定位，不靠猜。
7. **阶段性改动先有决策稿**：新增里程碑 / 切片、重排模块边界、协议或线格式扩展、元数据 / 事务 / 集群行为变化，先在 `docs/superpowers/specs/` 写目标、范围、非目标、决策项、测试矩阵，再在 `docs/superpowers/plans/` 写可勾选的任务计划；进度与证据写回 STATUS.md。
8. **不确定就先查本仓真相源**：对既有行为不确定时，先查 STATUS.md、相关 spec / plan、fixture README 与现有测试，再按 §2.2 第 8 条查外部权威资料。
9. **代码旁文档同步维护**：
   - Elixir 公共模块补 `@moduledoc`，公共函数补 `@doc`；Rust 公共模块补 `//!`，公共类型 / 函数补 `///`。
   - 涉及监督树、请求管线、存储 / 元数据分层、协议层与实现层关系变化的修改，必须同步更新对应 spec、STATUS 或 README（README 声称支持的能力必须与代码一致）。
   - 子系统说明以 `@moduledoc` 与 spec 为载体，不强制 `lib/` 下目录 README；新增目录 README 时同样纳入同步维护。
10. **写文档时活用 mermaid 图**解释概念、流程、所有权、状态机与阶段边界。
11. **代码中的所有注释统一用中文**，写“为什么”。新增或改写的注释不写阶段 / 里程碑代号（M7、Phase 1、B4-2 等，它们属于 STATUS 与 spec）；既有注释在触及时顺手改正，不为此单独批量改写。
12. **数据库 schema 自文档化**：所有迁移建的表、列、索引、自定义类型，凡能加注释处必须加中文 `COMMENT`（Ecto `comment:` 选项；裸 `execute` 建的索引用单独 `COMMENT ON INDEX`，down 置 `NULL`；enum 用 `COMMENT ON TYPE`），使 `psql \d+` 即可读懂 schema。
13. **最小充分测试**：测试范围由本次变更的契约、失败模型和直接影响边界推导，不由“跑得越多越安全”推导。先写能证伪本次改动的最小测试（改前红、改后绿），再补该改动自身引入的边界与回归；禁止为求保险盲目扩大 suite、抬高环境档次、加大数据量或重复验证上游契约已经保证、其它用例已经覆盖的事实。只有当改动触达共享契约、跨模块边界，或已有失败证据显示风险确实扩散时才扩大范围，并在验收说明中写清扩大的理由与它能抓住的具体破坏。
14. **人类友好**：代码要让人能理解、能读懂、能共同开发、能维护。参考大型开源项目的代码规范，在命名、函数长度、注释与可读性上优化；不写只有作者当下才看得懂的代码。
15. **主机资源安全**：本机依赖远程连接工具，远程可用性优先于开发与测试。测试、探针、活体演练、多节点集群（含 libcluster UDP Gossip）必须预先限定并发数、尝试次数与总时长，成功 / 失败 / 超时 / 取消路径都要释放其拥有的进程、套接字与容器；禁止按请求新建端点、无界重试、无界并发或遗留后台进程。只清理本任务创建的资源，不得停止其它项目的容器或远程服务。

### 3.1 S3 / Admin 端到端验证（强制）

声明 S3 或 Admin 操作“可用”前，必须用**真实客户端做端到端活体取证**：aws-cli（`--endpoint-url` 指向 dev S3 端点，端口见工程参考）、boto3、`mc` / `mc admin`，或自签 SigV4 的 ExUnit 集成测试——证明能创建桶、Put / Get / List / Delete 对象、签名通过、XML / JSON 被客户端正确解析。上传路径必须覆盖 aws-chunked（`STREAMING-AWS4-HMAC-SHA256-PAYLOAD`，S3 兼容的头号风险）；本机 aws-cli 对 http 端点默认不走 aws-chunked，须由 `mc` 或自签测试覆盖。客户端缺失导致无法活体取证时，STATUS 中必须如实标为 blocked，不得写成通过。

## 4. 会话与代理约束（强制）

1. **短平快会话**：工作时把任务细粒度合理切分，分配给独立的代理会话（subagent / worker）执行；总会话只负责统筹、安排与集成，让所有会话的上下文长度维持在尽量短的区间。
2. **职责代理级隔离**：设计 / 架构、研究 / 查资料、开发 / 实现、测试 / 审查 / 验证四类职责**永远由独立代理承担**，一个代理不得同时承担两类。**实现者绝不自审**：写代码的代理与审查 / 验证的代理必须是不同代理、不同上下文。编写 RED 测试与开发中的聚焦测试属于开发职责；“测试 / 审查 / 验证”职责指独立复核测试能否证伪改动、执行验收命令并收集证据。
3. **编排者边界**：总会话不亲自承担上述任一专职职责；例外仅限规划类文档（`AGENTS.md`、`CLAUDE.md`、spec、plan、STATUS.md）的直接编写。
4. **角色映射**：

   | 职责 | Claude Code | Codex / 其它 |
   |---|---|---|
   | 设计 / 架构 / 计划 | `Plan` 子代理 | 独立规划会话 |
   | 研究 / 查资料 / 探索代码 | `Explore`、`general-purpose` | 独立只读会话 |
   | 开发 / 实现 | `general-purpose` | 独立实现 worker |
   | 测试 / 审查 / 验证 | 独立 `general-purpose` | 独立审查 worker |

   模型选择：设计 / 架构与安全相关或大范围改动的实现、审查用最强模型；常规实现用中档模型；研究 / 探索可用较快模型。Console 浏览器调试在 Claude Code 中用 Claude-in-Chrome 工具，其它工具用等价的浏览器自动化能力。
5. **委派说明完整**：委派时写清目标、范围、已排除项、相关文件与验收标准；不要把自己的假设当结论交给审查者，审查应拿到代码而不是作者的结论。
6. **并行与串行**：彼此独立的研究 / 审查任务并行委派；同一工作区内涉及 mix 编译的实现任务串行执行（避免并行编译竞争 `_build` 与锁文件）。
7. **分支与工作区纪律**：一个切片一个分支（`codex/<切片>`）与一个 worktree（`.worktrees/<切片>`）；切片合并并推送后及时移除对应 worktree 与本地分支。会话结束前未提交的半成品必须在 STATUS.md 或计划中写明状态与下一步，不得只留在本地工作区。
8. **跨会话交接**：STATUS.md 是唯一的跨会话状态源（抗闪退）；每个批次收口时更新，记录完成内容、验证证据（命令 + 结果）、残余风险与下一步。不得依赖会话记忆或聊天记录作为进度真值。
9. **验证才算完成**：声明“完成 / 修复 / 通过”前，必须由独立验证代理执行验证命令并收集证据；失败则继续迭代。完成判据：零待办、`compile --warnings-as-errors` 零警告、测试通过、审查证据齐备、可经 CLI / 日志 / 真实客户端复现验证。审查须自建取证环境（不要沿用作者遗留的进程或构建）；判断测试是否空转时用变异实验（改回错误实现，测试必须变红）。
10. **批次收口**：开发中不得每个小功能点都跑完整 `mix precommit`，先用聚焦 `mix test`、`mix compile --warnings-as-errors`、必要的 `mix format --check-formatted` 快速反馈；多个相关功能点合并为一个 coherent batch 后，再独立复审、更新 STATUS，并在批次收口或最终交付时跑一次完整 `mix precommit`。
11. **最终说明分层**：交付说明必须区分实现内容、验证证据（命令、结果、产物位置）与残余风险 / 未覆盖项。

## 5. 推荐工作流

1. **定位影响范围**：判断改动属于 S3 管线（plugs / dispatcher / handler）、Admin API、IAM / 策略、存储后端、元数据、集群、ObjectMutation、Console 还是文档主线。
2. **读最近文档**：STATUS.md 顶部最新批次 → 相关 spec / plan → 对应模块 `@moduledoc` 与现有测试 / fixture。
3. **研究与决策稿**：按 §2.2 第 8 条查证权威资料；需要时冻结协议证据（fixture + 哈希），写 spec / plan。
4. **设计可观测性**：先定义 CLI 输出与结构化日志字段。
5. **RED → 实现 → 审查**：先写能证伪改动的失败测试，再由实现代理落地，再由独立代理审查与修复闭环。
6. **验证闭环**：聚焦测试 → 批次 `mix precommit` → 真实客户端活体取证（§3.1）→ 更新 STATUS → 合并推送 → 清理 worktree。

## 6. 验证入口

> 跑任何 mix 命令前必须设置 `ERL_FLAGS="-kernel standard_io_encoding unicode"`（详见工程参考）。

- 编译：`mix compile --warnings-as-errors`
- 聚焦测试：`mix test <路径或文件>`；含 `:peer` 真节点集成测试：`mix test --include distributed`（默认排除）
- 批次收口：`mix precommit`（组成见工程参考）
- 签名取证：`mix maxio.sigv4.debug`
- 活体取证：aws-cli / boto3 / `mc` 对 dev S3 端点（§3.1）
- 完整命令、数据库与工具链见 [`docs/reference/engineering/project-engineering-guide.md`](docs/reference/engineering/project-engineering-guide.md)

## 7. 关键路径（索引）

- 当前状态 / 批次证据 / 已固化决策：[`docs/superpowers/STATUS.md`](docs/superpowers/STATUS.md)
- 待办：[`docs/superpowers/TODO.md`](docs/superpowers/TODO.md)
- 基础设计：[`docs/superpowers/specs/2026-06-08-maxio-s3-foundation-design.md`](docs/superpowers/specs/2026-06-08-maxio-s3-foundation-design.md)（子系统设计见 `specs/_design_inputs/auth_iam.md`、`specs/_design_inputs/s3_api_layer.md`）
- MinIO Admin API 设计：[`docs/superpowers/specs/2026-08-18-minio-admin-surface-design.md`](docs/superpowers/specs/2026-08-18-minio-admin-surface-design.md)、[`2026-08-20-minio-admin-user-policy-design.md`](docs/superpowers/specs/2026-08-20-minio-admin-user-policy-design.md)、[`2026-08-29-minio-admin-config-kv-design.md`](docs/superpowers/specs/2026-08-29-minio-admin-config-kv-design.md)、[`2026-08-29-minio-admin-config-help-s6-design.md`](docs/superpowers/specs/2026-08-29-minio-admin-config-help-s6-design.md)
- ObjectMutation final fingerprint gate：[`docs/superpowers/specs/2026-07-28-object-mutation-final-fingerprint-gate-design.md`](docs/superpowers/specs/2026-07-28-object-mutation-final-fingerprint-gate-design.md)
- 实现计划：[`docs/superpowers/plans/`](docs/superpowers/plans/)；活体演练手册：[`docs/superpowers/runbooks/`](docs/superpowers/runbooks/)
- 工程参考：[`docs/reference/engineering/project-engineering-guide.md`](docs/reference/engineering/project-engineering-guide.md)
- Phoenix / LiveView / Ecto 规则：[`docs/reference/engineering/phoenix-phx-new-guidelines.md`](docs/reference/engineering/phoenix-phx-new-guidelines.md)
