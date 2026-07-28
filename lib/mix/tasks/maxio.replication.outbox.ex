defmodule Mix.Tasks.Maxio.Replication.Outbox do
  @shortdoc "List S3 bucket replication outbox tasks"
  @moduledoc """
  List recent S3 bucket replication outbox tasks without claiming or delivering
  them.

      mix maxio.replication.outbox
      mix maxio.replication.outbox --status failed --limit 50
      mix maxio.replication.outbox --json
  """

  use Mix.Task

  alias Maxio.S3.ReplicationOutbox

  @statuses ~w(pending delivering completed failed)

  @impl true
  def run(args) do
    {opts, rest, invalid} =
      OptionParser.parse(args,
        strict: [status: :string, limit: :integer, json: :boolean]
      )

    if rest != [] or invalid != [] do
      unexpected = rest ++ Enum.map(invalid, &elem(&1, 0))

      Mix.raise(
        "usage: mix maxio.replication.outbox [--status pending|delivering|completed|failed] " <>
          "[--limit N] [--json] (unexpected: #{inspect(unexpected)})"
      )
    end

    validate_status!(Keyword.get(opts, :status))
    validate_limit!(Keyword.get(opts, :limit))

    Mix.Task.run("app.start")

    events =
      opts
      |> list_opts()
      |> ReplicationOutbox.list()
      |> Enum.map(&ReplicationOutbox.to_view/1)

    print_report(%{count: length(events), events: events}, opts)
  end

  defp list_opts(opts) do
    []
    |> maybe_put(:status, Keyword.get(opts, :status))
    |> maybe_put(:limit, Keyword.get(opts, :limit))
  end

  defp validate_status!(nil), do: :ok
  defp validate_status!(status) when status in @statuses, do: :ok

  defp validate_status!(status) do
    Mix.raise("--status must be one of #{Enum.join(@statuses, ", ")}, got #{inspect(status)}")
  end

  defp validate_limit!(nil), do: :ok
  defp validate_limit!(limit) when is_integer(limit) and limit > 0, do: :ok

  defp validate_limit!(limit),
    do: Mix.raise("--limit must be a positive integer, got #{inspect(limit)}")

  defp print_report(report, opts) do
    if Keyword.get(opts, :json, false) do
      IO.puts(Jason.encode!(report))
    else
      print_text(report)
    end
  end

  defp print_text(%{count: 0}) do
    IO.puts("[maxio replication.outbox] tasks=0")
  end

  defp print_text(%{count: count, events: events}) do
    IO.puts("[maxio replication.outbox] tasks=#{count}")

    Enum.each(events, fn event ->
      IO.puts(
        "id=#{safe_text(event.id)} status=#{safe_text(event.status)} attempts=#{event.attempts} " <>
          "source=#{safe_text(event.source_bucket)}/#{safe_text(event.source_key)} " <>
          "version_id=#{safe_text(event.source_version_id)} event=#{safe_text(event.event_name)} " <>
          "destination_bucket=#{safe_text(event.destination_bucket)} " <>
          "next_attempt_at=#{format_dt(event.next_attempt_at)}"
      )
    end)
  end

  defp safe_text(nil), do: inspect("")
  defp safe_text(value), do: inspect(to_string(value), printable_limit: 200)

  defp format_dt(nil), do: ""
  defp format_dt(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp format_dt(value), do: to_string(value)

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)
end
