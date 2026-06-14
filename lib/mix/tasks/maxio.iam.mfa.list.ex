defmodule Mix.Tasks.Maxio.Iam.Mfa.List do
  @shortdoc "List local MFA devices without secrets"
  @moduledoc """
  List local MFA devices. Secrets and otpauth URIs are never printed.

      mix maxio.iam.mfa.list
      mix maxio.iam.mfa.list --principal arn:aws:iam:::root --json
  """
  use Mix.Task

  alias Mix.Tasks.Maxio.Iam.Mfa.Output

  @usage "usage: mix maxio.iam.mfa.list [--principal <arn>] [--json]"
  @switches [principal: :string, json: :boolean]

  @impl true
  def run(args) do
    {opts, rest, invalid} = OptionParser.parse(args, strict: @switches)
    Output.reject_invalid!(rest, invalid, @usage)

    Mix.Task.run("app.start")

    devices = Maxio.IAM.list_mfa_devices(Keyword.get(opts, :principal))
    print_result(devices, Keyword.get(opts, :json, false))
  end

  defp print_result(devices, true), do: Output.print_json(%{status: "ok", devices: devices})

  defp print_result(devices, false) do
    IO.puts("[maxio iam.mfa.list] status=ok count=#{length(devices)}")

    Enum.each(devices, fn device ->
      IO.puts(
        "[maxio iam.mfa.device] serial=#{inspect(device.serial)} " <>
          "principal_arn=#{inspect(device.principal_arn)} name=#{inspect(device.device_name)} " <>
          "status=#{device.status} kind=#{device.kind} algorithm=#{device.algorithm}"
      )
    end)
  end
end
