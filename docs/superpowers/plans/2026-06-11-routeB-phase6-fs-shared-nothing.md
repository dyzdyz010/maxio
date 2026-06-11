# Route B P6 — FS 单机 shared-nothing（B5-4 入口守卫收口 + B6-1 FS obj-dir/maxio2 sidecar + B6-2 FS 读/列权威 quorum=1）

> 状态：待实现。基线 = 本计划提交。路线图 `plans/2026-06-09-routeB-shared-nothing-metadata.md` B6-1 段。
> 默认行为不变：`authoritative_source` 全 `:pg`、scanner disabled。FS 新布局只在写路径生效，读对旧布局回退兼容——先发布不破坏既有 dev 数据。

## 勘探事实（已核实）

- FS 对象 = **裸单文件** `<data_dir>/<bucket>/<encoded-key>`（null）/ `.versions/<bucket>/<encoded-key>/<version_id>`（版本化）（fs.ex:310-325 object_path）。无任何盘上元数据。
- FS put/assemble 已是 temp→`ShardServer.commit_file` 原子 rename + fsync（fs.ex:83-119, :197-229；B1-2 落地）。
- `FS.put_delete_marker` → `{:error,:not_supported}`（fs.ex:73）；`opts[:object_meta]`（B4-5）FS 收了但忽略。
- `Paths.encode_key`（9747ef4）已消除保留名/空段/尾斜杠碰撞——FS 路径全经它，**obj-dir 布局直接复用**。
- ObjectMeta.sidecar_read / Maxio.Listing / Scanner 全依赖 `endpoints_for`（opts[:topology] 或 `Topology.endpoints/1`，object_meta.ex:608-618）+ Transport callbacks；FS 无拓扑 → `copies==[]` → PG fallback（object_meta.ex:260-267）。
- `Transport.Erpc` 对 `node == Node.self()` 直接本地调 ShardServer（transport.ex:104-119）——合成端点 node 用 `Node.self()` 即零网络、零新 transport。
- ShardServer 的 get_sidecar/put_sidecar/list_dir/commit（含 meta_only）都是纯本地磁盘函数，FS 已直接调用 commit_file——无监督树问题。
- config 默认后端 = FS（config.exs:96）。FS 测试：fs_test / fs_conformance_test / fs_parts_test（per-test 临时 data_dir opts）。

## 架构决策（本计划的 load-bearing 选择）

**FS 采用与 EC/Distributed 同构的 obj-dir 布局**：`<bucket>/<key>/{part.0, meta.json}`、版本 `.versions/<bucket>/<key>/<vid>/{part.0, meta.json}`。
理由：旁侧 `.meta/` 树虽迁移成本低，但 walk 语义（`object?` = 目录含 meta.json）、scanner presence probe、delete-marker meta_only 提交全都适配不了，会长出整套 FS 平行逻辑（违铁律 1/2）。同构布局让 ObjectMeta/Listing/Scanner/SidecarHeal 经**合成单端点 topology**（`data_shards:1, parity_shards:0, write_quorum:1, read_quorum:1, endpoints:[{Node.self(), data_dir}]`）逐字复用，FS 真正成为 shared-nothing 一等公民。
兼容：**读回退**——obj-dir miss 时回退旧单文件路径（File.stat 一次，命中记结构化日志 `legacy_layout`）；delete 双布局都清；旧数据由 P7 B7-1 backfill 收尾迁移。

---

## B5-4 — 对象 key/versionId 入口守卫收口（B5-3 backlog 的 medium + 安全 follow-up）

1. **KeyTooLongError（medium）**：`Paths.validate_key/1` 加长度闸——`byte_size(key) > 1024` → `{:error, :key_too_long}`；`Maxio.S3.Error` 加 `key_too_long: {"KeyTooLongError", 400, "Your key is too long"}`（MinIO ErrKeyTooLongError / AWS 同 Code）；`validate_object_key!` 映射之（区分于 :invalid_key→XMinioInvalidObjectName）。
2. **?versionId 路径守卫（安全）**：客户端 versionId 现在不经校验直接进 `Paths.object_rel` 盘路径（`../..` 滥用面）。单一来源修法：`Maxio.Versioning.VersionId` 加 `valid?/1`（`"null"` 或 26 位 Crockford base32 ULID `^[0-9A-HJKMNP-TV-Z]{26}$`）；handler 在 GET/HEAD/DELETE/Copy 源的 versionId 入口统一校验，非法 → 400 `InvalidArgument` "Invalid version id specified"（AWS/MinIO ErrInvalidVersionID 逐字）。注意：PG 查无此版本的合法形状 versionId 仍走既有 404/NoSuchVersion 语义不变。
3. 测试：>1024B key → 400 KeyTooLongError（恰 1024 通过）；versionId `../x`、`..`、空串、畸形 → 400 InvalidArgument（GET/HEAD/DELETE/copy source 各一）；合法 ULID/null 不受影响；全量无回归。
4. defer（已记 STATUS，不做）：dot-segment Code 换 XMinioInvalidResourceName（low）、HEAD 错误响应头（low）。

## B6-1 — FS obj-dir 布局 + maxio/2 sidecar + delete marker（写侧）

1. **写路径换 obj-dir**：`do_put`/`do_assemble` 改为 temp 目录（`part.0` + `meta.json`）→ `ShardServer.commit`（复用既有 obj-dir 提交原语，含 fsync/meta_only 语义；替换 commit_file）。`part.0` 命名与 EC/Distributed 逐字一致。
2. **sidecar 内容**：v1 core `%{"size","etag","sha256"}`（FS 无 ec/shards——合法，读侧 Sidecar.latest/find_version/to_view 只依赖 versions）经 `Sidecar.migrate_v1(core, version_opts)` 产 maxio/2；`version_opts` 与 EC/Distributed 的同名私有函数逐字一致（从 `opts[:object_meta]` 取 content_type/tags/sse/acl/storage_class/user_metadata + version_id/data_dir/modtime 单次 ns）——FS 从此**不再忽略 object_meta**。
3. **put_delete_marker**：FS 实现之（替换 `:not_supported`）——复用 `Maxio.Storage.DeleteMarker.sidecar/2` + ShardServer 的 meta_only 提交，quorum=1（单盘写成功即 `:ok`）；Suspended null 替换语义与 Distributed 对齐（pre-commit 不破坏、成功后 GC 孤儿 part.0——B5-3 R2 同款不变式）。
4. **读回退**：`do_get`/`stat` 先 obj-dir（`part.0`），miss 回退旧单文件路径（命中 → 结构化日志 `action: :legacy_layout_read`，绝不静默）；`delete` 双布局清理；`copy 源读` 同回退。
5. 测试：FS put→盘上断言 obj-dir + maxio/2 sidecar（format/versions[0] 富字段）；旧布局文件手工放置 → GET/HEAD/DELETE 仍工作 + legacy 日志；fs_conformance 全绿（行为锁定）；put_delete_marker e2e（marker sidecar 落盘 + Suspended 替换）；全量无回归。

## B6-2 — FS 读/列权威（合成单端点 topology，quorum=1）

1. **合成 topology 单一来源**：新增 `Maxio.Storage.FS.local_topology(opts) :: map`（`%{data_shards: 1, parity_shards: 0, block_size: <任意>, sets: %{0 => %{id: 0, endpoints: [{Node.self(), data_dir(opts)}]}}, set_ids: [0]}`——形状与 Topology.endpoints_from 兼容）。`ObjectMeta`/`Listing`/`Scanner` 的 topology 解析（`endpoints_for` / 对应 listing 内部）在「无 opts[:topology] 且全局 Topology 未配置且 backend == FS」时取 `FS.local_topology`（单点新增 helper，如 `ObjectMeta.effective_topology(opts)`，三处复用；其余路径零改动）。
2. **read_quorum/write_quorum = 1** 自然成立（data_shards=1，B4-3 的 `opts[:topology].data_shards` 优先逻辑直接给 1）。
3. **e2e（FS + 翻权威，distributed 范式平移）**：真实签名 PUT（带 metadata/tags/SSE）→ `:read=:sidecar` GET/HEAD 全字段正确；`:list=:sidecar` LIST（含前缀/分页）；DELETE（Enabled 桶 marker + Suspended 替换 + versionId 永久删）→ 不复活/撤销恢复；Scanner `run_once` 在 FS 上 reconcile（PG 缺行 upsert / stale 修正 / 孤儿 GC——quorum=1 下「全端点可达且 :missing」即单盘确认）；`mix maxio.reconcile_index --dry-run` 对 FS 真跑。
4. **versioned latest**：`discover_current_version` 走盘（modtime 排序，545c623 语义）在 FS 单端点同样成立——e2e 覆盖 Enabled 桶 latest 读。
5. 测试矩阵默认配置不变取证：不翻 flag 时 FS 行为与基线字节级一致。

## 验收（每单元独立）
- `mix compile --warnings-as-errors` 零警告；全量 `mix test` 绿；`mix format --check-formatted` exit 0；`git status -s` 干净；默认配置行为不变。
- B6-2 终态：**FS 单机在 `:read/:list/:write=:sidecar` 下完整可用**（真实 PUT/GET/LIST/DELETE/SSE/版本化 e2e 取证）——单机部署同样去 PG SPOF。

## 非目标 / defer
- 旧布局 backfill 迁移（P7 B7-1 统一做，含 EC/Distributed v1 sidecar 升级）。
- FS 多盘（那是 ErasureCoded 的领域）；inline 小对象（路线图后期）。
- dot-segment Code / HEAD 错误头（low，既有 defer）。
- 实现者绝不自审：executor 实现 → 独立 verifier/code-reviewer/fidelity 审查。
