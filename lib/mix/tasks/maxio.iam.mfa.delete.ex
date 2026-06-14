defmodule Mix.Tasks.Maxio.Iam.Mfa.Delete do
  @shortdoc "Physically delete a local MFA device row"
  @moduledoc """
  Physically delete a local MFA device row. Active devices require --force.

      mix maxio.iam.mfa.delete --serial arn:aws:iam:::mfa/root-account-mfa-device
      mix maxio.iam.mfa.delete --serial arn:aws:iam:::mfa/root-account-mfa-device --force
  """
  use Mix.Task

  alias Mix.Tasks.Maxio.Iam.Mfa.Output

  @usage "usage: mix maxio.iam.mfa.delete --serial <serial> [--force] [--json]"
  @switches [serial: :string, force: :boolean, json: :boolean]

  @impl true
  def run(args) do
    {opts, rest, invalid} = OptionParser.parse(args, strict: @switches)
    Output.reject_invalid!(rest, invalid, @usage)
    serial = Keyword.get(opts, :serial) || Mix.raise(@usage)

    Mix.Task.run("app.start")

    case Maxio.IAM.delete_mfa_device(serial, force: Keyword.get(opts, :force, false)) do
      :ok -> print_result(serial, Keyword.get(opts, :json, false))
      {:error, reason} -> Mix.raise("mfa delete failed: #{inspect(reason)}")
    end
  end

  defp print_result(serial, true), do: Output.print_json(%{status: "deleted", serial: serial})

  defp print_result(serial, false) do
    IO.puts("[maxio iam.mfa.delete] status=deleted serial=#{inspect(serial)}")
  end
end
