defmodule Maxio.S3.ChecksumTest do
  use ExUnit.Case, async: true

  import Bitwise

  alias Maxio.S3.Checksum

  @u64_mask 0xFFFFFFFFFFFFFFFF
  @xxh64_prime1 0x9E3779B185EBCA87
  @xxh64_prime2 0xC2B2AE3D27D4EB4F
  @xxh64_prime3 0x165667B19E3779F9
  @xxh64_prime4 0x85EBCA77C2B2AE63
  @xxh64_prime5 0x27D4EB2F165667C5

  test "wrap_stream cleans trailer getter on no-check success path" do
    parent = self()
    checksum = checksum_without_checks(fn -> send(parent, :trailers_read) end)

    {stream, get_context, _discard} = Checksum.wrap_stream(["data"], checksum)

    assert Enum.to_list(stream) == ["data"]
    context = get_context.()
    assert context.checks == []
    assert context.response_headers == []
    assert context.verify!.() == :ok
    assert_received :trailers_read
  end

  test "wrap_stream cleans trailer getter on no-check discard path" do
    parent = self()
    checksum = checksum_without_checks(fn -> send(parent, :trailers_discarded) end)

    {_stream, _get_context, discard} = Checksum.wrap_stream(["data"], checksum)

    assert discard.() == :ok
    assert_received :trailers_discarded
  end

  test "object_metadata returns AWS checksum field names for durable object metadata" do
    checksum = %{
      checks: [],
      get_trailers: fn -> %{} end,
      response_headers: [
        {"x-amz-checksum-crc32", "DUoRhQ=="},
        {"x-amz-checksum-crc32c", "yZRlqg=="},
        {"x-amz-checksum-crc64nvme", crc64nvme_b64("object")},
        {"x-amz-checksum-md5", "aOEJ8PQMpyoV4FzCJ4b45g=="},
        {"x-amz-checksum-sha1", "Kq5sNclPz7QV2+lfQIuc6R7oRu0="},
        {"x-amz-checksum-sha256", "ungWv48Bz+pBQUDeXa4iI7ADYaOWF3NbVm9YhQh/fxg="},
        {"x-amz-checksum-sha512", hash_b64(:sha512, "object")},
        {"x-amz-checksum-xxhash3", "f+tdioLBbYs="},
        {"x-amz-checksum-xxhash128", "n+6DAAd0dGNoe1vTFI1bBA=="},
        {"x-amz-checksum-xxhash64", xxhash64_b64("object")}
      ],
      verify!: fn -> :ok end
    }

    assert Checksum.object_metadata(checksum) == %{
             "ChecksumCRC32" => "DUoRhQ==",
             "ChecksumCRC32C" => "yZRlqg==",
             "ChecksumCRC64NVME" => crc64nvme_b64("object"),
             "ChecksumMD5" => "aOEJ8PQMpyoV4FzCJ4b45g==",
             "ChecksumSHA1" => "Kq5sNclPz7QV2+lfQIuc6R7oRu0=",
             "ChecksumSHA256" => "ungWv48Bz+pBQUDeXa4iI7ADYaOWF3NbVm9YhQh/fxg=",
             "ChecksumSHA512" => hash_b64(:sha512, "object"),
             "ChecksumXXHASH3" => "f+tdioLBbYs=",
             "ChecksumXXHASH128" => "n+6DAAd0dGNoe1vTFI1bBA==",
             "ChecksumXXHASH64" => xxhash64_b64("object"),
             "ChecksumType" => "FULL_OBJECT"
           }
  end

  test "object_metadata omits ChecksumType when no modeled checksum was supplied" do
    assert Checksum.object_metadata(checksum_without_checks(fn -> :ok end)) == %{}
  end

  test "for_copy_object_source_metadata recomputes the source metadata algorithm as full object" do
    checksum =
      Checksum.for_copy_object_source_metadata!(%{
        "ChecksumSHA256" => "old-composite-value-2",
        "ChecksumType" => "COMPOSITE"
      })

    {stream, get_context, _discard} = Checksum.wrap_stream(["copied ", "object"], checksum)

    assert Enum.to_list(stream) == ["copied ", "object"]

    context = get_context.()
    assert context.verify!.() == :ok

    assert Checksum.object_metadata(context) == %{
             "ChecksumSHA256" => hash_b64(:sha256, "copied object"),
             "ChecksumType" => "FULL_OBJECT"
           }
  end

  test "for_copy_object_source_metadata recomputes XXHASH3 source checksum metadata" do
    checksum =
      Checksum.for_copy_object_source_metadata!(%{
        "ChecksumXXHASH3" => "old-composite-value-2",
        "ChecksumType" => "COMPOSITE"
      })

    {stream, get_context, _discard} = Checksum.wrap_stream(["copied ", "object"], checksum)

    assert Enum.to_list(stream) == ["copied ", "object"]

    context = get_context.()
    assert context.verify!.() == :ok

    assert Checksum.object_metadata(context) == %{
             "ChecksumXXHASH3" => "S08MD3Os788=",
             "ChecksumType" => "FULL_OBJECT"
           }
  end

  test "for_copy_object_source_metadata fail-closes unknown source checksum metadata" do
    assert_raise Maxio.S3.Error, ~r/ChecksumBLAKE3/, fn ->
      Checksum.for_copy_object_source_metadata!(%{
        "ChecksumBLAKE3" => Base.encode64("unsupported"),
        "ChecksumType" => "FULL_OBJECT"
      })
    end
  end

  test "for_copy_object_source_metadata fail-closes checksum type without checksum value" do
    assert_raise Maxio.S3.Error, ~r/inconsistent/, fn ->
      Checksum.for_copy_object_source_metadata!(%{"ChecksumType" => "COMPOSITE"})
    end
  end

  test "multipart_upload_intent accepts composite-capable algorithms and defaults type" do
    assert Checksum.multipart_upload_intent!([{"x-amz-checksum-algorithm", "sha256"}]) == %{
             checksum_algorithm: "SHA256",
             checksum_type: "COMPOSITE"
           }

    assert Checksum.multipart_upload_intent!([
             {"x-amz-checksum-algorithm", "CRC32C"},
             {"x-amz-checksum-type", "COMPOSITE"}
           ]) == %{checksum_algorithm: "CRC32C", checksum_type: "COMPOSITE"}

    assert Checksum.multipart_upload_intent!([{"x-amz-checksum-algorithm", "XXHASH64"}]) == %{
             checksum_algorithm: "XXHASH64",
             checksum_type: "COMPOSITE"
           }

    assert Checksum.multipart_upload_intent!([{"x-amz-checksum-algorithm", "XXHASH3"}]) == %{
             checksum_algorithm: "XXHASH3",
             checksum_type: "COMPOSITE"
           }

    assert Checksum.multipart_upload_intent!([{"x-amz-checksum-algorithm", "XXHASH128"}]) == %{
             checksum_algorithm: "XXHASH128",
             checksum_type: "COMPOSITE"
           }
  end

  test "multipart_upload_intent accepts CRC full-object algorithms" do
    assert Checksum.multipart_upload_intent!([]) == %{
             checksum_algorithm: "CRC64NVME",
             checksum_type: "FULL_OBJECT"
           }

    assert Checksum.multipart_upload_intent!([
             {"x-amz-checksum-algorithm", "CRC32"},
             {"x-amz-checksum-type", "FULL_OBJECT"}
           ]) == %{checksum_algorithm: "CRC32", checksum_type: "FULL_OBJECT"}

    assert Checksum.multipart_upload_intent!([
             {"x-amz-checksum-algorithm", "CRC64NVME"}
           ]) == %{checksum_algorithm: "CRC64NVME", checksum_type: "FULL_OBJECT"}
  end

  test "complete_multipart_request parses supported full-object checksum headers" do
    assert Checksum.complete_multipart_request!([
             {"x-amz-checksum-crc64nvme", crc64nvme_b64("object")},
             {"x-amz-checksum-type", "FULL_OBJECT"},
             {"x-amz-mp-object-size", "6"}
           ]) == %{
             checksum_algorithm: "CRC64NVME",
             checksum_value: crc64nvme_b64("object"),
             checksum_type: "FULL_OBJECT",
             object_size: 6
           }
  end

  test "complete_multipart_request parses composite checksum headers" do
    assert Checksum.complete_multipart_request!([
             {"x-amz-checksum-sha256", hash_b64(:sha256, "composite")},
             {"x-amz-checksum-type", "COMPOSITE"}
           ]) == %{
             checksum_algorithm: "SHA256",
             checksum_value: hash_b64(:sha256, "composite"),
             checksum_type: "COMPOSITE",
             object_size: nil
           }

    assert Checksum.complete_multipart_request!([
             {"x-amz-checksum-xxhash64", xxhash64_b64("composite")},
             {"x-amz-checksum-type", "COMPOSITE"}
           ]) == %{
             checksum_algorithm: "XXHASH64",
             checksum_value: xxhash64_b64("composite"),
             checksum_type: "COMPOSITE",
             object_size: nil
           }

    assert Checksum.complete_multipart_request!([
             {"x-amz-checksum-xxhash3", "gCuMgkf0cck="},
             {"x-amz-checksum-type", "COMPOSITE"}
           ]) == %{
             checksum_algorithm: "XXHASH3",
             checksum_value: "gCuMgkf0cck=",
             checksum_type: "COMPOSITE",
             object_size: nil
           }

    assert Checksum.complete_multipart_request!([
             {"x-amz-checksum-xxhash128", "s2GE+XdRbgfl1/f+nyfW4Q=="},
             {"x-amz-checksum-type", "COMPOSITE"}
           ]) == %{
             checksum_algorithm: "XXHASH128",
             checksum_value: "s2GE+XdRbgfl1/f+nyfW4Q==",
             checksum_type: "COMPOSITE",
             object_size: nil
           }
  end

  test "full_object_multipart_context validates expected checksum" do
    checksum =
      Checksum.full_object_multipart_context!("CRC32C", %{
        checksum_value: crc32c_b64("full object")
      })

    {stream, get_context, _discard} = Checksum.wrap_stream(["full ", "object"], checksum)

    assert Enum.to_list(stream) == ["full ", "object"]
    assert get_context.().verify!.() == :ok
  end

  test "with_multipart_algorithm computes an inferred per-part checksum" do
    checksum =
      checksum_without_checks(fn -> :ok end)
      |> Checksum.with_multipart_algorithm!("SHA256")

    {stream, get_context, _discard} = Checksum.wrap_stream(["part"], checksum)

    assert Enum.to_list(stream) == ["part"]

    context = get_context.()
    assert context.verify!.() == :ok
    assert Checksum.part_metadata(context) == %{"ChecksumSHA256" => hash_b64(:sha256, "part")}
  end

  test "with_multipart_algorithm computes an inferred XXHASH64 per-part checksum" do
    checksum =
      checksum_without_checks(fn -> :ok end)
      |> Checksum.with_multipart_algorithm!("XXHASH64")

    {stream, get_context, _discard} = Checksum.wrap_stream(["xx", "hash", "64"], checksum)

    assert Enum.to_list(stream) == ["xx", "hash", "64"]

    context = get_context.()
    assert context.verify!.() == :ok
    assert Checksum.part_metadata(context) == %{"ChecksumXXHASH64" => xxhash64_b64("xxhash64")}
  end

  test "with_multipart_algorithm computes inferred XXHASH3 and XXHASH128 per-part checksums" do
    checksum =
      checksum_without_checks(fn -> :ok end)
      |> Checksum.with_multipart_algorithm!("XXHASH3")

    {stream, get_context, _discard} = Checksum.wrap_stream(["xx", "hash", "3"], checksum)

    assert Enum.to_list(stream) == ["xx", "hash", "3"]

    context = get_context.()
    assert context.verify!.() == :ok
    assert Checksum.part_metadata(context) == %{"ChecksumXXHASH3" => "tjWMdhyczyM="}

    checksum =
      checksum_without_checks(fn -> :ok end)
      |> Checksum.with_multipart_algorithm!("XXHASH128")

    {stream, get_context, _discard} = Checksum.wrap_stream(["xx", "hash", "128"], checksum)

    assert Enum.to_list(stream) == ["xx", "hash", "128"]

    context = get_context.()
    assert context.verify!.() == :ok
    assert Checksum.part_metadata(context) == %{"ChecksumXXHASH128" => "EsPy48lcSWehxJN+dkQr8w=="}
  end

  test "with_multipart_algorithm rejects explicit part checksums that differ from upload intent" do
    checksum = %{
      checks: [
        %{
          response_header: "x-amz-checksum-crc32",
          kind: :crc32,
          context: 0
        }
      ],
      get_trailers: fn -> %{} end,
      response_headers: [],
      verify!: fn -> :ok end
    }

    assert_raise Maxio.S3.Error, fn ->
      Checksum.with_multipart_algorithm!(checksum, "SHA256")
    end
  end

  test "composite_object_metadata builds S3 multipart SHA256 checksum of checksums" do
    part1 = hash_b64(:sha256, "first")
    part2 = hash_b64(:sha256, "second")

    expected =
      ["first", "second"]
      |> Enum.map(&:crypto.hash(:sha256, &1))
      |> IO.iodata_to_binary()
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode64()

    assert Checksum.composite_object_metadata([
             %{"PartNumber" => 1, "Size" => 5, "ChecksumSHA256" => part1},
             %{"PartNumber" => 2, "Size" => 6, "ChecksumSHA256" => part2}
           ]) ==
             {:ok, %{"ChecksumSHA256" => "#{expected}-2", "ChecksumType" => "COMPOSITE"}}
  end

  test "composite_object_metadata builds S3 multipart SHA512 checksum of checksums" do
    part1 = hash_b64(:sha512, "first")
    part2 = hash_b64(:sha512, "second")

    expected =
      ["first", "second"]
      |> Enum.map(&:crypto.hash(:sha512, &1))
      |> IO.iodata_to_binary()
      |> then(&:crypto.hash(:sha512, &1))
      |> Base.encode64()

    assert Checksum.composite_object_metadata([
             %{"PartNumber" => 1, "Size" => 5, "ChecksumSHA512" => part1},
             %{"PartNumber" => 2, "Size" => 6, "ChecksumSHA512" => part2}
           ]) ==
             {:ok, %{"ChecksumSHA512" => "#{expected}-2", "ChecksumType" => "COMPOSITE"}}
  end

  test "composite_object_metadata builds S3 multipart CRC32 checksum of checksums" do
    part1 = crc32_b64("first")
    part2 = crc32_b64("second")

    expected =
      ["first", "second"]
      |> Enum.map(&:erlang.crc32/1)
      |> Enum.map(&<<&1::32>>)
      |> IO.iodata_to_binary()
      |> :erlang.crc32()
      |> then(&<<&1::32>>)
      |> Base.encode64()

    assert Checksum.composite_object_metadata([
             %{"PartNumber" => 1, "Size" => 5, "ChecksumCRC32" => part1},
             %{"PartNumber" => 2, "Size" => 6, "ChecksumCRC32" => part2}
           ]) ==
             {:ok, %{"ChecksumCRC32" => "#{expected}-2", "ChecksumType" => "COMPOSITE"}}
  end

  test "composite_object_metadata builds S3 multipart CRC32C checksum of checksums" do
    part1 = crc32c_b64("first")
    part2 = crc32c_b64("second")

    expected = crc32c_b64([crc32c_raw("first"), crc32c_raw("second")])

    assert Checksum.composite_object_metadata([
             %{"PartNumber" => 1, "Size" => 5, "ChecksumCRC32C" => part1},
             %{"PartNumber" => 2, "Size" => 6, "ChecksumCRC32C" => part2}
           ]) ==
             {:ok, %{"ChecksumCRC32C" => "#{expected}-2", "ChecksumType" => "COMPOSITE"}}
  end

  test "composite_object_metadata builds S3 multipart XXHASH64 checksum of checksums" do
    part1 = xxhash64_b64("first")
    part2 = xxhash64_b64("second")

    expected =
      [xxhash64_raw("first"), xxhash64_raw("second")]
      |> IO.iodata_to_binary()
      |> xxhash64_b64()

    assert Checksum.composite_object_metadata([
             %{"PartNumber" => 1, "Size" => 5, "ChecksumXXHASH64" => part1},
             %{"PartNumber" => 2, "Size" => 6, "ChecksumXXHASH64" => part2}
           ]) ==
             {:ok, %{"ChecksumXXHASH64" => "#{expected}-2", "ChecksumType" => "COMPOSITE"}}
  end

  test "composite_object_metadata builds S3 multipart XXHASH3 and XXHASH128 checksums" do
    assert Checksum.composite_object_metadata([
             %{"PartNumber" => 1, "Size" => 18, "ChecksumXXHASH3" => "+IREpmYMwCQ="},
             %{"PartNumber" => 2, "Size" => 19, "ChecksumXXHASH3" => "pVA50B7iMtY="}
           ]) ==
             {:ok, %{"ChecksumXXHASH3" => "Plp2DY4jh2Y=-2", "ChecksumType" => "COMPOSITE"}}

    assert Checksum.composite_object_metadata([
             %{
               "PartNumber" => 1,
               "Size" => 20,
               "ChecksumXXHASH128" => "QHLeBw9KsSe3cm8p3RwD5w=="
             },
             %{"PartNumber" => 2, "Size" => 21, "ChecksumXXHASH128" => "Ok2MxmJsTYk+an8R4T3R0A=="}
           ]) ==
             {:ok,
              %{
                "ChecksumXXHASH128" => "Qyao1V7pHkcwj79QERWdhQ==-2",
                "ChecksumType" => "COMPOSITE"
              }}
  end

  test "xxhash64 stream implementation matches external vectors across stripe boundaries" do
    assert_xxhash64_chunks("", "70bbN1HY6Zk=", [])
    assert_xxhash64_chunks("123456789", "jLhB20DmroM=", [3, 3])

    assert_xxhash64_chunks(
      byte_range(30),
      "w0bStZtNjuE=",
      [7, 11]
    )

    assert_xxhash64_chunks(
      byte_range(31),
      "y/WcURb/MrQ=",
      [5, 9, 13]
    )

    assert_xxhash64_chunks(
      byte_range(32),
      "DFNdGsr7jq0=",
      [1, 31]
    )

    assert_xxhash64_chunks(
      byte_range(63) <> "boundary-split-check",
      "yNgzjTcajXM=",
      [5, 27, 3, 41]
    )
  end

  test "xxhash3 and xxhash128 stream implementations match external vectors across boundaries" do
    assert_checksum_chunks("XXHASH3", "ChecksumXXHASH3", "", "LQaABTjTlMI=", [])
    assert_checksum_chunks("XXHASH128", "ChecksumXXHASH128", "", "maoG0wFHmNhgAcMkRo1Jfw==", [])

    assert_checksum_chunks("XXHASH3", "ChecksumXXHASH3", "123456789", "ctyxi2ehff8=", [3, 3])

    assert_checksum_chunks(
      "XXHASH128",
      "ChecksumXXHASH128",
      "123456789",
      "MxGUd+3l3NXpcWQnaB1YYA==",
      [3, 3]
    )

    assert_checksum_chunks("XXHASH3", "ChecksumXXHASH3", byte_range(16), "nvNBqZ3jcyg=", [1, 7])

    assert_checksum_chunks(
      "XXHASH128",
      "ChecksumXXHASH128",
      byte_range(16),
      "aFvEWLN9BX/AbiM993KSFw==",
      [1, 7]
    )

    assert_checksum_chunks("XXHASH3", "ChecksumXXHASH3", byte_range(240), "AujNlUIcbQI=", [
      17,
      64,
      3
    ])

    assert_checksum_chunks(
      "XXHASH128",
      "ChecksumXXHASH128",
      byte_range(240),
      "HaHLYby4oqEC6M2VQhxtAg==",
      [17, 64, 3]
    )

    large = :binary.copy(byte_range(255), 5) <> "boundary"

    assert_checksum_chunks("XXHASH3", "ChecksumXXHASH3", large, "Fw4ryOM3Udo=", [1, 257, 31, 700])

    assert_checksum_chunks(
      "XXHASH128",
      "ChecksumXXHASH128",
      large,
      "9zWqJJ3hJdsXDivI4zdR2g==",
      [1, 257, 31, 700]
    )

    overlap = :binary.copy(byte_range(255), 8) <> <<0>>

    assert_checksum_chunks(
      "XXHASH3",
      "ChecksumXXHASH3",
      overlap,
      "Yt/zQ+fbrJs=",
      [513, 600, 700]
    )

    assert_checksum_chunks(
      "XXHASH128",
      "ChecksumXXHASH128",
      overlap,
      "lfZdR6iqIxZi3/ND59usmw==",
      [513, 600, 700]
    )
  end

  test "xxhash64 helper test vector uses canonical big-endian representation" do
    assert xxhash64_b64("") == "70bbN1HY6Zk="
  end

  test "crc32c helper test vector uses Castagnoli polynomial" do
    assert crc32c_b64("123456789") == "4waSgw=="
  end

  test "crc64nvme helper test vector uses NVMe polynomial" do
    assert crc64nvme_b64("123456789") == "rosUhgp5mIg="
  end

  test "composite_object_metadata omits unsupported or incomplete multipart checksums" do
    assert Checksum.composite_object_metadata([
             %{"PartNumber" => 1, "ChecksumCRC64NVME" => "DUoRhQ=="},
             %{"PartNumber" => 2, "ChecksumCRC64NVME" => "DUoRhQ=="}
           ]) == {:ok, %{}}

    assert Checksum.composite_object_metadata([
             %{"PartNumber" => 1, "ChecksumSHA256" => hash_b64(:sha256, "first")},
             %{"PartNumber" => 2}
           ]) == {:ok, %{}}
  end

  defp checksum_without_checks(on_trailers) do
    %{
      checks: [],
      get_trailers: fn ->
        on_trailers.()
        %{}
      end,
      response_headers: [],
      verify!: fn -> :ok end
    }
  end

  defp hash_b64(algorithm, body), do: :crypto.hash(algorithm, body) |> Base.encode64()

  defp crc32_b64(body), do: <<:erlang.crc32(body)::32>> |> Base.encode64()

  defp assert_xxhash64_chunks(data, expected, chunk_sizes) do
    checksum = Checksum.for_multipart_algorithm!("XXHASH64")
    chunks = binary_chunks(data, chunk_sizes)
    {stream, get_context, _discard} = Checksum.wrap_stream(chunks, checksum)

    assert IO.iodata_to_binary(Enum.to_list(stream)) == data

    context = get_context.()
    assert context.verify!.() == :ok
    assert Checksum.part_metadata(context) == %{"ChecksumXXHASH64" => expected}
  end

  defp assert_checksum_chunks(algorithm, field, data, expected, chunk_sizes) do
    checksum = Checksum.for_multipart_algorithm!(algorithm)
    chunks = binary_chunks(data, chunk_sizes)
    {stream, get_context, _discard} = Checksum.wrap_stream(chunks, checksum)

    assert IO.iodata_to_binary(Enum.to_list(stream)) == data

    context = get_context.()
    assert context.verify!.() == :ok
    assert Checksum.part_metadata(context) == %{field => expected}
  end

  defp binary_chunks("", []), do: []

  defp binary_chunks(data, sizes) do
    {chunks, rest} =
      Enum.map_reduce(sizes, data, fn size, bin ->
        <<chunk::binary-size(size), rest::binary>> = bin
        {chunk, rest}
      end)

    if rest == "", do: chunks, else: chunks ++ [rest]
  end

  defp byte_range(last), do: 0..last |> Enum.to_list() |> :binary.list_to_bin()

  defp crc32c_b64(iodata) do
    iodata
    |> IO.iodata_to_binary()
    |> crc32c_raw()
    |> Base.encode64()
  end

  defp crc32c_raw(iodata) do
    data = IO.iodata_to_binary(iodata)

    table =
      0..255
      |> Enum.map(fn byte ->
        Enum.reduce(1..8, byte, fn _bit, crc ->
          if Bitwise.band(crc, 1) == 1 do
            Bitwise.bxor(Bitwise.bsr(crc, 1), 0x82F63B78)
          else
            Bitwise.bsr(crc, 1)
          end
        end)
      end)
      |> List.to_tuple()

    crc =
      for <<byte <- data>>, reduce: Bitwise.bxor(0, 0xFFFFFFFF) do
        crc ->
          table_index = Bitwise.band(Bitwise.bxor(crc, byte), 0xFF)
          table_value = elem(table, table_index)
          Bitwise.bxor(Bitwise.bsr(crc, 8), table_value)
      end

    <<Bitwise.band(Bitwise.bxor(crc, 0xFFFFFFFF), 0xFFFFFFFF)::32>>
  end

  defp crc64nvme_b64(iodata) do
    iodata
    |> IO.iodata_to_binary()
    |> crc64nvme_raw()
    |> Base.encode64()
  end

  defp crc64nvme_raw(iodata) do
    data = IO.iodata_to_binary(iodata)

    table =
      0..255
      |> Enum.map(fn byte ->
        Enum.reduce(1..8, byte, fn _bit, crc ->
          if Bitwise.band(crc, 1) == 1 do
            Bitwise.bxor(Bitwise.bsr(crc, 1), 0x9A6C9329AC4BC9B5)
          else
            Bitwise.bsr(crc, 1)
          end
        end)
      end)
      |> List.to_tuple()

    crc =
      for <<byte <- data>>, reduce: Bitwise.bxor(0, 0xFFFFFFFFFFFFFFFF) do
        crc ->
          table_index = Bitwise.band(Bitwise.bxor(crc, byte), 0xFF)
          table_value = elem(table, table_index)
          Bitwise.bxor(Bitwise.bsr(crc, 8), table_value)
      end

    <<Bitwise.band(Bitwise.bxor(crc, 0xFFFFFFFFFFFFFFFF), 0xFFFFFFFFFFFFFFFF)::64>>
  end

  defp xxhash64_b64(iodata) do
    iodata
    |> IO.iodata_to_binary()
    |> xxhash64_raw()
    |> Base.encode64()
  end

  defp xxhash64_raw(iodata) do
    data = IO.iodata_to_binary(iodata)
    <<xxhash64_digest(data)::unsigned-integer-size(64)>>
  end

  defp xxhash64_digest(data) do
    {v1, v2, v3, v4, rest} =
      xxh64_stripes(
        data,
        u64(@xxh64_prime1 + @xxh64_prime2),
        @xxh64_prime2,
        0,
        u64(-@xxh64_prime1)
      )

    acc =
      if byte_size(data) >= 32 do
        v1
        |> rotl64(1)
        |> add64(rotl64(v2, 7))
        |> add64(rotl64(v3, 12))
        |> add64(rotl64(v4, 18))
        |> xxh64_merge_round(v1)
        |> xxh64_merge_round(v2)
        |> xxh64_merge_round(v3)
        |> xxh64_merge_round(v4)
      else
        @xxh64_prime5
      end

    acc
    |> add64(byte_size(data))
    |> xxh64_tail(rest)
    |> xxh64_avalanche()
  end

  defp xxh64_stripes(data, v1, v2, v3, v4) when byte_size(data) < 32,
    do: {v1, v2, v3, v4, data}

  defp xxh64_stripes(data, v1, v2, v3, v4) do
    <<d1::little-unsigned-integer-size(64), d2::little-unsigned-integer-size(64),
      d3::little-unsigned-integer-size(64), d4::little-unsigned-integer-size(64), rest::binary>> =
      data

    xxh64_stripes(
      rest,
      xxh64_round(v1, d1),
      xxh64_round(v2, d2),
      xxh64_round(v3, d3),
      xxh64_round(v4, d4)
    )
  end

  defp xxh64_tail(acc, <<lane::little-unsigned-integer-size(64), rest::binary>>) do
    acc
    |> bxor(xxh64_round(0, lane))
    |> rotl64(27)
    |> mul64(@xxh64_prime1)
    |> add64(@xxh64_prime4)
    |> xxh64_tail(rest)
  end

  defp xxh64_tail(acc, <<lane::little-unsigned-integer-size(32), rest::binary>>) do
    acc
    |> bxor(mul64(lane, @xxh64_prime1))
    |> rotl64(23)
    |> mul64(@xxh64_prime2)
    |> add64(@xxh64_prime3)
    |> xxh64_tail(rest)
  end

  defp xxh64_tail(acc, <<byte::unsigned-integer-size(8), rest::binary>>) do
    acc
    |> bxor(mul64(byte, @xxh64_prime5))
    |> rotl64(11)
    |> mul64(@xxh64_prime1)
    |> xxh64_tail(rest)
  end

  defp xxh64_tail(acc, ""), do: acc

  defp xxh64_round(acc, input) do
    acc
    |> add64(mul64(input, @xxh64_prime2))
    |> rotl64(31)
    |> mul64(@xxh64_prime1)
  end

  defp xxh64_merge_round(acc, value) do
    acc
    |> bxor(xxh64_round(0, value))
    |> mul64(@xxh64_prime1)
    |> add64(@xxh64_prime4)
  end

  defp xxh64_avalanche(acc) do
    acc = acc |> bxor(bsr(acc, 33)) |> mul64(@xxh64_prime2)
    acc = acc |> bxor(bsr(acc, 29)) |> mul64(@xxh64_prime3)
    acc |> bxor(bsr(acc, 32)) |> u64()
  end

  defp rotl64(value, shift), do: u64(bor(bsl(value, shift), bsr(value, 64 - shift)))
  defp add64(left, right), do: u64(left + right)
  defp mul64(left, right), do: u64(left * right)
  defp u64(value), do: band(value, @u64_mask)
end
