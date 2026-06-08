defmodule Maxio.S3.BodyReaderTest do
  use ExUnit.Case, async: true

  alias Maxio.S3.BodyReader

  describe "parse_chunk_header/1（aws-chunked 帧头解析，区分 0 终止块 vs 非 hex 垃圾）" do
    test "合法 hex 帧头返回 {:ok, size}" do
      assert {:ok, 65_536} = BodyReader.parse_chunk_header("10000;chunk-signature=abc")
      assert {:ok, 1024} = BodyReader.parse_chunk_header("400;chunk-signature=def")
      assert {:ok, 10} = BodyReader.parse_chunk_header("a")
    end

    test "0 大小终止帧头返回 {:ok, 0}" do
      assert {:ok, 0} = BodyReader.parse_chunk_header("0;chunk-signature=ffff")
      assert {:ok, 0} = BodyReader.parse_chunk_header("0")
    end

    test "非 hex 垃圾帧头返回 :error（不再静默当 0）" do
      assert :error = BodyReader.parse_chunk_header("xyz;chunk-signature=abc")
      assert :error = BodyReader.parse_chunk_header("")
      assert :error = BodyReader.parse_chunk_header("  ;chunk-signature=abc")
    end
  end
end
