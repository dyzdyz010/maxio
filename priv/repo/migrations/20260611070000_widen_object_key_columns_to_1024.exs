defmodule Maxio.Repo.Migrations.WidenObjectKeyColumnsTo1024 do
  use Ecto.Migration

  @moduledoc """
  ROUTE B B5-4 —— 对象 key 列宽与 S3 key 上限对齐。

  S3/MinIO 对象 key 上限为 **1024 字节**（B5-4 入口守卫 `Paths.validate_key/1` 同源），
  而 Ecto `:string` 默认 varchar(255)——合法的长 key（256..1024 字节）在 PG 索引落库时
  曾触发 22001 string_data_right_truncation → 500（违铁律 3：合法请求绝不塌缩内部错误）。
  改为 varchar(1024)：守卫按**字节**计量（UTF-8 字符数 ≤ 字节数），1024 字节 key 必然
  ≤ 1024 字符，列宽充分；既有 btree 索引行（≤ 1024B key）远低于 PG 索引行上限，无需重建。
  """

  def change do
    alter table(:objects) do
      modify :key, :string,
        size: 1024,
        null: false,
        from: {:string, size: 255, null: false},
        comment:
          "对象键（完整 S3 key，含任意 / 层级；与 bucket 唯一确定一个对象）。" <>
            "S3/MinIO key 上限 1024 字节 → varchar(1024)，与 B5-4 入口守卫（Paths.validate_key）同源"
    end

    alter table(:multipart_uploads) do
      modify :key, :string,
        size: 1024,
        null: false,
        from: {:string, size: 255, null: false},
        comment:
          "目标对象键（Complete 后写入此 key）。" <>
            "S3/MinIO key 上限 1024 字节 → varchar(1024)，与 B5-4 入口守卫（Paths.validate_key）同源"
    end
  end
end
