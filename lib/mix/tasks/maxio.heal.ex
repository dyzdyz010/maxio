defmodule Mix.Tasks.Maxio.Heal do
  @shortdoc "纠删码自愈：重建单个对象（或单桶）的缺失/损坏分片"
  @moduledoc """
  纠删码自愈 CLI（铁律 4：后端功能 CLI 可观测）。

      mix maxio.heal <bucket> <key> [version_id]   # heal 单个对象（version_id 缺省 "null"）
      mix maxio.heal <bucket>                       # scrub 整桶

  从 K 个存活分片 RS 重建坏分片并回写；某 block 存活 < K -> 打印 unrecoverable（绝不伪造数据）。
  EC 参数取 config :maxio, :erasure。
  """
  use Mix.Task

  alias Maxio.Storage.Erasure.Heal

  @impl true
  def run(args) do
    Mix.Task.run("app.start")

    case args do
      [bucket, key | rest] ->
        version_id = List.first(rest) || "null"

        case Heal.heal_object(bucket, key, version_id) do
          {:ok, %{healed: n}} ->
            IO.puts("[maxio heal] #{bucket}/#{key}@#{version_id}: healed #{n} shard(s)")

          {:error, :unrecoverable} ->
            IO.puts(
              "[maxio heal] #{bucket}/#{key}@#{version_id}: UNRECOVERABLE (survivors < K) — data NOT fabricated"
            )

          {:error, :enoent} ->
            IO.puts("[maxio heal] #{bucket}/#{key}@#{version_id}: no sidecar found (object missing)")
        end

      [bucket] ->
        {:ok, %{scanned: sc, healed_objects: hl, unrecoverable: ur}} = Heal.scrub_bucket(bucket)
        IO.puts("[maxio heal] bucket #{bucket}: scanned=#{sc} healed=#{hl} unrecoverable=#{ur}")

      _ ->
        IO.puts("usage: mix maxio.heal <bucket> [<key> [version_id]]")
    end
  end
end
