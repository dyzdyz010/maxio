defmodule Mix.Tasks.Maxio.Notification.Drain do
  @shortdoc "Drain due S3 bucket notification outbox events"
  @moduledoc """
  Deliver due S3 bucket notification outbox events through the configured
  notification deliverer.

      mix maxio.notification.drain
      mix maxio.notification.drain --limit 50
      mix maxio.notification.drain --json

  This task never scans objects and never creates new events. It only consumes
  rows already persisted after successful S3 object mutations.
  """

  use Mix.Task

  alias Maxio.S3.NotificationDelivery

  @impl true
  def run(args) do
    {opts, rest, invalid} =
      OptionParser.parse(args,
        strict: [limit: :integer, json: :boolean]
      )

    if rest != [] or invalid != [] do
      unexpected = rest ++ Enum.map(invalid, &elem(&1, 0))

      Mix.raise(
        "usage: mix maxio.notification.drain [--limit N] [--json] " <>
          "(unexpected: #{inspect(unexpected)})"
      )
    end

    validate_limit!(Keyword.get(opts, :limit))

    Mix.Task.run("app.start")

    drain_opts =
      opts
      |> maybe_put(:limit, Keyword.get(opts, :limit))

    case NotificationDelivery.drain(drain_opts) do
      {:ok, summary} ->
        print_summary(summary, opts)

      {:error, :no_deliverer} ->
        Mix.raise(
          "notification drain requires config :maxio, :notification_delivery, deliverer: ..."
        )

      {:error, reason} ->
        Mix.raise("notification drain failed: #{inspect(reason)}")
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
        "[maxio notification.drain] claimed=#{summary.claimed} " <>
          "delivered=#{summary.delivered} failed=#{summary.failed}"
      )
    end
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)
end
