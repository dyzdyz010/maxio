defmodule MaxioWeb.ConsolePostObjectFormTest do
  use ExUnit.Case, async: false

  alias MaxioWeb.ConsolePostObjectForm

  @base_params %{
    "expires_in" => "600",
    "max_size" => "64",
    "success_action_status" => "201"
  }

  test "parses Content-MD5, metadata, and KMS fields into exact POST fields" do
    content_md5 = :crypto.hash(:md5, "console body") |> Base.encode64()
    context = Base.encode64(~s({"purpose":"console-post"}))

    assert {:ok, %{fields: fields}} =
             @base_params
             |> Map.put("content_md5", content_md5)
             |> Map.put("metadata", "Origin=Console\nteam=storage")
             |> Map.put("sse_algorithm", "aws:kms")
             |> Map.put("sse_kms_key_id", "alias/maxio-local")
             |> Map.put("sse_context", context)
             |> Map.put("sse_bucket_key", "true")
             |> ConsolePostObjectForm.parse()

    assert Map.new(fields) == %{
             "Content-MD5" => content_md5,
             "x-amz-meta-origin" => "Console",
             "x-amz-meta-team" => "storage",
             "x-amz-server-side-encryption" => "aws:kms",
             "x-amz-server-side-encryption-aws-kms-key-id" => "alias/maxio-local",
             "x-amz-server-side-encryption-context" => context,
             "x-amz-server-side-encryption-bucket-key-enabled" => "true"
           }
  end

  test "parses SSE-C customer key fields and computes key MD5 when omitted" do
    customer_key = :binary.copy(<<7>>, 32)
    customer_key_b64 = Base.encode64(customer_key)
    key_md5_b64 = :crypto.hash(:md5, customer_key) |> Base.encode64()

    assert {:ok, %{fields: fields}} =
             @base_params
             |> Map.put("sse_customer_key", customer_key_b64)
             |> ConsolePostObjectForm.parse()

    assert Map.new(fields) == %{
             "x-amz-server-side-encryption-customer-algorithm" => "AES256",
             "x-amz-server-side-encryption-customer-key" => customer_key_b64,
             "x-amz-server-side-encryption-customer-key-md5" => key_md5_b64
           }

    assert {:ok, %{fields: explicit_fields}} =
             @base_params
             |> Map.put("sse_customer_key", customer_key_b64)
             |> Map.put("sse_customer_key_md5", key_md5_b64)
             |> ConsolePostObjectForm.parse()

    assert Map.new(explicit_fields) == Map.new(fields)
  end

  test "parses allowed raw x-amz fields into exact POST fields" do
    content_md5 = :crypto.hash(:md5, "locked body") |> Base.encode64()

    assert {:ok, %{fields: fields}} =
             @base_params
             |> Map.put("content_md5", content_md5)
             |> Map.put(
               "raw_amz_fields",
               [
                 "x-amz-storage-class=STANDARD_IA",
                 "x-amz-website-redirect-location=/landing.html",
                 "x-amz-expected-bucket-owner=000000000000",
                 "x-amz-object-lock-mode=GOVERNANCE",
                 "x-amz-object-lock-retain-until-date=2037-01-01T00:00:00Z",
                 "x-amz-object-lock-legal-hold=OFF"
               ]
               |> Enum.join("\n")
             )
             |> ConsolePostObjectForm.parse()

    assert Map.new(fields) == %{
             "Content-MD5" => content_md5,
             "x-amz-storage-class" => "STANDARD_IA",
             "x-amz-website-redirect-location" => "/landing.html",
             "x-amz-expected-bucket-owner" => "000000000000",
             "x-amz-object-lock-mode" => "GOVERNANCE",
             "x-amz-object-lock-retain-until-date" => "2037-01-01T00:00:00Z",
             "x-amz-object-lock-legal-hold" => "OFF"
           }
  end

  test "enforces configured POST redirect allowlist before signing" do
    with_console_config(
      s3_public_url: "http://localhost:9900",
      post_object_redirect_allowlist: ["https://console.example.test/uploads"]
    )

    assert {:ok, %{fields: fields}} =
             @base_params
             |> Map.put(
               "success_action_redirect",
               "https://console.example.test/uploads/done?state=ok"
             )
             |> ConsolePostObjectForm.parse()

    assert {"success_action_redirect", "https://console.example.test/uploads/done?state=ok"} in fields

    assert {:error, :invalid_redirect} =
             @base_params
             |> Map.put("success_action_redirect", "https://console.example.test/other/done")
             |> ConsolePostObjectForm.parse()

    assert {:error, :invalid_redirect} =
             @base_params
             |> Map.put(
               "success_action_redirect",
               "https://console.example.test/uploads.evil/done"
             )
             |> ConsolePostObjectForm.parse()

    assert {:error, :invalid_redirect} =
             @base_params
             |> Map.put(
               "success_action_redirect",
               "https://evilconsole.example.test/uploads/done"
             )
             |> ConsolePostObjectForm.parse()
  end

  test "does not retain SSE-C secrets in rebuilt form state" do
    form =
      ConsolePostObjectForm.form(%{
        "sse_customer_key" => Base.encode64(:binary.copy(<<1>>, 32)),
        "sse_customer_key_md5" => Base.encode64(:binary.copy(<<2>>, 16)),
        "content_type" => "text/plain"
      })

    assert form[:sse_customer_key].value == ""
    assert form[:sse_customer_key_md5].value == ""
    assert form[:content_type].value == "text/plain"
  end

  test "rejects unsafe redirect URL values" do
    assert {:error, :invalid_redirect} =
             ConsolePostObjectForm.parse(
               Map.put(
                 @base_params,
                 "success_action_redirect",
                 "https://user:pass@example.test/done"
               )
             )

    assert {:error, :invalid_redirect} =
             ConsolePostObjectForm.parse(
               Map.put(
                 @base_params,
                 "success_action_redirect",
                 "https://example.test/done\r\nX-Bad: 1"
               )
             )
  end

  test "rejects CRLF in advanced field values before signing" do
    assert {:error, :invalid_field} =
             ConsolePostObjectForm.parse(
               Map.put(@base_params, "content_type", "text/plain\r\nX-Bad: 1")
             )

    assert {:error, :invalid_sse} =
             @base_params
             |> Map.put("sse_algorithm", "aws:kms")
             |> Map.put("sse_kms_key_id", "alias/key\r\nX-Bad: 1")
             |> ConsolePostObjectForm.parse()

    assert {:error, :invalid_checksum} =
             @base_params
             |> Map.put("checksum_algorithm", "SHA256")
             |> Map.put("checksum_value", "abc\r\nX-Bad: 1")
             |> ConsolePostObjectForm.parse()
  end

  test "rejects NUL bytes in advanced field values before signing" do
    assert {:error, :invalid_field} =
             ConsolePostObjectForm.parse(Map.put(@base_params, "cache_control", "max-age=1\0"))

    assert {:error, :invalid_metadata} =
             @base_params
             |> Map.put("metadata", "origin=console\0")
             |> ConsolePostObjectForm.parse()

    assert {:error, :invalid_metadata} =
             @base_params
             |> Map.put("metadata", "bad\0name=value")
             |> ConsolePostObjectForm.parse()

    assert {:error, :invalid_sse} =
             @base_params
             |> Map.put("sse_algorithm", "aws:kms")
             |> Map.put("sse_kms_key_id", "alias/key\0")
             |> ConsolePostObjectForm.parse()
  end

  test "rejects invalid Content-MD5 before signing" do
    assert {:error, :invalid_content_md5} =
             @base_params
             |> Map.put("content_md5", "not-base64")
             |> ConsolePostObjectForm.parse()

    assert {:error, :invalid_content_md5} =
             @base_params
             |> Map.put("content_md5", Base.encode64("too short"))
             |> ConsolePostObjectForm.parse()
  end

  test "rejects invalid SSE-C customer key inputs before signing" do
    customer_key = :binary.copy(<<9>>, 32)
    customer_key_b64 = Base.encode64(customer_key)
    wrong_md5_b64 = :crypto.hash(:md5, :binary.copy(<<8>>, 32)) |> Base.encode64()

    assert {:error, :invalid_sse} =
             @base_params
             |> Map.put("sse_customer_key", Base.encode64("too short"))
             |> ConsolePostObjectForm.parse()

    assert {:error, :invalid_sse} =
             @base_params
             |> Map.put("sse_customer_key", customer_key_b64)
             |> Map.put("sse_customer_key_md5", wrong_md5_b64)
             |> ConsolePostObjectForm.parse()

    assert {:error, :invalid_sse} =
             @base_params
             |> Map.put("sse_customer_key", customer_key_b64)
             |> Map.put("sse_algorithm", "aws:kms")
             |> ConsolePostObjectForm.parse()

    assert {:error, :invalid_sse} =
             @base_params
             |> Map.put("sse_customer_key", customer_key_b64 <> "\0")
             |> ConsolePostObjectForm.parse()
  end

  test "rejects unsafe or oversized metadata before signing" do
    assert {:error, :invalid_metadata} =
             @base_params
             |> Map.put("metadata", "x-amz-acl=public-read")
             |> ConsolePostObjectForm.parse()

    assert {:error, :invalid_metadata} =
             @base_params
             |> Map.put("metadata", "origin=console\nORIGIN=duplicate")
             |> ConsolePostObjectForm.parse()

    assert {:error, :invalid_metadata} =
             @base_params
             |> Map.put("metadata", "bad:name=value")
             |> ConsolePostObjectForm.parse()

    assert {:error, :invalid_metadata} =
             @base_params
             |> Map.put("metadata", "origin=console\r\nX-Bad: 1")
             |> ConsolePostObjectForm.parse()

    assert {:error, :invalid_metadata} =
             @base_params
             |> Map.put("metadata", "large=#{String.duplicate("x", Maxio.Metadata.max_size())}")
             |> ConsolePostObjectForm.parse()
  end

  test "rejects invalid KMS context and unsupported bucket-key combinations" do
    assert {:error, :invalid_sse} =
             @base_params
             |> Map.put("sse_context", Base.encode64(~s({"purpose":"console"})))
             |> ConsolePostObjectForm.parse()

    assert {:error, :invalid_sse} =
             @base_params
             |> Map.put("sse_algorithm", "AES256")
             |> Map.put("sse_context", Base.encode64(~s({"purpose":"console"})))
             |> ConsolePostObjectForm.parse()

    assert {:error, :invalid_sse} =
             @base_params
             |> Map.put("sse_algorithm", "aws:kms:dsse")
             |> Map.put("sse_bucket_key", "true")
             |> ConsolePostObjectForm.parse()

    assert {:error, :invalid_sse} =
             @base_params
             |> Map.put("sse_algorithm", "aws:kms")
             |> Map.put("sse_context", Base.encode64(~s(["not","object"])))
             |> ConsolePostObjectForm.parse()

    assert {:error, :invalid_sse} =
             @base_params
             |> Map.put("sse_algorithm", "aws:kms")
             |> Map.put("sse_context", "not-base64")
             |> ConsolePostObjectForm.parse()
  end

  test "rejects unsupported or colliding raw x-amz fields before signing" do
    assert {:error, :invalid_raw_amz_field} =
             @base_params
             |> Map.put("raw_amz_fields", "x-amz-copy-source=/bucket/key")
             |> ConsolePostObjectForm.parse()

    assert {:error, :invalid_raw_amz_field} =
             @base_params
             |> Map.put("raw_amz_fields", "x-amz-storage-class=NOPE")
             |> ConsolePostObjectForm.parse()

    assert {:error, :invalid_raw_amz_field} =
             @base_params
             |> Map.put(
               "raw_amz_fields",
               "x-amz-website-redirect-location=/ok\nX-Amz-Website-Redirect-Location=/dupe"
             )
             |> ConsolePostObjectForm.parse()

    assert {:error, :invalid_raw_amz_field} =
             @base_params
             |> Map.put("acl", "private")
             |> Map.put(
               "raw_amz_fields",
               ~s(x-amz-grant-read=uri="http://acs.amazonaws.com/groups/global/AllUsers")
             )
             |> ConsolePostObjectForm.parse()

    assert {:error, :invalid_raw_amz_field} =
             @base_params
             |> Map.put("raw_amz_fields", "x-amz-object-lock-legal-hold=ON")
             |> ConsolePostObjectForm.parse()
  end

  defp with_console_config(config) do
    previous = Application.get_env(:maxio, :console, :__unset__)
    Application.put_env(:maxio, :console, config)

    on_exit(fn ->
      case previous do
        :__unset__ -> Application.delete_env(:maxio, :console)
        value -> Application.put_env(:maxio, :console, value)
      end
    end)
  end
end
