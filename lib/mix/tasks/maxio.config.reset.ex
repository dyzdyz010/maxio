defmodule Mix.Tasks.Maxio.Config.Reset do
  @shortdoc "Remove a runtime config override and fall back to env / compile-time default"
  @moduledoc """
  删除运行时覆盖值，回落到 env var / 编译期默认。

      mix maxio.config.reset listing sql_hard_limit
      mix maxio.config.reset s3 clock_skew_ms --expected-version 4

  输出里的 `changed=` 是显式的：对一个本来就没有覆盖值的键 reset，会打 `changed=false`
  而不是假装干了点什么。
  """

  use Mix.Task

  alias Maxio.Config
  alias Maxio.Config.CLI

  @impl true
  def run(args) do
    {opts, rest, invalid} = OptionParser.parse(args, strict: [expected_version: :integer])

    {subsystem, key} =
      case {rest, invalid} do
        {[subsystem, key], []} ->
          {subsystem, key}

        _other ->
          Mix.raise("usage: mix maxio.config.reset <subsystem> <key> [--expected-version N]")
      end

    case CLI.boot() do
      :ok -> :ok
      {:error, reason} -> Mix.raise(reason)
    end

    with {:ok, subsystem_atom, key_atom} <- CLI.parse_key(subsystem, key),
         {:ok, outcome} <- Config.reset(subsystem_atom, key_atom, write_opts(opts)) do
      effective = Config.effective(subsystem_atom, key_atom)

      IO.puts(
        "[maxio config.reset] subsystem=#{subsystem_atom} key=#{key_atom} " <>
          "changed=#{outcome.changed?} applied=#{outcome.applied} source=cli"
      )

      IO.puts(CLI.line(effective))
    else
      {:error, reason} -> Mix.raise(CLI.describe_error(reason))
    end
  end

  defp write_opts(opts) do
    base = [source: "cli"]

    case Keyword.fetch(opts, :expected_version) do
      :error -> base
      {:ok, 0} -> Keyword.put(base, :expected_version, nil)
      {:ok, version} -> Keyword.put(base, :expected_version, version)
    end
  end
end
