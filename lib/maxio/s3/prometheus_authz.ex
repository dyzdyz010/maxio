defmodule Maxio.S3.PrometheusAuthz do
  @moduledoc """
  Authorization for MinIO-style Prometheus metrics scrape requests.

  This is intentionally identity-policy only. Bucket policies and ACLs cannot
  grant cluster-wide admin actions, but session policy boundaries still apply.
  """

  import Plug.Conn, only: [assign: 3]

  alias Maxio.Policy.{Evaluator, RequestContext, Store}
  alias Maxio.S3.Authz

  @action "admin:Prometheus"
  @resource "arn:aws:s3:::*"

  @spec authorize(Plug.Conn.t(), map()) :: :ok | {:error, atom()}
  def authorize(conn, principal) when is_map(principal) do
    authenticated? = principal != :anonymous
    conn = assign(conn, :principal, principal)
    conditions = Authz.conditions_for(conn, authenticated?)

    ctx = %RequestContext{
      principal: principal,
      authenticated?: authenticated?,
      owner?: root?(principal),
      action: @action,
      resource: @resource,
      conditions: conditions
    }

    case Evaluator.evaluate(ctx, Store.principal_policies(principal)) do
      :allow ->
        if Authz.session_policy_allows?(principal, @action, @resource, conditions) do
          :ok
        else
          {:error, :session_policy}
        end

      {:deny, reason} ->
        {:error, reason}
    end
  end

  def authorize(_conn, _principal), do: {:error, :implicit_deny}

  defp root?(%{type: :root}), do: true
  defp root?(_principal), do: false
end
