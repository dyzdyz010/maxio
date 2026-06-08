# maxio · 项目状态（STATUS）

> 单一事实来源（cross-session / 抗闪退）。最后更新：2026-06-08。
> 设计 spec：`docs/superpowers/specs/2026-06-08-maxio-s3-foundation-design.md`（+ `_design_inputs/`）
> 工程准则：`AGENTS.md`（先读）；Claude/OMC 执行细节：`CLAUDE.md`

## 项目目标

用 Elixir/Phoenix 完整复刻 MinIO 的全功能、Amazon S3 兼容对象存储系统（aws-cli/boto3/mc/SDK 直连）。工程约束参考姊妹项目寰析（huanxi）。

## 里程碑进度

| 里程碑 | 内容 | 状态 |
|---|---|---|
| **脚手架** | Phoenix 1.8 项目（Maxio/`:maxio`/`Maxio.Repo`）、Ecto+Postgres、Bandit；config 已关 ColocatedJS 符号链接警告 | ✅ 已生成、可编译 |
| **设计** | 两份子系统设计（S3 API 层、SigV4/IAM）+ 合并 spec 索引 + 工程铁律注入 AGENTS/CLAUDE | ✅ 已完成（2026-06-08） |
| **M0 地基** | 存储后端 behaviour + FS；bucket/object 元数据 schema（中文 COMMENT）+ 上下文；s3 config；结构化日志基座 | 🚧 进行中（本会话） |
| **M1 S3 核心读写** | 独立 S3 Endpoint + AddressStyle + SigV4 + Dispatcher + bucket/object handlers + ListObjectsV2 + XML + 错误映射 + CLI；aws-cli e2e | 🚧 进行中（本会话） |
| **M2 分段上传 + 流式** | multipart + aws-chunked 流式签名 + Range + 条件头 + DeleteObjects | ⬜ 待 |
| **M3 IAM / 策略** | access key + EctoStore + policy 评估 + canned ACL + presigned + Authz | ⬜ 待 |
| **M4 高级特性** | versioning / tagging / lifecycle / CORS / CopyObject / SSE | ⬜ 待 |
| **M5 Console** | LiveView 管理台 | ⬜ 待 |
| **M6 纠删码 / 分布式** | Reed-Solomon（Rustler）+ 分布式 + 自愈 | ⬜ 待 |

## 当前会话进展（2026-06-08）

接手上一被中断会话（停在设计阶段，已产出两份 `_design_inputs/` 设计文档）。本会话：
1. ✅ 把工程铁律注入 `AGENTS.md`（前置 maxio 身份 + 架构/工程铁律 + 保留 Phoenix usage-rules）、新建 `CLAUDE.md`（OMC 角色映射 + S3 调试约定）。
2. ✅ 创建合并 spec 索引 `specs/2026-06-08-maxio-s3-foundation-design.md` 与本 STATUS.md。
3. 🚧 M0+M1 垂直切片：研究核验 → planner 详细计划 → 串行 executor 实现 → 独立审查/验证（进行中）。

## 工具链与环境（本机 Windows 11，关键教训）

- **Elixir 1.20.0 / Erlang OTP 28** 在 `C:\Users\dyz\Documents\dev\usr\Elixir\bin`；mix / phx_new 1.8.5 / hex 已装；docker / git 可用；**psql 不在 PATH**（用 `docker exec maxio-db psql -U postgres -d maxio_dev -c "..."`）。
- **Postgres**：专用容器 `maxio-db`（postgres:16，端口 5432，卷 `maxio_pgdata`，user/pass=postgres/postgres，db=maxio_dev）。`docker start maxio-db` 恢复。dev.exs 默认连 localhost:5432。
- **坑1（phx.new 崩溃）**：在已存在的非空目录 `mix phx.new .` 会触发交互确认，非 TTY 下读 stdin 失败 → VM 硬崩留 `erl_crash.dump`。解法：生成到全新目录再合并（脚手架已生成，本坑已过）。
- **坑2（Unicode 硬崩）**：mix 输出重定向到非 TTY 时编译期中文/Unicode 输出触发 `io.put_chars badarg` 硬崩。**跑 mix 前必设** `$env:ERL_FLAGS="-kernel standard_io_encoding unicode"`。
- **坑3（ColocatedJS 符号链接）**：Windows 非管理员下 LiveView ColocatedJS 建 node_modules 符号链接失败（:eperm）。已在 `config/config.exs` 设 `config :phoenix_live_view, :colocated_js, disable_symlink_warning: true`。

## 已固化的关键决策

1. **S3 与 Console 双 Endpoint 物理隔离**：S3 走新增独立 `Maxio.S3.Endpoint`（端口 9000，不挂 Plug.Parsers）；Console 走现有 `MaxioWeb.Endpoint`（端口 4000）。理由见 s3_api_layer.md 决策 1（MinIO 本身 API/Console 端口分离）。
2. **动作分发用判定表非 Router**：`Maxio.S3.Dispatcher.resolve(level, method, query_keys)`（S3 是 RPC-over-query，Router 表达不了 `?uploads` vs `?acl`）。
3. **三大后端均 behaviour 抽象**：存储（FS→纠删码→分布式）、凭据（Memory→Ecto）、策略——上层只认 behaviour（铁律 1/2）。
4. **body 流式**：对象字节绝不进 Plug.Parsers/不全缓冲；小 XML 走带上限整读 + saxy。
5. **XML 用 saxy**：出站 builder + 入站 SAX 解析，一依赖两用。
6. **M1 签名范围**：header-based SigV4（单块 + UNSIGNED-PAYLOAD）+ presigned；aws-chunked 流式签名留 M2（aws-cli 默认上传方式，头号兼容风险）。

## 下一步（续作入口）

- 本会话 M0+M1 完成后：M2（aws-chunked 流式签名 + multipart）是打通 **aws-cli 默认大文件上传**的关键，应优先。
- 每完成一里程碑：独立 reviewer/verifier 取证 + 更新本 STATUS + 提交。
