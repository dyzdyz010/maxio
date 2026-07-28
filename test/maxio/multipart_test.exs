defmodule Maxio.MultipartTest do
  use Maxio.DataCase, async: true

  alias Maxio.{Buckets, Multipart}
  alias Maxio.S3.Checksum

  setup do
    {:ok, _} = Buckets.create("mp-bucket", "arn:aws:iam:::root")
    :ok
  end

  describe "multipart_etag/1（KNOWN-ANSWER）" do
    test "= hex(MD5(concat raw MD5s))-N" do
      m1 = :crypto.hash(:md5, "A")
      m2 = :crypto.hash(:md5, "B")

      expected =
        (:crypto.hash(:md5, m1 <> m2) |> Base.encode16(case: :lower)) <> "-2"

      assert Multipart.multipart_etag([m1, m2]) == expected
    end
  end

  describe "initiate/get_upload/put_part/complete（注入 min_part_size: 1）" do
    test "initiate_with rolls back the upload row when the callback fails" do
      assert {:error, :registry_failed} =
               Multipart.initiate_with(
                 "mp-bucket",
                 "rollback",
                 %{owner: "arn:aws:iam:::root"},
                 fn _upload -> {:error, :registry_failed} end
               )

      assert Multipart.list_uploads("mp-bucket", %{prefix: "rollback"}).uploads == []
    end

    test "complete returns multipart etag and size for uploaded parts" do
      {:ok, up} = Multipart.initiate("mp-bucket", "obj", %{owner: "arn:aws:iam:::root"})

      {:ok, r1} = Maxio.Storage.put_part("mp-bucket", "obj", up.upload_id, 1, ["AAAAA"])
      {:ok, r2} = Maxio.Storage.put_part("mp-bucket", "obj", up.upload_id, 2, ["BB"])
      {:ok, _} = Multipart.put_part(up, 1, %{etag: r1.etag, size: r1.size})
      {:ok, _} = Multipart.put_part(up, 2, %{etag: r2.etag, size: r2.size})

      requested = [
        %{part_number: 1, etag: "\"#{r1.etag}\""},
        %{part_number: 2, etag: "\"#{r2.etag}\""}
      ]

      {:ok, %{etag: etag, size: size}} = Multipart.complete(up, requested, min_part_size: 1)

      assert size == 7
      assert String.ends_with?(etag, "-2")
      assert {:ok, stream} = Maxio.Storage.get("mp-bucket", "obj", "null", nil)
      assert IO.iodata_to_binary(Enum.to_list(stream)) == "AAAAABB"
    end

    test "缺失 part → :invalid_part" do
      {:ok, up} = Multipart.initiate("mp-bucket", "o2", %{owner: "arn:aws:iam:::root"})
      {:ok, r1} = Maxio.Storage.put_part("mp-bucket", "o2", up.upload_id, 1, ["X"])
      {:ok, _} = Multipart.put_part(up, 1, %{etag: r1.etag, size: r1.size})

      requested = [
        %{part_number: 1, etag: "\"#{r1.etag}\""},
        %{part_number: 2, etag: "\"deadbeef\""}
      ]

      assert {:error, :invalid_part} = Multipart.complete(up, requested, min_part_size: 1)
    end

    test "乱序 part → :invalid_part_order" do
      {:ok, up} = Multipart.initiate("mp-bucket", "o3", %{owner: "arn:aws:iam:::root"})
      {:ok, r1} = Maxio.Storage.put_part("mp-bucket", "o3", up.upload_id, 1, ["X"])
      {:ok, r2} = Maxio.Storage.put_part("mp-bucket", "o3", up.upload_id, 2, ["Y"])
      {:ok, _} = Multipart.put_part(up, 1, %{etag: r1.etag, size: r1.size})
      {:ok, _} = Multipart.put_part(up, 2, %{etag: r2.etag, size: r2.size})

      requested = [
        %{part_number: 2, etag: "\"#{r2.etag}\""},
        %{part_number: 1, etag: "\"#{r1.etag}\""}
      ]

      assert {:error, :invalid_part_order} = Multipart.complete(up, requested, min_part_size: 1)
    end

    test "非末 part 小于 min_part_size → :entity_too_small" do
      {:ok, up} = Multipart.initiate("mp-bucket", "o4", %{owner: "arn:aws:iam:::root"})
      {:ok, r1} = Maxio.Storage.put_part("mp-bucket", "o4", up.upload_id, 1, ["tiny"])
      {:ok, r2} = Maxio.Storage.put_part("mp-bucket", "o4", up.upload_id, 2, ["last"])
      {:ok, _} = Multipart.put_part(up, 1, %{etag: r1.etag, size: r1.size})
      {:ok, _} = Multipart.put_part(up, 2, %{etag: r2.etag, size: r2.size})

      requested = [
        %{part_number: 1, etag: "\"#{r1.etag}\""},
        %{part_number: 2, etag: "\"#{r2.etag}\""}
      ]

      assert {:error, :entity_too_small} =
               Multipart.complete(up, requested, min_part_size: 5_242_880)
    end

    test "CRC64NVME FULL_OBJECT completes by hashing assembled object bytes" do
      {:ok, up} =
        Multipart.initiate("mp-bucket", "o-crc64", %{
          owner: "arn:aws:iam:::root",
          checksum_algorithm: "CRC64NVME",
          checksum_type: "FULL_OBJECT"
        })

      {:ok, r1} = Maxio.Storage.put_part("mp-bucket", "o-crc64", up.upload_id, 1, ["X"])

      {:ok, _} = Multipart.put_part(up, 1, %{etag: r1.etag, size: r1.size})

      requested = [
        %{
          part_number: 1,
          etag: "\"#{r1.etag}\""
        }
      ]

      expected = checksum_metadata!("CRC64NVME", ["X"])

      assert {:ok, %{checksum: ^expected, size: 1}} =
               Multipart.complete(up, requested, min_part_size: 1)

      assert {:ok, stream} = Maxio.Storage.get("mp-bucket", "o-crc64", "null", nil)
      assert IO.iodata_to_binary(Enum.to_list(stream)) == "X"
    end

    test "abort 删会话且 get_upload 报 not_found" do
      {:ok, up} = Multipart.initiate("mp-bucket", "o5", %{owner: "arn:aws:iam:::root"})
      assert :ok = Multipart.abort(up)
      assert {:error, :not_found} = Multipart.get_upload("mp-bucket", "o5", up.upload_id)
    end

    test "list_parts 升序 + part_number_marker 过滤" do
      {:ok, up} = Multipart.initiate("mp-bucket", "o6", %{owner: "arn:aws:iam:::root"})
      for pn <- [1, 2, 3], do: Multipart.put_part(up, pn, %{etag: "e#{pn}", size: pn})

      res = Multipart.list_parts(up, %{part_number_marker: 1})
      assert Enum.map(res.parts, & &1.part_number) == [2, 3]
    end

    test "list_uploads uses initiation time before upload_id for same-key pagination" do
      {:ok, first} = Multipart.initiate("mp-bucket", "same-key", %{owner: "arn:aws:iam:::root"})
      {:ok, second} = Multipart.initiate("mp-bucket", "same-key", %{owner: "arn:aws:iam:::root"})

      first_upload_id = "z-first-upload-id"
      second_upload_id = "a-second-upload-id"
      first_initiated = ~U[2026-01-01 00:00:00.000000Z]
      second_initiated = ~U[2026-01-01 00:00:01.000000Z]

      Repo.update_all(
        from(u in Maxio.Multipart.Upload, where: u.id == ^first.id),
        set: [
          upload_id: first_upload_id,
          inserted_at: first_initiated,
          updated_at: first_initiated
        ]
      )

      Repo.update_all(
        from(u in Maxio.Multipart.Upload, where: u.id == ^second.id),
        set: [
          upload_id: second_upload_id,
          inserted_at: second_initiated,
          updated_at: second_initiated
        ]
      )

      page1 = Multipart.list_uploads("mp-bucket", %{max_uploads: 1})
      assert Enum.map(page1.uploads, & &1.upload_id) == [first_upload_id]
      assert page1.is_truncated
      assert page1.next_key_marker == "same-key"
      assert page1.next_upload_id_marker == first_upload_id

      page2 =
        Multipart.list_uploads("mp-bucket", %{
          max_uploads: 1,
          key_marker: page1.next_key_marker,
          upload_id_marker: page1.next_upload_id_marker
        })

      assert Enum.map(page2.uploads, & &1.upload_id) == [second_upload_id]
      refute page2.is_truncated
    end

    test "list_uploads delimiter marker does not repeat a returned common prefix" do
      {:ok, _} = Multipart.initiate("mp-bucket", "photos/2006/a.jpg")
      {:ok, _} = Multipart.initiate("mp-bucket", "photos/2006/b.jpg")
      {:ok, _} = Multipart.initiate("mp-bucket", "photos/2007/a.jpg")

      page1 =
        Multipart.list_uploads("mp-bucket", %{
          prefix: "photos/",
          delimiter: "/",
          max_uploads: 1
        })

      assert page1.uploads == []
      assert page1.common_prefixes == ["photos/2006/"]
      assert page1.is_truncated
      assert page1.next_key_marker == "photos/2006/"
      assert page1.next_upload_id_marker == nil

      page2 =
        Multipart.list_uploads("mp-bucket", %{
          prefix: "photos/",
          delimiter: "/",
          max_uploads: 1,
          key_marker: page1.next_key_marker
        })

      assert page2.uploads == []
      assert page2.common_prefixes == ["photos/2007/"]
      refute page2.is_truncated
    end

    test "list_uploads normalizes nonpositive internal max_uploads to a progressable page" do
      {:ok, _} = Multipart.initiate("mp-bucket", "internal/a")
      {:ok, _} = Multipart.initiate("mp-bucket", "internal/b")

      page = Multipart.list_uploads("mp-bucket", %{prefix: "internal/", max_uploads: 0})

      assert Enum.map(page.uploads, & &1.key) == ["internal/a", "internal/b"]
      refute page.is_truncated
      assert page.next_key_marker == nil
      assert page.next_upload_id_marker == nil
    end
  end

  defp checksum_metadata!(algorithm, chunks) do
    checksum = Checksum.full_object_multipart_context!(algorithm, %{})
    {stream, get_context, _discard} = Checksum.wrap_stream(chunks, checksum)
    _ = Enum.to_list(stream)
    context = get_context.()
    :ok = context.verify!.()
    Checksum.object_metadata(context)
  end
end
