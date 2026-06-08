defmodule Maxio.Storage.Erasure.MetaTest do
  use ExUnit.Case, async: true
  alias Maxio.Storage.Erasure.Meta

  test "encode -> decode! round-trip 保形" do
    m = %{
      "ec" => %{"k" => 4, "m" => 2, "block_size" => 1024, "algo" => "blake3-256"},
      "size" => 900,
      "etag" => "abc",
      "sha256" => "def",
      "parts" => [%{"part" => 0, "size" => 900}],
      "shards" => [
        %{"drive" => 0, "shard_file_size" => 256, "block_hashes" => ["aa", "bb"]},
        %{"drive" => 1, "shard_file_size" => 256, "block_hashes" => ["cc", "dd"]}
      ]
    }

    bin = Meta.encode(m)
    assert is_binary(bin)
    assert Meta.decode!(bin) == m
  end
end
