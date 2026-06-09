# Route B B4-7 — 用户元数据 2KB 上限含 x-amz-meta- 前缀（修 B4-6 fidelity 残留 medium + docstring low）

> 状态：待实现。基线 = `583697a`（B4-6 exec），**含未经独立 code-review 的 fidelity-fix `f856c7e`**——本单元基线设在 583697a，使 review/fidelity 一并覆盖 f856c7e（补上它缺的独立审查）+ 本次修改。
> 默认 `:pg` 不变；本单元只收紧元数据大小边界、订正注释，不动读逻辑、不动耐久字节。

## 偏离清单与定级（B4-6 fidelity 审计残留）

| # | 偏离 | 严重度 | 本单元 |
|---|---|---|---|
| E1 | `Maxio.Metadata.validate_size!/1` 在**剥掉 `x-amz-meta-` 前缀后**对 name 计字节 → 比 MinIO 每头少算 11 字节，边界请求（如 d2b：`x-amz-meta-big` + 2045B 值 = maxio 算 2048 接受、MinIO 算 2059 拒）被错误接受 | medium | ✅ 修 |
| E2 | `metadata.ex` / `error.ex` 注释引用**不存在**的 s3-tests 函数 `test_object_set_get_metadata_overflow_*` 作阈值权威 | low | ✅ 顺手修（同文件、诚实性） |
| E3 | 缺 8 KB 总请求头上限 + 不识别 `x-minio-meta-` 前缀（MinIO 两者皆 → MetadataTooLarge，在中间件层） | low | ⏸ defer（中间件 scope，文档化） |

## 修法（架构层，对齐 MinIO `cmd/generic-handlers.go` `isHTTPHeaderSizeTooLarge`，铁律 5）

### E1 — 计入 `x-amz-meta-` 前缀（对齐 MinIO `len(key)+len(value)`，key 含前缀）
- MinIO：`length := len(fullHeaderKey) + len(value)`，`fullHeaderKey` 含 `x-amz-meta-` 前缀；`usersize > maxUserDataSize(=2*1024)` → 400。AWS UsingMetadata 亦述前缀属规范 key。
- maxio 现状：`Maxio.Metadata.validate_size!/1`（`lib/maxio/metadata.ex:25-36`）对 `%{stripped_name => value}` 求 `byte_size(name)+byte_size(value)`，name 已被 `parse_headers/1` 去掉 `"x-amz-meta-"` 前缀 → 每头少算 `byte_size("x-amz-meta-")=11`。
- 修：在求和时每条 entry 加回前缀长度——`acc + byte_size("x-amz-meta-") + byte_size(k) + byte_size(v)`（或让 `parse_headers/1` 之外保留原始 header 名传入 validate_size!；首选前者，改动小且语义明确：常量 11）。阈值仍严格 `> 2048`。
- **同步订正 B4-6 测试 d2b**（`test/maxio/routeb_b4_6_metadata_fidelity_test.exs`）：原断言 `x-amz-meta-big`+2045B→200（编码了错误边界）。改为：`x-amz-meta-big`（key=3，含前缀 14）+ **2034B 值**（14+2034=2048）→ 200；**2035B 值**（14+2035=2049）→ 400 MetadataTooLarge。使边界镜像 MinIO。
- 复核 d2a/d2c/d4f 等其它 D2 用例：若其值远超/远低于 2048 不受 11 字节影响则无需改；若恰在边界须按新算法调整断言（executor 核对每个）。

### E2 — 订正注释引用
- `lib/maxio/metadata.ex:7` 与 `lib/maxio/s3/error.ex:51` 删除 `s3-tests test_object_set_get_metadata_overflow_*` 引用（ceph/s3-tests 无此函数），替换为真实权威：
  - AWS UsingMetadata.html（user-defined metadata 限 2 KB / 每个 key+value 的 UTF-8 字节和）；
  - minio/minio `cmd/generic-handlers.go` `isHTTPHeaderSizeTooLarge`（`maxUserDataSize = 2*1024`，key 含前缀）。

## 验收
- `mix compile --warnings-as-errors` 零警告。
- E1 测试：`x-amz-meta-big`+2034B → 200；+2035B → 400 `MetadataTooLarge`（边界镜像 MinIO，含前缀计量）。
- 全量 `mix test` 绿、无回归；`mix format --check-formatted` exit 0。
- 默认 `:pg` 既有用例全绿；不改任何耐久字节/读逻辑。

## 非目标 / defer（文档化，绝不静默）
- **E3（low）defer**：8 KB 总请求头上限 + `x-minio-meta-` 前缀——属 HTTP 中间件 scope（MinIO 在 `setRequestLimitMiddleware` 层），非写路径 handler。留「请求管线 plug 镜像 isHTTPHeaderSizeTooLarge」跟进里程碑（届时：总头 >8192→MetadataTooLarge 400，user-metadata 前缀集含 `x-minio-meta-`）。已记 STATUS。
- **系统头 follow-up**（B4-6 semantics-lens notes 提出，未计为偏离）：PutObject/CopyObject/MPU 未捕获/回显 `Content-Disposition`/`Content-Encoding`/`Cache-Control`/`Expires`——真实 S3/MinIO 对象系统元数据。留响应/写路径系统头里程碑。已记 STATUS。
- 不改 MetaReconcile/Sidecar/ObjectMeta/Listing 读逻辑。实现者绝不自审。
