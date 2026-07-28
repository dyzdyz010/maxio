defmodule MaxioWeb.ConsoleDirectMultipartUploadFormTest do
  use ExUnit.Case, async: true

  alias MaxioWeb.ConsoleDirectMultipartUploadForm

  test "parses SSE-C customer key headers and computes key MD5 when omitted" do
    customer_key = :binary.copy(<<7>>, 32)
    customer_key_b64 = Base.encode64(customer_key)
    key_md5_b64 = :crypto.hash(:md5, customer_key) |> Base.encode64()

    assert {:ok, parsed} =
             %{"sse_customer_key" => customer_key_b64}
             |> ConsoleDirectMultipartUploadForm.parse("text/plain")

    assert parsed.request_payer == false
    assert parsed.sse_customer_key_required == true

    assert Map.new(parsed.create_headers) == %{
             "content-type" => "text/plain",
             "x-amz-server-side-encryption-customer-algorithm" => "AES256",
             "x-amz-server-side-encryption-customer-key" => customer_key_b64,
             "x-amz-server-side-encryption-customer-key-md5" => key_md5_b64
           }

    assert Map.new(parsed.request_headers) == %{
             "x-amz-server-side-encryption-customer-algorithm" => "AES256",
             "x-amz-server-side-encryption-customer-key" => customer_key_b64,
             "x-amz-server-side-encryption-customer-key-md5" => key_md5_b64
           }

    assert {:ok, explicit} =
             %{
               "sse_customer_key" => customer_key_b64,
               "sse_customer_key_md5" => key_md5_b64
             }
             |> ConsoleDirectMultipartUploadForm.parse("text/plain")

    assert explicit.create_headers == parsed.create_headers
    assert explicit.request_headers == parsed.request_headers
  end

  test "includes Requester Pays with SSE-C replay headers" do
    customer_key = :binary.copy(<<8>>, 32)
    customer_key_b64 = Base.encode64(customer_key)

    assert {:ok, parsed} =
             %{
               "sse_customer_key" => customer_key_b64,
               "request_payer" => true
             }
             |> ConsoleDirectMultipartUploadForm.parse("application/octet-stream")

    assert Map.new(parsed.request_headers)["x-amz-request-payer"] == "requester"

    assert Map.new(parsed.request_headers)["x-amz-server-side-encryption-customer-key"] ==
             customer_key_b64
  end

  test "rejects invalid SSE-C customer key inputs" do
    customer_key = :binary.copy(<<9>>, 32)
    customer_key_b64 = Base.encode64(customer_key)
    wrong_md5_b64 = :crypto.hash(:md5, :binary.copy(<<8>>, 32)) |> Base.encode64()

    assert {:error, :invalid_sse} =
             %{"sse_customer_key" => Base.encode64("too short")}
             |> ConsoleDirectMultipartUploadForm.parse("text/plain")

    assert {:error, :invalid_sse} =
             %{"sse_customer_key" => customer_key_b64, "sse_customer_key_md5" => wrong_md5_b64}
             |> ConsoleDirectMultipartUploadForm.parse("text/plain")

    assert {:error, :invalid_sse} =
             %{"sse_customer_key_md5" => :crypto.hash(:md5, customer_key) |> Base.encode64()}
             |> ConsoleDirectMultipartUploadForm.parse("text/plain")

    assert {:error, :invalid_sse} =
             %{"sse_customer_key" => customer_key_b64 <> "\0"}
             |> ConsoleDirectMultipartUploadForm.parse("text/plain")
  end

  test "rejects SSE-C combined with managed SSE or KMS fields" do
    customer_key_b64 = Base.encode64(:binary.copy(<<10>>, 32))

    cases = [
      %{"sse_customer_key" => customer_key_b64, "sse_algorithm" => "AES256"},
      %{"sse_customer_key" => customer_key_b64, "sse_algorithm" => "aws:kms"},
      %{"sse_customer_key" => customer_key_b64, "sse_kms_key_id" => "alias/maxio-local"},
      %{
        "sse_customer_key" => customer_key_b64,
        "sse_context" => Base.encode64(~s({"tenant":"a"}))
      },
      %{"sse_customer_key" => customer_key_b64, "sse_bucket_key" => true}
    ]

    for params <- cases do
      assert {:error, :invalid_sse} =
               ConsoleDirectMultipartUploadForm.parse(params, "application/octet-stream")
    end
  end

  test "rejects non-string SSE-C JSON values" do
    assert {:error, :invalid_sse} =
             %{"sse_customer_key" => %{}}
             |> ConsoleDirectMultipartUploadForm.parse("application/octet-stream")

    assert {:error, :invalid_sse} =
             %{"sse_customer_key_md5" => []}
             |> ConsoleDirectMultipartUploadForm.parse("application/octet-stream")
  end
end
