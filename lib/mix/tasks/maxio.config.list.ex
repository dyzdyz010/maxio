defmodule Mix.Tasks.Maxio.Config.List do
  @shortdoc "List every runtime-settable config key with its effective value and source"
  @moduledoc """
  列出 `Maxio.Config.Schema` 白名单里的**全部**键：生效值、生效来源、apply 模式、版本，
  以及 runtime / env / app-env 三层各自的值。

      mix maxio.config.list
      mix maxio.config.list --subsystem listing
      mix maxio.config.list --json
  """

  use Mix.Task

  alias Maxio.Config.CLI

  @impl true
  def run(args) do
    {opts, rest, invalid} = OptionParser.parse(args, strict: [subsystem: :string, json: :boolean])

    if rest != [] or invalid != [] do
      Mix.raise(
        "usage: mix maxio.config.list [--subsystem S] [--json] " <>
          "(unexpected: #{inspect(rest ++ Enum.map(invalid, &elem(&1, 0)))})"
      )
    end

    case CLI.boot() do
      :ok -> :ok
      {:error, reason} -> Mix.raise(reason)
    end

    entries = CLI.list(Keyword.take(opts, [:subsystem]))

    if Keyword.get(opts, :json, false) do
      IO.puts(Jason.encode!(%{"entries" => Enum.map(entries, &CLI.json_entry/1)}))
    else
      Enum.each(entries, &IO.puts(CLI.line(&1)))
    end
  end
end
