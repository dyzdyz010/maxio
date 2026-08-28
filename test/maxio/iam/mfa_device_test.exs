defmodule Maxio.IAM.MFADeviceTest do
  use Maxio.DataCase, async: false

  alias Maxio.IAM
  alias Maxio.IAM.{MFADevice, TOTP}

  @root IAM.root_principal_arn()

  test "create_mfa_device stores only an encrypted seed envelope and lists no secret" do
    serial = serial("create")

    assert {:ok, enrolled} =
             IAM.create_mfa_device(device_name: "create-device", serial: serial)

    assert enrolled.secret_base32 =~ ~r/^[A-Z2-7]+$/
    assert enrolled.otpauth_uri =~ "otpauth://totp/"
    assert enrolled.device.status == "pending"

    row = Repo.get_by!(MFADevice, serial: serial)
    refute inspect(row) =~ enrolled.secret_base32
    refute inspect(row.secret_envelope) =~ enrolled.secret_base32
    assert row.secret_envelope["ciphertext_b64"]

    assert [listed] = IAM.list_mfa_devices(@root)
    assert listed.serial == serial
    refute Map.has_key?(listed, :secret_envelope)
    refute Map.has_key?(listed, :secret_base32)
  end

  test "pending device activation consumes the activation step" do
    serial = serial("activate")
    assert {:ok, enrolled} = IAM.create_mfa_device(device_name: "activate-device", serial: serial)
    activation_time = DateTime.add(DateTime.utc_now(), -120, :second)
    assert {:ok, activation_code} = TOTP.code(enrolled.secret_base32, time: activation_time)

    assert {:ok, device} = IAM.activate_mfa_device(serial, activation_code, time: activation_time)
    assert device.status == "active"
    assert device.confirmed_at

    assert {:error, :mfa_device_not_pending} =
             IAM.activate_mfa_device(serial, activation_code, time: activation_time)
  end

  test "active device verification can be non-consuming or consuming with replay guard" do
    serial = serial("verify")
    assert {:ok, enrolled} = IAM.create_mfa_device(device_name: "verify-device", serial: serial)
    activation_time = DateTime.add(DateTime.utc_now(), -120, :second)
    assert {:ok, activation_code} = TOTP.code(enrolled.secret_base32, time: activation_time)

    assert {:ok, _device} =
             IAM.activate_mfa_device(serial, activation_code, time: activation_time)

    verify_time = DateTime.utc_now()
    assert {:ok, code} = TOTP.code(enrolled.secret_base32, time: verify_time)

    assert :ok =
             IAM.verify_mfa_device(%{type: :root, arn: @root}, serial, code,
               time: verify_time,
               consume: false
             )

    assert :ok =
             IAM.verify_mfa_device(%{type: :root, arn: @root}, serial, code,
               time: verify_time,
               consume: false
             )

    assert :ok =
             IAM.verify_mfa_device(%{type: :root, arn: @root}, serial, code, time: verify_time)

    assert {:error, :mfa_code_replayed} =
             IAM.verify_mfa_device(%{type: :root, arn: @root}, serial, code, time: verify_time)
  end

  test "verifier rejects wrong principal, inactive device, and duplicate serial" do
    serial = serial("reject")
    assert {:ok, enrolled} = IAM.create_mfa_device(device_name: "reject-device", serial: serial)
    assert {:error, :mfa_device_not_active} = IAM.verify_mfa_device(@root, serial, "123456")

    activation_time = DateTime.add(DateTime.utc_now(), -120, :second)
    assert {:ok, activation_code} = TOTP.code(enrolled.secret_base32, time: activation_time)

    assert {:ok, _device} =
             IAM.activate_mfa_device(serial, activation_code, time: activation_time)

    verify_time = DateTime.utc_now()
    assert {:ok, code} = TOTP.code(enrolled.secret_base32, time: verify_time)

    assert {:error, :mfa_principal_mismatch} =
             IAM.verify_mfa_device("arn:aws:iam:::user/alice", serial, code,
               time: verify_time,
               consume: false
             )

    assert {:ok, disabled} = IAM.disable_mfa_device(serial, force: true)
    assert disabled.status == "disabled"

    assert {:error, :mfa_device_not_active} =
             IAM.verify_mfa_device(@root, serial, code, time: verify_time)

    assert {:error, changeset} =
             IAM.create_mfa_device(device_name: "reject-device-2", serial: serial)

    assert %{serial: [_message]} = errors_on(changeset)
  end

  test "serial validation fails closed and IAM user principals are supported" do
    assert {:error, changeset} =
             IAM.create_mfa_device(device_name: "bad serial", serial: "serial with spaces")

    assert %{serial: [_message], device_name: [_device_message]} = errors_on(changeset)

    assert {:ok, user} = IAM.create_user(name: "alice")
    user_arn = user.user_arn
    user_serial = serial("alice")

    assert {:ok, enrolled} =
             IAM.create_mfa_device(
               principal_arn: user_arn,
               device_name: "alice",
               serial: user_serial
             )

    assert enrolled.device.principal_type == "iam_user"
    assert [listed] = IAM.list_mfa_devices(user_arn)
    assert listed.serial == user_serial

    activation_time = DateTime.add(DateTime.utc_now(), -120, :second)
    assert {:ok, activation_code} = TOTP.code(enrolled.secret_base32, time: activation_time)

    assert {:ok, _device} =
             IAM.activate_mfa_device(user_serial, activation_code, time: activation_time)

    verify_time = DateTime.utc_now()
    assert {:ok, code} = TOTP.code(enrolled.secret_base32, time: verify_time)

    assert :ok =
             IAM.verify_mfa_device(%{type: :iam_user, arn: user_arn}, user_serial, code,
               time: verify_time,
               consume: false
             )

    assert {:error, :mfa_principal_mismatch} =
             IAM.verify_mfa_device(%{type: :root, arn: @root}, user_serial, code,
               time: verify_time,
               consume: false
             )
  end

  defp serial(name), do: "arn:aws:iam:::mfa/#{name}-#{System.unique_integer([:positive])}"
end
