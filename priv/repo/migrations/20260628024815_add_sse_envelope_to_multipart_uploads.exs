defmodule Maxio.Repo.Migrations.AddSseEnvelopeToMultipartUploads do
  use Ecto.Migration

  def change do
    alter table(:multipart_uploads) do
      add :sse_envelope, :map,
        null: true,
        comment:
          "分段上传会话捕获的服务端加密信封；SSE-C 仅保存 customer key MD5 与带盐 HMAC 校验材料，绝不保存原始客户密钥；nil 表示未加密或不需要会话级信封"
    end
  end
end
