defmodule Maxio.RouteBB62FSAuthorityTest do
  @moduledoc """
  ROUTE B B6-2 —— FS 单机在无全局 Topology 时通过 `FS.local_topology/1`
  翻 `:read/:list/:write = :sidecar` 的端到端取证。

  覆盖：

    * 真实签名 PutObject 写 FS obj-dir + maxio/2 sidecar 后，删除 PG 对象索引行，
      GET/HEAD/ListObjectsV2 仍从 sidecar 权威读回对象与富元数据；
    * Enabled 桶 DeleteObject 写 delete-marker sidecar，latest GET 被 marker 遮蔽，
      删除 marker version 后 latest 从盘上版本树恢复；
    * SSE-S3 对象在 FS local topology 下从 sidecar 读到 envelope 并透明解密。
  """
  use Maxio.DataCase, async: false

  import Plug.Conn, only: [get_resp_header: 2]

  alias Maxio.{Objects, ObjectMeta}
  alias Maxio.S3.Endpoint
  alias Maxio.Test.SigV4Request

  defp call(conn), do: Endpoint.call(conn, Endpoint.init([]))

  setup do
    data_dir =
      Path.join(System.tmp_dir!(), "maxio_b62fs_#{System.unique_integer([:positive])}")

    File.rm_rf(data_dir)
    File.mkdir_p!(data_dir)

    prev_s3 = Application.get_env(:maxio, :s3)
    prev_auth = Application.get_env(:maxio, :authoritative_source)
    prev_backend = Application.get_env(:maxio, :storage_backend)
    topo_key = {Maxio.Cluster.Topology, :topology}
    prev_topo = :persistent_term.get(topo_key, :__maxio_no_topology__)

    Application.put_env(:maxio, :s3, Keyword.put(prev_s3, :data_dir, data_dir))
    Application.put_env(:maxio, :storage_backend, Maxio.Storage.FS)

    Application.put_env(:maxio, :authoritative_source,
      read: :sidecar,
      list: :sidecar,
      write: :sidecar
    )

    :persistent_term.erase(topo_key)

    on_exit(fn ->
      Application.put_env(:maxio, :s3, prev_s3)
      Application.put_env(:maxio, :authoritative_source, prev_auth)
      Application.put_env(:maxio, :storage_backend, prev_backend)
      restore_topology(prev_topo)
      File.rm_rf(data_dir)
    end)

    assert ObjectMeta.effective_topology([]) == Maxio.Storage.FS.local_topology()

    {:ok, data_dir: data_dir}
  end

  test "PUT -> remove PG object row -> GET/HEAD/LIST still succeed from FS sidecar authority" do
    bucket = "rb62fs"
    key = "logs/2026/a.txt"
    body = "fs local topology body"

    assert SigV4Request.signed_conn(:put, "/#{bucket}") |> call() |> Map.fetch!(:status) == 200

    put =
      SigV4Request.signed_conn(:put, "/#{bucket}/#{key}",
        body: body,
        headers: [
          {"content-type", "text/plain"},
          {"x-amz-storage-class", "STANDARD_IA"},
          {"x-amz-meta-origin", "fs-local"},
          {"x-amz-tagging", "stage=canary&part=1"}
        ]
      )
      |> call()

    assert put.status == 200
    [etag] = get_resp_header(put, "etag")

    # Prove subsequent read/list cannot be satisfied by the PG object index.
    assert :ok = Objects.delete_metadata(bucket, key)
    assert {:error, :not_found} = Objects.get_metadata(bucket, key)

    get = SigV4Request.signed_conn(:get, "/#{bucket}/#{key}") |> call()
    assert get.status == 200
    assert get.resp_body == body
    assert get_resp_header(get, "content-type") == ["text/plain"]
    assert get_resp_header(get, "x-amz-storage-class") == ["STANDARD_IA"]
    assert get_resp_header(get, "x-amz-meta-origin") == ["fs-local"]
    assert get_resp_header(get, "x-amz-tagging-count") == ["2"]
    assert get_resp_header(get, "etag") == [etag]

    head = SigV4Request.signed_conn(:head, "/#{bucket}/#{key}") |> call()
    assert head.status == 200
    assert get_resp_header(head, "content-type") == ["text/plain"]
    assert get_resp_header(head, "x-amz-storage-class") == ["STANDARD_IA"]
    assert get_resp_header(head, "x-amz-meta-origin") == ["fs-local"]
    assert get_resp_header(head, "content-length") == [Integer.to_string(byte_size(body))]

    list =
      SigV4Request.signed_conn(:get, "/#{bucket}",
        query: %{"list-type" => "2", "prefix" => "logs/"}
      )
      |> call()

    assert list.status == 200
    assert list.resp_body =~ "<Key>#{key}</Key>"
    assert list.resp_body =~ "<Size>#{byte_size(body)}</Size>"
    assert list.resp_body =~ "<ETag>#{etag}</ETag>"
    assert list.resp_body =~ "<StorageClass>STANDARD_IA</StorageClass>"
  end

  test "Enabled bucket delete marker is authoritative on FS sidecar and can be removed by version id" do
    bucket = "rb62fsver"
    key = "doc.txt"

    assert SigV4Request.signed_conn(:put, "/#{bucket}") |> call() |> Map.fetch!(:status) == 200
    assert set_versioning(bucket, "Enabled").status == 200

    put = SigV4Request.signed_conn(:put, "/#{bucket}/#{key}", body: "versioned body") |> call()
    assert put.status == 200
    [object_vid] = get_resp_header(put, "x-amz-version-id")

    del = SigV4Request.signed_conn(:delete, "/#{bucket}/#{key}") |> call()
    assert del.status == 204
    assert get_resp_header(del, "x-amz-delete-marker") == ["true"]
    [marker_vid] = get_resp_header(del, "x-amz-version-id")
    assert marker_vid != object_vid

    latest = SigV4Request.signed_conn(:get, "/#{bucket}/#{key}") |> call()
    assert latest.status == 404
    assert get_resp_header(latest, "x-amz-delete-marker") == ["true"]
    assert get_resp_header(latest, "x-amz-version-id") == [marker_vid]

    old =
      SigV4Request.signed_conn(:get, "/#{bucket}/#{key}", query: %{"versionId" => object_vid})
      |> call()

    assert old.status == 200
    assert old.resp_body == "versioned body"

    remove_marker =
      SigV4Request.signed_conn(:delete, "/#{bucket}/#{key}", query: %{"versionId" => marker_vid})
      |> call()

    assert remove_marker.status == 204
    assert get_resp_header(remove_marker, "x-amz-delete-marker") == ["true"]

    restored = SigV4Request.signed_conn(:get, "/#{bucket}/#{key}") |> call()
    assert restored.status == 200
    assert restored.resp_body == "versioned body"
    assert get_resp_header(restored, "x-amz-version-id") == [object_vid]
  end

  test "SSE-S3 object decrypts through FS local sidecar read authority" do
    bucket = "rb62fssse"
    key = "secret.txt"
    body = "fs local topology encrypted body"

    assert SigV4Request.signed_conn(:put, "/#{bucket}") |> call() |> Map.fetch!(:status) == 200

    put =
      SigV4Request.signed_conn(:put, "/#{bucket}/#{key}",
        body: body,
        headers: [
          {"content-type", "text/plain"},
          {"x-amz-server-side-encryption", "AES256"}
        ]
      )
      |> call()

    assert put.status == 200
    assert get_resp_header(put, "x-amz-server-side-encryption") == ["AES256"]

    assert :ok = Objects.delete_metadata(bucket, key)
    assert {:error, :not_found} = Objects.get_metadata(bucket, key)

    get = SigV4Request.signed_conn(:get, "/#{bucket}/#{key}") |> call()
    assert get.status == 200
    assert get.resp_body == body
    assert get_resp_header(get, "x-amz-server-side-encryption") == ["AES256"]
  end

  defp set_versioning(bucket, status) do
    body = ~s(<VersioningConfiguration><Status>#{status}</Status></VersioningConfiguration>)

    SigV4Request.signed_conn(:put, "/#{bucket}", query: %{"versioning" => ""}, body: body)
    |> call()
  end

  defp restore_topology(:__maxio_no_topology__),
    do: :persistent_term.erase({Maxio.Cluster.Topology, :topology})

  defp restore_topology(topo),
    do: :persistent_term.put({Maxio.Cluster.Topology, :topology}, topo)
end
