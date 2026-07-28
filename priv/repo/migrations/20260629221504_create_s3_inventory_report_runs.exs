defmodule Maxio.Repo.Migrations.CreateS3InventoryReportRuns do
  use Ecto.Migration

  def up do
    create table(:s3_inventory_report_runs,
             primary_key: false,
             comment: "S3 Inventory 报表自动调度运行账本；用于按 bucket/config/report_date 去重、记录失败和审计输出对象"
           ) do
      add :id, :binary_id, primary_key: true, comment: "Inventory 报表运行记录 UUID 主键"

      add :bucket, :string,
        null: false,
        comment: "源 bucket 名称；对应 InventoryConfiguration 所在 bucket"

      add :inventory_id, :string,
        null: false,
        comment: "InventoryConfiguration 的 Id；与 bucket/report_date 共同定义一次计划报表"

      add :report_date, :date,
        null: false,
        comment: "调度语义上的报表日期；Daily 每日一条，Weekly 使用 UTC 周日日期"

      add :frequency, :string,
        null: false,
        comment: "配置中的调度频率：Daily 或 Weekly"

      add :config_hash, :string,
        null: false,
        comment: "规范化 InventoryConfiguration 的 SHA256 摘要；用于审计本次运行对应的配置快照"

      add :trigger, :string,
        null: false,
        comment: "触发来源：manual 表示 run_now/CLI/IEx，scheduled 表示后台定时器"

      add :status, :string,
        null: false,
        comment: "运行状态：running/ok/failed/skipped；ok 对同一 bucket/config/report_date 幂等终止"

      add :attempts, :integer,
        null: false,
        default: 0,
        comment: "该 bucket/config/report_date 已尝试次数；失败重试会递增"

      add :run_id, :string,
        null: false,
        comment: "本次计划报表使用的稳定 run id；由 bucket、Inventory Id 与 report_date 派生"

      add :file_id, :string,
        null: false,
        comment: "本次计划报表使用的稳定 data file id；用于重试保持同一路径"

      add :lease_until, :utc_datetime_usec, comment: "running 状态租约截止时间；进程崩溃后超过该时间允许重新 claim"

      add :started_at, :utc_datetime_usec, null: false, comment: "本次尝试开始时间"
      add :finished_at, :utc_datetime_usec, comment: "本次尝试结束时间；running 时为 NULL"

      add :duration_ms, :bigint,
        null: false,
        default: 0,
        comment: "本次尝试耗时毫秒；running 时为 0"

      add :manifest_key, :string, comment: "成功写出的 manifest.json object key；未写出时为 NULL"
      add :data_key, :string, comment: "成功写出的 CSV gzip data object key；未写出时为 NULL"
      add :checksum_key, :string, comment: "成功写出的 manifest.checksum object key；未写出时为 NULL"
      add :symlink_key, :string, comment: "成功写出的 hive symlink.txt object key；未写出时为 NULL"

      add :rows_written, :bigint,
        null: false,
        default: 0,
        comment: "本次成功写出的 Inventory CSV 行数"

      add :objects_written, :integer,
        null: false,
        default: 0,
        comment: "本次成功写出的报表对象数量：data/symlink/checksum/manifest"

      add :summary, :map,
        null: false,
        default: %{},
        comment: "裁剪后的运行摘要 JSON；不得保存对象字节、签名、secret 或客户密钥"

      add :error_reason, :string, comment: "失败或跳过原因的结构化摘要"

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:s3_inventory_report_runs, [:bucket, :inventory_id, :report_date],
             name: :s3_inventory_report_runs_unique_report_index,
             comment: "同一源 bucket、Inventory Id 与 report_date 只能有一条账本行，保证自动调度幂等"
           )

    create index(:s3_inventory_report_runs, [:status, :lease_until],
             name: :s3_inventory_report_runs_status_lease_index,
             comment: "按状态和 running 租约查询可重试或卡住的 Inventory 报表运行"
           )

    create index(:s3_inventory_report_runs, [:trigger, :started_at],
             name: :s3_inventory_report_runs_trigger_started_at_index,
             comment: "按触发来源和开始时间查询 Inventory 报表运行历史"
           )

    execute("COMMENT ON COLUMN s3_inventory_report_runs.inserted_at IS 'Inventory 报表账本记录创建时间'")
    execute("COMMENT ON COLUMN s3_inventory_report_runs.updated_at IS 'Inventory 报表账本记录最后更新时间'")
  end

  def down do
    execute("COMMENT ON COLUMN s3_inventory_report_runs.updated_at IS NULL")
    execute("COMMENT ON COLUMN s3_inventory_report_runs.inserted_at IS NULL")

    drop_if_exists index(:s3_inventory_report_runs, [:trigger, :started_at],
                     name: :s3_inventory_report_runs_trigger_started_at_index
                   )

    drop_if_exists index(:s3_inventory_report_runs, [:status, :lease_until],
                     name: :s3_inventory_report_runs_status_lease_index
                   )

    drop_if_exists unique_index(:s3_inventory_report_runs, [:bucket, :inventory_id, :report_date],
                     name: :s3_inventory_report_runs_unique_report_index
                   )

    drop table(:s3_inventory_report_runs)
  end
end
