defmodule Maxio.Repo.Migrations.AddLastUsedToAccessKeys do
  use Ecto.Migration

  def change do
    alter table(:access_keys) do
      add :last_used_at, :utc_datetime_usec,
        comment: "最近一次成功使用该长期 Access Key 通过 SigV4 认证的时间；从未使用则为空"

      add :last_used_service, :string,
        comment: "最近一次成功认证请求的 SigV4 service scope，例如 s3、iam、sts；从未使用则为空"

      add :last_used_region, :string,
        comment: "最近一次成功认证请求的 SigV4 region scope，例如 us-east-1；从未使用则为空"
    end
  end
end
