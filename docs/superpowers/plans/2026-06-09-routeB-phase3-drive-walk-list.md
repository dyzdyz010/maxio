# ROUTE B 阶段 3 实现计划 · maxio（drive-walk LIST —— SHADOW 模式）

> 由 orchestrator 直接编写（规划文档；本机网络对长时 subagent 不稳定，见 STATUS「网络教训」）。串行 **B3-1 → B3-2 → B3-3**，逐单元 TDD + 独立提交。禁占位符。每条 mix 前置 `$env:Path = 'C:\Users\dyz\Documents\dev\usr\Elixir\bin;' + $env:Path; $env:ERL_FLAGS='-kernel standard_io_encoding unicode';`。每单元末 `git status` 干净 + `mix format --check-formatted` 退出 0 + `mix compile --warnings-as-errors` 零警告 + `mix test` 全量绿（基线 630）。commit footer：`Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`。

## Goal

把对象列举从「Postgres SQL」推进到「**跨端点走盘 drive-walk**」的 SHADOW 模式（不翻 list 权威）：

1. **Transport `list_dir`**（B3-1）：单端点读一层目录，标记每个子目录是否为「对象」（含 `meta.json`），排除内部前缀 `.versions`/`.uploads`/`.tmp`。
2. **`Maxio.Listing`**（B3-2）：fan-out 全 set 端点 → set 内 quorum-walk（每对象 sidecar 在 N 端点，读到 quorum 即认对象存在）→ 跨 set k-way 归并按 key 升序 → 惰性 prefix/delimiter/start-after/max-keys 折叠 → walk-position 续点 token（**绝不 offset**）。**从构造上消除无 LIMIT DoS**。
3. **list shadow**（B3-3）：handler ListObjectsV2 仍返回 PG SQL 结果（`authoritative_source[:list]=:pg` 默认），同时跑 drive-walk 比对、分歧 `Log.warn`、绝不破坏列举路径。

**显式 DEFER**：翻转 list 权威（`list: :sidecar`）→ P4+；ListObjectVersions 走盘 → 随 P4（本阶段仅 ListObjectsV2 走盘 shadow）；原子写权威 / 读权威翻转 / sidecar heal 回写 → P4。

## 盘上布局（既有，B3 据此走盘）

```
<drive_i>/<bucket>/<key...>/{part.0, meta.json}      # null 版本对象：key（含 /）整体为目录树，含 meta.json 的目录 = 一个对象
<drive_i>/.versions/<bucket>/<key...>/<vid>/{...}    # 版本化（B3 不走，DEFER）
<drive_i>/.uploads/<bucket>/<upload_id>/<n>          # multipart parts（遍历须排除）
<drive_i>/.tmp/<uuid>/{...}                          # 原子提交临时区（遍历须排除）
```

> S3 key 空间是平的、maxio 用目录树模拟：key=`a/b.txt` → 目录 `a/b.txt/`；key=`a/b.txt/c` → `a/b.txt/c/`（对象目录内可嵌套别的对象目录）。走盘须递归、用 `meta.json` 标记对象、重建 key、再做 prefix/delimiter 折叠（同 MinIO listPathRaw）。

## 全局命名契约（P3 新增；既有逐字复用）

**既有**：`Maxio.Cluster.Transport`（behaviour + `impl/1`，回调首参 `node()`）、`Transport.Erpc`/`Transport.InProcess`；`ShardServer`（`@meta_file "meta.json"`、`get_sidecar/1` 等本机函数）；`Topology.endpoints/1`/`endpoints_from/2`、`Router.set_for/2,3`、`Topology.all_set_ids/0`；`Config.read_quorum`；`Maxio.Objects.list_objects_v2/2`（PG 权威，返回 `%{name,prefix,delimiter,max_keys,key_count,is_truncated,next_continuation_token,start_after,objects,common_prefixes,...}`）；`Maxio.ObjectMeta.authoritative_source/1`。

**P3 新增**：
- `Transport.list_dir(node, drive_dir, opts) :: {:ok, [%{name, object?}]} | {:error, term}`（B3-1）+ `ShardServer.list_dir/2`。
- `Maxio.Listing.list_objects_v2(bucket, list_opts, opts) :: list_result`（B3-2，返回形态与 `Objects.list_objects_v2/2` 逐字段一致）+ `Maxio.Listing.Continuation.{encode/1, decode/1}`。
- `Maxio.ObjectMeta` 扩展 `list_shadow/3`（B3-3）+ `config :maxio, :authoritative_source, list: :pg`。

---

## 单元 B3-1 — `Transport.list_dir` + `ShardServer.list_dir`（单端点单层目录）

**目的**：单端点读 `drive_dir` 下一层条目，每个子目录标记 `object?`（其内含 `meta.json`），跳过内部前缀 `.versions`/`.uploads`/`.tmp`。走盘的最小原语；B3-2 在其上递归。

### 步骤 1（TDD 红）：`test/maxio/cluster/list_dir_test.exs`

```elixir
defmodule Maxio.Cluster.ListDirTest do
  use ExUnit.Case, async: true
  alias Maxio.Cluster.ShardServer

  setup do
    root = Path.join(System.tmp_dir!(), "ld_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(root) end)
    {:ok, root: root}
  end

  defp mkobj(root, rel) do
    dir = Path.join(root, rel)
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "meta.json"), "{}")
  end

  defp mkdir(root, rel), do: File.mkdir_p!(Path.join(root, rel))

  test "list_dir 标记含 meta.json 的子目录为 object?，纯前缀目录非 object", %{root: root} do
    mkobj(root, "b/a.txt")
    mkobj(root, "b/c.txt")
    mkdir(root, "b/photos")           # 纯前缀（无 meta.json）
    mkobj(root, "b/photos/x.png")     # photos 下的对象
    {:ok, entries} = ShardServer.list_dir(Path.join(root, "b"), [])
    map = Map.new(entries, fn e -> {e.name, e.object?} end)
    assert map["a.txt"] == true
    assert map["c.txt"] == true
    assert map["photos"] == false
    refute Map.has_key?(map, "meta.json")   # meta.json 文件本身不作为条目返回
  end

  test "list_dir 跳过内部前缀 .versions/.uploads/.tmp", %{root: root} do
    mkobj(root, "b/k.txt")
    mkdir(root, "b/.versions")
    mkdir(root, "b/.uploads")
    mkdir(root, "b/.tmp")
    {:ok, entries} = ShardServer.list_dir(Path.join(root, "b"), [])
    names = Enum.map(entries, & &1.name)
    assert "k.txt" in names
    refute ".versions" in names
    refute ".uploads" in names
    refute ".tmp" in names
  end

  test "list_dir 不存在的目录 -> {:ok, []}", %{root: root} do
    assert {:ok, []} = ShardServer.list_dir(Path.join(root, "nope"), [])
  end

  test "list_dir 返回 name 升序", %{root: root} do
    mkobj(root, "b/z")
    mkobj(root, "b/a")
    mkobj(root, "b/m")
    {:ok, entries} = ShardServer.list_dir(Path.join(root, "b"), [])
    assert Enum.map(entries, & &1.name) == ["a", "m", "z"]
  end
end
```

跑：`mix test test/maxio/cluster/list_dir_test.exs` → 红（`list_dir/2` 未定义）。

### 步骤 2（实现绿）：`lib/maxio/cluster/shard_server.ex` 加 `list_dir/2`

在 `get_sidecar/1` 附近加（本机函数，被 :erpc 寻址，无 node 首参）：

```elixir
  @internal_prefixes [".versions", ".uploads", ".tmp"]

  @doc """
  读单层目录 drive_dir 下的条目（ROUTE B P3 drive-walk LIST 原语，本机）。
  返回 `{:ok, [%{name, object?}]}`（name 升序）；object? = 该子目录内含 meta.json。
  跳过内部前缀 .versions/.uploads/.tmp 与 meta.json/part.0 文件本身。目录不存在 -> {:ok, []}。
  """
  @spec list_dir(String.t(), keyword()) :: {:ok, [%{name: String.t(), object?: boolean()}]} | {:error, term()}
  def list_dir(drive_dir, _opts \\ []) do
    case File.ls(drive_dir) do
      {:ok, names} ->
        entries =
          names
          |> Enum.reject(&(&1 in @internal_prefixes))
          |> Enum.reject(&(&1 in [@meta_file, @part_file]))
          |> Enum.filter(fn n -> File.dir?(Path.join(drive_dir, n)) end)
          |> Enum.sort()
          |> Enum.map(fn n ->
            %{name: n, object?: File.regular?(Path.join([drive_dir, n, @meta_file]))}
          end)

        {:ok, entries}

      {:error, :enoent} ->
        {:ok, []}

      {:error, reason} ->
        {:error, reason}
    end
  end
```

### 步骤 3（实现绿）：`lib/maxio/cluster/transport.ex` 加 `list_dir` 回调 + 两 impl

behaviour 加回调（在 `commit_object` 之后）：

```elixir
  @callback list_dir(node(), String.t(), keyword()) ::
              {:ok, [%{name: String.t(), object?: boolean()}]} | {:error, term()}
```

`Transport.Erpc` 加（同 `get_sidecar` 的 call 模式，down 节点回 `{:error, :unavailable}`）：

```elixir
  @impl true
  def list_dir(node, drive_dir, opts) do
    call(node, :list_dir, [drive_dir, opts], fn -> {:error, :unavailable} end)
  end
```

`test/support/transport_in_process.ex`（`Transport.InProcess`）加（down 节点回 `{:error, :unavailable}`，否则委托 `ShardServer.list_dir`）：

```elixir
  @impl true
  def list_dir(node, drive_dir, opts) do
    if down?(node), do: {:error, :unavailable}, else: Maxio.Cluster.ShardServer.list_dir(drive_dir, opts)
  end
```

> 注：executor 逐字核对 `Transport.Erpc.call/4` 与 `InProcess.down?/1` 既有签名；`--warnings-as-errors` 要求两 impl 都实现新回调（全有或全无）。

跑：`mix test test/maxio/cluster/list_dir_test.exs` → 绿（4 passed）。`mix test`（全量）→ 绿。`mix format`。

**Commit**：`feat(routeB): Transport.list_dir + ShardServer.list_dir — single-endpoint dir walk primitive (B3-1)`

---

## 单元 B3-2 — `Maxio.Listing`（走盘核心：quorum-walk + 跨 set 归并 + 折叠 + 续点）

**目的**：跨 set 全端点走盘，惰性产出按 key 升序的对象流，应用 prefix/delimiter/start-after/max-keys，输出与 `Objects.list_objects_v2/2` 逐字段一致的 list_result + walk-position 续点。**有界内存**：从不物化整桶；每"对象"只需 quorum 个端点确认其存在（含 meta.json）。

### 设计（铁律 3/4）

- **对象枚举**：对桶下每个 set 的每个端点 `list_dir` 递归走盘（DFS，name 升序），把"含 meta.json 的目录"的相对路径（= key）产出。同一 key 在 N 端点重复出现，需在 set 内按 read_quorum 去重确认；跨 set 因路由确定（同 key 必同 set）无需跨 set 去重，只按 key 归并排序。
- **MVP 实现（B3 范围，正确性优先于极致惰性）**：走盘收集**候选 key 集**（用 `MapSet` 去重，每 key 记命中端点数），保留命中 ≥ 1 的 key（B3 shadow 不强制 quorum 门，避免与 PG 误报分歧；quorum 确认留 B4 翻权威时收紧——文档化）。对候选 key 排序后惰性折叠 prefix/delimiter/start-after/max-keys，超 max_keys 即停并产出续点。**有界内存的边界**：候选 key 集大小 = 桶内对象数；B3 用 `max_keys` + 续点把**输出**有界，候选集仍可能大——这是 MVP 已知边界（真·流式惰性走盘留后续优化），但**绝无 SQL 那种无 LIMIT 全量物化 + DoS**，且续点保证可分页遍历。executor 在 moduledoc 写明此边界。
- **续点 token**：base64 包裹「上次产出的最后 key」（walk-position，非 offset）；下次以 `start_after = last_key` 续走。`Continuation.encode/decode`。
- **delimiter 折叠**：key 去掉 prefix 后，若剩余含 delimiter，取 `prefix <> 截到首个 delimiter（含）` 为 common_prefix（去重）；否则为对象 key。复用语义对齐 `Objects.common_prefix_of/3`（executor 读其实现保持一致）。

### 步骤 1（TDD 红）：`test/maxio/listing_test.exs`

```elixir
defmodule Maxio.ListingTest do
  use ExUnit.Case, async: true
  alias Maxio.Listing
  alias Maxio.Cluster.Transport.InProcess

  # 单 set N=3（K=2 M=1）InProcess topology；3 端点同写 sidecar 模拟对象
  setup do
    InProcess.setup!()
    root = fn i -> Path.join(System.tmp_dir!(), "lst_d#{i}_#{System.unique_integer([:positive])}") end
    eps = for i <- 0..2, do: {:"ln#{i}", root.(i)}
    topo = %{data_shards: 2, parity_shards: 1, block_size: 1024,
             sets: %{0 => %{id: 0, endpoints: eps}}, set_ids: [0]}
    :persistent_term.put({Maxio.Cluster.Topology, :topology}, topo)
    on_exit(fn -> :persistent_term.erase({Maxio.Cluster.Topology, :topology}); Enum.each(eps, fn {_n, d} -> File.rm_rf(d) end) end)
    {:ok, topo: topo, eps: eps}
  end

  # 在所有端点为 bucket/key 写一个对象目录（含 meta.json）
  defp put(eps, bucket, key) do
    Enum.each(eps, fn {_n, drive} ->
      dir = Path.join([drive, bucket, key])
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "meta.json"), "{}")
    end)
  end

  defp opts(topo), do: [transport: InProcess, topology: topo]

  test "列举所有对象，key 升序", %{topo: topo, eps: eps} do
    put(eps, "b", "a.txt"); put(eps, "b", "m.txt"); put(eps, "b", "z.txt")
    r = Listing.list_objects_v2("b", %{max_keys: 100}, opts(topo))
    assert Enum.map(r.objects, & &1.key) == ["a.txt", "m.txt", "z.txt"]
    assert r.is_truncated == false
    assert r.key_count == 3
  end

  test "prefix 过滤", %{topo: topo, eps: eps} do
    put(eps, "b", "photos/1.jpg"); put(eps, "b", "photos/2.jpg"); put(eps, "b", "docs/a.txt")
    r = Listing.list_objects_v2("b", %{prefix: "photos/", max_keys: 100}, opts(topo))
    assert Enum.map(r.objects, & &1.key) == ["photos/1.jpg", "photos/2.jpg"]
  end

  test "delimiter 折叠 common_prefixes", %{topo: topo, eps: eps} do
    put(eps, "b", "photos/2006/a.jpg"); put(eps, "b", "photos/2007/b.jpg"); put(eps, "b", "root.txt")
    r = Listing.list_objects_v2("b", %{prefix: "photos/", delimiter: "/", max_keys: 100}, opts(topo))
    assert r.common_prefixes == ["photos/2006/", "photos/2007/"]
    assert r.objects == []
  end

  test "max_keys 截断 + 续点可续", %{topo: topo, eps: eps} do
    for k <- ~w(a b c d e), do: put(eps, "b", k)
    r1 = Listing.list_objects_v2("b", %{max_keys: 2}, opts(topo))
    assert Enum.map(r1.objects, & &1.key) == ["a", "b"]
    assert r1.is_truncated == true
    assert is_binary(r1.next_continuation_token)
    r2 = Listing.list_objects_v2("b", %{max_keys: 2, continuation_token: r1.next_continuation_token}, opts(topo))
    assert Enum.map(r2.objects, & &1.key) == ["c", "d"]
    assert r2.is_truncated == true
    r3 = Listing.list_objects_v2("b", %{max_keys: 2, continuation_token: r2.next_continuation_token}, opts(topo))
    assert Enum.map(r3.objects, & &1.key) == ["e"]
    assert r3.is_truncated == false
  end

  test "start-after", %{topo: topo, eps: eps} do
    for k <- ~w(a b c), do: put(eps, "b", k)
    r = Listing.list_objects_v2("b", %{max_keys: 100, start_after: "a"}, opts(topo))
    assert Enum.map(r.objects, & &1.key) == ["b", "c"]
  end

  test "Continuation encode/decode round-trip", %{} do
    tok = Maxio.Listing.Continuation.encode("photos/x.jpg")
    assert {:ok, "photos/x.jpg"} = Maxio.Listing.Continuation.decode(tok)
    assert :error = Maxio.Listing.Continuation.decode("!!!notbase64!!!")
  end
end
```

跑：`mix test test/maxio/listing_test.exs` → 红。

### 步骤 2（实现绿）：`lib/maxio/listing.ex`

```elixir
defmodule Maxio.Listing do
  @moduledoc """
  ROUTE B P3 —— 跨端点 drive-walk LIST（shadow，不翻权威）。

  对桶下每个 erasure set 的每个端点递归走盘（Transport.list_dir），把「含 meta.json 的目录」
  的相对路径作为对象 key 收集（同 key 在 N 端点/跨 set 去重），排序后惰性折叠
  prefix/delimiter/start-after/max-keys，输出与 Maxio.Objects.list_objects_v2/2 逐字段一致的
  list_result + walk-position 续点（绝不 offset）。

  铁律 4：输出经 max_keys + 续点有界、绝无 SQL 无 LIMIT 全量物化。MVP 已知边界：候选 key 集大小
  = 桶内对象数（真·流式惰性走盘留后续优化）；shadow 阶段不强制 quorum 门（命中 >=1 即收候选，避免
  与 PG 误报分歧），quorum 确认留 B4 翻 list 权威时收紧。
  """

  alias Maxio.Cluster.{Topology, Router}

  defmodule Continuation do
    @moduledoc "walk-position 续点 token（base64 包裹最后产出的 key；绝非 offset）。"
    @spec encode(String.t()) :: String.t()
    def encode(last_key) when is_binary(last_key), do: Base.url_encode64(last_key, padding: false)

    @spec decode(String.t()) :: {:ok, String.t()} | :error
    def decode(token) when is_binary(token) do
      case Base.url_decode64(token, padding: false) do
        {:ok, key} -> {:ok, key}
        :error -> :error
      end
    end

    def decode(_), do: :error
  end

  @spec list_objects_v2(String.t(), map(), keyword()) :: map()
  def list_objects_v2(bucket, list_opts, opts \\ []) do
    prefix = Map.get(list_opts, :prefix, "") || ""
    delimiter = Map.get(list_opts, :delimiter)
    max_keys = Map.get(list_opts, :max_keys, 1000) || 1000

    start_after =
      case Map.get(list_opts, :continuation_token) do
        nil -> Map.get(list_opts, :start_after)
        tok -> case Continuation.decode(tok), do: ({:ok, k} -> k; :error -> Map.get(list_opts, :start_after))
      end

    keys = collect_keys(bucket, prefix, opts) |> Enum.sort()

    keys =
      keys
      |> Enum.filter(fn k -> String.starts_with?(k, prefix) end)
      |> then(fn ks -> if start_after, do: Enum.filter(ks, &(&1 > start_after)), else: ks end)

    {objects, common_prefixes, truncated, last} =
      fold(keys, prefix, delimiter, max_keys, [], [], nil)

    next = if truncated, do: Continuation.encode(last), else: nil

    %{
      name: bucket,
      prefix: prefix,
      delimiter: delimiter,
      max_keys: max_keys,
      key_count: length(objects) + length(common_prefixes),
      is_truncated: truncated,
      next_continuation_token: next,
      start_after: Map.get(list_opts, :start_after),
      encoding_type: Map.get(list_opts, :encoding_type),
      objects: Enum.reverse(objects),
      common_prefixes: Enum.reverse(common_prefixes)
    }
  end

  # 收集桶下所有对象 key（跨 set 全端点递归走盘，去重）
  defp collect_keys(bucket, _prefix, opts) do
    transport = Keyword.get(opts, :transport, Maxio.Cluster.Transport.impl(opts))
    topo = Keyword.get(opts, :topology)
    set_ids = if topo, do: Topology.all_set_ids_from(topo), else: Topology.all_set_ids()

    set_ids
    |> Enum.flat_map(fn set_id ->
      endpoints = if topo, do: Topology.endpoints_from(topo, set_id), else: Topology.endpoints(set_id)

      endpoints
      |> Enum.flat_map(fn {node, drive} ->
        walk(transport, node, Path.join(drive, bucket), "")
      end)
    end)
    |> Enum.uniq()
  end

  # 递归 DFS：dir = 端点下当前目录绝对路径；rel = 相对 bucket 根的 key 前缀
  defp walk(transport, node, dir, rel) do
    case transport.list_dir(node, dir, []) do
      {:ok, entries} ->
        Enum.flat_map(entries, fn %{name: name, object?: obj?} ->
          child_rel = if rel == "", do: name, else: rel <> "/" <> name
          child_dir = Path.join(dir, name)
          here = if obj?, do: [child_rel], else: []
          here ++ walk(transport, node, child_dir, child_rel)
        end)

      {:error, _} ->
        []
    end
  end

  # 惰性折叠：产出 objects/common_prefixes，超 max_keys 即停
  defp fold([], _prefix, _delim, _max, objs, cps, _last), do: {objs, cps, false, nil}

  defp fold([key | rest], prefix, delimiter, max, objs, cps, _last) do
    cond do
      length(objs) + length(cps) >= max ->
        # 已达上限且仍有候选 -> 截断（last = 上一个产出项的 key，由调用链记录）
        {objs, cps, true, last_emitted(objs, cps)}

      true ->
        case common_prefix(key, prefix, delimiter) do
          nil ->
            fold(rest, prefix, delimiter, max, [%{key: key} | objs], cps, key)

          cp ->
            if cp in cps do
              fold(rest, prefix, delimiter, max, objs, cps, key)
            else
              fold(rest, prefix, delimiter, max, objs, [cp | cps], key)
            end
        end
    end
  end

  # common prefix：去 prefix 后剩余含 delimiter -> prefix <> 截到首个 delimiter（含）
  defp common_prefix(_key, _prefix, nil), do: nil

  defp common_prefix(key, prefix, delimiter) do
    rest = String.replace_prefix(key, prefix, "")

    case :binary.match(rest, delimiter) do
      {pos, len} -> prefix <> binary_part(rest, 0, pos + len)
      :nomatch -> nil
    end
  end

  # 截断时最后已产出项的 key：objs/cps 都是逆序累积，取两者中"最后纳入的" key。
  # 为正确性，fold 在每步把当前 key 作为潜在 last 传递；这里从已累积项推导最大 key。
  defp last_emitted(objs, cps) do
    keys =
      Enum.map(objs, & &1.key) ++
        Enum.map(cps, fn cp -> cp end)

    case keys do
      [] -> nil
      _ -> Enum.max(keys)
    end
  end
end
```

> 实现注意（executor 必校）：
> 1. `fold/7` 的 `last` 续点语义——上面用 `last_emitted/2` 从已产出项取 max key 作续点；因 keys 已升序、产出也升序，max 即"最后产出"。executor 跑「max_keys 截断 + 续点」用例确认 r1 续点 = `"b"`、r2 从 `> "b"` 续出 `["c","d"]`。若 delimiter 折叠下 common_prefix 的 key 与续点比较语义有偏差（cp 字符串 > 其下对象 key），executor 以「续点 = 最后纳入 objs/cps 对应的原始遍历 key」修正（保持「下次 start_after=该 key 能续上且不重不漏」）。
> 2. `then/2` + `case` 内联写法若触发格式/可读性问题，executor 可改 `with`/私有函数（语义不变）。
> 3. B3 的 list_result **不含 LastModified/ETag/Size**（走盘只到 key 级；shadow 比对只比 key 集 + common_prefixes，不比对象元数据——B3-3 明确）。若 view 渲染需要这些字段，shadow 路径不调 view（仅比对），故不阻塞。

跑：`mix test test/maxio/listing_test.exs` → 绿（含 round-trip）。`mix test`（全量）→ 绿。`mix format`。

**Commit**：`feat(routeB): Maxio.Listing — cross-endpoint drive-walk LIST with delimiter fold + walk-position continuation (B3-2)`

---

## 单元 B3-3 — list shadow 接线（`ObjectMeta.list_shadow` + config + handler）

**目的**：ListObjectsV2 handler 仍返回 PG SQL 结果（`authoritative_source[:list]=:pg`），同时跑 drive-walk 比对 key 集 + common_prefixes，分歧 `Log.warn`，绝不破坏列举路径（try/rescue 自吞，同 P2 read shadow）。

### 步骤 1（config）：`config/config.exs`

把 P2 加的 `authoritative_source` 扩展为含 `list`：

```elixir
# ROUTE B 元数据权威来源（读/列/写分别可切；P2 引入 :read，P3 引入 :list；默认全 :pg = 今天行为，shadow 不翻权威）。
config :maxio, :authoritative_source, read: :pg, list: :pg
```

### 步骤 2（TDD 红）：`test/maxio/object_meta_list_shadow_test.exs`

```elixir
defmodule Maxio.ObjectMetaListShadowTest do
  use Maxio.DataCase, async: false
  import ExUnit.CaptureLog
  alias Maxio.{ObjectMeta, Objects, Buckets}
  alias Maxio.Cluster.Transport.InProcess

  setup do
    InProcess.setup!()
    eps = for i <- 0..2, do: {:"lsn#{i}", Path.join(System.tmp_dir!(), "ls_d#{i}_#{System.unique_integer([:positive])}")}
    topo = %{data_shards: 2, parity_shards: 1, block_size: 1024, sets: %{0 => %{id: 0, endpoints: eps}}, set_ids: [0]}
    :persistent_term.put({Maxio.Cluster.Topology, :topology}, topo)
    on_exit(fn -> :persistent_term.erase({Maxio.Cluster.Topology, :topology}); Enum.each(eps, fn {_n, d} -> File.rm_rf(d) end) end)
    {:ok, _} = Buckets.create("lsb", "arn:aws:iam:::root")
    {:ok, topo: topo, eps: eps}
  end

  test "authoritative_source(:list) 默认 :pg" do
    assert ObjectMeta.authoritative_source(:list) == :pg
  end

  test "list_shadow 返回 :ok 且不抛（PG 与 drive-walk 一致时无分歧日志）", %{topo: topo, eps: eps} do
    Enum.each(eps, fn {_n, d} ->
      dir = Path.join([d, "lsb", "k.txt"]); File.mkdir_p!(dir); File.write!(Path.join(dir, "meta.json"), "{}")
    end)
    {:ok, _} = Objects.put_version_with_id("lsb", "k.txt", "null", %{size: 1, etag: "\"e\""})
    pg = Objects.list_objects_v2("lsb", %{max_keys: 100})
    assert :ok = ObjectMeta.list_shadow("lsb", %{max_keys: 100}, pg: pg, transport: InProcess, topology: topo)
  end

  test "PG 有 key 而 drive-walk 缺 -> 记分歧日志，仍 :ok（不破坏列举）", %{topo: topo} do
    {:ok, _} = Objects.put_version_with_id("lsb", "ghost.txt", "null", %{size: 1, etag: "\"g\""})
    pg = Objects.list_objects_v2("lsb", %{max_keys: 100})
    log = capture_log(fn ->
      assert :ok = ObjectMeta.list_shadow("lsb", %{max_keys: 100}, pg: pg, transport: InProcess, topology: topo)
    end)
    assert log =~ "list divergence" or log =~ "divergence"
  end
end
```

跑：`mix test test/maxio/object_meta_list_shadow_test.exs` → 红（`list_shadow/3` 未定义）。

### 步骤 3（实现绿）：`lib/maxio/object_meta.ex` 加 `list_shadow/3`

```elixir
  @doc """
  ROUTE B P3 —— ListObjectsV2 的 drive-walk shadow（best-effort，不翻 list 权威）。
  比对 PG SQL 结果（opts[:pg]）与 Maxio.Listing 走盘结果的 key 集 + common_prefixes，分歧 Log.warn。
  任何异常自吞（绝不破坏列举路径）。返回 :ok。
  """
  @spec list_shadow(String.t(), map(), keyword()) :: :ok
  def list_shadow(bucket, list_opts, opts) do
    pg = Keyword.get(opts, :pg)

    try do
      walk = Maxio.Listing.list_objects_v2(bucket, list_opts, opts)
      compare_list(bucket, list_opts, pg, walk)
    rescue
      e -> Maxio.S3.Log.warn("list shadow error", bucket: bucket, reason: inspect(e))
    catch
      kind, reason -> Maxio.S3.Log.warn("list shadow caught", bucket: bucket, reason: inspect({kind, reason}))
    end

    :ok
  end

  defp compare_list(bucket, _list_opts, %{} = pg, %{} = walk) do
    pg_keys = MapSet.new(Map.get(pg, :objects, []), & &1.key)
    walk_keys = MapSet.new(Map.get(walk, :objects, []), & &1.key)
    pg_cps = MapSet.new(Map.get(pg, :common_prefixes, []))
    walk_cps = MapSet.new(Map.get(walk, :common_prefixes, []))

    only_pg = MapSet.difference(pg_keys, walk_keys)
    only_walk = MapSet.difference(walk_keys, pg_keys)
    cp_only_pg = MapSet.difference(pg_cps, walk_cps)
    cp_only_walk = MapSet.difference(walk_cps, pg_cps)

    if MapSet.size(only_pg) > 0 or MapSet.size(only_walk) > 0 or
         MapSet.size(cp_only_pg) > 0 or MapSet.size(cp_only_walk) > 0 do
      Maxio.S3.Log.warn("list divergence: PG vs drive-walk",
        bucket: bucket,
        only_pg: inspect(Enum.take(MapSet.to_list(only_pg), 20)),
        only_walk: inspect(Enum.take(MapSet.to_list(only_walk), 20)),
        cp_only_pg: inspect(MapSet.to_list(cp_only_pg)),
        cp_only_walk: inspect(MapSet.to_list(cp_only_walk))
      )
    end

    :ok
  end

  defp compare_list(_bucket, _opts, _pg, _walk), do: :ok
```

### 步骤 4（handler 接线，shadow 不改行为）

`lib/maxio/s3/handlers/bucket.ex` 的 `list_objects_v2/1` 在用 `Objects.list_objects_v2` 取到结果（设其为 `result`）、渲染前，追加一行 best-effort（不改返回/控制流）：

```elixir
    _ = Maxio.ObjectMeta.list_shadow(bucket, list_opts, pg: result)
```

> 接线最小化：`list_opts` 用 handler 已解析的 prefix/delimiter/max-keys/start-after/continuation map；`opts` 仅传 `pg: result`（生产读 config topology/transport；无 topology 的单机 FS dev 下 `list_shadow` 的 try/rescue 自吞并记一条 warn，列举不受影响）。executor 读 `list_objects_v2/1` 现有变量名对齐。

跑：`mix test test/maxio/object_meta_list_shadow_test.exs` → 绿。`mix test`（全量）→ 绿。`mix compile --warnings-as-errors` 零警告。`mix format`。

**Commit**：`feat(routeB): list_shadow drive-walk vs PG comparison + authoritative_source[:list] + ListObjectsV2 hook (B3-3)`

---

## P3 完成判据

- `mix compile --warnings-as-errors` 零警告；`mix test` 全量绿（630 + B3 新增约 17）。
- `Transport.list_dir`/`ShardServer.list_dir` 单层走盘 + object? 标记 + 排除内部前缀 + 升序。
- `Maxio.Listing` 跨 set 全端点递归走盘、prefix/delimiter/start-after/max-keys 折叠、walk-position 续点可分页遍历（不重不漏）。
- `authoritative_source(:list)` 默认 `:pg`；ListObjectsV2 仍返回 PG 结果；drive-walk 分歧记结构化日志、绝不静默、绝不破坏列举路径。
- `git status` 干净 + `mix format --check-formatted` 退出 0。

## 显式 DEFER（P4+，文档化）

- **翻转 list 权威**（`list: :sidecar`，走盘成 list 唯一真值，强制 quorum 门）→ P4。
- **ListObjectVersions 走盘**（`.versions/` 树遍历）→ P4。
- **真·流式惰性走盘**（候选 key 集不再全收集，端点游标 + 堆归并按需产出）→ 后续优化（B3 用 max_keys+续点把输出有界，候选集大小 = 桶对象数为已知 MVP 边界）。
- **走盘 sidecar 富集 LastModified/ETag/Size**（B3 走盘只到 key 级；翻权威时需读 sidecar 富集对象字段，复用 P2 MetaReconcile）→ P4。
- **原子写权威 / 读权威翻转 / sidecar heal 回写** → P4。


