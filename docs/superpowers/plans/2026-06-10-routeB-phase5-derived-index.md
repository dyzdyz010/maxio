# Route B P5 — PG 降为受维护的派生索引（B5-0 删除标记落盘 + B5-1 索引列/全分流 + B5-2 Scanner/reverse-GC）

> 状态：待实现。基线 = `9cc8b4f`（B4-7 收敛后）。路线图：`plans/2026-06-09-routeB-shared-nothing-metadata.md` P5 段 + 全局命名契约。
> 默认 `authoritative_source: read/list/write = :pg` 不变；`:scanner.enabled` 默认 false；`:read_prefer_index` 默认 false——**先发布不改行为，全部可回滚**。
> 每单元串行、独立提交、绝不并行 mix 编译。

## 勘探事实（已核实，executor 直接引用）

- `lib/maxio/objects/object.ex:10-29`：objects schema 无 `synced_at`/`index_generation`；unique index `[:bucket_id,:key,:version_id]`。
- 写路径 PG 入口：`Objects.put_version_with_id/4`（objects.ex:170，致命）/ `put_version_index/4`（:233，best-effort）/ `put_metadata/2`（:34，MPU complete 用）/ `insert_delete_marker/3`（:248）/ `delete_metadata/2`（:148）/ `delete_version/3`（:288）。
- handler 分流现状：仅 do_put 的 `commit_metadata/4`（s3/handlers/object.ex:~700）按 `authoritative_source(:write)` 分流；**CopyObject（:613）/ MPU complete（multipart.ex:116）/ DELETE 三分支（object.ex:309-366）全部无条件走 PG 致命路径**。
- **критical 缺口（B5-0 的根因）**：`insert_delete_marker` 纯 PG；`build_meta` 恒 `"is_delete_marker"=>false`；全仓无盘上 delete-marker sidecar 写。`:read/:list=:sidecar` 下 DeleteObject 后盘上 sidecar 仍是旧对象 → **GET 仍 200（应 404+x-amz-delete-marker）、LIST 仍列出 = 已删对象复活**。读侧已就绪：`ObjectMeta.view_or_not_found` 处理 `type=="delete_marker"` entry（latest marker→404+头；显式 versionId→405）、`Maxio.Listing` 当前版本解析排除 delete marker——B4-3/B4-4 已建，只缺写侧落盘。
- `Maxio.Sidecar.to_object_attrs/3`（sidecar.ex:162）已是 sidecar→PG attrs 桥。`Sidecar.put_version_entry/2`、`signature/1` 可复用。
- Scanner 完全缺失；`lib/maxio/application.ex:10-21` children 无周期任务；config 无 `:scanner` 键。
- 测试范式：`test/maxio/routeb_real_put_sidecar_authority_e2e_test.exs:29-72`（distributed+InProcess+注入 3 端点 topology K=2/M=1/N=3，Application.put_env 切后端 + on_exit 还原）。

---

## B5-0 — DeleteObject/DeleteObjects 写盘上 delete-marker sidecar（sidecar 权威的删除完整性）

**根因修法（架构层）**：删除是写操作；sidecar 为事实来源则**删除必须被盘上权威记录**。

1. **Storage behaviour 新 callback**（铁律 1）：`put_delete_marker(bucket, key, version_id, entry_opts, opts) :: :ok | {:error, term}`（或等效命名；executor 可定签名但须 behaviour 级）。语义：在 `version_id` 对应盘上路径写一个**纯 delete-marker maxio/2 sidecar**（`%{"format"=>"maxio/2","versions"=>[entry]}`，entry `type="delete_marker"`/`version_id`/`modtime`(单次 ns)/`generation:0`/`is_latest:true`，无 part.0 字节、无 ec/shards 耐久 core——delete marker 无字节，合法），写到 write_quorum 个端点（temp→rename 原子，与 PUT 同级耐久），不足 quorum → `{:error,:write_quorum}` → handler 503 SlowDownWrite（绝不静默）。
   - **Distributed + ErasureCoded** 实现（复用 begin_tmp/put_sidecar/commit 或 ShardServer.put_sidecar + temp-rename 既有原语；modtime 单次计算所有端点同值 → signature 一致）。
   - **FS** 后端：`{:error, :not_supported}` 或 no-op `:ok` + 注释「FS sidecar = B6-1 接线」——显式文档化（铁律 3），FS 仅在 `:pg` 权威下使用故无正确性影响。
2. **handler delete（object.ex:339-347 Enabled/Suspended 分支）+ DeleteObjects 批量对应分支**：在对象锁内，**先**盘上 `Storage.put_delete_marker`（quorum 致命）**再** PG `insert_delete_marker`（`authoritative_source(:write)==:sidecar` 时 PG 降 best-effort：失败 Log.error 不致命；`:pg` 默认时维持现状致命）——顺序与 do_put 一致（盘先 PG 后、同锁）。
   - **Suspended 桶**：null delete marker **替换**既有 null 版本（AWS 语义）——先删 null 版本字节+sidecar（`Storage.delete(bucket,key,"null")` 已有）再写 marker sidecar 到 null 路径；PG 侧 `insert_delete_marker` 的 Suspended 语义已有、不动。
   - **versionId 指定删除**（永久删，含删 marker 本身）已有 `Storage.delete(bucket,key,version_id)` 落盘——不动。Unversioned 真删已落盘——不动。
3. **e2e 取证（必须，distributed+InProcess+topology 范式）**：真实 PUT（Enabled 桶）→ 真实 DELETE（无 versionId，插 marker）→ `:read=:sidecar` GET → **404 + x-amz-delete-marker:true**（不再复活）；`:list=:sidecar` LIST → key 不出现；DELETE 指定 marker 的 versionId（撤销删除）→ GET 恢复 200。Suspended 桶 null marker 替换案例。DeleteObjects 批量同断言。

## B5-1 — objects 加 synced_at/index_generation + 写路径全 best-effort 分流 + PREFER 索引读门控

1. **迁移**（`mix ecto.gen.migration add_index_sync_to_objects`，铁律 6 中文 COMMENT）：
   - `synced_at :utc_datetime_usec, null: true` —— COMMENT「派生索引最后一次与盘上 sidecar 权威同步的时刻；NULL=尚未经 scanner 确认」。
   - `index_generation :bigint, default: 0` —— COMMENT「同步时对应的 sidecar 版本 generation，scanner 判 stale 用」。
2. **写路径注入**：`put_version_with_id`/`put_version_index`/`put_metadata`/`insert_delete_marker` 统一在写入时设 `synced_at: DateTime.utc_now()`、`index_generation:`（来自 attrs/entry generation，PUT 路径当前恒 0）。
3. **best-effort 分流补全**（与 do_put `commit_metadata` 模式逐字一致；`:pg` 默认分支字节级不变）：
   - **CopyObject**（object.ex:613）：`:write==:sidecar` → `put_version_index` best-effort + 内存构造响应视图（仿 `build_put_view`）。
   - **MPU complete**（multipart.ex:116）：`:write==:sidecar` → `put_metadata` 失败降 Log.error 非致命（盘上 assemble sidecar 已权威）。
   - DELETE 的分流 B5-0 已做。
4. **命名契约函数**（B5-2 复用）：`Objects.mark_synced/4`（bucket,key,version_id,generation → 更新 synced_at/index_generation）、`Objects.reconcile_from_sidecar/3`（bucket,key,entry → `Sidecar.to_object_attrs` upsert + mark_synced，`:ok | {:error,term}`）、`Objects.stale?/2`（PG row vs sidecar entry：generation 或 signature 字段不一致）。
5. **PREFER 索引读门控（默认关）**：config 加 `config :maxio, :read_prefer_index, false`。`ObjectMeta.get` 在 `authoritative_source(:read)==:sidecar` **且** `read_prefer_index==true`（opts 可覆盖）时：先 `pg_read`，命中即返回（快路径，scanner 维护新鲜度）；miss → 走盘 sidecar_read（现有路径）。默认 false = 纯走盘正确性优先，P7-3 cutover 经 shadow 驱零取证后才开。**LIST 的 PREFER 显式 defer 到 P7**（续点 token 形态不同，文档化，不静默）。
6. 测试：分流矩阵（copy/MPU × :pg/:sidecar × PG 成败）+ prefer 门控（命中/miss/默认关行为不变）+ 迁移列注入断言。

## B5-2 — Maxio.Storage.Scanner（reconcile 索引 + reverse-GC 孤儿）+ mix maxio.reconcile_index

1. **config**：`config :maxio, :scanner, enabled: false, interval_ms: 86_400_000, batch_size: 500`。
2. **`Maxio.Storage.Scanner`**（GenServer，挂 `application.ex` children；`enabled: false` 时启动但不调度（或不启动），显式日志声明状态）：每 interval 一轮：
   - 遍历 buckets（PG）→ 每桶经 `Maxio.Listing` 走盘原语分页（batch_size）枚举对象+版本 → 每版本 quorum reconcile 出 canonical entry：
     - PG 行缺失或 `stale?/2` → `reconcile_from_sidecar/3` upsert + 结构化日志（`action: :reconcile_index`）。
     - **reverse-GC**：PG 有行但盘上无 → **仅当**该版本所有端点**全部可达且全部显式 :missing**（任一端点 down/异常 → skip + 日志，绝不猜，铁律 3）→ 删 PG 行 + 日志（`action: :reverse_gc`）。
   - 每轮汇总报告日志：scanned/upserted/gc/skipped/divergent 计数。
3. **`mix maxio.reconcile_index`**（CLI+日志铁律）：手动触发一轮；`--dry-run`（只报告绝不写）、`--bucket <name>` 过滤；打印结构化报告。
4. 测试（DataCase + InProcess+topology）：三场景——PG 缺行（盘上有）→ upsert；PG stale（generation 落后/字段漂移）→ 修正；PG 孤儿行（盘上 quorum 确认不存在）→ GC；端点 down → skip 不删；dry-run 零写入。

## 验收（每单元独立）
- `mix compile --warnings-as-errors` 零警告；全量 `mix test` 绿无回归；`mix format --check-formatted` exit 0；`git status -s` 干净。
- B5-0 e2e：`:sidecar` 权威下删除不复活（404+marker 头 / LIST 不出现 / 撤销恢复）。
- B5-1：默认行为字节级不变（`:pg` 全绿 + prefer 默认关）；迁移列含中文 COMMENT（docker exec maxio-db psql 取证）。
- B5-2：scanner 三场景 + dry-run + skip-on-down 取证；`mix maxio.reconcile_index --dry-run` 真跑通。

## 非目标 / defer（文档化）
- LIST 的 PREFER 索引快路径（P7-3）；FS 后端 sidecar/delete-marker（B6-1）；backfill 既有 v1 对象（B7-1）；scanner 限流/采样精细化（M7 deferral 既有条目）。
- 不改 MetaReconcile/Sidecar 读逻辑核心。实现者绝不自审。
