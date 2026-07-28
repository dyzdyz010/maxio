defmodule Maxio.IAMOIDCProviderTest do
  use Maxio.DataCase, async: false

  alias Maxio.IAM
  alias Maxio.IAM.OIDCProvider
  alias Maxio.STS

  test "persists OIDC providers and exposes active DB providers to STS WebIdentity" do
    issuer = unique_issuer("db")
    subject = "system:serviceaccount:maxio:writer"
    audience = "sts.amazonaws.com"
    jwk = JOSE.JWK.generate_key({:rsa, 2048})
    jwks = public_jwks(jwk)
    thumbprint = sha1_hex("root-ca")

    assert {:ok, provider} =
             IAM.create_oidc_provider(
               url: issuer,
               client_ids: [audience],
               thumbprints: [thumbprint],
               jwks: jwks
             )

    assert provider.issuer_url == issuer
    assert provider.client_ids == [audience]
    assert provider.thumbprints == [thumbprint]
    assert provider.jwks == jwks
    assert provider.provider_arn == elem(STS.WebIdentity.oidc_provider_arn(issuer), 1)

    assert [%{issuer: ^issuer, jwks: ^jwks}] = IAM.web_identity_providers_for_issuer(issuer)

    token = web_identity_token(jwk, issuer, subject, audience)

    assert {:ok, verified} = STS.WebIdentity.verify(token)
    assert verified.provider_arn == provider.provider_arn
    assert verified.subject == subject
    assert verified.audience == audience

    assert {:error, :unknown_identity_provider} =
             STS.WebIdentity.verify(token, stored_providers?: false)
  end

  test "creates OIDC providers with discovered TLS thumbprints and rejects mismatches" do
    previous_discovery = Application.get_env(:maxio, :oidc_discovery, :__unset__)
    previous_fixtures = Application.get_env(:maxio, :oidc_discovery_fixtures, :__unset__)

    Application.put_env(:maxio, :oidc_discovery, Maxio.Test.OIDCDiscovery)
    Application.put_env(:maxio, :oidc_discovery_fixtures, %{})

    try do
      issuer = unique_issuer("discovered-thumbprint")
      jwks = public_jwks(JOSE.JWK.generate_key({:rsa, 2048}))
      issuer_thumbprint = sha1_hex("issuer-chain")
      jwks_thumbprint = sha1_hex("jwks-chain")

      put_oidc_discovery_fixture(issuer, jwks, thumbprints: [issuer_thumbprint, jwks_thumbprint])

      assert {:ok, provider} =
               IAM.create_oidc_provider(
                 url: issuer,
                 client_ids: ["sts.amazonaws.com"]
               )

      assert provider.thumbprints == [issuer_thumbprint, jwks_thumbprint]
      assert provider.jwks == jwks

      mismatch_issuer = unique_issuer("thumbprint-mismatch")
      put_oidc_discovery_fixture(mismatch_issuer, jwks, thumbprints: [jwks_thumbprint])

      assert {:error, :oidc_discovery_thumbprint_mismatch} =
               IAM.create_oidc_provider(
                 url: mismatch_issuer,
                 client_ids: ["sts.amazonaws.com"],
                 thumbprints: [issuer_thumbprint]
               )
    after
      restore_env(:oidc_discovery, previous_discovery)
      restore_env(:oidc_discovery_fixtures, previous_fixtures)
    end
  end

  test "updates OIDC provider client ids, thumbprints and rejects invalid lifecycle changes" do
    issuer = unique_issuer("lifecycle")
    jwk = JOSE.JWK.generate_key({:rsa, 2048})
    thumbprint = sha1_hex("initial")

    assert {:ok, provider} =
             IAM.create_oidc_provider(
               url: issuer <> "/",
               client_ids: ["sts.amazonaws.com"],
               thumbprints: [thumbprint],
               jwks: public_jwks(jwk)
             )

    assert provider.issuer_url == issuer

    assert {:ok, with_console} =
             IAM.add_oidc_provider_client_id(provider.provider_arn, "console.maxio.test")

    assert with_console.client_ids == ["sts.amazonaws.com", "console.maxio.test"]

    assert {:ok, idempotent} =
             IAM.add_oidc_provider_client_id(provider.provider_arn, "console.maxio.test")

    assert idempotent.client_ids == with_console.client_ids

    replacement_thumbprints = [sha1_hex("next-a"), sha1_hex("next-b")]

    assert {:ok, updated_thumbprints} =
             IAM.update_oidc_provider_thumbprints(provider.provider_arn, replacement_thumbprints)

    assert updated_thumbprints.thumbprints == replacement_thumbprints

    assert {:ok, disabled} = IAM.update_oidc_provider_status(provider.provider_arn, "disabled")
    assert disabled.status == "disabled"

    assert {:error, %Ecto.Changeset{} = status_changeset} =
             IAM.update_oidc_provider_status(provider.provider_arn, "paused")

    assert %{status: [_message]} = errors_on(status_changeset)

    assert {:ok, active} = IAM.update_oidc_provider_status(provider.provider_arn, "active")
    assert active.status == "active"

    assert {:ok, removed_console} =
             IAM.remove_oidc_provider_client_id(provider.provider_arn, "console.maxio.test")

    assert removed_console.client_ids == ["sts.amazonaws.com"]

    assert {:error, %Ecto.Changeset{} = changeset} =
             IAM.remove_oidc_provider_client_id(provider.provider_arn, "sts.amazonaws.com")

    assert %{client_ids: [_message]} = errors_on(changeset)

    assert :ok = IAM.delete_oidc_provider(provider.provider_arn)
    assert IAM.get_oidc_provider(provider.provider_arn) == :error
    assert IAM.web_identity_providers_for_issuer(issuer) == []
  end

  test "DB OIDC providers take precedence over static config and disabled rows fail closed" do
    issuer = unique_issuer("precedence")
    subject = "system:serviceaccount:maxio:writer"
    audience = "sts.amazonaws.com"
    db_jwk = JOSE.JWK.generate_key({:rsa, 2048})
    static_jwk = JOSE.JWK.from_oct("static-secret")
    previous = Application.get_env(:maxio, :web_identity_providers, :__unset__)

    static_provider = %{
      issuer: issuer,
      client_ids: [audience],
      jwks: [static_jwk],
      allowed_algs: ["HS256"]
    }

    try do
      Application.put_env(:maxio, :web_identity_providers, [static_provider])

      assert {:ok, provider} =
               IAM.create_oidc_provider(
                 url: issuer,
                 client_ids: [audience],
                 thumbprints: [sha1_hex("root-ca")],
                 jwks: public_jwks(db_jwk)
               )

      db_token = web_identity_token(db_jwk, issuer, subject, audience)
      static_token = web_identity_token(static_jwk, issuer, subject, audience, alg: "HS256")

      assert {:ok, verified} = STS.WebIdentity.verify(db_token)
      assert verified.provider_arn == provider.provider_arn
      assert {:error, :invalid_signature} = STS.WebIdentity.verify(static_token)

      provider_row = Repo.get_by!(OIDCProvider, provider_arn: provider.provider_arn)

      provider_row
      |> Ecto.Changeset.change(status: "disabled")
      |> Repo.update!()

      assert {:error, :identity_provider_disabled} = STS.WebIdentity.verify(db_token)
      assert {:error, :identity_provider_disabled} = STS.WebIdentity.verify(static_token)
    after
      case previous do
        :__unset__ -> Application.delete_env(:maxio, :web_identity_providers)
        value -> Application.put_env(:maxio, :web_identity_providers, value)
      end
    end
  end

  test "rejects malformed JWKS during create and manual JWKS replacement" do
    issuer = unique_issuer("malformed")

    assert {:error, :invalid_provider_issuer} =
             IAM.oidc_provider_arn(String.replace_prefix(issuer, "https://", "https://evil@"))

    assert {:error, %Ecto.Changeset{} = userinfo_changeset} =
             IAM.create_oidc_provider(
               url: String.replace_prefix(issuer, "https://", "https://evil@"),
               client_ids: ["sts.amazonaws.com"],
               thumbprints: [sha1_hex("root-ca")],
               jwks: public_jwks(JOSE.JWK.generate_key({:rsa, 2048}))
             )

    refute userinfo_changeset.valid?

    assert {:error, %Ecto.Changeset{} = create_changeset} =
             IAM.create_oidc_provider(
               url: issuer,
               client_ids: ["sts.amazonaws.com"],
               thumbprints: [sha1_hex("root-ca")],
               jwks: %{"keys" => [%{"kty" => "unsupported"}]}
             )

    assert %{jwks: [_message]} = errors_on(create_changeset)

    assert {:ok, provider} =
             IAM.create_oidc_provider(
               url: issuer,
               client_ids: ["sts.amazonaws.com"],
               thumbprints: [sha1_hex("root-ca")],
               jwks: public_jwks(JOSE.JWK.generate_key({:rsa, 2048}))
             )

    assert {:error, %Ecto.Changeset{} = replace_changeset} =
             IAM.set_oidc_provider_jwks(provider.provider_arn, %{
               "keys" => [%{"kty" => "unsupported"}]
             })

    assert %{jwks: [_message]} = errors_on(replace_changeset)
  end

  test "rejects secret JWKS material and redacts legacy secret keys from public projections" do
    private_issuer = unique_issuer("private-jwks")
    oct_issuer = unique_issuer("oct-jwks")

    assert {:error, %Ecto.Changeset{} = private_changeset} =
             IAM.create_oidc_provider(
               url: private_issuer,
               client_ids: ["sts.amazonaws.com"],
               thumbprints: [sha1_hex("root-ca")],
               jwks: %{"keys" => [private_jwk_map(JOSE.JWK.generate_key({:rsa, 2048}))]}
             )

    assert %{jwks: [_message]} = errors_on(private_changeset)

    assert {:error, %Ecto.Changeset{} = oct_changeset} =
             IAM.create_oidc_provider(
               url: oct_issuer,
               client_ids: ["sts.amazonaws.com"],
               thumbprints: [sha1_hex("root-ca")],
               jwks: %{"keys" => [%{"kty" => "oct", "k" => "legacy-secret", "kid" => "oct"}]}
             )

    assert %{jwks: [_message]} = errors_on(oct_changeset)

    assert {:error, %Ecto.Changeset{} = ec_changeset} =
             IAM.create_oidc_provider(
               url: unique_issuer("ec-private-jwks"),
               client_ids: ["sts.amazonaws.com"],
               thumbprints: [sha1_hex("root-ca")],
               jwks: %{"keys" => [ec_private_jwk()]}
             )

    assert %{jwks: [_message]} = errors_on(ec_changeset)

    assert {:error, %Ecto.Changeset{} = okp_changeset} =
             IAM.create_oidc_provider(
               url: unique_issuer("okp-private-jwks"),
               client_ids: ["sts.amazonaws.com"],
               thumbprints: [sha1_hex("root-ca")],
               jwks: %{"keys" => [okp_private_jwk()]}
             )

    assert %{jwks: [_message]} = errors_on(okp_changeset)

    legacy_key_material = "oct-key-material-do-not-leak"
    legacy_issuer = unique_issuer("legacy-oct")
    {:ok, legacy_provider_arn} = STS.WebIdentity.oidc_provider_arn(legacy_issuer)
    {:ok, legacy_host_path} = STS.WebIdentity.issuer_host_path(legacy_issuer)

    Repo.insert!(%OIDCProvider{
      provider_arn: legacy_provider_arn,
      issuer_url: legacy_issuer,
      issuer_host_path: legacy_host_path,
      client_ids: ["sts.amazonaws.com"],
      thumbprints: [sha1_hex("root-ca")],
      jwks: %{"keys" => [%{"kty" => "oct", "k" => legacy_key_material, "kid" => "oct"}]},
      jwks_fetched_at: DateTime.utc_now()
    })

    assert {:ok, public_provider} = IAM.get_oidc_provider(legacy_provider_arn)
    assert public_provider.jwks == %{"keys" => []}
    refute inspect(public_provider) =~ legacy_key_material

    assert [
             %{
               issuer: ^legacy_issuer,
               client_ids: ["sts.amazonaws.com"],
               jwks: %{"keys" => []}
             }
           ] = IAM.web_identity_providers_for_issuer(legacy_issuer)
  end

  defp public_jwks(jwk) do
    {_metadata, public_jwk} = JOSE.JWK.to_public_map(jwk)
    %{"keys" => [Map.put(public_jwk, "kid", "maxio-test")]}
  end

  defp private_jwk_map(jwk) do
    case JOSE.JWK.to_map(jwk) do
      {_metadata, private_jwk} -> Map.put(private_jwk, "kid", "maxio-test")
      private_jwk when is_map(private_jwk) -> Map.put(private_jwk, "kid", "maxio-test")
    end
  end

  defp ec_private_jwk do
    %{
      "kty" => "EC",
      "crv" => "P-256",
      "x" => b64url32("ec-x"),
      "y" => b64url32("ec-y"),
      "d" => b64url32("ec-d"),
      "kid" => "ec-private"
    }
  end

  defp okp_private_jwk do
    %{
      "kty" => "OKP",
      "crv" => "Ed25519",
      "x" => b64url32("okp-x"),
      "d" => b64url32("okp-d"),
      "kid" => "okp-private"
    }
  end

  defp b64url32(seed) do
    :crypto.hash(:sha256, seed)
    |> Base.url_encode64(padding: false)
  end

  defp web_identity_token(jwk, issuer, subject, audience, opts \\ []) do
    now = DateTime.utc_now() |> DateTime.to_unix()
    alg = Keyword.get(opts, :alg, "RS256")

    claims = %{
      "iss" => issuer,
      "sub" => subject,
      "aud" => audience,
      "iat" => now,
      "exp" => now + 3_600
    }

    jwk
    |> JOSE.JWT.sign(%{"alg" => alg, "kid" => "maxio-test"}, claims)
    |> JOSE.JWS.compact()
    |> elem(1)
  end

  defp sha1_hex(value), do: :crypto.hash(:sha, value) |> Base.encode16(case: :lower)

  defp unique_issuer(prefix) do
    "https://#{prefix}-#{System.unique_integer([:positive])}.oidc.example.test/tenant"
  end

  defp put_oidc_discovery_fixture(issuer, jwks, opts) do
    fixture = %{
      discovery_document: %{
        "issuer" => issuer,
        "jwks_uri" => issuer <> "/keys"
      },
      jwks: jwks,
      jwks_fetched_at: Keyword.get(opts, :jwks_fetched_at, DateTime.utc_now()),
      thumbprints: Keyword.get(opts, :thumbprints, [])
    }

    fixtures = Application.get_env(:maxio, :oidc_discovery_fixtures, %{})
    Application.put_env(:maxio, :oidc_discovery_fixtures, Map.put(fixtures, issuer, fixture))
  end

  defp restore_env(key, :__unset__), do: Application.delete_env(:maxio, key)
  defp restore_env(key, value), do: Application.put_env(:maxio, key, value)
end
