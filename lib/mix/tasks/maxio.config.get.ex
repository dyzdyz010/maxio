defmodule Mix.Tasks.Maxio.Config.Get do
  @shortdoc "Show one config key: effective value plus each of the three layers"
  @moduledoc """
  单键取证。**这是定位"我改了怎么没生效"的核心工具**：除了生效值，它还打出
  runtime override / env var / Application env 三层各自的值和最终生效来源。

      mix maxio.config.get listing sql_hard_limit
      mix maxio.config.get s3 clock_skew_ms --json
  """

  use Mix.Task

  alias Maxio.Config
  alias Maxio.Config.CLI

  @impl true
  def run(args) do
    {opts, rest, invalid} = OptionParser.parse(args, strict: [json: :boolean])

    {subsystem, key} =
      case {rest, invalid} do
        {[subsystem, key], []} -> {subsystem, key}
        _other -> Mix.raise("usage: mix maxio.config.get <subsystem> <key> [--json]")
      end

    case CLI.boot() do
      :ok -> :ok
      {:error, reason} -> Mix.raise(reason)
    end

    case CLI.parse_key(subsystem, key) do
      {:ok, subsystem_atom, key_atom} ->
        print(Config.effective(subsystem_atom, key_atom), opts)

      {:error, reason} ->
        Mix.raise(CLI.describe_error(reason))
    end
  end

  defp print(effective, opts) do
    if Keyword.get(opts, :json, false) do
      IO.puts(Jason.encode!(CLI.json_entry(effective)))
    else
      IO.puts(CLI.line(effective))
      IO.puts("[maxio config.doc] #{effective.doc}")
    end
  end
end
