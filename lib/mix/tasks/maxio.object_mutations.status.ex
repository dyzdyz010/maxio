defmodule Mix.Tasks.Maxio.ObjectMutations.Status do
  @shortdoc "Print ObjectMutation journal / durable epoch reconciliation status"
  @moduledoc """
  只读展示对象变更 journal 与后端 durable epoch 的对账视图（ObjectMutation 协议
  2026-07-10 §7，实现计划 B7）。

      mix maxio.object_mutations.status
      mix maxio.object_mutations.status --bucket B --key K
      mix maxio.object_mutations.status --mutation-id ID
      mix maxio.object_mutations.status --bucket B --key K --json

  每条 mutation 展示：journal phase / generation / attempts / lease / last_error、
  placement snapshot、backend epoch 的逐 endpoint 读数（token generation+mutation_id+
  phase，含 epoch quorum 阈值与 corrupt/unavailable 证据）、durable backup manifest
  存在性与建议动作。

  本任务只读：绝不写库、绝不触碰盘上任何字节（epoch 读数走与 recovery 同一
  per-endpoint 读原语）。恢复动作一律经 `mix maxio.object_mutations.recover --execute`
  （与 recovery worker 同一 `Recovery.recover/2` 入口，禁止旁路）。
  """

  use Mix.Task

  import Ecto.Query

  alias Maxio.Cluster.ShardServer
  alias Maxio.Cluster.Topology
  alias Maxio.Cluster.Transport
  alias Maxio.ObjectMutation
  alias Maxio.ObjectMutation.Journal
  alias Maxio.Repo
  alias Maxio.Storage
  alias Maxio.Storage.Erasure
  alias Maxio.Storage.MutationBackup
  alias Maxio.Storage.MutationContext

  # 无过滤条件时的展示上限（协议 §7 未定义分页；操作员按 --bucket/--key/--mutation-id 收窄）。
  @limit 100

  # attempts 超阈值仍停留在可重试错误（典型：EC 少数盘 claim 残留导致 restore 永久
  # `{:partial, _}`——fail-safe 零破坏但 liveness 不收敛，B6 审查项 2）：建议动作升级为
  # 操作员裁决口径，而非继续机械重试。
  @stuck_attempts_threshold 5

  @impl true
  def run(args) do
    {opts, rest, invalid} =
      OptionParser.parse(args,
        strict: [bucket: :string, key: :string, mutation_id: :string, json: :boolean]
      )

    if rest != [] or invalid != [] do
      unexpected = rest ++ Enum.map(invalid, &elem(&1, 0))

      Mix.raise(
        "usage: mix maxio.object_mutations.status [--bucket B --key K --mutation-id ID] " <>
          "[--json] (unexpected: #{inspect(unexpected)})"
      )
    end

    validate_filters!(opts)

    Mix.Task.run("app.start")

    views =
      opts
      |> load_journals()
      |> Enum.map(&status_view/1)

    print_report(%{"count" => length(views), "mutations" => views}, opts)
  end

  defp validate_filters!(opts) do
    if Keyword.has_key?(opts, :key) and not Keyword.has_key?(opts, :bucket) do
      Mix.raise("--key requires --bucket")
    end

    case Keyword.get(opts, :mutation_id) do
      nil ->
        :ok

      id ->
        case Ecto.UUID.cast(id) do
          {:ok, _uuid} -> :ok
          :error -> Mix.raise("--mutation-id must be a UUID, got #{inspect(id)}")
        end
    end
  end

  # ── journal 选取（--mutation-id 优先；bucket/key 过滤；缺省最近 @limit 条）──

  defp load_journals(opts) do
    case Keyword.get(opts, :mutation_id) do
      nil ->
        Journal
        |> maybe_filter(:bucket_name, Keyword.get(opts, :bucket))
        |> maybe_filter(:object_key, Keyword.get(opts, :key))
        |> order_by([j], desc: j.updated_at, desc: j.inserted_at, desc: j.id)
        |> limit(@limit)
        |> Repo.all()

      id ->
        case ObjectMutation.get(id) do
          %Journal{} = journal -> [journal]
          nil -> Mix.raise("object mutation not found: #{id}")
        end
    end
  end

  defp maybe_filter(query, _field, nil), do: query
  defp maybe_filter(query, field, value), do: where(query, [j], field(j, ^field) == ^value)

  # ── 单条视图：journal + epoch 逐 endpoint 读数 + backup manifest + 建议动作 ──

  defp status_view(%Journal{} = journal) do
    plan = endpoint_plan(journal)
    target = journal_target(journal)
    epoch = epoch_view(plan, target)
    backup = backup_view(plan, journal)

    %{
      "mutation_id" => journal.id,
      "target_kind" => journal.target_kind,
      "bucket" => journal.bucket_name,
      "key" => journal.object_key,
      "version_id" => journal.version_id,
      "generation" => journal.generation,
      "operation" => journal.operation,
      "authority_mode" => journal.authority_mode,
      "backend" => journal.backend,
      "phase" => journal.phase,
      "attempts" => journal.attempts,
      "next_attempt_at" => format_dt(journal.next_attempt_at),
      "lease_owner" => journal.lease_owner,
      "lease_expires_at" => format_dt(journal.lease_expires_at),
      "last_error" => journal.last_error,
      "placement_snapshot" => journal.placement_snapshot,
      "epoch" => epoch,
      "backup" => backup,
      "suggested_action" => suggested_action(journal)
    }
  end

  # target/context 从 journal 确定性重建（与 recovery 的 MutationContext.from_journal 同源）。
  defp journal_target(journal) do
    case MutationContext.from_journal(journal) do
      {:ok, ctx} -> {:ok, ctx.target}
      {:error, reason} -> {:error, reason}
    end
  end

  # ── endpoint 解析（与各后端 epoch 编排同源）：FS 单端点 / EC 本机多盘 /
  # Distributed 按 journal placement snapshot（绝不按当前 router 猜测）──

  defp endpoint_plan(journal) do
    backend = Storage.backend()

    cond do
      backend == Maxio.Storage.FS ->
        %{sets: %{0 => %{endpoints: endpoints}}} = Maxio.Storage.FS.local_topology([])
        {:ok, %{quorum: 1, endpoints: endpoints, transport: :local}}

      backend == Maxio.Storage.ErasureCoded ->
        cfg = Erasure.Config.load!([])

        {:ok,
         %{
           quorum: cfg.epoch_quorum,
           endpoints: Enum.map(cfg.drives, &{Node.self(), &1}),
           transport: :local
         }}

      backend == Maxio.Storage.Distributed ->
        distributed_endpoint_plan(journal)

      true ->
        {:error, {:unsupported_backend, backend}}
    end
  rescue
    error -> {:error, {:endpoint_resolution_failed, Exception.message(error)}}
  end

  defp distributed_endpoint_plan(%Journal{placement_snapshot: %{"set_id" => set_id}})
       when is_integer(set_id) do
    endpoints = Topology.endpoints(set_id)
    ec = Topology.ec_params()

    # epoch_quorum 复用 Erasure.Config 的 D4 钳制公式单一来源；drives 仅满足
    # length == K+M 校验（endpoint 集即 N 个 drive），绝不用于 IO。
    cfg =
      Erasure.Config.load!(
        Keyword.put(ec, :drives, Enum.map(endpoints, fn {node, drive} -> "#{node}:#{drive}" end))
      )

    {:ok, %{quorum: cfg.epoch_quorum, endpoints: endpoints, transport: Transport.impl([])}}
  end

  defp distributed_endpoint_plan(%Journal{placement_snapshot: snapshot}),
    do: {:error, {:invalid_placement_snapshot, snapshot}}

  # ── epoch 逐 endpoint 只读读数 ──

  defp epoch_view({:error, reason}, _target),
    do: %{"status" => "unavailable", "reason" => error_text(reason)}

  defp epoch_view({:ok, _plan}, {:error, reason}),
    do: %{"status" => "unavailable", "reason" => error_text(reason)}

  defp epoch_view({:ok, plan}, {:ok, target}) do
    readings =
      Enum.map(plan.endpoints, fn {node, drive} = endpoint ->
        result =
          case plan.transport do
            :local -> ShardServer.read_epoch(drive, target)
            transport -> transport.read_epoch(node, drive, target)
          end

        Map.merge(%{"endpoint" => endpoint_text(endpoint)}, reading_view(result))
      end)

    %{"epoch_quorum" => plan.quorum, "endpoints" => readings}
  end

  defp reading_view({:ok, :absent}), do: %{"status" => "absent"}

  defp reading_view({:ok, %{"token" => token, "phase" => phase}}) do
    %{
      "status" => "ok",
      "generation" => token["generation"],
      "mutation_id" => token["mutation_id"],
      "phase" => phase
    }
  end

  defp reading_view({:error, reason}), do: %{"status" => "error", "reason" => error_text(reason)}
  defp reading_view(other), do: %{"status" => "error", "reason" => error_text(other)}

  # ── durable backup manifest 存在性（本机盘直接取证；远端 endpoint 无只读 manifest
  # 原语，诚实标 unknown 而非猜测——Transport 暴露面归 Phase 2C 取证收口）──

  defp backup_view({:error, reason}, _journal),
    do: %{"status" => "unavailable", "reason" => error_text(reason)}

  defp backup_view({:ok, plan}, journal) do
    relative_dir = MutationBackup.relative_dir(journal.id)

    endpoints =
      Enum.map(plan.endpoints, fn {node, drive} = endpoint ->
        manifest =
          if node == Node.self() or plan.transport == :local do
            File.regular?(Path.join([drive, relative_dir, MutationBackup.manifest_name()]))
          else
            "unknown (remote endpoint)"
          end

        %{"endpoint" => endpoint_text(endpoint), "manifest" => manifest}
      end)

    %{"relative_dir" => relative_dir, "endpoints" => endpoints}
  end

  # ── 建议动作（recovery 决策表的操作员口径镜像；执行一律走 recover --execute）──

  defp suggested_action(%Journal{phase: phase}) when phase in ~w(finalized rolled_back),
    do: "none (terminal: #{phase})"

  defp suggested_action(%Journal{phase: "quarantined"}) do
    "operator adjudication required: inspect recovery_evidence / per-endpoint epoch readings / " <>
      "retained backup; do not delete backup before resolving"
  end

  defp suggested_action(%Journal{attempts: attempts} = journal)
       when attempts >= @stuck_attempts_threshold do
    "stuck retryable error after #{attempts} attempts (#{summary(journal.last_error)}): " <>
      "operator adjudication — persistent {:partial,_} usually means minority-endpoint " <>
      "claim/backup residue (fail-safe, zero destruction); repair endpoints or defer to " <>
      "Phase 2C heal, then " <> recover_hint(journal)
  end

  defp suggested_action(%Journal{phase: phase} = journal)
       when phase in ~w(metadata_committed finalize_pending),
       do: "finalize: " <> recover_hint(journal)

  defp suggested_action(%Journal{phase: "published", authority_mode: "sidecar"} = journal),
    do:
      "finalize (sidecar authority, journal-level rollback forbidden): " <> recover_hint(journal)

  defp suggested_action(%Journal{phase: "published"} = journal),
    do: "restore (rollback orphan published mutation): " <> recover_hint(journal)

  defp suggested_action(%Journal{} = journal),
    do: "rollback: " <> recover_hint(journal)

  defp recover_hint(journal),
    do: "mix maxio.object_mutations.recover --execute --mutation-id #{journal.id}"

  defp summary(nil), do: "no last_error"
  defp summary(text), do: String.slice(text, 0, 120)

  # ── 输出 ──

  defp print_report(report, opts) do
    if Keyword.get(opts, :json, false) do
      IO.puts(Jason.encode!(report))
    else
      print_text(report)
    end
  end

  defp print_text(%{"count" => 0}) do
    IO.puts("[maxio object_mutations.status] mutations=0")
  end

  defp print_text(%{"count" => count, "mutations" => mutations}) do
    IO.puts("[maxio object_mutations.status] mutations=#{count}")
    Enum.each(mutations, &print_mutation/1)
  end

  defp print_mutation(view) do
    IO.puts(
      "mutation_id=#{view["mutation_id"]} phase=#{view["phase"]} " <>
        "generation=#{view["generation"]} operation=#{safe_text(view["operation"])} " <>
        "authority_mode=#{view["authority_mode"]} backend=#{safe_text(view["backend"])} " <>
        "bucket=#{safe_text(view["bucket"])} key=#{safe_text(view["key"])} " <>
        "version_id=#{safe_text(view["version_id"])} attempts=#{view["attempts"]} " <>
        "next_attempt_at=#{view["next_attempt_at"]} lease_owner=#{safe_text(view["lease_owner"])} " <>
        "placement_snapshot=#{inspect(view["placement_snapshot"])}"
    )

    print_epoch(view["epoch"])
    print_backup(view["backup"])

    if view["last_error"], do: IO.puts("  last_error=#{safe_text(view["last_error"])}")
    IO.puts("  suggested_action=#{view["suggested_action"]}")
  end

  defp print_epoch(%{"status" => "unavailable", "reason" => reason}) do
    IO.puts("  epoch=unavailable reason=#{safe_text(reason)}")
  end

  defp print_epoch(%{"epoch_quorum" => quorum, "endpoints" => endpoints}) do
    IO.puts("  epoch_quorum=#{quorum}")

    Enum.each(endpoints, fn reading ->
      IO.puts(
        "  epoch endpoint=#{safe_text(reading["endpoint"])} status=#{reading["status"]}" <>
          reading_suffix(reading)
      )
    end)
  end

  defp reading_suffix(%{"status" => "ok"} = reading) do
    " generation=#{reading["generation"]} mutation_id=#{reading["mutation_id"]} " <>
      "phase=#{reading["phase"]}"
  end

  defp reading_suffix(%{"status" => "error"} = reading),
    do: " reason=#{safe_text(reading["reason"])}"

  defp reading_suffix(_reading), do: ""

  defp print_backup(%{"status" => "unavailable", "reason" => reason}) do
    IO.puts("  backup=unavailable reason=#{safe_text(reason)}")
  end

  defp print_backup(%{"relative_dir" => dir, "endpoints" => endpoints}) do
    IO.puts("  backup_dir=#{safe_text(dir)}")

    Enum.each(endpoints, fn entry ->
      IO.puts(
        "  backup endpoint=#{safe_text(entry["endpoint"])} manifest=#{inspect(entry["manifest"])}"
      )
    end)
  end

  defp endpoint_text({node, drive}), do: "#{node}:#{drive}"

  defp error_text(reason), do: inspect(reason, limit: 20, printable_limit: 500)

  # 键名/路径/错误可能含恶意控制字符——inspect 转义后输出（与 notification.outbox 同源防线）。
  defp safe_text(nil), do: inspect("")
  defp safe_text(value), do: inspect(to_string(value), printable_limit: 500)

  defp format_dt(nil), do: ""
  defp format_dt(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
end
