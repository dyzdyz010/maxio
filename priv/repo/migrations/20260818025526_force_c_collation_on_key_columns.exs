defmodule Maxio.Repo.Migrations.ForceCCollationOnKeyColumns do
  use Ecto.Migration

  # S3 明文规定 key 的列举顺序是 UTF-8 字节序（"List results are always returned in
  # UTF-8 binary order"）。这些列此前继承库默认 collation（en_US.utf8），在该 locale 下
  # 'photos/2007/a.txt' > 'photos/20070' 为 true，而字节序应为 false——导致 ListObjects V1
  # 用 delimiter successor 游标分页时上一页已返回的 CommonPrefix 被重复扫回，且让
  # PG 权威查询与 drive-walk（Erlang binary 比较 = 字节序）两条路径语义不一致。
  #
  # 修法：把 key/name 列在 schema 层固定为 COLLATE "C"，使「key 顺序 = UTF-8 字节序」
  # 成为单一事实来源；查询侧一行不改（禁止在 Ecto 查询里散落 fragment COLLATE）。
  #
  # 每项：{表, 列, 现有类型（逐字保持，不借机变更）, 迁移前 COMMENT, 迁移后 COMMENT}
  @columns [
    {"objects", "key", "character varying(1024)",
     "对象键（完整 S3 key，含任意 / 层级；与 bucket 唯一确定一个对象）。S3/MinIO key 上限 1024 字节 → varchar(1024)，与 B5-4 入口守卫（Paths.validate_key）同源",
     "对象键（完整 S3 key，含任意 / 层级；与 bucket 唯一确定一个对象）。S3/MinIO key 上限 1024 字节 → varchar(1024)，与 B5-4 入口守卫（Paths.validate_key）同源。固定 COLLATE \"C\"：S3 要求 key 按 UTF-8 字节序比较/排序（List results are always returned in UTF-8 binary order），勿改回库默认 locale collation（en_US.utf8 会让 'photos/2007/a.txt' > 'photos/20070'，与字节序相反，破坏 delimiter 游标分页并与 drive-walk 不一致）"},
    {"multipart_uploads", "key", "character varying(1024)",
     "目标对象键（Complete 后写入此 key）。S3/MinIO key 上限 1024 字节 → varchar(1024)，与 B5-4 入口守卫（Paths.validate_key）同源",
     "目标对象键（Complete 后写入此 key）。S3/MinIO key 上限 1024 字节 → varchar(1024)，与 B5-4 入口守卫（Paths.validate_key）同源。固定 COLLATE \"C\"：S3 要求 key 按 UTF-8 字节序比较/排序（ListMultipartUploads 同样按字节序分页），勿改回库默认 locale collation"},
    {"buckets", "name", "character varying(255)",
     "桶名（S3 全局唯一，3-63 字符，命名规则见 Buckets.validate_name）",
     "桶名（S3 全局唯一，3-63 字符，命名规则见 Buckets.validate_name）。固定 COLLATE \"C\"：S3 要求桶名/key 按 UTF-8 字节序比较/排序（ListBuckets 按字节序返回；locale collation 会忽略 '-' '.' 等标点的权重），勿改回库默认 locale collation"},
    {"console_direct_multipart_uploads", "key", "text",
     "目标对象 key 原文；不做 URL 编码，必须与 multipart_uploads.key 一致",
     "目标对象 key 原文；不做 URL 编码，必须与 multipart_uploads.key 一致。固定 COLLATE \"C\"：与 multipart_uploads.key 同为 S3 key 域，按 UTF-8 字节序比较/排序（本表按 key 升序列举断点续传登记），勿改回库默认 locale collation"},
    {"console_direct_multipart_upload_histories", "key", "text",
     "目标对象 key 原文；不保存 URL 或 presigned query",
     "目标对象 key 原文；不保存 URL 或 presigned query。固定 COLLATE \"C\"：与 multipart_uploads.key 同为 S3 key 域，按 UTF-8 字节序比较/排序，勿改回库默认 locale collation"}
  ]

  def up do
    for {table, column, type, _old_comment, new_comment} <- @columns do
      execute(~s[ALTER TABLE #{table} ALTER COLUMN #{column} TYPE #{type} COLLATE "C"])
      execute(~s[COMMENT ON COLUMN #{table}.#{column} IS '#{escape(new_comment)}'])
    end
  end

  def down do
    for {table, column, type, old_comment, _new_comment} <- @columns do
      execute(~s[ALTER TABLE #{table} ALTER COLUMN #{column} TYPE #{type} COLLATE "default"])
      execute(~s[COMMENT ON COLUMN #{table}.#{column} IS '#{escape(old_comment)}'])
    end
  end

  defp escape(text), do: String.replace(text, "'", "''")
end
