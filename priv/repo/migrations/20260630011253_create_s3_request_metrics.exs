defmodule Maxio.Repo.Migrations.CreateS3RequestMetrics do
  use Ecto.Migration

  def up do
    create table(:s3_request_metrics,
             primary_key: false,
             comment:
               "S3 Bucket Metrics 本地请求指标分钟聚合账本；按 bucket、MetricsConfiguration Id、UTC 分钟窗口、操作和状态码汇总请求计数、字节数和响应启动延迟"
           ) do
      add :id, :binary_id, primary_key: true, comment: "请求指标聚合行 UUID 主键"

      add :bucket, :string,
        null: false,
        comment: "S3 bucket 名称"

      add :filter_id, :string,
        null: false,
        comment: "MetricsConfiguration Id，对应 CloudWatch FilterId 维度"

      add :window_started_at, :utc_datetime_usec,
        null: false,
        comment: "按 UTC 分钟截断的聚合窗口开始时间"

      add :operation, :string,
        null: false,
        comment: "Maxio 归一化后的 S3 操作名，如 get_object、copy_object、list_objects_v2"

      add :metric_family, :string,
        null: false,
        comment: "请求指标分类：get、put、delete、head、post、list 或 other"

      add :status_code, :integer,
        null: false,
        comment: "HTTP 响应状态码"

      add :status_class, :string,
        null: false,
        comment: "HTTP 响应状态族：2xx、3xx、4xx、5xx 或 other"

      add :request_count, :bigint,
        null: false,
        default: 0,
        comment: "本聚合维度内的请求数量"

      add :bytes_uploaded_sum, :bigint,
        null: false,
        default: 0,
        comment: "本聚合维度内已观测上传字节总和；服务端拷贝按目标对象可见大小计"

      add :bytes_downloaded_sum, :bigint,
        null: false,
        default: 0,
        comment: "本聚合维度内已观测下载字节总和"

      add :latency_ms_sum, :bigint,
        null: false,
        default: 0,
        comment: "请求进入 Metrics plug 到响应 header 发送前的累计毫秒；用于本地诊断，不等同 CloudWatch TotalRequestLatency"

      add :latency_ms_min, :integer,
        null: false,
        default: 0,
        comment: "本聚合维度内响应启动延迟最小值（毫秒）"

      add :latency_ms_max, :integer,
        null: false,
        default: 0,
        comment: "本聚合维度内响应启动延迟最大值（毫秒）"

      add :first_seen_at, :utc_datetime_usec,
        null: false,
        comment: "本聚合行首次观测到请求的时间"

      add :last_seen_at, :utc_datetime_usec,
        null: false,
        comment: "本聚合行最近一次观测到请求的时间"

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(
             :s3_request_metrics,
             [:bucket, :filter_id, :window_started_at, :operation, :status_code],
             name: :s3_request_metrics_unique_window_operation_status_index,
             comment: "同一 bucket、MetricsConfiguration Id、分钟窗口、操作和状态码只保留一行聚合记录"
           )

    create index(:s3_request_metrics, [:bucket, :window_started_at],
             name: :s3_request_metrics_bucket_window_index,
             comment: "按 bucket 和时间窗口查询本地请求指标"
           )

    create index(:s3_request_metrics, [:filter_id, :window_started_at],
             name: :s3_request_metrics_filter_window_index,
             comment: "按 MetricsConfiguration Id 和时间窗口查询本地请求指标"
           )

    create index(:s3_request_metrics, [:operation, :window_started_at],
             name: :s3_request_metrics_operation_window_index,
             comment: "按 S3 操作名和时间窗口查询本地请求指标"
           )

    execute("COMMENT ON COLUMN s3_request_metrics.inserted_at IS '请求指标聚合行首次创建时间'")
    execute("COMMENT ON COLUMN s3_request_metrics.updated_at IS '请求指标聚合行最后更新时间'")
  end

  def down do
    execute("COMMENT ON COLUMN s3_request_metrics.updated_at IS NULL")
    execute("COMMENT ON COLUMN s3_request_metrics.inserted_at IS NULL")

    drop_if_exists index(:s3_request_metrics, [:operation, :window_started_at],
                     name: :s3_request_metrics_operation_window_index
                   )

    drop_if_exists index(:s3_request_metrics, [:filter_id, :window_started_at],
                     name: :s3_request_metrics_filter_window_index
                   )

    drop_if_exists index(:s3_request_metrics, [:bucket, :window_started_at],
                     name: :s3_request_metrics_bucket_window_index
                   )

    drop_if_exists unique_index(
                     :s3_request_metrics,
                     [:bucket, :filter_id, :window_started_at, :operation, :status_code],
                     name: :s3_request_metrics_unique_window_operation_status_index
                   )

    drop table(:s3_request_metrics)
  end
end
