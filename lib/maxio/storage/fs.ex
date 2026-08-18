defmodule Maxio.Storage.FS do
  @moduledoc """
  单机文件系统存储后端。ROUTE B B6-1 起对象落 **obj-dir 布局**（与 ErasureCoded/Distributed
  同构，铁律 2 单一布局语义）：

    * null 版本：`<data_dir>/<bucket>/<encoded-key>/{part.0, meta.json}`
    * 版本化：`<data_dir>/.versions/<bucket>/<encoded-key>/<version_id>/{part.0, meta.json}`

  `part.0` 为对象完整字节（FS 单盘无纠删，无填充——文件长度即对象 size）；`meta.json` 为
  maxio/2 sidecar（v1 core `size/etag/sha256` 经 `Maxio.Sidecar.migrate_v1/2` 携 versions 数组，
  富元数据从 `opts[:object_meta]` 取——FS 从此不再忽略 object_meta），与 EC/Distributed 的
  sidecar 同构，使 ObjectMeta/Listing/Scanner 经合成单端点 topology 逐字复用（B6-2）。

  key → 盘段编码经 `Maxio.Cluster.Paths.encode_key/1`（空段/尾斜杠/布局保留名段无碰撞落盘，
  单一事实来源）。put 流式写入并边写边算 MD5/SHA256（绝不全缓冲，铁律 4）；get 支持 Range，
  按区间用 :file.pread 分块发出；防 `..` 路径穿越。

  写路径（put/assemble/put_delete_marker）经 **temp obj-dir + 原子 rename + fsync**
  （`ShardServer.begin_tmp/1` + `ShardServer.commit/3`，B1-2 原语：数据先于元数据 rename，
  crash 在两 rename 之间绝不 meta 指向不存在数据）。rename busy（Windows reader 持文件打开）
  -> 有界重试后 {:error, :rename_busy}（铁律 3）。fsync 开关由 `config :maxio, :durability, fsync:` 控制。

  ## 旧单文件布局读回退（B6-1 兼容；P7 B7-1 backfill 收尾迁移）

  B6-1 之前 FS 对象 = 裸单文件（路径与 obj-dir 同名互斥）。get/stat（含 copy 源读，经同一
  do_get）先探 obj-dir 的 part.0，miss 则回退旧单文件路径——命中**必记**结构化日志
  `action: :legacy_layout_read`（绝不静默）；delete 双布局清理；put/assemble/put_delete_marker
  覆盖旧布局对象时先把旧文件原子移入同卷 `.tmp` backup（`action: :legacy_layout_replace` 日志），
  commit 成功后删除 backup；commit 失败则恢复旧文件（绝不因转换 obj-dir 失败丢 pre-B6-1 字节）。

  每个回调额外接受可选末参 `opts`（`:data_dir` 覆盖根目录，便于测试隔离），
  缺省时从 `config :maxio, :s3, :data_dir` 读取。
  """
  @behaviour Maxio.Storage.Backend

  require Logger

  alias Maxio.Cluster.{Paths, ShardServer}
  alias Maxio.Sidecar

  alias Maxio.Storage.{
    DeleteMarker,
    EpochStore,
    MutationBackup,
    MutationContext,
    NotificationLedger,
    ObjectCommit,
    ObjectEpoch,
    PublishedProof
  }

  alias Maxio.Storage.ObjectCommit.Control

  @chunk_size 1_048_576
  @part_file "part.0"
  @meta_file "meta.json"

  @impl true
  def put(bucket, key, version_id \\ "null", chunks, opts \\ [])

  def put(bucket, key, version_id, chunks, opts),
    do: do_put(bucket, key, version_id, chunks, opts)

  @impl true
  def get(bucket, key, version_id \\ "null", range \\ nil, opts \\ []),
    do: do_get(bucket, key, version_id, range, opts)

  @impl true
  def stat(bucket, key, version_id \\ "null", opts \\ []),
    do: do_stat(bucket, key, version_id, opts)

  @impl true
  def delete(bucket, key, version_id \\ "null", opts \\ []),
    do: do_delete(bucket, key, version_id, opts)

  @impl true
  def put_bucket(bucket, opts \\ []), do: do_put_bucket(bucket, opts)

  @impl true
  def delete_bucket(bucket, opts \\ []), do: do_delete_bucket(bucket, opts)

  # ── 分段上传 parts 回调（M2-4）。part 字节落在
  # <data_dir>/.uploads/<bucket>/<upload_id>/<part_number>.part（平铺布局不变，B6-1 非目标）；
  # assemble 按 part 升序拼到对象 obj-dir；abort 删整个 upload 临时目录。──

  @impl true
  def put_part(bucket, key, upload_id, part_number, chunks, opts \\ []),
    do: do_put_part(bucket, key, upload_id, part_number, chunks, opts)

  @impl true
  def get_part_stream(bucket, key, upload_id, part_number, opts \\ []),
    do: do_get_part_stream(bucket, key, upload_id, part_number, opts)

  @impl true
  def assemble(bucket, key, upload_id, part_numbers, opts \\ []),
    do: do_assemble(bucket, key, upload_id, part_numbers, opts)

  @impl true
  def abort_upload(bucket, key, upload_id, opts \\ []),
    do: do_abort_upload(bucket, key, upload_id, opts)

  # ROUTE B B6-1：delete marker 落盘（替换 B5-0 的 {:error, :not_supported}）。FS 单盘 quorum=1：
  # 唯一副本的 meta_only 原子提交成功即 :ok。与 ErasureCoded/Distributed 同源
  # （Maxio.Storage.DeleteMarker.sidecar/2 单一形态来源 + ShardServer.commit :meta_only）。
  @impl true
  def put_delete_marker(bucket, key, version_id, entry_opts \\ [], opts \\ []),
    do: do_put_delete_marker(bucket, key, version_id, entry_opts, opts)

  # ROUTE B fidelity —— DELETE ?versionId 的权威删除（Backend.delete_version/4 契约）。FS 单副本
  # 本地盘：唯一副本的删除即权威提交（无 quorum 语义）——rm 成功 / 本就不存在 → :ok（幂等）；
  # IO 错误 → {:error, term}（handler 据此绝不回 204，铁律 3 不静默）。
  @impl true
  def delete_version(bucket, key, version_id \\ "null", opts \\ []),
    do: do_delete(bucket, key, version_id, opts)

  @impl true
  def put_notification_ledgers(bucket, key, entries, opts \\ []),
    do: do_put_notification_ledgers(bucket, key, entries, opts)

  @impl true
  def list_notification_ledgers(bucket, key_filter, opts \\ []),
    do: do_list_notification_ledgers(bucket, key_filter, opts)

  @impl true
  def delete_notification_ledgers(bucket, key, ids, opts \\ []),
    do: do_delete_notification_ledgers(bucket, key, ids, opts)

  # ── ObjectMutation epoch CAS 回调（协议 §3.3，Phase 1 B2）：FS 单 drive 薄包装——
  # drive_root 恒为 data_dir(opts) 原值透传（EpochStore 串行路由键按原始字符串 phash2，
  # 绝不自行拼接变体），直调 ShardServer per-endpoint 原语（quorum=1：单盘成功即权威提交）。──

  @impl true
  def claim_epoch(target, token, operation, opts \\ []),
    do: do_claim_epoch(target, token, operation, opts)

  @impl true
  def current_epoch(target, opts \\ []), do: do_current_epoch(target, opts)

  @impl true
  def restore_if_current(ctx, opts \\ []), do: do_restore_if_current(ctx, opts)

  @impl true
  def finalize_if_current(ctx, opts \\ []), do: do_finalize_if_current(ctx, opts)

  @impl true
  def verify_published(ctx, opts \\ []), do: do_verify_published(ctx, opts)

  @doc """
  ROUTE B B6-2 —— FS 的**合成单端点 topology**（单一事实来源；经
  `Maxio.ObjectMeta.effective_topology/1` 注入读/列/scanner 权威路径的 `opts[:topology]`）。

  形状与 `Maxio.Cluster.Topology.t/0` 兼容（`Topology.endpoints_from/2`、
  `Topology.all_set_ids_from/1`、`Router.set_for/3` 直接消费）：单 set、单端点
  `{Node.self(), data_dir}`——B6-1 起 FS 的 obj-dir 布局（part.0 + meta.json sidecar）与
  EC/Distributed 端点盘上同构，故 ObjectMeta/Listing/Scanner 的跨端点机器在「N=1 端点 =
  本机 data_dir」上逐字复用：

    * `node = Node.self()` → `Transport.Erpc` 走本地直调快路径（transport.ex 的
      `node == Node.self()` 分支直接函数调 ShardServer），零网络、零新 transport；
    * `data_shards: 1` → 既有 `opts[:topology].data_shards` 优先逻辑（B4-3）自然给出
      read/write quorum = 1（单盘确认即权威——FS 单副本语义）；
    * `parity_shards: 0`：FS 单盘无纠删。本 map **不经** `Topology.parse_and_validate!/1`
      （那是真集群 config 的校验闸，要求 M>=1），仅作端点/quorum 的事实来源；
    * `block_size`：形状占位（FS 读写不走分片偏移寻址，无消费者）。

  opts[:data_dir] 覆盖根目录（测试隔离），缺省读 `config :maxio, :s3, :data_dir`——
  与 FS 写路径同一来源，端点指向的盘即写路径落的盘。
  """
  # 返回 spec 用 map()：Topology.t() 要求 parity_shards 为 pos_integer()（真集群 M>=1），
  # FS 合成端点 parity=0 是诚实形状（不谎称 Topology.t()），消费者只按键读取。
  @spec local_topology(keyword()) :: map()
  def local_topology(opts \\ []) do
    %{
      data_shards: 1,
      parity_shards: 0,
      block_size: @chunk_size,
      pools: %{0 => %{id: 0, set_ids: [0]}},
      pool_ids: [0],
      sets: %{0 => %{id: 0, pool_id: 0, endpoints: [{Node.self(), data_dir(opts)}]}},
      set_ids: [0]
    }
  end

  # ── PUT：流式写 temp obj-dir（part.0 + meta.json sidecar），原子提交到 final ──

  defp do_put(bucket, key, version_id, chunks, opts) do
    with {:ok, _validated_path} <- object_path(bucket, key, version_id, opts) do
      # B1-2 原子提交：同卷 .tmp temp obj-dir 内流式写 part.0，流尾写 maxio/2 sidecar（meta.json），
      # 数据先于元数据原子 rename 到 final（crash 前 final 保旧值/缺失）。
      {:ok, tmp} = ShardServer.begin_tmp(data_dir(opts))

      try do
        {:ok, fd} = File.open(Path.join(tmp, @part_file), [:write, :binary, :raw])

        {etag, sha256, size} =
          try do
            md5_0 = :crypto.hash_init(:md5)
            sha_0 = :crypto.hash_init(:sha256)

            {md5_ctx, sha_ctx, size} =
              Enum.reduce(chunks, {md5_0, sha_0, 0}, fn chunk, {m, s, acc} ->
                :ok = IO.binwrite(fd, chunk)

                {:crypto.hash_update(m, chunk), :crypto.hash_update(s, chunk),
                 acc + byte_size(chunk)}
              end)

            etag = md5_ctx |> :crypto.hash_final() |> Base.encode16(case: :lower)
            sha256 = sha_ctx |> :crypto.hash_final() |> Base.encode16(case: :lower)
            {etag, sha256, size}
          after
            File.close(fd)
          end

        result = %{size: size, etag: etag, sha256: sha256}
        extra = run_before_object_commit!(opts, result)
        prepared = Map.merge(result, extra)

        ObjectCommit.run(
          opts,
          prepared,
          default_object_commit_opts(version_id, opts, extra),
          fn commit_opts ->
            publish_staged_put(tmp, bucket, key, opts, prepared, commit_opts)
          end,
          fn -> File.rm_rf(tmp) end
        )
      rescue
        err ->
          _ = File.rm_rf(tmp)
          reraise(err, __STACKTRACE__)
      catch
        kind, reason ->
          _ = File.rm_rf(tmp)
          :erlang.raise(kind, reason, __STACKTRACE__)
      end
    end
  end

  defp default_object_commit_opts(version_id, opts, extra) do
    object_meta =
      opts
      |> Keyword.get(:object_meta, %{})
      |> Map.merge(Map.get(extra, :object_meta, %{}))

    [version_id: version_id, object_meta: object_meta]
  end

  defp publish_staged_put(tmp, bucket, key, opts, prepared, commit_opts) do
    version_id = Keyword.fetch!(commit_opts, :version_id)
    object_meta = Keyword.fetch!(commit_opts, :object_meta)
    control = Keyword.fetch!(commit_opts, :object_commit_control)
    identity = Keyword.fetch!(commit_opts, :object_commit_identity)
    publish_opts = Keyword.put(opts, :object_meta, object_meta)

    case object_path(bucket, key, version_id, opts) do
      {:ok, final_dir} ->
        meta =
          version_id
          |> build_meta(
            publish_opts,
            prepared.size,
            prepared.etag,
            prepared.sha256
          )
          |> Map.put("object_commit_identity", identity)

        case ShardServer.put_sidecar(tmp, meta) do
          :ok ->
            committed = Map.put(prepared, :version_id, version_id)

            # 协议化 PutObject（commit_opts[:object_mutation]，B5 orchestrator 注入）走
            # ObjectMutation publish 分支；不传该 opt 的调用者保持现状路径逐字节不变（R6）。
            case Keyword.get(commit_opts, :object_mutation) do
              nil ->
                publish_controlled_obj_dir(
                  tmp,
                  final_dir,
                  bucket,
                  key,
                  version_id,
                  opts,
                  committed,
                  control,
                  identity
                )

              %MutationContext{} = ctx ->
                publish_mutation_obj_dir(tmp, final_dir, opts, committed, control, identity, ctx)

              invalid ->
                _ = File.rm_rf(tmp)
                {:error, {:invalid_object_mutation, invalid}}
            end

          {:error, reason} ->
            _ = File.rm_rf(tmp)
            {:error, reason}
        end

      {:error, reason} ->
        _ = File.rm_rf(tmp)
        {:error, reason}
    end
  end

  defp publish_controlled_obj_dir(
         tmp,
         final_dir,
         bucket,
         key,
         version_id,
         opts,
         result,
         control,
         identity
       ) do
    case plan_put_backup(final_dir, opts) do
      {:ok, plan} ->
        rollback = fn ->
          rollback_put_plan(final_dir, plan, identity, bucket, key, version_id)
        end

        finalize = fn -> discard_put_plan(plan) end

        case Control.register(control, identity, rollback, finalize) do
          :ok ->
            with :ok <- materialize_put_backup(plan),
                 :ok <- log_materialized_legacy_replace(plan, final_dir, bucket, key, version_id),
                 :ok <- ShardServer.commit(tmp, final_dir, commit_opts(opts)) do
              {:ok, result}
            else
              {:error, reason} -> {:error, structured_reason(reason)}
            end

          {:error, reason} ->
            _ = discard_put_plan(plan)
            _ = File.rm_rf(tmp)
            {:error, reason}
        end

      {:error, reason} ->
        _ = File.rm_rf(tmp)
        {:error, structured_reason(reason)}
    end
  end

  # ── ObjectMutation 协议化 publish（协议 §3.2/§3.3/§5，实现计划 B2）──
  # commit_opts[:object_mutation]（%MutationContext{}）存在时的 publish 分支，与
  # publish_controlled_obj_dir 的差异：
  #   * 旧值备份落 <data_dir>/.maxio-object-mutations/<mutation_id>/（durable，recovery 凭
  #     journal + 磁盘即可定位），不再用 .tmp/<uuid>；
  #   * Control.register 之后、备份物化之前写 manifest.json 并 fsync（协议 §5「backend 在
  #     第一次 destructive IO 前同步注册 durable mutation context」的磁盘侧落点）；
  #   * 备份物化之后、destructive rename 之前 epoch CAS {:exact, token, ["claimed"]} →
  #     "published"（携精确 fingerprint）；fenced → 不 rename，{:error, {:epoch_fenced, ...}}
  #     （实现计划决策点 2：publish CAS 固定在 rename 之前，不得调换）；
  #   * rollback/finalize 闭包指向 restore_if_current/finalize_if_current——所有权判定只认
  #     epoch token；sidecar 仍写 object_commit_identity（旧调用者与取证兼容），但协议分支
  #     不再走 identity 比对。
  # 非协议路径 rollback_put_plan 的 `{:error, :enoent} → remove_current_object_files` 分支
  # （把 sidecar 缺失当删除授权）仅存在于旧路径（Phase 2 迁移）；协议路径不触达——epoch
  # absent 时 restore_mutation 返回 {:error, :epoch_missing}，绝不删任何字节（协议 §3.3
  # 「禁止把 nil/:enoent 当成可恢复授权」）。
  # VERIFY-AT-IMPL(Phase 2B)：sidecar entry 的 "generation"（version_opts/DeleteMarker.sidecar）
  # 与 mutation generation 的代际收敛属 Phase 2B；Phase 1 fence 唯一事实来源是 epoch token。
  defp publish_mutation_obj_dir(tmp, final_dir, opts, result, control, identity, ctx) do
    drive_root = data_dir(opts)

    with :ok <- validate_mutation_final_dir(final_dir, drive_root, ctx),
         {:ok, plan} <- plan_mutation_backup(final_dir, drive_root, ctx),
         {:ok, fingerprint} <- staged_fingerprint(tmp, result) do
      # 设计 D2：proof_ctx 必须在 Control.register 之前派生。restore 闭包捕获原始 ctx
      # （回滚与 fingerprint 无关）；finalize 闭包捕获带 published fingerprint 的
      # proof_ctx——proof-aware finalize 需要精确的 expected fingerprint 才能取证。
      proof_ctx = %MutationContext{ctx | published_fingerprint: fingerprint}
      rollback = fn -> mutation_control_result(do_restore_if_current(ctx, opts)) end
      finalize = fn -> mutation_control_result(do_finalize_if_current(proof_ctx, opts)) end

      case Control.register(control, identity, rollback, finalize) do
        :ok ->
          # register 之后的失败不清 tmp/backup：ObjectCommit 的 rollback 路径会经
          # restore_if_current 收敛（durable manifest 在，幂等），discard_fun 清 tmp。
          with :ok <- write_mutation_manifest(plan, ctx, opts),
               :ok <- materialize_put_backup(plan),
               :ok <- publish_mutation_epoch(drive_root, ctx, fingerprint, opts),
               :ok <- ShardServer.commit(tmp, final_dir, commit_opts(opts)) do
            {:ok, Map.put(result, :epoch_fingerprint, fingerprint)}
          else
            {:error, reason} -> {:error, structured_reason(reason)}
          end

        {:error, reason} ->
          _ = File.rm_rf(tmp)
          {:error, reason}
      end
    else
      {:error, reason} ->
        _ = File.rm_rf(tmp)
        {:error, structured_reason(reason)}
    end
  end

  # 防线：ctx.final_rel（restore 的回位落点，journal 派生）必须与本次 publish 的 final_dir
  # 指向同一路径——不一致意味着上下文与请求落点脱节，restore 会把旧字节回错目录。
  defp validate_mutation_final_dir(final_dir, drive_root, %MutationContext{final_rel: final_rel}) do
    if is_binary(final_rel) and Path.join(drive_root, final_rel) == final_dir do
      :ok
    else
      {:error, {:mutation_final_rel_mismatch, final_rel}}
    end
  end

  # 协议化备份计划：backup 落 durable mutation 目录（非 .tmp）。旧单文件布局（pre-B6-1）
  # 与 manifest 契约（entries = final obj-dir 内单层文件名）不可表达——fail-closed 结构化
  # 拒绝，绝不静默转换布局或把旧字节留在 recovery 定位不到的地方（P7 backfill 迁移旧布局
  # 后此分支消亡；非协议路径的 legacy 替换行为不变）。
  defp plan_mutation_backup(final_dir, drive_root, %MutationContext{mutation_id: mutation_id}) do
    backup_dir = Path.join(drive_root, MutationBackup.relative_dir(mutation_id))

    cond do
      File.regular?(final_dir) ->
        {:error, :legacy_layout_conflict}

      File.dir?(final_dir) ->
        names =
          Enum.filter([@part_file, @meta_file], fn name ->
            File.regular?(Path.join(final_dir, name))
          end)

        {:ok,
         %{
           backup_dir: backup_dir,
           names: names,
           entries:
             Enum.map(names, fn name ->
               {Path.join(final_dir, name), Path.join(backup_dir, name)}
             end)
         }}

      true ->
        # fresh put：无旧文件可备份，manifest entries=[]（restore 只翻转 epoch、清 backup）。
        {:ok, %{backup_dir: backup_dir, names: [], entries: []}}
    end
  end

  # manifest 先行（B1 EpochStore 契约：published 的 restore 要求 manifest 必在）：manifest +
  # fsync 落盘于任何 destructive IO 之前，crash 后 recovery 仅凭 mutation_id 即可定位备份名单。
  defp write_mutation_manifest(plan, ctx, opts) do
    entries = Enum.map(plan.names, &%{"name" => &1})

    with {:ok, manifest} <-
           MutationBackup.manifest(ctx.target, ctx.token, previous_epoch_token(ctx), entries),
         {:ok, bytes} <- MutationBackup.encode(manifest),
         :ok <- File.mkdir_p(plan.backup_dir),
         manifest_path = Path.join(plan.backup_dir, MutationBackup.manifest_name()),
         :ok <- File.write(manifest_path, bytes),
         :ok <- maybe_sync_mutation_path(opts, manifest_path) do
      maybe_sync_mutation_dir(opts, plan.backup_dir)
    end
  end

  # fingerprint 的 sidecar_sha256 针对**实际落盘**的 tmp/meta.json 字节（读回而非重编码，
  # 杜绝编码漂移）；publish rename 后 final/meta.json 即这份字节。
  defp staged_fingerprint(tmp, result) do
    case File.read(Path.join(tmp, @meta_file)) do
      {:ok, sidecar_bytes} ->
        {:ok, ObjectEpoch.fingerprint(result.etag, result.size, sidecar_bytes)}

      {:error, reason} ->
        {:error, {:staged_sidecar_unreadable, reason}}
    end
  end

  # destructive rename 之前的 publish 门（FS 单盘 quorum=1）：epoch {:exact, token,
  # ["claimed"]} → "published" + 精确 fingerprint。fenced（successor 已 claim）→ 绝不
  # rename——backup + manifest 保留在 durable 目录，收敛交给 journal/recovery（B5/B6）。
  defp publish_mutation_epoch(drive_root, ctx, fingerprint, opts) do
    with {:ok, published} <-
           ObjectEpoch.new(ctx.target, ctx.token, %{
             operation: ctx.operation,
             phase: "published",
             value_type: "object",
             fingerprint: fingerprint,
             previous_token: previous_epoch_token(ctx),
             updated_at: DateTime.utc_now()
           }),
         {:ok, payload} <- EpochStore.payload(published) do
      case ShardServer.cas_epoch(
             drive_root,
             %{next: payload, expect: {:exact, ctx.token, ["claimed"]}},
             epoch_opts(opts)
           ) do
        {:ok, :applied} -> :ok
        {:error, {:fenced, current}} -> {:error, {:epoch_fenced, current}}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  # Control 闭包契约：:ok | {:error, reason}。restore/finalize 的 :superseded 视为收敛完成
  # （successor 已建立，本次提交对 final 无事可做——绝不触碰 successor）。
  defp mutation_control_result({:ok, _outcome}), do: :ok
  defp mutation_control_result({:error, _reason} = error), do: error

  defp previous_epoch_token(%MutationContext{previous_epoch: %{"token" => token}}), do: token
  defp previous_epoch_token(%MutationContext{}), do: nil

  # ── ObjectMutation epoch 原语（B2）：单 drive 直调 ShardServer 的薄包装。──

  defp do_claim_epoch(target, token, operation, opts) do
    drive_root = data_dir(opts)

    # read → CAS 非单一串行段：previous 仅作 lineage 信息（B5 写入 journal previous_epoch），
    # fence 正确性由 CAS 的「仅接受严格更大 token」独立保证（B5 起 claim 恒在 object lock 内）。
    with {:ok, current} <- do_current_epoch(target, opts),
         previous = epoch_or_nil(current),
         {:ok, claimed} <-
           ObjectEpoch.new(target, token, %{
             operation: operation,
             # B1 收口确认项：EpochStore {:claim, ...} 不约束 next.phase——后端层恒写
             # "claimed"（publish 的 {:exact, token, ["claimed"]} 门依赖该不变量）。
             phase: "claimed",
             value_type: "object",
             previous_token: previous && previous.token,
             updated_at: DateTime.utc_now()
           }),
         {:ok, payload} <- EpochStore.payload(claimed),
         {:ok, :applied} <-
           ShardServer.cas_epoch(
             drive_root,
             %{next: payload, expect: {:claim, token}},
             epoch_opts(opts)
           ) do
      {:ok, %{previous: previous, endpoints_ok: 1}}
    end
  end

  defp do_current_epoch(target, opts) do
    case ShardServer.read_epoch(data_dir(opts), target, epoch_opts(opts)) do
      {:ok, :absent} -> {:ok, :absent}
      {:ok, payload} -> epoch_from_payload(payload)
      {:error, reason} -> {:error, reason}
    end
  end

  defp do_restore_if_current(%MutationContext{} = ctx, opts) do
    ShardServer.restore_mutation(
      data_dir(opts),
      %{
        target: ctx.target,
        token: ctx.token,
        mutation_id: ctx.mutation_id,
        final_rel: ctx.final_rel
      },
      epoch_opts(opts)
    )
  end

  defp do_finalize_if_current(%MutationContext{} = ctx, opts) do
    endpoint =
      ShardServer.finalize_mutation(
        data_dir(opts),
        endpoint_proof_request(ctx),
        epoch_opts(opts)
      )

    PublishedProof.classify_finalize(1, [{"local", endpoint}])
  end

  # FS 是 1/1 endpoint：构造 `layout: %{kind: "fs"}` 的完整 D4 proof request，交本地
  # endpoint primitive 取证，再由 Task 1 公共 classifier 唯一裁决。nil published
  # fingerprint 不做 caller precheck——它是非法 request，由 endpoint 结构化失败关闭。
  defp do_verify_published(%MutationContext{} = ctx, opts) do
    endpoint =
      ShardServer.verify_mutation(data_dir(opts), endpoint_proof_request(ctx), epoch_opts(opts))

    PublishedProof.classify(1, [{"local", endpoint}])
  end

  defp endpoint_proof_request(%MutationContext{} = ctx) do
    %{
      target: ctx.target,
      token: ctx.token,
      mutation_id: ctx.mutation_id,
      final_rel: ctx.final_rel,
      expected_fingerprint: ctx.published_fingerprint,
      layout: %{kind: "fs"}
    }
  end

  defp epoch_or_nil(:absent), do: nil
  defp epoch_or_nil(%ObjectEpoch{} = epoch), do: epoch

  # ShardServer 原语响应是纯数据 payload（erpc 同形）；behaviour 契约返回结构体，
  # 经 decode 全量重验还原（坏 payload 结构化拒绝，绝不静默）。
  defp epoch_from_payload(payload) do
    with {:ok, bytes} <- Jason.encode(payload) do
      ObjectEpoch.decode(bytes)
    end
  end

  defp epoch_opts(opts), do: Keyword.take(opts, [:fsync])

  defp maybe_sync_mutation_path(opts, path) do
    if mutation_fsync?(opts), do: ShardServer.sync_path(path), else: :ok
  end

  defp maybe_sync_mutation_dir(opts, dir) do
    if mutation_fsync?(opts), do: ShardServer.sync_dir(dir), else: :ok
  end

  # opts[:fsync] 显式覆盖；否则读 config :maxio, :durability, fsync:
  # （与 ShardServer/EpochStore 同源开关）。
  defp mutation_fsync?(opts) do
    case Keyword.fetch(opts, :fsync) do
      {:ok, value} -> value
      :error -> Application.get_env(:maxio, :durability, [])[:fsync] || false
    end
  end

  # ── GET / STAT：先 obj-dir（part.0），miss 回退旧单文件布局（命中必记日志，绝不静默）──

  defp do_get(bucket, key, version_id, range, opts) do
    with {:ok, dir} <- object_path(bucket, key, version_id, opts) do
      part = Path.join(dir, @part_file)

      case stat_path(part, opts) do
        {:ok, %File.Stat{size: total}} ->
          {:ok, stream_file(part, range, total)}

        {:error, reason} when reason in [:enoent, :enotdir] ->
          with {:ok, total} <- legacy_stat(dir, bucket, key, version_id, opts) do
            {:ok, stream_file(dir, range, total)}
          end

        {:error, reason} ->
          stat_failed(:get_object, bucket, key, version_id, part, reason)
      end
    end
  end

  defp do_stat(bucket, key, version_id, opts) do
    with {:ok, dir} <- object_path(bucket, key, version_id, opts) do
      part = Path.join(dir, @part_file)

      case stat_path(part, opts) do
        {:ok, %File.Stat{size: size}} ->
          {:ok, %{size: size}}

        {:error, reason} when reason in [:enoent, :enotdir] ->
          with {:ok, size} <- legacy_stat(dir, bucket, key, version_id, opts) do
            {:ok, %{size: size}}
          end

        {:error, reason} ->
          stat_failed(:stat_object, bucket, key, version_id, part, reason)
      end
    end
  end

  # ── DELETE：双布局清理。obj-dir 只摘对象布局文件 part.0/meta.json（绝不 rm_rf 整目录——
  # FS 单树上对象 "a" 的 obj-dir 同时是更深 key "a/b" 的命名空间父目录，rm_rf 会踩踏兄弟对象
  # 字节）；空目录 best-effort rmdir 收尾。旧单文件布局直接 rm。幂等（本就不存在 → :ok）。──

  defp do_delete(bucket, key, version_id, opts) do
    with {:ok, dir} <- object_path(bucket, key, version_id, opts) do
      if File.dir?(dir) do
        delete_obj_dir(dir)
      else
        # 旧单文件布局（或不存在，幂等 :ok）。
        rm_ok(dir)
      end
    end
  end

  defp do_put_notification_ledgers(_bucket, _key, [], _opts), do: :ok

  defp do_put_notification_ledgers(bucket, key, entries, opts) when is_list(entries) do
    Enum.reduce_while(entries, :ok, fn entry, :ok ->
      case put_one_notification_ledger(bucket, key, entry, opts) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp put_one_notification_ledger(bucket, key, entry, opts) do
    with {:ok, id} <- notification_ledger_id(entry),
         final_dir <- notification_ledger_path(bucket, key, id, opts),
         {:ok, tmp} <- ShardServer.begin_tmp(data_dir(opts)),
         :ok <- ShardServer.put_sidecar(tmp, NotificationLedger.sidecar(entry)) do
      case ShardServer.commit(tmp, final_dir, commit_opts(opts) ++ [meta_only: true]) do
        :ok ->
          :ok

        {:error, reason} ->
          _ = File.rm_rf(tmp)
          {:error, structured_reason(reason)}
      end
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp do_list_notification_ledgers(bucket, :all, opts) do
    root = Path.join(data_dir(opts), Paths.notification_ledger_bucket_rel(bucket))
    read_notification_ledgers_under(root, bucket: bucket)
  end

  defp do_list_notification_ledgers(bucket, key, opts) when is_binary(key) do
    root = Path.join(data_dir(opts), Paths.notification_ledger_key_rel(bucket, key))
    read_notification_ledgers_under(root, bucket: bucket, key: key)
  end

  defp do_delete_notification_ledgers(_bucket, _key, [], _opts), do: :ok

  defp do_delete_notification_ledgers(bucket, key, ids, opts) when is_list(ids) do
    with {:ok, ids} <- notification_ledger_ids(ids) do
      Enum.each(ids, fn id ->
        _ = File.rm_rf(notification_ledger_path(bucket, key, id, opts))
      end)

      :ok
    end
  end

  defp delete_obj_dir(dir) do
    with :ok <- rm_ok(Path.join(dir, @part_file)),
         :ok <- rm_ok(Path.join(dir, @meta_file)) do
      # 仅当目录已空（无更深 key 的子目录）才删得掉；非空失败即忽略（目录此后只是命名空间前缀）。
      _ = File.rmdir(dir)
      :ok
    end
  end

  defp rm_ok(path) do
    case File.rm(path) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp do_put_bucket(bucket, opts) do
    File.mkdir_p!(bucket_path(bucket, opts))
    :ok
  end

  defp do_delete_bucket(bucket, opts) do
    case File.rmdir(bucket_path(bucket, opts)) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp do_put_part(bucket, key, upload_id, part_number, chunks, opts) do
    with {:ok, _obj} <- object_path(bucket, key, "null", opts),
         {:ok, tmp_dir} <- ShardServer.begin_tmp(data_dir(opts)) do
      final_path = part_path(bucket, upload_id, part_number, opts)
      tmp_path = Path.join(tmp_dir, @part_file)

      try do
        result = write_part_file!(tmp_path, chunks)
        extra = run_before_part_commit!(opts, result)

        case ShardServer.commit_file(tmp_path, final_path, commit_opts(opts)) do
          :ok -> {:ok, Map.merge(result, extra)}
          {:error, reason} -> {:error, reason}
        end
      after
        _ = File.rm_rf(tmp_dir)
      end
    end
  end

  defp write_part_file!(path, chunks) do
    {:ok, fd} = File.open(path, [:write, :binary, :raw])

    try do
      ctx0 = :crypto.hash_init(:md5)

      {ctx, size} =
        Enum.reduce(chunks, {ctx0, 0}, fn chunk, {ctx, acc} ->
          :ok = IO.binwrite(fd, chunk)
          {:crypto.hash_update(ctx, chunk), acc + byte_size(chunk)}
        end)

      md5_raw = :crypto.hash_final(ctx)

      %{
        size: size,
        etag: Base.encode16(md5_raw, case: :lower),
        md5_raw: md5_raw
      }
    after
      File.close(fd)
    end
  end

  defp run_before_part_commit!(opts, result) do
    case Keyword.get(opts, :before_part_commit) do
      nil -> %{}
      fun when is_function(fun, 1) -> normalize_part_commit_extra(fun.(result))
      fun when is_function(fun, 0) -> normalize_part_commit_extra(fun.())
    end
  end

  defp run_before_object_commit!(opts, result) do
    case Keyword.get(opts, :before_object_commit) do
      nil -> %{}
      fun when is_function(fun, 1) -> normalize_part_commit_extra(fun.(result))
      fun when is_function(fun, 0) -> normalize_part_commit_extra(fun.())
    end
  end

  defp normalize_part_commit_extra(nil), do: %{}
  defp normalize_part_commit_extra(extra) when is_map(extra), do: extra

  defp opts_with_commit_extra(opts, extra) do
    object_meta =
      opts
      |> Keyword.get(:object_meta, %{})
      |> Map.merge(Map.get(extra, :object_meta, %{}) || %{})

    Keyword.put(opts, :object_meta, object_meta)
  end

  defp do_get_part_stream(bucket, key, upload_id, part_number, opts) do
    with {:ok, _obj} <- object_path(bucket, key, "null", opts) do
      path = part_path(bucket, upload_id, part_number, opts)

      case File.stat(path) do
        {:ok, %File.Stat{size: total}} -> {:ok, stream_file(path, nil, total)}
        {:error, :enoent} -> {:error, :enoent}
      end
    end
  end

  # ── ASSEMBLE：逐 part 流式拼进 temp obj-dir 的 part.0（边拷边算 etag/sha256），流尾写
  # maxio/2 sidecar，原子提交到 opts[:version_id] 指定布局 final（缺省 null，与 EC do_assemble
  # 同语义：assemble 透传 opts[:object_meta]，sidecar 自描述真实 content_type/user_metadata，B4-6 D1）。
  #
  # Phase 2A C6：与 do_put 同构改经 ObjectCommit.run 编排——staging = begin_tmp + part 拼接 +
  # run_before_object_commit! + sidecar（object_meta 在此按 opts_with_commit_extra 合并
  # before_object_commit extra 后落盘，around 与 default 两条路径天然同一份 merge），
  # publish = publish_staged_assemble（非协议走 commit_obj_dir；commit_opts[:object_mutation]
  # 存在时复用 publish_mutation_obj_dir 协议分支）。不传协议 opt 的调用者行为逐字节不变。──

  defp do_assemble(bucket, key, upload_id, part_numbers, opts) do
    version_id = Keyword.get(opts, :version_id, "null")

    with {:ok, final_dir} <- object_path(bucket, key, version_id, opts) do
      {:ok, tmp} = ShardServer.begin_tmp(data_dir(opts))

      try do
        {:ok, out} = File.open(Path.join(tmp, @part_file), [:write, :binary, :raw])

        {etag, sha256, size} =
          try do
            acc0 = {:crypto.hash_init(:md5), :crypto.hash_init(:sha256), 0}

            {md5_ctx, sha_ctx, size} =
              Enum.reduce(part_numbers, acc0, fn pn, acc ->
                path = part_path(bucket, upload_id, pn, opts)
                {:ok, in_fd} = :file.open(String.to_charlist(path), [:read, :binary, :raw])

                try do
                  copy_fd(in_fd, out, acc)
                after
                  :file.close(in_fd)
                end
              end)

            {md5_ctx |> :crypto.hash_final() |> Base.encode16(case: :lower),
             sha_ctx |> :crypto.hash_final() |> Base.encode16(case: :lower), size}
          after
            File.close(out)
          end

        result = %{size: size, etag: etag, sha256: sha256}
        extra = run_before_object_commit!(opts, result)
        meta = build_meta(version_id, opts_with_commit_extra(opts, extra), size, etag, sha256)
        prepared = Map.merge(result, extra)

        case ShardServer.put_sidecar(tmp, meta) do
          :ok ->
            # assemble 的 version_id/object_meta 在 staging 期已由 opts 钉定（sidecar 已落盘），
            # default commit_opts 无需承载（publish 只消费 :object_mutation 与 Control 键）。
            ObjectCommit.run(
              opts,
              prepared,
              [],
              fn commit_opts ->
                publish_staged_assemble(
                  tmp,
                  final_dir,
                  bucket,
                  key,
                  version_id,
                  opts,
                  prepared,
                  commit_opts
                )
              end,
              fn -> File.rm_rf(tmp) end
            )

          {:error, reason} ->
            _ = File.rm_rf(tmp)
            {:error, reason}
        end
      rescue
        err ->
          _ = File.rm_rf(tmp)
          reraise(err, __STACKTRACE__)
      catch
        kind, reason ->
          _ = File.rm_rf(tmp)
          :erlang.raise(kind, reason, __STACKTRACE__)
      end
    end
  end

  # assemble 的 publish 阶段（C6）。staging 已把拼接字节 + sidecar 写进 tmp obj-dir，此处只做
  # final 提交编排：
  #   * 非协议（无 :object_mutation）：Control 注册 no-op rollback/finalize 后 commit_obj_dir。
  #     现状 assemble 本就无 identity 比对回滚语义（temp→final 原子 rename 级原子性），注册仅
  #     满足 ObjectCommit 收口契约（finalize 拒绝未注册）——行为逐字节不变；
  #   * 协议（%MutationContext{}）：复用 publish_mutation_obj_dir（与 do_put 协议分支同一结构：
  #     plan backup 旧 final entries → staged fingerprint → Control.register → manifest 写+fsync →
  #     materialize 备份 → epoch CAS claimed→published → ShardServer.commit）。
  # commit_opts[:version_id] 仅作一致性校验：落点已在 staging 按 opts[:version_id] 钉定，
  # 不一致意味着 around 调用者与 staging 脱节（绝不静默改写落点，fail-loud 拒绝）。
  defp publish_staged_assemble(
         tmp,
         final_dir,
         bucket,
         key,
         version_id,
         opts,
         prepared,
         commit_opts
       ) do
    control = Keyword.fetch!(commit_opts, :object_commit_control)
    identity = Keyword.fetch!(commit_opts, :object_commit_identity)

    with :ok <- validate_assemble_version(commit_opts, version_id) do
      case Keyword.get(commit_opts, :object_mutation) do
        nil ->
          case Control.register(control, identity, fn -> :ok end, fn -> :ok end) do
            :ok ->
              commit_obj_dir(tmp, final_dir, bucket, key, version_id, opts, prepared)

            {:error, reason} ->
              _ = File.rm_rf(tmp)
              {:error, reason}
          end

        %MutationContext{} = ctx ->
          committed = Map.put(prepared, :version_id, version_id)
          publish_mutation_obj_dir(tmp, final_dir, opts, committed, control, identity, ctx)

        invalid ->
          _ = File.rm_rf(tmp)
          {:error, {:invalid_object_mutation, invalid}}
      end
    else
      {:error, reason} ->
        _ = File.rm_rf(tmp)
        {:error, reason}
    end
  end

  defp validate_assemble_version(commit_opts, version_id) do
    case Keyword.fetch(commit_opts, :version_id) do
      :error ->
        :ok

      {:ok, ^version_id} ->
        :ok

      {:ok, other} ->
        {:error, {:assemble_version_mismatch, %{staged: version_id, requested: other}}}
    end
  end

  defp do_abort_upload(bucket, _key, upload_id, opts) do
    dir = upload_dir(bucket, upload_id, opts)
    _ = File.rm_rf(dir)
    :ok
  end

  # ── delete marker 落盘（ROUTE B B6-1）：temp obj-dir 只写 marker sidecar（无 part.0，合法），
  # ShardServer.commit :meta_only 原子 rename meta.json 覆盖 final（Suspended 的 null「替换」语义
  # 天然由该 rename 完成，与 Distributed/EC 对齐）。quorum=1：单盘提交成功即 :ok。
  # B5-3 R2 不变式：pre-commit 绝不破坏 final（失败只清 temp）；quorum 成功后 best-effort GC
  # final 里被替换 null 版本的孤儿 part.0（delete marker 无字节，其版本目录里任何 part.0 定义上
  # 都是孤儿）。──

  defp do_put_delete_marker(bucket, key, version_id, entry_opts, opts) do
    with {:ok, final_dir} <- object_path(bucket, key, version_id, opts),
         {:ok, tmp} <- ShardServer.begin_tmp(data_dir(opts)) do
      meta = DeleteMarker.sidecar(version_id, entry_opts)

      case ShardServer.put_sidecar(tmp, meta) do
        :ok -> commit_marker(tmp, final_dir, bucket, key, version_id, opts)
        {:error, reason} -> marker_failed(tmp, bucket, key, reason)
      end
    end
  end

  defp commit_marker(tmp, final_dir, bucket, key, version_id, opts) do
    # 旧单文件布局的 null 对象与 obj-dir 同路径互斥：marker 落点被旧文件占据时先移到同卷
    # backup。commit 成功后丢弃 backup；失败则恢复旧文件（绝不制造裸 404 窗口）。
    case protect_legacy_file(final_dir, bucket, key, version_id, opts) do
      {:ok, legacy} ->
        case ShardServer.commit(tmp, final_dir, commit_opts(opts) ++ [meta_only: true]) do
          :ok ->
            discard_legacy_backup(legacy)
            _ = File.rm(Path.join(final_dir, @part_file))
            :ok

          {:error, reason} ->
            restore_legacy_backup(legacy, final_dir, bucket, key, version_id, reason)
            marker_failed(tmp, bucket, key, reason)
        end

      {:error, reason} ->
        marker_failed(tmp, bucket, key, reason)
    end
  end

  # marker 提交失败：只清 temp，绝不触碰 final（B5-3 R2——替换式提交失败回滚删 final 会摧毁
  # 被替换的旧 null 版本，制造裸 404 窗口）。Logger.error 留痕（铁律 3 不静默）。
  defp marker_failed(tmp, bucket, key, reason) do
    Logger.error("fs put_delete_marker failed",
      action: :put_delete_marker,
      bucket: bucket,
      key: key,
      reason: inspect(reason)
    )

    _ = File.rm_rf(tmp)
    {:error, structured_reason(reason)}
  end

  # ── obj-dir 原子提交（do_put/do_assemble 共用）──

  defp commit_obj_dir(tmp, final_dir, bucket, key, version_id, opts, result) do
    case protect_legacy_file(final_dir, bucket, key, version_id, opts) do
      {:ok, legacy} ->
        case ShardServer.commit(tmp, final_dir, commit_opts(opts)) do
          :ok ->
            discard_legacy_backup(legacy)
            {:ok, result}

          {:error, reason} ->
            restore_legacy_backup(legacy, final_dir, bucket, key, version_id, reason)
            _ = File.rm_rf(tmp)
            {:error, structured_reason(reason)}
        end

      {:error, reason} ->
        _ = File.rm_rf(tmp)
        {:error, structured_reason(reason)}
    end
  end

  # Planning allocates same-volume backup paths and records the old sidecar
  # identity without moving final. The control is registered synchronously
  # before materialize_put_backup/1 performs the first destructive rename.
  defp plan_put_backup(final_dir, opts) do
    cond do
      File.regular?(final_dir) ->
        with {:ok, backup_dir} <- ShardServer.begin_tmp(data_dir(opts)) do
          {:ok,
           %{
             kind: :legacy,
             backup_dir: backup_dir,
             entries: [{final_dir, Path.join(backup_dir, "legacy-file")}],
             old_identity: :legacy
           }}
        end

      File.dir?(final_dir) ->
        plan_object_file_backup(final_dir, opts)

      true ->
        {:ok, %{kind: :none, backup_dir: nil, entries: [], old_identity: {:error, :enoent}}}
    end
  end

  defp plan_object_file_backup(final_dir, opts) do
    entries =
      [@part_file, @meta_file]
      |> Enum.map(fn name -> {Path.join(final_dir, name), name} end)
      |> Enum.filter(fn {source, _name} -> File.regular?(source) end)

    case entries do
      [] ->
        {:ok, %{kind: :none, backup_dir: nil, entries: [], old_identity: {:error, :enoent}}}

      entries ->
        with {:ok, old_identity} <- readable_old_identity(final_dir),
             {:ok, backup_dir} <- ShardServer.begin_tmp(data_dir(opts)) do
          {:ok,
           %{
             kind: :object,
             backup_dir: backup_dir,
             entries:
               Enum.map(entries, fn {source, name} ->
                 {source, Path.join(backup_dir, name)}
               end),
             old_identity: old_identity
           }}
        end
    end
  end

  defp readable_old_identity(final_dir) do
    case final_object_commit_identity(final_dir) do
      {:ok, identity} -> {:ok, {:ok, identity}}
      {:error, :enoent} -> {:ok, {:error, :enoent}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp materialize_put_backup(%{entries: entries}) do
    Enum.reduce_while(entries, :ok, fn {source, backup}, :ok ->
      case File.rename(source, backup) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp log_materialized_legacy_replace(
         %{kind: :legacy},
         final_dir,
         bucket,
         key,
         version_id
       ) do
    log_legacy_replace(final_dir, bucket, key, version_id)
  end

  defp log_materialized_legacy_replace(
         _plan,
         _final_dir,
         _bucket,
         _key,
         _version_id
       ),
       do: :ok

  defp rollback_put_plan(final_dir, %{kind: :none} = plan, identity, bucket, key, version_id) do
    case final_object_commit_identity(final_dir) do
      {:ok, ^identity} -> remove_current_object_files(final_dir)
      {:error, :enoent} -> remove_current_object_files(final_dir)
      {:ok, _successor_identity} -> discard_put_plan(plan)
      {:error, reason} -> rollback_identity_error(reason, identity, bucket, key, version_id)
    end
  end

  defp rollback_put_plan(final_dir, plan, identity, bucket, key, version_id) do
    moved = moved_put_entries(plan)

    if moved == [] do
      discard_put_plan(plan)
    else
      case final_object_commit_identity(final_dir) do
        {:ok, ^identity} ->
          with :ok <- remove_current_object_files(final_dir) do
            restore_put_entries(plan, moved, final_dir, bucket, key, version_id)
          end

        current when current == plan.old_identity ->
          # Publisher died while backing up: old final is still authoritative;
          # restore only files that were already moved.
          restore_put_entries(plan, moved, final_dir, bucket, key, version_id)

        {:error, :enoent} ->
          with :ok <- remove_current_object_files(final_dir) do
            restore_put_entries(plan, moved, final_dir, bucket, key, version_id)
          end

        {:ok, _successor_identity} ->
          # A later writer owns final. This stale rollback may only discard its
          # own backup; it must never remove the successor's part/meta.
          discard_put_plan(plan)

        {:error, reason} ->
          rollback_identity_error(reason, identity, bucket, key, version_id)
      end
    end
  end

  defp moved_put_entries(%{entries: entries}) do
    Enum.filter(entries, fn {_source, backup} -> File.exists?(backup) end)
  end

  defp restore_put_entries(plan, moved, final_dir, bucket, key, version_id) do
    result =
      Enum.reduce_while(moved, :ok, fn {source, backup}, :ok ->
        _ = remove_restore_target(source)
        _ = File.mkdir_p(Path.dirname(source))

        case File.rename(backup, source) do
          :ok -> {:cont, :ok}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)

    case result do
      :ok ->
        with :ok <- log_restored_legacy_plan(plan, final_dir, bucket, key, version_id),
             do: discard_put_plan(plan)

      {:error, _reason} = error ->
        error
    end
  end

  defp log_restored_legacy_plan(%{kind: :legacy}, final_dir, bucket, key, version_id) do
    log_legacy_restore(final_dir, bucket, key, version_id, :object_commit_rollback)
  end

  defp log_restored_legacy_plan(_plan, _final_dir, _bucket, _key, _version_id), do: :ok

  defp remove_restore_target(path) do
    cond do
      File.dir?(path) ->
        File.rmdir(path)

      true ->
        case File.rm(path) do
          :ok -> :ok
          {:error, :enoent} -> :ok
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp final_object_commit_identity(final_dir) do
    case File.read(Path.join(final_dir, @meta_file)) do
      {:ok, bin} ->
        try do
          {:ok, bin |> Sidecar.decode!() |> Map.get("object_commit_identity")}
        rescue
          error -> {:error, {:invalid_sidecar, error}}
        end

      {:error, reason} when reason in [:enoent, :enotdir] ->
        {:error, :enoent}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp remove_current_object_files(final_dir) do
    result =
      Enum.reduce_while([@part_file, @meta_file], :ok, fn name, :ok ->
        case File.rm(Path.join(final_dir, name)) do
          :ok -> {:cont, :ok}
          {:error, :enoent} -> {:cont, :ok}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)

    if result == :ok, do: _ = File.rmdir(final_dir)
    result
  end

  defp rollback_identity_error(reason, identity, bucket, key, version_id) do
    Logger.error("fs object commit identity check failed",
      action: :object_commit_rollback,
      bucket: bucket,
      key: key,
      version_id: version_id,
      commit_identity: identity,
      reason: inspect(reason)
    )

    {:error, reason}
  end

  defp discard_put_plan(%{backup_dir: nil}), do: :ok

  defp discard_put_plan(%{backup_dir: backup_dir}) do
    case File.rm_rf(backup_dir) do
      {:ok, _paths} -> :ok
      {:error, reason, _path} -> {:error, reason}
    end
  end

  defp commit_opts(opts), do: Keyword.take(opts, [:fsync, :rename_fun])

  defp notification_ledger_path(bucket, key, id, opts) do
    Path.join(data_dir(opts), Paths.notification_ledger_entry_rel(bucket, key, id))
  end

  defp notification_ledger_id(entry),
    do: entry |> NotificationLedger.id() |> NotificationLedger.validate_id()

  defp notification_ledger_ids(ids) do
    Enum.reduce_while(ids, {:ok, []}, fn id, {:ok, acc} ->
      case NotificationLedger.validate_id(id) do
        {:ok, id} -> {:cont, {:ok, [id | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, ids} -> {:ok, Enum.reverse(ids)}
      {:error, _reason} = err -> err
    end
  end

  defp read_notification_ledgers_under(root, context) do
    with {:ok, paths} <- notification_ledger_meta_paths(root) do
      Enum.reduce_while(paths, {:ok, []}, fn path, {:ok, acc} ->
        case File.read(path) do
          {:ok, bin} ->
            {:cont, {:ok, decode_notification_ledger(bin, path, context) ++ acc}}

          {:error, reason} ->
            {:halt, {:error, {:notification_ledger_read_failed, path, reason}}}
        end
      end)
      |> case do
        {:ok, entries} -> {:ok, Enum.reverse(entries)}
        {:error, _reason} = err -> err
      end
    end
  end

  defp decode_notification_ledger(bin, path, context) do
    bin
    |> Sidecar.decode!()
    |> NotificationLedger.entry()
    |> case do
      {:ok, entry} -> [entry]
      {:error, _} -> [invalid_notification_ledger(path, "invalid_format", context)]
    end
  rescue
    _ -> [invalid_notification_ledger(path, "invalid_meta", context)]
  end

  defp invalid_notification_ledger(path, reason, context) do
    path
    |> notification_ledger_id_from_meta_path()
    |> NotificationLedger.invalid_entry(reason, context)
  end

  defp notification_ledger_id_from_meta_path(path) do
    path |> Path.dirname() |> Path.basename()
  end

  defp notification_ledger_meta_paths(root) do
    meta_path = Path.join(root, @meta_file)

    case File.stat(meta_path) do
      {:ok, %File.Stat{type: :regular}} ->
        {:ok, [meta_path]}

      {:ok, _stat} ->
        {:error, {:invalid_notification_ledger_meta, meta_path}}

      {:error, reason} when reason in [:enoent, :enotdir] ->
        notification_ledger_child_meta_paths(root)

      {:error, reason} ->
        {:error, {:notification_ledger_stat_failed, meta_path, reason}}
    end
  end

  defp notification_ledger_child_meta_paths(root) do
    case File.stat(root) do
      {:ok, %File.Stat{type: :directory}} ->
        case File.ls(root) do
          {:ok, names} ->
            Enum.reduce_while(names, {:ok, []}, fn name, {:ok, acc} ->
              case notification_ledger_meta_paths(Path.join(root, name)) do
                {:ok, paths} -> {:cont, {:ok, paths ++ acc}}
                {:error, reason} -> {:halt, {:error, reason}}
              end
            end)
            |> case do
              {:ok, paths} -> {:ok, Enum.reverse(paths)}
              {:error, _reason} = err -> err
            end

          {:error, reason} ->
            {:error, {:notification_ledger_list_failed, root, reason}}
        end

      {:ok, _stat} ->
        {:error, {:invalid_notification_ledger_root, root}}

      {:error, :enoent} ->
        {:ok, []}

      {:error, reason} ->
        {:error, {:notification_ledger_stat_failed, root, reason}}
    end
  end

  # OS 报路径段超 NAME_MAX（:enametoolong）→ 结构化 :key_too_long（handler 映射 400
  # KeyTooLongError），对齐 MinIO toObjectErr：errFileNameTooLong → ObjectNameTooLong →
  # ErrKeyTooLongError（cmd/xl-storage.go checkPathLength / cmd/api-errors.go）。
  # Paths.validate_key 的段长闸已在入口先行拦截；此处是后端 backstop（守卫部署前遗留的在途
  # multipart 会话等），绝不让 posix 原因冒成 500 InternalError。
  defp structured_reason(:enametoolong), do: :key_too_long
  defp structured_reason(reason), do: reason

  # 旧单文件布局对象占据 final obj-dir 路径 → 先原子移入同卷 .tmp backup（否则 commit 的
  # mkdir_p 撞文件）。commit 成功后删 backup；失败恢复旧文件，避免转换期间的 runtime 错误吞掉
  # pre-B6-1 字节。命中必记结构化日志（绝不静默），P7 backfill 迁移后此路径消亡。
  defp protect_legacy_file(final_dir, bucket, key, version_id, opts) do
    if File.regular?(final_dir) do
      with {:ok, legacy} <- backup_legacy_file(final_dir, opts),
           :ok <- log_legacy_replace(final_dir, bucket, key, version_id) do
        {:ok, legacy}
      end
    else
      {:ok, :none}
    end
  end

  defp log_legacy_replace(final_dir, bucket, key, version_id) do
    Logger.warning("fs legacy single-file layout object replaced by obj-dir commit",
      action: :legacy_layout_replace,
      bucket: bucket,
      key: key,
      version_id: version_id,
      path: final_dir
    )
  end

  defp backup_legacy_file(final_dir, opts) do
    case ShardServer.begin_tmp(data_dir(opts)) do
      {:ok, backup_dir} ->
        backup_path = Path.join(backup_dir, "legacy-file")

        case File.rename(final_dir, backup_path) do
          :ok ->
            {:ok, {:legacy_backup, backup_dir, backup_path}}

          {:error, reason} ->
            _ = File.rm_rf(backup_dir)
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp discard_legacy_backup(:none), do: :ok

  defp discard_legacy_backup({:legacy_backup, backup_dir, _backup_path}) do
    _ = File.rm_rf(backup_dir)
    :ok
  end

  defp restore_legacy_backup(:none, _final_dir, _bucket, _key, _version_id, _original_reason),
    do: :ok

  defp restore_legacy_backup(
         {:legacy_backup, backup_dir, backup_path},
         final_dir,
         bucket,
         key,
         version_id,
         original_reason
       ) do
    if File.dir?(final_dir), do: delete_obj_dir(final_dir)

    case File.rename(backup_path, final_dir) do
      :ok ->
        _ = File.rm_rf(backup_dir)
        :ok = log_legacy_restore(final_dir, bucket, key, version_id, original_reason)
        :ok

      {:error, reason} ->
        Logger.error("fs legacy single-file layout restore failed",
          action: :legacy_layout_restore_failed,
          bucket: bucket,
          key: key,
          version_id: version_id,
          path: final_dir,
          backup_path: backup_path,
          commit_reason: inspect(original_reason),
          reason: inspect(reason)
        )

        {:error, reason}
    end
  end

  defp log_legacy_restore(final_dir, bucket, key, version_id, reason) do
    Logger.warning("fs legacy single-file layout restored after obj-dir commit failure",
      action: :legacy_layout_restore,
      bucket: bucket,
      key: key,
      version_id: version_id,
      path: final_dir,
      reason: inspect(reason)
    )
  end

  # 旧单文件布局读回退：obj-dir 的 part.0 miss 后，对象路径本身若是常规文件即 B6-1 之前落的
  # 裸单文件对象——命中必记结构化日志 action: :legacy_layout_read（绝不静默）；目录（纯命名空间
  # 前缀 / 无 part.0 的 marker obj-dir）或不存在 → :enoent。
  defp legacy_stat(path, bucket, key, version_id, opts) do
    case stat_path(path, opts) do
      {:ok, %File.Stat{type: :regular, size: size}} ->
        Logger.warning("fs legacy single-file layout read (pre-B6-1 data; P7 backfill migrates)",
          action: :legacy_layout_read,
          bucket: bucket,
          key: key,
          version_id: version_id,
          path: path
        )

        {:ok, size}

      {:ok, _stat} ->
        {:error, :enoent}

      {:error, reason} when reason in [:enoent, :enotdir] ->
        {:error, :enoent}

      {:error, reason} ->
        stat_failed(:legacy_stat_object, bucket, key, version_id, path, reason)
    end
  end

  # Production uses File.stat/1; tests can inject deterministic filesystem faults without relying on
  # platform-specific permissions behavior.
  defp stat_path(path, opts) do
    opts
    |> Keyword.get(:stat_fun, &File.stat/1)
    |> then(& &1.(path))
  end

  defp stat_failed(action, bucket, key, version_id, path, reason) do
    Logger.error("fs object stat failed",
      action: action,
      bucket: bucket,
      key: key,
      version_id: version_id,
      path: path,
      reason: inspect(reason)
    )

    {:error, structured_reason(reason)}
  end

  # ── sidecar 构造（ROUTE B B6-1）：v1 core 仅 size/etag/sha256（FS 单盘无 ec/shards——合法，
  # 读侧 Sidecar.latest/find_version/to_view 只依赖 versions 数组），经 Sidecar.migrate_v1/2
  # 升级为完整 maxio/2（富元数据来自 opts[:object_meta]，FS 从此不再忽略 object_meta）。──

  defp build_meta(version_id, opts, size, etag, sha256) do
    core = %{"size" => size, "etag" => etag, "sha256" => sha256}
    Sidecar.migrate_v1(core, version_opts(version_id, opts))
  end

  # 从 opts[:object_meta] 取 maxio/2 版本头字段，产出 Sidecar.migrate_v1/2 的 keyword。
  # 与 ErasureCoded/Distributed 的同名私有函数逐字一致（铁律 2 单一语义）；modtime 一次计算；
  # data_dir = version_id（方案 B 每版本独立目录）。缺字段由 migrate_v1 兜底默认。
  # :etag（B6-2a）：多段完成对象的 S3 多段 ETag（"...-N"，Multipart.complete 透传）覆盖 versions
  # entry 的 S3 可见 etag；单次 PUT 无此键（nil）→ migrate_v1 沿用 core etag。
  defp version_opts(version_id, opts) do
    om = Keyword.get(opts, :object_meta, %{})
    modtime = Map.get(om, :modtime, System.os_time(:nanosecond))

    [
      version_id: version_id,
      data_dir: version_id,
      modtime: modtime,
      generation: Map.get(om, :generation, 0),
      size: object_meta_value(om, :size),
      etag: Map.get(om, :etag),
      content_type: Map.get(om, :content_type, "binary/octet-stream"),
      content_encoding: Map.get(om, :content_encoding),
      content_disposition: Map.get(om, :content_disposition),
      cache_control: Map.get(om, :cache_control),
      expires: Map.get(om, :expires),
      website_redirect_location: Map.get(om, :website_redirect_location),
      tags: Map.get(om, :tags, %{}),
      checksum: object_meta_value(om, :checksum) || %{},
      object_parts: object_meta_value(om, :object_parts) || %{},
      sse: Map.get(om, :sse),
      acl_canned: Map.get(om, :acl_canned, "private"),
      acl_grants: Map.get(om, :acl_grants, %{"grants" => []}),
      storage_class: Map.get(om, :storage_class, "STANDARD"),
      user_metadata: Map.get(om, :user_metadata, %{}),
      object_lock_mode: Map.get(om, :object_lock_mode),
      object_lock_retain_until: Map.get(om, :object_lock_retain_until),
      object_lock_legal_hold: Map.get(om, :object_lock_legal_hold),
      restore_status: Map.get(om, :restore_status),
      restore_expiry: Map.get(om, :restore_expiry),
      replication_status: Map.get(om, :replication_status),
      notification_outbox: object_meta_value(om, :notification_outbox) || []
    ]
  end

  defp object_meta_value(om, key) do
    case Map.get(om, key) do
      fun when is_function(fun, 0) -> fun.()
      value -> value
    end
  end

  # 1MB 分块把 in_fd 全量拷到 out，边拷边算 MD5/SHA256（assemble 的 sidecar 需 etag/sha256，
  # 与 EC do_assemble 同语义；铁律 4 绝不全缓冲）。acc = {md5_ctx, sha_ctx, size}。
  defp copy_fd(in_fd, out, {md5, sha, size} = acc) do
    case :file.read(in_fd, @chunk_size) do
      {:ok, data} ->
        :ok = IO.binwrite(out, data)

        copy_fd(
          in_fd,
          out,
          {:crypto.hash_update(md5, data), :crypto.hash_update(sha, data), size + byte_size(data)}
        )

      :eof ->
        acc

      {:error, _} ->
        acc
    end
  end

  defp upload_dir(bucket, upload_id, opts) do
    Path.join([data_dir(opts), ".uploads", bucket, upload_id])
  end

  defp part_path(bucket, upload_id, part_number, opts) do
    Path.join(upload_dir(bucket, upload_id, opts), "#{part_number}.part")
  end

  defp stream_file(path, nil, total), do: stream_file(path, {0, max(total - 1, 0)}, total)
  defp stream_file(_path, {_first, _last}, 0), do: []

  defp stream_file(path, {first, last}, _total) do
    length = last - first + 1

    Stream.resource(
      fn ->
        {:ok, fd} = :file.open(String.to_charlist(path), [:read, :binary, :raw])
        {fd, first, length}
      end,
      fn
        {fd, _off, remaining} when remaining <= 0 ->
          {:halt, fd}

        {fd, off, remaining} ->
          to_read = min(@chunk_size, remaining)

          case :file.pread(fd, off, to_read) do
            {:ok, data} -> {[data], {fd, off + byte_size(data), remaining - byte_size(data)}}
            :eof -> {:halt, fd}
            {:error, _} -> {:halt, fd}
          end
      end,
      fn fd -> :file.close(fd) end
    )
  end

  defp data_dir(opts) do
    Keyword.get(opts, :data_dir) ||
      Application.fetch_env!(:maxio, :s3) |> Keyword.fetch!(:data_dir)
  end

  defp bucket_path(bucket, opts), do: Path.join(data_dir(opts), bucket)

  # version_id == "null"（无版本）→ obj-dir 落 <data_dir>/<bucket>/<encoded-key>/。
  # 否则落版本化 obj-dir <data_dir>/.versions/<bucket>/<encoded-key>/<version_id>/（物理隔离）。
  #
  # key → 盘段编码经 Maxio.Cluster.Paths.encode_key（单一事实来源，铁律 2）：空段（"a//b"）、
  # 尾斜杠 folder marker（"dir/"）、布局保留名段（meta.json 等）全部无碰撞落盘——绝不再
  # trim 折叠空段（"a//b" 与 "a/b"、"dir/" 与 "dir" 曾静默同路径 = 跨 key 字节覆写）。
  defp object_path(bucket, key, "null", opts) do
    case Paths.encode_key(key) do
      {:ok, rel} -> {:ok, Path.join([data_dir(opts), bucket, rel])}
      {:error, :invalid_key} -> {:error, :invalid_key}
    end
  end

  defp object_path(bucket, key, version_id, opts) do
    case Paths.encode_key(key) do
      {:ok, rel} ->
        {:ok, Path.join([data_dir(opts), ".versions", bucket, rel, version_id])}

      {:error, :invalid_key} ->
        {:error, :invalid_key}
    end
  end
end
