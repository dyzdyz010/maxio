defmodule Mix.Tasks.Maxio.Iam.Mfa.Create do
  @shortdoc "Enroll a local TOTP MFA device"
  @moduledoc """
  Enroll a pending local TOTP MFA device for S3 MFA Delete or STS MFA context.

      mix maxio.iam.mfa.create --name root-account-mfa-device
      mix maxio.iam.mfa.create --name root-account-mfa-device --serial arn:aws:iam:::mfa/root-account-mfa-device
      mix maxio.iam.mfa.create --principal arn:aws:iam:::user/alice --name alice-mfa
      mix maxio.iam.mfa.create --name root-account-mfa-device --json

  The Base32 secret and otpauth URI are printed only once by this command.
  """
  use Mix.Task

  alias Mix.Tasks.Maxio.Iam.Mfa.Output

  @usage "usage: mix maxio.iam.mfa.create [--principal <arn>] [--name <name>] [--serial <serial>] [--json]"
  @switches [principal: :string, name: :string, serial: :string, json: :boolean]

  @impl true
  def run(args) do
    {opts, rest, invalid} = OptionParser.parse(args, strict: @switches)
    Output.reject_invalid!(rest, invalid, @usage)

    Mix.Task.run("app.start")

    iam_opts =
      []
      |> put_if(:principal_arn, opts[:principal])
      |> put_if(:device_name, opts[:name])
      |> put_if(:serial, opts[:serial])

    case Maxio.IAM.create_mfa_device(iam_opts) do
      {:ok, result} ->
        print_result(result, Keyword.get(opts, :json, false))

      {:error, reason} ->
        Mix.raise("mfa create failed: #{format_error(reason)}")
    end
  end

  defp print_result(result, true) do
    Output.print_json(%{
      status: "created",
      device: result.device,
      serial: result.serial,
      secret_base32: result.secret_base32,
      otpauth_uri: result.otpauth_uri
    })
  end

  defp print_result(result, false) do
    IO.puts(
      "[maxio iam.mfa.create] status=created serial=#{inspect(result.serial)} " <>
        "principal_arn=#{inspect(result.device.principal_arn)} device_status=#{result.device.status}"
    )

    IO.puts("SecretBase32: #{result.secret_base32}")
    IO.puts("OtpAuthURI  : #{result.otpauth_uri}")
  end

  defp put_if(kw, _key, nil), do: kw
  defp put_if(kw, key, value), do: Keyword.put(kw, key, value)

  defp format_error(%Ecto.Changeset{} = changeset) do
    errors =
      Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
        Regex.replace(~r"%{(\w+)}", message, fn _, key ->
          opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
        end)
      end)

    inspect(errors)
  end

  defp format_error(reason), do: inspect(reason)
end
