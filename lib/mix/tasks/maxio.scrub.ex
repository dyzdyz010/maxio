defmodule Mix.Tasks.Maxio.Scrub do
  @shortdoc "纠删码全盘巡检：扫描所有桶/对象，检测并自愈坏分片"
  @moduledoc """
  纠删码 scrub CLI（全盘巡检 + 自愈，铁律 4 可观测）。

      mix maxio.scrub             # 扫描所有盘上所有桶的全部对象，逐个 heal
      mix maxio.scrub <bucket>    # 仅扫描指定桶

  M6 全扫（单机量可控）；MinIO 式 1/1024 采样 + 限流 defer M7（见 README）。
  EC 参数取 config :maxio, :erasure。
  """
  use Mix.Task

  alias Maxio.Storage.Erasure.Heal

  @impl true
  def run(args) do
    Mix.Task.run("app.start")

    case args do
      [bucket] ->
        {:ok, %{scanned: sc, healed_objects: hl, unrecoverable: ur}} = Heal.scrub_bucket(bucket)
        IO.puts("[maxio scrub] bucket #{bucket}: scanned=#{sc} healed=#{hl} unrecoverable=#{ur}")

      [] ->
        {:ok, %{buckets: results}} = Heal.scrub_all()

        Enum.each(results, fn {b, {:ok, %{scanned: sc, healed_objects: hl, unrecoverable: ur}}} ->
          IO.puts("[maxio scrub] bucket #{b}: scanned=#{sc} healed=#{hl} unrecoverable=#{ur}")
        end)

      _ ->
        IO.puts("usage: mix maxio.scrub [<bucket>]")
    end
  end
end
