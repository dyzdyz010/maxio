defmodule Maxio.Crypto.SSETest do
  use ExUnit.Case, async: true
  alias Maxio.Crypto.SSE

  setup do
    prev = Application.get_env(:maxio, :sse)
    key = :crypto.strong_rand_bytes(32) |> Base.encode64()
    Application.put_env(:maxio, :sse, master_key: key)
    on_exit(fn -> Application.put_env(:maxio, :sse, prev) end)
    :ok
  end

  test "wrap/unwrap 往返还原明文（单块）" do
    plain = "Welcome to Amazon S3 SSE-S3."
    {cipher_stream, envelope} = SSE.wrap_stream([plain])
    cipher = Enum.to_list(cipher_stream) |> IO.iodata_to_binary()
    refute cipher == plain

    out = SSE.unwrap_stream([cipher], envelope) |> Enum.to_list() |> IO.iodata_to_binary()
    assert out == plain
  end

  test "多块流往返（>64KB）" do
    plain = :crypto.strong_rand_bytes(200_000)
    {cipher_stream, envelope} = SSE.wrap_stream([plain])
    cipher = Enum.to_list(cipher_stream) |> IO.iodata_to_binary()

    out = SSE.unwrap_stream([cipher], envelope) |> Enum.to_list() |> IO.iodata_to_binary()
    assert out == plain
  end

  test "unwrap_stream 支持密文帧跨输入 chunk 切分" do
    plain = :crypto.strong_rand_bytes(80_000)
    {cipher_stream, envelope} = SSE.wrap_stream([plain])
    cipher = Enum.to_list(cipher_stream) |> IO.iodata_to_binary()

    split_cipher =
      cipher
      |> :binary.bin_to_list()
      |> Enum.chunk_every(7)
      |> Enum.map(&:erlang.list_to_binary/1)

    out = SSE.unwrap_stream(split_cipher, envelope) |> Enum.to_list() |> IO.iodata_to_binary()
    assert out == plain
  end

  test "篡改密文 → 解密 raise（GCM 认证失败，绝不静默）" do
    {cipher_stream, envelope} = SSE.wrap_stream(["data"])
    cipher = Enum.to_list(cipher_stream) |> IO.iodata_to_binary()

    tampered =
      cipher
      |> :binary.bin_to_list()
      |> List.update_at(-1, &Bitwise.bxor(&1, 0xFF))
      |> :erlang.list_to_binary()

    assert_raise RuntimeError, fn ->
      SSE.unwrap_stream([tampered], envelope) |> Enum.to_list()
    end
  end
end
