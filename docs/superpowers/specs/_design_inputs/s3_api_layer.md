I have confirmed the key protocol details I needed. I have enough verified information (ListObjectsV2 element semantics, error code/status mappings) plus my own knowledge of SigV4 streaming and ETag semantics. Now I'll write the complete design.

# maxio S3 API / HTTP 层与路由 — 架构设计

## 概述

本子系统是 maxio 的**北向门面**：把外部 S3 客户端（aws-cli、boto3、mc、SDK）发来的原始 HTTP/HTTPS 请求，翻译成 maxio 内部的统一数据契约（`Maxio.S3.Request` / `Maxio.S3.Response`），交给业务编排层（bucket/object/multipart 用例）执行，再把结果（含错误）渲染回 S3 兼容的 XML/二进制响应。它**不包含**业务逻辑、不直接碰存储后端，只负责：寻址解析、动作分发、流式 body 接管、入站 XML 解析、出站 XML 渲染、错误映射、Range 处理。

核心矛盾是 S3 协议与 Phoenix 默认管线的冲突：S3 用"HTTP 方法 + query 参数子资源"做 RPC 风格分发（不是 REST 资源路由），且 `PutObject`/`UploadPart` 的 body 是**任意字节流（可达数 GB）**，绝不能被 `Plug.Parsers` 读进内存。因此本设计的第一原则是：**让 S3 流量在 `Plug.Parsers` 之前分流，走一条独立的、不消费 body 的 Plug 管线**，与现有 LiveView/Dashboard 浏览器管线完全隔离。这符合工程铁律 1（数据契约抽象）与 2（架构层解决，不打补丁）。

## 关键设计决策

### 决策 1：S3 流量用独立 Endpoint 子树，而非改造现有 endpoint.ex
- **选择**：在 `Maxio.Application` 的 supervision tree 中，除现有 `MaxioWeb.Endpoint`（控制台/LiveView，监听如 9001）外，**新增一个独立 `Maxio.S3.Endpoint`（监听 S3 端口，如 9000）**，专门跑 Bandit + S3 Plug 管线。
- **理由**：MinIO 本身就是 API 端口（9000）与 Console 端口（9001）分离。两套管线诉求根本对立——浏览器侧需要 session/CSRF/Parsers，S3 侧需要零 body 消费、SigV4 鉴权、XML 渲染。物理隔离避免在同一 endpoint 里写 `if path =~ "/s3"` 这类分叉补丁（违反铁律 2），也让 SigV4 chunk 解码、超大 body 等只作用于 S3 子树。
- **备选**：(a) 在现有 endpoint 中、`Plug.Parsers` 之前插一个 `Maxio.S3.Dispatch` plug，命中 S3 host/path 就 `halt` 接管。可行且少开一个端口，但端口共享会让 S3 与 console 路由互相污染，且 Parsers 仍在管线里（哪怕被跳过也是耦合）。作为**降级方案**保留——若部署要求单端口，用此法，关键是 Dispatch 必须位于 `Plug.Parsers` 之前。(b) 完全裸 Bandit handler 不用 Plug——丢掉 Plug 生态（telemetry、RequestId、测试 `Plug.Test`），不取。**最终取独立 Endpoint**。

### 决策 2：body 绝不进 Plug.Parsers，用 `Plug.Conn.read_body/2` 流式读取 + SigV4 chunk 解码 reader
- **选择**：S3 管线**不挂 `Plug.Parsers`**。PutObject/UploadPart 的 body 由 handler 通过 `Plug.Conn.read_body(conn, length: …)` 按块拉取，转成 `Stream`/`Enumerable` 交给存储层。对入站 XML（CompleteMultipartUpload、Delete）这类**小 body**，由专用的 `read_full_body/2`（带大小上限，超限报 `MaxMessageLengthExceeded`/`EntityTooLarge`）一次性读出再交 saxy 解析。
- **理由**：直接满足铁律 1/2 与任务硬约束。区分"流式大 body"与"小 XML body"两条路径，避免把 XML 也流式化的过度设计。
- **VERIFY-AT-IMPL**：当客户端用 `Content-Encoding: aws-chunked` + `x-amz-content-sha256: STREAMING-AWS4-HMAC-SHA256-PAYLOAD`（aws-cli 默认对大文件如此）时，wire 上的 body 是 `chunk-signature` 包裹的分块格式，**真实对象字节需先剥离 chunk 头/尾**。必须实现一个 `Maxio.S3.ChunkedBodyReader`（作为 `read_body` 的替代/包装），边读边解析 `<hex-size>;chunk-signature=<sig>\r\n<data>\r\n`，对每块校验 SigV4 链式签名后输出纯净数据。chunk 帧格式、trailing checksum（`x-amz-trailer`）、各 `x-amz-content-sha256` 取值需对照官方 SigV4 streaming 文档核验。

### 决策 3：寻址解析独立成 Plug，path-style 与 virtual-host 归一化
- **选择**：`Maxio.S3.Plugs.AddressStyle` 在分发前统一把 `{bucket, key}` 解析出来并写入 `conn.assigns`。规则：读取配置的根域名 `s3_domain`（如 `s3.example.com`、`localhost`）；若 `Host` 形如 `<bucket>.<s3_domain>` → virtual-host，bucket = 子域，key = `conn.path_info` join；否则 path-style，`["bucket" | rest]` → bucket = 第一段，key = 其余 join（保留前导/尾随 `/` 与 URL 解码语义）。空 path（`/`）= Service 级操作（ListBuckets）。
- **理由**：把"两种寻址"的复杂度集中在一个 plug，下游 handler 只看 `{bucket, key}`，不关心寻址方式（铁律 1）。
- **VERIFY-AT-IMPL**：key 的 URL 解码细节（`+` 不解码为空格、`%2F` 是否保留、`encoding-type=url` 对响应回显的影响）、bucket 命名校验规则（3–63 字符、不可点分 IP 样式等触发 `InvalidBucketName`）需对照文档。

### 决策 4：动作分发用"方法 + 子资源 query key"的判定表，而非 Phoenix Router
- **选择**：放弃 `MaxioWeb.Router` 的 verb/path 宏（它表达不了 `?uploads` vs `?acl` 这种同 path 不同动作）。改用一个**纯函数判定表** `Maxio.S3.Dispatcher.resolve(level, method, query_keys) -> action_atom`，按 `level ∈ {:service, :bucket, :object}`、HTTP method、以及出现的子资源 query key（`uploads`/`uploadId`/`delete`/`versioning`/`acl`/`tagging`/`location`/`cors`/`policy`/`lifecycle` 等）匹配出动作原子。
- **理由**：S3 是 RPC over query-string，判定表是它的自然表达，且可穷举测试、易扩展（铁律 3 的"明确状态/动作映射"在路由层的体现）。
- **备选**：用 Router + 大量 `forward`/正则——僵硬且分散。不取。

### 决策 5：XML 渲染用 saxy 的 builder（XML.element/iolist），错误渲染走统一 ErrorView
- **选择**：引入 `saxy`。出站用 `Saxy.XML`（`element/3`、`characters/1`）构造 simple-form 再 `Saxy.encode!/1` 输出 iolist，保证正确转义与 UTF-8。每个响应一个 view 模块。错误统一经 `Maxio.S3.ErrorView.render(code, opts)`。
- **理由**：saxy 同时覆盖出站构造与入站 SAX 解析（一个依赖两用）；iolist 直接喂给 `send_resp`，零中间字符串。手写 iolist 在转义/编码上易错，不取手写。

## Elixir 模块清单

**Endpoint / 管线**
- `Maxio.S3.Endpoint` — 独立 Phoenix.Endpoint（或裸 `Plug.Builder` + Bandit child spec）。挂：`Plug.RequestId`、`Plug.Telemetry`、`Maxio.S3.Plugs.AddressStyle`、`Maxio.S3.Plugs.Auth`（SigV4）、`Maxio.S3.Plugs.Dispatch`。**不挂 `Plug.Parsers`**。函数：`init/1`、`call/2`。
- `Maxio.S3.Plugs.AddressStyle` — 解析寻址，填 `conn.assigns.s3_bucket/s3_key/s3_level`。`call/2`、`parse_host/2`。
- `Maxio.S3.Plugs.Auth` — SigV4 校验（与鉴权子系统对接，本层只负责把签名所需的 canonical request 材料从 conn 取出、调用 `Maxio.Auth.SigV4.verify/2`，失败映射 `SignatureDoesNotMatch`/`AccessDenied`）。`call/2`。**VERIFY-AT-IMPL**：canonical request 的 header 规范化、签名头解析、`x-amz-date` 偏移容忍窗口。
- `Maxio.S3.Plugs.Dispatch` — 调 `Dispatcher.resolve/3` 得 action，转交对应 handler；统一 `try/rescue` 把抛出的 `%Maxio.S3.Error{}` 交 ErrorView。`call/2`。
- `Maxio.S3.ChunkedBodyReader` — `aws-chunked` 流式解码（决策 2）。`read_chunk/2`、`stream/2`。

**分发 / 动作**
- `Maxio.S3.Dispatcher` — 纯判定表。`resolve(level, method, query_map) :: {:ok, action} | {:error, :method_not_allowed}`。
- `Maxio.S3.Handlers.Service` — `list_buckets/1`。
- `Maxio.S3.Handlers.Bucket` — `create/1`、`delete/1`、`head/1`、`list_objects_v2/1`、`list_object_versions/1`、`get_location/1`、`get/put/delete` for versioning/acl/tagging/cors/policy/lifecycle、`delete_objects/1`（多对象删除）、`list_multipart_uploads/1`。
- `Maxio.S3.Handlers.Object` — `put/1`（流式）、`get/1`（含 Range）、`head/1`、`delete/1`、`copy/1`（`x-amz-copy-source`）、`get/put acl/tagging`、multipart：`create_upload/1`、`upload_part/1`、`complete_upload/1`、`abort_upload/1`、`list_parts/1`。

**契约 / 数据结构**
- `Maxio.S3.Conn` — 把 `Plug.Conn` 投影成内部 `Request` 结构（解耦 handler 与 Plug）。`from_conn/1`。
- `Maxio.S3.Error` — 异常结构体（`defexception`），见下。`new/2`、`http_status/1`。

**XML 出站**
- `Maxio.S3.XML.Render` — 通用辅助（`element/3`、`iso8601/1`、`etag/1`、wrap root + namespace）。
- `Maxio.S3.Views.{ListAllMyBuckets, ListBucket, ListVersions, InitiateMultipartUpload, CompleteMultipartUpload, ListParts, ListMultipartUploads, CopyObjectResult, DeleteResult, LocationConstraint, Tagging}` — 各响应一个 `render/1 :: iodata`。
- `Maxio.S3.ErrorView` — `render(%Maxio.S3.Error{})  :: {status, iodata}`。

**XML 入站**
- `Maxio.S3.Parsers.CompleteMultipartUpload` — saxy handler，解析 `<Part><PartNumber/><ETag/></Part>` 列表。`parse(binary) :: {:ok, [%{part_number, etag}]} | {:error, :malformed_xml}`。
- `Maxio.S3.Parsers.Delete` — 解析多对象删除 `<Delete><Object><Key/><VersionId/></Object>…<Quiet/></Delete>`。`parse/1`。
- `Maxio.S3.Parsers.{Tagging, VersioningConfiguration}` — 配置类入站。

## 关键数据结构 / behaviour / 端点映射

**统一错误结构**
```elixir
defmodule Maxio.S3.Error do
  defexception [:code, :message, :http_status, :resource, :request_id, extra: %{}]
end
```
**错误码 → HTTP 状态映射表（已核验，VERIFY-AT-IMPL 补全剩余）**：

| Code | HTTP | 触发 |
|---|---|---|
| NoSuchBucket | 404 | bucket 不存在 |
| NoSuchKey | 404 | object 不存在 |
| NoSuchUpload | 404 | uploadId 无效/已 abort/已 complete |
| AccessDenied | 403 | 鉴权通过但无权限 |
| SignatureDoesNotMatch | 403 | 签名不匹配 |
| InvalidAccessKeyId | 403 | access key 未知 |
| BucketAlreadyOwnedByYou | 409 | 重复创建自有 bucket |
| BucketNotEmpty | 409 | 删非空 bucket |
| InvalidArgument | 400 | 参数非法 |
| InvalidBucketName | 400 | bucket 名非法 |
| EntityTooSmall | 400 | multipart 非末块 < 5MiB |
| EntityTooLarge | 400 | 单对象超限 |
| InvalidPart / InvalidPartOrder | 400 | complete 时 part 缺失/乱序 |
| MalformedXML | 400 | 入站 XML 解析失败 |
| PreconditionFailed | 412 | If-Match/If-Unmodified-Since 不满足 |
| NotModified | 304 | If-None-Match/If-Modified-Since（GET，无 body） |
| InvalidRange | 416 | Range 不可满足 |
| MethodNotAllowed | 405 | 动作判定表无匹配 |
| MissingContentLength | 411 | PutObject 缺 Content-Length |
| NotImplemented | 501 | MVP 未支持的子资源 |
| InternalError | 500 | 兜底 |

错误 XML 形如 `<?xml version="1.0" encoding="UTF-8"?><Error><Code/><Message/><Resource/><RequestId/></Error>`。**铁律 3**：所有错误必须显式映射并结构化日志记录（`Logger.warning(code: …, bucket: …, key: …, request_id: …)`），禁止静默 500。

**Range 处理（GetObject）**：解析 `Range: bytes=start-end` / `bytes=start-` / `bytes=-suffix`；命中 → `206 Partial Content` + `Content-Range: bytes start-end/total` + `Accept-Ranges: bytes`，body 用 `read_body`-反向的 `chunk/2` 从存储层按区间流式发送；越界 → `416 InvalidRange`（带 `Content-Range: bytes */total`）；多区间（multipart/byteranges）MVP 可只支持单区间，多区间标 `NotImplemented`。同时处理条件头 `If-Match/If-None-Match/If-Modified-Since/If-Unmodified-Since`（ETag 语义见下）。

**ListObjectsV2 响应元素（已核验）**：root `<ListBucketResult>`，含 `Name/Prefix/KeyCount/MaxKeys/Delimiter/IsTruncated/ContinuationToken/NextContinuationToken/StartAfter/EncodingType`，每对象 `<Contents><Key/><LastModified/><ETag/><Size/><StorageClass/></Contents>`，目录折叠 `<CommonPrefixes><Prefix/></CommonPrefixes>`。语义要点：`IsTruncated=true` 时才回 `NextContinuationToken`；`KeyCount ≤ MaxKeys`；`CommonPrefixes` 仅在指定 `delimiter` 时出现；指定 `encoding-type=url` 时对 `Key/Prefix/Delimiter/StartAfter` 做 percent-encode 并回显 `<EncodingType>url</EncodingType>`。

**ETag 语义（VERIFY-AT-IMPL 精度点）**：普通 PutObject 的 ETag = 对象内容 MD5 的十六进制，带引号。Multipart 完成对象 ETag = `MD5(各 part 的 MD5 二进制拼接)` 的十六进制 + `-<partCount>` 后缀（如 `"d41…-3"`），由 object/multipart 子系统计算，本层只负责带引号渲染与在 `If-Match` 比较时去引号。

## MVP 必须支持的操作清单

**Service**：`GET /` ListBuckets。
**Bucket**：`PUT /{b}` CreateBucket、`DELETE /{b}` DeleteBucket、`HEAD /{b}` HeadBucket、`GET /{b}?list-type=2` ListObjectsV2（含 prefix/delimiter/max-keys/continuation-token/start-after/encoding-type）、`GET /{b}?location` GetBucketLocation、`GET /{b}?versioning` / `PUT /{b}?versioning`、`POST /{b}?delete` DeleteObjects（多对象删除）、`GET /{b}?uploads` ListMultipartUploads。
**Object**：`PUT /{b}/{k}` PutObject（流式，含 `x-amz-copy-source` 走 CopyObject）、`GET /{b}/{k}` GetObject（含 Range + 条件头）、`HEAD /{b}/{k}` HeadObject、`DELETE /{b}/{k}` DeleteObject、`GET/PUT /{b}/{k}?tagging`。
**Multipart**：`POST /{b}/{k}?uploads` CreateMultipartUpload、`PUT /{b}/{k}?partNumber=N&uploadId=…` UploadPart、`POST /{b}/{k}?uploadId=…` CompleteMultipartUpload（入站 XML）、`DELETE /{b}/{k}?uploadId=…` AbortMultipartUpload、`GET /{b}/{k}?uploadId=…` ListParts。
**MVP 后**（返回 `NotImplemented` 占位）：bucket policy/cors/lifecycle、object ACL 细粒度、versioning 读写历史、UploadPartCopy、SelectObjectContent。

## 风险

1. **`aws-chunked` 流式签名**（最大风险）：aws-cli 默认对文件用 STREAMING-AWS4-HMAC-SHA256，若 ChunkedBodyReader 解析或链式签名校验有误，所有 cli put 失败且现象隐晦。须早做并用真实 aws-cli 端到端测。
2. **body 误被消费**：任何无意中挂上 Parsers 或在 Auth plug 里 `read_body` 后未把 body 传下去，都会破坏流式。须在测试中断言大文件不进内存。
3. **寻址歧义**：`localhost`/IP 下 virtual-host 不可用，客户端常需 `path-style`/`--endpoint-url`；root-domain 配置错误会全盘错判。须配置可调并默认兼容 path-style。
4. **XML 兼容细节**：命名空间 `xmlns="http://s3.amazonaws.com/doc/2006-03-01/"`、日期格式、空列表元素省略与否，SDK 对此敏感。
5. **HEAD 不带 body 但要带全部头**（Content-Length/ETag/Last-Modified），易遗漏。

## 需要的依赖

- **Hex**：`{:saxy, "~> 1.6"}`（出站 XML 构造 + 入站 SAX 解析）。Bandit/Plug/Phoenix 已在 `mix.exs`。SigV4 的 HMAC-SHA256 用 OTP 内置 `:crypto`，无需额外 crate。
- **Rust crates**：本层（HTTP/路由/XML）**不需要** Rustler。热点（纠删码、对象内容/分块 MD5、SHA256）归存储/哈希子系统，可选 Rustler NIF，与本层通过统一契约解耦。

## 落地改造点（对照现有代码）
- `lib/maxio/application.ex`：children 增加 `Maxio.S3.Endpoint`（或单端口降级方案：在 `MaxioWeb.Endpoint` 第 46 行 `Plug.Parsers` **之前**插 `Maxio.S3.Plugs.Dispatch`）。
- 现有 `MaxioWeb.Endpoint` / `MaxioWeb.Router`（`C:/Users/dyz/Documents/dev/hemifuture/maxio/lib/maxio_web/endpoint.ex`、`router.ex`）**保持不变**，专供 console/LiveView/Dashboard。
- `config/config.exs`/`runtime.exs`：新增 `config :maxio, Maxio.S3.Endpoint, http: [port: 9000]` 与 `s3_domain` 配置项。
- `mix.exs` deps 增加 `:saxy`。

相关文件（绝对路径）：`C:/Users/dyz/Documents/dev/hemifuture/maxio/lib/maxio_web/endpoint.ex`（line 46 `Plug.Parsers`，S3 流量须在其前分流）、`C:/Users/dyz/Documents/dev/hemifuture/maxio/lib/maxio_web/router.ex`、`C:/Users/dyz/Documents/dev/hemifuture/maxio/lib/maxio/application.ex`、`C:/Users/dyz/Documents/dev/hemifuture/maxio/mix.exs`、`C:/Users/dyz/Documents/dev/hemifuture/maxio/config/config.exs`。新模块建议置于 `C:/Users/dyz/Documents/dev/hemifuture/maxio/lib/maxio/s3/`。

Sources:
- [ListObjectsV2 - Amazon S3](https://docs.aws.amazon.com/AmazonS3/latest/API/API_ListObjectsV2.html)
- [Error responses - Amazon S3](https://docs.aws.amazon.com/AmazonS3/latest/API/ErrorResponses.html)
