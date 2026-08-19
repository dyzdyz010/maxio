defmodule Mix.Tasks.Maxio.Config.Set do
  @shortdoc "Set a runtime config override (prints whether it takes effect hot or needs a restart)"
  @moduledoc """
  写一个运行时覆盖值。

      mix maxio.config.set listing sql_hard_limit 50000
      mix maxio.config.set prometheus_metrics public true
      mix maxio.config.set s3 clock_skew_ms 600000 --expected-version 3

  输出里的 `applied=` **必须**被当真：`hot` 表示下一次读就生效；`next_cycle` 表示下一轮
  调度生效；`restart` 表示**已持久化但还没生效**，要重启节点。写成功 ≠ 生效，两者绝不
  混为一谈。

  `--expected-version` 做乐观并发：与当前版本不符即 `config_version_conflict` 硬失败，
  绝不静默覆盖别人的改动。首次覆盖用 `--expected-version 0` 表达"我预期这个键还没有覆盖值"。
  """

  use Mix.Task

  alias Maxio.Config
  alias Maxio.Config.{CLI, Schema}

  @impl true
  def run(args) do
    {opts, rest, invalid} =
      OptionParser.parse(args, strict: [expected_version: :integer])

    {subsystem, key, raw} =
      case {rest, invalid} do
        {[subsystem, key, raw], []} ->
          {subsystem, key, raw}

        _other ->
          Mix.raise(
            "usage: mix maxio.config.set <subsystem> <key> <value> [--expected-version N] " <>
              "(use --expected-version 0 to assert the key currently has no override)"
          )
      end

    case CLI.boot() do
      :ok -> :ok
      {:error, reason} -> Mix.raise(reason)
    end

    with {:ok, subsystem_atom, key_atom} <- CLI.parse_key(subsystem, key),
         {:ok, value} <- Schema.parse(subsystem_atom, key_atom, raw),
         {:ok, outcome} <- Config.set(subsystem_atom, key_atom, value, write_opts(opts)) do
      IO.puts(
        "[maxio config.set] subsystem=#{subsystem_atom} key=#{key_atom} " <>
          "value=#{inspect(outcome.value)} version=#{outcome.version} " <>
          "applied=#{outcome.applied} source=cli"
      )

      IO.puts("[maxio config.set] #{applied_note(outcome.applied)}")
    else
      {:error, reason} -> Mix.raise(CLI.describe_error(reason))
    end
  end

  # --expected-version 0 表示"预期还没有覆盖行"（版本从 1 起，0 不是合法版本号）。
  # 不用省略参数表达这个意图：省略的语义是"我不检查"，两者必须可区分。
  defp write_opts(opts) do
    base = [source: "cli"]

    case Keyword.fetch(opts, :expected_version) do
      :error -> base
      {:ok, 0} -> Keyword.put(base, :expected_version, nil)
      {:ok, version} -> Keyword.put(base, :expected_version, version)
    end
  end

  defp applied_note(:hot), do: "applied=hot -> the next read already sees the new value."

  defp applied_note(:next_cycle),
    do: "applied=next_cycle -> takes effect on the next scheduler tick, not immediately."

  defp applied_note(:restart) do
    "applied=restart -> PERSISTED BUT NOT YET IN EFFECT. This key is read once at startup; " <>
      "restart the node for it to take effect."
  end
end
