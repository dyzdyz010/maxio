
# Phase 1 — 无悔正确性修正（ROUTE B subsumes / needs；不翻权威，纯硬化）

> **阶段目标**：把 ROUTE B 从构造上要消灭的那批 bug 的「地基修正」先落地——这些修正即便 ROUTE B 后续阶段不做也独立正确、独立有价值（铁律 2 不打补丁式 hack，从架构层根治）。**本阶段 PG 仍是权威**，行为对客户端不变；只是写路径变原子、锁变横跨 seam、拓扑变严校验、LIST 加临时硬闸、sidecar schema 就位。
> **可回滚性**：每个单元纯加固/向后兼容；原子提交 temp-then-rename 对读者透明（rename 是原子原语）；sidecar v2 是 v1 的超集（`migrate_v1` 幂等）。flag `:durability` 可关 fsync 回退。**阶段整体可独立发布**。
> **最高风险单元**：**B1-2**（temp-then-rename 改写既有 in-place 写——必须保证 crash 任意点要么旧要么新，绝不撕裂；Windows rename-over-open-file 语义须处理，见 §Windows 注意）。

---

# 单元 B1-1：对象锁横跨「字节 + 元数据」提交 seam

**目标**：今天 `Distributed` 的 `Lock.with_lock({bucket,key})` **只**守护后端字节写（`put_locked`/`assemble_locked`/`do_delete`），而 handler 在锁**外**做 `Objects.put_version_with_id`（元数据落库）——并发同 key PUT 可让「A 的字节 + B 的元数据」交错（静默 ETag/bytes 分歧）。本单元把**整个提交 seam（字节 + 元数据）纳入同一对象锁**：在 handler 层引入 `Maxio.Lock.with_object_lock/2` 包裹 `Storage.put + Objects.put_version_with_id` 整体，使 Distributed 后端**不再**自持锁（避免重入/双锁），改由 handler 单点持锁横跨 seam。FS/EC 单机也经同一门面（单节点退化本地锁）。

**依赖**：M7。**TDD**：两并发同 key PUT（不同字节）→ 最终 sidecar 的 etag 与 PG 的 etag **必一致**（要么全 A 要么全 B，绝不 A-bytes/B-meta）。

### 设计要点（铁律 2/3）
- **锁单点上移到 handler**：`Maxio.S3.Handlers.Object.do_put/copy/delete` 与 `Maxio.S3.Handlers.Multipart.complete` 在调 `Storage.*` + `Objects.*` **整段**外包一层 `Maxio.Lock.with_object_lock({bucket,key}, fun)`。
- **后端去重锁**：`Maxio.Storage.Distributed` 的 `do_put`/`do_assemble`/`do_delete` 现有 `Lock.with_lock` 改为移除——因为 handler 已持同名锁，后端再 `:global.trans` 同 `{bucket,key}` 会**死等自己**（`:global.trans` 非重入）。锁责任收敛到 handler 单点（铁律 2：锁是请求编排关注点，不是字节后端关注点）。EC/FS 后端本就无锁，行为对齐。
- **新门面 `Maxio.Lock`**（非 `Maxio.Cluster.Lock`，后者是底层 :global 实现）：`with_object_lock/2` = `Maxio.Cluster.Lock.with_lock/2` 的语义包装 + 获锁失败映射 S3 503。单节点 / FS 后端：`Maxio.Cluster.Lock.with_lock` 在 `nodes()==[self()]` 下退化本地锁，**同一代码路径**，无需后端分支。

### 步骤 1（TDD 红）：并发同 key PUT 的 seam 一致性测试

新建 `test/maxio/s3/seam_consistency_test.exs`（`async: false`，经 `Maxio.S3.Endpoint.call/2` 自签 SigV4，复用 `Maxio.Test.SigV4Request`，后端用 Distributed + InProcess 注入 N=6 K=4 M=2 topology）：

    defmodule Maxio.S3.SeamConsistencyTest do
      use Maxio.DataCase, async: false
      alias Maxio.{Objects, Storage}

      # 两并发同 key PUT（不同字节）—— 提交 seam 在同一对象锁内，最终 sidecar.etag 必等于 PG.etag。
      test "concurrent same-key put: sidecar etag and index etag never diverge" do
        # ... 起 InProcess topology（同 cluster_e2e_test setup）；建桶；
        # 并发两 Task：各 Maxio.Lock.with_object_lock 写不同 1MB 随机字节 + Objects.put_version_with_id；
        # 等两 Task 完成（Task.await）；读 PG get_metadata 的 etag + 读 sidecar 的 etag；assert 二者相等。
      end
    end

> 该测试用 `Maxio.Lock.with_object_lock/2`（本单元新建）。先写测试确认红。

执行（确认红）：

    mix test test/maxio/s3/seam_consistency_test.exs

### 步骤 2（实现绿）：`Maxio.Lock` 门面

新建 `lib/maxio/lock.ex`：

    defmodule Maxio.Lock do
      @moduledoc """
      请求编排层的对象锁门面（ROUTE B B1-1）。把「字节写 + 元数据提交」整段纳入同一对象级互斥锁，
      消灭并发同 key 写的「字节-元数据交错分歧」（静默 ETag/bytes 分歧）。底层复用
      Maxio.Cluster.Lock.with_lock/2（:global.trans 全 mesh 互斥；单节点退化本地锁，同一代码路径）。

      铁律 3：获锁失败 -> {:error, :locked}，调用方（handler）映射 S3 503，绝不静默并发写同对象。
      铁律 2：锁是请求编排关注点 —— 字节后端（Distributed/EC/FS）不再自持对象锁；锁责任收敛到本门面单点。
      """
      alias Maxio.Cluster.Lock

      @type resource :: {String.t(), String.t()}

      @doc "在对象级互斥锁内运行 fun（横跨字节+元数据提交）。获锁失败 -> {:error, :locked}。"
      @spec with_object_lock(resource(), (-> result)) :: {:ok, result} | {:error, :locked}
            when result: var
      def with_object_lock({_bucket, _key} = resource, fun) when is_function(fun, 0) do
        Lock.with_lock(resource, fun)
      end
    end

### 步骤 3（实现绿）：handler 提交段外包对象锁

`lib/maxio/s3/handlers/object.ex` 的 `do_put/1`，把「`Storage.put` + 校验 + `Objects.put_version_with_id`」整段移进 `Maxio.Lock.with_object_lock`（version_id/SSE/tags 等纯计算/读保持锁外）。改写提交核心：

    commit_result =
      Maxio.Lock.with_object_lock({bucket, key}, fn ->
        case Storage.put(bucket, key, version_id, chunks) do
          {:ok, %{size: size, etag: etag, sha256: sha256}} ->
            {:ok, obj} =
              try do
                unless sse_requested do
                  :ok = verify_decoded_length!(conn, payload_mode, size)
                  :ok = verify_content_sha256!(conn, payload_mode, sha256)
                end

                Objects.put_version_with_id(bucket, key, version_id, %{
                  size: size, etag: etag, content_type: content_type, storage_class: "STANDARD",
                  acl_canned: header(conn, "x-amz-acl") || "private", tags: tags_map,
                  sse_algorithm: sse_requested, sse_envelope: sse_envelope
                })
              rescue
                err ->
                  _ = Storage.delete(bucket, key, version_id)
                  Log.warn("put object rolled back orphan bytes",
                    action: :put_object, bucket: bucket, key: key, reason: :incomplete_body)
                  reraise(err, __STACKTRACE__)
              end

            {:ok, {size, etag, obj}}

          {:error, reason} -> {:error, reason}
        end
      end)

    case commit_result do
      {:ok, {:ok, {_size, etag, obj}}} ->
        # ... 既有成功响应（put_resp_header etag / version_id / sse / 200）...
      {:ok, {:error, :invalid_key}} ->
        raise Error.new(:invalid_argument, resource: "/#{bucket}/#{key}", message: "Invalid key")
      {:ok, {:error, reason}} ->
        raise Error.new(:internal_error, message: inspect(reason))
      {:error, :locked} ->
        raise Error.new(:slow_down, resource: "/#{bucket}/#{key}")
    end

> `:slow_down` 错误码若 `Maxio.S3.Error` 未定义，须在 `Maxio.S3.Error` 加映射（503 `SlowDown`，对齐 AWS）。同样 `delete/1`（Unversioned 真删段）与 `copy/1` 目标写提交段、`Multipart.complete`（assemble + put_metadata）外包同锁。**注意 `copy` 源读不持目标锁**（避免跨 key 死锁，仅目标写持目标锁）。

### 步骤 4（实现绿）：Distributed 后端移除自持锁

`lib/maxio/storage/distributed.ex`：`do_put` 改直调 `put_locked`（去 `Lock.with_lock` 包裹），`do_assemble` 改直调 `assemble_locked`，`do_delete` 去 `Lock.with_lock`（直接 `Enum.each(dirs, delete_shard)`）。删未用 `alias Lock`。moduledoc 更新：「对象锁由 handler 层 `Maxio.Lock` 横跨提交 seam 单点持有；后端不自持，避免双锁/:global.trans 非重入死等」。

> **架构性注意**：移除后端锁后，直接经 `Storage.put` 的非 handler 调用方（backfill task、scanner、conformance 测试）若需并发安全须自行 `Maxio.Lock.with_object_lock`。conformance 单线程无需；backfill/scanner 各单元显式加锁。

### 步骤 5（绿 + 提交）

    mix compile --warnings-as-errors
    mix test test/maxio/s3/seam_consistency_test.exs
    mix test

期望：新测试绿；全量 510+ 绿（既有并发不变，锁退化本地）。提交。

**验收（B1-1）**：并发同 key PUT 后 sidecar.etag == PG.etag；Distributed 后端不再自持对象锁（grep 确认）；`Maxio.Lock.with_object_lock` 单点持锁横跨字节+元数据；获锁失败映射 503。全量回归绿、`--warnings-as-errors` 零警告。

**可回滚性**：纯加锁 + 锁点上移；无 schema 变更；行为对客户端不变（仅消除并发分歧）。回退 = 还原后端自持锁 + 去 handler 包裹。

---

# 单元 B1-2：原子 temp-then-rename + fsync-before-quorum

**目标**：今天 `ShardServer.put_shard`（EC `do_put` 同理）**就地** `:file.pwrite` 到 `<dir>/part.0`，`put_sidecar` 就地 `File.write` `meta.json`——crash 在分片写与 sidecar 写之间留**不一致对象**，且就地覆盖对并发读者非原子；更无任何 `fsync`，write-quorum 在掉电下是**耐久谎言**。本单元改为 **temp-dir + 原子 rename + fsync-before-quorum**：每端点把新分片 + 新 sidecar 写到 `<drive>/.tmp/<uuid>/`，`fsync` 文件 + 目录，再原子 `rename` 到 final obj-dir（数据先于元数据，对齐 MinIO PR #10734），成功端点数 ≥ write_quorum 才算提交，否则 `File.rm_rf` 全部 temp。

**依赖**：B1-1。**TDD**：(a) 提交后 obj-dir 含完整 part.0 + meta.json；(b) 模拟 crash（写完 temp 但未 rename）→ final obj-dir 不存在（旧值保留），temp 可被 GC；(c) fsync 开关测试（fsync:true 时 `:file.sync` 被调用）。

### 设计要点（铁律 3/4 + Windows）
- **MinIO 顺序：数据先于元数据**（PR #10734）。落地：先原子 rename `part.0`（temp→final 同 drive 卷内，`:file.rename` 原子），fsync final 目录；**再**原子 rename `meta.json`（temp `meta.json` → final）。crash 在两 rename 之间 → 数据在、meta 旧/无（harmless，旧值或交 heal），**绝不 meta 指向不存在数据**。
- **Windows rename-over-open-file**（STATUS/research 已警示）：`:file.rename/2` over 既有 target 在 Windows 上若 reader 持文件打开会失败。落地：读侧 GET 用 `:file.open` 短持（M6 已逐块 pread 后 close，窗口小）；写侧 rename **同卷**（temp 在 `<drive>/.tmp`，final 在 `<drive>/<bucket>/...`，同 drive 根 = 同卷）保证原子；rename 失败（target busy）→ 有界重试后 `{:error, :rename_busy}`，handler 映射 503（绝不静默写坏）。
- **fsync**：`config :maxio, :durability, fsync: true`（prod）/`false`（test 快）。fsync `part.0` 文件 fd（`:file.sync/1`）+ tmp/final 目录 fd（POSIX：open dir + fsync；Windows：best-effort，文档化对齐 MinIO Windows 行为）。

### 步骤 1（TDD 红）：ShardServer 原子提交单测

新建 `test/maxio/cluster/shard_server_atomic_test.exs`（`async: false`）：

    defmodule Maxio.Cluster.ShardServerAtomicTest do
      use ExUnit.Case, async: false
      alias Maxio.Cluster.ShardServer

      setup do
        root = Path.join(System.tmp_dir!(), "maxio_atomic_#{System.unique_integer([:positive])}")
        on_exit(fn -> File.rm_rf(root) end)
        %{root: root}
      end

      test "prepare_commit writes to tmp, commit renames atomically to final", %{root: root} do
        obj_dir = Path.join([root, "bucket", "key"])
        meta = %{"ec" => %{"k" => 4, "m" => 2, "block_size" => 16, "algo" => "blake3-256"},
                 "size" => 4, "etag" => "x", "parts" => [%{"part" => 0, "size" => 4}],
                 "shards" => [%{"drive" => 0, "shard_file_size" => 2, "block_hashes" => ["aa"]}]}
        {:ok, tmp} = ShardServer.prepare_commit(obj_dir, %{0 => <<1, 2>>}, 2, meta, fsync: false, drive_root: root)
        refute File.exists?(Path.join(obj_dir, "part.0"))
        assert File.exists?(Path.join(tmp, "part.0"))
        :ok = ShardServer.commit(tmp, obj_dir, fsync: false)
        assert File.exists?(Path.join(obj_dir, "part.0"))
        assert File.exists?(Path.join(obj_dir, "meta.json"))
        refute File.exists?(tmp)
      end

      test "crash before commit leaves final absent (no torn object)", %{root: root} do
        obj_dir = Path.join([root, "bucket", "key2"])
        meta = %{"shards" => [], "size" => 0}
        {:ok, _tmp} = ShardServer.prepare_commit(obj_dir, %{}, 1, meta, fsync: false, drive_root: root)
        refute File.exists?(Path.join(obj_dir, "meta.json"))
      end
    end

执行（确认红——`prepare_commit`/`commit` 未定义）：

    mix test test/maxio/cluster/shard_server_atomic_test.exs

### 步骤 2（实现绿）：ShardServer 加原子提交函数

`lib/maxio/cluster/shard_server.ex` 追加（保留既有 `put_shard`/`get_shard`/`put_sidecar`/... 不删，B4 切换调用点；本单元先提供原子原语 + 单测）：

    @tmp_root ".tmp"

    @doc """
    原子提交准备：整对象所有 block 分片（block_map=%{block_index=>shard_bytes}）+ sidecar 写到
    <drive_root>/.tmp/<uuid>/{part.0,meta.json}，fsync（opts[:fsync]）。返回 {:ok, tmp_dir}。
    drive_root 由调用方传入（端点 drive 根，定位同卷 .tmp 保证 rename 原子）。
    """
    @spec prepare_commit(String.t(), %{non_neg_integer() => binary()}, pos_integer(), map(), keyword()) ::
            {:ok, String.t()} | {:error, term()}
    def prepare_commit(_drive_obj_dir, block_map, shard_len, meta, opts) do
      drive_root = Keyword.fetch!(opts, :drive_root)
      fsync? = Keyword.get(opts, :fsync, true)
      tmp = Path.join([drive_root, @tmp_root, uuid()])
      File.mkdir_p!(tmp)
      path = Path.join(tmp, @part_file)
      {:ok, fd} = :file.open(String.to_charlist(path), [:read, :write, :binary, :raw])

      try do
        Enum.each(block_map, fn {j, shard} -> :ok = :file.pwrite(fd, j * shard_len, shard) end)
        if fsync?, do: :ok = :file.sync(fd)
      after
        :file.close(fd)
      end

      File.write!(Path.join(tmp, @meta_file), Meta.encode(meta))
      if fsync?, do: sync_path(Path.join(tmp, @meta_file))
      {:ok, tmp}
    end

    @doc """
    原子提交：tmp_dir 的 part.0（数据先）再 meta.json（元数据后）原子 rename 到 final obj-dir
    （同卷 :file.rename 原子；MinIO PR #10734 数据先于元数据，crash 绝不 meta 指向不存在数据）。
    """
    @spec commit(String.t(), String.t(), keyword()) :: :ok | {:error, term()}
    def commit(tmp_dir, drive_obj_dir, opts) do
      fsync? = Keyword.get(opts, :fsync, true)
      File.mkdir_p!(drive_obj_dir)

      with :ok <- rename_atomic(Path.join(tmp_dir, @part_file), Path.join(drive_obj_dir, @part_file)),
           :ok <- maybe_sync_dir(fsync?, drive_obj_dir),
           :ok <- rename_atomic(Path.join(tmp_dir, @meta_file), Path.join(drive_obj_dir, @meta_file)),
           :ok <- maybe_sync_dir(fsync?, drive_obj_dir) do
        _ = File.rm_rf(tmp_dir)
        :ok
      end
    end

    defp uuid, do: :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)

    defp rename_atomic(src, dst), do: rename_atomic(src, dst, 5)
    defp rename_atomic(src, dst, 0), do: do_rename(src, dst)

    defp rename_atomic(src, dst, n) do
      case do_rename(src, dst) do
        :ok -> :ok
        {:error, reason} when reason in [:eacces, :eexist, :ebusy] -> rename_atomic(src, dst, n - 1)
        {:error, _} = err -> err
      end
    end

    defp do_rename(src, dst) do
      case :file.rename(String.to_charlist(src), String.to_charlist(dst)) do
        :ok -> :ok
        {:error, reason} -> {:error, reason}
      end
    end

    defp maybe_sync_dir(false, _dir), do: :ok
    defp maybe_sync_dir(true, dir), do: sync_dir(dir)

    defp sync_path(path) do
      case :file.open(String.to_charlist(path), [:read, :binary, :raw]) do
        {:ok, fd} ->
          _ = :file.sync(fd)
          :file.close(fd)
          :ok

        {:error, _} ->
          :ok
      end
    end

    defp sync_dir(dir) do
      case :file.open(String.to_charlist(dir), [:read, :raw]) do
        {:ok, fd} ->
          _ = :file.sync(fd)
          :file.close(fd)
          :ok

        {:error, _} ->
          :ok
      end
    end

> `sync_dir` 在 Windows 上 `:file.open` 目录可能失败 → `:ok`（best-effort，moduledoc 诚实声明对齐 MinIO Windows 行为）。

### 步骤 3（实现绿）：EC + FS 单机后端走原子提交

- `lib/maxio/storage/erasure_coded.ex` `do_put`：把「逐块 `IO.binwrite` 到各盘就地 part.0 fd + `write_sidecars` 就地」改为「各盘把分片写到 `<drive>/.tmp/<uuid>/part.0`（逐块 pwrite，drive_root = `cfg.drives` 元素）+ sidecar 写各 temp + 全盘 `commit`，成功盘数 ≥ write_quorum」。保留逐块流式（分片边算边写 temp fd），仅把「就地」换成「temp + rename」。内存仍 ≈ 一块 × N 分片（铁律 4）。
- `lib/maxio/storage/fs.ex` `do_put`：把「就地 `File.open(path,[:write])`」改为「写 `<data_dir>/.tmp/<uuid>` + fsync + rename 到 final」。FS 无 sidecar（B6 才加），本单元仅原子化字节写。

### 步骤 4（实现绿）：Transport + Distributed 接原子提交

- `lib/maxio/cluster/transport.ex`：behaviour 加两 callback：`begin_tmp(node, drive_root) :: {:ok, tmp_dir} | {:error,_}`（建 `<drive_root>/.tmp/<uuid>` 返回路径）与 `commit_object(node, tmp_dir, final_obj_dir, opts) :: :ok | {:error,_}`（fsync + 数据先于元数据 rename）。逐块写仍用既有 `put_shard(node, tmp_dir, j, shard, shard_len)`、sidecar 用既有 `put_sidecar(node, tmp_dir, meta)`——drive_obj_dir 形参传 tmp_dir。`Erpc` 与 `InProcess` 各实现（Erpc 转 :erpc 到 ShardServer 新函数，本地直调；InProcess 委托 ShardServer）。
- `lib/maxio/storage/distributed.ex` `put_locked`/`assemble_locked`：端点 i 首块前 `tx.begin_tmp(node, drive_root)`（drive_root = endpoint 的 drive）得 tmp_dir 贯穿整 PUT，逐块 `put_shard(node, tmp_dir, ...)`，流尾 `put_sidecar(node, tmp_dir, meta)`，最后 `tx.commit_object(node, tmp_dir, final_dir, fsync)`，成功端点数 ≥ write_quorum 才 `{:ok}`，否则全端点 `tx.delete_shard(tmp_dir)` 清理 + `{:error, :write_quorum}`。

> **端点 drive_root**：endpoint = `{node, drive}`，drive 即 drive_root；final_dir = `Path.join(drive, obj_rel)`。tmp 在 `<drive>/.tmp` 与 final 同卷，rename 原子。

### 步骤 5（绿 + 提交）

    mix compile --warnings-as-errors
    mix test test/maxio/cluster/shard_server_atomic_test.exs
    mix test test/maxio/storage/
    mix test

期望：原子提交单测绿；conformance 三后端全绿（提交后对象可读、crash-before-commit 无撕裂）；全量绿。提交。

**验收（B1-2）**：写路径全部经 temp-then-rename（grep 确认就地 `File.write` `meta.json` / 就地 part.0 写已下线于写路径）；数据先于元数据 rename；fsync 在 `fsync:true` 时被调用（单测断言）；crash-before-commit 测试证 final 缺失（无撕裂）；write_quorum 未达 → temp 清理 + `{:error,:write_quorum}`。全量回归绿。

**可回滚性**：temp+rename 对读者透明（读侧仍读 final 的 part.0/meta.json）；`:durability fsync:false` 可关 fsync 回退性能。**这是本阶段最高风险单元**：rename 原子性是正确性基石，Windows busy 重试 + 同卷约束须 reviewer 重点核验。

---

# 单元 B1-3：拓扑 distinct-node 校验器 + SQL LIST 临时硬 LIMIT 闸

**目标**：两个独立无悔修正。(A) `Topology.parse_and_validate!` 今天只校验 `endpoints==K+M` 与 `M<=N/2`，**不**校验一个 set 的 N 端点是否落在 **distinct 节点（failure domain）**——错配置（两端点同节点）静默把真实容错降到 M 以下，使 quorum 成谎言。本单元加 distinct-node 校验（违反 raise，铁律 3 绝不带病启动；单机部署经 `allow_colocated_endpoints: true` 显式放行）。(B) `Objects.list_objects_v2`/`list_object_versions`/`Multipart.list_uploads` 今天 `Repo.all` 无 SQL LIMIT，大桶 = DoS；ROUTE B 后期 drive-walk 从构造消除，但 PG 权威期需**临时硬 LIMIT 闸**。

**依赖**：M7。**TDD**：(A) 同节点重复端点 → `parse_and_validate!` raise；显式 `allow_colocated_endpoints: true` → 放行；(B) 大量行 `list_objects_v2` 候选有界。

### 步骤 1（TDD 红）：distinct-node 校验测试

`test/maxio/cluster/topology_test.exs` 追加：

    test "parse_and_validate! rejects a set whose endpoints are not on distinct nodes" do
      cfg = [
        data_shards: 2, parity_shards: 1, block_size: 16,
        pools: [%{id: 0, sets: [%{id: 0, endpoints: [
          {:"a@h", "/d0"}, {:"a@h", "/d1"}, {:"b@h", "/d2"}
        ]}]}]
      ]
      assert_raise ArgumentError, ~r/distinct|failure domain|同一节点/, fn ->
        Maxio.Cluster.Topology.parse_and_validate!(cfg)
      end
    end

    test "allow_colocated_endpoints true permits colocated set (single-node degraded)" do
      cfg = [
        data_shards: 2, parity_shards: 1, block_size: 16, allow_colocated_endpoints: true,
        pools: [%{id: 0, sets: [%{id: 0, endpoints: [
          {:"a@h", "/d0"}, {:"a@h", "/d1"}, {:"a@h", "/d2"}
        ]}]}]
      ]
      assert %{set_ids: [0]} = Maxio.Cluster.Topology.parse_and_validate!(cfg)
    end

执行（确认红）：

    mix test test/maxio/cluster/topology_test.exs

### 步骤 2（实现绿）：Topology 加 distinct-node 校验

`lib/maxio/cluster/topology.ex` `parse_and_validate!`，在 set 内 endpoints 数校验之后、reduce 回调内加：

    allow_colocated = Keyword.get(cfg, :allow_colocated_endpoints, false)
    # ... reduce set 回调内：
    unless allow_colocated do
      ep_nodes = Enum.map(s.endpoints, fn {node, _drive} -> node end)
      if length(Enum.uniq(ep_nodes)) != length(ep_nodes) do
        raise ArgumentError,
              "topology: set #{s.id} 的端点未落在 distinct 节点（failure domain）；" <>
                "同一节点上多端点会把真实容错降到 M 以下（quorum 谎言）。" <>
                "单机部署/测试请显式设 allow_colocated_endpoints: true。"
      end
    end

> config 文档：dev/test 单机 EC 拓扑加 `allow_colocated_endpoints: true`；prod 多节点不设（默认 false 强制 distinct）。`Maxio.Application` 的 InProcess 测试拓扑构造处 + 既有 cluster 测试的注入拓扑同步加该键（避免现有单机测试 break）。

### 步骤 3（TDD 红 + 实现绿）：SQL LIST 硬 LIMIT 闸

`test/maxio/objects_test.exs`（或新建 `objects_limit_test.exs`）：插 `sql_hard_limit` 余量内的大量行同 prefix，断言 `list_objects_v2` 返回 ≤ max_keys 且不 OOM。

`lib/maxio/objects.ex` `list_objects_v2` 的 `candidates = Repo.all(base_query)` 前给 `base_query` 加 limit：

    hard_limit = Application.get_env(:maxio, :listing, [])[:sql_hard_limit] || 100_000
    fetch_limit = min(hard_limit, max_keys * 4 + 1000)
    base_query = limit(base_query, ^fetch_limit)

> **语义保真**：折叠 delimiter 时一个公共前缀可能吃掉很多行，故 `max_keys+1` 不够；取 `max_keys*4+1000` 经验余量，上限 `hard_limit` 防 DoS。`list_object_versions` 的 `Repo.all(base)` 与 `Multipart.list_uploads` 的 `Repo.all(base)` 同法加 `limit(^fetch_limit)`。**这是临时闸**：B3 drive-walk 上线后 PG 仅作快路径，硬 LIMIT 保留为 DoS 兜底。

### 步骤 4（绿 + 提交）

    mix compile --warnings-as-errors
    mix test test/maxio/cluster/topology_test.exs test/maxio/objects_test.exs
    mix test

期望：distinct-node raise/allow 测试绿；SQL LIMIT 闸测试绿；全量绿（既有列举行为不变——余量足够覆盖现有测试规模；既有单机拓扑加 allow_colocated 键不破坏）。提交。

**验收（B1-3）**：错配置启动期 raise（除非显式 allow）；三处 SQL LIST 均有有界 `limit`，大桶不 OOM；现有列举/集群测试行为不变。全量回归绿。

**可回滚性**：纯校验 + 查询加 limit；对合法配置/常规桶不变。回退 = 去校验 / 去 limit。

---

# 单元 B1-4：sidecar v2 schema（`Maxio.Sidecar`）+ reverse-GC 脚手架

**目标**：定义 ROUTE B 的 sidecar v2 形态与编解码（纯函数，**不写盘**），为 B2 起「sidecar 自描述」打地基。v2 在 M6 既有 `meta.json` 之上加 `format:"maxio/2"` + `versions` 数组（本计划选**方案 B**：每版本独立目录 + 自描述 sidecar，故 `versions` 通常单元素；保留数组形态兼容未来单 sidecar 多版本）。同时为 reverse-GC 建脚手架接口（B5-2 填实现）。

**依赖**：B1-2。**TDD**：v2 编解码 round-trip；`migrate_v1` 幂等；`latest`/`find_version`/`signature` 真值。

### 步骤 1（TDD 红）：`Maxio.Sidecar` 单测

新建 `test/maxio/storage/sidecar_test.exs`：

    defmodule Maxio.SidecarTest do
      use ExUnit.Case, async: true
      alias Maxio.Sidecar

      @v1 %{
        "ec" => %{"k" => 4, "m" => 2, "block_size" => 1024, "algo" => "blake3-256"},
        "size" => 10, "etag" => "abc", "sha256" => "def",
        "parts" => [%{"part" => 0, "size" => 10}],
        "shards" => [%{"drive" => 0, "shard_file_size" => 4, "block_hashes" => ["aa"]}]
      }

      test "migrate_v1 wraps v1 meta into maxio/2 versions array, preserving ec/shards" do
        v2 = Sidecar.migrate_v1(@v1, version_id: "null", modtime: 1, content_type: "text/plain")
        assert v2["format"] == "maxio/2"
        assert v2["ec"] == @v1["ec"]
        assert v2["shards"] == @v1["shards"]
        [ver] = v2["versions"]
        assert ver["version_id"] == "null"
        assert ver["type"] == "object"
        assert ver["is_latest"] == true
        assert ver["etag"] == "abc"
        assert ver["content_type"] == "text/plain"
      end

      test "migrate_v1 idempotent on already-v2 meta" do
        v2 = Sidecar.migrate_v1(@v1, version_id: "null", modtime: 1)
        assert Sidecar.migrate_v1(v2, version_id: "null", modtime: 99) == v2
      end

      test "latest picks max-modtime; find_version by id" do
        v2 = Sidecar.migrate_v1(@v1, version_id: "v1", modtime: 5)
        v2 = Sidecar.put_version_entry(v2, %{"version_id" => "v2", "type" => "delete_marker",
                                             "modtime" => 9, "size" => 0, "etag" => ""})
        assert Sidecar.latest(v2)["version_id"] == "v2"
        assert Sidecar.find_version(v2, "v1")["type"] == "object"
      end

      test "signature stable for identical bodies, differs on change" do
        e1 = %{"version_id" => "v", "modtime" => 1, "generation" => 0, "etag" => "a"}
        e2 = %{"version_id" => "v", "modtime" => 1, "generation" => 0, "etag" => "a"}
        e3 = Map.put(e1, "generation", 1)
        assert Sidecar.signature(e1) == Sidecar.signature(e2)
        assert Sidecar.signature(e1) != Sidecar.signature(e3)
      end
    end

执行（确认红）：

    mix test test/maxio/storage/sidecar_test.exs

### 步骤 2（实现绿）：`Maxio.Sidecar`

新建 `lib/maxio/storage/sidecar.ex`：

    defmodule Maxio.Sidecar do
      @moduledoc """
      ROUTE B sidecar v2 形态与编解码（纯函数，不写盘）。在 M6 既有 meta.json（ec/shards/size/etag/
      sha256/parts —— 耐久元数据，绝不被污染）之上加 `format:"maxio/2"` + versions 数组，使 sidecar
      自描述全部 S3 元数据（成为事实来源的前提）。方案 B：每版本独立目录 + 自描述 sidecar，故 versions
      通常单元素；保留数组形态兼容未来单 sidecar 多版本（MinIO xl.meta 式）。

      字段对齐 MinIO xl.meta v2：version_id / type(object|delete_marker) / is_latest（派生自 max modtime，
      存为缓存）/ modtime（int64 纳秒，latest 排序键）/ generation（单调，元数据变更冲突解析）/
      content_type / user_metadata / tags / sse / acl_canned / storage_class / data_dir / inline。

      铁律 3：latest 由 max(modtime) 派生（绝不让两版本都 latest）；signature 是版本体 hash（分歧检测）。
      铁律 5：modtime 纳秒、type、delete_marker 语义对齐 AWS/MinIO。
      """

      @type version_entry :: %{optional(String.t()) => term()}

      @doc "把旧 v1 meta（或已 v2 的 meta）升级为 maxio/2 形态（幂等）。opts 提供版本头字段。"
      @spec migrate_v1(map(), keyword()) :: map()
      def migrate_v1(%{"format" => "maxio/2"} = v2, _opts), do: v2

      def migrate_v1(%{} = v1, opts) do
        entry = %{
          "version_id" => Keyword.get(opts, :version_id, "null"),
          "type" => "object",
          "is_latest" => true,
          "modtime" => Keyword.get(opts, :modtime, now_ns()),
          "generation" => Keyword.get(opts, :generation, 0),
          "data_dir" => Keyword.get(opts, :data_dir),
          "size" => v1["size"],
          "etag" => v1["etag"],
          "sha256" => v1["sha256"],
          "content_type" => Keyword.get(opts, :content_type, "binary/octet-stream"),
          "user_metadata" => Keyword.get(opts, :user_metadata, %{}),
          "tags" => Keyword.get(opts, :tags, %{}),
          "sse" => Keyword.get(opts, :sse),
          "acl_canned" => Keyword.get(opts, :acl_canned, "private"),
          "storage_class" => Keyword.get(opts, :storage_class, "STANDARD"),
          "inline" => Keyword.get(opts, :inline)
        }

        v1
        |> Map.put("format", "maxio/2")
        |> Map.put("versions", [entry])
      end

      @doc "把版本 entry merge 进 versions（同 version_id 覆盖），重算 is_latest（max modtime）。"
      @spec put_version_entry(map(), version_entry()) :: map()
      def put_version_entry(%{} = meta, %{} = entry) do
        vid = entry["version_id"]
        existing = Map.get(meta, "versions", [])
        merged = Enum.reject(existing, fn e -> e["version_id"] == vid end) ++ [entry]
        Map.put(meta, "versions", recompute_latest(merged))
      end

      @doc "当前 latest 版本（max modtime；并列按 generation desc, version_id desc）。空 -> nil。"
      @spec latest(map()) :: version_entry() | nil
      def latest(%{"versions" => versions}) when versions != [] do
        versions |> Enum.sort_by(&sort_key/1, :desc) |> List.first()
      end

      def latest(_), do: nil

      @doc "按 version_id 取版本 entry；无 -> nil。"
      @spec find_version(map(), String.t()) :: version_entry() | nil
      def find_version(%{"versions" => versions}, vid),
        do: Enum.find(versions, fn e -> e["version_id"] == vid end)

      def find_version(_, _), do: nil

      @doc "版本体内容签名（分歧检测；对敏感字段做确定性 hash）。"
      @spec signature(version_entry()) :: binary()
      def signature(%{} = entry) do
        canon =
          ["version_id", "type", "modtime", "generation", "etag", "size", "acl_canned",
           "storage_class", "tags", "user_metadata", "sse"]
          |> Enum.map(fn k -> {k, Map.get(entry, k)} end)

        :crypto.hash(:sha256, :erlang.term_to_binary(canon))
      end

      @doc "把 sidecar 某版本 entry 翻成 Maxio.Objects 索引行 attrs（PG 派生用）。"
      @spec to_object_attrs(String.t(), String.t(), version_entry()) :: map()
      def to_object_attrs(_bucket, _key, %{} = e) do
        %{
          size: e["size"] || 0,
          etag: e["etag"] || "",
          content_type: e["content_type"] || "binary/octet-stream",
          metadata: e["user_metadata"] || %{},
          storage_class: e["storage_class"] || "STANDARD",
          acl_canned: e["acl_canned"] || "private",
          tags: e["tags"] || %{},
          sse_algorithm: get_in(e, ["sse", "algo"]),
          sse_envelope: e["sse"] && e["sse"]["envelope"],
          version_id: e["version_id"],
          is_latest: e["is_latest"] || false,
          is_delete_marker: e["type"] == "delete_marker"
        }
      end

      defp recompute_latest(versions) do
        case Enum.max_by(versions, &sort_key/1, fn -> nil end) do
          nil -> versions
          top -> Enum.map(versions, fn e -> Map.put(e, "is_latest", e == top) end)
        end
      end

      defp sort_key(e), do: {e["modtime"] || 0, e["generation"] || 0, e["version_id"] || ""}
      defp now_ns, do: System.os_time(:nanosecond)
    end

### 步骤 3（脚手架）：reverse-GC 接口占位

新建 `lib/maxio/storage/reverse_gc.ex`（接口 + moduledoc，实现 defer 到 B5-2；铁律 3 诚实标 defer）：

    defmodule Maxio.Storage.ReverseGC do
      @moduledoc """
      反向 GC 脚手架（ROUTE B；实现见 B5-2 scanner）。两类孤儿：
        1. PG 索引有行但 sidecar 缺（PG 滞后/旧备份恢复后的幽灵行）-> 标记/删索引行（绝不删盘上数据）。
        2. sidecar 在但 PG 缺（best-effort 索引写失败）-> upsert 索引行（reconcile）。
      本模块当前仅暴露接口；周期执行经 Maxio.Storage.Scanner（B5-2）。铁律 3：绝不静默删盘上数据。
      """

      @doc "扫描一个桶，返回需 reconcile 的差异（实现 defer 到 B5-2）。"
      @spec scan_divergence(String.t(), keyword()) ::
              {:ok, %{missing_sidecar: list(), missing_index: list()}}
      def scan_divergence(_bucket, _opts), do: {:ok, %{missing_sidecar: [], missing_index: []}}
    end

### 步骤 4（绿 + 提交）

    mix compile --warnings-as-errors
    mix test test/maxio/storage/sidecar_test.exs
    mix test

期望：Sidecar 单测绿；全量绿（纯加模块，无行为变更）。提交。

**验收（B1-4）**：`Maxio.Sidecar` v2 编解码 + `migrate_v1` 幂等 + `latest`/`find_version`/`signature` 测试绿；`ec`/`shards` 耐久元数据在 migrate 中逐字保留；reverse-GC 接口就位标 defer。全量回归绿。

**可回滚性**：纯新增模块，无后端/handler 调用它（B2 才接线）。回退 = 删模块。

---
