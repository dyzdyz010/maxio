defmodule Mix.Tasks.Maxio.Config do
  @moduledoc """
  运行时配置存储的 CLI 入口索引（AGENTS.md §4.4：后端无 GUI，必须 CLI 可完整调试）。

      mix maxio.config.list [--subsystem S] [--json]
      mix maxio.config.get <subsystem> <key> [--json]
      mix maxio.config.set <subsystem> <key> <value> [--expected-version N]
      mix maxio.config.reset <subsystem> <key> [--expected-version N]
      mix maxio.config.history <subsystem> <key> [--limit N] [--json]
      mix maxio.config.status [--json]

  排查"我改了怎么没生效"的标准动作是 `mix maxio.config.get`：它把**生效值**与
  runtime / env / app-env **三层各自的值**一起打出来，一眼看出是哪一层在起作用。
  """

  @shortdoc "Runtime config store CLI index"

  use Mix.Task

  @impl true
  def run(_args) do
    Mix.shell().info(@moduledoc)
  end
end
