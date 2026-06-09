# Route B B4-5 — 写路径产出 maxio/2 版本化 sidecar（补齐权威翻转的集成临门一脚）

> 状态：待实现。基线 = `20045a1`（P4 B4-1..B4-4 + fidelity 修复 acb4f26 + format-tail 已落地）。
> 默认 `authoritative_source: read/list/write = :pg` 保持不变、字节级可回滚——本单元只让 `:sidecar` 分支对**真实对象**真正可用。

## 1. 根因（非症状）

- `Maxio.Storage.ErasureCoded.build_meta/6`（`lib/maxio/storage/erasure_coded.ex:458`）与
  `Maxio.Storage.Distributed.build_meta/6`（`lib/maxio/storage/distributed.ex:323`）仍产出**扁平 v1 meta**：
  `%{"ec","size","etag","sha256","is_delete_marker","parts","shards"}`——**无 `format:"maxio/2"`、无 `versions` 数组**。
- `Maxio.MetaReconcile.reconcile/3` 经 `Maxio.Sidecar.latest/1`、`Maxio.Sidecar.find_version/2` 取 canonical entry，
  二者均 `when is_list(versions)`——对 v1 扁平 meta 一律返回 `nil`。
- 后果：在**已配置分布式/纠删拓扑** + `authoritative_source(:read)=:sidecar` 或 `:list=:sidecar` 下，
  对**真实 PutObject** 写出的对象：
  - GET → `read_endpoint_sidecars` 拿到 N 份非 `:missing` 的 v1 meta → reconcile 取不到 versioned entry →
    `{:error,:read_quorum}` → **503 ServiceUnavailable（对象在却读不出）**。
  - LIST → `Maxio.Listing` 当前版本/quorum 解析拿不到 versions → 该 key 不计入 → **列举丢对象**。
  即 B4-3/B4-4 翻转的"读/列权威"能力对真实对象**完全不可用**。
- B4 新增 5 个测试**全部手工在盘上构造 maxio/2 sidecar**（带 versions 数组），从不经真实 `Storage.put` 写路径——
  套件全绿但掩盖了写/读权威格式断裂（CLAUDE.md「禁止打补丁/虚假信心」；铁律 1/3/5）。
- 同时关闭 code-review must_fix #2：版本桶 latest 读。acb4f26 已加 `discover_current_version` 走盘发现当前版本目录，
  但该目录里仍是 v1 扁平 meta → reconcile 仍失败；**唯有本单元让发现到的版本产出可用 entry，#2 才真正修复**。

## 2. 修法（架构层，对齐 AGENTS.md §3 + 铁律 1/5）

盘上 sidecar 即事实来源（Route B）。故 `Storage.put` **必须**产出携带 GET/HEAD/LIST 所需全部 S3 元数据的完整 maxio/2 sidecar。
**复用既有桥接** `Maxio.Sidecar.migrate_v1/2`（它逐字保留耐久 ec/shards/size/etag/sha256/parts 核心、仅 `Map.put` 加
`format:"maxio/2"` + 单元素 `versions` 数组——绝不污染耐久字段）。富元数据在 handler 调 `Storage.put` 之前**均已就绪**，
经 `Storage.put/5` 既有的 `opts` 关键字透传——**不改 arity**。

### Step 1 — `Storage.put` 的 opts 契约（`lib/maxio/storage.ex` + behaviour @callback）
- 文档化新 opt `:object_meta`（map）：`%{content_type, tags, sse, acl_canned, storage_class, user_metadata}`，
  其中 `sse` 为 `nil` 或 `%{"algo" => "AES256", "envelope" => <信封>}`（形状必须匹配 `Sidecar.to_view/3` 读
  `e["sse"]["algo"]` / `e["sse"]["envelope"]`）。
- 不改函数签名（opts 已存在）；只更新 `@callback put` 的 typespec/doc。FS 后端可忽略（无多端点拓扑，读权威永不命中 FS）。

### Step 2 — `ErasureCoded.build_meta` → maxio/2（`erasure_coded.ex:458`）
- 构造 v1 core map（保持不变）后，紧接调：
  ```elixir
  Sidecar.migrate_v1(core, version_opts(version_id, opts))
  ```
- 新增私有 `version_opts(version_id, opts)`：从 `opts[:object_meta]`（缺省 `%{}`）取字段，产出 keyword：
  `[version_id: version_id, data_dir: version_id, modtime: <一次性 System.os_time(:nanosecond)>,
    content_type:, tags:, sse:, acl_canned:, storage_class:, user_metadata:]`。
- `build_meta` 须接收 `version_id` 与 `opts`：从 `put/5` → `do_put`/写链 一路透传（增参）。
- **modtime 一次计算**：build_meta 每次 PUT 只调一次、同一份 meta 写所有 drive → N 份 `Sidecar.signature` 逐字一致（已验证）。
- 耐久 core（ec/shards/size/etag/sha256/parts）字节不变（migrate_v1 只加键）——绝不污染。

### Step 3 — `Distributed.build_meta` → maxio/2（`distributed.ex:323`）
- 同 Step 2 变换；分布式同样**单次 build_meta、同一份 meta 发所有端点**（已验证 → signature 一致）。
- 透传 version_id + opts 至 build_meta。

### Step 4 — handler 把 object_meta 透传进 Storage.put（`handlers/object.ex` do_put）
- 用调 `Storage.put` 之前**已算出**的值组 object_meta：content_type（L29）、tags_map（L41）、
  acl_canned（`header(conn,"x-amz-acl")||"private"`）、storage_class（"STANDARD"）、
  sse（`if sse_requested, do: %{"algo"=>sse_requested,"envelope"=>sse_envelope}, else: nil`）、
  user_metadata（PutObject 当前未捕获 `x-amz-meta-*`——用既有 `parse_user_metadata/1` 解析后并入 sidecar，使 sidecar 自描述完整）。
- 把 `Storage.put(bucket, key, version_id, chunks)`（do_put ~L57）改为 `Storage.put(bucket, key, version_id, chunks, object_meta: om)`。
- **PG 索引侧的 `attrs` map（put 返回后构造，~L74）字段保持不变**——`:pg` 默认路径字节级一致、可回滚。
  （决策：不动 PG attrs 已有字段；仅让 sidecar 携带完整元数据。user_metadata 仅注入 sidecar，PG 路径维持原状以零行为变更。）
- **CopyObject 路径**（`Storage.put(dest_bucket, dest_key, dest_version_id, src_stream.stream)` ~L571）同样透传 object_meta
  （此处 content_type/tags/metadata 已解析），使复制对象也写出完整 maxio/2 sidecar。

### Step 5 — 多段上传 complete 路径
- 查 CompleteMultipartUpload 的最终对象 sidecar 是否经 `build_meta` 组装：
  - 若复用 build_meta → 已被 Step 2/3 覆盖（但仍须为它构造 object_meta 并透传）。
  - 若自有 meta 组装逻辑 → 同样产出 maxio/2 并透传 object_meta。
- 多段对象也必须 sidecar-可读/可列。若一单元内确实够不到，**显式在 notes 记为 B4-6 跟进**（绝不静默截断）。

### Step 6 — 真实 PUT 端到端回归（必须；替换手搓 fixture）
新建 `test/maxio/routeb_real_put_sidecar_authority_e2e_test.exs`：
- setup：distributed 后端 + InProcess transport + 注入 3 端点 topology（复用
  `test/maxio/object_meta_read_authority_test.exs` setup 的临时 3 drive 目录手法），但**驱动真实 `Storage.put`**。
- **Case A（Unversioned）**：`Storage.put("rb","k","null", chunks, object_meta: om, transport: InProcess, topology: topo)`，
  真实 body → 解码盘上 sidecar 断言 `format=="maxio/2"`、`versions[0]` 含 version_id="null"/content_type/etag/size/tags；
  再 `ObjectMeta.get("rb","k",nil, [authoritative_source:[read: :sidecar], transport:, topology:])` → 返回
  `%Object{}` 且 etag/content_type/size/tags 正确（**不是** `{:error,:read_quorum}`）；
  再 `Listing.list_objects_v2("rb", %{}, [authoritative_source:[list: :sidecar], transport:, topology:])` →
  key 出现且 ETag 非空、Size 正确。
- **Case B（Versioned/Enabled）**：真实 `Storage.put("rb","k", <ULID>, chunks, ...)` 落 `.versions/...` →
  `ObjectMeta.get("rb","k", nil, read=:sidecar)`（latest、无 versionId）→ 返回对象（证 discover_current_version +
  maxio/2 reconcile 共同解析当前版本，**关闭 must_fix #2**）；显式 versionId GET 也返回。
- **Case C（SSE）**：真实 SSE PUT（om.sse 置位）→ read=:sidecar GET → sse_envelope 随视图携带、解密成功（无 unwrap_dek(nil) 崩 500）。
- 全部经**真实写路径**取证 write→sidecar→read/list 集成；**严禁手搓 sidecar**。

## 3. 验收（Acceptance）
- `mix compile --warnings-as-errors` 零警告。
- 新 e2e 全过：真实 PUT → 翻 read/list=:sidecar，Unversioned + Versioned + SSE 均成功读/列。
- 全量 `mix test` 绿、无回归；`mix format --check-formatted` exit 0。
- 默认 `read/list/write:=:pg` 字节级一致（既有 S3/listing 用例全绿）；每个 sidecar 的 v1 耐久核心不变。
- 解码一个真实 PUT 写出的 sidecar，可见 `format:"maxio/2"` + `versions[0]` 携带富字段。

## 4. 非目标 / 注意
- **不改** MetaReconcile / Sidecar / ObjectMeta 的读逻辑（它们已正确，只是此前缺 v2 输入）。
- **保持 PG `:pg` 路径字节级一致**（可回滚）。
- 多段 complete 若 meta 组装独立且过大，覆盖之 OR 显式记 B4-6 跟进（不静默截断）。
- 实现者绝不自审：本单元由 executor 实现、独立 verifier/code-reviewer/fidelity 审查。
