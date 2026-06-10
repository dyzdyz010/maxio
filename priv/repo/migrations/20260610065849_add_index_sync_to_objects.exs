defmodule Maxio.Repo.Migrations.AddIndexSyncToObjects do
  use Ecto.Migration

  # ROUTE B B5-1 —— PG 降为受维护的派生索引：objects 加 scanner 同步追踪列。
  # synced_at/index_generation 由写路径（写穿即视作同步）与 B5-2 Scanner（reconcile 后 mark_synced）维护。
  def change do
    alter table(:objects) do
      add :synced_at, :utc_datetime_usec,
        null: true,
        comment: "派生索引最后一次与盘上 sidecar 权威同步的时刻；NULL=尚未经 scanner 确认"

      add :index_generation, :bigint,
        null: false,
        default: 0,
        comment: "同步时对应的 sidecar 版本 generation，scanner 判 stale 用"
    end
  end
end
