defmodule MaxioWeb.IdpLiveTest do
  use MaxioWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Maxio.Auth.CredentialStore
  alias Maxio.IAM

  setup %{conn: conn} do
    {:ok, conn: log_in_console(conn)}
  end

  test "mounts OIDC provider console", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/idp")

    assert has_element?(view, "#nav-idp")
    assert has_element?(view, "#oidc-providers")
    assert has_element?(view, "#oidc-providers-empty")
    assert has_element?(view, "#create-oidc-provider-form")
    assert has_element?(view, "#create-oidc-provider-submit")
  end

  test "rejects non-root console principals", %{conn: conn} do
    access_key = unique_access_key("CONSOLEIDPUSER")

    :ok =
      CredentialStore.put_access_key(%{
        access_key: access_key,
        secret_key: "non-root-secret",
        principal: %{
          type: :iam_user,
          access_key: access_key,
          arn: "arn:aws:iam:::user/#{access_key}"
        }
      })

    try do
      assert {:error, {:redirect, %{to: "/"}}} = live(log_in_console(conn, access_key), ~p"/idp")
    after
      CredentialStore.invalidate({:access_key, access_key})
    end
  end

  test "creates and deletes an OIDC provider", %{conn: conn} do
    issuer = unique_issuer("console-create")
    provider_arn = elem(IAM.oidc_provider_arn(issuer), 1)
    suffix = dom_suffix(provider_arn)

    {:ok, view, _html} = live(conn, ~p"/idp")

    view
    |> form("#create-oidc-provider-form",
      provider: %{
        issuer_url: issuer,
        client_ids: "sts.amazonaws.com\nconsole.maxio.test",
        thumbprints: sha1_hex("root-ca"),
        jwks_json: Jason.encode!(public_jwks("create")),
        status: "active"
      }
    )
    |> render_submit()

    assert has_element?(view, "#oidc-provider-#{suffix}")

    assert {:ok, provider} = IAM.get_oidc_provider(provider_arn)
    assert provider.issuer_url == issuer
    assert provider.client_ids == ["sts.amazonaws.com", "console.maxio.test"]

    view |> element("#delete-oidc-provider-#{suffix}") |> render_click()

    refute has_element?(view, "#oidc-provider-#{suffix}")
    assert :error = IAM.get_oidc_provider(provider_arn)
  end

  test "rejects invalid provider create payload", %{conn: conn} do
    issuer = "http://console-invalid.example.test/tenant"

    {:ok, view, _html} = live(conn, ~p"/idp")

    html =
      view
      |> form("#create-oidc-provider-form",
        provider: %{
          issuer_url: issuer,
          client_ids: "",
          thumbprints: "not-a-thumbprint",
          jwks_json: "{",
          status: "active"
        }
      )
      |> render_submit()

    assert html =~ "Issuer URL must be an HTTPS URL with a host"
    assert has_element?(view, "#oidc-providers-empty")
    assert IAM.list_oidc_providers() == []
  end

  test "rejects forged invalid provider create status", %{conn: conn} do
    issuer = unique_issuer("console-invalid-status")

    {:ok, view, _html} = live(conn, ~p"/idp")

    html =
      render_submit(view, "create_provider", %{
        "provider" => %{
          "issuer_url" => issuer,
          "client_ids" => "sts.amazonaws.com",
          "thumbprints" => sha1_hex("root-ca"),
          "jwks_json" => Jason.encode!(public_jwks("invalid-status")),
          "status" => "paused"
        }
      })

    assert html =~ "OIDC provider status is invalid"
    assert IAM.get_oidc_provider(issuer) == :error
  end

  test "selected provider can add and remove client IDs", %{conn: conn} do
    issuer = unique_issuer("console-client")

    {:ok, provider} =
      IAM.create_oidc_provider(
        url: issuer,
        client_ids: ["sts.amazonaws.com", "console.maxio.test"],
        thumbprints: [sha1_hex("root-ca")],
        jwks: public_jwks("client")
      )

    provider_suffix = dom_suffix(provider.provider_arn)
    extra_suffix = dom_suffix("app.maxio.test")

    {:ok, view, _html} = live(conn, ~p"/idp")

    view |> element("#select-oidc-provider-#{provider_suffix}") |> render_click()

    assert has_element?(view, "#oidc-provider-detail-panel")
    assert has_element?(view, "#oidc-client-id-#{dom_suffix("sts.amazonaws.com")}")

    view
    |> form("#oidc-client-id-form", client: %{client_id: "app.maxio.test"})
    |> render_submit()

    assert has_element?(view, "#oidc-client-id-#{extra_suffix}")

    assert {:ok, updated} = IAM.get_oidc_provider(provider.provider_arn)
    assert "app.maxio.test" in updated.client_ids

    view |> element("#remove-oidc-client-id-#{extra_suffix}") |> render_click()

    refute has_element?(view, "#oidc-client-id-#{extra_suffix}")

    assert {:ok, removed} = IAM.get_oidc_provider(provider.provider_arn)
    refute "app.maxio.test" in removed.client_ids
  end

  test "rejects removing the final client ID without clearing detail", %{conn: conn} do
    issuer = unique_issuer("console-final-client")

    {:ok, provider} =
      IAM.create_oidc_provider(
        url: issuer,
        client_ids: ["sts.amazonaws.com"],
        thumbprints: [sha1_hex("root-ca")],
        jwks: public_jwks("final-client")
      )

    provider_suffix = dom_suffix(provider.provider_arn)
    client_suffix = dom_suffix("sts.amazonaws.com")

    {:ok, view, _html} = live(conn, ~p"/idp")
    view |> element("#select-oidc-provider-#{provider_suffix}") |> render_click()

    html = view |> element("#remove-oidc-client-id-#{client_suffix}") |> render_click()

    assert html =~ "Remove OIDC client ID failed"
    assert has_element?(view, "#oidc-provider-detail-panel")
    assert has_element?(view, "#oidc-client-id-#{client_suffix}")

    assert {:ok, current} = IAM.get_oidc_provider(provider.provider_arn)
    assert current.client_ids == ["sts.amazonaws.com"]
  end

  test "updates thumbprints, JWKS snapshot and status", %{conn: conn} do
    issuer = unique_issuer("console-update")

    {:ok, provider} =
      IAM.create_oidc_provider(
        url: issuer,
        client_ids: ["sts.amazonaws.com"],
        thumbprints: [sha1_hex("root-ca")],
        jwks: public_jwks("initial")
      )

    provider_suffix = dom_suffix(provider.provider_arn)
    replacement_thumbprint = sha1_hex("replacement-ca")
    replacement_jwks = public_jwks("replacement")

    {:ok, view, _html} = live(conn, ~p"/idp")
    view |> element("#select-oidc-provider-#{provider_suffix}") |> render_click()

    view
    |> form("#oidc-thumbprints-form", thumbprints: %{values: replacement_thumbprint})
    |> render_submit()

    assert has_element?(view, "#oidc-thumbprint-#{dom_suffix(replacement_thumbprint)}")

    view
    |> form("#oidc-jwks-form", jwks: %{json: Jason.encode!(replacement_jwks)})
    |> render_submit()

    view
    |> form("#oidc-provider-status-form", status: %{status: "disabled"})
    |> render_submit()

    assert {:ok, updated} = IAM.get_oidc_provider(provider.provider_arn)
    assert updated.thumbprints == [replacement_thumbprint]
    assert updated.jwks == replacement_jwks
    assert updated.jwks_fetched_at
    assert updated.status == "disabled"
    assert render(view) =~ "disabled"

    html = render_submit(view, "update_status", %{"status" => %{"status" => "paused"}})

    assert html =~ "OIDC provider status is invalid"
    assert {:ok, still_disabled} = IAM.get_oidc_provider(provider.provider_arn)
    assert still_disabled.status == "disabled"
  end

  test "detail panel does not pre-render JWKS key material", %{conn: conn} do
    issuer = unique_issuer("console-jwks-material")
    raw_key_id = "raw-key-id-not-rendered"

    {:ok, provider} =
      IAM.create_oidc_provider(
        url: issuer,
        client_ids: ["sts.amazonaws.com"],
        thumbprints: [sha1_hex("root-ca")],
        jwks: public_jwks(raw_key_id)
      )

    {:ok, view, _html} = live(conn, ~p"/idp")

    view
    |> element("#select-oidc-provider-#{dom_suffix(provider.provider_arn)}")
    |> render_click()

    refute render(view) =~ raw_key_id
    assert has_element?(view, "#oidc-jwks-key-count")
  end

  defp public_jwks(kid) do
    jwk = JOSE.JWK.generate_key({:rsa, 2048})
    {_metadata, public_jwk} = JOSE.JWK.to_public_map(jwk)
    %{"keys" => [Map.put(public_jwk, "kid", kid)]}
  end

  defp sha1_hex(value), do: :crypto.hash(:sha, value) |> Base.encode16(case: :lower)

  defp unique_access_key(prefix), do: "AKIA#{prefix}#{System.unique_integer([:positive])}"

  defp unique_issuer(prefix) do
    "https://#{prefix}-#{System.unique_integer([:positive])}.oidc.example.test/tenant"
  end

  defp dom_suffix(value), do: Base.encode16(to_string(value), case: :lower)
end
