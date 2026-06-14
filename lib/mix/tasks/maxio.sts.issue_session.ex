defmodule Mix.Tasks.Maxio.Sts.IssueSession do
  @shortdoc "Issue local STS session credentials"
  @moduledoc """
  Issue local STS session credentials from an active long-term access key.

      mix maxio.sts.issue_session --access-key AKIA...
      mix maxio.sts.issue_session --access-key AKIA... --duration-seconds 3600 --session-name cli
      mix maxio.sts.issue_session --access-key AKIA... --json

  The secret access key and session token are printed only by this command.
  """
  use Mix.Task

  alias Mix.Tasks.Maxio.Iam.Mfa.Output

  @usage "usage: mix maxio.sts.issue_session --access-key <ak> [--duration-seconds <seconds>] [--session-name <name>] [--json]"
  @switches [
    access_key: :string,
    duration_seconds: :integer,
    session_name: :string,
    json: :boolean
  ]

  @impl true
  def run(args) do
    {opts, rest, invalid} = OptionParser.parse(args, strict: @switches)
    Output.reject_invalid!(rest, invalid, @usage)
    issuer_access_key_id = Keyword.get(opts, :access_key) || Mix.raise(@usage)

    Mix.Task.run("app.start")

    sts_opts =
      []
      |> Keyword.put(:issuer_access_key_id, issuer_access_key_id)
      |> put_if(:duration_seconds, Keyword.get(opts, :duration_seconds))
      |> put_if(:session_name, Keyword.get(opts, :session_name))

    case Maxio.STS.issue_session(sts_opts) do
      {:ok, session} -> print_result(session, Keyword.get(opts, :json, false))
      {:error, reason} -> Mix.raise("sts issue_session failed: #{format_error(reason)}")
    end
  end

  defp print_result(session, true) do
    Output.print_json(%{status: "issued", session: session})
  end

  defp print_result(session, false) do
    IO.puts(
      "[maxio sts.issue_session] status=issued access_key_id=#{inspect(session.access_key_id)} " <>
        "issuer_access_key_id=#{inspect(session.issuer_access_key_id)} expires_at=#{DateTime.to_iso8601(session.expires_at)}"
    )

    IO.puts("SecretAccessKey: #{session.secret_key}")
    IO.puts("SessionToken   : #{session.session_token}")
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

  defp format_error(errors) when is_map(errors), do: inspect(errors)

  defp format_error(reason), do: inspect(reason)
end
