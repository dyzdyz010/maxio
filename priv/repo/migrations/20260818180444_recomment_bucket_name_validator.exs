defmodule Maxio.Repo.Migrations.RecommentBucketNameValidator do
  use Ecto.Migration

  # AGENTS §4.6 —— `psql \d+` 输出必须自文档化，因此**绝不能指向不存在的符号**。
  # `buckets.name` 的 COMMENT（由 20260608125535 建表时写下、20260818025526 固定 COLLATE "C"
  # 时改写）仍写着「命名规则见 Buckets.validate_name」，而 `Maxio.Buckets.validate_name/1`
  # 已被拆分删除：保留桶名（`minio` 等）只能用于 CreateBucket 准入，写路径 / journal changeset /
  # ObjectEpoch target 只做桶名语法校验——两者混用会把存量同名桶静默降级成只读
  # （设计 D8 回写第 2 条）。COMMENT 指着一个已不存在的函数，会把读 schema 的人直接引向死路。
  #
  # 历史迁移一律不改（改了会让已跑过迁移的库与迁移文件不一致）；新增一条迁移重新 COMMENT。
  # COLLATE "C" 的说明逐字保留——那条纪律仍然成立，此处只替换失效的符号指引。
  @collation_note "固定 COLLATE \"C\"：S3 要求桶名/key 按 UTF-8 字节序比较/排序（ListBuckets 按字节序返回；locale collation 会忽略 '-' '.' 等标点的权重），勿改回库默认 locale collation"

  @stale "桶名（S3 全局唯一，3-63 字符，命名规则见 Buckets.validate_name）。" <> @collation_note

  @current "桶名（S3 全局唯一，3-63 字符）。命名规则分两个不可混用的判定：新建准入见 Buckets.validate_creatable_name/1（额外拒绝保留名/保留前后缀，如 minio），寻址与写路径只做语法校验见 Buckets.validate_addressable_name/1（存量同名桶仍是合法可读写的桶）。" <>
             @collation_note

  def up do
    execute(~s[COMMENT ON COLUMN buckets.name IS '#{escape(@current)}'])
  end

  def down do
    execute(~s[COMMENT ON COLUMN buckets.name IS '#{escape(@stale)}'])
  end

  defp escape(text), do: String.replace(text, "'", "''")
end
