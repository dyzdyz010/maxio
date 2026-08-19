defmodule Maxio.Admin.Authz do
  @moduledoc """
  `/minio/admin/*` 的 per-endpoint 授权（设计 D9）。

  结构逐条对齐 `Maxio.S3.PrometheusAuthz`——那不是巧合：MinIO 的 `admin:Prometheus` 与
  `admin:ServerInfo` 本来就是同一张 admin action 表里的两项，用两套授权代码只会让两者
  慢慢分叉。区别只有一个：action 名由调用方给出。

  三条与 Prometheus 面完全一致的立场：

    * **identity policy only**。bucket policy 与 ACL 绝不能授予集群级 admin 动作——
      桶的所有者不该因为拥有一个桶就能读整个集群的部署信息。
    * **STS session policy 边界仍然生效**：identity policy 放行之后还要过一次
      session policy，临时凭据不能越过签发时声明的边界。
    * **root 短路，但显式 Deny 仍优先**（Evaluator 的 Step 1 早于 owner 短路）。

  `admin:*` 前缀不需要 policy 层任何改动：`Maxio.Policy.Statement` 已为 admin action 开了
  "identity statement 的 Action 全是 admin:* 且缺 Resource 时补 Resource: *"的口子
  （MinIO 官方最小 admin policy 就是这个形态：`{"Effect":"Allow","Action":"admin:ServerInfo"}`）。
  """

  import Plug.Conn, only: [assign: 3]

  alias Maxio.Policy.{Evaluator, RequestContext, Store}
  alias Maxio.S3.Authz

  @resource "arn:aws:s3:::*"

  @doc "对给定 admin action 授权。允许即 `:ok`，否则 `{:error, reason}`（一律映射成 403 JSON）。"
  @spec authorize(Plug.Conn.t(), map(), String.t()) :: :ok | {:error, atom()}
  def authorize(conn, principal, action) when is_map(principal) and is_binary(action) do
    # is_map/1 守卫已排除 :anonymous（匿名走下面的 implicit_deny 子句），
    # 因此到这里的 principal 必然是已认证的 principal map。
    authenticated? = true
    conn = assign(conn, :principal, principal)
    conditions = Authz.conditions_for(conn, authenticated?)

    ctx = %RequestContext{
      principal: principal,
      authenticated?: authenticated?,
      owner?: root?(principal),
      action: action,
      resource: @resource,
      conditions: conditions
    }

    case Evaluator.evaluate(ctx, Store.principal_policies(principal)) do
      :allow ->
        if Authz.session_policy_allows?(principal, action, @resource, conditions) do
          :ok
        else
          {:error, :session_policy}
        end

      {:deny, reason} ->
        {:error, reason}
    end
  end

  def authorize(_conn, _principal, _action), do: {:error, :implicit_deny}

  defp root?(%{type: :root}), do: true
  defp root?(_principal), do: false
end
