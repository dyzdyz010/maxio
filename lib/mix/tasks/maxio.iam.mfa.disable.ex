defmodule Mix.Tasks.Maxio.Iam.Mfa.Disable do
  @shortdoc "Disable a local MFA device"
  @moduledoc """
  Disable a local MFA device while keeping the row for audit.

      mix maxio.iam.mfa.disable --serial arn:aws:iam:::mfa/root-account-mfa-device --code 123456
      mix maxio.iam.mfa.disable --serial arn:aws:iam:::mfa/root-account-mfa-device --force
  """
  use Mix.Task

  alias Mix.Tasks.Maxio.Iam.Mfa.Output

  @usage "usage: mix maxio.iam.mfa.disable --serial <serial> [--code <6-digit-code>] [--force] [--json]"
  @switches [serial: :string, code: :string, force: :boolean, json: :boolean]

  @impl true
  def run(args) do
    {opts, rest, invalid} = OptionParser.parse(args, strict: @switches)
    Output.reject_invalid!(rest, invalid, @usage)
    serial = Keyword.get(opts, :serial) || Mix.raise(@usage)

    Mix.Task.run("app.start")

    iam_opts =
      []
      |> Keyword.put(:force, Keyword.get(opts, :force, false))
      |> put_if(:code, Keyword.get(opts, :code))

    case Maxio.IAM.disable_mfa_device(serial, iam_opts) do
      {:ok, device} -> print_result(device, Keyword.get(opts, :json, false))
      {:error, reason} -> Mix.raise("mfa disable failed: #{inspect(reason)}")
    end
  end

  defp print_result(device, true), do: Output.print_json(%{status: "disabled", device: device})

  defp print_result(device, false) do
    IO.puts(
      "[maxio iam.mfa.disable] status=disabled serial=#{inspect(device.serial)} " <>
        "principal_arn=#{inspect(device.principal_arn)}"
    )
  end

  defp put_if(kw, _key, nil), do: kw
  defp put_if(kw, key, value), do: Keyword.put(kw, key, value)
end
