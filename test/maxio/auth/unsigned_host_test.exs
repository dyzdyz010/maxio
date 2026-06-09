defmodule Maxio.Auth.UnsignedHostTest do
  use ExUnit.Case, async: true
  alias Maxio.Auth
  alias Maxio.Auth.SigV4.SignedRequest

  test "SignedHeaders 缺 host → unsigned_headers（AccessDenied/400），验签前即拒" do
    sr = %SignedRequest{
      access_key: "AKIAIOSFODNN7EXAMPLE",
      scope_date: "20130524",
      region: "us-east-1",
      service: "s3",
      signed_headers: ["x-amz-date"],
      signature: "deadbeef",
      amz_date: "20130524T000000Z",
      auth_type: :header,
      payload_mode: :single,
      expires: nil
    }

    material = %{
      signed_request: sr,
      method: "GET",
      path: "/",
      query: "",
      headers: [{"x-amz-date", "20130524T000000Z"}],
      payload_hash: "UNSIGNED-PAYLOAD",
      now: DateTime.utc_now()
    }

    assert {:error, %Maxio.S3.Error{code: "AccessDenied", http_status: 400}} =
             Auth.authenticate(material)
  end
end
