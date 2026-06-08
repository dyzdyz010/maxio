defmodule Maxio.Repo.Migrations.CreateMultipartParts do
  use Ecto.Migration

  def change do
    create table(:multipart_parts,
             primary_key: false,
             comment: "分段上传的已上传分块元数据：每个 (upload, part_number) 一行；分块字节归存储后端，本表只存元信息"
           ) do
      add :id, :binary_id, primary_key: true, comment: "分块元数据主键（UUID）"

      add :upload_id,
          references(:multipart_uploads, column: :id, type: :binary_id, on_delete: :delete_all),
          null: false,
          comment: "所属分段上传会话外键（删会话级联删分块元数据）"

      add :part_number, :integer,
        null: false,
        comment: "分块序号（1..10000，Complete 时按此升序组装）"

      add :etag, :string,
        null: false,
        comment: "分块 ETag：该 part 字节的 MD5 hex（本列不含引号，渲染时加引号）"

      add :size, :bigint,
        null: false,
        default: 0,
        comment: "分块字节大小（Complete 校验非末块 ≥ 5 MiB 用）"

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:multipart_parts, [:upload_id, :part_number],
             comment: "会话内分块序号唯一索引（同 part_number 重传走 upsert 覆盖）"
           )
  end
end
