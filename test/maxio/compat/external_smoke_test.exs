defmodule Maxio.Compat.ExternalSmokeTest do
  use ExUnit.Case, async: true

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
    assert Keyword.fetch!(opts, :stderr_to_stdout)
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

  test "mc smoke keeps credentials in env and redacts output snippets" do
    tmp_root = tmp_root()
    on_exit(fn -> File.rm_rf(tmp_root) end)
    Process.put(:mc_calls, [])

    command_runner = fn command, args, opts ->
      ["--config-dir", config_dir, subcommand | command_args] = args
      Process.put(:mc_calls, [{command, args, opts} | Process.get(:mc_calls)])

      File.mkdir_p!(config_dir)
      File.write!(Path.join(config_dir, "initialized-by-mc"), "temporary")

      cond do
        subcommand == "admin" and Enum.take(command_args, 2) == ["policy", "create"] ->
          ["policy", "create", "maxiocompat", policy_name, policy_path] = command_args
          Process.put(:policy_name, policy_name)
          Process.put(:policy_fixture, File.read!(policy_path))
          {"Created policy `#{policy_name}` successfully.", 0}

        subcommand == "admin" and Enum.take(command_args, 3) == ["policy", "ls", "maxiocompat"] ->
          {Process.get(:policy_name), 0}

        subcommand == "admin" and Enum.take(command_args, 3) == ["policy", "info", "maxiocompat"] ->
          ["policy", "info", "maxiocompat", policy_name] = command_args
          {"PolicyName: #{policy_name}", 0}

        subcommand == "admin" and Enum.take(command_args, 3) == ["user", "list", "maxiocompat"] ->
          ["user", "list", "maxiocompat"] = command_args
          user_name = Process.get(:admin_fixture_user)
          send(self(), {:admin_user_list, user_name})
          {"#{user_name} enabled\nsuper-secret test-access", 0}

        subcommand == "admin" and Enum.take(command_args, 3) == ["user", "info", "maxiocompat"] ->
          ["user", "info", "maxiocompat", user_name] = command_args
          send(self(), {:admin_user_info, user_name})
          {"AccessKey: #{user_name}\nStatus: enabled\nsuper-secret test-access", 0}

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
             "admin_policy_create",
             "admin_policy_list",
             "admin_policy_info",
             "admin_user_list",
             "admin_user_info",
             "admin_policy_remove",
             "delete_copied_object",
             "delete_object",
             "delete_bucket",
             "admin_user_fixture_cleanup"
           ]

    assert entry["scenario_counts"]["object_copy"] == 3
    assert entry["scenario_counts"]["admin_policy_lifecycle"] == 4
    assert entry["scenario_counts"]["admin_user_list"] == 1
    assert entry["scenario_counts"]["admin_user_info"] == 1

    encoded = Jason.encode!(entry)
    refute encoded =~ "super-secret"
    refute encoded =~ "test-access"

    calls = Process.get(:mc_calls) |> Enum.reverse()
    [{_command, ["--config-dir", config_dir | _args], _opts} | _rest] = calls

    assert config_dir |> Path.dirname() |> Path.dirname() |> Path.expand() |> Path.split() ==
             tmp_root |> Path.expand() |> Path.split()

    assert length(calls) == 16

    Enum.each(calls, fn {command, args, opts} ->
      assert command == "mc.exe"
      assert Enum.take(args, 2) == ["--config-dir", config_dir]
      refute Enum.any?(args, &String.contains?(&1, "test-access"))
      refute Enum.any?(args, &String.contains?(&1, "super-secret"))

      env = Keyword.fetch!(opts, :env)

      assert {"MC_HOST_maxiocompat", mc_host} =
               Enum.find(env, &(elem(&1, 0) == "MC_HOST_maxiocompat"))

      assert mc_host =~ "test-access"
      assert mc_host =~ "super-secret"
      assert_loopback_bypass(opts, "127.0.0.1")
    end)

    assert ["--config-dir", ^config_dir, "mb", _bucket] = elem(hd(calls), 1)

    assert [
             "--config-dir",
             ^config_dir,
             "cp",
             "--attr",
             "maxio-smoke=deep-matrix",
             _payload,
             _object
           ] = elem(Enum.at(calls, 1), 1)

    assert [
             "--config-dir",
             ^config_dir,
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
               "Action" => "s3:GetObject",
               "Resource" => "arn:aws:s3:::maxio-compat-*/*"
             }
           }

    assert ["--config-dir", ^config_dir, "admin", "policy", "ls", "maxiocompat"] =
             elem(Enum.at(calls, 8), 1)

    assert [
             "--config-dir",
             ^config_dir,
             "admin",
             "policy",
             "info",
             "maxiocompat",
             ^policy_name
           ] = elem(Enum.at(calls, 9), 1)

    assert [
             "--config-dir",
             ^config_dir,
             "admin",
             "user",
             "list",
             "maxiocompat"
           ] = elem(Enum.at(calls, 10), 1)

    assert [
             "--config-dir",
             ^config_dir,
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

    assert [
             "--config-dir",
             ^config_dir,
             "admin",
             "policy",
             "rm",
             "maxiocompat",
             ^policy_name
           ] = elem(Enum.at(calls, 12), 1)

    refute Enum.any?(calls, fn {_command, args, _opts} ->
             args_text = Enum.join(args, " ")

             args_text =~ " admin user add " or args_text =~ " admin user enable " or
               args_text =~ " admin user disable " or
               args_text =~ " admin user remove "
           end)

    refute File.exists?(config_dir)
    refute File.exists?(Path.dirname(config_dir))
  end

  test "late mc failure does not replay resources already removed successfully" do
    Process.put(:policy_remove_calls, 0)
    Process.put(:delete_copied_calls, 0)

    runner = fn _command, args, _opts ->
      ["--config-dir", _config_dir, subcommand | command_args] = args

      cond do
        subcommand == "cp" and Enum.any?(command_args, &File.regular?/1) ->
          payload_path = Enum.find(command_args, &File.regular?/1)
          Process.put(:cleanup_payload, File.read!(payload_path))
          {"copied", 0}

        subcommand == "stat" ->
          {"maxio-smoke: deep-matrix", 0}

        subcommand == "cat" ->
          {Process.get(:cleanup_payload), 0}

        subcommand == "admin" and Enum.take(command_args, 2) == ["policy", "create"] ->
          ["policy", "create", "maxiocompat", policy_name, _policy_path] = command_args
          Process.put(:cleanup_policy_name, policy_name)
          {"created", 0}

        subcommand == "admin" and Enum.take(command_args, 2) == ["policy", "ls"] ->
          {Process.get(:cleanup_policy_name), 0}

        subcommand == "admin" and Enum.take(command_args, 2) == ["policy", "info"] ->
          {"PolicyName #{Process.get(:cleanup_policy_name)}", 0}

        subcommand == "admin" and Enum.take(command_args, 2) == ["user", "list"] ->
          {"#{Process.get(:admin_fixture_user)} enabled", 0}

        subcommand == "admin" and Enum.take(command_args, 2) == ["user", "info"] ->
          {"AccessKey: #{Process.get(:admin_fixture_user)}\nStatus: enabled", 0}

        subcommand == "admin" and Enum.take(command_args, 2) == ["policy", "rm"] ->
          calls = Process.get(:policy_remove_calls) + 1
          Process.put(:policy_remove_calls, calls)

          if calls == 1, do: {"removed", 0}, else: {"policy not found", 1}

        subcommand == "rm" and String.contains?(List.last(command_args), "-copy") ->
          calls = Process.get(:delete_copied_calls) + 1
          Process.put(:delete_copied_calls, calls)

          if calls == 1, do: {"late cleanup failure", 9}, else: {"removed", 0}

        true ->
          {"ok", 0}
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
    assert Process.get(:policy_remove_calls) == 1
    assert Process.get(:delete_copied_calls) == 2
    assert entry["scenario_counts"]["admin_policy_lifecycle"] == 4
    assert entry["scenario_counts"]["cleanup"] == 4

    assert Enum.all?(Enum.frequencies(Enum.map(entry["steps"], & &1["id"])), fn {_id, n} ->
             n == 1
           end)
  end

  test "failed first mc creation does not clean resources that were never created" do
    owner = self()

    runner = fn _command, args, _opts ->
      ["--config-dir", _config_dir, subcommand | _command_args] = args

      if subcommand == "mb" do
        {"bucket creation failed", 9}
      else
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

    assert Enum.map(entry["steps"], & &1["id"]) == [
             "make_bucket",
             "admin_user_fixture_cleanup"
           ]

    assert entry["scenario_counts"] == %{
             "bucket_lifecycle" => 1,
             "cleanup" => 1
           }

    refute_received {:unexpected_cleanup, _args}
  end

  test "mc smoke blocks when stat output does not include metadata" do
    command_runner = fn _command, args, _opts ->
      ["--config-dir", _config_dir, subcommand | command_args] = args

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
      assert List.last(entry["steps"])["id"] == "admin_user_fixture_cleanup"
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
    user_commands = Enum.filter(argv, &(Enum.slice(&1, 2, 2) == ["admin", "user"]))
    assert Enum.count(user_commands, &(Enum.at(&1, 4) == "list")) == 2
    assert Enum.count(user_commands, &(Enum.at(&1, 4) == "info")) == 2

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
    assert List.last(entry["steps"])["id"] == "admin_user_fixture_cleanup"
    assert [%{"reason" => "external_smoke_cleanup_failed"}] = entry["blockers"]
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

    assert List.last(entry["steps"])["id"] == "admin_user_fixture_cleanup"

    assert [
             %{"reason" => "external_smoke_step_failed", "step" => "admin_user_info"},
             %{
               "reason" => "external_smoke_cleanup_failed",
               "step" => "admin_user_fixture_cleanup"
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
    assert length(calls) == 8
    expected = "example.com,LOCALHOST,service.internal,127.0.0.1"

    Enum.each(calls, fn {_command, _args, opts} ->
      env = Keyword.fetch!(opts, :env)
      assert {"NO_PROXY", expected} in env
      assert {"no_proxy", expected} in env
    end)
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

  defp fixture_opts(owner, cleanup_result \\ :ok) do
    [
      start_repo: fn -> :ok end,
      name: "maxio-compat-user-#{System.unique_integer([:positive])}",
      create_user: fn name ->
        Process.put(:admin_fixture_user, name)
        send(owner, {:admin_fixture_created, name})
        {:ok, %{user_name: name, status: "active"}}
      end,
      cleanup_user: fn name ->
        send(owner, {:admin_fixture_cleaned, name})
        cleanup_result
      end
    ]
  end

  defp successful_mc_runner(opts \\ []) do
    admin_user_list = Keyword.get(opts, :admin_user_list)
    admin_user_info = Keyword.get(opts, :admin_user_info, {"Status: enabled", 0})

    fn _command, args, _command_opts ->
      ["--config-dir", _config_dir, subcommand | command_args] = args

      cond do
        subcommand == "cp" and Enum.any?(command_args, &File.regular?/1) ->
          payload_path = Enum.find(command_args, &File.regular?/1)
          Process.put(:successful_mc_payload, File.read!(payload_path))
          {"copied", 0}

        subcommand == "stat" ->
          {"maxio-smoke: deep-matrix", 0}

        subcommand == "cat" ->
          {Process.get(:successful_mc_payload), 0}

        subcommand == "admin" and Enum.take(command_args, 2) == ["policy", "create"] ->
          ["policy", "create", "maxiocompat", policy_name, _policy_path] = command_args
          Process.put(:successful_mc_policy, policy_name)
          {"created", 0}

        subcommand == "admin" and Enum.take(command_args, 2) == ["policy", "ls"] ->
          {Process.get(:successful_mc_policy), 0}

        subcommand == "admin" and Enum.take(command_args, 2) == ["policy", "info"] ->
          {"PolicyName #{Process.get(:successful_mc_policy)}", 0}

        subcommand == "admin" and Enum.take(command_args, 2) == ["user", "list"] ->
          admin_user_list || {"#{Process.get(:admin_fixture_user)} enabled", 0}

        subcommand == "admin" and Enum.take(command_args, 2) == ["user", "info"] ->
          case admin_user_info do
            {output, status} when status == 0 ->
              {"AccessKey: #{Process.get(:admin_fixture_user)}\n#{output}", status}

            failure ->
              failure
          end

        true ->
          {"ok", 0}
      end
    end
  end

  defp tmp_root do
    Path.join(
      System.tmp_dir!(),
      "maxio_external_smoke_test_#{System.unique_integer([:positive])}"
    )
  end
end
