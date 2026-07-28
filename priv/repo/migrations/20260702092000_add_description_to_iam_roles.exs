defmodule Maxio.Repo.Migrations.AddDescriptionToIamRoles do
  use Ecto.Migration

  def change do
    alter table(:iam_roles) do
      add :description, :text,
        null: false,
        default: "",
        comment: "IAM 角色描述；CreateRole/UpdateRole Description，AWS 上限 1000 字符"
    end
  end
end
