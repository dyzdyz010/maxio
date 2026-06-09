defmodule Maxio.S3.SigV4PlusQueryE2ETest do
  use Maxio.DataCase, async: false
  alias Maxio.Test.SigV4Request
  alias Maxio.S3.Endpoint

  @data_dir Path.join(System.tmp_dir!(), "maxio_sigv4_plus_e2e")

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

  test "签名 query 含字面 '+' 的值 → 通过验签（不再 SignatureDoesNotMatch）" do
    SigV4Request.signed_conn(:put, "/plusb") |> call()
    # list-type=2 + 一个含 '+' 的自定义查询值，二者都参与签名
    res =
      SigV4Request.signed_conn(:get, "/plusb",
        query: %{"list-type" => "2", "x-token" => "a+b+c"}
      )
      |> call()

    refute res.resp_body =~ "SignatureDoesNotMatch"
    assert res.status == 200
  end

  test "多个含字面 '+' 的查询值并存 → 全部正确单次编码、验签通过" do
    # 注意：signed_conn 用 URI.encode_query 上线（www_form：真实空格→'+'），
    # 故端到端用例只覆盖"字面 '+'"（wire 上恒为 %2B、无歧义）；真实空格(%20)区分由
    # canonical_raw_query_test.exs 的纯函数用例取证（避免 www_form 空格歧义污染本端到端断言）。
    SigV4Request.signed_conn(:put, "/plusm") |> call()

    res =
      SigV4Request.signed_conn(:get, "/plusm",
        query: %{"list-type" => "2", "prefix" => "a+b", "delimiter" => "x+y"}
      )
      |> call()

    refute res.resp_body =~ "SignatureDoesNotMatch"
    assert res.status == 200
  end
end
