defmodule Mix.Tasks.Maxio.Iam.MFATest do
  use Maxio.DataCase, async: false

  import ExUnit.CaptureIO

  alias Mix.Tasks.Maxio.Iam.Mfa

  @tasks [
    "maxio.iam.mfa.create",
    "maxio.iam.mfa.list",
    "maxio.iam.mfa.verify",
    "maxio.iam.mfa.delete"
  ]

  setup do
    Enum.each(@tasks, &Mix.Task.reenable/1)

    on_exit(fn ->
      Enum.each(@tasks, &Mix.Task.reenable/1)
    end)
  end

  test "create prints the seed once and list does not leak it" do
    serial = serial("cli")

    create_output =
      capture_io(fn ->
        Mfa.Create.run(["--name", "cli-device", "--serial", serial])
      end)

    assert create_output =~ "[maxio iam.mfa.create] status=created"
    assert create_output =~ serial
    [_, secret] = Regex.run(~r/SecretBase32:\s+([A-Z2-7]+)/, create_output)

    list_output =
      capture_io(fn ->
        Mfa.List.run([])
      end)

    assert list_output =~ "[maxio iam.mfa.list] status=ok count=1"
    assert list_output =~ serial
    refute list_output =~ secret
    refute list_output =~ "OtpAuthURI"
  end

  test "json list output is parseable and excludes secrets" do
    serial = serial("json")

    assert {:ok, _result} =
             Maxio.IAM.create_mfa_device(device_name: "json-device", serial: serial)

    output =
      capture_io(fn ->
        Mfa.List.run(["--json"])
      end)

    assert %{"status" => "ok", "devices" => [device]} = Jason.decode!(output)
    assert device["serial"] == serial
    refute Map.has_key?(device, "secret_base32")
    refute Map.has_key?(device, "secret_envelope")
  end

  test "verify defaults to non-consuming and consume burns the step" do
    serial = serial("verify-cli")

    assert {:ok, enrolled} =
             Maxio.IAM.create_mfa_device(device_name: "verify-cli-device", serial: serial)

    activation_time = DateTime.add(DateTime.utc_now(), -120, :second)
    activation_code = Maxio.IAM.TOTP.code!(enrolled.secret_base32, time: activation_time)

    assert {:ok, _device} =
             Maxio.IAM.activate_mfa_device(serial, activation_code, time: activation_time)

    verify_time = DateTime.utc_now()
    code = Maxio.IAM.TOTP.code!(enrolled.secret_base32, time: verify_time)

    first =
      capture_io(fn ->
        Mfa.Verify.run(["--serial", serial, "--code", code])
      end)

    second =
      capture_io(fn ->
        Mfa.Verify.run(["--serial", serial, "--code", code])
      end)

    consumed =
      capture_io(fn ->
        Mfa.Verify.run(["--serial", serial, "--code", code, "--consume"])
      end)

    assert first =~ "consume=false"
    assert second =~ "consume=false"
    assert consumed =~ "consume=true"

    assert_raise Mix.Error, ~r/mfa verify failed: :mfa_code_replayed/, fn ->
      Mfa.Verify.run(["--serial", serial, "--code", code, "--consume"])
    end
  end

  test "invalid args raise usage before work starts" do
    assert_raise Mix.Error, ~r/usage: mix maxio\.iam\.mfa\.list/, fn ->
      Mfa.List.run(["unexpected"])
    end
  end

  defp serial(name), do: "arn:aws:iam:::mfa/#{name}-#{System.unique_integer([:positive])}"
end
