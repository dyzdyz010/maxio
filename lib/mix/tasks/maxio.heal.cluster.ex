defmodule Mix.Tasks.Maxio.Heal.Cluster do
  @shortdoc "跨节点纠删码自愈：从存活端点重建对象的缺失/损坏分片"
  @moduledoc """
  跨节点纠删码自愈 CLI（铁律 4：后端功能 CLI 可观测）。

      mix maxio.heal.cluster <bucket> <key> [version_id]   # heal 单对象（version_id 缺省 "null"）

  从 K 个存活端点（peer 经 :erpc）RS 重建坏分片并经 Transport.heal_shard 回写；
  某 block 存活 < K -> 打印 unrecoverable（绝不伪造数据）。
  拓扑/EC 参数取 config :maxio, Maxio.Cluster.Topology；传输取 config :maxio, :shard_transport。
  """
  use Mix.Task

  alias Maxio.Cluster.Heal

  @impl true
  def run(args) do
    Mix.Task.run("app.start")

    case args do
      [bucket, key | rest] ->
        version_id = List.first(rest) || "null"

        case Heal.heal_object(bucket, key, version_id) do
          {:ok, %{healed: n}} ->
            IO.puts("[maxio heal.cluster] #{bucket}/#{key}@#{version_id}: healed #{n} shard(s)")

          {:error, :unrecoverable} ->
            IO.puts(
              "[maxio heal.cluster] #{bucket}/#{key}@#{version_id}: UNRECOVERABLE (survivors < K) — data NOT fabricated"
            )

          {:error, :enoent} ->
            IO.puts(
              "[maxio heal.cluster] #{bucket}/#{key}@#{version_id}: no sidecar found on any endpoint"
            )
        end

      _ ->
        IO.puts("usage: mix maxio.heal.cluster <bucket> <key> [version_id]")
    end
  end
end
