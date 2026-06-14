defmodule Mix.Tasks.Maxio.Iam.Mfa.Activate do
  @shortdoc "Activate a pending local MFA device"
  @moduledoc """
  Activate a pending local MFA device after scanning the TOTP secret.

      mix maxio.iam.mfa.activate --serial arn:aws:iam:::mfa/root-account-mfa-device --code 123456
  """
  use Mix.Task

  alias Mix.Tasks.Maxio.Iam.Mfa.Output

  @usage "usage: mix maxio.iam.mfa.activate --serial <serial> --code <6-digit-code> [--json]"
  @switches [serial: :string, code: :string, json: :boolean]

  @impl true
  def run(args) do
    {opts, rest, invalid} = OptionParser.parse(args, strict: @switches)
    Output.reject_invalid!(rest, invalid, @usage)
    serial = Keyword.get(opts, :serial) || Mix.raise(@usage)
    code = Keyword.get(opts, :code) || Mix.raise(@usage)

    Mix.Task.run("app.start")

    case Maxio.IAM.activate_mfa_device(serial, code) do
      {:ok, device} -> print_result(device, Keyword.get(opts, :json, false))
      {:error, reason} -> Mix.raise("mfa activate failed: #{inspect(reason)}")
    end
  end

  defp print_result(device, true), do: Output.print_json(%{status: "active", device: device})

  defp print_result(device, false) do
    IO.puts(
      "[maxio iam.mfa.activate] status=active serial=#{inspect(device.serial)} " <>
        "principal_arn=#{inspect(device.principal_arn)}"
    )
  end
end
