defmodule Maxio.Repo.Migrations.AddSseToMultipartUploads do
  use Ecto.Migration

  def change do
    alter table(:multipart_uploads) do
      add :sse_algorithm, :string,
        comment: "分段上传会话捕获的目标服务端加密算法；AES256 表示 Complete 时对最终对象执行 SSE-S3 加密"
    end
  end
end
