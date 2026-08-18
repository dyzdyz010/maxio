defmodule Maxio.S3.ReservedNamespaceTest do
  @moduledoc """
  保留面认领规则表与它的**全部派生物**必须同源（I2）：plug 的认领判定、
  `Maxio.S3.Prometheus.metrics_path?/1`、启动期审计的扫描面，三者都由 `@claims` 派生。
  一旦有人绕过规则表另写一份，本文件必须失败——否则审计会漏报被影子化的 key，
  那是最恶劣的静默失败（铁律 3）。
  """
  use ExUnit.Case, async: true

  alias Maxio.S3.{Prometheus, ReservedNamespace}

  test "every claim rule is claimed by exactly the surface that declares it" do
    for {surface, kind, path} <- ReservedNamespace.claims() do
      sample = sample_path(kind, path)

      assert ReservedNamespace.path_claimed?(sample, surface),
             "#{inspect(sample)} is declared by #{surface} but not claimed by it"

      assert ReservedNamespace.claimed_path?(sample)

      for other <- ReservedNamespace.surfaces() -- [surface] do
        refute ReservedNamespace.path_claimed?(sample, other),
               "#{inspect(sample)} leaked into the #{other} surface"
      end
    end
  end

  test "Prometheus.metrics_path?/1 is the claim table, not a private copy" do
    for {surface, kind, path} <- ReservedNamespace.claims() do
      sample = sample_path(kind, path)
      assert Prometheus.metrics_path?(sample) == (surface == :metrics)
    end

    # 既有的谨慎写法必须保住：相邻但不同段的路径绝不被吞。
    refute Prometheus.metrics_path?("/minio/v2/metricsfoobar")
    refute ReservedNamespace.claimed_path?("/minio/adminxyz")
    refute ReservedNamespace.claimed_path?("/minioxyz/health/live")
    refute ReservedNamespace.claimed_path?("/minio/health/livecheck")
  end

  test "the audit scan surface derived from the table matches the claim decision key by key" do
    # shadowed_targets/0 是审计 SQL 条件的唯一来源；它必须与 claimed_path?/1 逐条对应，
    # 且不多不少——多了会误报"数据丢失"，少了会漏报，两者一样有害。
    for {bucket, kind, key} <- ReservedNamespace.shadowed_targets() do
      hit = sample_key(kind, key)

      assert ReservedNamespace.shadowed?(bucket, hit)
      assert ReservedNamespace.claimed_path?("/" <> bucket <> "/" <> hit)

      # 同名 key 挂到别的桶上绝不算影子化（vhost 劫持已修复，见寻址用例）
      refute ReservedNamespace.shadowed?("otherbucket", hit)
    end

    assert length(ReservedNamespace.shadowed_targets()) == length(ReservedNamespace.claims())
  end

  test "health_paths/0 stays derived from the table" do
    assert ReservedNamespace.health_paths() == ["/minio/health/live", "/minio/health/ready"]

    for path <- ReservedNamespace.health_paths() do
      assert ReservedNamespace.health_path?(path)
    end
  end

  test "claiming a request without AddressStyle having run fails loudly" do
    conn = Plug.Test.conn(:get, "/minio/health/live")

    # 专用异常类型（不是裸 RuntimeError）：各面 plug 的通用 500 兜底必须能把"管线顺序错误"
    # 与偶发运行时异常区分开并原样上抛（M-3）。
    assert_raise Maxio.S3.PipelineOrderError, ~r/s3_address_style/, fn ->
      ReservedNamespace.claimed?(conn, :health)
    end

    # 路径本来就不相干的请求不该因为管线顺序而炸
    refute ReservedNamespace.claimed?(Plug.Test.conn(:get, "/some/bucket/key"), :health)
  end

  defp sample_path(:exact, path), do: path
  defp sample_path(:prefix, path), do: path <> "sample"

  defp sample_key(:exact, key), do: key
  defp sample_key(:prefix, key), do: key <> "sample"
end
