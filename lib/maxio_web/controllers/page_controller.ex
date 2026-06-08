defmodule MaxioWeb.PageController do
  use MaxioWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
