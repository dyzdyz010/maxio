defmodule Maxio.IAMOIDCProviderRefreshTest do
  use Maxio.DataCase, async: false

  alias Maxio.IAM
  alias Maxio.IAM.OIDCProviderRefresh.Scheduler
  alias Maxio.STS

  @old_time ~U[2026-06-30 00:00:00Z]
  @new_time ~U[2026-07-01 00:00:00Z]

  setup do
    previous_discovery = Application.get_env(:maxio, :oidc_discovery, :__unset__)
    previous_fixtures = Application.get_env(:maxio, :oidc_discovery_fixtures, :__unset__)
    previous_notify = Application.get_env(:maxio, :oidc_discovery_notify, :__unset__)
    previous_scheduler = Application.get_env(:maxio, :iam_oidc_provider_jwks_refresh, :__unset__)

    Application.put_env(:maxio, :oidc_discovery, Maxio.Test.OIDCDiscovery)
    Application.put_env(:maxio, :oidc_discovery_fixtures, %{})
    Application.delete_env(:maxio, :oidc_discovery_notify)

    on_exit(fn ->
      restore_env(:oidc_discovery, previous_discovery)
      restore_env(:oidc_discovery_fixtures, previous_fixtures)
      restore_env(:oidc_discovery_notify, previous_notify)
      restore_env(:iam_oidc_provider_jwks_refresh, previous_scheduler)
    end)

    :ok
  end

  test "single-provider dry-run validates discovery without mutating the DB snapshot" do
    issuer = unique_issuer("dry-run")
    old_jwk = JOSE.JWK.generate_key({:rsa, 2048})
    new_jwk = JOSE.JWK.generate_key({:rsa, 2048})
    old_jwks = public_jwks(old_jwk, "old")
    new_jwks = public_jwks(new_jwk, "new")

    assert {:ok, provider} =
             IAM.create_oidc_provider(
               url: issuer,
               client_ids: ["sts.amazonaws.com"],
               thumbprints: [sha1_hex("root-ca")],
               jwks: old_jwks,
               jwks_fetched_at: @old_time
             )

    put_oidc_discovery_fixture(issuer, new_jwks, @new_time)

    assert {:ok, report} = IAM.refresh_oidc_provider_jwks(provider.provider_arn)
    assert report.status == :dry_run
    assert report.dry_run
    assert report.scanned == 1
    assert report.candidates == 1
    assert report.refreshed == 0
    assert [%{status: :would_refresh, key_count: 1}] = report.providers

    assert {:ok, unchanged} = IAM.get_oidc_provider(provider.provider_arn)
    assert unchanged.jwks == old_jwks
    assert DateTime.compare(unchanged.jwks_fetched_at, @old_time) == :eq
  end

  test "confirmed refresh updates JWKS and lets STS verify tokens signed by the new key" do
    issuer = unique_issuer("confirm")
    subject = "system:serviceaccount:maxio:writer"
    audience = "sts.amazonaws.com"
    old_jwk = JOSE.JWK.generate_key({:rsa, 2048})
    new_jwk = JOSE.JWK.generate_key({:rsa, 2048})
    old_jwks = public_jwks(old_jwk, "old")
    new_jwks = public_jwks(new_jwk, "new")

    assert {:ok, provider} =
             IAM.create_oidc_provider(
               url: issuer,
               client_ids: [audience],
               thumbprints: [sha1_hex("root-ca")],
               jwks: old_jwks,
               jwks_fetched_at: @old_time
             )

    put_oidc_discovery_fixture(issuer, new_jwks, @new_time)

    assert {:error, :invalid_signature} =
             new_jwk
             |> web_identity_token(issuer, subject, audience, kid: "new")
             |> STS.WebIdentity.verify()

    assert {:ok, report} =
             IAM.refresh_oidc_provider_jwks(provider.provider_arn, dry_run: false)

    assert report.status == :refreshed
    assert report.refreshed == 1

    assert {:ok, refreshed} = IAM.get_oidc_provider(provider.provider_arn)
    assert refreshed.jwks == new_jwks
    assert DateTime.compare(refreshed.jwks_fetched_at, @new_time) == :eq
    assert refreshed.discovery_document["jwks_uri"] == issuer <> "/keys"

    assert {:ok, verified} =
             new_jwk
             |> web_identity_token(issuer, subject, audience, kid: "new")
             |> STS.WebIdentity.verify()

    assert verified.provider_arn == provider.provider_arn
    assert verified.subject == subject
  end

  test "discovery failure and private JWKS leave the last known good snapshot intact" do
    issuer = unique_issuer("failure")
    old_jwk = JOSE.JWK.generate_key({:rsa, 2048})
    old_jwks = public_jwks(old_jwk, "old")

    assert {:ok, provider} =
             IAM.create_oidc_provider(
               url: issuer,
               client_ids: ["sts.amazonaws.com"],
               thumbprints: [sha1_hex("root-ca")],
               jwks: old_jwks,
               jwks_fetched_at: @old_time
             )

    put_oidc_discovery_error(issuer, :oidc_discovery_http_error)

    assert {:error, http_report} =
             IAM.refresh_oidc_provider_jwks(provider.provider_arn, dry_run: false)

    assert http_report.status == :failed
    assert [%{reason: :oidc_discovery_http_error}] = http_report.errors

    assert {:ok, after_http_failure} = IAM.get_oidc_provider(provider.provider_arn)
    assert after_http_failure.jwks == old_jwks
    assert DateTime.compare(after_http_failure.jwks_fetched_at, @old_time) == :eq

    put_oidc_discovery_fixture(issuer, %{
      "keys" => [private_jwk_map(JOSE.JWK.generate_key({:rsa, 2048}))]
    })

    assert {:error, private_report} =
             IAM.refresh_oidc_provider_jwks(provider.provider_arn, dry_run: false)

    assert private_report.status == :failed
    assert [%{reason: %{code: :invalid_oidc_provider_refresh}}] = private_report.errors

    assert {:ok, after_private_failure} = IAM.get_oidc_provider(provider.provider_arn)
    assert after_private_failure.jwks == old_jwks
    assert DateTime.compare(after_private_failure.jwks_fetched_at, @old_time) == :eq
  end

  test "TLS thumbprint mismatch leaves the last known good snapshot intact" do
    issuer = unique_issuer("thumbprint-mismatch")
    old_jwk = JOSE.JWK.generate_key({:rsa, 2048})
    new_jwk = JOSE.JWK.generate_key({:rsa, 2048})
    old_jwks = public_jwks(old_jwk, "old")
    new_jwks = public_jwks(new_jwk, "new")
    configured_thumbprint = sha1_hex("configured-chain")
    discovered_thumbprint = sha1_hex("rotated-chain")

    assert {:ok, provider} =
             IAM.create_oidc_provider(
               url: issuer,
               client_ids: ["sts.amazonaws.com"],
               thumbprints: [configured_thumbprint],
               jwks: old_jwks,
               jwks_fetched_at: @old_time
             )

    put_oidc_discovery_fixture(issuer, new_jwks, @new_time, thumbprints: [discovered_thumbprint])

    assert {:error, report} =
             IAM.refresh_oidc_provider_jwks(provider.provider_arn, dry_run: false)

    assert report.status == :failed
    assert [%{reason: :oidc_discovery_thumbprint_mismatch}] = report.errors

    assert {:ok, unchanged} = IAM.get_oidc_provider(provider.provider_arn)
    assert unchanged.jwks == old_jwks
    assert unchanged.thumbprints == [configured_thumbprint]
    assert DateTime.compare(unchanged.jwks_fetched_at, @old_time) == :eq
  end

  test "STS WebIdentity verification never calls the OIDC discoverer on key miss" do
    issuer = unique_issuer("no-network")
    subject = "system:serviceaccount:maxio:writer"
    audience = "sts.amazonaws.com"
    stored_jwk = JOSE.JWK.generate_key({:rsa, 2048})
    rotated_jwk = JOSE.JWK.generate_key({:rsa, 2048})

    assert {:ok, _provider} =
             IAM.create_oidc_provider(
               url: issuer,
               client_ids: [audience],
               thumbprints: [sha1_hex("root-ca")],
               jwks: public_jwks(stored_jwk, "stored")
             )

    Application.put_env(:maxio, :oidc_discovery_notify, self())
    put_oidc_discovery_fixture(issuer, public_jwks(rotated_jwk, "rotated"))

    assert {:error, :invalid_signature} =
             rotated_jwk
             |> web_identity_token(issuer, subject, audience, kid: "rotated")
             |> STS.WebIdentity.verify()

    refute_received {:oidc_discovery_called, ^issuer}
  end

  test "refresh_all skips fresh and disabled providers unless explicitly forced" do
    fresh_issuer = unique_issuer("fresh")
    stale_issuer = unique_issuer("stale")
    disabled_issuer = unique_issuer("disabled")

    fresh_jwks = public_jwks(JOSE.JWK.generate_key({:rsa, 2048}), "fresh-old")
    stale_jwks = public_jwks(JOSE.JWK.generate_key({:rsa, 2048}), "stale-old")
    disabled_jwks = public_jwks(JOSE.JWK.generate_key({:rsa, 2048}), "disabled-old")

    {:ok, fresh} =
      create_provider(fresh_issuer, fresh_jwks,
        jwks_fetched_at: @new_time,
        status: "active"
      )

    {:ok, stale} =
      create_provider(stale_issuer, stale_jwks,
        jwks_fetched_at: @old_time,
        status: "active"
      )

    {:ok, disabled} =
      create_provider(disabled_issuer, disabled_jwks,
        jwks_fetched_at: @old_time,
        status: "disabled"
      )

    put_oidc_discovery_fixture(
      fresh_issuer,
      public_jwks(JOSE.JWK.generate_key({:rsa, 2048}), "fresh-new")
    )

    stale_next = public_jwks(JOSE.JWK.generate_key({:rsa, 2048}), "stale-new")
    put_oidc_discovery_fixture(stale_issuer, stale_next)

    put_oidc_discovery_fixture(
      disabled_issuer,
      public_jwks(JOSE.JWK.generate_key({:rsa, 2048}), "disabled-new")
    )

    assert {:ok, report} =
             IAM.refresh_oidc_provider_jwks_if_due(
               dry_run: false,
               now: @new_time,
               refresh_after_seconds: 3_600
             )

    assert report.refreshed == 1

    assert Enum.any?(
             report.providers,
             &(&1.provider_arn == stale.provider_arn and &1.status == :refreshed)
           )

    assert {:ok, refreshed_stale} = IAM.get_oidc_provider(stale.provider_arn)
    assert refreshed_stale.jwks == stale_next

    assert {:ok, unchanged_fresh} = IAM.get_oidc_provider(fresh.provider_arn)
    assert unchanged_fresh.jwks == fresh_jwks

    assert {:ok, unchanged_disabled} = IAM.get_oidc_provider(disabled.provider_arn)
    assert unchanged_disabled.jwks == disabled_jwks
  end

  test "refresh_all applies due filtering before limit to avoid starving stale providers" do
    stale_issuer = unique_issuer("zz-stale")
    stale_old_jwks = public_jwks(JOSE.JWK.generate_key({:rsa, 2048}), "stale-old")
    stale_new_jwks = public_jwks(JOSE.JWK.generate_key({:rsa, 2048}), "stale-new")

    {:ok, fresh_a} =
      create_provider(
        unique_issuer("aa-fresh"),
        public_jwks(JOSE.JWK.generate_key({:rsa, 2048}), "fresh-a"),
        jwks_fetched_at: @new_time,
        status: "active"
      )

    {:ok, fresh_b} =
      create_provider(
        unique_issuer("ab-fresh"),
        public_jwks(JOSE.JWK.generate_key({:rsa, 2048}), "fresh-b"),
        jwks_fetched_at: @new_time,
        status: "active"
      )

    {:ok, stale} =
      create_provider(stale_issuer, stale_old_jwks,
        jwks_fetched_at: @old_time,
        status: "active"
      )

    put_oidc_discovery_fixture(stale_issuer, stale_new_jwks)

    assert {:ok, report} =
             IAM.refresh_oidc_provider_jwks_if_due(
               dry_run: false,
               now: @new_time,
               refresh_after_seconds: 3_600,
               limit: 1
             )

    assert report.scanned == 1
    assert report.refreshed == 1
    assert [%{provider_arn: provider_arn, status: :refreshed}] = report.providers
    assert provider_arn == stale.provider_arn

    assert {:ok, refreshed_stale} = IAM.get_oidc_provider(stale.provider_arn)
    assert refreshed_stale.jwks == stale_new_jwks

    assert {:ok, unchanged_fresh_a} = IAM.get_oidc_provider(fresh_a.provider_arn)
    assert {:ok, unchanged_fresh_b} = IAM.get_oidc_provider(fresh_b.provider_arn)
    refute unchanged_fresh_a.jwks == stale_new_jwks
    refute unchanged_fresh_b.jwks == stale_new_jwks
  end

  test "scheduler is disabled by default and cannot be forced to write without confirm_refresh" do
    parent = self()

    runner = fn opts ->
      send(parent, {:scheduler_runner_called, opts})
      {:ok, %{status: :dry_run, dry_run: Keyword.fetch!(opts, :dry_run), errors: []}}
    end

    pid =
      start_supervised!(
        {Scheduler,
         name: nil,
         enabled: false,
         runner: runner,
         confirm_refresh: false,
         run_opts: [dry_run: false],
         refresh_after_seconds: 60}
      )

    assert %{enabled: false, scheduled?: false, last_result: nil} = Scheduler.status(pid)

    assert {:ok, %{status: :dry_run, dry_run: true}} = Scheduler.run_now(pid, [])

    assert_receive {:scheduler_runner_called, opts}
    assert Keyword.fetch!(opts, :dry_run) == true
    assert Keyword.fetch!(opts, :refresh_after_seconds) == 60
  end

  test "enabled scheduler tick uses confirmed writes only with confirm_refresh true" do
    parent = self()

    runner = fn opts ->
      send(parent, {:scheduled_runner_called, opts})
      {:ok, %{status: :refreshed, dry_run: Keyword.fetch!(opts, :dry_run), errors: []}}
    end

    pid =
      start_supervised!(
        {Scheduler,
         name: nil,
         enabled: true,
         confirm_refresh: true,
         initial_delay_ms: 60_000,
         interval_ms: 60_000,
         runner: runner}
      )

    token = :sys.get_state(pid).timer_token
    send(pid, {:refresh_oidc_provider_jwks, token})
    _ = :sys.get_state(pid)

    assert_receive {:scheduled_runner_called, opts}
    assert Keyword.fetch!(opts, :dry_run) == false
    assert %{scheduled?: true, last_result: {:ok, %{status: :refreshed}}} = Scheduler.status(pid)
  end

  defp create_provider(issuer, jwks, opts) do
    IAM.create_oidc_provider(
      [
        url: issuer,
        client_ids: ["sts.amazonaws.com"],
        thumbprints: [sha1_hex("root-ca")],
        jwks: jwks
      ] ++ opts
    )
  end

  defp put_oidc_discovery_fixture(issuer, jwks, fetched_at \\ @new_time, opts \\ []) do
    fixture = %{
      discovery_document: %{
        "issuer" => issuer,
        "jwks_uri" => issuer <> "/keys"
      },
      jwks: jwks,
      jwks_fetched_at: fetched_at,
      thumbprints: Keyword.get(opts, :thumbprints, [])
    }

    fixtures = Application.get_env(:maxio, :oidc_discovery_fixtures, %{})
    Application.put_env(:maxio, :oidc_discovery_fixtures, Map.put(fixtures, issuer, fixture))
  end

  defp put_oidc_discovery_error(issuer, reason) do
    fixtures = Application.get_env(:maxio, :oidc_discovery_fixtures, %{})

    Application.put_env(
      :maxio,
      :oidc_discovery_fixtures,
      Map.put(fixtures, issuer, {:error, reason})
    )
  end

  defp public_jwks(jwk, kid) do
    {_metadata, public_jwk} = JOSE.JWK.to_public_map(jwk)
    %{"keys" => [Map.put(public_jwk, "kid", kid)]}
  end

  defp private_jwk_map(jwk) do
    case JOSE.JWK.to_map(jwk) do
      {_metadata, private_jwk} -> Map.put(private_jwk, "kid", "private")
      private_jwk when is_map(private_jwk) -> Map.put(private_jwk, "kid", "private")
    end
  end

  defp web_identity_token(jwk, issuer, subject, audience, opts) do
    now = DateTime.utc_now() |> DateTime.to_unix()
    kid = Keyword.get(opts, :kid, "maxio-test")

    claims = %{
      "iss" => issuer,
      "sub" => subject,
      "aud" => audience,
      "iat" => now,
      "exp" => now + 3_600
    }

    jwk
    |> JOSE.JWT.sign(%{"alg" => "RS256", "kid" => kid}, claims)
    |> JOSE.JWS.compact()
    |> elem(1)
  end

  defp sha1_hex(value), do: :crypto.hash(:sha, value) |> Base.encode16(case: :lower)

  defp unique_issuer(prefix) do
    "https://#{prefix}-#{System.unique_integer([:positive])}.oidc.example.test/tenant"
  end

  defp restore_env(key, :__unset__), do: Application.delete_env(:maxio, key)
  defp restore_env(key, value), do: Application.put_env(:maxio, key, value)
end
