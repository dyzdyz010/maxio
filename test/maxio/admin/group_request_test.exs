defmodule Maxio.Admin.GroupRequestTest do
  use ExUnit.Case, async: true

  import Plug.Conn
  import Plug.Test

  alias Maxio.Admin.GroupRequest
  alias Maxio.S3.Error

  @max_group_request_bytes 262_272

  test "reads bounded plaintext across adapter chunks without Content-Type" do
    body =
      ~s({"group":"g1","members":["bob","alice","bob"],"groupStatus":"ignored","isRemove":false})

    [first, second, third] = split_body(body)

    conn =
      body
      |> request_conn(content_type: :absent)
      |> Map.put(:adapter, {
        Maxio.Test.BodyReadProbeAdapter,
        {self(), {:chunks, [first, second, third]}}
      })

    assert {parsed_conn, request} = GroupRequest.read_update_body!(conn)
    assert parsed_conn.state == :unset

    assert request == %{
             group: "g1",
             group_status: "ignored",
             members: ["bob", "alice", "bob"],
             remove?: false
           }

    assert_receive :body_reader_called
    assert_receive :body_reader_called
    assert_receive :body_reader_called
  end

  test "accepts arbitrary Content-Type and ignores declared length when actual bytes are valid" do
    body = valid_body()

    for content_type <- [
          "application/json",
          "text/plain; charset=utf-8",
          "application/octet-stream"
        ] do
      conn = request_conn(body, content_type: content_type, content_length: "1")
      assert {_conn, %{group: "g1"}} = GroupRequest.read_update_body!(conn)
    end
  end

  test "actual byte limit accepts the boundary and maps overflow to config-too-large" do
    accepted =
      ~s({"group":"g1","members":[],"groupStatus":") <>
        String.duplicate("x", @max_group_request_bytes - 61) <>
        ~s(","isRemove":false})

    assert byte_size(accepted) == @max_group_request_bytes

    assert {_conn, %{group_status: status}} =
             GroupRequest.read_update_body!(request_conn(accepted))

    assert byte_size(status) == @max_group_request_bytes - 61

    too_large = accepted <> " "

    assert_error(
      fn -> GroupRequest.read_update_body!(request_conn(too_large)) end,
      "XMinioAdminConfigTooLarge"
    )
  end

  test "empty, truncated, invalid UTF-8, and malformed JSON are config-bad-json" do
    invalid = [
      "",
      ~s({"group":"g1"),
      <<?{, ?\", ?g, ?r, ?o, ?u, ?p, ?\", ?:, ?\", 255, ?\", ?}>>,
      "[]",
      "null"
    ]

    for body <- invalid do
      assert_error(
        fn -> GroupRequest.read_update_body!(request_conn(body)) end,
        "XMinioAdminConfigBadJSON"
      )
    end
  end

  test "wrong non-null field types are config-bad-json" do
    invalid = [
      ~s({"group":1,"members":[],"groupStatus":"","isRemove":false}),
      ~s({"group":"g","members":"alice","groupStatus":"","isRemove":false}),
      ~s({"group":"g","members":["alice",1],"groupStatus":"","isRemove":false}),
      ~s({"group":"g","members":[],"groupStatus":false,"isRemove":false}),
      ~s({"group":"g","members":[],"groupStatus":"","isRemove":"false"})
    ]

    for body <- invalid do
      assert_error(
        fn -> GroupRequest.read_update_body!(request_conn(body)) end,
        "XMinioAdminConfigBadJSON"
      )
    end
  end

  test "missing and null fields use pinned Go zero values" do
    for body <- ["{}", ~s({"group":null,"members":null,"groupStatus":null,"isRemove":null})] do
      assert {_conn, request} = GroupRequest.read_update_body!(request_conn(body))

      assert request == %{
               group: "",
               group_status: "",
               members: [],
               remove?: false
             }
    end
  end

  test "unknown fields are ignored and duplicate keys keep their last value" do
    body =
      ~s({"unknown":{"secret":"not-returned"},"group":"old","group":"new","members":["old"],"members":["bob","alice","bob"],"groupStatus":"old","groupStatus":"new-status","isRemove":false,"isRemove":true})

    assert {_conn, request} = GroupRequest.read_update_body!(request_conn(body))

    assert request == %{
             group: "new",
             group_status: "new-status",
             members: ["bob", "alice", "bob"],
             remove?: true
           }
  end

  test "plaintext parser has no signing-secret or envelope capability requirement" do
    conn = request_conn(valid_body())
    refute Map.has_key?(conn.assigns, :sigv4_context)
    refute Map.has_key?(conn.assigns, :signing_secret)

    assert {_conn, %{group: "g1"}} = GroupRequest.read_update_body!(conn)
  end

  defp valid_body do
    ~s({"group":"g1","members":["bob","alice","bob"],"groupStatus":"","isRemove":false})
  end

  defp request_conn(body, opts \\ []) do
    conn =
      :put
      |> conn("/minio/admin/v3/update-group-members", body)
      |> delete_req_header("content-length")
      |> delete_req_header("content-type")
      |> put_req_header(
        "content-length",
        Keyword.get(opts, :content_length, Integer.to_string(byte_size(body)))
      )

    case Keyword.get(opts, :content_type, :absent) do
      :absent -> conn
      content_type -> put_req_header(conn, "content-type", content_type)
    end
  end

  defp split_body(body) do
    first_size = div(byte_size(body), 3)
    second_size = div(byte_size(body) - first_size, 2)
    <<first::binary-size(^first_size), second::binary-size(^second_size), third::binary>> = body
    [first, second, third]
  end

  defp assert_error(callback, code) do
    error = assert_raise Error, callback
    assert error.code == code
  end
end
