defmodule MaxioWeb.ConsoleAuthTest do
  use MaxioWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  @root_ak "AKIAIOSFODNN7EXAMPLE"
  @root_sk "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"

  describe "verify_credentials/2" do
    test "正确 root 凭据 → {:ok, principal}" do
      assert {:ok, %{type: :root, access_key: @root_ak}} =
               MaxioWeb.ConsoleAuth.verify_credentials(@root_ak, @root_sk)
    end

    test "错误 secret → :error" do
      assert :error = MaxioWeb.ConsoleAuth.verify_credentials(@root_ak, "wrong")
    end

    test "未知 access_key → :error" do
      assert :error = MaxioWeb.ConsoleAuth.verify_credentials("AKIANOPE", "x")
    end

    test "非字符串 → :error" do
      assert :error = MaxioWeb.ConsoleAuth.verify_credentials(nil, nil)
    end
  end

  describe "GET /login" do
    test "渲染登录表单", %{conn: conn} do
      conn = get(conn, ~p"/login")
      html = html_response(conn, 200)
      assert html =~ "login-form"
      assert html =~ "Access Key"
    end
  end

  describe "POST /login" do
    test "正确凭据 → 设 session 并重定向 /", %{conn: conn} do
      conn = post(conn, ~p"/login", creds: %{access_key: @root_ak, secret_key: @root_sk})
      assert redirected_to(conn) == ~p"/"
      assert get_session(conn, "console_access_key") == @root_ak
    end

    test "错误凭据 → 渲染错误，不设 session", %{conn: conn} do
      conn = post(conn, ~p"/login", creds: %{access_key: @root_ak, secret_key: "nope"})
      assert html_response(conn, 200) =~ "login-error"
      refute get_session(conn, "console_access_key")
    end
  end

  describe "DELETE /logout" do
    test "清 session 跳 /login", %{conn: conn} do
      conn = conn |> log_in_console() |> delete(~p"/logout")
      assert redirected_to(conn) == ~p"/login"

      # drop: true 在响应发送时丢弃 session cookie；回收 conn 发起后续请求验证 session 真被清。
      conn = conn |> recycle() |> get(~p"/login")
      refute get_session(conn, "console_access_key")
    end
  end

  describe "on_mount 鉴权门控" do
    test "未登录访问 / 重定向到 /login", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/login"}}} = live(conn, ~p"/")
    end

    test "已登录可挂载 Dashboard", %{conn: conn} do
      {:ok, view, _html} = conn |> log_in_console() |> live(~p"/")
      assert has_element?(view, "#dashboard")
    end
  end
end
