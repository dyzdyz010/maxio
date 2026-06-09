defmodule Maxio.S3.CopyObjectAuthzTest do
  @moduledoc """
  FX-H7 回归锁：钉死 CopyObject 的目标 put 与源 get 都按**对象级 ARN** 授权。

  CopyObject 走 :put_object（ActionMap.for_action(:put_object) → {"s3:PutObject", :object}，
  目标对象级）；源读由 Authz.maybe_authorize_copy_source/5 对源**对象 ARN** 二次 s3:GetObject 检查。
  本测试证明：对象级策略（coa/*）授权成功；仅桶 ARN（coa，无对象段）→ 目标/源对象动作不被满足 → 403。
  防未来回归到桶级粗门（铁律 5：授权资源层级须与 AWS 一致）。
  """
  use Maxio.DataCase, async: false
  alias Maxio.Test.SigV4Request
  alias Maxio.S3.Endpoint

  @data_dir Path.join(System.tmp_dir!(), "maxio_copy_authz")

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

  test "对象级 s3:PutObject(目标) + s3:GetObject(源) 策略授权匿名 CopyObject" do
    SigV4Request.signed_conn(:put, "/coa1") |> call()
    SigV4Request.signed_conn(:put, "/coa1/src.txt", body: "data") |> call()

    policy =
      ~s({"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":"*","Action":["s3:GetObject","s3:PutObject"],"Resource":["arn:aws:s3:::coa1/*"]}]})

    SigV4Request.signed_conn(:put, "/coa1", query: %{"policy" => ""}, body: policy) |> call()

    res =
      SigV4Request.anon_conn(:put, "/coa1/dst.txt",
        headers: [{"x-amz-copy-source", "/coa1/src.txt"}]
      )
      |> call()

    assert res.status == 200
    assert res.resp_body =~ "CopyObjectResult"
  end

  test "仅授权桶 ARN（非对象 ARN）→ CopyObject 目标 put 被拒 403（证明走对象级）" do
    SigV4Request.signed_conn(:put, "/coa2") |> call()
    SigV4Request.signed_conn(:put, "/coa2/src.txt", body: "data") |> call()

    # 只对桶 ARN 授 PutObject/GetObject —— 对象动作不应被桶 ARN 满足
    policy =
      ~s({"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":"*","Action":["s3:GetObject","s3:PutObject"],"Resource":["arn:aws:s3:::coa2"]}]})

    SigV4Request.signed_conn(:put, "/coa2", query: %{"policy" => ""}, body: policy) |> call()

    res =
      SigV4Request.anon_conn(:put, "/coa2/dst.txt",
        headers: [{"x-amz-copy-source", "/coa2/src.txt"}]
      )
      |> call()

    assert res.status == 403
    assert res.resp_body =~ "AccessDenied"
  end
end
