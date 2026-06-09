# ROUTE B 阶段 2 实现计划 · maxio（sidecar 权威翻转 —— 读路径 SHADOW 模式）

> 由 orchestrator 直接编写（规划/设计文档，CLAUDE.md 允许）。本机网络当前对长时 subagent 不稳定（socket 反复关闭），故计划由主线撰写、再交串行 executor 实现。
> 严格按单元 **B2-1 → B2-2 → B2-3** 顺序执行（串行，禁止并行 mix 编译）。逻辑性代码用 **TDD**（先写失败测试 → 红 → 最小实现 → 绿 → commit）。每个任务给精确文件路径、完整可用代码（**禁止占位符 / TODO / 省略号**）、确切 PowerShell 命令与期望输出。复用 P0–P1 既有模块时逐字照抄其现有签名。每个 commit 末尾加 `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`。

## 环境约束（每条命令都必须遵守）

- Windows + PowerShell。每条 mix 命令前：`$env:Path = 'C:\Users\dyz\Documents\dev\usr\Elixir\bin;' + $env:Path; $env:ERL_FLAGS = '-kernel standard_io_encoding unicode';`
- Postgres docker 容器 `maxio-db`（localhost:5432 / postgres / maxio_dev）；`mix test` 经 aliases 自动建库迁移。
- 验证：`mix compile --warnings-as-errors` 零警告；`mix test` 全量绿（当前基线 615 passed, 1 excluded）；新单元各自加测试。每单元结束 `git status -s` 工作树须干净 + `mix format --check-formatted` 退出 0。

## Goal

把 maxio 对象元数据从「Postgres 权威」推进到「**每对象 sidecar（meta.json）即事实来源**」的**第一步（SHADOW 读）**：

1. **不翻读权威**：`config :maxio, :authoritative_source, read: :pg`（默认 `:pg` = 今天行为）。本阶段读路径仍返回 PG 结果。
2. **跨端点 quorum 读 + 分歧 reconcile**（`Maxio.MetaReconcile`，纯函数）：读全 N 端点 sidecar → 按 `Sidecar.signature/1` 分组 → ≥ `read_quorum`(=K) 一致才接受；无值达 quorum → `{:error, :read_quorum}`（**绝不服务猜测副本**，铁律 3）；少数派（stale/missing/corrupt）记入 `divergent` 供 heal。
3. **dual-read shadow 比对**（`Maxio.ObjectMeta` 门面）：读 PG 权威结果 + reconcile sidecar 视图，逐字段比对，**返回 PG 结果**，分歧 → `Log.warn(divergence: ...)`（绝不静默）。divergent 端点 → 记录 heal 钩子（heal-write 落 P4，本阶段仅记日志）。

**显式 DEFER（文档化，绝不静默）**：翻转读权威（`read: :sidecar`）→ P4 之后；drive-walk LIST → P3；原子写权威 → P4；sidecar heal 实际回写 → P4（本阶段仅调度/记日志）。

## 全局命名契约（P2 新增；P0–P1 既有逐字复用）

**既有（逐字复用，绝不重定义）**：
- `Maxio.Sidecar`：`decode!/1`、`v2?/1`、`migrate_v1/2`、`latest/1`、`latest_object/1`、`find_version/2`、`signature/1`、`to_object_attrs/3`。版本 entry 字段：`version_id/type/is_latest/modtime/generation/content_type/user_metadata/tags/sse/acl_canned/storage_class/data_dir/inline/size/etag/sha256`。
- `Maxio.Cluster.Transport`：`get_sidecar(node, drive_obj_dir) :: {:ok, map()} | {:error, :enoent}`、`impl/1`（opts[:transport] 注入）。`Transport.InProcess`（测试）。
- `Maxio.Cluster.Topology`：`endpoints(set_id)`、`endpoints_from(t, set_id)`（有序 N 个 `{node, drive}`，索引 i = 分片 i）；`Maxio.Cluster.Router.set_for/2,3`；`Maxio.Cluster.Paths.object_rel(bucket, key, version_id) :: {:ok, rel} | {:error, :invalid_key}`。
- `Maxio.Storage.Erasure.Config`：`load!(opts) :: %Config{read_quorum, data_shards, ...}`。
- `Maxio.Objects`：`get_metadata(bucket, key) :: %Object{} | nil`、`get_version(bucket, key, vid) :: {:ok, %Object{}} | {:error, :not_found}`。`%Maxio.Objects.Object{}` 字段：size/etag/content_type/metadata/storage_class/acl_canned/version_id/is_latest/is_delete_marker/tags/sse_algorithm/sse_envelope。
- `Maxio.S3.Log`：`warn/2`（结构化日志）。

**P2 新增**：
- `Maxio.Sidecar.to_view/3`（B2-1）—— sidecar 版本 entry → 与 `Objects.get_metadata` 可比的视图 map（仅元数据字段，便于 shadow 比对）。
- `Maxio.MetaReconcile.reconcile/3`（B2-2）—— 纯函数 quorum 仲裁。
- `Maxio.ObjectMeta`（B2-3）—— dual-read 门面 + `authoritative_source/1` + shadow 比对接线。

---

## 单元总览（串行）

| 单元 | 标题 | 主文件 | 依赖 |
|---|---|---|---|
| **B2-1** | `Sidecar.to_view/3` + 字段对齐确认 | `lib/maxio/sidecar.ex`, `test/maxio/sidecar_to_view_test.exs` | P1 |
| **B2-2** | `Maxio.MetaReconcile`（纯函数 quorum 仲裁，真值表硬测） | `lib/maxio/meta_reconcile.ex`, `test/maxio/meta_reconcile_test.exs` | B2-1 |
| **B2-3** | `Maxio.ObjectMeta` dual-read shadow + config + 读 handler 接线 | `lib/maxio/object_meta.ex`, `config/config.exs`, `lib/maxio/s3/handlers/object.ex`, `test/maxio/object_meta_shadow_test.exs` | B2-2 |

---

## 单元 B2-1 — `Sidecar.to_view/3`（sidecar → 可比视图）

**目的**：ObjectMeta shadow 比对需要把 reconcile 出的 sidecar 版本 entry 与 PG 的 `%Object{}` 放在同一形状上比。`to_object_attrs/3` 已产出 PG 索引行 attrs（写侧用），但 shadow 比对侧需要一个**只含读路径关心字段、键统一**的视图。`to_view/3` 复用 `to_object_attrs/3` 的取值逻辑，输出固定 map。

### 步骤 1（TDD 红）：`test/maxio/sidecar_to_view_test.exs`

```elixir
defmodule Maxio.SidecarToViewTest do
  use ExUnit.Case, async: true
  alias Maxio.Sidecar

  @entry %{
    "version_id" => "v-abc",
    "type" => "object",
    "is_latest" => true,
    "modtime" => 1_700_000_000_000_000_000,
    "generation" => 3,
    "size" => 11,
    "etag" => "\"d41d8cd98f00b204e9800998ecf8427e\"",
    "content_type" => "text/plain",
    "user_metadata" => %{"x-amz-meta-a" => "1"},
    "tags" => %{"k" => "v"},
    "sse" => %{"algo" => "AES256", "envelope" => %{"iv" => "..."}},
    "acl_canned" => "private",
    "storage_class" => "STANDARD"
  }

  test "to_view/3 产出读路径可比视图（键与 Object 字段对齐）" do
    v = Sidecar.to_view("b", "k", @entry)
    assert v.version_id == "v-abc"
    assert v.size == 11
    assert v.etag == "\"d41d8cd98f00b204e9800998ecf8427e\""
    assert v.content_type == "text/plain"
    assert v.metadata == %{"x-amz-meta-a" => "1"}
    assert v.tags == %{"k" => "v"}
    assert v.storage_class == "STANDARD"
    assert v.acl_canned == "private"
    assert v.is_latest == true
    assert v.is_delete_marker == false
    assert v.sse_algorithm == "AES256"
  end

  test "delete_marker entry -> is_delete_marker true" do
    dm = %{"version_id" => "v-dm", "type" => "delete_marker", "modtime" => 1, "generation" => 0}
    v = Sidecar.to_view("b", "k", dm)
    assert v.is_delete_marker == true
    assert v.version_id == "v-dm"
  end
end
```

跑：`mix test test/maxio/sidecar_to_view_test.exs` → 红（`to_view/3` 未定义）。

### 步骤 2（实现绿）：在 `lib/maxio/sidecar.ex` 加 `to_view/3`

在 `to_object_attrs/3` 之后插入：

```elixir
  @doc """
  把 sidecar 某版本 entry 翻成「读路径可比视图」map（B2 shadow 比对用）。
  键与 `Maxio.Objects.Object` 的读相关字段对齐，便于 ObjectMeta 逐字段比对 PG 与 sidecar。
  与 `to_object_attrs/3` 取值一致，但固定输出读路径字段集。
  """
  @spec to_view(String.t(), String.t(), version_entry()) :: map()
  def to_view(_bucket, _key, %{} = e) do
    %{
      version_id: e["version_id"],
      size: e["size"] || 0,
      etag: e["etag"] || "",
      content_type: e["content_type"] || "binary/octet-stream",
      metadata: e["user_metadata"] || %{},
      storage_class: e["storage_class"] || "STANDARD",
      acl_canned: e["acl_canned"] || "private",
      tags: e["tags"] || %{},
      sse_algorithm: get_in(e, ["sse", "algo"]),
      is_latest: e["is_latest"] || false,
      is_delete_marker: e["type"] == "delete_marker"
    }
  end
```

跑：`mix test test/maxio/sidecar_to_view_test.exs` → `2 passed`。`mix test`（全量）→ 绿。`mix format`。

**Commit**：`feat(routeB): Sidecar.to_view/3 — comparable read-path view for shadow reconcile (B2-1)`

---

## 单元 B2-2 — `Maxio.MetaReconcile`（纯函数 quorum 仲裁）

**目的**：跨 N 端点 sidecar 副本，按 quorum 取权威值；无 quorum 报错绝不猜；少数派记为 divergent（供 heal）。这是 sidecar 安全成为事实来源的**首要正确性核心**——纯函数，穷举真值表硬测。

### 算法（铁律 3）

输入 `copies :: [%{node, drive, meta} | :missing]`（N 个端点的 sidecar 读结果；`:missing` = `get_sidecar` 返回 `{:error, :enoent}`），`read_quorum`，`target :: :latest | {:version, vid}`。

1. 对每个非 `:missing` 副本，按 `target` 取出对应版本 entry：
   - `:latest` → `Sidecar.latest(meta)`（任意 type，含 delete_marker；对应 S3 latest-version 语义）；
   - `{:version, vid}` → `Sidecar.find_version(meta, vid)`。
   取不到（nil）的副本视为对该 target「无此版本」，不参与一致分组（但若**全体**都取不到 → `{:error, :read_quorum}`，对齐「该版本不存在 = 无 quorum 证据」）。
2. 对取到 entry 的副本，按 `Sidecar.signature(entry)` 分组。
3. 找出**最大一致组**：若其大小 ≥ `read_quorum` → 该组的 canonical entry（组内 `sort_key` 最大者，即 generation/modtime/version_id 最大）即权威；其余端点（含 `:missing`、签名不一致、无此版本）为 `divergent`（端点索引列表）。
4. 否则（无组达 quorum）→ `{:error, :read_quorum}`。
5. 返回 `{:ok, canonical_entry, divergent_indices}`。

> tie-break：同签名即同版本体（signature 已含 generation/modtime/etag 等身份字段），故同组内 entry 等价；`divergent` 仅按「签名是否等于权威组签名」判定。多个**不同**签名组并存且都不足 quorum → 报错（绝不在分歧中挑一个）。

### 步骤 1（TDD 红）：`test/maxio/meta_reconcile_test.exs`

```elixir
defmodule Maxio.MetaReconcileTest do
  use ExUnit.Case, async: true
  alias Maxio.{MetaReconcile, Sidecar}

  # 构造一个带单版本的 v2 sidecar
  defp meta(vid, gen, etag) do
    entry = %{
      "version_id" => vid,
      "type" => "object",
      "is_latest" => true,
      "modtime" => 1_000 + gen,
      "generation" => gen,
      "size" => 3,
      "etag" => etag,
      "content_type" => "text/plain",
      "user_metadata" => %{},
      "tags" => %{},
      "sse" => nil,
      "acl_canned" => "private",
      "storage_class" => "STANDARD"
    }

    %{"format" => "maxio/2", "versions" => [entry]}
  end

  defp copy(i, m), do: %{node: :"n#{i}", drive: "d#{i}", meta: m}

  # N=6 K=4：read_quorum=4
  @rq 4

  test "全 6 副本一致 -> {:ok, entry, []}" do
    m = meta("v1", 1, "\"e1\"")
    copies = for i <- 1..6, do: copy(i, m)
    assert {:ok, canon, []} = MetaReconcile.reconcile(copies, @rq, :latest)
    assert canon["version_id"] == "v1"
  end

  test "4 一致 + 2 stale -> {:ok, 权威, [stale 索引]}" do
    good = meta("v1", 2, "\"e2\"")
    stale = meta("v1", 1, "\"e1\"")
    copies = [copy(1, good), copy(2, good), copy(3, good), copy(4, good), copy(5, stale), copy(6, stale)]
    assert {:ok, canon, divergent} = MetaReconcile.reconcile(copies, @rq, :latest)
    assert canon["generation"] == 2
    assert Enum.sort(divergent) == [4, 5]
  end

  test "4 一致 + 1 missing + 1 corrupt -> {:ok, 权威, [missing+corrupt 索引]}" do
    good = meta("v1", 1, "\"e1\"")
    corrupt = meta("v1", 9, "\"DIFFERENT\"")
    copies = [copy(1, good), copy(2, good), copy(3, good), copy(4, good), :missing, copy(6, corrupt)]
    assert {:ok, canon, divergent} = MetaReconcile.reconcile(copies, @rq, :latest)
    assert canon["etag"] == "\"e1\""
    assert Enum.sort(divergent) == [4, 5]
  end

  test "无组达 quorum（3 vs 3）-> {:error, :read_quorum}（绝不挑一个）" do
    a = meta("v1", 1, "\"a\"")
    b = meta("v1", 2, "\"b\"")
    copies = [copy(1, a), copy(2, a), copy(3, a), copy(4, b), copy(5, b), copy(6, b)]
    assert {:error, :read_quorum} = MetaReconcile.reconcile(copies, @rq, :latest)
  end

  test "全 missing -> {:error, :read_quorum}" do
    copies = List.duplicate(:missing, 6)
    assert {:error, :read_quorum} = MetaReconcile.reconcile(copies, @rq, :latest)
  end

  test "按 versionId 读：只一致那个版本，其余无此版本算 divergent" do
    e2 = %{"version_id" => "v2", "type" => "object", "modtime" => 5, "generation" => 0, "etag" => "\"x\"", "size" => 1}
    with_v2 = %{"format" => "maxio/2", "versions" => [hd(meta("v1", 1, "\"e1\"")["versions"]), e2]}
    only_v1 = meta("v1", 1, "\"e1\"")
    copies = [copy(1, with_v2), copy(2, with_v2), copy(3, with_v2), copy(4, with_v2), copy(5, only_v1), copy(6, only_v1)]
    assert {:ok, canon, divergent} = MetaReconcile.reconcile(copies, @rq, {:version, "v2"})
    assert canon["version_id"] == "v2"
    assert Enum.sort(divergent) == [4, 5]
  end

  test "latest 取 delete_marker（任意 type）" do
    dm = %{"version_id" => "vdm", "type" => "delete_marker", "modtime" => 9, "generation" => 1}
    obj = hd(meta("v1", 1, "\"e1\"")["versions"])
    m = %{"format" => "maxio/2", "versions" => [obj, dm]}
    copies = for i <- 1..5, do: copy(i, m)
    assert {:ok, canon, _} = MetaReconcile.reconcile(copies ++ [:missing], @rq, :latest)
    assert canon["type"] == "delete_marker"
  end
end
```

跑：`mix test test/maxio/meta_reconcile_test.exs` → 红（模块未定义）。

### 步骤 2（实现绿）：`lib/maxio/meta_reconcile.ex`

```elixir
defmodule Maxio.MetaReconcile do
  @moduledoc """
  ROUTE B P2 —— 跨端点 sidecar 副本的 quorum 仲裁（纯函数，无副作用、无 IO）。

  对齐 MinIO xl.meta 读路径（reduceCommonVersions/pickValidInfo）：读全 N 端点 sidecar，
  按目标版本的内容签名（`Maxio.Sidecar.signature/1`）分组，要求 >= read_quorum(=K) 一致才接受；
  无任何组达 quorum -> `{:error, :read_quorum}`（**绝不在分歧中挑一个、绝不服务猜测副本**，铁律 3）。
  少数派（缺失 / 签名不一致 / 无此版本）记为 `divergent`（端点索引），供 P4 heal 回写。

  generation/modtime/version_id 是 signature 的组成身份字段，故同签名即同版本体；
  并列权威组内 canonical 取 sort_key（modtime, generation, version_id）最大者（等价，确定性）。
  """

  alias Maxio.Sidecar

  @type copy :: %{node: term(), drive: String.t(), meta: map()} | :missing
  @type target :: :latest | {:version, String.t()}

  @doc """
  reconcile(copies, read_quorum, target)。
  copies 顺序即端点索引顺序（0-based）。返回 `{:ok, canonical_entry, divergent_indices}`
  或 `{:error, :read_quorum}`。
  """
  @spec reconcile([copy()], pos_integer(), target()) ::
          {:ok, map(), [non_neg_integer()]} | {:error, :read_quorum}
  def reconcile(copies, read_quorum, target)
      when is_list(copies) and is_integer(read_quorum) and read_quorum > 0 do
    # 每端点取出 target 对应 entry（取不到 -> nil）
    indexed =
      copies
      |> Enum.with_index()
      |> Enum.map(fn {c, idx} -> {idx, entry_for(c, target)} end)

    # 按签名分组（仅对取到 entry 的端点）
    present = Enum.filter(indexed, fn {_idx, e} -> not is_nil(e) end)

    groups =
      present
      |> Enum.group_by(fn {_idx, e} -> Sidecar.signature(e) end)

    case Enum.max_by(groups, fn {_sig, members} -> length(members) end, fn -> nil end) do
      nil ->
        {:error, :read_quorum}

      {_sig, members} ->
        if length(members) >= read_quorum do
          canonical =
            members
            |> Enum.map(fn {_idx, e} -> e end)
            |> Enum.max_by(&sort_key/1)

          quorum_indices = MapSet.new(members, fn {idx, _e} -> idx end)

          divergent =
            indexed
            |> Enum.map(fn {idx, _e} -> idx end)
            |> Enum.reject(&MapSet.member?(quorum_indices, &1))

          {:ok, canonical, divergent}
        else
          {:error, :read_quorum}
        end
    end
  end

  defp entry_for(:missing, _target), do: nil
  defp entry_for(%{meta: meta}, :latest), do: Sidecar.latest(meta)
  defp entry_for(%{meta: meta}, {:version, vid}), do: Sidecar.find_version(meta, vid)

  defp sort_key(e), do: {e["modtime"] || 0, e["generation"] || 0, e["version_id"] || ""}
end
```

跑：`mix test test/maxio/meta_reconcile_test.exs` → `7 passed`。`mix test`（全量）→ 绿。`mix format`。

**Commit**：`feat(routeB): Maxio.MetaReconcile — pure cross-endpoint sidecar quorum arbitration (B2-2)`

---

## 单元 B2-3 — `Maxio.ObjectMeta` dual-read shadow + config + 读 handler 接线

**目的**：门面把「读全 N 端点 sidecar → reconcile → 比对 PG 权威」串起来；**返回 PG 结果**（不翻权威），分歧 `Log.warn`，divergent 端点记 heal 钩子（仅日志）。读 handler（GET/HEAD）在 PG 取元数据后调 `ObjectMeta.shadow_check`（异步/best-effort，绝不影响响应）。

### 步骤 1（config）：`config/config.exs` 追加

在 storage_backend / shard_transport 块附近追加：

```elixir
# ROUTE B 元数据权威来源（读/列/写分别可切；P2 仅引入 :read，默认 :pg = 今天行为，shadow 比对不翻权威）。
config :maxio, :authoritative_source, read: :pg
```

### 步骤 2（TDD 红）：`test/maxio/object_meta_shadow_test.exs`

```elixir
defmodule Maxio.ObjectMetaShadowTest do
  use Maxio.DataCase, async: false

  alias Maxio.{ObjectMeta, Objects, Buckets}
  alias Maxio.Cluster.Transport.InProcess

  # 复用 cluster_e2e_test 的 InProcess topology N=6 K=4 M=2（同 setup 模式）
  @topology %{
    data_shards: 4,
    parity_shards: 2,
    block_size: 1024,
    sets: %{
      0 => %{
        id: 0,
        endpoints: for(i <- 0..5, do: {:"n#{i}", Path.join(System.tmp_dir!(), "om_d#{i}_#{System.unique_integer([:positive])}")})
      }
    },
    set_ids: [0]
  }

  setup do
    InProcess.setup!()
    :persistent_term.put({Maxio.Cluster.Topology, :topology}, @topology)
    on_exit(fn -> :persistent_term.erase({Maxio.Cluster.Topology, :topology}) end)
    {:ok, _b} = Buckets.create("shadowb", %{})
    :ok
  end

  defp opts, do: [transport: InProcess, topology: @topology]

  test "authoritative_source(:read) 默认 :pg" do
    assert ObjectMeta.authoritative_source(:read) == :pg
  end

  test "shadow get 返回 PG 结果（不翻权威）" do
    {:ok, _} = Objects.put_version_with_id("shadowb", "k.txt", "null", %{size: 3, etag: "\"e\"", content_type: "text/plain"})
    # 即便 sidecar 缺失/分歧，shadow get 仍返回 PG 的 %Object{}
    assert %Objects.Object{} = obj = ObjectMeta.get("shadowb", "k.txt", nil, opts())
    assert obj.etag == "\"e\""
  end

  test "PG 有而 sidecar 全缺 -> 记 divergence 日志，仍返回 PG" do
    {:ok, _} = Objects.put_version_with_id("shadowb", "miss.txt", "null", %{size: 1, etag: "\"m\""})
    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert %Objects.Object{} = ObjectMeta.get("shadowb", "miss.txt", nil, opts())
      end)
    assert log =~ "metadata divergence" or log =~ "read_quorum"
  end
end
```

> 注：本测试聚焦门面契约（默认权威 :pg、返回 PG、分歧记日志）。sidecar 实际写入由 ErasureCoded/Distributed 写路径产生，端到端 sidecar-vs-PG 一致路径在 B2-3 集成测试覆盖；此处用「PG 有、sidecar 全缺」构造确定性分歧。

跑：`mix test test/maxio/object_meta_shadow_test.exs` → 红（模块未定义）。

### 步骤 3（实现绿）：`lib/maxio/object_meta.ex`

```elixir
defmodule Maxio.ObjectMeta do
  @moduledoc """
  ROUTE B P2 —— 对象元数据门面（dual-read SHADOW）。

  读路径：PG 仍权威（`authoritative_source(:read)` 默认 `:pg`），同时跨 N 端点读 sidecar 并
  `Maxio.MetaReconcile` 仲裁，逐字段比对 PG 与 sidecar 视图，**返回 PG 结果**（不翻权威），
  分歧 -> 结构化 `Log.warn`（铁律 3 绝不静默）。reconcile 出的 divergent 端点 -> 记 heal 钩子
  （本阶段仅日志；实际 heal 回写落 P4）。

  P4 之后把 `authoritative_source(:read)` 切 `:sidecar` 即翻转读权威（届时 reconcile 错误直接成
  read-quorum 5xx）。本阶段 reconcile 错误**不影响响应**（PG 权威），仅记日志。
  """

  require Logger

  alias Maxio.{Objects, Sidecar, MetaReconcile}
  alias Maxio.Cluster.{Router, Topology, Paths}
  alias Maxio.Storage.Erasure.Config
  alias Maxio.S3.Log

  @doc "读/列/写的元数据权威来源（读 config，可经 opts 覆盖 for tests）。"
  @spec authoritative_source(:read | :list | :write) :: :pg | :sidecar
  def authoritative_source(kind) do
    Application.get_env(:maxio, :authoritative_source, read: :pg)
    |> Keyword.get(kind, :pg)
  end

  @doc """
  读对象元数据。SHADOW 模式：返回 PG 权威 `%Object{}`（或 nil/{:error,:not_found}），
  并 best-effort 跨端点 sidecar reconcile + 分歧日志（不影响返回值、不抛错）。
  version_id=nil 读 latest；否则读指定版本。
  """
  @spec get(String.t(), String.t(), String.t() | nil, keyword()) ::
          Objects.Object.t() | nil | {:error, :not_found}
  def get(bucket, key, version_id \\ nil, opts \\ []) do
    pg = pg_read(bucket, key, version_id)
    shadow_check(bucket, key, version_id, pg, opts)
    pg
  end

  defp pg_read(bucket, key, nil), do: Objects.get_metadata(bucket, key)

  defp pg_read(bucket, key, vid) do
    case Objects.get_version(bucket, key, vid) do
      {:ok, obj} -> obj
      {:error, :not_found} -> {:error, :not_found}
    end
  end

  @doc """
  best-effort shadow 比对：读全 N 端点 sidecar -> reconcile -> 比对 PG。任何异常都被吞并记日志
  （shadow 绝不破坏读路径）。返回 :ok。
  """
  @spec shadow_check(String.t(), String.t(), String.t() | nil, term(), keyword()) :: :ok
  def shadow_check(bucket, key, version_id, pg, opts) do
    target = if version_id, do: {:version, version_id}, else: :latest

    try do
      do_shadow(bucket, key, version_id, target, pg, opts)
    rescue
      e -> Log.warn("metadata shadow error", bucket: bucket, key: key, reason: inspect(e))
    catch
      kind, reason ->
        Log.warn("metadata shadow caught", bucket: bucket, key: key, reason: inspect({kind, reason}))
    end

    :ok
  end

  defp do_shadow(bucket, key, version_id, target, pg, opts) do
    copies = read_endpoint_sidecars(bucket, key, version_id, opts)
    rq = read_quorum(opts)

    case MetaReconcile.reconcile(copies, rq, target) do
      {:ok, entry, divergent} ->
        if divergent != [],
          do: Log.warn("sidecar divergence (heal pending)", bucket: bucket, key: key, version_id: version_id, divergent: inspect(divergent))

        compare(bucket, key, version_id, pg, Sidecar.to_view(bucket, key, entry))

      {:error, :read_quorum} ->
        # PG 有对象但 sidecar 不足 quorum -> 记分歧（P4 翻权威后此为 5xx，本阶段仅日志）
        case pg do
          %Objects.Object{} ->
            Log.warn("metadata divergence: sidecar read_quorum unmet while PG has object",
              bucket: bucket, key: key, version_id: version_id)

          _ ->
            :ok
        end
    end
  end

  # 逐字段比对 PG %Object{} 与 sidecar 视图；不一致 -> 日志（返回 :ok）
  defp compare(bucket, key, version_id, %Objects.Object{} = pg, view) do
    diffs =
      [
        field_diff(:etag, pg.etag, view.etag),
        field_diff(:size, pg.size, view.size),
        field_diff(:content_type, pg.content_type, view.content_type),
        field_diff(:is_delete_marker, pg.is_delete_marker, view.is_delete_marker),
        field_diff(:storage_class, pg.storage_class, view.storage_class)
      ]
      |> Enum.reject(&is_nil/1)

    if diffs != [],
      do: Log.warn("metadata divergence: PG vs sidecar", bucket: bucket, key: key, version_id: version_id, diffs: inspect(diffs))

    :ok
  end

  defp compare(bucket, key, version_id, _pg_nil_or_error, _view) do
    # sidecar 有 quorum 但 PG 无 -> 分歧（PG 落后或漏写）
    Log.warn("metadata divergence: sidecar has object while PG does not",
      bucket: bucket, key: key, version_id: version_id)

    :ok
  end

  defp field_diff(_field, same, same), do: nil
  defp field_diff(field, pg_v, sc_v), do: {field, pg: pg_v, sidecar: sc_v}

  # 读全 N 端点 sidecar -> [%{node, drive, meta} | :missing]
  defp read_endpoint_sidecars(bucket, key, version_id, opts) do
    transport = Keyword.get(opts, :transport, Maxio.Cluster.Transport.impl(opts))
    endpoints = endpoints_for(bucket, key, opts)

    case Paths.object_rel(bucket, key, version_id || "null") do
      {:ok, rel} ->
        Enum.map(endpoints, fn {node, drive} ->
          dir = Path.join(drive, rel)

          case transport.get_sidecar(node, dir) do
            {:ok, meta} -> %{node: node, drive: drive, meta: meta}
            {:error, _} -> :missing
          end
        end)

      {:error, _} ->
        []
    end
  end

  defp endpoints_for(bucket, key, opts) do
    case Keyword.get(opts, :topology) do
      nil ->
        set_id = Router.set_for(bucket, key)
        Topology.endpoints(set_id)

      t ->
        set_id = Router.set_for(bucket, key, t)
        Topology.endpoints_from(t, set_id)
    end
  end

  defp read_quorum(opts) do
    cfg = Config.load!(Keyword.take(opts, [:drives, :data_shards, :parity_shards, :block_size]))
    cfg.read_quorum
  rescue
    _ -> Keyword.get(opts, :read_quorum, 1)
  end
end
```

> 实现注意：`Maxio.Cluster.Transport.impl/1` 与 `endpoints_for` 的 `:topology` 注入沿用 distributed.ex 既有模式；executor 实现时逐字核对 `Transport.impl/1` 签名与 `Paths.object_rel/3` 的 version 参数（null 版本传 `"null"`）。`read_quorum/1` 在无 erasure 配置（如默认 FS 后端）时 rescue 回落，shadow 仍不破坏读路径。

### 步骤 4（读 handler 接线，shadow 不改行为）

`lib/maxio/s3/handlers/object.ex` 的 GET/HEAD 在用 `Objects.get_metadata`/`get_version` 取到对象后，**追加一行** best-effort shadow（不改返回、不改控制流）。例：

```elixir
# 在 object_or_raise/3 取到 object 后（GET 路径），追加：
_ = Maxio.ObjectMeta.shadow_check(bucket, key, version_id, object, [])
```

> 接线最小化：仅在已有 PG 读之后调 `shadow_check/5`（已 try/rescue 自吞，绝不影响响应）。executor 选择 GET + HEAD 两处取到 `%Object{}` 后各加一行；`opts` 传 `[]`（生产读 config topology/transport）。若生产 topology 未配置（单机 FS dev），`read_endpoint_sidecars` 的 `endpoints_for` 走 `Router.set_for` 在无 topology 时会 raise → 被 `shadow_check` 的 try/rescue 吞掉并记一条 warn，读路径不受影响（可接受：shadow 仅在配了 erasure/distributed 后端时有意义）。

跑：`mix test test/maxio/object_meta_shadow_test.exs` → 绿。`mix test`（全量）→ 绿（615 + 新增）。`mix compile --warnings-as-errors` 零警告。`mix format`。

**Commit**：`feat(routeB): Maxio.ObjectMeta dual-read shadow + authoritative_source config + GET/HEAD shadow hook (B2-3)`

---

## P2 完成判据

- `mix compile --warnings-as-errors` 零警告；`mix test` 全量绿（615 + B2 新增约 11）。
- `Maxio.MetaReconcile` 真值表全覆盖（全一致 / 少数 stale / missing+corrupt / 无 quorum 报错 / 全 missing / versionId / delete_marker latest）。
- `authoritative_source(:read)` 默认 `:pg`；shadow get 返回 PG 结果；分歧记结构化日志、绝不静默、绝不破坏读路径。
- `git status` 干净、`mix format --check-formatted` 退出 0。

## 显式 DEFER（P3+，文档化）

- **翻转读权威**（`read: :sidecar`，reconcile 错误成 read-quorum 5xx）→ P4 之后（需 P4 原子写权威先保证 sidecar 始终被正确写全）。
- **drive-walk LIST**（Transport `list_dir` + `Maxio.Listing`）→ P3。
- **原子写权威**（写路径以 sidecar 为准、PG best-effort 索引）→ P4。
- **sidecar heal 实际回写**（把权威副本 temp-then-rename 写回 divergent 端点）→ P4（本阶段仅 `Log.warn` 调度钩子）。
- **list/write 的 shadow**（本阶段仅 read shadow）→ 随 P3/P4。
