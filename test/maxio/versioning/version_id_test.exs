defmodule Maxio.Versioning.VersionIdTest do
  use ExUnit.Case, async: true
  alias Maxio.Versioning.VersionId

  test "generate 产出 26 字符 Crockford base32，URL-safe" do
    id = VersionId.generate()
    assert byte_size(id) == 26
    assert Regex.match?(~r/\A[0-9A-HJKMNP-TV-Z]{26}\z/, id)
  end

  test "时间有序：后生成的 >= 先生成的（字典序）" do
    a = VersionId.generate()
    Process.sleep(2)
    b = VersionId.generate()
    assert b >= a
  end

  test "null sentinel" do
    assert VersionId.null_sentinel() == "null"
  end

  test "唯一性（1000 次无碰撞）" do
    ids = for _ <- 1..1000, do: VersionId.generate()
    assert length(Enum.uniq(ids)) == 1000
  end
end
