defmodule Maxio.Repo.Migrations.AddPermissionsBoundaryToIamPrincipals do
  use Ecto.Migration

  def up do
    alter table(:iam_users) do
      add :permissions_boundary_policy_arn, :text,
        comment: "IAM 用户权限边界托管策略 ARN；PutUserPermissionsBoundary/CreateUser PermissionsBoundary"
    end

    alter table(:iam_roles) do
      add :permissions_boundary_policy_arn, :text,
        comment: "IAM 角色权限边界托管策略 ARN；PutRolePermissionsBoundary/CreateRole PermissionsBoundary"
    end

    create index(:iam_users, [:permissions_boundary_policy_arn],
             name: :iam_users_permissions_boundary_policy_arn_index
           )

    create index(:iam_roles, [:permissions_boundary_policy_arn],
             name: :iam_roles_permissions_boundary_policy_arn_index
           )

    execute("""
    COMMENT ON INDEX iam_users_permissions_boundary_policy_arn_index IS
    '按权限边界托管策略 ARN 反查 IAM 用户；支撑 ListPolicies/ListEntitiesForPolicy PermissionsBoundary'
    """)

    execute("""
    COMMENT ON INDEX iam_roles_permissions_boundary_policy_arn_index IS
    '按权限边界托管策略 ARN 反查 IAM 角色；支撑 ListPolicies/ListEntitiesForPolicy PermissionsBoundary'
    """)
  end

  def down do
    execute("COMMENT ON INDEX iam_roles_permissions_boundary_policy_arn_index IS NULL")
    execute("COMMENT ON INDEX iam_users_permissions_boundary_policy_arn_index IS NULL")

    drop index(:iam_roles, [:permissions_boundary_policy_arn],
           name: :iam_roles_permissions_boundary_policy_arn_index
         )

    drop index(:iam_users, [:permissions_boundary_policy_arn],
           name: :iam_users_permissions_boundary_policy_arn_index
         )

    alter table(:iam_roles) do
      remove :permissions_boundary_policy_arn
    end

    alter table(:iam_users) do
      remove :permissions_boundary_policy_arn
    end
  end
end
