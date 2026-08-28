defmodule Maxio.DataCase do
  @moduledoc """
  This module defines the setup for tests requiring
  access to the application's data layer.

  You may define functions here to be used as helpers in
  your tests.

  Finally, if the test case interacts with the database,
  we enable the SQL sandbox, so changes done to the database
  are reverted at the end of every test. If you are using
  PostgreSQL, you can even run database tests asynchronously
  by setting `use Maxio.DataCase, async: true`, although
  this option is not recommended for other databases.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      alias Maxio.Repo

      import Ecto
      import Ecto.Changeset
      import Ecto.Query
      import Maxio.DataCase
    end
  end

  setup tags do
    Maxio.DataCase.setup_sandbox(tags)
    :ok
  end

  @doc """
  Sets up the sandbox based on the test tags.

  这里同时**结构性地**隔离运行时配置快照，见 `reset_runtime_config_snapshot/0`：
  `MaxioWeb.ConnCase` 也调本函数，所以它是唯一同时覆盖两个 case template 的收口点。
  """
  def setup_sandbox(tags) do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(Maxio.Repo, shared: not tags[:async])
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
    reset_runtime_config_snapshot()
  end

  @doc """
  把本节点的运行时配置快照恢复成"空"（= 全部键回落 Application env），测试前后各一次。

  ## 为什么这必须是结构性保证，而不是各测试自觉

  `Maxio.Config.set/4` 提交事务后会**同步**在调用方进程里重装 `:persistent_term` 快照
  （`Maxio.Config.finish_write/5`）。`:persistent_term` 是**节点全局**的，不属于 Ecto
  sandbox 的事务，所以测试结束回滚 DB 行时，快照里的值**原样留着**：下一个测试模块读到的
  是上一个模块写下的覆盖值，而 PG 里那一行早已不存在。`config/test.exs` 的
  `subscribe: false` 只堵住了异步广播那条通路，堵不住这条同步通路。

  在此之前，不出事完全靠"每个碰过配置的测试文件恰好都在 `on_exit` 里清了快照"——那是纪律，
  不是保证。放在这里，忘记清理的新测试也污染不了别人。
  """
  @spec reset_runtime_config_snapshot() :: :ok
  def reset_runtime_config_snapshot do
    Maxio.Config.Store.reset_local!()
    on_exit(&Maxio.Config.Store.reset_local!/0)
    :ok
  end

  @doc """
  Creates a concrete IAM user and a long-term access key bound to that user.

  Policy-bearing tests must use the returned `user_arn` instead of synthesizing
  an ARN from an otherwise legacy access-key-only fixture.
  """
  def create_user_with_access_key!(opts \\ []) do
    suffix = System.unique_integer([:positive, :monotonic])
    access_key_id = Keyword.get(opts, :access_key_id, "AKIATEST#{suffix}")
    user_name = Keyword.get(opts, :user_name, access_key_id)
    secret_key = Keyword.get(opts, :secret_key, "test-secret-#{suffix}")

    {:ok, user} =
      Maxio.IAM.create_user(
        name: user_name,
        status: Keyword.get(opts, :user_status, "active"),
        tags: Keyword.get(opts, :user_tags, %{})
      )

    {:ok, access_key} =
      Maxio.IAM.create_access_key(
        access_key_id: access_key_id,
        secret_key: secret_key,
        principal_arn: user.user_arn,
        status: Keyword.get(opts, :access_key_status, "active"),
        tags: Keyword.get(opts, :access_key_tags, %{})
      )

    %{
      user: user,
      user_arn: user.user_arn,
      access_key: access_key,
      access_key_id: access_key.access_key_id,
      principal_arn: user.user_arn,
      secret_key: secret_key
    }
  end

  @doc """
  A helper that transforms changeset errors into a map of messages.

      assert {:error, changeset} = Accounts.create_user(%{password: "short"})
      assert "password is too short" in errors_on(changeset).password
      assert %{password: ["password is too short"]} = errors_on(changeset)

  """
  def errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
