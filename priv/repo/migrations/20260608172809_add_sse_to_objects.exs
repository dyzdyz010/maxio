defmodule Maxio.Repo.Migrations.AddSseToObjects do
  use Ecto.Migration

  def change do
    alter table(:objects) do
      add :sse_algorithm, :string,
        null: true,
        comment:
          "服务端加密算法（AES256=SSE-S3 真实加密；nil=明文）。GET 据此决定是否透明解密；响应回显 x-amz-server-side-encryption"

      add :sse_envelope, :map,
        null: true,
        comment:
          "SSE-S3 信封头（jsonb）：%{wrapped_dek_b64, dek_iv_b64, dek_tag_b64}——对象数据密钥经服务端主密钥 AES-256-GCM 包裹（单一静态主密钥 MVP，无轮转）；nil=未加密"
    end
  end
end
