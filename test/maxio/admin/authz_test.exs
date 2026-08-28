defmodule Maxio.Admin.AuthzTest do
  @moduledoc """
  `Maxio.Admin.Authz` 的授权立场回归（设计 D9）。

  这里补的是 HTTP 用例覆盖不到的两条边界：**STS session policy 边界**与
  **bucket policy 不能授予集群级 admin 动作**。两者都不是"顺带的"——

    * session policy 若不生效，一张临时凭据就能越过签发时声明的边界读整个集群的部署信息；
    * bucket policy 若能授予 `admin:ServerInfo`，任何一个桶的所有者都成了半个集群管理员。
  """
  use Maxio.DataCase, async: false

  alias Maxio.Admin.Authz
  alias Maxio.Auth.CredentialStore
  alias Maxio.Policy.{Statement, Store}
  alias Maxio.Test.SigV4Request

  @action "admin:ServerInfo"
  @ak "AKIAADMINAUTHZ0001"
  @arn "arn:aws:iam:::user/#{@ak}"

  defp conn, do: SigV4Request.anon_conn(:get, "/minio/admin/v3/info")

  defp put_key do
    :ok =
      CredentialStore.put_access_key(%{
        access_key: @ak,
        secret_key: "admin-authz-secret",
        principal: %{type: :iam_user, access_key: @ak, arn: @arn}
      })
  end

  defp principal(extra \\ %{}) do
    Map.merge(%{type: :iam_user, access_key: @ak, arn: @arn}, extra)
  end

  defp statements!(json) do
    {:ok, statements} = Statement.parse_identity_policy(json)
    statements
  end

  defp allow_identity! do
    :ok =
      Store.put_principal_policy(
        @arn,
        "admin-info",
        ~s({"Version":"2012-10-17","Statement":[{"Effect":"Allow","Action":"admin:ServerInfo"}]})
      )
  end

  test "root 短路放行" do
    assert Authz.authorize(conn(), %{type: :root, arn: "arn:aws:iam:::root"}, @action) == :ok
  end

  test "匿名 principal 是 implicit_deny（绝不靠形状推断）" do
    assert Authz.authorize(conn(), :anonymous, @action) == {:error, :implicit_deny}
  end

  test "identity policy 允许即放行；无 policy 即拒绝" do
    put_key()
    assert {:error, _reason} = Authz.authorize(conn(), principal(), @action)

    allow_identity!()
    assert Authz.authorize(conn(), principal(), @action) == :ok
  end

  test "STS session policy 边界仍然生效：identity 允许但 session 不允许 → 拒绝" do
    put_key()
    allow_identity!()

    bounded =
      principal(%{
        session_policy_statements:
          statements!(
            ~s({"Version":"2012-10-17","Statement":[{"Effect":"Allow","Action":"s3:GetObject","Resource":"arn:aws:s3:::*"}]})
          )
      })

    assert Authz.authorize(conn(), bounded, @action) == {:error, :session_policy}
  end

  test "session policy 同时允许该 action 时放行（边界只收紧，不额外授予）" do
    put_key()
    allow_identity!()

    within =
      principal(%{
        session_policy_statements:
          statements!(
            ~s({"Version":"2012-10-17","Statement":[{"Effect":"Allow","Action":"admin:ServerInfo"}]})
          )
      })

    assert Authz.authorize(conn(), within, @action) == :ok
  end

  test "无法解析的 session policy 一律拒绝，绝不当成空边界放行" do
    put_key()
    allow_identity!()

    assert Authz.authorize(conn(), principal(%{session_policy_statements: :invalid}), @action) ==
             {:error, :session_policy}
  end

  test "bucket policy 授予 admin:ServerInfo 仍然拒绝（identity-policy only）" do
    put_key()

    # 桶策略把 admin action 授给该 principal——集群级动作绝不能由桶的所有者授予。
    :ok =
      Store.put_bucket_policy(
        "admin-authz-bucket",
        ~s({"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"AWS":"#{@arn}"},"Action":"admin:ServerInfo","Resource":"arn:aws:s3:::*"}]})
      )

    assert {:error, _reason} = Authz.authorize(conn(), principal(), @action)
  end

  test "admin:GetUser uses the same exact-action identity-only boundary" do
    put_key()
    allow_identity!()
    assert {:error, _reason} = Authz.authorize(conn(), principal(), "admin:GetUser")

    :ok =
      Store.put_principal_policy(
        @arn,
        "admin-user-info",
        ~s({"Version":"2012-10-17","Statement":[{"Effect":"Allow","Action":"admin:GetUser"}]})
      )

    assert Authz.authorize(conn(), principal(), "admin:GetUser") == :ok
  end
end
