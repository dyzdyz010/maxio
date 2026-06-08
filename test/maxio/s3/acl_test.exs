defmodule Maxio.S3.AclTest do
  use Maxio.DataCase, async: false

  alias Maxio.Test.SigV4Request
  alias Maxio.S3.Endpoint

  @data_dir Path.join(System.tmp_dir!(), "maxio_acl_test")

  setup do
    File.rm_rf(@data_dir)
    File.mkdir_p!(@data_dir)
    prev = Application.get_env(:maxio, :s3)
    Application.put_env(:maxio, :s3, Keyword.put(prev, :data_dir, @data_dir))

    on_exit(fn ->
      Application.put_env(:maxio, :s3, prev)
      File.rm_rf(@data_dir)
    end)

    :ok
  end

  defp call(conn), do: Endpoint.call(conn, Endpoint.init([]))

  test "PutObject x-amz-acl=public-read → GetObjectAcl 展开 AllUsers READ" do
    SigV4Request.signed_conn(:put, "/abk") |> call()

    SigV4Request.signed_conn(:put, "/abk/pub.txt",
      body: "hi",
      headers: [{"x-amz-acl", "public-read"}]
    )
    |> call()

    acl = SigV4Request.signed_conn(:get, "/abk/pub.txt", query: %{"acl" => ""}) |> call()
    assert acl.status == 200
    assert acl.resp_body =~ ~s(xsi:type="Group")
    assert acl.resp_body =~ "AllUsers"
    assert acl.resp_body =~ "<Permission>READ</Permission>"
    assert acl.resp_body =~ ~s(xmlns="http://s3.amazonaws.com/doc/2006-03-01/")
  end

  test "GetBucketAcl 默认 private → 仅 owner FULL_CONTROL" do
    SigV4Request.signed_conn(:put, "/abk2") |> call()
    acl = SigV4Request.signed_conn(:get, "/abk2", query: %{"acl" => ""}) |> call()
    assert acl.status == 200
    assert acl.resp_body =~ "<Permission>FULL_CONTROL</Permission>"
    refute acl.resp_body =~ "AllUsers"
  end

  test "PutBucketAcl x-amz-acl=public-read → GetBucketAcl 展开" do
    SigV4Request.signed_conn(:put, "/abk3") |> call()

    put =
      SigV4Request.signed_conn(:put, "/abk3",
        query: %{"acl" => ""},
        headers: [{"x-amz-acl", "public-read"}]
      )
      |> call()

    assert put.status == 200

    acl = SigV4Request.signed_conn(:get, "/abk3", query: %{"acl" => ""}) |> call()
    assert acl.resp_body =~ "AllUsers"
  end

  test "PutObjectAcl XML body → GetObjectAcl 展开（round-trip）" do
    SigV4Request.signed_conn(:put, "/abk4") |> call()
    SigV4Request.signed_conn(:put, "/abk4/x.txt", body: "hi") |> call()

    xml =
      ~s(<AccessControlPolicy><AccessControlList>) <>
        ~s(<Grant><Grantee xsi:type="Group"><URI>http://acs.amazonaws.com/groups/global/AllUsers</URI></Grantee><Permission>READ</Permission></Grant>) <>
        ~s(</AccessControlList></AccessControlPolicy>)

    put =
      SigV4Request.signed_conn(:put, "/abk4/x.txt", query: %{"acl" => ""}, body: xml)
      |> call()

    assert put.status == 200

    acl = SigV4Request.signed_conn(:get, "/abk4/x.txt", query: %{"acl" => ""}) |> call()
    assert acl.resp_body =~ "AllUsers"
    assert acl.resp_body =~ "<Permission>READ</Permission>"
  end

  test "PutObjectAcl email grantee → 400 InvalidArgument" do
    SigV4Request.signed_conn(:put, "/abk5") |> call()
    SigV4Request.signed_conn(:put, "/abk5/y.txt", body: "hi") |> call()

    xml =
      ~s(<AccessControlPolicy><AccessControlList>) <>
        ~s(<Grant><Grantee xsi:type="AmazonCustomerByEmail"><EmailAddress>nobody@example.com</EmailAddress></Grantee><Permission>READ</Permission></Grant>) <>
        ~s(</AccessControlList></AccessControlPolicy>)

    resp =
      SigV4Request.signed_conn(:put, "/abk5/y.txt", query: %{"acl" => ""}, body: xml)
      |> call()

    assert resp.status == 400
    assert resp.resp_body =~ "InvalidArgument"
  end
end
