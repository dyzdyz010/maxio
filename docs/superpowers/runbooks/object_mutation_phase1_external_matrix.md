# ObjectMutation Phase 1 External Client Matrix Runbook（aws-cli / mc / boto3）

> 目标：在 heal、rebalance、scanner destructive cleanup **未并发运行**的隔离环境中，
> 用真实外部客户端（aws-cli、MinIO mc、python-boto3）对 Maxio 执行
> Put/Head/Get/List 顺序矩阵，产出可审计 JSON artifact，并做到零残留。
> 对应协议验收：`docs/superpowers/plans/2026-07-10-object-mutation-protocol.md` §Phase 1 验收。
>
> 本 runbook 不包含任何真实凭据。所有 `<ACCESS_KEY>` / `<SECRET_KEY>` 为占位符。

## 1. 适用范围与工具

- 服务端：本仓库 dev profile（`MIX_ENV=dev`），S3 endpoint `http://127.0.0.1:9900`
  （`config/dev.exs` 中 `Maxio.S3.Endpoint, port: 9900`；可经 `MAXIO_S3_PORT` 覆盖）。
- 客户端：aws-cli v2（参考版本 2.35.20）、MinIO mc（参考 RELEASE.2025-08-13）、
  python3 + boto3（参考 1.43.45）。
- 依赖：Postgres（本机容器 `maxio-db`，`localhost:5432`）。
- harness：`mix maxio.compat.matrix`（`lib/maxio/compat/matrix.ex` +
  `lib/maxio/compat/external_smoke.ex`），外部 smoke 为显式 opt-in，不会自行启动 Maxio。

Windows/PowerShell 纪律（每个跑 mix 的 shell 都要执行）：

```powershell
$env:ERL_FLAGS = "-kernel standard_io_encoding unicode"
Remove-Item Env:PGPORT -ErrorAction SilentlyContinue
```

## 2. 隔离环境前置条件（强制）

Phase 1 external matrix 必须在 heal / rebalance / scanner destructive cleanup
未并发运行的环境执行。Maxio 的这些组件默认全部 **disabled（启动但不调度）**，
因此隔离保证 = 「不要显式开启它们」+ 「用启动日志取证」。

1. 确认没有任何 config/env 打开以下开关（dev 默认均关闭）：

   ```elixir
   config :maxio, :fresh_drive_heal_scheduler, enabled: true   # 必须不存在
   config :maxio, :rebalance_scheduler, enabled: true          # 必须不存在
   config :maxio, :scanner, enabled: true                      # 必须不存在
   config :maxio, :scrubber, ...                               # 必须不存在
   config :maxio, :lifecycle_scheduler, enabled: true          # 必须不存在
   ```

2. 服务器启动后，在 stdout 日志中必须能看到以下证据行（缺一即中止）：

   ```text
   [info] fresh-drive heal scheduler disabled
   [info] rebalance scheduler disabled
   [info] scanner disabled: periodic derived-index reconcile NOT scheduled ...
   [info] scrubber disabled: periodic usage/auto-heal scan NOT scheduled
   [info] lifecycle scheduler disabled: periodic sweeps NOT scheduled ...
   ```

   注意：`object mutation recovery scheduler enabled` 是 Phase 1 协议自身的
   correctness 组件（journal 驱动的 crash 收敛），**属预期**，不违反隔离要求。

3. 矩阵运行期间不要手动触发 `mix maxio.heal.* / maxio.rebalance.* / maxio.scrub.*`
   等任何 destructive CLI。

## 3. 启动隔离服务器

```powershell
$env:ERL_FLAGS = "-kernel standard_io_encoding unicode"
Remove-Item Env:PGPORT -ErrorAction SilentlyContinue
docker start maxio-db   # 如未运行
Set-Location D:\dev\maxio
mix compile             # 先编译，避免 server 与矩阵任务竞争 build lock

# 后台启动并把日志留作隔离证据（命名沿用 artifacts/external_smoke_*_server.*.log 惯例）
Start-Process -FilePath "C:\Program Files\Elixir\bin\mix.bat" -ArgumentList "phx.server" `
  -WorkingDirectory "D:\dev\maxio" `
  -RedirectStandardOutput "D:\dev\maxio\artifacts\external_smoke_<RUN_TAG>_server.stdout.log" `
  -RedirectStandardError  "D:\dev\maxio\artifacts\external_smoke_<RUN_TAG>_server.stderr.log" `
  -NoNewWindow -PassThru   # 记下 PID，收口时 taskkill /T
```

就绪判定：stdout 日志出现
`Running Maxio.S3.Endpoint with Bandit ... at 127.0.0.1:9900`，
且 §2 的 disabled 证据行齐全。

凭据：dev 默认 root 凭据来自 `config :maxio, :s3, root_user/root_password`
（可经 `MAXIO_ROOT_USER` / `MAXIO_ROOT_PASSWORD` 覆盖）。服务器启动时 IAM bootstrap
会写入该 access key。下文以 `<ACCESS_KEY>` / `<SECRET_KEY>` 指代。

## 4. 运行 harness 矩阵（主 artifact）

```powershell
$env:ERL_FLAGS = "-kernel standard_io_encoding unicode"
Remove-Item Env:PGPORT -ErrorAction SilentlyContinue
Set-Location D:\dev\maxio
mix maxio.compat.matrix --include-external-smoke --no-internal-suites `
  --fail-on-blocked --fail-on-attention `
  --external-smoke-client aws_cli --external-smoke-client minio_mc --external-smoke-client python_boto3 `
  --external-endpoint http://127.0.0.1:9900 `
  --external-access-key <ACCESS_KEY> --external-secret-key <SECRET_KEY> `
  --external-region us-east-1 `
  --artifact artifacts/s3_compat_matrix_external_<RUN_TAG>.json
```

- 凭据也可改用 env：`MAXIO_COMPAT_ACCESS_KEY` / `MAXIO_COMPAT_SECRET_KEY` /
  `MAXIO_COMPAT_ENDPOINT` / `MAXIO_COMPAT_REGION`（见 `Maxio.Compat.Matrix.external_smoke_config/2`）。
- harness 自动将凭据在 artifact 与输出中替换为 `[REDACTED]`。
- 通过标准：exit code 0 且 artifact `gate_status == "ok"`、`counts.ok == counts.total`。

harness 每客户端步骤矩阵（全部必须 `ok`）：

| 客户端 | 步骤 |
|---|---|
| aws_cli（12 步） | create_bucket → head_bucket → put_object → head_object → get_object → get_object_range → copy_object → head_copied_object → get_copied_object → delete_copied_object → delete_object → delete_bucket |
| minio_mc（10 步） | make_bucket → put_object(cp) → stat_object → get_object(cat) → copy_object → stat_copied_object → get_copied_object → delete_copied_object(rm) → delete_object(rm) → delete_bucket(rb) |
| python_boto3（1 步 deep matrix） | create_bucket / put_object(带 metadata) / head_object(含 Range head) / get_object(全量+Range) / copy_object / 校验 body 与 metadata / delete_object / delete_bucket |

隔离细节（harness 内建，无需手工）：

- 每客户端使用独立随机桶名 `maxio-compat-<client>-<n>` 与独立 temp 目录
  `%TEMP%\maxio_compat_smoke_<client>_<n>`，运行后 `rm_rf` 整个 temp 目录。
- mc 使用 `--config-dir <temp>\mc-config` + `MC_HOST_maxiocompat` 环境变量传递
  endpoint/凭据（形如 `http://<ACCESS_KEY>:<SECRET_KEY>@127.0.0.1:9900`），
  **不会创建/污染 `~/mc`**，凭据不落盘。
- 失败时自动执行 cleanup steps（delete object/bucket），不留桶。

## 5. 显式 Put/Head/Get/List 顺序矩阵（补充 artifact）

harness 步骤不含显式 List；验收要求的 Put→Head→Get→List 顺序按下表逐客户端执行，
结果写入 `artifacts/s3_compat_matrix_external_<RUN_TAG>_list_supplement.json`
（每步记录 command/exit_status/status/evidence，凭据一律占位或删除）。
桶名惯例 `maxio-phase1-<client>-<RUN_TAG>`。

aws-cli（`AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY`/`AWS_DEFAULT_REGION` 经 env 传入，
另设 `AWS_EC2_METADATA_DISABLED=true`、`AWS_PAGER=""`、`NO_PROXY=127.0.0.1,localhost`）：

```text
aws --endpoint-url http://127.0.0.1:9900 --region us-east-1 s3api create-bucket --bucket <BUCKET>
aws --endpoint-url http://127.0.0.1:9900 --region us-east-1 s3 cp <payload> s3://<BUCKET>/<KEY> --debug   # Put（--debug 取签名模式证据）
aws --endpoint-url http://127.0.0.1:9900 --region us-east-1 s3api head-object --bucket <BUCKET> --key <KEY>        # Head：校验 ContentLength
aws --endpoint-url http://127.0.0.1:9900 --region us-east-1 s3api get-object --bucket <BUCKET> --key <KEY> <dst>   # Get：逐字节比对
aws --endpoint-url http://127.0.0.1:9900 --region us-east-1 s3api list-objects-v2 --bucket <BUCKET>                # List：断言 Contents[].Key 含 <KEY>
aws --endpoint-url http://127.0.0.1:9900 --region us-east-1 s3api delete-object --bucket <BUCKET> --key <KEY>
aws --endpoint-url http://127.0.0.1:9900 --region us-east-1 s3api delete-bucket --bucket <BUCKET>
```

mc（临时 config：`mc --config-dir <TMP>\mc-config`；凭据仅经
`MC_HOST_<alias>=http://<ACCESS_KEY>:<SECRET_KEY>@127.0.0.1:9900` env 传入，零落盘；
跑完 `Remove-Item -Recurse -Force <TMP>\mc-config`）：

```text
mc --config-dir <TMP>\mc-config mb <alias>/<BUCKET>
mc --config-dir <TMP>\mc-config --debug cp <payload> <alias>/<BUCKET>/<KEY>   # Put（--debug 取 STREAMING 签名证据）
mc --config-dir <TMP>\mc-config stat <alias>/<BUCKET>/<KEY>                    # Head 等价
mc --config-dir <TMP>\mc-config cat <alias>/<BUCKET>/<KEY>                     # Get：比对 payload
mc --config-dir <TMP>\mc-config ls <alias>/<BUCKET>                            # List：断言输出含 <KEY>
mc --config-dir <TMP>\mc-config rm <alias>/<BUCKET>/<KEY>
mc --config-dir <TMP>\mc-config rb <alias>/<BUCKET>
```

boto3（`boto3.client("s3", endpoint_url="http://127.0.0.1:9900", region_name="us-east-1",
aws_access_key_id=..., aws_secret_access_key=...)`）：

```text
create_bucket → put_object → head_object(断言 ContentLength) → get_object(断言 body)
→ list_objects_v2(断言 Contents 含 key) → delete_object → delete_bucket
```

失败路径必须 best-effort 清理（aws：`s3 rm --recursive` + `delete-bucket`；
mc：`rb --force`；boto3：try/finally delete），确保 blocked 也不留桶。

### aws-chunked（STREAMING-AWS4-HMAC-SHA256）覆盖说明

- **mc 是 http 端点上 aws-chunked 签名流式的活体覆盖**：minio-go 对非 TLS 端点默认
  `X-Amz-Content-Sha256: STREAMING-AWS4-HMAC-SHA256-PAYLOAD` +
  `X-Amz-Decoded-Content-Length`。取证：`mc --debug cp` 的 stderr 中 PUT 请求头。
- aws-cli ≥2.23（实测 2.35.20）对 **http** 端点默认改为预计算
  `x-amz-checksum-crc64nvme` + 全量 payload 签名（`x-amz-content-sha256=SHA256(body)`），
  botocore 仅对 **https** 端点选择 aws-chunked trailer 路径。取证：`aws s3 cp --debug`
  的 stderr 中 `x-amz-content-sha256:` 行。两种真实签名模式服务器都必须接受。
- 自签 aws-chunked 向量另有内部套件 `mix maxio.compat.matrix --suite streaming_matrix`。

### zh-CN Windows 编码陷阱

包装脚本用 `subprocess` 捕获 aws/mc 输出时必须显式 `encoding="utf-8", errors="replace"`：
中文 Windows 默认 GBK 解码，`mc --debug` 输出含非 GBK 字节会使 reader 线程崩溃。
PowerShell 5.1 的 `2>` 重定向产物为 UTF-16，供 bash/grep 处理前注意转码。

## 6. 收口检查清单（全部必须为 0 / 通过）

1. 停服：`taskkill /PID <server_pid> /T /F`，确认 9900 端口释放。
2. 桶残留：`aws ... s3api list-buckets` 不含 `maxio-compat-*` / `maxio-phase1-*`。
3. 磁盘残留：`priv\s3_data\dev` 下无本次运行的桶目录。已知既有行为：DeleteBucket
   会在 FS 后端留下**空目录壳**（API 不可见），本次运行产生的空壳须手动删除。
4. temp 残留：`%TEMP%` 无 `maxio_compat_smoke_*`；包装脚本工作目录已删除。
5. mc 全局配置：`~/mc` 与 `~/.mc` 不存在（或未被本次运行创建/修改）。
6. artifact secret 扫描：对两个 JSON artifact 与 server 日志 grep
   `<ACCESS_KEY>` / `<SECRET_KEY>` 明文——JSON 必须 0 命中（harness 输出应为
   `[REDACTED]`）；server stdout 的 SQL debug 行只允许出现 access_key_id 与
   `maxio-ak-secret-v1:` 加密 blob，不得出现明文 secret。
7. gate 判定：主 artifact 与补充 artifact 的 `gate_status` 均为 `"ok"`。

## 7. 失败处置

矩阵任何一步 blocked/error：不弱化断言、不跳步。收集：

- artifact 中该 step 的 `output_snippet` / `detail`；
- server stdout 中对应时间窗的结构化日志（object mutation 路径含 `mutation_id` /
  `phase` 字段，logger formatter 已支持）；
- 必要时 `mix maxio.sigv4.debug` 复算签名链路。

按根因修复后**整批重跑**（新 RUN_TAG、全新桶名），不复用半途状态。
