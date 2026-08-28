defmodule Mix.Tasks.MaxioConfigTest do
  @moduledoc """
  `mix maxio.config.*` 的 CLI 取证回归（AGENTS.md §4.4：后端无 GUI，必须 CLI 可完整调试）。

  最关键的一条是 `set` 必须把 `applied` 打出来——**写成功 ≠ 生效**，运维只从 CLI 输出
  就要能分辨"下一次读就生效"和"已持久化但要重启"。
  """
  use Maxio.DataCase, async: false

  import ExUnit.CaptureIO

  alias Maxio.Config
  alias Maxio.Config.{RuntimeConfig, Store}
  alias Mix.Tasks.Maxio.Admin.Config.Get, as: AdminConfigGet
  alias Mix.Tasks.Maxio.Admin.Config.Set, as: AdminConfigSet

  setup do
    Store.reset_local!()
    on_exit(fn -> Store.reset_local!() end)
    :ok
  end

  test "list 打印全部白名单键的生效值、来源与 apply 模式" do
    out = capture_io(fn -> Mix.Tasks.Maxio.Config.List.run([]) end)

    assert out =~ "subsystem=listing key=sql_hard_limit"
    assert out =~ "source=compile"
    assert out =~ "apply=hot"
    assert out =~ "subsystem=cluster key=deployment_id"
  end

  test "list --json 输出可解析且逐键带三层取证" do
    out = capture_io(fn -> Mix.Tasks.Maxio.Config.List.run(["--json"]) end)
    %{"entries" => entries} = Jason.decode!(out)

    entry = Enum.find(entries, &(&1["subsystem"] == "listing" and &1["key"] == "sql_hard_limit"))
    assert entry["source"] == "compile"
    assert entry["apply"] == "hot"
    assert entry["version"] == nil
    assert Map.has_key?(entry, "runtime_value")
    assert Map.has_key?(entry, "env_value")
    assert Map.has_key?(entry, "app_env_value")
  end

  test "set 打印 applied，且 get 能看到运行时覆盖生效" do
    set_out =
      capture_io(fn ->
        Mix.Tasks.Maxio.Config.Set.run(["listing", "sql_hard_limit", "4242"])
      end)

    assert set_out =~ "applied=hot"
    assert set_out =~ "version=1"
    assert set_out =~ "source=cli"

    get_out = capture_io(fn -> Mix.Tasks.Maxio.Config.Get.run(["listing", "sql_hard_limit"]) end)
    assert get_out =~ "value=4242"
    assert get_out =~ "source=runtime"

    assert Config.get(:listing, :sql_hard_limit) == 4242
  end

  test "旧 CLI 在 KVS mutation 后保留 expected-version 并与新 GET 互操作" do
    # Catches the new KVS path writing a second authority, or removing optimistic version checks
    # from the existing single-key CLI while migrating both writers to the shared coordinator.
    admin_output =
      capture_io(fn ->
        apply(AdminConfigSet, :run, [["listing sql_hard_limit=4242"]])
      end)

    assert admin_output ==
             "committed=true changed_count=1 apply_modes=hot local_reload=ok broadcast=ok " <>
               "attention=false\n"

    old_output =
      capture_io(fn ->
        Mix.Tasks.Maxio.Config.Set.run([
          "listing",
          "sql_hard_limit",
          "5252",
          "--expected-version",
          "1"
        ])
      end)

    assert old_output =~ "version=2"
    assert old_output =~ "source=cli"

    conflict_output =
      capture_io(fn ->
        error =
          assert_raise Mix.Error, fn ->
            Mix.Tasks.Maxio.Config.Set.run([
              "listing",
              "sql_hard_limit",
              "6262",
              "--expected-version",
              "1"
            ])
          end

        send(self(), {:old_cli_version_conflict, error.message})
      end)

    assert conflict_output == ""
    assert_receive {:old_cli_version_conflict, message}
    assert message =~ "config_version_conflict"

    assert capture_io(fn -> apply(AdminConfigGet, :run, [["listing"]]) end) ==
             "listing sql_hard_limit=5252 \n"

    assert Repo.one(
             from row in RuntimeConfig,
               where: row.subsystem == "listing" and row.key == "sql_hard_limit",
               select: {row.value, row.version, row.source}
           ) == {%{"v" => 5252}, 2, "cli"}
  end

  test "set 未知键 / 禁止键 / 非法值一律硬失败，绝不静默成功" do
    assert_raise Mix.Error, ~r/unknown_config_key/, fn ->
      Mix.Tasks.Maxio.Config.Set.run(["listing", "nope", "1"])
    end

    assert_raise Mix.Error, ~r/forbidden_config_key/, fn ->
      Mix.Tasks.Maxio.Config.Set.run(["sse", "master_key", "leak"])
    end

    assert_raise Mix.Error, ~r/invalid_config_value/, fn ->
      Mix.Tasks.Maxio.Config.Set.run(["listing", "sql_hard_limit", "not-an-int"])
    end
  end

  test "reset 回落到 app env" do
    capture_io(fn -> Mix.Tasks.Maxio.Config.Set.run(["listing", "sql_hard_limit", "7"]) end)
    assert Config.get(:listing, :sql_hard_limit) == 7

    out = capture_io(fn -> Mix.Tasks.Maxio.Config.Reset.run(["listing", "sql_hard_limit"]) end)
    assert out =~ "changed=true"

    assert Config.get(:listing, :sql_hard_limit) ==
             Application.get_env(:maxio, :listing)[:sql_hard_limit]
  end

  test "history 打印审计流水" do
    capture_io(fn -> Mix.Tasks.Maxio.Config.Set.run(["listing", "sql_hard_limit", "7"]) end)
    capture_io(fn -> Mix.Tasks.Maxio.Config.Set.run(["listing", "sql_hard_limit", "8"]) end)

    out = capture_io(fn -> Mix.Tasks.Maxio.Config.History.run(["listing", "sql_hard_limit"]) end)

    assert out =~ "operation=set"
    assert out =~ "to_version=2"
    assert out =~ "to_version=1"
  end

  test "status 报告本节点快照版本、PG 权威版本与漂移" do
    capture_io(fn -> Mix.Tasks.Maxio.Config.Set.run(["listing", "sql_hard_limit", "7"]) end)

    out = capture_io(fn -> Mix.Tasks.Maxio.Config.Status.run(["--json"]) end)
    status = Jason.decode!(out)

    assert status["drifted"] == false
    assert status["orphan_config_keys"] == []
    assert status["local"]["count"] == 1
    assert status["authoritative"]["count"] == 1
  end
end
