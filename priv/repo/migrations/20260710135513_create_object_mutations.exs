defmodule Maxio.Repo.Migrations.CreateObjectMutations do
  use Ecto.Migration

  @phases ~w(prepared claimed published metadata_committed finalize_pending finalized rollback_pending rolled_back quarantined)

  def up do
    create table(:object_mutations,
             primary_key: false,
             comment: "对象变更协议持久化日志；以 CAS 阶段推进协调发布、元数据提交、收尾、回滚与隔离"
           ) do
      add(:id, :binary_id,
        primary_key: true,
        comment: "变更 UUID；同时作为磁盘 epoch 的 mutation_id"
      )

      add(:target_kind, :string,
        null: false,
        comment: "目标类型：object_version、multipart_upload 或 multipart_part"
      )

      add(:bucket_name, :string, null: false, comment: "目标桶名")
      add(:object_key, :text, null: false, comment: "目标对象键，按原始 UTF-8 值保存")
      add(:version_id, :string, comment: "对象版本 ID；object_version 目标必填")
      add(:upload_id, :string, comment: "分段上传 ID；multipart 目标必填")
      add(:part_number, :integer, comment: "分段编号；multipart_part 目标必填且限定为 1 至 10000")
      add(:generation, :bigint, null: false, comment: "目标单调代次；与 mutation_id 组成全序 fencing token")
      add(:operation, :string, null: false, comment: "发起此次变更的操作名称")
      add(:authority_mode, :string, null: false, comment: "权威模式：pg 或 sidecar")
      add(:phase, :string, null: false, default: "prepared", comment: "CAS 推进的协议阶段")
      add(:backend, :string, null: false, comment: "执行变更的存储后端标识")
      add(:placement_snapshot, :map, comment: "变更开始时冻结的放置拓扑与后端参数")
      add(:previous_epoch, :map, comment: "claim 前观察到的上一代 epoch 证据")
      add(:published_fingerprint, :map, comment: "已发布 final 值及 sidecar 的精确指纹")
      add(:recovery_evidence, :map, comment: "恢复、重试或隔离判定所保留的结构化证据")
      add(:attempts, :integer, null: false, default: 0, comment: "恢复或收尾尝试次数")
      add(:next_attempt_at, :utc_datetime_usec, null: false, comment: "下一次允许恢复或收尾的时间")
      add(:lease_owner, :string, comment: "当前恢复租约持有者")
      add(:lease_expires_at, :utc_datetime_usec, comment: "当前恢复租约失效时间")
      add(:last_error, :text, comment: "最近一次失败的可审计原因")
      add(:metadata_committed_at, :utc_datetime_usec, comment: "权威元数据提交完成时间")
      add(:finalized_at, :utc_datetime_usec, comment: "备份与临时产物安全收尾完成时间")
      add(:rolled_back_at, :utc_datetime_usec, comment: "同锁同步回滚或经精确 fencing 验证后的回滚完成时间")
      add(:quarantined_at, :utc_datetime_usec, comment: "因证据不足而停止自动变更并隔离的时间")
      timestamps(type: :utc_datetime_usec)
    end

    create(
      constraint(:object_mutations, :object_mutations_phase_check,
        check: "phase IN (#{Enum.map_join(@phases, ", ", &("'" <> &1 <> "'"))})"
      )
    )

    create(
      constraint(:object_mutations, :object_mutations_generation_check,
        check: "generation >= 0 AND attempts >= 0"
      )
    )

    create(
      constraint(:object_mutations, :object_mutations_target_shape_check,
        check: """
        (target_kind = 'object_version' AND version_id IS NOT NULL AND upload_id IS NULL AND part_number IS NULL) OR
        (target_kind = 'multipart_upload' AND version_id IS NULL AND upload_id IS NOT NULL AND part_number IS NULL) OR
        (target_kind = 'multipart_part' AND version_id IS NULL AND upload_id IS NOT NULL AND part_number BETWEEN 1 AND 10000)
        """
      )
    )

    create(
      constraint(:object_mutations, :object_mutations_authority_mode_check,
        check: "authority_mode IN ('pg', 'sidecar')"
      )
    )

    create(
      constraint(:object_mutations, :object_mutations_lease_pair_check,
        check: """
        (lease_owner IS NULL AND lease_expires_at IS NULL) OR
        (lease_owner IS NOT NULL AND btrim(lease_owner) <> '' AND lease_expires_at IS NOT NULL)
        """
      )
    )

    create(
      constraint(:object_mutations, :object_mutations_locator_nonblank_check,
        check: """
        btrim(bucket_name) <> '' AND
        octet_length(object_key) BETWEEN 1 AND 1024 AND
        btrim(operation) <> '' AND btrim(backend) <> '' AND
        (version_id IS NULL OR btrim(version_id) <> '') AND
        (upload_id IS NULL OR btrim(upload_id) <> '')
        """
      )
    )

    create(
      constraint(:object_mutations, :object_mutations_phase_timestamp_check,
        check: """
        (metadata_committed_at IS NULL OR
          (authority_mode = 'pg' AND phase IN ('metadata_committed', 'finalize_pending', 'finalized', 'quarantined'))) AND
        (authority_mode <> 'pg' OR phase NOT IN ('metadata_committed', 'finalize_pending', 'finalized') OR
          metadata_committed_at IS NOT NULL) AND
        ((phase = 'finalized') = (finalized_at IS NOT NULL)) AND
        ((phase = 'rolled_back') = (rolled_back_at IS NOT NULL)) AND
        ((phase = 'quarantined') = (quarantined_at IS NOT NULL))
        """
      )
    )

    create(
      constraint(:object_mutations, :object_mutations_published_fingerprint_check,
        check: """
        phase NOT IN ('published', 'metadata_committed', 'finalize_pending', 'finalized') OR
        (published_fingerprint IS NOT NULL AND
         jsonb_typeof(published_fingerprint) = 'object' AND
         published_fingerprint ?& ARRAY['etag', 'size', 'sidecar_sha256'] AND
         published_fingerprint - ARRAY['etag', 'size', 'sidecar_sha256'] = '{}'::jsonb AND
         jsonb_typeof(published_fingerprint->'etag') = 'string' AND
         published_fingerprint->>'etag' <> '' AND
         jsonb_typeof(published_fingerprint->'size') = 'number' AND
         published_fingerprint->>'size' ~ '^[0-9]+$' AND
         jsonb_typeof(published_fingerprint->'sidecar_sha256') = 'string' AND
         published_fingerprint->>'sidecar_sha256' ~ '^[0-9a-f]{64}$')
        """
      )
    )

    create(
      index(:object_mutations, [:phase, :next_attempt_at],
        name: :obj_mut_due_idx,
        comment: "恢复器按阶段和下次执行时间领取待处理变更"
      )
    )

    create(
      index(:object_mutations, [:bucket_name, :object_key, :version_id, :inserted_at],
        name: :obj_mut_target_idx,
        comment: "按对象版本追溯完整变更历史"
      )
    )

    create(
      index(:object_mutations, [:upload_id, :part_number],
        name: :obj_mut_upload_idx,
        comment: "按 UploadId 与分段编号定位 multipart 变更"
      )
    )

    execute(
      "COMMENT ON CONSTRAINT object_mutations_pkey ON object_mutations IS '对象变更日志主键约束，保证 mutation_id 唯一'"
    )

    execute("COMMENT ON INDEX object_mutations_pkey IS '对象变更日志主键支撑索引，按 mutation_id 定位记录'")
    execute("COMMENT ON COLUMN object_mutations.inserted_at IS 'journal 记录创建时间'")
    execute("COMMENT ON COLUMN object_mutations.updated_at IS 'journal 最近一次 CAS 更新时间'")

    execute(
      "COMMENT ON CONSTRAINT object_mutations_phase_check ON object_mutations IS '阶段只能取协议定义的九个合法值'"
    )

    execute(
      "COMMENT ON CONSTRAINT object_mutations_generation_check ON object_mutations IS '代次与尝试次数不得为负数'"
    )

    execute(
      "COMMENT ON CONSTRAINT object_mutations_target_shape_check ON object_mutations IS '不同目标类型必须携带且只能携带对应定位字段，分段编号限定为 1 至 10000'"
    )

    execute(
      "COMMENT ON CONSTRAINT object_mutations_authority_mode_check ON object_mutations IS '权威来源只能是 PostgreSQL 或磁盘 sidecar'"
    )

    execute(
      "COMMENT ON CONSTRAINT object_mutations_lease_pair_check ON object_mutations IS '恢复租约持有者非空且与过期时间同时存在，或两者同时为空'"
    )

    execute(
      "COMMENT ON CONSTRAINT object_mutations_locator_nonblank_check ON object_mutations IS '桶、1 至 1024 字节对象键、操作、后端及已出现的版本或上传定位值不得为空'"
    )

    execute(
      "COMMENT ON CONSTRAINT object_mutations_phase_timestamp_check ON object_mutations IS '提交、完成、回滚与隔离时间戳必须和权威模式及当前阶段一致'"
    )

    execute(
      "COMMENT ON CONSTRAINT object_mutations_published_fingerprint_check ON object_mutations IS '发布及其后续成功阶段必须携带完整且规范的 final 指纹'"
    )
  end

  def down do
    execute("COMMENT ON CONSTRAINT object_mutations_pkey ON object_mutations IS NULL")
    execute("COMMENT ON INDEX object_mutations_pkey IS NULL")
    execute("COMMENT ON CONSTRAINT object_mutations_phase_check ON object_mutations IS NULL")
    execute("COMMENT ON CONSTRAINT object_mutations_generation_check ON object_mutations IS NULL")

    execute(
      "COMMENT ON CONSTRAINT object_mutations_target_shape_check ON object_mutations IS NULL"
    )

    execute(
      "COMMENT ON CONSTRAINT object_mutations_authority_mode_check ON object_mutations IS NULL"
    )

    execute("COMMENT ON CONSTRAINT object_mutations_lease_pair_check ON object_mutations IS NULL")

    execute(
      "COMMENT ON CONSTRAINT object_mutations_locator_nonblank_check ON object_mutations IS NULL"
    )

    execute(
      "COMMENT ON CONSTRAINT object_mutations_phase_timestamp_check ON object_mutations IS NULL"
    )

    execute(
      "COMMENT ON CONSTRAINT object_mutations_published_fingerprint_check ON object_mutations IS NULL"
    )

    execute("COMMENT ON COLUMN object_mutations.inserted_at IS NULL")
    execute("COMMENT ON COLUMN object_mutations.updated_at IS NULL")
    drop(table(:object_mutations))
  end
end
