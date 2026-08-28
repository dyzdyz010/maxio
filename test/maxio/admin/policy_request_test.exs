defmodule Maxio.Admin.PolicyRequestTest do
  use ExUnit.Case, async: true

  import Plug.Conn

  alias Maxio.Admin.PolicyRequest
  alias Maxio.S3.Error

  test "accepts positive Content-Length without Content-Type" do
    body = ~s({"Version":"2012-10-17","Statement":[]})
    conn = conn_with_headers(body, [{"content-length", Integer.to_string(byte_size(body))}])

    assert get_req_header(conn, "content-type") == []
    assert {_conn, ^body} = PolicyRequest.read_add_body!(conn)
  end

  test "only a positive ASCII decimal Content-Length is accepted" do
    cases = [
      [],
      [{"content-length", "0"}],
      [{"content-length", "-1"}],
      [{"content-length", "+1"}],
      [{"content-length", " 1"}],
      [{"content-length", "1 "}],
      [{"content-length", "\t1"}],
      [{"content-length", "١"}],
      [{"content-length", "１"}],
      [{"content-length", "abc"}],
      [{"content-length", "2"}, {"content-length", "2"}],
      [{"transfer-encoding", "chunked"}, {"content-length", "2"}]
    ]

    for headers <- cases do
      conn = conn_with_headers("{}", headers)

      error =
        assert_raise Error, fn ->
          PolicyRequest.read_add_body!(conn)
        end

      assert error.code == "MissingContentLength"
      assert error.http_status == 411
    end
  end

  test "reads exactly 20_480 bytes and rejects 20_481 before invoking the body reader" do
    accepted = String.duplicate(" ", 20_480)
    accepted_conn = conn_with_headers(accepted, [{"content-length", "20480"}])
    assert {_conn, ^accepted} = PolicyRequest.read_add_body!(accepted_conn)

    rejected = String.duplicate(" ", 20_481)
    conn = conn_with_headers(rejected, [{"content-length", "20481"}])
    {adapter, state} = conn.adapter
    conn = %{conn | adapter: {Maxio.Test.BodyReadProbeAdapter, {self(), state}}}

    error =
      assert_raise Error, fn ->
        PolicyRequest.read_add_body!(conn)
      end

    assert error.code == "XMinioAdminInvalidArgument"
    assert error.http_status == 400
    refute_received :body_reader_called
    assert adapter == Plug.Adapters.Test.Conn
  end

  test "declared length must equal the bytes actually read" do
    conn = conn_with_headers("{}", [{"content-length", "3"}])

    error =
      assert_raise Error, fn ->
        PolicyRequest.read_add_body!(conn)
      end

    assert error.code == "IncompleteBody"
    assert error.http_status == 400
  end

  defp conn_with_headers(body, headers) do
    conn =
      :put
      |> Plug.Test.conn("/minio/admin/v3/add-canned-policy?name=p", body)
      |> delete_req_header("content-length")
      |> delete_req_header("transfer-encoding")

    %{conn | req_headers: headers ++ conn.req_headers}
  end
end
