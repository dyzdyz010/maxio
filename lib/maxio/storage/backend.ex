defmodule Maxio.Storage.Backend do
  @moduledoc """
  对象字节存储后端契约（behaviour）。上层 handler 只认本契约，对实现无感
  （AGENTS.md 铁律 1/2：后端即插件，换 FS→纠删码→分布式 核心管线一行不改）。

  约定：
    * put/4 的 `chunks` 是一个产出二进制块的 Enumerable（来自 read_body 流式拉取），
      实现必须**边消费边落盘 / 边算哈希，绝不把整对象读进内存**（铁律 4）。
    * get/3 的 range 为 nil（全量）或 {first_byte, last_byte}（含端点，0-based），
      返回产出二进制块的 Enumerable（供 send_chunked 流式发出）。
    * ETag 形态：单次 PUT 对象 = MD5(对象内容) 的小写 hex（**不含引号**，引号由 XML/HTTP 层加）。

  ## put/5 的 `:object_meta`（ROUTE B B4-5）

  `opts[:object_meta]`（可选 map）携带 GET/HEAD/LIST 所需的全部 S3 富元数据，使纠删/分布式后端
  写出**完整 maxio/2 sidecar**（携带 `format:"maxio/2"` + 单元素 `versions` 数组）——盘上 sidecar
  即事实来源（Route B），故写路径**必须**自描述这些字段，否则 `authoritative_source(:read|:list)=:sidecar`
  下对真实对象 reconcile 取不到 versioned entry（v1 扁平 meta → `Sidecar.latest/find_version` 返回 nil）
  → GET 503 / LIST 丢对象。形状（缺省 `%{}`，缺省字段由 `Maxio.Sidecar.migrate_v1/2` 兜底）：

      %{
        content_type: String.t(),
        content_encoding: String.t() | nil,
        content_disposition: String.t() | nil,
        cache_control: String.t() | nil,
        expires: String.t() | nil,
        tags: %{String.t() => String.t()},
        sse: nil | %{"algo" => "AES256", "envelope" => map()},
        acl_canned: String.t(),
        acl_grants: %{String.t() => term()},
        storage_class: String.t(),
        user_metadata: %{String.t() => String.t()},
        # B6-2a（仅 assemble 路径，可选）：S3 可见 ETag 覆盖——多段完成对象的 sidecar versions
        # entry etag 必须是多段形态 hex(MD5(concat part MD5s))-N（Multipart.complete 透传）；
        # 耐久 core 顶层 etag 仍为整体字节 MD5（完整性校验语义）。缺省/nil → entry 沿用 core etag。
        etag: String.t() | nil
      }

  `sse` 形状必须匹配 `Sidecar.to_view/3` 读 `e["sse"]["algo"]` / `e["sse"]["envelope"]`（信封随读视图携带，
  否则 SSE 对象 GET 解密 `unwrap_dek(nil)` 炸 500）。FS 后端无多端点拓扑（读权威永不命中 FS），可忽略
  本 opt——耐久核心字节不变（铁律 5：默认 :pg 路径字节级可回滚）。
  """

  @type bucket :: String.t()
  @type key :: String.t()
  @type range :: nil | {non_neg_integer(), non_neg_integer()}
  @type put_result :: %{size: non_neg_integer(), etag: String.t(), sha256: String.t()}
  @type object_meta :: %{optional(atom()) => term()}

  @doc """
  Streams one object into a staged location and commits it atomically.

  Backends may receive `opts[:before_object_commit]` as a precommit hook. When
  present, the backend must write object bytes into a temp/staged location,
  compute `%{size, etag, sha256}`, call the hook with that result, then commit
  the final object only if the hook succeeds. A hook may return a map, which is
  merged into the successful result.

  If the hook raises, backends must clean staged bytes and must not replace an
  existing final object. This keeps checksum and decoded-length failures
  fail-closed before object visibility.

  Backends may also receive `opts[:around_object_commit]` for PutObject staging.
  After the body has been fully consumed in the caller process and
  `before_object_commit` has succeeded, the backend calls
  `around_object_commit.(prepared, publish_fun)`. `prepared` contains the
  computed write result plus precommit additions. The callback may acquire an
  object lock, revalidate mutable state, and then call
  `publish_fun.(commit_opts)` with the final `:version_id` and `:object_meta`.

  A successful callback must publish exactly once. Returning `{:error, reason}`
  without publishing aborts the staged write. Missing publication, callback
  exceptions, and duplicate publication must discard only this invocation's
  temp data and must never delete or replace an existing final object. This
  option applies only to `put/5`; multipart part and assemble contracts are
  unchanged.

  ## `opts[:object_mutation]`（ObjectMutation 协议 Phase 1，B1 契约 / B2–B4 落地）

  协议化 PutObject 提交可携带 `opts[:object_mutation]`（`%Maxio.Storage.MutationContext{}`，
  含 mutation_id/token/target/final_rel）。存在时 publish 步骤必须：

    * 在第一次 destructive IO 之前把旧值备份写入
      `<drive>/.maxio-object-mutations/<mutation_id>/` 并落 durable manifest
      （`Maxio.Storage.MutationBackup`，协议 §3.2——绝不再用 `.tmp/<uuid>` 备份）；
    * 在 destructive rename **之前**对 target epoch 执行
      `{:exact, token, ["claimed"]}` → `"published"`（携带精确 fingerprint）的 CAS；
      CAS 失败（fenced）→ 不 rename，结构化返回；
    * 注册进 Control 的 rollback/finalize 闭包改指向 `restore_if_current/2` /
      `finalize_if_current/2`（所有权判定只认 epoch token，不再走 identity 比对）。

  不传该 opt 的调用者保持现状路径逐字节不变（Copy/Multipart 等 Phase 2 迁移）。
  """
  @callback put(
              bucket(),
              key(),
              version_id :: String.t(),
              chunks :: Enumerable.t(),
              opts :: [{:object_meta, object_meta()} | {atom(), term()}]
            ) ::
              {:ok, put_result()} | {:error, term()}
  @callback get(bucket(), key(), version_id :: String.t(), range(), opts :: keyword()) ::
              {:ok, Enumerable.t()} | {:error, :enoent | term()}
  @callback stat(bucket(), key(), version_id :: String.t(), opts :: keyword()) ::
              {:ok, %{size: non_neg_integer()}} | {:error, :enoent}
  @callback delete(bucket(), key(), version_id :: String.t(), opts :: keyword()) ::
              :ok | {:error, term()}
  @callback put_bucket(bucket()) :: :ok | {:error, term()}
  @callback delete_bucket(bucket()) :: :ok | {:error, term()}

  # ── 分段上传 parts 回调（M2-4，追加在既有回调之后；铁律 1/2：part 字节也只走本契约）──

  @type upload_id :: String.t()
  @type part_number :: pos_integer()
  @type part_put_result :: %{size: non_neg_integer(), etag: String.t(), md5_raw: binary()}

  @doc """
  Streams one multipart-upload part and returns size, unquoted MD5 hex ETag,
  and the raw 16-byte MD5.

  Backends may receive `opts[:before_part_commit]` as a precommit hook. When
  present, the backend must write the new part into a temp/staged location,
  compute `%{size, etag, md5_raw}`, call the hook with that result, then commit
  the final part only if the hook succeeds. A hook may return a map, which is
  merged into the successful result.

  If the hook raises, backends must clean the staged bytes and must not replace
  an existing final part. This keeps checksum failures and other precommit
  validation failures fail-closed. Final commit failures keep each backend's
  normal write-quorum error semantics.
  """
  @callback put_part(
              bucket(),
              key(),
              upload_id(),
              part_number(),
              chunks :: Enumerable.t(),
              opts :: keyword()
            ) ::
              {:ok, part_put_result()} | {:error, term()}

  @doc "流式读取一个 part 的字节（组装时按 part number 升序拼接用）。"
  @callback get_part_stream(bucket(), key(), upload_id(), part_number(), opts :: keyword()) ::
              {:ok, Enumerable.t()} | {:error, :enoent | term()}

  @doc """
  按给定 part number 升序把各 part 字节拼成最终对象（落到对象路径），返回总大小。

  `opts[:version_id]` 指定最终对象版本路径；缺省为 `"null"` 以保持既有未版本化调用语义。
  """
  @callback assemble(
              bucket(),
              key(),
              upload_id(),
              part_numbers :: [part_number()],
              opts :: keyword()
            ) ::
              {:ok, %{size: non_neg_integer()}} | {:error, term()}

  @doc "删除该 upload 的所有 part 字节与临时目录（Abort / Complete 后清理）。幂等。"
  @callback abort_upload(bucket(), key(), upload_id(), opts :: keyword()) ::
              :ok | {:error, term()}

  # ── delete marker 落盘回调（ROUTE B B5-0；铁律 1：删除是写操作，sidecar 权威则删除必须被盘上权威记录）──

  @doc """
  在 `version_id` 对应盘上路径写一个**纯 delete-marker maxio/2 sidecar**，达 write_quorum 才 `:ok`，
  否则 `{:error, :write_quorum}`（handler 据此回 503 SlowDownWrite，绝不静默）。

  根因（B5-0）：`Objects.insert_delete_marker/3` 纯 PG，盘上从不落 delete-marker sidecar →
  `authoritative_source(:read|:list)=:sidecar` 下 DeleteObject 后盘上旧对象 sidecar 仍在
  → GET 仍 200、LIST 仍列出 = **已删对象复活**。本回调让删除被盘上权威记录，与 PUT 同级耐久。

  写出的 sidecar 形态 = `%{"format"=>"maxio/2","versions"=>[entry]}`，entry：
    * `type="delete_marker"` / 给定 `version_id` / `modtime`（单次纳秒，所有端点同值 → signature 一致）
    * `generation:0` / `is_latest:true`
    * **无 part.0 字节、无 ec/shards 耐久 core**——delete marker 无字节，合法（对齐 MinIO xl.meta delete-marker version）。

  `entry_opts`（keyword，可选）：`:modtime`（覆盖单次纳秒，默认实现自算）等版本头覆盖；缺省全默认。
  写到 write_quorum 个端点（temp→rename 原子，复用 PUT 同级原语）。

  **FS 后端**（ROUTE B B6-1 接线）：单盘 quorum=1——唯一副本的 meta_only 原子提交成功即 `:ok`，
  失败 `{:error, term}`（绝不静默 no-op，铁律 3）。
  """
  @callback put_delete_marker(
              bucket(),
              key(),
              version_id :: String.t(),
              entry_opts :: keyword(),
              opts :: keyword()
            ) :: :ok | {:error, term()}

  # ── 版本永久删除回调（ROUTE B fidelity：DELETE ?versionId 在 sidecar 写权威下的权威提交）──

  @doc """
  永久删除 `version_id` 的盘上版本记录（版本 obj-dir：meta.json + 字节分片），**quorum 确认**才 `:ok`。

  根因：DELETE ?versionId 从前 PG-first、盘上删除结果被静默丢弃（PG 行缺失时甚至完全不触盘）——
  `authoritative_source(:write)=:sidecar` 下盘上才是权威介质，「客户端拿到 204 但权威盘上版本仍在」
  会被 B5-2 scanner forward 从幸存 sidecar 忠实 re-upsert 回派生索引（**已永久删除的版本复活**），
  且 reverse-GC 的「盘上确有 → 绝不删」守恒保证该行永不消失。删除是写操作，必须在权威介质上
  quorum 提交（与 `put_delete_marker/5` 的 B5-0 既定原则同源）。

  确认语义（必须结构性区分「已删除」与「端点不可达」——transport 的 `delete_shard` 把宕机塌缩成
  `:ok`，绝不可直接计数）：每端点先删版本 obj-dir，再经 `list_dir` 探针确认「端点可达且版本目录
  显式 missing（无 meta.json——meta.json 即版本记录本体）」；确认端点数 ≥ write_quorum → `:ok`，
  否则 `{:error, :write_quorum}`（handler 回 503 SlowDownWrite，绝不在权威介质仍持有该版本时宣告
  删除成功）。幂等：版本本就不存在的端点同样计入确认（对齐 AWS 删除不存在版本回 204）。

  对齐 MinIO DeleteObject/DeleteVersion 的 write-quorum 语义（cmd/erasure-object.go；quorum 不足 →
  errErasureWriteQuorum → ErrSlowDownWrite，cmd/api-errors.go——绝不返回成功后又被 scanner/healer 复活）。

  **FS 后端**（单副本本地盘）：唯一副本的删除即权威提交（rm 成功 / 本就不存在 → `:ok`；IO 错误 →
  `{:error, term}`）。
  """
  @callback delete_version(bucket(), key(), version_id :: String.t(), opts :: keyword()) ::
              :ok | {:error, :write_quorum | term()}

  # ── bucket/key retained notification ledger（sidecar write authority recovery carrier）──

  @type notification_ledger_entry :: %{optional(String.t()) => term()}

  @doc """
  Persist retained notification ledger entries outside the object/version carrier.

  These entries are small JSON-safe maps; they never contain object body bytes.
  A sidecar-authoritative handler must call this before acknowledging a
  destructive/overwriting object mutation that may otherwise erase the
  per-version `notification_outbox` carrier. Backends must return `:ok` only
  after the ledger entry is durably present at write quorum; otherwise the
  object mutation must not proceed.
  """
  @callback put_notification_ledgers(
              bucket(),
              key(),
              [notification_ledger_entry()],
              opts :: keyword()
            ) :: :ok | {:error, term()}

  @doc """
  List retained notification ledger entries for a key or a whole bucket.

  Passing `:all` as the key filter returns every retained entry under that
  bucket. Backends should only return entries with a read-quorum canonical
  replica; divergent/corrupt evidence may be logged and left in place for
  operator repair.
  """
  @callback list_notification_ledgers(bucket(), key() | :all, opts :: keyword()) ::
              {:ok, [notification_ledger_entry()]} | {:error, term()}

  @doc """
  Delete retained notification ledger entries after successful idempotent replay
  or after a predicate proves the prepared mutation never committed.

  Deletion is best-effort but must not raise; callers rely on stable outbox ids
  for idempotency if a partial prune leaves evidence behind.
  """
  @callback delete_notification_ledgers(bucket(), key(), [String.t()], opts :: keyword()) ::
              :ok | {:error, term()}

  # ── ObjectMutation epoch CAS 回调（协议 §3.3，Phase 1 B1 契约 / B2–B4 落地，B4 起强制）──

  @doc """
  以 quorum 语义 claim target 的 fencing epoch（per-endpoint CAS 仅接受严格更大 token；
  EC/Distributed 的破坏性 quorum = `max(write_quorum, ⌊n/2⌋+1)`，保证两个 write quorum
  必有交集）。返回 claim 前的 previous epoch（quorum 读中最大 token；legacy 无 epoch →
  nil——但 nil 绝不构成后续 destructive 授权）与成功端点数。

  Distributed 后端额外返回 `:placement_snapshot`（`Placement.resolve_write/3` 快照的
  durable 形状 `%{"set_id" | "pool_id" | "topology_hash"}`，B5 写入 journal
  `placement_snapshot`）——`restore_if_current/2`、`finalize_if_current/2` 的恢复端点解析
  **只认该快照**（核对 topology_hash，漂移 → `{:error, {:placement_drift, evidence}}`），
  绝不按当前 router 猜测。
  """
  @callback claim_epoch(
              Maxio.Storage.ObjectEpoch.target(),
              Maxio.Storage.ObjectEpoch.token(),
              operation :: String.t(),
              opts :: keyword()
            ) ::
              {:ok,
               %{
                 :previous => Maxio.Storage.ObjectEpoch.t() | nil,
                 :endpoints_ok => non_neg_integer(),
                 optional(:placement_snapshot) => map()
               }}
              | {:error, term()}

  @doc "quorum 读 target 当前 epoch；`:absent` 显式区分（nil/:enoent 绝不当授权）。"
  @callback current_epoch(Maxio.Storage.ObjectEpoch.target(), opts :: keyword()) ::
              {:ok, Maxio.Storage.ObjectEpoch.t() | :absent} | {:error, term()}

  @doc """
  仅当 ctx.token 仍为当前 epoch 时恢复旧值（epoch → rolled_back + backup rename 回 final +
  清 backup）。遇 successor 只返回 `{:ok, :superseded}`，绝不触碰 successor；`committed`
  epoch 拒绝（metadata_committed 禁回滚的端点级防线）；epoch absent/损坏/quorum 不足 →
  结构化错误并保留 backup（不猜测、不破坏）。
  """
  @callback restore_if_current(Maxio.Storage.MutationContext.t(), opts :: keyword()) ::
              {:ok, :restored | :superseded} | {:error, term()}

  @doc "仅当 ctx.token 仍为当前 epoch 时终结（epoch → committed + 丢弃 backup）；幂等。"
  @callback finalize_if_current(Maxio.Storage.MutationContext.t(), opts :: keyword()) ::
              {:ok, :finalized | :superseded} | {:error, term()}
end
