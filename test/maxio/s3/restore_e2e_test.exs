defmodule Maxio.S3.RestoreE2ETest do
  use Maxio.DataCase, async: false

  import Plug.Conn, only: [get_resp_header: 2]

  alias Maxio.Objects
  alias Maxio.S3.Endpoint
  alias Maxio.Test.SigV4Request

  @data_dir Path.join(System.tmp_dir!(), "maxio_restore_e2e")

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

  test "RestoreObject records restore metadata and unblocks archive GET" do
    SigV4Request.signed_conn(:put, "/restore") |> call()

    put =
      SigV4Request.signed_conn(:put, "/restore/cold.txt",
        body: "cold bytes",
        headers: [{"x-amz-storage-class", "GLACIER"}]
      )
      |> call()

    assert put.status == 200

    before_restore = SigV4Request.signed_conn(:get, "/restore/cold.txt") |> call()
    assert before_restore.status == 403
    assert before_restore.resp_body =~ "<Code>InvalidObjectState</Code>"

    xml =
      ~s(<RestoreRequest><Days>3</Days><GlacierJobParameters><Tier>Standard</Tier></GlacierJobParameters></RestoreRequest>)

    restore =
      SigV4Request.signed_conn(:post, "/restore/cold.txt", query: %{"restore" => ""}, body: xml)
      |> call()

    assert restore.status == 202
    {:ok, object} = Objects.get_metadata("restore", "cold.txt")
    assert object.restore_status == "restored"
    assert %DateTime{} = object.restore_expiry

    head = SigV4Request.signed_conn(:head, "/restore/cold.txt") |> call()
    assert head.status == 200
    [restore_header] = get_resp_header(head, "x-amz-restore")
    assert restore_header =~ ~s(ongoing-request="false")
    assert restore_header =~ "expiry-date="

    get = SigV4Request.signed_conn(:get, "/restore/cold.txt") |> call()
    assert get.status == 200
    assert get.resp_body == "cold bytes"
    assert get_resp_header(get, "x-amz-restore") == [restore_header]

    second =
      SigV4Request.signed_conn(:post, "/restore/cold.txt", query: %{"restore" => ""}, body: xml)
      |> call()

    assert second.status == 200
  end

  test "RestoreObject rejects non archive storage classes" do
    SigV4Request.signed_conn(:put, "/restorestd") |> call()
    SigV4Request.signed_conn(:put, "/restorestd/std.txt", body: "plain") |> call()

    xml = ~s(<RestoreRequest><Days>1</Days></RestoreRequest>)

    restore =
      SigV4Request.signed_conn(:post, "/restorestd/std.txt",
        query: %{"restore" => ""},
        body: xml
      )
      |> call()

    assert restore.status == 403
    assert restore.resp_body =~ "<Code>InvalidObjectState</Code>"
  end

  test "RestoreObject rejects select restore without mutating object" do
    SigV4Request.signed_conn(:put, "/restoreselect") |> call()

    SigV4Request.signed_conn(:put, "/restoreselect/cold.txt",
      body: "cold bytes",
      headers: [{"x-amz-storage-class", "DEEP_ARCHIVE"}]
    )
    |> call()

    xml =
      ~s(<RestoreRequest><Days>1</Days><Type>SELECT</Type><SelectParameters></SelectParameters></RestoreRequest>)

    restore =
      SigV4Request.signed_conn(:post, "/restoreselect/cold.txt",
        query: %{"restore" => ""},
        body: xml
      )
      |> call()

    assert restore.status == 501
    {:ok, object} = Objects.get_metadata("restoreselect", "cold.txt")
    assert object.restore_status == nil
  end

  test "RestoreObject maps invalid object names to structured S3 errors" do
    SigV4Request.signed_conn(:put, "/restorebadkey") |> call()
    xml = ~s(<RestoreRequest><Days>1</Days></RestoreRequest>)

    restore =
      SigV4Request.signed_conn(:post, "/restorebadkey/a/../b",
        query: %{"restore" => ""},
        body: xml
      )
      |> call()

    assert restore.status == 400
    assert restore.resp_body =~ "<Code>XMinioInvalidObjectName</Code>"
    refute restore.resp_body =~ "InternalError"
  end

  defp call(conn), do: Endpoint.call(conn, Endpoint.init([]))
end
