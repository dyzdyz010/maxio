defmodule Mix.Tasks.Maxio.Replication.Drain do
  @shortdoc "Drain due S3 bucket replication outbox tasks"
  @moduledoc """
  Copy due S3 bucket replication outbox tasks to their destination buckets.

      mix maxio.replication.drain
      mix maxio.replication.drain --limit 50
      mix maxio.replication.drain --json

  This task only consumes rows already persisted after successful S3 object
  mutations. It does not scan objects or synthesize new replication events.
  """

  use Mix.Task

  alias Maxio.S3.ReplicationDelivery

  @impl true
  def run(args) do
    {opts, rest, invalid} =
      OptionParser.parse(args,
        strict: [limit: :integer, json: :boolean]
      )

    if rest != [] or invalid != [] do
      unexpected = rest ++ Enum.map(invalid, &elem(&1, 0))

      Mix.raise(
        "usage: mix maxio.replication.drain [--limit N] [--json] " <>
          "(unexpected: #{inspect(unexpected)})"
      )
    end

    validate_limit!(Keyword.get(opts, :limit))

    Mix.Task.run("app.start")

    drain_opts =
      []
      |> maybe_put(:limit, Keyword.get(opts, :limit))

    case ReplicationDelivery.drain(drain_opts) do
      {:ok, summary} -> print_summary(summary, opts)
      {:error, reason} -> Mix.raise("replication drain failed: #{inspect(reason)}")
    end
  end

  defp validate_limit!(nil), do: :ok
  defp validate_limit!(limit) when is_integer(limit) and limit > 0, do: :ok

  defp validate_limit!(limit),
    do: Mix.raise("--limit must be a positive integer, got #{inspect(limit)}")

  defp print_summary(summary, opts) do
    if Keyword.get(opts, :json, false) do
      IO.puts(Jason.encode!(summary))
    else
      IO.puts(
        "[maxio replication.drain] claimed=#{summary.claimed} " <>
          "completed=#{summary.completed} failed=#{summary.failed}"
      )
    end
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)
end
