defmodule Maxio.Repo.Migrations.CreateRuntimeConfigs do
  use Ecto.Migration

  # 因含裸 execute（CHECK 约束 + COMMENT ON CONSTRAINT），用 up/down 而非 change：
  # down 逐条把注释置 NULL、删约束，保证迁移可逆（对齐 20260613153149 拓扑版本链迁移）。
  def up do
    create table(:runtime_configs,
             primary_key: false,
             comment: "运行时配置存储；每个白名单配置键一行，是集群配置覆盖值的单一事实来源，优先级高于 env var 与编译期默认"
           ) do
      add :id, :binary_id, primary_key: true, comment: "运行时配置行 UUID 主键"

      add :subsystem, :string,
        null: false,
        comment:
          "配置子系统名；对应 Application env 的第二级键，如 durability / listing / s3 / cluster，或模块名字符串如 Elixir.Maxio.S3.Endpoint"

      add :key, :string,
        null: false,
        comment: "子系统内的配置键名，如 sql_hard_limit / clock_skew_ms；与 subsystem 组成白名单查表主键"

      add :value, :map,
        null: false,
        comment:
          "配置值的 JSON 包装 %{\"v\" => 值}；统一包成 object 以便存储标量、列表与 map，读取时按 Maxio.Config.Schema 声明的类型解码"

      add :previous_value, :map, comment: "上一版配置值的 JSON 包装；NULL 表示这是该键的首次覆盖，供快速回滚与漂移取证"

      add :version, :integer,
        null: false,
        default: 1,
        comment: "该键的单调递增版本号；写路径以 expected_version 做乐观并发，冲突返回结构化错误而非静默覆盖"

      add :apply_mode, :string,
        null: false,
        comment: "生效方式快照：hot 表示下一次读即生效，next_cycle 表示下一轮调度生效，restart 表示已持久化但需重启节点才生效"

      add :updated_by, :string, comment: "最后一次写入者的 principal ARN；CLI 写入记为实际操作者或 NULL，供审计追溯"

      add :source, :string,
        null: false,
        comment:
          "最后一次写入来源：admin_api / cli / console / system；system 专指首启自动引导（如 deployment_id），区分变更通道以便定位误操作"

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:runtime_configs, [:subsystem, :key],
             name: :runtime_configs_subsystem_key_index,
             comment: "运行时配置键唯一索引；同一 subsystem 下同名键最多一行，保证配置无歧义"
           )

    create index(:runtime_configs, [:updated_at],
             name: :runtime_configs_updated_at_index,
             comment: "按更新时间检索配置变更；供节点缓存对账与最近变更取证"
           )

    execute("""
    ALTER TABLE runtime_configs
      ADD CONSTRAINT runtime_configs_apply_mode_check
      CHECK (apply_mode IN ('hot', 'next_cycle', 'restart'))
    """)

    execute("""
    COMMENT ON CONSTRAINT runtime_configs_apply_mode_check ON runtime_configs IS
    '生效方式白名单约束；禁止写入未知 apply_mode，避免运维误判配置是否已生效'
    """)

    execute("""
    ALTER TABLE runtime_configs
      ADD CONSTRAINT runtime_configs_source_check
      CHECK (source IN ('admin_api', 'cli', 'console', 'system'))
    """)

    execute("""
    COMMENT ON CONSTRAINT runtime_configs_source_check ON runtime_configs IS
    '变更来源白名单约束；禁止写入未知来源，保证审计通道可枚举'
    """)

    execute("""
    ALTER TABLE runtime_configs
      ADD CONSTRAINT runtime_configs_version_positive_check
      CHECK (version >= 1)
    """)

    execute("""
    COMMENT ON CONSTRAINT runtime_configs_version_positive_check ON runtime_configs IS
    '版本号下界约束；乐观并发以版本单调递增为前提，非正版本会让冲突判定失去意义'
    """)

    execute("COMMENT ON COLUMN runtime_configs.inserted_at IS '该配置键首次被覆盖的时间'")
    execute("COMMENT ON COLUMN runtime_configs.updated_at IS '该配置键最后一次变更时间'")

    create table(:runtime_config_audits,
             primary_key: false,
             comment: "运行时配置变更审计流水；只追加不修改，记录每次 set/reset 的前后值与操作者，供合规追溯与回滚取证"
           ) do
      add :id, :binary_id, primary_key: true, comment: "配置审计记录 UUID 主键"

      add :subsystem, :string,
        null: false,
        comment: "被变更配置的子系统名；与 runtime_configs.subsystem 同义，审计行不设外键以便配置行删除后审计仍保留"

      add :key, :string, null: false, comment: "被变更配置的键名；与 runtime_configs.key 同义"

      add :operation, :string,
        null: false,
        comment: "变更操作：set 表示写入覆盖值，reset 表示删除覆盖值回落到 env/编译期默认"

      add :old_value, :map, comment: "变更前的配置值 JSON 包装；NULL 表示变更前无覆盖值"
      add :new_value, :map, comment: "变更后的配置值 JSON 包装；reset 操作为 NULL"

      add :from_version, :integer, comment: "变更前的键版本号；NULL 表示首次覆盖"

      add :to_version, :integer,
        null: false,
        comment:
          "变更后的键版本号；set 时与 runtime_configs.version 对应，reset 时为被删除行版本号加一（配置行已不存在，但审计的版本序仍需单调）"

      add :apply_mode, :string,
        null: false,
        comment: "本次变更的生效方式：hot / next_cycle / restart，记录当时 Schema 声明值"

      add :principal_arn, :string, comment: "发起变更的 principal ARN；匿名或无法解析时为 NULL 并在 source 中标注通道"

      add :access_key_id, :string, comment: "发起变更所用的 access key id；便于与 IAM 访问记录关联，CLI 通道可为 NULL"

      add :request_id, :string, comment: "触发变更的 HTTP 请求 id；与结构化日志的 request_id 对齐，CLI 通道为 NULL"

      add :source, :string,
        null: false,
        comment: "变更来源通道：admin_api / cli / console / system"

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:runtime_config_audits, [:subsystem, :key, :inserted_at],
             name: :runtime_config_audits_key_time_index,
             comment: "按配置键与时间倒查变更历史；供单键回滚与漂移定位"
           )

    create index(:runtime_config_audits, [:inserted_at],
             name: :runtime_config_audits_time_index,
             comment: "按时间检索全局配置变更流水；供审计导出与近期变更巡检"
           )

    execute("""
    ALTER TABLE runtime_config_audits
      ADD CONSTRAINT runtime_config_audits_operation_check
      CHECK (operation IN ('set', 'reset'))
    """)

    execute("""
    COMMENT ON CONSTRAINT runtime_config_audits_operation_check ON runtime_config_audits IS
    '配置审计操作白名单约束；只允许 set / reset 两种已定义变更语义'
    """)

    execute("""
    ALTER TABLE runtime_config_audits
      ADD CONSTRAINT runtime_config_audits_source_check
      CHECK (source IN ('admin_api', 'cli', 'console', 'system'))
    """)

    execute("""
    COMMENT ON CONSTRAINT runtime_config_audits_source_check ON runtime_config_audits IS
    '审计来源白名单约束；与 runtime_configs.source 同集合，保证两表的通道枚举不漂移'
    """)

    execute("""
    ALTER TABLE runtime_config_audits
      ADD CONSTRAINT runtime_config_audits_apply_mode_check
      CHECK (apply_mode IN ('hot', 'next_cycle', 'restart'))
    """)

    execute("""
    COMMENT ON CONSTRAINT runtime_config_audits_apply_mode_check ON runtime_config_audits IS
    '审计生效方式白名单约束；与 runtime_configs.apply_mode 同集合，保证历史记录可按同一枚举解读'
    """)

    execute("COMMENT ON COLUMN runtime_config_audits.inserted_at IS '配置变更发生时间；审计行只追加，无更新时间列'")
  end

  def down do
    execute("COMMENT ON COLUMN runtime_config_audits.inserted_at IS NULL")

    execute("""
    COMMENT ON CONSTRAINT runtime_config_audits_apply_mode_check ON runtime_config_audits IS NULL
    """)

    execute("""
    ALTER TABLE runtime_config_audits DROP CONSTRAINT runtime_config_audits_apply_mode_check
    """)

    execute("""
    COMMENT ON CONSTRAINT runtime_config_audits_source_check ON runtime_config_audits IS NULL
    """)

    execute(
      "ALTER TABLE runtime_config_audits DROP CONSTRAINT runtime_config_audits_source_check"
    )

    execute("""
    COMMENT ON CONSTRAINT runtime_config_audits_operation_check ON runtime_config_audits IS NULL
    """)

    execute("""
    ALTER TABLE runtime_config_audits DROP CONSTRAINT runtime_config_audits_operation_check
    """)

    drop index(:runtime_config_audits, [:inserted_at], name: :runtime_config_audits_time_index)

    drop index(:runtime_config_audits, [:subsystem, :key, :inserted_at],
           name: :runtime_config_audits_key_time_index
         )

    drop table(:runtime_config_audits)

    execute("COMMENT ON COLUMN runtime_configs.updated_at IS NULL")
    execute("COMMENT ON COLUMN runtime_configs.inserted_at IS NULL")

    execute("""
    COMMENT ON CONSTRAINT runtime_configs_version_positive_check ON runtime_configs IS NULL
    """)

    execute("ALTER TABLE runtime_configs DROP CONSTRAINT runtime_configs_version_positive_check")
    execute("COMMENT ON CONSTRAINT runtime_configs_source_check ON runtime_configs IS NULL")
    execute("ALTER TABLE runtime_configs DROP CONSTRAINT runtime_configs_source_check")
    execute("COMMENT ON CONSTRAINT runtime_configs_apply_mode_check ON runtime_configs IS NULL")
    execute("ALTER TABLE runtime_configs DROP CONSTRAINT runtime_configs_apply_mode_check")

    drop index(:runtime_configs, [:updated_at], name: :runtime_configs_updated_at_index)

    drop index(:runtime_configs, [:subsystem, :key], name: :runtime_configs_subsystem_key_index)

    drop table(:runtime_configs)
  end
end
