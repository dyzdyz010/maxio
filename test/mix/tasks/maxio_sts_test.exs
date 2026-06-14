defmodule Mix.Tasks.Maxio.STSTest do
  use Maxio.DataCase, async: false

  import ExUnit.CaptureIO

  alias Maxio.IAM
  alias Maxio.STS
  alias Mix.Tasks.Maxio.Sts

  @tasks [
    "maxio.sts.issue_session",
    "maxio.sts.list_sessions",
    "maxio.sts.revoke_session"
  ]

  setup do
    Enum.each(@tasks, &Mix.Task.reenable/1)

    on_exit(fn ->
      Enum.each(@tasks, &Mix.Task.reenable/1)
    end)
  end

  test "issue prints session secret once and list does not leak it" do
    {:ok, issuer} =
      IAM.create_access_key(access_key_id: unique_ak("CLI"), secret_key: "issuer-secret")

    issue_output =
      capture_io(fn ->
        Sts.IssueSession.run([
          "--access-key",
          issuer.access_key_id,
          "--duration-seconds",
          "900",
          "--session-name",
          "cli-session"
        ])
      end)

    assert issue_output =~ "[maxio sts.issue_session] status=issued"
    [_, access_key_id] = Regex.run(~r/access_key_id="([^"]+)"/, issue_output)
    [_, secret_key] = Regex.run(~r/SecretAccessKey:\s+(\S+)/, issue_output)
    [_, session_token] = Regex.run(~r/SessionToken\s+:\s+(\S+)/, issue_output)

    list_output =
      capture_io(fn ->
        Sts.ListSessions.run([])
      end)

    assert list_output =~ access_key_id
    refute list_output =~ secret_key
    refute list_output =~ session_token
  end

  test "json outputs are parseable and hide secrets outside issue response" do
    {:ok, issuer} =
      IAM.create_access_key(access_key_id: unique_ak("JSON"), secret_key: "issuer-secret")

    issue_output =
      capture_io(fn ->
        Sts.IssueSession.run([
          "--access-key",
          issuer.access_key_id,
          "--duration-seconds",
          "900",
          "--json"
        ])
      end)

    assert %{
             "status" => "issued",
             "session" => %{
               "access_key_id" => access_key_id,
               "secret_key" => secret_key,
               "session_token" => session_token
             }
           } = Jason.decode!(issue_output)

    list_output =
      capture_io(fn ->
        Sts.ListSessions.run(["--json"])
      end)

    assert %{"status" => "ok", "sessions" => sessions} = Jason.decode!(list_output)
    public = Enum.find(sessions, &(&1["access_key_id"] == access_key_id))
    refute Map.has_key?(public, "secret_key")
    refute Map.has_key?(public, "session_token")
    refute Map.has_key?(public, "session_token_sha256")
    refute list_output =~ secret_key
    refute list_output =~ session_token
  end

  test "revoke command is idempotent and does not leak secrets" do
    {:ok, issuer} =
      IAM.create_access_key(access_key_id: unique_ak("REV"), secret_key: "issuer-secret")

    {:ok, session} =
      STS.issue_session(
        issuer_access_key_id: issuer.access_key_id,
        duration_seconds: 900,
        session_access_key_id: unique_session_ak("REV"),
        secret_key: "session-secret",
        session_token: "session-token"
      )

    output =
      capture_io(fn ->
        Sts.RevokeSession.run(["--access-key", session.access_key_id, "--json"])
      end)

    assert %{"status" => "revoked", "access_key_id" => access_key_id} = Jason.decode!(output)
    assert access_key_id == session.access_key_id
    refute output =~ "session-secret"
    refute output =~ "session-token"

    again =
      capture_io(fn ->
        Sts.RevokeSession.run(["--access-key", session.access_key_id])
      end)

    assert again =~ "status=revoked"
  end

  test "invalid args raise usage before work starts" do
    assert_raise Mix.Error, ~r/usage: mix maxio\.sts\.list_sessions/, fn ->
      Sts.ListSessions.run(["unexpected"])
    end
  end

  defp unique_ak(prefix), do: "AKIA#{prefix}#{System.unique_integer([:positive])}"
  defp unique_session_ak(prefix), do: "ASIA#{prefix}#{System.unique_integer([:positive])}"
end
