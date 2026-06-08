# M2 分段上传 + aws-chunked 流式签名 + 条件头 + DeleteObjects 实现计划 · maxio

> For agentic workers（executor）：严格按单元 M2-1..M2-7 顺序执行。逻辑性代码用 **TDD**（先写失败测试 → 运行确认红 → 最小实现 → 运行确认绿 → commit）；脚手架/配置类任务用"执行命令 + 验证输出"。每个任务都给了**精确文件路径、完整可用代码（禁止占位符 / TODO / 省略号）、确切 PowerShell 命令与期望输出**。后面任务引用的类型/函数/字段名与前面定义（及 M1 既有代码）**严格一致**——复用 M1 模块时逐字照抄其现有签名。
>
> **本计划建立在已交付并验证的 M0+M1 之上**（master，125 测试全绿、独立 reviewer APPROVE）。M2 复用 M1 全部既有模块：`Maxio.S3.{Error,XML,ErrorView,Dispatcher,Endpoint,BodyReader,RawPath}`、`Maxio.S3.Plugs.{AddressStyle,SigV4,Dispatch}`、`Maxio.S3.Handlers.{Service,Bucket,Object}` + `Maxio.S3.Handlers`、`Maxio.S3.Views.*`、`Maxio.Auth` + `Maxio.Auth.SigV4.{Canonical,Signer,AuthHeaderParser,SignedRequest}`、`Maxio.Auth.CredentialStore{,.MemoryStore}`、`Maxio.Storage{,.Backend,.FS}`、`Maxio.{Buckets,Objects}`。**严禁重写或破坏这些模块的公开契约**；只允许按本计划做明确的增量扩展。
>
> **铁律对齐（AGENTS.md §3/§4，违反即返工）**：①后端经 behaviour 抽象（存储/凭据），上层只认契约——multipart parts 也走 `Maxio.Storage.Backend` 新增回调，不在 handler 里直接碰文件系统；②禁止打补丁式修复——从架构层解决；③绝不静默失败——逐块签名验证失败、解帧异常、part 校验失败必须返回结构化 S3 错误 XML + 正确 HTTP 状态 + 结构化日志，**绝不静默放行或静默落盘**；流式用**显式状态机**（`StreamingVerifier`）；④对象 body 绝不进 `Plug.Parsers`、绝不全缓冲——UploadPart 字节流式交存储层；只有小 XML（CompleteMultipartUpload / Delete）走带上限整读 + saxy SAX；⑤S3 行为以官方 AWS 文档/SDK 测试向量为准（本计划已内嵌核验过的 AWS 官方 worked-example 向量）；⑥DB schema 自文档化——新表/列/索引中文 `COMMENT`。
>
> **作者/审查隔离**：本计划由 executor 实现；每个单元收尾由**独立** `code-reviewer`/`verifier`（不同上下文）取证，实现者不得自审。

---

## 环境约束（每条 mix 命令都必须遵守）

- **本机**：Windows 11 + PowerShell。Elixir 1.20.0 / OTP 28，位于 `C:\Users\dyz\Documents\dev\usr\Elixir\bin`（已在 PATH）。
- **跑任何 mix 命令前必设**（否则编译期/运行期中文输出重定向到非 TTY 触发 `io.put_chars badarg` 硬崩、留 `erl_crash.dump`）：
  ```powershell
  $env:Path = 'C:\Users\dyz\Documents\dev\usr\Elixir\bin;' + $env:Path
  $env:ERL_FLAGS = "-kernel standard_io_encoding unicode"
  ```
  本计划所有 PowerShell 命令块**默认已假设当前会话已设此两变量**；每个新 shell 会话第一条命令前先执行它。
- **Postgres**：docker 容器 `maxio-db`（postgres:16，localhost:5432，user/pass=postgres/postgres，dev 库 `maxio_dev`，test 库 `maxio_test`）。`psql` 不在 PATH，一律经容器：
  ```powershell
  docker exec maxio-db psql -U postgres -d maxio_dev -c "SELECT 1;"
  ```
  执行前确保容器在跑：`docker start maxio-db`。
- **无 aws-cli / boto3 / mc / python**。端到端验证只用：(a) 内嵌的 AWS 官方 **KNOWN-ANSWER** 流式签名向量（byte-for-byte 证明 `StreamingVerifier` 正确，是独立 ground truth）；(b) **自签 SigV4** 集成测试（用项目自己的 `Maxio.Auth.SigV4.Signer` 自签——对 aws-chunked，本计划扩展 `test/support/sigv4_request.ex`，使其能用**项目自己的 Signer** 生成合法 chunk-signed body，从而"我们签 → 我们验"闭环成立）。**禁止依赖外部 CLI**。
- **提交**：每个任务（或紧密相关的红绿对）一次 commit，message footer 固定一行：
  `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`
  当前分支为 `master`；本计划全部提交到当前分支（无需开新分支，除非用户另行要求）。

---

## Goal

在 M1 垂直切片之上，补齐 **真实 aws-cli / SDK 默认大文件上传链路** 与分段上传：

1. **M1 硬化（小、先做、降风险）**：dev S3 端口移出 Windows 9000–9099 保留段（dev 9900，prod 默认仍 9000）；aws-chunked 帧头非 hex → 显式 `IncompleteBody` 而非静默当 0；`:single` 模式可选校验 `x-amz-content-sha256` vs 实际字节 → `BadDigest`/`XAmzContentSHA256Mismatch`（或显式记录 defer）；`Object.put` 在 `verify_decoded_length!` 抛错时清理孤儿字节；HeadObject 缺失 key 不发 XML body。
2. **aws-chunked 完整逐块签名验证**：`Maxio.Auth.SigV4.StreamingVerifier` 显式状态机（seed sig → 逐块 6 行 string-to-sign 链 → 常数时间比对 → 推进 prev_sig；0 大小终止块）。接入 `Maxio.S3.BodyReader`，坏块**硬停** `SignatureDoesNotMatch`（铁律 3，替换 M1 passthrough）。trailer chunk 签名可做（5 行 STS，便宜）；checksum trailer 重算 defer 到 M3（显式记录）。SigV4A（ECDSA）→ `501 NotImplemented`。
3. **Multipart Upload**：`Maxio.Storage.Backend` 新增 parts 回调 + FS 实现（`put_part`/`get_part_stream`/`list_parts`/`assemble`/`abort_upload`）；`Maxio.Multipart` 上下文 + Ecto 迁移（`multipart_uploads` + `multipart_parts` 表，中文 COMMENT）；handlers（CreateMultipartUpload/UploadPart/CompleteMultipartUpload[XML 入站 SAX 解析]/AbortMultipartUpload/ListParts/ListMultipartUploads）；saxy 出站 views + CompleteMultipartUpload 请求 SAX 解析器；multipart ETag = `hex(MD5(concat part-MD5-bytes))-N`；EntityTooSmall/InvalidPart/InvalidPartOrder/NoSuchUpload 全套错误。接入 `Dispatcher`（这些正是 M1 的 `:not_implemented` 子资源）。
4. **DeleteObjects**（`POST /{bucket}?delete` 批量）+ `<Delete>` 请求 SAX 解析器 + `<DeleteResult>` view。
5. **条件头**（If-Match/If-None-Match/If-Modified-Since/If-Unmodified-Since）于 GET/HEAD/PUT，按 RFC 7232 §6 次序映射 412/304；多区间 Range → 对齐 S3 返回完整 200（不实现 multipart/byteranges）。
6. **CopyObject**（`PUT` 带 `x-amz-copy-source`）—— 列为可选单元 M2-7，若时间不足则按文档化方式 defer 到 M4（STATUS 已把 CopyObject 列在 M4）。本计划给出完整方案，executor 视进度决定是否纳入。

**显式不做（defer，到达即文档化）**：
- aws-chunked **checksum trailer 重算**（CRC32/CRC32C/CRC64NVME/SHA1/SHA256 端到端比对）→ M3。M2 解析并跳过 trailer chunk（保证解帧正确），signed-trailer 变体验证 trailer 签名（便宜），但不重算 checksum 值。
- SigV4A（`STREAMING-AWS4-ECDSA-P256-SHA256-PAYLOAD[-TRAILER]`）→ `501 NotImplemented`（不同算法，非 HMAC）。
- DeleteObjects 的 `<Object>` 条件子字段（ETag/LastModifiedTime/Size 预条件）→ 只认 `Key`/`VersionId`（M1 无 versioning，VersionId 忽略）。
- 完整 IAM/bucket policy → M3；M2 仍 **root principal 全权放行**（沿用 M1 AuthZ stub）。

## Architecture（M2 在 M1 管线上的增量）

```
S3 客户端 → Maxio.S3.Endpoint (Bandit, dev :9900 / prod :9000, 无 Plug.Parsers)
  Plug.RequestId
  Maxio.S3.Plugs.AddressStyle      （M1，不变）
  Maxio.S3.Plugs.SigV4             （M1；本计划把 kSigning 等流式材料经 assigns 透传给 BodyReader）
  Maxio.S3.Plugs.Dispatch          （M1；Dispatcher 表新增 multipart / delete-objects action）
     Handlers.Service/.Bucket/.Object        （M1，扩 Object：条件头 + CopyObject + DeleteObjects）
     Handlers.Multipart  ★新                  （Create/UploadPart/Complete/Abort/ListParts/ListMultipartUploads）
        Maxio.Multipart  ★新（uploads/parts 元数据，Ecto）
        Maxio.Storage.Backend(+parts 回调) → Maxio.Storage.FS(+parts 实现)
     入站小 XML：Maxio.S3.RequestParsers.{CompleteMultipartUpload,Delete}  ★新（saxy SAX，带上限整读）
     出站 XML：Maxio.S3.Views.{InitiateMultipartUpload,CompleteMultipartUpload,ListParts,ListMultipartUploads,DeleteResult,CopyObjectResult}  ★新
  Maxio.S3.BodyReader   （M1；:streaming 分支改为驱动 StreamingVerifier 状态机，逐块验证）
  Maxio.Auth.SigV4.StreamingVerifier  ★新（显式状态机，逐块签名链）
```

现有 `MaxioWeb.Endpoint`（:4000，Console/LiveView）**保持不变**，物理隔离。

## 单元总览（按依赖串行；每单元结束须 green compile + 测试通过 + 一次 commit）

| 单元 | 标题 | 依赖 | 规模/分割理由 |
|---|---|---|---|
| **M2-1** | M1 硬化（端口/解帧/单次校验/孤儿清理/HEAD body） | M1 | 小、降风险、独立可测，先做 |
| **M2-2** | `StreamingVerifier` 状态机（纯逻辑 + AWS KNOWN-ANSWER 向量） | M2-1 | 纯函数/状态机，TDD 重，单独成单元 |
| **M2-3** | `StreamingVerifier` 接入 `BodyReader` + SigV4 透传材料 + 自签 chunked e2e | M2-2 | 管线接线 + 集成测试 |
| **M2-4** | Multipart：存储后端 parts 回调 + FS 实现 + 迁移 + `Maxio.Multipart` 上下文 + ETag | M2-1 | context + 迁移（不含 handler/view），控制单轮规模 |
| **M2-5** | Multipart：入站 SAX 解析器 + 出站 views + Handlers + Dispatcher 接线 + 自签 e2e | M2-4 | handlers + views + 集成 |
| **M2-6** | DeleteObjects + 条件头（If-*）+ 多区间 Range 对齐 | M2-5 | 批删 + 条件语义 |
| **M2-7（可选）** | CopyObject（x-amz-copy-source + metadata-directive + 条件 + 自拷贝守卫） | M2-6 | 可 defer 到 M4 |

**执行顺序**：M2-1 → M2-2 → M2-3 → M2-4 → M2-5 → M2-6 →（可选）M2-7。**串行执行，禁止并行 mix 编译**（避免锁文件竞争）。每单元规模都控制在"单个 executor 一轮内可完成实现 + 跑测试 + 调用 StructuredOutput"。

---

## 全局命名契约（M2 新增，一次定义全程复用；M1 既有契约见 M1 计划）

**沿用 M1 常量**：XML 命名空间 `"http://s3.amazonaws.com/doc/2006-03-01/"`；空 body SHA256 hex `"e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"`；region `"us-east-1"`；service `"s3"`；termination `"aws4_request"`；算法 `"AWS4-HMAC-SHA256"`。

**M2 新增模块与签名（跨单元引用，逐字一致）**：

- `Maxio.Auth.SigV4.StreamingVerifier`（M2-2）：
  - 状态结构 `%StreamingVerifier{}` 字段：`kSigning :: binary, date :: String.t, scope :: String.t, prev_sig :: String.t, decoded_count :: non_neg_integer, expected_decoded_len :: non_neg_integer | nil, flavor :: :signed | :signed_trailer | :unsigned_trailer, trailer_names :: [String.t], buffer :: binary, stage :: :data | :trailer | :done`
  - `init(opts) :: t()` —— opts: `:k_signing, :date, :scope, :seed_signature, :expected_decoded_len, :flavor, :trailer_names`
  - `feed(t(), binary()) :: {:ok, [binary()], t()} | {:error, atom()}` —— 喂入网络字节，产出**已验证的纯净 data 块列表** + 新状态；`:error` 原因 ∈ `:signature_does_not_match | :incomplete_body | :invalid_chunk`
  - `finalize(t()) :: :ok | {:error, atom()}` —— 校验已达终止块 + decoded 长度一致
  - `chunk_string_to_sign(date, scope, prev_sig, data_hash_hex) :: String.t()`（6 行，无尾换行；纯函数，测试直接调）
  - `trailer_string_to_sign(date, scope, prev_sig, trailer_block_hash_hex) :: String.t()`（5 行）
- `Maxio.Storage.Backend`（M2-4，**新增回调**，追加在 M1 回调之后）：
  - `@callback put_part(bucket, key, upload_id :: String.t(), part_number :: pos_integer(), chunks :: Enumerable.t(), opts :: keyword()) :: {:ok, %{size: non_neg_integer(), etag: String.t(), md5_raw: binary()}} | {:error, term()}`
  - `@callback get_part_stream(bucket, key, upload_id :: String.t(), part_number :: pos_integer(), opts :: keyword()) :: {:ok, Enumerable.t()} | {:error, :enoent | term()}`
  - `@callback assemble(bucket, key, upload_id :: String.t(), part_numbers :: [pos_integer()], opts :: keyword()) :: {:ok, %{size: non_neg_integer()}} | {:error, term()}`
  - `@callback abort_upload(bucket, key, upload_id :: String.t(), opts :: keyword()) :: :ok | {:error, term()}`
  - 注：`md5_raw` 是该 part 的 **16 字节原始 MD5 digest**（用于 multipart ETag 计算，避免再读盘）。
- `Maxio.Multipart`（M2-4）上下文函数：
  - `initiate(bucket :: String.t, key :: String.t, attrs :: map()) :: {:ok, %Upload{}} | {:error, term()}`（生成 upload_id）
  - `get_upload(bucket, key, upload_id) :: {:ok, %Upload{}} | {:error, :not_found}`
  - `put_part(upload :: %Upload{}, part_number, %{etag, size}) :: {:ok, %Part{}}`（upsert 元数据）
  - `list_parts(upload, opts) :: %{parts: [...], is_truncated: boolean, next_part_number_marker: ...}`
  - `list_uploads(bucket, opts) :: %{uploads: [...], common_prefixes: [...], is_truncated, next_key_marker, next_upload_id_marker}`
  - `complete(upload, requested_parts :: [%{part_number, etag}]) :: {:ok, %{etag, size}} | {:error, atom()}`
  - `abort(upload) :: :ok`
  - `multipart_etag(part_md5_raws :: [binary()]) :: String.t()`（= `hex(MD5(concat raws))-N`，无引号）
- `%Maxio.Multipart.Upload{}`（M2-4）：schema 字段 `id, bucket_name, key, upload_id, initiated_at, storage_class, content_type, owner, metadata`。
- `%Maxio.Multipart.Part{}`（M2-4）：schema 字段 `id, upload_id（FK）, part_number, etag, size, last_modified`。
- `Maxio.S3.RequestParsers.CompleteMultipartUpload`（M2-5）：`parse(xml :: binary()) :: {:ok, [%{part_number: pos_integer(), etag: String.t()}]} | {:error, :malformed_xml}`
- `Maxio.S3.RequestParsers.Delete`（M2-6）：`parse(xml :: binary()) :: {:ok, %{quiet: boolean(), objects: [%{key: String.t(), version_id: String.t() | nil}]}} | {:error, :malformed_xml}`
- `Maxio.S3.Handlers.Multipart`（M2-5）：`create_multipart_upload/1, upload_part/1, complete_multipart_upload/1, abort_multipart_upload/1, list_parts/1, list_multipart_uploads/1`。
- 出站 views（M2-5/6/7）：`Maxio.S3.Views.{InitiateMultipartUpload,CompleteMultipartUpload,ListParts,ListMultipartUploads,DeleteResult,CopyObjectResult}`，各 `render(map()) :: iodata()`，复用 `Maxio.S3.XML.{encode/1,namespace/0,iso8601/1,quote_etag/1}`。

**owner/initiator 占位**（M2 无完整 IAM，固定值，对齐 root principal）：
- ID：`"maxio"`；DisplayName：`"maxio"`。（M3 接 IAM 后替换为真实 principal。）

---

## 单元 M2-1 — M1 硬化（端口 / 解帧非 hex / 单次校验 / 孤儿清理 / HEAD body）

**目标**：清掉 M1 reviewer 列出的 5 个非阻塞项 + Windows 端口阻塞，使 dev server 可真实绑定、aws-chunked 解帧不静默截断、`:single` 模式可选校验 body 哈希、PUT 失败不留孤儿字节、HeadObject 缺失 key 不发 body。小步、独立可测，先做以降风险。

### Task M2-1.1 — dev S3 端口移出 Windows 9000–9099 保留段

**Files:** Modify `config/dev.exs`、`config/config.exs`（注释说明）

Windows 把 TCP 9000–9099 列入 OS 保留排除段（`netsh int ipv4 show excludedportrange tcp` 实证），监督树绑定 9000 报 `:eacces`。dev 改 9900；prod/编译期默认仍 9000（对齐 MinIO 习惯），runtime 经 `MAXIO_S3_PORT` 可覆盖（M1 已实现）。

`config/dev.exs` 末尾把端口行从 `port: 9000` 改为 `port: 9900`：
```elixir
# maxio S3：开发期对象数据目录与监听端口
# 注：Windows 本机把 TCP 9000–9099 列入 OS 保留排除段（netsh int ipv4 show excludedportrange tcp），
# 绑定 9000 报 :eacces。dev 用 9900 规避；prod 默认仍 9000（见 config.exs），可经 MAXIO_S3_PORT 覆盖。
config :maxio, :s3,
  data_dir: Path.expand("../priv/s3_data/dev", __DIR__)

config :maxio, Maxio.S3.Endpoint, port: 9900, ip: {127, 0, 0, 1}
```

`config/config.exs` 的 S3 Endpoint 行保留 9000，但补一行注释（无需改值）：
```elixir
# 独立 S3 Endpoint（Bandit child）监听配置。
# prod/默认 9000（对齐 MinIO）；dev 因 Windows 9000–9099 保留段改用 9900（见 dev.exs）；
# 可经 MAXIO_S3_PORT 运行时覆盖（runtime.exs）。
config :maxio, Maxio.S3.Endpoint, port: 9000, ip: :any
```

**验证**：
```powershell
mix compile
mix run -e "IO.inspect(Application.get_env(:maxio, Maxio.S3.Endpoint) |> Keyword.fetch!(:port))"
```
期望：编译成功；dev 环境（默认）端口输出 `9900`。

**Commit**：
```powershell
git add -A
git commit -m "fix(s3): move dev S3 port to 9900 (Windows 9000-9099 reserved range)" -m "Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

### Task M2-1.2 — HeadObject 缺失 key 不发 XML body（失败测试 → 修复）

**Files:** Modify `test/maxio/s3/integration_test.exs`（加用例）、`lib/maxio/s3/handlers/object.ex`

M1 中 `object_or_raise/2` 对缺失 key `raise Error.new(:no_such_key, ...)`，Dispatch 的 rescue 用 `ErrorView.render` 产出 XML body 并 `send_resp(404, body)`；对 HEAD 请求 HTTP 层会剥 body，但与 head_bucket 特例（直接 `send_resp(404, "")`）不一致，且依赖下游剥离不优雅。统一：HeadObject 缺失 key 直接状态 + 头，无 body。

先在 `test/maxio/s3/integration_test.exs` 末尾（`end` 之前）加用例：
```elixir
  test "HeadObject 缺失 key → 404 且响应体为空（HEAD 无 body）" do
    SigV4Request.signed_conn(:put, "/headmiss") |> call()
    head = SigV4Request.signed_conn(:head, "/headmiss/nope") |> call()
    assert head.status == 404
    assert head.resp_body == ""
  end

  test "HeadObject 缺失桶 → 404 且响应体为空" do
    head = SigV4Request.signed_conn(:head, "/no-such-bucket-head/x") |> call()
    assert head.status == 404
    assert head.resp_body == ""
  end
```

1. 跑确认红：
   ```powershell
   mix test test/maxio/s3/integration_test.exs
   ```
   期望：上面两个新用例失败（resp_body 含 `<Error>` XML 而非空）。

修复 `lib/maxio/s3/handlers/object.ex` 的 `head/1`：缺失桶/key 时直接发空体 404，不走 raise→ErrorView。把 `head/1` 改为：
```elixir
  @spec head(Plug.Conn.t()) :: Plug.Conn.t()
  def head(conn) do
    bucket = conn.assigns.s3_bucket
    key = conn.assigns.s3_key

    with {:ok, _b} <- Buckets.lookup(bucket),
         {:ok, object} <- Objects.get_metadata(bucket, key) do
      conn
      |> put_common_object_headers(object, object.size)
      |> send_resp(200, "")
    else
      {:error, :not_found} ->
        # HEAD 无 body：缺失桶/对象只回状态 + 头，绝不发 XML body（与 head_bucket 一致）。
        Log.info("head object miss", action: :head_object, bucket: bucket, key: key)
        send_resp(conn, 404, "")
    end
  end
```
> 说明：`Buckets.lookup/1` 与 `Objects.get_metadata/2` 都返回 `{:error, :not_found}`，可共用一个 else 分支。`object_or_raise/2` 仍由 `get/1` 使用（GET 缺失 key 仍回 `<Error>` NoSuchKey body，符合 S3——只有 HEAD 无 body）。

2. 跑确认绿：
   ```powershell
   mix test test/maxio/s3/integration_test.exs
   ```
   期望：全绿（含两个新 HEAD 用例）。

**Commit**：
```powershell
git add -A
git commit -m "fix(s3): HeadObject missing bucket/key returns status-only (no XML body)" -m "Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

### Task M2-1.3 — aws-chunked 帧头非 hex → 显式 IncompleteBody（不静默当 0）

**Files:** Create `test/maxio/s3/body_reader_test.exs`、Modify `lib/maxio/s3/body_reader.ex`

M1 `chunk_size/1` 对非 hex 帧头 `rescue _ -> 0`，会被 `parse_chunk` 当成 terminator → 无 `x-amz-decoded-content-length` 时静默截断成"完整"对象（轻微违铁律 3）。本任务把"无法解析的帧头"显式判别：区分**真正的 0 大小终止块**（帧头数值就是 `"0"`，可能带 chunk-signature/扩展）与**非 hex 垃圾帧头**（→ raise `Maxio.S3.Error` IncompleteBody）。

> 注意：M2-3 会用 `StreamingVerifier` 全面替换 `:streaming` 解帧路径。本任务是 M2-3 前的"先治本止血"——即便如此也要把"非 hex 帧头静默当 0"修掉（reviewer note 1），并为 `:streaming` 路径留正确的硬失败语义。M2-3 接入 verifier 后，本任务的 deframe 状态机仍作为 `:streaming` 的字节解析层被复用（verifier 负责签名，deframe 负责切帧），故此处把帧头解析做对是必要前置。

先写失败测试 `test/maxio/s3/body_reader_test.exs`。BodyReader 当前只接受 `Plug.Conn`，为单测可控，本任务暴露一个纯函数 `parse_chunk_header/1` 供测试（不改公开 `stream/2` 语义）。测试：
```elixir
defmodule Maxio.S3.BodyReaderTest do
  use ExUnit.Case, async: true

  alias Maxio.S3.BodyReader

  describe "parse_chunk_header/1（aws-chunked 帧头解析，区分 0 终止块 vs 非 hex 垃圾）" do
    test "合法 hex 帧头返回 {:ok, size}" do
      assert {:ok, 65_536} = BodyReader.parse_chunk_header("10000;chunk-signature=abc")
      assert {:ok, 1024} = BodyReader.parse_chunk_header("400;chunk-signature=def")
      assert {:ok, 10} = BodyReader.parse_chunk_header("a")
    end

    test "0 大小终止帧头返回 {:ok, 0}" do
      assert {:ok, 0} = BodyReader.parse_chunk_header("0;chunk-signature=ffff")
      assert {:ok, 0} = BodyReader.parse_chunk_header("0")
    end

    test "非 hex 垃圾帧头返回 :error（不再静默当 0）" do
      assert :error = BodyReader.parse_chunk_header("xyz;chunk-signature=abc")
      assert :error = BodyReader.parse_chunk_header("")
      assert :error = BodyReader.parse_chunk_header("  ;chunk-signature=abc")
    end
  end
end
```

1. 跑确认红（函数未定义）：
   ```powershell
   mix test test/maxio/s3/body_reader_test.exs
   ```

修改 `lib/maxio/s3/body_reader.ex`：把 `chunk_size/1` 替换为可区分错误的 `parse_chunk_header/1`，并让 `parse_chunk` 在帧头非法时 raise `Error`：
```elixir
defmodule Maxio.S3.BodyReader do
  @moduledoc """
  把 Plug.Conn 的请求 body 包成产出**纯净对象字节块**的 Stream（绝不全缓冲，铁律 4）。

  - :single / :unsigned —— 直接逐块产出 read_body 的 chunk。
  - :streaming（aws-chunked）—— 边读边解帧，剥去每个 chunk 的
    `<hexsize>;chunk-signature=<sig>\\r\\n` 头与尾随 \\r\\n，输出纯净 data；遇 size=0 终止块停止。
    M2-3 起逐块签名链由 Maxio.Auth.SigV4.StreamingVerifier 验证（接入见 M2-3）。

  解帧帧头解析见 parse_chunk_header/1：区分真正的 0 终止块（帧头数值 "0"）与
  非 hex 垃圾帧头（→ IncompleteBody，绝不静默当 0，铁律 3）。

  返回逐块产出纯净对象字节的 Stream；调用方 Enum 消费（如交 Storage.put/4）。
  注意：因 read_body 会推进 conn，stream 内部持有并推进 conn——消费必须在同一进程内一次性完成。
  """
  alias Maxio.S3.{Error, Log}

  @read_opts [length: 1_048_576, read_length: 1_048_576, read_timeout: 30_000]

  @doc "返回逐块产出纯净对象字节的 Stream.resource。"
  @spec stream(Plug.Conn.t(), :single | :unsigned | :streaming) :: Enumerable.t()
  def stream(conn, :streaming) do
    # 铁律 3：M2-3 起逐块签名验证由 StreamingVerifier 完成；本路径在 verifier 接入前
    # 仅做解帧（非 hex 帧头硬失败，不静默截断）。
    Log.warn("aws-chunked de-frame (per-chunk sig verify wired in M2-3)",
      payload_mode: :streaming,
      reason: :m2_3_streaming_verify_pending
    )

    Stream.resource(
      fn -> {conn, ""} end,
      &deframe_step/1,
      fn _acc -> :ok end
    )
  end

  def stream(conn, _mode) do
    Stream.resource(
      fn -> conn end,
      fn
        :done ->
          {:halt, :done}

        c ->
          case Plug.Conn.read_body(c, @read_opts) do
            {:ok, chunk, _c2} -> {[chunk], :done}
            {:more, chunk, c2} -> {[chunk], c2}
            {:error, _} -> {:halt, :done}
          end
      end,
      fn _ -> :ok end
    )
  end

  # ── aws-chunked 解帧状态机 ──
  defp deframe_step(:done), do: {:halt, :done}

  defp deframe_step({conn, buffer}) do
    case parse_chunk(buffer) do
      {:chunk, data, rest} ->
        {[data], {conn, rest}}

      :terminator ->
        {:halt, :done}

      :need_more ->
        case Plug.Conn.read_body(conn, @read_opts) do
          {:ok, "", _conn2} -> {:halt, :done}
          {:ok, more, conn2} -> deframe_step({conn2, buffer <> more})
          {:more, more, conn2} -> deframe_step({conn2, buffer <> more})
          {:error, _} -> {:halt, :done}
        end
    end
  end

  # 解析一个 chunk 帧。返回 {:chunk, data, rest} | :terminator | :need_more。
  # 帧头非法（非 hex、空）→ raise IncompleteBody（铁律 3，不静默当 0）。
  defp parse_chunk(buffer) do
    case :binary.split(buffer, "\r\n") do
      [header, after_header] ->
        case parse_chunk_header(header) do
          {:ok, 0} ->
            :terminator

          {:ok, size} when byte_size(after_header) >= size + 2 ->
            <<data::binary-size(^size), "\r\n", rest::binary>> = after_header
            {:chunk, data, rest}

          {:ok, _size} ->
            :need_more

          :error ->
            Log.warn("aws-chunked malformed frame header", reason: :incomplete_body)
            raise Error.new(:incomplete_body, message: "malformed aws-chunked frame header")
        end

      [_only] ->
        :need_more
    end
  end

  @doc """
  解析 aws-chunked 帧头（`<hexsize>[;chunk-signature=...][;ext...]`）。
  取首个分号前的 token 作为 hex 大小。

    * 合法 hex（含 "0"）→ {:ok, size}
    * 非 hex / 空 / 仅空白 → :error（调用方应 raise IncompleteBody，绝不静默当 0）
  """
  @spec parse_chunk_header(binary()) :: {:ok, non_neg_integer()} | :error
  def parse_chunk_header(header) when is_binary(header) do
    token =
      header
      |> :binary.split(";")
      |> List.first()
      |> String.trim()

    case token do
      "" ->
        :error

      hex ->
        case Integer.parse(hex, 16) do
          {n, ""} when n >= 0 -> {:ok, n}
          _ -> :error
        end
    end
  end
end
```

2. 跑确认绿：
   ```powershell
   mix test test/maxio/s3/body_reader_test.exs
   ```
   期望：`6 tests, 0 failures`（3 describe 用例分解）。再跑既有集成测试确认未回归：
   ```powershell
   mix test test/maxio/s3/integration_test.exs
   ```
   期望：全绿。

**Commit**：
```powershell
git add -A
git commit -m "fix(s3): aws-chunked malformed frame header raises IncompleteBody (no silent truncation)" -m "Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

### Task M2-1.4 — Object.put 失败时清理孤儿字节

**Files:** Modify `lib/maxio/s3/handlers/object.ex`

M1 `Object.put` 在 `verify_decoded_length!` 抛 IncompleteBody 时，字节已写入 FS（孤儿泄漏）。从架构层修：put 流程中任何在"元数据落库前"抛出的错误，都先 `Storage.delete(bucket, key)` 清理已写字节，再重新抛出（铁律 3：失败不留半成品）。

把 `put/1` 改为在校验/落库失败时清理：
```elixir
  @spec put(Plug.Conn.t()) :: Plug.Conn.t()
  def put(conn) do
    bucket = conn.assigns.s3_bucket
    key = conn.assigns.s3_key
    _ = ensure_bucket!(bucket)

    content_type = header(conn, "content-type") || "binary/octet-stream"
    payload_mode = conn.assigns.payload_mode
    chunks = BodyReader.stream(conn, payload_mode)

    case Storage.put(bucket, key, chunks) do
      {:ok, %{size: size, etag: etag}} ->
        # 校验/落库失败 → 先清理已写字节再抛（绝不留孤儿，铁律 3）。
        try do
          :ok = verify_decoded_length!(conn, payload_mode, size)

          {:ok, _obj} =
            Objects.put_metadata(bucket, key, %{
              size: size,
              etag: etag,
              content_type: content_type,
              storage_class: "STANDARD"
            })
        rescue
          err ->
            _ = Storage.delete(bucket, key)
            Log.warn("put object rolled back orphan bytes",
              action: :put_object,
              bucket: bucket,
              key: key,
              reason: :incomplete_body
            )

            reraise(err, __STACKTRACE__)
        end

        Log.info("put object",
          action: :put_object,
          bucket: bucket,
          key: key,
          size: size,
          auth_type: conn.assigns.auth_type
        )

        conn
        |> put_resp_header("etag", XML.quote_etag(etag))
        |> send_resp(200, "")

      {:error, :invalid_key} ->
        raise Error.new(:invalid_argument, resource: "/#{bucket}/#{key}", message: "Invalid key")

      {:error, reason} ->
        raise Error.new(:internal_error, message: inspect(reason))
    end
  end
```
> 说明：`reraise/2` 保留原异常与栈，交给 Dispatch 的 rescue 渲染正确的 S3 Error XML。清理是幂等的（FS `delete` 对 `:enoent` 返回 `:ok`）。

**验证**：
```powershell
mix test test/maxio/s3/integration_test.exs
```
期望：既有用例全绿（行为未变，只在失败路径多了清理）。

**Commit**：
```powershell
git add -A
git commit -m "fix(s3): PutObject cleans up orphan bytes when post-write validation fails" -m "Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

### Task M2-1.5 — :single 模式可选校验 x-amz-content-sha256 vs 实际字节（BadDigest）

**Files:** Modify `lib/maxio/storage/fs.ex`、`lib/maxio/storage/backend.ex`、`lib/maxio/s3/handlers/object.ex`、`test/maxio/s3/integration_test.exs`

M1 `:single` 模式不校验声明的 `x-amz-content-sha256` 与实际 body（reviewer note 2）。S3 在 `:single`（声明了真实 payload 哈希）时若实际 body 哈希不符应回 `XAmzContentSHA256Mismatch`（错误码字符串），本计划用既有 `bad_digest` 通道但补一个专用错误码。架构上：FS `put` 已边写边算 MD5；扩展为**同时**边写边算 SHA256，把 `sha256` hex 一并返回；Object.put 在 `:single` 模式下比对声明值。

先在 `lib/maxio/s3/error.ex` 的 `@table` 里补一条专用错误码（紧邻 `bad_digest`）：
```elixir
    x_amz_content_sha256_mismatch:
      {"XAmzContentSHA256Mismatch", 400,
       "The provided 'x-amz-content-sha256' header does not match what was computed."},
```

扩展 `Maxio.Storage.Backend` 的 `put_result` 类型与 `put` 文档（追加 sha256 字段，向后兼容——M1 已有调用只解构 size/etag）：
```elixir
  @type put_result :: %{size: non_neg_integer(), etag: String.t(), sha256: String.t()}
```
> 注：M1 调用方用 `%{size: size, etag: etag}` 解构（map 部分匹配），新增 `:sha256` 不破坏既有解构。

`lib/maxio/storage/fs.ex` 的 `do_put` 改为同时算 SHA256：
```elixir
  defp do_put(bucket, key, chunks, opts) do
    with {:ok, path} <- object_path(bucket, key, opts) do
      File.mkdir_p!(Path.dirname(path))
      {:ok, fd} = File.open(path, [:write, :binary, :raw])

      try do
        md5_0 = :crypto.hash_init(:md5)
        sha_0 = :crypto.hash_init(:sha256)

        {md5_ctx, sha_ctx, size} =
          Enum.reduce(chunks, {md5_0, sha_0, 0}, fn chunk, {m, s, acc} ->
            :ok = IO.binwrite(fd, chunk)
            {:crypto.hash_update(m, chunk), :crypto.hash_update(s, chunk), acc + byte_size(chunk)}
          end)

        etag = md5_ctx |> :crypto.hash_final() |> Base.encode16(case: :lower)
        sha256 = sha_ctx |> :crypto.hash_final() |> Base.encode16(case: :lower)
        {:ok, %{size: size, etag: etag, sha256: sha256}}
      after
        File.close(fd)
      end
    end
  end
```

`lib/maxio/s3/handlers/object.ex` 的 `put/1` 成功分支增加 `:single` 校验（在 verify_decoded_length! 之后、落库之前，仍在 try 块内以触发孤儿清理）。把 try 块内主体改为：
```elixir
        try do
          :ok = verify_decoded_length!(conn, payload_mode, size)
          :ok = verify_content_sha256!(conn, payload_mode, sha256)

          {:ok, _obj} =
            Objects.put_metadata(bucket, key, %{
              size: size,
              etag: etag,
              content_type: content_type,
              storage_class: "STANDARD"
            })
        rescue
          ...（同 M2-1.4，不变）
        end
```
并把成功分支的解构改为 `{:ok, %{size: size, etag: etag, sha256: sha256}}`，再加私有函数：
```elixir
  # :single 模式：声明的 x-amz-content-sha256 必须等于实际字节 SHA256（铁律 3/5）。
  # UNSIGNED-PAYLOAD / STREAMING-* 不在此校验（前者声明 unsigned，后者由 StreamingVerifier 验）。
  defp verify_content_sha256!(conn, :single, actual_sha256) do
    case header(conn, "x-amz-content-sha256") do
      nil ->
        :ok

      declared ->
        cond do
          declared in ["UNSIGNED-PAYLOAD", ""] ->
            :ok

          String.downcase(declared) == actual_sha256 ->
            :ok

          true ->
            Log.warn("content sha256 mismatch", reason: :bad_digest)

            raise Error.new(:x_amz_content_sha256_mismatch,
              message: "declared #{declared} != computed #{actual_sha256}"
            )
        end
    end
  end

  defp verify_content_sha256!(_conn, _mode, _sha256), do: :ok
```

测试：在 `test/maxio/s3/integration_test.exs` 加用例。注意自签 helper 会把 `x-amz-content-sha256` 设为真实 body 哈希（故正常 PUT 天然通过校验，已被既有用例覆盖）。这里构造一个**声明值与 body 不符**的请求：复用 helper 但篡改 body（保持声明哈希为原 body 的哈希、实际发不同 body 会破坏签名）——为隔离仅测 BadDigest 而非签名失败，直接构造 conn 较繁。简化：用一个新 helper 选项让 `signed_conn` 接受显式 `content_sha256` 覆盖。

在 `test/support/sigv4_request.ex` 的 `signed_conn` 增加：当 `opts` 含 `:content_sha256_override` 时，用该值作为 `x-amz-content-sha256`（参与签名），但 body 仍是真实 body——这样签名仍合法（因签名用的是覆盖后的声明值），但声明值 ≠ 真实哈希 → 触发 BadDigest。修改 helper（见下方完整 helper 重写，M2-3 会进一步扩展）。本任务先加最小覆盖：
```elixir
    payload_hash =
      Keyword.get(opts, :content_sha256_override) || Signer.hex_sha256(body)
```
（即把 `payload_hash = Signer.hex_sha256(body)` 一行替换为上面两行——声明哈希可被覆盖，签名与声明值一致仍合法。）

集成用例：
```elixir
  test "PutObject :single 声明 sha256 与实际不符 → 400 XAmzContentSHA256Mismatch" do
    SigV4Request.signed_conn(:put, "/digestbk") |> call()

    bad =
      SigV4Request.signed_conn(:put, "/digestbk/x.txt",
        body: "real-bytes",
        content_sha256_override: String.duplicate("a", 64)
      )
      |> call()

    assert bad.status == 400
    assert bad.resp_body =~ "<Code>XAmzContentSHA256Mismatch</Code>"
  end
```

1. 跑确认绿：
   ```powershell
   mix test test/maxio/s3/integration_test.exs
   ```
   期望：新用例通过；既有 PutObject 用例仍绿（声明 = 实际哈希）。

**Commit**：
```powershell
git add -A
git commit -m "feat(s3): verify declared x-amz-content-sha256 vs body (single mode) -> XAmzContentSHA256Mismatch" -m "Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

### 单元 M2-1 验收

```powershell
$env:Path = 'C:\Users\dyz\Documents\dev\usr\Elixir\bin;' + $env:Path
$env:ERL_FLAGS = "-kernel standard_io_encoding unicode"
mix compile --warnings-as-errors
mix test
```
期望：编译零警告；全部既有 + 新增测试通过（M1 的 125 测试 + M2-1 新增约 5 个，无回归）。dev S3 端口为 9900。

---

## 单元 M2-2 — StreamingVerifier 状态机（纯逻辑 + AWS KNOWN-ANSWER 向量）

**目标**：实现 `Maxio.Auth.SigV4.StreamingVerifier` —— `Content-Encoding: aws-chunked` 流式上传的**显式状态机**逐块签名链验证（铁律 3）。本单元只做纯状态机 + 单元测试（含 AWS 官方 worked-example 的 byte-for-byte KNOWN-ANSWER 向量），暂不接管线（M2-3 接入 BodyReader）。

**协议事实（已核验，见研究；bake in）**：
- 每个数据块（含 0 大小终止块）的 string-to-sign = **6 行**以 `\n` 连接、**无尾换行**：
  ```
  AWS4-HMAC-SHA256-PAYLOAD
  <amz-date, e.g. 20130524T000000Z>
  <scope, e.g. 20130524/us-east-1/s3/aws4_request>
  <prev-signature (64 hex)>
  e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855   # hex(SHA256(""))，固定常量
  <hex(SHA256(chunk-data)) (64 hex)>
  ```
- `chunk_signature = hex(HMAC-SHA256(kSigning, sts))`；`kSigning` 与 seed/header 签名同一把（**只推导一次**，由调用方传入）。
- 第 1 块 `prev_sig` = seed 签名（Authorization 头 `Signature=` 值）；其后 `prev_sig := 上一块的 expected_sig`。
- 0 大小终止块也是真块、照常签名验证（其 data hash = 空串常量，line5==line6）。
- 帧格式：`<hexsize>;chunk-signature=<64hex>\r\n<data>\r\n`，定位 `;chunk-signature=` 取签名（容忍其它扩展）。
- 终止块后：无 trailer → 完成；signed_trailer → 校验 trailer chunk（5 行 STS，line1=`AWS4-HMAC-SHA256-TRAILER`，prev_sig=终止块签名，line5=`hex(SHA256(trailing-headers-block))`，无空串常量行）。
- decoded 总字节数必须 == `x-amz-decoded-content-length`。
- 任一异常（缺 `;chunk-signature=`、帧头非 hex、data 短、缺 CRLF、签名不符、缺终止块、长度不符）→ 硬失败（`:signature_does_not_match` 用于密码学不符，`:incomplete_body` 用于截断/长度不符，`:invalid_chunk` 用于帧结构破坏）。绝不把半验证字节交存储（铁律 3）。

**AWS 官方 KNOWN-ANSWER 向量（signed-payload，逐字内嵌为测试）**：
- secret = `wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY`，scope_date = `20130524`，region = `us-east-1`，service = `s3`，amz_date = `20130524T000000Z`，scope = `20130524/us-east-1/s3/aws4_request`。
- seed 签名 = `4f232c4386841ef735655705268965c44a0e4690baa4adea153f7db9fa80a0a9`。
- chunk1 = 65536 × 'a'：`hex(SHA256(data))` = `bf718b6f653bebc184e1479f1935b8da974d701b893afcf49e701f3e2f9f9c5a` → chunk sig `ad80c730a21e5b8d04586a2213dd63b9a0e99e0e2307b0ade35a65485a288648`。
- chunk2 = 1024 × 'a'：`hex(SHA256(data))` = `2edc986847e209b4016e141a6dc8716d3207350f416969382d431539bf292e4a` → chunk sig `0055627c9e194cb4542bae2aa5492e3c1575bbb81b612b7d234b86a503ef5497`。
- chunk3 = 0 字节（终止）：data hash = 空串常量 → chunk sig `b6c6ea8a5354eaf15b3cb7646744f4275b71ea724fed81ceb9323e279d449df9`。
- decoded length = 66560。

### Task M2-2.1 — StreamingVerifier 失败测试（TDD，含 KNOWN-ANSWER 向量）

**Files:** Create `test/maxio/auth/sigv4/streaming_verifier_test.exs`

```elixir
defmodule Maxio.Auth.SigV4.StreamingVerifierTest do
  use ExUnit.Case, async: true

  alias Maxio.Auth.SigV4.{Signer, StreamingVerifier}

  # AWS 官方 sigv4-streaming worked-example 参数
  @secret "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"
  @scope_date "20130524"
  @region "us-east-1"
  @service "s3"
  @amz_date "20130524T000000Z"
  @scope "20130524/us-east-1/s3/aws4_request"
  @seed "4f232c4386841ef735655705268965c44a0e4690baa4adea153f7db9fa80a0a9"
  @empty_sha "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"

  @sig1 "ad80c730a21e5b8d04586a2213dd63b9a0e99e0e2307b0ade35a65485a288648"
  @sig2 "0055627c9e194cb4542bae2aa5492e3c1575bbb81b612b7d234b86a503ef5497"
  @sig3 "b6c6ea8a5354eaf15b3cb7646744f4275b71ea724fed81ceb9323e279d449df9"

  defp k_signing, do: Signer.derive_signing_key(@secret, @scope_date, @region, @service)

  defp data1, do: String.duplicate("a", 65_536)
  defp data2, do: String.duplicate("a", 1024)

  # 用项目自己的 Signer 复算某块签名（与 verifier 内部应一致）
  defp expected_sig(prev_sig, data) do
    data_hash = Signer.hex_sha256(data)
    sts = StreamingVerifier.chunk_string_to_sign(@amz_date, @scope, prev_sig, data_hash)
    Signer.signature(k_signing(), sts)
  end

  # 按帧格式拼一个 chunk（含 chunk-signature）
  defp frame(data, sig) do
    size_hex = Integer.to_string(byte_size(data), 16) |> String.downcase()
    "#{size_hex};chunk-signature=#{sig}\r\n" <> data <> "\r\n"
  end

  describe "chunk_string_to_sign/4（6 行，无尾换行）" do
    test "结构与 AWS 向量一致（line5 == 空串常量）" do
      sts = StreamingVerifier.chunk_string_to_sign(@amz_date, @scope, @seed, Signer.hex_sha256(data1()))
      lines = String.split(sts, "\n")
      assert length(lines) == 6
      assert Enum.at(lines, 0) == "AWS4-HMAC-SHA256-PAYLOAD"
      assert Enum.at(lines, 1) == @amz_date
      assert Enum.at(lines, 2) == @scope
      assert Enum.at(lines, 3) == @seed
      assert Enum.at(lines, 4) == @empty_sha
      assert Enum.at(lines, 5) == "bf718b6f653bebc184e1479f1935b8da974d701b893afcf49e701f3e2f9f9c5a"
      refute String.ends_with?(sts, "\n")
    end
  end

  describe "KNOWN-ANSWER：项目 Signer 复算的每块签名 == AWS 向量" do
    test "chunk1/2/3 签名链 byte-for-byte 一致" do
      s1 = expected_sig(@seed, data1())
      assert s1 == @sig1
      s2 = expected_sig(s1, data2())
      assert s2 == @sig2
      s3 = expected_sig(s2, "")
      assert s3 == @sig3
    end
  end

  describe "feed/2 + finalize/1（完整链）" do
    test "三块流（含终止块）全部验证通过，产出纯净 data 与正确长度" do
      v =
        StreamingVerifier.init(
          k_signing: k_signing(),
          date: @amz_date,
          scope: @scope,
          seed_signature: @seed,
          expected_decoded_len: 66_560,
          flavor: :signed
        )

      stream =
        frame(data1(), @sig1) <> frame(data2(), @sig2) <> frame("", @sig3)

      assert {:ok, chunks, v2} = StreamingVerifier.feed(v, stream)
      assert IO.iodata_to_binary(chunks) == data1() <> data2()
      assert StreamingVerifier.finalize(v2) == :ok
    end

    test "分片喂入（半个帧）也能正确累积验证" do
      v =
        StreamingVerifier.init(
          k_signing: k_signing(),
          date: @amz_date,
          scope: @scope,
          seed_signature: @seed,
          expected_decoded_len: 66_560,
          flavor: :signed
        )

      full = frame(data1(), @sig1) <> frame(data2(), @sig2) <> frame("", @sig3)
      {a, b} = String.split_at(full, 100)

      assert {:ok, c1, v1} = StreamingVerifier.feed(v, a)
      assert {:ok, c2, v2} = StreamingVerifier.feed(v1, b)
      assert IO.iodata_to_binary([c1, c2]) == data1() <> data2()
      assert StreamingVerifier.finalize(v2) == :ok
    end

    test "篡改 data 一字节 → :signature_does_not_match（铁律 3 硬失败）" do
      v =
        StreamingVerifier.init(
          k_signing: k_signing(),
          date: @amz_date,
          scope: @scope,
          seed_signature: @seed,
          expected_decoded_len: 66_560,
          flavor: :signed
        )

      tampered = String.duplicate("a", 65_535) <> "b"
      stream = frame(tampered, @sig1)
      assert {:error, :signature_does_not_match} = StreamingVerifier.feed(v, stream)
    end

    test "错误的 chunk-signature → :signature_does_not_match" do
      v =
        StreamingVerifier.init(
          k_signing: k_signing(),
          date: @amz_date,
          scope: @scope,
          seed_signature: @seed,
          expected_decoded_len: 66_560,
          flavor: :signed
        )

      stream = frame(data1(), String.duplicate("0", 64))
      assert {:error, :signature_does_not_match} = StreamingVerifier.feed(v, stream)
    end

    test "缺 ;chunk-signature= → :invalid_chunk" do
      v =
        StreamingVerifier.init(
          k_signing: k_signing(),
          date: @amz_date,
          scope: @scope,
          seed_signature: @seed,
          expected_decoded_len: 0,
          flavor: :signed
        )

      stream = "10000\r\n" <> data1() <> "\r\n"
      assert {:error, :invalid_chunk} = StreamingVerifier.feed(v, stream)
    end

    test "未达终止块即 finalize → :incomplete_body" do
      v =
        StreamingVerifier.init(
          k_signing: k_signing(),
          date: @amz_date,
          scope: @scope,
          seed_signature: @seed,
          expected_decoded_len: 66_560,
          flavor: :signed
        )

      {:ok, _c, v2} = StreamingVerifier.feed(v, frame(data1(), @sig1))
      assert {:error, :incomplete_body} = StreamingVerifier.finalize(v2)
    end

    test "decoded 长度与声明不符 → finalize :incomplete_body" do
      v =
        StreamingVerifier.init(
          k_signing: k_signing(),
          date: @amz_date,
          scope: @scope,
          seed_signature: @seed,
          expected_decoded_len: 999_999,
          flavor: :signed
        )

      stream = frame(data1(), @sig1) <> frame(data2(), @sig2) <> frame("", @sig3)
      {:ok, _c, v2} = StreamingVerifier.feed(v, stream)
      assert {:error, :incomplete_body} = StreamingVerifier.finalize(v2)
    end
  end
end
```

1. 跑确认红（模块未定义）：
   ```powershell
   mix test test/maxio/auth/sigv4/streaming_verifier_test.exs
   ```

**验证**：测试因模块缺失失败即通过本步。

### Task M2-2.2 — 实现 StreamingVerifier（使测试通过）

**Files:** Create `lib/maxio/auth/sigv4/streaming_verifier.ex`

```elixir
defmodule Maxio.Auth.SigV4.StreamingVerifier do
  @moduledoc """
  aws-chunked（Content-Encoding: aws-chunked）流式上传的逐块签名链验证状态机（铁律 3：
  显式状态机驱动，任一异常硬失败，绝不把半验证字节交下游）。

  替换 M1 的 passthrough：M1 只验 seed 签名 + 解帧；M2 对每个数据块（含 0 大小终止块）
  按 AWS sigv4-streaming 规范复算 chunk_signature 并常数时间比对，签名链以 prev_sig 串联。

  ## string-to-sign（数据块，6 行，无尾换行）
      AWS4-HMAC-SHA256-PAYLOAD
      <amz-date>
      <scope>
      <prev-signature>
      <hex(SHA256("")) 固定常量>
      <hex(SHA256(chunk-data))>

  ## 帧格式
      <hexsize>;chunk-signature=<64hex>\\r\\n<data>\\r\\n
  终止块 size=0，仍签名验证（data hash = 空串常量）。

  ## flavor（由 x-amz-content-sha256 决定，调用方传入）
    * :signed          STREAMING-AWS4-HMAC-SHA256-PAYLOAD
    * :signed_trailer  STREAMING-AWS4-HMAC-SHA256-PAYLOAD-TRAILER（终止块后验 trailer chunk 签名）
    * :unsigned_trailer STREAMING-UNSIGNED-PAYLOAD-TRAILER（不验逐块签名，仅解帧）

  ## 用法
      v = init(k_signing:, date:, scope:, seed_signature:, expected_decoded_len:, flavor:)
      {:ok, decoded_chunks, v} = feed(v, network_bytes)   # 可多次
      :ok = finalize(v)                                    # 校验终止块 + 长度
  """
  alias Maxio.Auth.SigV4.Signer

  @empty_sha "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
  @sig_marker ";chunk-signature="

  @enforce_keys [:k_signing, :date, :scope, :prev_sig, :flavor]
  defstruct [
    :k_signing,
    :date,
    :scope,
    :prev_sig,
    :flavor,
    expected_decoded_len: nil,
    trailer_names: [],
    decoded_count: 0,
    buffer: "",
    stage: :data
  ]

  @type t :: %__MODULE__{}

  @spec init(keyword()) :: t()
  def init(opts) do
    %__MODULE__{
      k_signing: Keyword.fetch!(opts, :k_signing),
      date: Keyword.fetch!(opts, :date),
      scope: Keyword.fetch!(opts, :scope),
      prev_sig: Keyword.fetch!(opts, :seed_signature),
      flavor: Keyword.get(opts, :flavor, :signed),
      expected_decoded_len: Keyword.get(opts, :expected_decoded_len),
      trailer_names: Keyword.get(opts, :trailer_names, [])
    }
  end

  @doc "数据块 string-to-sign（6 行，无尾换行）。纯函数，供测试与内部复用。"
  @spec chunk_string_to_sign(String.t(), String.t(), String.t(), String.t()) :: String.t()
  def chunk_string_to_sign(date, scope, prev_sig, data_hash_hex) do
    Enum.join(
      [
        "AWS4-HMAC-SHA256-PAYLOAD",
        date,
        scope,
        prev_sig,
        @empty_sha,
        data_hash_hex
      ],
      "\n"
    )
  end

  @doc "trailer chunk string-to-sign（5 行，无尾换行；signed_trailer 变体用）。"
  @spec trailer_string_to_sign(String.t(), String.t(), String.t(), String.t()) :: String.t()
  def trailer_string_to_sign(date, scope, prev_sig, trailer_block_hash_hex) do
    Enum.join(
      [
        "AWS4-HMAC-SHA256-TRAILER",
        date,
        scope,
        prev_sig,
        trailer_block_hash_hex
      ],
      "\n"
    )
  end

  @doc """
  喂入网络字节，返回 {:ok, decoded_chunks, new_state} | {:error, reason}。
  decoded_chunks 是**已逐块验证通过**的纯净 data（iodata 列表，可空）。
  reason ∈ :signature_does_not_match | :incomplete_body | :invalid_chunk。
  """
  @spec feed(t(), binary()) :: {:ok, [binary()], t()} | {:error, atom()}
  def feed(%__MODULE__{} = v, bytes) when is_binary(bytes) do
    consume(%{v | buffer: v.buffer <> bytes}, [])
  end

  # 已到 done：忽略多余字节（终止块后只可能是 trailer，已在 done 前处理）
  defp consume(%__MODULE__{stage: :done} = v, acc), do: {:ok, Enum.reverse(acc), v}

  defp consume(%__MODULE__{stage: :data} = v, acc) do
    case take_frame(v.buffer) do
      :need_more ->
        {:ok, Enum.reverse(acc), v}

      {:error, reason} ->
        {:error, reason}

      {:frame, size, provided_sig, data, rest} ->
        with :ok <- verify_data_chunk(v, size, provided_sig, data) do
          expected = data_chunk_signature(v, data)
          v2 = %{v | prev_sig: expected, buffer: rest, decoded_count: v.decoded_count + size}

          cond do
            size == 0 and v.flavor == :signed_trailer ->
              # 终止块已验；进入 trailer 解析（prev_sig = 终止块签名）
              consume(%{v2 | stage: :trailer}, acc)

            size == 0 ->
              consume(%{v2 | stage: :done}, acc)

            true ->
              consume(v2, [data | acc])
          end
        end
    end
  end

  defp consume(%__MODULE__{stage: :trailer} = v, acc) do
    case parse_trailer(v.buffer) do
      :need_more ->
        {:ok, Enum.reverse(acc), v}

      {:error, reason} ->
        {:error, reason}

      {:ok, trailer_block, provided_sig, rest} ->
        sts = trailer_string_to_sign(v.date, v.scope, v.prev_sig, Signer.hex_sha256(trailer_block))
        expected = Signer.signature(v.k_signing, sts)

        if Signer.secure_compare(expected, provided_sig) do
          consume(%{v | stage: :done, buffer: rest}, acc)
        else
          {:error, :signature_does_not_match}
        end
    end
  end

  # ── 数据块签名验证 ──
  defp verify_data_chunk(%__MODULE__{flavor: :unsigned_trailer}, _size, _sig, _data), do: :ok

  defp verify_data_chunk(v, _size, provided_sig, data) do
    expected = data_chunk_signature(v, data)

    if Signer.secure_compare(expected, provided_sig) do
      :ok
    else
      {:error, :signature_does_not_match}
    end
  end

  defp data_chunk_signature(v, data) do
    data_hash = Signer.hex_sha256(data)
    sts = chunk_string_to_sign(v.date, v.scope, v.prev_sig, data_hash)
    Signer.signature(v.k_signing, sts)
  end

  # ── 帧解析：<hexsize>;chunk-signature=<64hex>\r\n<data>\r\n ──
  # 返回 {:frame, size, sig, data, rest} | :need_more | {:error, reason}
  defp take_frame(buffer) do
    case :binary.split(buffer, "\r\n") do
      [_only] ->
        :need_more

      [header, after_header] ->
        with {:ok, size} <- parse_size(header),
             {:ok, sig} <- parse_signature(header) do
          if byte_size(after_header) >= size + 2 do
            case after_header do
              <<data::binary-size(^size), "\r\n", rest::binary>> ->
                {:frame, size, sig, data, rest}

              _ ->
                {:error, :invalid_chunk}
            end
          else
            :need_more
          end
        end
    end
  end

  defp parse_size(header) do
    token = header |> :binary.split(";") |> List.first() |> String.trim()

    case Integer.parse(token, 16) do
      {n, ""} when n >= 0 -> {:ok, n}
      _ -> {:error, :invalid_chunk}
    end
  end

  defp parse_signature(header) do
    case :binary.match(header, @sig_marker) do
      :nomatch ->
        {:error, :invalid_chunk}

      {pos, len} ->
        sig = binary_part(header, pos + len, byte_size(header) - pos - len) |> String.trim()

        if valid_hex64?(sig), do: {:ok, sig}, else: {:error, :invalid_chunk}
    end
  end

  defp valid_hex64?(sig) do
    byte_size(sig) == 64 and String.match?(sig, ~r/\A[0-9a-fA-F]{64}\z/)
  end

  # ── trailer chunk：<name>:<value>\r\nx-amz-trailer-signature:<sig>\r\n ──
  # 返回 {:ok, trailer_block, sig, rest} | :need_more | {:error, reason}
  # trailer_block 用于哈希：每个 trailing header "name:value\n"（小写名，无空白）。
  defp parse_trailer(buffer) do
    case :binary.match(buffer, "x-amz-trailer-signature:") do
      :nomatch ->
        :need_more

      {pos, len} ->
        header_part = binary_part(buffer, 0, pos)
        after_marker = binary_part(buffer, pos + len, byte_size(buffer) - pos - len)

        case :binary.split(after_marker, "\r\n") do
          [_only] ->
            :need_more

          [sig_raw, rest] ->
            sig = String.trim(sig_raw)

            if valid_hex64?(sig) do
              {:ok, normalize_trailer_block(header_part), sig, rest}
            else
              {:error, :invalid_chunk}
            end
        end
    end
  end

  # header_part 形如 "x-amz-checksum-crc32c:sOO8/Q==\r\n"（可能多行），
  # 规整为按行 "name:value\n"（小写名、去空白）。
  defp normalize_trailer_block(header_part) do
    header_part
    |> String.split("\r\n", trim: true)
    |> Enum.map(fn line ->
      case String.split(line, ":", parts: 2) do
        [name, value] -> String.downcase(String.trim(name)) <> ":" <> String.trim(value) <> "\n"
        _ -> ""
      end
    end)
    |> Enum.join("")
  end

  @doc "校验已达终止块（stage == :done）且 decoded 长度与声明一致。"
  @spec finalize(t()) :: :ok | {:error, atom()}
  def finalize(%__MODULE__{stage: :done} = v) do
    cond do
      is_nil(v.expected_decoded_len) -> :ok
      v.decoded_count == v.expected_decoded_len -> :ok
      true -> {:error, :incomplete_body}
    end
  end

  def finalize(%__MODULE__{}), do: {:error, :incomplete_body}
end
```

1. 跑确认绿：
   ```powershell
   mix test test/maxio/auth/sigv4/streaming_verifier_test.exs
   ```
   期望：全绿（含 KNOWN-ANSWER 向量链 byte-for-byte 一致）。

**验证**：StreamingVerifierTest 全绿即通过。

**Commit**：
```powershell
git add -A
git commit -m "feat(auth): SigV4 StreamingVerifier state machine with AWS known-answer vectors" -m "Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

### 单元 M2-2 验收

```powershell
$env:Path = 'C:\Users\dyz\Documents\dev\usr\Elixir\bin;' + $env:Path
$env:ERL_FLAGS = "-kernel standard_io_encoding unicode"
mix compile --warnings-as-errors
mix test test/maxio/auth/sigv4/streaming_verifier_test.exs
```
期望：零警告；全绿。证明：逐块 6 行 STS、签名链 prev_sig 推进、常数时间比对、终止块、长度校验、各类硬失败、AWS 向量一致。

---

## 单元 M2-3 — StreamingVerifier 接入 BodyReader + SigV4 透传材料 + 自签 chunked e2e

**目标**：把 M2-2 的 `StreamingVerifier` 接入请求管线，使 `:streaming`（aws-chunked）PUT/UploadPart 走**逐块签名验证**：坏块硬停 `SignatureDoesNotMatch`（403），截断/长度不符硬停 `IncompleteBody`（400），SigV4A 变体 `501 NotImplemented`。`BodyReader.stream(conn, :streaming)` 内部用 verifier 状态机替换 M1 passthrough。为此 SigV4 plug 必须把验证 seed 时已有的材料（kSigning、date、scope、seed 签名）经 conn assigns 透传给 BodyReader（**kSigning 只推导一次**，铁律 2：不重复推导）。最后扩展自签 helper 生成合法 chunk-signed body，做"我们签→我们验"的端到端闭环集成测试。

### Task M2-3.1 — Auth.authenticate 返回流式材料（供 BodyReader 复用 kSigning）

**Files:** Modify `lib/maxio/auth.ex`

`Maxio.Auth.verify_signature/3` 已推导 `kSigning`（`Signer.derive_signing_key/4`）。为不重复推导，让 `authenticate/1` 在成功时额外返回流式材料。把返回从 `{:ok, principal}` 扩展为 `{:ok, principal, sig_context}`：

```elixir
  @spec authenticate(map()) :: {:ok, map(), map()} | {:error, Error.t()}
  def authenticate(%{signed_request: sr} = material) do
    with :ok <- check_request_time(sr, material.now),
         {:ok, %{secret_key: secret, principal: principal}} <- lookup_secret(sr.access_key),
         {:ok, sig_context} <- verify_signature(sr, material, secret) do
      Log.info("sigv4 authenticated", auth_type: sr.auth_type)
      {:ok, principal, sig_context}
    end
  end
```

把 `verify_signature/3` 改为成功时返回 `{:ok, sig_context}`（含 kSigning/scope/seed_signature/amz_date）：
```elixir
  defp verify_signature(sr, material, secret) do
    scope = "#{sr.scope_date}/#{sr.region}/#{sr.service}/aws4_request"

    req = %{
      method: material.method,
      path: material.path,
      query: material.query,
      headers: filter_signed_headers(material.headers, sr.signed_headers),
      payload_hash: material.payload_hash
    }

    canonical = Canonical.canonical_request(req)
    sts = Signer.string_to_sign(sr.amz_date, scope, canonical, @algorithm)
    key = Signer.derive_signing_key(secret, sr.scope_date, sr.region, sr.service)
    computed = Signer.signature(key, sts)

    if Signer.secure_compare(computed, sr.signature) do
      {:ok,
       %{
         k_signing: key,
         scope: scope,
         seed_signature: sr.signature,
         amz_date: sr.amz_date
       }}
    else
      Log.warn("signature mismatch", auth_type: sr.auth_type, reason: :signature_does_not_match)
      {:error, Error.new(:signature_does_not_match)}
    end
  end
```
> 说明：sig_context 即"验完 seed 签名后已有的、逐块验证要复用的材料"——避免 BodyReader 重新查 secret / 重推 kSigning（铁律 2：不重复劳动）。presigned 形态也返回 sig_context（虽其 payload_mode 恒 :unsigned，BodyReader 不会用到）。

> 若仓库存在 `test/maxio/auth_test.exs` 且断言 `{:ok, principal}`，同步把断言改为 `{:ok, principal, _ctx}`。

**验证**：此改动会破坏 SigV4 plug（调用方解构 `{:ok, principal}`），M2-3.2 同步修；本任务先不单独验证。

### Task M2-3.2 — SigV4 plug 把流式材料写入 assigns + SigV4A 早拒 501

**Files:** Modify `lib/maxio/s3/plugs/sigv4.ex`

把 `call/2` 改为：先对 SigV4A（ECDSA）变体早拒 501（它非 HMAC，无法验 seed），否则走鉴权流程并把 sig_context 放进 assigns：

```elixir
  @impl true
  def call(conn, _opts) do
    conn = fetch_query_params(conn)
    content_sha = header(conn, "x-amz-content-sha256") || ""

    if sigv4a_streaming?(content_sha) do
      reject(conn, Error.new(:not_implemented, message: "SigV4A streaming (ECDSA P-256) not supported"))
    else
      do_authenticate(conn)
    end
  end

  defp sigv4a_streaming?(v) do
    v in [
      "STREAMING-AWS4-ECDSA-P256-SHA256-PAYLOAD",
      "STREAMING-AWS4-ECDSA-P256-SHA256-PAYLOAD-TRAILER"
    ]
  end

  defp do_authenticate(conn) do
    case detect_and_parse(conn) do
      {:ok, signed_request} ->
        material = build_material(conn, signed_request)

        case Auth.authenticate(material) do
          {:ok, principal, sig_context} ->
            conn
            |> assign(:principal, principal)
            |> assign(:auth_type, signed_request.auth_type)
            |> assign(:payload_mode, signed_request.payload_mode)
            |> assign(:sigv4_context, sig_context)

          {:error, %Error{} = err} ->
            reject(conn, err)
        end

      {:error, code} ->
        reject(conn, Error.new(code))
    end
  end
```
> 说明：`assigns.sigv4_context` = `%{k_signing, scope, seed_signature, amz_date}`。其余既有私有函数（`detect_and_parse/1`、`build_material/2`、`header/2`、`reject/2` 等）保持不变。`fetch_query_params` 在 `call/2` 已做，`do_authenticate/1` 内不重复。

**验证**：
```powershell
mix compile --warnings-as-errors
```
期望：编译零警告（plug 与 Auth 三元组契约对齐）。

### Task M2-3.3 — BodyReader :streaming 用 StreamingVerifier（含 flavor）

**Files:** Modify `lib/maxio/s3/body_reader.ex`

把 `:streaming` 分支改为驱动 verifier 状态机。需要 conn 上：`assigns.sigv4_context`、`x-amz-content-sha256`（flavor）、`x-amz-decoded-content-length`、`x-amz-trailer`。替换 `stream(conn, :streaming)` 整段与解帧私有函数：

```elixir
  alias Maxio.Auth.SigV4.StreamingVerifier

  def stream(conn, :streaming) do
    ctx = conn.assigns[:sigv4_context]
    content_sha = req_header(conn, "x-amz-content-sha256") || ""
    flavor = flavor_of(content_sha)
    decoded_len = parse_int(req_header(conn, "x-amz-decoded-content-length"))
    trailer_names = parse_trailer_names(req_header(conn, "x-amz-trailer"))

    verifier =
      StreamingVerifier.init(
        k_signing: ctx.k_signing,
        date: ctx.amz_date,
        scope: ctx.scope,
        seed_signature: ctx.seed_signature,
        expected_decoded_len: decoded_len,
        flavor: flavor,
        trailer_names: trailer_names
      )

    Log.info("aws-chunked streaming verify start", payload_mode: :streaming, reason: flavor)

    Stream.resource(
      fn -> {conn, verifier, :reading} end,
      &verify_step/1,
      fn _ -> :ok end
    )
  end
```

加 verifier 驱动私有函数（坏块/截断 raise Error，硬停；铁律 3），删除已无用的 `deframe_step/1`、`parse_chunk/1`（保留 `parse_chunk_header/1`，M2-1.3 单测仍依赖；若编译器报其 unused，加 `@doc` 已使其为公开函数，不会 unused）：

```elixir
  defp verify_step({:done, verifier}) do
    case StreamingVerifier.finalize(verifier) do
      :ok -> {:halt, :ok}
      {:error, reason} -> raise streaming_error(reason)
    end
  end

  defp verify_step({conn, verifier, :reading}) do
    case Plug.Conn.read_body(conn, @read_opts) do
      {:ok, more, _conn2} ->
        case StreamingVerifier.feed(verifier, more) do
          {:ok, chunks, v2} -> {chunks, {:done, v2}}
          {:error, reason} -> raise streaming_error(reason)
        end

      {:more, more, conn2} ->
        case StreamingVerifier.feed(verifier, more) do
          {:ok, chunks, v2} -> {chunks, {conn2, v2, :reading}}
          {:error, reason} -> raise streaming_error(reason)
        end

      {:error, _} ->
        raise streaming_error(:incomplete_body)
    end
  end

  defp streaming_error(:signature_does_not_match), do: Error.new(:signature_does_not_match)
  defp streaming_error(:incomplete_body), do: Error.new(:incomplete_body)
  defp streaming_error(_), do: Error.new(:incomplete_body, message: "invalid aws-chunked frame")

  defp flavor_of("STREAMING-AWS4-HMAC-SHA256-PAYLOAD"), do: :signed
  defp flavor_of("STREAMING-AWS4-HMAC-SHA256-PAYLOAD-TRAILER"), do: :signed_trailer
  defp flavor_of("STREAMING-UNSIGNED-PAYLOAD-TRAILER"), do: :unsigned_trailer
  defp flavor_of(_), do: :signed

  defp req_header(conn, name), do: conn |> Plug.Conn.get_req_header(name) |> List.first()

  defp parse_int(nil), do: nil

  defp parse_int(str) do
    case Integer.parse(str) do
      {n, ""} -> n
      _ -> nil
    end
  end

  defp parse_trailer_names(nil), do: []

  defp parse_trailer_names(str) do
    str |> String.split(",", trim: true) |> Enum.map(&(&1 |> String.trim() |> String.downcase()))
  end
```
> 重要：`verify_step` 在 `{:ok, more, _}`（read_body 读完最后一片）时把状态切到 `{:done, v2}`，下一次迭代 `verify_step({:done, verifier})` 调 `finalize` 校验终止块 + 长度，再 `:halt`。这样即便整个 body 一次读完，也会过 finalize。`raise` 出的 `Maxio.S3.Error` 由 `Maxio.S3.Plugs.Dispatch` 的 rescue 渲染（403/400）。坏块在 emit 前 raise——**绝不把半验证字节交存储**（铁律 3）。但注意：Storage.put 已在消费 stream 时逐块写盘；若中途 raise，Object.put 的孤儿清理（M2-1.4）会删掉已写字节，故"不落盘"在 GET 404 层面成立。

**验证**：
```powershell
mix compile --warnings-as-errors
mix test test/maxio/auth/sigv4/streaming_verifier_test.exs test/maxio/s3/body_reader_test.exs
```
期望：零警告；StreamingVerifier 与 parse_chunk_header 单测仍绿。

### Task M2-3.4 — 扩展自签 helper 生成 aws-chunked body

**Files:** Modify `test/support/sigv4_request.ex`

新增 `signed_chunked_conn/4`：用项目自己的 Signer 算 seed 与逐块签名，拼合法 chunk-signed body（"我们签→我们验"闭环）。在既有 `signed_conn/3` 之后追加（复用模块属性 `@access_key/@secret/@region/@service/@host`）：

```elixir
  @doc """
  自签一个 aws-chunked（STREAMING-AWS4-HMAC-SHA256-PAYLOAD）流式请求。
  opts: :chunk_size（默认整 body 一块）、:headers、:tamper（fn binary -> binary，
  对最终 chunked body 做篡改，用于负向测试）、:decoded_length_override（覆盖声明长度）。
  """
  def signed_chunked_conn(method, path, body, opts \\ []) do
    chunk_size = Keyword.get(opts, :chunk_size, max(byte_size(body), 1))
    extra_headers = Keyword.get(opts, :headers, [])

    now = DateTime.utc_now()
    amz_date = Calendar.strftime(now, "%Y%m%dT%H%M%SZ")
    scope_date = Calendar.strftime(now, "%Y%m%d")
    scope = "#{scope_date}/#{@region}/#{@service}/aws4_request"
    decoded_len = byte_size(body)
    decoded_len_header = Keyword.get(opts, :decoded_length_override, decoded_len)

    data_chunks = chunk_body(body, chunk_size)

    base_headers =
      [
        {"host", @host},
        {"content-encoding", "aws-chunked"},
        {"x-amz-content-sha256", "STREAMING-AWS4-HMAC-SHA256-PAYLOAD"},
        {"x-amz-date", amz_date},
        {"x-amz-decoded-content-length", Integer.to_string(decoded_len_header)}
      ] ++ Enum.map(extra_headers, fn {k, v} -> {String.downcase(k), v} end)

    canonical_req = %{
      method: to_string(method) |> String.upcase(),
      path: path,
      query: %{},
      headers: base_headers,
      payload_hash: "STREAMING-AWS4-HMAC-SHA256-PAYLOAD"
    }

    canonical = Canonical.canonical_request(canonical_req)
    sts = Signer.string_to_sign(amz_date, scope, canonical, "AWS4-HMAC-SHA256")
    key = Signer.derive_signing_key(@secret, scope_date, @region, @service)
    seed_sig = Signer.signature(key, sts)
    signed_headers = Canonical.signed_headers(base_headers)

    auth =
      "AWS4-HMAC-SHA256 Credential=#{@access_key}/#{scope}," <>
        "SignedHeaders=#{signed_headers},Signature=#{seed_sig}"

    chunked_body = build_chunked_body(data_chunks, key, amz_date, scope, seed_sig)
    chunked_body = if t = Keyword.get(opts, :tamper), do: t.(chunked_body), else: chunked_body

    conn =
      conn(method, path, chunked_body)
      |> Map.put(:host, @host)
      |> put_private(:maxio_now, now)

    base_headers
    |> Enum.reject(fn {k, _v} -> k == "host" end)
    |> Enum.reduce(conn, fn {k, v}, acc -> put_req_header(acc, k, v) end)
    |> put_req_header("authorization", auth)
  end

  defp chunk_body("", _size), do: []

  defp chunk_body(body, size) do
    body
    |> :binary.bin_to_list()
    |> Enum.chunk_every(size)
    |> Enum.map(&:erlang.list_to_binary/1)
  end

  defp build_chunked_body(data_chunks, key, amz_date, scope, seed_sig) do
    {frames, _last} =
      Enum.reduce(data_chunks ++ [""], {[], seed_sig}, fn data, {acc, prev} ->
        data_hash = Signer.hex_sha256(data)

        chunk_sts =
          Maxio.Auth.SigV4.StreamingVerifier.chunk_string_to_sign(amz_date, scope, prev, data_hash)

        sig = Signer.signature(key, chunk_sts)
        size_hex = Integer.to_string(byte_size(data), 16) |> String.downcase()
        frame = "#{size_hex};chunk-signature=#{sig}\r\n" <> data <> "\r\n"
        {[frame | acc], sig}
      end)

    frames |> Enum.reverse() |> IO.iodata_to_binary()
  end
```
> 注意：`data_chunks ++ [""]` 在末尾追加空串作为 0 大小终止块（其 prev_sig 为最后数据块签名，符合规范）。`decoded_length_override` 只改头值（参与签名，故声明值即便错也签名合法），body 仍按真实数据拼帧 → verifier 逐块签名通过、finalize 长度比对失败 → IncompleteBody。

**验证**：
```powershell
mix compile --warnings-as-errors
```
期望：零警告。

### Task M2-3.5 — aws-chunked 端到端集成测试

**Files:** Modify `test/maxio/s3/integration_test.exs`

在文件 `end` 前加用例：

```elixir
  test "aws-chunked PutObject（单块）→ GET 取回 + ETag 为 MD5（解帧后）" do
    SigV4Request.signed_conn(:put, "/chunkbk") |> call()

    body = "Welcome to Amazon S3."
    put = SigV4Request.signed_chunked_conn(:put, "/chunkbk/c.txt", body) |> call()
    assert put.status == 200
    expected = "\"" <> (:crypto.hash(:md5, body) |> Base.encode16(case: :lower)) <> "\""
    assert get_resp_header(put, "etag") == [expected]

    get = SigV4Request.signed_conn(:get, "/chunkbk/c.txt") |> call()
    assert get.status == 200
    assert get.resp_body == body
  end

  test "aws-chunked PutObject（多块）→ 解帧后内容完整" do
    SigV4Request.signed_conn(:put, "/chunkmb") |> call()

    body = String.duplicate("z", 20)
    put = SigV4Request.signed_chunked_conn(:put, "/chunkmb/m.txt", body, chunk_size: 7) |> call()
    assert put.status == 200

    get = SigV4Request.signed_conn(:get, "/chunkmb/m.txt") |> call()
    assert get.resp_body == body
  end

  test "aws-chunked 篡改某块 data → 403 SignatureDoesNotMatch（硬停，绝不落盘）" do
    SigV4Request.signed_conn(:put, "/chunkbad") |> call()

    tamper = fn chunked -> String.replace(chunked, "abcdefghij", "abcdefghiZ") end

    bad =
      SigV4Request.signed_chunked_conn(:put, "/chunkbad/x.txt", "abcdefghij",
        chunk_size: 10,
        tamper: tamper
      )
      |> call()

    assert bad.status == 403
    assert bad.resp_body =~ "<Code>SignatureDoesNotMatch</Code>"

    get = SigV4Request.signed_conn(:get, "/chunkbad/x.txt") |> call()
    assert get.status == 404
  end

  test "aws-chunked 声明 decoded-content-length 与实际不符 → 400 IncompleteBody" do
    SigV4Request.signed_conn(:put, "/chunklen") |> call()

    bad =
      SigV4Request.signed_chunked_conn(:put, "/chunklen/x.txt", "abcdefghij",
        decoded_length_override: 999
      )
      |> call()

    assert bad.status == 400
    assert bad.resp_body =~ "<Code>IncompleteBody</Code>"
  end

  test "SigV4A 流式（ECDSA）→ 501 NotImplemented" do
    SigV4Request.signed_conn(:put, "/sigv4a") |> call()
    # 直接发一个声明 SigV4A 流式的 PUT（不必合法签名，plug 早拒 501）
    conn =
      SigV4Request.signed_conn(:put, "/sigv4a/x.txt",
        headers: [{"x-amz-content-sha256", "STREAMING-AWS4-ECDSA-P256-SHA256-PAYLOAD"}],
        content_sha256_override: "STREAMING-AWS4-ECDSA-P256-SHA256-PAYLOAD"
      )
      |> call()

    assert conn.status == 501
    assert conn.resp_body =~ "<Code>NotImplemented</Code>"
  end
```

1. 跑确认绿：
   ```powershell
   mix test test/maxio/s3/integration_test.exs
   ```
   期望：全部 aws-chunked 用例通过（含篡改 403 + 不落盘 404 + 长度不符 400 + SigV4A 501）。

**Commit**：
```powershell
git add -A
git commit -m "feat(s3): wire StreamingVerifier into BodyReader (per-chunk aws-chunked verify, hard-fail) + e2e" -m "Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

### 单元 M2-3 验收

```powershell
$env:Path = 'C:\Users\dyz\Documents\dev\usr\Elixir\bin;' + $env:Path
$env:ERL_FLAGS = "-kernel standard_io_encoding unicode"
mix compile --warnings-as-errors
mix test
```
期望：零警告；全绿。证明：aws-chunked 逐块签名验证端到端工作（替换 M1 passthrough）；坏块硬停 403 且不落盘；长度不符 400；SigV4A 501。

---

## 单元 M2-4 — Multipart：存储后端 parts 回调 + FS 实现 + 迁移 + Maxio.Multipart 上下文 + ETag

**目标**：为分段上传打地基（不含 handler/view，控制单轮规模）：①`Maxio.Storage.Backend` 新增 4 个 parts 回调 + FS 实现（part 字节流式落盘、组装、清理）；②Ecto 迁移建 `multipart_uploads` + `multipart_parts` 两表（中文 COMMENT）；③`Maxio.Multipart` 上下文（initiate/get/put_part/list_parts/list_uploads/complete/abort + multipart ETag 算法）。本单元末尾 green compile + 上下文/ETag/FS parts 单测全绿。

**协议事实（已核验，bake in）**：
- multipart ETag = `"` + `hex(MD5(concat(rawMD5(part1) ++ rawMD5(part2) ++ ... ++ rawMD5(partN))))` + `"-N"` + `"`（无引号存库，渲染加引号）。`rawMD5(partI)` = part I 的 **16 字节原始 MD5 digest**。
- 每个 part 的 ETag（UploadPart 返回、ListParts 列出）= `"<hex md5 of that part>"`。
- Complete 校验：part 存在（否则 `InvalidPart` 400）、升序（否则 `InvalidPartOrder` 400）、每个非末 part ≥ 5 MiB=5242880 字节（否则 `EntityTooSmall` 400）、upload 存在（否则 `NoSuchUpload` 404）。末 part 任意大小 ≥ 1 字节。
- part number 范围 1..10000；ListParts 默认/最大 1000；ListMultipartUploads 默认/最大 1000。

> **测试时禁用 5 MiB 下限的做法**：`Maxio.Multipart.complete/2` 的 EntityTooSmall 校验阈值取自一个可注入的 `min_part_size`（默认 `5_242_880`，测试经 `Application.put_env(:maxio, :multipart_min_part_size, 1)` 或函数 opts 注入小值），使微型 part 的 ETag 数学可被 KNOWN-ANSWER 测试覆盖。

### Task M2-4.1 — Backend behaviour 新增 parts 回调 + Storage 门面转发

**Files:** Modify `lib/maxio/storage/backend.ex`、`lib/maxio/storage.ex`

`lib/maxio/storage/backend.ex` 在既有回调之后追加（**不动既有回调**）：
```elixir
  @type upload_id :: String.t()
  @type part_number :: pos_integer()
  @type part_put_result :: %{size: non_neg_integer(), etag: String.t(), md5_raw: binary()}

  @doc "流式写入一个 part 的字节，返回该 part 的 size、MD5 hex etag（无引号）与 16 字节原始 MD5。"
  @callback put_part(bucket(), key(), upload_id(), part_number(), chunks :: Enumerable.t(), opts :: keyword()) ::
              {:ok, part_put_result()} | {:error, term()}

  @doc "流式读取一个 part 的字节（组装时按 part number 升序拼接用）。"
  @callback get_part_stream(bucket(), key(), upload_id(), part_number(), opts :: keyword()) ::
              {:ok, Enumerable.t()} | {:error, :enoent | term()}

  @doc "按给定 part number 升序把各 part 字节拼成最终对象（落到对象路径），返回总大小。"
  @callback assemble(bucket(), key(), upload_id(), part_numbers :: [part_number()], opts :: keyword()) ::
              {:ok, %{size: non_neg_integer()}} | {:error, term()}

  @doc "删除该 upload 的所有 part 字节与临时目录（Abort / Complete 后清理）。幂等。"
  @callback abort_upload(bucket(), key(), upload_id(), opts :: keyword()) :: :ok | {:error, term()}
```

`lib/maxio/storage.ex` 追加转发门面（在既有函数之后）：
```elixir
  @spec put_part(String.t(), String.t(), String.t(), pos_integer(), Enumerable.t(), keyword()) ::
          {:ok, Maxio.Storage.Backend.part_put_result()} | {:error, term()}
  def put_part(bucket, key, upload_id, part_number, chunks, opts \\ []),
    do: backend().put_part(bucket, key, upload_id, part_number, chunks, opts)

  @spec get_part_stream(String.t(), String.t(), String.t(), pos_integer(), keyword()) ::
          {:ok, Enumerable.t()} | {:error, term()}
  def get_part_stream(bucket, key, upload_id, part_number, opts \\ []),
    do: backend().get_part_stream(bucket, key, upload_id, part_number, opts)

  @spec assemble(String.t(), String.t(), String.t(), [pos_integer()], keyword()) ::
          {:ok, %{size: non_neg_integer()}} | {:error, term()}
  def assemble(bucket, key, upload_id, part_numbers, opts \\ []),
    do: backend().assemble(bucket, key, upload_id, part_numbers, opts)

  @spec abort_upload(String.t(), String.t(), String.t(), keyword()) :: :ok | {:error, term()}
  def abort_upload(bucket, key, upload_id, opts \\ []),
    do: backend().abort_upload(bucket, key, upload_id, opts)
```

**验证**：
```powershell
mix compile --warnings-as-errors
```
期望：编译会报 `Maxio.Storage.FS` **未实现新回调**的 warning（@behaviour 缺回调）——预期，下个任务补。先确认无语法错（可暂时容忍该 warning，下任务消除）。

### Task M2-4.2 — FS parts 失败测试（TDD）

**Files:** Create `test/maxio/storage/fs_parts_test.exs`

part 字节落在 `<data_dir>/.uploads/<bucket>/<upload_id>/<part_number>.part`；assemble 按 part 升序拼到对象路径 `<data_dir>/<bucket>/<key>`；abort 删整个 upload 临时目录。

```elixir
defmodule Maxio.Storage.FSPartsTest do
  use ExUnit.Case, async: true

  alias Maxio.Storage.FS

  setup do
    dir = Path.join(System.tmp_dir!(), "maxio_fs_parts_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    {:ok, dir: dir}
  end

  defp opts(dir), do: [data_dir: dir]

  test "put_part 流式写入并返回 size/etag(MD5 hex 无引号)/md5_raw(16字节)", %{dir: dir} do
    :ok = FS.put_bucket("b", opts(dir))
    {:ok, r} = FS.put_part("b", "k", "uid1", 1, ["hel", "lo"], opts(dir))
    assert r.size == 5
    assert r.etag == (:crypto.hash(:md5, "hello") |> Base.encode16(case: :lower))
    assert r.md5_raw == :crypto.hash(:md5, "hello")
    assert byte_size(r.md5_raw) == 16
    refute String.contains?(r.etag, "\"")
  end

  test "get_part_stream 读回 part 字节", %{dir: dir} do
    :ok = FS.put_bucket("b", opts(dir))
    {:ok, _} = FS.put_part("b", "k", "uid1", 2, ["world"], opts(dir))
    {:ok, stream} = FS.get_part_stream("b", "k", "uid1", 2, opts(dir))
    assert IO.iodata_to_binary(Enum.to_list(stream)) == "world"
  end

  test "assemble 按 part number 升序拼接成最终对象", %{dir: dir} do
    :ok = FS.put_bucket("b", opts(dir))
    {:ok, _} = FS.put_part("b", "big", "uid2", 2, ["DEF"], opts(dir))
    {:ok, _} = FS.put_part("b", "big", "uid2", 1, ["ABC"], opts(dir))
    {:ok, %{size: 6}} = FS.assemble("b", "big", "uid2", [1, 2], opts(dir))
    {:ok, stream} = FS.get("b", "big", nil, opts(dir))
    assert IO.iodata_to_binary(Enum.to_list(stream)) == "ABCDEF"
  end

  test "abort_upload 删除该 upload 所有 part 字节（幂等）", %{dir: dir} do
    :ok = FS.put_bucket("b", opts(dir))
    {:ok, _} = FS.put_part("b", "k", "uid3", 1, ["x"], opts(dir))
    assert :ok = FS.abort_upload("b", "k", "uid3", opts(dir))
    assert {:error, :enoent} = FS.get_part_stream("b", "k", "uid3", 1, opts(dir))
    assert :ok = FS.abort_upload("b", "k", "uid3", opts(dir))
  end
end
```

1. 跑确认红：
   ```powershell
   mix test test/maxio/storage/fs_parts_test.exs
   ```

### Task M2-4.3 — FS 实现 parts 回调（使测试通过 + 消除 behaviour warning）

**Files:** Modify `lib/maxio/storage/fs.ex`

在 `Maxio.Storage.FS` 加 4 个新回调实现 + 私有路径辅助（part 临时目录 `.uploads`）。在既有公开回调之后追加：
```elixir
  @impl true
  def put_part(bucket, key, upload_id, part_number, chunks, opts \\ []),
    do: do_put_part(bucket, key, upload_id, part_number, chunks, opts)

  @impl true
  def get_part_stream(bucket, key, upload_id, part_number, opts \\ []),
    do: do_get_part_stream(bucket, key, upload_id, part_number, opts)

  @impl true
  def assemble(bucket, key, upload_id, part_numbers, opts \\ []),
    do: do_assemble(bucket, key, upload_id, part_numbers, opts)

  @impl true
  def abort_upload(bucket, key, upload_id, opts \\ []),
    do: do_abort_upload(bucket, key, upload_id, opts)

  defp do_put_part(bucket, key, upload_id, part_number, chunks, opts) do
    with {:ok, _obj} <- object_path(bucket, key, opts) do
      path = part_path(bucket, upload_id, part_number, opts)
      File.mkdir_p!(Path.dirname(path))
      {:ok, fd} = File.open(path, [:write, :binary, :raw])

      try do
        ctx0 = :crypto.hash_init(:md5)

        {ctx, size} =
          Enum.reduce(chunks, {ctx0, 0}, fn chunk, {ctx, acc} ->
            :ok = IO.binwrite(fd, chunk)
            {:crypto.hash_update(ctx, chunk), acc + byte_size(chunk)}
          end)

        md5_raw = :crypto.hash_final(ctx)
        etag = Base.encode16(md5_raw, case: :lower)
        {:ok, %{size: size, etag: etag, md5_raw: md5_raw}}
      after
        File.close(fd)
      end
    end
  end

  defp do_get_part_stream(bucket, key, upload_id, part_number, opts) do
    with {:ok, _obj} <- object_path(bucket, key, opts) do
      path = part_path(bucket, upload_id, part_number, opts)

      case File.stat(path) do
        {:ok, %File.Stat{size: total}} -> {:ok, stream_file(path, nil, total)}
        {:error, :enoent} -> {:error, :enoent}
      end
    end
  end

  defp do_assemble(bucket, key, upload_id, part_numbers, opts) do
    with {:ok, obj_path} <- object_path(bucket, key, opts) do
      File.mkdir_p!(Path.dirname(obj_path))
      {:ok, out} = File.open(obj_path, [:write, :binary, :raw])

      try do
        size =
          Enum.reduce(part_numbers, 0, fn pn, acc ->
            path = part_path(bucket, upload_id, pn, opts)
            {:ok, in_fd} = :file.open(String.to_charlist(path), [:read, :binary, :raw])

            try do
              acc + copy_fd(in_fd, out, 0)
            after
              :file.close(in_fd)
            end
          end)

        {:ok, %{size: size}}
      after
        File.close(out)
      end
    end
  end

  defp do_abort_upload(bucket, upload_id, opts) when is_list(opts) do
    # 兼容 4 元/5 元：本实现以 (bucket, key, upload_id, opts) 为准，见下方 do_abort_upload/4
    :ok
  end

  defp do_abort_upload(bucket, _key, upload_id, opts) do
    dir = upload_dir(bucket, upload_id, opts)
    _ = File.rm_rf(dir)
    :ok
  end

  # 1MB 分块把 in_fd 全量拷到 out，返回拷贝字节数。
  defp copy_fd(in_fd, out, acc) do
    case :file.read(in_fd, @chunk_size) do
      {:ok, data} ->
        :ok = IO.binwrite(out, data)
        copy_fd(in_fd, out, acc + byte_size(data))

      :eof ->
        acc

      {:error, _} ->
        acc
    end
  end

  defp upload_dir(bucket, upload_id, opts) do
    Path.join([data_dir(opts), ".uploads", bucket, upload_id])
  end

  defp part_path(bucket, upload_id, part_number, opts) do
    Path.join(upload_dir(bucket, upload_id, opts), "#{part_number}.part")
  end
```
> **修正 abort 的 arity**：删除上面误写的 `do_abort_upload/3`，只保留 `do_abort_upload/4`。即公开 `abort_upload(bucket, key, upload_id, opts)` 转发 `do_abort_upload(bucket, key, upload_id, opts)`，私有实现签名为 `defp do_abort_upload(bucket, _key, upload_id, opts)`。（上面 `do_abort_upload(bucket, upload_id, opts)` 那段是错误，executor 不要写它。）

最终正确的私有 abort 实现仅此一处：
```elixir
  defp do_abort_upload(bucket, _key, upload_id, opts) do
    dir = upload_dir(bucket, upload_id, opts)
    _ = File.rm_rf(dir)
    :ok
  end
```

1. 跑确认绿：
   ```powershell
   mix test test/maxio/storage/fs_parts_test.exs test/maxio/storage/fs_test.exs
   ```
   期望：parts 测试 + 既有 FS 测试全绿；`mix compile --warnings-as-errors` 零警告（behaviour 回调齐全）。

**Commit**：
```powershell
git add -A
git commit -m "feat(storage): Backend parts callbacks + FS impl (put_part/get_part_stream/assemble/abort_upload)" -m "Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

### Task M2-4.4 — 迁移：multipart_uploads + multipart_parts 表（中文 COMMENT）

**Files:** Create `priv/repo/migrations/<timestamp>_create_multipart_uploads.exs`、`priv/repo/migrations/<timestamp>_create_multipart_parts.exs`

1. 生成两个迁移：
   ```powershell
   mix ecto.gen.migration create_multipart_uploads
   mix ecto.gen.migration create_multipart_parts
   ```

`create_multipart_uploads`：
```elixir
defmodule Maxio.Repo.Migrations.CreateMultipartUploads do
  use Ecto.Migration

  def change do
    create table(:multipart_uploads, primary_key: false,
             comment: "S3 分段上传会话：CreateMultipartUpload 建一行，Complete/Abort 后删除；part 字节归存储后端") do
      add :id, :binary_id, primary_key: true, comment: "分段上传主键（UUID）"
      add :upload_id, :string, null: false, comment: "对客户端暴露的 UploadId（S3 全局应答；本系统用 UUID 串）"
      add :bucket_name, :string, null: false, comment: "目标桶名（与 key 一起定位最终对象）"
      add :key, :string, null: false, comment: "目标对象键（Complete 后写入此 key）"
      add :content_type, :string, null: false, default: "binary/octet-stream", comment: "最终对象 MIME（CreateMultipartUpload 的 Content-Type）"
      add :storage_class, :string, null: false, default: "STANDARD", comment: "存储类别（S3 兼容，MVP 恒 STANDARD）"
      add :owner, :string, null: false, comment: "发起者 principal（M2 恒为 root 的 arn）"
      add :metadata, :map, null: false, default: %{}, comment: "用户自定义元数据（x-amz-meta-*，Complete 时随对象落库）"

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:multipart_uploads, [:upload_id],
             comment: "UploadId 唯一索引（UploadPart/Complete/Abort/ListParts 按此定位会话）")

    create index(:multipart_uploads, [:bucket_name, :key],
             comment: "按桶名 + key 列举进行中分段上传索引（ListMultipartUploads prefix/分页）")
  end
end
```

`create_multipart_parts`：
```elixir
defmodule Maxio.Repo.Migrations.CreateMultipartParts do
  use Ecto.Migration

  def change do
    create table(:multipart_parts, primary_key: false,
             comment: "分段上传的已上传分块元数据：每个 (upload, part_number) 一行；分块字节归存储后端，本表只存元信息") do
      add :id, :binary_id, primary_key: true, comment: "分块元数据主键（UUID）"
      add :upload_id, references(:multipart_uploads, column: :id, type: :binary_id, on_delete: :delete_all),
        null: false, comment: "所属分段上传会话外键（删会话级联删分块元数据）"
      add :part_number, :integer, null: false, comment: "分块序号（1..10000，Complete 时按此升序组装）"
      add :etag, :string, null: false, comment: "分块 ETag：该 part 字节的 MD5 hex（本列不含引号，渲染时加引号）"
      add :size, :bigint, null: false, default: 0, comment: "分块字节大小（Complete 校验非末块 ≥ 5 MiB 用）"

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:multipart_parts, [:upload_id, :part_number],
             comment: "会话内分块序号唯一索引（同 part_number 重传走 upsert 覆盖）")
  end
end
```

**验证**：
```powershell
mix ecto.migrate
docker exec maxio-db psql -U postgres -d maxio_dev -c "\d+ multipart_uploads"
docker exec maxio-db psql -U postgres -d maxio_dev -c "\d+ multipart_parts"
```
期望：迁移成功；`\d+` 显示各列中文注释、索引带注释、外键到 multipart_uploads。

**Commit**：
```powershell
git add -A
git commit -m "feat(meta): migrations for multipart_uploads + multipart_parts (Chinese COMMENTs)" -m "Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

### Task M2-4.5 — Upload/Part schema + Maxio.Multipart 上下文 + ETag（TDD）

**Files:** Create `lib/maxio/multipart/upload.ex`、`lib/maxio/multipart/part.ex`、`lib/maxio/multipart.ex`、`test/maxio/multipart_test.exs`

先写 schema 与上下文，再写测试（含 multipart ETag KNOWN-ANSWER + Complete 各类错误）。

Create `lib/maxio/multipart/upload.ex`：
```elixir
defmodule Maxio.Multipart.Upload do
  @moduledoc "分段上传会话 schema（part 字节归存储后端，本表只存会话元信息）。"
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "multipart_uploads" do
    field :upload_id, :string
    field :bucket_name, :string
    field :key, :string
    field :content_type, :string, default: "binary/octet-stream"
    field :storage_class, :string, default: "STANDARD"
    field :owner, :string
    field :metadata, :map, default: %{}

    has_many :parts, Maxio.Multipart.Part, foreign_key: :upload_id, references: :id

    timestamps(type: :utc_datetime_usec)
  end

  @required [:upload_id, :bucket_name, :key, :owner]
  @optional [:content_type, :storage_class, :metadata]

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(upload, attrs) do
    upload
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> unique_constraint(:upload_id, name: :multipart_uploads_upload_id_index)
  end
end
```

Create `lib/maxio/multipart/part.ex`：
```elixir
defmodule Maxio.Multipart.Part do
  @moduledoc "分段上传分块元数据 schema（分块字节归存储后端，本表只存元信息）。"
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "multipart_parts" do
    field :part_number, :integer
    field :etag, :string
    field :size, :integer, default: 0

    belongs_to :upload, Maxio.Multipart.Upload, foreign_key: :upload_id, references: :id

    timestamps(type: :utc_datetime_usec)
  end

  @required [:upload_id, :part_number, :etag, :size]

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(part, attrs) do
    part
    |> cast(attrs, @required)
    |> validate_required(@required)
    |> validate_inclusion(:part_number, 1..10_000)
    |> unique_constraint([:upload_id, :part_number], name: :multipart_parts_upload_id_part_number_index)
  end
end
```

Create `lib/maxio/multipart.ex`：
```elixir
defmodule Maxio.Multipart do
  @moduledoc """
  分段上传元数据上下文：initiate/get/put_part(元数据)/list_parts/list_uploads/complete/abort
  + multipart ETag 算法。分块字节走 Maxio.Storage（FS parts 回调），本上下文管会话与分块元数据
  及 Complete 时的校验（InvalidPart/InvalidPartOrder/EntityTooSmall/NoSuchUpload，铁律 3）。
  """
  import Ecto.Query
  alias Maxio.Repo
  alias Maxio.Multipart.{Upload, Part}

  @default_min_part_size 5_242_880

  @doc "发起分段上传：生成 UploadId（UUID hex），落会话元数据。"
  @spec initiate(String.t(), String.t(), map()) :: {:ok, Upload.t()} | {:error, Ecto.Changeset.t()}
  def initiate(bucket_name, key, attrs \\ %{}) do
    upload_id = generate_upload_id()

    base = %{
      upload_id: upload_id,
      bucket_name: bucket_name,
      key: key,
      content_type: Map.get(attrs, :content_type, "binary/octet-stream"),
      storage_class: Map.get(attrs, :storage_class, "STANDARD"),
      owner: Map.get(attrs, :owner, "arn:aws:iam:::root"),
      metadata: Map.get(attrs, :metadata, %{})
    }

    %Upload{} |> Upload.changeset(base) |> Repo.insert()
  end

  @doc "按 (bucket, key, upload_id) 取会话。"
  @spec get_upload(String.t(), String.t(), String.t()) :: {:ok, Upload.t()} | {:error, :not_found}
  def get_upload(bucket_name, key, upload_id) do
    case Repo.get_by(Upload, bucket_name: bucket_name, key: key, upload_id: upload_id) do
      nil -> {:error, :not_found}
      upload -> {:ok, upload}
    end
  end

  @doc "写入/覆盖一个 part 的元数据（按 (upload_id, part_number) upsert）。"
  @spec put_part(Upload.t(), pos_integer(), %{etag: String.t(), size: non_neg_integer()}) ::
          {:ok, Part.t()} | {:error, Ecto.Changeset.t()}
  def put_part(%Upload{id: uid}, part_number, %{etag: etag, size: size}) do
    %Part{}
    |> Part.changeset(%{upload_id: uid, part_number: part_number, etag: etag, size: size})
    |> Repo.insert(
      on_conflict: {:replace, [:etag, :size, :updated_at]},
      conflict_target: [:upload_id, :part_number]
    )
  end

  @doc """
  列出会话已上传 part（升序）。opts: :max_parts(默认1000), :part_number_marker(仅列更大的)。
  返回 %{parts, is_truncated, next_part_number_marker}。
  """
  @spec list_parts(Upload.t(), map()) :: %{parts: [Part.t()], is_truncated: boolean(), next_part_number_marker: pos_integer() | nil}
  def list_parts(%Upload{id: uid}, opts \\ %{}) do
    max_parts = Map.get(opts, :max_parts, 1000)
    marker = Map.get(opts, :part_number_marker, 0) || 0

    query =
      from p in Part,
        where: p.upload_id == ^uid and p.part_number > ^marker,
        order_by: [asc: p.part_number],
        limit: ^(max_parts + 1)

    all = Repo.all(query)
    truncated = length(all) > max_parts
    parts = Enum.take(all, max_parts)

    next = if truncated, do: List.last(parts).part_number, else: nil
    %{parts: parts, is_truncated: truncated, next_part_number_marker: next}
  end

  @doc """
  列出桶内进行中分段上传（按 key 升序、再按 initiated 升序）。
  opts: :prefix, :delimiter, :max_uploads(默认1000), :key_marker, :upload_id_marker。
  返回 %{uploads, common_prefixes, is_truncated, next_key_marker, next_upload_id_marker}。
  """
  @spec list_uploads(String.t(), map()) :: map()
  def list_uploads(bucket_name, opts \\ %{}) do
    prefix = Map.get(opts, :prefix, "") || ""
    delimiter = Map.get(opts, :delimiter)
    max_uploads = Map.get(opts, :max_uploads, 1000)
    key_marker = Map.get(opts, :key_marker)

    base =
      from u in Upload,
        where: u.bucket_name == ^bucket_name,
        order_by: [asc: u.key, asc: u.inserted_at]

    base = if prefix != "", do: where(base, [u], like(u.key, ^(escape_like(prefix) <> "%"))), else: base
    base = if key_marker, do: where(base, [u], u.key > ^key_marker), else: base

    candidates = Repo.all(base)
    {uploads, common_prefixes, truncated, next_key} = collapse_uploads(candidates, prefix, delimiter, max_uploads)

    %{
      uploads: uploads,
      common_prefixes: common_prefixes,
      is_truncated: truncated,
      next_key_marker: if(truncated, do: next_key, else: nil),
      next_upload_id_marker: if(truncated, do: (List.last(uploads) || %{}) |> Map.get(:upload_id), else: nil)
    }
  end

  @doc """
  完成分段上传：按客户端给的 requested_parts（[%{part_number, etag}]，须升序）校验后组装。
  返回 {:ok, %{etag, size}} | {:error, reason}，reason ∈
  :no_such_upload | :invalid_part | :invalid_part_order | :entity_too_small | :no_parts。
  opts: :min_part_size（默认 5_242_880；测试可注入小值）。
  """
  @spec complete(Upload.t(), [%{part_number: pos_integer(), etag: String.t()}], keyword()) ::
          {:ok, %{etag: String.t(), size: non_neg_integer()}} | {:error, atom()}
  def complete(%Upload{} = upload, requested_parts, opts \\ []) do
    min_part_size = Keyword.get(opts, :min_part_size, min_part_size())
    stored = list_all_parts(upload) |> Map.new(fn p -> {p.part_number, p} end)

    with :ok <- ensure_nonempty(requested_parts),
         :ok <- ensure_ascending(requested_parts),
         {:ok, ordered} <- match_parts(requested_parts, stored),
         :ok <- ensure_min_size(ordered, min_part_size) do
      part_numbers = Enum.map(ordered, & &1.part_number)
      md5_raws = Enum.map(ordered, fn p -> Base.decode16!(p.etag, case: :mixed) end)
      etag = multipart_etag(md5_raws)

      case Maxio.Storage.assemble(upload.bucket_name, upload.key, upload.upload_id, part_numbers) do
        {:ok, %{size: size}} ->
          _ = Maxio.Storage.abort_upload(upload.bucket_name, upload.key, upload.upload_id)
          {:ok, %{etag: etag, size: size}}

        {:error, _} = err ->
          err
      end
    end
  end

  @doc "中止分段上传：删会话（级联删 part 元数据）+ 清理 part 字节。幂等。"
  @spec abort(Upload.t()) :: :ok
  def abort(%Upload{} = upload) do
    _ = Maxio.Storage.abort_upload(upload.bucket_name, upload.key, upload.upload_id)
    Repo.delete_all(from u in Upload, where: u.id == ^upload.id)
    :ok
  end

  @doc """
  multipart ETag = hex(MD5(concat(part 的 16 字节原始 MD5...)))-N（无引号）。
  """
  @spec multipart_etag([binary()]) :: String.t()
  def multipart_etag(part_md5_raws) when is_list(part_md5_raws) do
    n = length(part_md5_raws)
    concat = IO.iodata_to_binary(part_md5_raws)
    digest = :crypto.hash(:md5, concat) |> Base.encode16(case: :lower)
    "#{digest}-#{n}"
  end

  # ── 内部 ──
  defp list_all_parts(%Upload{id: uid}) do
    Repo.all(from p in Part, where: p.upload_id == ^uid, order_by: [asc: p.part_number])
  end

  defp ensure_nonempty([]), do: {:error, :no_parts}
  defp ensure_nonempty(_), do: :ok

  defp ensure_ascending(parts) do
    nums = Enum.map(parts, & &1.part_number)
    if nums == Enum.sort(nums) and length(Enum.uniq(nums)) == length(nums), do: :ok, else: {:error, :invalid_part_order}
  end

  # 把客户端请求 part 与存储 part 对齐：每个请求 part 必须存在且 ETag 匹配（规范化去引号比较）。
  defp match_parts(requested, stored) do
    Enum.reduce_while(requested, {:ok, []}, fn req, {:ok, acc} ->
      case Map.get(stored, req.part_number) do
        nil ->
          {:halt, {:error, :invalid_part}}

        %Part{} = p ->
          if normalize_etag(p.etag) == normalize_etag(req.etag) do
            {:cont, {:ok, [p | acc]}}
          else
            {:halt, {:error, :invalid_part}}
          end
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      err -> err
    end
  end

  # 非末 part 必须 ≥ min_part_size（末 part 任意）。
  defp ensure_min_size(ordered, min_part_size) do
    non_last = Enum.drop(ordered, -1)

    if Enum.all?(non_last, fn p -> p.size >= min_part_size end) do
      :ok
    else
      {:error, :entity_too_small}
    end
  end

  defp normalize_etag(etag), do: etag |> to_string() |> String.trim("\"") |> String.downcase()

  defp generate_upload_id do
    :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
  end

  defp escape_like(str) do
    str |> String.replace("\\", "\\\\") |> String.replace("%", "\\%") |> String.replace("_", "\\_")
  end

  defp min_part_size do
    Application.get_env(:maxio, :multipart_min_part_size, @default_min_part_size)
  end

  # ListMultipartUploads 的 delimiter 折叠（与 Objects.list_objects_v2 同构）。
  defp collapse_uploads(candidates, prefix, delimiter, max) do
    do_collapse_uploads(candidates, prefix, delimiter, max, [], MapSet.new(), [])
  end

  defp do_collapse_uploads([], _prefix, _delim, _max, ups, _seen, cps),
    do: {Enum.reverse(ups), Enum.reverse(cps), false, nil}

  defp do_collapse_uploads([u | rest], prefix, delimiter, max, ups, seen, cps) do
    count = length(ups) + MapSet.size(seen)

    cond do
      count >= max ->
        last_key = previous_key(ups, cps)
        {Enum.reverse(ups), Enum.reverse(cps), true, last_key}

      true ->
        case common_prefix_of(u.key, prefix, delimiter) do
          nil ->
            do_collapse_uploads(rest, prefix, delimiter, max, [u | ups], seen, cps)

          cp ->
            if MapSet.member?(seen, cp) do
              do_collapse_uploads(rest, prefix, delimiter, max, ups, seen, cps)
            else
              do_collapse_uploads(rest, prefix, delimiter, max, ups, MapSet.put(seen, cp), [cp | cps])
            end
        end
    end
  end

  defp common_prefix_of(_key, _prefix, nil), do: nil

  defp common_prefix_of(key, prefix, delimiter) do
    rest = String.replace_prefix(key, prefix, "")

    case :binary.match(rest, delimiter) do
      {pos, len} -> prefix <> binary_part(rest, 0, pos + len)
      :nomatch -> nil
    end
  end

  defp previous_key([u | _], _cps), do: u.key
  defp previous_key([], [cp | _]), do: cp
  defp previous_key([], []), do: nil
end
```

Create `test/maxio/multipart_test.exs`：
```elixir
defmodule Maxio.MultipartTest do
  use Maxio.DataCase, async: true

  alias Maxio.{Buckets, Multipart}

  setup do
    {:ok, _} = Buckets.create("mp-bucket", "arn:aws:iam:::root")
    :ok
  end

  describe "multipart_etag/1（KNOWN-ANSWER）" do
    test "= hex(MD5(concat raw MD5s))-N" do
      m1 = :crypto.hash(:md5, "A")
      m2 = :crypto.hash(:md5, "B")
      expected =
        (:crypto.hash(:md5, m1 <> m2) |> Base.encode16(case: :lower)) <> "-2"

      assert Multipart.multipart_etag([m1, m2]) == expected
    end
  end

  describe "initiate/get_upload/put_part/complete（注入 min_part_size: 1）" do
    test "完整闭环：发起→传两块→完成，返回 multipart ETag 与总大小" do
      {:ok, up} = Multipart.initiate("mp-bucket", "obj", %{owner: "arn:aws:iam:::root"})

      {:ok, r1} = Maxio.Storage.put_part("mp-bucket", "obj", up.upload_id, 1, ["AAAAA"])
      {:ok, r2} = Maxio.Storage.put_part("mp-bucket", "obj", up.upload_id, 2, ["BB"])
      {:ok, _} = Multipart.put_part(up, 1, %{etag: r1.etag, size: r1.size})
      {:ok, _} = Multipart.put_part(up, 2, %{etag: r2.etag, size: r2.size})

      requested = [%{part_number: 1, etag: "\"#{r1.etag}\""}, %{part_number: 2, etag: "\"#{r2.etag}\""}]
      {:ok, %{etag: etag, size: size}} = Multipart.complete(up, requested, min_part_size: 1)

      assert size == 7
      assert String.ends_with?(etag, "-2")
      assert {:ok, stream} = Maxio.Storage.get("mp-bucket", "obj", nil)
      assert IO.iodata_to_binary(Enum.to_list(stream)) == "AAAAABB"
    end

    test "缺失 part → :invalid_part" do
      {:ok, up} = Multipart.initiate("mp-bucket", "o2", %{owner: "arn:aws:iam:::root"})
      {:ok, r1} = Maxio.Storage.put_part("mp-bucket", "o2", up.upload_id, 1, ["X"])
      {:ok, _} = Multipart.put_part(up, 1, %{etag: r1.etag, size: r1.size})

      requested = [%{part_number: 1, etag: "\"#{r1.etag}\""}, %{part_number: 2, etag: "\"deadbeef\""}]
      assert {:error, :invalid_part} = Multipart.complete(up, requested, min_part_size: 1)
    end

    test "乱序 part → :invalid_part_order" do
      {:ok, up} = Multipart.initiate("mp-bucket", "o3", %{owner: "arn:aws:iam:::root"})
      {:ok, r1} = Maxio.Storage.put_part("mp-bucket", "o3", up.upload_id, 1, ["X"])
      {:ok, r2} = Maxio.Storage.put_part("mp-bucket", "o3", up.upload_id, 2, ["Y"])
      {:ok, _} = Multipart.put_part(up, 1, %{etag: r1.etag, size: r1.size})
      {:ok, _} = Multipart.put_part(up, 2, %{etag: r2.etag, size: r2.size})

      requested = [%{part_number: 2, etag: "\"#{r2.etag}\""}, %{part_number: 1, etag: "\"#{r1.etag}\""}]
      assert {:error, :invalid_part_order} = Multipart.complete(up, requested, min_part_size: 1)
    end

    test "非末 part 小于 min_part_size → :entity_too_small" do
      {:ok, up} = Multipart.initiate("mp-bucket", "o4", %{owner: "arn:aws:iam:::root"})
      {:ok, r1} = Maxio.Storage.put_part("mp-bucket", "o4", up.upload_id, 1, ["tiny"])
      {:ok, r2} = Maxio.Storage.put_part("mp-bucket", "o4", up.upload_id, 2, ["last"])
      {:ok, _} = Multipart.put_part(up, 1, %{etag: r1.etag, size: r1.size})
      {:ok, _} = Multipart.put_part(up, 2, %{etag: r2.etag, size: r2.size})

      requested = [%{part_number: 1, etag: "\"#{r1.etag}\""}, %{part_number: 2, etag: "\"#{r2.etag}\""}]
      assert {:error, :entity_too_small} = Multipart.complete(up, requested, min_part_size: 5_242_880)
    end

    test "abort 删会话且 get_upload 报 not_found" do
      {:ok, up} = Multipart.initiate("mp-bucket", "o5", %{owner: "arn:aws:iam:::root"})
      assert :ok = Multipart.abort(up)
      assert {:error, :not_found} = Multipart.get_upload("mp-bucket", "o5", up.upload_id)
    end

    test "list_parts 升序 + part_number_marker 过滤" do
      {:ok, up} = Multipart.initiate("mp-bucket", "o6", %{owner: "arn:aws:iam:::root"})
      for pn <- [1, 2, 3], do: Multipart.put_part(up, pn, %{etag: "e#{pn}", size: pn})

      res = Multipart.list_parts(up, %{part_number_marker: 1})
      assert Enum.map(res.parts, & &1.part_number) == [2, 3]
    end
  end
end
```

1. 跑确认绿：
   ```powershell
   mix test test/maxio/multipart_test.exs
   ```
   期望：全绿（含 multipart ETag KNOWN-ANSWER + Complete 各错误码）。

**Commit**：
```powershell
git add -A
git commit -m "feat(multipart): Upload/Part schema + Maxio.Multipart context + multipart ETag with tests" -m "Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

### 单元 M2-4 验收

```powershell
$env:Path = 'C:\Users\dyz\Documents\dev\usr\Elixir\bin;' + $env:Path
$env:ERL_FLAGS = "-kernel standard_io_encoding unicode"
mix compile --warnings-as-errors
mix test test/maxio/storage/fs_parts_test.exs test/maxio/multipart_test.exs
```
期望：零警告；全绿。证明：FS parts 流式写/读/组装/清理；multipart ETag 算法正确；Complete 校验 InvalidPart/InvalidPartOrder/EntityTooSmall/no_parts；list_parts 分页。

---

## 单元 M2-5 — Multipart：入站 SAX 解析器 + 出站 views + Handlers + Dispatcher 接线 + 自签 e2e

**目标**：把 M2-4 的上下文接进 S3 管线，对外暴露 6 个 multipart 操作。①CompleteMultipartUpload 请求体 SAX 解析器（saxy，带上限整读）；②4 个出站 view（InitiateMultipartUpload/CompleteMultipartUpload/ListParts/ListMultipartUploads）；③`Maxio.S3.Handlers.Multipart`；④`Dispatcher` 把 `uploads`/`uploadid`/`partnumber` 子资源解析成对应 action（从 M1 的 `:not_implemented` 升级）；⑤`Maxio.S3.Handlers.dispatch/2` 接线；⑥自签 e2e（发起→传两块→完成→GET 取回；Abort；ListParts；ListMultipartUploads）。

**Dispatch 规则（已核验，bake in）**：
| 操作 | level | method | 子资源/条件 |
|---|---|---|---|
| CreateMultipartUpload | object | POST | query 含 `uploads` |
| UploadPart | object | PUT | query 含 `partnumber` 且含 `uploadid` |
| CompleteMultipartUpload | object | POST | query 含 `uploadid`（无 `uploads`） |
| AbortMultipartUpload | object | DELETE | query 含 `uploadid` |
| ListParts | object | GET | query 含 `uploadid` |
| ListMultipartUploads | bucket | GET | query 含 `uploads` |

> query key 已小写（Dispatch plug 把 keys downcase）。AWS 真实 query 名是 `uploadId`/`partNumber`，小写后为 `uploadid`/`partnumber`。

### Task M2-5.1 — CompleteMultipartUpload 请求 SAX 解析器（TDD）

**Files:** Create `lib/maxio/s3/request_parsers/complete_multipart_upload.ex`、`test/maxio/s3/request_parsers/complete_multipart_upload_test.exs`

解析 `<CompleteMultipartUpload><Part><PartNumber>n</PartNumber><ETag>"x"</ETag></Part>...</CompleteMultipartUpload>`，按元素名取值（元素顺序不敏感），返回升序无关的原始顺序 `[%{part_number, etag}]`。畸形 XML / 无 Part → `{:error, :malformed_xml}`（空 Part 列表也算 malformed，对齐 S3 400）。

先写测试：
```elixir
defmodule Maxio.S3.RequestParsers.CompleteMultipartUploadTest do
  use ExUnit.Case, async: true

  alias Maxio.S3.RequestParsers.CompleteMultipartUpload, as: P

  test "解析多个 Part（按元素名取值，保留请求顺序）" do
    xml = """
    <?xml version="1.0" encoding="UTF-8"?>
    <CompleteMultipartUpload>
      <Part><PartNumber>1</PartNumber><ETag>"a54357aff0632cce46d942af68356b38"</ETag></Part>
      <Part><PartNumber>2</PartNumber><ETag>"0c78aef83f66abc1fa1e8477f296d394"</ETag></Part>
    </CompleteMultipartUpload>
    """

    assert {:ok, parts} = P.parse(xml)
    assert parts == [
             %{part_number: 1, etag: "\"a54357aff0632cce46d942af68356b38\""},
             %{part_number: 2, etag: "\"0c78aef83f66abc1fa1e8477f296d394\""}
           ]
  end

  test "ETag 在前 PartNumber 在后也能解析（元素顺序不敏感）" do
    xml = "<CompleteMultipartUpload><Part><ETag>\"x\"</ETag><PartNumber>3</PartNumber></Part></CompleteMultipartUpload>"
    assert {:ok, [%{part_number: 3, etag: "\"x\""}]} = P.parse(xml)
  end

  test "带命名空间也能解析" do
    xml = ~s(<CompleteMultipartUpload xmlns="http://s3.amazonaws.com/doc/2006-03-01/"><Part><PartNumber>1</PartNumber><ETag>"y"</ETag></Part></CompleteMultipartUpload>)
    assert {:ok, [%{part_number: 1, etag: "\"y\""}]} = P.parse(xml)
  end

  test "无 Part → :malformed_xml" do
    assert {:error, :malformed_xml} = P.parse("<CompleteMultipartUpload></CompleteMultipartUpload>")
  end

  test "畸形 XML → :malformed_xml" do
    assert {:error, :malformed_xml} = P.parse("<CompleteMultipartUpload><Part>")
    assert {:error, :malformed_xml} = P.parse("not xml at all <<<")
  end
end
```

1. 跑确认红：
   ```powershell
   mix test test/maxio/s3/request_parsers/complete_multipart_upload_test.exs
   ```

实现 `lib/maxio/s3/request_parsers/complete_multipart_upload.ex`（saxy SAX handler）：
```elixir
defmodule Maxio.S3.RequestParsers.CompleteMultipartUpload do
  @moduledoc """
  CompleteMultipartUpload 请求体 SAX 解析（saxy）。按元素名取值（PartNumber/ETag 顺序不敏感），
  返回 [%{part_number, etag}]（保留请求出现顺序，升序校验交上下文）。畸形/无 Part → :malformed_xml。
  小 XML 走带上限整读后传入（铁律 4：只有小 XML 整读，对象字节绝不整读）。
  """
  @behaviour Saxy.Handler

  @spec parse(binary()) :: {:ok, [%{part_number: pos_integer(), etag: String.t()}]} | {:error, :malformed_xml}
  def parse(xml) when is_binary(xml) do
    case Saxy.parse_string(xml, __MODULE__, %{parts: [], current: nil, text: nil, in: nil}) do
      {:ok, %{parts: []}} -> {:error, :malformed_xml}
      {:ok, %{parts: parts}} -> {:ok, Enum.reverse(parts)}
      {:error, _} -> {:error, :malformed_xml}
    end
  end

  @impl true
  def handle_event(:start_document, _prolog, state), do: {:ok, state}

  @impl true
  def handle_event(:start_element, {name, _attrs}, state) do
    case local_name(name) do
      "Part" -> {:ok, %{state | current: %{part_number: nil, etag: nil}, in: nil}}
      "PartNumber" -> {:ok, %{state | in: :part_number, text: ""}}
      "ETag" -> {:ok, %{state | in: :etag, text: ""}}
      _ -> {:ok, %{state | in: nil}}
    end
  end

  @impl true
  def handle_event(:characters, chars, %{in: nil} = state), do: {:ok, state}

  def handle_event(:characters, chars, %{text: text} = state) when is_binary(text) do
    {:ok, %{state | text: text <> chars}}
  end

  def handle_event(:characters, _chars, state), do: {:ok, state}

  @impl true
  def handle_event(:end_element, name, state) do
    case local_name(name) do
      "PartNumber" ->
        pn = parse_int(state.text)
        {:ok, %{state | current: Map.put(state.current || %{}, :part_number, pn), in: nil, text: nil}}

      "ETag" ->
        {:ok, %{state | current: Map.put(state.current || %{}, :etag, String.trim(state.text || "")), in: nil, text: nil}}

      "Part" ->
        case state.current do
          %{part_number: pn, etag: etag} when is_integer(pn) and is_binary(etag) ->
            {:ok, %{state | parts: [%{part_number: pn, etag: etag} | state.parts], current: nil}}

          _ ->
            # Part 缺字段：视为畸形（让 parse/1 因 parts 仍可能为空而报 malformed，
            # 或这里直接丢弃该 Part；保守起见丢弃，最终若无有效 Part 则 malformed）
            {:ok, %{state | current: nil}}
        end

      _ ->
        {:ok, %{state | in: nil, text: nil}}
    end
  end

  @impl true
  def handle_event(:end_document, _data, state), do: {:ok, state}

  # saxy 可能给 "ns:Local" 形式的名；取本地名。
  defp local_name(name) do
    case String.split(name, ":") do
      [_ns, local] -> local
      [local] -> local
    end
  end

  defp parse_int(nil), do: nil

  defp parse_int(str) do
    case Integer.parse(String.trim(str)) do
      {n, _} -> n
      _ -> nil
    end
  end
end
```
> 注：saxy `parse_string/3` 对畸形 XML 返回 `{:error, _}`，被 `parse/1` 映射 malformed。`handle_event(:characters, _, %{in: nil})` 一行可能触发 unused 变量警告——把 `chars` 改 `_chars`。

2. 跑确认绿：
   ```powershell
   mix test test/maxio/s3/request_parsers/complete_multipart_upload_test.exs
   ```
   期望：全绿。

**Commit**：
```powershell
git add -A
git commit -m "feat(s3): CompleteMultipartUpload request SAX parser (saxy)" -m "Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

### Task M2-5.2 — 出站 views（Initiate / Complete / ListParts / ListMultipartUploads）

**Files:** Create `lib/maxio/s3/views/initiate_multipart_upload.ex`、`lib/maxio/s3/views/complete_multipart_upload.ex`、`lib/maxio/s3/views/list_parts.ex`、`lib/maxio/s3/views/list_multipart_uploads.ex`

全部复用 `Maxio.S3.XML.{encode/1,namespace/0,iso8601/1,quote_etag/1}`，命名空间挂根元素。

`initiate_multipart_upload.ex`：
```elixir
defmodule Maxio.S3.Views.InitiateMultipartUpload do
  @moduledoc "CreateMultipartUpload 响应 XML（InitiateMultipartUploadResult）。"
  import Saxy.XML
  alias Maxio.S3.XML

  @spec render(%{bucket: String.t(), key: String.t(), upload_id: String.t()}) :: iodata()
  def render(%{bucket: bucket, key: key, upload_id: upload_id}) do
    root =
      element("InitiateMultipartUploadResult", [{"xmlns", XML.namespace()}], [
        element("Bucket", [], characters(bucket)),
        element("Key", [], characters(key)),
        element("UploadId", [], characters(upload_id))
      ])

    XML.encode(root)
  end
end
```

`complete_multipart_upload.ex`：
```elixir
defmodule Maxio.S3.Views.CompleteMultipartUpload do
  @moduledoc "CompleteMultipartUpload 响应 XML（CompleteMultipartUploadResult）。Location/Bucket/Key/ETag。"
  import Saxy.XML
  alias Maxio.S3.XML

  @spec render(%{location: String.t(), bucket: String.t(), key: String.t(), etag: String.t()}) :: iodata()
  def render(%{location: location, bucket: bucket, key: key, etag: etag}) do
    root =
      element("CompleteMultipartUploadResult", [{"xmlns", XML.namespace()}], [
        element("Location", [], characters(location)),
        element("Bucket", [], characters(bucket)),
        element("Key", [], characters(key)),
        element("ETag", [], characters(XML.quote_etag(etag)))
      ])

    XML.encode(root)
  end
end
```

`list_parts.ex`：
```elixir
defmodule Maxio.S3.Views.ListParts do
  @moduledoc "ListParts 响应 XML（ListPartsResult）。"
  import Saxy.XML
  alias Maxio.S3.XML

  @spec render(map()) :: iodata()
  def render(data) do
    part_elems =
      Enum.map(data.parts, fn p ->
        element("Part", [], [
          element("PartNumber", [], characters(Integer.to_string(p.part_number))),
          element("LastModified", [], characters(XML.iso8601(p.last_modified))),
          element("ETag", [], characters(XML.quote_etag(p.etag))),
          element("Size", [], characters(Integer.to_string(p.size)))
        ])
      end)

    children =
      [
        element("Bucket", [], characters(data.bucket)),
        element("Key", [], characters(data.key)),
        element("UploadId", [], characters(data.upload_id)),
        element("PartNumberMarker", [], characters(Integer.to_string(data.part_number_marker))),
        element("NextPartNumberMarker", [], characters(Integer.to_string(data.next_part_number_marker || 0))),
        element("MaxParts", [], characters(Integer.to_string(data.max_parts))),
        element("IsTruncated", [], characters(to_string(data.is_truncated))),
        element("Initiator", [], [
          element("ID", [], characters(data.owner_id)),
          element("DisplayName", [], characters(data.owner_display))
        ]),
        element("Owner", [], [
          element("ID", [], characters(data.owner_id)),
          element("DisplayName", [], characters(data.owner_display))
        ]),
        element("StorageClass", [], characters(data.storage_class))
      ] ++ part_elems

    root = element("ListPartsResult", [{"xmlns", XML.namespace()}], children)
    XML.encode(root)
  end
end
```

`list_multipart_uploads.ex`：
```elixir
defmodule Maxio.S3.Views.ListMultipartUploads do
  @moduledoc "ListMultipartUploads 响应 XML（ListMultipartUploadsResult）。"
  import Saxy.XML
  alias Maxio.S3.XML

  @spec render(map()) :: iodata()
  def render(data) do
    upload_elems =
      Enum.map(data.uploads, fn u ->
        element("Upload", [], [
          element("Key", [], characters(u.key)),
          element("UploadId", [], characters(u.upload_id)),
          element("Initiator", [], [
            element("ID", [], characters(data.owner_id)),
            element("DisplayName", [], characters(data.owner_display))
          ]),
          element("Owner", [], [
            element("ID", [], characters(data.owner_id)),
            element("DisplayName", [], characters(data.owner_display))
          ]),
          element("StorageClass", [], characters(u.storage_class)),
          element("Initiated", [], characters(XML.iso8601(u.initiated)))
        ])
      end)

    common =
      Enum.map(data.common_prefixes, fn cp ->
        element("CommonPrefixes", [], [element("Prefix", [], characters(cp))])
      end)

    children =
      [
        element("Bucket", [], characters(data.bucket)),
        element("KeyMarker", [], characters(data.key_marker || "")),
        element("UploadIdMarker", [], characters(data.upload_id_marker || "")),
        element("NextKeyMarker", [], characters(data.next_key_marker || "")),
        element("NextUploadIdMarker", [], characters(data.next_upload_id_marker || "")),
        element("MaxUploads", [], characters(Integer.to_string(data.max_uploads))),
        element("IsTruncated", [], characters(to_string(data.is_truncated))),
        element("Prefix", [], characters(data.prefix || ""))
      ]
      |> maybe_delimiter(data.delimiter)

    root =
      element("ListMultipartUploadsResult", [{"xmlns", XML.namespace()}], children ++ upload_elems ++ common)

    XML.encode(root)
  end

  defp maybe_delimiter(children, nil), do: children
  defp maybe_delimiter(children, ""), do: children
  defp maybe_delimiter(children, d), do: children ++ [element("Delimiter", [], characters(d))]
end
```

**验证**：
```powershell
mix compile --warnings-as-errors
```
期望：零警告。

**Commit**：
```powershell
git add -A
git commit -m "feat(s3): multipart response views (Initiate/Complete/ListParts/ListMultipartUploads)" -m "Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

### Task M2-5.3 — Handlers.Multipart + Dispatcher 接线 + Handlers.dispatch 接线

**Files:** Create `lib/maxio/s3/handlers/multipart.ex`、Modify `lib/maxio/s3/dispatcher.ex`、`lib/maxio/s3/handlers.ex`

`Maxio.S3.Dispatcher.resolve/3`：把 multipart 子资源从 `@m2_subresources`（→ not_implemented）中**移除**并加专用规则。从 `@m2_subresources` 列表里删掉 `uploads`、`uploadid`、`partnumber`（保留其它如 acl/tagging 仍 not_implemented），并在 `resolve/3` 的 cond 里加规则（在 m2_subresource? 之前）：
```elixir
  def resolve(level, method, query_keys) do
    cond do
      multipart_action(level, method, query_keys) != nil ->
        {:ok, multipart_action(level, method, query_keys)}

      level == :bucket and method == "POST" and MapSet.member?(query_keys, "delete") ->
        {:ok, :delete_objects}

      m2_subresource?(query_keys) ->
        {:error, :not_implemented}

      level == :bucket and method == "GET" and MapSet.member?(query_keys, "location") ->
        {:ok, :get_bucket_location}

      true ->
        dispatch(level, method)
    end
  end

  # multipart 子资源分发（nil = 非 multipart）。
  defp multipart_action(:object, "POST", qk) do
    cond do
      MapSet.member?(qk, "uploads") -> :create_multipart_upload
      MapSet.member?(qk, "uploadid") -> :complete_multipart_upload
      true -> nil
    end
  end

  defp multipart_action(:object, "PUT", qk) do
    if MapSet.member?(qk, "partnumber") and MapSet.member?(qk, "uploadid"),
      do: :upload_part,
      else: nil
  end

  defp multipart_action(:object, "DELETE", qk) do
    if MapSet.member?(qk, "uploadid"), do: :abort_multipart_upload, else: nil
  end

  defp multipart_action(:object, "GET", qk) do
    if MapSet.member?(qk, "uploadid"), do: :list_parts, else: nil
  end

  defp multipart_action(:bucket, "GET", qk) do
    if MapSet.member?(qk, "uploads"), do: :list_multipart_uploads, else: nil
  end

  defp multipart_action(_level, _method, _qk), do: nil
```
> 注意：`@m2_subresources` 删掉 `uploads uploadid partnumber delete` 四个（`delete` 因 M2-6 DeleteObjects 也要分发；本任务先加 `:delete_objects` 规则，handler 在 M2-6 实现——故本任务 Dispatcher 已引用 `:delete_objects`，但 `Handlers.dispatch(:delete_objects, ...)` 需在 M2-6 才有；为不在本单元引入未定义 handler，**本任务暂不从 @m2_subresources 删 `delete`、也不加 delete_objects 规则**，把这两行留到 M2-6）。即本任务 `resolve/3` 只加 multipart 规则与从 @m2_subresources 删 `uploads uploadid partnumber`；DeleteObjects 那条规则在 M2-6 加。

修正后的 `@m2_subresources`（删 uploads/uploadid/partnumber，保留 delete 等）：
```elixir
  @m2_subresources ~w(delete acl tagging versioning cors policy lifecycle website
                      versions notification replication encryption object-lock legal-hold retention
                      attributes select torrent restore accelerate analytics inventory metrics
                      ownershipcontrols publicaccessblock requestpayment logging)
```

实现 `lib/maxio/s3/handlers/multipart.ex`：
```elixir
defmodule Maxio.S3.Handlers.Multipart do
  @moduledoc """
  Multipart 级 handler：Create/UploadPart/Complete/Abort/ListParts/ListMultipartUploads。
  会话/分块元数据走 Maxio.Multipart，分块字节走 Maxio.Storage（FS parts）。
  对象 body 绝不整读（UploadPart 流式）；只有 CompleteMultipartUpload 的小 XML 走带上限整读 + SAX。
  """
  import Plug.Conn
  alias Maxio.{Buckets, Multipart, Objects, Storage}
  alias Maxio.S3.{BodyReader, Error, Log, XML}
  alias Maxio.S3.RequestParsers.CompleteMultipartUpload, as: CompleteParser

  alias Maxio.S3.Views.{
    InitiateMultipartUpload,
    CompleteMultipartUpload,
    ListParts,
    ListMultipartUploads
  }

  @owner_id "maxio"
  @owner_display "maxio"
  @complete_xml_limit 1_048_576

  @spec create_multipart_upload(Plug.Conn.t()) :: Plug.Conn.t()
  def create_multipart_upload(conn) do
    bucket = conn.assigns.s3_bucket
    key = conn.assigns.s3_key
    _ = ensure_bucket!(bucket)

    content_type = header(conn, "content-type") || "binary/octet-stream"
    owner = conn.assigns.principal.arn

    {:ok, upload} =
      Multipart.initiate(bucket, key, %{content_type: content_type, owner: owner})

    Log.info("create multipart upload", action: :create_multipart_upload, bucket: bucket, key: key)

    body = InitiateMultipartUpload.render(%{bucket: bucket, key: key, upload_id: upload.upload_id})

    conn
    |> put_resp_content_type("application/xml")
    |> send_resp(200, body)
  end

  @spec upload_part(Plug.Conn.t()) :: Plug.Conn.t()
  def upload_part(conn) do
    bucket = conn.assigns.s3_bucket
    key = conn.assigns.s3_key
    conn = fetch_query_params(conn)
    upload_id = Map.fetch!(conn.query_params, "uploadId")
    part_number = parse_part_number!(Map.fetch!(conn.query_params, "partNumber"))

    upload = upload_or_raise(bucket, key, upload_id)
    chunks = BodyReader.stream(conn, conn.assigns.payload_mode)

    case Storage.put_part(bucket, key, upload_id, part_number, chunks) do
      {:ok, %{size: size, etag: etag}} ->
        {:ok, _} = Multipart.put_part(upload, part_number, %{etag: etag, size: size})

        Log.info("upload part",
          action: :upload_part,
          bucket: bucket,
          key: key,
          size: size
        )

        conn
        |> put_resp_header("etag", XML.quote_etag(etag))
        |> send_resp(200, "")

      {:error, reason} ->
        raise Error.new(:internal_error, message: inspect(reason))
    end
  end

  @spec complete_multipart_upload(Plug.Conn.t()) :: Plug.Conn.t()
  def complete_multipart_upload(conn) do
    bucket = conn.assigns.s3_bucket
    key = conn.assigns.s3_key
    conn = fetch_query_params(conn)
    upload_id = Map.fetch!(conn.query_params, "uploadId")

    upload = upload_or_raise(bucket, key, upload_id)
    xml = read_small_body!(conn)

    requested =
      case CompleteParser.parse(xml) do
        {:ok, parts} -> parts
        {:error, :malformed_xml} -> raise Error.new(:malformed_xml, resource: "/#{bucket}/#{key}")
      end

    case Multipart.complete(upload, requested) do
      {:ok, %{etag: etag, size: size}} ->
        {:ok, _obj} =
          Objects.put_metadata(bucket, key, %{
            size: size,
            etag: etag,
            content_type: upload.content_type,
            storage_class: upload.storage_class
          })

        _ = Multipart.abort(upload)

        Log.info("complete multipart upload",
          action: :complete_multipart_upload,
          bucket: bucket,
          key: key,
          size: size
        )

        body =
          CompleteMultipartUpload.render(%{
            location: "/#{bucket}/#{key}",
            bucket: bucket,
            key: key,
            etag: etag
          })

        conn
        |> put_resp_content_type("application/xml")
        |> send_resp(200, body)

      {:error, reason} ->
        raise complete_error(reason, bucket, key)
    end
  end

  @spec abort_multipart_upload(Plug.Conn.t()) :: Plug.Conn.t()
  def abort_multipart_upload(conn) do
    bucket = conn.assigns.s3_bucket
    key = conn.assigns.s3_key
    conn = fetch_query_params(conn)
    upload_id = Map.fetch!(conn.query_params, "uploadId")

    upload = upload_or_raise(bucket, key, upload_id)
    :ok = Multipart.abort(upload)
    Log.info("abort multipart upload", action: :abort_multipart_upload, bucket: bucket, key: key)
    send_resp(conn, 204, "")
  end

  @spec list_parts(Plug.Conn.t()) :: Plug.Conn.t()
  def list_parts(conn) do
    bucket = conn.assigns.s3_bucket
    key = conn.assigns.s3_key
    conn = fetch_query_params(conn)
    upload_id = Map.fetch!(conn.query_params, "uploadId")
    max_parts = parse_int(Map.get(conn.query_params, "max-parts"), 1000)
    marker = parse_int(Map.get(conn.query_params, "part-number-marker"), 0)

    upload = upload_or_raise(bucket, key, upload_id)
    res = Multipart.list_parts(upload, %{max_parts: max_parts, part_number_marker: marker})

    parts =
      Enum.map(res.parts, fn p ->
        %{part_number: p.part_number, last_modified: p.updated_at, etag: p.etag, size: p.size}
      end)

    body =
      ListParts.render(%{
        bucket: bucket,
        key: key,
        upload_id: upload_id,
        part_number_marker: marker,
        next_part_number_marker: res.next_part_number_marker,
        max_parts: max_parts,
        is_truncated: res.is_truncated,
        parts: parts,
        owner_id: @owner_id,
        owner_display: @owner_display,
        storage_class: upload.storage_class
      })

    conn
    |> put_resp_content_type("application/xml")
    |> send_resp(200, body)
  end

  @spec list_multipart_uploads(Plug.Conn.t()) :: Plug.Conn.t()
  def list_multipart_uploads(conn) do
    bucket = conn.assigns.s3_bucket
    conn = fetch_query_params(conn)
    qp = conn.query_params
    _ = ensure_bucket!(bucket)

    prefix = Map.get(qp, "prefix", "")
    delimiter = Map.get(qp, "delimiter")
    max_uploads = parse_int(Map.get(qp, "max-uploads"), 1000)
    key_marker = Map.get(qp, "key-marker")

    res =
      Multipart.list_uploads(bucket, %{
        prefix: prefix,
        delimiter: delimiter,
        max_uploads: max_uploads,
        key_marker: key_marker
      })

    uploads =
      Enum.map(res.uploads, fn u ->
        %{key: u.key, upload_id: u.upload_id, storage_class: u.storage_class, initiated: u.inserted_at}
      end)

    body =
      ListMultipartUploads.render(%{
        bucket: bucket,
        prefix: prefix,
        delimiter: delimiter,
        key_marker: key_marker,
        upload_id_marker: Map.get(qp, "upload-id-marker"),
        next_key_marker: res.next_key_marker,
        next_upload_id_marker: res.next_upload_id_marker,
        max_uploads: max_uploads,
        is_truncated: res.is_truncated,
        uploads: uploads,
        common_prefixes: res.common_prefixes,
        owner_id: @owner_id,
        owner_display: @owner_display
      })

    conn
    |> put_resp_content_type("application/xml")
    |> send_resp(200, body)
  end

  # ── helpers ──
  defp ensure_bucket!(bucket) do
    case Buckets.lookup(bucket) do
      {:ok, b} -> b
      {:error, :not_found} -> raise Error.new(:no_such_bucket, resource: "/" <> bucket)
    end
  end

  defp upload_or_raise(bucket, key, upload_id) do
    _ = ensure_bucket!(bucket)

    case Multipart.get_upload(bucket, key, upload_id) do
      {:ok, upload} -> upload
      {:error, :not_found} -> raise Error.new(:no_such_upload, resource: "/#{bucket}/#{key}")
    end
  end

  # CompleteMultipartUpload 的小 XML 整读（带上限，铁律 4）。
  defp read_small_body!(conn) do
    case read_body(conn, length: @complete_xml_limit, read_length: @complete_xml_limit) do
      {:ok, body, _conn} -> body
      {:more, _partial, _conn} -> raise Error.new(:entity_too_large, message: "Complete request body too large")
      {:error, _} -> raise Error.new(:malformed_xml)
    end
  end

  defp complete_error(:no_such_upload, b, k), do: Error.new(:no_such_upload, resource: "/#{b}/#{k}")
  defp complete_error(:invalid_part, b, k), do: Error.new(:invalid_part, resource: "/#{b}/#{k}")
  defp complete_error(:invalid_part_order, b, k), do: Error.new(:invalid_part_order, resource: "/#{b}/#{k}")
  defp complete_error(:entity_too_small, b, k), do: Error.new(:entity_too_small, resource: "/#{b}/#{k}")
  defp complete_error(:no_parts, b, k), do: Error.new(:malformed_xml, resource: "/#{b}/#{k}")
  defp complete_error(_other, b, k), do: Error.new(:internal_error, resource: "/#{b}/#{k}")

  defp parse_part_number!(str) do
    case Integer.parse(str) do
      {n, ""} when n >= 1 and n <= 10_000 -> n
      _ -> raise Error.new(:invalid_argument, message: "partNumber must be 1..10000")
    end
  end

  defp parse_int(nil, default), do: default

  defp parse_int(str, default) do
    case Integer.parse(str) do
      {n, ""} when n >= 0 -> n
      _ -> default
    end
  end

  defp header(conn, name), do: conn |> get_req_header(name) |> List.first()
end
```

`lib/maxio/s3/handlers.ex` 增加分发条目（在既有 object 分发之后）：
```elixir
  alias Maxio.S3.Handlers.{Service, Bucket, Object, Multipart}

  # ...既有 dispatch 子句不变...

  def dispatch(:create_multipart_upload, conn), do: Multipart.create_multipart_upload(conn)
  def dispatch(:upload_part, conn), do: Multipart.upload_part(conn)
  def dispatch(:complete_multipart_upload, conn), do: Multipart.complete_multipart_upload(conn)
  def dispatch(:abort_multipart_upload, conn), do: Multipart.abort_multipart_upload(conn)
  def dispatch(:list_parts, conn), do: Multipart.list_parts(conn)
  def dispatch(:list_multipart_uploads, conn), do: Multipart.list_multipart_uploads(conn)
```

**验证**：
```powershell
mix compile --warnings-as-errors
```
期望：零警告。

### Task M2-5.4 — Multipart 端到端集成测试（自签）

**Files:** Create `test/maxio/s3/multipart_integration_test.exs`

新文件（与 integration_test 同款 setup：隔离 data_dir + sandbox）。**关键**：测试需注入 `multipart_min_part_size: 1`（用微型 part），并在 setup 里设/还原。

```elixir
defmodule Maxio.S3.MultipartIntegrationTest do
  use Maxio.DataCase, async: false

  import Plug.Conn
  alias Maxio.Test.SigV4Request
  alias Maxio.S3.Endpoint

  @data_dir Path.join(System.tmp_dir!(), "maxio_mp_int_test")

  setup do
    File.rm_rf(@data_dir)
    File.mkdir_p!(@data_dir)
    prev = Application.get_env(:maxio, :s3)
    Application.put_env(:maxio, :s3, Keyword.put(prev, :data_dir, @data_dir))
    Application.put_env(:maxio, :multipart_min_part_size, 1)

    on_exit(fn ->
      Application.put_env(:maxio, :s3, prev)
      Application.delete_env(:maxio, :multipart_min_part_size)
      File.rm_rf(@data_dir)
    end)

    :ok
  end

  defp call(conn), do: Endpoint.call(conn, Endpoint.init([]))

  # 从 InitiateMultipartUploadResult 抠 UploadId（简单字符串切，无需 XML 解析依赖）
  defp upload_id(xml) do
    [_, rest] = String.split(xml, "<UploadId>")
    [id, _] = String.split(rest, "</UploadId>")
    id
  end

  test "Create→UploadPart x2→Complete→GET 取回完整对象 + multipart ETag(-2)" do
    SigV4Request.signed_conn(:put, "/mpbk") |> call()

    init =
      SigV4Request.signed_conn(:post, "/mpbk/big.bin", query: %{"uploads" => ""})
      |> call()

    assert init.status == 200
    uid = upload_id(init.resp_body)

    p1body = "PART-ONE-DATA"
    p2body = "PART-TWO!"

    up1 =
      SigV4Request.signed_conn(:put, "/mpbk/big.bin",
        query: %{"partNumber" => "1", "uploadId" => uid},
        body: p1body
      )
      |> call()

    assert up1.status == 200
    [etag1] = get_resp_header(up1, "etag")

    up2 =
      SigV4Request.signed_conn(:put, "/mpbk/big.bin",
        query: %{"partNumber" => "2", "uploadId" => uid},
        body: p2body
      )
      |> call()

    assert up2.status == 200
    [etag2] = get_resp_header(up2, "etag")

    complete_xml =
      "<CompleteMultipartUpload>" <>
        "<Part><PartNumber>1</PartNumber><ETag>#{etag1}</ETag></Part>" <>
        "<Part><PartNumber>2</PartNumber><ETag>#{etag2}</ETag></Part>" <>
        "</CompleteMultipartUpload>"

    complete =
      SigV4Request.signed_conn(:post, "/mpbk/big.bin",
        query: %{"uploadId" => uid},
        body: complete_xml
      )
      |> call()

    assert complete.status == 200
    assert complete.resp_body =~ "<ETag>"
    assert complete.resp_body =~ "-2&quot;</ETag>" or complete.resp_body =~ ~s(-2"</ETag>)

    get = SigV4Request.signed_conn(:get, "/mpbk/big.bin") |> call()
    assert get.status == 200
    assert get.resp_body == p1body <> p2body
  end

  test "Complete 引用不存在的 part → 400 InvalidPart" do
    SigV4Request.signed_conn(:put, "/mpbk2") |> call()
    init = SigV4Request.signed_conn(:post, "/mpbk2/o", query: %{"uploads" => ""}) |> call()
    uid = upload_id(init.resp_body)

    SigV4Request.signed_conn(:put, "/mpbk2/o",
      query: %{"partNumber" => "1", "uploadId" => uid},
      body: "x"
    )
    |> call()

    xml =
      "<CompleteMultipartUpload><Part><PartNumber>1</PartNumber><ETag>\"deadbeef\"</ETag></Part></CompleteMultipartUpload>"

    complete =
      SigV4Request.signed_conn(:post, "/mpbk2/o", query: %{"uploadId" => uid}, body: xml) |> call()

    assert complete.status == 400
    assert complete.resp_body =~ "<Code>InvalidPart</Code>"
  end

  test "AbortMultipartUpload → 204；之后 ListParts → 404 NoSuchUpload" do
    SigV4Request.signed_conn(:put, "/mpbk3") |> call()
    init = SigV4Request.signed_conn(:post, "/mpbk3/o", query: %{"uploads" => ""}) |> call()
    uid = upload_id(init.resp_body)

    abort = SigV4Request.signed_conn(:delete, "/mpbk3/o", query: %{"uploadId" => uid}) |> call()
    assert abort.status == 204

    lp = SigV4Request.signed_conn(:get, "/mpbk3/o", query: %{"uploadId" => uid}) |> call()
    assert lp.status == 404
    assert lp.resp_body =~ "<Code>NoSuchUpload</Code>"
  end

  test "ListParts 列出已上传分块" do
    SigV4Request.signed_conn(:put, "/mpbk4") |> call()
    init = SigV4Request.signed_conn(:post, "/mpbk4/o", query: %{"uploads" => ""}) |> call()
    uid = upload_id(init.resp_body)

    SigV4Request.signed_conn(:put, "/mpbk4/o", query: %{"partNumber" => "1", "uploadId" => uid}, body: "aa") |> call()
    SigV4Request.signed_conn(:put, "/mpbk4/o", query: %{"partNumber" => "2", "uploadId" => uid}, body: "bb") |> call()

    lp = SigV4Request.signed_conn(:get, "/mpbk4/o", query: %{"uploadId" => uid}) |> call()
    assert lp.status == 200
    assert lp.resp_body =~ "<PartNumber>1</PartNumber>"
    assert lp.resp_body =~ "<PartNumber>2</PartNumber>"
  end

  test "ListMultipartUploads 列出进行中上传" do
    SigV4Request.signed_conn(:put, "/mpbk5") |> call()
    SigV4Request.signed_conn(:post, "/mpbk5/aaa", query: %{"uploads" => ""}) |> call()
    SigV4Request.signed_conn(:post, "/mpbk5/bbb", query: %{"uploads" => ""}) |> call()

    lmu = SigV4Request.signed_conn(:get, "/mpbk5", query: %{"uploads" => ""}) |> call()
    assert lmu.status == 200
    assert lmu.resp_body =~ "<Key>aaa</Key>"
    assert lmu.resp_body =~ "<Key>bbb</Key>"
  end
end
```
> 注：ETag 渲染 `<ETag>"...-2"</ETag>`（`XML.encode` 把 `&quot;` 还原为字面 `"`，故断言用字面引号 `-2"</ETag>`；保留 `&quot;` 分支只为稳健）。`signed_conn` 已支持 `:query`（URL 编码进 path，参与签名），multipart 操作的 query 子资源天然被签名覆盖。

1. 跑确认绿：
   ```powershell
   mix test test/maxio/s3/multipart_integration_test.exs
   ```
   期望：全绿。

**Commit**：
```powershell
git add -A
git commit -m "feat(s3): multipart handlers + Dispatcher wiring + e2e (Create/UploadPart/Complete/Abort/List)" -m "Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

### 单元 M2-5 验收

```powershell
$env:Path = 'C:\Users\dyz\Documents\dev\usr\Elixir\bin;' + $env:Path
$env:ERL_FLAGS = "-kernel standard_io_encoding unicode"
mix compile --warnings-as-errors
mix test
```
期望：零警告；全绿（含 multipart e2e）。证明：6 个 multipart 操作端到端工作，UploadPart 流式、Complete 小 XML SAX 解析、multipart ETag、错误码、ListParts/ListMultipartUploads。M1 的 `:not_implemented` multipart 子资源已升级。

---

## 单元 M2-6 — DeleteObjects（POST ?delete）+ 条件头（If-*）+ 多区间 Range 对齐

**目标**：①DeleteObjects 批量删除（`POST /{bucket}?delete`，`<Delete>` 请求 SAX 解析 + `<DeleteResult>` view，verbose/quiet，缺失 key 计 success）；②GET/HEAD/PUT 条件头（If-Match/If-None-Match/If-Modified-Since/If-Unmodified-Since），按 RFC 7232 §6 次序映射 412/304；③多区间 Range（含逗号）对齐 S3 返回完整 200（不实现 multipart/byteranges）。

**条件头次序（RFC 7232 §6，已核验，bake in）**：
1. `If-Match` 存在：求值；false → 412；true → 忽略 `If-Unmodified-Since`，继续。
2. 否则 `If-Unmodified-Since` 存在：false（已修改）→ 412；true → 继续。
3. `If-None-Match` 存在：false（匹配上了）→ GET/HEAD 返回 **304**，其它方法（PUT）返回 **412**；true → 忽略 `If-Modified-Since`，继续。
4. 否则 `If-Modified-Since` 存在（仅 GET/HEAD）：false（未修改）→ **304**；true → 继续。
5. 通过 → 正常 200/206。

ETag 比较（已核验）：strip `W/` 前缀 + strip 引号后比较；`*` 表示"存在即匹配"（If-Match: *）/"不存在才匹配"（If-None-Match: *）。If-[Un]Modified-Since 用 RFC1123 解析，不可解析则忽略该头。

### Task M2-6.1 — Delete 请求 SAX 解析器（TDD）

**Files:** Create `lib/maxio/s3/request_parsers/delete.ex`、`test/maxio/s3/request_parsers/delete_test.exs`

解析 `<Delete><Object><Key>k</Key><VersionId>v</VersionId></Object>...<Quiet>true</Quiet></Delete>`，返回 `%{quiet: boolean, objects: [%{key, version_id}]}`。畸形/无 Object → `{:error, :malformed_xml}`。

测试：
```elixir
defmodule Maxio.S3.RequestParsers.DeleteTest do
  use ExUnit.Case, async: true
  alias Maxio.S3.RequestParsers.Delete, as: P

  test "解析多个 Object（含 VersionId）+ Quiet" do
    xml = """
    <Delete>
      <Quiet>true</Quiet>
      <Object><Key>a.txt</Key></Object>
      <Object><Key>b.txt</Key><VersionId>v2</VersionId></Object>
    </Delete>
    """

    assert {:ok, %{quiet: true, objects: objs}} = P.parse(xml)
    assert objs == [%{key: "a.txt", version_id: nil}, %{key: "b.txt", version_id: "v2"}]
  end

  test "默认 verbose（无 Quiet）" do
    xml = "<Delete><Object><Key>k</Key></Object></Delete>"
    assert {:ok, %{quiet: false, objects: [%{key: "k", version_id: nil}]}} = P.parse(xml)
  end

  test "带命名空间解析" do
    xml = ~s(<Delete xmlns="http://s3.amazonaws.com/doc/2006-03-01/"><Object><Key>k</Key></Object></Delete>)
    assert {:ok, %{objects: [%{key: "k", version_id: nil}]}} = P.parse(xml)
  end

  test "无 Object → :malformed_xml" do
    assert {:error, :malformed_xml} = P.parse("<Delete></Delete>")
  end

  test "畸形 XML → :malformed_xml" do
    assert {:error, :malformed_xml} = P.parse("<Delete><Object>")
  end
end
```

1. 跑确认红：
   ```powershell
   mix test test/maxio/s3/request_parsers/delete_test.exs
   ```

实现 `lib/maxio/s3/request_parsers/delete.ex`：
```elixir
defmodule Maxio.S3.RequestParsers.Delete do
  @moduledoc """
  DeleteObjects 请求体 SAX 解析（saxy）。返回 %{quiet, objects: [%{key, version_id}]}。
  畸形/无 Object → :malformed_xml。小 XML 整读后传入（铁律 4）。
  """
  @behaviour Saxy.Handler

  @spec parse(binary()) ::
          {:ok, %{quiet: boolean(), objects: [%{key: String.t(), version_id: String.t() | nil}]}}
          | {:error, :malformed_xml}
  def parse(xml) when is_binary(xml) do
    init = %{quiet: false, objects: [], current: nil, in: nil, text: nil}

    case Saxy.parse_string(xml, __MODULE__, init) do
      {:ok, %{objects: []}} -> {:error, :malformed_xml}
      {:ok, %{quiet: q, objects: objs}} -> {:ok, %{quiet: q, objects: Enum.reverse(objs)}}
      {:error, _} -> {:error, :malformed_xml}
    end
  end

  @impl true
  def handle_event(:start_document, _prolog, state), do: {:ok, state}

  @impl true
  def handle_event(:start_element, {name, _attrs}, state) do
    case local_name(name) do
      "Object" -> {:ok, %{state | current: %{key: nil, version_id: nil}, in: nil}}
      "Key" -> {:ok, %{state | in: :key, text: ""}}
      "VersionId" -> {:ok, %{state | in: :version_id, text: ""}}
      "Quiet" -> {:ok, %{state | in: :quiet, text: ""}}
      _ -> {:ok, %{state | in: nil}}
    end
  end

  @impl true
  def handle_event(:characters, _chars, %{in: nil} = state), do: {:ok, state}

  def handle_event(:characters, chars, %{text: text} = state) when is_binary(text),
    do: {:ok, %{state | text: text <> chars}}

  def handle_event(:characters, _chars, state), do: {:ok, state}

  @impl true
  def handle_event(:end_element, name, state) do
    case local_name(name) do
      "Key" ->
        {:ok, %{state | current: Map.put(state.current || %{}, :key, String.trim(state.text || "")), in: nil, text: nil}}

      "VersionId" ->
        {:ok, %{state | current: Map.put(state.current || %{}, :version_id, nilify(state.text)), in: nil, text: nil}}

      "Quiet" ->
        {:ok, %{state | quiet: String.trim(state.text || "") == "true", in: nil, text: nil}}

      "Object" ->
        case state.current do
          %{key: key} when is_binary(key) and key != "" ->
            obj = %{key: key, version_id: Map.get(state.current, :version_id)}
            {:ok, %{state | objects: [obj | state.objects], current: nil}}

          _ ->
            {:ok, %{state | current: nil}}
        end

      _ ->
        {:ok, %{state | in: nil, text: nil}}
    end
  end

  @impl true
  def handle_event(:end_document, _data, state), do: {:ok, state}

  defp local_name(name) do
    case String.split(name, ":") do
      [_ns, local] -> local
      [local] -> local
    end
  end

  defp nilify(nil), do: nil
  defp nilify(""), do: nil

  defp nilify(s) do
    case String.trim(s) do
      "" -> nil
      v -> v
    end
  end
end
```

2. 跑确认绿：
   ```powershell
   mix test test/maxio/s3/request_parsers/delete_test.exs
   ```

**Commit**：
```powershell
git add -A
git commit -m "feat(s3): DeleteObjects request SAX parser (Delete)" -m "Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

### Task M2-6.2 — DeleteResult view + DeleteObjects handler + Dispatcher 接线

**Files:** Create `lib/maxio/s3/views/delete_result.ex`、Modify `lib/maxio/s3/handlers/object.ex`（加 `delete_objects/1`）、`lib/maxio/s3/handlers.ex`、`lib/maxio/s3/dispatcher.ex`

`lib/maxio/s3/views/delete_result.ex`：
```elixir
defmodule Maxio.S3.Views.DeleteResult do
  @moduledoc "DeleteObjects 响应 XML（DeleteResult）。verbose 含每个 Deleted；quiet 仅 Error。"
  import Saxy.XML
  alias Maxio.S3.XML

  @spec render(%{deleted: [String.t()], errors: [%{key: String.t(), code: String.t(), message: String.t()}]}) :: iodata()
  def render(%{deleted: deleted, errors: errors}) do
    deleted_elems =
      Enum.map(deleted, fn key ->
        element("Deleted", [], [element("Key", [], characters(key))])
      end)

    error_elems =
      Enum.map(errors, fn e ->
        element("Error", [], [
          element("Key", [], characters(e.key)),
          element("Code", [], characters(e.code)),
          element("Message", [], characters(e.message))
        ])
      end)

    root = element("DeleteResult", [{"xmlns", XML.namespace()}], deleted_elems ++ error_elems)
    XML.encode(root)
  end
end
```

`lib/maxio/s3/handlers/object.ex` 加 `delete_objects/1`（POST ?delete，bucket level；解析 `<Delete>` → 逐 key 删元数据 + 字节，缺失 key 算 success）。先 `alias` 补 `Maxio.S3.RequestParsers.Delete` 与 `Maxio.S3.Views.DeleteResult`，再加：
```elixir
  @complete_xml_limit 1_048_576

  @spec delete_objects(Plug.Conn.t()) :: Plug.Conn.t()
  def delete_objects(conn) do
    bucket = conn.assigns.s3_bucket
    _ = ensure_bucket!(bucket)
    xml = read_small_body!(conn)

    %{quiet: quiet, objects: objects} =
      case Maxio.S3.RequestParsers.Delete.parse(xml) do
        {:ok, parsed} -> parsed
        {:error, :malformed_xml} -> raise Error.new(:malformed_xml, resource: "/" <> bucket)
      end

    if length(objects) > 1000 do
      raise Error.new(:malformed_xml, message: "A maximum of 1000 keys may be specified")
    end

    {deleted, errors} =
      Enum.reduce(objects, {[], []}, fn %{key: key}, {dacc, eacc} ->
        # 缺失 key 也算 success（S3 语义）；删元数据 + 字节皆幂等。
        :ok = Objects.delete_metadata(bucket, key)
        _ = Storage.delete(bucket, key)
        {[key | dacc], eacc}
      end)

    Log.info("delete objects", action: :delete_objects, bucket: bucket, size: length(objects))

    body =
      Maxio.S3.Views.DeleteResult.render(%{
        deleted: if(quiet, do: [], else: Enum.reverse(deleted)),
        errors: Enum.reverse(errors)
      })

    conn
    |> put_resp_content_type("application/xml")
    |> send_resp(200, body)
  end

  # DeleteObjects 的小 XML 整读（带上限，铁律 4）。
  defp read_small_body!(conn) do
    case read_body(conn, length: @complete_xml_limit, read_length: @complete_xml_limit) do
      {:ok, body, _conn} -> body
      {:more, _partial, _conn} -> raise Error.new(:entity_too_large, message: "Delete request body too large")
      {:error, _} -> raise Error.new(:malformed_xml)
    end
  end
```
> 注：`read_small_body!/1` 与 Multipart handler 里的同名私有函数互不冲突（不同模块）。`@complete_xml_limit` 在 Object 模块内定义一次。

`lib/maxio/s3/handlers.ex` 加：
```elixir
  def dispatch(:delete_objects, conn), do: Object.delete_objects(conn)
```

`lib/maxio/s3/dispatcher.ex`：把 `delete` 从 `@m2_subresources` 删除，并在 `resolve/3` 的 cond 加规则（在 multipart 之后、m2_subresource? 之前）：
```elixir
      level == :bucket and method == "POST" and MapSet.member?(query_keys, "delete") ->
        {:ok, :delete_objects}
```
更新 `@m2_subresources`（删 `delete`）：
```elixir
  @m2_subresources ~w(acl tagging versioning cors policy lifecycle website
                      versions notification replication encryption object-lock legal-hold retention
                      attributes select torrent restore accelerate analytics inventory metrics
                      ownershipcontrols publicaccessblock requestpayment logging)
```

**验证**：
```powershell
mix compile --warnings-as-errors
```
期望：零警告。

### Task M2-6.3 — 条件头模块 + GET/HEAD/PUT 接入（TDD）

**Files:** Create `lib/maxio/s3/conditional.ex`、`test/maxio/s3/conditional_test.exs`、Modify `lib/maxio/s3/handlers/object.ex`

`Maxio.S3.Conditional.evaluate/3`：纯函数，给定 conn 的条件头、对象 etag（无引号 hex）、last_modified（DateTime）、HTTP 方法，返回 `:proceed | {:respond, 304} | {:error, :precondition_failed}`。

测试（纯函数）：
```elixir
defmodule Maxio.S3.ConditionalTest do
  use ExUnit.Case, async: true
  alias Maxio.S3.Conditional

  @etag "9b2cf535f27731c974343645a3985328"
  @lm ~U[2009-10-12 17:50:30Z]

  defp headers(list), do: list

  test "If-Match 命中 → proceed" do
    assert :proceed = Conditional.evaluate(headers([{"if-match", "\"#{@etag}\""}]), %{etag: @etag, last_modified: @lm}, "GET")
  end

  test "If-Match 不符 → 412" do
    assert {:error, :precondition_failed} =
             Conditional.evaluate(headers([{"if-match", "\"other\""}]), %{etag: @etag, last_modified: @lm}, "GET")
  end

  test "If-None-Match 命中（GET）→ 304" do
    assert {:respond, 304} =
             Conditional.evaluate(headers([{"if-none-match", "\"#{@etag}\""}]), %{etag: @etag, last_modified: @lm}, "GET")
  end

  test "If-None-Match 命中（PUT，状态变更方法）→ 412" do
    assert {:error, :precondition_failed} =
             Conditional.evaluate(headers([{"if-none-match", "\"#{@etag}\""}]), %{etag: @etag, last_modified: @lm}, "PUT")
  end

  test "If-None-Match: * 且对象存在（PUT no-clobber）→ 412" do
    assert {:error, :precondition_failed} =
             Conditional.evaluate(headers([{"if-none-match", "*"}]), %{etag: @etag, last_modified: @lm}, "PUT")
  end

  test "If-Match 优先于 If-Unmodified-Since（If-Match true 覆盖）" do
    # 对象在 since 之后被改，但 If-Match 命中 → proceed
    headers = [{"if-match", "\"#{@etag}\""}, {"if-unmodified-since", "Mon, 01 Jan 2001 00:00:00 GMT"}]
    assert :proceed = Conditional.evaluate(headers, %{etag: @etag, last_modified: @lm}, "GET")
  end

  test "If-Unmodified-Since 已修改 → 412" do
    headers = [{"if-unmodified-since", "Mon, 01 Jan 2001 00:00:00 GMT"}]
    assert {:error, :precondition_failed} = Conditional.evaluate(headers, %{etag: @etag, last_modified: @lm}, "GET")
  end

  test "If-Modified-Since 未修改 → 304（GET）" do
    headers = [{"if-modified-since", "Sat, 01 Jan 2050 00:00:00 GMT"}]
    assert {:respond, 304} = Conditional.evaluate(headers, %{etag: @etag, last_modified: @lm}, "GET")
  end

  test "不可解析的日期被忽略（条件不应用）" do
    headers = [{"if-modified-since", "garbage"}]
    assert :proceed = Conditional.evaluate(headers, %{etag: @etag, last_modified: @lm}, "GET")
  end

  test "无条件头 → proceed" do
    assert :proceed = Conditional.evaluate([], %{etag: @etag, last_modified: @lm}, "GET")
  end
end
```

实现 `lib/maxio/s3/conditional.ex`：
```elixir
defmodule Maxio.S3.Conditional do
  @moduledoc """
  S3 条件请求求值（RFC 7232 §6 次序，对齐真实 S3，铁律 5）。
  evaluate(headers, %{etag, last_modified}, method) →
    :proceed | {:respond, 304} | {:error, :precondition_failed}

  次序：
    1. If-Match：false→412；true→忽略 If-Unmodified-Since，继续。
    2. 否则 If-Unmodified-Since：false（已改）→412；true→继续。
    3. If-None-Match：false（匹配）→ GET/HEAD 304，其它 412；true→忽略 If-Modified-Since，继续。
    4. 否则 If-Modified-Since（GET/HEAD）：false（未改）→304；true→继续。
    5. proceed。
  ETag 比较：strip W/ + strip 引号；* 表示存在性。日期 RFC1123，不可解析则忽略该头。
  """

  @type meta :: %{etag: String.t(), last_modified: DateTime.t()}

  @spec evaluate([{String.t(), String.t()}], meta(), String.t()) ::
          :proceed | {:respond, 304} | {:error, :precondition_failed}
  def evaluate(headers, %{etag: etag, last_modified: lm}, method) do
    if_match = get(headers, "if-match")
    if_unmod = get(headers, "if-unmodified-since")
    if_none = get(headers, "if-none-match")
    if_mod = get(headers, "if-modified-since")

    step1(if_match, if_unmod, if_none, if_mod, etag, lm, method)
  end

  defp step1(if_match, if_unmod, if_none, if_mod, etag, lm, method) do
    cond do
      is_binary(if_match) ->
        if etag_matches?(if_match, etag),
          do: step3(if_none, if_mod, etag, lm, method),
          else: {:error, :precondition_failed}

      true ->
        step2(if_unmod, if_none, if_mod, etag, lm, method)
    end
  end

  defp step2(if_unmod, if_none, if_mod, etag, lm, method) do
    case parse_http_date(if_unmod) do
      {:ok, since} ->
        # 已修改（lm > since）→ 412
        if DateTime.compare(lm, since) == :gt,
          do: {:error, :precondition_failed},
          else: step3(if_none, if_mod, etag, lm, method)

      :none ->
        step3(if_none, if_mod, etag, lm, method)
    end
  end

  defp step3(if_none, if_mod, etag, lm, method) do
    cond do
      is_binary(if_none) ->
        if etag_matches?(if_none, etag) do
          if method in ["GET", "HEAD"], do: {:respond, 304}, else: {:error, :precondition_failed}
        else
          :proceed
        end

      true ->
        step4(if_mod, lm, method)
    end
  end

  defp step4(if_mod, lm, method) do
    if method in ["GET", "HEAD"] do
      case parse_http_date(if_mod) do
        {:ok, since} ->
          # 未修改（lm <= since）→ 304
          if DateTime.compare(lm, since) == :gt, do: :proceed, else: {:respond, 304}

        :none ->
          :proceed
      end
    else
      :proceed
    end
  end

  # ETag 匹配：* 总命中（存在性）；否则按逗号分隔逐个比，strip W/ + 引号。
  defp etag_matches?("*", _etag), do: true

  defp etag_matches?(value, etag) do
    normalized_stored = normalize(etag)

    value
    |> String.split(",")
    |> Enum.map(&normalize/1)
    |> Enum.any?(fn v -> v == normalized_stored end)
  end

  defp normalize(tag) do
    tag
    |> String.trim()
    |> strip_weak()
    |> String.trim("\"")
    |> String.downcase()
  end

  defp strip_weak("W/" <> rest), do: rest
  defp strip_weak(other), do: other

  defp get(headers, name) do
    Enum.find_value(headers, fn {k, v} -> if String.downcase(k) == name, do: v end)
  end

  # RFC1123（"Wed, 30 Nov 2011 03:39:05 GMT"）。不可解析 → :none（忽略该头）。
  defp parse_http_date(nil), do: :none

  defp parse_http_date(str) do
    case Calendar.DateTime.Helpers.__noop__() do
      _ -> rfc1123(str)
    end
  rescue
    _ -> :none
  end

  defp rfc1123(str) do
    # 用 Calendar 内置：先尝试 RFC1123；Elixir 标准库无直接解析，自行解析常见格式。
    re = ~r/^[A-Za-z]{3}, (\d{2}) ([A-Za-z]{3}) (\d{4}) (\d{2}):(\d{2}):(\d{2}) GMT$/

    case Regex.run(re, String.trim(str)) do
      [_, d, mon, y, h, mi, s] ->
        with {:ok, month} <- month_num(mon),
             {:ok, naive} <-
               NaiveDateTime.new(
                 String.to_integer(y),
                 month,
                 String.to_integer(d),
                 String.to_integer(h),
                 String.to_integer(mi),
                 String.to_integer(s)
               ) do
          {:ok, DateTime.from_naive!(naive, "Etc/UTC")}
        else
          _ -> :none
        end

      _ ->
        :none
    end
  end

  defp month_num(m) do
    map = %{
      "Jan" => 1, "Feb" => 2, "Mar" => 3, "Apr" => 4, "May" => 5, "Jun" => 6,
      "Jul" => 7, "Aug" => 8, "Sep" => 9, "Oct" => 10, "Nov" => 11, "Dec" => 12
    }

    case Map.get(map, m) do
      nil -> :error
      n -> {:ok, n}
    end
  end
end
```
> **修正**：上面 `parse_http_date/1` 里 `Calendar.DateTime.Helpers.__noop__()` 是占位错误，executor **删除该 try 包装**，直接：
> ```elixir
> defp parse_http_date(nil), do: :none
> defp parse_http_date(str), do: rfc1123(str)
> ```
> `rfc1123/1` 已自带不可解析返回 `:none`，无需 rescue。

接入 `lib/maxio/s3/handlers/object.ex`：
- `get/1`：在 `object_or_raise` 之后、解析 Range 之前，求值条件头：
  ```elixir
    {object, total} = object_or_raise(bucket, key)

    case Maxio.S3.Conditional.evaluate(conn.req_headers, %{etag: object.etag, last_modified: object.updated_at}, "GET") do
      :proceed -> :ok
      {:respond, 304} -> raise Error.new(:not_modified, resource: "/#{bucket}/#{key}")
      {:error, :precondition_failed} -> raise Error.new(:precondition_failed, resource: "/#{bucket}/#{key}")
    end

    range = parse_range(header(conn, "range"), total)
    # ... 其余不变
  ```
  > 注：`not_modified` 错误码 HTTP 状态 304（M1 Error 表已有），ErrorView 渲染会带 body——但 304 不应有 body。为对齐，给 304 特判：见下方"304 无 body 处理"。
- `head/1`：同样在取到 object 后求值（方法 "HEAD"），304 → `send_resp(conn, 304, "")`，412 → `send_resp(conn, 412, "")`（HEAD 无 body）。
- 因 304/412 在 HEAD 必须无 body，且 GET 的 304 也无 body，最稳妥：handler 内直接处理而非 raise。把 `get/1` 的条件求值改为：
  ```elixir
    case Maxio.S3.Conditional.evaluate(conn.req_headers, %{etag: object.etag, last_modified: object.updated_at}, "GET") do
      :proceed ->
        range = parse_range(header(conn, "range"), total)
        serve_get(conn, object, total, range, bucket, key)

      {:respond, 304} ->
        send_resp(conn, 304, "")

      {:error, :precondition_failed} ->
        raise Error.new(:precondition_failed, resource: "/#{bucket}/#{key}")
    end
  ```
  把原 Range 处理抽到 `serve_get/6`（即原 `case range do :invalid -> ... ; _ -> ... end` 逻辑）。`head/1` 类似，304/412 都直接 `send_resp`（无 body）。

**多区间 Range**：`parse_range/2` 当前对 `"bytes=0-9,20-29"` 会进 `[a, b]` 之外的分支返回 `:invalid`（含逗号 split 出 3 段）。S3 对多区间返回**完整 200**而非 416。改 `parse_range/2`：在 `"bytes=" <> spec` 分支开头判断含逗号 → 返回 `:full`（新原子），handler 把 `:full` 当作"无 Range，返回完整 200"。即：
```elixir
  defp parse_range("bytes=" <> spec, total) do
    if String.contains?(spec, ",") do
      :full
    else
      # ... 原单区间解析
    end
  end
```
`serve_get/6` 的 range 分支增加 `:full -> 当 nil 处理（完整 200）`：把 `range_tuple/1` 与 `send_object/5` 对 `:full` 等同 `nil`：
```elixir
  defp range_tuple(:full), do: nil
  # send_object(conn, object, total, :full, stream) 走 nil 分支：
  defp send_object(conn, object, total, range, stream) when range in [nil, :full] do
    # 完整 200（原 nil 分支体）
  end
```

**验证**：
```powershell
mix test test/maxio/s3/conditional_test.exs
mix compile --warnings-as-errors
```
期望：Conditional 单测全绿；编译零警告。

### Task M2-6.4 — DeleteObjects + 条件头 + 多区间 端到端集成测试

**Files:** Modify `test/maxio/s3/integration_test.exs`

```elixir
  test "DeleteObjects 批量删除 → 200 DeleteResult（含缺失 key 也算 success）" do
    SigV4Request.signed_conn(:put, "/batchdel") |> call()
    SigV4Request.signed_conn(:put, "/batchdel/a", body: "1") |> call()
    SigV4Request.signed_conn(:put, "/batchdel/b", body: "2") |> call()

    xml = "<Delete><Object><Key>a</Key></Object><Object><Key>ghost</Key></Object></Delete>"

    del = SigV4Request.signed_conn(:post, "/batchdel", query: %{"delete" => ""}, body: xml) |> call()
    assert del.status == 200
    assert del.resp_body =~ "<Deleted><Key>a</Key></Deleted>"
    assert del.resp_body =~ "<Deleted><Key>ghost</Key></Deleted>"

    # a 已删
    assert SigV4Request.signed_conn(:get, "/batchdel/a") |> call() |> Map.get(:status) == 404
    # b 未删
    assert SigV4Request.signed_conn(:get, "/batchdel/b") |> call() |> Map.get(:status) == 200
  end

  test "DeleteObjects quiet 模式不返回 Deleted" do
    SigV4Request.signed_conn(:put, "/quietdel") |> call()
    SigV4Request.signed_conn(:put, "/quietdel/a", body: "1") |> call()

    xml = "<Delete><Quiet>true</Quiet><Object><Key>a</Key></Object></Delete>"
    del = SigV4Request.signed_conn(:post, "/quietdel", query: %{"delete" => ""}, body: xml) |> call()
    assert del.status == 200
    refute del.resp_body =~ "<Deleted>"
  end

  test "GET If-None-Match 命中 → 304 无 body" do
    SigV4Request.signed_conn(:put, "/condbk") |> call()
    put = SigV4Request.signed_conn(:put, "/condbk/c.txt", body: "hello") |> call()
    [etag] = get_resp_header(put, "etag")

    get =
      SigV4Request.signed_conn(:get, "/condbk/c.txt", headers: [{"if-none-match", etag}]) |> call()

    assert get.status == 304
    assert get.resp_body == ""
  end

  test "GET If-Match 不符 → 412" do
    SigV4Request.signed_conn(:put, "/condbk2") |> call()
    SigV4Request.signed_conn(:put, "/condbk2/c.txt", body: "hello") |> call()

    get =
      SigV4Request.signed_conn(:get, "/condbk2/c.txt", headers: [{"if-match", "\"nope\""}]) |> call()

    assert get.status == 412
    assert get.resp_body =~ "<Code>PreconditionFailed</Code>"
  end

  test "多区间 Range（含逗号）→ 完整 200（对齐 S3，不实现 multipart/byteranges）" do
    SigV4Request.signed_conn(:put, "/multirange") |> call()
    SigV4Request.signed_conn(:put, "/multirange/r.txt", body: "0123456789") |> call()

    get =
      SigV4Request.signed_conn(:get, "/multirange/r.txt", headers: [{"range", "bytes=0-2,5-7"}]) |> call()

    assert get.status == 200
    assert get.resp_body == "0123456789"
  end
```

1. 跑确认绿：
   ```powershell
   mix test test/maxio/s3/integration_test.exs
   ```
   期望：全绿。

**Commit**：
```powershell
git add -A
git commit -m "feat(s3): DeleteObjects batch + conditional headers (If-*) + multi-range full-200 alignment" -m "Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

### 单元 M2-6 验收

```powershell
$env:Path = 'C:\Users\dyz\Documents\dev\usr\Elixir\bin;' + $env:Path
$env:ERL_FLAGS = "-kernel standard_io_encoding unicode"
mix compile --warnings-as-errors
mix test
```
期望：零警告；全绿。证明：DeleteObjects verbose/quiet + 缺失 key success + >1000 MalformedXML；条件头 412/304 RFC 次序；多区间 Range 完整 200。

---

## 单元 M2-7（可选） — CopyObject（x-amz-copy-source）

> **可选**：STATUS 把 CopyObject 列在 M4。若 M2 时间充裕可纳入；否则跳过本单元、在 STATUS 记"CopyObject defer 到 M4"。本单元给出完整可执行方案。

**目标**：`PUT /{destBucket}/{destKey}` 带 `x-amz-copy-source` 头时执行服务端拷贝（而非上传）。支持 `x-amz-metadata-directive: COPY|REPLACE`、源条件头 `x-amz-copy-source-if-*`、自拷贝守卫、`<CopyObjectResult>` 响应。

**协议事实（已核验，bake in）**：
- `x-amz-copy-source` 值 = `/{srcBucket}/{srcKey}`（leading slash 可选；URL 编码；`?versionId=` 可选——M2 无 versioning，忽略）。
- 无请求 body。响应 `<CopyObjectResult><LastModified>...</LastModified><ETag>"..."</ETag></CopyObjectResult>`（ETag 含引号）。
- `metadata-directive` 默认 COPY（保留源 Content-Type/用户元数据）；REPLACE 用请求头的。
- 自拷贝（src==dest）且 directive==COPY 无变化 → `400 InvalidRequest`。
- 源条件 `x-amz-copy-source-if-match`/`-if-none-match`/`-if-modified-since`/`-if-unmodified-since` 对**源对象**求值，失败 → `412 PreconditionFailed`。
- 简单全量拷贝 ETag == 源 ETag（= 内容 MD5）。

### Task M2-7.1 — CopyObject handler + Dispatcher 分流 + view + e2e

**Files:** Create `lib/maxio/s3/views/copy_object_result.ex`、Modify `lib/maxio/s3/handlers/object.ex`（`put/1` 分流 + `copy/1`）、`test/maxio/s3/integration_test.exs`

`lib/maxio/s3/views/copy_object_result.ex`：
```elixir
defmodule Maxio.S3.Views.CopyObjectResult do
  @moduledoc "CopyObject 响应 XML（CopyObjectResult）。ETag 含引号，LastModified ISO8601。"
  import Saxy.XML
  alias Maxio.S3.XML

  @spec render(%{etag: String.t(), last_modified: DateTime.t()}) :: iodata()
  def render(%{etag: etag, last_modified: lm}) do
    root =
      element("CopyObjectResult", [{"xmlns", XML.namespace()}], [
        element("LastModified", [], characters(XML.iso8601(lm))),
        element("ETag", [], characters(XML.quote_etag(etag)))
      ])

    XML.encode(root)
  end
end
```

`lib/maxio/s3/handlers/object.ex` 的 `put/1` 开头分流（若有 `x-amz-copy-source` 头 → `copy/1`）：
```elixir
  def put(conn) do
    case header(conn, "x-amz-copy-source") do
      nil -> do_put(conn)
      _src -> copy(conn)
    end
  end
```
把原 `put/1` 主体重命名为 `do_put/1`（其余不变）。新增 `copy/1`：
```elixir
  @spec copy(Plug.Conn.t()) :: Plug.Conn.t()
  def copy(conn) do
    dest_bucket = conn.assigns.s3_bucket
    dest_key = conn.assigns.s3_key
    _ = ensure_bucket!(dest_bucket)

    {src_bucket, src_key} = parse_copy_source!(header(conn, "x-amz-copy-source"))
    {src_obj, _total} = object_or_raise(src_bucket, src_key)

    # 源条件头（对源对象求值；失败 412）
    case eval_copy_source_conditions(conn, src_obj) do
      :proceed -> :ok
      {:error, :precondition_failed} -> raise Error.new(:precondition_failed, resource: "/#{src_bucket}/#{src_key}")
    end

    directive = header(conn, "x-amz-metadata-directive") || "COPY"

    # 自拷贝守卫：src==dest 且 COPY 且无元数据变化 → 400 InvalidRequest
    if src_bucket == dest_bucket and src_key == dest_key and directive == "COPY" do
      raise Error.new(:invalid_request,
        message: "This copy request is illegal because it is trying to copy an object to itself without changing the object's metadata, storage class, website redirect location or encryption attributes."
      )
    end

    content_type =
      case directive do
        "REPLACE" -> header(conn, "content-type") || "binary/octet-stream"
        _ -> src_obj.content_type
      end

    # 拷贝字节：读源流 → 写目标（FS put 重算 MD5；全量拷贝 ETag == 源 ETag）
    {:ok, src_stream} = Storage.get(src_bucket, src_key, nil)

    case Storage.put(dest_bucket, dest_key, src_stream) do
      {:ok, %{size: size, etag: etag}} ->
        {:ok, obj} =
          Objects.put_metadata(dest_bucket, dest_key, %{
            size: size,
            etag: etag,
            content_type: content_type,
            storage_class: "STANDARD"
          })

        Log.info("copy object",
          action: :copy_object,
          bucket: dest_bucket,
          key: dest_key
        )

        body = Maxio.S3.Views.CopyObjectResult.render(%{etag: etag, last_modified: obj.updated_at})

        conn
        |> put_resp_content_type("application/xml")
        |> send_resp(200, body)

      {:error, reason} ->
        raise Error.new(:internal_error, message: inspect(reason))
    end
  end

  # "/srcBucket/srcKey" | "srcBucket/srcKey"（URL 编码；忽略 ?versionId=）
  defp parse_copy_source!(raw) do
    decoded = URI.decode(raw)
    trimmed = String.replace_prefix(decoded, "/", "")
    # 去掉 ?versionId=...（M2 无 versioning）
    [path | _] = String.split(trimmed, "?", parts: 2)

    case String.split(path, "/", parts: 2) do
      [bucket, key] when key != "" -> {bucket, key}
      _ -> raise Error.new(:invalid_argument, message: "Invalid x-amz-copy-source")
    end
  end

  # 源条件头（x-amz-copy-source-if-*）→ 复用 Conditional，但头名不同，先映射成标准名再求值。
  defp eval_copy_source_conditions(conn, src_obj) do
    mapped =
      conn.req_headers
      |> Enum.flat_map(fn {k, v} ->
        case String.downcase(k) do
          "x-amz-copy-source-if-match" -> [{"if-match", v}]
          "x-amz-copy-source-if-none-match" -> [{"if-none-match", v}]
          "x-amz-copy-source-if-modified-since" -> [{"if-modified-since", v}]
          "x-amz-copy-source-if-unmodified-since" -> [{"if-unmodified-since", v}]
          _ -> []
        end
      end)

    case Maxio.S3.Conditional.evaluate(mapped, %{etag: src_obj.etag, last_modified: src_obj.updated_at}, "COPY") do
      :proceed -> :proceed
      {:respond, 304} -> {:error, :precondition_failed}
      {:error, :precondition_failed} -> {:error, :precondition_failed}
    end
  end
```
> 注：CopyObject 走 M1 既有 `put_object` 分发（PUT object 级），无需改 Dispatcher——`put/1` 内分流即可。`Maxio.S3.Conditional` 对非 GET/HEAD 方法（"COPY"）的 If-None-Match false → 412（状态变更语义），符合源条件需求。

集成测试：
```elixir
  test "CopyObject 复制源对象到目标 + CopyObjectResult（ETag 一致）" do
    SigV4Request.signed_conn(:put, "/copybk") |> call()
    put = SigV4Request.signed_conn(:put, "/copybk/src.txt", body: "copy-me") |> call()
    [src_etag] = get_resp_header(put, "etag")

    copy =
      SigV4Request.signed_conn(:put, "/copybk/dst.txt",
        headers: [{"x-amz-copy-source", "/copybk/src.txt"}]
      )
      |> call()

    assert copy.status == 200
    assert copy.resp_body =~ "<CopyObjectResult"
    assert copy.resp_body =~ "<ETag>"

    get = SigV4Request.signed_conn(:get, "/copybk/dst.txt") |> call()
    assert get.status == 200
    assert get.resp_body == "copy-me"
    assert get_resp_header(get, "etag") == [src_etag]
  end

  test "CopyObject 自拷贝（COPY 无变化）→ 400 InvalidRequest" do
    SigV4Request.signed_conn(:put, "/selfcopy") |> call()
    SigV4Request.signed_conn(:put, "/selfcopy/x.txt", body: "x") |> call()

    copy =
      SigV4Request.signed_conn(:put, "/selfcopy/x.txt",
        headers: [{"x-amz-copy-source", "/selfcopy/x.txt"}]
      )
      |> call()

    assert copy.status == 400
    assert copy.resp_body =~ "<Code>InvalidRequest</Code>"
  end

  test "CopyObject 源 if-match 不符 → 412" do
    SigV4Request.signed_conn(:put, "/copycond") |> call()
    SigV4Request.signed_conn(:put, "/copycond/s.txt", body: "y") |> call()

    copy =
      SigV4Request.signed_conn(:put, "/copycond/d.txt",
        headers: [
          {"x-amz-copy-source", "/copycond/s.txt"},
          {"x-amz-copy-source-if-match", "\"wrong\""}
        ]
      )
      |> call()

    assert copy.status == 412
  end
```

1. 跑确认绿：
   ```powershell
   mix test test/maxio/s3/integration_test.exs
   ```
   期望：全绿（含 CopyObject 三用例）。

**Commit**：
```powershell
git add -A
git commit -m "feat(s3): CopyObject (x-amz-copy-source, metadata-directive, source conditions, self-copy guard)" -m "Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

### 单元 M2-7 验收

```powershell
$env:Path = 'C:\Users\dyz\Documents\dev\usr\Elixir\bin;' + $env:Path
$env:ERL_FLAGS = "-kernel standard_io_encoding unicode"
mix compile --warnings-as-errors
mix test
```
期望：零警告；全绿。证明：CopyObject 全量拷贝 ETag 一致、自拷贝守卫 400、源条件 412。

---

## M2 总验收（全单元完成后，独立 verifier/code-reviewer 取证）

```powershell
$env:Path = 'C:\Users\dyz\Documents\dev\usr\Elixir\bin;' + $env:Path
$env:ERL_FLAGS = "-kernel standard_io_encoding unicode"
mix compile --warnings-as-errors
mix test
```
期望：编译零警告；M1（125）+ M2 新增全部测试通过。

**审查重点（独立 code-reviewer，实现者不得自审）**：
1. **铁律 3（绝不静默）**：aws-chunked 坏块/截断硬停且不落盘（GET 404 取证）；StreamingVerifier 常数时间比对；Complete 各错误码正确；DeleteObjects 缺失 key 算 success（S3 语义，非静默吞错）。
2. **铁律 4（body 不全缓冲）**：UploadPart/PutObject/CopyObject 字节流式；只有 CompleteMultipartUpload / DeleteObjects 小 XML 走带上限整读。
3. **铁律 1/2（后端 behaviour）**：multipart parts 经 `Maxio.Storage.Backend` 回调，handler 不直接碰文件系统。
4. **铁律 5（对齐 AWS）**：StreamingVerifier 对 AWS KNOWN-ANSWER 向量 byte-for-byte 一致；multipart ETag `-N` 形态；条件头 RFC 7232 §6 次序；多区间 Range 完整 200；XML 命名空间/元素/ISO8601。
5. **铁律 6（中文 COMMENT）**：`multipart_uploads`/`multipart_parts` 表/列/索引中文注释（`\d+` 取证）。
6. **回归**：M1 既有 11+ 集成用例与 SigV4 KNOWN-ANSWER 全绿；dev S3 端口 9900 可绑定。

**完成后更新 STATUS.md**：M2 标 ✅；记录 aws-chunked 全验证已通、multipart 全套、DeleteObjects、条件头、（可选）CopyObject；deferred 项（checksum trailer 重算 → M3、SigV4A 501、DeleteObjects 条件子字段、versioning）。
