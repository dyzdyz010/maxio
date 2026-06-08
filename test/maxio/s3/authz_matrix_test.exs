defmodule Maxio.S3.AuthzMatrixTest do
  use Maxio.DataCase, async: false

  alias Maxio.Test.SigV4Request
  alias Maxio.Auth.CredentialStore
  alias Maxio.S3.Endpoint

  @data_dir Path.join(System.tmp_dir!(), "maxio_authz_matrix_test")
  @alice_ak "AKIAALICEKEY00000001"
  @alice_secret "alicealicealicealicealicealice12"
  @alice_arn "arn:aws:iam:::user/" <> @alice_ak

  setup do
    File.rm_rf(@data_dir)
    File.mkdir_p!(@data_dir)
    prev = Application.get_env(:maxio, :s3)
    Application.put_env(:maxio, :s3, Keyword.put(prev, :data_dir, @data_dir))

    # 注入非 owner 认证 principal（MemoryStore）。
    :ok =
      CredentialStore.put_access_key(%{
        access_key: @alice_ak,
        secret_key: @alice_secret,
        principal: %{type: :iam_user, access_key: @alice_ak, arn: @alice_arn}
      })

    on_exit(fn ->
      Application.put_env(:maxio, :s3, prev)
      File.rm_rf(@data_dir)
    end)

    :ok
  end

  defp call(conn), do: Endpoint.call(conn, Endpoint.init([]))

  defp alice(method, path, opts) do
    SigV4Request.signed_conn(
      method,
      path,
      Keyword.merge([access_key: @alice_ak, secret: @alice_secret], opts)
    )
  end

  test "认证非 owner 无 policy → 403（认证 ≠ 授权）" do
    # root 建桶（owner=root）
    SigV4Request.signed_conn(:put, "/mba") |> call()
    SigV4Request.signed_conn(:put, "/mba/o.txt", body: "x") |> call()

    get = alice(:get, "/mba/o.txt", []) |> call()
    assert get.status == 403
    assert get.resp_body =~ "AccessDenied"
  end

  test "policy 命名该 principal arn → 放行" do
    SigV4Request.signed_conn(:put, "/mb2") |> call()
    SigV4Request.signed_conn(:put, "/mb2/o.txt", body: "yes") |> call()

    pol =
      ~s({"Statement":{"Effect":"Allow","Principal":{"AWS":"#{@alice_arn}"},"Action":"s3:GetObject","Resource":"arn:aws:s3:::mb2/*"}})

    SigV4Request.signed_conn(:put, "/mb2",
      query: %{"policy" => ""},
      body: pol,
      headers: [{"content-type", "application/json"}]
    )
    |> call()

    get = alice(:get, "/mb2/o.txt", []) |> call()
    assert get.status == 200
    assert get.resp_body == "yes"
  end

  test "policy StringLike s3:prefix 限制 ListBucket" do
    SigV4Request.signed_conn(:put, "/mb3") |> call()

    pol =
      ~s({"Statement":{"Effect":"Allow","Principal":{"AWS":"#{@alice_arn}"},"Action":"s3:ListBucket","Resource":"arn:aws:s3:::mb3","Condition":{"StringLike":{"s3:prefix":["home/*"]}}}})

    SigV4Request.signed_conn(:put, "/mb3",
      query: %{"policy" => ""},
      body: pol,
      headers: [{"content-type", "application/json"}]
    )
    |> call()

    ok = alice(:get, "/mb3", query: %{"prefix" => "home/alice/"}) |> call()
    assert ok.status == 200

    denied = alice(:get, "/mb3", query: %{"prefix" => "secret/"}) |> call()
    assert denied.status == 403
  end

  test "CopyObject 源读权限：源对象对 alice private → copy 被拒（源 GetObject 二次检查）" do
    SigV4Request.signed_conn(:put, "/mb4") |> call()
    SigV4Request.signed_conn(:put, "/mb4/src.txt", body: "src") |> call()

    # 给 alice 目标 PutObject 权限，但不给源 GetObject → 二次检查应拒。
    pol =
      ~s({"Statement":{"Effect":"Allow","Principal":{"AWS":"#{@alice_arn}"},"Action":"s3:PutObject","Resource":"arn:aws:s3:::mb4/*"}})

    SigV4Request.signed_conn(:put, "/mb4",
      query: %{"policy" => ""},
      body: pol,
      headers: [{"content-type", "application/json"}]
    )
    |> call()

    copy = alice(:put, "/mb4/dst.txt", headers: [{"x-amz-copy-source", "/mb4/src.txt"}]) |> call()
    assert copy.status == 403
  end
end
