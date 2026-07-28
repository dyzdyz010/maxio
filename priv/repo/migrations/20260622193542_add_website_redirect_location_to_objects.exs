defmodule Maxio.Repo.Migrations.AddWebsiteRedirectLocationToObjects do
  use Ecto.Migration

  def change do
    alter table(:objects) do
      add :website_redirect_location, :string,
        comment: "S3 对象级网站重定向位置（x-amz-website-redirect-location）；PUT/COPY/MPU 写入后供 GET/HEAD 回显"
    end

    alter table(:multipart_uploads) do
      add :website_redirect_location, :string,
        comment: "CreateMultipartUpload 阶段捕获的对象级网站重定向位置；CompleteMultipartUpload 时落入最终对象元数据"
    end
  end
end
