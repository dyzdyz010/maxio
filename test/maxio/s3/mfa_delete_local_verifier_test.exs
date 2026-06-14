defmodule Maxio.S3.MFADeleteLocalVerifierTest do
  use Maxio.DataCase, async: false

  alias Maxio.IAM
  alias Maxio.IAM.TOTP
  alias Maxio.S3.Endpoint
  alias Maxio.Test.SigV4Request

  @data_dir Path.join(System.tmp_dir!(), "maxio_mfa_delete_local_verifier_test")

  setup do
    File.rm_rf(@data_dir)
    File.mkdir_p!(@data_dir)

    prev_s3 = Application.get_env(:maxio, :s3)
    prev_mfa_verifier = Application.fetch_env(:maxio, :mfa_delete_verifier)

    Application.put_env(:maxio, :s3, Keyword.put(prev_s3, :data_dir, @data_dir))
    Application.put_env(:maxio, :mfa_delete_verifier, Maxio.IAM.MFADeleteVerifier)

    on_exit(fn ->
      Application.put_env(:maxio, :s3, prev_s3)
      restore_mfa_verifier(prev_mfa_verifier)
      File.rm_rf(@data_dir)
    end)

    :ok
  end

  test "DB-backed TOTP verifier enables MFA Delete with a valid root code" do
    serial = serial("s3")
    assert {:ok, enrolled} = IAM.create_mfa_device(device_name: "s3-device", serial: serial)
    activate_with_past_code!(serial, enrolled.secret_base32)

    assert put_bucket("mfadb1").status == 200

    body =
      ~s(<VersioningConfiguration><Status>Enabled</Status><MfaDelete>Enabled</MfaDelete></VersioningConfiguration>)

    assert {:ok, code} = TOTP.code(enrolled.secret_base32)

    accepted =
      SigV4Request.signed_conn(:put, "/mfadb1",
        query: %{"versioning" => ""},
        body: body,
        headers: [{"x-amz-mfa", "#{serial} #{code}"}]
      )
      |> https()
      |> call()

    assert accepted.status == 200
  end

  test "DB-backed verifier fails closed when serial or code is unknown" do
    assert put_bucket("mfadb2").status == 200

    body =
      ~s(<VersioningConfiguration><Status>Enabled</Status><MfaDelete>Enabled</MfaDelete></VersioningConfiguration>)

    rejected =
      SigV4Request.signed_conn(:put, "/mfadb2",
        query: %{"versioning" => ""},
        body: body,
        headers: [{"x-amz-mfa", "#{serial("missing")} 123456"}]
      )
      |> https()
      |> call()

    assert rejected.status == 403
    assert rejected.resp_body =~ "<Code>AccessDenied</Code>"
  end

  defp call(conn), do: Endpoint.call(conn, Endpoint.init([]))
  defp https(conn), do: %{conn | scheme: :https}
  defp put_bucket(bucket), do: SigV4Request.signed_conn(:put, "/#{bucket}") |> call()

  defp activate_with_past_code!(serial, secret_base32) do
    activation_time = DateTime.add(DateTime.utc_now(), -120, :second)
    code = TOTP.code!(secret_base32, time: activation_time)
    assert {:ok, _device} = IAM.activate_mfa_device(serial, code, time: activation_time)
  end

  defp serial(name), do: "arn:aws:iam:::mfa/#{name}-#{System.unique_integer([:positive])}"

  defp restore_mfa_verifier({:ok, value}),
    do: Application.put_env(:maxio, :mfa_delete_verifier, value)

  defp restore_mfa_verifier(:error), do: Application.delete_env(:maxio, :mfa_delete_verifier)
end
