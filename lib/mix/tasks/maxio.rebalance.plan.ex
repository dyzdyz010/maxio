defmodule Mix.Tasks.Maxio.Rebalance.Plan do
  @shortdoc "Print read-only rebalance/decommission planning telemetry"
  @moduledoc """
  Print a read-only rebalance/decommission planning report.

      mix maxio.rebalance.plan
      mix maxio.rebalance.plan --current-only
      mix maxio.rebalance.plan --decommission-set 1
      mix maxio.rebalance.plan --no-drive-stats
      mix maxio.rebalance.plan --json

  The report accounts object metadata against the current topology. It does not
  move data, change object placement, or implement MinIO's rebalance/decommission
  state machines. Byte counts are logical object bytes, not erasure-coded shard
  bytes.
  """
  use Mix.Task

  alias Maxio.Cluster.Rebalance

  @impl true
  def run(args) do
    {opts, rest, invalid} =
      OptionParser.parse(args,
        strict: [
          current_only: :boolean,
          decommission_set: :integer,
          page_size: :integer,
          no_drive_stats: :boolean,
          json: :boolean
        ]
      )

    if rest != [] or invalid != [] do
      unexpected = rest ++ Enum.map(invalid, &elem(&1, 0))

      Mix.raise(
        "usage: mix maxio.rebalance.plan [--current-only] [--decommission-set <id>] " <>
          "[--page-size <n>] [--no-drive-stats] [--json] " <>
          "(unexpected: #{inspect(unexpected)})"
      )
    end

    validate_positive!(opts, :page_size, "--page-size")

    Mix.Task.run("app.start")

    plan_opts = [
      current_only: Keyword.get(opts, :current_only, false),
      decommission_set: Keyword.get(opts, :decommission_set),
      page_size: Keyword.get(opts, :page_size),
      include_drive_stats: not Keyword.get(opts, :no_drive_stats, false)
    ]

    case Rebalance.plan(plan_opts) do
      {:ok, report} ->
        if Keyword.get(opts, :json, false) do
          IO.puts(Jason.encode!(json_ready(report)))
        else
          print_report(report)
        end

      {:error, {:unknown_set_id, set_id, set_ids}} ->
        Mix.raise(
          "unknown --decommission-set #{inspect(set_id)}; configured set ids: #{inspect(set_ids)}"
        )

      {:error, reason} ->
        Mix.raise("rebalance plan failed: #{inspect(reason)}")
    end
  end

  defp print_report(report) do
    IO.puts(
      "[maxio rebalance.plan] status=#{report.status} scope=#{report.scope} " <>
        "topology_sets=#{report.topology_sets} endpoints=#{report.endpoints} " <>
        "buckets=#{report.buckets} pages=#{report.pages} scanned=#{report.scanned} " <>
        "objects=#{report.objects} versions=#{report.versions} " <>
        "delete_markers=#{report.delete_markers} bytes=#{report.bytes} " <>
        "drive_status=#{report.drive_stats.status} drive_ok=#{report.drive_stats.ok} " <>
        "drive_errors=#{report.drive_stats.errors} " <>
        "decommission_set=#{format_value(report.decommission_set)} " <>
        "decommission_objects=#{report.decommission.objects} " <>
        "decommission_versions=#{report.decommission.versions} " <>
        "decommission_delete_markers=#{report.decommission.delete_markers} " <>
        "decommission_bytes=#{report.decommission.bytes}"
    )

    Enum.each(report.per_set, &print_set/1)
  end

  defp print_set(set) do
    IO.puts(
      "[maxio rebalance.set] set_id=#{set.set_id} target=#{Map.fetch!(set, :target?)} " <>
        "endpoints=#{set.endpoints} objects=#{set.objects} versions=#{set.versions} " <>
        "delete_markers=#{set.delete_markers} bytes=#{set.bytes} " <>
        "drive_endpoints=#{set.drive_endpoints} drive_ok=#{set.drive_ok} " <>
        "drive_errors=#{set.drive_errors} " <>
        "drive_capacity_bytes=#{set.drive_capacity_bytes} " <>
        "drive_free_bytes=#{set.drive_free_bytes} " <>
        "drive_min_free_bytes=#{set.drive_min_free_bytes}"
    )
  end

  defp validate_positive!(opts, key, flag) do
    case Keyword.get(opts, key) do
      nil -> :ok
      value when is_integer(value) and value > 0 -> :ok
      value -> Mix.raise("#{flag} must be a positive integer, got #{inspect(value)}")
    end
  end

  defp format_value(nil), do: "nil"
  defp format_value(value), do: to_string(value)

  defp json_ready(nil), do: nil
  defp json_ready(value) when is_boolean(value), do: value
  defp json_ready(value) when is_atom(value), do: Atom.to_string(value)
  defp json_ready(value) when is_list(value), do: Enum.map(value, &json_ready/1)

  defp json_ready(%{} = value) do
    Map.new(value, fn {key, item} -> {to_string(key), json_ready(item)} end)
  end

  defp json_ready(value), do: value
end
