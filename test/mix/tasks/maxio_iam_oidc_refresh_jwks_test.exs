defmodule Mix.Tasks.MaxioIamOIDCRefreshJwksTest do
  use Maxio.DataCase, async: false

  import ExUnit.CaptureIO

  alias Maxio.IAM
  alias Mix.Tasks.Maxio.Iam.Oidc.RefreshJwks

  @task "maxio.iam.oidc.refresh_jwks"
  @old_time ~U[2026-06-30 00:00:00Z]
  @new_time ~U[2026-07-01 00:00:00Z]

  setup do
    previous_discovery = Application.get_env(:maxio, :oidc_discovery, :__unset__)
    previous_fixtures = Application.get_env(:maxio, :oidc_discovery_fixtures, :__unset__)

    Application.put_env(:maxio, :oidc_discovery, Maxio.Test.OIDCDiscovery)
    Application.put_env(:maxio, :oidc_discovery_fixtures, %{})
    Mix.Task.reenable(@task)

    on_exit(fn ->
      restore_env(:oidc_discovery, previous_discovery)
      restore_env(:oidc_discovery_fixtures, previous_fixtures)
      Mix.Task.reenable(@task)
    end)

    :ok
  end

  test "CLI defaults to dry-run and confirm writes the refreshed JWKS" do
    issuer = unique_issuer("cli")
    old_jwks = public_jwks(JOSE.JWK.generate_key({:rsa, 2048}), "cli-old")
    new_jwks = public_jwks(JOSE.JWK.generate_key({:rsa, 2048}), "cli-new")

    assert {:ok, provider} =
             IAM.create_oidc_provider(
               url: issuer,
               client_ids: ["sts.amazonaws.com"],
               thumbprints: [sha1_hex("root-ca")],
               jwks: old_jwks,
               jwks_fetched_at: @old_time
             )

    put_oidc_discovery_fixture(issuer, new_jwks)

    dry_output =
      capture_io(fn ->
        RefreshJwks.run(["--provider", provider.provider_arn, "--json"])
      end)

    assert %{
             "status" => "dry_run",
             "dry_run" => true,
             "scanned" => 1,
             "refreshed" => 0
           } = Jason.decode!(dry_output)

    refute dry_output =~ "cli-new"
    assert {:ok, unchanged} = IAM.get_oidc_provider(provider.provider_arn)
    assert unchanged.jwks == old_jwks

    Mix.Task.reenable(@task)

    confirm_output =
      capture_io(fn ->
        RefreshJwks.run(["--provider", provider.provider_arn, "--confirm"])
      end)

    assert confirm_output =~ "[maxio iam.oidc.refresh_jwks] status=refreshed"
    assert confirm_output =~ "refreshed=1"

    assert {:ok, refreshed} = IAM.get_oidc_provider(provider.provider_arn)
    assert refreshed.jwks == new_jwks
  end

  test "CLI all mode supports due-only refresh and rejects conflicting arguments" do
    issuer = unique_issuer("cli-all")
    old_jwks = public_jwks(JOSE.JWK.generate_key({:rsa, 2048}), "cli-all-old")
    new_jwks = public_jwks(JOSE.JWK.generate_key({:rsa, 2048}), "cli-all-new")

    assert {:ok, provider} =
             IAM.create_oidc_provider(
               url: issuer,
               client_ids: ["sts.amazonaws.com"],
               thumbprints: [sha1_hex("root-ca")],
               jwks: old_jwks,
               jwks_fetched_at: @old_time
             )

    put_oidc_discovery_fixture(issuer, new_jwks)

    output =
      capture_io(fn ->
        RefreshJwks.run([
          "--all",
          "--confirm",
          "--refresh-after-seconds",
          "3600",
          "--limit",
          "10",
          "--json"
        ])
      end)

    assert %{"status" => "refreshed", "refreshed" => 1} = Jason.decode!(output)
    assert {:ok, refreshed} = IAM.get_oidc_provider(provider.provider_arn)
    assert refreshed.jwks == new_jwks

    Mix.Task.reenable(@task)

    assert_raise Mix.Error, ~r/--dry-run and --confirm are mutually exclusive/, fn ->
      RefreshJwks.run(["--all", "--dry-run", "--confirm"])
    end

    Mix.Task.reenable(@task)

    assert_raise Mix.Error, ~r/usage: mix maxio\.iam\.oidc\.refresh_jwks/, fn ->
      RefreshJwks.run(["--all", "--issuer", issuer])
    end
  end

  test "CLI failure prints sanitized report and raises" do
    issuer = unique_issuer("cli-failure")
    old_jwks = public_jwks(JOSE.JWK.generate_key({:rsa, 2048}), "cli-failure-old")
    leaked_marker = "private-key-material-must-not-print"

    assert {:ok, provider} =
             IAM.create_oidc_provider(
               url: issuer,
               client_ids: ["sts.amazonaws.com"],
               thumbprints: [sha1_hex("root-ca")],
               jwks: old_jwks,
               jwks_fetched_at: @old_time
             )

    put_oidc_discovery_fixture(issuer, %{
      "keys" => [
        %{
          "kty" => "oct",
          "kid" => "private",
          "k" => leaked_marker
        }
      ]
    })

    {output, error} =
      capture_mix_error(fn ->
        RefreshJwks.run(["--issuer", issuer, "--confirm", "--json"])
      end)

    assert %{"status" => "failed", "failed" => 1} = Jason.decode!(output)
    refute output =~ leaked_marker
    refute error =~ leaked_marker

    assert {:ok, unchanged} = IAM.get_oidc_provider(provider.provider_arn)
    assert unchanged.jwks == old_jwks
  end

  defp capture_mix_error(fun) do
    parent = self()

    output =
      capture_io(fn ->
        try do
          fun.()
        rescue
          error in Mix.Error -> send(parent, {:mix_error, error.message})
        end
      end)

    assert_receive {:mix_error, message}
    {output, message}
  end

  defp put_oidc_discovery_fixture(issuer, jwks) do
    fixture = %{
      discovery_document: %{
        "issuer" => issuer,
        "jwks_uri" => issuer <> "/keys"
      },
      jwks: jwks,
      jwks_fetched_at: @new_time
    }

    fixtures = Application.get_env(:maxio, :oidc_discovery_fixtures, %{})
    Application.put_env(:maxio, :oidc_discovery_fixtures, Map.put(fixtures, issuer, fixture))
  end

  defp public_jwks(jwk, kid) do
    {_metadata, public_jwk} = JOSE.JWK.to_public_map(jwk)
    %{"keys" => [Map.put(public_jwk, "kid", kid)]}
  end

  defp sha1_hex(value), do: :crypto.hash(:sha, value) |> Base.encode16(case: :lower)

  defp unique_issuer(prefix) do
    "https://#{prefix}-#{System.unique_integer([:positive])}.oidc.example.test/tenant"
  end

  defp restore_env(key, :__unset__), do: Application.delete_env(:maxio, key)
  defp restore_env(key, value), do: Application.put_env(:maxio, key, value)
end
