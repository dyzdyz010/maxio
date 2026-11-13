# 项目工程参考（技术栈 / 结构 / 命令 / 工具链 / 约定）

> 本文件是 maxio 的**工程背景与参考资料**，从 `AGENTS.md` / `CLAUDE.md` 迁出（2026-11-12）。
> - 约束性铁律与工程纪律见 [`AGENTS.md`](../../../AGENTS.md)（跨工具工程准则单一来源）。
> - 进度、批次证据与已固化决策见 [`docs/superpowers/STATUS.md`](../../superpowers/STATUS.md)。
> - 本文件只提供长期相对稳定的项目概览、技术栈、结构、命令、工具链与编码约定，不记录易变的进度。
> - 本机工具链与环境的现行描述以本文件为准；STATUS.md「工具链与环境」节是 2026-06 的历史记录。

## 项目概览

maxio 用 Elixir/Phoenix 复刻 [MinIO](https://github.com/minio/minio) 的 **Amazon S3 兼容**对象存储：
对外暴露 S3 REST API（aws-cli / boto3 / mc / 各语言 SDK 直连）与 MinIO Admin API 子集（`/minio/admin/v3/*`，供 `mc admin` 使用），
对内做 SigV4 鉴权、IAM / bucket policy 授权、对象 / 桶 / 分段上传管理、可插拔存储后端（单机 FS → 纠删码 → 多节点分布式），
并提供 MinIO Console 式的 LiveView 管理控制台。

## 技术栈

- **语言**：Erlang/OTP 29（erts-17.0.4）/ Elixir 1.20.2（本机安装于 `C:\Program Files\Erlang OTP`、`C:\Program Files\Elixir`；仓库无 `.tool-versions`）
- **Web / HTTP**：Phoenix 1.8 + LiveView（Console）、Bandit（S3 Endpoint，流式 body）、Plug 管线、`:req`（HTTP 客户端）
- **S3 协议**：SigV4（header / presigned / aws-chunked streaming / trailer）、XML 出入站用 `saxy`、RPC-over-query 判定表分发
- **元数据**：PostgreSQL + Ecto（默认 `:pg` 元数据模式）；路线 B 的对象 sidecar 权威为 opt-in（见 STATUS「路线 B」）
- **原生扩展**：Rust via Rustler（`native/maxio_native`）
- **集群**：libcluster（dev 用 Gossip，UDP 多播）+ `:peer` 分布式集成测试

## 仓库结构

```text
maxio/
├── config/                  # dev/test/prod/runtime 配置（runtime.exs 读 MAXIO_* / PORT 等环境变量）
├── docs/
│   ├── reference/engineering/   # 本文件、Phoenix 规则等长稳参考
│   └── superpowers/
│       ├── STATUS.md            # 当前状态与批次证据（单一事实源，跨会话）
│       ├── TODO.md
│       ├── specs/               # 设计 spec（含 _design_inputs/ 子系统设计）
│       ├── plans/               # 实现计划（按切片 / 阶段）
│       └── runbooks/            # 活体演练手册
├── lib/
│   ├── maxio/               # 领域与运行时
│   │   ├── s3/              # S3 Endpoint、plugs（SigV4 等）、Dispatcher 判定表、handlers、XML
│   │   ├── admin/           # MinIO Admin API（/minio/admin/v3/*）
│   │   ├── iam/ sts/ policy/ auth/   # 凭据、IAM、STS、策略评估
│   │   ├── storage/         # 存储后端 behaviour 与 FS / 纠删码实现
│   │   ├── cluster/         # 多节点路由、锁、拓扑、分片传输
│   │   ├── object_mutation/ # 对象变更协议（PG 写权威 + durable recovery）
│   │   ├── config/          # 运行时配置存储（Admin config KV 的后端）
│   │   ├── ops/             # 运维门禁、release readiness 证据
│   │   └── …                # buckets / objects / multipart / versioning / lifecycle / kms / native 等
│   ├── maxio_web/           # Console（LiveView）与 Phoenix Endpoint
│   └── mix/tasks/           # CLI：`mix maxio.*`（127 个任务）
├── native/maxio_native/     # Rust NIF：Reed-Solomon 编解码、BLAKE3、Windows reparse point 检测
├── priv/repo/migrations/    # Ecto 迁移（中文 COMMENT 自文档化）
└── test/                    # ExUnit；test/fixtures/ 下有冻结的协议证据
```

## 架构分层

```text
S3 客户端（aws-cli / boto3 / mc / SDK）        浏览器
  ↓ HTTP :9900（dev）/ :9000（prod）            ↓ HTTP :4000
Maxio.S3.Endpoint（Bandit，不挂 Plug.Parsers）  MaxioWeb.Endpoint（Console LiveView）
  ↓ plugs：SigV4 鉴权 → 授权
Maxio.S3.Dispatcher（判定表：level × method × query keys）  ← /minio/admin/* 走 Maxio.Admin.Plug
  ↓ handlers（normalize 为 Maxio.S3.Request / Response 契约）
编排：objects / multipart / versioning / object_mutation …
  ↓ behaviour
存储后端（FS / 纠删码 / 分布式）     元数据（Postgres / sidecar）     IAM / 策略后端
```

## 常用命令

本机为 Windows 11 原生开发。**跑任何 mix 命令前必须设置** `ERL_FLAGS="-kernel standard_io_encoding unicode"`，
否则编译期中文输出重定向到非 TTY 会触发 `io.put_chars badarg` 硬崩并留下 `erl_crash.dump`。

```bash
# Git Bash
export ERL_FLAGS="-kernel standard_io_encoding unicode"
mix deps.get
mix compile --warnings-as-errors
mix format --check-formatted
mix test test/maxio/admin/                 # 聚焦测试（开发中首选）
mix test --include distributed             # 含 :peer 真节点集成测试（默认排除）
mix precommit                              # 批次收口：compile --warnings-as-errors → deps.unlock --unused → format → test
mix maxio.sigv4.debug ...                  # 签名不匹配取证：打印 canonical request / string-to-sign / 各级 HMAC
iex -S mix phx.server                      # 启动 Console :4000 与 S3 :9900
```

```powershell
# PowerShell
$env:ERL_FLAGS = "-kernel standard_io_encoding unicode"
```

- `mix test` alias 会先 `ecto.create --quiet` + `ecto.migrate --quiet`。
- `mix precommit` 里是 `format`（会改写文件），不是 `--check-formatted`。
- 测试库：`maxio_test<MIX_TEST_PARTITION>`，端口读 `PGPORT`（默认 5432），user/pass = postgres/postgres。
- 默认排除 `:distributed`（`test/test_helper.exs`）。

## 本机工具链与环境（Windows 11）

- **PostgreSQL**：约定容器 `maxio-db`（postgres:16，5432，user/pass=postgres/postgres，dev 库 `maxio_dev`）。
  容器丢失时重建：`docker run -d --name maxio-db -e POSTGRES_PASSWORD=postgres -p 5432:5432 postgres:16`；平时 `docker start maxio-db`。
  `psql` 不在 PATH，用 `docker exec maxio-db psql -U postgres -d maxio_dev -c "..."`。5432 被别的项目占用时用 `PGPORT` 指向其它端口，不要动别人的容器。
- **S3 端口**：Windows 把 TCP 9000–9099 列入 OS 保留排除段（`netsh int ipv4 show excludedportrange tcp`），绑定 9000 报 `:eacces`；
  dev 用 **9900**，prod 默认 9000，可经 `MAXIO_S3_PORT` 覆盖；需要容器内客户端直连时用 `MAXIO_S3_IP=0.0.0.0`。
- **UDP**：dev 的 libcluster Gossip 使用 UDP 多播（端口 45892）。本机远程连接依赖 UDP 资源，多节点演练必须限定节点数与时长并在结束后关闭全部节点（见 AGENTS.md §3 资源安全）。
- **ColocatedJS 符号链接**：Windows 非管理员下建 node_modules 符号链接失败（`:eperm`），已在 `config/config.exs` 关闭该警告。
- **PowerShell 5.1 丢失真实 exit code**：完整 `mix precommit` 输出带 native stderr 时，PowerShell 捕获可能提前终止、`$LASTEXITCODE` 不可信。
  可靠做法：前台同步 `cmd.exe /d /s /c "call mix.bat precommit > log 2>&1"`，返回后立即记录 exit code，并用完整 log 中唯一的 ExUnit 摘要交叉验证。
- **外部客户端**：aws-cli、boto3 可用；`mc` 按需从钉版源码构建（S5/S6/S7 证据见各自 fixture README），不要把构建出的二进制提交进仓库。
  aws-cli 2.35 对 http 端点默认不使用 aws-chunked，aws-chunked 活体覆盖由 `mc` 提供。

## 代码组织约定

- **OTP**：GenServer 回调标 `@impl true`；测试里用 `start_supervised!/1` 启进程。
- **命名**：模块 `Maxio.<子系统>.<类型>`，文件 `snake_case.ex`；CLI 任务 `mix maxio.<子系统>.<动作>`。
- **日志**：`require Logger`，警告用 `Logger.warning/2`；字段与脱敏要求见 AGENTS.md §3 第 1 条。
- **注释**：中文，写“为什么”，不写阶段代号（见 AGENTS.md §3）。
- **迁移**：表 / 列 / 索引 / 类型必须有中文 `COMMENT`（见 AGENTS.md §3）。

## Rust 原生扩展

| 位置 | 用途 |
|---|---|
| `native/maxio_native`（`Maxio.Native` 加载） | Reed-Solomon encode / reconstruct（纠删码）、BLAKE3（bitrot 检测）、Windows reparse point 检测（路径安全） |

## 已固化的关键决策

见 STATUS.md「已固化的关键决策」节与各 spec；本文件不复述，避免出现第二份真值。
