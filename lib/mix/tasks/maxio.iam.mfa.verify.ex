defmodule Mix.Tasks.Maxio.Iam.Mfa.Verify do
  @shortdoc "Verify a local MFA code"
  @moduledoc """
  Verify a local MFA device code. By default this is a read-only diagnostic and
  does not consume the TOTP step; pass --consume to exercise replay protection.

      mix maxio.iam.mfa.verify --serial arn:aws:iam:::mfa/root-account-mfa-device --code 123456
      mix maxio.iam.mfa.verify --serial arn:aws:iam:::mfa/root-account-mfa-device --code 123456 --consume
  """
  use Mix.Task

  alias Mix.Tasks.Maxio.Iam.Mfa.Output

  @usage "usage: mix maxio.iam.mfa.verify [--principal <arn>] --serial <serial> --code <6-digit-code> [--consume] [--json]"
  @switches [
    principal: :string,
    serial: :string,
    code: :string,
    consume: :boolean,
    json: :boolean
  ]

  @impl true
  def run(args) do
    {opts, rest, invalid} = OptionParser.parse(args, strict: @switches)
    Output.reject_invalid!(rest, invalid, @usage)
    serial = Keyword.get(opts, :serial) || Mix.raise(@usage)
    code = Keyword.get(opts, :code) || Mix.raise(@usage)
    principal = Keyword.get(opts, :principal, Maxio.IAM.root_principal_arn())
    consume? = Keyword.get(opts, :consume, false)

    Mix.Task.run("app.start")

    case Maxio.IAM.verify_mfa_device(principal, serial, code, consume: consume?) do
      :ok -> print_result(serial, principal, consume?, Keyword.get(opts, :json, false))
      {:error, reason} -> Mix.raise("mfa verify failed: #{inspect(reason)}")
    end
  end

  defp print_result(serial, principal, consume?, true) do
    Output.print_json(%{
      status: "ok",
      serial: serial,
      principal_arn: principal,
      consume: consume?
    })
  end

  defp print_result(serial, principal, consume?, false) do
    IO.puts(
      "[maxio iam.mfa.verify] status=ok serial=#{inspect(serial)} " <>
        "principal_arn=#{inspect(principal)} consume=#{consume?}"
    )
  end
end
