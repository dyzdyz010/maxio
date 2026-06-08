defmodule MaxioWeb.ConnCase do
  @moduledoc """
  This module defines the test case to be used by
  tests that require setting up a connection.

  Such tests rely on `Phoenix.ConnTest` and also
  import other functionality to make it easier
  to build common data structures and query the data layer.

  Finally, if the test case interacts with the database,
  we enable the SQL sandbox, so changes done to the database
  are reverted at the end of every test. If you are using
  PostgreSQL, you can even run database tests asynchronously
  by setting `use MaxioWeb.ConnCase, async: true`, although
  this option is not recommended for other databases.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      # The default endpoint for testing
      @endpoint MaxioWeb.Endpoint

      use MaxioWeb, :verified_routes

      # Import conveniences for testing with connections
      import Plug.Conn
      import Phoenix.ConnTest
      import MaxioWeb.ConnCase
    end
  end

  @doc """
  返回一个已登录 Console 的 conn：session 里塞 "console_access_key"。
  默认用 test 环境 MemoryStore 引导的 root（access_key=AKIAIOSFODNN7EXAMPLE，见 config/test.exs）。
  """
  def log_in_console(conn, access_key \\ "AKIAIOSFODNN7EXAMPLE") do
    Plug.Test.init_test_session(conn, %{"console_access_key" => access_key})
  end

  setup tags do
    Maxio.DataCase.setup_sandbox(tags)
    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end
end
