defmodule Maxio.Cluster.SchedulerEnabledRehearsal do
  @moduledoc """
  Bounded scheduler-enabled rehearsal harness.

  Unlike `Maxio.Cluster.SchedulerLiveRehearsal`, this harness starts real local
  scheduler GenServers and forces one scheduled tick through the same singleton
  lock and ledger path used by background automation. The default runner is a
  controlled no-op fixture, so the rehearsal proves scheduler/lock/ledger
  behavior without running destructive heal, rebalance, or topology mutation.
  """

  alias Maxio.Cluster.FreshDriveHeal.Scheduler, as: FreshScheduler
  alias Maxio.Cluster.Lock
  alias Maxio.Cluster.Rebalance.Job
  alias Maxio.Cluster.Rebalance.Scheduler, as: RebalanceScheduler
  alias Maxio.Cluster.SchedulerRuns

  @usage """
  Usage:
    mix run --no-start scripts/m8_scheduler_enabled_rehearsal.exs -- \\
      --scheduler fresh_drive_heal|rebalance|all \\
      [--nodes node_a,node_b] [--window-minutes N] \\
      [--expected-interval-ms N] [--stale-after-ms N] \\
      [--min-effective-nodes N] [--require-lock-loser] [--require-rollups] \\
      [--artifact artifacts/m8_scheduler_enabled_rehearsal.json] [--json]

  Default mode is bounded and local-safe. It starts two local scheduler
  instances per selected scheduler, lets the first enter the real singleton
  lock, forces the second to record lock-loser evidence, then releases the
  first and builds a read-only scheduler evidence report over the scheduled
  ledger rows.
  """

  @default_scheduler "all"
  @default_nodes ["node_a", "node_b"]
  @default_window_minutes 1
  @default_expected_interval_ms 60_000
  @default_stale_after_ms 120_000
  @default_min_effective_nodes 1

  def usage, do: @usage

  def run(argv, opts \\ []) do
    case normalize(argv, opts) do
      {:ok, config} -> run_rehearsal(config, opts)
      {:help, usage} -> {:ok, %{exit_code: 0, stdout: usage}}
      {:error, message} -> {:error, usage_result(message)}
    end
  end

  def print_result(result) do
    if Map.get(result, :stdout), do: IO.write(result.stdout)
    if Map.get(result, :stderr), do: IO.write(:stderr, result.stderr)
  end

  defp normalize(argv, opts) do
    {parsed, rest, invalid} =
      OptionParser.parse(argv,
        strict: [
          scheduler: :string,
          nodes: :string,
          window_minutes: :integer,
          expected_interval_ms: :integer,
          stale_after_ms: :integer,
          min_effective_nodes: :integer,
          require_lock_loser: :boolean,
          require_rollups: :boolean,
          artifact: :string,
          json: :boolean,
          help: :boolean
        ]
      )

    cond do
      Keyword.get(parsed, :help, false) ->
        {:help, @usage}

      rest != [] or invalid != [] ->
        {:error, "unexpected arguments: #{inspect(rest ++ Enum.map(invalid, &elem(&1, 0)))}"}

      true ->
        normalize_opts(argv, parsed, opts)
    end
  end

  defp normalize_opts(argv, parsed, opts) do
    now = Keyword.get(opts, :now_fun, &DateTime.utc_now/0).()

    with {:ok, scheduler} <- scheduler(Keyword.get(parsed, :scheduler, @default_scheduler)),
         :ok <- validate_positive(parsed, :window_minutes, "--window-minutes"),
         :ok <- validate_positive(parsed, :expected_interval_ms, "--expected-interval-ms"),
         :ok <- validate_positive(parsed, :stale_after_ms, "--stale-after-ms"),
         :ok <- validate_positive(parsed, :min_effective_nodes, "--min-effective-nodes"),
         {:ok, nodes} <- nodes(Keyword.get(parsed, :nodes)),
         :ok <- validate_nodes(nodes),
         {:ok, window_minutes} <-
           positive_or_default(parsed, :window_minutes, @default_window_minutes),
         {:ok, expected_interval_ms} <-
           positive_or_default(parsed, :expected_interval_ms, @default_expected_interval_ms),
         {:ok, stale_after_ms} <-
           positive_or_default(parsed, :stale_after_ms, @default_stale_after_ms),
         {:ok, min_effective_nodes} <-
           positive_or_default(parsed, :min_effective_nodes, @default_min_effective_nodes) do
      require_rollups? = Keyword.get(parsed, :require_rollups, false)
      window_ms = window_minutes * 60 * 1_000
      from = rehearsal_window_start(now, window_ms, require_rollups?)
      until = DateTime.add(from, window_ms, :millisecond)

      {:ok,
       %{
         argv: argv,
         scheduler: scheduler,
         schedulers: schedulers(scheduler),
         nodes: nodes,
         from: from,
         until: until,
         window_minutes: window_minutes,
         window_ms: window_ms,
         expected_interval_ms: expected_interval_ms,
         stale_after_ms: stale_after_ms,
         min_effective_nodes: min_effective_nodes,
         require_lock_loser?: Keyword.get(parsed, :require_lock_loser, false),
         require_rollups?: require_rollups?,
         artifact_path: Keyword.get_lazy(parsed, :artifact, fn -> default_artifact_path(now) end),
         json?: Keyword.get(parsed, :json, false)
       }}
    end
  end

  defp run_rehearsal(config, opts) do
    ensure_runtime_started!(opts)

    writer = Keyword.get(opts, :artifact_writer, &write_artifact!/2)
    git_sha_fun = Keyword.get(opts, :git_sha_fun, &git_sha/0)
    run_scheduler_fun = Keyword.get(opts, :run_scheduler_fun, &run_scheduler/5)

    scheduler_results =
      Enum.map(config.schedulers, fn scheduler ->
        run_scheduler_fun.(scheduler, config.nodes, config.from, config.window_ms, opts)
      end)

    rollup_results = maybe_rollup(config, opts)
    evidence = scheduler_evidence(config, opts)
    evidence_view = evidence |> SchedulerRuns.evidence_to_view() |> stringify_keys()

    artifact = %{
      "version" => 1,
      "evidence_kind" => "scheduler_live_rehearsal",
      "scenario" => "scheduler_enabled_multinode_rehearsal",
      "generated_at" => DateTime.to_iso8601(config.until),
      "git_sha" => git_sha_fun.(),
      "scheduler" => config.scheduler,
      "schedulers" => config.schedulers,
      "nodes" => config.nodes,
      "from" => DateTime.to_iso8601(config.from),
      "until" => DateTime.to_iso8601(config.until),
      "window_minutes" => config.window_minutes,
      "artifact_path" => config.artifact_path,
      "expected_interval_ms" => config.expected_interval_ms,
      "stale_after_ms" => config.stale_after_ms,
      "min_effective_nodes" => config.min_effective_nodes,
      "require_lock_loser?" => config.require_lock_loser?,
      "require_rollups?" => config.require_rollups?,
      "scheduler_runs" => scheduler_results,
      "rollups" => rollup_results,
      "evidence_exit_status" => if(evidence_view["status"] == "ok", do: 0, else: 1),
      "scheduler_evidence" => evidence_view
    }

    writer.(config.artifact_path, artifact)

    status = evidence_view["status"]
    warnings = Map.get(evidence_view, "warnings", [])
    exit_code = if(status == "ok" and warnings == [], do: 0, else: 1)

    result = %{
      exit_code: exit_code,
      artifact_path: config.artifact_path,
      artifact: artifact,
      stdout: stdout(artifact, config),
      stderr: stderr(exit_code, status)
    }

    if exit_code == 0, do: {:ok, result}, else: {:error, result}
  rescue
    error ->
      {:error,
       %{
         exit_code: 1,
         artifact_path: Map.get(config, :artifact_path),
         stdout: nil,
         stderr: "[maxio scheduler.enabled_rehearsal] #{Exception.message(error)}\n"
       }}
  end

  defp run_scheduler(scheduler, nodes, started_at, _window_ms, opts) do
    [winner_node, loser_node | _rest] = nodes
    lock_nodes = [Node.self()]

    runner = fn result -> result end

    first = start_scheduler!(scheduler, winner_node, lock_nodes, started_at, runner, opts)
    second = start_scheduler!(scheduler, loser_node, lock_nodes, started_at, runner, opts)

    try do
      winner_result = run_scheduled_now(scheduler, first)

      {:ok, lease} =
        scheduler
        |> scheduler_lock_resource()
        |> Lock.acquire(nodes: lock_nodes, refresh: false, timeout: 25)

      loser_result =
        try do
          run_scheduled_now(scheduler, second)
        after
          Lock.release(lease)
        end

      %{
        "scheduler" => Atom.to_string(scheduler),
        "winner_node" => winner_node,
        "lock_loser_node" => loser_node,
        "winner_result" => inspect(winner_result),
        "lock_loser_result" => inspect(loser_result),
        "status" => "ok"
      }
    after
      stop_scheduler(first)
      stop_scheduler(second)
    end
  end

  defp start_scheduler!(:fresh_drive_heal, node, lock_nodes, started_at, runner, _opts) do
    {:ok, pid} =
      FreshScheduler.start_link(
        name: nil,
        enabled: true,
        initial_delay_ms: 60_000,
        interval_ms: 60_000,
        probe_drive_health: false,
        lock_nodes: lock_nodes,
        lock_timeout_ms: 25,
        scheduler_ledger: [node: node, now_fun: fn -> started_at end],
        runner: fn _run_opts -> {:ok, runner.(%{status: :ok, scanned: 0, rehearsal: true})} end
      )

    pid
  end

  defp start_scheduler!(:rebalance, node, lock_nodes, started_at, runner, _opts) do
    job = %Job{
      id: "rehearsal-#{System.unique_integer([:positive])}",
      kind: "rebalance",
      status: "planned",
      data_movement_status: "not_started",
      source_cleanup_status: "not_started"
    }

    {:ok, pid} =
      RebalanceScheduler.start_link(
        name: nil,
        enabled: true,
        initial_delay_ms: 60_000,
        interval_ms: 60_000,
        lock_nodes: lock_nodes,
        lock_timeout_ms: 25,
        scheduler_ledger: [node: node, now_fun: fn -> started_at end],
        job_selector: fn _run_opts -> {:ok, job} end,
        copy_runner: fn job_id, _run_opts ->
          {:ok, runner.(%{status: :ok, phase: :copy, job_id: job_id, scheduler: true})}
        end
      )

    pid
  end

  defp run_scheduled_now(:fresh_drive_heal, pid), do: FreshScheduler.run_scheduled_now(pid, [])
  defp run_scheduled_now(:rebalance, pid), do: RebalanceScheduler.run_scheduled_now(pid, [])

  defp scheduler_lock_resource(:fresh_drive_heal), do: {:fresh_drive_heal_scheduler, :run}
  defp scheduler_lock_resource(:rebalance), do: {:rebalance_scheduler, :run}

  defp stop_scheduler(pid) when is_pid(pid) do
    if Process.alive?(pid), do: GenServer.stop(pid, :normal, 1_000)
  catch
    :exit, _reason -> :ok
  end

  defp scheduler_evidence(config, opts) do
    evidence_opts = [
      from: config.from,
      until: config.until,
      window_ms: config.window_ms,
      expected_interval_ms: config.expected_interval_ms,
      stale_after_ms: config.stale_after_ms,
      expected_nodes: config.nodes,
      min_effective_nodes: config.min_effective_nodes,
      require_lock_loser?: config.require_lock_loser?,
      require_rollups?: config.require_rollups?
    ]

    evidence_opts =
      if config.scheduler == "all" do
        evidence_opts
      else
        Keyword.put(evidence_opts, :scheduler, config.scheduler)
      end

    case SchedulerRuns.evidence_report(
           Keyword.merge(evidence_opts, Keyword.get(opts, :evidence_opts, []))
         ) do
      {:ok, report} -> report
      {:error, reason} -> raise "scheduler evidence failed: #{inspect(reason)}"
    end
  end

  defp maybe_rollup(%{require_rollups?: false}, _opts), do: []

  defp maybe_rollup(%{require_rollups?: true} = config, opts) do
    rollup_opts = Keyword.get(opts, :rollup_opts, [])

    Enum.map(config.schedulers, fn scheduler ->
      case SchedulerRuns.rollup_window(
             scheduler,
             :scheduled,
             config.from,
             config.window_ms,
             rollup_opts
           ) do
        {:ok, result} ->
          result
          |> SchedulerRuns.rollup_to_view()
          |> Map.put(:status, :ok)
          |> SchedulerRuns.evidence_to_view()
          |> stringify_keys()

        {:error, reason} ->
          %{
            "status" => "error",
            "scheduler" => Atom.to_string(scheduler),
            "reason" => inspect(reason)
          }
      end
    end)
  end

  defp ensure_runtime_started!(opts) do
    ensure_app!(:ecto_sql)
    ensure_app!(:postgrex)
    ensure_repo_started!()

    if Keyword.get(opts, :ensure_lock_server?, true) do
      ensure_named_started!(Maxio.Cluster.LockServer)
    end

    :ok
  end

  defp ensure_app!(app) do
    case Application.ensure_all_started(app) do
      {:ok, _apps} -> :ok
      {:error, {failed, reason}} -> raise "failed to start #{inspect(failed)}: #{inspect(reason)}"
    end
  end

  defp ensure_repo_started! do
    case Process.whereis(Maxio.Repo) do
      nil ->
        case Maxio.Repo.start_link() do
          {:ok, _pid} -> :ok
          {:error, {:already_started, _pid}} -> :ok
          {:error, reason} -> raise "failed to start Maxio.Repo: #{inspect(reason)}"
        end

      _pid ->
        :ok
    end
  end

  defp ensure_named_started!(module) do
    case Process.whereis(module) do
      nil ->
        case module.start_link([]) do
          {:ok, _pid} -> :ok
          {:error, {:already_started, _pid}} -> :ok
          {:error, reason} -> raise "failed to start #{inspect(module)}: #{inspect(reason)}"
        end

      _pid ->
        :ok
    end
  end

  defp stdout(artifact, %{json?: true}), do: Jason.encode!(artifact) <> "\n"

  defp stdout(artifact, _config) do
    "[maxio scheduler.enabled_rehearsal] scheduler=#{artifact["scheduler"]} " <>
      "status=#{artifact["scheduler_evidence"]["status"]} " <>
      "artifact=#{artifact["artifact_path"] || ""}\n"
  end

  defp stderr(0, _status), do: nil

  defp stderr(_exit_code, status) do
    "[maxio scheduler.enabled_rehearsal] evidence gate failed: #{status}\n"
  end

  defp write_artifact!(path, artifact) do
    path
    |> Path.dirname()
    |> File.mkdir_p!()

    File.write!(path, Jason.encode!(artifact) <> "\n")
  end

  defp default_artifact_path(now) do
    stamp =
      now
      |> DateTime.to_iso8601()
      |> String.replace(~r/[^0-9A-Za-z_.-]/, "_")

    Path.join("artifacts", "m8_scheduler_enabled_rehearsal_#{stamp}.json")
  end

  defp scheduler("fresh_drive_heal"), do: {:ok, "fresh_drive_heal"}
  defp scheduler("rebalance"), do: {:ok, "rebalance"}
  defp scheduler("all"), do: {:ok, "all"}

  defp scheduler(value),
    do: {:error, "--scheduler must be fresh_drive_heal, rebalance, or all; got #{inspect(value)}"}

  defp schedulers("all"), do: [:fresh_drive_heal, :rebalance]
  defp schedulers("fresh_drive_heal"), do: [:fresh_drive_heal]
  defp schedulers("rebalance"), do: [:rebalance]

  defp nodes(nil), do: {:ok, @default_nodes}

  defp nodes(value) when is_binary(value) do
    nodes =
      value
      |> String.split(",", trim: true)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    {:ok, nodes}
  end

  defp validate_nodes(nodes) when length(nodes) >= 2, do: :ok
  defp validate_nodes(_nodes), do: {:error, "--nodes must contain at least two node names"}

  defp positive_or_default(parsed, key, default) do
    case Keyword.get(parsed, key, default) do
      value when is_integer(value) and value > 0 ->
        {:ok, value}

      value ->
        {:error,
         "--#{String.replace(to_string(key), "_", "-")} must be positive, got #{inspect(value)}"}
    end
  end

  defp validate_positive(parsed, key, flag) do
    case Keyword.get(parsed, key) do
      nil -> :ok
      value when is_integer(value) and value > 0 -> :ok
      value -> {:error, "#{flag} must be a positive integer, got #{inspect(value)}"}
    end
  end

  defp floor_window(%DateTime{} = now, window_ms) do
    unix_ms = DateTime.to_unix(now, :millisecond)
    window_started_ms = div(unix_ms, window_ms) * window_ms
    DateTime.from_unix!(window_started_ms, :millisecond)
  end

  defp rehearsal_window_start(%DateTime{} = now, window_ms, true) do
    now
    |> DateTime.add(-window_ms, :millisecond)
    |> floor_window(window_ms)
  end

  defp rehearsal_window_start(%DateTime{} = now, window_ms, false),
    do: floor_window(now, window_ms)

  defp stringify_keys(values) when is_list(values), do: Enum.map(values, &stringify_keys/1)

  defp stringify_keys(%{} = map) do
    Map.new(map, fn {key, value} -> {string_key(key), stringify_keys(value)} end)
  end

  defp stringify_keys(value), do: value

  defp string_key(key) when is_binary(key), do: key
  defp string_key(key) when is_atom(key), do: Atom.to_string(key)
  defp string_key(key), do: to_string(key)

  defp usage_result(message),
    do: %{exit_code: 64, stderr: "[maxio scheduler.enabled_rehearsal] #{message}\n\n" <> @usage}

  defp git_sha do
    case System.cmd("git", ["rev-parse", "HEAD"], stderr_to_stdout: true) do
      {sha, 0} -> String.trim(sha)
      _other -> "unknown"
    end
  rescue
    _error -> "unknown"
  end
end
