defmodule Mix.Tasks.Maxio.Sts.RevokeSession do
  @shortdoc "Revoke a local STS session"
  @moduledoc """
  Revoke a local STS session credential.

      mix maxio.sts.revoke_session --access-key ASIA...
      mix maxio.sts.revoke_session --access-key ASIA... --json
  """
  use Mix.Task

  alias Mix.Tasks.Maxio.Iam.Mfa.Output

  @usage "usage: mix maxio.sts.revoke_session --access-key <session-ak> [--json]"
  @switches [access_key: :string, json: :boolean]

  @impl true
  def run(args) do
    {opts, rest, invalid} = OptionParser.parse(args, strict: @switches)
    Output.reject_invalid!(rest, invalid, @usage)
    access_key_id = Keyword.get(opts, :access_key) || Mix.raise(@usage)

    Mix.Task.run("app.start")

    case Maxio.STS.revoke_session(access_key_id) do
      {:ok, session} -> print_result(access_key_id, session, Keyword.get(opts, :json, false))
      {:error, reason} -> Mix.raise("sts revoke_session failed: #{inspect(reason)}")
    end
  end

  defp print_result(access_key_id, session, true) do
    Output.print_json(%{status: "revoked", access_key_id: access_key_id, session: session})
  end

  defp print_result(access_key_id, nil, false) do
    IO.puts("[maxio sts.revoke_session] status=revoked access_key_id=#{inspect(access_key_id)}")
  end

  defp print_result(_access_key_id, session, false) do
    IO.puts(
      "[maxio sts.revoke_session] status=revoked access_key_id=#{inspect(session.access_key_id)} " <>
        "revoked_at=#{revoked_at(session)}"
    )
  end

  defp revoked_at(%{revoked_at: %DateTime{} = revoked_at}), do: DateTime.to_iso8601(revoked_at)
  defp revoked_at(_session), do: "already-revoked"
end
