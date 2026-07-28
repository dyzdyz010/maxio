defmodule Maxio.S3.BucketPolicyTest do
  use Maxio.DataCase, async: false

  import Plug.Conn
  alias Maxio.Test.SigV4Request
  alias Maxio.S3.Endpoint
  alias Maxio.Policy.Store

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

  defp policy(bucket, sid) do
    ~s({"Version":"2012-10-17","Statement":[{"Sid":"#{sid}","Effect":"Allow","Principal":"*","Action":"s3:GetObject","Resource":"arn:aws:s3:::#{bucket}/*"}]})
  end

  defp checksum_b64(algorithm, body), do: :crypto.hash(algorithm, body) |> Base.encode64()

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

  test "Put/Get/DeleteBucketPolicy validate checksums, trailers, and expected owner" do
    bucket = "polchecksum"
    initial = policy(bucket, "Initial")
    updated = policy(bucket, "Updated")
    trailer_update = policy(bucket, "Trailer")

    SigV4Request.signed_conn(:put, "/#{bucket}") |> call()

    good_header =
      SigV4Request.signed_conn(:put, "/#{bucket}",
        query: %{"policy" => ""},
        body: initial,
        headers: [
          {"x-amz-sdk-checksum-algorithm", "SHA256"},
          {"x-amz-checksum-sha256", checksum_b64(:sha256, initial)}
        ]
      )
      |> call()

    assert good_header.status == 204
    assert {:ok, stored} = Store.get_bucket_policy(bucket)
    assert stored =~ "Initial"

    bad_header =
      SigV4Request.signed_conn(:put, "/#{bucket}",
        query: %{"policy" => ""},
        body: updated,
        headers: [
          {"x-amz-sdk-checksum-algorithm", "SHA256"},
          {"x-amz-checksum-sha256", checksum_b64(:sha256, "different")}
        ]
      )
      |> call()

    assert bad_header.status == 400
    assert bad_header.resp_body =~ "<Code>BadDigest</Code>"
    assert {:ok, stored} = Store.get_bucket_policy(bucket)
    assert stored =~ "Initial"

    plain_trailer =
      SigV4Request.signed_conn(:put, "/#{bucket}",
        query: %{"policy" => ""},
        body: updated,
        headers: [
          {"x-amz-sdk-checksum-algorithm", "SHA256"},
          {"x-amz-trailer", "x-amz-checksum-sha256"}
        ]
      )
      |> call()

    assert plain_trailer.status == 400
    assert plain_trailer.resp_body =~ "<Code>InvalidRequest</Code>"
    assert {:ok, stored} = Store.get_bucket_policy(bucket)
    assert stored =~ "Initial"

    ok_trailer =
      SigV4Request.signed_chunked_conn(:put, "/#{bucket}", trailer_update,
        query: %{"policy" => ""},
        headers: [{"x-amz-sdk-checksum-algorithm", "SHA256"}],
        trailer_headers: [{"x-amz-checksum-sha256", checksum_b64(:sha256, trailer_update)}]
      )
      |> call()

    assert ok_trailer.status == 204
    assert {:ok, stored} = Store.get_bucket_policy(bucket)
    assert stored =~ "Trailer"

    wrong_put =
      SigV4Request.signed_conn(:put, "/#{bucket}",
        query: %{"policy" => ""},
        body: updated,
        headers: [{"x-amz-expected-bucket-owner", "111111111111"}]
      )
      |> call()

    assert wrong_put.status == 403
    assert wrong_put.resp_body =~ "<Code>AccessDenied</Code>"
    assert {:ok, stored} = Store.get_bucket_policy(bucket)
    assert stored =~ "Trailer"

    wrong_get =
      SigV4Request.signed_conn(:get, "/#{bucket}",
        query: %{"policy" => ""},
        headers: [{"x-amz-expected-bucket-owner", "111111111111"}]
      )
      |> call()

    assert wrong_get.status == 403

    wrong_delete =
      SigV4Request.signed_conn(:delete, "/#{bucket}",
        query: %{"policy" => ""},
        headers: [{"x-amz-expected-bucket-owner", "111111111111"}]
      )
      |> call()

    assert wrong_delete.status == 403
    assert {:ok, stored} = Store.get_bucket_policy(bucket)
    assert stored =~ "Trailer"
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

    # "NotAnOperator" 不是任何 AWS/MinIO 合法算子 → 应拒绝。
    policy =
      ~s({"Version":"2012-10-17","Statement":[{"Effect":"Deny","Principal":"*","Action":["s3:GetObject"],"Resource":["arn:aws:s3:::pbc1/*"],"Condition":{"NotAnOperator":{"s3:max-keys":"10"}}}]})

    res =
      SigV4Request.signed_conn(:put, "/pbc1", query: %{"policy" => ""}, body: policy) |> call()

    assert res.status == 400
    assert res.resp_body =~ "MalformedPolicy"
  end

  test "PutBucketPolicy 拒绝空 Condition / 空 operator map → 400 MalformedPolicy" do
    SigV4Request.signed_conn(:put, "/pbc-empty") |> call()

    for policy <- [
          ~s({"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":"*","Action":["s3:GetObject"],"Resource":["arn:aws:s3:::pbc-empty/*"],"Condition":{}}]}),
          ~s({"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":"*","Action":["s3:GetObject"],"Resource":["arn:aws:s3:::pbc-empty/*"],"Condition":{"StringEquals":{}}}]})
        ] do
      res =
        SigV4Request.signed_conn(:put, "/pbc-empty",
          query: %{"policy" => ""},
          body: policy
        )
        |> call()

      assert res.status == 400
      assert res.resp_body =~ "MalformedPolicy"
    end
  end

  test "PutBucketPolicy 含受实现求值的 Condition 算子（Bool）→ 204" do
    SigV4Request.signed_conn(:put, "/pbc2") |> call()

    policy =
      ~s({"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":"*","Action":["s3:GetObject"],"Resource":["arn:aws:s3:::pbc2/*"],"Condition":{"Bool":{"aws:SecureTransport":"true"}}}]})

    res =
      SigV4Request.signed_conn(:put, "/pbc2", query: %{"policy" => ""}, body: policy) |> call()

    assert res.status == 204
  end

  test "PutBucketPolicy 含 NumericLessThan Condition 算子 → 204（对齐 MinIO/AWS）" do
    SigV4Request.signed_conn(:put, "/pbc3") |> call()

    policy =
      ~s({"Version":"2012-10-17","Statement":[{"Effect":"Deny","Principal":"*","Action":["s3:GetObject"],"Resource":["arn:aws:s3:::pbc3/*"],"Condition":{"NumericLessThan":{"s3:max-keys":"10"}}}]})

    res =
      SigV4Request.signed_conn(:put, "/pbc3", query: %{"policy" => ""}, body: policy) |> call()

    assert res.status == 204
  end

  test "PutBucketPolicy 含 StringNotEquals/DateLessThan/NotIpAddress/Null 算子 → 204" do
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

  test "PutBucketPolicy 含 ForAnyValue / ForAllValues 集合算子 → 204" do
    SigV4Request.signed_conn(:put, "/pbc6") |> call()

    policy =
      ~s({"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":"*","Action":["s3:ListBucket"],"Resource":["arn:aws:s3:::pbc6"],"Condition":{"ForAnyValue:StringLike":{"s3:prefix":["home/*","public/*"]},"ForAllValues:StringEqualsIfExists":{"s3:delimiter":"/"}}}]})

    res =
      SigV4Request.signed_conn(:put, "/pbc6", query: %{"policy" => ""}, body: policy) |> call()

    assert res.status == 204
  end

  test "PutBucketPolicy 含 NotAction / NotResource / NotPrincipal → 204" do
    SigV4Request.signed_conn(:put, "/pbc8") |> call()

    policy =
      ~s({"Version":"2012-10-17","Statement":[{"Effect":"Deny","NotPrincipal":{"AWS":"arn:aws:iam:::user/alice"},"NotAction":["s3:GetObject"],"NotResource":["arn:aws:s3:::pbc8/public/*"]}]})

    res =
      SigV4Request.signed_conn(:put, "/pbc8", query: %{"policy" => ""}, body: policy) |> call()

    assert res.status == 204
  end

  test "PutBucketPolicy 拒绝互斥的 Action/NotAction → 400 MalformedPolicy" do
    SigV4Request.signed_conn(:put, "/pbc9") |> call()

    policy =
      ~s({"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":"*","Action":["s3:GetObject"],"NotAction":["s3:PutObject"],"Resource":["arn:aws:s3:::pbc9/*"]}]})

    res =
      SigV4Request.signed_conn(:put, "/pbc9", query: %{"policy" => ""}, body: policy) |> call()

    assert res.status == 400
    assert res.resp_body =~ "MalformedPolicy"
  end

  test "PutBucketPolicy 拒绝 Not* 畸形组合和值 → 400 MalformedPolicy" do
    SigV4Request.signed_conn(:put, "/pbc10") |> call()

    for policy <- [
          ~s({"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":"*","Action":["s3:GetObject"],"Resource":["arn:aws:s3:::pbc10/*"],"NotResource":["arn:aws:s3:::pbc10/private/*"]}]}),
          ~s({"Version":"2012-10-17","Statement":[{"Effect":"Deny","Principal":"*","NotPrincipal":{"AWS":"arn:aws:iam:::user/alice"},"Action":["s3:GetObject"],"Resource":["arn:aws:s3:::pbc10/*"]}]}),
          ~s({"Version":"2012-10-17","Statement":[{"Effect":"Allow","NotPrincipal":{"AWS":"arn:aws:iam:::user/alice"},"Action":["s3:GetObject"],"Resource":["arn:aws:s3:::pbc10/*"]}]}),
          ~s({"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":"*","NotAction":["s3:GetObject",123],"Resource":["arn:aws:s3:::pbc10/*"]}]})
        ] do
      res =
        SigV4Request.signed_conn(:put, "/pbc10", query: %{"policy" => ""}, body: policy)
        |> call()

      assert res.status == 400
      assert res.resp_body =~ "MalformedPolicy"
    end
  end

  test "PutBucketPolicy 拒绝 Null 的集合算子变体 → 400 MalformedPolicy" do
    SigV4Request.signed_conn(:put, "/pbc7") |> call()

    policy =
      ~s({"Version":"2012-10-17","Statement":[{"Effect":"Deny","Principal":"*","Action":["s3:GetObject"],"Resource":["arn:aws:s3:::pbc7/*"],"Condition":{"ForAllValues:Null":{"s3:x-amz-server-side-encryption":"true"}}}]})

    res =
      SigV4Request.signed_conn(:put, "/pbc7", query: %{"policy" => ""}, body: policy) |> call()

    assert res.status == 400
    assert res.resp_body =~ "MalformedPolicy"
  end
end
