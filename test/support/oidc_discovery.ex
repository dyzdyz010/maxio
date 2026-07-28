defmodule Maxio.Test.OIDCDiscovery do
  @moduledoc false

  @behaviour Maxio.IAM.OIDCDiscovery

  @impl true
  def discover(issuer_url, _opts) do
    if pid = Application.get_env(:maxio, :oidc_discovery_notify) do
      send(pid, {:oidc_discovery_called, issuer_url})
    end

    fixtures = Application.get_env(:maxio, :oidc_discovery_fixtures, %{})

    case Map.fetch(fixtures, issuer_url) do
      {:ok, {:error, reason}} -> {:error, reason}
      {:ok, discovery} -> {:ok, discovery}
      :error -> {:error, :oidc_discovery_http_error}
    end
  end
end
