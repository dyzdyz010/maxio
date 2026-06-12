defmodule Maxio.Repo.Migrations.AddObjectSystemHeaders do
  use Ecto.Migration

  def change do
    alter table(:objects) do
      add :content_encoding, :string, comment: "对象可控系统元数据：Content-Encoding 响应头（未设置为 NULL）"

      add :content_disposition, :string, comment: "对象可控系统元数据：Content-Disposition 响应头（未设置为 NULL）"

      add :cache_control, :string, comment: "对象可控系统元数据：Cache-Control 响应头（未设置为 NULL）"

      add :expires, :string, comment: "对象可控系统元数据：Expires 响应头原始 HTTP-date 字符串（未设置为 NULL）"
    end

    alter table(:multipart_uploads) do
      add :content_encoding, :string, comment: "分段上传会话捕获的 Content-Encoding；Complete 时随最终对象落库"

      add :content_disposition, :string,
        comment: "分段上传会话捕获的 Content-Disposition；Complete 时随最终对象落库"

      add :cache_control, :string, comment: "分段上传会话捕获的 Cache-Control；Complete 时随最终对象落库"

      add :expires, :string, comment: "分段上传会话捕获的 Expires 原始 HTTP-date 字符串；Complete 时随最终对象落库"
    end
  end
end
