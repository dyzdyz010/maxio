# ROUTE B 阶段 4 实现计划 · maxio（翻转权威 —— 去 PG SPOF 临门一脚）

> orchestrator 直接编写（规划文档；网络对长 subagent 不稳定）。串行 **B4-1 → B4-2 → B4-3 → B4-4**，逐单元 TDD + 独立提交。**最高风险阶段**：一旦翻读/列权威，sidecar 必须始终写全、reconcile 错误成真实 5xx。故顺序铁律——**先把"写全 + 自愈"做扎实（B4-1/B4-2），再翻读权威（B4-3）、再翻列权威（B4-4）**，每步 feature flag 可独立回滚。
> 每条 mix 前置 `$env:Path = 'C:\Users\dyz\Documents\dev\usr\Elixir\bin;' + $env:Path; $env:ERL_FLAGS='-kernel standard_io_encoding unicode';`。每单元末 `git status` 干净 + `mix format --check-formatted` 退出 0 + `mix compile --warnings-as-errors` 零警告 + `mix test` 全量绿（基线 658）。commit footer：`Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`。

## Goal

把对象元数据权威从「Postgres」**真正翻转**到「sidecar」，PG 降为可选派生索引，消除 PG 单点故障 + 双写/孤儿整类问题：

1. **B4-1 sidecar heal 回写**：P2 reconcile 出的 divergent 端点（stale/missing/corrupt sidecar），用权威副本经 temp-then-rename 写回（复用 B1-2 原子提交 + M6/M7 heal 机制）。读路径检测即调度（best-effort、绝不阻塞）。
2. **B4-2 写路径 PG→best-effort 索引**：sidecar 已是写路径的权威载体（写全 N 端点，达 write_quorum 才算成功）；`Objects.put_version_with_id` 改为 best-effort 索引更新——失败**非致命**（记结构化日志 + 标 `synced_at` 滞后），绝不因 PG 故障让写失败（去 SPOF 关键）。
3. **B4-3 翻转读权威**：`authoritative_source(:read)==:sidecar` 时，`ObjectMeta.get` 返回 reconcile 的 sidecar 视图（而非 PG）；reconcile `{:error,:read_quorum}` → 真实错误（对象不可读，绝不猜）；sidecar 未找到 → not_found。PG 仅作"sidecar 端点全不可达"时的降级 fallback（记日志）。默认仍 `:pg`，flag 切 `:sidecar` 灰度。
4. **B4-4 翻转列权威**：`authoritative_source(:list)==:sidecar` 时，ListObjectsV2 返回 drive-walk 结果（强制每对象 quorum 确认，去掉 P3 shadow 的"命中≥1 即收"宽松门）。默认仍 `:pg`。

**残留 PG 依赖（诚实文档化）**：IAM/access_keys、bucket_policies、bucket_configs（配置面，低频、较小 SPOF）本阶段**仍在 PG**（去配置面 SPOF 留后续）。对象元数据面（buckets 对象列举/对象元数据）P4 后 sidecar 权威。`Maxio.Console.Stats` 等仍读 PG 索引（best-effort，可能滞后）。

**显式 DEFER**：去配置面 PG SPOF（IAM/policy/config sidecar 化）→ 后续；真·流式惰性走盘 → 后续；ListObjectVersions 翻权威 → 随后续（B4-4 仅 ListObjectsV2）。

## 全局命名契约（P4 新增；既有逐字复用）

**既有**：`Maxio.ObjectMeta`（`authoritative_source/1`、`get/4`、`shadow_check/5`、`list_shadow/3`、私有 `pg_read/3`、`do_shadow`、`read_endpoint_sidecars/4`、`endpoints_for/3`、`read_quorum/1`）；`Maxio.MetaReconcile.reconcile/3`；`Maxio.Sidecar`（`to_view/3`、`signature/1`、`latest/1`、`find_version/2`、`encode/1`）；`Maxio.Cluster.Transport`（`get_sidecar`、`put_sidecar`、`begin_tmp`、`commit_object`、`heal_shard`、`list_dir`）；`Maxio.Cluster.Paths.object_rel/3`、`Topology.endpoints/1`、`Router.set_for/2`；`Maxio.Storage.Erasure.Config.read_quorum`；`Maxio.Objects.{put_version_with_id/4, get_metadata/2, get_version/3, mark_synced/4?}`；`Maxio.S3.Log.{warn,error}`。
**P4 新增**：`Maxio.SidecarHeal.heal_divergent/4`（B4-1）；`Maxio.Objects.put_version_index/4`（B4-2，best-effort 索引写）；`ObjectMeta.get` 翻权威分支（B4-3）；`ObjectMeta.list/3` + handler 翻列权威（B4-4）。

---

## 单元 B4-1 — `Maxio.SidecarHeal`（divergent 端点回写）

**目的**：P2 `MetaReconcile` 返回的 `divergent` 端点索引（其 sidecar 缺失/陈旧/损坏），用权威 canonical sidecar 经 temp-then-rename 原子写回。读路径 reconcile 检测到 divergent 即 best-effort 调度（绝不阻塞读、绝不因 heal 失败影响读）。

### 设计（铁律 2/3）

- 输入：`bucket, key, version_id, %{canonical_meta, divergent_endpoints, endpoints}`（endpoints = 该对象 set 的有序 `{node, drive}` 列表）。
- 对每个 divergent 端点：`Transport.begin_tmp(node, drive_root)` → 写 canonical sidecar 到 temp（`put_sidecar`）→ `commit_object`（temp-then-rename，复用 B1-2）。**仅 heal sidecar 元数据**（数据分片 heal 是 M6/M7 既有机制，本单元不碰）。
- best-effort：单端点 heal 失败 → 记 `Log.warn`，继续其他端点；返回 heal 成功端点数。绝不 raise 进读路径。
- 接线：`ObjectMeta.do_shadow`（P2）在 reconcile 出 `divergent != []` 时，当前仅记日志；B4-1 改为 `Task.start`（或同进程 best-effort）调 `SidecarHeal.heal_divergent`（不阻塞读响应）。

### 步骤 1（TDD 红）：`test/maxio/sidecar_heal_test.exs`

```elixir
defmodule Maxio.SidecarHealTest do
  use ExUnit.Case, async: false
  alias Maxio.{SidecarHeal, Sidecar}
  alias Maxio.Cluster.Transport.InProcess

  setup do
    InProcess.setup!()
    eps = for i <- 0..2, do: {:"shn#{i}", Path.join(System.tmp_dir!(), "sh_d#{i}_#{System.unique_integer([:positive])}")}
    on_exit(fn -> Enum.each(eps, fn {_n, d} -> File.rm_rf(d) end) end)
    {:ok, eps: eps}
  end

  defp meta(vid), do: %{"format" => "maxio/2", "versions" => [%{"version_id" => vid, "type" => "object", "modtime" => 5, "generation" => 1, "etag" => "\"e\"", "size" => 3}]}

  # 在端点写对象目录（含 sidecar）
  defp put_sidecar(drive, bucket, key, m) do
    dir = Path.join([drive, bucket, key]); File.mkdir_p!(dir)
    File.write!(Path.join(dir, "meta.json"), Sidecar.encode(m))
  end

  test "heal_divergent 把权威 sidecar 写回缺失/陈旧端点", %{eps: eps} do
    canon = meta("v1")
    # 端点 0/1 有权威；端点 2 缺失（divergent）
    [{_n0, d0}, {_n1, d1}, {_n2, d2}] = eps
    put_sidecar(d0, "b", "k", canon)
    put_sidecar(d1, "b", "k", canon)
    refute File.exists?(Path.join([d2, "b", "k", "meta.json"]))

    info = %{canonical_meta: canon, divergent_endpoints: [2], endpoints: eps}
    n = SidecarHeal.heal_divergent("b", "k", "null", info, transport: InProcess)
    assert n == 1
    assert File.exists?(Path.join([d2, "b", "k", "meta.json"]))
    {:ok, healed} = InProcess.get_sidecar(:"shn2", Path.join([d2, "b", "k"]))
    assert healed == canon
  end

  test "单端点 heal 失败不抛、返回成功计数", %{eps: eps} do
    canon = meta("v1")
    InProcess.set_down(:"shn2")   # 端点 2 不可达
    info = %{canonical_meta: canon, divergent_endpoints: [2], endpoints: eps}
    assert 0 = SidecarHeal.heal_divergent("b", "k", "null", info, transport: InProcess)
    InProcess.set_up(:"shn2")
  end
end
```

跑：`mix test test/maxio/sidecar_heal_test.exs` → 红（模块未定义）。

### 步骤 2（实现绿）：`lib/maxio/sidecar_heal.ex`

```elixir
defmodule Maxio.SidecarHeal do
  @moduledoc """
  ROUTE B P4 —— 把权威 canonical sidecar 写回 divergent（缺失/陈旧/损坏）端点。
  复用 B1-2 原子提交（begin_tmp → 写 temp → commit_object 的 temp-then-rename）。best-effort：
  单端点失败记 Log.warn 并继续，绝不 raise 进读路径（铁律 3 不静默 + 不阻塞读）。仅 heal sidecar
  元数据；数据分片 heal 走 M6/M7 既有机制。
  """
  alias Maxio.Cluster.Paths
  alias Maxio.S3.Log

  @spec heal_divergent(String.t(), String.t(), String.t(), map(), keyword()) :: non_neg_integer()
  def heal_divergent(bucket, key, version_id, %{canonical_meta: canon, divergent_endpoints: divs, endpoints: endpoints}, opts) do
    transport = Keyword.get(opts, :transport, Maxio.Cluster.Transport.impl(opts))

    case Paths.object_rel(bucket, key, version_id || "null") do
      {:ok, rel} ->
        Enum.reduce(divs, 0, fn idx, acc ->
          case Enum.at(endpoints, idx) do
            {node, drive} -> acc + heal_one(transport, node, drive, rel, canon, bucket, key)
            _ -> acc
          end
        end)

      {:error, _} ->
        0
    end
  end

  defp heal_one(transport, node, drive, rel, canon, bucket, key) do
    final_dir = Path.join(drive, rel)

    with {:ok, tmp} <- transport.begin_tmp(node, drive),
         :ok <- transport.put_sidecar(node, tmp, canon),
         :ok <- transport.commit_object(node, tmp, final_dir, fsync: durability_fsync()) do
      1
    else
      other ->
        Log.warn("sidecar heal failed", bucket: bucket, key: key, node: inspect(node), reason: inspect(other))
        0
    end
  end

  defp durability_fsync, do: Application.get_env(:maxio, :durability, fsync: false) |> Keyword.get(:fsync, false)
end
```

> 实现注意：executor 核对 `Transport.commit_object/4` 实际签名（B1-2 落地形态）——若 `commit_object(node, tmp_dir, final_dir, opts)`，则上面一致；若 sidecar-only commit 需专门路径（commit 默认同时 rename part.0），executor 视 commit_object 是否容忍"只有 meta.json 无 part.0 的 temp"调整（heal sidecar 时 temp 里只有 meta.json）。若 commit_object 强制要求 part.0，则 B4-1 改用 `put_sidecar` 直接写 final_dir（非原子但 sidecar 单文件写本身近原子）+ 记注释；executor 二选一并在 notes 说明。

### 步骤 3（接线）：`lib/maxio/object_meta.ex` `do_shadow` 的 divergent 分支

把 P2 中"divergent 仅记日志"改为：记日志 + best-effort 调度 heal（不阻塞读）。executor 在 `do_shadow` reconcile `{:ok, entry, divergent}` 且 `divergent != []` 处，追加：

```elixir
        if divergent != [] do
          Log.warn("sidecar divergence -> scheduling heal", bucket: bucket, key: key, version_id: version_id, divergent: inspect(divergent))
          info = %{canonical_meta: canonical_full_meta, divergent_endpoints: divergent, endpoints: endpoints}
          _ = Maxio.SidecarHeal.heal_divergent(bucket, key, eff_vid || "null", info, opts)
        end
```

> 注：heal 需要 canonical **完整 meta**（含 versions 数组）而非单 entry——executor 让 `do_shadow`/`read_endpoint_sidecars` 保留 quorum 组的完整 meta（reconcile 当前返回单 entry；executor 从该 entry 所属端点的完整 sidecar 取，或扩展 reconcile 返回 canonical 完整 meta）。最简：heal 写"权威端点之一的完整 meta.json"（reconcile 的 canonical entry 所在端点的完整 sidecar）。executor 在 notes 说明取 canonical 完整 meta 的方式。endpoints 由 `endpoints_for/3` 提供。同步调用（非 Task）避免 sandbox/连接所有权问题，但加 try/rescue 确保不阻塞读——executor 评估同步 best-effort 是否够快（heal 仅在分歧时触发、低频）；若慢则 `Task.Supervisor` 异步（注意 DB sandbox）。

跑：`mix test test/maxio/sidecar_heal_test.exs` → 绿。`mix test`（全量）→ 绿。`mix format`。

**Commit**：`feat(routeB): Maxio.SidecarHeal — atomic write-back of canonical sidecar to divergent endpoints + read-path scheduling (B4-1)`

---

## 单元 B4-2 — 写路径 PG 降 best-effort 索引（sidecar 为权威载体）

**目的**：写路径已先 `Storage.put`（sidecar+字节写全 N 端点、达 write_quorum 才成功 = 权威已落）再写 PG。B4-2 把 PG 写改为 **best-effort 索引**：PG 失败**非致命**（记结构化日志 + 标 `synced_at` 滞后），绝不因 PG 故障让对象 PUT 失败（去 SPOF 关键）。只有 `authoritative_source(:write)==:sidecar` 时启用 best-effort；默认 `:pg` 仍维持原致命语义（向后兼容、可回滚）。

### 设计（铁律 3）

- config 扩展：`config :maxio, :authoritative_source, read: :pg, list: :pg, write: :pg`。
- `Maxio.Objects` 加 `put_version_index/4`：与 `put_version_with_id/4` 同参，但**捕获异常/错误**返回 `:ok | {:error, reason}`（不抛）；写成功后（或失败后）由调用方决定致命性。
- `Object.do_put` 写 PG 处按 `ObjectMeta.authoritative_source(:write)` 分流：
  - `:pg`（默认）→ 现状：`put_version_with_id` 失败则回滚字节 + reraise（B1-1 既有，维持）。
  - `:sidecar` → sidecar 已是权威（Storage.put 成功 = 已达 write_quorum）；PG 用 `put_version_index` best-effort：失败 → `Log.error("pg index update failed (object durably stored in sidecars)", ...)`，**不回滚字节、不失败请求**（对象已耐久存于 sidecar）。返回对象视图取自已写入的 version_id + 计算结果（不依赖 PG 读回）。
- **绝不静默**：PG 索引写失败必记 `Log.error` + （若 schema 有）标 `synced_at`/`index_generation` 滞后；scanner（M8/后续）reconcile 索引。

### 步骤 1（TDD 红）：`test/maxio/s3/write_authority_test.exs`

```elixir
defmodule Maxio.S3.WriteAuthorityTest do
  use Maxio.DataCase, async: false
  import ExUnit.CaptureLog
  alias Maxio.{Objects, ObjectMeta}

  test "authoritative_source(:write) 默认 :pg" do
    assert ObjectMeta.authoritative_source(:write) == :pg
  end

  test "put_version_index best-effort：PG 写成功返回 :ok" do
    {:ok, _b} = Maxio.Buckets.create("wab", "arn:aws:iam:::root")
    assert :ok = Objects.put_version_index("wab", "k", "null", %{size: 1, etag: "\"e\""})
    assert %Objects.Object{etag: "\"e\""} = Objects.get_metadata("wab", "k") |> unwrap()
  end

  defp unwrap({:ok, o}), do: o
  defp unwrap(o), do: o
end
```

> 注：「PG 写失败仍 :ok」的注入测试较重（需让 Repo 写抛错），executor 用一个 changeset 必失败的输入（如超长 etag 触发约束，或 mock）验证 `put_version_index` 捕获并返回 `{:error,_}` 不抛；若难以确定性注入，则至少断言 `put_version_index` 在正常输入返回 `:ok` + 单测 do_put 在 `:write=:sidecar` + Storage 成功 + PG 故障（用一个会被 changeset 拒的 key 形态）时**请求仍成功**（对象可经 sidecar 读回）。executor 选可确定性注入的方式并在 notes 说明。

跑：红。

### 步骤 2（实现绿）

**config/config.exs**：`authoritative_source` 加 `write: :pg`。

**lib/maxio/objects.ex** 加：

```elixir
  @doc """
  ROUTE B P4 —— best-effort 索引写（与 put_version_with_id/4 同语义，但捕获异常返回 {:error,_} 不抛）。
  用于 authoritative_source(:write)==:sidecar：sidecar 是权威载体，PG 仅派生索引，失败非致命。
  """
  @spec put_version_index(String.t(), String.t(), String.t(), map()) :: :ok | {:error, term()}
  def put_version_index(bucket, key, version_id, attrs) do
    case put_version_with_id(bucket, key, version_id, attrs) do
      {:ok, _obj} -> :ok
      {:error, reason} -> {:error, reason}
    end
  rescue
    e -> {:error, e}
  end
```

**lib/maxio/s3/handlers/object.ex** `do_put` 写 PG 处（B1-1 锁内、Storage.put 成功后）按 write 权威分流。executor 把现有 `Objects.put_version_with_id(...)` 调用改为：

```elixir
            case Maxio.ObjectMeta.authoritative_source(:write) do
              :sidecar ->
                # sidecar 已达 write_quorum = 权威已耐久落盘；PG best-effort 索引，失败不致命
                case Objects.put_version_index(bucket, key, version_id, attrs) do
                  :ok -> :ok
                  {:error, reason} ->
                    Maxio.S3.Log.error("pg index update failed (object durably stored in sidecars)",
                      bucket: bucket, key: key, version_id: version_id, reason: inspect(reason))
                end
                # 返回视图由 version_id + 已知 attrs 构造（不依赖 PG 读回）
                build_put_view(bucket, key, version_id, attrs, etag)

              _ ->
                # :pg 默认：维持 B1-1 致命语义（失败回滚字节 + reraise）
                {:ok, obj} = Objects.put_version_with_id(bucket, key, version_id, attrs)
                obj
            end
```

> executor 核对 `do_put` 现有变量名（`attrs`/`etag`/`obj`/响应管线用的字段），并实现 `build_put_view/5`（产出与 `%Object{}` 响应所需字段兼容的结构：version_id/etag 用于响应头）。`:pg` 分支逐字保留 B1-1 现有逻辑（含失败回滚）。

跑：绿。`mix test`（全量）绿。`mix format`。

**Commit**：`feat(routeB): write-path PG demoted to best-effort index under authoritative_source(:write)=:sidecar (B4-2)`

---

## 单元 B4-3 — 翻转读权威（`read: :sidecar`）

**目的**：`authoritative_source(:read)==:sidecar` 时，`ObjectMeta.get` 的**返回值取自 reconcile 的 sidecar 视图**（而非 PG）；reconcile `{:error,:read_quorum}` → 真实"对象不可读"（绝不猜）；sidecar 未找到 → not_found。PG 仅作"所有 sidecar 端点不可达/无 topology"时的降级 fallback（记日志）。默认仍 `:pg`（P2 shadow 行为不变），flag 切 `:sidecar` 灰度、可回滚。

### 设计（铁律 3）

- `ObjectMeta.get(bucket, key, version_id, opts)` 顶部按 `authoritative_source(:read)` 分流：
  - `:pg`（默认）→ 现状：`pg_read` + `shadow_check`（P2/B4-1），返回 PG。
  - `:sidecar` → 读全 N 端点 sidecar（复用 `read_endpoint_sidecars`）→ `MetaReconcile.reconcile`：
    - `{:ok, entry, divergent}` → 调度 heal（B4-1）；若 `entry` 是 delete_marker 且 version_id==nil → 返回 `{:error,:not_found}`（latest 是删除标记，GET 应 404）；否则返回 `Sidecar.to_view`（+ 从 entry 补全响应所需字段）转成与 `%Object{}` 兼容的结构。
    - `{:error,:read_quorum}` → 若**所有端点 :missing**（对象确实不存在于任何端点）→ `{:error,:not_found}`；否则（端点不可达/分歧不足 quorum）→ `{:error,:read_quorum}`（handler 映射为 503/ServiceUnavailable 或 InternalError——绝不返回猜测数据）。
    - sidecar 路径完全不可达（无 topology / transport 异常）→ 降级 fallback PG + `Log.warn("read authority sidecar unreachable, falling back to PG index")`。
- handler GET/HEAD：当 `get` 返回 `{:error,:read_quorum}` → 映射 S3 错误（新错误码或复用既有；executor 选 503 `ServiceUnavailable` 或既有 `:internal_error`，并记结构化日志）。`{:error,:not_found}` → NoSuchKey 404（既有）。

### 步骤 1（TDD 红）：`test/maxio/object_meta_read_authority_test.exs`

```elixir
defmodule Maxio.ObjectMetaReadAuthorityTest do
  use Maxio.DataCase, async: false
  alias Maxio.{ObjectMeta, Sidecar}
  alias Maxio.Cluster.Transport.InProcess

  setup do
    InProcess.setup!()
    eps = for i <- 0..2, do: {:"ran#{i}", Path.join(System.tmp_dir!(), "ra_d#{i}_#{System.unique_integer([:positive])}")}
    topo = %{data_shards: 2, parity_shards: 1, block_size: 1024, sets: %{0 => %{id: 0, endpoints: eps}}, set_ids: [0]}
    :persistent_term.put({Maxio.Cluster.Topology, :topology}, topo)
    on_exit(fn -> :persistent_term.erase({Maxio.Cluster.Topology, :topology}); Enum.each(eps, fn {_n, d} -> File.rm_rf(d) end) end)
    {:ok, eps: eps, topo: topo}
  end

  defp m(vid, type \\ "object"), do: %{"format" => "maxio/2", "versions" => [%{"version_id" => vid, "type" => type, "modtime" => 5, "generation" => 1, "etag" => "\"e\"", "size" => 3, "content_type" => "text/plain"}]}
  defp put(eps, key, meta), do: Enum.each(eps, fn {_n, d} -> dir = Path.join([d, "rab", key]); File.mkdir_p!(dir); File.write!(Path.join(dir, "meta.json"), Sidecar.encode(meta)) end)
  defp opts(topo), do: [transport: InProcess, topology: topo, authoritative_source: [read: :sidecar]]

  test "read=:sidecar 时返回 sidecar 视图（不依赖 PG）", %{eps: eps, topo: topo} do
    put(eps, "k", m("v1"))   # 仅写 sidecar，不写 PG
    obj = ObjectMeta.get("rab", "k", nil, opts(topo))
    assert obj.etag == "\"e\""
    assert obj.version_id == "v1"
  end

  test "read=:sidecar latest 是 delete_marker -> not_found", %{eps: eps, topo: topo} do
    put(eps, "dk", m("vd", "delete_marker"))
    assert {:error, :not_found} = ObjectMeta.get("rab", "dk", nil, opts(topo))
  end

  test "read=:sidecar 全端点缺该对象 -> not_found", %{topo: topo} do
    assert {:error, :not_found} = ObjectMeta.get("rab", "ghost", nil, opts(topo))
  end

  test "read=:sidecar 仅 1/3 端点有（< read_quorum=2）-> read_quorum 错误（绝不猜）", %{eps: eps, topo: topo} do
    [{_n0, d0} | _] = eps
    dir = Path.join([d0, "rab", "lonely"]); File.mkdir_p!(dir); File.write!(Path.join(dir, "meta.json"), Sidecar.encode(m("v1")))
    assert {:error, :read_quorum} = ObjectMeta.get("rab", "lonely", nil, opts(topo))
  end
end
```

> `authoritative_source` 经 opts 覆盖 for tests：`ObjectMeta.authoritative_source/1` executor 改为可读 opts（`Keyword.get(opts, :authoritative_source)` 优先于 Application env）——为此 `get/4` 需把 opts 传入分流判定。executor 调整 `authoritative_source` 签名或在 `get` 内联读 opts。

跑：红。

### 步骤 2（实现绿）：`lib/maxio/object_meta.ex`

`get/4` 改为按 read 权威分流（保留 `:pg` 现状分支不变）；新增 `:sidecar` 分支（读端点 sidecar → reconcile → to_view / not_found / read_quorum，并调度 heal）。executor 复用 `read_endpoint_sidecars/4`、`MetaReconcile.reconcile/3`、`Sidecar.to_view/3`、`SidecarHeal.heal_divergent/4`。read_quorum 来自 `read_quorum/1`（opts）。

handler `Object.get/1`、`head/1`：把 `resolve_object_for_get!` / 取对象处改为经 `ObjectMeta.get`（已是入口），并处理 `{:error,:read_quorum}` → 503/ServiceUnavailable（executor 加错误码 `:service_unavailable` → `{"ServiceUnavailable", 503, ...}` 若 `Maxio.S3.Error` 无，则加）+ 结构化日志；`{:error,:not_found}` → NoSuchKey（既有路径）。**仅当 read 权威 :sidecar 时**这些新分支可达；默认 :pg 行为不变。

跑：绿。全量绿（默认 :pg，新测试用 opts 覆盖 :sidecar）。`mix format`。

**Commit**：`feat(routeB): flip READ authority to sidecar under authoritative_source(:read)=:sidecar (reconcile result authoritative, read-quorum errors never guess) (B4-3)`

---

## 单元 B4-4 — 翻转列权威（`list: :sidecar`）

**目的**：`authoritative_source(:list)==:sidecar` 时，ListObjectsV2 handler 返回 **drive-walk 结果**（`Maxio.Listing`），强制每对象 quorum 确认（去掉 P3 shadow 的"命中≥1 即收"宽松门）；默认 `:pg` 仍返回 SQL + shadow 比对（P3 行为不变）。

### 设计

- `Maxio.Listing.list_objects_v2` 加 quorum 选项：`opts[:require_quorum]`（默认 false=P3 宽松）；为 true 时，`collect_keys` 只保留**命中端点数 ≥ read_quorum** 的 key（跨 set 内）。executor 在 `collect_keys` 累计每 key 命中端点计数（不再 `Enum.uniq` 即丢计数），按 quorum 过滤。
- `ObjectMeta.list/3`（新）：按 `authoritative_source(:list)` 分流——`:pg` → `Objects.list_objects_v2` + `list_shadow`（现状）；`:sidecar` → `Maxio.Listing.list_objects_v2(..., require_quorum: true)` 直接返回（权威）。
- handler `Bucket.list_objects_v2/1`：把现有 `Objects.list_objects_v2` + `list_shadow` 调用替换为 `ObjectMeta.list(bucket, list_opts, opts)`（内部分流；默认 :pg 行为不变）。

### 步骤 1（TDD 红）：`test/maxio/object_meta_list_authority_test.exs`

```elixir
defmodule Maxio.ObjectMetaListAuthorityTest do
  use Maxio.DataCase, async: false
  alias Maxio.ObjectMeta
  alias Maxio.Cluster.Transport.InProcess

  setup do
    InProcess.setup!()
    eps = for i <- 0..2, do: {:"lan#{i}", Path.join(System.tmp_dir!(), "la_d#{i}_#{System.unique_integer([:positive])}")}
    topo = %{data_shards: 2, parity_shards: 1, block_size: 1024, sets: %{0 => %{id: 0, endpoints: eps}}, set_ids: [0]}
    :persistent_term.put({Maxio.Cluster.Topology, :topology}, topo)
    on_exit(fn -> :persistent_term.erase({Maxio.Cluster.Topology, :topology}); Enum.each(eps, fn {_n, d} -> File.rm_rf(d) end) end)
    {:ok, eps: eps, topo: topo}
  end

  defp put(eps, key), do: Enum.each(eps, fn {_n, d} -> dir = Path.join([d, "lab", key]); File.mkdir_p!(dir); File.write!(Path.join(dir, "meta.json"), "{}") end)
  defp opts(topo), do: [transport: InProcess, topology: topo, authoritative_source: [list: :sidecar]]

  test "list=:sidecar 返回 drive-walk 结果（quorum 确认）", %{eps: eps, topo: topo} do
    put(eps, "a"); put(eps, "b")
    r = ObjectMeta.list("lab", %{max_keys: 100}, opts(topo))
    assert Enum.map(r.objects, & &1.key) == ["a", "b"]
  end

  test "list=:sidecar 仅 1/3 端点有的 key 不计入（< quorum）", %{eps: eps, topo: topo} do
    put(eps, "full")
    [{_n0, d0} | _] = eps
    dir = Path.join([d0, "lab", "lonely"]); File.mkdir_p!(dir); File.write!(Path.join(dir, "meta.json"), "{}")
    r = ObjectMeta.list("lab", %{max_keys: 100}, opts(topo))
    assert Enum.map(r.objects, & &1.key) == ["full"]   # lonely 未达 quorum 被排除
  end
end
```

跑：红。

### 步骤 2（实现绿）

- `lib/maxio/listing.ex`：`collect_keys` 改为累计每 key 命中计数（`Enum.reduce` 成 `%{key => count}`），`list_objects_v2` 接 `opts[:require_quorum]`（true → 用 `read_quorum` 过滤 `count >= rq`）。read_quorum 来自 `Config`（executor 复用 ObjectMeta.read_quorum 或 Config.load!）。默认 false 保持 P3 行为。
- `lib/maxio/object_meta.ex`：加 `list/3` 分流（`:pg` → Objects + list_shadow；`:sidecar` → Listing require_quorum:true）。
- `lib/maxio/s3/handlers/bucket.ex`：`list_objects_v2/1` 用 `ObjectMeta.list`（默认 :pg 行为不变）。

跑：绿。全量绿。`mix format`。

**Commit**：`feat(routeB): flip LIST authority to sidecar drive-walk with quorum confirmation under authoritative_source(:list)=:sidecar (B4-4)`

---

## P4 完成判据

- `mix compile --warnings-as-errors` 零警告；`mix test` 全量绿（658 + P4 新增约 14）；`mix precommit` 绿。
- **默认 `read/list/write` 全 `:pg`**——P4 后默认行为与 P3 完全一致（向后兼容、可回滚），翻权威仅经 config flag 灰度。
- B4-1 sidecar heal 把权威副本原子写回 divergent 端点；best-effort 不阻塞读。
- B4-2 `:write=:sidecar` 时 PG 写失败非致命（对象耐久于 sidecar、请求成功、记日志）。
- B4-3 `:read=:sidecar` 时 get 返回 sidecar 视图；delete_marker→not_found；< quorum→read_quorum 错误（绝不猜）；全缺→not_found。
- B4-4 `:list=:sidecar` 时 ListObjectsV2 返回 quorum 确认的 drive-walk。
- `git status` 干净 + `mix format --check-formatted` 退出 0。

## 显式 DEFER（文档化）

- **去配置面 PG SPOF**（IAM/access_keys、bucket_policies、bucket_configs sidecar 化）→ 后续（P4 后对象元数据面已去 SPOF，配置面低频仍在 PG）。
- **生产默认翻 :sidecar**（P4 仅交付能力 + flag，默认仍 :pg；何时把生产默认切 :sidecar 由运维灰度决定，需 backfill 既有对象 sidecar——见路线图 P7 迁移）。
- **ListObjectVersions 翻权威** → 随后续（B4-4 仅 ListObjectsV2）。
- **真·流式惰性走盘** / **PG 索引 reconcile scanner（写回滞后修复）** → 后续优化。


