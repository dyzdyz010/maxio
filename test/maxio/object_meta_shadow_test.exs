defmodule Maxio.ObjectMetaShadowTest do
  use Maxio.DataCase, async: false

  alias Maxio.{ObjectMeta, Objects, Buckets}
  alias Maxio.Cluster.Transport.InProcess

  # 复用 cluster_e2e_test 的 InProcess topology N=6 K=4 M=2（同 setup 模式）
  @topology %{
    data_shards: 4,
    parity_shards: 2,
    block_size: 1024,
    sets: %{
      0 => %{
        id: 0,
        endpoints:
          for(
            i <- 0..5,
            do:
              {:"n#{i}",
               Path.join(System.tmp_dir!(), "om_d#{i}_#{System.unique_integer([:positive])}")}
          )
      }
    },
    set_ids: [0]
  }

  setup do
    InProcess.setup!()
    :persistent_term.put({Maxio.Cluster.Topology, :topology}, @topology)
    on_exit(fn -> :persistent_term.erase({Maxio.Cluster.Topology, :topology}) end)
    {:ok, _b} = Buckets.create("shadowb", "arn:aws:iam:::root")
    :ok
  end

  defp opts, do: [transport: InProcess, topology: @topology]

  test "authoritative_source(:read) 默认 :pg" do
    assert ObjectMeta.authoritative_source(:read) == :pg
  end

  test "shadow get 返回 PG 结果（不翻权威）" do
    {:ok, _} =
      Objects.put_version_with_id("shadowb", "k.txt", "null", %{
        size: 3,
        etag: "\"e\"",
        content_type: "text/plain"
      })

    # 即便 sidecar 缺失/分歧，shadow get 仍返回 PG 的 %Object{}
    assert %Objects.Object{} = obj = ObjectMeta.get("shadowb", "k.txt", nil, opts())
    assert obj.etag == "\"e\""
  end

  test "PG 有而 sidecar 全缺 -> 记 divergence 日志，仍返回 PG" do
    {:ok, _} =
      Objects.put_version_with_id("shadowb", "miss.txt", "null", %{size: 1, etag: "\"m\""})

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert %Objects.Object{} = ObjectMeta.get("shadowb", "miss.txt", nil, opts())
      end)

    assert log =~ "metadata divergence" or log =~ "read_quorum"
  end
end
