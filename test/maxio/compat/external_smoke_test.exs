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

    assert Enum.map(entry["steps"], & &1["id"]) == ["create_bucket", "head_bucket", "put_object"]
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
        tmp_root_fun: fn -> tmp_root end
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
             "delete_copied_object",
             "delete_object",
             "delete_bucket"
           ]

    assert entry["scenario_counts"]["object_copy"] == 3

    encoded = Jason.encode!(entry)
    refute encoded =~ "super-secret"
    refute encoded =~ "test-access"

    calls = Process.get(:mc_calls) |> Enum.reverse()
    [{_command, ["--config-dir", config_dir | _args], _opts} | _rest] = calls

    assert config_dir |> Path.dirname() |> Path.dirname() |> Path.expand() |> Path.split() ==
             tmp_root |> Path.expand() |> Path.split()

    assert length(calls) == 10

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

    refute File.exists?(config_dir)
    refute File.exists?(Path.dirname(config_dir))
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
        tmp_root_fun: &tmp_root/0
      )

    assert entry["status"] == "blocked"

    assert [%{"reason" => "external_smoke_output_missing", "step" => "stat_object"}] =
             entry["blockers"]
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

      if Enum.join(args, " ") =~ "importlib.util.find_spec('boto3')" do
        {"", 0}
      else
        {"blocked for env inspection", 9}
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
        system_env: %{
          "NO_PROXY" => "example.com,LOCALHOST",
          "no_proxy" => "EXAMPLE.com,service.internal"
        }
      )

    assert Enum.map(entries, & &1["status"]) == ["blocked", "blocked", "blocked"]

    calls = Process.get(:proxy_env_calls)
    assert length(calls) == 10
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

  defp tmp_root do
    Path.join(
      System.tmp_dir!(),
      "maxio_external_smoke_test_#{System.unique_integer([:positive])}"
    )
  end
end
