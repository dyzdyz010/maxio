defmodule Maxio.Storage.EpochStore do
  @moduledoc """
  节点本地 durable epoch 串行执行器（ObjectMutation 协议 Phase 1 B1，实现计划 D1）。

  per-endpoint 的 epoch CAS（read-validate-write）必须原子，否则 fence 单调性被破坏
  （两个写者同读 gen=5 各写 gen=6 → lost update）；Windows 上 rename 覆盖已存在目标可能
  需要「先挪走旧文件再 rename 新文件」的两步窗口（窗口内 epoch 暂时 absent，而
  nil/:enoent 绝不能当授权）。因此同一 epoch 路径的所有读写经 PartitionSupervisor 按
  `{drive_root, epoch_rel_path}` 路由到同一 Worker 内串行执行——两步 rename 窗口对协议
  不可见，进程硬崩的残留由串行段内读侧自愈回位。

  锁序纪律（实现计划 R2）：Worker 串行段内**禁止**取 object lock、禁止调 Repo、禁止调
  其他 EpochStore worker、禁止任何网络/RPC——只做本机文件 IO。quorum 编排
  （EC/Distributed）永远在本模块之外。

  写入协议：同 drive 卷 temp 写 → fsync 文件 → 原子 rename 进位（`:eexist` 时串行段内
  两步替换）→ fsync 目录（复用 ShardServer fsync 原语与 `[:maxio, :durability, :fsync]`
  遥测）。损坏 epoch（JSON 坏/格式不识别/decode 拒绝）**永不静默覆盖**，原样上报
  `{:corrupt, reason}`（后端映射 quarantine 证据）。
  """

  alias Maxio.Cluster.ShardServer
  alias Maxio.Storage.{MutationBackup, ObjectEpoch, PublishedProof}

  @call_timeout 30_000
  # 两步 rename 的暂存名固定：串行段内独占无并发冲突，crash 残留由 read 自愈回位。
  @stale_suffix ".stale"
  @tmp_suffix ".tmp"
  @restore_phases ~w(claimed published)
  @proof_phases ~w(published committed)
  @sidecar_limit 16 * 1024 * 1024
  @verify_request_keys [
    :expected_fingerprint,
    :final_rel,
    :layout,
    :mutation_id,
    :target,
    :token
  ]

  @typedoc """
  CAS 前置条件：
    * `{:claim, proposed}`——接受当前 absent 或 current_token < proposed（fence 全序，
      endpoint 仅接受严格更大 token 的 claim）；
    * `{:exact, token, allowed_phases}`——当前 token 必须精确相等且 phase 在允许集内；
      epoch absent 一律 `{:error, :epoch_missing}`（绝不把 nil/:enoent 当授权落点）。
  """
  @type expect ::
          {:claim, ObjectEpoch.token()}
          | {:exact, ObjectEpoch.token(), [String.t()]}

  @doc "读 target 在该 drive 上的 durable epoch（串行段内执行）。"
  @spec read(String.t(), ObjectEpoch.target(), keyword()) ::
          {:ok, ObjectEpoch.t()} | {:ok, :absent} | {:error, term()}
  def read(drive_root, target, opts \\ []) do
    with {:ok, rel} <- ObjectEpoch.relative_path(target) do
      serialize(drive_root, rel, fn -> do_read(epoch_path(drive_root, rel)) end, opts)
    end
  end

  @doc """
  epoch CAS：串行段内读当前 → 校验 `expect` → temp 写 + fsync + 原子 rename 进位。
  `next.token` 必须与 expect 中的 token 一致（claim 的 proposed / exact 的持有 token）。
  """
  @spec cas(String.t(), ObjectEpoch.t(), expect(), keyword()) ::
          {:ok, :applied}
          | {:error, {:fenced, map() | nil}}
          | {:error, :epoch_missing}
          | {:error, term()}
  def cas(drive_root, %ObjectEpoch{} = next, expect, opts \\ []) do
    with {:ok, rel} <- ObjectEpoch.relative_path(next.target),
         :ok <- validate_expect_shape(next, expect) do
      serialize(
        drive_root,
        rel,
        fn -> do_cas(epoch_path(drive_root, rel), next, expect, opts) end,
        opts
      )
    end
  end

  @doc """
  per-endpoint 恢复原语（单次串行原子调用，避免多轮调用交错）：完成 exact-token/phase
  与 manifest 身份校验后，fresh manifest 先幂等删除 final，再将 epoch 收敛为
  rolled_back；overwrite 则在 epoch 收敛后把 backup entries rename 回 final，最后清 backup。
  request = `%{target, token, mutation_id, final_rel}`。语义（协议 §3.3）：
    * successor（当前 token 更大）→ `{:ok, :superseded}`，绝不触碰 final/backup；
    * `committed` epoch 即使 token 匹配也拒绝（`{:error, :epoch_committed}`，
      metadata_committed 禁回滚的端点级防线）；
    * epoch absent → `{:error, :epoch_missing}`，绝不删/恢复任何字节；
    * `rolled_back` 幂等重放同一 manifest plan（继续 fresh 删除或 overwrite 恢复并清理 backup）。
  """
  @spec restore_mutation(String.t(), map(), keyword()) ::
          {:ok, :restored} | {:ok, :superseded} | {:error, term()}
  def restore_mutation(drive_root, request, opts \\ [])

  def restore_mutation(
        drive_root,
        %{target: target, token: token, mutation_id: mutation_id, final_rel: final_rel},
        opts
      )
      when is_binary(final_rel) do
    with {:ok, rel} <- ObjectEpoch.relative_path(target),
         {:ok, token} <- validate_token(token),
         {:ok, mutation_id} <- validate_owned_mutation_id(token, mutation_id),
         {:ok, final_rel} <- validate_final_rel(final_rel) do
      backup_dir = Path.join(drive_root, MutationBackup.relative_dir(mutation_id))
      final_dir = Path.join(drive_root, final_rel)

      serialize(
        drive_root,
        rel,
        fn ->
          do_restore(epoch_path(drive_root, rel), token, backup_dir, final_dir, target, opts)
        end,
        opts
      )
    end
  end

  def restore_mutation(_drive_root, request, _opts),
    do: {:error, {:invalid_mutation_request, request}}

  @doc """
  per-endpoint 终结原语：token 精确匹配且 phase ∈ published/committed（幂等）→ epoch →
  committed + 丢弃 backup 目录。request = `%{target, token, mutation_id}`；successor →
  `{:ok, :superseded}`。
  """
  @spec finalize_mutation(String.t(), map(), keyword()) ::
          {:ok, :finalized} | {:ok, :superseded} | {:error, term()}
  def finalize_mutation(drive_root, request, opts \\ [])

  def finalize_mutation(
        drive_root,
        %{target: target, token: token, mutation_id: mutation_id},
        opts
      ) do
    with {:ok, rel} <- ObjectEpoch.relative_path(target),
         {:ok, token} <- validate_token(token),
         {:ok, mutation_id} <- validate_owned_mutation_id(token, mutation_id) do
      backup_dir = Path.join(drive_root, MutationBackup.relative_dir(mutation_id))

      serialize(
        drive_root,
        rel,
        fn -> do_finalize(epoch_path(drive_root, rel), token, backup_dir, opts) end,
        opts
      )
    end
  end

  def finalize_mutation(_drive_root, request, _opts),
    do: {:error, {:invalid_mutation_request, request}}

  @doc """
  在 target 的 epoch 串行段内验证已发布 final 的 exact epoch/raw-sidecar fingerprint 与
  物理 part 形状。standalone proof 只接受 published/committed；successor 在任何 final
  探测前短路为 `:superseded`。响应由 `PublishedProof` 限界，绝不包含绝对路径或 sidecar。
  """
  @spec verify_mutation(String.t(), map(), keyword()) :: PublishedProof.proof_result()
  def verify_mutation(drive_root, request, opts \\ [])

  def verify_mutation(drive_root, request, opts)
      when is_binary(drive_root) and is_map(request) do
    case validate_verify_request(request) do
      {:ok, normalized} ->
        serialize(
          drive_root,
          normalized.epoch_rel,
          fn ->
            do_verify_mutation(
              epoch_path(drive_root, normalized.epoch_rel),
              drive_root,
              normalized,
              opts
            )
          end,
          opts
        )

      {:error, code} ->
        PublishedProof.failed(:corrupt, "local", %{code: code, owned: false})
    end
  end

  def verify_mutation(_drive_root, _request, _opts),
    do: PublishedProof.failed(:corrupt, "local", %{code: :invalid_request, owned: false})

  @doc "epoch → 纯数据 payload map（erpc 传输/ShardServer 响应用；与磁盘 JSON 同形）。"
  @spec payload(ObjectEpoch.t()) :: {:ok, map()} | {:error, term()}
  def payload(%ObjectEpoch{} = epoch) do
    with {:ok, bytes} <- ObjectEpoch.encode(epoch), do: Jason.decode(bytes)
  end

  # ── 串行段内实现（Worker 内执行；只做本机文件 IO）──

  defp do_read(path) do
    case File.read(path) do
      {:ok, bytes} -> decode_epoch(bytes)
      {:error, :enoent} -> read_stale_fallback(path)
      {:error, reason} -> {:error, reason}
    end
  end

  # 两步替换在 rename 间硬崩的残留自愈：epoch.json 缺失但 .stale 在 → 串行段内先挪回
  # 再读（absent 判定绝不吞掉仍然耐久的旧 epoch——nil/:enoent 不当授权的第一道防线）。
  defp read_stale_fallback(path) do
    case :file.rename(path <> @stale_suffix, path) do
      :ok ->
        case File.read(path) do
          {:ok, bytes} -> decode_epoch(bytes)
          {:error, :enoent} -> {:ok, :absent}
          {:error, reason} -> {:error, reason}
        end

      {:error, :enoent} ->
        {:ok, :absent}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp decode_epoch(bytes) do
    case ObjectEpoch.decode(bytes) do
      {:ok, epoch} -> {:ok, epoch}
      {:error, reason} -> {:error, {:corrupt, reason}}
    end
  end

  defp do_cas(path, next, expect, opts) do
    with {:ok, current} <- do_read(path),
         :ok <- check_expect(current, expect) do
      write_epoch(path, next, opts)
    end
  end

  defp check_expect(:absent, {:claim, _proposed}), do: :ok
  defp check_expect(:absent, {:exact, _token, _phases}), do: {:error, :epoch_missing}

  defp check_expect(%ObjectEpoch{} = current, {:claim, proposed}) do
    case ObjectEpoch.compare_tokens(current.token, proposed) do
      # fence 全序：endpoint 仅接受严格更大 token 的 claim（同 token 重复 claim 也拒绝）。
      {:ok, :lt} -> :ok
      {:ok, _order} -> {:error, {:fenced, current.token}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp check_expect(%ObjectEpoch{} = current, {:exact, token, phases}) do
    case ObjectEpoch.compare_tokens(current.token, token) do
      {:ok, :eq} ->
        if current.phase in phases, do: :ok, else: {:error, {:fenced, current.token}}

      {:ok, _order} ->
        {:error, {:fenced, current.token}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp do_restore(epoch_path, token, backup_dir, final_dir, target, opts) do
    case do_read(epoch_path) do
      {:ok, :absent} ->
        # nil/:enoent 绝不当授权：不删、不恢复任何字节。
        {:error, :epoch_missing}

      {:ok, %ObjectEpoch{} = current} ->
        case ObjectEpoch.compare_tokens(current.token, token) do
          # successor 已建立：只报告，绝不触碰 successor 的 final/backup。
          {:ok, :gt} ->
            {:ok, :superseded}

          # 当前 epoch 比调用者还旧：证据矛盾（claim 应已写下本 token），拒绝并上报。
          {:ok, :lt} ->
            {:error, {:epoch_mismatch, current.token}}

          {:ok, :eq} ->
            restore_owned(current, epoch_path, backup_dir, final_dir, target, token, opts)

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # metadata_committed 禁回滚的端点级防线：committed epoch 即使 token 匹配也拒绝恢复。
  defp restore_owned(%ObjectEpoch{phase: "committed"}, _path, _backup, _final, _target, _tok, _o),
    do: {:error, :epoch_committed}

  # 幂等重放：epoch 已 rolled_back，但上次执行可能在 fresh 删除后的 backup 清理，或
  # overwrite 的「rename 回 final」中途崩溃——重放同一 plan 后再返回 :restored。
  defp restore_owned(
         %ObjectEpoch{phase: "rolled_back"},
         _epoch_path,
         backup_dir,
         final_dir,
         target,
         token,
         opts
       ) do
    with {:ok, plan} <- read_backup_plan(backup_dir, target, token, :optional),
         :ok <- prepare_backup_plan(plan, final_dir, opts),
         :ok <- apply_backup_plan(plan, backup_dir, final_dir, opts) do
      {:ok, :restored}
    end
  end

  defp restore_owned(
         %ObjectEpoch{phase: phase} = current,
         epoch_path,
         backup_dir,
         final_dir,
         target,
         token,
         opts
       )
       when phase in @restore_phases do
    # published 必有 manifest（B2 起 manifest 先于备份物化与 publish CAS 落盘）；缺失即
    # 证据矛盾，在翻转 epoch 之前拒绝——否则幂等重放会把「旧字节尚未恢复」误判为已收敛。
    requirement = if phase == "published", do: :required, else: :optional
    rolled = %ObjectEpoch{current | phase: "rolled_back", updated_at: DateTime.utc_now()}

    with {:ok, plan} <- read_backup_plan(backup_dir, target, token, requirement),
         :ok <- prepare_backup_plan(plan, final_dir, opts),
         {:ok, :applied} <- write_epoch(epoch_path, rolled, opts),
         :ok <- apply_backup_plan(plan, backup_dir, final_dir, opts) do
      {:ok, :restored}
    end
  end

  defp restore_owned(%ObjectEpoch{phase: phase}, _path, _backup, _final, _target, _tok, _opts),
    do: {:error, {:unexpected_epoch_phase, phase}}

  defp read_backup_plan(backup_dir, target, token, requirement) do
    case File.read(Path.join(backup_dir, MutationBackup.manifest_name())) do
      {:ok, bytes} ->
        with {:ok, manifest} <- decode_manifest(bytes),
             :ok <- validate_manifest_identity(manifest, target, token) do
          {:ok, {:manifest, manifest}}
        end

      {:error, :enoent} ->
        case requirement do
          :required -> {:error, :backup_manifest_missing}
          :optional -> {:ok, :none}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp decode_manifest(bytes) do
    case MutationBackup.decode(bytes) do
      {:ok, manifest} -> {:ok, manifest}
      {:error, reason} -> {:error, {:corrupt, {:backup_manifest, reason}}}
    end
  end

  # manifest 与请求身份（target digest + token）不符即证据矛盾——不猜测、不恢复。
  defp validate_manifest_identity(manifest, target, token) do
    with {:ok, :eq} <- ObjectEpoch.compare_tokens(manifest.token, token),
         {:ok, manifest_digest} <- ObjectEpoch.target_digest(manifest.target),
         {:ok, request_digest} <- ObjectEpoch.target_digest(target),
         true <- manifest_digest == request_digest do
      :ok
    else
      _mismatch -> {:error, {:corrupt, :backup_manifest_mismatch}}
    end
  end

  # fresh manifest 明确表示 previous value absent：先于 epoch 写入幂等删除本 mutation 的 final。
  defp prepare_backup_plan(
         {:manifest, %MutationBackup{entries: [], previous_token: nil}},
         final_dir,
         opts
       ),
       do: discard_final_dir(final_dir, opts)

  defp prepare_backup_plan(_plan, _final_dir, _opts), do: :ok

  # 无 manifest（claimed 阶段 publish 从未开始）：final 未被触碰，仅清残留备份目录。
  defp apply_backup_plan(:none, backup_dir, _final_dir, _opts), do: discard_dir(backup_dir)

  defp apply_backup_plan(
         {:manifest, %MutationBackup{entries: [], previous_token: nil}},
         backup_dir,
         _final_dir,
         _opts
       ),
       do: discard_dir(backup_dir)

  defp apply_backup_plan({:manifest, manifest}, backup_dir, final_dir, opts) do
    fsync? = fsync?(opts)

    with :ok <- File.mkdir_p(final_dir),
         :ok <- restore_entries(MutationBackup.entry_names(manifest), backup_dir, final_dir),
         :ok <- maybe_sync_dir(fsync?, final_dir) do
      discard_dir(backup_dir)
    end
  end

  defp restore_entries(names, backup_dir, final_dir) do
    Enum.reduce_while(names, :ok, fn name, :ok ->
      case rename_replace(Path.join(backup_dir, name), Path.join(final_dir, name)) do
        :ok -> {:cont, :ok}
        # 上次中途崩溃后该 entry 已回位：幂等跳过。
        {:error, :enoent} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, {:restore_entry_failed, name, reason}}}
      end
    end)
  end

  defp do_finalize(epoch_path, token, backup_dir, opts) do
    case do_read(epoch_path) do
      {:ok, :absent} ->
        {:error, :epoch_missing}

      {:ok, %ObjectEpoch{} = current} ->
        case ObjectEpoch.compare_tokens(current.token, token) do
          {:ok, :gt} -> {:ok, :superseded}
          {:ok, :lt} -> {:error, {:epoch_mismatch, current.token}}
          {:ok, :eq} -> finalize_owned(current, epoch_path, backup_dir, opts)
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # 幂等重放：epoch 已 committed，但上次可能在 discard backup 前崩溃——收敛清理后返回。
  defp finalize_owned(%ObjectEpoch{phase: "committed"}, _epoch_path, backup_dir, _opts) do
    with :ok <- discard_dir(backup_dir), do: {:ok, :finalized}
  end

  defp finalize_owned(%ObjectEpoch{phase: "published"} = current, epoch_path, backup_dir, opts) do
    committed = %ObjectEpoch{current | phase: "committed", updated_at: DateTime.utc_now()}

    with {:ok, :applied} <- write_epoch(epoch_path, committed, opts),
         :ok <- discard_dir(backup_dir) do
      {:ok, :finalized}
    end
  end

  defp finalize_owned(%ObjectEpoch{phase: phase}, _epoch_path, _backup_dir, _opts),
    do: {:error, {:unexpected_epoch_phase, phase}}

  # Task 2 的 proof-aware finalize 必须在同一 EpochStore 串行闭包内复用这一函数；
  # standalone?/claimed-repair 的差异只允许在进入本 proof 核心前显式裁决，不能复制盘上校验。
  defp do_verify_mutation(epoch_path, drive_root, request, opts) do
    case do_read(epoch_path) do
      {:ok, :absent} ->
        proof_failure(:corrupt, :epoch_missing, false, request)

      {:ok, %ObjectEpoch{} = current} ->
        verify_current_epoch(current, drive_root, request, opts)

      {:error, {:corrupt, _reason}} ->
        proof_failure(:corrupt, :epoch_corrupt, false, request)

      {:error, reason} ->
        proof_failure(io_class(reason), :epoch_unavailable, false, request)
    end
  end

  defp verify_current_epoch(current, drive_root, request, opts) do
    case ObjectEpoch.compare_tokens(current.token, request.token) do
      {:ok, :gt} ->
        PublishedProof.superseded(endpoint_identity(request.layout))

      {:ok, :lt} ->
        proof_failure(:corrupt, :old_epoch, false, request)

      {:ok, :eq} ->
        verify_owned_epoch(current, drive_root, request, opts)

      {:error, _reason} ->
        proof_failure(:corrupt, :invalid_epoch_token, false, request)
    end
  end

  defp verify_owned_epoch(%ObjectEpoch{} = current, drive_root, request, opts) do
    cond do
      current.phase not in @proof_phases ->
        proof_failure(:corrupt, :unexpected_phase, true, request)

      current.value_type != "object" ->
        proof_failure(:corrupt, :invalid_value_type, true, request)

      not ObjectEpoch.fingerprint_matches?(request.expected_fingerprint, current.fingerprint) ->
        proof_failure(:mismatch, :epoch_fingerprint_mismatch, true, request)

      true ->
        verify_final(current, drive_root, request, opts)
    end
  end

  defp verify_final(current, drive_root, request, opts) do
    final_dir = Path.join(drive_root, request.final_rel)
    meta_path = Path.join(final_dir, "meta.json")

    with {:ok, raw_meta} <- read_bounded_regular(meta_path, opts),
         {:ok, core} <- decode_durable_core(raw_meta),
         actual <-
           ObjectEpoch.fingerprint(
             core.etag,
             core.size,
             raw_meta
           ),
         :ok <- match_actual_fingerprint(request.expected_fingerprint, actual),
         {:ok, expected_part_size} <- expected_part_size(core.meta, core.size, request.layout),
         :ok <-
           verify_regular_part(Path.join(final_dir, "part.0"), expected_part_size, opts) do
      PublishedProof.verified(endpoint_identity(request.layout), %{
        layout: layout_label(request.layout),
        owned: true,
        phase: current.phase
      })
    else
      {:proof_error, class, code} ->
        proof_failure(class, code, true, request)
    end
  end

  defp read_bounded_regular(path, opts) do
    case lstat(path, opts) do
      {:ok, %File.Stat{type: :regular, size: size}} when size <= @sidecar_limit ->
        read_bounded(path)

      {:ok, %File.Stat{type: :regular}} ->
        {:proof_error, :corrupt, :sidecar_too_large}

      {:ok, %File.Stat{}} ->
        {:proof_error, :corrupt, :sidecar_not_regular}

      {:error, :enoent} ->
        {:proof_error, :corrupt, :sidecar_missing}

      {:error, reason} ->
        {:proof_error, io_class(reason), :sidecar_unavailable}
    end
  end

  # limit+1 的单次有界读取避免 TOCTOU 增长把 sidecar 全量拉入内存。
  defp read_bounded(path) do
    case File.open(path, [:read, :binary]) do
      {:ok, io} ->
        result =
          case IO.binread(io, @sidecar_limit + 1) do
            bytes when is_binary(bytes) and byte_size(bytes) <= @sidecar_limit ->
              {:ok, bytes}

            bytes when is_binary(bytes) ->
              {:proof_error, :corrupt, :sidecar_too_large}

            :eof ->
              {:ok, ""}

            {:error, reason} ->
              {:proof_error, io_class(reason), :sidecar_unavailable}
          end

        _ = File.close(io)
        result

      {:error, :enoent} ->
        {:proof_error, :corrupt, :sidecar_missing}

      {:error, reason} ->
        {:proof_error, io_class(reason), :sidecar_unavailable}
    end
  end

  defp decode_durable_core(raw_meta) do
    case Jason.decode(raw_meta) do
      {:ok, %{} = meta} ->
        etag = Map.get(meta, "etag")
        size = Map.get(meta, "size")

        if is_binary(etag) and etag != "" and is_integer(size) and size >= 0 do
          {:ok, %{etag: etag, size: size, meta: meta}}
        else
          {:proof_error, :corrupt, :invalid_sidecar_core}
        end

      {:ok, _non_map} ->
        {:proof_error, :corrupt, :invalid_sidecar_shape}

      {:error, _reason} ->
        {:proof_error, :corrupt, :invalid_sidecar_json}
    end
  end

  defp match_actual_fingerprint(expected, actual) do
    if ObjectEpoch.fingerprint_matches?(expected, actual),
      do: :ok,
      else: {:proof_error, :mismatch, :final_fingerprint_mismatch}
  end

  defp expected_part_size(_meta, core_size, %{kind: "fs"}), do: {:ok, core_size}

  defp expected_part_size(meta, _core_size, %{kind: "shard", index: index}) do
    with shards when is_list(shards) <- Map.get(meta, "shards"),
         :ok <- validate_shard_metadata(shards),
         %{"drive" => ^index} = entry <- Enum.at(shards, index) do
      {:ok, Map.fetch!(entry, "shard_file_size")}
    else
      _invalid -> {:proof_error, :corrupt, :invalid_shard_metadata}
    end
  end

  defp validate_shard_metadata(shards) do
    valid? =
      shards
      |> Enum.with_index()
      |> Enum.all?(fn
        {%{"drive" => drive, "shard_file_size" => size}, index}
        when is_integer(drive) and drive == index and is_integer(size) and size >= 0 ->
          true

        _invalid ->
          false
      end)

    if shards != [] and valid? do
      :ok
    else
      {:error, :invalid_shard_metadata}
    end
  end

  defp verify_regular_part(path, expected_size, opts) do
    case lstat(path, opts) do
      {:ok, %File.Stat{type: :regular, size: ^expected_size}} ->
        :ok

      {:ok, %File.Stat{type: :regular}} ->
        {:proof_error, :mismatch, :part_size_mismatch}

      {:ok, %File.Stat{}} ->
        {:proof_error, :corrupt, :part_not_regular}

      {:error, :enoent} ->
        {:proof_error, :corrupt, :part_missing}

      {:error, reason} ->
        {:proof_error, io_class(reason), :part_unavailable}
    end
  end

  defp proof_failure(class, code, owned?, request) do
    PublishedProof.failed(class, endpoint_identity(request.layout), %{
      code: code,
      layout: layout_label(request.layout),
      owned: owned?
    })
  end

  defp layout_label(%{kind: "fs"}), do: "fs"
  defp layout_label(%{kind: "shard", index: index}), do: "shard:#{index}"
  defp endpoint_identity(%{kind: "fs"}), do: "local"
  defp endpoint_identity(%{kind: "shard", index: index}), do: index

  defp validate_verify_request(request) do
    with true <- Map.keys(request) |> Enum.sort() == @verify_request_keys,
         %{"kind" => "object_version"} <- request.target,
         {:ok, epoch_rel} <- ObjectEpoch.relative_path(request.target),
         {:ok, token} <- validate_token(request.token),
         {:ok, mutation_id} <-
           validate_owned_mutation_id(token, request.mutation_id),
         {:ok, final_rel} <- validate_final_rel(request.final_rel),
         true <-
           ObjectEpoch.fingerprint_matches?(
             request.expected_fingerprint,
             request.expected_fingerprint
           ),
         {:ok, layout} <- validate_layout(request.layout) do
      {:ok,
       %{
         epoch_rel: epoch_rel,
         expected_fingerprint: request.expected_fingerprint,
         final_rel: final_rel,
         layout: layout,
         mutation_id: mutation_id,
         target: request.target,
         token: token
       }}
    else
      _invalid -> {:error, :invalid_request}
    end
  end

  defp validate_layout(%{kind: "fs"} = layout) when map_size(layout) == 1, do: {:ok, layout}

  defp validate_layout(%{kind: "shard", index: index} = layout)
       when map_size(layout) == 2 and is_integer(index) and index >= 0,
       do: {:ok, layout}

  defp validate_layout(_layout), do: {:error, :invalid_layout}

  defp io_class(reason) when reason in [:eacces, :eio], do: :unavailable
  defp io_class(_reason), do: :unavailable

  defp lstat(path, opts) do
    case Keyword.get(opts, :lstat) do
      fun when is_function(fun, 1) -> fun.(path)
      _other -> File.lstat(path)
    end
  end

  defp discard_dir(dir) do
    case File.rm_rf(dir) do
      {:ok, _paths} -> :ok
      {:error, reason, _file} -> {:error, {:backup_discard_failed, reason}}
    end
  end

  defp discard_final_dir(final_dir, opts) do
    case File.rm_rf(final_dir) do
      {:ok, _paths} -> maybe_sync_existing_dir(fsync?(opts), Path.dirname(final_dir))
      {:error, reason, file} -> {:error, {:final_discard_failed, file, reason}}
    end
  end

  defp maybe_sync_existing_dir(false, _dir), do: :ok

  defp maybe_sync_existing_dir(true, dir) do
    if File.dir?(dir), do: maybe_sync_dir(true, dir), else: :ok
  end

  # 写入协议：temp 写 → fsync 文件 → 原子 rename 进位 → fsync 目录。失败清 temp，
  # 绝不留半写文件冒充 epoch。
  defp write_epoch(path, %ObjectEpoch{} = epoch, opts) do
    fsync? = fsync?(opts)
    dir = Path.dirname(path)
    tmp = path <> @tmp_suffix

    with {:ok, bytes} <- ObjectEpoch.encode(epoch),
         :ok <- File.mkdir_p(dir),
         :ok <- File.write(tmp, bytes),
         :ok <- maybe_sync_path(fsync?, tmp),
         :ok <- rename_replace(tmp, path),
         :ok <- maybe_sync_dir(fsync?, dir) do
      {:ok, :applied}
    else
      {:error, reason} ->
        _ = File.rm(tmp)
        {:error, reason}
    end
  end

  # 原子 rename 进位；Windows 覆盖已存在目标 `:eexist` 时串行段内两步替换
  # （先把旧目标挪到 <dst>.stale，再 rename 新文件；失败则把旧目标挪回——
  # 「替换失败」绝不留成 absent，见风险 R3）。
  defp rename_replace(src, dst) do
    case :file.rename(src, dst) do
      :ok -> :ok
      {:error, :eexist} -> replace_two_step(src, dst)
      {:error, reason} -> {:error, reason}
    end
  end

  defp replace_two_step(src, dst) do
    stale = dst <> @stale_suffix
    _ = File.rm(stale)

    case :file.rename(dst, stale) do
      :ok ->
        case :file.rename(src, dst) do
          :ok ->
            _ = File.rm(stale)
            :ok

          {:error, reason} ->
            _ = :file.rename(stale, dst)
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp validate_token(token) do
    case ObjectEpoch.compare_tokens(token, token) do
      {:ok, :eq} -> {:ok, token}
      {:error, reason} -> {:error, reason}
    end
  end

  # backup 目录由 mutation_id 定位、由 token 授权：两者必须指向同一 mutation。
  defp validate_owned_mutation_id(token, mutation_id) do
    with {:ok, id} <- MutationBackup.validate_mutation_id(mutation_id) do
      if token["mutation_id"] == id, do: {:ok, id}, else: {:error, :mutation_id_mismatch}
    end
  end

  # final_rel 会成为 Path.join(drive_root, final_rel) 的盘上回位落点，且经 erpc 暴露面
  # 可达（B4 收口，B1 遗留 2）：拒绝绝对/盘符相对路径、反斜杠、NUL、空段与点段——与
  # mutation_id/manifest entry 名防线对称，绝不放行逃出 drive 根的回位目标。
  defp validate_final_rel(final_rel) when is_binary(final_rel) do
    invalid? =
      final_rel == "" or
        Path.type(final_rel) != :relative or
        String.contains?(final_rel, ["\\", <<0>>]) or
        Enum.any?(String.split(final_rel, "/"), &(&1 in ["", ".", ".."]))

    if invalid?, do: {:error, {:invalid_final_rel, final_rel}}, else: {:ok, final_rel}
  end

  defp validate_expect_shape(next, {:claim, proposed}) do
    case ObjectEpoch.compare_tokens(next.token, proposed) do
      {:ok, :eq} -> :ok
      {:ok, _order} -> {:error, :expect_token_mismatch}
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_expect_shape(next, {:exact, token, phases}) when is_list(phases) do
    with true <- phases != [] and Enum.all?(phases, &is_binary/1),
         {:ok, :eq} <- ObjectEpoch.compare_tokens(next.token, token) do
      :ok
    else
      false -> {:error, :invalid_expect}
      {:ok, _order} -> {:error, :expect_token_mismatch}
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_expect_shape(_next, _expect), do: {:error, :invalid_expect}

  defp maybe_sync_path(false, _path), do: :ok
  defp maybe_sync_path(true, path), do: ShardServer.sync_path(path)
  defp maybe_sync_dir(false, _dir), do: :ok
  defp maybe_sync_dir(true, dir), do: ShardServer.sync_dir(dir)

  # opts[:fsync] 显式覆盖；否则读 config :maxio, :durability, fsync:（与 ShardServer 同源）。
  defp fsync?(opts) do
    case Keyword.fetch(opts, :fsync) do
      {:ok, value} -> value
      :error -> Application.get_env(:maxio, :durability, [])[:fsync] || false
    end
  end

  # 同一 epoch 路径恒路由同一 partition worker（PartitionSupervisor 按 key phash2 路由），
  # 所有读写在 worker 内串行执行。
  defp serialize(drive_root, rel, fun, opts) do
    name = Keyword.get(opts, :epoch_store, __MODULE__)
    timeout = Keyword.get(opts, :epoch_store_timeout, @call_timeout)

    GenServer.call(
      {:via, PartitionSupervisor, {name, {drive_root, rel}}},
      {:run, fun},
      timeout
    )
  end

  defp epoch_path(drive_root, rel), do: Path.join(drive_root, rel)
end
