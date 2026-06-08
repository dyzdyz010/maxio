defmodule Maxio.Auth.SigV4.StreamingVerifierTest do
  use ExUnit.Case, async: true

  alias Maxio.Auth.SigV4.{Signer, StreamingVerifier}

  # AWS 官方 sigv4-streaming worked-example 参数
  @secret "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"
  @scope_date "20130524"
  @region "us-east-1"
  @service "s3"
  @amz_date "20130524T000000Z"
  @scope "20130524/us-east-1/s3/aws4_request"
  @seed "4f232c4386841ef735655705268965c44a0e4690baa4adea153f7db9fa80a0a9"
  @empty_sha "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"

  @sig1 "ad80c730a21e5b8d04586a2213dd63b9a0e99e0e2307b0ade35a65485a288648"
  @sig2 "0055627c9e194cb4542bae2aa5492e3c1575bbb81b612b7d234b86a503ef5497"
  @sig3 "b6c6ea8a5354eaf15b3cb7646744f4275b71ea724fed81ceb9323e279d449df9"

  defp k_signing, do: Signer.derive_signing_key(@secret, @scope_date, @region, @service)

  defp data1, do: String.duplicate("a", 65_536)
  defp data2, do: String.duplicate("a", 1024)

  # 用项目自己的 Signer 复算某块签名（与 verifier 内部应一致）
  defp expected_sig(prev_sig, data) do
    data_hash = Signer.hex_sha256(data)
    sts = StreamingVerifier.chunk_string_to_sign(@amz_date, @scope, prev_sig, data_hash)
    Signer.signature(k_signing(), sts)
  end

  # 按帧格式拼一个 chunk（含 chunk-signature）
  defp frame(data, sig) do
    size_hex = Integer.to_string(byte_size(data), 16) |> String.downcase()
    "#{size_hex};chunk-signature=#{sig}\r\n" <> data <> "\r\n"
  end

  describe "chunk_string_to_sign/4（6 行，无尾换行）" do
    test "结构与 AWS 向量一致（line5 == 空串常量）" do
      sts =
        StreamingVerifier.chunk_string_to_sign(
          @amz_date,
          @scope,
          @seed,
          Signer.hex_sha256(data1())
        )

      lines = String.split(sts, "\n")
      assert length(lines) == 6
      assert Enum.at(lines, 0) == "AWS4-HMAC-SHA256-PAYLOAD"
      assert Enum.at(lines, 1) == @amz_date
      assert Enum.at(lines, 2) == @scope
      assert Enum.at(lines, 3) == @seed
      assert Enum.at(lines, 4) == @empty_sha

      assert Enum.at(lines, 5) ==
               "bf718b6f653bebc184e1479f1935b8da974d701b893afcf49e701f3e2f9f9c5a"

      refute String.ends_with?(sts, "\n")
    end
  end

  describe "KNOWN-ANSWER：项目 Signer 复算的每块签名 == AWS 向量" do
    test "chunk1/2/3 签名链 byte-for-byte 一致" do
      s1 = expected_sig(@seed, data1())
      assert s1 == @sig1
      s2 = expected_sig(s1, data2())
      assert s2 == @sig2
      s3 = expected_sig(s2, "")
      assert s3 == @sig3
    end
  end

  describe "feed/2 + finalize/1（完整链）" do
    test "三块流（含终止块）全部验证通过，产出纯净 data 与正确长度" do
      v =
        StreamingVerifier.init(
          k_signing: k_signing(),
          date: @amz_date,
          scope: @scope,
          seed_signature: @seed,
          expected_decoded_len: 66_560,
          flavor: :signed
        )

      stream =
        frame(data1(), @sig1) <> frame(data2(), @sig2) <> frame("", @sig3)

      assert {:ok, chunks, v2} = StreamingVerifier.feed(v, stream)
      assert IO.iodata_to_binary(chunks) == data1() <> data2()
      assert StreamingVerifier.finalize(v2) == :ok
    end

    test "分片喂入（半个帧）也能正确累积验证" do
      v =
        StreamingVerifier.init(
          k_signing: k_signing(),
          date: @amz_date,
          scope: @scope,
          seed_signature: @seed,
          expected_decoded_len: 66_560,
          flavor: :signed
        )

      full = frame(data1(), @sig1) <> frame(data2(), @sig2) <> frame("", @sig3)
      {a, b} = String.split_at(full, 100)

      assert {:ok, c1, v1} = StreamingVerifier.feed(v, a)
      assert {:ok, c2, v2} = StreamingVerifier.feed(v1, b)
      assert IO.iodata_to_binary([c1, c2]) == data1() <> data2()
      assert StreamingVerifier.finalize(v2) == :ok
    end

    test "篡改 data 一字节 → :signature_does_not_match（铁律 3 硬失败）" do
      v =
        StreamingVerifier.init(
          k_signing: k_signing(),
          date: @amz_date,
          scope: @scope,
          seed_signature: @seed,
          expected_decoded_len: 66_560,
          flavor: :signed
        )

      tampered = String.duplicate("a", 65_535) <> "b"
      stream = frame(tampered, @sig1)
      assert {:error, :signature_does_not_match} = StreamingVerifier.feed(v, stream)
    end

    test "错误的 chunk-signature → :signature_does_not_match" do
      v =
        StreamingVerifier.init(
          k_signing: k_signing(),
          date: @amz_date,
          scope: @scope,
          seed_signature: @seed,
          expected_decoded_len: 66_560,
          flavor: :signed
        )

      stream = frame(data1(), String.duplicate("0", 64))
      assert {:error, :signature_does_not_match} = StreamingVerifier.feed(v, stream)
    end

    test "缺 ;chunk-signature= → :invalid_chunk" do
      v =
        StreamingVerifier.init(
          k_signing: k_signing(),
          date: @amz_date,
          scope: @scope,
          seed_signature: @seed,
          expected_decoded_len: 0,
          flavor: :signed
        )

      stream = "10000\r\n" <> data1() <> "\r\n"
      assert {:error, :invalid_chunk} = StreamingVerifier.feed(v, stream)
    end

    test "未达终止块即 finalize → :incomplete_body" do
      v =
        StreamingVerifier.init(
          k_signing: k_signing(),
          date: @amz_date,
          scope: @scope,
          seed_signature: @seed,
          expected_decoded_len: 66_560,
          flavor: :signed
        )

      {:ok, _c, v2} = StreamingVerifier.feed(v, frame(data1(), @sig1))
      assert {:error, :incomplete_body} = StreamingVerifier.finalize(v2)
    end

    test "decoded 长度与声明不符 → finalize :incomplete_body" do
      v =
        StreamingVerifier.init(
          k_signing: k_signing(),
          date: @amz_date,
          scope: @scope,
          seed_signature: @seed,
          expected_decoded_len: 999_999,
          flavor: :signed
        )

      stream = frame(data1(), @sig1) <> frame(data2(), @sig2) <> frame("", @sig3)
      {:ok, _c, v2} = StreamingVerifier.feed(v, stream)
      assert {:error, :incomplete_body} = StreamingVerifier.finalize(v2)
    end
  end
end
