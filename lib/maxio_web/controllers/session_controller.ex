defmodule MaxioWeb.SessionController do
  use MaxioWeb, :controller

  alias MaxioWeb.ConsoleAuth

  # GET /login：渲染登录表单（plain HTML，无 LiveView）。
  def new(conn, _params) do
    render(conn, :new, error_message: nil, page_title: "登录 maxio Console", layout: false)
  end

  # POST /login：校验凭据 → 设 session 跳转 /；失败回渲染错误（不泄露是 ak 还是 sk 错，铁律 3）。
  def create(conn, %{"creds" => %{"access_key" => ak, "secret_key" => sk}}) do
    case ConsoleAuth.verify_credentials(ak, sk) do
      {:ok, _principal} ->
        conn
        |> ConsoleAuth.log_in(ak)
        |> put_flash(:info, "登录成功")
        |> redirect(to: ~p"/")

      :error ->
        conn
        |> put_flash(:error, "Access Key 或 Secret Key 无效")
        |> render(:new, error_message: "凭据无效", page_title: "登录 maxio Console", layout: false)
    end
  end

  def create(conn, _params) do
    conn
    |> put_flash(:error, "缺少凭据")
    |> render(:new, error_message: "缺少凭据", page_title: "登录 maxio Console", layout: false)
  end

  # DELETE /logout：清 session 跳回 /login。
  def delete(conn, _params) do
    conn
    |> ConsoleAuth.log_out()
    |> put_flash(:info, "已登出")
    |> redirect(to: ~p"/login")
  end
end
