defmodule Maxio.Storage.DistributedConformanceTest do
  use ExUnit.Case, async: false
  @backend Maxio.Storage.Distributed

  alias Maxio.Cluster.{Topology, Transport.InProcess}

  setup do
    InProcess.setup!()
    base = Path.join(System.tmp_dir!(), "maxio_dist_conf_#{System.unique_integer([:positive])}")

    # 1 pool, 1 set, N=6 端点 = 6 个独立临时目录（同机模拟 6 节点，3 个 node 名各 2 drive）。
    endpoints =
      for i <- 0..5 do
        {:"maxio@n#{rem(i, 3)}", Path.join(base, "n#{rem(i, 3)}_d#{div(i, 3)}")}
      end

    topology =
      Topology.parse_and_validate!(
        data_shards: 4,
        parity_shards: 2,
        block_size: 1024,
        pools: [%{id: 0, sets: [%{id: 0, endpoints: endpoints}]}]
      )

    on_exit(fn -> File.rm_rf(base) end)
    {:ok, topology: topology}
  end

  defp opts(ctx), do: [topology: ctx.topology, transport: InProcess]

  use Maxio.Test.StorageConformance
end
