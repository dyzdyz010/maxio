defmodule Mix.Tasks.Maxio.Sts.ListSessions do
  @shortdoc "List local STS sessions without secrets"
  @moduledoc """
  List local STS sessions. Secret keys and token hashes are never printed.

      mix maxio.sts.list_sessions
      mix maxio.sts.list_sessions --access-key AKIA...
      mix maxio.sts.list_sessions --principal arn:aws:iam:::root --json
  """
  use Mix.Task

  alias Mix.Tasks.Maxio.Iam.Mfa.Output

  @usage "usage: mix maxio.sts.list_sessions [--access-key <issuer-ak>] [--principal <arn>] [--json]"
  @switches [access_key: :string, principal: :string, json: :boolean]

  @impl true
  def run(args) do
    {opts, rest, invalid} = OptionParser.parse(args, strict: @switches)
    Output.reject_invalid!(rest, invalid, @usage)

    Mix.Task.run("app.start")

    sessions =
      Maxio.STS.list_sessions(
        issuer_access_key_id: Keyword.get(opts, :access_key),
        principal_arn: Keyword.get(opts, :principal)
      )

    print_result(sessions, Keyword.get(opts, :json, false))
  end

  defp print_result(sessions, true), do: Output.print_json(%{status: "ok", sessions: sessions})

  defp print_result(sessions, false) do
    IO.puts("[maxio sts.list_sessions] status=ok count=#{length(sessions)}")

    Enum.each(sessions, fn session ->
      IO.puts(
        "[maxio sts.session] access_key_id=#{inspect(session.access_key_id)} " <>
          "issuer_access_key_id=#{inspect(session.issuer_access_key_id)} " <>
          "principal_arn=#{inspect(session.principal_arn)} status=#{session.status} " <>
          "expires_at=#{DateTime.to_iso8601(session.expires_at)}"
      )
    end)
  end
end
