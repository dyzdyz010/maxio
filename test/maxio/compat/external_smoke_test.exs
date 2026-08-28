defmodule Maxio.Compat.ExternalSmokeTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Maxio.Compat.ExternalSmoke

  @config %{
    endpoint: "http://127.0.0.1:9900",
    access_key: "test-access",
    secret_key: "super-secret",
    region: "us-east-1"
  }

  test "missing endpoint or credentials are attention evidence without invoking clients" do
    [entry] =
      ExternalSmoke.run(%{clients: ["aws_cli"]},
        executable_finder: fn _ -> raise "finder should not run" end,
        command_runner: fn _, _, _ -> raise "runner should not run" end
      )

    assert entry["status"] == "attention"

    assert [%{"reason" => "external_smoke_not_configured", "missing" => missing}] =
             entry["warnings"]

    assert "endpoint" in missing
    assert "access_key" in missing
    assert "secret_key" in missing
  end

  test "missing external executable is attention evidence" do
    [entry] =
      @config
      |> Map.put(:clients, ["aws_cli"])
      |> ExternalSmoke.run(
        executable_finder: fn "aws" -> nil end,
        command_runner: fn _, _, _ -> raise "runner should not run" end
      )

    assert entry["status"] == "attention"
    assert [%{"reason" => "external_smoke_client_not_configured"}] = entry["warnings"]
  end

  test "aws-cli smoke runs minimal CRUD and redacts artifact output" do
    owner = self()

    command_runner = fn command, args, opts ->
      send(owner, {:cmd, command, args, opts})

      cond do
        "put-object" in args ->
          payload_path = Enum.at(args, Enum.find_index(args, &(&1 == "--body")) + 1)
          Process.put(:payload, File.read!(payload_path))
          {"put ok super-secret test-access", 0}

        "copy-object" in args ->
          Process.put(:copied_payload, Process.get(:payload))
          {"copy ok", 0}

        "head-object" in args and "--query" in args ->
          {"deep-matrix\n", 0}

        "get-object" in args ->
          download_path = List.last(args)

          payload =
            if "--range" in args do
              Process.get(:payload) |> binary_part(0, 6)
            else
              Process.get(:payload)
            end

          File.write!(download_path, payload)
          {"get ok", 0}

        true ->
          {"ok super-secret test-access", 0}
      end
    end

    [entry] =
      @config
      |> Map.put(:clients, ["aws_cli"])
      |> ExternalSmoke.run(
        executable_finder: fn "aws" -> "aws.exe" end,
        command_runner: command_runner,
        tmp_root_fun: &tmp_root/0
      )

    assert entry["status"] == "ok"

    assert Enum.map(entry["steps"], & &1["id"]) == [
             "create_bucket",
             "head_bucket",
             "put_object",
             "head_object",
             "get_object",
             "get_object_range",
             "copy_object",
             "head_copied_object",
             "get_copied_object",
             "delete_copied_object",
             "delete_object",
             "delete_bucket"
           ]

    assert entry["scenario_counts"] == %{
             "bucket_lifecycle" => 2,
             "cleanup" => 3,
             "object_copy" => 3,
             "object_metadata" => 1,
             "object_write_read" => 2,
             "range_read" => 1
           }

    assert Enum.all?(entry["steps"], &is_binary(&1["scenario"]))
    assert Enum.all?(entry["steps"], &is_binary(&1["assertion"]))

    encoded = Jason.encode!(entry)
    refute encoded =~ "super-secret"
    refute encoded =~ "test-access"

    assert_received {:cmd, "aws.exe", ["--endpoint-url", "http://127.0.0.1:9900" | _], opts}
    refute Keyword.has_key?(opts, :stderr_to_stdout)
    assert {"AWS_ACCESS_KEY_ID", "test-access"} in Keyword.fetch!(opts, :env)
    assert {"AWS_SECRET_ACCESS_KEY", "super-secret"} in Keyword.fetch!(opts, :env)
    assert_loopback_bypass(opts, "127.0.0.1")

    assert_received {:cmd, "aws.exe",
                     [
                       "--endpoint-url",
                       "http://127.0.0.1:9900",
                       "--region",
                       "us-east-1",
                       "s3api",
                       "head-object" | head_args
                     ], _opts}

    assert "--query" in head_args
    assert "Metadata.\"maxio-smoke\"" in head_args
  end

  test "aws-cli smoke blocks when head-object metadata value is wrong" do
    command_runner = fn _command, args, _opts ->
      cond do
        "put-object" in args ->
          {"put ok", 0}

        "head-object" in args and "--query" in args ->
          {"wrong\n", 0}

        true ->
          {"ok", 0}
      end
    end

    [entry] =
      @config
      |> Map.put(:clients, ["aws_cli"])
      |> ExternalSmoke.run(
        executable_finder: fn "aws" -> "aws.exe" end,
        command_runner: command_runner,
        tmp_root_fun: &tmp_root/0
      )

    assert entry["status"] == "blocked"

    assert [%{"reason" => "external_smoke_body_mismatch", "step" => "head_object"}] =
             entry["blockers"]
  end

  test "nonzero external command is blocked evidence" do
    owner = self()

    command_runner = fn command, args, opts ->
      send(owner, {:cmd, command, args, opts})

      cond do
        "put-object" in args ->
          {"put failed", 3}

        true ->
          {"ok", 0}
      end
    end

    [entry] =
      @config
      |> Map.put(:clients, ["aws_cli"])
      |> ExternalSmoke.run(
        executable_finder: fn "aws" -> "aws.exe" end,
        command_runner: command_runner,
        tmp_root_fun: &tmp_root/0
      )

    assert entry["status"] == "blocked"

    assert [%{"reason" => "external_smoke_step_failed", "step" => "put_object"}] =
             entry["blockers"]

    assert Enum.map(entry["steps"], & &1["id"]) == [
             "create_bucket",
             "head_bucket",
             "put_object",
             "delete_bucket"
           ]

    assert_received {:cmd, "aws.exe", ["--endpoint-url", "http://127.0.0.1:9900" | _], _opts}
  end

  test "external command exception is error evidence" do
    [entry] =
      @config
      |> Map.put(:clients, ["aws_cli"])
      |> ExternalSmoke.run(
        executable_finder: fn "aws" -> "aws.exe" end,
        command_runner: fn _, _, _ -> raise "boom super-secret" end,
        tmp_root_fun: &tmp_root/0
      )

    assert entry["status"] == "error"

    assert [%{"reason" => "external_smoke_command_failed", "message" => message}] =
             entry["blockers"]

    assert message =~ "boom"
    refute Jason.encode!(entry) =~ "super-secret"
  end

  test "mc fixture capability redacts its temporary credentials before runner invocation" do
    owner = self()
    fixture_secret = "fixture-secret-that-must-not-leak"
    raw_mc_host = "http://fixture-user:#{fixture_secret}@127.0.0.1:9900"
    base_runner = successful_mc_runner()

    echoing_runner = fn command, args, opts ->
      {_config_dir, _json?, [subcommand | _command_args]} = parse_mc_args(args, opts)
      result = base_runner.(command, args, opts)

      if subcommand == "ls" do
        send(owner, :fixture_mc_host_echoed)
        {stdout, stderr, exit_status} = normalize_test_command_result(result)
        {stdout, stderr <> " runner opts=" <> inspect(opts), exit_status}
      else
        result
      end
    end

    fixture =
      fixture_opts(owner)
      |> Keyword.put(:mc_probe, fn probe ->
        opts =
          Keyword.update!(probe.opts, :env, fn env ->
            Enum.reject(env, &(elem(&1, 0) == "MC_HOST_#{probe.alias}")) ++
              [{"MC_HOST_#{probe.alias}", raw_mc_host}]
          end)

        {:external_command_capability, [fixture_secret, raw_mc_host],
         fn command_runner ->
           args = if probe.json?, do: ["--json", "ls", probe.alias], else: ["ls", probe.alias]
           command_runner.(probe.executable, args, opts)
         end}
      end)

    {entry, log} =
      with_log(fn ->
        [entry] =
          @config
          |> Map.put(:clients, ["minio_mc"])
          |> ExternalSmoke.run(
            executable_finder: fn "mc" -> "mc.exe" end,
            command_runner: echoing_runner,
            tmp_root_fun: &tmp_root/0,
            admin_user_fixture_opts: fixture
          )

        entry
      end)

    assert_receive :fixture_mc_host_echoed

    for evidence <- [Jason.encode!(entry), log] do
      refute evidence =~ fixture_secret
      refute evidence =~ raw_mc_host
    end
  end

  test "mc smoke keeps credentials in env and redacts output snippets" do
    tmp_root = tmp_root()
    on_exit(fn -> File.rm_rf(tmp_root) end)
    Process.put(:mc_calls, [])

    command_runner = fn command, args, opts ->
      {config_dir, json?, [subcommand | command_args]} = parse_mc_args(args, opts)

      Process.put(:mc_calls, [{command, args, opts} | Process.get(:mc_calls)])

      File.mkdir_p!(config_dir)
      File.write!(Path.join(config_dir, "initialized-by-mc"), "temporary")

      cond do
        subcommand == "ls" ->
          allowed? =
            Process.get(:admin_fixture_status) == :enabled and
              Process.get(:admin_fixture_policy_attached) == true

          cond do
            allowed? -> {"", "", 0}
            json? -> {Jason.encode!(%{"status" => "error"}) <> "\n", "", 1}
            true -> {"", "mc: <ERROR> Unable to list folder. Access Denied.\n", 1}
          end

        subcommand == "admin" and Enum.take(command_args, 2) == ["policy", "create"] ->
          ["policy", "create", _mc_alias, policy_name, policy_path] = command_args
          Process.put(:policy_name, policy_name)
          Process.put(:policy_fixture, File.read!(policy_path))

          if json? do
            {json_policy_output(policy_name), 0}
          else
            {"Created policy `#{policy_name}` successfully.\n", 0}
          end

        subcommand == "admin" and Enum.take(command_args, 2) == ["policy", "ls"] ->
          {Process.get(:policy_name), 0}

        subcommand == "admin" and Enum.take(command_args, 2) == ["policy", "info"] ->
          ["policy", "info", _mc_alias, policy_name] = command_args
          {"PolicyName: #{policy_name}", 0}

        subcommand == "admin" and Enum.take(command_args, 2) == ["policy", "attach"] ->
          ["policy", "attach", _mc_alias | association_args] = command_args

          {policies, ["--user", user_name]} =
            Enum.split_while(association_args, &(&1 != "--user"))

          Process.put(:admin_fixture_policy_attached, true)

          if json? do
            {json_association_output(:attach, policies, user_name), "", 0}
          else
            {"Attached Policies: [#{Enum.join(policies, " ")}]\nTo User: #{user_name}\n", "", 0}
          end

        subcommand == "admin" and Enum.take(command_args, 2) == ["policy", "detach"] ->
          ["policy", "detach", _mc_alias | association_args] = command_args

          {policies, ["--user", user_name]} =
            Enum.split_while(association_args, &(&1 != "--user"))

          Process.put(:admin_fixture_policy_attached, false)

          if json? do
            {json_association_output(:detach, policies, user_name), "", 0}
          else
            {"Detached Policies: [#{Enum.join(policies, " ")}]\nFrom User: #{user_name}\n", "", 0}
          end

        subcommand == "admin" and Enum.take(command_args, 2) == ["policy", "entities"] ->
          policy_name = Process.get(:policy_name)
          user_name = Process.get(:admin_fixture_user)
          timestamp = "2026-08-28T01:02:03Z"

          if json? do
            {json_entities_output(policy_name, user_name, timestamp), "", 0}
          else
            {"Query time: #{timestamp}\nPolicy -> Entity Mappings:\n" <>
               "  Policy: #{policy_name}\n    User Mappings:\n      #{user_name}\n", "", 0}
          end

        subcommand == "admin" and Enum.take(command_args, 2) == ["policy", "rm"] ->
          policy_name = List.last(command_args)

          if json? do
            {json_policy_output(policy_name), "", 0}
          else
            {"Removed policy `#{policy_name}` successfully.\n", "", 0}
          end

        subcommand == "admin" and Enum.take(command_args, 2) == ["user", "list"] ->
          ["user", "list", _mc_alias] = command_args
          user_name = Process.get(:admin_fixture_user)
          send(self(), {:admin_user_list, user_name})
          {"#{user_name} enabled\nsuper-secret test-access", 0}

        subcommand == "admin" and Enum.take(command_args, 2) == ["user", "info"] ->
          ["user", "info", _mc_alias, user_name] = command_args
          send(self(), {:admin_user_info, user_name})

          if json? do
            status =
              if Process.get(:admin_fixture_status) == :disabled, do: "disabled", else: "enabled"

            {json_user_info_output(user_name, status), "", 0}
          else
            status =
              if user_name != @config.access_key and
                   Process.get(:admin_fixture_status) == :disabled,
                 do: "disabled",
                 else: "enabled"

            {human_user_info(user_name, status), "", 0}
          end

        subcommand == "admin" and
            Enum.take(command_args, 2) == ["user", "disable"] ->
          ["user", "disable", _mc_alias, user_name] = command_args
          Process.put(:admin_fixture_status, :disabled)

          if json? do
            {json_user_mutation_output(user_name), "", 0}
          else
            {"Disabled user `#{user_name}` successfully.\n", "", 0}
          end

        subcommand == "admin" and
            Enum.take(command_args, 2) == ["user", "enable"] ->
          ["user", "enable", _mc_alias, user_name] = command_args
          Process.put(:admin_fixture_status, :enabled)

          if json? do
            {json_user_mutation_output(user_name), "", 0}
          else
            {"Enabled user `#{user_name}` successfully.\n", "", 0}
          end

        subcommand == "admin" and
            Enum.take(command_args, 2) == ["user", "remove"] ->
          ["user", "remove", _mc_alias, user_name] = command_args

          if user_name == @config.access_key or Process.get(:admin_fixture_status) == :removed do
            {"",
             "mc: <ERROR> Unable to remove #{user_name}. The specified user does not exist. (Specified user does not exist).\n",
             1}
          else
            Process.put(:admin_fixture_status, :removed)

            if json? do
              {json_user_mutation_output(user_name), "", 0}
            else
              {"Removed user `#{user_name}` successfully.\n", "", 0}
            end
          end

        subcommand == "cp" and Enum.any?(command_args, &File.regular?/1) ->
          payload_path = Enum.find(command_args, &File.regular?/1)
          Process.put(:payload, File.read!(payload_path))
          {"copied super-secret test-access", 0}

        subcommand == "cp" ->
          Process.put(:copied_payload, Process.get(:payload))
          {"server side copied", 0}

        subcommand == "stat" ->
          {"Name: smoke.txt\nMetadata:\n  maxio-smoke: deep-matrix\n", 0}

        subcommand == "cat" ->
          {Process.get(:payload), 0}

        true ->
          {"ok super-secret test-access", 0}
      end
    end

    [entry] =
      @config
      |> Map.put(:clients, ["minio_mc"])
      |> ExternalSmoke.run(
        executable_finder: fn "mc" -> "mc.exe" end,
        command_runner: command_runner,
        tmp_root_fun: fn -> tmp_root end,
        admin_user_fixture_opts: fixture_opts(self())
      )

    assert entry["status"] == "ok"

    assert Enum.map(entry["steps"], & &1["id"]) == [
             "make_bucket",
             "put_object",
             "stat_object",
             "get_object",
             "copy_object",
             "stat_copied_object",
             "get_copied_object",
             "admin_policy_human_create",
             "admin_policy_human_list",
             "admin_policy_human_info",
             "admin_user_list",
             "admin_user_info",
             "admin_policy_human_mc_ls_baseline_denied",
             "admin_policy_human_attach",
             "admin_policy_human_mc_ls_attached",
             "admin_policy_human_attach_no_effect",
             "admin_policy_human_entities",
             "admin_policy_human_detach",
             "admin_policy_human_mc_ls_detached",
             "admin_policy_human_reattach",
             "admin_user_human_disable",
             "admin_user_human_info_disabled",
             "admin_user_human_mc_ls_disabled",
             "admin_user_human_enable",
             "admin_user_human_info_reenabled",
             "admin_user_human_mc_ls_reenabled",
             "admin_policy_human_cleanup_detach",
             "admin_user_human_remove",
             "admin_user_human_remove_again",
             "admin_user_human_remove_root",
             "admin_user_human_root_probe_after_remove_rejected",
             "admin_policy_human_remove",
             "delete_copied_object",
             "delete_object",
             "delete_bucket",
             "admin_user_fixture_cleanup_human",
             "admin_policy_json_create",
             "admin_user_json_info_enabled",
             "admin_policy_json_mc_ls_baseline_denied",
             "admin_policy_json_attach",
             "admin_policy_json_mc_ls_attached",
             "admin_policy_json_attach_no_effect",
             "admin_policy_json_entities",
             "admin_policy_json_detach",
             "admin_policy_json_mc_ls_detached",
             "admin_policy_json_reattach",
             "admin_user_json_disable",
             "admin_user_json_info_disabled",
             "admin_user_json_mc_ls_disabled",
             "admin_user_json_enable",
             "admin_user_json_info_reenabled",
             "admin_user_json_mc_ls_reenabled",
             "admin_policy_json_cleanup_detach",
             "admin_user_json_remove",
             "admin_policy_json_remove",
             "admin_user_fixture_cleanup_json"
           ]

    assert entry["scenario_counts"]["object_copy"] == 3
    assert entry["scenario_counts"]["admin_policy_lifecycle"] == 6
    assert entry["scenario_counts"]["admin_policy_association_lifecycle"] == 18
    assert entry["scenario_counts"]["admin_user_list"] == 1
    assert entry["scenario_counts"]["admin_user_info"] == 1
    assert entry["scenario_counts"]["admin_user_human_lifecycle"] == 10
    assert entry["scenario_counts"]["admin_user_json_lifecycle"] == 8

    encoded = Jason.encode!(entry)
    refute encoded =~ "super-secret"
    refute encoded =~ "test-access"

    calls = Process.get(:mc_calls) |> Enum.reverse()

    [{_command, _args, first_opts} | _rest] = calls

    {"MC_CONFIG_DIR", config_dir} =
      first_opts
      |> Keyword.fetch!(:env)
      |> Enum.find(&(elem(&1, 0) == "MC_CONFIG_DIR"))

    assert config_dir |> Path.dirname() |> Path.dirname() |> Path.expand() |> Path.split() ==
             tmp_root |> Path.expand() |> Path.split()

    assert length(calls) == 54

    Enum.each(calls, fn {command, args, opts} ->
      assert command == "mc.exe"
      refute Enum.any?(args, &String.contains?(&1, "super-secret"))
      refute "--config-dir" in args

      if "test-access" in args, do: assert(admin_user_action(args) == "remove")

      env = Keyword.fetch!(opts, :env)

      assert {"MC_HOST_maxiocompat", mc_host} =
               Enum.find(env, &(elem(&1, 0) == "MC_HOST_maxiocompat"))

      assert mc_host =~ "test-access"
      assert mc_host =~ "super-secret"

      {"MC_CONFIG_DIR", call_config_dir} =
        Enum.find(env, &(elem(&1, 0) == "MC_CONFIG_DIR"))

      if "--json" in args do
        assert hd(args) == "--json"
        assert call_config_dir == config_dir <> "-json"
      else
        assert call_config_dir == config_dir
      end

      assert_loopback_bypass(opts, "127.0.0.1")
    end)

    assert ["mb", _bucket] = elem(hd(calls), 1)

    assert [
             "cp",
             "--attr",
             "maxio-smoke=deep-matrix",
             _payload,
             _object
           ] = elem(Enum.at(calls, 1), 1)

    assert [
             "admin",
             "policy",
             "create",
             "maxiocompat",
             policy_name,
             policy_path
           ] = elem(Enum.at(calls, 7), 1)

    assert String.starts_with?(policy_name, "maxio-compat-policy-")
    assert Path.basename(policy_path) == "policy.json"

    assert Jason.decode!(Process.get(:policy_fixture)) == %{
             "Version" => "2012-10-17",
             "Statement" => %{
               "Effect" => "Allow",
               "Action" => "s3:ListAllMyBuckets",
               "Resource" => "*"
             }
           }

    assert ["admin", "policy", "ls", "maxiocompat"] =
             elem(Enum.at(calls, 8), 1)

    assert [
             "admin",
             "policy",
             "info",
             "maxiocompat",
             ^policy_name
           ] = elem(Enum.at(calls, 9), 1)

    assert [
             "admin",
             "user",
             "list",
             "maxiocompat"
           ] = elem(Enum.at(calls, 10), 1)

    assert [
             "admin",
             "user",
             "info",
             "maxiocompat",
             fixture_user
           ] = elem(Enum.at(calls, 11), 1)

    assert_received {:admin_fixture_created, ^fixture_user}
    assert_received {:admin_user_list, ^fixture_user}
    assert_received {:admin_user_info, ^fixture_user}
    assert_received {:admin_fixture_cleaned, ^fixture_user}

    {_command, ["--json", "admin", "user", "info", "maxiocompatjson", json_fixture_user], _opts} =
      Enum.find(calls, fn {_command, args, _opts} ->
        Enum.take(args, 5) == ["--json", "admin", "user", "info", "maxiocompatjson"]
      end)

    assert json_fixture_user != fixture_user
    assert_received {:admin_fixture_created, ^json_fixture_user}
    assert_received {:admin_fixture_cleaned, ^json_fixture_user}

    assert Enum.any?(calls, fn {_command, args, _opts} ->
             args == ["admin", "policy", "rm", "maxiocompat", policy_name]
           end)

    refute Enum.any?(calls, fn {_command, args, _opts} ->
             Enum.chunk_every(args, 3, 1, :discard)
             |> Enum.any?(&(&1 == ["admin", "user", "add"]))
           end)

    assert Enum.any?(calls, fn {_command, args, _opts} ->
             args == [
               "--json",
               "admin",
               "user",
               "remove",
               "maxiocompatjson",
               json_fixture_user
             ]
           end)

    mc_ls_calls =
      Enum.filter(calls, fn {_command, args, _opts} ->
        args in [["ls", "maxiocompat"], ["--json", "ls", "maxiocompatjson"]]
      end)

    assert length(mc_ls_calls) == 10

    refute File.exists?(config_dir)
    refute File.exists?(Path.dirname(config_dir))
  end

  test "late mc failure does not replay resources already removed successfully" do
    Process.put(:policy_remove_calls, 0)
    Process.put(:delete_copied_calls, 0)
    user_runner = successful_mc_runner()

    runner = fn command, args, opts ->
      {_config_dir, _json?, [subcommand | command_args]} = parse_mc_args(args, opts)

      cond do
        subcommand == "admin" and Enum.take(command_args, 2) == ["policy", "rm"] ->
          Process.put(:policy_remove_calls, Process.get(:policy_remove_calls) + 1)
          user_runner.(command, args, opts)

        subcommand in ["admin", "ls"] ->
          user_runner.(command, args, opts)

        true ->
          cond do
            subcommand == "cp" and Enum.any?(command_args, &File.regular?/1) ->
              payload_path = Enum.find(command_args, &File.regular?/1)
              Process.put(:cleanup_payload, File.read!(payload_path))
              {"copied", 0}

            subcommand == "stat" ->
              {"maxio-smoke: deep-matrix", 0}

            subcommand == "cat" ->
              {Process.get(:cleanup_payload), 0}

            subcommand == "rm" and String.contains?(List.last(command_args), "-copy") ->
              calls = Process.get(:delete_copied_calls) + 1
              Process.put(:delete_copied_calls, calls)

              if calls == 1, do: {"late cleanup failure", 9}, else: {"removed", 0}

            true ->
              {"ok", 0}
          end
      end
    end

    [entry] =
      @config
      |> Map.put(:clients, ["minio_mc"])
      |> ExternalSmoke.run(
        executable_finder: fn "mc" -> "mc.exe" end,
        command_runner: runner,
        tmp_root_fun: &tmp_root/0,
        admin_user_fixture_opts: fixture_opts(self())
      )

    assert entry["status"] == "blocked"
    assert [%{"step" => "delete_copied_object"}] = entry["blockers"]
    assert Process.get(:policy_remove_calls) == 2
    assert Process.get(:delete_copied_calls) == 2
    assert entry["scenario_counts"]["admin_policy_lifecycle"] == 6
    assert entry["scenario_counts"]["cleanup"] == 5

    assert Enum.all?(Enum.frequencies(Enum.map(entry["steps"], & &1["id"])), fn {_id, n} ->
             n == 1
           end)
  end

  test "mc human and JSON modes independently exercise policy association data-plane lifecycle" do
    Process.put(:policy_lifecycle_calls, [])
    runner = successful_mc_runner()

    tracing_runner = fn command, args, opts ->
      Process.put(:policy_lifecycle_calls, [args | Process.get(:policy_lifecycle_calls)])
      runner.(command, args, opts)
    end

    [entry] =
      @config
      |> Map.put(:clients, ["minio_mc"])
      |> ExternalSmoke.run(
        executable_finder: fn "mc" -> "mc.exe" end,
        command_runner: tracing_runner,
        tmp_root_fun: &tmp_root/0,
        admin_user_fixture_opts: fixture_opts(self())
      )

    assert entry["status"] == "ok"

    association_ids =
      entry["steps"]
      |> Enum.filter(&(&1["scenario"] == "admin_policy_association_lifecycle"))
      |> Enum.map(& &1["id"])

    assert association_ids == [
             "admin_policy_human_mc_ls_baseline_denied",
             "admin_policy_human_attach",
             "admin_policy_human_mc_ls_attached",
             "admin_policy_human_attach_no_effect",
             "admin_policy_human_entities",
             "admin_policy_human_detach",
             "admin_policy_human_mc_ls_detached",
             "admin_policy_human_reattach",
             "admin_policy_human_cleanup_detach",
             "admin_policy_json_mc_ls_baseline_denied",
             "admin_policy_json_attach",
             "admin_policy_json_mc_ls_attached",
             "admin_policy_json_attach_no_effect",
             "admin_policy_json_entities",
             "admin_policy_json_detach",
             "admin_policy_json_mc_ls_detached",
             "admin_policy_json_reattach",
             "admin_policy_json_cleanup_detach"
           ]

    calls = Process.get(:policy_lifecycle_calls) |> Enum.reverse()

    no_effect_calls =
      Enum.filter(calls, fn args ->
        "attach" in args and
          Enum.count(args, &String.starts_with?(&1, "maxio-compat-policy-")) == 2
      end)

    assert length(no_effect_calls) == 2

    entities_calls =
      Enum.filter(calls, &(&1 |> Enum.join(" ") |> String.contains?("policy entities")))

    assert length(entities_calls) == 2

    Enum.each(entities_calls, fn args ->
      assert Enum.count(args, &(&1 == "--user")) == 2
      assert Enum.count(args, &(&1 == "--policy")) == 2
    end)
  end

  test "policy lifecycle failure cleanup detaches and deletes user before policy removal" do
    Process.put(:policy_cleanup_calls, [])
    base_runner = successful_mc_runner()

    runner = fn command, args, opts ->
      Process.put(:policy_cleanup_calls, [args | Process.get(:policy_cleanup_calls)])

      if "--json" not in args and
           args |> Enum.join(" ") |> String.contains?("policy entities") do
        {"injected entities failure", 9}
      else
        base_runner.(command, args, opts)
      end
    end

    [entry] =
      @config
      |> Map.put(:clients, ["minio_mc"])
      |> ExternalSmoke.run(
        executable_finder: fn "mc" -> "mc.exe" end,
        command_runner: runner,
        tmp_root_fun: &tmp_root/0,
        admin_user_fixture_opts: fixture_opts(self())
      )

    assert entry["status"] == "blocked"
    assert hd(entry["blockers"])["step"] == "admin_policy_human_entities"

    calls = Process.get(:policy_cleanup_calls) |> Enum.reverse()

    failure_index =
      Enum.find_index(calls, fn args ->
        "--json" not in args and
          args |> Enum.join(" ") |> String.contains?("policy entities")
      end)

    cleanup_commands =
      calls
      |> Enum.drop(failure_index + 1)
      |> Enum.take(3)
      |> Enum.map(&Enum.join(&1, " "))

    assert [detach, remove_user, remove_policy] = cleanup_commands
    assert detach =~ "admin policy detach maxiocompat"
    assert remove_user =~ "admin user remove maxiocompat"
    assert remove_policy =~ "admin policy rm maxiocompat"
  end

  test "mc JSON admin user commands use exact prefix-first argv and isolate config through env" do
    Process.put(:json_mc_calls, [])
    base_runner = successful_mc_runner()

    runner = fn command, args, opts ->
      if "--json" in args and admin_user_command?(args) do
        Process.put(:json_mc_calls, [{command, args, opts} | Process.get(:json_mc_calls)])
      end

      base_runner.(command, args, opts)
    end

    [entry] =
      @config
      |> Map.put(:clients, ["minio_mc"])
      |> ExternalSmoke.run(
        executable_finder: fn "mc" -> "mc.exe" end,
        command_runner: runner,
        tmp_root_fun: &tmp_root/0,
        admin_user_fixture_opts: fixture_opts(self())
      )

    assert entry["status"] == "ok"
    json_calls = Process.get(:json_mc_calls) |> Enum.reverse()
    assert length(json_calls) == 6

    Enum.each(json_calls, fn {"mc.exe", args, opts} ->
      assert ["--json", "admin", "user" | _rest] = args
      refute "--config-dir" in args

      assert {"MC_CONFIG_DIR", config_dir} =
               opts
               |> Keyword.fetch!(:env)
               |> Enum.find(&(elem(&1, 0) == "MC_CONFIG_DIR"))

      assert Path.basename(config_dir) == "mc-config-json"
    end)
  end

  for mutation <- [:missing_lf, :double_lf, :compact] do
    @json_document_mutation mutation
    test "JSON admin framing rejects #{mutation}" do
      mutation = @json_document_mutation
      base_runner = successful_mc_runner()

      runner = fn command, args, opts ->
        result = base_runner.(command, args, opts)

        case {result, json_mode?(args), admin_user_action(args)} do
          {{stdout, 0}, true, "info"} ->
            {mutate_json_document(stdout, mutation), 0}

          _other ->
            result
        end
      end

      [entry] =
        @config
        |> Map.put(:clients, ["minio_mc"])
        |> ExternalSmoke.run(
          executable_finder: fn "mc" -> "mc.exe" end,
          command_runner: runner,
          tmp_root_fun: &tmp_root/0,
          admin_user_fixture_opts: fixture_opts(self())
        )

      assert entry["status"] == "blocked"
      assert hd(entry["blockers"])["step"] == "admin_user_json_info_enabled"
    end
  end

  test "fake runner emits the source-pinned complete JSON documents" do
    assert json_association_output(:attach, ["a-policy", "z-policy"], "alice") ==
             "{\n \"status\": \"success\",\n \"policiesAttached\": [\n  \"a-policy\",\n  \"z-policy\"\n ],\n \"user\": \"alice\"\n}\n"

    assert json_entities_output("a-policy", "alice", "2026-08-28T01:02:03Z") ==
             "{\n  \"status\": \"success\",\n  \"result\": {\n    \"timestamp\": \"2026-08-28T01:02:03Z\",\n    \"policyMappings\": [\n      {\n        \"policy\": \"a-policy\",\n        \"users\": [\n          \"alice\"\n        ],\n        \"groups\": null\n      }\n    ]\n  }\n}\n"

    assert json_user_info_output("NAME", "enabled") ==
             "{\n \"status\": \"success\",\n \"accessKey\": \"NAME\",\n \"userStatus\": \"enabled\"\n}\n"

    assert json_user_mutation_output("NAME") ==
             "{\n \"status\": \"success\",\n \"accessKey\": \"NAME\"\n}\n"
  end

  for mutation <- [:missing_lf, :double_lf, :compact] do
    @json_entities_mutation mutation
    test "JSON policy entities framing rejects #{mutation}" do
      mutation = @json_entities_mutation
      base_runner = successful_mc_runner()

      runner = fn command, args, opts ->
        result = base_runner.(command, args, opts)

        if "--json" in args and Enum.slice(args, 1, 3) == ["admin", "policy", "entities"] do
          {stdout, exit_status} = result
          {mutate_json_document(stdout, mutation), exit_status}
        else
          result
        end
      end

      [entry] =
        @config
        |> Map.put(:clients, ["minio_mc"])
        |> ExternalSmoke.run(
          executable_finder: fn "mc" -> "mc.exe" end,
          command_runner: runner,
          tmp_root_fun: &tmp_root/0,
          admin_user_fixture_opts: fixture_opts(self())
        )

      assert entry["status"] == "blocked"
      assert hd(entry["blockers"])["step"] == "admin_policy_json_entities"
    end
  end

  test "human and JSON user lifecycles interleave info and real mc ls probes in pinned order" do
    Process.put(:admin_lifecycle_trace, [])
    base_runner = successful_mc_runner()

    runner = fn command, args, opts ->
      {_config_dir, json?, [subcommand | _command_args]} = parse_mc_args(args, opts)

      if subcommand == "ls" do
        append_lifecycle_trace(
          {:mc_ls, json?, Process.get(:admin_fixture_status),
           Process.get(:admin_fixture_policy_attached)}
        )
      else
        case admin_user_action(args) do
          action when action in ["info", "disable", "enable", "remove"] ->
            append_lifecycle_trace({:mc, json?, action})

          _other ->
            :ok
        end
      end

      base_runner.(command, args, opts)
    end

    [entry] =
      @config
      |> Map.put(:clients, ["minio_mc"])
      |> ExternalSmoke.run(
        executable_finder: fn "mc" -> "mc.exe" end,
        command_runner: runner,
        tmp_root_fun: &tmp_root/0,
        admin_user_fixture_opts: fixture_opts(self())
      )

    assert entry["status"] == "ok"

    lifecycle =
      Process.get(:admin_lifecycle_trace)
      |> Enum.reverse()
      |> Enum.filter(fn
        {:mc, _json?, action} when action in ["info", "disable", "enable"] -> true
        {:mc_ls, _json?, _status, _attached?} -> true
        _other -> false
      end)

    expected_one_mode = [
      {:mc, :json_mode, "info"},
      {:mc_ls, :json_mode, :enabled, false},
      {:mc_ls, :json_mode, :enabled, true},
      {:mc_ls, :json_mode, :enabled, false},
      {:mc, :json_mode, "disable"},
      {:mc, :json_mode, "info"},
      {:mc_ls, :json_mode, :disabled, true},
      {:mc, :json_mode, "enable"},
      {:mc, :json_mode, "info"},
      {:mc_ls, :json_mode, :enabled, true}
    ]

    assert lifecycle ==
             Enum.map(expected_one_mode, &put_json_mode(&1, false)) ++
               Enum.map(expected_one_mode, &put_json_mode(&1, true))
  end

  test "human info rejects contradictory status text instead of substring matching" do
    runner = successful_mc_runner(admin_user_info: {"Status: enabled\nStatus: disabled\n", 0})

    [entry] =
      @config
      |> Map.put(:clients, ["minio_mc"])
      |> ExternalSmoke.run(
        executable_finder: fn "mc" -> "mc.exe" end,
        command_runner: runner,
        tmp_root_fun: &tmp_root/0,
        admin_user_fixture_opts: fixture_opts(self())
      )

    assert entry["status"] == "blocked"
    assert hd(entry["blockers"])["step"] == "admin_user_info"
  end

  test "human repeated remove rejects any extra stderr text" do
    base_runner = successful_mc_runner()

    runner = fn command, args, opts ->
      case base_runner.(command, args, opts) do
        {"", stderr, 1} when is_binary(stderr) -> {"", stderr <> "\nEXTRA", 1}
        other -> other
      end
    end

    [entry] =
      @config
      |> Map.put(:clients, ["minio_mc"])
      |> ExternalSmoke.run(
        executable_finder: fn "mc" -> "mc.exe" end,
        command_runner: runner,
        tmp_root_fun: &tmp_root/0,
        admin_user_fixture_opts: fixture_opts(self())
      )

    assert entry["status"] == "blocked"
    assert hd(entry["blockers"])["step"] == "admin_user_human_remove_again"
  end

  test "human info rejects an otherwise exact four-line response without its trailing LF" do
    base_runner = successful_mc_runner()

    runner = fn command, args, opts ->
      case {base_runner.(command, args, opts), json_mode?(args), admin_user_action(args)} do
        {{stdout, 0}, false, "info"} ->
          {String.trim_trailing(stdout, "\n"), 0}

        {other, _json?, _action} ->
          other
      end
    end

    [entry] =
      @config
      |> Map.put(:clients, ["minio_mc"])
      |> ExternalSmoke.run(
        executable_finder: fn "mc" -> "mc.exe" end,
        command_runner: runner,
        tmp_root_fun: &tmp_root/0,
        admin_user_fixture_opts: fixture_opts(self())
      )

    assert entry["status"] == "blocked"
    assert hd(entry["blockers"])["step"] == "admin_user_info"
  end

  test "human no-such-user stderr rejects an otherwise exact response without its trailing LF" do
    base_runner = successful_mc_runner()

    runner = fn command, args, opts ->
      case base_runner.(command, args, opts) do
        {"", stderr, 1} -> {"", String.trim_trailing(stderr, "\n"), 1}
        other -> other
      end
    end

    [entry] =
      @config
      |> Map.put(:clients, ["minio_mc"])
      |> ExternalSmoke.run(
        executable_finder: fn "mc" -> "mc.exe" end,
        command_runner: runner,
        tmp_root_fun: &tmp_root/0,
        admin_user_fixture_opts: fixture_opts(self())
      )

    assert entry["status"] == "blocked"
    assert hd(entry["blockers"])["step"] == "admin_user_human_remove_again"
  end

  test "human exact-output full lifecycle uses the host-native line ending" do
    base_runner = successful_mc_runner()
    line_ending = if match?({:win32, _name}, :os.type()), do: "\r\n", else: "\n"

    runner = fn command, args, opts ->
      case {base_runner.(command, args, opts), json_mode?(args), admin_user_action(args)} do
        {{stdout, 0}, false, action} when action in ["info", "disable", "enable"] ->
          {String.trim_trailing(stdout, "\n") <> line_ending, 0}

        {{stdout, "", 0}, false, "remove"} ->
          {String.trim_trailing(stdout, "\n") <> line_ending, "", 0}

        {{"", stderr, 1}, _json?, "remove"} ->
          {"", String.trim_trailing(stderr, "\n") <> line_ending, 1}

        {other, _json?, _action} ->
          other
      end
    end

    [entry] =
      @config
      |> Map.put(:clients, ["minio_mc"])
      |> ExternalSmoke.run(
        executable_finder: fn "mc" -> "mc.exe" end,
        command_runner: runner,
        tmp_root_fun: &tmp_root/0,
        admin_user_fixture_opts: fixture_opts(self())
      )

    assert entry["status"] == "ok"
  end

  test "canonical human matcher accepts CRLF only for Windows and preserves exact LF framing" do
    expected = "Disabled user `fixture-user` successfully.\n"

    assert ExternalSmoke.mc_output_exact?(
             "Disabled user `fixture-user` successfully.\r\n",
             expected,
             {:win32, :nt}
           )

    refute ExternalSmoke.mc_output_exact?(
             "Disabled user `fixture-user` successfully.\r\n",
             expected,
             {:unix, :linux}
           )

    Enum.each(
      [
        "Disabled user `fixture-user` successfully.",
        "Disabled user `fixture-user` successfully.\n\n",
        "Disabled user `fixture-user` successfully. \n",
        "Disabled user `fixture-user` successfully.\r"
      ],
      fn malformed ->
        refute ExternalSmoke.mc_output_exact?(malformed, expected, {:win32, :nt})
      end
    )
  end

  for mutation <- [:missing_lf, :double_lf, :trailing_space, :lone_cr] do
    @human_success_mutation mutation
    test "human mutation success rejects #{mutation}" do
      mutation = @human_success_mutation
      base_runner = successful_mc_runner()

      runner = fn command, args, opts ->
        result = base_runner.(command, args, opts)

        case {result, json_mode?(args), admin_user_action(args)} do
          {{stdout, 0}, false, "disable"} ->
            canonical = String.trim_trailing(stdout, "\n")
            {mutate_human_success(canonical, mutation), 0}

          _other ->
            result
        end
      end

      [entry] =
        @config
        |> Map.put(:clients, ["minio_mc"])
        |> ExternalSmoke.run(
          executable_finder: fn "mc" -> "mc.exe" end,
          command_runner: runner,
          tmp_root_fun: &tmp_root/0,
          admin_user_fixture_opts: fixture_opts(self())
        )

      assert entry["status"] == "blocked"
      assert hd(entry["blockers"])["step"] == "admin_user_human_disable"
    end
  end

  for {label, mode, evidence} <- [
        {:human_wrong_exit, :human, {"", "mc: <ERROR> Access Denied.\n", 0}},
        {:human_wrong_stderr, :human, {"", "permission refused\n", 1}},
        {:human_wrong_stdout, :human, {"unexpected", "mc: <ERROR> Access Denied.\n", 1}},
        {:json_wrong_exit, :json, {"{\"status\":\"error\"}\n", "", 0}},
        {:json_wrong_status, :json, {"{\"status\":\"success\"}\n", "", 1}},
        {:json_nonempty_stderr, :json, {"{\"status\":\"error\"}\n", "Access Denied\n", 1}}
      ] do
    @invalid_mc_ls_mode mode
    @invalid_mc_ls_evidence evidence
    @invalid_mc_ls_step if(mode == :json,
                          do: "admin_user_json_mc_ls_disabled",
                          else: "admin_user_human_mc_ls_disabled"
                        )
    test "disabled real mc ls rejects #{label} evidence" do
      invalid_mode = @invalid_mc_ls_mode
      invalid = @invalid_mc_ls_evidence

      mc_probe = fn probe ->
        mode = if probe.json?, do: :json, else: :human
        {:external_command_capability, redactions, run} = invoke_fixture_mc_probe(probe)

        {:external_command_capability, redactions,
         fn command_runner ->
           if Process.get(:admin_fixture_status) == :disabled and mode == invalid_mode do
             invalid
           else
             run.(command_runner)
           end
         end}
      end

      opts = Keyword.put(fixture_opts(self()), :mc_probe, mc_probe)

      [entry] =
        @config
        |> Map.put(:clients, ["minio_mc"])
        |> ExternalSmoke.run(
          executable_finder: fn "mc" -> "mc.exe" end,
          command_runner: successful_mc_runner(),
          tmp_root_fun: &tmp_root/0,
          admin_user_fixture_opts: opts
        )

      assert entry["status"] == "blocked"

      assert hd(entry["blockers"])["step"] == @invalid_mc_ls_step
    end
  end

  test "failed first mc creation does not clean resources that were never created" do
    owner = self()
    json_runner = successful_mc_runner()

    runner = fn command, args, opts ->
      {_config_dir, _json?, [subcommand | _command_args]} = parse_mc_args(args, opts)

      cond do
        "--json" in args ->
          json_runner.(command, args, opts)

        subcommand == "mb" ->
          {"bucket creation failed", 9}

        true ->
          send(owner, {:unexpected_cleanup, args})
          {"resource not found", 1}
      end
    end

    [entry] =
      @config
      |> Map.put(:clients, ["minio_mc"])
      |> ExternalSmoke.run(
        executable_finder: fn "mc" -> "mc.exe" end,
        command_runner: runner,
        tmp_root_fun: &tmp_root/0,
        admin_user_fixture_opts: fixture_opts(self())
      )

    assert entry["status"] == "blocked"

    assert [%{"reason" => "external_smoke_step_failed", "step" => "make_bucket"}] =
             entry["blockers"]

    assert Enum.take(Enum.map(entry["steps"], & &1["id"]), 2) == [
             "make_bucket",
             "admin_user_fixture_cleanup_human"
           ]

    assert entry["scenario_counts"]["bucket_lifecycle"] == 1
    assert entry["scenario_counts"]["cleanup"] == 2
    assert entry["scenario_counts"]["admin_user_json_lifecycle"] == 8

    refute_received {:unexpected_cleanup, _args}

    assert_receive {:admin_fixture_created, human_name}
    assert_receive {:admin_fixture_cleaned, ^human_name}
    assert_receive {:admin_fixture_created, json_name}
    assert_receive {:admin_fixture_cleaned, ^json_name}
    assert human_name != json_name
  end

  test "mc smoke blocks when stat output does not include metadata" do
    json_runner = successful_mc_runner()

    command_runner = fn command, args, opts ->
      {_config_dir, _json?, [subcommand | command_args]} = parse_mc_args(args, opts)

      if "--json" in args do
        json_runner.(command, args, opts)
      else
        cond do
          subcommand == "cp" and Enum.any?(command_args, &File.regular?/1) ->
            payload_path = Enum.find(command_args, &File.regular?/1)
            Process.put(:payload, File.read!(payload_path))
            {"copied", 0}

          subcommand == "stat" ->
            {"Name: smoke.txt\nMetadata: none\n", 0}

          subcommand == "cat" ->
            {Process.get(:payload), 0}

          true ->
            {"ok", 0}
        end
      end
    end

    [entry] =
      @config
      |> Map.put(:clients, ["minio_mc"])
      |> ExternalSmoke.run(
        executable_finder: fn "mc" -> "mc.exe" end,
        command_runner: command_runner,
        tmp_root_fun: &tmp_root/0,
        admin_user_fixture_opts: fixture_opts(self())
      )

    assert entry["status"] == "blocked"

    assert [%{"reason" => "external_smoke_output_missing", "step" => "stat_object"}] =
             entry["blockers"]
  end

  test "mc user list command and decrypted-output assertions fail explicitly before info" do
    for {list_result, reason, step_status} <- [
          {{"user list failed", 17}, "external_smoke_step_failed", "blocked"},
          {{"somebody-else disabled", 0}, "external_smoke_output_missing", "ok"}
        ] do
      [entry] =
        @config
        |> Map.put(:clients, ["minio_mc"])
        |> ExternalSmoke.run(
          executable_finder: fn "mc" -> "mc.exe" end,
          command_runner: successful_mc_runner(admin_user_list: list_result),
          tmp_root_fun: &tmp_root/0,
          admin_user_fixture_opts: fixture_opts(self())
        )

      assert entry["status"] == "blocked"

      assert Enum.any?(
               entry["steps"],
               &(&1["id"] == "admin_user_list" and &1["status"] == step_status)
             )

      refute Enum.any?(entry["steps"], &(&1["id"] == "admin_user_info"))
      assert hd(entry["blockers"])["reason"] == reason
      assert hd(entry["blockers"])["step"] == "admin_user_list"
      assert List.last(entry["steps"])["id"] == "admin_user_fixture_cleanup_json"
    end
  end

  test "mc prerequisites block before fixture setup or command execution" do
    [entry] =
      ExternalSmoke.run(%{clients: ["minio_mc"]},
        executable_finder: fn _candidate -> raise "finder must not run" end,
        command_runner: fn _, _, _ -> raise "runner must not run" end,
        admin_user_fixture_opts: [create_user: fn _ -> raise "fixture must not run" end]
      )

    assert entry["status"] == "attention"
    assert [%{"reason" => "external_smoke_not_configured"}] = entry["warnings"]
    assert entry["steps"] == []
  end

  test "mc read smoke is repeatable and never constructs admin user add argv" do
    owner = self()
    successful = successful_mc_runner()

    runner = fn command, args, opts ->
      send(owner, {:repeatable_mc_argv, args})
      successful.(command, args, opts)
    end

    entries =
      for _iteration <- 1..2 do
        [entry] =
          @config
          |> Map.put(:clients, ["minio_mc"])
          |> ExternalSmoke.run(
            executable_finder: fn "mc" -> "mc.exe" end,
            command_runner: runner,
            tmp_root_fun: &tmp_root/0,
            admin_user_fixture_opts: fixture_opts(owner)
          )

        entry
      end

    assert Enum.all?(entries, &(&1["status"] == "ok"))

    argv = receive_all_argv()
    user_commands = Enum.filter(argv, &admin_user_command?/1)
    human_commands = Enum.reject(user_commands, &("--json" in &1))
    json_commands = Enum.filter(user_commands, &("--json" in &1))

    assert Enum.count(human_commands, &(admin_user_action(&1) == "list")) == 4
    assert Enum.count(human_commands, &(admin_user_action(&1) == "info")) == 6
    assert Enum.count(human_commands, &(admin_user_action(&1) == "disable")) == 2
    assert Enum.count(human_commands, &(admin_user_action(&1) == "enable")) == 2
    assert Enum.count(human_commands, &(admin_user_action(&1) == "remove")) == 6
    assert Enum.count(json_commands, &(admin_user_action(&1) == "info")) == 6
    assert Enum.count(json_commands, &(admin_user_action(&1) == "disable")) == 2
    assert Enum.count(json_commands, &(admin_user_action(&1) == "enable")) == 2
    assert Enum.count(json_commands, &(admin_user_action(&1) == "remove")) == 2

    refute Enum.any?(argv, fn args ->
             Enum.chunk_every(args, 3, 1, :discard)
             |> Enum.any?(&(&1 == ["admin", "user", "add"]))
           end)
  end

  test "successful user info plus fixture cleanup failure keeps primary evidence and blocks" do
    [entry] =
      @config
      |> Map.put(:clients, ["minio_mc"])
      |> ExternalSmoke.run(
        executable_finder: fn "mc" -> "mc.exe" end,
        command_runner: successful_mc_runner(),
        tmp_root_fun: &tmp_root/0,
        admin_user_fixture_opts: fixture_opts(self(), {:error, :cleanup_failed})
      )

    assert entry["status"] == "blocked"
    assert Enum.any?(entry["steps"], &(&1["id"] == "admin_user_info" and &1["status"] == "ok"))
    assert List.last(entry["steps"])["id"] == "admin_user_fixture_cleanup_json"

    assert [
             %{
               "reason" => "external_smoke_cleanup_failed",
               "step" => "admin_user_fixture_cleanup_human"
             },
             %{
               "reason" => "external_smoke_cleanup_failed",
               "step" => "admin_user_fixture_cleanup_json"
             }
           ] = entry["blockers"]
  end

  test "blocked user info plus fixture cleanup failure retains both causes in order" do
    [entry] =
      @config
      |> Map.put(:clients, ["minio_mc"])
      |> ExternalSmoke.run(
        executable_finder: fn "mc" -> "mc.exe" end,
        command_runner: successful_mc_runner(admin_user_info: {"user info failed", 17}),
        tmp_root_fun: &tmp_root/0,
        admin_user_fixture_opts: fixture_opts(self(), {:error, :cleanup_failed})
      )

    assert entry["status"] == "blocked"

    assert Enum.any?(
             entry["steps"],
             &(&1["id"] == "admin_user_info" and &1["status"] == "blocked")
           )

    assert List.last(entry["steps"])["id"] == "admin_user_fixture_cleanup_json"

    assert [
             %{"reason" => "external_smoke_step_failed", "step" => "admin_user_info"},
             %{
               "reason" => "external_smoke_cleanup_failed",
               "step" => "admin_user_fixture_cleanup_human"
             },
             %{
               "reason" => "external_smoke_cleanup_failed",
               "step" => "admin_user_fixture_cleanup_json"
             }
           ] = entry["blockers"]

    refute Enum.any?(entry["blockers"], &(&1["reason"] == "external_smoke_failed"))
  end

  test "python-boto3 smoke runs one self-verifying CRUD script" do
    owner = self()

    [entry] =
      @config
      |> Map.put(:clients, ["python_boto3"])
      |> ExternalSmoke.run(
        executable_finder: fn
          "python" -> nil
          "python3" -> "python3.exe"
          "py" -> nil
        end,
        command_runner: fn command, args, opts ->
          send(owner, {:cmd, command, args, opts})

          if Enum.join(args, " ") =~ "importlib.util" do
            {"", 0}
          else
            {"ok", 0}
          end
        end,
        tmp_root_fun: &tmp_root/0
      )

    assert entry["status"] == "ok"
    assert entry["scenario_counts"] == %{"sdk_deep_matrix" => 1}

    assert [%{"id" => "deep_matrix", "command" => command, "scenario" => "sdk_deep_matrix"}] =
             entry["steps"]

    assert command =~ "python3.exe"
    refute Jason.encode!(entry) =~ "super-secret"

    assert_received {:cmd, "python3.exe", ["-c", probe_script], probe_opts}
    assert probe_script =~ "importlib.util.find_spec('boto3')"
    assert_loopback_bypass(probe_opts, "127.0.0.1")

    assert_received {:cmd, "python3.exe", ["-c", script], opts}
    assert script =~ "boto3.client"
    assert script =~ "copy_object"
    assert script =~ "Range=\"bytes=0-5\""
    assert {"MAXIO_COMPAT_ENDPOINT", "http://127.0.0.1:9900"} in Keyword.fetch!(opts, :env)
    assert_loopback_bypass(opts, "127.0.0.1")

    assert {"MAXIO_COMPAT_COPY_KEY", _copy_key} =
             Enum.find(Keyword.fetch!(opts, :env), &(elem(&1, 0) == "MAXIO_COMPAT_COPY_KEY"))
  end

  test "python-boto3 missing boto3 dependency is attention evidence" do
    owner = self()

    [entry] =
      @config
      |> Map.put(:clients, ["python_boto3"])
      |> ExternalSmoke.run(
        executable_finder: fn
          "python" -> "python.exe"
          "python3" -> nil
          "py" -> nil
        end,
        command_runner: fn command, args, opts ->
          send(owner, {:cmd, command, args, opts})
          {"missing boto3", 2}
        end,
        tmp_root_fun: &tmp_root/0
      )

    assert entry["status"] == "attention"

    assert [
             %{
               "reason" => "external_smoke_client_not_configured",
               "dependency" => "boto3"
             }
           ] = entry["warnings"]

    assert entry["steps"] == []
    assert_received {:cmd, "python.exe", ["-c", probe_script], probe_opts}
    assert probe_script =~ "importlib.util.find_spec('boto3')"
    assert_loopback_bypass(probe_opts, "127.0.0.1")
  end

  test "loopback proxy bypass is merged for every client step and cleanup" do
    Process.put(:proxy_env_calls, [])

    runner = fn command, args, opts ->
      Process.put(:proxy_env_calls, [{command, args, opts} | Process.get(:proxy_env_calls)])

      cond do
        Enum.join(args, " ") =~ "importlib.util.find_spec('boto3')" -> {"", 0}
        "create-bucket" in args -> {"", 0}
        "mb" in args -> {"", 0}
        true -> {"blocked for env inspection", 9}
      end
    end

    entries =
      @config
      |> Map.put(:clients, ["aws_cli", "minio_mc", "python_boto3"])
      |> ExternalSmoke.run(
        executable_finder: fn
          "aws" -> "aws.exe"
          "mc" -> "mc.exe"
          "python" -> "python.exe"
          _other -> nil
        end,
        command_runner: runner,
        tmp_root_fun: &tmp_root/0,
        admin_user_fixture_opts: fixture_opts(self()),
        system_env: %{
          "NO_PROXY" => "example.com,LOCALHOST",
          "no_proxy" => "EXAMPLE.com,service.internal"
        }
      )

    assert Enum.map(entries, & &1["status"]) == ["blocked", "blocked", "blocked"]

    calls = Process.get(:proxy_env_calls)
    assert length(calls) == 9
    expected = "example.com,LOCALHOST,service.internal,127.0.0.1"

    Enum.each(calls, fn {_command, _args, opts} ->
      env = Keyword.fetch!(opts, :env)
      assert {"NO_PROXY", expected} in env
      assert {"no_proxy", expected} in env
    end)
  end

  test "mc JSON lifecycle rejects malformed objects, mismatched fields, stderr, and exit status" do
    cases = [
      {"json lines", "{\"accessKey\":\"wrong\"}\n{\"status\":\"enabled\"}\n", "", 0,
       "external_smoke_json_mismatch"},
      {"array", "[]", "", 0, "external_smoke_json_mismatch"},
      {"wrong access key",
       Jason.encode!(%{
         "accessKey" => "wrong",
         "status" => "success",
         "userStatus" => "enabled"
       }), "", 0, "external_smoke_json_mismatch"},
      {"wrong status",
       Jason.encode!(%{
         "accessKey" => "placeholder",
         "status" => "enabled",
         "userStatus" => "enabled"
       }), "", 0, "external_smoke_json_mismatch"},
      {"stderr",
       Jason.encode!(%{
         "accessKey" => "placeholder",
         "status" => "success",
         "userStatus" => "enabled"
       }), "unexpected diagnostic", 0, "external_smoke_stderr_not_empty"},
      {"exit", "", "", 7, "external_smoke_step_failed"}
    ]

    Enum.each(cases, fn {label, stdout_template, stderr, exit_status, reason} ->
      Process.delete(:json_failure_injected)
      base_runner = successful_mc_runner()

      runner = fn command, args, opts ->
        if "--json" in args and admin_user_action(args) == "info" and
             Process.get(:json_failure_injected) != true do
          Process.put(:json_failure_injected, true)
          user_name = List.last(args)
          stdout = String.replace(stdout_template, "placeholder", user_name)
          {stdout, stderr, exit_status}
        else
          base_runner.(command, args, opts)
        end
      end

      [entry] =
        @config
        |> Map.put(:clients, ["minio_mc"])
        |> ExternalSmoke.run(
          executable_finder: fn "mc" -> "mc.exe" end,
          command_runner: runner,
          tmp_root_fun: &tmp_root/0,
          admin_user_fixture_opts: fixture_opts(self())
        )

      assert entry["status"] == "blocked", "#{label}: #{inspect(entry["blockers"])}"

      assert Enum.any?(entry["blockers"], fn blocker ->
               blocker["reason"] == reason and blocker["step"] == "admin_user_json_info_enabled"
             end),
             label
    end)
  end

  for {label, response} <- [
        missing_user_status: %{"accessKey" => "placeholder", "status" => "success"},
        wrong_status: %{
          "accessKey" => "placeholder",
          "status" => "enabled",
          "userStatus" => "enabled"
        },
        contradictory_user_status: %{
          "accessKey" => "placeholder",
          "status" => "success",
          "userStatus" => "disabled"
        },
        unexpected_field: %{
          "accessKey" => "placeholder",
          "status" => "success",
          "userStatus" => "enabled",
          "message" => "unexpected"
        }
      ] do
    @invalid_json_info response
    test "mc JSON info rejects #{label} instead of accepting expected field subsets" do
      response = @invalid_json_info
      base_runner = successful_mc_runner()

      runner = fn command, args, opts ->
        if "--json" in args and admin_user_action(args) == "info" and
             Process.get(:json_schema_failure_injected) != true do
          Process.put(:json_schema_failure_injected, true)
          user_name = List.last(args)
          {response |> Map.put("accessKey", user_name) |> Jason.encode!(), "", 0}
        else
          base_runner.(command, args, opts)
        end
      end

      [entry] =
        @config
        |> Map.put(:clients, ["minio_mc"])
        |> ExternalSmoke.run(
          executable_finder: fn "mc" -> "mc.exe" end,
          command_runner: runner,
          tmp_root_fun: &tmp_root/0,
          admin_user_fixture_opts: fixture_opts(self())
        )

      assert entry["status"] == "blocked"

      assert Enum.any?(entry["blockers"], fn blocker ->
               blocker["reason"] == "external_smoke_json_mismatch" and
                 blocker["step"] == "admin_user_json_info_enabled"
             end)
    end
  end

  test "remote endpoint does not inject a proxy bypass for any client" do
    Process.put(:remote_proxy_calls, [])

    runner = fn command, args, opts ->
      Process.put(:remote_proxy_calls, [{command, args, opts} | Process.get(:remote_proxy_calls)])

      if Enum.join(args, " ") =~ "importlib.util.find_spec('boto3')" do
        {"", 0}
      else
        {"blocked for env inspection", 9}
      end
    end

    entries =
      @config
      |> Map.put(:endpoint, "https://s3.example.test")
      |> Map.put(:clients, ["aws_cli", "minio_mc", "python_boto3"])
      |> ExternalSmoke.run(
        executable_finder: fn
          "aws" -> "aws.exe"
          "mc" -> "mc.exe"
          "python" -> "python.exe"
          _other -> nil
        end,
        command_runner: runner,
        tmp_root_fun: &tmp_root/0,
        admin_user_fixture_opts: fixture_opts(self()),
        system_env: %{"NO_PROXY" => "existing.local", "no_proxy" => "legacy.local"}
      )

    assert Enum.map(entries, & &1["status"]) == ["blocked", "blocked", "blocked"]

    Enum.each(Process.get(:remote_proxy_calls), fn {_command, _args, opts} ->
      names = opts |> Keyword.fetch!(:env) |> Enum.map(&elem(&1, 0))
      refute "NO_PROXY" in names
      refute "no_proxy" in names
    end)
  end

  defp assert_loopback_bypass(opts, host) do
    env = Keyword.fetch!(opts, :env)
    {"NO_PROXY", upper} = Enum.find(env, &(elem(&1, 0) == "NO_PROXY"))
    {"no_proxy", lower} = Enum.find(env, &(elem(&1, 0) == "no_proxy"))
    assert upper == lower
    assert host in String.split(upper, ",")
  end

  defp receive_all_argv(acc \\ []) do
    receive do
      {:repeatable_mc_argv, args} -> receive_all_argv([args | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp admin_user_command?(args) do
    case Enum.find_index(args, &(&1 == "admin")) do
      nil -> false
      index -> Enum.slice(args, index, 2) == ["admin", "user"]
    end
  end

  defp admin_user_action(args) do
    case Enum.find_index(args, &(&1 == "admin")) do
      nil ->
        nil

      index ->
        case Enum.slice(args, index, 3) do
          ["admin", "user", action] -> action
          _other -> nil
        end
    end
  end

  defp fixture_opts(owner, cleanup_result \\ :ok) do
    [
      start_repo: fn -> :ok end,
      name: "maxio-compat-user-#{System.unique_integer([:positive])}",
      create_user: fn name ->
        Process.put(:admin_fixture_user, name)
        Process.put(:admin_fixture_status, :enabled)
        Process.put(:admin_fixture_policy_attached, false)
        send(owner, {:admin_fixture_created, name})
        {:ok, %{user_name: name, status: "active"}}
      end,
      s3_probe: fn ->
        case {Process.get(:admin_fixture_status), Process.get(:admin_fixture_policy_attached)} do
          {:enabled, true} -> %{status: 200, code: nil, message: nil}
          {:enabled, false} -> disabled_probe()
          {:disabled, _attached?} -> disabled_probe()
          {:removed, _attached?} -> disabled_probe()
          _other -> %{status: nil, code: "probe_not_configured", message: nil}
        end
      end,
      mc_probe: fn probe ->
        args = if probe.json?, do: ["--json", "ls", probe.alias], else: ["ls", probe.alias]

        {:external_command_capability, [],
         fn command_runner ->
           command_runner.(probe.executable, args, probe.opts)
         end}
      end,
      cleanup_user: fn name ->
        send(owner, {:admin_fixture_cleaned, name})
        cleanup_result
      end
    ]
  end

  defp invoke_fixture_mc_probe(probe) do
    args = if probe.json?, do: ["--json", "ls", probe.alias], else: ["ls", probe.alias]

    {:external_command_capability, [],
     fn command_runner ->
       command_runner.(probe.executable, args, probe.opts)
     end}
  end

  defp disabled_probe do
    %{
      status: 403,
      code: "InvalidAccessKeyId",
      message: "The AWS access key ID that you provided does not exist in our records."
    }
  end

  defp json_mode?(args), do: "--json" in args

  defp append_lifecycle_trace(value) do
    Process.put(:admin_lifecycle_trace, [value | Process.get(:admin_lifecycle_trace, [])])
  end

  defp put_json_mode({:mc, :json_mode, action}, json?), do: {:mc, json?, action}

  defp put_json_mode({:mc_ls, :json_mode, status, attached?}, json?),
    do: {:mc_ls, json?, status, attached?}

  defp put_json_mode(other, _json?), do: other

  defp successful_mc_runner(opts \\ []) do
    admin_user_list = Keyword.get(opts, :admin_user_list)
    admin_user_info = Keyword.get(opts, :admin_user_info)

    fn _command, args, command_opts ->
      {_config_dir, json?, [subcommand | command_args]} = parse_mc_args(args, command_opts)

      user_name = Process.get(:admin_fixture_user)

      cond do
        subcommand == "ls" ->
          allowed? =
            Process.get(:admin_fixture_status) == :enabled and
              Process.get(:admin_fixture_policy_attached) == true

          cond do
            allowed? ->
              {"", "", 0}

            json? ->
              {Jason.encode!(%{
                 "status" => "error",
                 "error" => %{"message" => "Access Denied"}
               }) <> "\n", "", 1}

            true ->
              {"", "mc: <ERROR> Unable to list folder. Access Denied.\n", 1}
          end

        subcommand == "cp" and Enum.any?(command_args, &File.regular?/1) ->
          payload_path = Enum.find(command_args, &File.regular?/1)
          Process.put(:successful_mc_payload, File.read!(payload_path))
          {"copied", 0}

        subcommand == "stat" ->
          {"maxio-smoke: deep-matrix", 0}

        subcommand == "cat" ->
          {Process.get(:successful_mc_payload), 0}

        subcommand == "admin" and Enum.take(command_args, 2) == ["policy", "create"] ->
          ["policy", "create", _mc_alias, policy_name, _policy_path] = command_args
          Process.put(:successful_mc_policy, policy_name)

          if json?,
            do: {json_policy_output(policy_name), 0},
            else: {"Created policy `#{policy_name}` successfully.\n", 0}

        subcommand == "admin" and Enum.take(command_args, 2) == ["policy", "ls"] ->
          {Process.get(:successful_mc_policy), 0}

        subcommand == "admin" and Enum.take(command_args, 2) == ["policy", "info"] ->
          {"PolicyName #{Process.get(:successful_mc_policy)}", 0}

        subcommand == "admin" and Enum.take(command_args, 2) == ["policy", "attach"] ->
          ["policy", "attach", _mc_alias | association_args] = command_args

          {policies, ["--user", target_name]} =
            Enum.split_while(association_args, &(&1 != "--user"))

          Process.put(:admin_fixture_policy_attached, true)

          if json? do
            {json_association_output(:attach, policies, target_name), 0}
          else
            {"Attached Policies: [#{Enum.join(policies, " ")}]\nTo User: #{target_name}\n", 0}
          end

        subcommand == "admin" and Enum.take(command_args, 2) == ["policy", "detach"] ->
          ["policy", "detach", _mc_alias | association_args] = command_args

          {policies, ["--user", target_name]} =
            Enum.split_while(association_args, &(&1 != "--user"))

          Process.put(:admin_fixture_policy_attached, false)

          if json? do
            {json_association_output(:detach, policies, target_name), 0}
          else
            {"Detached Policies: [#{Enum.join(policies, " ")}]\nFrom User: #{target_name}\n", 0}
          end

        subcommand == "admin" and Enum.take(command_args, 2) == ["policy", "entities"] ->
          policy_name = Process.get(:successful_mc_policy)
          timestamp = "2026-08-28T01:02:03Z"

          if json? do
            {json_entities_output(policy_name, user_name, timestamp), 0}
          else
            {"Query time: #{timestamp}\nPolicy -> Entity Mappings:\n" <>
               "  Policy: #{policy_name}\n    User Mappings:\n      #{user_name}\n", 0}
          end

        subcommand == "admin" and Enum.take(command_args, 2) == ["policy", "rm"] ->
          policy_name = List.last(command_args)

          if json?,
            do: {json_policy_output(policy_name), 0},
            else: {"Removed policy `#{policy_name}` successfully.\n", 0}

        subcommand == "admin" and Enum.take(command_args, 2) == ["user", "list"] ->
          admin_user_list || {"#{Process.get(:admin_fixture_user)} enabled", 0}

        subcommand == "admin" and Enum.take(command_args, 2) == ["user", "info"] ->
          target_name = List.last(command_args)

          if json? do
            status =
              if Process.get(:admin_fixture_status) == :disabled, do: "disabled", else: "enabled"

            {json_user_info_output(target_name, status), 0}
          else
            case admin_user_info do
              nil ->
                status =
                  if target_name != @config.access_key and
                       Process.get(:admin_fixture_status) == :disabled,
                     do: "disabled",
                     else: "enabled"

                {human_user_info(target_name, status), 0}

              {output, status} when status == 0 ->
                {"AccessKey: #{target_name}\n#{output}", status}

              failure ->
                failure
            end
          end

        subcommand == "admin" and Enum.take(command_args, 2) == ["user", "disable"] ->
          Process.put(:admin_fixture_status, :disabled)

          if json?,
            do: {json_user_mutation_output(user_name), 0},
            else: {"Disabled user `#{user_name}` successfully.\n", 0}

        subcommand == "admin" and Enum.take(command_args, 2) == ["user", "enable"] ->
          Process.put(:admin_fixture_status, :enabled)

          if json?,
            do: {json_user_mutation_output(user_name), 0},
            else: {"Enabled user `#{user_name}` successfully.\n", 0}

        subcommand == "admin" and Enum.take(command_args, 2) == ["user", "remove"] ->
          target_name = List.last(command_args)

          if target_name == @config.access_key or Process.get(:admin_fixture_status) == :removed do
            {"",
             "mc: <ERROR> Unable to remove #{target_name}. The specified user does not exist. (Specified user does not exist).\n",
             1}
          else
            Process.put(:admin_fixture_status, :removed)

            if json?,
              do: {json_user_mutation_output(user_name), "", 0},
              else: {"Removed user `#{user_name}` successfully.\n", "", 0}
          end

        true ->
          {"ok", 0}
      end
    end
  end

  defp parse_mc_args(args, opts) do
    {config_dir, remaining_args} =
      case args do
        ["--config-dir", config_dir | rest] ->
          {config_dir, rest}

        rest ->
          env = Keyword.fetch!(opts, :env)
          {"MC_CONFIG_DIR", config_dir} = Enum.find(env, &(elem(&1, 0) == "MC_CONFIG_DIR"))
          {config_dir, rest}
      end

    case remaining_args do
      ["--json" | rest] -> {config_dir, true, rest}
      rest -> {config_dir, false, rest}
    end
  end

  defp normalize_test_command_result({stdout, stderr, status}),
    do: {stdout, stderr, status}

  defp normalize_test_command_result({stdout, status}), do: {stdout, "", status}

  defp json_policy_output(policy_name) do
    "{\n" <>
      " \"status\": \"success\",\n" <>
      " \"policy\": #{Jason.encode!(policy_name)},\n" <>
      " \"isGroup\": false\n" <>
      "}\n"
  end

  defp json_association_output(operation, policies, user_name) do
    field = if operation == :attach, do: "policiesAttached", else: "policiesDetached"
    policy_lines = Enum.map_join(policies, ",\n", &("  " <> Jason.encode!(&1)))

    "{\n" <>
      " \"status\": \"success\",\n" <>
      " \"#{field}\": [\n" <>
      policy_lines <>
      "\n ],\n" <>
      " \"user\": #{Jason.encode!(user_name)}\n" <>
      "}\n"
  end

  defp json_entities_output(policy_name, user_name, timestamp) do
    "{\n" <>
      "  \"status\": \"success\",\n" <>
      "  \"result\": {\n" <>
      "    \"timestamp\": #{Jason.encode!(timestamp)},\n" <>
      "    \"policyMappings\": [\n" <>
      "      {\n" <>
      "        \"policy\": #{Jason.encode!(policy_name)},\n" <>
      "        \"users\": [\n" <>
      "          #{Jason.encode!(user_name)}\n" <>
      "        ],\n" <>
      "        \"groups\": null\n" <>
      "      }\n" <>
      "    ]\n" <>
      "  }\n" <>
      "}\n"
  end

  defp json_user_info_output(user_name, status) do
    "{\n" <>
      " \"status\": \"success\",\n" <>
      " \"accessKey\": #{Jason.encode!(user_name)},\n" <>
      " \"userStatus\": #{Jason.encode!(status)}\n" <>
      "}\n"
  end

  defp json_user_mutation_output(user_name) do
    "{\n" <>
      " \"status\": \"success\",\n" <>
      " \"accessKey\": #{Jason.encode!(user_name)}\n" <>
      "}\n"
  end

  defp human_user_info(user_name, status) do
    "AccessKey: #{user_name}\nStatus: #{status}\nPolicyName: \nMemberOf: []\n"
  end

  defp mutate_human_success(canonical, :missing_lf), do: canonical
  defp mutate_human_success(canonical, :double_lf), do: canonical <> "\n\n"
  defp mutate_human_success(canonical, :trailing_space), do: canonical <> " \n"
  defp mutate_human_success(canonical, :lone_cr), do: canonical <> "\r"

  defp mutate_json_document(output, :missing_lf), do: String.trim_trailing(output, "\n")
  defp mutate_json_document(output, :double_lf), do: String.trim_trailing(output, "\n") <> "\n\n"

  defp mutate_json_document(output, :compact) do
    output
    |> Jason.decode!()
    |> Jason.encode!()
    |> Kernel.<>("\n")
  end

  defp tmp_root do
    Path.join(
      System.tmp_dir!(),
      "maxio_external_smoke_test_#{System.unique_integer([:positive])}"
    )
  end
end
