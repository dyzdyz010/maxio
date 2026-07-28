defmodule Maxio.Repo.Migrations.AddIamNameUpdateCascadeConstraints do
  use Ecto.Migration

  def up do
    replace_constraint(
      :iam_group_memberships,
      :iam_group_memberships_user_arn_fkey,
      "FOREIGN KEY (user_arn) REFERENCES iam_users(user_arn) ON UPDATE CASCADE ON DELETE CASCADE",
      "IAM 用户组成员关系的 user_arn 外键；用户重命名时级联更新 membership，用户删除时级联清理"
    )

    replace_constraint(
      :iam_group_memberships,
      :iam_group_memberships_group_arn_fkey,
      "FOREIGN KEY (group_arn) REFERENCES iam_groups(group_arn) ON UPDATE CASCADE ON DELETE CASCADE",
      "IAM 用户组成员关系的 group_arn 外键；组重命名时级联更新 membership，组删除时级联清理"
    )

    replace_constraint(
      :iam_user_managed_policy_attachments,
      :iam_user_managed_policy_attachments_user_arn_fkey,
      "FOREIGN KEY (user_arn) REFERENCES iam_users(user_arn) ON UPDATE CASCADE ON DELETE CASCADE",
      "IAM 用户托管策略绑定的 user_arn 外键；用户重命名时级联更新绑定关系，用户删除时级联清理"
    )

    replace_constraint(
      :iam_group_managed_policy_attachments,
      :iam_group_managed_policy_attachments_group_arn_fkey,
      "FOREIGN KEY (group_arn) REFERENCES iam_groups(group_arn) ON UPDATE CASCADE ON DELETE CASCADE",
      "IAM 用户组托管策略绑定的 group_arn 外键；组重命名时级联更新绑定关系，组删除时级联清理"
    )
  end

  def down do
    replace_constraint(
      :iam_group_managed_policy_attachments,
      :iam_group_managed_policy_attachments_group_arn_fkey,
      "FOREIGN KEY (group_arn) REFERENCES iam_groups(group_arn) ON DELETE CASCADE",
      nil
    )

    replace_constraint(
      :iam_user_managed_policy_attachments,
      :iam_user_managed_policy_attachments_user_arn_fkey,
      "FOREIGN KEY (user_arn) REFERENCES iam_users(user_arn) ON DELETE CASCADE",
      nil
    )

    replace_constraint(
      :iam_group_memberships,
      :iam_group_memberships_group_arn_fkey,
      "FOREIGN KEY (group_arn) REFERENCES iam_groups(group_arn) ON DELETE CASCADE",
      nil
    )

    replace_constraint(
      :iam_group_memberships,
      :iam_group_memberships_user_arn_fkey,
      "FOREIGN KEY (user_arn) REFERENCES iam_users(user_arn) ON DELETE CASCADE",
      nil
    )
  end

  defp replace_constraint(table, name, definition, comment) do
    execute("ALTER TABLE #{table} DROP CONSTRAINT IF EXISTS #{name}")
    execute("ALTER TABLE #{table} ADD CONSTRAINT #{name} #{definition}")
    execute("COMMENT ON CONSTRAINT #{name} ON #{table} IS #{quoted_comment(comment)}")
  end

  defp quoted_comment(nil), do: "NULL"
  defp quoted_comment(comment), do: "'" <> String.replace(comment, "'", "''") <> "'"
end
