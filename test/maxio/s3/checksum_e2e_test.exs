defmodule Maxio.S3.ChecksumE2ETest do
  use Maxio.DataCase, async: false

  import Ecto.Query
  import Bitwise
  import Plug.Conn

  alias Maxio.Objects.Object
  alias Maxio.Repo
  alias Maxio.S3.Endpoint
  alias Maxio.Sidecar
  alias Maxio.Test.SigV4Request

  @data_dir Path.join(System.tmp_dir!(), "maxio_checksum_e2e")
  @u64_mask 0xFFFFFFFFFFFFFFFF
  @xxh64_prime1 0x9E3779B185EBCA87
  @xxh64_prime2 0xC2B2AE3D27D4EB4F
  @xxh64_prime3 0x165667B19E3779F9
  @xxh64_prime4 0x85EBCA77C2B2AE63
  @xxh64_prime5 0x27D4EB2F165667C5

  setup do
    File.rm_rf(@data_dir)
    File.mkdir_p!(@data_dir)
    prev = Application.get_env(:maxio, :s3)
    prev_min_part_size = Application.get_env(:maxio, :multipart_min_part_size)
    Application.put_env(:maxio, :s3, Keyword.put(prev, :data_dir, @data_dir))
    Application.put_env(:maxio, :multipart_min_part_size, 1)

    on_exit(fn ->
      Application.put_env(:maxio, :s3, prev)

      if prev_min_part_size,
        do: Application.put_env(:maxio, :multipart_min_part_size, prev_min_part_size),
        else: Application.delete_env(:maxio, :multipart_min_part_size)

      File.rm_rf(@data_dir)
    end)

    :ok
  end

  defp call(conn), do: Endpoint.call(conn, Endpoint.init([]))

  defp assert_persisted_checksum(bucket, key, expected_checksum) do
    assert %Object{checksum: pg_checksum} =
             Repo.get_by(Object, bucket_name: bucket, key: key, is_latest: true)

    assert pg_checksum == expected_checksum

    meta =
      [@data_dir, bucket, key, "meta.json"]
      |> Path.join()
      |> File.read!()
      |> Sidecar.decode!()

    assert [%{"checksum" => sidecar_checksum}] = meta["versions"]
    assert sidecar_checksum == expected_checksum
  end

  test "PutObject validates x-amz-checksum-sha256 and echoes the checksum header" do
    SigV4Request.signed_conn(:put, "/cksum") |> call()
    body = "checksum payload"
    checksum = hash_b64(:sha256, body)

    put =
      SigV4Request.signed_conn(:put, "/cksum/ok.txt",
        body: body,
        headers: [
          {"x-amz-sdk-checksum-algorithm", "SHA256"},
          {"x-amz-checksum-sha256", checksum}
        ]
      )
      |> call()

    assert put.status == 200
    assert get_resp_header(put, "x-amz-checksum-sha256") == [checksum]
    assert get_resp_header(put, "x-amz-checksum-crc64nvme") == []

    get = SigV4Request.signed_conn(:get, "/cksum/ok.txt") |> call()
    assert get.status == 200
    assert get.resp_body == body
  end

  test "PutObject defaults to CRC64NVME when no modeled checksum is supplied" do
    SigV4Request.signed_conn(:put, "/ckdefaultcrc64") |> call()
    body = "default crc64nvme payload"
    checksum = crc64nvme_b64(body)

    put =
      SigV4Request.signed_conn(:put, "/ckdefaultcrc64/ok.txt", body: body)
      |> call()

    assert put.status == 200
    assert get_resp_header(put, "x-amz-checksum-crc64nvme") == [checksum]

    assert %Object{checksum: pg_checksum} =
             Repo.get_by(Object, bucket_name: "ckdefaultcrc64", key: "ok.txt", is_latest: true)

    assert pg_checksum == %{
             "ChecksumCRC64NVME" => checksum,
             "ChecksumType" => "FULL_OBJECT"
           }

    meta =
      [@data_dir, "ckdefaultcrc64", "ok.txt", "meta.json"]
      |> Path.join()
      |> File.read!()
      |> Sidecar.decode!()

    assert [%{"checksum" => sidecar_checksum}] = meta["versions"]
    assert sidecar_checksum == pg_checksum

    attrs =
      SigV4Request.signed_conn(:get, "/ckdefaultcrc64/ok.txt",
        query: %{"attributes" => ""},
        headers: [{"x-amz-object-attributes", "Checksum"}]
      )
      |> call()

    assert attrs.status == 200
    assert attrs.resp_body =~ "<ChecksumCRC64NVME>#{checksum}</ChecksumCRC64NVME>"
    assert attrs.resp_body =~ "<ChecksumType>FULL_OBJECT</ChecksumType>"
  end

  test "PutObject persists modeled checksum to PG, sidecar, and GetObjectAttributes" do
    SigV4Request.signed_conn(:put, "/ckpersist") |> call()
    body = "persistent checksum payload"
    checksum = hash_b64(:sha256, body)

    put =
      SigV4Request.signed_conn(:put, "/ckpersist/ok.txt",
        body: body,
        headers: [
          {"x-amz-sdk-checksum-algorithm", "SHA256"},
          {"x-amz-checksum-sha256", checksum}
        ]
      )
      |> call()

    assert put.status == 200

    assert %Object{checksum: pg_checksum} =
             Repo.get_by(Object, bucket_name: "ckpersist", key: "ok.txt", is_latest: true)

    assert pg_checksum == %{
             "ChecksumSHA256" => checksum,
             "ChecksumType" => "FULL_OBJECT"
           }

    meta =
      [@data_dir, "ckpersist", "ok.txt", "meta.json"]
      |> Path.join()
      |> File.read!()
      |> Sidecar.decode!()

    assert [%{"checksum" => sidecar_checksum}] = meta["versions"]
    assert sidecar_checksum == pg_checksum

    attrs =
      SigV4Request.signed_conn(:get, "/ckpersist/ok.txt",
        query: %{"attributes" => ""},
        headers: [{"x-amz-object-attributes", "Checksum"}]
      )
      |> call()

    assert attrs.status == 200
    assert attrs.resp_body =~ "<ChecksumSHA256>#{checksum}</ChecksumSHA256>"
    assert attrs.resp_body =~ "<ChecksumType>FULL_OBJECT</ChecksumType>"

    prev_auth = Application.get_env(:maxio, :authoritative_source)
    Application.put_env(:maxio, :authoritative_source, read: :sidecar, list: :pg, write: :pg)

    try do
      sidecar_attrs =
        SigV4Request.signed_conn(:get, "/ckpersist/ok.txt",
          query: %{"attributes" => ""},
          headers: [{"x-amz-object-attributes", "Checksum"}]
        )
        |> call()

      assert sidecar_attrs.status == 200
      assert sidecar_attrs.resp_body =~ "<ChecksumSHA256>#{checksum}</ChecksumSHA256>"
      assert sidecar_attrs.resp_body =~ "<ChecksumType>FULL_OBJECT</ChecksumType>"
    after
      if prev_auth,
        do: Application.put_env(:maxio, :authoritative_source, prev_auth),
        else: Application.delete_env(:maxio, :authoritative_source)
    end
  end

  test "CopyObject inherits source modeled checksum to PG, sidecar, result XML, and GetObjectAttributes" do
    SigV4Request.signed_conn(:put, "/ckcopy") |> call()
    body = "copy checksum payload"
    checksum = hash_b64(:sha256, body)

    put =
      SigV4Request.signed_conn(:put, "/ckcopy/src.txt",
        body: body,
        headers: [
          {"x-amz-sdk-checksum-algorithm", "SHA256"},
          {"x-amz-checksum-sha256", checksum}
        ]
      )
      |> call()

    assert put.status == 200

    copy =
      SigV4Request.signed_conn(:put, "/ckcopy/dst.txt",
        headers: [{"x-amz-copy-source", "/ckcopy/src.txt"}]
      )
      |> call()

    assert copy.status == 200
    assert copy.resp_body =~ "<ChecksumSHA256>#{checksum}</ChecksumSHA256>"
    assert copy.resp_body =~ "<ChecksumType>FULL_OBJECT</ChecksumType>"

    assert %Object{checksum: pg_checksum} =
             Repo.get_by(Object, bucket_name: "ckcopy", key: "dst.txt", is_latest: true)

    assert pg_checksum == %{
             "ChecksumSHA256" => checksum,
             "ChecksumType" => "FULL_OBJECT"
           }

    meta =
      [@data_dir, "ckcopy", "dst.txt", "meta.json"]
      |> Path.join()
      |> File.read!()
      |> Sidecar.decode!()

    assert [%{"checksum" => sidecar_checksum}] = meta["versions"]
    assert sidecar_checksum == pg_checksum

    attrs =
      SigV4Request.signed_conn(:get, "/ckcopy/dst.txt",
        query: %{"attributes" => ""},
        headers: [{"x-amz-object-attributes", "Checksum"}]
      )
      |> call()

    assert attrs.status == 200
    assert attrs.resp_body =~ "<ChecksumSHA256>#{checksum}</ChecksumSHA256>"
    assert attrs.resp_body =~ "<ChecksumType>FULL_OBJECT</ChecksumType>"
  end

  test "CopyObject recomputes MPU COMPOSITE source checksum as FULL_OBJECT" do
    SigV4Request.signed_conn(:put, "/ckcopympucomposite") |> call()
    part_bodies = ["copy source composite part one", "copy source composite part two"]
    part_checksums = Enum.map(part_bodies, &hash_b64(:sha256, &1))
    source_composite = composite_hash_b64(:sha256, part_bodies) <> "-2"
    object_body = Enum.join(part_bodies, "")
    target_checksum = hash_b64(:sha256, object_body)

    init =
      SigV4Request.signed_conn(:post, "/ckcopympucomposite/src.bin",
        query: %{"uploads" => ""},
        headers: [{"x-amz-checksum-algorithm", "SHA256"}]
      )
      |> call()

    assert init.status == 200
    upload_id = upload_id(init.resp_body)

    complete_parts =
      part_bodies
      |> Enum.zip(part_checksums)
      |> Enum.with_index(1)
      |> Enum.map(fn {{body, checksum}, part_number} ->
        part =
          SigV4Request.signed_conn(:put, "/ckcopympucomposite/src.bin",
            query: %{"partNumber" => Integer.to_string(part_number), "uploadId" => upload_id},
            body: body,
            headers: [
              {"x-amz-sdk-checksum-algorithm", "SHA256"},
              {"x-amz-checksum-sha256", checksum}
            ]
          )
          |> call()

        assert part.status == 200
        [etag] = get_resp_header(part, "etag")
        %{part_number: part_number, etag: etag, checksums: [{"ChecksumSHA256", checksum}]}
      end)

    complete =
      complete_multipart_upload_parts(
        "ckcopympucomposite",
        "src.bin",
        upload_id,
        complete_parts
      )

    assert complete.status == 200
    assert complete.resp_body =~ "<ChecksumSHA256>#{source_composite}</ChecksumSHA256>"
    assert complete.resp_body =~ "<ChecksumType>COMPOSITE</ChecksumType>"

    copy =
      SigV4Request.signed_conn(:put, "/ckcopympucomposite/dst.bin",
        headers: [{"x-amz-copy-source", "/ckcopympucomposite/src.bin"}]
      )
      |> call()

    assert copy.status == 200
    assert copy.resp_body =~ "<ChecksumSHA256>#{target_checksum}</ChecksumSHA256>"
    assert copy.resp_body =~ "<ChecksumType>FULL_OBJECT</ChecksumType>"
    refute copy.resp_body =~ source_composite

    get = SigV4Request.signed_conn(:get, "/ckcopympucomposite/dst.bin") |> call()
    assert get.status == 200
    assert get.resp_body == object_body

    assert %Object{checksum: pg_checksum} =
             Repo.get_by(Object,
               bucket_name: "ckcopympucomposite",
               key: "dst.bin",
               is_latest: true
             )

    assert pg_checksum == %{
             "ChecksumSHA256" => target_checksum,
             "ChecksumType" => "FULL_OBJECT"
           }

    meta =
      [@data_dir, "ckcopympucomposite", "dst.bin", "meta.json"]
      |> Path.join()
      |> File.read!()
      |> Sidecar.decode!()

    assert [%{"checksum" => sidecar_checksum}] = meta["versions"]
    assert sidecar_checksum == pg_checksum

    attrs =
      SigV4Request.signed_conn(:get, "/ckcopympucomposite/dst.bin",
        query: %{"attributes" => ""},
        headers: [{"x-amz-object-attributes", "Checksum"}]
      )
      |> call()

    assert attrs.status == 200
    assert attrs.resp_body =~ "<ChecksumSHA256>#{target_checksum}</ChecksumSHA256>"
    assert attrs.resp_body =~ "<ChecksumType>FULL_OBJECT</ChecksumType>"
    refute attrs.resp_body =~ source_composite
  end

  test "CopyObject default self-copy refreshes MPU COMPOSITE checksum as FULL_OBJECT" do
    SigV4Request.signed_conn(:put, "/ckcopyselfmpucomposite") |> call()
    part_bodies = ["self copy composite part one", "self copy composite part two"]
    part_checksums = Enum.map(part_bodies, &hash_b64(:sha256, &1))
    source_composite = composite_hash_b64(:sha256, part_bodies) <> "-2"
    object_body = Enum.join(part_bodies, "")
    target_checksum = hash_b64(:sha256, object_body)

    init =
      SigV4Request.signed_conn(:post, "/ckcopyselfmpucomposite/object.bin",
        query: %{"uploads" => ""},
        headers: [{"x-amz-checksum-algorithm", "SHA256"}]
      )
      |> call()

    assert init.status == 200
    upload_id = upload_id(init.resp_body)

    complete_parts =
      part_bodies
      |> Enum.zip(part_checksums)
      |> Enum.with_index(1)
      |> Enum.map(fn {{body, checksum}, part_number} ->
        part =
          SigV4Request.signed_conn(:put, "/ckcopyselfmpucomposite/object.bin",
            query: %{"partNumber" => Integer.to_string(part_number), "uploadId" => upload_id},
            body: body,
            headers: [
              {"x-amz-sdk-checksum-algorithm", "SHA256"},
              {"x-amz-checksum-sha256", checksum}
            ]
          )
          |> call()

        assert part.status == 200
        [etag] = get_resp_header(part, "etag")
        %{part_number: part_number, etag: etag, checksums: [{"ChecksumSHA256", checksum}]}
      end)

    complete =
      complete_multipart_upload_parts(
        "ckcopyselfmpucomposite",
        "object.bin",
        upload_id,
        complete_parts
      )

    assert complete.status == 200
    assert complete.resp_body =~ "<ChecksumSHA256>#{source_composite}</ChecksumSHA256>"
    assert complete.resp_body =~ "<ChecksumType>COMPOSITE</ChecksumType>"

    copy =
      SigV4Request.signed_conn(:put, "/ckcopyselfmpucomposite/object.bin",
        headers: [{"x-amz-copy-source", "/ckcopyselfmpucomposite/object.bin"}]
      )
      |> call()

    assert copy.status == 200
    assert copy.resp_body =~ "<ChecksumSHA256>#{target_checksum}</ChecksumSHA256>"
    assert copy.resp_body =~ "<ChecksumType>FULL_OBJECT</ChecksumType>"
    refute copy.resp_body =~ source_composite

    get = SigV4Request.signed_conn(:get, "/ckcopyselfmpucomposite/object.bin") |> call()
    assert get.status == 200
    assert get.resp_body == object_body

    assert %Object{checksum: pg_checksum} =
             Repo.get_by(Object,
               bucket_name: "ckcopyselfmpucomposite",
               key: "object.bin",
               is_latest: true
             )

    assert pg_checksum == %{
             "ChecksumSHA256" => target_checksum,
             "ChecksumType" => "FULL_OBJECT"
           }
  end

  test "CopyObject x-amz-checksum-algorithm recalculates target checksum instead of inheriting source" do
    SigV4Request.signed_conn(:put, "/ckcopyexplicit") |> call()
    body = "copy explicit checksum payload"
    source_checksum = hash_b64(:sha256, body)
    target_checksum = crc32c_b64(body)

    put =
      SigV4Request.signed_conn(:put, "/ckcopyexplicit/src.txt",
        body: body,
        headers: [
          {"x-amz-sdk-checksum-algorithm", "SHA256"},
          {"x-amz-checksum-sha256", source_checksum}
        ]
      )
      |> call()

    assert put.status == 200

    copy =
      SigV4Request.signed_conn(:put, "/ckcopyexplicit/dst.txt",
        headers: [
          {"x-amz-copy-source", "/ckcopyexplicit/src.txt"},
          {"x-amz-checksum-algorithm", "CRC32C"}
        ]
      )
      |> call()

    assert copy.status == 200
    assert copy.resp_body =~ "<ChecksumCRC32C>#{target_checksum}</ChecksumCRC32C>"
    assert copy.resp_body =~ "<ChecksumType>FULL_OBJECT</ChecksumType>"
    refute copy.resp_body =~ "<ChecksumSHA256>#{source_checksum}</ChecksumSHA256>"

    get = SigV4Request.signed_conn(:get, "/ckcopyexplicit/dst.txt") |> call()
    assert get.status == 200
    assert get.resp_body == body

    assert %Object{checksum: pg_checksum} =
             Repo.get_by(Object, bucket_name: "ckcopyexplicit", key: "dst.txt", is_latest: true)

    assert pg_checksum == %{
             "ChecksumCRC32C" => target_checksum,
             "ChecksumType" => "FULL_OBJECT"
           }

    meta =
      [@data_dir, "ckcopyexplicit", "dst.txt", "meta.json"]
      |> Path.join()
      |> File.read!()
      |> Sidecar.decode!()

    assert [%{"checksum" => sidecar_checksum}] = meta["versions"]
    assert sidecar_checksum == pg_checksum

    attrs =
      SigV4Request.signed_conn(:get, "/ckcopyexplicit/dst.txt",
        query: %{"attributes" => ""},
        headers: [{"x-amz-object-attributes", "Checksum"}]
      )
      |> call()

    assert attrs.status == 200
    assert attrs.resp_body =~ "<ChecksumCRC32C>#{target_checksum}</ChecksumCRC32C>"
    assert attrs.resp_body =~ "<ChecksumType>FULL_OBJECT</ChecksumType>"
  end

  test "CopyObject x-amz-checksum-algorithm can refresh a self-copy checksum" do
    SigV4Request.signed_conn(:put, "/ckcopyselfchecksum") |> call()
    body = "self-copy checksum refresh payload"
    checksum = hash_b64(:sha512, body)

    put =
      SigV4Request.signed_conn(:put, "/ckcopyselfchecksum/object.txt", body: body)
      |> call()

    assert put.status == 200

    copy =
      SigV4Request.signed_conn(:put, "/ckcopyselfchecksum/object.txt",
        headers: [
          {"x-amz-copy-source", "/ckcopyselfchecksum/object.txt"},
          {"x-amz-checksum-algorithm", "SHA512"}
        ]
      )
      |> call()

    assert copy.status == 200
    assert copy.resp_body =~ "<ChecksumSHA512>#{checksum}</ChecksumSHA512>"
    assert copy.resp_body =~ "<ChecksumType>FULL_OBJECT</ChecksumType>"

    get = SigV4Request.signed_conn(:get, "/ckcopyselfchecksum/object.txt") |> call()
    assert get.status == 200
    assert get.resp_body == body

    assert %Object{checksum: pg_checksum} =
             Repo.get_by(Object,
               bucket_name: "ckcopyselfchecksum",
               key: "object.txt",
               is_latest: true
             )

    assert pg_checksum == %{
             "ChecksumSHA512" => checksum,
             "ChecksumType" => "FULL_OBJECT"
           }
  end

  test "CopyObject defaults checksum-less source to CRC64NVME" do
    SigV4Request.signed_conn(:put, "/ckcopydefault") |> call()
    body = "copy source without stored checksum"
    checksum = crc64nvme_b64(body)

    put =
      SigV4Request.signed_conn(:put, "/ckcopydefault/src.txt", body: body)
      |> call()

    assert put.status == 200
    clear_object_checksum!("ckcopydefault", "src.txt")

    copy =
      SigV4Request.signed_conn(:put, "/ckcopydefault/dst.txt",
        headers: [{"x-amz-copy-source", "/ckcopydefault/src.txt"}]
      )
      |> call()

    assert copy.status == 200
    assert copy.resp_body =~ "<ChecksumCRC64NVME>#{checksum}</ChecksumCRC64NVME>"
    assert copy.resp_body =~ "<ChecksumType>FULL_OBJECT</ChecksumType>"

    assert %Object{checksum: pg_checksum} =
             Repo.get_by(Object, bucket_name: "ckcopydefault", key: "dst.txt", is_latest: true)

    assert pg_checksum == %{
             "ChecksumCRC64NVME" => checksum,
             "ChecksumType" => "FULL_OBJECT"
           }

    meta =
      [@data_dir, "ckcopydefault", "dst.txt", "meta.json"]
      |> Path.join()
      |> File.read!()
      |> Sidecar.decode!()

    assert [%{"checksum" => sidecar_checksum} | _] = meta["versions"]
    assert sidecar_checksum == pg_checksum

    attrs =
      SigV4Request.signed_conn(:get, "/ckcopydefault/dst.txt",
        query: %{"attributes" => ""},
        headers: [{"x-amz-object-attributes", "Checksum"}]
      )
      |> call()

    assert attrs.status == 200
    assert attrs.resp_body =~ "<ChecksumCRC64NVME>#{checksum}</ChecksumCRC64NVME>"
    assert attrs.resp_body =~ "<ChecksumType>FULL_OBJECT</ChecksumType>"
  end

  test "CopyObject inherits modeled checksum when source metadata is read from sidecar authority" do
    SigV4Request.signed_conn(:put, "/ckcopysidecar") |> call()
    body = "sidecar copy checksum payload"
    checksum = hash_b64(:sha256, body)

    put =
      SigV4Request.signed_conn(:put, "/ckcopysidecar/src.txt",
        body: body,
        headers: [
          {"x-amz-sdk-checksum-algorithm", "SHA256"},
          {"x-amz-checksum-sha256", checksum}
        ]
      )
      |> call()

    assert put.status == 200
    :ok = Maxio.Objects.delete_metadata("ckcopysidecar", "src.txt")

    prev_auth = Application.get_env(:maxio, :authoritative_source)
    Application.put_env(:maxio, :authoritative_source, read: :sidecar, list: :pg, write: :sidecar)

    try do
      copy =
        SigV4Request.signed_conn(:put, "/ckcopysidecar/dst.txt",
          headers: [{"x-amz-copy-source", "/ckcopysidecar/src.txt"}]
        )
        |> call()

      assert copy.status == 200
      assert copy.resp_body =~ "<ChecksumSHA256>#{checksum}</ChecksumSHA256>"
      assert copy.resp_body =~ "<ChecksumType>FULL_OBJECT</ChecksumType>"

      meta =
        [@data_dir, "ckcopysidecar", "dst.txt", "meta.json"]
        |> Path.join()
        |> File.read!()
        |> Sidecar.decode!()

      assert [%{"checksum" => sidecar_checksum}] = meta["versions"]

      assert sidecar_checksum == %{
               "ChecksumSHA256" => checksum,
               "ChecksumType" => "FULL_OBJECT"
             }
    after
      if prev_auth,
        do: Application.put_env(:maxio, :authoritative_source, prev_auth),
        else: Application.delete_env(:maxio, :authoritative_source)
    end
  end

  test "CopyObject defaults checksum-less source from sidecar authority to CRC64NVME" do
    SigV4Request.signed_conn(:put, "/ckcopydefaultsidecar") |> call()
    body = "sidecar source without stored checksum"
    checksum = crc64nvme_b64(body)

    put =
      SigV4Request.signed_conn(:put, "/ckcopydefaultsidecar/src.txt", body: body)
      |> call()

    assert put.status == 200
    clear_object_checksum!("ckcopydefaultsidecar", "src.txt")
    :ok = Maxio.Objects.delete_metadata("ckcopydefaultsidecar", "src.txt")

    prev_auth = Application.get_env(:maxio, :authoritative_source)
    Application.put_env(:maxio, :authoritative_source, read: :sidecar, list: :pg, write: :sidecar)

    try do
      copy =
        SigV4Request.signed_conn(:put, "/ckcopydefaultsidecar/dst.txt",
          headers: [{"x-amz-copy-source", "/ckcopydefaultsidecar/src.txt"}]
        )
        |> call()

      assert copy.status == 200
      assert copy.resp_body =~ "<ChecksumCRC64NVME>#{checksum}</ChecksumCRC64NVME>"
      assert copy.resp_body =~ "<ChecksumType>FULL_OBJECT</ChecksumType>"

      meta =
        [@data_dir, "ckcopydefaultsidecar", "dst.txt", "meta.json"]
        |> Path.join()
        |> File.read!()
        |> Sidecar.decode!()

      assert [%{"checksum" => sidecar_checksum}] = meta["versions"]

      assert sidecar_checksum == %{
               "ChecksumCRC64NVME" => checksum,
               "ChecksumType" => "FULL_OBJECT"
             }
    after
      if prev_auth,
        do: Application.put_env(:maxio, :authoritative_source, prev_auth),
        else: Application.delete_env(:maxio, :authoritative_source)
    end
  end

  test "CopyObject fail-closes unsupported source checksum metadata before target commit" do
    SigV4Request.signed_conn(:put, "/ckcopybadsourcechecksum") |> call()

    put =
      SigV4Request.signed_conn(:put, "/ckcopybadsourcechecksum/src.txt", body: "source bytes")
      |> call()

    assert put.status == 200

    set_object_checksum!("ckcopybadsourcechecksum", "src.txt", %{
      "ChecksumBLAKE3" => Base.encode64("unsupported"),
      "ChecksumType" => "FULL_OBJECT"
    })

    copy =
      SigV4Request.signed_conn(:put, "/ckcopybadsourcechecksum/dst.txt",
        headers: [{"x-amz-copy-source", "/ckcopybadsourcechecksum/src.txt"}]
      )
      |> call()

    assert copy.status == 501
    assert copy.resp_body =~ "<Code>NotImplemented</Code>"

    get = SigV4Request.signed_conn(:get, "/ckcopybadsourcechecksum/dst.txt") |> call()
    assert get.status == 404
  end

  test "CopyObject checksum validation headers fail closed before target commit" do
    SigV4Request.signed_conn(:put, "/ckcopyalg") |> call()
    SigV4Request.signed_conn(:put, "/ckcopyalg/src.txt", body: "source bytes") |> call()

    rejected =
      [
        {"value", [{"x-amz-checksum-sha256", hash_b64(:sha256, "source bytes")}]},
        {"sdk", [{"x-amz-sdk-checksum-algorithm", "SHA256"}]},
        {"content-md5", [{"content-md5", hash_b64(:md5, "source bytes")}]},
        {"checksum-type", [{"x-amz-checksum-type", "FULL_OBJECT"}]},
        {"xxhash64-value", [{"x-amz-checksum-xxhash64", xxhash64_b64("source bytes")}]},
        {"trailer", [{"x-amz-trailer", "x-amz-checksum-sha256"}]}
      ]

    for {key, extra_headers} <- rejected do
      copy =
        SigV4Request.signed_conn(:put, "/ckcopyalg/#{key}.txt",
          headers: [{"x-amz-copy-source", "/ckcopyalg/src.txt"} | extra_headers]
        )
        |> call()

      assert copy.status == 400
      assert copy.resp_body =~ "<Code>InvalidRequest</Code>"

      assert (SigV4Request.signed_conn(:get, "/ckcopyalg/#{key}.txt") |> call()).status == 404
    end
  end

  test "CopyObject rejects invalid checksum algorithms before target commit" do
    SigV4Request.signed_conn(:put, "/ckcopyunsupported") |> call()
    SigV4Request.signed_conn(:put, "/ckcopyunsupported/src.txt", body: "source bytes") |> call()

    for algorithm <- ["BLAKE3"] do
      key = String.downcase(algorithm)

      copy =
        SigV4Request.signed_conn(:put, "/ckcopyunsupported/#{key}.txt",
          headers: [
            {"x-amz-copy-source", "/ckcopyunsupported/src.txt"},
            {"x-amz-checksum-algorithm", algorithm}
          ]
        )
        |> call()

      assert copy.status == 400
      assert copy.resp_body =~ "<Code>InvalidArgument</Code>"

      get = SigV4Request.signed_conn(:get, "/ckcopyunsupported/#{key}.txt") |> call()
      assert get.status == 404
    end
  end

  test "CopyObject x-amz-checksum-algorithm recalculates XXHASH64" do
    SigV4Request.signed_conn(:put, "/ckcopyxxhash64") |> call()
    body = "copy object xxhash64 payload"
    source_checksum = hash_b64(:sha256, body)
    target_checksum = xxhash64_b64(body)

    put =
      SigV4Request.signed_conn(:put, "/ckcopyxxhash64/src.txt",
        body: body,
        headers: [
          {"x-amz-sdk-checksum-algorithm", "SHA256"},
          {"x-amz-checksum-sha256", source_checksum}
        ]
      )
      |> call()

    assert put.status == 200

    copy =
      SigV4Request.signed_conn(:put, "/ckcopyxxhash64/dst.txt",
        headers: [
          {"x-amz-copy-source", "/ckcopyxxhash64/src.txt"},
          {"x-amz-checksum-algorithm", "XXHASH64"}
        ]
      )
      |> call()

    assert copy.status == 200
    assert copy.resp_body =~ "<ChecksumXXHASH64>#{target_checksum}</ChecksumXXHASH64>"
    assert copy.resp_body =~ "<ChecksumType>FULL_OBJECT</ChecksumType>"
    refute copy.resp_body =~ "<ChecksumSHA256>#{source_checksum}</ChecksumSHA256>"

    assert %Object{checksum: pg_checksum} =
             Repo.get_by(Object, bucket_name: "ckcopyxxhash64", key: "dst.txt", is_latest: true)

    assert pg_checksum == %{
             "ChecksumXXHASH64" => target_checksum,
             "ChecksumType" => "FULL_OBJECT"
           }

    attrs =
      SigV4Request.signed_conn(:get, "/ckcopyxxhash64/dst.txt",
        query: %{"attributes" => ""},
        headers: [{"x-amz-object-attributes", "Checksum"}]
      )
      |> call()

    assert attrs.status == 200
    assert attrs.resp_body =~ "<ChecksumXXHASH64>#{target_checksum}</ChecksumXXHASH64>"
    assert attrs.resp_body =~ "<ChecksumType>FULL_OBJECT</ChecksumType>"
  end

  test "CopyObject x-amz-checksum-algorithm recalculates XXHASH3 and XXHASH128" do
    cases = [
      {"XXHASH3", "ckcopyxxhash3", "copy object xxhash3 payload", "ChecksumXXHASH3",
       "YF+D+Ce6X14="},
      {"XXHASH128", "ckcopyxxhash128", "copy object xxhash128 payload", "ChecksumXXHASH128",
       "yI8pDxLkGFI/XrmnrIIxGg=="}
    ]

    for {algorithm, bucket, body, target_field, target_checksum} <- cases do
      SigV4Request.signed_conn(:put, "/#{bucket}") |> call()

      source_checksum = hash_b64(:sha256, body)

      put =
        SigV4Request.signed_conn(:put, "/#{bucket}/src.txt",
          body: body,
          headers: [
            {"x-amz-sdk-checksum-algorithm", "SHA256"},
            {"x-amz-checksum-sha256", source_checksum}
          ]
        )
        |> call()

      assert put.status == 200

      copy =
        SigV4Request.signed_conn(:put, "/#{bucket}/dst.txt",
          headers: [
            {"x-amz-copy-source", "/#{bucket}/src.txt"},
            {"x-amz-checksum-algorithm", algorithm}
          ]
        )
        |> call()

      assert copy.status == 200
      assert copy.resp_body =~ "<#{target_field}>#{target_checksum}</#{target_field}>"
      assert copy.resp_body =~ "<ChecksumType>FULL_OBJECT</ChecksumType>"
      refute copy.resp_body =~ "<ChecksumSHA256>#{source_checksum}</ChecksumSHA256>"

      assert %Object{checksum: pg_checksum} =
               Repo.get_by(Object, bucket_name: bucket, key: "dst.txt", is_latest: true)

      assert pg_checksum == %{
               target_field => target_checksum,
               "ChecksumType" => "FULL_OBJECT"
             }

      attrs =
        SigV4Request.signed_conn(:get, "/#{bucket}/dst.txt",
          query: %{"attributes" => ""},
          headers: [{"x-amz-object-attributes", "Checksum"}]
        )
        |> call()

      assert attrs.status == 200
      assert attrs.resp_body =~ "<#{target_field}>#{target_checksum}</#{target_field}>"
      assert attrs.resp_body =~ "<ChecksumType>FULL_OBJECT</ChecksumType>"
    end
  end

  test "PutObject bad Content-MD5 returns BadDigest and does not leave an object" do
    SigV4Request.signed_conn(:put, "/ckmd5") |> call()

    bad =
      SigV4Request.signed_conn(:put, "/ckmd5/bad.txt",
        body: "real bytes",
        headers: [{"content-md5", hash_b64(:md5, "different bytes")}]
      )
      |> call()

    assert bad.status == 400
    assert bad.resp_body =~ "<Code>BadDigest</Code>"

    get = SigV4Request.signed_conn(:get, "/ckmd5/bad.txt") |> call()
    assert get.status == 404
  end

  test "PutObject valid-length checksum mismatches return BadDigest" do
    SigV4Request.signed_conn(:put, "/ckmismatch") |> call()

    bad_sha256 =
      SigV4Request.signed_conn(:put, "/ckmismatch/bad-sha256.txt",
        body: "real bytes",
        headers: [{"x-amz-checksum-sha256", hash_b64(:sha256, "different bytes")}]
      )
      |> call()

    assert bad_sha256.status == 400
    assert bad_sha256.resp_body =~ "<Code>BadDigest</Code>"

    bad_crc32 =
      SigV4Request.signed_conn(:put, "/ckmismatch/bad-crc32.txt",
        body: "real bytes",
        headers: [{"x-amz-checksum-crc32", crc32_b64("different bytes")}]
      )
      |> call()

    assert bad_crc32.status == 400
    assert bad_crc32.resp_body =~ "<Code>BadDigest</Code>"

    sha_get = SigV4Request.signed_conn(:get, "/ckmismatch/bad-sha256.txt") |> call()
    crc_get = SigV4Request.signed_conn(:get, "/ckmismatch/bad-crc32.txt") |> call()

    assert sha_get.status == 404
    assert crc_get.status == 404
  end

  test "PutObject validates x-amz-checksum-md5 without echoing Content-MD5" do
    SigV4Request.signed_conn(:put, "/ckmd5ok") |> call()
    body = "md5 payload"
    content_md5 = hash_b64(:md5, body)
    checksum_md5 = hash_b64(:md5, body)

    put =
      SigV4Request.signed_conn(:put, "/ckmd5ok/ok.txt",
        body: body,
        headers: [
          {"content-md5", content_md5},
          {"x-amz-sdk-checksum-algorithm", "MD5"},
          {"x-amz-checksum-md5", checksum_md5}
        ]
      )
      |> call()

    assert put.status == 200
    assert get_resp_header(put, "content-md5") == []
    assert get_resp_header(put, "x-amz-checksum-md5") == [checksum_md5]
    assert get_resp_header(put, "x-amz-checksum-crc64nvme") == []
  end

  test "PutObject with only Content-MD5 still defaults to CRC64NVME" do
    SigV4Request.signed_conn(:put, "/ckcontentmd5default") |> call()
    body = "content md5 default payload"
    content_md5 = hash_b64(:md5, body)
    checksum = crc64nvme_b64(body)

    put =
      SigV4Request.signed_conn(:put, "/ckcontentmd5default/ok.txt",
        body: body,
        headers: [{"content-md5", content_md5}]
      )
      |> call()

    assert put.status == 200
    assert get_resp_header(put, "content-md5") == []
    assert get_resp_header(put, "x-amz-checksum-crc64nvme") == [checksum]
    assert get_resp_header(put, "x-amz-checksum-type") == ["FULL_OBJECT"]
  end

  test "PutObject validates x-amz-checksum-crc32" do
    SigV4Request.signed_conn(:put, "/ckcrc") |> call()
    body = "crc payload"
    checksum = crc32_b64(body)

    put =
      SigV4Request.signed_conn(:put, "/ckcrc/ok.txt",
        body: body,
        headers: [{"x-amz-checksum-crc32", checksum}]
      )
      |> call()

    assert put.status == 200
    assert get_resp_header(put, "x-amz-checksum-crc32") == [checksum]
  end

  test "PutObject validates x-amz-checksum-crc32c" do
    SigV4Request.signed_conn(:put, "/ckcrc32c") |> call()
    body = "crc32c payload"
    checksum = crc32c_b64(body)

    put =
      SigV4Request.signed_conn(:put, "/ckcrc32c/ok.txt",
        body: body,
        headers: [
          {"x-amz-sdk-checksum-algorithm", "CRC32C"},
          {"x-amz-checksum-crc32c", checksum}
        ]
      )
      |> call()

    assert put.status == 200
    assert get_resp_header(put, "x-amz-checksum-crc32c") == [checksum]

    attrs =
      SigV4Request.signed_conn(:get, "/ckcrc32c/ok.txt",
        query: %{"attributes" => ""},
        headers: [{"x-amz-object-attributes", "Checksum"}]
      )
      |> call()

    assert attrs.status == 200
    assert attrs.resp_body =~ "<ChecksumCRC32C>#{checksum}</ChecksumCRC32C>"
    assert attrs.resp_body =~ "<ChecksumType>FULL_OBJECT</ChecksumType>"
  end

  test "PutObject validates x-amz-checksum-crc64nvme" do
    SigV4Request.signed_conn(:put, "/ckcrc64nvme") |> call()
    body = "crc64nvme payload"
    checksum = crc64nvme_b64(body)

    put =
      SigV4Request.signed_conn(:put, "/ckcrc64nvme/ok.txt",
        body: body,
        headers: [
          {"x-amz-sdk-checksum-algorithm", "CRC64NVME"},
          {"x-amz-checksum-crc64nvme", checksum}
        ]
      )
      |> call()

    assert put.status == 200
    assert get_resp_header(put, "x-amz-checksum-crc64nvme") == [checksum]

    attrs =
      SigV4Request.signed_conn(:get, "/ckcrc64nvme/ok.txt",
        query: %{"attributes" => ""},
        headers: [{"x-amz-object-attributes", "Checksum"}]
      )
      |> call()

    assert attrs.status == 200
    assert attrs.resp_body =~ "<ChecksumCRC64NVME>#{checksum}</ChecksumCRC64NVME>"
    assert attrs.resp_body =~ "<ChecksumType>FULL_OBJECT</ChecksumType>"
  end

  test "PutObject validates x-amz-checksum-xxhash64" do
    SigV4Request.signed_conn(:put, "/ckxxhash64") |> call()
    body = "xxhash64 payload"
    checksum = xxhash64_b64(body)

    put =
      SigV4Request.signed_conn(:put, "/ckxxhash64/ok.txt",
        body: body,
        headers: [
          {"x-amz-sdk-checksum-algorithm", "XXHASH64"},
          {"x-amz-checksum-xxhash64", checksum}
        ]
      )
      |> call()

    assert put.status == 200
    assert get_resp_header(put, "x-amz-checksum-xxhash64") == [checksum]

    assert %Object{checksum: pg_checksum} =
             Repo.get_by(Object, bucket_name: "ckxxhash64", key: "ok.txt", is_latest: true)

    assert pg_checksum == %{
             "ChecksumXXHASH64" => checksum,
             "ChecksumType" => "FULL_OBJECT"
           }

    attrs =
      SigV4Request.signed_conn(:get, "/ckxxhash64/ok.txt",
        query: %{"attributes" => ""},
        headers: [{"x-amz-object-attributes", "Checksum"}]
      )
      |> call()

    assert attrs.status == 200
    assert attrs.resp_body =~ "<ChecksumXXHASH64>#{checksum}</ChecksumXXHASH64>"
    assert attrs.resp_body =~ "<ChecksumType>FULL_OBJECT</ChecksumType>"
  end

  test "PutObject validates x-amz-checksum-xxhash3 and x-amz-checksum-xxhash128" do
    cases = [
      {"XXHASH3", "ckxxhash3", "xxhash3 payload", "x-amz-checksum-xxhash3", "ChecksumXXHASH3",
       "YstyBQcAuQ4="},
      {"XXHASH128", "ckxxhash128", "xxhash128 payload", "x-amz-checksum-xxhash128",
       "ChecksumXXHASH128", "ELbunnHcXG1eA8dqL//V5A=="}
    ]

    for {algorithm, bucket, body, header, field, checksum} <- cases do
      SigV4Request.signed_conn(:put, "/#{bucket}") |> call()

      put =
        SigV4Request.signed_conn(:put, "/#{bucket}/ok.txt",
          body: body,
          headers: [
            {"x-amz-sdk-checksum-algorithm", algorithm},
            {header, checksum}
          ]
        )
        |> call()

      assert put.status == 200
      assert get_resp_header(put, header) == [checksum]
      assert get_resp_header(put, "x-amz-checksum-type") == ["FULL_OBJECT"]

      assert %Object{checksum: pg_checksum} =
               Repo.get_by(Object, bucket_name: bucket, key: "ok.txt", is_latest: true)

      assert pg_checksum == %{
               field => checksum,
               "ChecksumType" => "FULL_OBJECT"
             }

      attrs =
        SigV4Request.signed_conn(:get, "/#{bucket}/ok.txt",
          query: %{"attributes" => ""},
          headers: [{"x-amz-object-attributes", "Checksum"}]
        )
        |> call()

      assert attrs.status == 200
      assert attrs.resp_body =~ "<#{field}>#{checksum}</#{field}>"
      assert attrs.resp_body =~ "<ChecksumType>FULL_OBJECT</ChecksumType>"
    end
  end

  test "PutObject validates x-amz-checksum-sha512" do
    SigV4Request.signed_conn(:put, "/cksha512") |> call()
    body = "sha512 payload"
    checksum = hash_b64(:sha512, body)

    put =
      SigV4Request.signed_conn(:put, "/cksha512/ok.txt",
        body: body,
        headers: [
          {"x-amz-sdk-checksum-algorithm", "SHA512"},
          {"x-amz-checksum-sha512", checksum}
        ]
      )
      |> call()

    assert put.status == 200
    assert get_resp_header(put, "x-amz-checksum-sha512") == [checksum]

    attrs =
      SigV4Request.signed_conn(:get, "/cksha512/ok.txt",
        query: %{"attributes" => ""},
        headers: [{"x-amz-object-attributes", "Checksum"}]
      )
      |> call()

    assert attrs.status == 200
    assert attrs.resp_body =~ "<ChecksumSHA512>#{checksum}</ChecksumSHA512>"
    assert attrs.resp_body =~ "<ChecksumType>FULL_OBJECT</ChecksumType>"
  end

  test "PutObject validates aws-chunked checksum trailer and echoes it" do
    SigV4Request.signed_conn(:put, "/cktrail") |> call()
    body = "trailer payload"
    checksum = hash_b64(:sha256, body)

    put =
      SigV4Request.signed_chunked_conn(:put, "/cktrail/ok.txt", body,
        trailer_headers: [{"x-amz-checksum-sha256", checksum}]
      )
      |> call()

    assert put.status == 200
    assert get_resp_header(put, "x-amz-checksum-sha256") == [checksum]

    get = SigV4Request.signed_conn(:get, "/cktrail/ok.txt") |> call()
    assert get.status == 200
    assert get.resp_body == body
  end

  test "PutObject validates signed aws-chunked checksum trailer" do
    SigV4Request.signed_conn(:put, "/cktrailsigned") |> call()
    body = "signed trailer payload"
    checksum = hash_b64(:sha256, body)

    put =
      SigV4Request.signed_chunked_conn(:put, "/cktrailsigned/ok.txt", body,
        streaming_payload_hash: "STREAMING-AWS4-HMAC-SHA256-PAYLOAD-TRAILER",
        trailer_headers: [{"x-amz-checksum-sha256", checksum}]
      )
      |> call()

    assert put.status == 200
    assert get_resp_header(put, "x-amz-checksum-sha256") == [checksum]
  end

  test "PutObject validates aws-chunked CRC32C checksum trailer" do
    SigV4Request.signed_conn(:put, "/cktrailcrc32c") |> call()
    body = "crc32c trailer payload"
    checksum = crc32c_b64(body)

    put =
      SigV4Request.signed_chunked_conn(:put, "/cktrailcrc32c/ok.txt", body,
        trailer_headers: [{"x-amz-checksum-crc32c", checksum}]
      )
      |> call()

    assert put.status == 200
    assert get_resp_header(put, "x-amz-checksum-crc32c") == [checksum]
  end

  test "PutObject validates aws-chunked SHA512 checksum trailer" do
    SigV4Request.signed_conn(:put, "/cktrailsha512") |> call()
    body = "sha512 trailer payload"
    checksum = hash_b64(:sha512, body)

    put =
      SigV4Request.signed_chunked_conn(:put, "/cktrailsha512/ok.txt", body,
        trailer_headers: [{"x-amz-checksum-sha512", checksum}]
      )
      |> call()

    assert put.status == 200
    assert get_resp_header(put, "x-amz-checksum-sha512") == [checksum]
  end

  test "PutObject validates aws-chunked CRC64NVME checksum trailer" do
    SigV4Request.signed_conn(:put, "/cktrailcrc64nvme") |> call()
    body = "crc64nvme trailer payload"
    checksum = crc64nvme_b64(body)

    put =
      SigV4Request.signed_chunked_conn(:put, "/cktrailcrc64nvme/ok.txt", body,
        trailer_headers: [{"x-amz-checksum-crc64nvme", checksum}]
      )
      |> call()

    assert put.status == 200
    assert get_resp_header(put, "x-amz-checksum-crc64nvme") == [checksum]
  end

  test "PutObject validates aws-chunked XXHASH64 checksum trailer" do
    SigV4Request.signed_conn(:put, "/cktrailxxhash64") |> call()
    body = "xxhash64 trailer payload"
    checksum = xxhash64_b64(body)

    put =
      SigV4Request.signed_chunked_conn(:put, "/cktrailxxhash64/ok.txt", body,
        trailer_headers: [{"x-amz-checksum-xxhash64", checksum}]
      )
      |> call()

    assert put.status == 200
    assert get_resp_header(put, "x-amz-checksum-xxhash64") == [checksum]
  end

  test "PutObject validates aws-chunked XXHASH3 and XXHASH128 checksum trailers" do
    cases = [
      {"cktrailxxhash3", "xxhash3 trailer payload", "x-amz-checksum-xxhash3", "crPZS12saZg="},
      {"cktrailxxhash128", "xxhash128 trailer payload", "x-amz-checksum-xxhash128",
       "zAGimiX9ne4h0oVNCMWceQ=="}
    ]

    for {bucket, body, header, checksum} <- cases do
      SigV4Request.signed_conn(:put, "/#{bucket}") |> call()

      put =
        SigV4Request.signed_chunked_conn(:put, "/#{bucket}/ok.txt", body,
          trailer_headers: [{header, checksum}]
        )
        |> call()

      assert put.status == 200
      assert get_resp_header(put, header) == [checksum]
    end
  end

  test "PutObject bad checksum trailer returns BadDigest and does not leave an object" do
    SigV4Request.signed_conn(:put, "/cktrailbad") |> call()

    bad =
      SigV4Request.signed_chunked_conn(:put, "/cktrailbad/bad.txt", "real bytes",
        trailer_headers: [{"x-amz-checksum-crc32", crc32_b64("different bytes")}]
      )
      |> call()

    assert bad.status == 400
    assert bad.resp_body =~ "<Code>BadDigest</Code>"

    get = SigV4Request.signed_conn(:get, "/cktrailbad/bad.txt") |> call()
    assert get.status == 404
  end

  test "unknown checksum algorithms fail closed" do
    SigV4Request.signed_conn(:put, "/ckunsupported") |> call()

    put =
      SigV4Request.signed_conn(:put, "/ckunsupported/object.txt",
        body: "bytes",
        headers: [{"x-amz-checksum-blake3", "AAAAAA=="}]
      )
      |> call()

    assert put.status == 501
    assert put.resp_body =~ "<Code>NotImplemented</Code>"

    sdk =
      SigV4Request.signed_conn(:put, "/ckunsupported/sdk.txt",
        body: "bytes",
        headers: [{"x-amz-sdk-checksum-algorithm", "BLAKE3"}]
      )
      |> call()

    assert sdk.status == 400
    assert sdk.resp_body =~ "<Code>InvalidArgument</Code>"
  end

  test "x-amz-sdk-checksum-algorithm fails closed without a matching checksum value" do
    SigV4Request.signed_conn(:put, "/cksdk") |> call()

    missing =
      SigV4Request.signed_conn(:put, "/cksdk/missing.txt",
        body: "bytes",
        headers: [{"x-amz-sdk-checksum-algorithm", "SHA256"}]
      )
      |> call()

    assert missing.status == 400
    assert missing.resp_body =~ "<Code>InvalidRequest</Code>"

    mismatch =
      SigV4Request.signed_conn(:put, "/cksdk/mismatch.txt",
        body: "bytes",
        headers: [
          {"x-amz-sdk-checksum-algorithm", "SHA256"},
          {"x-amz-checksum-crc32", crc32_b64("bytes")}
        ]
      )
      |> call()

    assert mismatch.status == 400
    assert mismatch.resp_body =~ "<Code>BadDigest</Code>"
  end

  test "UploadPart validates x-amz-checksum-sha256 and echoes the checksum header" do
    SigV4Request.signed_conn(:put, "/ckmp") |> call()
    body = "part bytes"
    checksum = hash_b64(:sha256, body)

    init =
      SigV4Request.signed_conn(:post, "/ckmp/object.bin",
        query: %{"uploads" => ""},
        headers: [{"x-amz-checksum-algorithm", "SHA256"}]
      )
      |> call()

    assert init.status == 200
    upload_id = upload_id(init.resp_body)

    part =
      SigV4Request.signed_conn(:put, "/ckmp/object.bin",
        query: %{"partNumber" => "1", "uploadId" => upload_id},
        body: body,
        headers: [
          {"x-amz-sdk-checksum-algorithm", "SHA256"},
          {"x-amz-checksum-sha256", checksum}
        ]
      )
      |> call()

    assert part.status == 200
    assert get_resp_header(part, "x-amz-checksum-sha256") == [checksum]
    [etag] = get_resp_header(part, "etag")

    complete = complete_multipart_upload("ckmp", "object.bin", upload_id, [etag])
    assert complete.status == 200

    get = SigV4Request.signed_conn(:get, "/ckmp/object.bin") |> call()
    assert get.status == 200
    assert get.resp_body == body
  end

  test "checksum-less multipart upload defaults to CRC64NVME FULL_OBJECT" do
    SigV4Request.signed_conn(:put, "/ckmpdefaultcrc64") |> call()
    first_body = "default crc64 direct part"
    copied_body = "default crc64 copied part"
    object_body = first_body <> copied_body
    first_checksum = crc64nvme_b64(first_body)
    copied_checksum = crc64nvme_b64(copied_body)
    object_checksum = crc64nvme_b64(object_body)

    SigV4Request.signed_conn(:put, "/ckmpdefaultcrc64/src.txt", body: copied_body) |> call()

    init =
      SigV4Request.signed_conn(:post, "/ckmpdefaultcrc64/object.bin", query: %{"uploads" => ""})
      |> call()

    assert init.status == 200
    assert get_resp_header(init, "x-amz-checksum-algorithm") == ["CRC64NVME"]
    assert get_resp_header(init, "x-amz-checksum-type") == ["FULL_OBJECT"]
    upload_id = upload_id(init.resp_body)

    uploaded =
      SigV4Request.signed_conn(:put, "/ckmpdefaultcrc64/object.bin",
        query: %{"partNumber" => "1", "uploadId" => upload_id},
        body: first_body
      )
      |> call()

    assert uploaded.status == 200
    assert get_resp_header(uploaded, "x-amz-checksum-crc64nvme") == [first_checksum]
    [etag1] = get_resp_header(uploaded, "etag")

    copied =
      SigV4Request.signed_conn(:put, "/ckmpdefaultcrc64/object.bin",
        query: %{"partNumber" => "2", "uploadId" => upload_id},
        headers: [{"x-amz-copy-source", "/ckmpdefaultcrc64/src.txt"}]
      )
      |> call()

    assert copied.status == 200
    assert copied.resp_body =~ "<ChecksumCRC64NVME>#{copied_checksum}</ChecksumCRC64NVME>"
    etag2 = copy_part_etag(copied.resp_body)

    parts =
      SigV4Request.signed_conn(:get, "/ckmpdefaultcrc64/object.bin",
        query: %{"uploadId" => upload_id}
      )
      |> call()

    assert parts.status == 200
    assert parts.resp_body =~ "<ChecksumCRC64NVME>#{first_checksum}</ChecksumCRC64NVME>"
    assert parts.resp_body =~ "<ChecksumCRC64NVME>#{copied_checksum}</ChecksumCRC64NVME>"

    complete =
      complete_multipart_upload("ckmpdefaultcrc64", "object.bin", upload_id, [etag1, etag2])

    assert complete.status == 200
    assert complete.resp_body =~ "<ChecksumCRC64NVME>#{object_checksum}</ChecksumCRC64NVME>"
    assert complete.resp_body =~ "<ChecksumType>FULL_OBJECT</ChecksumType>"

    assert_persisted_checksum("ckmpdefaultcrc64", "object.bin", %{
      "ChecksumCRC64NVME" => object_checksum,
      "ChecksumType" => "FULL_OBJECT"
    })

    attrs =
      SigV4Request.signed_conn(:get, "/ckmpdefaultcrc64/object.bin",
        query: %{"attributes" => ""},
        headers: [{"x-amz-object-attributes", "Checksum,ObjectParts"}]
      )
      |> call()

    assert attrs.status == 200
    assert attrs.resp_body =~ "<ChecksumCRC64NVME>#{object_checksum}</ChecksumCRC64NVME>"
    assert attrs.resp_body =~ "<ChecksumType>FULL_OBJECT</ChecksumType>"
    assert attrs.resp_body =~ "<PartsCount>2</PartsCount>"
    assert attrs.resp_body =~ "<ChecksumCRC64NVME>#{first_checksum}</ChecksumCRC64NVME>"
    assert attrs.resp_body =~ "<ChecksumCRC64NVME>#{copied_checksum}</ChecksumCRC64NVME>"

    get = SigV4Request.signed_conn(:get, "/ckmpdefaultcrc64/object.bin") |> call()
    assert get.status == 200
    assert get.resp_body == object_body
  end

  test "CRC64NVME FULL_OBJECT multipart intent completes with object checksum" do
    SigV4Request.signed_conn(:put, "/ckmpfullcrc64") |> call()
    first_body = String.duplicate("a", 5_242_880)
    second_body = "crc64 full-object tail"
    object_body = first_body <> second_body
    object_checksum = crc64nvme_b64(object_body)

    init =
      SigV4Request.signed_conn(:post, "/ckmpfullcrc64/object.bin",
        query: %{"uploads" => ""},
        headers: [{"x-amz-checksum-algorithm", "CRC64NVME"}]
      )
      |> call()

    assert init.status == 200
    assert get_resp_header(init, "x-amz-checksum-algorithm") == ["CRC64NVME"]
    assert get_resp_header(init, "x-amz-checksum-type") == ["FULL_OBJECT"]
    upload_id = upload_id(init.resp_body)

    etags =
      [
        {1, first_body},
        {2, second_body}
      ]
      |> Enum.map(fn {part_number, body} ->
        part =
          SigV4Request.signed_conn(:put, "/ckmpfullcrc64/object.bin",
            query: %{"partNumber" => Integer.to_string(part_number), "uploadId" => upload_id},
            body: body
          )
          |> call()

        assert part.status == 200
        assert get_resp_header(part, "x-amz-checksum-crc64nvme") == [crc64nvme_b64(body)]
        [etag] = get_resp_header(part, "etag")
        etag
      end)

    complete =
      complete_multipart_upload("ckmpfullcrc64", "object.bin", upload_id, etags, [
        {"x-amz-checksum-crc64nvme", object_checksum},
        {"x-amz-checksum-type", "FULL_OBJECT"},
        {"x-amz-mp-object-size", Integer.to_string(byte_size(object_body))}
      ])

    assert complete.status == 200
    assert complete.resp_body =~ "<ChecksumCRC64NVME>#{object_checksum}</ChecksumCRC64NVME>"
    assert complete.resp_body =~ "<ChecksumType>FULL_OBJECT</ChecksumType>"

    assert_persisted_checksum("ckmpfullcrc64", "object.bin", %{
      "ChecksumCRC64NVME" => object_checksum,
      "ChecksumType" => "FULL_OBJECT"
    })

    attrs =
      SigV4Request.signed_conn(:get, "/ckmpfullcrc64/object.bin",
        query: %{"attributes" => ""},
        headers: [{"x-amz-object-attributes", "Checksum,ObjectParts"}]
      )
      |> call()

    assert attrs.status == 200
    assert attrs.resp_body =~ "<ChecksumCRC64NVME>#{object_checksum}</ChecksumCRC64NVME>"
    assert attrs.resp_body =~ "<ChecksumType>FULL_OBJECT</ChecksumType>"
    assert attrs.resp_body =~ "<PartsCount>2</PartsCount>"

    get = SigV4Request.signed_conn(:get, "/ckmpfullcrc64/object.bin") |> call()
    assert get.status == 200
    assert get.resp_body == object_body
  end

  test "CompleteMultipartUpload validates aws-chunked checksum trailer as object checksum" do
    SigV4Request.signed_conn(:put, "/ckmpcompletetrail") |> call()
    first_body = "complete trailer first part"
    second_body = "complete trailer tail"
    object_body = first_body <> second_body
    object_checksum = crc64nvme_b64(object_body)

    init =
      SigV4Request.signed_conn(:post, "/ckmpcompletetrail/object.bin",
        query: %{"uploads" => ""},
        headers: [{"x-amz-checksum-algorithm", "CRC64NVME"}]
      )
      |> call()

    assert init.status == 200
    upload_id = upload_id(init.resp_body)

    etags =
      [
        {1, first_body},
        {2, second_body}
      ]
      |> Enum.map(fn {part_number, body} ->
        part =
          SigV4Request.signed_conn(:put, "/ckmpcompletetrail/object.bin",
            query: %{"partNumber" => Integer.to_string(part_number), "uploadId" => upload_id},
            body: body
          )
          |> call()

        assert part.status == 200
        [etag] = get_resp_header(part, "etag")
        etag
      end)

    complete =
      complete_multipart_upload_chunked(
        "ckmpcompletetrail",
        "object.bin",
        upload_id,
        etags,
        [{"x-amz-checksum-crc64nvme", object_checksum}],
        [
          {"x-amz-checksum-type", "FULL_OBJECT"},
          {"x-amz-mp-object-size", Integer.to_string(byte_size(object_body))}
        ]
      )

    assert complete.status == 200
    assert complete.resp_body =~ "<ChecksumCRC64NVME>#{object_checksum}</ChecksumCRC64NVME>"
    assert complete.resp_body =~ "<ChecksumType>FULL_OBJECT</ChecksumType>"

    get = SigV4Request.signed_conn(:get, "/ckmpcompletetrail/object.bin") |> call()
    assert get.status == 200
    assert get.resp_body == object_body
  end

  test "CompleteMultipartUpload bad checksum trailer returns BadDigest and keeps upload retryable" do
    SigV4Request.signed_conn(:put, "/ckmpcompletetrailbad") |> call()
    body = "complete trailer bad digest"
    object_checksum = crc64nvme_b64(body)

    init =
      SigV4Request.signed_conn(:post, "/ckmpcompletetrailbad/object.bin",
        query: %{"uploads" => ""},
        headers: [{"x-amz-checksum-algorithm", "CRC64NVME"}]
      )
      |> call()

    assert init.status == 200
    upload_id = upload_id(init.resp_body)

    part =
      SigV4Request.signed_conn(:put, "/ckmpcompletetrailbad/object.bin",
        query: %{"partNumber" => "1", "uploadId" => upload_id},
        body: body
      )
      |> call()

    assert part.status == 200
    [etag] = get_resp_header(part, "etag")

    rejected =
      complete_multipart_upload_chunked(
        "ckmpcompletetrailbad",
        "object.bin",
        upload_id,
        [etag],
        [{"x-amz-checksum-crc64nvme", crc64nvme_b64("different bytes")}],
        [{"x-amz-checksum-type", "FULL_OBJECT"}]
      )

    assert rejected.status == 400
    assert rejected.resp_body =~ "<Code>BadDigest</Code>"

    get_missing = SigV4Request.signed_conn(:get, "/ckmpcompletetrailbad/object.bin") |> call()
    assert get_missing.status == 404

    retry =
      complete_multipart_upload("ckmpcompletetrailbad", "object.bin", upload_id, [etag], [
        {"x-amz-checksum-crc64nvme", object_checksum},
        {"x-amz-checksum-type", "FULL_OBJECT"}
      ])

    assert retry.status == 200
  end

  test "CompleteMultipartUpload unknown checksum trailer fails closed before object commit" do
    SigV4Request.signed_conn(:put, "/ckmpcompletetrailxx") |> call()

    init =
      SigV4Request.signed_conn(:post, "/ckmpcompletetrailxx/object.bin",
        query: %{"uploads" => ""}
      )
      |> call()

    assert init.status == 200
    upload_id = upload_id(init.resp_body)

    part =
      SigV4Request.signed_conn(:put, "/ckmpcompletetrailxx/object.bin",
        query: %{"partNumber" => "1", "uploadId" => upload_id},
        body: "part"
      )
      |> call()

    assert part.status == 200
    [etag] = get_resp_header(part, "etag")

    rejected =
      complete_multipart_upload_chunked(
        "ckmpcompletetrailxx",
        "object.bin",
        upload_id,
        [etag],
        [{"x-amz-checksum-blake3", Base.encode64("unsupported")}]
      )

    assert rejected.status == 501
    assert rejected.resp_body =~ "<Code>NotImplemented</Code>"

    get = SigV4Request.signed_conn(:get, "/ckmpcompletetrailxx/object.bin") |> call()
    assert get.status == 404
  end

  test "CompleteMultipartUpload checksum trailer declaration requires streaming trailer payload" do
    SigV4Request.signed_conn(:put, "/ckmpcompletetrailplain") |> call()

    init =
      SigV4Request.signed_conn(:post, "/ckmpcompletetrailplain/object.bin",
        query: %{"uploads" => ""}
      )
      |> call()

    assert init.status == 200
    upload_id = upload_id(init.resp_body)

    part =
      SigV4Request.signed_conn(:put, "/ckmpcompletetrailplain/object.bin",
        query: %{"partNumber" => "1", "uploadId" => upload_id},
        body: "part"
      )
      |> call()

    assert part.status == 200
    [etag] = get_resp_header(part, "etag")

    rejected =
      complete_multipart_upload("ckmpcompletetrailplain", "object.bin", upload_id, [etag], [
        {"x-amz-trailer", "x-amz-checksum-crc64nvme"}
      ])

    assert rejected.status == 400
    assert rejected.resp_body =~ "<Code>InvalidRequest</Code>"

    get = SigV4Request.signed_conn(:get, "/ckmpcompletetrailplain/object.bin") |> call()
    assert get.status == 404
  end

  test "CRC32 and CRC32C FULL_OBJECT multipart intents complete with object checksum" do
    cases = [
      {"CRC32", "ckmpfullcrc32", "x-amz-checksum-crc32", &crc32_b64/1, "ChecksumCRC32"},
      {"CRC32C", "ckmpfullcrc32c", "x-amz-checksum-crc32c", &crc32c_b64/1, "ChecksumCRC32C"}
    ]

    for {algorithm, bucket, response_header, checksum_fun, checksum_field} <- cases do
      SigV4Request.signed_conn(:put, "/#{bucket}") |> call()
      first_body = "#{algorithm} full-object first part"
      second_body = "#{algorithm} full-object tail"
      object_body = first_body <> second_body
      object_checksum = checksum_fun.(object_body)

      init =
        SigV4Request.signed_conn(:post, "/#{bucket}/object.bin",
          query: %{"uploads" => ""},
          headers: [
            {"x-amz-checksum-algorithm", algorithm},
            {"x-amz-checksum-type", "FULL_OBJECT"}
          ]
        )
        |> call()

      assert init.status == 200
      assert get_resp_header(init, "x-amz-checksum-algorithm") == [algorithm]
      assert get_resp_header(init, "x-amz-checksum-type") == ["FULL_OBJECT"]
      upload_id = upload_id(init.resp_body)

      etags =
        [
          {1, first_body},
          {2, second_body}
        ]
        |> Enum.map(fn {part_number, body} ->
          part =
            SigV4Request.signed_conn(:put, "/#{bucket}/object.bin",
              query: %{"partNumber" => Integer.to_string(part_number), "uploadId" => upload_id},
              body: body
            )
            |> call()

          assert part.status == 200
          assert get_resp_header(part, response_header) == [checksum_fun.(body)]
          [etag] = get_resp_header(part, "etag")
          etag
        end)

      complete =
        complete_multipart_upload(bucket, "object.bin", upload_id, etags, [
          {response_header, object_checksum},
          {"x-amz-checksum-type", "FULL_OBJECT"},
          {"x-amz-mp-object-size", Integer.to_string(byte_size(object_body))}
        ])

      assert complete.status == 200
      assert complete.resp_body =~ "<#{checksum_field}>#{object_checksum}</#{checksum_field}>"
      assert complete.resp_body =~ "<ChecksumType>FULL_OBJECT</ChecksumType>"

      assert_persisted_checksum(bucket, "object.bin", %{
        checksum_field => object_checksum,
        "ChecksumType" => "FULL_OBJECT"
      })

      attrs =
        SigV4Request.signed_conn(:get, "/#{bucket}/object.bin",
          query: %{"attributes" => ""},
          headers: [{"x-amz-object-attributes", "Checksum,ObjectParts"}]
        )
        |> call()

      assert attrs.status == 200
      assert attrs.resp_body =~ "<#{checksum_field}>#{object_checksum}</#{checksum_field}>"
      assert attrs.resp_body =~ "<ChecksumType>FULL_OBJECT</ChecksumType>"
      assert attrs.resp_body =~ "<PartsCount>2</PartsCount>"
    end
  end

  test "CRC64NVME FULL_OBJECT complete rejects bad object checksum before commit" do
    SigV4Request.signed_conn(:put, "/ckmpfullcrc64bad") |> call()
    body = "real full object bytes"

    init =
      SigV4Request.signed_conn(:post, "/ckmpfullcrc64bad/object.bin",
        query: %{"uploads" => ""},
        headers: [{"x-amz-checksum-algorithm", "CRC64NVME"}]
      )
      |> call()

    assert init.status == 200
    upload_id = upload_id(init.resp_body)

    part =
      SigV4Request.signed_conn(:put, "/ckmpfullcrc64bad/object.bin",
        query: %{"partNumber" => "1", "uploadId" => upload_id},
        body: body
      )
      |> call()

    assert part.status == 200
    [etag] = get_resp_header(part, "etag")

    wrong_size =
      complete_multipart_upload("ckmpfullcrc64bad", "object.bin", upload_id, [etag], [
        {"x-amz-checksum-crc64nvme", crc64nvme_b64(body)},
        {"x-amz-checksum-type", "FULL_OBJECT"},
        {"x-amz-mp-object-size", Integer.to_string(byte_size(body) + 1)}
      ])

    assert wrong_size.status == 400
    assert wrong_size.resp_body =~ "<Code>InvalidRequest</Code>"

    bad =
      complete_multipart_upload("ckmpfullcrc64bad", "object.bin", upload_id, [etag], [
        {"x-amz-checksum-crc64nvme", crc64nvme_b64("different bytes")},
        {"x-amz-checksum-type", "FULL_OBJECT"},
        {"x-amz-mp-object-size", Integer.to_string(byte_size(body))}
      ])

    assert bad.status == 400
    assert bad.resp_body =~ "<Code>BadDigest</Code>"

    get = SigV4Request.signed_conn(:get, "/ckmpfullcrc64bad/object.bin") |> call()
    assert get.status == 404
  end

  test "default FULL_OBJECT multipart complete rejects a new checksum algorithm" do
    SigV4Request.signed_conn(:put, "/ckmpdefaultnewalg") |> call()

    init =
      SigV4Request.signed_conn(:post, "/ckmpdefaultnewalg/object.bin", query: %{"uploads" => ""})
      |> call()

    assert init.status == 200
    assert get_resp_header(init, "x-amz-checksum-algorithm") == ["CRC64NVME"]
    assert get_resp_header(init, "x-amz-checksum-type") == ["FULL_OBJECT"]
    upload_id = upload_id(init.resp_body)

    body = "default mpu new checksum algorithm"

    part =
      SigV4Request.signed_conn(:put, "/ckmpdefaultnewalg/object.bin",
        query: %{"partNumber" => "1", "uploadId" => upload_id},
        body: body
      )
      |> call()

    assert part.status == 200
    [etag] = get_resp_header(part, "etag")

    complete =
      complete_multipart_upload("ckmpdefaultnewalg", "object.bin", upload_id, [etag], [
        {"x-amz-checksum-xxhash3", "YstyBQcAuQ4="},
        {"x-amz-checksum-type", "FULL_OBJECT"},
        {"x-amz-mp-object-size", Integer.to_string(byte_size(body))}
      ])

    assert complete.status == 400
    assert complete.resp_body =~ "<Code>InvalidRequest</Code>"

    get = SigV4Request.signed_conn(:get, "/ckmpdefaultnewalg/object.bin") |> call()
    assert get.status == 404
  end

  test "CRC64NVME FULL_OBJECT intent includes UploadPartCopy bytes" do
    SigV4Request.signed_conn(:put, "/ckmpfullcrc64copy") |> call()
    source_body = "copied full-object bytes"
    object_checksum = crc64nvme_b64(source_body)

    SigV4Request.signed_conn(:put, "/ckmpfullcrc64copy/src.txt", body: source_body) |> call()

    init =
      SigV4Request.signed_conn(:post, "/ckmpfullcrc64copy/object.bin",
        query: %{"uploads" => ""},
        headers: [{"x-amz-checksum-algorithm", "CRC64NVME"}]
      )
      |> call()

    assert init.status == 200
    upload_id = upload_id(init.resp_body)

    copy =
      SigV4Request.signed_conn(:put, "/ckmpfullcrc64copy/object.bin",
        query: %{"partNumber" => "1", "uploadId" => upload_id},
        headers: [{"x-amz-copy-source", "/ckmpfullcrc64copy/src.txt"}]
      )
      |> call()

    assert copy.status == 200
    assert copy.resp_body =~ "<ChecksumCRC64NVME>#{object_checksum}</ChecksumCRC64NVME>"
    etag = copy_part_etag(copy.resp_body)

    complete =
      complete_multipart_upload("ckmpfullcrc64copy", "object.bin", upload_id, [etag], [
        {"x-amz-checksum-crc64nvme", object_checksum},
        {"x-amz-checksum-type", "FULL_OBJECT"}
      ])

    assert complete.status == 200
    assert complete.resp_body =~ "<ChecksumCRC64NVME>#{object_checksum}</ChecksumCRC64NVME>"
    assert complete.resp_body =~ "<ChecksumType>FULL_OBJECT</ChecksumType>"
  end

  test "CompleteMultipartUpload persists and returns SHA256 COMPOSITE checksum" do
    SigV4Request.signed_conn(:put, "/ckmpcomplete") |> call()
    part_bodies = ["first composite part", "second composite part"]
    part_checksums = Enum.map(part_bodies, &hash_b64(:sha256, &1))
    composite = composite_hash_b64(:sha256, part_bodies) <> "-2"

    init =
      SigV4Request.signed_conn(:post, "/ckmpcomplete/object.bin",
        query: %{"uploads" => ""},
        headers: [{"x-amz-checksum-algorithm", "SHA256"}]
      )
      |> call()

    assert init.status == 200
    upload_id = upload_id(init.resp_body)

    etags =
      part_bodies
      |> Enum.zip(part_checksums)
      |> Enum.with_index(1)
      |> Enum.map(fn {{body, checksum}, part_number} ->
        part =
          SigV4Request.signed_conn(:put, "/ckmpcomplete/object.bin",
            query: %{"partNumber" => Integer.to_string(part_number), "uploadId" => upload_id},
            body: body,
            headers: [
              {"x-amz-sdk-checksum-algorithm", "SHA256"},
              {"x-amz-checksum-sha256", checksum}
            ]
          )
          |> call()

        assert part.status == 200
        assert get_resp_header(part, "x-amz-checksum-sha256") == [checksum]
        [etag] = get_resp_header(part, "etag")
        etag
      end)

    complete_parts =
      etags
      |> Enum.zip(part_checksums)
      |> Enum.with_index(1)
      |> Enum.map(fn {{etag, checksum}, part_number} ->
        %{part_number: part_number, etag: etag, checksums: [{"ChecksumSHA256", checksum}]}
      end)

    complete =
      complete_multipart_upload_parts("ckmpcomplete", "object.bin", upload_id, complete_parts)

    assert complete.status == 200
    assert complete.resp_body =~ "<ChecksumSHA256>#{composite}</ChecksumSHA256>"
    assert complete.resp_body =~ "<ChecksumType>COMPOSITE</ChecksumType>"

    assert %Object{checksum: pg_checksum} =
             Repo.get_by(Object, bucket_name: "ckmpcomplete", key: "object.bin", is_latest: true)

    assert pg_checksum == %{
             "ChecksumSHA256" => composite,
             "ChecksumType" => "COMPOSITE"
           }

    meta =
      [@data_dir, "ckmpcomplete", "object.bin", "meta.json"]
      |> Path.join()
      |> File.read!()
      |> Sidecar.decode!()

    assert [%{"checksum" => sidecar_checksum}] = meta["versions"]
    assert sidecar_checksum == pg_checksum

    attrs =
      SigV4Request.signed_conn(:get, "/ckmpcomplete/object.bin",
        query: %{"attributes" => ""},
        headers: [{"x-amz-object-attributes", "Checksum"}]
      )
      |> call()

    assert attrs.status == 200
    assert attrs.resp_body =~ "<ChecksumSHA256>#{composite}</ChecksumSHA256>"
    assert attrs.resp_body =~ "<ChecksumType>COMPOSITE</ChecksumType>"
  end

  test "CompleteMultipartUpload accepts matching COMPOSITE checksum headers" do
    SigV4Request.signed_conn(:put, "/ckmpcompleteheaders") |> call()
    part_bodies = ["first composite header part", "second composite header part"]
    part_checksums = Enum.map(part_bodies, &hash_b64(:sha256, &1))
    composite = composite_hash_b64(:sha256, part_bodies) <> "-2"
    object_body = Enum.join(part_bodies, "")

    init =
      SigV4Request.signed_conn(:post, "/ckmpcompleteheaders/object.bin",
        query: %{"uploads" => ""},
        headers: [{"x-amz-checksum-algorithm", "SHA256"}]
      )
      |> call()

    assert init.status == 200
    upload_id = upload_id(init.resp_body)

    etags =
      part_bodies
      |> Enum.zip(part_checksums)
      |> Enum.with_index(1)
      |> Enum.map(fn {{body, checksum}, part_number} ->
        part =
          SigV4Request.signed_conn(:put, "/ckmpcompleteheaders/object.bin",
            query: %{"partNumber" => Integer.to_string(part_number), "uploadId" => upload_id},
            body: body,
            headers: [
              {"x-amz-sdk-checksum-algorithm", "SHA256"},
              {"x-amz-checksum-sha256", checksum}
            ]
          )
          |> call()

        assert part.status == 200
        [etag] = get_resp_header(part, "etag")
        etag
      end)

    complete =
      complete_multipart_upload("ckmpcompleteheaders", "object.bin", upload_id, etags, [
        {"x-amz-checksum-sha256", composite},
        {"x-amz-checksum-type", "COMPOSITE"},
        {"x-amz-mp-object-size", Integer.to_string(byte_size(object_body))}
      ])

    assert complete.status == 200
    assert complete.resp_body =~ "<ChecksumSHA256>#{composite}</ChecksumSHA256>"
    assert complete.resp_body =~ "<ChecksumType>COMPOSITE</ChecksumType>"
  end

  test "CompleteMultipartUpload rejects mismatched COMPOSITE checksum headers" do
    cases = [
      {"bad-value", [{"x-amz-checksum-sha256", hash_b64(:sha256, "wrong")}]},
      {"bad-type",
       [{"x-amz-checksum-sha256", :composite}, {"x-amz-checksum-type", "FULL_OBJECT"}]},
      {"bad-algorithm", [{"x-amz-checksum-crc32", crc32_b64("wrong")}]},
      {"bad-xxhash64-algorithm", [{"x-amz-checksum-xxhash64", xxhash64_b64("wrong")}]}
    ]

    for {suffix, complete_headers} <- cases do
      bucket = "ckmpcompletebad#{suffix}"
      SigV4Request.signed_conn(:put, "/#{bucket}") |> call()

      part_bodies = ["first composite mismatch part", "second composite mismatch part"]
      part_checksums = Enum.map(part_bodies, &hash_b64(:sha256, &1))
      composite = composite_hash_b64(:sha256, part_bodies) <> "-2"

      init =
        SigV4Request.signed_conn(:post, "/#{bucket}/object.bin",
          query: %{"uploads" => ""},
          headers: [{"x-amz-checksum-algorithm", "SHA256"}]
        )
        |> call()

      assert init.status == 200
      upload_id = upload_id(init.resp_body)

      etags =
        part_bodies
        |> Enum.zip(part_checksums)
        |> Enum.with_index(1)
        |> Enum.map(fn {{body, checksum}, part_number} ->
          part =
            SigV4Request.signed_conn(:put, "/#{bucket}/object.bin",
              query: %{"partNumber" => Integer.to_string(part_number), "uploadId" => upload_id},
              body: body,
              headers: [
                {"x-amz-sdk-checksum-algorithm", "SHA256"},
                {"x-amz-checksum-sha256", checksum}
              ]
            )
            |> call()

          assert part.status == 200
          [etag] = get_resp_header(part, "etag")
          etag
        end)

      headers =
        complete_headers
        |> Enum.map(fn
          {name, :composite} -> {name, composite}
          header -> header
        end)

      headers =
        if Enum.any?(headers, fn {name, _value} -> name == "x-amz-checksum-type" end) do
          headers
        else
          headers ++ [{"x-amz-checksum-type", "COMPOSITE"}]
        end

      bad = complete_multipart_upload(bucket, "object.bin", upload_id, etags, headers)

      assert bad.status == 400
      assert bad.resp_body =~ "<Code>BadDigest</Code>"

      get = SigV4Request.signed_conn(:get, "/#{bucket}/object.bin") |> call()
      assert get.status == 404
    end
  end

  test "CompleteMultipartUpload persists and returns SHA512 COMPOSITE checksum" do
    SigV4Request.signed_conn(:put, "/ckmpcompletesha512") |> call()
    part_bodies = ["first sha512 part", "second sha512 part"]
    part_checksums = Enum.map(part_bodies, &hash_b64(:sha512, &1))
    composite = composite_hash_b64(:sha512, part_bodies) <> "-2"

    init =
      SigV4Request.signed_conn(:post, "/ckmpcompletesha512/object.bin",
        query: %{"uploads" => ""},
        headers: [{"x-amz-checksum-algorithm", "SHA512"}]
      )
      |> call()

    assert init.status == 200
    upload_id = upload_id(init.resp_body)

    etags =
      part_bodies
      |> Enum.zip(part_checksums)
      |> Enum.with_index(1)
      |> Enum.map(fn {{body, checksum}, part_number} ->
        part =
          SigV4Request.signed_conn(:put, "/ckmpcompletesha512/object.bin",
            query: %{"partNumber" => Integer.to_string(part_number), "uploadId" => upload_id},
            body: body,
            headers: [
              {"x-amz-sdk-checksum-algorithm", "SHA512"},
              {"x-amz-checksum-sha512", checksum}
            ]
          )
          |> call()

        assert part.status == 200
        assert get_resp_header(part, "x-amz-checksum-sha512") == [checksum]
        [etag] = get_resp_header(part, "etag")
        etag
      end)

    complete_parts =
      etags
      |> Enum.zip(part_checksums)
      |> Enum.with_index(1)
      |> Enum.map(fn {{etag, checksum}, part_number} ->
        %{part_number: part_number, etag: etag, checksums: [{"ChecksumSHA512", checksum}]}
      end)

    complete =
      complete_multipart_upload_parts(
        "ckmpcompletesha512",
        "object.bin",
        upload_id,
        complete_parts
      )

    assert complete.status == 200
    assert complete.resp_body =~ "<ChecksumSHA512>#{composite}</ChecksumSHA512>"
    assert complete.resp_body =~ "<ChecksumType>COMPOSITE</ChecksumType>"

    assert %Object{checksum: pg_checksum} =
             Repo.get_by(Object,
               bucket_name: "ckmpcompletesha512",
               key: "object.bin",
               is_latest: true
             )

    assert pg_checksum == %{
             "ChecksumSHA512" => composite,
             "ChecksumType" => "COMPOSITE"
           }

    attrs =
      SigV4Request.signed_conn(:get, "/ckmpcompletesha512/object.bin",
        query: %{"attributes" => ""},
        headers: [{"x-amz-object-attributes", "Checksum,ObjectParts"}]
      )
      |> call()

    assert attrs.status == 200
    assert attrs.resp_body =~ "<ChecksumSHA512>#{composite}</ChecksumSHA512>"
    assert attrs.resp_body =~ "<ChecksumType>COMPOSITE</ChecksumType>"
    assert attrs.resp_body =~ "<ObjectParts>"
    assert attrs.resp_body =~ "<ChecksumSHA512>#{Enum.at(part_checksums, 0)}</ChecksumSHA512>"
    assert attrs.resp_body =~ "<ChecksumSHA512>#{Enum.at(part_checksums, 1)}</ChecksumSHA512>"
  end

  test "CompleteMultipartUpload persists and returns XXHASH64 COMPOSITE checksum" do
    SigV4Request.signed_conn(:put, "/ckmpcompletexxhash64") |> call()
    part_bodies = ["first xxhash64 part", "second xxhash64 part"]
    part_checksums = Enum.map(part_bodies, &xxhash64_b64/1)
    composite = composite_xxhash64_b64(part_bodies) <> "-2"
    object_body = Enum.join(part_bodies, "")

    init =
      SigV4Request.signed_conn(:post, "/ckmpcompletexxhash64/object.bin",
        query: %{"uploads" => ""},
        headers: [{"x-amz-checksum-algorithm", "XXHASH64"}]
      )
      |> call()

    assert init.status == 200
    assert get_resp_header(init, "x-amz-checksum-algorithm") == ["XXHASH64"]
    assert get_resp_header(init, "x-amz-checksum-type") == ["COMPOSITE"]
    upload_id = upload_id(init.resp_body)

    etags =
      part_bodies
      |> Enum.zip(part_checksums)
      |> Enum.with_index(1)
      |> Enum.map(fn {{body, checksum}, part_number} ->
        part =
          SigV4Request.signed_conn(:put, "/ckmpcompletexxhash64/object.bin",
            query: %{"partNumber" => Integer.to_string(part_number), "uploadId" => upload_id},
            body: body,
            headers: [
              {"x-amz-sdk-checksum-algorithm", "XXHASH64"},
              {"x-amz-checksum-xxhash64", checksum}
            ]
          )
          |> call()

        assert part.status == 200
        assert get_resp_header(part, "x-amz-checksum-xxhash64") == [checksum]
        [etag] = get_resp_header(part, "etag")
        etag
      end)

    complete_parts =
      etags
      |> Enum.zip(part_checksums)
      |> Enum.with_index(1)
      |> Enum.map(fn {{etag, checksum}, part_number} ->
        %{part_number: part_number, etag: etag, checksums: [{"ChecksumXXHASH64", checksum}]}
      end)

    complete =
      complete_multipart_upload_parts(
        "ckmpcompletexxhash64",
        "object.bin",
        upload_id,
        complete_parts,
        [
          {"x-amz-checksum-xxhash64", composite},
          {"x-amz-checksum-type", "COMPOSITE"},
          {"x-amz-mp-object-size", Integer.to_string(byte_size(object_body))}
        ]
      )

    assert complete.status == 200
    assert complete.resp_body =~ "<ChecksumXXHASH64>#{composite}</ChecksumXXHASH64>"
    assert complete.resp_body =~ "<ChecksumType>COMPOSITE</ChecksumType>"

    assert %Object{checksum: pg_checksum} =
             Repo.get_by(Object,
               bucket_name: "ckmpcompletexxhash64",
               key: "object.bin",
               is_latest: true
             )

    assert pg_checksum == %{
             "ChecksumXXHASH64" => composite,
             "ChecksumType" => "COMPOSITE"
           }

    attrs =
      SigV4Request.signed_conn(:get, "/ckmpcompletexxhash64/object.bin",
        query: %{"attributes" => ""},
        headers: [{"x-amz-object-attributes", "Checksum,ObjectParts"}]
      )
      |> call()

    assert attrs.status == 200
    assert attrs.resp_body =~ "<ChecksumXXHASH64>#{composite}</ChecksumXXHASH64>"
    assert attrs.resp_body =~ "<ChecksumType>COMPOSITE</ChecksumType>"
    assert attrs.resp_body =~ "<ObjectParts>"
    assert attrs.resp_body =~ "<ChecksumXXHASH64>#{Enum.at(part_checksums, 0)}</ChecksumXXHASH64>"
    assert attrs.resp_body =~ "<ChecksumXXHASH64>#{Enum.at(part_checksums, 1)}</ChecksumXXHASH64>"
  end

  test "CompleteMultipartUpload persists and returns XXHASH3 and XXHASH128 COMPOSITE checksums" do
    cases = [
      %{
        algorithm: "XXHASH3",
        bucket: "ckmpcompletexxhash3",
        header: "x-amz-checksum-xxhash3",
        field: "ChecksumXXHASH3",
        part_bodies: ["first xxhash3 part", "second xxhash3 part"],
        part_checksums: ["+IREpmYMwCQ=", "pVA50B7iMtY="],
        composite: "Plp2DY4jh2Y=-2"
      },
      %{
        algorithm: "XXHASH128",
        bucket: "ckmpcompletexxhash128",
        header: "x-amz-checksum-xxhash128",
        field: "ChecksumXXHASH128",
        part_bodies: ["first xxhash128 part", "second xxhash128 part"],
        part_checksums: ["QHLeBw9KsSe3cm8p3RwD5w==", "Ok2MxmJsTYk+an8R4T3R0A=="],
        composite: "Qyao1V7pHkcwj79QERWdhQ==-2"
      }
    ]

    for %{
          algorithm: algorithm,
          bucket: bucket,
          header: header,
          field: field,
          part_bodies: part_bodies,
          part_checksums: part_checksums,
          composite: composite
        } <- cases do
      SigV4Request.signed_conn(:put, "/#{bucket}") |> call()
      object_body = Enum.join(part_bodies, "")

      init =
        SigV4Request.signed_conn(:post, "/#{bucket}/object.bin",
          query: %{"uploads" => ""},
          headers: [{"x-amz-checksum-algorithm", algorithm}]
        )
        |> call()

      assert init.status == 200
      assert get_resp_header(init, "x-amz-checksum-algorithm") == [algorithm]
      assert get_resp_header(init, "x-amz-checksum-type") == ["COMPOSITE"]
      upload_id = upload_id(init.resp_body)

      etags =
        part_bodies
        |> Enum.zip(part_checksums)
        |> Enum.with_index(1)
        |> Enum.map(fn {{body, checksum}, part_number} ->
          part =
            SigV4Request.signed_conn(:put, "/#{bucket}/object.bin",
              query: %{"partNumber" => Integer.to_string(part_number), "uploadId" => upload_id},
              body: body,
              headers: [
                {"x-amz-sdk-checksum-algorithm", algorithm},
                {header, checksum}
              ]
            )
            |> call()

          assert part.status == 200
          assert get_resp_header(part, header) == [checksum]
          [etag] = get_resp_header(part, "etag")
          etag
        end)

      complete_parts =
        etags
        |> Enum.zip(part_checksums)
        |> Enum.with_index(1)
        |> Enum.map(fn {{etag, checksum}, part_number} ->
          %{part_number: part_number, etag: etag, checksums: [{field, checksum}]}
        end)

      complete =
        complete_multipart_upload_parts(bucket, "object.bin", upload_id, complete_parts, [
          {header, composite},
          {"x-amz-checksum-type", "COMPOSITE"},
          {"x-amz-mp-object-size", Integer.to_string(byte_size(object_body))}
        ])

      assert complete.status == 200
      assert complete.resp_body =~ "<#{field}>#{composite}</#{field}>"
      assert complete.resp_body =~ "<ChecksumType>COMPOSITE</ChecksumType>"

      assert %Object{checksum: pg_checksum} =
               Repo.get_by(Object, bucket_name: bucket, key: "object.bin", is_latest: true)

      assert pg_checksum == %{
               field => composite,
               "ChecksumType" => "COMPOSITE"
             }

      attrs =
        SigV4Request.signed_conn(:get, "/#{bucket}/object.bin",
          query: %{"attributes" => ""},
          headers: [{"x-amz-object-attributes", "Checksum,ObjectParts"}]
        )
        |> call()

      assert attrs.status == 200
      assert attrs.resp_body =~ "<#{field}>#{composite}</#{field}>"
      assert attrs.resp_body =~ "<ChecksumType>COMPOSITE</ChecksumType>"
      assert attrs.resp_body =~ "<ObjectParts>"
      assert attrs.resp_body =~ "<#{field}>#{Enum.at(part_checksums, 0)}</#{field}>"
      assert attrs.resp_body =~ "<#{field}>#{Enum.at(part_checksums, 1)}</#{field}>"
    end
  end

  test "CompleteMultipartUpload persists and returns CRC32 COMPOSITE checksum" do
    SigV4Request.signed_conn(:put, "/ckmpcompletecrc") |> call()
    part_bodies = ["first crc part", "second crc part"]
    part_checksums = Enum.map(part_bodies, &crc32_b64/1)
    composite = composite_crc32_b64(part_bodies) <> "-2"

    init =
      SigV4Request.signed_conn(:post, "/ckmpcompletecrc/object.bin",
        query: %{"uploads" => ""},
        headers: [{"x-amz-checksum-algorithm", "CRC32"}]
      )
      |> call()

    assert init.status == 200
    upload_id = upload_id(init.resp_body)

    etags =
      part_bodies
      |> Enum.zip(part_checksums)
      |> Enum.with_index(1)
      |> Enum.map(fn {{body, checksum}, part_number} ->
        part =
          SigV4Request.signed_conn(:put, "/ckmpcompletecrc/object.bin",
            query: %{"partNumber" => Integer.to_string(part_number), "uploadId" => upload_id},
            body: body,
            headers: [
              {"x-amz-sdk-checksum-algorithm", "CRC32"},
              {"x-amz-checksum-crc32", checksum}
            ]
          )
          |> call()

        assert part.status == 200
        assert get_resp_header(part, "x-amz-checksum-crc32") == [checksum]
        [etag] = get_resp_header(part, "etag")
        etag
      end)

    complete_parts =
      etags
      |> Enum.zip(part_checksums)
      |> Enum.with_index(1)
      |> Enum.map(fn {{etag, checksum}, part_number} ->
        %{part_number: part_number, etag: etag, checksums: [{"ChecksumCRC32", checksum}]}
      end)

    complete =
      complete_multipart_upload_parts("ckmpcompletecrc", "object.bin", upload_id, complete_parts)

    assert complete.status == 200
    assert complete.resp_body =~ "<ChecksumCRC32>#{composite}</ChecksumCRC32>"
    assert complete.resp_body =~ "<ChecksumType>COMPOSITE</ChecksumType>"

    assert %Object{checksum: pg_checksum} =
             Repo.get_by(Object,
               bucket_name: "ckmpcompletecrc",
               key: "object.bin",
               is_latest: true
             )

    assert pg_checksum == %{
             "ChecksumCRC32" => composite,
             "ChecksumType" => "COMPOSITE"
           }

    attrs =
      SigV4Request.signed_conn(:get, "/ckmpcompletecrc/object.bin",
        query: %{"attributes" => ""},
        headers: [{"x-amz-object-attributes", "Checksum,ObjectParts"}]
      )
      |> call()

    assert attrs.status == 200
    assert attrs.resp_body =~ "<ChecksumCRC32>#{composite}</ChecksumCRC32>"
    assert attrs.resp_body =~ "<ChecksumType>COMPOSITE</ChecksumType>"
    assert attrs.resp_body =~ "<ObjectParts>"
    assert attrs.resp_body =~ "<ChecksumCRC32>#{Enum.at(part_checksums, 0)}</ChecksumCRC32>"
    assert attrs.resp_body =~ "<ChecksumCRC32>#{Enum.at(part_checksums, 1)}</ChecksumCRC32>"
  end

  test "CompleteMultipartUpload persists and returns CRC32C COMPOSITE checksum" do
    SigV4Request.signed_conn(:put, "/ckmpcompletecrc32c") |> call()
    part_bodies = ["first crc32c part", "second crc32c part"]
    part_checksums = Enum.map(part_bodies, &crc32c_b64/1)
    composite = composite_crc32c_b64(part_bodies) <> "-2"

    init =
      SigV4Request.signed_conn(:post, "/ckmpcompletecrc32c/object.bin",
        query: %{"uploads" => ""},
        headers: [{"x-amz-checksum-algorithm", "CRC32C"}]
      )
      |> call()

    assert init.status == 200
    upload_id = upload_id(init.resp_body)

    etags =
      part_bodies
      |> Enum.zip(part_checksums)
      |> Enum.with_index(1)
      |> Enum.map(fn {{body, checksum}, part_number} ->
        part =
          SigV4Request.signed_conn(:put, "/ckmpcompletecrc32c/object.bin",
            query: %{"partNumber" => Integer.to_string(part_number), "uploadId" => upload_id},
            body: body,
            headers: [
              {"x-amz-sdk-checksum-algorithm", "CRC32C"},
              {"x-amz-checksum-crc32c", checksum}
            ]
          )
          |> call()

        assert part.status == 200
        assert get_resp_header(part, "x-amz-checksum-crc32c") == [checksum]
        [etag] = get_resp_header(part, "etag")
        etag
      end)

    complete_parts =
      etags
      |> Enum.zip(part_checksums)
      |> Enum.with_index(1)
      |> Enum.map(fn {{etag, checksum}, part_number} ->
        %{part_number: part_number, etag: etag, checksums: [{"ChecksumCRC32C", checksum}]}
      end)

    complete =
      complete_multipart_upload_parts(
        "ckmpcompletecrc32c",
        "object.bin",
        upload_id,
        complete_parts
      )

    assert complete.status == 200
    assert complete.resp_body =~ "<ChecksumCRC32C>#{composite}</ChecksumCRC32C>"
    assert complete.resp_body =~ "<ChecksumType>COMPOSITE</ChecksumType>"

    assert %Object{checksum: pg_checksum} =
             Repo.get_by(Object,
               bucket_name: "ckmpcompletecrc32c",
               key: "object.bin",
               is_latest: true
             )

    assert pg_checksum == %{
             "ChecksumCRC32C" => composite,
             "ChecksumType" => "COMPOSITE"
           }

    attrs =
      SigV4Request.signed_conn(:get, "/ckmpcompletecrc32c/object.bin",
        query: %{"attributes" => ""},
        headers: [{"x-amz-object-attributes", "Checksum,ObjectParts"}]
      )
      |> call()

    assert attrs.status == 200
    assert attrs.resp_body =~ "<ChecksumCRC32C>#{composite}</ChecksumCRC32C>"
    assert attrs.resp_body =~ "<ChecksumType>COMPOSITE</ChecksumType>"
    assert attrs.resp_body =~ "<ObjectParts>"
    assert attrs.resp_body =~ "<ChecksumCRC32C>#{Enum.at(part_checksums, 0)}</ChecksumCRC32C>"
    assert attrs.resp_body =~ "<ChecksumCRC32C>#{Enum.at(part_checksums, 1)}</ChecksumCRC32C>"
  end

  test "CompleteMultipartUpload rejects mismatched part checksum elements before object commit" do
    SigV4Request.signed_conn(:put, "/ckmpcompletebadpart") |> call()
    body = "part with checksum"
    checksum = hash_b64(:sha256, body)

    init =
      SigV4Request.signed_conn(:post, "/ckmpcompletebadpart/object.bin",
        query: %{"uploads" => ""},
        headers: [{"x-amz-checksum-algorithm", "SHA256"}]
      )
      |> call()

    assert init.status == 200
    upload_id = upload_id(init.resp_body)

    part =
      SigV4Request.signed_conn(:put, "/ckmpcompletebadpart/object.bin",
        query: %{"partNumber" => "1", "uploadId" => upload_id},
        body: body,
        headers: [
          {"x-amz-sdk-checksum-algorithm", "SHA256"},
          {"x-amz-checksum-sha256", checksum}
        ]
      )
      |> call()

    assert part.status == 200
    [etag] = get_resp_header(part, "etag")

    complete =
      complete_multipart_upload_parts("ckmpcompletebadpart", "object.bin", upload_id, [
        %{
          part_number: 1,
          etag: etag,
          checksums: [{"ChecksumSHA256", hash_b64(:sha256, "different")}]
        }
      ])

    assert complete.status == 400
    assert complete.resp_body =~ "<Code>InvalidPart</Code>"

    get = SigV4Request.signed_conn(:get, "/ckmpcompletebadpart/object.bin") |> call()
    assert get.status == 404
  end

  test "CompleteMultipartUpload rejects sparse checksum-enabled part numbers" do
    SigV4Request.signed_conn(:put, "/ckmpgaps") |> call()

    init =
      SigV4Request.signed_conn(:post, "/ckmpgaps/object.bin",
        query: %{"uploads" => ""},
        headers: [{"x-amz-checksum-algorithm", "SHA256"}]
      )
      |> call()

    assert init.status == 200
    upload_id = upload_id(init.resp_body)

    parts =
      [{"part one", 1}, {"part three", 3}]
      |> Enum.map(fn {body, part_number} ->
        checksum = hash_b64(:sha256, body)

        part =
          SigV4Request.signed_conn(:put, "/ckmpgaps/object.bin",
            query: %{"partNumber" => Integer.to_string(part_number), "uploadId" => upload_id},
            body: body,
            headers: [
              {"x-amz-sdk-checksum-algorithm", "SHA256"},
              {"x-amz-checksum-sha256", checksum}
            ]
          )
          |> call()

        assert part.status == 200
        [etag] = get_resp_header(part, "etag")
        %{part_number: part_number, etag: etag}
      end)

    complete = complete_multipart_upload_parts("ckmpgaps", "object.bin", upload_id, parts)

    assert complete.status == 400
    assert complete.resp_body =~ "<Code>InvalidPartOrder</Code>"

    get = SigV4Request.signed_conn(:get, "/ckmpgaps/object.bin") |> call()
    assert get.status == 404
  end

  test "CompleteMultipartUpload explicit unknown object checksum headers fail closed before object commit" do
    SigV4Request.signed_conn(:put, "/ckmpcompletealg") |> call()

    init =
      SigV4Request.signed_conn(:post, "/ckmpcompletealg/object.bin", query: %{"uploads" => ""})
      |> call()

    assert init.status == 200
    upload_id = upload_id(init.resp_body)

    part =
      SigV4Request.signed_conn(:put, "/ckmpcompletealg/object.bin",
        query: %{"partNumber" => "1", "uploadId" => upload_id},
        body: "part"
      )
      |> call()

    assert part.status == 200
    [etag] = get_resp_header(part, "etag")

    complete =
      complete_multipart_upload("ckmpcompletealg", "object.bin", upload_id, [etag], [
        {"x-amz-checksum-blake3", Base.encode64("unsupported")}
      ])

    assert complete.status == 501
    assert complete.resp_body =~ "<Code>NotImplemented</Code>"

    get = SigV4Request.signed_conn(:get, "/ckmpcompletealg/object.bin") |> call()
    assert get.status == 404
  end

  test "UploadPart validates aws-chunked checksum trailer and echoes it" do
    SigV4Request.signed_conn(:put, "/ckmptrail") |> call()
    body = "trailer part"
    checksum = hash_b64(:sha256, body)

    init =
      SigV4Request.signed_conn(:post, "/ckmptrail/object.bin",
        query: %{"uploads" => ""},
        headers: [{"x-amz-checksum-algorithm", "SHA256"}]
      )
      |> call()

    assert init.status == 200
    upload_id = upload_id(init.resp_body)

    part =
      SigV4Request.signed_chunked_conn(:put, "/ckmptrail/object.bin", body,
        query: %{"partNumber" => "1", "uploadId" => upload_id},
        trailer_headers: [{"x-amz-checksum-sha256", checksum}]
      )
      |> call()

    assert part.status == 200
    assert get_resp_header(part, "x-amz-checksum-sha256") == [checksum]
    [etag] = get_resp_header(part, "etag")

    complete = complete_multipart_upload("ckmptrail", "object.bin", upload_id, [etag])
    assert complete.status == 200

    get = SigV4Request.signed_conn(:get, "/ckmptrail/object.bin") |> call()
    assert get.status == 200
    assert get.resp_body == body
  end

  test "UploadPart BadDigest does not overwrite an existing part" do
    SigV4Request.signed_conn(:put, "/ckmprollback") |> call()

    init =
      SigV4Request.signed_conn(:post, "/ckmprollback/object.bin",
        query: %{"uploads" => ""},
        headers: [{"x-amz-checksum-algorithm", "SHA256"}]
      )
      |> call()

    assert init.status == 200
    upload_id = upload_id(init.resp_body)

    old =
      SigV4Request.signed_conn(:put, "/ckmprollback/object.bin",
        query: %{"partNumber" => "1", "uploadId" => upload_id},
        body: "OLD"
      )
      |> call()

    assert old.status == 200
    [old_etag] = get_resp_header(old, "etag")

    bad =
      SigV4Request.signed_conn(:put, "/ckmprollback/object.bin",
        query: %{"partNumber" => "1", "uploadId" => upload_id},
        body: "NEW",
        headers: [{"x-amz-checksum-sha256", hash_b64(:sha256, "different")}]
      )
      |> call()

    assert bad.status == 400
    assert bad.resp_body =~ "<Code>BadDigest</Code>"

    complete = complete_multipart_upload("ckmprollback", "object.bin", upload_id, [old_etag])
    assert complete.status == 200

    get = SigV4Request.signed_conn(:get, "/ckmprollback/object.bin") |> call()
    assert get.status == 200
    assert get.resp_body == "OLD"
  end

  test "CreateMultipartUpload checksum intent drives UploadPartCopy checksum metadata" do
    SigV4Request.signed_conn(:put, "/ckmpcopyintent") |> call()
    source_body = "source bytes copied as a checksum-aware part"
    part_checksum = hash_b64(:sha256, source_body)
    composite = composite_hash_b64(:sha256, [source_body]) <> "-1"

    SigV4Request.signed_conn(:put, "/ckmpcopyintent/src.txt", body: source_body) |> call()

    init =
      SigV4Request.signed_conn(:post, "/ckmpcopyintent/object.bin",
        query: %{"uploads" => ""},
        headers: [{"x-amz-checksum-algorithm", "SHA256"}]
      )
      |> call()

    assert init.status == 200
    assert get_resp_header(init, "x-amz-checksum-algorithm") == ["SHA256"]
    assert get_resp_header(init, "x-amz-checksum-type") == ["COMPOSITE"]
    upload_id = upload_id(init.resp_body)

    copy =
      SigV4Request.signed_conn(:put, "/ckmpcopyintent/object.bin",
        query: %{"partNumber" => "1", "uploadId" => upload_id},
        headers: [{"x-amz-copy-source", "/ckmpcopyintent/src.txt"}]
      )
      |> call()

    assert copy.status == 200
    assert copy.resp_body =~ "<ChecksumSHA256>#{part_checksum}</ChecksumSHA256>"

    etag = copy_part_etag(copy.resp_body)

    list =
      SigV4Request.signed_conn(:get, "/ckmpcopyintent/object.bin",
        query: %{"uploadId" => upload_id}
      )
      |> call()

    assert list.status == 200
    assert list.resp_body =~ "<ChecksumSHA256>#{part_checksum}</ChecksumSHA256>"

    {:ok, upload} = Maxio.Multipart.get_upload("ckmpcopyintent", "object.bin", upload_id)

    assert %{checksum: %{"ChecksumSHA256" => ^part_checksum}} =
             Repo.get_by(Maxio.Multipart.Part, upload_id: upload.id, part_number: 1)

    complete = complete_multipart_upload("ckmpcopyintent", "object.bin", upload_id, [etag])

    assert complete.status == 200
    assert complete.resp_body =~ "<ChecksumSHA256>#{composite}</ChecksumSHA256>"
    assert complete.resp_body =~ "<ChecksumType>COMPOSITE</ChecksumType>"

    attrs =
      SigV4Request.signed_conn(:get, "/ckmpcopyintent/object.bin",
        query: %{"attributes" => ""},
        headers: [{"x-amz-object-attributes", "Checksum,ObjectParts"}]
      )
      |> call()

    assert attrs.status == 200
    assert attrs.resp_body =~ "<ChecksumSHA256>#{composite}</ChecksumSHA256>"
    assert attrs.resp_body =~ "<ChecksumType>COMPOSITE</ChecksumType>"
    assert attrs.resp_body =~ "<ChecksumSHA256>#{part_checksum}</ChecksumSHA256>"
  end

  test "UploadPartCopy checksum intent hashes only the selected source range" do
    SigV4Request.signed_conn(:put, "/ckmpcopyrange") |> call()
    prefix = String.duplicate("a", 5_242_880)
    range_body = "RANGE-CHECKSUM"
    source_body = prefix <> range_body <> "tail"
    part_checksum = hash_b64(:sha256, range_body)

    SigV4Request.signed_conn(:put, "/ckmpcopyrange/src.bin", body: source_body) |> call()

    init =
      SigV4Request.signed_conn(:post, "/ckmpcopyrange/object.bin",
        query: %{"uploads" => ""},
        headers: [{"x-amz-checksum-algorithm", "SHA256"}]
      )
      |> call()

    assert init.status == 200
    upload_id = upload_id(init.resp_body)
    first = byte_size(prefix)
    last = first + byte_size(range_body) - 1

    copy =
      SigV4Request.signed_conn(:put, "/ckmpcopyrange/object.bin",
        query: %{"partNumber" => "1", "uploadId" => upload_id},
        headers: [
          {"x-amz-copy-source", "/ckmpcopyrange/src.bin"},
          {"x-amz-copy-source-range", "bytes=#{first}-#{last}"}
        ]
      )
      |> call()

    assert copy.status == 200
    assert copy.resp_body =~ "<ChecksumSHA256>#{part_checksum}</ChecksumSHA256>"

    etag = copy_part_etag(copy.resp_body)

    complete = complete_multipart_upload("ckmpcopyrange", "object.bin", upload_id, [etag])
    assert complete.status == 200

    get = SigV4Request.signed_conn(:get, "/ckmpcopyrange/object.bin") |> call()
    assert get.status == 200
    assert get.resp_body == range_body
  end

  test "checksum intent supports mixed UploadPart and UploadPartCopy completion" do
    SigV4Request.signed_conn(:put, "/ckmpcopymixed") |> call()
    first_body = "uploaded body part"
    second_body = "copied body part"
    first_checksum = hash_b64(:sha256, first_body)
    second_checksum = hash_b64(:sha256, second_body)
    composite = composite_hash_b64(:sha256, [first_body, second_body]) <> "-2"

    SigV4Request.signed_conn(:put, "/ckmpcopymixed/src.txt", body: second_body) |> call()

    init =
      SigV4Request.signed_conn(:post, "/ckmpcopymixed/object.bin",
        query: %{"uploads" => ""},
        headers: [{"x-amz-checksum-algorithm", "SHA256"}]
      )
      |> call()

    assert init.status == 200
    upload_id = upload_id(init.resp_body)

    uploaded =
      SigV4Request.signed_conn(:put, "/ckmpcopymixed/object.bin",
        query: %{"partNumber" => "1", "uploadId" => upload_id},
        body: first_body
      )
      |> call()

    assert uploaded.status == 200
    assert get_resp_header(uploaded, "x-amz-checksum-sha256") == [first_checksum]
    [etag1] = get_resp_header(uploaded, "etag")

    copied =
      SigV4Request.signed_conn(:put, "/ckmpcopymixed/object.bin",
        query: %{"partNumber" => "2", "uploadId" => upload_id},
        headers: [{"x-amz-copy-source", "/ckmpcopymixed/src.txt"}]
      )
      |> call()

    assert copied.status == 200
    assert copied.resp_body =~ "<ChecksumSHA256>#{second_checksum}</ChecksumSHA256>"

    etag2 = copy_part_etag(copied.resp_body)

    complete = complete_multipart_upload("ckmpcopymixed", "object.bin", upload_id, [etag1, etag2])

    assert complete.status == 200
    assert complete.resp_body =~ "<ChecksumSHA256>#{composite}</ChecksumSHA256>"
    assert complete.resp_body =~ "<ChecksumType>COMPOSITE</ChecksumType>"

    get = SigV4Request.signed_conn(:get, "/ckmpcopymixed/object.bin") |> call()
    assert get.status == 200
    assert get.resp_body == first_body <> second_body
  end

  test "CreateMultipartUpload unsupported checksum modes fail before session commit" do
    SigV4Request.signed_conn(:put, "/ckmpintentfail") |> call()

    sha_full_object =
      SigV4Request.signed_conn(:post, "/ckmpintentfail/full-sha.bin",
        query: %{"uploads" => ""},
        headers: [
          {"x-amz-checksum-algorithm", "SHA256"},
          {"x-amz-checksum-type", "FULL_OBJECT"}
        ]
      )
      |> call()

    assert sha_full_object.status == 400
    assert sha_full_object.resp_body =~ "<Code>InvalidRequest</Code>"

    crc64_composite =
      SigV4Request.signed_conn(:post, "/ckmpintentfail/crc64-composite.bin",
        query: %{"uploads" => ""},
        headers: [
          {"x-amz-checksum-algorithm", "CRC64NVME"},
          {"x-amz-checksum-type", "COMPOSITE"}
        ]
      )
      |> call()

    assert crc64_composite.status == 400
    assert crc64_composite.resp_body =~ "<Code>InvalidRequest</Code>"

    xxhash64_full_object =
      SigV4Request.signed_conn(:post, "/ckmpintentfail/xxhash64-full.bin",
        query: %{"uploads" => ""},
        headers: [
          {"x-amz-checksum-algorithm", "XXHASH64"},
          {"x-amz-checksum-type", "FULL_OBJECT"}
        ]
      )
      |> call()

    assert xxhash64_full_object.status == 400
    assert xxhash64_full_object.resp_body =~ "<Code>InvalidRequest</Code>"

    for algorithm <- ["XXHASH3", "XXHASH128"] do
      full_object =
        SigV4Request.signed_conn(:post, "/ckmpintentfail/#{String.downcase(algorithm)}-full.bin",
          query: %{"uploads" => ""},
          headers: [
            {"x-amz-checksum-algorithm", algorithm},
            {"x-amz-checksum-type", "FULL_OBJECT"}
          ]
        )
        |> call()

      assert full_object.status == 400
      assert full_object.resp_body =~ "<Code>InvalidRequest</Code>"
    end

    type_without_algorithm =
      SigV4Request.signed_conn(:post, "/ckmpintentfail/type-only.bin",
        query: %{"uploads" => ""},
        headers: [{"x-amz-checksum-type", "COMPOSITE"}]
      )
      |> call()

    assert type_without_algorithm.status == 400
    assert type_without_algorithm.resp_body =~ "<Code>InvalidRequest</Code>"

    assert {:error, :not_found} =
             Maxio.Multipart.get_upload("ckmpintentfail", "full-sha.bin", "does-not-matter")

    assert [] =
             Repo.all(
               from u in Maxio.Multipart.Upload,
                 where: u.bucket_name == "ckmpintentfail"
             )
  end

  test "UploadPartCopy checksum headers fail closed before copying source bytes" do
    SigV4Request.signed_conn(:put, "/ckmpcopy") |> call()
    SigV4Request.signed_conn(:put, "/ckmpcopy/src.txt", body: "source bytes") |> call()

    init =
      SigV4Request.signed_conn(:post, "/ckmpcopy/object.bin", query: %{"uploads" => ""})
      |> call()

    assert init.status == 200
    upload_id = upload_id(init.resp_body)

    rejected_headers = [
      [
        {"x-amz-copy-source", "/ckmpcopy/src.txt"},
        {"x-amz-checksum-sha256", hash_b64(:sha256, "source bytes")}
      ],
      [
        {"x-amz-copy-source", "/ckmpcopy/src.txt"},
        {"x-amz-sdk-checksum-algorithm", "SHA256"}
      ],
      [
        {"x-amz-copy-source", "/ckmpcopy/src.txt"},
        {"x-amz-checksum-algorithm", "SHA256"}
      ],
      [
        {"x-amz-copy-source", "/ckmpcopy/src.txt"},
        {"x-amz-trailer", "x-amz-checksum-sha256"}
      ]
    ]

    for {headers, part_number} <- Enum.with_index(rejected_headers, 1) do
      part =
        SigV4Request.signed_conn(:put, "/ckmpcopy/object.bin",
          query: %{"partNumber" => Integer.to_string(part_number), "uploadId" => upload_id},
          headers: headers
        )
        |> call()

      assert part.status == 400
      assert part.resp_body =~ "<Code>InvalidRequest</Code>"
    end

    list =
      SigV4Request.signed_conn(:get, "/ckmpcopy/object.bin", query: %{"uploadId" => upload_id})
      |> call()

    assert list.status == 200

    for part_number <- 1..length(rejected_headers) do
      refute list.resp_body =~ "<PartNumber>#{part_number}</PartNumber>"
    end
  end

  defp complete_multipart_upload(bucket, key, upload_id, etags, headers \\ []) do
    parts =
      etags
      |> Enum.with_index(1)
      |> Enum.map(fn {etag, part_number} -> %{part_number: part_number, etag: etag} end)

    complete_multipart_upload_parts(bucket, key, upload_id, parts, headers)
  end

  defp complete_multipart_upload_parts(bucket, key, upload_id, parts, headers \\ []) do
    body = complete_multipart_upload_body(parts)

    SigV4Request.signed_conn(:post, "/#{bucket}/#{key}",
      query: %{"uploadId" => upload_id},
      body: body,
      headers: headers
    )
    |> call()
  end

  defp complete_multipart_upload_chunked(
         bucket,
         key,
         upload_id,
         etags,
         trailer_headers,
         headers \\ []
       ) do
    parts =
      etags
      |> Enum.with_index(1)
      |> Enum.map(fn {etag, part_number} -> %{part_number: part_number, etag: etag} end)

    body = complete_multipart_upload_body(parts)

    SigV4Request.signed_chunked_conn(:post, "/#{bucket}/#{key}", body,
      query: %{"uploadId" => upload_id},
      headers: headers,
      trailer_headers: trailer_headers
    )
    |> call()
  end

  defp complete_multipart_upload_body(parts) do
    parts =
      Enum.map(parts, fn part ->
        checksum_xml =
          part
          |> Map.get(:checksums, [])
          |> Enum.map(fn {name, value} -> "<#{name}>#{value}</#{name}>" end)

        [
          "<Part><PartNumber>",
          Integer.to_string(part.part_number),
          "</PartNumber>",
          checksum_xml,
          "<ETag>",
          part.etag,
          "</ETag></Part>"
        ]
      end)

    IO.iodata_to_binary(["<CompleteMultipartUpload>", parts, "</CompleteMultipartUpload>"])
  end

  defp upload_id(xml) do
    [_, rest] = String.split(xml, "<UploadId>")
    [id, _] = String.split(rest, "</UploadId>")
    id
  end

  defp copy_part_etag(xml) do
    [_, rest] = String.split(xml, "<ETag>")
    [etag, _] = String.split(rest, "</ETag>")
    String.replace(etag, "&quot;", "\"")
  end

  defp clear_object_checksum!(bucket, key) do
    set_object_checksum!(bucket, key, %{})
  end

  defp set_object_checksum!(bucket, key, checksum) do
    {:ok, object} = Maxio.Objects.get_metadata(bucket, key)

    {:ok, _object} =
      Maxio.Objects.put_version_with_id(bucket, key, object.version_id, %{
        size: object.size,
        etag: object.etag,
        content_type: object.content_type,
        storage_class: object.storage_class || "STANDARD",
        metadata: object.metadata || %{},
        tags: object.tags || %{},
        checksum: checksum
      })

    meta_path = Path.join([@data_dir, bucket, key, "meta.json"])

    meta =
      meta_path
      |> File.read!()
      |> Sidecar.decode!()

    versions =
      Enum.map(meta["versions"], fn version ->
        if version["version_id"] == object.version_id do
          Map.put(version, "checksum", checksum)
        else
          version
        end
      end)

    meta_path
    |> File.write!(Jason.encode!(Map.put(meta, "versions", versions)))
  end

  defp hash_b64(algorithm, body), do: :crypto.hash(algorithm, body) |> Base.encode64()

  defp composite_hash_b64(algorithm, bodies) do
    bodies
    |> Enum.map(&:crypto.hash(algorithm, &1))
    |> IO.iodata_to_binary()
    |> then(&:crypto.hash(algorithm, &1))
    |> Base.encode64()
  end

  defp composite_crc32_b64(bodies) do
    bodies
    |> Enum.map(&:erlang.crc32/1)
    |> Enum.map(&<<&1::32>>)
    |> IO.iodata_to_binary()
    |> :erlang.crc32()
    |> then(&<<&1::32>>)
    |> Base.encode64()
  end

  defp composite_crc32c_b64(bodies) do
    bodies
    |> Enum.map(&crc32c_raw/1)
    |> IO.iodata_to_binary()
    |> crc32c_raw()
    |> Base.encode64()
  end

  defp composite_xxhash64_b64(bodies) do
    bodies
    |> Enum.map(&xxhash64_raw/1)
    |> IO.iodata_to_binary()
    |> xxhash64_raw()
    |> Base.encode64()
  end

  defp crc32_b64(body), do: <<:erlang.crc32(body)::32>> |> Base.encode64()

  defp crc64nvme_b64(iodata) do
    iodata
    |> IO.iodata_to_binary()
    |> crc64nvme_raw()
    |> Base.encode64()
  end

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
