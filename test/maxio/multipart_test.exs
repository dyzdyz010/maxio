defmodule Maxio.MultipartTest do
  use Maxio.DataCase, async: true

  alias Maxio.{Buckets, Multipart}

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
    test "完整闭环：发起→传两块→完成，返回 multipart ETag 与总大小" do
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
  end
end
