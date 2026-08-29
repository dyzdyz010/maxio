defmodule Maxio.Compat.ExternalSmoke do
  @moduledoc """
  Opt-in external S3 client smoke checks for the compatibility matrix.

  These checks deliberately do not start Maxio. They use an already-running
  endpoint and configured credentials to exercise bucket lifecycle, object
  write/read, metadata, range reads, server-side copy, MinIO admin policy
  lifecycle, real `mc ls ALIAS` / `mc --json ls ALIAS` data-plane checks, and
  cleanup through external clients.
  """

  alias Maxio.Compat.AdminUserFixture

  @clients [
    %{
      id: "aws_cli",
      label: "aws-cli",
      executable_candidates: ["aws"]
    },
    %{
      id: "minio_mc",
      label: "MinIO mc",
      executable_candidates: ["mc"]
    },
    %{
      id: "python_boto3",
      label: "python-boto3",
      executable_candidates: ["python", "python3", "py"]
    }
  ]

  def client_ids, do: Enum.map(@clients, & &1.id)

  def canonical_client_id(value) do
    normalized =
      value
      |> to_string()
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/, "_")
      |> String.trim("_")

    case normalized do
      "aws" -> "aws_cli"
      "aws_cli" -> "aws_cli"
      "awscli" -> "aws_cli"
      "mc" -> "minio_mc"
      "minio_mc" -> "minio_mc"
      "minio" -> "minio_mc"
      "boto3" -> "python_boto3"
      "python_boto3" -> "python_boto3"
      "python" -> "python_boto3"
      other -> other
    end
  end

  @doc false
  def mc_output_exact?(actual, expected, os_type \\ :os.type())

  def mc_output_exact?(actual, expected, {:win32, _name}) do
    String.replace(actual, "\r\n", "\n") == expected
  end

  def mc_output_exact?(actual, expected, _os_type), do: actual == expected

  def run(config, opts \\ []) do
    config = normalize_config(config)
    system_env = Keyword.get(opts, :system_env, System.get_env())
    config = Map.put(config, :proxy_bypass_env, proxy_bypass_env(config.endpoint, system_env))
    executable_finder = Keyword.get(opts, :executable_finder, &System.find_executable/1)
    command_runner = Keyword.get(opts, :command_runner, &run_command/3)
    tmp_root_fun = Keyword.get(opts, :tmp_root_fun, &System.tmp_dir!/0)
    admin_user_fixture_opts = Keyword.get(opts, :admin_user_fixture_opts, [])
    metrics_probe = Keyword.get(opts, :metrics_probe, &default_metrics_probe/2)

    config.clients
    |> Enum.map(
      &run_client(
        &1,
        config,
        executable_finder,
        command_runner,
        tmp_root_fun,
        admin_user_fixture_opts,
        metrics_probe
      )
    )
  end

  defp default_metrics_probe(url, request_opts) do
    url
    |> Req.get!(request_opts)
    |> Map.fetch!(:status)
  end

  defp normalize_config(config) do
    clients =
      config
      |> get_config(:clients)
      |> normalize_clients()

    %{
      endpoint: config |> get_config(:endpoint) |> blank_to_nil(),
      access_key: config |> get_config(:access_key) |> blank_to_nil(),
      secret_key: config |> get_config(:secret_key) |> blank_to_nil(),
      region: config |> get_config(:region) |> blank_to_nil() || "us-east-1",
      clients: clients
    }
  end

  defp normalize_clients(nil), do: client_ids()
  defp normalize_clients([]), do: client_ids()

  defp normalize_clients(clients) do
    clients
    |> List.wrap()
    |> Enum.map(&canonical_client_id/1)
    |> Enum.uniq()
  end

  defp run_client(
         client_id,
         config,
         executable_finder,
         command_runner,
         tmp_root_fun,
         admin_user_fixture_opts,
         metrics_probe
       ) do
    started = System.monotonic_time(:millisecond)

    try do
      case client_spec(client_id) do
        nil ->
          attention_entry(client_id, client_id, started, [
            %{"reason" => "external_smoke_client_unknown", "client" => client_id}
          ])

        spec ->
          with :ok <- validate_required_config(config, client_id, spec.label),
               {:ok, executable} <- find_executable(spec, executable_finder) do
            run_configured_client(
              spec,
              executable,
              config,
              command_runner,
              tmp_root_fun,
              admin_user_fixture_opts,
              metrics_probe,
              started
            )
          else
            {:attention, warnings} ->
              attention_entry(client_id, spec.label, started, warnings)
          end
      end
    rescue
      error ->
        error_entry(client_id, client_id, started, [], [
          %{"reason" => "external_smoke_failed", "message" => Exception.message(error)}
        ])
    end
  end

  defp run_configured_client(
         spec,
         executable,
         config,
         command_runner,
         tmp_root_fun,
         admin_user_fixture_opts,
         metrics_probe,
         started
       ) do
    with_temp_paths(spec.id, tmp_root_fun, fn paths ->
      case spec.id do
        "aws_cli" ->
          run_aws_cli(spec, executable, config, paths, command_runner, started)

        "minio_mc" ->
          run_minio_mc(
            spec,
            executable,
            config,
            paths,
            command_runner,
            admin_user_fixture_opts,
            metrics_probe,
            started
          )

        "python_boto3" ->
          run_python_boto3(spec, executable, config, paths, command_runner, started)
      end
    end)
  end

  defp validate_required_config(config, client_id, _label) do
    missing =
      [
        {"endpoint", config.endpoint},
        {"access_key", config.access_key},
        {"secret_key", config.secret_key},
        {"region", config.region}
      ]
      |> Enum.filter(fn {_name, value} -> blank?(value) end)
      |> Enum.map(&elem(&1, 0))

    if missing == [] do
      :ok
    else
      {:attention,
       [
         %{
           "reason" => "external_smoke_not_configured",
           "client" => client_id,
           "missing" => missing
         }
       ]}
    end
  end

  defp find_executable(spec, executable_finder) do
    executable =
      Enum.find_value(spec.executable_candidates, fn candidate ->
        case executable_finder.(candidate) do
          nil -> nil
          "" -> nil
          path -> path
        end
      end)

    if executable do
      {:ok, executable}
    else
      {:attention,
       [
         %{
           "reason" => "external_smoke_client_not_configured",
           "client" => spec.id,
           "executables" => spec.executable_candidates
         }
       ]}
    end
  end

  defp run_aws_cli(spec, executable, config, paths, command_runner, started) do
    redactions = redactions(config)
    env = aws_env(config)

    {steps, cleanup_steps} = aws_steps(executable, config, paths, env)
    run_step_plan(spec, config, paths, steps, cleanup_steps, command_runner, redactions, started)
  end

  defp run_minio_mc(
         spec,
         executable,
         config,
         paths,
         command_runner,
         admin_user_fixture_opts,
         metrics_probe,
         started
       ) do
    redactions = redactions(config)
    env = mc_env(config)

    admin_user_fixture_opts =
      admin_user_fixture_opts
      |> Keyword.put_new(:endpoint, config.endpoint)
      |> Keyword.put_new(:initial_list_buckets_policy, false)

    human =
      run_mc_user_mode(
        :human,
        spec,
        executable,
        config,
        paths,
        env,
        command_runner,
        admin_user_fixture_opts,
        metrics_probe,
        redactions,
        started
      )

    json =
      run_mc_user_mode(
        :json,
        spec,
        executable,
        config,
        paths,
        env,
        command_runner,
        independent_fixture_opts(admin_user_fixture_opts, :json),
        metrics_probe,
        redactions,
        started
      )

    combine_mc_mode_entries(human, json)
  end

  defp run_mc_user_mode(
         mode,
         spec,
         executable,
         config,
         paths,
         env,
         command_runner,
         fixture_opts,
         metrics_probe,
         redactions,
         started
       ) do
    case AdminUserFixture.with_user(fixture_opts, fn user, _http_probe, mc_probe ->
           mode_paths = independent_mc_paths(paths, mode)

           {steps, cleanup_steps} =
             case mode do
               :human ->
                 mc_steps(
                   executable,
                   config,
                   mode_paths,
                   env,
                   user.user_name,
                   mc_probe,
                   metrics_probe
                 )

               :json ->
                 mc_json_user_steps(
                   executable,
                   config,
                   mode_paths,
                   env,
                   user.user_name,
                   mc_probe,
                   metrics_probe
                 )
             end

           run_step_plan(
             spec,
             config,
             paths,
             steps,
             cleanup_steps,
             command_runner,
             redactions,
             started
           )
         end) do
      {:ok, entry, cleanup} ->
        entry |> merge_cleanup(cleanup, redactions) |> tag_mc_mode(mode)

      {:error, blocker, cleanup} ->
        spec
        |> blocked_entry(config, paths, started, [], [redact_value(blocker, redactions)])
        |> merge_cleanup(cleanup, redactions)
        |> tag_mc_mode(mode)
    end
  end

  defp independent_fixture_opts(opts, :json) do
    case Keyword.fetch(opts, :name) do
      {:ok, name} when is_binary(name) ->
        suffix = "-json"
        max_prefix = max(3, 64 - byte_size(suffix))
        Keyword.put(opts, :name, binary_part(name, 0, min(byte_size(name), max_prefix)) <> suffix)

      _other ->
        opts
    end
  end

  defp independent_mc_paths(paths, :human), do: paths

  defp independent_mc_paths(paths, :json) do
    suffix = "-json"
    max_prefix = max(3, 128 - byte_size(suffix))

    %{
      paths
      | policy_name:
          binary_part(paths.policy_name, 0, min(byte_size(paths.policy_name), max_prefix)) <>
            suffix,
        mc_config_dir: paths.mc_config_dir <> suffix,
        mc_alias: "maxiocompatjson"
    }
  end

  defp tag_mc_mode(entry, mode) do
    suffix = Atom.to_string(mode)

    steps =
      Enum.map(entry["steps"], fn
        %{"id" => "admin_user_fixture_cleanup"} = step ->
          Map.put(step, "id", "admin_user_fixture_cleanup_#{suffix}")

        step ->
          step
      end)

    blockers =
      Enum.map(entry["blockers"], fn
        %{"step" => "admin_user_fixture_cleanup"} = blocker ->
          Map.put(blocker, "step", "admin_user_fixture_cleanup_#{suffix}")

        blocker ->
          blocker
      end)

    entry
    |> Map.put("steps", steps)
    |> Map.put("blockers", blockers)
    |> Map.put("scenario_counts", scenario_counts(steps))
  end

  defp combine_mc_mode_entries(human, json) do
    steps = human["steps"] ++ json["steps"]

    human
    |> Map.put("status", combined_status(human["status"], json["status"]))
    |> Map.put("steps", steps)
    |> Map.put("blockers", human["blockers"] ++ json["blockers"])
    |> Map.put("warnings", human["warnings"] ++ json["warnings"])
    |> Map.put("scenario_counts", scenario_counts(steps))
  end

  defp combined_status(left, right) do
    Enum.max_by([left, right], &status_rank/1)
  end

  defp status_rank("error"), do: 3
  defp status_rank("blocked"), do: 2
  defp status_rank("attention"), do: 1
  defp status_rank(_status), do: 0

  defp run_python_boto3(spec, executable, config, paths, command_runner, started) do
    redactions = redactions(config)

    with :ok <- probe_boto3_module(executable, config, command_runner) do
      steps = [
        step(
          "deep_matrix",
          executable,
          ["-c", boto3_script()],
          command_opts(config, boto3_env(config, paths)),
          :none,
          scenario: "sdk_deep_matrix",
          assertion: "boto3 verifies bucket, metadata, range, copy, and cleanup paths"
        )
      ]

      run_step_plan(spec, config, paths, steps, [], command_runner, redactions, started)
    else
      {:attention, warnings} ->
        attention_entry(spec.id, spec.label, started, warnings)
    end
  end

  defp probe_boto3_module(executable, config, command_runner) do
    python_code =
      "import importlib.util, sys; " <>
        "sys.exit(0 if importlib.util.find_spec('boto3') else 2)"

    case command_runner.(executable, ["-c", python_code], command_opts(config, [])) do
      {_output, 0} ->
        :ok

      {output, exit_status} ->
        {:attention,
         [
           %{
             "reason" => "external_smoke_client_not_configured",
             "client" => "python_boto3",
             "dependency" => "boto3",
             "detail" => "boto3 probe exited #{exit_status}: #{output_snippet(output, [])}"
           }
         ]}
    end
  rescue
    error ->
      {:attention,
       [
         %{
           "reason" => "external_smoke_client_not_configured",
           "client" => "python_boto3",
           "dependency" => "boto3",
           "detail" => Exception.message(error)
         }
       ]}
  end

  defp run_step_plan(
         spec,
         config,
         paths,
         steps,
         cleanup_steps,
         command_runner,
         redactions,
         started
       ) do
    case run_steps(steps, command_runner, redactions) do
      {:ok, step_views} ->
        ok_entry(spec, config, paths, started, step_views)

      {:blocked, step_views, blocker} ->
        cleanup =
          cleanup_steps
          |> pending_cleanup_steps(step_views)
          |> run_cleanup_steps(command_runner, redactions)

        spec
        |> blocked_entry(config, paths, started, step_views, [blocker])
        |> merge_cleanup(cleanup, redactions)

      {:error, step_views, blocker} ->
        cleanup =
          cleanup_steps
          |> pending_cleanup_steps(step_views)
          |> run_cleanup_steps(command_runner, redactions)

        spec.id
        |> error_entry(spec.label, started, step_views, [blocker], config, paths)
        |> merge_cleanup(cleanup, redactions)
    end
  end

  defp aws_steps(executable, config, paths, env) do
    base_args = ["--endpoint-url", config.endpoint, "--region", config.region]
    common_opts = command_opts(config, env)
    source = "#{paths.bucket}/#{paths.key}"

    create_args =
      base_args ++
        ["s3api", "create-bucket", "--bucket", paths.bucket] ++
        create_bucket_config_args(config.region)

    steps = [
      step("create_bucket", executable, create_args, common_opts,
        scenario: "bucket_lifecycle",
        assertion: "bucket can be created through aws-cli s3api"
      ),
      step(
        "head_bucket",
        executable,
        base_args ++ ["s3api", "head-bucket", "--bucket", paths.bucket],
        common_opts,
        scenario: "bucket_lifecycle",
        assertion: "created bucket is visible to aws-cli"
      ),
      step(
        "put_object",
        executable,
        base_args ++
          [
            "s3api",
            "put-object",
            "--bucket",
            paths.bucket,
            "--key",
            paths.key,
            "--body",
            paths.payload_path,
            "--metadata",
            "maxio-smoke=deep-matrix"
          ],
        common_opts,
        scenario: "object_write_read",
        assertion: "object upload with user metadata succeeds"
      ),
      step(
        "head_object",
        executable,
        base_args ++
          [
            "s3api",
            "head-object",
            "--bucket",
            paths.bucket,
            "--key",
            paths.key,
            "--query",
            "Metadata.\"maxio-smoke\"",
            "--output",
            "text"
          ],
        common_opts,
        {:output_equals, "deep-matrix"},
        scenario: "object_metadata",
        assertion: "uploaded object metadata value is returned by head-object"
      ),
      step(
        "get_object",
        executable,
        base_args ++
          [
            "s3api",
            "get-object",
            "--bucket",
            paths.bucket,
            "--key",
            paths.key,
            paths.download_path
          ],
        common_opts,
        {:file_equals, paths.download_path, paths.payload},
        scenario: "object_write_read",
        assertion: "downloaded object body matches uploaded bytes"
      ),
      step(
        "get_object_range",
        executable,
        base_args ++
          [
            "s3api",
            "get-object",
            "--bucket",
            paths.bucket,
            "--key",
            paths.key,
            "--range",
            paths.range_header,
            paths.range_download_path
          ],
        common_opts,
        {:file_equals, paths.range_download_path, paths.range_payload},
        scenario: "range_read",
        assertion: "byte range download returns only the requested slice"
      ),
      step(
        "copy_object",
        executable,
        base_args ++
          [
            "s3api",
            "copy-object",
            "--bucket",
            paths.bucket,
            "--key",
            paths.copied_key,
            "--copy-source",
            source
          ],
        common_opts,
        scenario: "object_copy",
        assertion: "server-side copy creates a second object"
      ),
      step(
        "head_copied_object",
        executable,
        base_args ++
          [
            "s3api",
            "head-object",
            "--bucket",
            paths.bucket,
            "--key",
            paths.copied_key,
            "--query",
            "Metadata.\"maxio-smoke\"",
            "--output",
            "text"
          ],
        common_opts,
        {:output_equals, "deep-matrix"},
        scenario: "object_copy",
        assertion: "copied object preserves metadata value"
      ),
      step(
        "get_copied_object",
        executable,
        base_args ++
          [
            "s3api",
            "get-object",
            "--bucket",
            paths.bucket,
            "--key",
            paths.copied_key,
            paths.copy_download_path
          ],
        common_opts,
        {:file_equals, paths.copy_download_path, paths.payload},
        scenario: "object_copy",
        assertion: "copied object body matches the source bytes"
      ),
      step(
        "delete_copied_object",
        executable,
        base_args ++
          ["s3api", "delete-object", "--bucket", paths.bucket, "--key", paths.copied_key],
        common_opts,
        scenario: "cleanup",
        assertion: "copied object can be deleted"
      ),
      step(
        "delete_object",
        executable,
        base_args ++
          ["s3api", "delete-object", "--bucket", paths.bucket, "--key", paths.key],
        common_opts,
        scenario: "cleanup",
        assertion: "source object can be deleted"
      ),
      step(
        "delete_bucket",
        executable,
        base_args ++ ["s3api", "delete-bucket", "--bucket", paths.bucket],
        common_opts,
        scenario: "cleanup",
        assertion: "empty bucket can be deleted"
      )
    ]

    cleanup_steps =
      select_cleanup_steps(steps, [
        {"delete_copied_object", "copy_object"},
        {"delete_object", "put_object"},
        {"delete_bucket", "create_bucket"}
      ])

    {steps, cleanup_steps}
  end

  defp mc_config_lifecycle_steps(mode, executable, config, paths, opts, metrics_probe) do
    scenario = mc_config_scenario(mode)
    metrics_url = metrics_url(config.endpoint)
    base_args = mc_config_base_args(mode)
    mc_alias = paths.mc_alias
    help_steps = mc_config_help_steps(mode, executable, mc_alias, opts)

    mutation_steps = [
      metrics_probe_step(
        mc_config_step_id(mode, :metrics_denied_before),
        metrics_url,
        metrics_probe,
        403,
        scenario,
        "anonymous metrics are denied before prometheus_metrics.public is enabled"
      ),
      step(
        mc_config_step_id(mode, :get_false),
        executable,
        base_args ++ ["admin", "config", "get", mc_alias, "prometheus_metrics"],
        opts,
        {:output_exact, mc_config_output(mode, :get_false)},
        scenario: scenario,
        assertion: "mc admin config get reports effective prometheus_metrics.public=false"
      ),
      step(
        mc_config_step_id(mode, :set_true),
        executable,
        base_args ++
          ["admin", "config", "set", mc_alias, "prometheus_metrics", "public=true"],
        opts,
        {:output_exact, mc_config_output(mode, :set_true)},
        scenario: scenario,
        assertion:
          "mc admin config set hot-applies prometheus_metrics.public=true without restart text"
      ),
      step(
        mc_config_step_id(mode, :get_true),
        executable,
        base_args ++ ["admin", "config", "get", mc_alias, "prometheus_metrics"],
        opts,
        {:output_exact, mc_config_output(mode, :get_true)},
        scenario: scenario,
        assertion: "mc admin config get reports effective prometheus_metrics.public=true"
      ),
      metrics_probe_step(
        mc_config_step_id(mode, :metrics_public),
        metrics_url,
        metrics_probe,
        200,
        scenario,
        "anonymous metrics become available after the hot config change"
      ),
      step(
        mc_config_step_id(mode, :reset_public),
        executable,
        base_args ++
          ["admin", "config", "reset", mc_alias, "prometheus_metrics", "public"],
        opts,
        {:output_exact, mc_config_output(mode, :reset_public)},
        scenario: scenario,
        assertion: "mc admin config reset removes only the prometheus_metrics public key"
      ),
      step(
        mc_config_step_id(mode, :get_false_after_reset),
        executable,
        base_args ++ ["admin", "config", "get", mc_alias, "prometheus_metrics"],
        opts,
        {:output_exact, mc_config_output(mode, :get_false)},
        scenario: scenario,
        assertion: "mc admin config get reports public=false after reset"
      ),
      metrics_probe_step(
        mc_config_step_id(mode, :metrics_denied_after_reset),
        metrics_url,
        metrics_probe,
        403,
        scenario,
        "anonymous metrics are denied again after reset"
      )
    ]

    help_steps ++ mutation_steps
  end

  defp mc_config_help_steps(mode, executable, mc_alias, opts) do
    base_args = mc_config_base_args(mode)
    scenario = mc_config_help_scenario(mode)

    [
      {:get_alias, ["admin", "config", "get", mc_alias], :top_level},
      {:reset_alias, ["admin", "config", "reset", mc_alias], :top_level},
      {:set_subsystem, ["admin", "config", "set", mc_alias, "s3"], :s3},
      {:set_key, ["admin", "config", "set", mc_alias, "s3", "clock_skew_ms"], :s3}
    ]
    |> Enum.map(fn {stage, command_args, transcript} ->
      args = base_args ++ command_args

      step(
        mc_config_help_step_id(mode, stage),
        executable,
        args,
        opts,
        {:output_exact, mc_config_help_output(mode, transcript)},
        scenario: scenario,
        assertion: "native mc dispatches the #{stage} config help branch"
      )
      |> Map.merge(%{
        argv: args,
        expected_evidence: "fixture_expected",
        observed_evidence: "fake_observed"
      })
    end)
  end

  defp mc_config_cleanup_step(mode, executable, paths, opts) do
    step(
      mc_config_step_id(mode, :cleanup_reset),
      executable,
      mc_config_base_args(mode) ++
        ["admin", "config", "reset", paths.mc_alias, "prometheus_metrics", "public"],
      opts,
      {:output_exact, mc_config_output(mode, :reset_public)},
      scenario: mc_config_scenario(mode),
      assertion: "failed config lifecycle cleanup restores prometheus_metrics.public default"
    )
    |> Map.put(:created_by, :always)
    |> Map.put(:failure_scenario, [mc_config_help_scenario(mode), mc_config_scenario(mode)])
  end

  defp metrics_probe_step(id, metrics_url, metrics_probe, expected, scenario, assertion) do
    %{
      id: id,
      command: "GET",
      args: [metrics_url],
      opts: [],
      verify: {:output_exact, Integer.to_string(expected)},
      scenario: scenario,
      assertion: assertion,
      local_fun: fn -> metrics_probe.(metrics_url, redirect: false) end
    }
  end

  defp metrics_url(endpoint) do
    endpoint
    |> URI.merge("/minio/v2/metrics/cluster")
    |> to_string()
  end

  defp mc_config_base_args(:human), do: []
  defp mc_config_base_args(:json), do: ["--json"]

  defp mc_config_scenario(mode), do: "admin_config_#{mode}_lifecycle"
  defp mc_config_help_scenario(mode), do: "admin_config_help_#{mode}"

  defp mc_config_help_step_id(mode, stage), do: "admin_config_help_#{mode}_#{stage}"

  defp mc_config_step_id(mode, stage) do
    suffix =
      case stage do
        :metrics_denied_before -> "metrics_denied_before"
        :get_false -> "get_false"
        :set_true -> "set_true"
        :get_true -> "get_true"
        :metrics_public -> "metrics_public"
        :reset_public -> "reset_public"
        :get_false_after_reset -> "get_false_after_reset"
        :metrics_denied_after_reset -> "metrics_denied_after_reset"
        :cleanup_reset -> "cleanup_reset_public"
      end

    "admin_config_#{mode}_#{suffix}"
  end

  defp mc_config_output(:human, :get_false), do: "prometheus_metrics public=false \n"
  defp mc_config_output(:human, :get_true), do: "prometheus_metrics public=true \n"
  defp mc_config_output(:human, :set_true), do: "Successfully applied new settings.\n"

  defp mc_config_output(:human, :reset_public),
    do: "'prometheus_metrics public' is successfully reset.\n"

  defp mc_config_output(:json, :get_false) do
    "{\"status\":\"success\",\"config\":[{\"subSystem\":\"prometheus_metrics\",\"kv\":[{\"key\":\"public\",\"value\":\"false\"}]}]}\n"
  end

  defp mc_config_output(:json, :get_true) do
    "{\"status\":\"success\",\"config\":[{\"subSystem\":\"prometheus_metrics\",\"kv\":[{\"key\":\"public\",\"value\":\"true\"}]}]}\n"
  end

  defp mc_config_output(:json, stage) when stage in [:set_true, :reset_public],
    do: "{\"status\":\"success\"}\n"

  defp mc_config_help_output(:human, :top_level) do
    "KEYS:\n" <>
      "s3                  Maxio extension: configure s3.clock_skew_ms.\n" <>
      "listing             Maxio extension: configure listing.sql_hard_limit.\n" <>
      "prometheus_metrics  Maxio extension: configure prometheus_metrics.public.\n"
  end

  defp mc_config_help_output(:human, :s3) do
    "KEY:\n" <>
      "s3  Maxio extension: configure s3.clock_skew_ms.\n\n" <>
      "ARGS:\n" <>
      "clock_skew_ms  (integer in 0..3600000)  Maximum allowed SigV4 header-signature clock skew in milliseconds; applied to the next authentication request.\n"
  end

  defp mc_config_help_output(:json, :top_level) do
    "{\"status\":\"success\",\"help\":{\"subSys\":\"\",\"description\":\"\",\"multipleTargets\":false,\"keysHelp\":[{\"key\":\"s3\",\"description\":\"Maxio extension: configure s3.clock_skew_ms.\",\"optional\":false,\"type\":\"\",\"multipleTargets\":false},{\"key\":\"listing\",\"description\":\"Maxio extension: configure listing.sql_hard_limit.\",\"optional\":false,\"type\":\"\",\"multipleTargets\":false},{\"key\":\"prometheus_metrics\",\"description\":\"Maxio extension: configure prometheus_metrics.public.\",\"optional\":false,\"type\":\"\",\"multipleTargets\":false}]}}\n"
  end

  defp mc_config_help_output(:json, :s3) do
    "{\"status\":\"success\",\"help\":{\"subSys\":\"s3\",\"description\":\"Maxio extension: configure s3.clock_skew_ms.\",\"multipleTargets\":false,\"keysHelp\":[{\"key\":\"clock_skew_ms\",\"description\":\"Maximum allowed SigV4 header-signature clock skew in milliseconds; applied to the next authentication request.\",\"optional\":true,\"type\":\"integer in 0..3600000\",\"multipleTargets\":false}]}}\n"
  end

  defp mc_steps(executable, config, paths, env, user_name, mc_probe, metrics_probe) do
    opts = command_opts(config, [{"MC_CONFIG_DIR", paths.mc_config_dir} | env])
    base_args = []
    object = "maxiocompat/#{paths.bucket}/#{paths.key}"
    copied_object = "maxiocompat/#{paths.bucket}/#{paths.copied_key}"
    bucket = "maxiocompat/#{paths.bucket}"

    steps = [
      step("make_bucket", executable, base_args ++ ["mb", bucket], opts,
        scenario: "bucket_lifecycle",
        assertion: "bucket can be created through mc"
      ),
      step(
        "put_object",
        executable,
        base_args ++
          ["cp", "--attr", "maxio-smoke=deep-matrix", paths.payload_path, object],
        opts,
        scenario: "object_write_read",
        assertion: "object upload with custom metadata succeeds through mc cp"
      ),
      step(
        "stat_object",
        executable,
        base_args ++ ["stat", object],
        opts,
        {:output_contains, ["maxio-smoke", "deep-matrix"]},
        scenario: "object_metadata",
        assertion: "uploaded object metadata is returned through mc stat"
      ),
      step(
        "get_object",
        executable,
        base_args ++ ["cat", object],
        opts,
        {:output_equals, paths.payload},
        scenario: "object_write_read",
        assertion: "mc cat returns uploaded object bytes"
      ),
      step("copy_object", executable, base_args ++ ["cp", object, copied_object], opts,
        scenario: "object_copy",
        assertion: "server-side object copy succeeds through mc cp"
      ),
      step(
        "stat_copied_object",
        executable,
        base_args ++ ["stat", copied_object],
        opts,
        {:output_contains, ["maxio-smoke", "deep-matrix"]},
        scenario: "object_copy",
        assertion: "copied object metadata is returned through mc stat"
      ),
      step(
        "get_copied_object",
        executable,
        base_args ++ ["cat", copied_object],
        opts,
        {:output_equals, paths.payload},
        scenario: "object_copy",
        assertion: "copied object body matches the source bytes"
      ),
      step(
        "admin_policy_human_create",
        executable,
        base_args ++
          [
            "admin",
            "policy",
            "create",
            "maxiocompat",
            paths.policy_name,
            paths.policy_path
          ],
        opts,
        scenario: "admin_policy_lifecycle",
        assertion: "managed policy can be created through mc admin"
      ),
      step(
        "admin_policy_human_list",
        executable,
        base_args ++ ["admin", "policy", "ls", "maxiocompat"],
        opts,
        {:output_contains, [paths.policy_name]},
        scenario: "admin_policy_lifecycle",
        assertion: "created managed policy is visible through mc admin policy ls"
      ),
      step(
        "admin_policy_human_info",
        executable,
        base_args ++ ["admin", "policy", "info", "maxiocompat", paths.policy_name],
        opts,
        {:output_contains, ["PolicyName", paths.policy_name]},
        scenario: "admin_policy_lifecycle",
        assertion: "mc admin policy info returns the named PolicyInfo projection"
      ),
      step(
        "admin_user_list",
        executable,
        base_args ++ ["admin", "user", "list", "maxiocompat"],
        opts,
        {:output_contains, [user_name, "enabled"]},
        scenario: "admin_user_list",
        assertion: "mc admin user list returns the active temporary IAM user"
      ),
      step(
        "admin_user_info",
        executable,
        base_args ++ ["admin", "user", "info", "maxiocompat", user_name],
        opts,
        {:output_exact, human_user_info(user_name, "enabled")},
        scenario: "admin_user_info",
        assertion: "mc admin user info returns the active temporary IAM user"
      ),
      mc_probe_step(
        "admin_policy_human_mc_ls_baseline_denied",
        executable,
        paths,
        opts,
        mc_probe,
        :human,
        :rejected,
        "admin_policy_association_lifecycle",
        "unprivileged temporary user cannot list buckets before attach"
      ),
      step(
        "admin_policy_human_attach",
        executable,
        base_args ++
          ["admin", "policy", "attach", "maxiocompat", paths.policy_name, "--user", user_name],
        opts,
        {:output_exact, association_human_output(:attach, [paths.policy_name], user_name)},
        scenario: "admin_policy_association_lifecycle",
        assertion: "mc attaches the dedicated ListBuckets policy"
      ),
      mc_probe_step(
        "admin_policy_human_mc_ls_attached",
        executable,
        paths,
        opts,
        mc_probe,
        :human,
        :success,
        "admin_policy_association_lifecycle",
        "attached managed policy enables ListBuckets"
      ),
      step(
        "admin_policy_human_attach_no_effect",
        executable,
        base_args ++
          [
            "admin",
            "policy",
            "attach",
            "maxiocompat",
            paths.policy_name,
            paths.policy_name,
            "--user",
            user_name
          ],
        opts,
        {:output_exact,
         association_human_output(:attach, [paths.policy_name, paths.policy_name], user_name)},
        scenario: "admin_policy_association_lifecycle",
        assertion: "pinned mc synthesizes no-effect success from original duplicate argv"
      ),
      step(
        "admin_policy_human_entities",
        executable,
        base_args ++ policy_entities_args(paths.policy_name, user_name),
        opts,
        {:policy_entities_human, paths.policy_name, user_name},
        scenario: "admin_policy_association_lifecycle",
        assertion: "mc renders policy entities after independently repeated filters"
      ),
      step(
        "admin_policy_human_detach",
        executable,
        base_args ++
          ["admin", "policy", "detach", "maxiocompat", paths.policy_name, "--user", user_name],
        opts,
        {:output_exact, association_human_output(:detach, [paths.policy_name], user_name)},
        scenario: "admin_policy_association_lifecycle",
        assertion: "mc detaches the dedicated policy"
      ),
      mc_probe_step(
        "admin_policy_human_mc_ls_detached",
        executable,
        paths,
        opts,
        mc_probe,
        :human,
        :rejected,
        "admin_policy_association_lifecycle",
        "detaching the only grant restores S3 denial"
      ),
      step(
        "admin_policy_human_reattach",
        executable,
        base_args ++
          ["admin", "policy", "attach", "maxiocompat", paths.policy_name, "--user", user_name],
        opts,
        {:output_exact, association_human_output(:attach, [paths.policy_name], user_name)},
        scenario: "admin_policy_association_lifecycle",
        assertion: "policy is reattached before the existing user-status lifecycle"
      ),
      step(
        "admin_user_human_disable",
        executable,
        base_args ++ ["admin", "user", "disable", "maxiocompat", user_name],
        opts,
        {:output_exact, "Disabled user `#{user_name}` successfully.\n"},
        scenario: "admin_user_human_lifecycle",
        assertion: "mc disables the temporary user"
      ),
      step(
        "admin_user_human_info_disabled",
        executable,
        base_args ++ ["admin", "user", "info", "maxiocompat", user_name],
        opts,
        {:output_exact, human_user_info(user_name, "disabled")},
        scenario: "admin_user_human_lifecycle",
        assertion: "mc reports disabled status"
      ),
      mc_probe_step(
        "admin_user_human_mc_ls_disabled",
        executable,
        paths,
        opts,
        mc_probe,
        :human,
        :rejected,
        "admin_user_human_lifecycle",
        "disabled user is rejected by S3"
      ),
      step(
        "admin_user_human_enable",
        executable,
        base_args ++ ["admin", "user", "enable", "maxiocompat", user_name],
        opts,
        {:output_exact, "Enabled user `#{user_name}` successfully.\n"},
        scenario: "admin_user_human_lifecycle",
        assertion: "mc re-enables the temporary user"
      ),
      step(
        "admin_user_human_info_reenabled",
        executable,
        base_args ++ ["admin", "user", "info", "maxiocompat", user_name],
        opts,
        {:output_exact, human_user_info(user_name, "enabled")},
        scenario: "admin_user_human_lifecycle",
        assertion: "mc reports re-enabled status"
      ),
      mc_probe_step(
        "admin_user_human_mc_ls_reenabled",
        executable,
        paths,
        opts,
        mc_probe,
        :human,
        :success,
        "admin_user_human_lifecycle",
        "the same credential works after re-enable"
      ),
      step(
        "admin_policy_human_cleanup_detach",
        executable,
        base_args ++
          ["admin", "policy", "detach", "maxiocompat", paths.policy_name, "--user", user_name],
        opts,
        {:output_exact, association_human_output(:detach, [paths.policy_name], user_name)},
        scenario: "admin_policy_association_lifecycle",
        assertion: "cleanup detaches policy before deleting user and managed policy"
      ),
      step(
        "admin_user_human_remove",
        executable,
        base_args ++ ["admin", "user", "remove", "maxiocompat", user_name],
        opts,
        {:output_exact, "Removed user `#{user_name}` successfully.\n"},
        scenario: "admin_user_human_lifecycle",
        assertion: "mc removes the temporary user"
      ),
      step(
        "admin_user_human_remove_again",
        executable,
        base_args ++ ["admin", "user", "remove", "maxiocompat", user_name],
        opts,
        {:expected_streams, 1, "", no_such_user_stderr(user_name)},
        scenario: "admin_user_human_lifecycle",
        assertion: "a sequential second remove returns the exact dynamic no-such-user error"
      ),
      step(
        "admin_user_human_remove_root",
        executable,
        base_args ++ ["admin", "user", "remove", "maxiocompat", config.access_key],
        opts,
        {:expected_streams, 1, "", no_such_user_stderr(config.access_key)},
        scenario: "admin_user_human_lifecycle",
        assertion: "configured-root remove returns the exact dynamic no-such-user error"
      ),
      step(
        "admin_user_human_root_probe_after_remove_rejected",
        executable,
        base_args ++ ["admin", "user", "list", "maxiocompat"],
        opts,
        :none,
        scenario: "admin_user_human_lifecycle",
        assertion: "root-signed admin request still succeeds after root removal is rejected"
      ),
      step(
        "admin_policy_human_remove",
        executable,
        base_args ++ ["admin", "policy", "rm", "maxiocompat", paths.policy_name],
        opts,
        scenario: "admin_policy_lifecycle",
        assertion: "managed policy can be removed through mc admin"
      ),
      step("delete_copied_object", executable, base_args ++ ["rm", copied_object], opts,
        scenario: "cleanup",
        assertion: "copied object can be deleted"
      ),
      step("delete_object", executable, base_args ++ ["rm", object], opts,
        scenario: "cleanup",
        assertion: "source object can be deleted"
      ),
      step("delete_bucket", executable, base_args ++ ["rb", bucket], opts,
        scenario: "cleanup",
        assertion: "empty bucket can be deleted"
      )
    ]

    {before_user_remove, user_remove_and_after} =
      Enum.split_while(steps, &(&1.id != "admin_user_human_remove"))

    steps =
      before_user_remove ++
        mc_human_group_steps(executable, paths, opts, user_name, mc_probe) ++
        user_remove_and_after ++
        mc_config_lifecycle_steps(:human, executable, config, paths, opts, metrics_probe)

    cleanup_steps =
      [
        mc_config_cleanup_step(:human, executable, paths, opts)
        | select_cleanup_steps(steps, [
            {"admin_policy_human_cleanup_detach", "admin_policy_human_create"},
            {"admin_group_human_cleanup_detach", "admin_group_human_add"},
            {"admin_group_human_cleanup_remove_member", "admin_group_human_add"},
            {"admin_group_human_remove", "admin_group_human_add"},
            {"admin_user_human_remove", "admin_policy_human_create"},
            {"admin_policy_human_remove", "admin_policy_human_create"},
            {"delete_copied_object", "copy_object"},
            {"delete_object", "put_object"},
            {"delete_bucket", "make_bucket"}
          ])
      ]

    {steps, cleanup_steps}
  end

  defp mc_json_user_steps(executable, config, paths, env, user_name, mc_probe, metrics_probe) do
    opts = command_opts(config, [{"MC_CONFIG_DIR", paths.mc_config_dir} | env])
    base_args = ["--json"]
    mc_alias = paths.mc_alias

    steps = [
      step(
        "admin_policy_json_create",
        executable,
        base_args ++
          ["admin", "policy", "create", mc_alias, paths.policy_name, paths.policy_path],
        opts,
        {:json_exact, policy_json_output(paths.policy_name)},
        scenario: "admin_policy_lifecycle",
        assertion: "JSON mode independently creates its managed policy"
      ),
      json_user_step(
        "admin_user_json_info_enabled",
        executable,
        base_args,
        opts,
        "info",
        user_name,
        mc_alias,
        %{"accessKey" => user_name, "status" => "success", "userStatus" => "enabled"}
      ),
      mc_probe_step(
        "admin_policy_json_mc_ls_baseline_denied",
        executable,
        paths,
        opts,
        mc_probe,
        :json,
        :rejected,
        "admin_policy_association_lifecycle",
        "independent JSON fixture begins without ListBuckets permission"
      ),
      step(
        "admin_policy_json_attach",
        executable,
        base_args ++
          ["admin", "policy", "attach", mc_alias, paths.policy_name, "--user", user_name],
        opts,
        {:json_exact, association_json_output(:attach, [paths.policy_name], user_name)},
        scenario: "admin_policy_association_lifecycle",
        assertion: "JSON mc attaches the dedicated policy"
      ),
      mc_probe_step(
        "admin_policy_json_mc_ls_attached",
        executable,
        paths,
        opts,
        mc_probe,
        :json,
        :success,
        "admin_policy_association_lifecycle",
        "JSON fixture can list buckets after attach"
      ),
      step(
        "admin_policy_json_attach_no_effect",
        executable,
        base_args ++
          [
            "admin",
            "policy",
            "attach",
            mc_alias,
            paths.policy_name,
            paths.policy_name,
            "--user",
            user_name
          ],
        opts,
        {:json_exact,
         association_json_output(:attach, [paths.policy_name, paths.policy_name], user_name)},
        scenario: "admin_policy_association_lifecycle",
        assertion: "JSON no-effect synthesis preserves duplicate argv"
      ),
      step(
        "admin_policy_json_entities",
        executable,
        base_args ++ policy_entities_args(paths.policy_name, user_name, mc_alias),
        opts,
        {:policy_entities_json, paths.policy_name, user_name},
        scenario: "admin_policy_association_lifecycle",
        assertion: "JSON entities output preserves omission, null, and sorting semantics"
      ),
      step(
        "admin_policy_json_detach",
        executable,
        base_args ++
          ["admin", "policy", "detach", mc_alias, paths.policy_name, "--user", user_name],
        opts,
        {:json_exact, association_json_output(:detach, [paths.policy_name], user_name)},
        scenario: "admin_policy_association_lifecycle",
        assertion: "JSON mc detaches the dedicated policy"
      ),
      mc_probe_step(
        "admin_policy_json_mc_ls_detached",
        executable,
        paths,
        opts,
        mc_probe,
        :json,
        :rejected,
        "admin_policy_association_lifecycle",
        "JSON fixture is denied again after detach"
      ),
      step(
        "admin_policy_json_reattach",
        executable,
        base_args ++
          ["admin", "policy", "attach", mc_alias, paths.policy_name, "--user", user_name],
        opts,
        {:json_exact, association_json_output(:attach, [paths.policy_name], user_name)},
        scenario: "admin_policy_association_lifecycle",
        assertion: "JSON policy is reattached before user-status checks"
      ),
      json_user_step(
        "admin_user_json_disable",
        executable,
        base_args,
        opts,
        "disable",
        user_name,
        mc_alias,
        %{"accessKey" => user_name, "status" => "success"}
      ),
      json_user_step(
        "admin_user_json_info_disabled",
        executable,
        base_args,
        opts,
        "info",
        user_name,
        mc_alias,
        %{"accessKey" => user_name, "status" => "success", "userStatus" => "disabled"}
      ),
      mc_probe_step(
        "admin_user_json_mc_ls_disabled",
        executable,
        paths,
        opts,
        mc_probe,
        :json,
        :rejected,
        "admin_user_json_lifecycle",
        "JSON fixture credential is rejected while disabled"
      ),
      json_user_step(
        "admin_user_json_enable",
        executable,
        base_args,
        opts,
        "enable",
        user_name,
        mc_alias,
        %{"accessKey" => user_name, "status" => "success"}
      ),
      json_user_step(
        "admin_user_json_info_reenabled",
        executable,
        base_args,
        opts,
        "info",
        user_name,
        mc_alias,
        %{"accessKey" => user_name, "status" => "success", "userStatus" => "enabled"}
      ),
      mc_probe_step(
        "admin_user_json_mc_ls_reenabled",
        executable,
        paths,
        opts,
        mc_probe,
        :json,
        :success,
        "admin_user_json_lifecycle",
        "JSON fixture credential works after re-enable"
      ),
      step(
        "admin_policy_json_cleanup_detach",
        executable,
        base_args ++
          ["admin", "policy", "detach", mc_alias, paths.policy_name, "--user", user_name],
        opts,
        {:json_exact, association_json_output(:detach, [paths.policy_name], user_name)},
        scenario: "admin_policy_association_lifecycle",
        assertion: "JSON cleanup detaches before deleting user and policy"
      ),
      json_user_step(
        "admin_user_json_remove",
        executable,
        base_args,
        opts,
        "remove",
        user_name,
        mc_alias,
        %{"accessKey" => user_name, "status" => "success"}
      ),
      step(
        "admin_policy_json_remove",
        executable,
        base_args ++ ["admin", "policy", "rm", mc_alias, paths.policy_name],
        opts,
        {:json_exact, policy_json_output(paths.policy_name)},
        scenario: "admin_policy_lifecycle",
        assertion: "JSON mode removes its independent policy after deleting the user"
      )
    ]

    {before_user_remove, user_remove_and_after} =
      Enum.split_while(steps, &(&1.id != "admin_user_json_remove"))

    steps =
      before_user_remove ++
        mc_json_group_steps(executable, paths, opts, user_name, mc_probe) ++
        user_remove_and_after ++
        mc_config_lifecycle_steps(:json, executable, config, paths, opts, metrics_probe)

    cleanup_steps =
      [
        mc_config_cleanup_step(:json, executable, paths, opts)
        | select_cleanup_steps(steps, [
            {"admin_policy_json_cleanup_detach", "admin_policy_json_create"},
            {"admin_group_json_cleanup_detach", "admin_group_json_add"},
            {"admin_group_json_cleanup_remove_member", "admin_group_json_add"},
            {"admin_group_json_remove", "admin_group_json_add"},
            {"admin_user_json_remove", "admin_policy_json_create"},
            {"admin_policy_json_remove", "admin_policy_json_create"}
          ])
      ]

    {steps, cleanup_steps}
  end

  defp mc_human_group_steps(executable, paths, opts, user_name, mc_probe) do
    group_name = smoke_group_name(paths)
    alias_name = paths.mc_alias

    [
      step(
        "admin_group_human_list_baseline_empty",
        executable,
        ["admin", "group", "ls", alias_name],
        opts,
        {:output_exact, "\n"},
        scenario: "admin_group_human_lifecycle",
        assertion: "isolated human group baseline is exactly the one-LF empty list"
      ),
      step(
        "admin_group_human_add",
        executable,
        ["admin", "group", "add", alias_name, group_name, user_name],
        opts,
        {:output_exact, "Added members `#{user_name}` to group `#{group_name}` successfully.\n"},
        scenario: "admin_group_human_lifecycle",
        assertion: "mc creates a temporary group with the unprivileged fixture user"
      ),
      mc_probe_step(
        "admin_group_human_mc_ls_baseline_denied",
        executable,
        paths,
        opts,
        mc_probe,
        :human,
        :rejected,
        "admin_group_human_lifecycle",
        "group membership alone does not grant ListBuckets"
      ),
      step(
        "admin_group_human_attach",
        executable,
        [
          "admin",
          "policy",
          "attach",
          alias_name,
          paths.policy_name,
          "--group",
          group_name
        ],
        opts,
        {:output_exact, association_group_human_output(:attach, [paths.policy_name], group_name)},
        scenario: "admin_group_human_lifecycle",
        assertion: "mc attaches the ListBuckets policy to the temporary group"
      ),
      step(
        "admin_group_human_list",
        executable,
        ["admin", "group", "ls", alias_name],
        opts,
        {:output_exact, "#{group_name}\n"},
        scenario: "admin_group_human_lifecycle",
        assertion: "mc group ls is exactly the sorted temporary group and one trailing LF"
      ),
      step(
        "admin_group_human_info",
        executable,
        ["admin", "group", "info", alias_name, group_name],
        opts,
        {:output_exact, human_group_info(group_name, user_name, paths.policy_name, "enabled")},
        scenario: "admin_group_human_lifecycle",
        assertion: "mc group info returns exact status, policy and member framing"
      ),
      mc_probe_step(
        "admin_group_human_mc_ls_attached",
        executable,
        paths,
        opts,
        mc_probe,
        :human,
        :success,
        "admin_group_human_lifecycle",
        "group managed policy enables real mc ls"
      ),
      group_human_status_step(executable, opts, alias_name, group_name, "disable"),
      mc_probe_step(
        "admin_group_human_mc_ls_disabled",
        executable,
        paths,
        opts,
        mc_probe,
        :human,
        :rejected,
        "admin_group_human_lifecycle",
        "disabled group removes its data-plane grant"
      ),
      group_human_status_step(executable, opts, alias_name, group_name, "enable"),
      mc_probe_step(
        "admin_group_human_mc_ls_reenabled",
        executable,
        paths,
        opts,
        mc_probe,
        :human,
        :success,
        "admin_group_human_lifecycle",
        "re-enabled group restores its data-plane grant"
      ),
      step(
        "admin_group_human_cleanup_remove_member",
        executable,
        ["admin", "group", "remove", alias_name, group_name, user_name],
        opts,
        {:output_exact,
         "Removed members {#{user_name}} from group #{group_name} successfully.\n"},
        scenario: "admin_group_human_lifecycle",
        assertion: "cleanup removes the user from the group before deleting it"
      ),
      mc_probe_step(
        "admin_group_human_mc_ls_removed",
        executable,
        paths,
        opts,
        mc_probe,
        :human,
        :rejected,
        "admin_group_human_lifecycle",
        "removed member immediately loses the group grant"
      ),
      step(
        "admin_group_human_cleanup_detach",
        executable,
        [
          "admin",
          "policy",
          "detach",
          alias_name,
          paths.policy_name,
          "--group",
          group_name
        ],
        opts,
        {:output_exact, association_group_human_output(:detach, [paths.policy_name], group_name)},
        scenario: "admin_group_human_lifecycle",
        assertion: "cleanup detaches the policy mapping before group deletion"
      ),
      step(
        "admin_group_human_remove",
        executable,
        ["admin", "group", "remove", alias_name, group_name],
        opts,
        {:output_exact, "Removed group #{group_name} successfully.\n"},
        scenario: "admin_group_human_lifecycle",
        assertion: "mc removes the now-empty temporary group"
      ),
      step(
        "admin_group_human_list_after_remove",
        executable,
        ["admin", "group", "ls", alias_name],
        opts,
        {:output_exact, "\n"},
        scenario: "admin_group_human_lifecycle",
        assertion: "post-delete human group list is exactly the one-LF empty list"
      )
    ]
  end

  defp mc_json_group_steps(executable, paths, opts, user_name, mc_probe) do
    group_name = smoke_group_name(paths)
    alias_name = paths.mc_alias
    base = ["--json"]

    [
      group_json_step(
        "admin_group_json_add",
        executable,
        base,
        ["add", alias_name, group_name, user_name],
        opts,
        group_json_output(:add, group_name, user_name, nil, nil)
      ),
      mc_probe_step(
        "admin_group_json_mc_ls_baseline_denied",
        executable,
        paths,
        opts,
        mc_probe,
        :json,
        :rejected,
        "admin_group_json_lifecycle",
        "independent JSON group begins without ListBuckets permission"
      ),
      step(
        "admin_group_json_attach",
        executable,
        base ++
          ["admin", "policy", "attach", alias_name, paths.policy_name, "--group", group_name],
        opts,
        {:json_exact, association_group_json_output(:attach, [paths.policy_name], group_name)},
        scenario: "admin_group_json_lifecycle",
        assertion: "JSON mode attaches policy to the group"
      ),
      group_json_step(
        "admin_group_json_list",
        executable,
        base,
        ["ls", alias_name],
        opts,
        group_json_output(:list, group_name, nil, nil, nil)
      ),
      group_json_step(
        "admin_group_json_info",
        executable,
        base,
        ["info", alias_name, group_name],
        opts,
        group_json_output(:info, group_name, user_name, "enabled", paths.policy_name)
      ),
      mc_probe_step(
        "admin_group_json_mc_ls_attached",
        executable,
        paths,
        opts,
        mc_probe,
        :json,
        :success,
        "admin_group_json_lifecycle",
        "JSON group policy enables real mc ls"
      ),
      group_json_step(
        "admin_group_json_disable",
        executable,
        base,
        ["disable", alias_name, group_name],
        opts,
        group_json_output(:status, group_name, nil, "disabled", nil)
      ),
      mc_probe_step(
        "admin_group_json_mc_ls_disabled",
        executable,
        paths,
        opts,
        mc_probe,
        :json,
        :rejected,
        "admin_group_json_lifecycle",
        "disabled JSON group removes the data-plane grant"
      ),
      group_json_step(
        "admin_group_json_enable",
        executable,
        base,
        ["enable", alias_name, group_name],
        opts,
        group_json_output(:status, group_name, nil, "enabled", nil)
      ),
      mc_probe_step(
        "admin_group_json_mc_ls_reenabled",
        executable,
        paths,
        opts,
        mc_probe,
        :json,
        :success,
        "admin_group_json_lifecycle",
        "re-enabled JSON group restores the data-plane grant"
      ),
      group_json_step(
        "admin_group_json_cleanup_remove_member",
        executable,
        base,
        ["remove", alias_name, group_name, user_name],
        opts,
        group_json_output(:remove_members, group_name, user_name, nil, nil)
      ),
      mc_probe_step(
        "admin_group_json_mc_ls_removed",
        executable,
        paths,
        opts,
        mc_probe,
        :json,
        :rejected,
        "admin_group_json_lifecycle",
        "removed JSON member immediately loses the grant"
      ),
      step(
        "admin_group_json_cleanup_detach",
        executable,
        base ++
          ["admin", "policy", "detach", alias_name, paths.policy_name, "--group", group_name],
        opts,
        {:json_exact, association_group_json_output(:detach, [paths.policy_name], group_name)},
        scenario: "admin_group_json_lifecycle",
        assertion: "JSON cleanup detaches policy before group deletion"
      ),
      group_json_step(
        "admin_group_json_remove",
        executable,
        base,
        ["remove", alias_name, group_name],
        opts,
        group_json_output(:remove_group, group_name, nil, nil, nil)
      )
    ]
  end

  defp group_human_status_step(executable, opts, alias_name, group_name, action) do
    past = if action == "disable", do: "Disabled", else: "Enabled"

    step(
      "admin_group_human_#{action}",
      executable,
      ["admin", "group", action, alias_name, group_name],
      opts,
      {:output_exact, "#{past} group `#{group_name}` successfully.\n"},
      scenario: "admin_group_human_lifecycle",
      assertion: "mc #{action}s the group through G4"
    )
  end

  defp group_json_step(id, executable, base, args, opts, expected) do
    step(
      id,
      executable,
      base ++ ["admin", "group" | args],
      opts,
      {:json_exact, expected},
      scenario: "admin_group_json_lifecycle",
      assertion: "mc --json group command returns one compact exact JSON document"
    )
  end

  defp association_human_output(:attach, policies, user_name) do
    "Attached Policies: [#{Enum.join(policies, " ")}]\nTo User: #{user_name}\n"
  end

  defp association_human_output(:detach, policies, user_name) do
    "Detached Policies: [#{Enum.join(policies, " ")}]\nFrom User: #{user_name}\n"
  end

  defp association_group_human_output(:attach, policies, group_name) do
    "Attached Policies: [#{Enum.join(policies, " ")}]\nTo Group: #{group_name}\n"
  end

  defp association_group_human_output(:detach, policies, group_name) do
    "Detached Policies: [#{Enum.join(policies, " ")}]\nFrom Group: #{group_name}\n"
  end

  defp human_group_info(group_name, user_name, policy_name, status) do
    "Group: #{group_name}\nStatus: #{status}\nPolicy: #{policy_name}\nMembers: #{user_name}\n"
  end

  defp smoke_group_name(paths) do
    "maxio-compat-group-#{:erlang.phash2({paths.mc_alias, paths.policy_name})}"
  end

  defp policy_json_output(policy_name) do
    "{\n" <>
      " \"status\": \"success\",\n" <>
      " \"policy\": #{Jason.encode!(policy_name)},\n" <>
      " \"isGroup\": false\n" <>
      "}\n"
  end

  defp association_json_output(operation, policies, user_name) do
    field = if operation == :attach, do: "policiesAttached", else: "policiesDetached"

    policy_lines =
      policies
      |> Enum.map_join(",\n", &("  " <> Jason.encode!(&1)))

    "{\n" <>
      " \"status\": \"success\",\n" <>
      " \"#{field}\": [\n" <>
      policy_lines <>
      "\n ],\n" <>
      " \"user\": #{Jason.encode!(user_name)}\n" <>
      "}\n"
  end

  defp association_group_json_output(operation, policies, group_name) do
    field = if operation == :attach, do: "policiesAttached", else: "policiesDetached"

    ordered_json([{"status", "success"}, {field, policies}, {"group", group_name}])
  end

  defp group_json_output(:add, group_name, member, _status, _policy) do
    ordered_json([
      {"status", "success"},
      {"groupName", group_name},
      {"members", [member]}
    ])
  end

  defp group_json_output(:remove_members, group_name, member, _status, _policy),
    do:
      ordered_json([
        {"status", "success"},
        {"groupName", group_name},
        {"members", [member]}
      ])

  defp group_json_output(:remove_group, group_name, _member, _status, _policy),
    do: ordered_json([{"status", "success"}, {"groupName", group_name}])

  defp group_json_output(:list, group_name, _member, _status, _policy),
    do: ordered_json([{"status", "success"}, {"groups", [group_name]}])

  defp group_json_output(:status, group_name, _member, status, _policy),
    do:
      ordered_json([
        {"status", "success"},
        {"groupName", group_name},
        {"groupStatus", status}
      ])

  defp group_json_output(:info, group_name, member, status, policy) do
    ordered_json([
      {"status", "success"},
      {"groupName", group_name},
      {"members", [member]},
      {"groupStatus", status},
      {"groupPolicy", policy}
    ])
  end

  defp ordered_json(values) do
    %Jason.OrderedObject{values: values}
    |> Jason.encode!()
    |> Kernel.<>("\n")
  end

  defp policy_entities_args(policy_name, user_name, mc_alias \\ "maxiocompat") do
    missing_user = "missing-#{user_name}"

    [
      "admin",
      "policy",
      "entities",
      mc_alias,
      "--user",
      missing_user,
      "--user",
      missing_user,
      "--policy",
      policy_name,
      "--policy",
      policy_name
    ]
  end

  defp json_user_step(id, executable, base_args, opts, action, user_name, mc_alias, expected) do
    step(
      id,
      executable,
      base_args ++ ["admin", "user", action, mc_alias, user_name],
      opts,
      {:json_exact, user_json_output(expected)},
      scenario: "admin_user_json_lifecycle",
      assertion: "mc --json admin user #{action} returns one exact JSON object"
    )
  end

  defp user_json_output(%{
         "accessKey" => user_name,
         "status" => "success",
         "userStatus" => status
       }) do
    "{\n" <>
      " \"status\": \"success\",\n" <>
      " \"accessKey\": #{Jason.encode!(user_name)},\n" <>
      " \"userStatus\": #{Jason.encode!(status)}\n" <>
      "}\n"
  end

  defp user_json_output(%{"accessKey" => user_name, "status" => "success"}) do
    "{\n" <>
      " \"status\": \"success\",\n" <>
      " \"accessKey\": #{Jason.encode!(user_name)}\n" <>
      "}\n"
  end

  defp select_cleanup_steps(steps, cleanup_pairs) do
    steps_by_id = Map.new(steps, &{&1.id, &1})

    Enum.map(cleanup_pairs, fn {cleanup_id, created_by} ->
      steps_by_id
      |> Map.fetch!(cleanup_id)
      |> Map.put(:created_by, created_by)
    end)
  end

  defp step(id, command, args, opts, metadata) when is_list(metadata) do
    step(id, command, args, opts, :none, metadata)
  end

  defp step(id, command, args, opts, verify, metadata) do
    %{
      id: id,
      command: command,
      args: args,
      opts: opts,
      verify: verify,
      scenario: Keyword.get(metadata, :scenario, "unspecified"),
      assertion: Keyword.get(metadata, :assertion)
    }
  end

  defp mc_probe_step(id, executable, paths, opts, mc_probe, mode, expected, scenario, assertion) do
    json? = mode == :json
    args = if json?, do: ["--json", "ls", paths.mc_alias], else: ["ls", paths.mc_alias]

    {:external_command_capability, capability_redactions, capability_fun} =
      mc_probe.(%{
        executable: executable,
        alias: paths.mc_alias,
        config_dir: paths.mc_config_dir,
        json?: json?,
        opts: opts
      })

    %{
      id: id,
      command: executable,
      args: args,
      opts: opts,
      verify: {:mc_ls, expected, mode},
      scenario: scenario,
      assertion: assertion,
      redactions: capability_redactions,
      local_fun: capability_fun
    }
  end

  defp run_steps(steps, command_runner, redactions) do
    Enum.reduce_while(steps, {:ok, []}, fn step, {:ok, step_views} ->
      case run_step(step, command_runner, redactions) do
        {:ok, step_view} ->
          {:cont, {:ok, [step_view | step_views]}}

        {:blocked, step_view, blocker} ->
          {:halt, {:blocked, Enum.reverse([step_view | step_views]), blocker}}

        {:error, step_view, blocker} ->
          {:halt, {:error, Enum.reverse([step_view | step_views]), blocker}}
      end
    end)
    |> case do
      {:ok, step_views} -> {:ok, Enum.reverse(step_views)}
      other -> other
    end
  end

  defp pending_cleanup_steps(cleanup_steps, step_views) do
    successful_ids =
      step_views
      |> Enum.filter(&(&1["status"] == "ok"))
      |> MapSet.new(& &1["id"])

    failed_scenario = step_views |> List.last() |> Map.get("scenario")

    Enum.filter(cleanup_steps, fn step ->
      created? =
        case step.created_by do
          :always -> failed_scenario in List.wrap(Map.get(step, :failure_scenario))
          created_by -> MapSet.member?(successful_ids, created_by)
        end

      completed? = MapSet.member?(successful_ids, step.id)

      created? and not completed?
    end)
  end

  defp run_step(step, command_runner, redactions) do
    started = System.monotonic_time(:millisecond)
    redactions = merge_redactions(redactions, Map.get(step, :redactions, []))

    try do
      {output, stderr, exit_status} = invoke_step(step, command_runner)
      duration_ms = System.monotonic_time(:millisecond) - started
      view = step_view(step, exit_status, output, stderr, duration_ms, redactions)

      expected_exit = expected_exit_status(step.verify)

      cond do
        exit_status != expected_exit ->
          {:blocked, view,
           %{
             "reason" => "external_smoke_step_failed",
             "step" => step.id,
             "exit_status" => exit_status,
             "output_snippet" => view["output_snippet"],
             "stderr_snippet" => view["stderr_snippet"]
           }}

        expected_exit == 0 and stderr != "" ->
          {:blocked, Map.put(view, "status", "blocked"),
           %{
             "reason" => "external_smoke_stderr_not_empty",
             "step" => step.id,
             "stderr_snippet" => view["stderr_snippet"]
           }}

        true ->
          case verify_step(step.verify, output, stderr) do
            :ok ->
              {:ok, Map.put(view, "status", "ok")}

            {:error, reason, detail} ->
              {:blocked, view, %{"reason" => reason, "step" => step.id, "detail" => detail}}
          end
      end
    rescue
      error ->
        duration_ms = System.monotonic_time(:millisecond) - started

        view =
          step_view(step, nil, Exception.message(error), "", duration_ms, redactions)
          |> Map.put("status", "error")

        {:error, view,
         %{
           "reason" => "external_smoke_command_failed",
           "step" => step.id,
           "message" => redact(Exception.message(error), redactions)
         }}
    end
  end

  defp merge_redactions(redactions, additional) do
    (redactions ++ additional)
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
    |> Enum.uniq()
  end

  defp invoke_step(%{local_fun: fun}, _command_runner) when is_function(fun, 0) do
    {Jason.encode!(fun.()), "", 0}
  end

  defp invoke_step(%{local_fun: fun}, command_runner) when is_function(fun, 1) do
    normalize_command_result(fun.(command_runner))
  end

  defp invoke_step(step, command_runner) do
    normalize_command_result(command_runner.(step.command, step.args, step.opts))
  end

  defp normalize_command_result(result) do
    case result do
      {stdout, stderr, exit_status}
      when is_binary(stdout) and is_binary(stderr) and is_integer(exit_status) ->
        {stdout, stderr, exit_status}

      {output, exit_status} when is_binary(output) and is_integer(exit_status) ->
        {output, "", exit_status}

      other ->
        raise "invalid external smoke command result: #{inspect(other)}"
    end
  end

  defp step_view(step, exit_status, output, stderr, duration_ms, redactions) do
    %{
      "id" => step.id,
      "scenario" => step.scenario,
      "command" => command_string([step.command | step.args]) |> redact(redactions),
      "exit_status" => exit_status,
      "duration_ms" => duration_ms,
      "status" => if(exit_status == 0, do: "ok", else: "blocked"),
      "output_snippet" => output_snippet(output, redactions),
      "stderr_snippet" => output_snippet(stderr, redactions)
    }
    |> maybe_put("assertion", step.assertion)
    |> maybe_put("argv", Map.get(step, :argv))
    |> maybe_put("expected_evidence", Map.get(step, :expected_evidence))
    |> maybe_put("observed_evidence", Map.get(step, :observed_evidence))
  end

  defp verify_step(verify, output, stderr) do
    case verify do
      {:expected_failure, _exit_status, expected_stderr_values} ->
        verify_step({:output_contains, expected_stderr_values}, stderr)

      {:expected_streams, _exit_status, expected_stdout, expected_stderr} ->
        if mc_output_exact?(output, expected_stdout) and
             mc_output_exact?(stderr, expected_stderr) do
          :ok
        else
          {:error, "external_smoke_stream_mismatch", "stdout/stderr did not exactly match"}
        end

      {:mc_ls, expected, mode} ->
        verify_mc_ls(expected, mode, output, stderr)

      other ->
        verify_step(other, output)
    end
  end

  defp expected_exit_status({:expected_failure, exit_status, _expected_stderr_values}),
    do: exit_status

  defp expected_exit_status({:expected_streams, exit_status, _stdout, _stderr}), do: exit_status
  defp expected_exit_status({:mc_ls, :rejected, _mode}), do: 1

  defp expected_exit_status(_verify), do: 0

  defp verify_step(:none, _output), do: :ok

  defp verify_step({:json_exact, expected}, output) do
    if mc_output_exact?(output, expected) do
      :ok
    else
      {:error, "external_smoke_json_mismatch", "mc JSON document bytes did not exactly match"}
    end
  end

  defp verify_step({:policy_entities_human, policy_name, user_name}, output) do
    with ["Query time: " <> timestamp, mappings] <- String.split(output, "\n", parts: 2),
         {:ok, _instant, _offset} <- DateTime.from_iso8601(timestamp),
         true <-
           mc_output_exact?(
             mappings,
             "Policy -> Entity Mappings:\n" <>
               "  Policy: #{policy_name}\n" <>
               "    User Mappings:\n" <>
               "      #{user_name}\n"
           ) do
      :ok
    else
      _other ->
        {:error, "external_smoke_output_mismatch", "mc policy entities output did not match"}
    end
  end

  defp verify_step({:policy_entities_json, policy_name, user_name}, output) do
    with {:ok,
          %{
            "status" => "success",
            "result" => %{
              "timestamp" => timestamp,
              "policyMappings" => [
                %{"policy" => ^policy_name, "users" => [^user_name], "groups" => nil}
              ]
            }
          }} <- Jason.decode(output),
         {:ok, _instant, _offset} <- DateTime.from_iso8601(timestamp),
         true <-
           mc_output_exact?(
             output,
             policy_entities_json_output(policy_name, user_name, timestamp)
           ) do
      :ok
    else
      _other ->
        {:error, "external_smoke_json_mismatch", "policy entities JSON did not match"}
    end
  end

  defp verify_step({:file_equals, path, expected}, _output) do
    case File.read(path) do
      {:ok, ^expected} -> :ok
      {:ok, _other} -> {:error, "external_smoke_body_mismatch", "downloaded body mismatch"}
      {:error, reason} -> {:error, "external_smoke_body_missing", inspect(reason)}
    end
  end

  defp verify_step({:output_equals, expected}, output) when is_binary(output) do
    if String.trim_trailing(output) == expected do
      :ok
    else
      {:error, "external_smoke_body_mismatch", "downloaded body mismatch"}
    end
  end

  defp verify_step({:output_exact, expected}, output) when is_binary(output) do
    if mc_output_exact?(output, expected) do
      :ok
    else
      {:error, "external_smoke_output_mismatch", "mc output did not exactly match"}
    end
  end

  defp verify_step({:output_contains, expected_values}, output) when is_binary(output) do
    normalized_output = String.downcase(output)

    missing =
      expected_values
      |> List.wrap()
      |> Enum.map(&String.downcase(to_string(&1)))
      |> Enum.reject(&String.contains?(normalized_output, &1))

    if missing == [] do
      :ok
    else
      {:error, "external_smoke_output_missing",
       "missing output values: #{Enum.join(missing, ", ")}"}
    end
  end

  defp verify_step(_verify, _output), do: :ok

  defp verify_mc_ls(:success, :human, _output, ""), do: :ok

  defp verify_mc_ls(:rejected, :human, "", stderr) do
    if String.contains?(String.downcase(stderr), "access denied") do
      :ok
    else
      {:error, "external_smoke_mc_ls_mismatch", "mc ls denial did not report access denied"}
    end
  end

  defp verify_mc_ls(:success, :json, output, "") do
    if output == "" or json_lines_have_status?(output, "success") do
      :ok
    else
      {:error, "external_smoke_mc_ls_mismatch", "mc --json ls success output was invalid"}
    end
  end

  defp verify_mc_ls(:rejected, :json, output, "") do
    if json_lines_have_status?(output, "error") do
      :ok
    else
      {:error, "external_smoke_mc_ls_mismatch", "mc --json ls denial was not a JSON error"}
    end
  end

  defp verify_mc_ls(_expected, _mode, _output, _stderr) do
    {:error, "external_smoke_mc_ls_mismatch", "mc ls stdout/stderr framing did not match"}
  end

  defp policy_entities_json_output(policy_name, user_name, timestamp) do
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

  defp json_lines_have_status?(output, status) do
    documents = String.split(output, ~r/\r?\n/, trim: true)

    documents != [] and
      Enum.all?(documents, fn document ->
        match?({:ok, %{"status" => ^status}}, Jason.decode(document))
      end)
  end

  defp run_cleanup_steps([], _command_runner, _redactions), do: %{steps: [], blockers: []}

  defp run_cleanup_steps(steps, command_runner, redactions) do
    Enum.reduce(steps, %{steps: [], blockers: []}, fn step, cleanup ->
      case run_step(step, command_runner, redactions) do
        {:ok, view} ->
          %{cleanup | steps: cleanup.steps ++ [view]}

        {:blocked, view, blocker} ->
          cleanup_blocker =
            blocker
            |> Map.put("reason", "external_smoke_cleanup_failed")
            |> Map.put("step", step.id)

          %{
            steps: cleanup.steps ++ [view],
            blockers: cleanup.blockers ++ [cleanup_blocker]
          }

        {:error, view, blocker} ->
          cleanup_blocker =
            blocker
            |> Map.put("reason", "external_smoke_cleanup_failed")
            |> Map.put("step", step.id)

          %{
            steps: cleanup.steps ++ [view],
            blockers: cleanup.blockers ++ [cleanup_blocker]
          }
      end
    end)
  end

  defp merge_cleanup(entry, cleanup, redactions) do
    cleanup = redact_value(cleanup, redactions)
    existing_ids = MapSet.new(entry["steps"], & &1["id"])
    unique_cleanup_steps = Enum.reject(cleanup.steps, &MapSet.member?(existing_ids, &1["id"]))
    steps = entry["steps"] ++ unique_cleanup_steps
    blockers = entry["blockers"] ++ cleanup.blockers

    status =
      if entry["status"] == "ok" and cleanup.blockers != [] do
        "blocked"
      else
        entry["status"]
      end

    entry
    |> Map.put("status", status)
    |> Map.put("steps", steps)
    |> Map.put("blockers", blockers)
    |> Map.put("scenario_counts", scenario_counts(steps))
  end

  defp ok_entry(spec, config, paths, started, steps) do
    entry(spec.id, spec.label, "ok", config, paths, started, steps, [], [])
  end

  defp blocked_entry(spec, config, paths, started, steps, blockers) do
    entry(spec.id, spec.label, "blocked", config, paths, started, steps, blockers, [])
  end

  defp error_entry(id, label, started, steps, blockers) do
    entry(id, label, "error", nil, nil, started, steps, blockers, [])
  end

  defp error_entry(id, label, started, steps, blockers, config, paths) do
    entry(id, label, "error", config, paths, started, steps, blockers, [])
  end

  defp attention_entry(id, label, started, warnings) do
    entry(id, label, "attention", nil, nil, started, [], [], warnings)
  end

  defp entry(id, label, status, config, paths, started, steps, blockers, warnings) do
    base = %{
      "kind" => "external_smoke",
      "id" => id,
      "label" => label,
      "mode" => "external_smoke",
      "status" => status,
      "duration_ms" => System.monotonic_time(:millisecond) - started,
      "steps" => steps,
      "blockers" => blockers,
      "warnings" => warnings
    }

    base
    |> maybe_put("endpoint", config && config.endpoint)
    |> maybe_put("region", config && config.region)
    |> maybe_put("bucket", paths && paths.bucket)
    |> maybe_put("key", paths && paths.key)
    |> maybe_put("scenario_counts", scenario_counts(steps))
  end

  defp with_temp_paths(client_id, tmp_root_fun, fun) do
    tmp_dir =
      tmp_root_fun.()
      |> Path.join("maxio_compat_smoke_#{safe_client_segment(client_id)}_#{unique_id()}")

    File.mkdir_p!(tmp_dir)

    bucket = "maxio-compat-#{safe_client_segment(client_id)}-#{unique_id()}"
    key = "smoke/#{unique_id()}.txt"
    copied_key = "smoke/#{unique_id()}-copy.txt"
    payload = "maxio external smoke #{client_id} #{unique_id()}"
    payload_path = Path.join(tmp_dir, "payload.txt")
    download_path = Path.join(tmp_dir, "download.txt")
    range_download_path = Path.join(tmp_dir, "download-range.txt")
    copy_download_path = Path.join(tmp_dir, "download-copy.txt")
    mc_config_dir = Path.join(tmp_dir, "mc-config")
    policy_name = "maxio-compat-policy-#{unique_id()}"
    policy_path = Path.join(tmp_dir, "policy.json")
    File.write!(payload_path, payload)

    File.write!(
      policy_path,
      Jason.encode!(%{
        "Version" => "2012-10-17",
        "Statement" => %{
          "Effect" => "Allow",
          "Action" => "s3:ListAllMyBuckets",
          "Resource" => "*"
        }
      })
    )

    range_payload = binary_part(payload, 0, min(6, byte_size(payload)))

    paths = %{
      tmp_dir: tmp_dir,
      bucket: bucket,
      key: key,
      copied_key: copied_key,
      payload: payload,
      payload_path: payload_path,
      download_path: download_path,
      range_download_path: range_download_path,
      copy_download_path: copy_download_path,
      mc_config_dir: mc_config_dir,
      mc_alias: "maxiocompat",
      policy_name: policy_name,
      policy_path: policy_path,
      range_header: "bytes=0-#{byte_size(range_payload) - 1}",
      range_payload: range_payload
    }

    try do
      fun.(paths)
    after
      File.rm_rf(tmp_dir)
    end
  end

  defp aws_env(config) do
    [
      {"AWS_ACCESS_KEY_ID", config.access_key},
      {"AWS_SECRET_ACCESS_KEY", config.secret_key},
      {"AWS_DEFAULT_REGION", config.region},
      {"AWS_EC2_METADATA_DISABLED", "true"},
      {"AWS_PAGER", ""}
    ]
  end

  defp mc_env(config) do
    host = endpoint_with_userinfo(config.endpoint, config.access_key, config.secret_key)

    [
      {"MC_HOST_maxiocompat", host},
      {"MC_HOST_maxiocompatjson", host}
    ]
  end

  defp human_user_info(user_name, status) do
    "AccessKey: #{user_name}\nStatus: #{status}\nPolicyName: \nMemberOf: []\n"
  end

  defp no_such_user_stderr(user_name) do
    "mc: <ERROR> Unable to remove #{user_name}. " <>
      "The specified user does not exist. (Specified user does not exist).\n"
  end

  defp boto3_env(config, paths) do
    aws_env(config) ++
      [
        {"MAXIO_COMPAT_ENDPOINT", config.endpoint},
        {"MAXIO_COMPAT_BUCKET", paths.bucket},
        {"MAXIO_COMPAT_KEY", paths.key},
        {"MAXIO_COMPAT_COPY_KEY", paths.copied_key},
        {"MAXIO_COMPAT_BODY", paths.payload}
      ]
  end

  defp command_opts(config, client_env) do
    [env: client_env ++ config.proxy_bypass_env]
  end

  defp run_command(command, args, opts) do
    stderr_path =
      Path.join(
        System.tmp_dir!(),
        "maxio_external_smoke_stderr_#{System.unique_integer([:positive])}.log"
      )

    try do
      {stdout, exit_status} =
        if match?({:win32, _name}, :os.type()) do
          powershell = System.find_executable("pwsh") || System.find_executable("powershell")

          unless powershell do
            raise "PowerShell executable is required to capture external smoke stderr"
          end

          script = """
          $ErrorActionPreference = 'Stop'
          $ProgressPreference = 'SilentlyContinue'
          $stderrPath = $env:MAXIO_EXTERNAL_SMOKE_STDERR_PATH

          function ConvertTo-NativeArgument([string]$value) {
            $builder = New-Object System.Text.StringBuilder
            [void]$builder.Append('"')
            $slashes = 0

            foreach ($character in $value.ToCharArray()) {
              if ($character -eq '\') {
                $slashes++
              } elseif ($character -eq '"') {
                [void]$builder.Append(('\' * (2 * $slashes + 1)))
                [void]$builder.Append('"')
                $slashes = 0
              } else {
                [void]$builder.Append(('\' * $slashes))
                [void]$builder.Append($character)
                $slashes = 0
              }
            }

            [void]$builder.Append(('\' * (2 * $slashes)))
            [void]$builder.Append('"')
            return $builder.ToString()
          }

          try {
            $commandArgs = @(ConvertFrom-Json $env:MAXIO_EXTERNAL_SMOKE_ARGS_JSON)
            $startInfo = New-Object System.Diagnostics.ProcessStartInfo
            $startInfo.FileName = $env:MAXIO_EXTERNAL_SMOKE_EXECUTABLE
            $startInfo.Arguments = (($commandArgs | ForEach-Object {
              ConvertTo-NativeArgument ([string]$_)
            }) -join ' ')
            $startInfo.UseShellExecute = $false
            $startInfo.CreateNoWindow = $true
            $startInfo.RedirectStandardOutput = $true
            $startInfo.RedirectStandardError = $true
            $startInfo.StandardOutputEncoding = New-Object System.Text.UTF8Encoding($false)
            $startInfo.StandardErrorEncoding = New-Object System.Text.UTF8Encoding($false)

            $process = New-Object System.Diagnostics.Process
            $process.StartInfo = $startInfo
            [void]$process.Start()
            $stdoutTask = $process.StandardOutput.ReadToEndAsync()
            $stderrTask = $process.StandardError.ReadToEndAsync()
            $process.WaitForExit()
            $stdout = $stdoutTask.Result
            $stderr = $stderrTask.Result
            [Console]::Out.Write($stdout)
            [IO.File]::WriteAllText(
              $stderrPath,
              $stderr,
              (New-Object System.Text.UTF8Encoding($false))
            )
            exit $process.ExitCode
          } catch {
            [IO.File]::WriteAllText(
              $stderrPath,
              $_.Exception.ToString(),
              (New-Object System.Text.UTF8Encoding($false))
            )
            exit 255
          }
          """

          encoded_script =
            script
            |> :unicode.characters_to_binary(:utf8, {:utf16, :little})
            |> Base.encode64()

          powershell_opts =
            command_env(
              opts,
              [
                {"MAXIO_EXTERNAL_SMOKE_STDERR_PATH", stderr_path},
                {"MAXIO_EXTERNAL_SMOKE_EXECUTABLE", command},
                {"MAXIO_EXTERNAL_SMOKE_ARGS_JSON", Jason.encode!(args)}
              ]
            )

          System.cmd(
            powershell,
            [
              "-NoLogo",
              "-NoProfile",
              "-NonInteractive",
              "-EncodedCommand",
              encoded_script
            ],
            powershell_opts
          )
        else
          System.cmd(
            "sh",
            [
              "-c",
              ~S(stderr_path=$1; shift; "$@" 2>"$stderr_path"),
              "maxio-external-smoke",
              stderr_path,
              command | args
            ],
            opts
          )
        end

      stderr =
        case File.read(stderr_path) do
          {:ok, bytes} -> bytes
          {:error, :enoent} -> ""
          {:error, reason} -> raise "cannot read external smoke stderr: #{inspect(reason)}"
        end

      {stdout, stderr, exit_status}
    after
      File.rm(stderr_path)
    end
  end

  defp command_env(opts, injected) do
    injected_names = MapSet.new(injected, &elem(&1, 0))

    existing =
      opts
      |> Keyword.get(:env, [])
      |> Enum.reject(fn {name, _value} -> MapSet.member?(injected_names, name) end)

    Keyword.put(opts, :env, existing ++ injected)
  end

  defp proxy_bypass_env(endpoint, system_env) do
    case URI.parse(endpoint || "") do
      %URI{host: host} when is_binary(host) ->
        if loopback_host?(host) do
          merged =
            [env_value(system_env, "NO_PROXY"), env_value(system_env, "no_proxy"), host]
            |> Enum.flat_map(&no_proxy_entries/1)
            |> uniq_no_proxy_entries()
            |> Enum.join(",")

          [{"NO_PROXY", merged}, {"no_proxy", merged}]
        else
          []
        end

      _other ->
        []
    end
  end

  defp env_value(system_env, name) when is_map(system_env), do: Map.get(system_env, name)

  defp env_value(system_env, name) when is_list(system_env) do
    case List.keyfind(system_env, name, 0) do
      {^name, value} -> value
      nil -> nil
    end
  end

  defp no_proxy_entries(value) when is_binary(value) do
    value
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp no_proxy_entries(_value), do: []

  defp uniq_no_proxy_entries(entries) do
    {entries, _seen} =
      Enum.reduce(entries, {[], MapSet.new()}, fn entry, {acc, seen} ->
        key = String.downcase(entry)

        if MapSet.member?(seen, key) do
          {acc, seen}
        else
          {[entry | acc], MapSet.put(seen, key)}
        end
      end)

    Enum.reverse(entries)
  end

  defp loopback_host?(host) do
    normalized = host |> String.downcase() |> String.trim_trailing(".")

    normalized == "localhost" or
      case :inet.parse_address(String.to_charlist(normalized)) do
        {:ok, {127, _b, _c, _d}} -> true
        {:ok, {0, 0, 0, 0, 0, 0, 0, 1}} -> true
        _other -> false
      end
  end

  defp endpoint_with_userinfo(endpoint, access_key, secret_key) do
    uri = URI.parse(endpoint)
    userinfo = "#{URI.encode_www_form(access_key)}:#{URI.encode_www_form(secret_key)}"
    URI.to_string(%{uri | userinfo: userinfo})
  end

  defp create_bucket_config_args("us-east-1"), do: []

  defp create_bucket_config_args(region),
    do: ["--create-bucket-configuration", "LocationConstraint=#{region}"]

  defp boto3_script do
    """
    import os, boto3

    endpoint = os.environ["MAXIO_COMPAT_ENDPOINT"]
    bucket = os.environ["MAXIO_COMPAT_BUCKET"]
    key = os.environ["MAXIO_COMPAT_KEY"]
    copy_key = os.environ["MAXIO_COMPAT_COPY_KEY"]
    body = os.environ["MAXIO_COMPAT_BODY"].encode("utf-8")
    region = os.environ.get("AWS_DEFAULT_REGION", "us-east-1")

    s3 = boto3.client(
        "s3",
        endpoint_url=endpoint,
        aws_access_key_id=os.environ["AWS_ACCESS_KEY_ID"],
        aws_secret_access_key=os.environ["AWS_SECRET_ACCESS_KEY"],
        region_name=region,
    )

    created_bucket = False
    created_object = False
    created_copy = False
    try:
        if region == "us-east-1":
            s3.create_bucket(Bucket=bucket)
        else:
            s3.create_bucket(
                Bucket=bucket,
                CreateBucketConfiguration={"LocationConstraint": region},
            )
        created_bucket = True
        s3.put_object(Bucket=bucket, Key=key, Body=body, Metadata={"maxio-smoke": "deep-matrix"})
        created_object = True
        head = s3.head_object(Bucket=bucket, Key=key)
        if head["ContentLength"] != len(body):
            raise RuntimeError("content length mismatch")
        if head.get("Metadata", {}).get("maxio-smoke") != "deep-matrix":
            raise RuntimeError("metadata mismatch")
        ranged_head = s3.head_object(Bucket=bucket, Key=key, Range="bytes=0-5")
        if ranged_head["ContentLength"] != 6:
            raise RuntimeError("head range length mismatch")
        got = s3.get_object(Bucket=bucket, Key=key)["Body"].read()
        if got != body:
            raise RuntimeError("body mismatch")
        got_range = s3.get_object(Bucket=bucket, Key=key, Range="bytes=0-5")["Body"].read()
        if got_range != body[:6]:
            raise RuntimeError("range body mismatch")
        s3.copy_object(Bucket=bucket, Key=copy_key, CopySource={"Bucket": bucket, "Key": key})
        created_copy = True
        copied = s3.get_object(Bucket=bucket, Key=copy_key)["Body"].read()
        if copied != body:
            raise RuntimeError("copied body mismatch")
        print("ok")
    finally:
        if created_copy:
            try:
                s3.delete_object(Bucket=bucket, Key=copy_key)
            except Exception:
                pass
        if created_object:
            try:
                s3.delete_object(Bucket=bucket, Key=key)
            except Exception:
                pass
        if created_bucket:
            try:
                s3.delete_bucket(Bucket=bucket)
            except Exception:
                pass
    """
  end

  defp redactions(config) do
    [config.access_key, config.secret_key]
    |> Enum.flat_map(fn value ->
      case blank_to_nil(value) do
        nil -> []
        value -> [value, URI.encode_www_form(value)]
      end
    end)
    |> Enum.uniq()
  end

  defp redact(value, redactions) do
    Enum.reduce(redactions, to_string(value), fn redaction, acc ->
      String.replace(acc, redaction, "[REDACTED]")
    end)
  end

  defp redact_value(%{} = value, redactions) do
    Map.new(value, fn {key, item} -> {key, redact_value(item, redactions)} end)
  end

  defp redact_value(value, redactions) when is_list(value) do
    Enum.map(value, &redact_value(&1, redactions))
  end

  defp redact_value(value, redactions) when is_binary(value), do: redact(value, redactions)
  defp redact_value(value, _redactions), do: value

  defp output_snippet(output, redactions) when is_binary(output) do
    output
    |> String.trim()
    |> String.slice(0, 1_000)
    |> redact(redactions)
  end

  defp output_snippet(output, redactions) do
    output
    |> inspect()
    |> String.slice(0, 1_000)
    |> redact(redactions)
  end

  defp command_string(parts), do: Enum.map_join(parts, " ", &quote_arg/1)

  defp quote_arg(part) do
    part = to_string(part)

    if String.match?(part, ~r/^[A-Za-z0-9_@.,:\/\\=-]+$/) do
      part
    else
      inspect(part)
    end
  end

  defp get_config(%{} = config, key) do
    Map.get(config, key) || Map.get(config, to_string(key))
  end

  defp get_config(_config, _key), do: nil

  defp client_spec(client_id), do: Enum.find(@clients, &(&1.id == client_id))

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, %{} = value) when map_size(value) == 0, do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp scenario_counts([]), do: nil

  defp scenario_counts(steps) do
    Enum.frequencies_by(steps, &(&1["scenario"] || "unspecified"))
  end

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(_value), do: false

  defp blank_to_nil(value) when is_binary(value) do
    if String.trim(value) == "", do: nil, else: value
  end

  defp blank_to_nil(value), do: value

  defp safe_client_segment(client_id) do
    client_id
    |> to_string()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9-]+/, "-")
    |> String.trim("-")
  end

  defp unique_id, do: System.unique_integer([:positive])
end
