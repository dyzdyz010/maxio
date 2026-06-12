defmodule Maxio.Repo.Migrations.CreateClusterDriveIdentities do
  use Ecto.Migration

  def up do
    create table(:cluster_drive_identities, primary_key: false, comment: "集群纠删码端点的持久化软件盘身份记录") do
      add :id, :binary_id, primary_key: true, comment: "记录 UUID 主键"
      add :node_name, :string, null: false, comment: "端点所属 Erlang 节点名"
      add :drive_path, :text, null: false, comment: "端点配置中的本机盘根路径"
      add :set_id, :integer, comment: "端点所在 erasure set id"
      add :endpoint_index, :integer, comment: "端点在 erasure set 内的分片序号"

      add :drive_uuid, :string,
        null: false,
        comment: "盘根身份文件中的软件 UUID；同路径更换新盘时会变化"

      add :previous_drive_uuid, :string, comment: "最近一次 replacement 前的旧软件 UUID"

      add :generation, :integer,
        null: false,
        default: 1,
        comment: "同一端点路径检测到 replacement 的代数，从 1 开始递增"

      add :identity_heal_required, :boolean,
        null: false,
        default: false,
        comment: "该端点因软件盘身份变化需要 fresh-drive heal"

      add :first_seen_at, :utc_datetime_usec, null: false, comment: "首次观察到该端点身份的时间"
      add :last_seen_at, :utc_datetime_usec, null: false, comment: "最近一次成功观察该端点身份的时间"
      add :replacement_detected_at, :utc_datetime_usec, comment: "最近一次检测到 replacement 的时间"
      add :healed_at, :utc_datetime_usec, comment: "最近一次清除 identity heal 标记的时间"

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:cluster_drive_identities, [:node_name, :drive_path],
             name: :cluster_drive_identities_endpoint_index
           )

    create index(:cluster_drive_identities, [:identity_heal_required],
             name: :cluster_drive_identities_heal_required_index
           )

    execute("COMMENT ON INDEX cluster_drive_identities_endpoint_index IS '按节点名与盘根路径唯一定位一个配置端点身份'")

    execute(
      "COMMENT ON INDEX cluster_drive_identities_heal_required_index IS '按是否需要 fresh-drive heal 查询 replacement 端点'"
    )

    execute("COMMENT ON COLUMN cluster_drive_identities.inserted_at IS '记录创建时间'")
    execute("COMMENT ON COLUMN cluster_drive_identities.updated_at IS '记录最后更新时间'")
  end

  def down do
    execute("COMMENT ON COLUMN cluster_drive_identities.updated_at IS NULL")
    execute("COMMENT ON COLUMN cluster_drive_identities.inserted_at IS NULL")
    execute("COMMENT ON INDEX cluster_drive_identities_heal_required_index IS NULL")
    execute("COMMENT ON INDEX cluster_drive_identities_endpoint_index IS NULL")

    drop_if_exists index(:cluster_drive_identities, [:identity_heal_required],
                     name: :cluster_drive_identities_heal_required_index
                   )

    drop_if_exists unique_index(:cluster_drive_identities, [:node_name, :drive_path],
                     name: :cluster_drive_identities_endpoint_index
                   )

    drop table(:cluster_drive_identities)
  end
end
