defmodule Maxio.Storage.ErasureCoded do
  @moduledoc """
  Reed-Solomon 纠删码存储后端（单机多盘 = 一个 erasure set），实现 Maxio.Storage.Backend 契约，
  与 Maxio.Storage.FS 返回形态逐字节一致（铁律 2：后端即插件，核心管线一行不改）。

  对象在每个盘 i 落成一个目录：part.0（盘 i 的分片字节，逐块流式追加）+ meta.json（per-object sidecar）。
  put 逐块流式编码（绝不缓冲整对象，铁律 4），分片 i 写盘 i + sidecar 写全部 N 盘，
  成功盘数 >= write_quorum 才 {:ok}，否则 {:error,:write_quorum}（铁律 3）。
  get 逐块读 K 个存活分片、按 sidecar 的 per-block BLAKE3 校验、重建、流式发出；
  存活 < K -> raise InsufficientShardsError（绝不静默返回错数据）。

  每个 callback 接受可选末参 opts（:drives 覆盖盘目录列表、:data_shards/:parity_shards/:block_size
  覆盖 EC 参数，便于测试隔离），缺省从 config :maxio, :erasure 读。
  """
  @behaviour Maxio.Storage.Backend

  require Logger

  alias Maxio.Storage.Erasure.{Codec, Config, Meta}
  alias Maxio.Cluster.{ShardServer, Transport}
  alias Maxio.Sidecar

  alias Maxio.Storage.{
    EpochStore,
    MutationBackup,
    MutationContext,
    NotificationLedger,
    ObjectCommit,
    ObjectEpoch,
    PublishedProof
  }

  alias Maxio.Storage.ObjectCommit.Control

  @meta_file "meta.json"
  @part_file "part.0"

  # ── Backend callbacks（签名与 FS 一致；opts 末参默认）──

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

  # ── 分段上传 parts 回调（M6-4）。part 分片落
  # <drive_i>/.uploads/<bucket>/<upload_id>/<n>/part.0 + meta.json；
  # assemble 逐 part 解码再重编码进对象 part.0；abort 跨盘删 upload 目录。──

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

  # ── ObjectMutation epoch CAS 回调（协议 §3.3，Phase 1 B3）：quorum 编排——per-endpoint
  # 原语（ShardServer.read_epoch/cas_epoch/restore_mutation/finalize_mutation）对 cfg.drives
  # 逐盘直调 + 三分类计数；epoch 破坏性 quorum = cfg.epoch_quorum（D4 多数派钳制，config.ex）。
  # drive_root 恒为 cfg.drives 元素原值透传（EpochStore 串行路由键按原始字符串 phash2，
  # 绝不自行拼接变体）。──

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

  # part 在盘 d 下的目录。
  defp part_dirs(bucket, upload_id, part_number, cfg) do
    sub = Path.join([".uploads", bucket, upload_id, Integer.to_string(part_number)])
    Enum.map(cfg.drives, &Path.join(&1, sub))
  end

  defp upload_dirs(bucket, upload_id, cfg) do
    sub = Path.join([".uploads", bucket, upload_id])
    Enum.map(cfg.drives, &Path.join(&1, sub))
  end

  defp do_put_part(bucket, _key, upload_id, part_number, chunks, opts) do
    cfg = Config.load!(opts)
    final_dirs = part_dirs(bucket, upload_id, part_number, cfg)
    commit_pairs = Enum.zip(cfg.drives, final_dirs)
    tmps = begin_tmp_dirs!(cfg.drives)

    try do
      fds = Enum.map(tmps, fn tmp -> open_write!(Path.join(tmp, @part_file)) end)

      acc =
        try do
          acc0 = %{
            md5: :crypto.hash_init(:md5),
            sha: nil,
            size: 0,
            shard_len: nil,
            block_hashes: List.duplicate([], Config.total(cfg)),
            buffer: <<>>,
            fds: fds
          }

          acc = Enum.reduce(chunks, acc0, fn chunk, acc -> feed_part(cfg, acc, chunk) end)
          flush_final(cfg, acc)
        after
          Enum.each(fds, &File.close/1)
        end

      md5_raw = :crypto.hash_final(acc.md5)
      etag = Base.encode16(md5_raw, case: :lower)
      shard_len = acc.shard_len || 0

      meta =
        build_part_meta(
          cfg,
          acc.size,
          etag,
          shard_len,
          Enum.map(acc.block_hashes, &Enum.reverse/1)
        )

      result = %{size: acc.size, etag: etag, md5_raw: md5_raw}
      extra = run_before_part_commit!(opts, result)
      write_tmp_sidecars(tmps, meta)

      case commit_part_replace(tmps, commit_pairs, cfg.write_quorum, opts) do
        :ok ->
          {:ok, Map.merge(result, extra)}

        {:error, :write_quorum} ->
          {:error, :write_quorum}
      end
    rescue
      err ->
        cleanup_tmps(tmps)
        reraise(err, __STACKTRACE__)
    catch
      kind, reason ->
        cleanup_tmps(tmps)
        :erlang.raise(kind, reason, __STACKTRACE__)
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

  defp do_get_part_stream(bucket, _key, upload_id, part_number, opts) do
    cfg = Config.load!(opts)
    dirs = part_dirs(bucket, upload_id, part_number, cfg)

    case read_any_sidecar(dirs) do
      {:ok, meta} ->
        size = meta["size"]
        block_size = get_in(meta, ["ec", "block_size"])

        if size == 0 do
          {:ok, []}
        else
          {:ok,
           stream_object(
             cfg,
             bucket,
             "#{upload_id}/#{part_number}",
             "null",
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

  # Phase 2A C6：与 do_put 同构改经 ObjectCommit.run 编排——staging = begin_tmp_dirs! + 逐 part
  # 解码重编码 + run_before_object_commit! + write_tmp_sidecars（object_meta 在此按
  # opts_with_commit_extra 合并 before_object_commit extra 后落盘，around 与 default 两条路径
  # 天然同一份 merge），publish = publish_staged_assemble（非协议走 commit_drives quorum 门；
  # commit_opts[:object_mutation] 存在时复用 publish_mutation_staged_put 四阶段协议分支）。
  # 不传协议 opt 的调用者行为逐字节不变。
  defp do_assemble(bucket, key, upload_id, part_numbers, opts) do
    cfg = Config.load!(opts)
    version_id = Keyword.get(opts, :version_id, "null")

    with {:ok, commit_pairs} <- commit_pairs(bucket, key, version_id, cfg) do
      # B1-2 原子提交：组装对象同样先写各盘 temp obj-dir，commit 数据先于元数据原子 rename 到 final。
      tmps =
        commit_pairs |> Enum.map(fn {drive_root, _final} -> drive_root end) |> begin_tmp_dirs!()

      try do
        fds = Enum.map(tmps, fn tmp -> open_write!(Path.join(tmp, @part_file)) end)

        acc =
          try do
            acc0 = %{
              md5: :crypto.hash_init(:md5),
              sha: :crypto.hash_init(:sha256),
              size: 0,
              shard_len: nil,
              block_hashes: List.duplicate([], Config.total(cfg)),
              buffer: <<>>,
              fds: fds
            }

            # 逐 part 解码 -> 喂入对象编码流（块接块流式）。
            acc =
              Enum.reduce(part_numbers, acc0, fn pn, acc ->
                {:ok, part_stream} = do_get_part_stream(bucket, key, upload_id, pn, opts)
                Enum.reduce(part_stream, acc, fn chunk, a -> feed(cfg, a, chunk) end)
              end)

            flush_final(cfg, acc)
          after
            Enum.each(fds, &File.close/1)
          end

        etag = acc.md5 |> :crypto.hash_final() |> Base.encode16(case: :lower)
        sha256 = acc.sha |> :crypto.hash_final() |> Base.encode16(case: :lower)
        shard_len = acc.shard_len || 0
        result = %{size: acc.size, etag: etag, sha256: sha256}
        extra = run_before_object_commit!(opts, result)
        prepared = Map.merge(result, extra)

        # 多段 assemble 的最终对象落 opts[:version_id] 指定布局（缺省 null）；同样产 maxio/2 sidecar
        # 使其 sidecar-可读/可列。ROUTE B B4-6 D1：透传 assemble 的 opts（携 opts[:object_meta]，由
        # Multipart.complete 从 upload 会话取 content_type/user_metadata 构造），version_opts 据此自描述
        # 真实 content_type/user_metadata（替换原硬编码 []，消除多段 :sidecar 读 content-type 错误）。
        meta =
          build_meta(
            cfg,
            version_id,
            opts_with_commit_extra(opts, extra),
            acc.size,
            etag,
            sha256,
            shard_len,
            Enum.map(acc.block_hashes, &Enum.reverse/1)
          )

        write_tmp_sidecars(tmps, meta)

        # assemble 的 version_id/object_meta 在 staging 期已由 opts 钉定（sidecar 已落盘），
        # default commit_opts 无需承载（publish 只消费 :object_mutation 与 Control 键）。
        ObjectCommit.run(
          opts,
          prepared,
          [],
          fn commit_opts ->
            publish_staged_assemble(
              tmps,
              commit_pairs,
              cfg,
              opts,
              version_id,
              prepared,
              commit_opts,
              bucket,
              key
            )
          end,
          fn -> cleanup_tmps(tmps) end
        )
      rescue
        err ->
          cleanup_tmps(tmps)
          reraise(err, __STACKTRACE__)
      catch
        kind, reason ->
          cleanup_tmps(tmps)
          :erlang.raise(kind, reason, __STACKTRACE__)
      end
    end
  end

  # assemble 的 publish 阶段（C6）。staging 已把各盘分片 + sidecar 写进 temp obj-dir，此处只做
  # final 提交编排：
  #   * 非协议（无 :object_mutation）：Control 注册 no-op rollback/finalize 后走现状
  #     commit_drives write_quorum 门（不足 → rollback_commit + {:error, :write_quorum}）。
  #     现状 assemble 本就无 identity 比对回滚语义，注册仅满足 ObjectCommit 收口契约
  #     （finalize 拒绝未注册）——行为逐字节不变；
  #   * 协议（%MutationContext{}）：复用 publish_mutation_staged_put 四阶段结构（每盘 manifest
  #     quorum 前置门 → 物化备份 → 逐盘 epoch CAS quorum 门（不足 → 不 rename、backup 保留）→
  #     仅 published 盘 commit_drives），错误形状沿 B3 契约（{:error, {:epoch_publish_quorum, _}} 等）。
  # commit_opts[:version_id] 仅作一致性校验：落点已在 staging 按 opts[:version_id] 钉定，
  # 不一致意味着 around 调用者与 staging 脱节（绝不静默改写落点，fail-loud 拒绝）。
  defp publish_staged_assemble(
         tmps,
         commit_pairs,
         cfg,
         opts,
         version_id,
         prepared,
         commit_opts,
         bucket,
         key
       ) do
    control = Keyword.fetch!(commit_opts, :object_commit_control)
    identity = Keyword.fetch!(commit_opts, :object_commit_identity)

    with :ok <- validate_assemble_version(commit_opts, version_id) do
      case Keyword.get(commit_opts, :object_mutation) do
        nil ->
          publish_controlled_assemble(
            tmps,
            commit_pairs,
            cfg,
            opts,
            prepared,
            control,
            identity,
            bucket,
            key
          )

        %MutationContext{} = ctx ->
          committed = Map.put(prepared, :version_id, version_id)

          publish_mutation_staged_put(
            tmps,
            commit_pairs,
            cfg,
            opts,
            committed,
            control,
            identity,
            ctx,
            bucket,
            key
          )

        invalid ->
          cleanup_tmps(tmps)
          {:error, {:invalid_object_mutation, invalid}}
      end
    else
      {:error, reason} ->
        cleanup_tmps(tmps)
        {:error, reason}
    end
  end

  # 非协议 assemble publish 路径（现状逐字节不变，R6/C6）：commit_drives write_quorum 门。
  defp publish_controlled_assemble(
         tmps,
         commit_pairs,
         cfg,
         opts,
         prepared,
         control,
         identity,
         bucket,
         key
       ) do
    case Control.register(control, identity, fn -> :ok end, fn -> :ok end) do
      :ok ->
        ok_drives = commit_drives(tmps, commit_pairs, opts)

        if ok_drives >= cfg.write_quorum do
          {:ok, prepared}
        else
          Logger.error("erasure assemble below write quorum",
            bucket: bucket,
            key: key,
            reason: "ok_drives=#{ok_drives} < write_quorum=#{cfg.write_quorum}"
          )

          rollback_commit(tmps, commit_pairs)
          {:error, :write_quorum}
        end

      {:error, reason} ->
        cleanup_tmps(tmps)
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
    cfg = Config.load!(opts)
    Enum.each(upload_dirs(bucket, upload_id, cfg), fn dir -> _ = File.rm_rf(dir) end)
    :ok
  end

  # ── delete marker 落盘（ROUTE B B5-0）──
  # 在 version_id 对应盘上对象目录写**纯 delete-marker maxio/2 sidecar**（无 part.0、无 ec/shards
  # core），与 PUT 同级 temp→rename 原子提交：各盘先 begin_tmp，sidecar 写 temp，commit 数据先于元数据
  # 原子 rename 到 final，成功盘数 >= write_quorum 才 :ok，否则回滚 + {:error,:write_quorum}（铁律 3）。
  defp do_put_delete_marker(bucket, key, version_id, entry_opts, opts) do
    cfg = Config.load!(opts)

    with {:ok, commit_pairs} <- commit_pairs(bucket, key, version_id, cfg) do
      tmps =
        commit_pairs |> Enum.map(fn {drive_root, _final} -> drive_root end) |> begin_tmp_dirs!()

      meta = build_delete_marker_meta(version_id, entry_opts)

      write_tmp_sidecars(tmps, meta)

      # 纯元数据提交声明（ShardServer.commit/3 :meta_only）：temp 只有 meta.json 无 part.0 →
      # 跳过 part rename 只提交 meta.json（仍 fsync + 原子 rename + sync dir）。
      ok_drives = commit_drives(tmps, commit_pairs, Keyword.put(opts, :meta_only, true))

      if ok_drives >= cfg.write_quorum do
        # B5-3 R2：marker 提交是对 final 的「替换」（Suspended null 路径 final 可能持有既有 null
        # 版本，meta_only rename 覆盖其 sidecar）——quorum 成功后 best-effort GC 各盘 final 里被
        # 替换 null 版本的孤儿 part.0（delete marker 无字节，marker 版本目录里任何 part.0 定义上
        # 都是孤儿）。失败幂等忽略（残余孤儿归 heal/GC 渠道），与 Distributed 同语义（铁律 2）。
        Enum.each(commit_pairs, fn {_drive_root, final_dir} ->
          _ = File.rm(Path.join(final_dir, @part_file))
        end)

        :ok
      else
        Logger.error("erasure put_delete_marker below write quorum",
          bucket: bucket,
          key: key,
          reason: "ok_drives=#{ok_drives} < write_quorum=#{cfg.write_quorum}"
        )

        # B5-3 R2：替换式提交的失败回滚**只清 temp，绝不删 final**（rollback_commit 会连 final 一并
        # 删掉 = 摧毁被替换的旧 null 版本，制造裸 404 破坏窗口）。已 commit 的盘留部分 marker
        # （< quorum 不构成读权威），由重试/heal 收敛，与 Distributed 同语义（铁律 2）。
        Enum.each(tmps, &File.rm_rf/1)
        {:error, :write_quorum}
      end
    end
  end

  # ── 对象目录布局（每盘一份）──

  # 对象在盘 d 下的目录：<d>/<bucket>/<rel>（null 版本）或 <d>/.versions/<bucket>/<rel>/<version_id>。
  # rel 经 Maxio.Cluster.Paths.object_rel（单一事实来源，铁律 2）：空段/尾斜杠/布局保留名段
  # 全部段编码无碰撞落盘（绝不 trim 折叠、绝不与 meta.json/part.0 布局名冲突）。
  defp object_dirs(bucket, key, version_id, cfg) do
    case Maxio.Cluster.Paths.object_rel(bucket, key, version_id) do
      {:ok, sub} -> {:ok, Enum.map(cfg.drives, &Path.join(&1, sub))}
      {:error, :invalid_key} -> {:error, :invalid_key}
    end
  end

  # ── 原子提交编排（B1-2）──
  # 每盘返回 {drive_root, final_obj_dir}：drive_root（cfg.drives 元素）下建同卷 .tmp，final 为对象目录。
  defp commit_pairs(bucket, key, version_id, cfg) do
    case Maxio.Cluster.Paths.object_rel(bucket, key, version_id) do
      {:ok, sub} ->
        {:ok, Enum.map(cfg.drives, fn drive -> {drive, Path.join(drive, sub)} end)}

      {:error, :invalid_key} ->
        {:error, :invalid_key}
    end
  end

  defp begin_tmp_dirs!(drive_roots) do
    Enum.reduce(drive_roots, [], fn drive_root, acc ->
      case ShardServer.begin_tmp(drive_root) do
        {:ok, tmp} ->
          [tmp | acc]

        {:error, reason} ->
          cleanup_tmps(acc)
          raise "failed to create shard temp dir: #{inspect(reason)}"
      end
    end)
    |> Enum.reverse()
  end

  # sidecar 写各盘 temp obj-dir（与 part.0 同 temp，一并 commit）。
  defp write_tmp_sidecars(tmps, meta) do
    bin = Meta.encode(meta)
    Enum.each(tmps, fn tmp -> File.write!(Path.join(tmp, @meta_file), bin) end)
  end

  # 各盘 commit（temp -> final 数据先于元数据原子 rename + fsync）；返回成功盘数（write quorum 判定）。
  # :meta_only 仅 do_put_delete_marker 注入（纯元数据提交声明，B5-0）；do_put/assemble 不注入 →
  # 缺省 false → 缺 part.0 仍立即失败（绝不静默把「忘写数据」当成功提交）。
  defp commit_drives(tmps, commit_pairs, opts) do
    commit_drives_results(tmps, commit_pairs, opts)
    |> Enum.count(fn {_commit_pair, ok?} -> ok? end)
  end

  defp commit_drives_results(tmps, commit_pairs, opts) do
    commit_opts = Keyword.take(opts, [:fsync, :meta_only, :rename_fun])

    tmps
    |> Enum.zip(commit_pairs)
    |> Enum.map(fn {tmp, {_drive_root, final_dir} = commit_pair} ->
      case ShardServer.commit(tmp, final_dir, commit_opts) do
        :ok -> {commit_pair, true}
        {:error, _} -> {commit_pair, false}
      end
    end)
  end

  # write_quorum 未达：回滚——删各盘 temp + 已 commit 到 final 的 obj-dir（保证 quorum 失败 => 对象不存在）。
  defp rollback_commit(tmps, commit_pairs) do
    Enum.each(tmps, &File.rm_rf/1)
    Enum.each(commit_pairs, fn {_drive_root, final_dir} -> File.rm_rf(final_dir) end)
  end

  defp commit_part_replace(tmps, commit_pairs, write_quorum, opts) do
    backups = backup_existing_shards!(commit_pairs)

    try do
      results = commit_drives_results(tmps, commit_pairs, opts)
      ok_drives = Enum.count(results, fn {_commit_pair, ok?} -> ok? end)

      if ok_drives >= write_quorum do
        cleanup_failed_part_finals(results)
        cleanup_tmps(tmps)
        cleanup_backups(backups)
        :ok
      else
        restore_part_backups(tmps, commit_pairs, backups)
        {:error, :write_quorum}
      end
    rescue
      err ->
        restore_part_backups(tmps, commit_pairs, backups)
        reraise(err, __STACKTRACE__)
    catch
      kind, reason ->
        restore_part_backups(tmps, commit_pairs, backups)
        :erlang.raise(kind, reason, __STACKTRACE__)
    end
  end

  # PutObject replacement is stricter than multipart part replacement: a failed
  # endpoint keeps its previous final value even when the other endpoints reach
  # quorum. This prevents a successful quorum write from destroying the only
  # readable old shard on a lagging drive.
  defp commit_object_replace(
         tmps,
         commit_pairs,
         write_quorum,
         opts,
         control,
         identity
       ) do
    with {:ok, plans} <- plan_object_backups(commit_pairs),
         :ok <-
           Control.register(
             control,
             identity,
             fn -> rollback_object_plans(plans, identity) end,
             fn -> discard_object_plans(plans) end
           ),
         :ok <- materialize_object_plans(plans) do
      results = commit_drives_results(tmps, commit_pairs, opts)
      ok_drives = Enum.count(results, fn {_commit_pair, ok?} -> ok? end)

      if ok_drives >= write_quorum do
        rollback_failed_object_plans(results, plans, identity)
        cleanup_tmps(tmps)
        :ok
      else
        {:error, :write_quorum}
      end
    else
      {:error, _reason} = error -> error
    end
  end

  defp plan_object_backups(commit_pairs) do
    Enum.reduce_while(commit_pairs, {:ok, []}, fn {drive, final}, {:ok, acc} ->
      entries =
        [@part_file, @meta_file]
        |> Enum.map(fn name -> {Path.join(final, name), name} end)
        |> Enum.filter(fn {source, _name} -> File.regular?(source) end)

      case entries do
        [] ->
          plan = %{
            drive: drive,
            final: final,
            backup_dir: nil,
            entries: [],
            old_identity: {:error, :enoent}
          }

          {:cont, {:ok, [plan | acc]}}

        entries ->
          with {:ok, old_identity} <- readable_object_identity(final),
               {:ok, backup_dir} <- ShardServer.begin_tmp(drive) do
            plan = %{
              drive: drive,
              final: final,
              backup_dir: backup_dir,
              entries:
                Enum.map(entries, fn {source, name} ->
                  {source, Path.join(backup_dir, name)}
                end),
              old_identity: old_identity
            }

            {:cont, {:ok, [plan | acc]}}
          else
            {:error, reason} ->
              _ = discard_object_plans(acc)
              {:halt, {:error, reason}}
          end
      end
    end)
    |> case do
      {:ok, plans} -> {:ok, Enum.reverse(plans)}
      {:error, _reason} = error -> error
    end
  end

  defp readable_object_identity(final) do
    case object_commit_identity(final) do
      {:ok, identity} -> {:ok, {:ok, identity}}
      {:error, :enoent} -> {:ok, {:error, :enoent}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp materialize_object_plans(plans) do
    Enum.reduce_while(plans, :ok, fn plan, :ok ->
      case materialize_object_plan(plan) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp materialize_object_plan(%{entries: entries}) do
    Enum.reduce_while(entries, :ok, fn {source, backup}, :ok ->
      case File.rename(source, backup) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp rollback_failed_object_plans(results, plans, identity) do
    Enum.zip(results, plans)
    |> Enum.each(fn
      {{_commit_pair, true}, _plan} -> :ok
      {{_commit_pair, false}, plan} -> _ = rollback_object_plan(plan, identity)
    end)
  end

  defp rollback_object_plans(plans, identity) do
    Enum.reduce_while(plans, :ok, fn plan, :ok ->
      case rollback_object_plan(plan, identity) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp rollback_object_plan(plan, identity) do
    moved = Enum.filter(plan.entries, fn {_source, backup} -> File.exists?(backup) end)

    cond do
      moved == [] and plan.backup_dir != nil ->
        discard_object_plan(plan)

      true ->
        case object_commit_identity(plan.final) do
          {:ok, ^identity} ->
            remove_object_files(plan.final)
            restore_object_entries(plan, moved)

          current when current == plan.old_identity ->
            restore_object_entries(plan, moved)

          {:error, :enoent} ->
            remove_object_files(plan.final)
            restore_object_entries(plan, moved)

          {:ok, _successor_identity} ->
            discard_object_plan(plan)

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  defp restore_object_entries(plan, moved) do
    result =
      Enum.reduce_while(moved, :ok, fn {source, backup}, :ok ->
        _ = File.rm(source)
        _ = File.mkdir_p(Path.dirname(source))

        case File.rename(backup, source) do
          :ok -> {:cont, :ok}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)

    if result == :ok, do: discard_object_plan(plan), else: result
  end

  defp remove_object_files(final) do
    Enum.each([@part_file, @meta_file], fn name -> _ = File.rm(Path.join(final, name)) end)
    _ = File.rmdir(final)
    :ok
  end

  defp object_commit_identity(final) do
    case File.read(Path.join(final, @meta_file)) do
      {:ok, bin} ->
        try do
          {:ok, bin |> Meta.decode!() |> Map.get("object_commit_identity")}
        rescue
          error -> {:error, {:invalid_sidecar, error}}
        end

      {:error, reason} when reason in [:enoent, :enotdir] ->
        {:error, :enoent}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp discard_object_plans(plans) do
    Enum.reduce_while(plans, :ok, fn plan, :ok ->
      case discard_object_plan(plan) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp discard_object_plan(%{backup_dir: nil}), do: :ok

  defp discard_object_plan(%{backup_dir: backup_dir}) do
    case File.rm_rf(backup_dir) do
      {:ok, _paths} -> :ok
      {:error, reason, _path} -> {:error, reason}
    end
  end

  defp cleanup_failed_part_finals(results) do
    Enum.each(results, fn
      {_commit_pair, true} -> :ok
      {{_drive_root, final_dir}, false} -> File.rm_rf(final_dir)
    end)
  end

  defp backup_existing_shards!(commit_pairs) do
    do_backup_existing_shards!(commit_pairs, [])
  end

  defp do_backup_existing_shards!([], acc), do: Enum.reverse(acc)

  defp do_backup_existing_shards!([{drive_root, final_dir} | rest], acc) do
    case backup_existing_shard(drive_root, final_dir) do
      {:ok, entry} ->
        do_backup_existing_shards!(rest, [entry | acc])

      {:error, reason} ->
        restore_part_backups([], [], Enum.reverse(acc))
        raise "failed to backup shard before replacement commit: #{inspect(reason)}"
    end
  end

  defp backup_existing_shard(drive_root, final_dir) do
    if File.exists?(final_dir) do
      with {:ok, backup} <- ShardServer.begin_tmp(drive_root) do
        case ShardServer.move_shard(final_dir, backup, []) do
          :ok ->
            {:ok, {drive_root, final_dir, backup}}

          {:error, :enoent} ->
            File.rm_rf(backup)
            {:ok, {drive_root, final_dir, nil}}

          {:error, reason} ->
            File.rm_rf(backup)
            {:error, reason}
        end
      end
    else
      {:ok, {drive_root, final_dir, nil}}
    end
  end

  defp cleanup_backups(backups) do
    Enum.each(backups, fn
      {_drive_root, _final_dir, nil} -> :ok
      {_drive_root, _final_dir, backup} -> File.rm_rf(backup)
    end)
  end

  defp restore_part_backups(tmps, commit_pairs, backups) do
    cleanup_tmps(tmps)

    Enum.each(commit_pairs, fn {_drive_root, final_dir} ->
      File.rm_rf(final_dir)
    end)

    Enum.each(backups, fn
      {_drive_root, _final_dir, nil} ->
        :ok

      {_drive_root, final_dir, backup} ->
        _ = ShardServer.move_shard(backup, final_dir, [])
    end)
  end

  # ── PUT：逐块流式编码 ──

  defp cleanup_tmps(tmps), do: Enum.each(tmps, &File.rm_rf/1)

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

  defp do_put(bucket, key, version_id, chunks, opts) do
    cfg = Config.load!(opts)

    with {:ok, _validated_commit_pairs} <- commit_pairs(bucket, key, version_id, cfg) do
      # B1-2 原子提交：各盘先建同卷 temp obj-dir，逐块流式写 temp 的 part.0，流尾 sidecar 写 temp，
      # 最后各盘 commit（数据先于元数据原子 rename 到 final），成功盘数 >= write_quorum 才 {:ok}。
      tmps = begin_tmp_dirs!(cfg.drives)

      try do
        fds = Enum.map(tmps, fn tmp -> open_write!(Path.join(tmp, @part_file)) end)

        acc =
          try do
            acc0 = %{
              md5: :crypto.hash_init(:md5),
              sha: :crypto.hash_init(:sha256),
              size: 0,
              shard_len: nil,
              # 每盘一个 block_hashes 反序列表（hex）
              block_hashes: List.duplicate([], Config.total(cfg)),
              buffer: <<>>,
              fds: fds
            }

            acc = Enum.reduce(chunks, acc0, fn chunk, acc -> feed(cfg, acc, chunk) end)
            flush_final(cfg, acc)
          after
            Enum.each(fds, &File.close/1)
          end

        etag = acc.md5 |> :crypto.hash_final() |> Base.encode16(case: :lower)
        sha256 = acc.sha |> :crypto.hash_final() |> Base.encode16(case: :lower)
        shard_len = acc.shard_len || 0

        result = %{size: acc.size, etag: etag, sha256: sha256}
        extra = run_before_object_commit!(opts, result)
        prepared = Map.merge(result, extra)
        block_hashes = Enum.map(acc.block_hashes, &Enum.reverse/1)

        ObjectCommit.run(
          opts,
          prepared,
          default_object_commit_opts(version_id, opts, extra),
          fn commit_opts ->
            publish_staged_put(
              tmps,
              bucket,
              key,
              cfg,
              opts,
              prepared,
              shard_len,
              block_hashes,
              commit_opts
            )
          end,
          fn -> cleanup_tmps(tmps) end
        )
      rescue
        err ->
          cleanup_tmps(tmps)
          reraise(err, __STACKTRACE__)
      catch
        kind, reason ->
          cleanup_tmps(tmps)
          :erlang.raise(kind, reason, __STACKTRACE__)
      end
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
         tmps,
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

    case commit_pairs(bucket, key, version_id, cfg) do
      {:ok, commit_pairs} ->
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

        write_tmp_sidecars(tmps, meta)
        committed = Map.put(prepared, :version_id, version_id)

        # 协议化 PutObject（commit_opts[:object_mutation]，B5 orchestrator 注入）走
        # ObjectMutation publish 分支；不传该 opt 的调用者保持现状路径逐字节不变（R6）。
        case Keyword.get(commit_opts, :object_mutation) do
          nil ->
            publish_controlled_replace(
              tmps,
              commit_pairs,
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
              tmps,
              commit_pairs,
              cfg,
              opts,
              committed,
              control,
              identity,
              ctx,
              bucket,
              key
            )

          invalid ->
            cleanup_tmps(tmps)
            {:error, {:invalid_object_mutation, invalid}}
        end

      {:error, reason} ->
        cleanup_tmps(tmps)
        {:error, reason}
    end
  end

  # 非协议 publish 路径（现状逐字节不变，R6）：identity 比对式 commit_object_replace。
  defp publish_controlled_replace(
         tmps,
         commit_pairs,
         cfg,
         opts,
         committed,
         control,
         identity,
         bucket,
         key
       ) do
    case commit_object_replace(
           tmps,
           commit_pairs,
           cfg.write_quorum,
           opts,
           control,
           identity
         ) do
      :ok ->
        {:ok, committed}

      {:error, :write_quorum} = error ->
        Logger.error("erasure put below write quorum",
          bucket: bucket,
          key: key,
          reason: "write_quorum=#{cfg.write_quorum}"
        )

        error

      # Phase 2A C1（B3 审查项 3）：commit_object_replace 的非 quorum 错误（备份计划、
      # Control 注册、备份物化失败等）由 CaseClauseError 裸崩收口为结构化返回；
      # `:write_quorum` 形状保持不变。
      {:error, reason} ->
        Logger.error("erasure put replace commit failed",
          bucket: bucket,
          key: key,
          reason: inspect(reason)
        )

        {:error, {:commit_failed, reason}}
    end
  end

  # ── ObjectMutation 协议化 publish（协议 §3.2/§3.3/§5，实现计划 B3）──
  # 与 FS publish_mutation_obj_dir（B2）同形的协议分支，差异仅在逐盘 quorum 编排：
  #   * 每盘旧值备份落 <drive>/.maxio-object-mutations/<mutation_id>/ + 每盘 manifest
  #     （durable，recovery 凭 journal + 磁盘即可定位），不再用 .tmp/<uuid>；
  #   * Control.register 之后、备份物化之前逐盘写 manifest + fsync（协议 §5「第一次
  #     destructive IO 前同步注册 durable mutation context」的磁盘侧落点）；manifest 落盘
  #     数不足 epoch_quorum → 在任何破坏性 IO 之前拒绝；
  #   * 备份物化之后、destructive rename 之前逐盘 epoch CAS {:exact, token, ["claimed"]}
  #     → "published"（携精确 fingerprint）quorum 门（D4：oks >= cfg.epoch_quorum）；不足
  #     quorum → 不进入 rename、backup 保留（实现计划决策点 2：publish CAS 固定在 rename
  #     之前，不得调换）；
  #   * rollback/finalize 闭包指向 restore_if_current/finalize_if_current——所有权判定只认
  #     epoch token；sidecar 仍写 object_commit_identity（旧调用者与取证兼容），协议分支
  #     不走 identity 比对；
  #   * 阶段中掉队的失败盘不做即时回位（非协议 rollback_failed_object_plans 的 identity
  #     比对路径不适用协议分支）——其 backup + manifest 原地保留，收敛交给 epoch token
  #     授权的 restore_mutation（journal/recovery，B5/B6）。
  # register 之后的失败不清 tmp/backup：ObjectCommit rollback 经 restore_if_current 收敛
  # （durable manifest 在，幂等），discard_fun 清 tmps。
  defp publish_mutation_staged_put(
         tmps,
         commit_pairs,
         cfg,
         opts,
         committed,
         control,
         identity,
         ctx,
         bucket,
         key
       ) do
    with :ok <- validate_mutation_commit_pairs(commit_pairs, ctx),
         {:ok, plans} <- plan_mutation_backups(commit_pairs, tmps, ctx),
         {:ok, fingerprint} <- staged_mutation_fingerprint(tmps, committed),
         {:ok, published_payload} <- published_epoch_payload(ctx, fingerprint) do
      # 设计 D2：proof_ctx 在 Control.register 之前派生。restore 闭包捕获原始 ctx；
      # finalize 闭包捕获带 published fingerprint 的 proof_ctx。
      proof_ctx = %MutationContext{ctx | published_fingerprint: fingerprint}
      rollback = fn -> mutation_control_result(do_restore_if_current(ctx, opts)) end
      finalize = fn -> mutation_control_result(do_finalize_if_current(proof_ctx, opts)) end

      case Control.register(control, identity, rollback, finalize) do
        :ok ->
          publish_mutation_plans(
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
          cleanup_tmps(tmps)
          {:error, reason}
      end
    else
      {:error, reason} ->
        cleanup_tmps(tmps)
        {:error, reason}
    end
  end

  defp publish_mutation_plans(
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
    # 阶段 1：每盘 manifest 先行（B1 EpochStore 契约：published 的 restore 要求 manifest
    # 必在）。落盘数不足 epoch_quorum → 尚无任何破坏性 IO，直接拒绝。
    {with_manifest, manifest_failures} =
      split_plans(plans, fn plan -> write_mutation_manifest(plan, ctx, opts) end)

    if length(with_manifest) < cfg.epoch_quorum do
      Logger.error("erasure mutation backup manifest below epoch quorum",
        bucket: bucket,
        key: key,
        mutation_id: ctx.mutation_id,
        reason:
          "ok=#{length(with_manifest)} < epoch_quorum=#{cfg.epoch_quorum} " <>
            "failures=#{inspect(plan_failures(manifest_failures))}"
      )

      {:error,
       {:mutation_backup_quorum,
        %{endpoints_ok: length(with_manifest), epoch_quorum: cfg.epoch_quorum}}}
    else
      # 阶段 2：物化备份（第一次 destructive IO；仅 manifest 已 durable 的盘）。失败盘
      # 掉队（其 final 残留由 restore_mutation 按 manifest 收敛），绝不中断其他盘。
      {materialized, materialize_failures} =
        split_plans(with_manifest, &materialize_object_plan/1)

      if materialize_failures != [] do
        Logger.warning("erasure mutation backup materialize failed on drives",
          bucket: bucket,
          key: key,
          mutation_id: ctx.mutation_id,
          reason: inspect(plan_failures(materialize_failures))
        )
      end

      # 阶段 3：destructive rename 之前的 epoch publish quorum 门（决策点 2）。
      {published, cas_failures} =
        split_plans(materialized, fn plan ->
          mutation_publish_cas(plan, ctx, published_payload, opts)
        end)

      if length(published) < cfg.epoch_quorum do
        Logger.error("erasure mutation epoch publish below epoch quorum",
          bucket: bucket,
          key: key,
          mutation_id: ctx.mutation_id,
          reason:
            "ok=#{length(published)} < epoch_quorum=#{cfg.epoch_quorum} " <>
              "failures=#{inspect(plan_failures(cas_failures))}"
        )

        {:error,
         {:epoch_publish_quorum,
          %{endpoints_ok: length(published), epoch_quorum: cfg.epoch_quorum}}}
      else
        if cas_failures != [] do
          Logger.warning("erasure mutation epoch publish failed on minority drives",
            bucket: bucket,
            key: key,
            mutation_id: ctx.mutation_id,
            reason: inspect(plan_failures(cas_failures))
          )
        end

        # 阶段 4：数据 rename（仅 epoch 已 published 的盘；数据 quorum 沿用 write_quorum，
        # epoch_quorum >= write_quorum 保证门内盘数足够）。不足 → 不回滚 final/backup，
        # 收敛交给 restore_if_current（journal/recovery）。
        data_commit_opts = Keyword.take(opts, [:fsync, :meta_only, :rename_fun])

        ok_drives =
          Enum.count(published, fn plan ->
            ShardServer.commit(plan.tmp, plan.final, data_commit_opts) == :ok
          end)

        if ok_drives >= cfg.write_quorum do
          cleanup_tmps(Enum.map(plans, & &1.tmp))
          {:ok, Map.put(committed, :epoch_fingerprint, fingerprint)}
        else
          Logger.error("erasure mutation put below write quorum",
            bucket: bucket,
            key: key,
            mutation_id: ctx.mutation_id,
            reason: "ok_drives=#{ok_drives} < write_quorum=#{cfg.write_quorum}"
          )

          {:error, :write_quorum}
        end
      end
    end
  end

  # 逐盘执行一个阶段函数（:ok | {:error, reason}），失败盘掉队、绝不中断其他盘；
  # quorum 门只看通过盘数（结构同 commit_drives_results 的盘迭代 + 计数）。
  defp split_plans(plans, fun) do
    {oks, failures} =
      Enum.reduce(plans, {[], []}, fn plan, {oks, failures} ->
        case fun.(plan) do
          :ok -> {[plan | oks], failures}
          {:error, reason} -> {oks, [{plan, reason} | failures]}
        end
      end)

    {Enum.reverse(oks), Enum.reverse(failures)}
  end

  defp plan_failures(failures),
    do: Enum.map(failures, fn {plan, reason} -> {plan.drive, reason} end)

  # 防线：ctx.final_rel（restore 的回位落点，journal 派生）必须与本次 publish 的各盘 final
  # 指向同一相对路径——不一致意味着上下文与请求落点脱节，restore 会把旧字节回错目录。
  defp validate_mutation_commit_pairs(commit_pairs, %MutationContext{final_rel: final_rel}) do
    if is_binary(final_rel) and
         Enum.all?(commit_pairs, fn {drive, final} -> Path.join(drive, final_rel) == final end) do
      :ok
    else
      {:error, {:mutation_final_rel_mismatch, final_rel}}
    end
  end

  # 协议化备份计划（每盘一份）：backup 落 durable mutation 目录（非 .tmp）。names 按盘各自
  # 探测（滞后盘可能缺 part.0/meta.json；fresh 盘 entries=[]——restore 只按 manifest 名单
  # 回位，绝不推断删除，nil/:enoent 不当授权同源纪律）。
  defp plan_mutation_backups(commit_pairs, tmps, %MutationContext{mutation_id: mutation_id}) do
    plans =
      commit_pairs
      |> Enum.zip(tmps)
      |> Enum.map(fn {{drive, final}, tmp} ->
        backup_dir = Path.join(drive, MutationBackup.relative_dir(mutation_id))

        names =
          Enum.filter([@part_file, @meta_file], fn name ->
            File.regular?(Path.join(final, name))
          end)

        %{
          drive: drive,
          final: final,
          tmp: tmp,
          backup_dir: backup_dir,
          names: names,
          entries:
            Enum.map(names, fn name ->
              {Path.join(final, name), Path.join(backup_dir, name)}
            end)
        }
      end)

    {:ok, plans}
  end

  # manifest 先行（每盘）：manifest + fsync 落盘于该盘任何 destructive IO 之前，crash 后
  # recovery 仅凭 mutation_id 即可定位该盘备份名单。
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

  # fingerprint 的 sidecar_sha256 针对**实际落盘**的 tmp meta.json 字节（读回而非重编码，
  # 杜绝编码漂移）；write_tmp_sidecars 对所有盘写同一份 bin，任一 tmp 读回即全体字节。
  defp staged_mutation_fingerprint([tmp | _rest], committed) do
    case File.read(Path.join(tmp, @meta_file)) do
      {:ok, sidecar_bytes} ->
        {:ok, ObjectEpoch.fingerprint(committed.etag, committed.size, sidecar_bytes)}

      {:error, reason} ->
        {:error, {:staged_sidecar_unreadable, reason}}
    end
  end

  # 各盘同一份 published payload：{:exact, token, ["claimed"]} 门依赖 B1 收口确认项
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

  defp mutation_publish_cas(plan, ctx, published_payload, opts) do
    case ShardServer.cas_epoch(
           plan.drive,
           %{next: published_payload, expect: {:exact, ctx.token, ["claimed"]}},
           epoch_opts(opts)
         ) do
      {:ok, :applied} -> :ok
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

  # ── ObjectMutation epoch 原语（B3）：per-endpoint 原语的逐盘 quorum 编排。──

  defp do_claim_epoch(target, token, operation, opts) do
    cfg = Config.load!(opts)

    # 先 quorum 读取 previous（lineage 信息，B5 写入 journal previous_epoch）；fence 正确性
    # 由各盘 CAS 的「仅接受严格更大 token」独立保证（B5 起 claim 恒在 object lock 内）。
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
         {:ok, payload} <- EpochStore.payload(claimed) do
      oks =
        Enum.count(cfg.drives, fn drive ->
          match?(
            {:ok, :applied},
            ShardServer.cas_epoch(
              drive,
              %{next: payload, expect: {:claim, token}},
              epoch_opts(opts)
            )
          )
        end)

      if oks >= cfg.epoch_quorum do
        {:ok, %{previous: previous, endpoints_ok: oks}}
      else
        # 少数盘已写入的 claim 无需回收：fence 单调性保证无害，后继 claim 会取 max+1。
        Logger.error("erasure claim_epoch below epoch quorum",
          bucket: Map.get(target, "bucket"),
          key: Map.get(target, "key"),
          reason: "ok=#{oks} < epoch_quorum=#{cfg.epoch_quorum}"
        )

        {:error, :write_quorum}
      end
    end
  end

  # quorum 读裁决（D4）：可读盘数（有效 epoch 或显式 :absent）>= epoch_quorum 才裁决，取
  # 最大 token 的 epoch；:absent 仅当可读盘全为 absent（nil/:enoent 绝不当授权）；不足 →
  # {:error, :epoch_quorum_unavailable}（不猜测）。
  defp do_current_epoch(target, opts) do
    cfg = Config.load!(opts)
    views = read_epoch_views(cfg.drives, target, opts)
    epochs = for {_drive, {:epoch, epoch}} <- views, do: epoch
    absent = Enum.count(views, fn {_drive, view} -> view == :absent end)

    cond do
      length(epochs) + absent < cfg.epoch_quorum -> {:error, :epoch_quorum_unavailable}
      epochs == [] -> {:ok, :absent}
      true -> {:ok, Enum.max_by(epochs, &token_sort_key/1)}
    end
  end

  # 先 quorum 读全局裁决（quorum 视图见 successor → 整体 :superseded，任何盘不动；见本
  # token 的 committed epoch → {:error, :epoch_committed}，metadata_committed 禁回滚的
  # quorum 级防线；absent → {:error, :epoch_missing}）；裁决通过才逐盘 restore_mutation
  # （per-endpoint CAS 仍各自把关），restored 盘数 >= epoch_quorum → 成功，否则
  # {:error, {:partial, evidence}}（journal 侧 mark_error 重试；backup 保留——不猜测、不破坏）。
  defp do_restore_if_current(%MutationContext{} = ctx, opts) do
    cfg = Config.load!(opts)

    case adjudicate_mutation_epoch(ctx, :restore, cfg, opts) do
      :superseded ->
        {:ok, :superseded}

      :proceed ->
        request = %{
          target: ctx.target,
          token: ctx.token,
          mutation_id: ctx.mutation_id,
          final_rel: ctx.final_rel
        }

        cfg.drives
        |> Enum.map(fn drive ->
          {drive, ShardServer.restore_mutation(drive, request, epoch_opts(opts))}
        end)
        |> conclude_mutation_quorum(:restored, cfg.epoch_quorum)

      {:error, reason} ->
        {:error, reason}
    end
  end

  # ── proof-aware backend 聚合（设计 D1/D4/D5，Task 2 G3）──
  #
  # 与旧的「全局 epoch 预裁决 + 三字段 finalize 请求」彻底替换：proof 与 finalize 都只走
  # 逐盘的完整 proof request，每个结果按**枚举时捕获的 ordinal**（而非完成顺序、drive
  # 路径或响应自报 identity）归位，再由 Task 1 的公共 classifier 唯一裁决 successor /
  # quorum / integrity / unavailable / orphan / cleanup。EC 不做任何 quorum 复算。

  defp do_verify_published(%MutationContext{} = ctx, opts) do
    cfg = Config.load!(opts)

    case ec_participants(cfg) do
      {:ok, participants} ->
        PublishedProof.classify(
          cfg.epoch_quorum,
          ec_observations(participants, ctx, opts, :proof)
        )

      {:error, code} ->
        placement_drift_aggregate(cfg.epoch_quorum, :proof, code)
    end
  end

  defp do_finalize_if_current(%MutationContext{} = ctx, opts) do
    cfg = Config.load!(opts)

    case ec_participants(cfg) do
      {:ok, participants} ->
        PublishedProof.classify_finalize(
          cfg.epoch_quorum,
          ec_observations(participants, ctx, opts, :finalize)
        )

      {:error, code} ->
        placement_drift_aggregate(cfg.epoch_quorum, :finalize, code)
    end
  end

  # 冻结参与者向量：`cfg.drives` **只枚举一次**（单次 reduction 同时建向量与 seen 集），
  # ordinal 即 drive 在配置中的下标，identity 固定为全局 `"ordinal:N"`（绝不含 drive
  # 路径）。空集/数量/精确重复项全部从**该捕获向量**判定，绝不二次枚举 `cfg.drives`；
  # 重复 drive 会让两个 ordinal 指向同一物理盘、冒充 quorum，属结构性 placement 漂移。
  # 端点 IO 只消费这一个向量。
  defp ec_participants(%Config{} = cfg) do
    {reversed, _seen, count, duplicate?} =
      Enum.reduce(cfg.drives, {[], MapSet.new(), 0, false}, fn drive,
                                                               {acc, seen, ordinal, duplicate?} ->
        participant = %{ordinal: ordinal, identity: "ordinal:#{ordinal}", drive: drive}

        {[participant | acc], MapSet.put(seen, drive), ordinal + 1,
         duplicate? or MapSet.member?(seen, drive)}
      end)

    cond do
      count == 0 -> {:error, :empty_placement}
      duplicate? -> {:error, :duplicate_endpoint}
      count < cfg.epoch_quorum -> {:error, :insufficient_participants}
      true -> {:ok, Enum.reverse(reversed)}
    end
  end

  defp ec_observations(participants, %MutationContext{} = ctx, opts, mode) do
    Enum.map(participants, fn participant ->
      request = shard_proof_request(ctx, participant.ordinal)
      {participant.identity, ec_endpoint_call(participant, request, opts, mode)}
    end)
  end

  # 复用 Transport 的惰性 outer-envelope 边界：call-time raise/exit/throw 与完全畸形的
  # 外层返回都归一化为**该捕获 ordinal** 的 canonical unavailable；具备 endpoint 信封的
  # 值（含伪造 identity/scope/mode/counts）原样透传给公共 classifier 判 placement drift。
  defp ec_endpoint_call(participant, request, opts, :proof) do
    Transport.call_mutation_proof(request, fn ->
      ShardServer.verify_mutation(participant.drive, request, epoch_opts(opts))
    end)
  end

  defp ec_endpoint_call(participant, request, opts, :finalize) do
    Transport.call_mutation_finalize(request, fn ->
      ShardServer.finalize_mutation(participant.drive, request, epoch_opts(opts))
    end)
  end

  # 设计 D4 的完整 endpoint request：精确 target/token/mutation_id/final_rel/expected
  # fingerprint + 捕获的 `layout.index`（端点据此固定自己的 shard ordinal 与响应 identity）。
  defp shard_proof_request(%MutationContext{} = ctx, ordinal) do
    %{
      target: ctx.target,
      token: ctx.token,
      mutation_id: ctx.mutation_id,
      final_rel: ctx.final_rel,
      expected_fingerprint: ctx.published_fingerprint,
      layout: %{kind: "shard", index: ordinal}
    }
  end

  # preflight 漂移的唯一出口：canonical、脱敏、零端点 IO 的 aggregate placement drift。
  # witness 由公共构造器生成（非 owned、无 node/drive/路径），再经公共 classifier 规范化。
  # 身份用 shard 域的稳定 `"ordinal:0"`；`"local"` 是 FS 专属身份，分片后端不得借用。
  @drift_identity "ordinal:0"

  defp placement_drift_aggregate(required, :proof, code) do
    witness =
      PublishedProof.failed(:placement_drift, @drift_identity, %{code: code, owned: false})

    PublishedProof.classify(required, [{@drift_identity, witness}])
  end

  defp placement_drift_aggregate(required, :finalize, code) do
    witness =
      PublishedProof.endpoint_finalize_failed(:placement_drift, @drift_identity, %{
        code: code,
        owned: false
      })

    PublishedProof.classify_finalize(required, [{@drift_identity, witness}])
  end

  # quorum 读全局裁决：裁决 token > ctx.token（successor 可见）→ :superseded；全 absent →
  # {:error, :epoch_missing}；裁决 token < ctx.token → 证据矛盾（claim 已达 quorum、两个
  # quorum 必有交集，可读视图不应只见更旧 token）→ {:error, {:epoch_mismatch, token}}。
  defp adjudicate_mutation_epoch(%MutationContext{} = ctx, kind, cfg, opts) do
    views = read_epoch_views(cfg.drives, ctx.target, opts)
    epochs = for {_drive, {:epoch, epoch}} <- views, do: epoch
    absent = Enum.count(views, fn {_drive, view} -> view == :absent end)

    cond do
      length(epochs) + absent < cfg.epoch_quorum ->
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

  # metadata_committed 禁回滚的 quorum 级防线：任一可读盘的本 token epoch 已 committed →
  # 整体拒绝 restore（per-endpoint restore_mutation 的 :epoch_committed 是端点级同源防线）。
  defp adjudicate_owned(epochs, token, :restore) do
    committed? =
      Enum.any?(epochs, fn epoch -> epoch.token == token and epoch.phase == "committed" end)

    if committed?, do: {:error, :epoch_committed}, else: :proceed
  end

  # finalize 对 committed 幂等（per-endpoint 收敛残余 backup），无需 quorum 级前置拒绝。
  defp adjudicate_owned(_epochs, _token, :finalize), do: :proceed

  # 三分类计数（实现计划 B3 要点 1）：ok_outcome（:restored/:finalized）/ :superseded /
  # error。per-endpoint 的 :superseded（全局裁决后另一写者插入的窗口）不计入成功——诚实
  # 上报 partial，重试时全局裁决折叠为整体 :superseded。
  defp conclude_mutation_quorum(results, ok_outcome, epoch_quorum) do
    {oks, supersededs, errors} =
      Enum.reduce(results, {0, 0, []}, fn {drive, result}, {oks, sups, errors} ->
        case result do
          {:ok, ^ok_outcome} -> {oks + 1, sups, errors}
          {:ok, :superseded} -> {oks, sups + 1, errors}
          {:error, reason} -> {oks, sups, [{drive, reason} | errors]}
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

  defp read_epoch_views(drives, target, opts) do
    Enum.map(drives, fn drive ->
      view =
        case ShardServer.read_epoch(drive, target, epoch_opts(opts)) do
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

      {drive, view}
    end)
  end

  # token 全序（{generation, mutation_id}，与 ObjectEpoch.compare_tokens 同序）：
  # decode 后 token 已规范化（generation 整数、mutation_id 小写），可直接按键排序。
  defp token_sort_key(%ObjectEpoch{token: token}),
    do: {token["generation"], token["mutation_id"]}

  # ShardServer 原语响应是纯数据 payload（erpc 同形）；quorum 裁决按结构体比较 token，
  # 经 decode 全量重验还原（坏 payload 计入不可读盘，绝不参与裁决）。
  defp epoch_from_payload(payload) do
    with {:ok, bytes} <- Jason.encode(payload) do
      ObjectEpoch.decode(bytes)
    end
  end

  defp epoch_or_nil(:absent), do: nil
  defp epoch_or_nil(%ObjectEpoch{} = epoch), do: epoch

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

  # 累积 chunk 到 buffer，满 block_size 即编码落盘。
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

  # 流尽：写最后不满块（非空对象至少一个块；空对象 buffer="" 不写块）。
  defp flush_final(_cfg, %{buffer: <<>>} = acc), do: acc

  defp flush_final(cfg, %{buffer: buffer} = acc),
    do: write_block(cfg, %{acc | buffer: <<>>}, buffer)

  # 编码一个 block：N 分片写各盘 fd，校验和按盘累积。
  #
  # 关键：把每个 block 零填充到固定 block_size 后再编码，保证全对象所有 block 的 shard_len 一致
  # （= even(ceil(block_size/K))）。否则末块（明文 < block_size）会产出更短的分片，破坏 sidecar
  # 单一 shard_len 假设与 GET 侧 `j * shard_len` 偏移寻址。填充字节在 GET 侧按每块明文长度
  # （block_plain_len）截断，明文逐字节不变（铁律 5）。
  defp write_block(cfg, acc, block) do
    padded =
      if byte_size(block) < cfg.block_size do
        block <> <<0::size((cfg.block_size - byte_size(block)) * 8)>>
      else
        block
      end

    %{shards: shards, checksums: checksums, shard_len: shard_len} = Codec.split_block(cfg, padded)

    Enum.zip(acc.fds, shards) |> Enum.each(fn {fd, shard} -> :ok = IO.binwrite(fd, shard) end)

    block_hashes =
      acc.block_hashes
      |> Enum.zip(checksums)
      |> Enum.map(fn {acc_list, ck} -> [Base.encode16(ck, case: :lower) | acc_list] end)

    %{acc | shard_len: shard_len, block_hashes: block_hashes}
  end

  # ROUTE B B4-5：构造 v1 core（耐久 ec/shards/size/etag/sha256/parts，字节不变），紧接经
  # Sidecar.migrate_v1/2 升级为完整 maxio/2 sidecar（仅 Map.put 加 format + 单元素 versions 数组，
  # 绝不污染耐久字段）。富元数据从 opts[:object_meta] 取（缺省 %{}）；modtime 一次计算（do_put
  # 单次 build_meta、同一份 meta 写所有盘 → N 份 Sidecar.signature 逐字一致）。version_id + opts
  # 由 put/5 → do_put 一路透传。
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

  # 从 opts[:object_meta] 取 maxio/2 版本头字段，产出 Sidecar.migrate_v1/2 的 keyword。
  # modtime 一次计算（同一份 meta 写所有盘 → N 份 signature 一致，铁律 3 分歧检测前提）；
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

  # ROUTE B B5-0：纯 delete-marker maxio/2 sidecar（无 part.0 字节、无 ec/shards 耐久 core——delete
  # marker 无字节，合法）。entry：type="delete_marker"/version_id/modtime（单次纳秒，所有盘同值 →
  # N 份 Sidecar.signature 一致）/generation:0/is_latest:true。读侧 ObjectMeta.view_or_not_found /
  # Maxio.Listing 的 delete_marker 处理（B4-3/B4-4）据此 latest marker→404+头 / LIST 排除。
  defp build_delete_marker_meta(version_id, entry_opts) do
    Maxio.Storage.DeleteMarker.sidecar(version_id, entry_opts)
  end

  # ── GET：逐块流式重建 ──

  defp do_get(bucket, key, version_id, range, opts) do
    cfg = Config.load!(opts)

    with {:ok, dirs} <- object_dirs(bucket, key, version_id, cfg),
         {:ok, meta} <- read_any_sidecar(dirs) do
      size = meta["size"]
      block_size = get_in(meta, ["ec", "block_size"])
      {first, last} = normalize_range(range, size)

      if size == 0 or last < first do
        {:ok, []}
      else
        {:ok, stream_object(cfg, bucket, key, version_id, dirs, meta, block_size, first, last)}
      end
    else
      {:error, :enoent} -> {:error, :enoent}
      :error -> {:error, :invalid_key}
    end
  end

  defp normalize_range(nil, size), do: {0, max(size - 1, 0)}
  defp normalize_range({first, last}, _size), do: {first, last}

  # 逐 block 读 K 存活分片、校验+重建、裁剪到 [first,last]，发出。
  defp stream_object(cfg, bucket, key, version_id, dirs, meta, block_size, first, last) do
    n = Config.total(cfg)
    shards_meta = meta["shards"]
    size = meta["size"]
    shard_len = block_shard_len(meta, cfg)
    first_block = div(first, block_size)
    last_block = div(last, block_size)

    Stream.resource(
      fn ->
        fds =
          Enum.map(dirs, fn dir ->
            case :file.open(String.to_charlist(Path.join(dir, @part_file)), [:read, :binary, :raw]) do
              {:ok, fd} -> fd
              {:error, _} -> nil
            end
          end)

        {fds, first_block}
      end,
      fn
        {fds, j} when j > last_block ->
          {:halt, {fds, j}}

        {fds, j} ->
          block_plain_len = block_plain_len(size, block_size, j)

          shards =
            Enum.with_index(fds)
            |> Enum.map(fn {fd, i} -> read_shard(fd, j, shard_len, shards_meta, i) end)

          checksums = block_checksums(shards_meta, n, j)

          plain =
            Codec.restore_block(cfg, shards, checksums, block_plain_len,
              bucket: bucket,
              key: key,
              version_id: version_id,
              block_index: j
            )

          # 裁剪到 [first,last] 与本块的交集。
          block_start = j * block_size
          lo = max(first, block_start) - block_start
          hi = min(last, block_start + block_plain_len - 1) - block_start
          out = binary_part(plain, lo, hi - lo + 1)
          {[out], {fds, j + 1}}
      end,
      fn {fds, _j} -> Enum.each(fds, fn fd -> if fd, do: :file.close(fd) end) end
    )
  end

  # 某盘缺/读不到 -> nil；否则该盘 block j 的分片字节。
  defp read_shard(nil, _j, _shard_len, _shards_meta, _i), do: nil

  defp read_shard(fd, j, shard_len, shards_meta, i) do
    drive_meta = Enum.at(shards_meta, i)

    if drive_meta && j < length(drive_meta["block_hashes"]) do
      case :file.pread(fd, j * shard_len, shard_len) do
        {:ok, data} when byte_size(data) == shard_len -> data
        _ -> nil
      end
    else
      nil
    end
  end

  # block j 的 N 个存储校验和（来自 sidecar，原始字节；缺位补 32 个 0 -> 必不匹配 -> 当缺失）。
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

  # 由 sidecar 推 shard_len：shard_file_size / 块数（取首个有块的盘）。
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

  # 第 j 块的明文长度（除最后一块外都是 block_size）。
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
    cfg = Config.load!(opts)

    with {:ok, dirs} <- object_dirs(bucket, key, version_id, cfg),
         {:ok, meta} <- read_any_sidecar(dirs) do
      {:ok, %{size: meta["size"]}}
    else
      {:error, :enoent} -> {:error, :enoent}
      :error -> {:error, :invalid_key}
    end
  end

  defp do_delete(bucket, key, version_id, opts) do
    cfg = Config.load!(opts)

    with {:ok, dirs} <- object_dirs(bucket, key, version_id, cfg) do
      Enum.each(dirs, fn dir -> _ = File.rm_rf(dir) end)
      :ok
    end
  end

  # ROUTE B fidelity —— DELETE ?versionId 的权威 quorum 删除（Backend.delete_version/4 契约）：
  # 逐盘 rm_rf 版本 obj-dir 后确认 meta.json 显式 missing（本地盘恒「可达」；rm_rf 失败/残留
  # meta.json 的盘不计确认）。确认数 >= write_quorum → :ok；否则 {:error, :write_quorum}
  # （绝不在权威介质仍持有该版本时宣告删除成功）。幂等：本就缺失的盘计入确认。
  defp do_delete_version(bucket, key, version_id, opts) do
    cfg = Config.load!(opts)

    with {:ok, dirs} <- object_dirs(bucket, key, version_id, cfg) do
      confirmed =
        Enum.count(dirs, fn dir ->
          _ = File.rm_rf(dir)
          not File.regular?(Path.join(dir, @meta_file))
        end)

      if confirmed >= cfg.write_quorum do
        :ok
      else
        Logger.error("erasure delete_version below write quorum",
          bucket: bucket,
          key: key,
          reason:
            "confirmed=#{confirmed} < write_quorum=#{cfg.write_quorum} version_id=#{version_id}"
        )

        {:error, :write_quorum}
      end
    end
  end

  defp do_put_notification_ledgers(_bucket, _key, [], _opts), do: :ok

  defp do_put_notification_ledgers(bucket, key, entries, opts) when is_list(entries) do
    cfg = Config.load!(opts)

    Enum.reduce_while(entries, :ok, fn entry, :ok ->
      case put_one_notification_ledger(bucket, key, entry, cfg, opts) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp put_one_notification_ledger(bucket, key, entry, cfg, opts) do
    with {:ok, id} <- notification_ledger_id(entry) do
      commit_pairs = notification_ledger_commit_pairs(bucket, key, id, cfg)

      tmps =
        commit_pairs |> Enum.map(fn {drive_root, _final} -> drive_root end) |> begin_tmp_dirs!()

      try do
        write_tmp_sidecars(tmps, NotificationLedger.sidecar(entry))
        ok_drives = commit_drives(tmps, commit_pairs, Keyword.put(opts, :meta_only, true))

        if ok_drives >= cfg.write_quorum do
          :ok
        else
          Logger.error("erasure notification ledger below write quorum",
            bucket: bucket,
            key: key,
            reason: "ok_drives=#{ok_drives} < write_quorum=#{cfg.write_quorum}"
          )

          rollback_commit(tmps, commit_pairs)
          {:error, :write_quorum}
        end
      rescue
        err ->
          cleanup_tmps(tmps)
          {:error, err}
      catch
        kind, reason ->
          cleanup_tmps(tmps)
          {:error, {kind, reason}}
      end
    end
  end

  defp do_list_notification_ledgers(bucket, :all, opts) do
    cfg = Config.load!(opts)

    with {:ok, replicas} <-
           read_notification_ledger_replicas(cfg.drives, fn drive ->
             drive
             |> Path.join(Maxio.Cluster.Paths.notification_ledger_bucket_rel(bucket))
             |> read_notification_ledger_replicas_under(
               bucket: bucket,
               read_fun: notification_ledger_read_fun(opts)
             )
           end) do
      {:ok, NotificationLedger.canonical_entries(replicas, cfg.read_quorum)}
    end
  end

  defp do_list_notification_ledgers(bucket, key, opts) when is_binary(key) do
    cfg = Config.load!(opts)

    with {:ok, replicas} <-
           read_notification_ledger_replicas(cfg.drives, fn drive ->
             drive
             |> Path.join(Maxio.Cluster.Paths.notification_ledger_key_rel(bucket, key))
             |> read_notification_ledger_replicas_under(
               bucket: bucket,
               key: key,
               read_fun: notification_ledger_read_fun(opts)
             )
           end) do
      {:ok, NotificationLedger.canonical_entries(replicas, cfg.read_quorum)}
    end
  end

  defp do_delete_notification_ledgers(_bucket, _key, [], _opts), do: :ok

  defp do_delete_notification_ledgers(bucket, key, ids, opts) when is_list(ids) do
    with {:ok, ids} <- notification_ledger_ids(ids) do
      cfg = Config.load!(opts)

      Enum.each(ids, fn id ->
        Enum.each(cfg.drives, fn drive ->
          _ =
            File.rm_rf(
              Path.join(drive, Maxio.Cluster.Paths.notification_ledger_entry_rel(bucket, key, id))
            )
        end)
      end)

      :ok
    end
  end

  defp do_put_bucket(bucket, opts) do
    cfg = Config.load!(opts)
    Enum.each(cfg.drives, fn d -> File.mkdir_p!(Path.join(d, bucket)) end)
    :ok
  end

  defp do_delete_bucket(bucket, opts) do
    cfg = Config.load!(opts)

    Enum.each(cfg.drives, fn d ->
      case File.rmdir(Path.join(d, bucket)) do
        :ok -> :ok
        {:error, :enoent} -> :ok
        # 其余盘上非空/出错忽略（与 FS 单盘 rmdir 语义对齐：仅删空目录）
        {:error, _} -> :ok
      end
    end)

    :ok
  end

  # ── 辅助 ──

  defp notification_ledger_commit_pairs(bucket, key, id, cfg) do
    rel = Maxio.Cluster.Paths.notification_ledger_entry_rel(bucket, key, id)
    Enum.map(cfg.drives, fn drive -> {drive, Path.join(drive, rel)} end)
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

  defp read_notification_ledger_replicas_under(root, context) do
    with {:ok, paths} <- notification_ledger_meta_paths(root) do
      read_notification_ledger_replica_paths(paths, context)
    end
  end

  defp read_notification_ledger_replica_paths(paths, context) do
    Enum.reduce_while(paths, {:ok, []}, fn path, {:ok, acc} ->
      case read_notification_ledger_replica(path, context) do
        {:ok, replicas} -> {:cont, {:ok, replicas ++ acc}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, replicas} -> {:ok, Enum.reverse(replicas)}
      {:error, _reason} = err -> err
    end
  end

  defp read_notification_ledger_replica(path, context) do
    with {:ok, bin} <- read_notification_ledger_meta(path, context),
         {:ok, replicas} <- decode_notification_ledger_replica(bin, path, context) do
      {:ok, replicas}
    end
  end

  defp read_notification_ledger_meta(path, context) do
    read_fun = Keyword.get(context, :read_fun, &File.read/1)

    case read_fun.(path) do
      {:ok, bin} -> {:ok, bin}
      {:error, reason} -> {:error, {:notification_ledger_read_failed, path, reason}}
      other -> {:error, {:notification_ledger_read_failed, path, other}}
    end
  rescue
    error -> {:error, {:notification_ledger_read_failed, path, error}}
  catch
    kind, reason -> {:error, {:notification_ledger_read_failed, path, {kind, reason}}}
  end

  defp decode_notification_ledger_replica(bin, path, context) do
    with meta <- Meta.decode!(bin),
         {:ok, entry} <- NotificationLedger.entry(meta),
         {:ok, id} <- NotificationLedger.validate_id(NotificationLedger.id(entry)) do
      {:ok, [{id, entry}]}
    else
      _ -> {:ok, [invalid_notification_ledger_replica(path, context)]}
    end
  rescue
    _ -> {:ok, [invalid_notification_ledger_replica(path, context)]}
  end

  defp notification_ledger_read_fun(opts),
    do: Keyword.get(opts, :notification_ledger_read_fun, &File.read/1)

  defp invalid_notification_ledger_replica(path, context) do
    path_id = notification_ledger_id_from_meta_path(path)
    {path_id, NotificationLedger.invalid_entry(path_id, "invalid_meta", context)}
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

  defp read_any_sidecar(dirs) do
    Enum.find_value(dirs, {:error, :enoent}, fn dir ->
      case File.read(Path.join(dir, @meta_file)) do
        {:ok, bin} -> {:ok, Meta.decode!(bin)}
        {:error, _} -> nil
      end
    end)
  end

  defp open_write!(path) do
    {:ok, fd} = File.open(path, [:write, :binary, :raw])
    fd
  end
end
