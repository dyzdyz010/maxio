# Route B B5-3 — P5 fidelity/review 残留收口（2 medium 修复 + scanner 生产前置硬化 + 顺手 low）

> 状态：待实现。基线 = `3bd9e93`（P5 三单元 + review-fix 34a8ae9 + fidelity-fix 545c623 + format-tail 已落地，precommit 取证中）。
> 来源：P5 独立 review（APPROVE_WITH_NOTES 非阻塞 notes）+ fidelity 审计（critical/high 已修，medium/low 残留）。
> 默认行为不变（scanner disabled、prefer 门控关、`:pg` 权威）；本单元只收口残留。

## 残留清单与归处

| # | 来源 | 内容 | 严重度 | 本单元 |
|---|---|---|---|---|
| R1 | fidelity ×2 lens | **Scanner reconcile 把 objects.updated_at 写成扫描时刻** → 客户端可见 Last-Modified / `<LastModified>` 漂移（reconcile/backfill 后同一对象 Last-Modified 变成 scanner 跑批时间，违 S3 不可变语义） | medium | ✅ 修 |
| R2 | fidelity + review note#1 | **Suspended + `:sidecar` 权威的破坏窗口**：`commit_delete_marker_sidecar` 先 `Storage.delete(bucket,key,"null")` 再写 marker；若 marker quorum 失败 → 503 但 null 版本已毁（GET 变裸 404 直至重试） | medium | ✅ 修 |
| R3 | review note#2 | **保留布局名段 key**（含 `meta.json`/`part.0`/`.versions`/`.uploads`/`.tmp` 段）可经 Storage.put 写入但 list_dir 枚举不到 → **reverse-GC 会把其有效 PG 行当孤儿删掉**、forward 永远加不回——「scanner 生产启用前必须修」 | 前置硬化 | ✅ 修 |
| R4 | fidelity low | key 含 `.`/`..` 段在新 delete-marker 路径 500 InternalError（MinIO 返 400 `XMinioInvalidObjectName`） | low | ✅ 顺手（与 R3 同处） |
| R5 | review note#4 | 覆盖缺口：HTTP DeleteObject `:sidecar` 分支（成功 + quorum 失败→503 SlowDownWrite）只在 Storage 原语级被测 | 测试 | ✅ 补 |
| R6 | review note#5 | `Distributed.put_delete_marker` 的 `version_id \\ "null"` 默认参（ErasureCoded 无）诱发误写 null marker | minor | ✅ 顺手（删默认参对齐） |
| R7 | fidelity | `read_prefer_index=true` 无新鲜度保证（启用时可短暂供 stale 行） | medium | ⏸ defer：门控默认关即是设计（fidelity 自评 correctly gated）；P7-2 shadow 驱零取证后 P7-3 才开。文档化，不改代码 |
| R8 | fidelity low | 锁竞争/marker 路径 503 Code `SlowDown` vs MinIO `RequestTimeout`；Suspended DELETE 头部细节 | low | ⏸ defer（与既有同款 low 列表合并） |

## 修法

### R1 — reconcile 的 updated_at 取 sidecar modtime（Last-Modified 不漂移）
- `Objects.reconcile_from_sidecar/3` 的 `@reconcile_replace` 集当前把 `updated_at` 写成 now。改为：从 canonical entry 的 `modtime`（int64 ns）导出 `DateTime.from_unix(modtime, :nanosecond)` 作为 `updated_at`（即对象真实写入时刻；与 `ObjectMeta` 读路径 `entry_modtime_to_datetime/1` 同源语义，可复用/提为共享辅助）。modtime 缺失（异常 sidecar）→ 保留行内既有 updated_at（已有行）或 now（新插，记 divergent 日志）。
- `synced_at`（同步确认时刻）继续用 now——它就是干这个的；只有 `updated_at`（客户端可见 Last-Modified 来源）必须忠于对象写入时刻。
- 测试：reconcile 后 GET/HEAD Last-Modified == 原 PUT 时刻（落在 sidecar modtime），不等于 scanner 跑批时刻。

### R2 — Suspended `:sidecar` 破坏窗口消除（review 给的修法）
- `meta_only` commit 本就**原子 rename meta.json 覆盖**旧对象 sidecar——null 路径的 marker 提交天然替换旧 sidecar。故重排序：**先 put_delete_marker（quorum 闸）**；成功后再 best-effort GC 孤儿 `part.0`（旧 null 版本字节；失败仅日志，孤儿由既有 reverse-GC/heal 渠道收）。quorum 失败 → 503 时旧对象完好（GET 仍 200 旧对象——优于裸 404，重试收敛）。
- `:pg` 权威分支顺序已由 34a8ae9 修正（PG 提交先于破坏性删除），核对一致性不回归。
- 测试：注入 quorum 失败（down 端点）→ 503 且旧 null 对象仍可读；成功路径 → marker 生效 + part.0 被 GC。

### R3+R4 — `Paths.object_rel` 拒绝保留段与点段（scanner 生产前置）
- `Maxio.Cluster.Paths.object_rel/3`（所有盘上路径的单一来源）对 key 按 `/` 分段校验：任一段 ∈ {`meta.json`,`part.0`,`.versions`,`.uploads`,`.tmp`} 或 ∈ {`.`,`..`} 或空段 → `{:error, :invalid_key}`（已有该错误形态）。
- handler 层把 `{:error,:invalid_key}` 映射 400（对齐 MinIO `XMinioInvalidObjectName`；error.ex 若无则加 code，描述对齐 MinIO）。覆盖 PUT/GET/HEAD/DELETE/Copy 源与目标（它们全经 object_rel）。
- 注意：`part.0` 形如 `part.N` 的其它名不拦（仅精确保留名）；大小写敏感按精确匹配（盘上布局是精确名）。
- 测试：PUT key `a/meta.json/b` → 400；GET/DELETE 同；`a/./b`、`a/../b` → 400 不再 500；正常含点 key（`a.b/c.d`）不受影响；既有套件无回归（确认现网测试无使用保留段的 key）。

### R5 — endpoint 级 `:sidecar` DELETE e2e
- 签名 DELETE（Enabled 桶，`:write=:sidecar`，distributed+InProcess+topology）：成功 → 204 + x-amz-delete-marker:true + `:read=:sidecar` GET 404；注入 quorum 失败 → **503 SlowDownWrite**（Code 断言）。

### R6 — 删 `Distributed.put_delete_marker` 的 `version_id \\ "null"` 默认参，与 ErasureCoded/behaviour 对齐（调用方全部显式传 version_id）。

## 验收
- `mix compile --warnings-as-errors` 零警告；全量 `mix test` 绿；`mix format --check-formatted` exit 0；`git status -s` 干净。
- R1：reconcile 后 Last-Modified 忠于对象写入时刻（测试断言）。
- R2：quorum 失败 503 时旧对象完好；成功后孤儿 part.0 被收。
- R3/R4：保留段/点段 key → 400 结构化错误（非 500），正常 key 无回归。
- R5：endpoint 级 :sidecar DELETE 成功/503 双断言。
- 默认配置行为不变。

## 非目标 / defer（文档化）
- R7 prefer 新鲜度（P7-2/P7-3 范畴）；R8 SlowDown-vs-RequestTimeout 等 low（既有 defer 列表）。
- 不动 MetaReconcile/Sidecar 核心读逻辑。实现者绝不自审。
