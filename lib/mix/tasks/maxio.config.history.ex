defmodule Mix.Tasks.Maxio.Config.History do
  @shortdoc "Print the change audit trail of one config key"
  @moduledoc """
  打印单键的变更审计流水（最近的在前）：谁、什么时候、从哪个版本改到哪个版本、前后值、
  经哪个通道（admin_api / cli / console / system）。

      mix maxio.config.history listing sql_hard_limit
      mix maxio.config.history s3 clock_skew_ms --limit 50 --json
  """

  use Mix.Task

  alias Maxio.Config
  alias Maxio.Config.CLI

  @impl true
  def run(args) do
    {opts, rest, invalid} = OptionParser.parse(args, strict: [limit: :integer, json: :boolean])

    {subsystem, key} =
      case {rest, invalid} do
        {[subsystem, key], []} ->
          {subsystem, key}

        _other ->
          Mix.raise("usage: mix maxio.config.history <subsystem> <key> [--limit N] [--json]")
      end

    limit = Keyword.get(opts, :limit, 20)

    if limit <= 0 do
      Mix.raise("--limit must be a positive integer, got #{limit}")
    end

    case CLI.boot() do
      :ok -> :ok
      {:error, reason} -> Mix.raise(reason)
    end

    case CLI.parse_key(subsystem, key) do
      {:ok, subsystem_atom, key_atom} ->
        subsystem_atom
        |> Config.history(key_atom, limit: limit)
        |> print(opts)

      {:error, reason} ->
        Mix.raise(CLI.describe_error(reason))
    end
  end

  defp print(audits, opts) do
    if Keyword.get(opts, :json, false) do
      IO.puts(Jason.encode!(%{"audits" => Enum.map(audits, &CLI.audit_json/1)}))
    else
      # 空历史必须显式说出来，否则"没有输出"会被读成"任务没跑起来"。
      if audits == [] do
        IO.puts("[maxio config.history] no runtime override has ever been written for this key")
      else
        Enum.each(audits, &IO.puts(CLI.audit_line(&1)))
      end
    end
  end
end
