defmodule Maxio.Repo.Migrations.AddChecksumIntentToMultipartUploads do
  use Ecto.Migration

  def change do
    alter table(:multipart_uploads) do
      add :checksum_algorithm, :string,
        comment:
          "S3 CreateMultipartUpload 声明或服务端默认的 checksum 算法（x-amz-checksum-algorithm）；用于 UploadPartCopy/UploadPart 生成同算法 part checksum"

      add :checksum_type, :string,
        comment:
          "S3 CreateMultipartUpload 声明或服务端默认的 checksum 类型（x-amz-checksum-type）；支持 COMPOSITE 与 CRC64NVME/CRC32/CRC32C 的 FULL_OBJECT"
    end
  end
end
