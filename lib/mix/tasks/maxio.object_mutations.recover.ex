defmodule Mix.Tasks.Maxio.ObjectMutations.Recover do
  @shortdoc "Recover due ObjectMutation journals (dry-run by default)"
  @moduledoc """
  收敛到期的对象变更 journal（ObjectMutation 协议 2026-07-10 §7，实现计划 B7）。

      mix maxio.object_mutations.recover --dry-run [--limit N --older-than SECONDS]
      mix maxio.object_mutations.recover --execute [--mutation-id ID]
      mix maxio.object_mutations.recover --execute [--limit N --older-than SECONDS]

  默认（含 `--dry-run`）只读：列出将被 recovery 处理的到期 journal 与对应决策方向，
  不领取租约、不推进任何 phase、不触碰任何存储 endpoint。

  `--execute` 才执行恢复，且**与 recovery worker 走同一入口**（`Recovery.recover/2` /
  `Recovery.drain/1`，禁止旁路）：带 `--mutation-id` 收敛单条；不带则 drain 一轮到期
  journal。`--older-than SECONDS` 只处理创建超过给定年龄的记录（避免与刚进入 60s 宽限
  窗口的 in-flight 请求擦肩）。未到期 / 被他人持租的记录结构化拒绝而非强行接管。
  """

  use Mix.Task

  alias Maxio.ObjectMutation
  alias Maxio.ObjectMutation.Journal
  alias Maxio.ObjectMutation.Recovery

  @impl true
  def run(args) do
    {opts, rest, invalid} =
      OptionParser.parse(args,
        strict: [
          dry_run: :boolean,
          execute: :boolean,
          mutation_id: :string,
          limit: :integer,
          older_than: :integer
        ]
      )

    if rest != [] or invalid != [] do
      unexpected = rest ++ Enum.map(invalid, &elem(&1, 0))

      Mix.raise(
        "usage: mix maxio.object_mutations.recover --dry-run [--limit N --older-than SECONDS] " <>
          "| --execute [--mutation-id ID] (unexpected: #{inspect(unexpected)})"
      )
    end

    validate_opts!(opts)

    Mix.Task.run("app.start")

    if Keyword.get(opts, :execute, false) do
      execute(opts)
    else
      dry_run(opts)
    end
  end

  defp validate_opts!(opts) do
    if Keyword.get(opts, :dry_run, false) and Keyword.get(opts, :execute, false) do
      Mix.raise("--dry-run and --execute are mutually exclusive")
    end

    if Keyword.has_key?(opts, :mutation_id) and not Keyword.get(opts, :execute, false) do
      Mix.raise("--mutation-id requires --execute (use status for read-only inspection)")
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

    validate_positive!(opts, :limit, "--limit")
    validate_positive!(opts, :older_than, "--older-than")
  end

  defp validate_positive!(opts, key, flag) do
    case Keyword.get(opts, key) do
      nil -> :ok
      value when is_integer(value) and value > 0 -> :ok
      value -> Mix.raise("#{flag} must be a positive integer, got #{inspect(value)}")
    end
  end

  # ── 默认 / --dry-run：零副作用列出到期 journal 与决策方向 ──

  defp dry_run(opts) do
    due = ObjectMutation.list_due(list_opts(opts))

    IO.puts("[maxio object_mutations.recover] dry_run=true due=#{length(due)}")

    Enum.each(due, fn journal ->
      IO.puts(
        "would_recover mutation_id=#{journal.id} phase=#{journal.phase} " <>
          "authority_mode=#{journal.authority_mode} generation=#{journal.generation} " <>
          "attempts=#{journal.attempts} bucket=#{safe_text(journal.bucket_name)} " <>
          "key=#{safe_text(journal.object_key)} version_id=#{safe_text(journal.version_id)} " <>
          "decision=#{decision(journal)}"
      )
    end)
  end

  # dry-run 的决策方向 = recovery 决策表的只读镜像（真实裁决仍由 Recovery 依 durable
  # epoch 作出——此处仅按 journal phase 预告方向，绝不读写存储）。
  defp decision(%Journal{phase: phase}) when phase in ~w(metadata_committed finalize_pending),
    do: "finalize"

  defp decision(%Journal{phase: "published", authority_mode: "sidecar"}),
    do: "finalize_if_epoch_published"

  defp decision(%Journal{}), do: "rollback"

  # ── --execute：与 recovery worker 同一入口 ──

  defp execute(opts) do
    case Keyword.get(opts, :mutation_id) do
      nil ->
        stats = Recovery.drain(list_opts(opts))

        IO.puts(
          "[maxio object_mutations.recover] executed=true claimed=#{stats.claimed} " <>
            "finalized=#{stats.finalized} rolled_back=#{stats.rolled_back} " <>
            "superseded=#{stats.superseded} quarantined=#{stats.quarantined} " <>
            "retried=#{stats.retried} skipped_locked=#{stats.skipped_locked}"
        )

      id ->
        case Recovery.recover(id) do
          {:ok, journal} ->
            IO.puts(
              "[maxio object_mutations.recover] executed=true mutation_id=#{journal.id} " <>
                "phase=#{journal.phase} attempts=#{journal.attempts}"
            )

          {:error, reason} ->
            Mix.raise("object mutation recover failed for #{id}: #{inspect(reason)}")
        end
    end
  end

  defp list_opts(opts) do
    []
    |> maybe_put(:limit, Keyword.get(opts, :limit))
    |> maybe_put(:older_than_ms, older_than_ms(opts))
  end

  defp older_than_ms(opts) do
    case Keyword.get(opts, :older_than) do
      nil -> nil
      seconds -> seconds * 1_000
    end
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  # 对象 key 可能含恶意控制字符——inspect 转义后输出（与 notification.outbox 同源防线）。
  defp safe_text(nil), do: inspect("")
  defp safe_text(value), do: inspect(to_string(value), printable_limit: 500)
end
