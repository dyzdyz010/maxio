# Route B B4-6 — 写路径元数据保真补全（修 B4-5 fidelity 审计的 3 个 medium 偏离）

> 状态：待实现。基线 = B4-5 提交 `5dd510c`（写路径已产 maxio/2 sidecar，单 PUT 路径已富元数据自描述）。
> 来源：B4-5 独立 MinIO-fidelity 审计（3 lenses）报出 3 medium + 1 low 偏离。按用户既定政策「全部修 critical+high+medium」修 3 个 medium；1 个 low 文档化 defer。
> 默认 `authoritative_source: read/list/write = :pg` 不变；本单元只补元数据富度/一致性，不动读逻辑、不动耐久字节。

## 偏离清单与定级

| # | 偏离 | 严重度 | 是否 B4-5 引入 | 本单元 |
|---|---|---|---|---|
| D1 | 多段完成对象的 maxio/2 sidecar 丢客户端 Content-Type/user_metadata（`:sidecar` 读下返 `binary/octet-stream`） | medium | 否（多段 sidecar 从未带过；B4-5 让单 PUT 带了、多段是剩余缺口，executor 已显式记 B4-6） | ✅ 修 |
| D2 | PutObject 现捕获 `x-amz-meta-*` 但无 2 KB 上限 → 缺 `MetadataTooLarge`/400 | medium | 部分（B4-5 首次在 PUT 路径存储 user metadata，使该失败路径可达） | ✅ 修 |
| D3 | PutObject `user_metadata` 进 sidecar 却没进 PG → `:pg`(默认) vs `:sidecar` 读分裂 | medium | 是（B4-5 引入的不一致） | ✅ 修 |
| D4 | CopyObject sidecar 硬编码 `private`/`STANDARD`，忽略 `x-amz-acl`/`x-amz-storage-class` | low | 否（预存在且与 PG 路径一致） | ⏸ defer（见末尾） |

## 修法（架构层，对齐 AGENTS.md 铁律 3/5）

### D3 — PutObject user_metadata 也写入 PG 索引（消除 :pg/:sidecar 分裂）
- `lib/maxio/s3/handlers/object.ex` `do_put`：PG 侧 `attrs` map（put 返回后构造，~L74-83）当前**无 `:metadata` 键** → `x-amz-meta-*` 被 PG 丢弃；而 B4-5 已让 sidecar 携带。两路读结果分裂（铁律 5：同一对象元数据不应取决于内部权威）。
- 修：把 `parse_user_metadata(conn)` 的结果并入 do_put 的 PG `attrs`（键 `metadata:`，与 CopyObject 已有的 `metadata: meta_map`（~L603）对齐）。复用 build_object_meta 已解析的 user_metadata，避免重复解析（可让 build_object_meta 返回的 om 复用，或 do_put 解析一次喂两路）。
- 结果：`:pg` 默认路径与 `:sidecar` 路径对 PutObject user metadata 一致。
- 注意：`put_common_object_headers`（~L868）当前不发 `x-amz-meta-*`/`x-amz-storage-class` 响应头——这是两路共有的**预存在**响应层缺口（非本单元；记入 STATUS defer 列表，留响应层里程碑）。本单元只保证两路**存储一致**，不扩展到响应头发射（避免范围蔓延 + 行为突变）。

### D2 — PutObject / CopyObject(REPLACE) 加 2 KB 用户元数据上限（MetadataTooLarge 400）
- `lib/maxio/s3/error.ex` `@table`（~L19-119）新增错误码：`metadata_too_large: {"MetadataTooLarge", 400, "Your metadata headers exceed the maximum allowed metadata size."}`（对齐 AWS ErrorResponses + MinIO `ErrMetadataTooLarge`）。
- 新增校验器（仿 `Maxio.Tags` 风格），如 `Maxio.Metadata.validate_size!/1`：对 `x-amz-meta-*` 的**每个 key+value 的 UTF-8 字节和**求和，超 **2048 字节**（AWS 阈值，s3-tests `test_object_set_get_metadata_overflow_*` 断言此值）→ `raise Error.new(:metadata_too_large)`。
- 调用点（在写任何字节/sidecar **之前**，与其它 400 校验并列，保证失败 pre-commit、无孤儿）：
  - `do_put`：紧随 `parse_tagging_header!` / `resolve_sse!` 之后。
  - `copy`：当 `x-amz-metadata-directive == "REPLACE"`（此时 `parse_user_metadata` 生效）时校验。
- 测试：PUT/COPY(REPLACE) 携带 >2 KB `x-amz-meta-*` → 400 `MetadataTooLarge`；恰好 ≤2 KB → 通过。

### D1 — 多段完成对象 sidecar 透传 Content-Type/user_metadata（消除多段 :sidecar 读 content-type 错误）
- 现状：`Maxio.Multipart.complete/3`（`lib/maxio/multipart.ex:143`）调 `Storage.assemble/4`**不带 object_meta**；两后端 `do_assemble`（`erasure_coded.ex:~225` / `distributed.ex:~763`）调 `build_meta(cfg, "null", [], ...)` 空 opts → version_opts 回落 `content_type:"binary/octet-stream"`、`user_metadata:%{}`。而 CreateMultipartUpload 的真实 content_type 存在 upload 行上（`handlers/multipart.ex:33`，且已正确落 PG，`:104-109`）。
- 修（架构层，扩 assemble 的元数据通道）：
  1. `Storage.assemble`（门面 `lib/maxio/storage.ex:~55` + behaviour `@callback`）增 `opts`（或 `:object_meta`）通道——若已有 opts 形参则复用，否则增一个 keyword 形参，默认 `[]`，不破坏既有调用。
  2. `Maxio.Multipart.complete/3` 从 upload 会话取 `content_type`（+ 已存的 user_metadata/tags 若有）构造 `object_meta`，传入 `Storage.assemble(..., object_meta: om)`。
  3. 两后端 `do_assemble` 把该 opts 转给 `build_meta(... version_opts(version_id, opts))`，替换硬编码 `[]`。
- 结果：多段对象 sidecar 自描述真实 content_type/user_metadata，`:sidecar` 读与 `:pg` 读一致。
- 多段对象版本化（Storage.assemble 无 version_id 形参、CompleteMPU 在 Enabled 桶不建新版本/不返 `x-amz-version-id`）是**预存在基础设施限制**，非本单元目标——如需一并补，须扩 assemble version_id 通道；本单元只补 content_type/user_metadata 的 sidecar 透传，若 version_id 通道一并顺手补上则更佳，否则**显式记 defer**（不静默截断）。

## 验收
- `mix compile --warnings-as-errors` 零警告。
- 新/改测试全过：
  - D1：真实多段 PUT（带非默认 content-type）→ complete →（distributed+InProcess+topology）`:sidecar` 读 GET content_type 正确（非 octet-stream）。
  - D2：PUT 与 COPY(REPLACE) >2 KB `x-amz-meta-*` → 400 `MetadataTooLarge`；≤2 KB 通过。
  - D3：PUT 带 `x-amz-meta-*` → `:pg` 与 `:sidecar` 读到的 user metadata 一致（断言 %Object{}.metadata 两路相等）。
- 全量 `mix test` 绿、无回归；`mix format --check-formatted` exit 0。
- 默认 `:pg` 既有 S3/listing 用例全绿；耐久 ec/shards/size/etag/sha256/parts 字节不变。

## 非目标 / defer
- **D4（low）defer**：CopyObject sidecar 硬编码 `private`/`STANDARD` 忽略 `x-amz-acl`/`x-amz-storage-class`——**预存在且与 PG 路径一致**（PG copy 也硬编码），非 B4-5 引入，与既有 12 项 low defer 同级。文档化于 STATUS「low 偏离 defer 列表」，留 CopyObject directive 完整化里程碑统一处理（届时 sidecar 与 PG 须锁步）。
- **响应层 `x-amz-meta-*`/`x-amz-storage-class` 发射缺口**：`put_common_object_headers` 两路共有、预存在，留响应层里程碑。本单元只保证存储两路一致。
- 不改 MetaReconcile/Sidecar/ObjectMeta/Listing 读逻辑。
- 实现者绝不自审：executor 实现 → 独立 verifier/code-reviewer/fidelity 审查。
