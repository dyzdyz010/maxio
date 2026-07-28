defmodule Maxio.S3.MultipartIntegrationTest do
  use Maxio.DataCase, async: false

  import Plug.Conn
  alias Maxio.Test.SigV4Request
  alias Maxio.S3.{Endpoint, SSE}
  alias Maxio.Cluster.{Paths, ShardServer}
  alias Maxio.Cluster.Transport.InProcess

  @data_dir Path.join(System.tmp_dir!(), "maxio_mp_int_test")
  @all_users "http://acs.amazonaws.com/groups/global/AllUsers"

  setup do
    File.rm_rf(@data_dir)
    File.mkdir_p!(@data_dir)
    prev = Application.get_env(:maxio, :s3)
    Application.put_env(:maxio, :s3, Keyword.put(prev, :data_dir, @data_dir))
    Application.put_env(:maxio, :multipart_min_part_size, 1)

    on_exit(fn ->
      Application.put_env(:maxio, :s3, prev)
      Application.delete_env(:maxio, :multipart_min_part_size)
      File.rm_rf(@data_dir)
    end)

    :ok
  end

  defp call(conn), do: Endpoint.call(conn, Endpoint.init([]))

  defp create_acl_bucket(bucket) do
    SigV4Request.signed_conn(:put, "/#{bucket}",
      headers: [{"x-amz-object-ownership", "ObjectWriter"}]
    )
    |> call()
  end

  # 从 InitiateMultipartUploadResult 抠 UploadId（简单字符串切，无需 XML 解析依赖）
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

  defp sse_c_headers(customer_key) do
    [
      {"x-amz-server-side-encryption-customer-algorithm", "AES256"},
      {"x-amz-server-side-encryption-customer-key", Base.encode64(customer_key)},
      {"x-amz-server-side-encryption-customer-key-md5",
       :crypto.hash(:md5, customer_key) |> Base.encode64()}
    ]
  end

  defp copy_source_sse_c_headers(customer_key) do
    [
      {"x-amz-copy-source-server-side-encryption-customer-algorithm", "AES256"},
      {"x-amz-copy-source-server-side-encryption-customer-key", Base.encode64(customer_key)},
      {"x-amz-copy-source-server-side-encryption-customer-key-md5",
       :crypto.hash(:md5, customer_key) |> Base.encode64()}
    ]
  end

  defp initiate_upload(bucket, key, conn_fun \\ &SigV4Request.signed_conn/3) do
    init =
      conn_fun.(:post, "/#{bucket}/#{key}", query: %{"uploads" => ""})
      |> call()

    assert init.status == 200
    upload_id(init.resp_body)
  end

  defp complete_xml(etags) do
    parts =
      etags
      |> Enum.with_index(1)
      |> Enum.map(fn {etag, part_number} ->
        "<Part><PartNumber>#{part_number}</PartNumber><ETag>#{etag}</ETag></Part>"
      end)

    IO.iodata_to_binary(["<CompleteMultipartUpload>", parts, "</CompleteMultipartUpload>"])
  end

  defp complete_upload(
         bucket,
         key,
         upload_id,
         etags,
         headers \\ [],
         conn_fun \\ &SigV4Request.signed_conn/3
       ) do
    complete_xml = complete_xml(etags)

    conn_fun.(:post, "/#{bucket}/#{key}",
      query: %{"uploadId" => upload_id},
      body: complete_xml,
      headers: headers
    )
    |> call()
  end

  defp md5_b64(body), do: :crypto.hash(:md5, body) |> Base.encode64()

  defp enable_versioning(bucket) do
    body = ~s(<VersioningConfiguration><Status>Enabled</Status></VersioningConfiguration>)

    SigV4Request.signed_conn(:put, "/#{bucket}", query: %{"versioning" => ""}, body: body)
    |> call()
  end

  defp suspend_versioning(bucket) do
    body = ~s(<VersioningConfiguration><Status>Suspended</Status></VersioningConfiguration>)

    SigV4Request.signed_conn(:put, "/#{bucket}", query: %{"versioning" => ""}, body: body)
    |> call()
  end

  defp complete_single_part(bucket, key, body, headers \\ []) do
    {uid, etag} = stage_single_part(bucket, key, body, headers)
    complete = complete_upload(bucket, key, uid, [etag])

    assert complete.status == 200
    complete
  end

  defp stage_single_part(bucket, key, body, headers \\ []) do
    init =
      SigV4Request.signed_conn(:post, "/#{bucket}/#{key}",
        query: %{"uploads" => ""},
        headers: headers
      )
      |> call()

    assert init.status == 200
    uid = upload_id(init.resp_body)

    upload_part =
      SigV4Request.signed_conn(:put, "/#{bucket}/#{key}",
        query: %{"partNumber" => "1", "uploadId" => uid},
        body: body
      )
      |> call()

    assert upload_part.status == 200
    [etag] = get_resp_header(upload_part, "etag")
    {uid, etag}
  end

  defp lock_resource(bucket, key) do
    parent = self()
    resource = {bucket, key}

    pid =
      spawn(fn ->
        {:ok, lease} = Maxio.Cluster.Lock.acquire(resource, nodes: [Node.self()], refresh: false)
        send(parent, {:locked, self()})

        receive do
          :release -> Maxio.Cluster.Lock.release(lease)
        end
      end)

    assert_receive {:locked, ^pid}
    on_exit(fn -> send(pid, :release) end)
    pid
  end

  defp with_sidecar_read_quorum_env(fun) do
    InProcess.setup!()

    prev_auth = Application.get_env(:maxio, :authoritative_source)
    prev_tx = Application.get_env(:maxio, :shard_transport)
    prev_ec = Application.get_env(:maxio, :erasure)

    prev_topology =
      try do
        {:ok, :persistent_term.get({Maxio.Cluster.Topology, :topology})}
      rescue
        ArgumentError -> :error
      end

    Application.put_env(:maxio, :authoritative_source, read: :sidecar, list: :pg, write: :pg)
    Application.put_env(:maxio, :shard_transport, InProcess)

    Application.put_env(:maxio, :erasure,
      drives: ["d0", "d1", "d2"],
      data_shards: 2,
      parity_shards: 1,
      block_size: 1024
    )

    eps =
      for i <- 0..2,
          do:
            {:"mpcondrq#{i}",
             Path.join(System.tmp_dir!(), "mp_cond_rq_#{i}_#{System.unique_integer([:positive])}")}

    topo = %{
      data_shards: 2,
      parity_shards: 1,
      block_size: 1024,
      sets: %{0 => %{id: 0, endpoints: eps}},
      set_ids: [0]
    }

    :persistent_term.put({Maxio.Cluster.Topology, :topology}, topo)

    on_exit(fn ->
      case prev_topology do
        {:ok, topology} -> :persistent_term.put({Maxio.Cluster.Topology, :topology}, topology)
        :error -> :persistent_term.erase({Maxio.Cluster.Topology, :topology})
      end

      restore_env(:authoritative_source, prev_auth)
      restore_env(:shard_transport, prev_tx)
      restore_env(:erasure, prev_ec)
      Enum.each(eps, fn {_node, dir} -> File.rm_rf(dir) end)
    end)

    fun.(eps)
  end

  defp restore_env(key, nil), do: Application.delete_env(:maxio, key)
  defp restore_env(key, value), do: Application.put_env(:maxio, key, value)

  test "Create→UploadPart x2→Complete→GET 取回完整对象 + multipart ETag(-2)" do
    SigV4Request.signed_conn(:put, "/mpbk") |> call()

    init =
      SigV4Request.signed_conn(:post, "/mpbk/big.bin", query: %{"uploads" => ""})
      |> call()

    assert init.status == 200
    uid = upload_id(init.resp_body)

    p1body = "PART-ONE-DATA"
    p2body = "PART-TWO!"

    up1 =
      SigV4Request.signed_conn(:put, "/mpbk/big.bin",
        query: %{"partNumber" => "1", "uploadId" => uid},
        body: p1body
      )
      |> call()

    assert up1.status == 200
    [etag1] = get_resp_header(up1, "etag")

    up2 =
      SigV4Request.signed_conn(:put, "/mpbk/big.bin",
        query: %{"partNumber" => "2", "uploadId" => uid},
        body: p2body
      )
      |> call()

    assert up2.status == 200
    [etag2] = get_resp_header(up2, "etag")

    complete_xml =
      "<CompleteMultipartUpload>" <>
        "<Part><PartNumber>1</PartNumber><ETag>#{etag1}</ETag></Part>" <>
        "<Part><PartNumber>2</PartNumber><ETag>#{etag2}</ETag></Part>" <>
        "</CompleteMultipartUpload>"

    complete =
      SigV4Request.signed_conn(:post, "/mpbk/big.bin",
        query: %{"uploadId" => uid},
        body: complete_xml
      )
      |> call()

    assert complete.status == 200
    assert complete.resp_body =~ "<ETag>"
    assert complete.resp_body =~ "-2&quot;</ETag>" or complete.resp_body =~ ~s(-2"</ETag>)
    assert get_resp_header(complete, "x-amz-version-id") == []

    get = SigV4Request.signed_conn(:get, "/mpbk/big.bin") |> call()
    assert get.status == 200
    assert get.resp_body == p1body <> p2body

    assert {:ok, null_row} = Maxio.Objects.get_version("mpbk", "big.bin", "null")
    assert null_row.is_latest == true
  end

  test "CompleteMultipartUpload validates XML Content-MD5 before commit and keeps upload retryable" do
    bucket = "mpcmd5"
    key = "object.bin"
    body = "multipart content md5"

    SigV4Request.signed_conn(:put, "/#{bucket}") |> call()
    {uid, etag} = stage_single_part(bucket, key, body)
    xml = complete_xml([etag])

    rejected =
      SigV4Request.signed_conn(:post, "/#{bucket}/#{key}",
        query: %{"uploadId" => uid},
        body: xml,
        headers: [{"content-md5", md5_b64("different xml")}]
      )
      |> call()

    assert rejected.status == 400
    assert rejected.resp_body =~ "<Code>BadDigest</Code>"

    missing = SigV4Request.signed_conn(:get, "/#{bucket}/#{key}") |> call()
    assert missing.status == 404

    retry =
      SigV4Request.signed_conn(:post, "/#{bucket}/#{key}",
        query: %{"uploadId" => uid},
        body: xml,
        headers: [{"content-md5", md5_b64(xml)}]
      )
      |> call()

    assert retry.status == 200

    get = SigV4Request.signed_conn(:get, "/#{bucket}/#{key}") |> call()
    assert get.status == 200
    assert get.resp_body == body
  end

  test "CreateMultipartUpload x-amz-tagging persists to completed object tags" do
    bucket = "mptagged"
    key = "tagged.bin"

    SigV4Request.signed_conn(:put, "/#{bucket}") |> call()

    {uid, etag} =
      stage_single_part(bucket, key, "tagged body", [{"x-amz-tagging", "env=prod&team=storage"}])

    complete = complete_upload(bucket, key, uid, [etag])
    assert complete.status == 200

    get = SigV4Request.signed_conn(:get, "/#{bucket}/#{key}") |> call()
    assert get.status == 200
    assert get_resp_header(get, "x-amz-tagging-count") == ["2"]

    tagging =
      SigV4Request.signed_conn(:get, "/#{bucket}/#{key}", query: %{"tagging" => ""})
      |> call()

    assert tagging.status == 200
    assert tagging.resp_body =~ "<Key>env</Key>"
    assert tagging.resp_body =~ "<Value>prod</Value>"
    assert tagging.resp_body =~ "<Key>team</Key>"
    assert tagging.resp_body =~ "<Value>storage</Value>"

    assert {:ok, object} = Maxio.Objects.get_version(bucket, key, "null")
    assert object.tags == %{"env" => "prod", "team" => "storage"}
  end

  test "CreateMultipartUpload rejects invalid x-amz-tagging before creating upload row" do
    bucket = "mpbadtag"
    key = "bad.bin"

    SigV4Request.signed_conn(:put, "/#{bucket}") |> call()

    rejected =
      SigV4Request.signed_conn(:post, "/#{bucket}/#{key}",
        query: %{"uploads" => ""},
        headers: [{"x-amz-tagging", "aws:reserved=1"}]
      )
      |> call()

    assert rejected.status == 400
    assert rejected.resp_body =~ "<Code>InvalidTag</Code>"
    assert %{uploads: []} = Maxio.Multipart.list_uploads(bucket, %{prefix: key})
  end

  test "CompleteMultipartUpload If-None-Match star succeeds when the destination is absent" do
    bucket = "mpcondabsent"
    key = "object.bin"

    SigV4Request.signed_conn(:put, "/#{bucket}") |> call()
    {uid, etag} = stage_single_part(bucket, key, "new body")

    complete = complete_upload(bucket, key, uid, [etag], [{"if-none-match", "*"}])

    assert complete.status == 200

    get = SigV4Request.signed_conn(:get, "/#{bucket}/#{key}") |> call()
    assert get.status == 200
    assert get.resp_body == "new body"
  end

  test "CompleteMultipartUpload If-None-Match star fails when the destination exists and keeps upload retryable" do
    bucket = "mpcondnone"
    key = "object.bin"

    SigV4Request.signed_conn(:put, "/#{bucket}") |> call()

    old = SigV4Request.signed_conn(:put, "/#{bucket}/#{key}", body: "old body") |> call()
    assert old.status == 200

    {uid, etag} = stage_single_part(bucket, key, "new body")

    rejected = complete_upload(bucket, key, uid, [etag], [{"if-none-match", "*"}])

    assert rejected.status == 412
    assert rejected.resp_body =~ "<Code>PreconditionFailed</Code>"

    get_old = SigV4Request.signed_conn(:get, "/#{bucket}/#{key}") |> call()
    assert get_old.status == 200
    assert get_old.resp_body == "old body"

    retry = complete_upload(bucket, key, uid, [etag])
    assert retry.status == 200

    get_new = SigV4Request.signed_conn(:get, "/#{bucket}/#{key}") |> call()
    assert get_new.status == 200
    assert get_new.resp_body == "new body"
  end

  test "CompleteMultipartUpload If-Match requires the current destination ETag" do
    bucket = "mpcondmatch"
    key = "object.bin"

    SigV4Request.signed_conn(:put, "/#{bucket}") |> call()

    old = SigV4Request.signed_conn(:put, "/#{bucket}/#{key}", body: "old body") |> call()
    assert old.status == 200
    [old_etag] = get_resp_header(old, "etag")

    {uid, etag} = stage_single_part(bucket, key, "matched body")

    rejected = complete_upload(bucket, key, uid, [etag], [{"if-match", "\"not-current\""}])

    assert rejected.status == 412
    assert rejected.resp_body =~ "<Code>PreconditionFailed</Code>"

    get_old = SigV4Request.signed_conn(:get, "/#{bucket}/#{key}") |> call()
    assert get_old.status == 200
    assert get_old.resp_body == "old body"

    accepted = complete_upload(bucket, key, uid, [etag], [{"if-match", old_etag}])
    assert accepted.status == 200

    get_new = SigV4Request.signed_conn(:get, "/#{bucket}/#{key}") |> call()
    assert get_new.status == 200
    assert get_new.resp_body == "matched body"
  end

  test "CompleteMultipartUpload If-Match returns NoSuchKey when the destination is absent and keeps upload retryable" do
    bucket = "mpcondmatchabs"
    key = "object.bin"

    SigV4Request.signed_conn(:put, "/#{bucket}") |> call()
    {uid, etag} = stage_single_part(bucket, key, "matched body")

    rejected = complete_upload(bucket, key, uid, [etag], [{"if-match", "\"missing\""}])

    assert rejected.status == 404
    assert rejected.resp_body =~ "<Code>NoSuchKey</Code>"

    retry = complete_upload(bucket, key, uid, [etag])
    assert retry.status == 200

    get = SigV4Request.signed_conn(:get, "/#{bucket}/#{key}") |> call()
    assert get.status == 200
    assert get.resp_body == "matched body"
  end

  test "CompleteMultipartUpload If-None-Match star treats a current delete marker as absent" do
    bucket = "mpconddm"
    key = "object.bin"

    SigV4Request.signed_conn(:put, "/#{bucket}") |> call()
    assert enable_versioning(bucket).status == 200

    put = SigV4Request.signed_conn(:put, "/#{bucket}/#{key}", body: "deleted body") |> call()
    assert put.status == 200

    delete = SigV4Request.signed_conn(:delete, "/#{bucket}/#{key}") |> call()
    assert delete.status == 204
    assert get_resp_header(delete, "x-amz-delete-marker") == ["true"]

    {uid, etag} = stage_single_part(bucket, key, "new body")

    complete = complete_upload(bucket, key, uid, [etag], [{"if-none-match", "*"}])

    assert complete.status == 200
    assert [_version_id] = get_resp_header(complete, "x-amz-version-id")

    get = SigV4Request.signed_conn(:get, "/#{bucket}/#{key}") |> call()
    assert get.status == 200
    assert get.resp_body == "new body"
  end

  test "CompleteMultipartUpload If-Match returns NoSuchKey when current version is a delete marker and keeps upload retryable" do
    bucket = "mpcondmatchdm"
    key = "object.bin"

    SigV4Request.signed_conn(:put, "/#{bucket}") |> call()
    assert enable_versioning(bucket).status == 200

    put = SigV4Request.signed_conn(:put, "/#{bucket}/#{key}", body: "deleted body") |> call()
    assert put.status == 200

    delete = SigV4Request.signed_conn(:delete, "/#{bucket}/#{key}") |> call()
    assert delete.status == 204
    assert get_resp_header(delete, "x-amz-delete-marker") == ["true"]

    {uid, etag} = stage_single_part(bucket, key, "matched body")

    rejected = complete_upload(bucket, key, uid, [etag], [{"if-match", "\"deleted\""}])

    assert rejected.status == 404
    assert rejected.resp_body =~ "<Code>NoSuchKey</Code>"

    retry = complete_upload(bucket, key, uid, [etag])
    assert retry.status == 200

    get = SigV4Request.signed_conn(:get, "/#{bucket}/#{key}") |> call()
    assert get.status == 200
    assert get.resp_body == "matched body"
  end

  test "CompleteMultipartUpload conditional object-lock conflict maps to ConditionalRequestConflict and keeps upload retryable" do
    bucket = "mpcondlock"
    key = "object.bin"

    SigV4Request.signed_conn(:put, "/#{bucket}") |> call()
    {uid, etag} = stage_single_part(bucket, key, "new body")
    lock_pid = lock_resource(bucket, key)

    rejected = complete_upload(bucket, key, uid, [etag], [{"if-none-match", "*"}])

    assert rejected.status == 409
    assert rejected.resp_body =~ "<Code>ConditionalRequestConflict</Code>"

    ref = Process.monitor(lock_pid)
    send(lock_pid, :release)
    assert_receive {:DOWN, ^ref, :process, ^lock_pid, :normal}

    retry = complete_upload(bucket, key, uid, [etag])
    assert retry.status == 200

    get = SigV4Request.signed_conn(:get, "/#{bucket}/#{key}") |> call()
    assert get.status == 200
    assert get.resp_body == "new body"
  end

  test "CompleteMultipartUpload conditional read quorum failure maps to SlowDownRead and keeps upload retryable" do
    with_sidecar_read_quorum_env(fn eps ->
      bucket = "mpcondrq"
      key = "object.bin"

      SigV4Request.signed_conn(:put, "/#{bucket}") |> call()
      {uid, etag} = stage_single_part(bucket, key, "new body")

      obj_meta = %{
        "format" => "maxio/2",
        "versions" => [
          %{
            "version_id" => "null",
            "type" => "object",
            "is_latest" => true,
            "modtime" => 5,
            "generation" => 0,
            "etag" => "\"old\"",
            "size" => 3,
            "content_type" => "text/plain"
          }
        ]
      }

      [{_node, drive} | _] = eps
      {:ok, rel} = Paths.object_rel(bucket, key, "null")
      ShardServer.put_sidecar(Path.join(drive, rel), obj_meta)

      rejected = complete_upload(bucket, key, uid, [etag], [{"if-none-match", "*"}])

      assert rejected.status == 503
      assert rejected.resp_body =~ "<Code>SlowDownRead</Code>"

      retry = complete_upload(bucket, key, uid, [etag])
      assert retry.status == 200
    end)
  end

  test "UploadPartCopy copies a full source object as the part body" do
    bucket = "mpcopyfull"
    source_body = "server side multipart copy source"

    SigV4Request.signed_conn(:put, "/#{bucket}") |> call()
    SigV4Request.signed_conn(:put, "/#{bucket}/src.txt", body: source_body) |> call()
    uid = initiate_upload(bucket, "dst.txt")

    copy =
      SigV4Request.signed_conn(:put, "/#{bucket}/dst.txt",
        query: %{"partNumber" => "1", "uploadId" => uid},
        headers: [{"x-amz-copy-source", "/#{bucket}/src.txt"}]
      )
      |> call()

    assert copy.status == 200
    assert copy.resp_body =~ "<CopyPartResult"
    etag = copy_part_etag(copy.resp_body)

    complete = complete_upload(bucket, "dst.txt", uid, [etag])
    assert complete.status == 200

    get = SigV4Request.signed_conn(:get, "/#{bucket}/dst.txt") |> call()
    assert get.status == 200
    assert get.resp_body == source_body
  end

  test "UploadPartCopy encrypts copied part bytes for SSE-C target uploads" do
    bucket = "mpcopytargetssec"
    source_body = "source body copied into an encrypted multipart part"
    customer_key = :crypto.strong_rand_bytes(32)
    headers = sse_c_headers(customer_key)
    key_md5_b64 = :crypto.hash(:md5, customer_key) |> Base.encode64()

    SigV4Request.signed_conn(:put, "/#{bucket}") |> call()
    SigV4Request.signed_conn(:put, "/#{bucket}/src.txt", body: source_body) |> call()

    init =
      SigV4Request.signed_conn(:post, "/#{bucket}/dst.txt",
        query: %{"uploads" => ""},
        headers: headers
      )
      |> call()

    assert init.status == 200
    uid = upload_id(init.resp_body)
    {:ok, upload} = Maxio.Multipart.get_upload(bucket, "dst.txt", uid)

    missing_target_key =
      SigV4Request.signed_conn(:put, "/#{bucket}/dst.txt",
        query: %{"partNumber" => "1", "uploadId" => uid},
        headers: [{"x-amz-copy-source", "/#{bucket}/src.txt"}]
      )
      |> call()

    assert missing_target_key.status == 400
    assert Maxio.Multipart.list_parts(upload).parts == []

    copy =
      SigV4Request.signed_conn(:put, "/#{bucket}/dst.txt",
        query: %{"partNumber" => "1", "uploadId" => uid},
        headers: [{"x-amz-copy-source", "/#{bucket}/src.txt"} | headers]
      )
      |> call()

    assert copy.status == 200
    assert get_resp_header(copy, "x-amz-server-side-encryption-customer-algorithm") == ["AES256"]
    assert get_resp_header(copy, "x-amz-server-side-encryption-customer-key-md5") == [key_md5_b64]
    etag = copy_part_etag(copy.resp_body)
    assert [%{size: size}] = Maxio.Multipart.list_parts(upload).parts
    assert size == byte_size(source_body)

    part_ciphertext = File.read!(Path.join([@data_dir, ".uploads", bucket, uid, "1.part"]))
    refute part_ciphertext =~ source_body

    complete = complete_upload(bucket, "dst.txt", uid, [etag], headers)
    assert complete.status == 200

    assert get_resp_header(complete, "x-amz-server-side-encryption-customer-key-md5") == [
             key_md5_b64
           ]

    missing_get = SigV4Request.signed_conn(:get, "/#{bucket}/dst.txt") |> call()
    assert missing_get.status == 400

    get =
      SigV4Request.signed_conn(:get, "/#{bucket}/dst.txt", headers: headers)
      |> call()

    assert get.status == 200
    assert get.resp_body == source_body
  end

  test "UploadPartCopy requires matching SSE-C copy-source key before copying a part" do
    bucket = "mpcopysourcessec"
    source_body = "source body encrypted with a customer key"
    source_key = :crypto.strong_rand_bytes(32)

    SigV4Request.signed_conn(:put, "/#{bucket}") |> call()

    put =
      SigV4Request.signed_conn(:put, "/#{bucket}/src.txt",
        body: source_body,
        headers: sse_c_headers(source_key)
      )
      |> call()

    assert put.status == 200
    uid = initiate_upload(bucket, "dst.txt")
    {:ok, upload} = Maxio.Multipart.get_upload(bucket, "dst.txt", uid)

    missing_source_key =
      SigV4Request.signed_conn(:put, "/#{bucket}/dst.txt",
        query: %{"partNumber" => "1", "uploadId" => uid},
        headers: [{"x-amz-copy-source", "/#{bucket}/src.txt"}]
      )
      |> call()

    assert missing_source_key.status == 400
    assert missing_source_key.resp_body =~ "<Code>InvalidArgument</Code>"
    assert Maxio.Multipart.list_parts(upload).parts == []

    wrong_source_key =
      SigV4Request.signed_conn(:put, "/#{bucket}/dst.txt",
        query: %{"partNumber" => "1", "uploadId" => uid},
        headers: [
          {"x-amz-copy-source", "/#{bucket}/src.txt"}
          | copy_source_sse_c_headers(:crypto.strong_rand_bytes(32))
        ]
      )
      |> call()

    assert wrong_source_key.status == 400
    assert wrong_source_key.resp_body =~ "<Code>InvalidArgument</Code>"
    assert Maxio.Multipart.list_parts(upload).parts == []

    copy =
      SigV4Request.signed_conn(:put, "/#{bucket}/dst.txt",
        query: %{"partNumber" => "1", "uploadId" => uid},
        headers: [
          {"x-amz-copy-source", "/#{bucket}/src.txt"}
          | copy_source_sse_c_headers(source_key)
        ]
      )
      |> call()

    assert copy.status == 200
    etag = copy_part_etag(copy.resp_body)
    assert [%{size: size}] = Maxio.Multipart.list_parts(upload).parts
    assert size == byte_size(source_body)
    assert File.read!(Path.join([@data_dir, ".uploads", bucket, uid, "1.part"])) == source_body

    complete = complete_upload(bucket, "dst.txt", uid, [etag])
    assert complete.status == 200

    get = SigV4Request.signed_conn(:get, "/#{bucket}/dst.txt") |> call()
    assert get.status == 200
    assert get.resp_body == source_body
  end

  test "UploadPartCopy decrypts SSE-KMS source into SSE-KMS multipart target" do
    bucket = "mpcopykms"
    source_body = "source body encrypted with a local KMS data key"
    source_key_id = "arn:aws:kms:us-east-1:000000000000:key/mp-copy-source"
    target_key_id = "arn:aws:kms:us-east-1:000000000000:key/mp-copy-target"

    SigV4Request.signed_conn(:put, "/#{bucket}") |> call()

    put_source =
      SigV4Request.signed_conn(:put, "/#{bucket}/src.txt",
        body: source_body,
        headers: [
          {"x-amz-server-side-encryption", "aws:kms"},
          {"x-amz-server-side-encryption-aws-kms-key-id", source_key_id}
        ]
      )
      |> call()

    assert put_source.status == 200

    init =
      SigV4Request.signed_conn(:post, "/#{bucket}/dst.txt",
        query: %{"uploads" => ""},
        headers: [
          {"x-amz-server-side-encryption", "aws:kms"},
          {"x-amz-server-side-encryption-aws-kms-key-id", target_key_id}
        ]
      )
      |> call()

    assert init.status == 200
    uid = upload_id(init.resp_body)

    copy =
      SigV4Request.signed_conn(:put, "/#{bucket}/dst.txt",
        query: %{"partNumber" => "1", "uploadId" => uid},
        headers: [{"x-amz-copy-source", "/#{bucket}/src.txt"}]
      )
      |> call()

    assert copy.status == 200
    assert get_resp_header(copy, "x-amz-server-side-encryption") == ["aws:kms"]

    assert get_resp_header(copy, "x-amz-server-side-encryption-aws-kms-key-id") == [
             target_key_id
           ]

    etag = copy_part_etag(copy.resp_body)
    part_on_disk = File.read!(Path.join([@data_dir, ".uploads", bucket, uid, "1.part"]))
    refute part_on_disk == source_body
    refute part_on_disk =~ source_body

    complete = complete_upload(bucket, "dst.txt", uid, [etag])
    assert complete.status == 200
    assert get_resp_header(complete, "x-amz-server-side-encryption") == ["aws:kms"]

    assert get_resp_header(complete, "x-amz-server-side-encryption-aws-kms-key-id") == [
             target_key_id
           ]

    get = SigV4Request.signed_conn(:get, "/#{bucket}/dst.txt") |> call()
    assert get.status == 200
    assert get.resp_body == source_body
    assert get_resp_header(get, "x-amz-server-side-encryption") == ["aws:kms"]

    {:ok, dst} = Maxio.Objects.get_metadata(bucket, "dst.txt")
    assert dst.sse_algorithm == "aws:kms"
    assert dst.sse_envelope["kms_key_id"] == target_key_id

    on_disk = File.read!(Path.join([@data_dir, bucket, "dst.txt", "part.0"]))
    refute on_disk =~ source_body
  end

  test "CreateMultipartUpload aws:kms:dsse encrypts regular UploadPart metadata and final ObjectParts" do
    bucket = "mpdsseupload"
    key = "regular.txt"
    body = "regular DSSE multipart body"
    target_key_id = "arn:aws:kms:us-east-1:000000000000:key/mp-dsse-regular"

    SigV4Request.signed_conn(:put, "/#{bucket}") |> call()

    init =
      SigV4Request.signed_conn(:post, "/#{bucket}/#{key}",
        query: %{"uploads" => ""},
        headers: [
          {"x-amz-server-side-encryption", "aws:kms:dsse"},
          {"x-amz-server-side-encryption-aws-kms-key-id", target_key_id}
        ]
      )
      |> call()

    assert init.status == 200
    assert get_resp_header(init, "x-amz-server-side-encryption") == ["aws:kms:dsse"]
    uid = upload_id(init.resp_body)
    {:ok, upload} = Maxio.Multipart.get_upload(bucket, key, uid)

    upload_part =
      SigV4Request.signed_conn(:put, "/#{bucket}/#{key}",
        query: %{"partNumber" => "1", "uploadId" => uid},
        body: body
      )
      |> call()

    assert upload_part.status == 200
    assert [part_checksum] = get_resp_header(upload_part, "x-amz-checksum-crc64nvme")
    [etag] = get_resp_header(upload_part, "etag")

    assert %Maxio.Multipart.Part{checksum: stored_part_checksum} =
             Maxio.Repo.get_by(Maxio.Multipart.Part,
               upload_id: upload.id,
               part_number: 1
             )

    assert is_map(stored_part_checksum["__maxio_dsse_encrypted_checksum"])
    refute Map.has_key?(stored_part_checksum, "ChecksumCRC64NVME")

    parts =
      SigV4Request.signed_conn(:get, "/#{bucket}/#{key}", query: %{"uploadId" => uid})
      |> call()

    assert parts.status == 200
    assert parts.resp_body =~ "<ChecksumCRC64NVME>#{part_checksum}</ChecksumCRC64NVME>"

    complete = complete_upload(bucket, key, uid, [etag])
    assert complete.status == 200
    assert get_resp_header(complete, "x-amz-server-side-encryption") == ["aws:kms:dsse"]
    assert complete.resp_body =~ "<ChecksumCRC64NVME>"
    assert complete.resp_body =~ "<ChecksumType>FULL_OBJECT</ChecksumType>"

    get = SigV4Request.signed_conn(:get, "/#{bucket}/#{key}") |> call()
    assert get.status == 200
    assert get.resp_body == body

    {:ok, object} = Maxio.Objects.get_metadata(bucket, key)
    assert object.sse_algorithm == "aws:kms:dsse"
    assert is_map(object.checksum["__maxio_dsse_encrypted_checksum"])
    assert is_map(object.object_parts["__maxio_dsse_encrypted_object_parts"])
    refute Map.has_key?(object.object_parts, "Parts")

    visible_object_parts = SSE.visible_object_parts(object)
    assert [visible_part] = visible_object_parts["Parts"]
    assert visible_part["ChecksumCRC64NVME"] == part_checksum

    attrs =
      SigV4Request.signed_conn(:get, "/#{bucket}/#{key}",
        query: %{"attributes" => ""},
        headers: [{"x-amz-object-attributes", "Checksum,ObjectParts"}]
      )
      |> call()

    assert attrs.status == 200
    assert attrs.resp_body =~ "<ChecksumCRC64NVME>#{part_checksum}</ChecksumCRC64NVME>"

    on_disk = File.read!(Path.join([@data_dir, bucket, key, "part.0"]))
    refute on_disk =~ body
  end

  test "UploadPartCopy decrypts DSSE-KMS source into DSSE-KMS multipart target" do
    bucket = "mpcopydsse"
    source_body = "source body encrypted with two local KMS data keys"
    source_key_id = "arn:aws:kms:us-east-1:000000000000:key/mp-dsse-source"
    target_key_id = "arn:aws:kms:us-east-1:000000000000:key/mp-dsse-target"

    SigV4Request.signed_conn(:put, "/#{bucket}") |> call()

    put_source =
      SigV4Request.signed_conn(:put, "/#{bucket}/src.txt",
        body: source_body,
        headers: [
          {"x-amz-server-side-encryption", "aws:kms:dsse"},
          {"x-amz-server-side-encryption-aws-kms-key-id", source_key_id}
        ]
      )
      |> call()

    assert put_source.status == 200
    assert [source_checksum] = get_resp_header(put_source, "x-amz-checksum-crc64nvme")

    init =
      SigV4Request.signed_conn(:post, "/#{bucket}/dst.txt",
        query: %{"uploads" => ""},
        headers: [
          {"x-amz-server-side-encryption", "aws:kms:dsse"},
          {"x-amz-server-side-encryption-aws-kms-key-id", target_key_id}
        ]
      )
      |> call()

    assert init.status == 200
    assert get_resp_header(init, "x-amz-server-side-encryption") == ["aws:kms:dsse"]
    uid = upload_id(init.resp_body)
    {:ok, upload} = Maxio.Multipart.get_upload(bucket, "dst.txt", uid)
    assert upload.sse_algorithm == "aws:kms:dsse"
    assert upload.sse_envelope["mode"] == "DSSE-KMS"

    copy =
      SigV4Request.signed_conn(:put, "/#{bucket}/dst.txt",
        query: %{"partNumber" => "1", "uploadId" => uid},
        headers: [{"x-amz-copy-source", "/#{bucket}/src.txt"}]
      )
      |> call()

    assert copy.status == 200
    assert get_resp_header(copy, "x-amz-server-side-encryption") == ["aws:kms:dsse"]
    assert copy.resp_body =~ "<ChecksumCRC64NVME>#{source_checksum}</ChecksumCRC64NVME>"

    assert get_resp_header(copy, "x-amz-server-side-encryption-aws-kms-key-id") == [
             target_key_id
           ]

    etag = copy_part_etag(copy.resp_body)

    assert %Maxio.Multipart.Part{checksum: stored_part_checksum} =
             Maxio.Repo.get_by(Maxio.Multipart.Part,
               upload_id: upload.id,
               part_number: 1
             )

    assert is_map(stored_part_checksum["__maxio_dsse_encrypted_checksum"])
    refute Map.has_key?(stored_part_checksum, "ChecksumCRC64NVME")

    parts =
      SigV4Request.signed_conn(:get, "/#{bucket}/dst.txt", query: %{"uploadId" => uid})
      |> call()

    assert parts.status == 200
    assert parts.resp_body =~ "<ChecksumCRC64NVME>#{source_checksum}</ChecksumCRC64NVME>"

    part_on_disk = File.read!(Path.join([@data_dir, ".uploads", bucket, uid, "1.part"]))
    refute part_on_disk == source_body
    refute part_on_disk =~ source_body

    complete = complete_upload(bucket, "dst.txt", uid, [etag])
    assert complete.status == 200
    assert get_resp_header(complete, "x-amz-server-side-encryption") == ["aws:kms:dsse"]
    assert complete.resp_body =~ "<ChecksumCRC64NVME>"
    assert complete.resp_body =~ "<ChecksumType>FULL_OBJECT</ChecksumType>"

    assert get_resp_header(complete, "x-amz-server-side-encryption-aws-kms-key-id") == [
             target_key_id
           ]

    get = SigV4Request.signed_conn(:get, "/#{bucket}/dst.txt") |> call()
    assert get.status == 200
    assert get.resp_body == source_body
    assert get_resp_header(get, "x-amz-server-side-encryption") == ["aws:kms:dsse"]

    {:ok, dst} = Maxio.Objects.get_metadata(bucket, "dst.txt")
    assert dst.sse_algorithm == "aws:kms:dsse"
    assert dst.sse_envelope["mode"] == "DSSE-KMS"
    assert dst.sse_envelope["kms_key_id"] == target_key_id
    assert is_map(dst.sse_envelope["dsse_inner"])
    assert is_map(dst.sse_envelope["dsse_outer"])
    assert is_map(dst.checksum["__maxio_dsse_encrypted_checksum"])
    assert is_map(dst.object_parts["__maxio_dsse_encrypted_object_parts"])
    refute Map.has_key?(dst.checksum, "ChecksumCRC64NVME")
    refute Map.has_key?(dst.object_parts, "Parts")

    visible_checksum = SSE.visible_checksum_metadata(dst)
    assert visible_checksum["ChecksumType"] == "FULL_OBJECT"
    assert is_binary(visible_checksum["ChecksumCRC64NVME"])

    visible_object_parts = SSE.visible_object_parts(dst)
    assert [visible_part] = visible_object_parts["Parts"]
    assert visible_part["ChecksumCRC64NVME"] == source_checksum

    attrs =
      SigV4Request.signed_conn(:get, "/#{bucket}/dst.txt",
        query: %{"attributes" => ""},
        headers: [{"x-amz-object-attributes", "Checksum,ObjectParts"}]
      )
      |> call()

    assert attrs.status == 200

    assert attrs.resp_body =~
             "<ChecksumCRC64NVME>#{visible_checksum["ChecksumCRC64NVME"]}</ChecksumCRC64NVME>"

    assert attrs.resp_body =~ "<ChecksumCRC64NVME>#{source_checksum}</ChecksumCRC64NVME>"
    assert attrs.resp_body =~ "<ChecksumType>FULL_OBJECT</ChecksumType>"

    on_disk = File.read!(Path.join([@data_dir, bucket, "dst.txt", "part.0"]))
    refute on_disk =~ source_body
  end

  test "UploadPartCopy preserves encoded question marks in the source key" do
    bucket = "mpcopyqmark"
    source_body = "source key contains a question mark"

    SigV4Request.signed_conn(:put, "/#{bucket}") |> call()
    SigV4Request.signed_conn(:put, "/#{bucket}/a%3Fb.txt", body: source_body) |> call()
    uid = initiate_upload(bucket, "dst.txt")

    copy =
      SigV4Request.signed_conn(:put, "/#{bucket}/dst.txt",
        query: %{"partNumber" => "1", "uploadId" => uid},
        headers: [{"x-amz-copy-source", "/#{bucket}/a%3Fb.txt"}]
      )
      |> call()

    assert copy.status == 200
    etag = copy_part_etag(copy.resp_body)
    assert complete_upload(bucket, "dst.txt", uid, [etag]).status == 200

    get = SigV4Request.signed_conn(:get, "/#{bucket}/dst.txt") |> call()
    assert get.status == 200
    assert get.resp_body == source_body
  end

  test "UploadPartCopy source If-Modified-Since failure returns PreconditionFailed" do
    bucket = "mpcopyims"

    SigV4Request.signed_conn(:put, "/#{bucket}") |> call()
    SigV4Request.signed_conn(:put, "/#{bucket}/src.txt", body: "conditional source") |> call()
    uid = initiate_upload(bucket, "dst.txt")

    copy =
      SigV4Request.signed_conn(:put, "/#{bucket}/dst.txt",
        query: %{"partNumber" => "1", "uploadId" => uid},
        headers: [
          {"x-amz-copy-source", "/#{bucket}/src.txt"},
          {"x-amz-copy-source-if-modified-since", "Wed, 30 Nov 2099 00:00:00 GMT"}
        ]
      )
      |> call()

    assert copy.status == 412
    assert copy.resp_body =~ "<Code>PreconditionFailed</Code>"
  end

  test "UploadPartCopy copies the requested byte range from a large source object" do
    bucket = "mpcopyrange"
    prefix = String.duplicate("a", 5_242_880)
    source_body = prefix <> "RANGE-OK" <> String.duplicate("z", 16)

    SigV4Request.signed_conn(:put, "/#{bucket}") |> call()
    SigV4Request.signed_conn(:put, "/#{bucket}/src.bin", body: source_body) |> call()
    uid = initiate_upload(bucket, "dst.bin")

    first = byte_size(prefix)
    last = first + byte_size("RANGE-OK") - 1

    copy =
      SigV4Request.signed_conn(:put, "/#{bucket}/dst.bin",
        query: %{"partNumber" => "1", "uploadId" => uid},
        headers: [
          {"x-amz-copy-source", "/#{bucket}/src.bin"},
          {"x-amz-copy-source-range", "bytes=#{first}-#{last}"}
        ]
      )
      |> call()

    assert copy.status == 200
    etag = copy_part_etag(copy.resp_body)
    assert complete_upload(bucket, "dst.bin", uid, [etag]).status == 200

    get = SigV4Request.signed_conn(:get, "/#{bucket}/dst.bin") |> call()
    assert get.status == 200
    assert get.resp_body == "RANGE-OK"
  end

  test "UploadPartCopy can copy a specific source version and echoes its version id" do
    bucket = "mpcopyversion"

    SigV4Request.signed_conn(:put, "/#{bucket}") |> call()
    assert enable_versioning(bucket).status == 200

    put1 = SigV4Request.signed_conn(:put, "/#{bucket}/src.txt", body: "old-version") |> call()
    assert [vid1] = get_resp_header(put1, "x-amz-version-id")

    put2 = SigV4Request.signed_conn(:put, "/#{bucket}/src.txt", body: "new-version") |> call()
    assert [_vid2] = get_resp_header(put2, "x-amz-version-id")

    uid = initiate_upload(bucket, "dst.txt")

    copy =
      SigV4Request.signed_conn(:put, "/#{bucket}/dst.txt",
        query: %{"partNumber" => "1", "uploadId" => uid},
        headers: [{"x-amz-copy-source", "/#{bucket}/src.txt?versionId=#{vid1}"}]
      )
      |> call()

    assert copy.status == 200
    assert get_resp_header(copy, "x-amz-copy-source-version-id") == [vid1]
    etag = copy_part_etag(copy.resp_body)
    assert complete_upload(bucket, "dst.txt", uid, [etag]).status == 200

    get = SigV4Request.signed_conn(:get, "/#{bucket}/dst.txt") |> call()
    assert get.status == 200
    assert get.resp_body == "old-version"
  end

  test "UploadPartCopy requires source read permission in addition to target write permission" do
    bucket = "mpcopyauth"

    SigV4Request.signed_conn(:put, "/#{bucket}") |> call()
    SigV4Request.signed_conn(:put, "/#{bucket}/src.txt", body: "private source") |> call()

    policy =
      ~s({"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":"*","Action":"s3:PutObject","Resource":"arn:aws:s3:::#{bucket}/dst.txt"}]})

    SigV4Request.signed_conn(:put, "/#{bucket}", query: %{"policy" => ""}, body: policy)
    |> call()

    uid = initiate_upload(bucket, "dst.txt")

    copy =
      SigV4Request.anon_conn(:put, "/#{bucket}/dst.txt",
        query: %{"partNumber" => "1", "uploadId" => uid},
        headers: [{"x-amz-copy-source", "/#{bucket}/src.txt"}]
      )
      |> call()

    assert copy.status == 403
    assert copy.resp_body =~ "<Code>AccessDenied</Code>"
  end

  test "CompleteMultipartUpload 在 Enabled 桶中创建独立对象版本并回 x-amz-version-id" do
    bucket = "mpverb"
    key = "big.bin"

    SigV4Request.signed_conn(:put, "/#{bucket}") |> call()
    assert enable_versioning(bucket).status == 200

    first = complete_single_part(bucket, key, "first multipart body")
    assert [vid1] = get_resp_header(first, "x-amz-version-id")
    assert vid1 != "null"

    second = complete_single_part(bucket, key, "second multipart body")
    assert [vid2] = get_resp_header(second, "x-amz-version-id")
    assert vid2 != "null"
    assert vid2 != vid1

    latest = SigV4Request.signed_conn(:get, "/#{bucket}/#{key}") |> call()
    assert latest.status == 200
    assert latest.resp_body == "second multipart body"
    assert get_resp_header(latest, "x-amz-version-id") == [vid2]

    old =
      SigV4Request.signed_conn(:get, "/#{bucket}/#{key}", query: %{"versionId" => vid1})
      |> call()

    assert old.status == 200
    assert old.resp_body == "first multipart body"
    assert get_resp_header(old, "x-amz-version-id") == [vid1]

    assert {:ok, old_row} = Maxio.Objects.get_version(bucket, key, vid1)
    assert old_row.is_latest == false
    assert {:ok, latest_row} = Maxio.Objects.get_version(bucket, key, vid2)
    assert latest_row.is_latest == true
  end

  test "CompleteMultipartUpload 在 Suspended 桶中继续写 null 版本且不回 version header" do
    bucket = "mpversusp"
    key = "big.bin"

    SigV4Request.signed_conn(:put, "/#{bucket}") |> call()
    assert suspend_versioning(bucket).status == 200

    first = complete_single_part(bucket, key, "first suspended body")
    assert get_resp_header(first, "x-amz-version-id") == []

    second = complete_single_part(bucket, key, "second suspended body")
    assert get_resp_header(second, "x-amz-version-id") == []

    latest = SigV4Request.signed_conn(:get, "/#{bucket}/#{key}") |> call()
    assert latest.status == 200
    assert latest.resp_body == "second suspended body"
    assert get_resp_header(latest, "x-amz-version-id") == []

    assert {:ok, null_row} = Maxio.Objects.get_version(bucket, key, "null")
    assert null_row.is_latest == true
    assert null_row.size == byte_size("second suspended body")
  end

  test "CompleteMultipartUpload AES256 在 Enabled 桶中写加密的非 null 版本" do
    bucket = "mpversse"
    key = "sse.bin"
    plain = "versioned multipart sse body"

    SigV4Request.signed_conn(:put, "/#{bucket}") |> call()
    assert enable_versioning(bucket).status == 200

    complete =
      complete_single_part(bucket, key, plain, [{"x-amz-server-side-encryption", "AES256"}])

    assert get_resp_header(complete, "x-amz-server-side-encryption") == ["AES256"]
    assert [vid] = get_resp_header(complete, "x-amz-version-id")
    assert vid != "null"

    get =
      SigV4Request.signed_conn(:get, "/#{bucket}/#{key}", query: %{"versionId" => vid})
      |> call()

    assert get.status == 200
    assert get.resp_body == plain
    assert get_resp_header(get, "x-amz-version-id") == [vid]
    assert get_resp_header(get, "x-amz-server-side-encryption") == ["AES256"]

    assert {:ok, obj} = Maxio.Objects.get_version(bucket, key, vid)
    assert obj.sse_algorithm == "AES256"
    assert is_map(obj.sse_envelope)
    assert obj.size == byte_size(plain)

    on_disk = File.read!(Path.join([@data_dir, ".versions", bucket, key, vid, "part.0"]))
    refute on_disk =~ plain
    refute File.exists?(Path.join([@data_dir, bucket, key, "part.0"]))
  end

  test "Complete 引用不存在的 part → 400 InvalidPart" do
    SigV4Request.signed_conn(:put, "/mpbk2") |> call()
    init = SigV4Request.signed_conn(:post, "/mpbk2/o", query: %{"uploads" => ""}) |> call()
    uid = upload_id(init.resp_body)

    SigV4Request.signed_conn(:put, "/mpbk2/o",
      query: %{"partNumber" => "1", "uploadId" => uid},
      body: "x"
    )
    |> call()

    xml =
      "<CompleteMultipartUpload><Part><PartNumber>1</PartNumber><ETag>\"deadbeef\"</ETag></Part></CompleteMultipartUpload>"

    complete =
      SigV4Request.signed_conn(:post, "/mpbk2/o", query: %{"uploadId" => uid}, body: xml)
      |> call()

    assert complete.status == 400
    assert complete.resp_body =~ "<Code>InvalidPart</Code>"
  end

  test "malformed CompleteMultipartUpload XML does not commit object and remains retryable" do
    bucket = "mpbadxml"
    key = "object.bin"
    body = "retryable multipart body"

    SigV4Request.signed_conn(:put, "/#{bucket}") |> call()
    {uid, etag} = stage_single_part(bucket, key, body)

    malformed_xml =
      "<CompleteMultipartUpload><Part><PartNumber>1</PartNumber><ETag>#{etag}</ETag><ETag>#{etag}</ETag></Part></CompleteMultipartUpload>"

    malformed =
      SigV4Request.signed_conn(:post, "/#{bucket}/#{key}",
        query: %{"uploadId" => uid},
        body: malformed_xml
      )
      |> call()

    assert malformed.status == 400
    assert malformed.resp_body =~ "<Code>MalformedXML</Code>"

    missing = SigV4Request.signed_conn(:get, "/#{bucket}/#{key}") |> call()
    assert missing.status == 404

    parts =
      SigV4Request.signed_conn(:get, "/#{bucket}/#{key}", query: %{"uploadId" => uid}) |> call()

    assert parts.status == 200
    assert parts.resp_body =~ "<PartNumber>1</PartNumber>"

    retry = complete_upload(bucket, key, uid, [etag])
    assert retry.status == 200

    get = SigV4Request.signed_conn(:get, "/#{bucket}/#{key}") |> call()
    assert get.status == 200
    assert get.resp_body == body
  end

  test "AbortMultipartUpload → 204；之后 ListParts → 404 NoSuchUpload" do
    SigV4Request.signed_conn(:put, "/mpbk3") |> call()
    init = SigV4Request.signed_conn(:post, "/mpbk3/o", query: %{"uploads" => ""}) |> call()
    uid = upload_id(init.resp_body)

    abort = SigV4Request.signed_conn(:delete, "/mpbk3/o", query: %{"uploadId" => uid}) |> call()
    assert abort.status == 204

    lp = SigV4Request.signed_conn(:get, "/mpbk3/o", query: %{"uploadId" => uid}) |> call()
    assert lp.status == 404
    assert lp.resp_body =~ "<Code>NoSuchUpload</Code>"
  end

  test "ListParts 列出已上传分块" do
    SigV4Request.signed_conn(:put, "/mpbk4") |> call()
    init = SigV4Request.signed_conn(:post, "/mpbk4/o", query: %{"uploads" => ""}) |> call()
    uid = upload_id(init.resp_body)

    SigV4Request.signed_conn(:put, "/mpbk4/o",
      query: %{"partNumber" => "1", "uploadId" => uid},
      body: "aa"
    )
    |> call()

    SigV4Request.signed_conn(:put, "/mpbk4/o",
      query: %{"partNumber" => "2", "uploadId" => uid},
      body: "bb"
    )
    |> call()

    lp = SigV4Request.signed_conn(:get, "/mpbk4/o", query: %{"uploadId" => uid}) |> call()
    assert lp.status == 200
    assert lp.resp_body =~ "<PartNumber>1</PartNumber>"
    assert lp.resp_body =~ "<PartNumber>2</PartNumber>"
  end

  test "ListMultipartUploads 列出进行中上传" do
    SigV4Request.signed_conn(:put, "/mpbk5") |> call()
    SigV4Request.signed_conn(:post, "/mpbk5/aaa", query: %{"uploads" => ""}) |> call()
    SigV4Request.signed_conn(:post, "/mpbk5/bbb", query: %{"uploads" => ""}) |> call()

    lmu = SigV4Request.signed_conn(:get, "/mpbk5", query: %{"uploads" => ""}) |> call()
    assert lmu.status == 200
    assert lmu.resp_body =~ "<Key>aaa</Key>"
    assert lmu.resp_body =~ "<Key>bbb</Key>"
  end

  test "ListMultipartUploads delimiter pagination does not repeat a previous common prefix" do
    SigV4Request.signed_conn(:put, "/mpbkdelim") |> call()

    SigV4Request.signed_conn(:post, "/mpbkdelim/photos/2006/a.jpg", query: %{"uploads" => ""})
    |> call()

    SigV4Request.signed_conn(:post, "/mpbkdelim/photos/2006/b.jpg", query: %{"uploads" => ""})
    |> call()

    SigV4Request.signed_conn(:post, "/mpbkdelim/photos/2007/a.jpg", query: %{"uploads" => ""})
    |> call()

    first =
      SigV4Request.signed_conn(:get, "/mpbkdelim",
        query: %{
          "uploads" => "",
          "prefix" => "photos/",
          "delimiter" => "/",
          "max-uploads" => "1"
        }
      )
      |> call()

    assert first.status == 200
    assert first.resp_body =~ "<CommonPrefixes><Prefix>photos/2006/</Prefix></CommonPrefixes>"
    assert first.resp_body =~ "<NextKeyMarker>photos/2006/</NextKeyMarker>"
    assert first.resp_body =~ "<NextUploadIdMarker></NextUploadIdMarker>"

    second =
      SigV4Request.signed_conn(:get, "/mpbkdelim",
        query: %{
          "uploads" => "",
          "prefix" => "photos/",
          "delimiter" => "/",
          "max-uploads" => "1",
          "key-marker" => "photos/2006/"
        }
      )
      |> call()

    assert second.status == 200
    refute second.resp_body =~ "<CommonPrefixes><Prefix>photos/2006/</Prefix></CommonPrefixes>"
    assert second.resp_body =~ "<CommonPrefixes><Prefix>photos/2007/</Prefix></CommonPrefixes>"
  end

  test "ListMultipartUploads rejects max-uploads outside the S3 1..1000 range" do
    SigV4Request.signed_conn(:put, "/mpbklimits") |> call()

    zero =
      SigV4Request.signed_conn(:get, "/mpbklimits",
        query: %{"uploads" => "", "max-uploads" => "0"}
      )
      |> call()

    assert zero.status == 400
    assert zero.resp_body =~ "<Code>InvalidArgument</Code>"

    too_many =
      SigV4Request.signed_conn(:get, "/mpbklimits",
        query: %{"uploads" => "", "max-uploads" => "1001"}
      )
      |> call()

    assert too_many.status == 400
    assert too_many.resp_body =~ "<Code>InvalidArgument</Code>"
  end

  test "CompleteMultipartUpload SSE-C encrypts parts and final versioned object with boundary range support" do
    bucket = "mpverssec"
    key = "ssec.bin"
    customer_key = :crypto.strong_rand_bytes(32)
    headers = sse_c_headers(customer_key)
    key_md5_b64 = :crypto.hash(:md5, customer_key) |> Base.encode64()
    part1 = String.duplicate("a", 65_530) <> "P1-END!"
    part2 = "P2-START!" <> String.duplicate("b", 70_000)
    plain = part1 <> part2
    part1_size = byte_size(part1)

    SigV4Request.signed_conn(:put, "/#{bucket}") |> call()
    assert enable_versioning(bucket).status == 200

    init =
      SigV4Request.signed_conn(:post, "/#{bucket}/#{key}",
        query: %{"uploads" => ""},
        headers: headers
      )
      |> call()

    assert init.status == 200
    assert get_resp_header(init, "x-amz-server-side-encryption-customer-algorithm") == ["AES256"]
    assert get_resp_header(init, "x-amz-server-side-encryption-customer-key-md5") == [key_md5_b64]
    uid = upload_id(init.resp_body)
    {:ok, upload} = Maxio.Multipart.get_upload(bucket, key, uid)
    assert upload.sse_algorithm == "SSE-C"
    assert is_map(upload.sse_envelope)
    refute inspect(upload.sse_envelope) =~ Base.encode64(customer_key)

    missing_key =
      SigV4Request.signed_conn(:put, "/#{bucket}/#{key}",
        query: %{"partNumber" => "1", "uploadId" => uid},
        body: part1
      )
      |> call()

    assert missing_key.status == 400
    assert Maxio.Multipart.list_parts(upload).parts == []

    upload1 =
      SigV4Request.signed_conn(:put, "/#{bucket}/#{key}",
        query: %{"partNumber" => "1", "uploadId" => uid},
        body: part1,
        headers: headers
      )
      |> call()

    assert upload1.status == 200
    [etag1] = get_resp_header(upload1, "etag")
    assert [%{size: ^part1_size}] = Maxio.Multipart.list_parts(upload).parts

    part_ciphertext = File.read!(Path.join([@data_dir, ".uploads", bucket, uid, "1.part"]))
    refute part_ciphertext =~ "P1-END!"

    upload2 =
      SigV4Request.signed_conn(:put, "/#{bucket}/#{key}",
        query: %{"partNumber" => "2", "uploadId" => uid},
        body: part2,
        headers: headers
      )
      |> call()

    assert upload2.status == 200
    [etag2] = get_resp_header(upload2, "etag")

    rejected_complete = complete_upload(bucket, key, uid, [etag1, etag2])
    assert rejected_complete.status == 400
    assert {:ok, _upload} = Maxio.Multipart.get_upload(bucket, key, uid)
    assert {:error, :not_found} = Maxio.Objects.get_metadata(bucket, key)

    complete = complete_upload(bucket, key, uid, [etag1, etag2], headers)
    assert complete.status == 200

    assert get_resp_header(complete, "x-amz-server-side-encryption-customer-algorithm") == [
             "AES256"
           ]

    assert get_resp_header(complete, "x-amz-server-side-encryption-customer-key-md5") == [
             key_md5_b64
           ]

    assert [vid] = get_resp_header(complete, "x-amz-version-id")
    assert vid != "null"

    missing_get = SigV4Request.signed_conn(:get, "/#{bucket}/#{key}") |> call()
    assert missing_get.status == 400

    get =
      SigV4Request.signed_conn(:get, "/#{bucket}/#{key}",
        query: %{"versionId" => vid},
        headers: headers
      )
      |> call()

    assert get.status == 200
    assert get.resp_body == plain
    assert get_resp_header(get, "x-amz-server-side-encryption-customer-key-md5") == [key_md5_b64]

    range =
      SigV4Request.signed_conn(:get, "/#{bucket}/#{key}",
        query: %{"versionId" => vid},
        headers: [{"range", "bytes=65530-65545"} | headers]
      )
      |> call()

    assert range.status == 206
    assert range.resp_body == binary_part(plain, 65_530, 16)

    assert {:ok, obj} = Maxio.Objects.get_version(bucket, key, vid)
    assert obj.sse_algorithm == "SSE-C"
    assert is_map(obj.sse_envelope)
    assert obj.size == byte_size(plain)
    refute inspect(obj.sse_envelope) =~ Base.encode64(customer_key)

    on_disk = File.read!(Path.join([@data_dir, ".versions", bucket, key, vid, "part.0"]))
    refute on_disk =~ "P1-END!"
    refute File.exists?(Path.join([@data_dir, bucket, key, "part.0"]))
  end

  test "CreateMultipartUpload x-amz-grant-read persists to completed object ACL" do
    bucket = "mpacl"
    key = "granted.bin"

    create_acl_bucket(bucket)

    complete =
      complete_single_part(bucket, key, "multipart body", [
        {"x-amz-grant-read", ~s(uri="#{@all_users}")}
      ])

    assert complete.status == 200

    {:ok, obj} = Maxio.Objects.get_metadata(bucket, key)
    assert obj.acl_canned == "public-read"
    assert [%{"permission" => "READ"}] = obj.acl_grants["grants"]

    anon = SigV4Request.anon_conn(:get, "/#{bucket}/#{key}") |> call()
    assert anon.status == 200
    assert anon.resp_body == "multipart body"
  end
end
