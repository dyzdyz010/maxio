defmodule Maxio.S3.WriteAuthorityTest do
  @moduledoc """
  ROUTE B B4-2 —— 写路径 PG 降 best-effort 索引。

  覆盖：authoritative_source(:write) 默认 :pg（向后兼容、可回滚）；
  Objects.put_version_index/4 best-effort（正常输入返回 :ok；put_version_with_id 抛异常时
  捕获返回 {:error,_} 不抛；put_version_with_id 返回 {:error, reason} 时原样 {:error, reason}）。
  """
  use Maxio.DataCase, async: false

  import Plug.Conn
  alias Maxio.{Objects, ObjectMeta}
  alias Maxio.Test.SigV4Request
  alias Maxio.S3.Endpoint

  test "authoritative_source(:write) 默认 :pg" do
    assert ObjectMeta.authoritative_source(:write) == :pg
  end

  test "put_version_index best-effort：PG 写成功返回 :ok 且对象可读回" do
    {:ok, _b} = Maxio.Buckets.create("wab", "arn:aws:iam:::root")
    assert :ok = Objects.put_version_index("wab", "k", "null", %{size: 1, etag: "\"e\""})
    assert %Objects.Object{etag: "\"e\""} = unwrap(Objects.get_metadata("wab", "k"))
  end

  test "put_version_index 捕获 put_version_with_id 抛出的异常返回 {:error,_} 不抛" do
    {:ok, _b} = Maxio.Buckets.create("wab2", "arn:aws:iam:::root")
    # 缺 :size 必填 attr -> put_version_with_id 内 Map.fetch!(attrs, :size) 抛 KeyError；
    # put_version_index 必须 rescue 之并返回 {:error, _}（绝不让 PG 故障冒泡成 raise）。
    assert {:error, %KeyError{}} =
             Objects.put_version_index("wab2", "k", "null", %{etag: "\"e\""})
  end

  test "put_version_index 透传 put_version_with_id 的 {:error, reason}（桶不存在）" do
    # 桶不存在 -> put_version_with_id 返回 {:error, :no_such_bucket}（非异常），
    # put_version_index 原样透传为 {:error, :no_such_bucket}。
    assert {:error, :no_such_bucket} =
             Objects.put_version_index("ghost-bucket", "k", "null", %{size: 1, etag: "\"e\""})
  end

  describe "do_put 按 authoritative_source(:write) 分流（端到端经 Endpoint）" do
    setup do
      # 隔离对象数据目录（避免污染 dev/test 共享目录），并把写权威切到 :sidecar。
      data_dir = Path.join(System.tmp_dir!(), "maxio_wa_#{System.unique_integer([:positive])}")
      File.rm_rf(data_dir)
      File.mkdir_p!(data_dir)

      prev_s3 = Application.get_env(:maxio, :s3)
      prev_auth = Application.get_env(:maxio, :authoritative_source)
      Application.put_env(:maxio, :s3, Keyword.put(prev_s3, :data_dir, data_dir))
      Application.put_env(:maxio, :authoritative_source, Keyword.put(prev_auth, :write, :sidecar))

      on_exit(fn ->
        Application.put_env(:maxio, :s3, prev_s3)
        Application.put_env(:maxio, :authoritative_source, prev_auth)
        File.rm_rf(data_dir)
      end)

      :ok
    end

    defp call(conn), do: Endpoint.call(conn, Endpoint.init([]))

    test ":write=:sidecar PutObject → 200 + 正确 ETag（响应视图不依赖 PG 读回）" do
      assert ObjectMeta.authoritative_source(:write) == :sidecar

      SigV4Request.signed_conn(:put, "/wa-sc") |> call()
      body = "route-b b4-2 sidecar write authority"

      put =
        SigV4Request.signed_conn(:put, "/wa-sc/obj.txt",
          body: body,
          headers: [{"content-type", "text/plain"}]
        )
        |> call()

      assert put.status == 200
      expected_etag = "\"" <> (:crypto.hash(:md5, body) |> Base.encode16(case: :lower)) <> "\""

      # ETag 由 build_put_view 经已知 attrs 构造（commit_metadata :sidecar 分支，未读 PG 行）。
      assert get_resp_header(put, "etag") == [expected_etag]

      # 默认 FS 后端下 PG best-effort 索引写成功，对象可经 GET 取回完整内容。
      get = SigV4Request.signed_conn(:get, "/wa-sc/obj.txt") |> call()
      assert get.status == 200
      assert get.resp_body == body
    end
  end

  defp unwrap({:ok, o}), do: o
  defp unwrap(o), do: o
end
