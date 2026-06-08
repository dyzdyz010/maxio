# CLAUDE.md — maxio（Elixir/Phoenix S3 兼容对象存储）

> **AGENTS.md 是工程准则单一来源，先读它。** 本文件只补充 Claude Code / OMC 专属的执行细节。
> 设计 spec：`docs/superpowers/specs/`；当前状态：`docs/superpowers/STATUS.md`。

## 对话语言
与用户对话默认使用**简体中文**。代码、标识符、技术术语保持原文。

## 职责 subagent 级隔离 —— OMC 角色映射（强制）

AGENTS.md §4.1 要求职责永远 subagent 级隔离、严禁一个 agent 同时做多项。在 Claude Code / OMC 下具体映射为：

| 职责 | 委派给 | 模型建议 |
|---|---|---|
| 设计 / 架构 | `architect`、`planner` | opus |
| 研究 / 查资料（S3 API / SigV4 / SDK 测试向量）/ 探索代码 | `document-specialist`、`explore`、`general-purpose` | sonnet/haiku |
| 开发 / 实现 | `executor` | 复杂任务 opus，常规 sonnet |
| 测试 / 审查 / 验证 | `code-reviewer`、`verifier` | opus（安全/大改） |

铁律：
- **实现者绝不自审**。写代码的 `executor` 与审查的 `code-reviewer`/`verifier` 必须是不同 subagent、不同上下文。
- 主线程（orchestrator）负责编排与集成，**不亲自承担上述任一专职职责**（规划/设计类文档与 `CLAUDE.md`/`AGENTS.md`/spec/STATUS 的直接编写除外）。
- 多个独立任务并行委派；但**涉及 mix 编译的实现任务串行执行**（避免并行编译竞争锁文件）。

## 禁止打补丁式修复（强制）

遇到 bug/失败，先委派系统化调试定位**根因**，修复方案必须从整体架构出发、说明如何契合 AGENTS.md §3 架构铁律；禁止局部 hack / 绕过 / 临时补丁掩盖问题。S3 兼容性问题（签名不匹配、XML 不被 SDK 接受）尤其要对照官方文档/测试向量定位，不靠猜。

## 勤查资料 + 最佳实践（强制）

不确定的 S3 API / SigV4 规范 / Bandit 流式 body / Plug / saxy / Ecto → 先经 `document-specialist` 查官方文档（AWS S3 API Reference、SigV4 文档、AWS SDK 官方测试向量优先；其次 Context Hub / `chub`，再 web 兜底）再实现。

## CLI + 日志优先（后端，强制）

实现任何后端功能时同步提供 CLI（Mix 任务 / IEx 辅助）与结构化日志，保证无 GUI 可完整调试。典型如 `mix maxio.sigv4.debug`（给定请求材料打印 canonical request / string-to-sign / 各级 HMAC / 最终签名，定位"签名不匹配"）。验证完成时优先用 CLI/日志/aws-cli 取证。

## S3 端到端验证（强制）

声明 S3 操作"可用"前，优先用 **aws-cli**（`aws s3 ... --endpoint-url http://localhost:9000`）或 boto3 / 自签 SigV4 的 ExUnit 集成测试做**端到端活体取证**：真实客户端能创建桶、Put/Get/List/Delete 对象、签名通过、XML 被正确解析。注意 aws-cli 默认对上传用 `STREAMING-AWS4-HMAC-SHA256`（aws-chunked）——这是 §3.4 头号兼容风险，验证时须覆盖。

## 浏览器端可调试（Console LiveView，强制）

管理控制台（M5）用 **Claude-in-Chrome 浏览器自动化工具**调试与验证：`navigate` / `read_console_messages`（带 pattern 过滤）/ `read_network_requests` / `javascript_tool` / 截图。前端输出带标签结构化 console 日志（如 `[maxio][Console]`）。

## 验证才算完成

声明"完成/修复/通过"前，必须由独立 `verifier`/`code-reviewer` 跑验证命令（`mix compile --warnings-as-errors`、`mix test`、aws-cli e2e）并收集证据；失败则继续迭代。

## 本机工具链速记（Windows，详见 STATUS.md）

- Elixir 1.20 / OTP 28 在 `C:\Users\dyz\Documents\dev\usr\Elixir\bin`；mix/phx_new/hex 已装；docker/git 可用；psql 不在 PATH（用 `docker exec maxio-db psql ...`）。
- Postgres：容器 `maxio-db`（postgres:16，5432，user/pass=postgres/postgres，db=maxio_dev）。`docker start maxio-db` 恢复。
- **跑 mix 命令前必设** `$env:ERL_FLAGS="-kernel standard_io_encoding unicode"`（否则编译期中文输出重定向到非 TTY 会触发 `io.put_chars badarg` 硬崩）。
- 已在 config.exs 关 LiveView ColocatedJS 符号链接警告（Windows 非管理员 :eperm）。
