defmodule Maxio.IAM.SigningSecretRewriterTest do
  use Maxio.DataCase, async: false

  alias Maxio.Auth.CredentialStore.EctoStore
  alias Maxio.IAM
  alias Maxio.IAM.{AccessKey, AccessKeySecret, STSSession, STSSessionSecret}
  alias Maxio.STS

  test "dry-run reports and confirmed run rewrites access-key and STS envelopes to current key" do
    old_key = b64_secret("rewrite-old-key")
    new_key = b64_secret("rewrite-new-key")

    with_access_key_secret_config([current_key_id: "old", secret_key: old_key], fn ->
      {:ok, key} =
        IAM.create_access_key(access_key_id: unique_ak("REWRITE"), secret_key: "old-secret")

      {:ok, session} =
        STS.issue_session(
          issuer_access_key_id: key.access_key_id,
          session_access_key_id: unique_session_ak("REWRITE"),
          secret_key: "old-session-secret",
          session_token: "old-session-token",
          duration_seconds: 900
        )

      assert row_key_id(Repo.get_by!(AccessKey, access_key_id: key.access_key_id).secret_key) ==
               "old"

      assert row_key_id(Repo.get_by!(STSSession, access_key_id: session.access_key_id).secret_key) ==
               "old"

      with_access_key_secret_config(
        [current_key_id: "new", secret_key: new_key, keys: %{"old" => old_key}],
        fn ->
          assert {:ok, dry_run} = IAM.rewrap_signing_secrets()
          assert dry_run.status == :dry_run
          assert dry_run.dry_run
          assert dry_run.totals.scanned == 2
          assert dry_run.totals.candidates == 2
          assert dry_run.totals.rewrapped == 0
          assert dry_run.scopes.access_keys.stale_key == 1
          assert dry_run.scopes.sts_sessions.stale_key == 1

          assert row_key_id(Repo.get_by!(AccessKey, access_key_id: key.access_key_id).secret_key) ==
                   "old"

          assert {:ok, report} = IAM.rewrap_signing_secrets(dry_run: false)
          assert report.status == :rewrapped
          assert report.totals.rewrapped == 2

          access_row = Repo.get_by!(AccessKey, access_key_id: key.access_key_id)
          session_row = Repo.get_by!(STSSession, access_key_id: session.access_key_id)
          assert row_key_id(access_row.secret_key) == "new"
          assert row_key_id(session_row.secret_key) == "new"

          assert {:ok, %{secret_key: "old-secret"}} = EctoStore.get_secret(key.access_key_id)

          assert {:ok, %{secret_key: "old-session-secret"}} =
                   EctoStore.get_secret(session.access_key_id,
                     session_token: "old-session-token",
                     now: DateTime.add(session.issued_at, 1, :second)
                   )
        end
      )

      with_access_key_secret_config([current_key_id: "new", secret_key: new_key], fn ->
        assert {:ok, %{secret_key: "old-secret"}} = EctoStore.get_secret(key.access_key_id)

        assert {:ok, %{secret_key: "old-session-secret"}} =
                 EctoStore.get_secret(session.access_key_id,
                   session_token: "old-session-token",
                   now: DateTime.add(session.issued_at, 1, :second)
                 )
      end)
    end)
  end

  test "legacy plaintext rows are rewritten without exposing plaintext in the report" do
    new_key = b64_secret("rewrite-legacy-new")
    access_key_id = unique_ak("LEGACYREWRITE")
    session_access_key_id = unique_session_ak("LEGACYREWRITE")

    with_access_key_secret_config([current_key_id: "new", secret_key: new_key], fn ->
      {:ok, issuer} =
        IAM.create_access_key(
          access_key_id: unique_ak("LEGACYISSUER"),
          secret_key: "issuer-secret"
        )

      Repo.insert!(%AccessKey{
        access_key_id: access_key_id,
        secret_key: "legacy-access-secret",
        principal_arn: IAM.user_arn(access_key_id),
        type: "iam_user",
        status: "active",
        tags: %{}
      })

      insert_sts_session_row!(
        issuer,
        session_access_key_id,
        "legacy-session-secret",
        "legacy-session-token"
      )

      {{:ok, report}, query_metadata} =
        capture_repo_query_metadata(fn -> IAM.rewrap_signing_secrets(dry_run: false) end)

      assert report.totals.legacy_plaintext == 2
      refute inspect(report) =~ "legacy-access-secret"
      refute inspect(report) =~ "legacy-session-secret"
      refute query_metadata_contains?(query_metadata, "legacy-access-secret")
      refute query_metadata_contains?(query_metadata, "legacy-session-secret")

      access_row = Repo.get_by!(AccessKey, access_key_id: access_key_id)
      session_row = Repo.get_by!(STSSession, access_key_id: session_access_key_id)
      assert AccessKeySecret.encrypted?(access_row.secret_key)
      assert STSSessionSecret.encrypted?(session_row.secret_key)
      assert row_key_id(access_row.secret_key) == "new"
      assert row_key_id(session_row.secret_key) == "new"
    end)
  end

  test "malformed access-key and STS envelopes block rewrite for both scopes" do
    new_key = b64_secret("rewrite-malformed-new")
    access_key_id = unique_ak("MALFORMED")
    session_access_key_id = unique_session_ak("MALFORMED")

    with_access_key_secret_config([current_key_id: "new", secret_key: new_key], fn ->
      {:ok, issuer} =
        IAM.create_access_key(
          access_key_id: unique_ak("MALFORMEDISSUER"),
          secret_key: "issuer-secret"
        )

      Repo.insert!(%AccessKey{
        access_key_id: access_key_id,
        secret_key: invalid_access_key_envelope("not-json-access-secret"),
        principal_arn: IAM.user_arn(access_key_id),
        type: "iam_user",
        status: "active",
        tags: %{}
      })

      insert_sts_session_row!(
        issuer,
        session_access_key_id,
        invalid_sts_session_envelope("not-json-session-secret"),
        "malformed-session-token"
      )

      assert {:error, report} = IAM.rewrap_signing_secrets(dry_run: false)
      assert report.status == :blocked
      assert report.totals.errors == 2
      assert report.scopes.access_keys.errors == 1
      assert report.scopes.sts_sessions.errors == 1
      refute inspect(report) =~ "not-json-access-secret"
      refute inspect(report) =~ "not-json-session-secret"
    end)
  end

  test "missing historical key blocks stale access-key and STS envelopes" do
    old_key = b64_secret("rewrite-missing-old")
    new_key = b64_secret("rewrite-missing-new")
    access_key_id = unique_ak("MISSINGKEY")
    session_access_key_id = unique_session_ak("MISSINGKEY")

    old_access_envelope =
      with_access_key_secret_config([current_key_id: "old", secret_key: old_key], fn ->
        {:ok, envelope} = AccessKeySecret.wrap("stale-access-secret", access_key_id)
        envelope
      end)

    old_session_envelope =
      with_access_key_secret_config([current_key_id: "old", secret_key: old_key], fn ->
        {:ok, envelope} = STSSessionSecret.wrap("stale-session-secret", session_access_key_id)
        envelope
      end)

    with_access_key_secret_config([current_key_id: "new", secret_key: new_key], fn ->
      {:ok, issuer} =
        IAM.create_access_key(
          access_key_id: unique_ak("MISSINGISSUER"),
          secret_key: "issuer-secret"
        )

      Repo.insert!(%AccessKey{
        access_key_id: access_key_id,
        secret_key: old_access_envelope,
        principal_arn: IAM.user_arn(access_key_id),
        type: "iam_user",
        status: "active",
        tags: %{}
      })

      insert_sts_session_row!(
        issuer,
        session_access_key_id,
        old_session_envelope,
        "missing-key-session-token"
      )

      assert {:error, report} = IAM.rewrap_signing_secrets(dry_run: false)
      assert report.status == :blocked
      assert report.totals.errors == 2

      reasons = Enum.map(report.totals.error_details, & &1.reason)
      assert :access_key_secret_key_not_configured in reasons
      assert :sts_session_secret_key_not_configured in reasons
    end)
  end

  test "invalid rows block the confirmed rewrite before any selected row is changed" do
    old_key = b64_secret("rewrite-block-old")
    new_key = b64_secret("rewrite-block-new")

    with_access_key_secret_config([current_key_id: "old", secret_key: old_key], fn ->
      {:ok, good} =
        IAM.create_access_key(access_key_id: unique_ak("BLOCKGOOD"), secret_key: "good-secret")

      Repo.insert!(%AccessKey{
        access_key_id: unique_ak("BLOCKBAD"),
        secret_key: "",
        principal_arn: IAM.user_arn("bad"),
        type: "iam_user",
        status: "active",
        tags: %{}
      })

      with_access_key_secret_config(
        [current_key_id: "new", secret_key: new_key, keys: %{"old" => old_key}],
        fn ->
          assert {:error, report} = IAM.rewrap_signing_secrets(dry_run: false)
          assert report.status == :blocked
          assert report.totals.errors == 1
          assert report.totals.rewrapped == 0

          good_row = Repo.get_by!(AccessKey, access_key_id: good.access_key_id)
          assert row_key_id(good_row.secret_key) == "old"
        end
      )
    end)
  end

  defp with_access_key_secret_config(config, fun) do
    original = Application.fetch_env!(:maxio, :access_key_secret)

    try do
      Application.put_env(:maxio, :access_key_secret, config)
      fun.()
    after
      Application.put_env(:maxio, :access_key_secret, original)
    end
  end

  defp b64_secret(label), do: :crypto.hash(:sha256, label) |> Base.encode64()
  defp unique_ak(prefix), do: "AKIA#{prefix}#{System.unique_integer([:positive])}"
  defp unique_session_ak(prefix), do: "ASIA#{prefix}#{System.unique_integer([:positive])}"

  defp invalid_access_key_envelope(payload) do
    "maxio-ak-secret-v1:" <> Base.url_encode64(payload, padding: false)
  end

  defp invalid_sts_session_envelope(payload) do
    "maxio-sts-secret-v1:" <> Base.url_encode64(payload, padding: false)
  end

  defp capture_repo_query_metadata(fun) do
    parent = self()
    handler_id = {__MODULE__, make_ref()}

    :ok =
      :telemetry.attach(
        handler_id,
        [:maxio, :repo, :query],
        fn _event, _measurements, metadata, _config ->
          send(parent, {:repo_query_metadata, metadata})
        end,
        nil
      )

    try do
      result = fun.()
      {result, drain_repo_query_metadata([])}
    after
      :telemetry.detach(handler_id)
    end
  end

  defp drain_repo_query_metadata(acc) do
    receive do
      {:repo_query_metadata, metadata} -> drain_repo_query_metadata([metadata | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp query_metadata_contains?(metadata, secret) do
    Enum.any?(metadata, fn event ->
      inspect(Map.get(event, :query)) =~ secret or inspect(Map.get(event, :params)) =~ secret
    end)
  end

  defp row_key_id(secret_key) do
    secret_key
    |> String.replace_prefix("maxio-ak-secret-v1:", "")
    |> String.replace_prefix("maxio-sts-secret-v1:", "")
    |> Base.url_decode64!(padding: false)
    |> Jason.decode!()
    |> Map.fetch!("key_id")
  end

  defp insert_sts_session_row!(issuer, access_key_id, secret_key, token) do
    now = DateTime.utc_now()

    Repo.insert!(%STSSession{
      access_key_id: access_key_id,
      secret_key: secret_key,
      session_token_sha256: Maxio.Auth.SessionToken.hash(token),
      issuer_access_key_id: issuer.access_key_id,
      principal_arn: issuer.principal_arn,
      principal_type: issuer.type,
      session_name: "legacy-session",
      status: "active",
      issued_at: now,
      expires_at: DateTime.add(now, 900, :second),
      tags: %{}
    })
  end
end
