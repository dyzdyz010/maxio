defmodule Maxio.Repo.Migrations.CreateManagedPolicyVersions do
  use Ecto.Migration

  def up do
    alter table(:managed_policies) do
      add :next_version_number, :integer,
        null: false,
        default: 2,
        comment: "IAM customer managed policy 下一次创建版本使用的单调递增版本号；v1 创建后从 2 开始，删除版本不复用"
    end

    create table(:managed_policy_versions,
             primary_key: false,
             comment:
               "IAM customer managed policy 版本表；每个策略最多保留 5 个活动版本，默认版本镜像到 managed_policies.document"
           ) do
      add :id, :binary_id,
        primary_key: true,
        comment: "managed policy version 主键 UUID"

      add :managed_policy_id,
          references(:managed_policies, type: :binary_id, on_delete: :delete_all),
          null: false,
          comment: "所属 managed_policies.id；策略删除时级联删除所有版本"

      add :version_id, :text,
        null: false,
        comment: "AWS IAM managed policy VersionId，例如 v1/v2；删除后不复用"

      add :document, :map,
        null: false,
        comment: "该版本的 IAM identity policy JSON 文档（jsonb）"

      add :is_default, :boolean,
        null: false,
        default: false,
        comment: "是否为当前默认版本；同一 managed policy 同时只能有一个默认版本"

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:managed_policy_versions, [:managed_policy_id, :version_id],
             name: :managed_policy_versions_policy_version_index,
             comment: "同一 managed policy 下 VersionId 唯一"
           )

    create unique_index(:managed_policy_versions, [:managed_policy_id],
             where: "is_default",
             name: :managed_policy_versions_default_index,
             comment: "同一 managed policy 只能有一个默认版本"
           )

    execute(
      "COMMENT ON COLUMN managed_policy_versions.inserted_at IS 'managed policy version 创建时间（UTC）'"
    )

    execute(
      "COMMENT ON COLUMN managed_policy_versions.updated_at IS 'managed policy version 更新时间（UTC）'"
    )

    flush()

    repo().query!(
      "SELECT id, document, inserted_at, updated_at FROM managed_policies",
      [],
      log: false
    ).rows
    |> Enum.each(fn [id, document, inserted_at, updated_at] ->
      repo().query!(
        """
        INSERT INTO managed_policy_versions
          (id, managed_policy_id, version_id, document, is_default, inserted_at, updated_at)
        VALUES ($1, $2, 'v1', $3, true, $4, $5)
        ON CONFLICT DO NOTHING
        """,
        [Ecto.UUID.generate(), id, document, inserted_at, updated_at],
        log: false
      )
    end)
  end

  def down do
    execute("COMMENT ON INDEX managed_policy_versions_default_index IS NULL")
    execute("COMMENT ON INDEX managed_policy_versions_policy_version_index IS NULL")
    execute("COMMENT ON COLUMN managed_policy_versions.inserted_at IS NULL")
    execute("COMMENT ON COLUMN managed_policy_versions.updated_at IS NULL")

    drop_if_exists index(:managed_policy_versions, [:managed_policy_id],
                     name: :managed_policy_versions_default_index
                   )

    drop_if_exists index(:managed_policy_versions, [:managed_policy_id, :version_id],
                     name: :managed_policy_versions_policy_version_index
                   )

    drop table(:managed_policy_versions)

    execute("COMMENT ON COLUMN managed_policies.next_version_number IS NULL")

    alter table(:managed_policies) do
      remove :next_version_number
    end
  end
end
