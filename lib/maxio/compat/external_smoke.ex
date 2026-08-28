defmodule Maxio.Compat.ExternalSmoke do
  @moduledoc """
  Opt-in external S3 client smoke checks for the compatibility matrix.

  These checks deliberately do not start Maxio. They use an already-running
  endpoint and configured credentials to exercise bucket lifecycle, object
  write/read, metadata, range reads, server-side copy, MinIO admin policy
  lifecycle, and cleanup through external clients.
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

  def run(config, opts \\ []) do
    config = normalize_config(config)
    system_env = Keyword.get(opts, :system_env, System.get_env())
    config = Map.put(config, :proxy_bypass_env, proxy_bypass_env(config.endpoint, system_env))
    executable_finder = Keyword.get(opts, :executable_finder, &System.find_executable/1)
    command_runner = Keyword.get(opts, :command_runner, &System.cmd/3)
    tmp_root_fun = Keyword.get(opts, :tmp_root_fun, &System.tmp_dir!/0)
    admin_user_fixture_opts = Keyword.get(opts, :admin_user_fixture_opts, [])

    config.clients
    |> Enum.map(
      &run_client(
        &1,
        config,
        executable_finder,
        command_runner,
        tmp_root_fun,
        admin_user_fixture_opts
      )
    )
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
         admin_user_fixture_opts
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
         started
       ) do
    redactions = redactions(config)
    env = mc_env(config)

    case AdminUserFixture.with_user(admin_user_fixture_opts, fn user ->
           {steps, cleanup_steps} = mc_steps(executable, config, paths, env, user.user_name)

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
        merge_cleanup(entry, cleanup, redactions)

      {:error, blocker, cleanup} ->
        spec
        |> blocked_entry(config, paths, started, [], [redact_value(blocker, redactions)])
        |> merge_cleanup(cleanup, redactions)
    end
  end

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

  defp mc_steps(executable, config, paths, env, user_name) do
    opts = command_opts(config, env)
    base_args = ["--config-dir", paths.mc_config_dir]
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
        "admin_policy_create",
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
        "admin_policy_list",
        executable,
        base_args ++ ["admin", "policy", "ls", "maxiocompat"],
        opts,
        {:output_contains, [paths.policy_name]},
        scenario: "admin_policy_lifecycle",
        assertion: "created managed policy is visible through mc admin policy ls"
      ),
      step(
        "admin_policy_info",
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
        {:output_contains, [user_name, "Status", "enabled"]},
        scenario: "admin_user_info",
        assertion: "mc admin user info returns the active temporary IAM user"
      ),
      step(
        "admin_policy_remove",
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

    cleanup_steps =
      select_cleanup_steps(steps, [
        {"admin_policy_remove", "admin_policy_create"},
        {"delete_copied_object", "copy_object"},
        {"delete_object", "put_object"},
        {"delete_bucket", "make_bucket"}
      ])

    {steps, cleanup_steps}
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

    Enum.filter(cleanup_steps, fn step ->
      MapSet.member?(successful_ids, step.created_by) and
        not MapSet.member?(successful_ids, step.id)
    end)
  end

  defp run_step(step, command_runner, redactions) do
    started = System.monotonic_time(:millisecond)

    try do
      {output, exit_status} = command_runner.(step.command, step.args, step.opts)
      duration_ms = System.monotonic_time(:millisecond) - started
      view = step_view(step, exit_status, output, duration_ms, redactions)

      cond do
        exit_status != 0 ->
          {:blocked, view,
           %{
             "reason" => "external_smoke_step_failed",
             "step" => step.id,
             "exit_status" => exit_status,
             "output_snippet" => view["output_snippet"]
           }}

        true ->
          case verify_step(step.verify, output) do
            :ok ->
              {:ok, view}

            {:error, reason, detail} ->
              {:blocked, view, %{"reason" => reason, "step" => step.id, "detail" => detail}}
          end
      end
    rescue
      error ->
        duration_ms = System.monotonic_time(:millisecond) - started

        view =
          step_view(step, nil, Exception.message(error), duration_ms, redactions)
          |> Map.put("status", "error")

        {:error, view,
         %{
           "reason" => "external_smoke_command_failed",
           "step" => step.id,
           "message" => redact(Exception.message(error), redactions)
         }}
    end
  end

  defp step_view(step, exit_status, output, duration_ms, redactions) do
    %{
      "id" => step.id,
      "scenario" => step.scenario,
      "command" => command_string([step.command | step.args]) |> redact(redactions),
      "exit_status" => exit_status,
      "duration_ms" => duration_ms,
      "status" => if(exit_status == 0, do: "ok", else: "blocked"),
      "output_snippet" => output_snippet(output, redactions)
    }
    |> maybe_put("assertion", step.assertion)
  end

  defp verify_step(:none, _output), do: :ok

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
          "Action" => "s3:GetObject",
          "Resource" => "arn:aws:s3:::maxio-compat-*/*"
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
    [
      {"MC_HOST_maxiocompat",
       endpoint_with_userinfo(config.endpoint, config.access_key, config.secret_key)}
    ]
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
    [stderr_to_stdout: true, env: client_env ++ config.proxy_bypass_env]
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
