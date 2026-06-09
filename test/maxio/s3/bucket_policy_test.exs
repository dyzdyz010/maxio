defmodule Maxio.S3.BucketPolicyTest do
  use Maxio.DataCase, async: false

  import Plug.Conn
  alias Maxio.Test.SigV4Request
  alias Maxio.S3.Endpoint

  @data_dir Path.join(System.tmp_dir!(), "maxio_policy_test")
  @policy ~s({"Version":"2012-10-17","Statement":[{"Sid":"P","Effect":"Allow","Principal":"*","Action":"s3:GetObject","Resource":"arn:aws:s3:::polb/*"}]})

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

  test "PutBucketPolicy 204 → GetBucketPolicy 200 JSON → DeleteBucketPolicy 204" do
    SigV4Request.signed_conn(:put, "/polb") |> call()

    put =
      SigV4Request.signed_conn(:put, "/polb",
        query: %{"policy" => ""},
        body: @policy,
        headers: [{"content-type", "application/json"}]
      )
      |> call()

    assert put.status == 204

    get = SigV4Request.signed_conn(:get, "/polb", query: %{"policy" => ""}) |> call()
    assert get.status == 200
    assert get_resp_header(get, "content-type") |> hd() =~ "application/json"
    assert {:ok, doc} = Jason.decode(get.resp_body)
    assert doc["Statement"] |> hd() |> Map.get("Effect") == "Allow"

    del = SigV4Request.signed_conn(:delete, "/polb", query: %{"policy" => ""}) |> call()
    assert del.status == 204

    get2 = SigV4Request.signed_conn(:get, "/polb", query: %{"policy" => ""}) |> call()
    assert get2.status == 404
    assert get2.resp_body =~ "NoSuchBucketPolicy"
  end

  test "GetBucketPolicy 无 policy → 404 NoSuchBucketPolicy" do
    SigV4Request.signed_conn(:put, "/pb2") |> call()
    get = SigV4Request.signed_conn(:get, "/pb2", query: %{"policy" => ""}) |> call()
    assert get.status == 404
    assert get.resp_body =~ "NoSuchBucketPolicy"
  end

  test "PutBucketPolicy 畸形 JSON → 400 MalformedPolicy" do
    SigV4Request.signed_conn(:put, "/pb3") |> call()

    put =
      SigV4Request.signed_conn(:put, "/pb3",
        query: %{"policy" => ""},
        body: "not json",
        headers: [{"content-type", "application/json"}]
      )
      |> call()

    assert put.status == 400
    assert put.resp_body =~ "MalformedPolicy"
  end

  test "DeleteBucketPolicy 无 policy 也 204（幂等）" do
    SigV4Request.signed_conn(:put, "/pb4") |> call()
    del = SigV4Request.signed_conn(:delete, "/pb4", query: %{"policy" => ""}) |> call()
    assert del.status == 204
  end

  test "PutBucketPolicy: Resource 引用别的桶 → 400 MalformedPolicy（不再静默接受）" do
    SigV4Request.signed_conn(:put, "/pbp1") |> call()

    policy =
      ~s({"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":"*","Action":["s3:GetObject"],"Resource":["arn:aws:s3:::otherbucket/*"]}]})

    res =
      SigV4Request.signed_conn(:put, "/pbp1", query: %{"policy" => ""}, body: policy) |> call()

    assert res.status == 400
    assert res.resp_body =~ "MalformedPolicy"
  end

  test "PutBucketPolicy: Resource 引用本桶（精确/通配）→ 204" do
    SigV4Request.signed_conn(:put, "/pbp2") |> call()

    policy =
      ~s({"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":"*","Action":["s3:GetObject"],"Resource":["arn:aws:s3:::pbp2/*","arn:aws:s3:::pbp2"]}]})

    res =
      SigV4Request.signed_conn(:put, "/pbp2", query: %{"policy" => ""}, body: policy) |> call()

    assert res.status == 204
  end

  test "PutBucketPolicy 含真正不存在的 Condition 算子 → 400 MalformedPolicy" do
    SigV4Request.signed_conn(:put, "/pbc1") |> call()

    # "NotAnOperator" 不是任何 AWS/MinIO 合法算子 → 应拒绝（区别于「合法但未实现求值」的算子）。
    policy =
      ~s({"Version":"2012-10-17","Statement":[{"Effect":"Deny","Principal":"*","Action":["s3:GetObject"],"Resource":["arn:aws:s3:::pbc1/*"],"Condition":{"NotAnOperator":{"s3:max-keys":"10"}}}]})

    res =
      SigV4Request.signed_conn(:put, "/pbc1", query: %{"policy" => ""}, body: policy) |> call()

    assert res.status == 400
    assert res.resp_body =~ "MalformedPolicy"
  end

  test "PutBucketPolicy 含受实现求值的 Condition 算子（Bool）→ 204" do
    SigV4Request.signed_conn(:put, "/pbc2") |> call()

    policy =
      ~s({"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":"*","Action":["s3:GetObject"],"Resource":["arn:aws:s3:::pbc2/*"],"Condition":{"Bool":{"aws:SecureTransport":"true"}}}]})

    res =
      SigV4Request.signed_conn(:put, "/pbc2", query: %{"policy" => ""}, body: policy) |> call()

    assert res.status == 204
  end

  test "PutBucketPolicy 含合法但未实现求值的 Condition 算子（NumericLessThan）→ 204（对齐 MinIO/AWS）" do
    SigV4Request.signed_conn(:put, "/pbc3") |> call()

    policy =
      ~s({"Version":"2012-10-17","Statement":[{"Effect":"Deny","Principal":"*","Action":["s3:GetObject"],"Resource":["arn:aws:s3:::pbc3/*"],"Condition":{"NumericLessThan":{"s3:max-keys":"10"}}}]})

    res =
      SigV4Request.signed_conn(:put, "/pbc3", query: %{"policy" => ""}, body: policy) |> call()

    assert res.status == 204
  end

  test "PutBucketPolicy 含合法但未实现求值的算子（StringNotEquals/DateLessThan/NotIpAddress/Null）→ 204" do
    SigV4Request.signed_conn(:put, "/pbc4") |> call()

    policy =
      ~s({"Version":"2012-10-17","Statement":[{"Effect":"Deny","Principal":"*","Action":["s3:GetObject"],"Resource":["arn:aws:s3:::pbc4/*"],"Condition":{"StringNotEquals":{"s3:x-amz-acl":"public-read"},"DateLessThan":{"aws:CurrentTime":"2030-01-01T00:00:00Z"},"NotIpAddress":{"aws:SourceIp":"10.0.0.0/8"},"Null":{"s3:x-amz-server-side-encryption":"true"}}}]})

    res =
      SigV4Request.signed_conn(:put, "/pbc4", query: %{"policy" => ""}, body: policy) |> call()

    assert res.status == 204
  end

  test "PutBucketPolicy 含合法的 *IfExists 算子变体（StringEqualsIfExists）→ 204" do
    SigV4Request.signed_conn(:put, "/pbc5") |> call()

    policy =
      ~s({"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":"*","Action":["s3:GetObject"],"Resource":["arn:aws:s3:::pbc5/*"],"Condition":{"StringEqualsIfExists":{"s3:prefix":"home/"}}}]})

    res =
      SigV4Request.signed_conn(:put, "/pbc5", query: %{"policy" => ""}, body: policy) |> call()

    assert res.status == 204
  end
end
