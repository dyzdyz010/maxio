defmodule Maxio.Storage.Distributed do
  @moduledoc """
  多节点分布式 Reed-Solomon 纠删码存储后端（M7），实现 Maxio.Storage.Backend 契约，与 FS/ErasureCoded
  返回形态逐字节一致（铁律 2：后端即插件，核心管线一行不改）。

  在 M6 单机纠删码核心（Maxio.Storage.Erasure.{Codec,Config,Meta} + NIF）之外加：
    * Router.set_for(bucket,key) -> set_id（对象名哈希取模，铁律 5 对齐 MinIO；版本不入哈希）
    * Topology.endpoints(set_id) -> 有序 N 个 {node, drive} 端点（索引 i = 分片 i）
    * Transport（:erpc / InProcess）把分片 i 寻址到端点 i 的节点 + drive（铁律 4 逐 block-shard）
  RS 数学/流式/quorum/校验 全部复用 M6，一行不重写——只把「分片 i 写本地盘 i」换成
  「分片 i 经 Transport 写端点 i」。

  put：逐块流式编码（Codec.split_block），分片 i 写端点 i 的 temp obj-dir，流尾 sidecar 写 temp，
       最后各端点 commit_object（数据先于元数据原子 rename 到 final，B1-2），成功端点数 >= write_quorum
       才 {:ok}；否则清理全部 temp + {:error,:write_quorum}（铁律 3）。
  原子提交（B1-2）：写路径绝不就地覆盖 final 的 part.0/meta.json——每端点先 begin_tmp 得同卷
       `<drive>/.tmp/<uuid>` temp obj-dir，逐块 put_shard 进 temp，commit_object fsync + temp->final
       原子 rename（crash 任意点要么旧要么新，绝不撕裂）。fsync-before-quorum 让 write_quorum 在掉电下
       不再是耐久谎言。
  对象锁（B1-1）由 handler 层 `Maxio.Lock` 横跨「字节 + 元数据」提交 seam 单点持有；本后端不自持
  对象锁——否则 handler 已持同名 {bucket,key} 锁、后端再 `:global.trans` 同资源会死等自己
  （`:global.trans` 非重入）。锁是请求编排关注点，不是字节后端关注点（铁律 2）。非 handler 的直接
  调用方（backfill/scanner/conformance）若需并发安全须自行 `Maxio.Lock.with_object_lock`。
  get：逐块跨节点并行读 K-of-N 分片（宕机/超时端点 -> nil），按 sidecar BLAKE3 校验 + Codec.restore_block
       重建（存活 < K -> raise InsufficientShardsError，绝不静默返回错数据，铁律 3）+ 截断 + Range 裁剪，流式发出。

  每 callback 末参 opts：opts[:topology]（parsed struct）覆盖 :persistent_term；
  opts[:transport] 覆盖 config :maxio, :shard_transport。便于 ExUnit 注入进程内多节点 transport。
  """
  @behaviour Maxio.Storage.Backend

  require Logger

  alias Maxio.Storage.Erasure.{Codec, Config, Meta}
  alias Maxio.Cluster.{Paths, Placement, Topology, Transport}
  alias Maxio.Sidecar

  alias Maxio.Storage.{
    EpochStore,
    MutationBackup,
    MutationContext,
    NotificationLedger,
    ObjectCommit,
    ObjectEpoch
  }

  alias Maxio.Storage.ObjectCommit.Control

  @part_file "part.0"
  @meta_file "meta.json"

  # ── Backend callbacks（签名与 FS/ErasureCoded 一致）──

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

  # B5-3 R6：version_id 无默认参（ErasureCoded/Storage 门面/behaviour 均无）——"null" 默认值会诱发
  # 调用方静默误写 null marker（替换 Suspended null 版本），删除这类语义性 version_id 必须显式传。
  @impl true
  def put_delete_marker(bucket, key, version_id, entry_opts \\ [], opts \\ []),
    do: do_put_delete_marker(bucket, key, version_id, entry_opts, opts)

  @impl true
  def delete_version(bucket, key, version_id \\ "null", opts \\ []),
    do: do_delete_version(bucket, key, version_id, opts)

  @impl true
  def put_notification_ledgers(bucket, key, entries, opts \\ []),
    do: do_put_notification_ledgers(bucket, key, entries, opts)

  @impl true
  def list_notification_ledgers(bucket, key_filter, opts \\ []),
    do: do_list_notification_ledgers(bucket, key_filter, opts)

  @impl true
  def delete_notification_ledgers(bucket, key, ids, opts \\ []),
    do: do_delete_notification_ledgers(bucket, key, ids, opts)

  # ── ObjectMutation epoch 原语（协议 §3.3，实现计划 B4）：B1 落在 ShardServer 的
  # per-endpoint 原语经 Transport 寻址到端点 {node, drive}，后端只做 quorum 编排（与 EC
  # B3 同形，endpoint 换 {node, drive}）；epoch 破坏性 quorum = cfg.epoch_quorum（D4
  # 多数派钳制——Distributed 与 EC 同经 Config.load! 计算，公式同源）。──

  @impl true
  def claim_epoch(target, token, operation, opts \\ []),
    do: do_claim_epoch(target, token, operation, opts)

  @impl true
  def current_epoch(target, opts \\ []), do: do_current_epoch(target, opts)

  @impl true
  def restore_if_current(ctx, opts \\ []), do: do_restore_if_current(ctx, opts)

  @impl true
  def finalize_if_current(ctx, opts \\ []), do: do_finalize_if_current(ctx, opts)

  # ── 端点解析（对象 -> set -> [{node, drive}]）──

  defp topology(opts), do: Keyword.get(opts, :topology)

  defp cfg(opts), do: Config.load!(ec_params(opts))

  defp ec_params(opts) do
    case topology(opts) do
      nil -> Topology.ec_params()
      t -> Topology.ec_params_from(t)
    end
    # Config.load!/1 需 drives 非空校验；分布式不用 cfg.drives，但 Config 校验要求其存在。
    # 注入一个长度 N 的占位 drives（仅满足 length==K+M 校验，绝不用于 IO）。
    |> with_placeholder_drives()
  end

  defp with_placeholder_drives(ec_kw) do
    n = Keyword.fetch!(ec_kw, :data_shards) + Keyword.fetch!(ec_kw, :parity_shards)
    Keyword.put(ec_kw, :drives, for(i <- 0..(n - 1), do: "__remote_#{i}__"))
  end

  defp endpoints_for(bucket, key, opts) do
    case Placement.resolve(bucket, key, opts) do
      {:ok, placement} -> {:ok, endpoints_for_set(placement.set_id, opts)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp endpoints_for_write(bucket, key, opts) do
    case Placement.resolve_write(bucket, key, opts) do
      {:ok, placement} -> {:ok, endpoints_for_set(placement.set_id, opts)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp endpoints_with_write_placement(bucket, key, opts) do
    case Placement.resolve_write(bucket, key, opts) do
      {:ok, placement} -> {:ok, {endpoints_for_set(placement.set_id, opts), placement}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp endpoints_for_set(nil, _opts), do: Topology.endpoints(nil)

  defp endpoints_for_set(set_id, opts) do
    case topology(opts) do
      nil -> Topology.endpoints(set_id)
      t -> Topology.endpoints_from(t, set_id)
    end
  end

  # part 的端点：以 upload_id 作 key 路由（同 upload 全 part + assemble 同 set）。
  defp endpoints_for_upload(bucket, upload_id, opts),
    do: endpoints_for(bucket, ".uploads/" <> upload_id, upload_placement_opts(opts))

  defp endpoints_for_upload_write(bucket, upload_id, opts),
    do: endpoints_for_write(bucket, ".uploads/" <> upload_id, upload_placement_opts(opts))

  defp upload_placement_opts(opts) do
    case Keyword.get(opts, :upload_placement_set_id) do
      nil ->
        opts

      set_id ->
        opts
        |> Keyword.put(:placement_set_id, set_id)
        |> maybe_put_opt(:placement_pool_id, Keyword.get(opts, :upload_placement_pool_id))
        |> maybe_put_opt(
          :placement_topology_hash,
          Keyword.get(opts, :upload_placement_topology_hash)
        )
    end
  end

  defp maybe_put_opt(opts, _key, nil), do: opts
  defp maybe_put_opt(opts, key, value), do: Keyword.put(opts, key, value)

  defp transport(opts), do: Transport.impl(opts)

  # 端点 i 的「该对象在该 drive 下的目录」= Path.join(drive_i, obj_rel)。
  defp endpoint_dirs(endpoints, obj_rel),
    do: Enum.map(endpoints, fn {node, drive} -> {node, Path.join(drive, obj_rel)} end)

  # ── 原子提交编排（B1-2）──
  # 每端点 begin_tmp（drive_root = endpoint drive，与 final 同卷保证 rename 原子）；返回保序的
  # %{node, drive, final_dir, tmp_dir}（begin_tmp 失败 -> tmp_dir=nil，写时跳过、commit 不计入 quorum）。
  defp begin_commit_targets(tx, endpoints, obj_rel) do
    tx
    |> begin_staged_targets(endpoints)
    |> put_final_dirs(obj_rel)
  end

  defp begin_staged_targets(tx, endpoints) do
    Enum.map(endpoints, fn {node, drive} ->
      tmp_dir =
        case tx.begin_tmp(node, drive) do
          {:ok, tmp} -> tmp
          {:error, _} -> nil
        end

      %{node: node, drive: drive, final_dir: nil, tmp_dir: tmp_dir}
    end)
  end

  defp put_final_dirs(targets, obj_rel) do
    Enum.map(targets, fn target ->
      Map.put(target, :final_dir, Path.join(target.drive, obj_rel))
    end)
  end

  # 保序 N 元素 (node, tmp_dir | nil)：分片 i 写端点 i 的 temp；begin_tmp 失败端点 -> nil（写时跳过）。
  defp ordered_tmp_dirs(targets) do
    Enum.map(targets, fn %{node: node, tmp_dir: tmp} -> {node, tmp} end)
  end

  # 各端点 commit_object（temp -> final 数据先于元数据原子 rename）；返回成功端点数（write quorum 判定）。
  # :meta_only 仅 do_put_delete_marker 注入（纯元数据提交声明，B5-0）；do_put/assemble 不注入 →
  # 缺省 false → 缺 part.0 仍立即失败（绝不静默把「忘写数据」当成功提交）。
  defp commit_all(tx, targets, opts) do
    commit_all_results(tx, targets, opts)
    |> Enum.count(fn {_target, ok?} -> ok? end)
  end

  defp commit_all_results(tx, targets, opts) do
    commit_opts = Keyword.take(opts, [:fsync, :meta_only, :rename_fun])

    targets
    |> Task.async_stream(
      fn
        %{tmp_dir: nil} ->
          false

        %{node: node, tmp_dir: tmp, final_dir: final} ->
          try do
            case tx.commit_object(node, tmp, final, commit_opts) do
              :ok -> true
              _ -> false
            end
          rescue
            _ -> false
          catch
            _kind, _reason -> false
          end
      end,
      timeout: :infinity,
      max_concurrency: max(length(targets), 1)
    )
    |> Enum.zip(targets)
    |> Enum.map(fn
      {{:ok, ok?}, target} -> {target, ok?}
      {{:exit, _reason}, target} -> {target, false}
    end)
  end

  # write_quorum 未达：回滚此次写参与（begin_tmp 成功）的端点——删其 temp obj-dir + 已 commit 到 final
  # 的 obj-dir（某些端点可能已原子 rename 到 final，但整体未达 quorum；删 final 保证「quorum 失败 =>
  # 对象不存在」不变量，绝不留低于 read_quorum 的撕裂半对象给后续 GET）。未参与端点（begin_tmp 失败）
  # 从未触碰 final，不删（保其旧值不变）。
  defp cleanup_tmp(tx, targets) do
    targets
    |> Enum.filter(& &1.tmp_dir)
    |> Enum.each(fn %{node: node, tmp_dir: tmp, final_dir: final} ->
      tx.delete_shard(node, tmp)
      tx.delete_shard(node, final)
    end)
  end

  # ── PUT（逐块流式编码；分片 i -> 端点 i）──
  # 不自持对象锁：B1-1 起锁由 handler 层 Maxio.Lock 横跨字节+元数据 seam 单点持有（避免双锁/非重入死等）。

  defp do_put(bucket, key, version_id, chunks, opts) do
    case Paths.object_rel(bucket, key, version_id) do
      {:error, :invalid_key} ->
        {:error, :invalid_key}

      {:ok, _validated_obj_rel} ->
        case endpoints_with_write_placement(bucket, key, opts) do
          {:ok, {endpoints, placement}} ->
            put_staged(bucket, key, version_id, chunks, opts, endpoints, placement)

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  defp put_staged(bucket, key, version_id, chunks, opts, endpoints, placement) do
    c = cfg(opts)
    tx = transport(opts)
    n = Config.total(c)

    # B1-2 原子提交：每端点先 begin_tmp（同卷 .tmp obj-dir），逐块流式写进 temp，最后 commit
    # 数据先于元数据原子 rename 到 final。begin_tmp 失败的端点（node down）记 tmp=nil，写时跳过。
    staged_targets = begin_staged_targets(tx, endpoints)

    # 保序 N 元素 (node, tmp_dir | nil)：分片 i 必须写端点 i 的 temp（down 端点 nil 跳过，绝不错位）。
    tmp_dirs = ordered_tmp_dirs(staged_targets)

    try do
      acc0 = %{
        md5: :crypto.hash_init(:md5),
        sha: :crypto.hash_init(:sha256),
        size: 0,
        shard_len: nil,
        block_hashes: List.duplicate([], n),
        buffer: <<>>,
        block_index: 0,
        dirs: tmp_dirs,
        tx: tx
      }

      acc = Enum.reduce(chunks, acc0, fn chunk, acc -> feed(c, acc, chunk) end)
      acc = flush_final(c, acc)

      etag = acc.md5 |> :crypto.hash_final() |> Base.encode16(case: :lower)
      sha256 = acc.sha |> :crypto.hash_final() |> Base.encode16(case: :lower)
      shard_len = acc.shard_len || 0

      result = %{
        size: acc.size,
        etag: etag,
        sha256: sha256,
        placement_set_id: placement.set_id,
        placement_pool_id: placement.pool_id,
        placement_topology_hash: placement.topology_hash
      }

      extra = run_before_object_commit!(opts, result)
      prepared = Map.merge(result, extra)
      block_hashes = Enum.map(acc.block_hashes, &Enum.reverse/1)

      ObjectCommit.run(
        opts,
        prepared,
        default_object_commit_opts(version_id, opts, extra),
        fn commit_opts ->
          publish_staged_put(
            tx,
            staged_targets,
            bucket,
            key,
            c,
            opts,
            prepared,
            shard_len,
            block_hashes,
            commit_opts
          )
        end,
        fn -> cleanup_tmps(tx, staged_targets) end
      )
    rescue
      err ->
        cleanup_tmps(tx, staged_targets)
        reraise(err, __STACKTRACE__)
    catch
      kind, reason ->
        cleanup_tmps(tx, staged_targets)
        :erlang.raise(kind, reason, __STACKTRACE__)
    end
  end

  defp default_object_commit_opts(version_id, opts, extra) do
    object_meta =
      opts
      |> Keyword.get(:object_meta, %{})
      |> Map.merge(Map.get(extra, :object_meta, %{}) || %{})

    [version_id: version_id, object_meta: object_meta]
  end

  defp publish_staged_put(
         tx,
         staged_targets,
         bucket,
         key,
         cfg,
         opts,
         prepared,
         shard_len,
         block_hashes,
         commit_opts
       ) do
    version_id = Keyword.fetch!(commit_opts, :version_id)
    object_meta = Keyword.fetch!(commit_opts, :object_meta)
    control = Keyword.fetch!(commit_opts, :object_commit_control)
    identity = Keyword.fetch!(commit_opts, :object_commit_identity)
    publish_opts = Keyword.put(opts, :object_meta, object_meta)

    with :ok <- revalidate_staged_placement(bucket, key, prepared, opts),
         {:ok, obj_rel} <- Paths.object_rel(bucket, key, version_id) do
      commit_targets = put_final_dirs(staged_targets, obj_rel)

      meta =
        build_meta(
          cfg,
          version_id,
          publish_opts,
          prepared.size,
          prepared.etag,
          prepared.sha256,
          shard_len,
          block_hashes
        )
        |> Map.put("object_commit_identity", identity)

      _ = write_sidecars(tx, ordered_tmp_dirs(commit_targets), meta)
      committed = Map.put(prepared, :version_id, version_id)

      # 协议化 PutObject（commit_opts[:object_mutation]，B5 orchestrator 注入）走
      # ObjectMutation publish 分支；不传该 opt 的调用者保持现状路径逐字节不变（R6）。
      case Keyword.get(commit_opts, :object_mutation) do
        nil ->
          publish_controlled_replace(
            tx,
            commit_targets,
            cfg,
            opts,
            committed,
            control,
            identity,
            bucket,
            key
          )

        %MutationContext{} = ctx ->
          publish_mutation_staged_put(
            tx,
            commit_targets,
            cfg,
            opts,
            committed,
            meta,
            control,
            identity,
            ctx,
            bucket,
            key
          )

        invalid ->
          cleanup_tmps(tx, staged_targets)
          {:error, {:invalid_object_mutation, invalid}}
      end
    else
      {:error, reason} ->
        cleanup_tmps(tx, staged_targets)
        {:error, reason}
    end
  end

  # 非协议 publish 路径（现状逐字节不变，R6）：identity 比对式 commit_object_replace。
  defp publish_controlled_replace(
         tx,
         commit_targets,
         cfg,
         opts,
         committed,
         control,
         identity,
         bucket,
         key
       ) do
    case commit_object_replace(
           tx,
           commit_targets,
           cfg.write_quorum,
           opts,
           control,
           identity
         ) do
      :ok ->
        {:ok, committed}

      {:error, :write_quorum} = error ->
        Logger.error("distributed put below write quorum",
          bucket: bucket,
          key: key,
          reason: "write_quorum=#{cfg.write_quorum}"
        )

        error

      # Phase 2A C1（B3 审查项 3）：commit_object_replace 的非 quorum 错误（Control
      # 注册失败等；备份计划/物化失败在 Distributed 已折叠为 :write_quorum）由
      # CaseClauseError 裸崩收口为结构化返回；`:write_quorum` 形状保持不变。
      {:error, reason} ->
        Logger.error("distributed put replace commit failed",
          bucket: bucket,
          key: key,
          reason: inspect(reason)
        )

        {:error, {:commit_failed, reason}}
    end
  end

  defp revalidate_staged_placement(bucket, key, prepared, opts) do
    case endpoints_with_write_placement(bucket, key, opts) do
      {:ok, {_endpoints, placement}} ->
        current =
          {placement.set_id, placement.pool_id, placement.topology_hash}

        staged =
          {prepared.placement_set_id, prepared.placement_pool_id,
           prepared.placement_topology_hash}

        if current == staged, do: :ok, else: {:error, :placement_changed}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # ── ObjectMutation 协议化 publish（协议 §3.2/§3.3/§5，实现计划 B4）──
  # 与 EC publish_mutation_staged_put（B3）同形的四阶段协议分支，差异仅在 endpoint 换
  # {node, drive}、per-endpoint IO 经 Transport（既有 revalidate_staged_placement 复核保留
  # 在外层 with）：
  #   * 每端点旧值备份落 <drive>/.maxio-object-mutations/<mutation_id>/ + 每端点 manifest
  #     （tx.put_mutation_manifest，远端 fsync——durable，recovery 凭 journal + 磁盘即可
  #     定位），不再用 .tmp/<uuid>；
  #   * 阶段 1 manifest 先行（names 经 tx.list_dir 逐端点探测；落盘数不足 epoch_quorum →
  #     在任何破坏性 IO 之前拒绝）；阶段 2 物化备份（tx.move_shard，失败端点掉队不中断）；
  #   * 阶段 3 destructive rename 之前逐端点 epoch CAS {:exact, token, ["claimed"]} →
  #     "published"（携精确 fingerprint）quorum 门（D4：oks >= cfg.epoch_quorum）；不足
  #     quorum → 不进入 rename、backup 保留（实现计划决策点 2：publish CAS 固定在 rename
  #     之前，不得调换）；
  #   * 阶段 4 仅 published 端点 tx.commit_object（数据 quorum 沿用 write_quorum）；
  #   * rollback/finalize 闭包指向 restore_if_current/finalize_if_current——所有权判定只认
  #     epoch token；sidecar 仍写 object_commit_identity（旧调用者与取证兼容），协议分支
  #     不走 identity 比对；
  #   * begin_tmp 失败的 down 端点不参与（其旧 final 不被触碰，与非协议路径同语义），
  #     收敛交给 epoch token 授权的 restore_mutation / Phase 2C heal。
  # register 之后的失败不清 tmp/backup：ObjectCommit rollback 经 restore_if_current 收敛
  # （durable manifest 在，幂等），discard_fun 清 tmps。
  defp publish_mutation_staged_put(
         tx,
         commit_targets,
         cfg,
         opts,
         committed,
         meta,
         control,
         identity,
         ctx,
         bucket,
         key
       ) do
    with :ok <- validate_mutation_commit_targets(commit_targets, ctx),
         {:ok, plans} <- plan_mutation_backups(commit_targets, ctx),
         {:ok, fingerprint} <- staged_mutation_fingerprint(meta, committed),
         {:ok, published_payload} <- published_epoch_payload(ctx, fingerprint) do
      rollback = fn -> mutation_control_result(do_restore_if_current(ctx, opts)) end
      finalize = fn -> mutation_control_result(do_finalize_if_current(ctx, opts)) end

      case Control.register(control, identity, rollback, finalize) do
        :ok ->
          publish_mutation_plans(
            tx,
            plans,
            cfg,
            opts,
            committed,
            fingerprint,
            published_payload,
            ctx,
            bucket,
            key
          )

        {:error, reason} ->
          cleanup_tmps(tx, commit_targets)
          {:error, reason}
      end
    else
      {:error, reason} ->
        cleanup_tmps(tx, commit_targets)
        {:error, reason}
    end
  end

  defp publish_mutation_plans(
         tx,
         plans,
         cfg,
         opts,
         committed,
         fingerprint,
         published_payload,
         ctx,
         bucket,
         key
       ) do
    # 阶段 1：每端点 manifest 先行（B1 EpochStore 契约：published 的 restore 要求 manifest
    # 必在）。落盘数不足 epoch_quorum → 尚无任何破坏性 IO，直接拒绝。
    {with_manifest, manifest_failures} =
      split_mutation_plans(plans, fn plan -> write_mutation_manifest(tx, plan, ctx) end)

    if length(with_manifest) < cfg.epoch_quorum do
      Logger.error("distributed mutation backup manifest below epoch quorum",
        bucket: bucket,
        key: key,
        mutation_id: ctx.mutation_id,
        reason:
          "ok=#{length(with_manifest)} < epoch_quorum=#{cfg.epoch_quorum} " <>
            "failures=#{inspect(mutation_plan_failures(manifest_failures))}"
      )

      {:error,
       {:mutation_backup_quorum,
        %{endpoints_ok: length(with_manifest), epoch_quorum: cfg.epoch_quorum}}}
    else
      # 阶段 2：物化备份（第一次 destructive IO；仅 manifest 已 durable 的端点）。失败端点
      # 掉队（其 final 残留由 restore_mutation 按 manifest 收敛），绝不中断其他端点。
      {materialized, materialize_failures} =
        split_mutation_plans(with_manifest, fn plan -> materialize_mutation_plan(tx, plan) end)

      if materialize_failures != [] do
        Logger.warning("distributed mutation backup materialize failed on endpoints",
          bucket: bucket,
          key: key,
          mutation_id: ctx.mutation_id,
          reason: inspect(mutation_plan_failures(materialize_failures))
        )
      end

      # 阶段 3：destructive rename 之前的 epoch publish quorum 门（决策点 2）。
      {published, cas_failures} =
        split_mutation_plans(materialized, fn plan ->
          mutation_publish_cas(tx, plan, ctx, published_payload)
        end)

      if length(published) < cfg.epoch_quorum do
        Logger.error("distributed mutation epoch publish below epoch quorum",
          bucket: bucket,
          key: key,
          mutation_id: ctx.mutation_id,
          reason:
            "ok=#{length(published)} < epoch_quorum=#{cfg.epoch_quorum} " <>
              "failures=#{inspect(mutation_plan_failures(cas_failures))}"
        )

        {:error,
         {:epoch_publish_quorum,
          %{endpoints_ok: length(published), epoch_quorum: cfg.epoch_quorum}}}
      else
        if cas_failures != [] do
          Logger.warning("distributed mutation epoch publish failed on minority endpoints",
            bucket: bucket,
            key: key,
            mutation_id: ctx.mutation_id,
            reason: inspect(mutation_plan_failures(cas_failures))
          )
        end

        # 阶段 4：数据 rename（仅 epoch 已 published 的端点；数据 quorum 沿用 write_quorum，
        # epoch_quorum >= write_quorum 保证门内端点数足够）。不足 → 不回滚 final/backup，
        # 收敛交给 restore_if_current（journal/recovery）。
        data_commit_opts = Keyword.take(opts, [:fsync, :meta_only, :rename_fun])

        ok_endpoints =
          Enum.count(published, fn plan ->
            tx.commit_object(plan.node, plan.tmp, plan.final, data_commit_opts) == :ok
          end)

        if ok_endpoints >= cfg.write_quorum do
          Enum.each(plans, fn plan -> tx.delete_shard(plan.node, plan.tmp) end)
          {:ok, Map.put(committed, :epoch_fingerprint, fingerprint)}
        else
          Logger.error("distributed mutation put below write quorum",
            bucket: bucket,
            key: key,
            mutation_id: ctx.mutation_id,
            reason: "ok_endpoints=#{ok_endpoints} < write_quorum=#{cfg.write_quorum}"
          )

          {:error, :write_quorum}
        end
      end
    end
  end

  # 逐端点执行一个阶段函数（{:ok, plan} | {:error, reason}），失败端点掉队、绝不中断其他
  # 端点；quorum 门只看通过端点数（结构同 EC split_plans，阶段函数可回填 plan——names 由
  # 阶段 1 的远端探测产出）。
  defp split_mutation_plans(plans, fun) do
    {oks, failures} =
      Enum.reduce(plans, {[], []}, fn plan, {oks, failures} ->
        case fun.(plan) do
          {:ok, plan} -> {[plan | oks], failures}
          {:error, reason} -> {oks, [{plan, reason} | failures]}
        end
      end)

    {Enum.reverse(oks), Enum.reverse(failures)}
  end

  defp mutation_plan_failures(failures),
    do: Enum.map(failures, fn {plan, reason} -> {{plan.node, plan.drive}, reason} end)

  # 防线：ctx.final_rel（restore 的回位落点，journal 派生）必须与本次 publish 的各端点
  # final 指向同一相对路径——不一致意味着上下文与请求落点脱节，restore 会把旧字节回错目录。
  defp validate_mutation_commit_targets(commit_targets, %MutationContext{final_rel: final_rel}) do
    if is_binary(final_rel) and
         Enum.all?(commit_targets, fn %{drive: drive, final_dir: final} ->
           Path.join(drive, final_rel) == final
         end) do
      :ok
    else
      {:error, {:mutation_final_rel_mismatch, final_rel}}
    end
  end

  # 协议化备份计划（每参与端点一份）：backup 落 durable mutation 目录（非 .tmp）。
  # begin_tmp 失败的 down 端点不参与（未 staging、其旧 final 不被触碰）；names 由阶段 1
  # 的远端探测回填（nil 占位）。
  defp plan_mutation_backups(commit_targets, %MutationContext{mutation_id: mutation_id}) do
    plans =
      commit_targets
      |> Enum.filter(& &1.tmp_dir)
      |> Enum.map(fn target ->
        %{
          node: target.node,
          drive: target.drive,
          tmp: target.tmp_dir,
          final: target.final_dir,
          backup_dir: Path.join(target.drive, MutationBackup.relative_dir(mutation_id)),
          names: nil
        }
      end)

    {:ok, plans}
  end

  # manifest 先行（每端点）：names 经 tx.list_dir 该端点探测（滞后端点可能缺 part.0/
  # meta.json；fresh 端点 entries=[]——restore 只按 manifest 名单回位，绝不推断删除，
  # nil/:enoent 不当授权同源纪律），manifest 经 tx.put_mutation_manifest 在该端点 drive 上
  # fsync 落盘于其任何 destructive IO 之前。
  defp write_mutation_manifest(tx, plan, ctx) do
    with {:ok, names} <- probe_mutation_backup_names(tx, plan),
         entries = Enum.map(names, &%{"name" => &1}),
         {:ok, manifest} <-
           MutationBackup.manifest(ctx.target, ctx.token, previous_epoch_token(ctx), entries),
         {:ok, payload} <- mutation_manifest_payload(manifest),
         :ok <-
           tx.put_mutation_manifest(plan.node, plan.drive, %{
             mutation_id: ctx.mutation_id,
             manifest: payload
           }) do
      {:ok, %{plan | names: names}}
    end
  end

  # 该端点 final obj-dir 内单层布局文件探测（include_layout_files 返回 meta.json/part.0
  # 文件条目；目录不存在 → []=fresh）。端点不可达 → 结构化失败（该端点无法建立 durable
  # 备份名单，掉队于 manifest 门，绝不猜测）。
  defp probe_mutation_backup_names(tx, plan) do
    case tx.list_dir(plan.node, plan.final, include_layout_files: true) do
      {:ok, entries} ->
        present = for %{name: name, type: :file} <- entries, do: name
        {:ok, Enum.filter([@part_file, @meta_file], &(&1 in present))}

      {:error, reason} ->
        {:error, {:backup_probe_failed, reason}}
    end
  end

  # manifest 结构体 → 纯数据 payload map（erpc 传输形状；远端 decode 全量重验）。
  defp mutation_manifest_payload(manifest) do
    with {:ok, bytes} <- MutationBackup.encode(manifest), do: Jason.decode(bytes)
  end

  # 物化备份：按 names 名单把该端点 final 内旧文件 rename 进 backup 目录（同 drive 卷，
  # tx.move_shard 原子）。任一 entry 失败 → 该端点整体掉队（manifest 已 durable，restore
  # 按名单幂等收敛）。
  defp materialize_mutation_plan(tx, plan) do
    plan.names
    |> Enum.reduce_while(:ok, fn name, :ok ->
      case tx.move_shard(
             plan.node,
             Path.join(plan.final, name),
             Path.join(plan.backup_dir, name),
             []
           ) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, {:backup_materialize_failed, name, reason}}}
      end
    end)
    |> case do
      :ok -> {:ok, plan}
      {:error, _reason} = error -> error
    end
  end

  # fingerprint 的 sidecar_sha256 针对各端点实际落盘的 meta.json 字节：ShardServer.put_sidecar
  # 在端点侧对同一 meta map 执行同一 Meta.encode（确定性 Jason 编码，erpc 保 term 不变、
  # 全集群同一 release）——本地对同一 map 编码即全端点落盘字节，杜绝读回解码的字节漂移。
  defp staged_mutation_fingerprint(meta, committed),
    do: {:ok, ObjectEpoch.fingerprint(committed.etag, committed.size, Meta.encode(meta))}

  # 各端点同一份 published payload：{:exact, token, ["claimed"]} 门依赖 B1 收口确认项
  # 「claim 恒写 phase=claimed」的不变量。
  defp published_epoch_payload(ctx, fingerprint) do
    with {:ok, published} <-
           ObjectEpoch.new(ctx.target, ctx.token, %{
             operation: ctx.operation,
             phase: "published",
             value_type: "object",
             fingerprint: fingerprint,
             previous_token: previous_epoch_token(ctx),
             updated_at: DateTime.utc_now()
           }) do
      EpochStore.payload(published)
    end
  end

  defp mutation_publish_cas(tx, plan, ctx, published_payload) do
    case tx.cas_epoch(plan.node, plan.drive, %{
           next: published_payload,
           expect: {:exact, ctx.token, ["claimed"]}
         }) do
      {:ok, :applied} -> {:ok, plan}
      {:error, {:fenced, current}} -> {:error, {:epoch_fenced, current}}
      {:error, reason} -> {:error, reason}
    end
  end

  # Control 闭包契约：:ok | {:error, reason}。restore/finalize 的 :superseded 视为收敛完成
  # （successor 已建立，本次提交对 final 无事可做——绝不触碰 successor）。
  defp mutation_control_result({:ok, _outcome}), do: :ok
  defp mutation_control_result({:error, _reason} = error), do: error

  defp previous_epoch_token(%MutationContext{previous_epoch: %{"token" => token}}), do: token
  defp previous_epoch_token(%MutationContext{}), do: nil

  # ── ObjectMutation epoch 原语（B4）：per-endpoint 原语经 Transport 的逐端点 quorum 编排。──

  defp do_claim_epoch(target, token, operation, opts) do
    cfg = cfg(opts)
    tx = transport(opts)

    # claim 端点 = 写 placement（与本次 put 的落点一致），并把 placement 快照交给调用者
    # （B5 写入 journal placement_snapshot——restore/finalize 端点解析只认它）。先 quorum
    # 读取 previous（lineage 信息，B5 写入 journal previous_epoch）；fence 正确性由各端点
    # CAS 的「仅接受严格更大 token」独立保证（B5 起 claim 恒在 object lock 内）。
    with {:ok, bucket, key} <- mutation_target_locator(target),
         {:ok, {endpoints, placement}} <- endpoints_with_write_placement(bucket, key, opts),
         {:ok, current} <- adjudicate_endpoint_epochs(tx, endpoints, target, cfg.epoch_quorum),
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
         {:ok, payload} <- EpochStore.payload(claimed) do
      request = %{next: payload, expect: {:claim, token}}

      oks =
        endpoints
        |> epoch_endpoint_results(fn node, drive -> tx.cas_epoch(node, drive, request) end)
        |> Enum.count(fn {_endpoint, result} -> match?({:ok, :applied}, result) end)

      if oks >= cfg.epoch_quorum do
        {:ok,
         %{
           previous: previous,
           endpoints_ok: oks,
           placement_snapshot: placement_snapshot(placement)
         }}
      else
        # 少数端点已写入的 claim 无需回收：fence 单调性保证无害，后继 claim 会取 max+1。
        Logger.error("distributed claim_epoch below epoch quorum",
          bucket: bucket,
          key: key,
          reason: "ok=#{oks} < epoch_quorum=#{cfg.epoch_quorum}"
        )

        {:error, :write_quorum}
      end
    end
  end

  # quorum 读裁决（D4）：可读端点数（有效 epoch 或显式 :absent）>= epoch_quorum 才裁决。
  defp do_current_epoch(target, opts) do
    cfg = cfg(opts)
    tx = transport(opts)

    with {:ok, bucket, key} <- mutation_target_locator(target),
         {:ok, endpoints} <- endpoints_for(bucket, key, opts) do
      adjudicate_endpoint_epochs(tx, endpoints, target, cfg.epoch_quorum)
    end
  end

  # 先 quorum 读全局裁决（quorum 视图见 successor → 整体 :superseded，任何端点不动；见本
  # token 的 committed epoch → {:error, :epoch_committed}，metadata_committed 禁回滚的
  # quorum 级防线；absent → {:error, :epoch_missing}）；裁决通过才逐端点 restore_mutation
  # （per-endpoint CAS 仍各自把关），restored 端点数 >= epoch_quorum → 成功，否则
  # {:error, {:partial, evidence}}（journal 侧 mark_error 重试；backup 保留——不猜测、不破坏）。
  defp do_restore_if_current(%MutationContext{} = ctx, opts) do
    cfg = cfg(opts)
    tx = transport(opts)

    with {:ok, endpoints} <- mutation_endpoints(ctx, opts) do
      case adjudicate_mutation_epoch(tx, endpoints, ctx, :restore, cfg.epoch_quorum) do
        :superseded ->
          {:ok, :superseded}

        :proceed ->
          request = %{
            target: ctx.target,
            token: ctx.token,
            mutation_id: ctx.mutation_id,
            final_rel: ctx.final_rel
          }

          endpoints
          |> epoch_endpoint_results(fn node, drive ->
            tx.restore_mutation(node, drive, request)
          end)
          |> conclude_mutation_quorum(:restored, cfg.epoch_quorum)

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp do_finalize_if_current(%MutationContext{} = ctx, opts) do
    cfg = cfg(opts)
    tx = transport(opts)

    with {:ok, endpoints} <- mutation_endpoints(ctx, opts) do
      case adjudicate_mutation_epoch(tx, endpoints, ctx, :finalize, cfg.epoch_quorum) do
        :superseded ->
          {:ok, :superseded}

        :proceed ->
          request = %{target: ctx.target, token: ctx.token, mutation_id: ctx.mutation_id}

          endpoints
          |> epoch_endpoint_results(fn node, drive ->
            tx.finalize_mutation(node, drive, request)
          end)
          |> conclude_mutation_quorum(:finalized, cfg.epoch_quorum)

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  # 恢复端点解析只认 journal 保存的历史 placement（协议 §3.3）：核对 topology_hash，
  # 漂移 → {:error, {:placement_drift, evidence}}（B6 recovery 映射 quarantine 证据，
  # 不触任何端点），**绝不按当前 router 猜测**。
  defp mutation_endpoints(%MutationContext{placement_snapshot: snapshot}, opts) do
    with {:ok, set_id, snapshot_hash} <- validate_placement_snapshot(snapshot) do
      current_hash = Placement.topology_hash_for_opts(opts)

      if current_hash == snapshot_hash do
        {:ok, endpoints_for_set(set_id, opts)}
      else
        {:error,
         {:placement_drift,
          %{
            set_id: set_id,
            snapshot_topology_hash: snapshot_hash,
            current_topology_hash: current_hash
          }}}
      end
    end
  end

  # placement_snapshot 的 durable 形状（journal JSONB，string keys）：set_id + topology_hash
  # 缺一不可（无快照 = 无法定位历史端点，结构化拒绝——绝不退回当前 router）。
  defp validate_placement_snapshot(%{"set_id" => set_id, "topology_hash" => hash} = _snapshot)
       when is_integer(set_id) and is_binary(hash),
       do: {:ok, set_id, hash}

  defp validate_placement_snapshot(snapshot),
    do: {:error, {:invalid_placement_snapshot, snapshot}}

  defp placement_snapshot(placement) do
    %{
      "set_id" => placement.set_id,
      "pool_id" => placement.pool_id,
      "topology_hash" => placement.topology_hash
    }
  end

  defp mutation_target_locator(%{"bucket" => bucket, "key" => key})
       when is_binary(bucket) and is_binary(key),
       do: {:ok, bucket, key}

  defp mutation_target_locator(target), do: {:error, {:invalid_epoch_target, target}}

  # 可读端点视图 >= epoch_quorum 才裁决，取最大 token 的 epoch；:absent 仅当可读端点全为
  # absent（nil/:enoent 绝不当授权）；不足 → {:error, :epoch_quorum_unavailable}（不猜测）。
  defp adjudicate_endpoint_epochs(tx, endpoints, target, epoch_quorum) do
    views = read_epoch_views(tx, endpoints, target)
    epochs = for {_endpoint, {:epoch, epoch}} <- views, do: epoch
    absent = Enum.count(views, fn {_endpoint, view} -> view == :absent end)

    cond do
      length(epochs) + absent < epoch_quorum -> {:error, :epoch_quorum_unavailable}
      epochs == [] -> {:ok, :absent}
      true -> {:ok, Enum.max_by(epochs, &token_sort_key/1)}
    end
  end

  # quorum 读全局裁决：裁决 token > ctx.token（successor 可见）→ :superseded；全 absent →
  # {:error, :epoch_missing}；裁决 token < ctx.token → 证据矛盾（claim 已达 quorum、两个
  # quorum 必有交集，可读视图不应只见更旧 token）→ {:error, {:epoch_mismatch, token}}。
  defp adjudicate_mutation_epoch(tx, endpoints, %MutationContext{} = ctx, kind, epoch_quorum) do
    views = read_epoch_views(tx, endpoints, ctx.target)
    epochs = for {_endpoint, {:epoch, epoch}} <- views, do: epoch
    absent = Enum.count(views, fn {_endpoint, view} -> view == :absent end)

    cond do
      length(epochs) + absent < epoch_quorum ->
        {:error, :epoch_quorum_unavailable}

      epochs == [] ->
        {:error, :epoch_missing}

      true ->
        adjudicated = Enum.max_by(epochs, &token_sort_key/1)

        case ObjectEpoch.compare_tokens(adjudicated.token, ctx.token) do
          {:ok, :gt} -> :superseded
          {:ok, :lt} -> {:error, {:epoch_mismatch, adjudicated.token}}
          {:ok, :eq} -> adjudicate_owned(epochs, ctx.token, kind)
          {:error, reason} -> {:error, reason}
        end
    end
  end

  # metadata_committed 禁回滚的 quorum 级防线：任一可读端点的本 token epoch 已 committed →
  # 整体拒绝 restore（per-endpoint restore_mutation 的 :epoch_committed 是端点级同源防线）。
  defp adjudicate_owned(epochs, token, :restore) do
    committed? =
      Enum.any?(epochs, fn epoch -> epoch.token == token and epoch.phase == "committed" end)

    if committed?, do: {:error, :epoch_committed}, else: :proceed
  end

  # finalize 对 committed 幂等（per-endpoint 收敛残余 backup），无需 quorum 级前置拒绝。
  defp adjudicate_owned(_epochs, _token, :finalize), do: :proceed

  # 三分类计数（与 EC conclude_mutation_quorum 同形，endpoint = {node, drive}）：
  # ok_outcome（:restored/:finalized）/ :superseded / error。per-endpoint 的 :superseded
  # （全局裁决后另一写者插入的窗口）不计入成功——诚实上报 partial，重试时全局裁决折叠为
  # 整体 :superseded。errors 为 [{{node, drive}, 原始 term}]（journal 证据侧须 stringify）。
  defp conclude_mutation_quorum(results, ok_outcome, epoch_quorum) do
    {oks, supersededs, errors} =
      Enum.reduce(results, {0, 0, []}, fn {endpoint, result}, {oks, sups, errors} ->
        case result do
          {:ok, ^ok_outcome} -> {oks + 1, sups, errors}
          {:ok, :superseded} -> {oks, sups + 1, errors}
          {:error, reason} -> {oks, sups, [{endpoint, reason} | errors]}
          other -> {oks, sups, [{endpoint, {:invalid_result, other}} | errors]}
        end
      end)

    if oks >= epoch_quorum do
      {:ok, ok_outcome}
    else
      {:error,
       {:partial,
        %{
          applied: oks,
          superseded: supersededs,
          epoch_quorum: epoch_quorum,
          errors: Enum.reverse(errors)
        }}}
    end
  end

  # per-endpoint epoch 原语的并行执行（抄 write_sidecars 的 Task.async_stream 模式）：
  # 返回保序 [{endpoint, result}]；task 异常/exit 折叠为 {:error, :unavailable}（铁律 3，
  # 与 Transport 宕机语义同形——绝不炸 quorum 编排）。
  defp epoch_endpoint_results(endpoints, fun) do
    endpoints
    |> Task.async_stream(
      fn {node, drive} ->
        try do
          fun.(node, drive)
        rescue
          _ -> {:error, :unavailable}
        catch
          _kind, _reason -> {:error, :unavailable}
        end
      end,
      timeout: :infinity,
      max_concurrency: max(length(endpoints), 1)
    )
    |> Enum.zip(endpoints)
    |> Enum.map(fn
      {{:ok, result}, endpoint} -> {endpoint, result}
      {{:exit, _reason}, endpoint} -> {endpoint, {:error, :unavailable}}
    end)
  end

  defp read_epoch_views(tx, endpoints, target) do
    endpoints
    |> epoch_endpoint_results(fn node, drive -> tx.read_epoch(node, drive, target) end)
    |> Enum.map(fn {endpoint, result} ->
      view =
        case result do
          {:ok, :absent} ->
            :absent

          {:ok, payload} ->
            case epoch_from_payload(payload) do
              {:ok, epoch} -> {:epoch, epoch}
              {:error, reason} -> {:error, reason}
            end

          {:error, reason} ->
            {:error, reason}
        end

      {endpoint, view}
    end)
  end

  # token 全序（{generation, mutation_id}，与 ObjectEpoch.compare_tokens 同序）：
  # decode 后 token 已规范化（generation 整数、mutation_id 小写），可直接按键排序。
  defp token_sort_key(%ObjectEpoch{token: token}),
    do: {token["generation"], token["mutation_id"]}

  # ShardServer 原语响应是纯数据 payload（erpc 同形）；quorum 裁决按结构体比较 token，
  # 经 decode 全量重验还原（坏 payload 计入不可读端点，绝不参与裁决）。
  defp epoch_from_payload(payload) do
    with {:ok, bytes} <- Jason.encode(payload) do
      ObjectEpoch.decode(bytes)
    end
  end

  defp epoch_or_nil(:absent), do: nil
  defp epoch_or_nil(%ObjectEpoch{} = epoch), do: epoch

  defp feed(cfg, acc, chunk) do
    acc = %{
      acc
      | md5: :crypto.hash_update(acc.md5, chunk),
        sha: :crypto.hash_update(acc.sha, chunk),
        size: acc.size + byte_size(chunk),
        buffer: acc.buffer <> chunk
    }

    drain_full_blocks(cfg, acc)
  end

  defp drain_full_blocks(cfg, %{buffer: buffer} = acc) when byte_size(buffer) >= cfg.block_size do
    block_size = cfg.block_size
    <<block::binary-size(^block_size), rest::binary>> = buffer
    acc = write_block(cfg, %{acc | buffer: rest}, block)
    drain_full_blocks(cfg, acc)
  end

  defp drain_full_blocks(_cfg, acc), do: acc

  defp flush_final(_cfg, %{buffer: <<>>} = acc), do: acc

  defp flush_final(cfg, %{buffer: buffer} = acc),
    do: write_block(cfg, %{acc | buffer: <<>>}, buffer)

  # 编码一个 block：N 分片经 transport 写各端点；校验和按端点累积（与 M6 write_block 逐字一致，
  # 仅落盘换成 transport.put_shard）。块零填充到 block_size 保证全对象 shard_len 一致（M6 不变量）。
  defp write_block(cfg, acc, block) do
    padded =
      if byte_size(block) < cfg.block_size do
        block <> <<0::size((cfg.block_size - byte_size(block)) * 8)>>
      else
        block
      end

    %{shards: shards, checksums: checksums, shard_len: shard_len} = Codec.split_block(cfg, padded)

    _ok = write_block_shards(acc.tx, acc.dirs, acc.block_index, shards, shard_len)

    block_hashes =
      acc.block_hashes
      |> Enum.zip(checksums)
      |> Enum.map(fn {acc_list, ck} -> [Base.encode16(ck, case: :lower) | acc_list] end)

    %{acc | shard_len: shard_len, block_index: acc.block_index + 1, block_hashes: block_hashes}
  end

  # 写 block j 的 N 个分片到 N 个端点（并行，铁律 4 一条消息一个分片）；返回成功端点数。
  # dirs 为保序 N 元素 (node, tmp_dir | nil)；nil 端点（begin_tmp 失败/down）跳过，绝不错位分片。
  defp write_block_shards(tx, dirs, j, shards, shard_len) do
    dirs
    |> Enum.zip(shards)
    |> Enum.reject(fn {{_node, dir}, _shard} -> is_nil(dir) end)
    |> Task.async_stream(
      fn {{node, dir}, shard} ->
        case tx.put_shard(node, dir, j, shard, shard_len) do
          :ok -> :ok
          _ -> :error
        end
      end,
      timeout: :infinity,
      max_concurrency: max(length(dirs), 1)
    )
    |> Enum.count(fn
      {:ok, :ok} -> true
      _ -> false
    end)
  end

  # ROUTE B B4-5：构造 v1 core（耐久 ec/shards/size/etag/sha256/parts，字节不变）后经
  # Sidecar.migrate_v1/2 升级为完整 maxio/2 sidecar（仅 Map.put 加 format + 单元素 versions，绝不
  # 污染耐久字段）。分布式同样单次 build_meta、同一份 meta 发所有端点 → N 份 signature 逐字一致。
  # version_id + opts 由 put/5 → do_put → put_locked 一路透传。
  defp build_meta(cfg, version_id, opts, size, etag, sha256, shard_len, block_hashes_per_drive) do
    n = Config.total(cfg)

    shards =
      for i <- 0..(n - 1) do
        hashes = Enum.at(block_hashes_per_drive, i)
        %{"drive" => i, "shard_file_size" => length(hashes) * shard_len, "block_hashes" => hashes}
      end

    core = %{
      "ec" => %{
        "k" => cfg.data_shards,
        "m" => cfg.parity_shards,
        "block_size" => cfg.block_size,
        "algo" => "blake3-256"
      },
      "size" => size,
      "etag" => etag,
      "sha256" => sha256,
      # 字节承载对象恒非 delete marker；sidecar 自描述该字段（缺省 false），使 drive-walk LIST
      # 能从盘上判定当前版本是否逻辑删除（对齐 MinIO xl.meta 承载 version type）。
      "is_delete_marker" => false,
      "parts" => [%{"part" => 0, "size" => size}],
      "shards" => shards
    }

    Sidecar.migrate_v1(core, version_opts(version_id, opts))
  end

  # 从 opts[:object_meta] 取 maxio/2 版本头字段，产出 Sidecar.migrate_v1/2 的 keyword（与
  # ErasureCoded.version_opts 逐字一致）。modtime 一次计算（同一份 meta 发所有端点 → N 份
  # signature 一致）；data_dir = version_id（方案 B 每版本独立目录）。
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

  # sidecar 写各端点（并行），返回成功端点数。dirs 可能含 nil（begin_tmp 失败端点）-> 跳过。
  defp write_sidecars(tx, dirs, meta) do
    dirs
    |> Enum.reject(fn {_node, dir} -> is_nil(dir) end)
    |> Task.async_stream(
      fn {node, dir} ->
        case tx.put_sidecar(node, dir, meta) do
          :ok -> :ok
          _ -> :error
        end
      end,
      timeout: :infinity,
      max_concurrency: max(length(dirs), 1)
    )
    |> Enum.count(fn
      {:ok, :ok} -> true
      _ -> false
    end)
  end

  # ── GET（逐块跨节点并行读 K-of-N；校验 + 重建；Range 裁剪；流式）──

  defp do_get(bucket, key, version_id, range, opts) do
    case Paths.object_rel(bucket, key, version_id) do
      {:error, :invalid_key} ->
        {:error, :invalid_key}

      {:ok, obj_rel} ->
        c = cfg(opts)

        with {:ok, endpoints} <- endpoints_for(bucket, key, opts) do
          dirs = endpoint_dirs(endpoints, obj_rel)
          tx = transport(opts)

          case read_any_sidecar(tx, dirs) do
            {:ok, meta} ->
              size = meta["size"]
              block_size = get_in(meta, ["ec", "block_size"])
              {first, last} = normalize_range(range, size)

              if size == 0 or last < first do
                {:ok, []}
              else
                {:ok,
                 stream_object(
                   c,
                   bucket,
                   key,
                   version_id,
                   tx,
                   dirs,
                   meta,
                   block_size,
                   first,
                   last
                 )}
              end

            {:error, :enoent} ->
              {:error, :enoent}
          end
        end
    end
  end

  defp normalize_range(nil, size), do: {0, max(size - 1, 0)}
  defp normalize_range({first, last}, _size), do: {first, last}

  # 逐 block 跨节点并行读 K 存活分片、校验+重建、裁剪到 [first,last]，发出。
  # 控制流与 M6 stream_object/8 逐字一致；仅 read_shard 换成 read_block_shards（transport）。
  defp stream_object(cfg, bucket, key, version_id, tx, dirs, meta, block_size, first, last) do
    n = Config.total(cfg)
    shards_meta = meta["shards"]
    size = meta["size"]
    shard_len = block_shard_len(meta, cfg)
    first_block = div(first, block_size)
    last_block = div(last, block_size)

    Stream.resource(
      fn -> first_block end,
      fn
        j when j > last_block ->
          {:halt, j}

        j ->
          block_plain_len = block_plain_len(size, block_size, j)
          shards = read_block_shards(tx, dirs, shards_meta, j, shard_len, n)
          checksums = block_checksums(shards_meta, n, j)

          plain =
            Codec.restore_block(cfg, shards, checksums, block_plain_len,
              bucket: bucket,
              key: key,
              version_id: version_id,
              block_index: j
            )

          block_start = j * block_size
          lo = max(first, block_start) - block_start
          hi = min(last, block_start + block_plain_len - 1) - block_start
          out = binary_part(plain, lo, hi - lo + 1)
          {[out], j + 1}
      end,
      fn _j -> :ok end
    )
  end

  # 读 block j 的 N 个分片（跨节点并行；宕机/超时端点 -> nil）。保序（索引 i = 分片 i）。
  defp read_block_shards(tx, dirs, shards_meta, j, shard_len, n) do
    0..(n - 1)
    |> Enum.zip(dirs)
    |> Task.async_stream(
      fn {i, {node, dir}} ->
        drive_meta = Enum.at(shards_meta, i)

        if drive_meta && j < length(drive_meta["block_hashes"]) do
          tx.get_shard(node, dir, j, shard_len)
        else
          nil
        end
      end,
      timeout: :infinity,
      max_concurrency: n,
      on_timeout: :kill_task
    )
    |> Enum.map(fn
      {:ok, shard} -> shard
      {:exit, _} -> nil
    end)
  end

  # block j 的 N 个存储校验和（来自 sidecar；缺位补 32 个 0 -> 必不匹配 -> 当缺失）。与 M6 逐字一致。
  defp block_checksums(shards_meta, n, j) do
    for i <- 0..(n - 1) do
      drive_meta = Enum.at(shards_meta, i)
      hex = drive_meta && Enum.at(drive_meta["block_hashes"], j)

      case hex && Base.decode16(hex, case: :lower) do
        {:ok, raw} -> raw
        _ -> <<0::256>>
      end
    end
  end

  defp block_shard_len(meta, cfg) do
    block_size = get_in(meta, ["ec", "block_size"]) || cfg.block_size

    meta["shards"]
    |> Enum.find_value(fn s ->
      bh = s["block_hashes"]

      if is_list(bh) and length(bh) > 0 and s["shard_file_size"] > 0 do
        div(s["shard_file_size"], length(bh))
      end
    end) || div(block_size + cfg.data_shards - 1, cfg.data_shards)
  end

  defp block_plain_len(size, block_size, j) do
    num_blocks = div(size + block_size - 1, block_size)

    cond do
      num_blocks == 0 -> 0
      j < num_blocks - 1 -> block_size
      true -> size - (num_blocks - 1) * block_size
    end
  end

  # ── stat / delete / bucket ──

  defp do_stat(bucket, key, version_id, opts) do
    case Paths.object_rel(bucket, key, version_id) do
      {:error, :invalid_key} ->
        {:error, :invalid_key}

      {:ok, obj_rel} ->
        with {:ok, endpoints} <- endpoints_for(bucket, key, opts) do
          dirs = endpoint_dirs(endpoints, obj_rel)
          tx = transport(opts)

          case read_any_sidecar(tx, dirs) do
            {:ok, meta} -> {:ok, %{size: meta["size"]}}
            {:error, :enoent} -> {:error, :enoent}
          end
        end
    end
  end

  defp do_delete(bucket, key, version_id, opts) do
    case Paths.object_rel(bucket, key, version_id) do
      {:error, :invalid_key} ->
        {:error, :invalid_key}

      {:ok, obj_rel} ->
        with {:ok, endpoints} <- endpoints_for(bucket, key, opts) do
          dirs = endpoint_dirs(endpoints, obj_rel)
          tx = transport(opts)

          # 不自持对象锁（B1-1：锁由 handler 层 Maxio.Lock 横跨提交 seam 单点持有）。
          Enum.each(dirs, fn {node, dir} -> tx.delete_shard(node, dir) end)
          :ok
        end
    end
  end

  # 桶在每端点（全 set 的全端点并集）建 bucket 目录。put_bucket 不路由（桶在所有 set 都需有目录）。
  defp do_put_bucket(bucket, opts) do
    tx = transport(opts)

    all_endpoint_dirs(bucket, opts)
    |> Enum.each(fn {node, dir} -> tx.put_sidecar(node, mkdir_marker(dir), %{}) end)

    :ok
  end

  defp do_delete_bucket(bucket, opts) do
    tx = transport(opts)

    all_endpoint_dirs(bucket, opts)
    |> Enum.each(fn {node, dir} -> tx.delete_shard(node, mkdir_marker(dir)) end)

    :ok
  end

  # 全部 set 的全部端点的「桶根目录」（bucket 在每端点 drive 下一目录）。
  defp all_endpoint_dirs(bucket, opts) do
    set_ids =
      case topology(opts) do
        nil -> Topology.all_set_ids()
        t -> Topology.all_set_ids_from(t)
      end

    set_ids
    |> Enum.flat_map(fn set_id ->
      eps =
        case topology(opts) do
          nil -> Topology.endpoints(set_id)
          t -> Topology.endpoints_from(t, set_id)
        end

      Enum.map(eps, fn {node, drive} -> {node, Path.join(drive, bucket)} end)
    end)
    |> Enum.uniq()
  end

  # 桶目录用一个 .keep 标记的 sidecar 占位（put_bucket 只是建目录；delete_bucket 删之）。
  defp mkdir_marker(dir), do: Path.join(dir, ".keep")

  # ── parts（put_part / get_part_stream / assemble / abort）──

  defp do_put_part(bucket, _key, upload_id, part_number, chunks, opts) do
    part_rel = Paths.part_rel(bucket, upload_id, part_number)
    c = cfg(opts)

    with {:ok, endpoints} <- endpoints_for_upload_write(bucket, upload_id, opts) do
      tx = transport(opts)
      commit_targets = begin_commit_targets(tx, endpoints, part_rel)
      tmp_dirs = ordered_tmp_dirs(commit_targets)

      try do
        n = Config.total(c)

        acc0 = %{
          md5: :crypto.hash_init(:md5),
          sha: nil,
          size: 0,
          shard_len: nil,
          block_hashes: List.duplicate([], n),
          buffer: <<>>,
          block_index: 0,
          dirs: tmp_dirs,
          tx: tx
        }

        acc = Enum.reduce(chunks, acc0, fn chunk, acc -> feed_part(c, acc, chunk) end)
        acc = flush_final(c, acc)

        md5_raw = :crypto.hash_final(acc.md5)
        etag = Base.encode16(md5_raw, case: :lower)
        shard_len = acc.shard_len || 0

        meta =
          build_part_meta(
            c,
            acc.size,
            etag,
            shard_len,
            Enum.map(acc.block_hashes, &Enum.reverse/1)
          )

        result = %{size: acc.size, etag: etag, md5_raw: md5_raw}
        extra = run_before_part_commit!(opts, result)
        _ = write_sidecars(tx, tmp_dirs, meta)

        case commit_part_replace(tx, commit_targets, c.write_quorum, opts) do
          :ok ->
            {:ok, Map.merge(result, extra)}

          {:error, :write_quorum} ->
            {:error, :write_quorum}
        end
      rescue
        err ->
          cleanup_tmps(tx, commit_targets)
          reraise(err, __STACKTRACE__)
      catch
        kind, reason ->
          cleanup_tmps(tx, commit_targets)
          :erlang.raise(kind, reason, __STACKTRACE__)
      end
    end
  end

  # 与 feed/3 同，但只更新 MD5（part 不需 sha256）。
  defp feed_part(cfg, acc, chunk) do
    acc = %{
      acc
      | md5: :crypto.hash_update(acc.md5, chunk),
        size: acc.size + byte_size(chunk),
        buffer: acc.buffer <> chunk
    }

    drain_full_blocks(cfg, acc)
  end

  defp build_part_meta(cfg, size, etag, shard_len, block_hashes_per_drive) do
    n = Config.total(cfg)

    shards =
      for i <- 0..(n - 1) do
        hashes = Enum.at(block_hashes_per_drive, i)
        %{"drive" => i, "shard_file_size" => length(hashes) * shard_len, "block_hashes" => hashes}
      end

    %{
      "ec" => %{
        "k" => cfg.data_shards,
        "m" => cfg.parity_shards,
        "block_size" => cfg.block_size,
        "algo" => "blake3-256"
      },
      "size" => size,
      "etag" => etag,
      "parts" => [%{"part" => 0, "size" => size}],
      "shards" => shards
    }
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

  defp do_get_part_stream(bucket, _key, upload_id, part_number, opts) do
    part_rel = Paths.part_rel(bucket, upload_id, part_number)
    c = cfg(opts)

    with {:ok, endpoints} <- endpoints_for_upload(bucket, upload_id, opts) do
      dirs = endpoint_dirs(endpoints, part_rel)
      tx = transport(opts)

      case read_any_sidecar(tx, dirs) do
        {:ok, meta} ->
          size = meta["size"]
          block_size = get_in(meta, ["ec", "block_size"])

          if size == 0 do
            {:ok, []}
          else
            {:ok,
             stream_object(
               c,
               bucket,
               "#{upload_id}/#{part_number}",
               "null",
               tx,
               dirs,
               meta,
               block_size,
               0,
               size - 1
             )}
          end

        {:error, :enoent} ->
          {:error, :enoent}
      end
    end
  end

  defp do_assemble(bucket, key, upload_id, part_numbers, opts) do
    version_id = Keyword.get(opts, :version_id, "null")

    case Paths.object_rel(bucket, key, version_id) do
      {:error, :invalid_key} ->
        {:error, :invalid_key}

      {:ok, obj_rel} ->
        # 不自持对象锁（B1-1：锁由 handler 层 Maxio.Lock 横跨 assemble 字节 + put_metadata 元数据单点持有）。
        case endpoints_with_write_placement(bucket, key, opts) do
          {:ok, {endpoints, placement}} ->
            assemble_locked(
              bucket,
              key,
              upload_id,
              version_id,
              obj_rel,
              part_numbers,
              opts,
              endpoints,
              placement
            )

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  defp assemble_locked(
         bucket,
         key,
         upload_id,
         version_id,
         obj_rel,
         part_numbers,
         opts,
         endpoints,
         placement
       ) do
    c = cfg(opts)
    tx = transport(opts)
    n = Config.total(c)

    # B1-2 原子提交：组装的对象同样先写各端点 temp obj-dir，commit 数据先于元数据原子 rename 到 final。
    commit_targets = begin_commit_targets(tx, endpoints, obj_rel)
    tmp_dirs = ordered_tmp_dirs(commit_targets)

    acc0 = %{
      md5: :crypto.hash_init(:md5),
      sha: :crypto.hash_init(:sha256),
      size: 0,
      shard_len: nil,
      block_hashes: List.duplicate([], n),
      buffer: <<>>,
      block_index: 0,
      dirs: tmp_dirs,
      tx: tx
    }

    # 逐 part 解码（跨节点读）-> 喂入对象编码流（块接块流式，绝不缓冲整对象）。
    acc =
      Enum.reduce(part_numbers, acc0, fn pn, acc ->
        {:ok, part_stream} = do_get_part_stream(bucket, key, upload_id, pn, opts)
        Enum.reduce(part_stream, acc, fn chunk, a -> feed(c, a, chunk) end)
      end)

    acc = flush_final(c, acc)

    etag = acc.md5 |> :crypto.hash_final() |> Base.encode16(case: :lower)
    sha256 = acc.sha |> :crypto.hash_final() |> Base.encode16(case: :lower)
    shard_len = acc.shard_len || 0

    result = %{
      size: acc.size,
      etag: etag,
      sha256: sha256,
      placement_set_id: placement.set_id,
      placement_pool_id: placement.pool_id,
      placement_topology_hash: placement.topology_hash
    }

    extra = run_before_object_commit!(opts, result)

    # 多段 assemble 的最终对象落 opts[:version_id] 指定布局（缺省 null）；同样产 maxio/2 sidecar
    # 使其 sidecar-可读/可列。ROUTE B B4-6 D1：透传 assemble 的 opts（携 opts[:object_meta]，由
    # Multipart.complete 从 upload 会话取 content_type/user_metadata 构造），version_opts 据此自描述
    # 真实 content_type/user_metadata（替换原硬编码 []，消除多段 :sidecar 读 content-type 错误）。
    meta =
      build_meta(
        c,
        version_id,
        opts_with_commit_extra(opts, extra),
        acc.size,
        etag,
        sha256,
        shard_len,
        Enum.map(acc.block_hashes, &Enum.reverse/1)
      )

    _ = write_sidecars(tx, tmp_dirs, meta)

    ok_endpoints = commit_all(tx, commit_targets, opts)

    if ok_endpoints >= c.write_quorum do
      {:ok, Map.merge(result, extra)}
    else
      Logger.error("distributed assemble below write quorum",
        bucket: bucket,
        key: key,
        reason: "ok_endpoints=#{ok_endpoints} < write_quorum=#{c.write_quorum}"
      )

      cleanup_tmp(tx, commit_targets)
      {:error, :write_quorum}
    end
  end

  defp do_abort_upload(bucket, _key, upload_id, opts) do
    upload_rel = Paths.upload_rel(bucket, upload_id)

    with {:ok, endpoints} <- endpoints_for_upload(bucket, upload_id, opts) do
      dirs = endpoint_dirs(endpoints, upload_rel)
      tx = transport(opts)
      Enum.each(dirs, fn {node, dir} -> tx.delete_shard(node, dir) end)
      :ok
    end
  end

  # ── delete marker 落盘（ROUTE B B5-0；B5-3 R2 非破坏化）──
  # 在 version_id 对应盘上对象目录写**纯 delete-marker maxio/2 sidecar**（无 part.0、无 ec/shards
  # core），与 PUT 同级 B1-2 原子提交。单次 build_delete_marker_meta、同一份 meta 发所有端点 →
  # N 份 signature 一致。
  #
  # B5-3 R2 —— marker 提交是对 final 的**替换**（Suspended null 路径的 final 可能持有既有 null 版本，
  # meta_only commit 原子 rename meta.json 覆盖旧 sidecar 即「替换」语义），故与 do_put 的
  # 「quorum 失败 ⇒ 新对象不存在」回滚不变量不同——此处**任何失败路径都绝不删 final**（删 final =
  # 摧毁被替换的旧版本，制造裸 404 破坏窗口）：
  #   1) pre-commit quorum 闸：temp sidecar 成功写出的端点数 < write_quorum → 在触碰任何 final 之前
  #      中止（只清 temp）→ 503 后旧版本全端点完好（GET 仍 200），重试收敛；
  #   2) commit 后仍 < quorum（罕见：rename 级失败）→ 只清 temp；已 commit 端点留部分 marker
  #      （< quorum 不构成读权威），由重试/heal 收敛（Logger.error 留痕，铁律 3 不静默）；
  #   3) quorum 成功 → best-effort GC final 里的孤儿 part.0（delete-marker 版本目录里任何 part.0
  #      定义上都是被替换 null 版本的孤儿字节；transport delete_shard 契约幂等/自吞，残余孤儿归
  #      heal/reverse-GC 渠道）。
  defp do_put_delete_marker(bucket, key, version_id, entry_opts, opts) do
    case Paths.object_rel(bucket, key, version_id) do
      {:error, :invalid_key} ->
        {:error, :invalid_key}

      {:ok, obj_rel} ->
        c = cfg(opts)

        with {:ok, endpoints} <- endpoints_for_write(bucket, key, opts) do
          tx = transport(opts)

          commit_targets = begin_commit_targets(tx, endpoints, obj_rel)
          tmp_dirs = ordered_tmp_dirs(commit_targets)
          meta = build_delete_marker_meta(version_id, entry_opts)

          prepared = write_sidecars(tx, tmp_dirs, meta)

          if prepared < c.write_quorum do
            Logger.error("distributed put_delete_marker below write quorum (pre-commit)",
              bucket: bucket,
              key: key,
              reason: "prepared=#{prepared} < write_quorum=#{c.write_quorum}"
            )

            cleanup_tmps(tx, commit_targets)
            {:error, :write_quorum}
          else
            # 纯元数据提交声明（ShardServer.commit/3 :meta_only）：temp 只有 meta.json 无 part.0 →
            # 跳过 part rename 只提交 meta.json（仍 fsync + 原子 rename + sync dir）。
            ok_endpoints = commit_all(tx, commit_targets, Keyword.put(opts, :meta_only, true))

            if ok_endpoints >= c.write_quorum do
              gc_orphan_parts(tx, commit_targets)
              :ok
            else
              Logger.error("distributed put_delete_marker below write quorum",
                bucket: bucket,
                key: key,
                reason: "ok_endpoints=#{ok_endpoints} < write_quorum=#{c.write_quorum}"
              )

              cleanup_tmps(tx, commit_targets)
              {:error, :write_quorum}
            end
          end
        end
    end
  end

  # B5-3 R2：只清本次写参与端点的 temp obj-dir，**绝不触碰 final**（替换式提交的失败回滚专用；
  # 与 cleanup_tmp/2 的「删 temp + final」语义相区分——那是 do_put/assemble 新对象落点的不变量）。
  defp cleanup_tmps(tx, targets) do
    targets
    |> Enum.filter(& &1.tmp_dir)
    |> Enum.each(fn %{node: node, tmp_dir: tmp} -> tx.delete_shard(node, tmp) end)
  end

  defp commit_part_replace(tx, targets, write_quorum, opts) do
    case backup_existing_targets(tx, targets) do
      {:ok, backups} ->
        commit_part_replace_with_backups(tx, targets, backups, write_quorum, opts)

      {:error, :write_quorum} ->
        cleanup_tmps(tx, targets)
        {:error, :write_quorum}
    end
  end

  # Only endpoints with a temp directory can participate in this commit. Down
  # endpoints are deliberately not backed up or touched, so their old final
  # remains available while the live endpoints establish write quorum.
  defp commit_object_replace(tx, targets, write_quorum, opts, control, identity) do
    participants = Enum.filter(targets, & &1.tmp_dir)

    with {:ok, plans} <- plan_distributed_backups(tx, participants),
         :ok <-
           Control.register(
             control,
             identity,
             fn -> rollback_distributed_plans(tx, plans, identity) end,
             fn -> discard_distributed_plans(tx, plans) end
           ),
         :ok <- materialize_distributed_plans(tx, plans) do
      results = commit_all_results(tx, targets, opts)
      ok_endpoints = Enum.count(results, fn {_target, ok?} -> ok? end)

      if ok_endpoints >= write_quorum do
        rollback_failed_distributed_plans(tx, results, plans, identity)
        cleanup_tmps(tx, targets)
        :ok
      else
        {:error, :write_quorum}
      end
    else
      {:error, _reason} = error -> error
    end
  end

  defp plan_distributed_backups(tx, targets) do
    Enum.reduce_while(targets, {:ok, []}, fn target, {:ok, acc} ->
      case tx.get_sidecar(target.node, target.final_dir) do
        {:ok, meta} ->
          with {:ok, backup_dir} <- tx.begin_tmp(target.node, target.drive) do
            names =
              case Sidecar.latest(meta) do
                %{"type" => "object"} -> [@part_file, @meta_file]
                %{"type" => "delete_marker"} -> [@meta_file]
                _invalid_or_legacy -> [@part_file, @meta_file]
              end

            plan = %{
              node: target.node,
              final_dir: target.final_dir,
              backup_dir: backup_dir,
              entries:
                Enum.map(names, fn name ->
                  {Path.join(target.final_dir, name), Path.join(backup_dir, name)}
                end),
              old_identity: {:ok, Map.get(meta, "object_commit_identity")}
            }

            {:cont, {:ok, [plan | acc]}}
          else
            {:error, _reason} ->
              _ = discard_distributed_plans(tx, acc)
              {:halt, {:error, :write_quorum}}
          end

        {:error, :enoent} ->
          plan = %{
            node: target.node,
            final_dir: target.final_dir,
            backup_dir: nil,
            entries: [],
            old_identity: {:error, :enoent}
          }

          {:cont, {:ok, [plan | acc]}}

        {:error, _reason} ->
          _ = discard_distributed_plans(tx, acc)
          {:halt, {:error, :write_quorum}}
      end
    end)
    |> case do
      {:ok, plans} -> {:ok, Enum.reverse(plans)}
      {:error, _reason} = error -> error
    end
  end

  defp materialize_distributed_plans(tx, plans) do
    Enum.reduce_while(plans, :ok, fn plan, :ok ->
      result =
        Enum.reduce_while(plan.entries, :ok, fn {source, backup}, :ok ->
          case tx.move_shard(plan.node, source, backup, []) do
            :ok -> {:cont, :ok}
            {:error, reason} -> {:halt, {:error, reason}}
          end
        end)

      case result do
        :ok -> {:cont, :ok}
        {:error, _reason} -> {:halt, {:error, :write_quorum}}
      end
    end)
  end

  defp rollback_failed_distributed_plans(tx, results, plans, identity) do
    plans_by_target = Map.new(plans, &{{&1.node, &1.final_dir}, &1})

    Enum.each(results, fn
      {_target, true} ->
        :ok

      {%{tmp_dir: nil}, false} ->
        :ok

      {%{node: node, final_dir: final}, false} ->
        _ = rollback_distributed_plan(tx, Map.fetch!(plans_by_target, {node, final}), identity)
    end)
  end

  defp rollback_distributed_plans(tx, plans, identity) do
    Enum.reduce_while(plans, :ok, fn plan, :ok ->
      case rollback_distributed_plan(tx, plan, identity) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp rollback_distributed_plan(tx, plan, identity) do
    current = distributed_commit_identity(tx, plan.node, plan.final_dir)

    cond do
      plan.backup_dir == nil and current == {:ok, identity} ->
        remove_distributed_object_files(tx, plan)

      plan.backup_dir == nil and current == {:error, :enoent} ->
        remove_distributed_object_files(tx, plan)

      plan.backup_dir == nil ->
        :ok

      current == {:ok, identity} ->
        remove_distributed_object_files(tx, plan)
        restore_distributed_entries(tx, plan)

      current == plan.old_identity ->
        restore_distributed_entries(tx, plan)

      current == {:error, :enoent} ->
        remove_distributed_object_files(tx, plan)
        restore_distributed_entries(tx, plan)

      match?({:ok, _successor}, current) ->
        discard_distributed_plan(tx, plan)

      true ->
        {:error, :write_quorum}
    end
  end

  defp distributed_commit_identity(tx, node, final) do
    case tx.get_sidecar(node, final) do
      {:ok, meta} -> {:ok, Map.get(meta, "object_commit_identity")}
      {:error, :enoent} -> {:error, :enoent}
      {:error, _reason} -> {:error, :unavailable}
    end
  end

  defp restore_distributed_entries(tx, plan) do
    result =
      Enum.reduce_while(plan.entries, :ok, fn {source, backup}, :ok ->
        case tx.move_shard(plan.node, backup, source, []) do
          :ok -> {:cont, :ok}
          {:error, :enoent} -> {:cont, :ok}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)

    case result do
      :ok -> discard_distributed_plan(tx, plan)
      {:error, _reason} = error -> error
    end
  end

  defp remove_distributed_object_files(tx, plan) do
    _ = tx.delete_shard(plan.node, Path.join(plan.final_dir, @part_file))
    _ = tx.delete_shard(plan.node, Path.join(plan.final_dir, @meta_file))
    :ok
  end

  defp discard_distributed_plans(tx, plans) do
    Enum.each(plans, &discard_distributed_plan(tx, &1))
    :ok
  end

  defp discard_distributed_plan(_tx, %{backup_dir: nil}), do: :ok
  defp discard_distributed_plan(tx, plan), do: tx.delete_shard(plan.node, plan.backup_dir)

  defp commit_part_replace_with_backups(tx, targets, backups, write_quorum, opts) do
    try do
      results = commit_all_results(tx, targets, opts)
      ok_endpoints = Enum.count(results, fn {_target, ok?} -> ok? end)

      if ok_endpoints >= write_quorum do
        cleanup_failed_part_finals(tx, results)
        cleanup_tmps(tx, targets)
        cleanup_backups(tx, backups)
        :ok
      else
        restore_part_backups(tx, targets, backups)
        {:error, :write_quorum}
      end
    rescue
      err ->
        restore_part_backups(tx, targets, backups)
        reraise(err, __STACKTRACE__)
    catch
      kind, reason ->
        restore_part_backups(tx, targets, backups)
        :erlang.raise(kind, reason, __STACKTRACE__)
    end
  end

  defp cleanup_failed_part_finals(tx, results) do
    Enum.each(results, fn
      {_target, true} -> :ok
      {%{node: node, final_dir: final}, false} -> tx.delete_shard(node, final)
      {_target, false} -> :ok
    end)
  end

  defp backup_existing_targets(tx, targets) do
    do_backup_existing_targets(tx, targets, [])
  end

  defp do_backup_existing_targets(_tx, [], acc), do: {:ok, Enum.reverse(acc)}

  defp do_backup_existing_targets(tx, [target | rest], acc) do
    case backup_existing_target(tx, target) do
      {:ok, entry} ->
        do_backup_existing_targets(tx, rest, [entry | acc])

      {:error, _reason} ->
        restore_part_backups(tx, [], Enum.reverse(acc))
        {:error, :write_quorum}
    end
  end

  defp backup_existing_target(tx, %{node: node, drive: drive, final_dir: final}) do
    case tx.get_sidecar(node, final) do
      {:ok, _meta} ->
        with {:ok, backup} <- tx.begin_tmp(node, drive) do
          case tx.move_shard(node, final, backup, []) do
            :ok ->
              {:ok, %{node: node, final_dir: final, backup_dir: backup}}

            {:error, :enoent} ->
              tx.delete_shard(node, backup)
              {:ok, %{node: node, final_dir: final, backup_dir: nil}}

            {:error, reason} ->
              tx.delete_shard(node, backup)
              {:error, reason}
          end
        end

      {:error, :enoent} ->
        {:ok, %{node: node, final_dir: final, backup_dir: nil}}

      {:error, _reason} ->
        {:error, :write_quorum}
    end
  end

  defp cleanup_backups(tx, backups) do
    Enum.each(backups, fn
      %{backup_dir: nil} -> :ok
      %{node: node, backup_dir: backup} -> tx.delete_shard(node, backup)
    end)
  end

  defp restore_part_backups(tx, targets, backups) do
    cleanup_tmps(tx, targets)

    targets
    |> Enum.filter(& &1.tmp_dir)
    |> Enum.each(fn %{node: node, final_dir: final} -> tx.delete_shard(node, final) end)

    Enum.each(backups, fn
      %{backup_dir: nil} ->
        :ok

      %{node: node, final_dir: final, backup_dir: backup} ->
        _ = tx.move_shard(node, backup, final, [])
    end)
  end

  # B5-3 R2：marker quorum 成功后 best-effort GC 各端点 final 里被替换 null 版本的孤儿 part.0
  # （delete marker 无字节，其版本目录里任何 part.0 定义上都是孤儿）。delete_shard 契约幂等且把
  # 宕机塌缩为 :ok（best-effort by contract），残余孤儿归既有 heal/reverse-GC 渠道。
  defp gc_orphan_parts(tx, targets) do
    Enum.each(targets, fn %{node: node, final_dir: final} ->
      _ = tx.delete_shard(node, Path.join(final, @part_file))
    end)
  end

  # ROUTE B B5-0：纯 delete-marker maxio/2 sidecar（无字节、无耐久 core）。与 ErasureCoded 同源
  # （Maxio.Storage.DeleteMarker.sidecar/2，单一形态来源）；modtime 单次计算所有端点同值 → signature 一致。
  defp build_delete_marker_meta(version_id, entry_opts) do
    Maxio.Storage.DeleteMarker.sidecar(version_id, entry_opts)
  end

  # ── DELETE ?versionId 的权威 quorum 删除（ROUTE B fidelity，Backend.delete_version/4 契约）──
  #
  # 与 do_delete 的 best-effort 清理删除不同：每端点删版本 obj-dir 后经 list_dir 探针**确认**
  # 「端点可达且版本目录显式 missing」（transport 的 delete_shard 把宕机塌缩成 :ok——契约如此，
  # 故确认必须经 list_dir 的结构性 {:error,:unavailable}，与 Maxio.Storage.Scanner.probe_endpoint
  # 同源判定，铁律 3 绝不把不可达当已删除）。确认数 >= write_quorum → :ok；否则
  # {:error, :write_quorum}（绝不静默成功——否则 scanner forward 会从幸存 sidecar 复活该版本）。
  # 幂等：版本本就缺失的端点同样计入确认。
  defp do_delete_version(bucket, key, version_id, opts) do
    case Paths.object_rel(bucket, key, version_id) do
      {:error, :invalid_key} ->
        {:error, :invalid_key}

      {:ok, obj_rel} ->
        c = cfg(opts)
        tx = transport(opts)

        with {:ok, endpoints} <- endpoints_for(bucket, key, opts) do
          confirmed =
            Enum.count(endpoints, fn {node, drive} ->
              dir = Path.join(drive, obj_rel)
              _ = tx.delete_shard(node, dir)
              version_deleted?(tx, node, dir)
            end)

          if confirmed >= c.write_quorum do
            :ok
          else
            Logger.error("distributed delete_version below write quorum",
              bucket: bucket,
              key: key,
              reason:
                "confirmed=#{confirmed} < write_quorum=#{c.write_quorum} version_id=#{version_id}"
            )

            {:error, :write_quorum}
          end
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
         {:ok, endpoints} <- endpoints_for_write(bucket, key, opts) do
      c = cfg(opts)
      tx = transport(opts)
      rel = Paths.notification_ledger_entry_rel(bucket, key, id)
      commit_targets = begin_commit_targets(tx, endpoints, rel)
      tmp_dirs = ordered_tmp_dirs(commit_targets)
      prepared = write_sidecars(tx, tmp_dirs, NotificationLedger.sidecar(entry))

      if prepared < c.write_quorum do
        Logger.error("distributed notification ledger below write quorum (pre-commit)",
          bucket: bucket,
          key: key,
          reason: "prepared=#{prepared} < write_quorum=#{c.write_quorum}"
        )

        cleanup_tmps(tx, commit_targets)
        {:error, :write_quorum}
      else
        ok_endpoints = commit_all(tx, commit_targets, Keyword.put(opts, :meta_only, true))

        if ok_endpoints >= c.write_quorum do
          :ok
        else
          Logger.error("distributed notification ledger below write quorum",
            bucket: bucket,
            key: key,
            reason: "ok_endpoints=#{ok_endpoints} < write_quorum=#{c.write_quorum}"
          )

          cleanup_tmp(tx, commit_targets)
          {:error, :write_quorum}
        end
      end
    end
  end

  defp do_list_notification_ledgers(bucket, :all, opts) do
    tx = transport(opts)
    read_quorum = cfg(opts).read_quorum

    with {:ok, replicas} <-
           read_notification_ledger_replicas(all_endpoints(opts), fn {node, drive} ->
             read_notification_ledger_replicas_under(
               tx,
               node,
               Path.join(drive, Paths.notification_ledger_bucket_rel(bucket)),
               bucket: bucket
             )
           end) do
      {:ok, NotificationLedger.canonical_entries(replicas, read_quorum)}
    end
  end

  defp do_list_notification_ledgers(bucket, key, opts) when is_binary(key) do
    tx = transport(opts)
    read_quorum = cfg(opts).read_quorum

    with {:ok, replicas} <-
           read_notification_ledger_replicas(all_endpoints(opts), fn {node, drive} ->
             read_notification_ledger_replicas_under(
               tx,
               node,
               Path.join(drive, Paths.notification_ledger_key_rel(bucket, key)),
               bucket: bucket,
               key: key
             )
           end) do
      {:ok, NotificationLedger.canonical_entries(replicas, read_quorum)}
    end
  end

  defp do_delete_notification_ledgers(_bucket, _key, [], _opts), do: :ok

  defp do_delete_notification_ledgers(bucket, key, ids, opts) when is_list(ids) do
    with {:ok, ids} <- notification_ledger_ids(ids) do
      tx = transport(opts)
      endpoints = all_endpoints(opts)

      Enum.each(ids, fn id ->
        rel = Paths.notification_ledger_entry_rel(bucket, key, id)
        Enum.each(endpoints, fn {node, drive} -> tx.delete_shard(node, Path.join(drive, rel)) end)
      end)

      :ok
    end
  end

  # 单端点删除确认探针：列版本目录的父目录——可达（{:ok, entries}，目录不存在为 {:ok,[]}）且无
  # 「名为版本末段且含 meta.json（object?=true）」的子目录 = 确认已删除；{:error,_}（宕机/异常）=
  # 不可达，绝不计入确认。
  defp version_deleted?(tx, node, dir) do
    parent = Path.dirname(dir)
    base = Path.basename(dir)

    case tx.list_dir(node, parent, []) do
      {:ok, entries} -> not Enum.any?(entries, &(&1.name == base and &1.object?))
      {:error, _} -> false
    end
  end

  # ── 辅助 ──

  defp all_endpoints(opts) do
    set_ids =
      case topology(opts) do
        nil -> Topology.all_set_ids()
        t -> Topology.all_set_ids_from(t)
      end

    set_ids
    |> Enum.flat_map(fn set_id -> endpoints_for_set(set_id, opts) end)
    |> Enum.uniq()
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

  defp read_notification_ledger_replicas(items, fun) do
    Enum.reduce_while(items, {:ok, []}, fn item, {:ok, acc} ->
      case fun.(item) do
        {:ok, replicas} -> {:cont, {:ok, replicas ++ acc}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, replicas} -> {:ok, Enum.reverse(replicas)}
      {:error, _reason} = err -> err
    end
  end

  defp read_notification_ledger_replicas_under(tx, node, root, context) do
    case tx.list_dir(node, root, []) do
      {:ok, entries} ->
        Enum.reduce_while(entries, {:ok, []}, fn entry, {:ok, acc} ->
          path = Path.join(root, entry.name)

          if entry.object? do
            case read_notification_ledger_replica(tx, node, path, context) do
              {:ok, replicas} -> {:cont, {:ok, replicas ++ acc}}
              {:error, reason} -> {:halt, {:error, reason}}
            end
          else
            case read_notification_ledger_replicas_under(tx, node, path, context) do
              {:ok, replicas} -> {:cont, {:ok, replicas ++ acc}}
              {:error, reason} -> {:halt, {:error, reason}}
            end
          end
        end)
        |> case do
          {:ok, replicas} -> {:ok, Enum.reverse(replicas)}
          {:error, _reason} = err -> err
        end

      {:error, reason} ->
        {:error, {:notification_ledger_list_failed, node, root, reason}}
    end
  end

  defp read_notification_ledger_replica(tx, node, dir, context) do
    case tx.get_sidecar(node, dir) do
      {:ok, meta} ->
        {:ok, decode_notification_ledger_replica(meta, dir, context)}

      {:error, reason} ->
        {:error, {:notification_ledger_read_failed, node, dir, reason}}
    end
  rescue
    error ->
      {:error, {:notification_ledger_read_failed, node, dir, error}}
  catch
    kind, reason ->
      {:error, {:notification_ledger_read_failed, node, dir, {kind, reason}}}
  end

  defp decode_notification_ledger_replica(meta, dir, context) do
    with {:ok, entry} <- NotificationLedger.entry(meta),
         {:ok, id} <- NotificationLedger.validate_id(NotificationLedger.id(entry)) do
      [{id, entry}]
    else
      _ ->
        [invalid_notification_ledger_replica(dir, context)]
    end
  end

  defp invalid_notification_ledger_replica(dir, context) do
    path_id = Path.basename(dir)
    {path_id, NotificationLedger.invalid_entry(path_id, "invalid_meta", context)}
  end

  # 从任一存活端点读 sidecar（与 M6 read_any_sidecar 等价，跨节点版）。
  defp read_any_sidecar(tx, dirs) do
    Enum.find_value(dirs, {:error, :enoent}, fn {node, dir} ->
      case tx.get_sidecar(node, dir) do
        {:ok, meta} -> {:ok, meta}
        {:error, _} -> nil
      end
    end)
  end
end
