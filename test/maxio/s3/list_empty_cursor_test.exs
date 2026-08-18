defmodule Maxio.S3.ListEmptyCursorTest do
  @moduledoc """
  空串**游标**参数（`?continuation-token=&start-after=dir/`，参数存在但值为空）的列举语义。

  与空 delimiter（`list_empty_delimiter_test.exs`）不是同一类缺陷：空 delimiter 会把
  `:binary.match/2` 炸成 500；空游标不崩，但会**参数遮蔽**——Elixir 里 `""` 是 truthy，
  `Map.get(opts, :continuation_token) || Map.get(opts, :start_after)` 让空的
  continuation-token 吞掉非空的 start-after，静默返回全量而不是游标之后的那一页。

  覆盖 ListObjectsV2 的 continuation-token / start-after，以及 V1 marker、
  ListObjectVersions 的 key-marker / version-id-marker、ListMultipartUploads 的
  key-marker / upload-id-marker，并回归**非空**游标的分页语义逐字不变。
  """
  use Maxio.DataCase, async: false

  alias Maxio.Auth.CredentialStore
  alias Maxio.S3.Endpoint
  alias Maxio.Test.SigV4Request

  @data_dir Path.join(System.tmp_dir!(), "maxio_list_empty_cursor")
  @ak "AKIALISTEMPTYCURSOR"
  @secret "listemptycursorsecret1234"
  @arn "arn:aws:iam:::user/" <> @ak

  setup do
    File.rm_rf(@data_dir)
    File.mkdir_p!(@data_dir)
    prev = Application.get_env(:maxio, :s3)
    Application.put_env(:maxio, :s3, Keyword.put(prev, :data_dir, @data_dir))

    :ok =
      CredentialStore.put_access_key(%{
        access_key: @ak,
        secret_key: @secret,
        principal: %{type: :iam_user, access_key: @ak, arn: @arn}
      })

    on_exit(fn ->
      Application.put_env(:maxio, :s3, prev)
      File.rm_rf(@data_dir)
    end)

    :ok
  end

  defp call(conn), do: Endpoint.call(conn, Endpoint.init([]))

  # 字典序：dir/a.txt < dir/sub/b.txt < top.txt
  defp seed_tree(bucket) do
    SigV4Request.signed_conn(:put, "/#{bucket}") |> call()

    for key <- ~w(top.txt dir/a.txt dir/sub/b.txt) do
      SigV4Request.signed_conn(:put, "/#{bucket}/#{key}", body: key) |> call()
    end

    :ok
  end

  describe "ListObjectsV2 空 continuation-token" do
    test "空 continuation-token 不得遮蔽非空 start-after" do
      bucket = "lec-v2-shadow"
      seed_tree(bucket)

      res =
        SigV4Request.signed_conn(:get, "/#{bucket}",
          query: %{
            "list-type" => "2",
            "continuation-token" => "",
            "start-after" => "dir/a.txt"
          }
        )
        |> call()

      assert res.status == 200

      # start-after 是"严格大于"起点：dir/a.txt 必须被排除，其后两条必须在。
      refute res.resp_body =~ "<Key>dir/a.txt</Key>"
      assert res.resp_body =~ "<Key>dir/sub/b.txt</Key>"
      assert res.resp_body =~ "<Key>top.txt</Key>"
      assert res.resp_body =~ "<KeyCount>2</KeyCount>"
    end

    test "空 continuation-token + 无 start-after：等价于未指定游标，全量列举" do
      bucket = "lec-v2-empty-only"
      seed_tree(bucket)

      res =
        SigV4Request.signed_conn(:get, "/#{bucket}",
          query: %{"list-type" => "2", "continuation-token" => ""}
        )
        |> call()

      assert res.status == 200
      assert res.resp_body =~ "<KeyCount>3</KeyCount>"

      # 空串游标视为未指定 → 不回显 <ContinuationToken>（与 MinIO omitempty 一致）
      refute res.resp_body =~ "<ContinuationToken>"
    end

    test "空 start-after 不影响列举，也不回显 <StartAfter>" do
      bucket = "lec-v2-empty-start-after"
      seed_tree(bucket)

      res =
        SigV4Request.signed_conn(:get, "/#{bucket}",
          query: %{"list-type" => "2", "start-after" => ""}
        )
        |> call()

      assert res.status == 200
      assert res.resp_body =~ "<KeyCount>3</KeyCount>"
      refute res.resp_body =~ "<StartAfter>"
    end

    test "回归：非空 continuation-token 仍优先于非空 start-after（分页语义逐字不变）" do
      bucket = "lec-v2-precedence"
      seed_tree(bucket)

      # continuation-token 指向 dir/sub/b.txt，start-after 指向更靠前的 dir/a.txt。
      # 官方语义：continuation-token 优先，故只应返回 top.txt。
      res =
        SigV4Request.signed_conn(:get, "/#{bucket}",
          query: %{
            "list-type" => "2",
            "continuation-token" => "dir/sub/b.txt",
            "start-after" => "dir/a.txt"
          }
        )
        |> call()

      assert res.status == 200
      assert res.resp_body =~ "<KeyCount>1</KeyCount>"
      assert res.resp_body =~ "<Key>top.txt</Key>"
      refute res.resp_body =~ "<Key>dir/a.txt</Key>"
      refute res.resp_body =~ "<Key>dir/sub/b.txt</Key>"
      assert res.resp_body =~ "<ContinuationToken>dir/sub/b.txt</ContinuationToken>"
    end

    test "回归：仅非空 start-after 的分页语义不变" do
      bucket = "lec-v2-start-after-only"
      seed_tree(bucket)

      res =
        SigV4Request.signed_conn(:get, "/#{bucket}",
          query: %{"list-type" => "2", "start-after" => "dir/sub/b.txt"}
        )
        |> call()

      assert res.status == 200
      assert res.resp_body =~ "<KeyCount>1</KeyCount>"
      assert res.resp_body =~ "<Key>top.txt</Key>"
      assert res.resp_body =~ "<StartAfter>dir/sub/b.txt</StartAfter>"
    end
  end

  describe "其余列举 API 的空串游标" do
    test "ListObjects V1：空 marker 等价于未指定" do
      bucket = "lec-v1-empty-marker"
      seed_tree(bucket)

      res =
        SigV4Request.signed_conn(:get, "/#{bucket}", query: %{"marker" => ""}) |> call()

      assert res.status == 200
      assert res.resp_body =~ "<Key>dir/a.txt</Key>"
      assert res.resp_body =~ "<Key>dir/sub/b.txt</Key>"
      assert res.resp_body =~ "<Key>top.txt</Key>"
      # V1 的 <Marker> 恒渲染（AWS 示例响应即 <KeyMarker></KeyMarker> 空元素形态）
      assert res.resp_body =~ "<Marker></Marker>"
    end

    test "ListObjects V1：回归——非空 marker 分页不变" do
      bucket = "lec-v1-marker"
      seed_tree(bucket)

      res =
        SigV4Request.signed_conn(:get, "/#{bucket}", query: %{"marker" => "dir/a.txt"}) |> call()

      assert res.status == 200
      refute res.resp_body =~ "<Key>dir/a.txt</Key>"
      assert res.resp_body =~ "<Key>dir/sub/b.txt</Key>"
      assert res.resp_body =~ "<Key>top.txt</Key>"
    end

    test "ListObjectVersions：空 key-marker / version-id-marker 等价于未指定" do
      bucket = "lec-versions-empty"
      seed_tree(bucket)

      res =
        SigV4Request.signed_conn(:get, "/#{bucket}",
          query: %{"versions" => "", "key-marker" => "", "version-id-marker" => ""}
        )
        |> call()

      assert res.status == 200
      assert res.resp_body =~ "<Key>dir/a.txt</Key>"
      assert res.resp_body =~ "<Key>dir/sub/b.txt</Key>"
      assert res.resp_body =~ "<Key>top.txt</Key>"
    end

    test "ListObjectVersions：空 version-id-marker 不得吃掉非空 key-marker" do
      bucket = "lec-versions-shadow"
      seed_tree(bucket)

      res =
        SigV4Request.signed_conn(:get, "/#{bucket}",
          query: %{"versions" => "", "key-marker" => "dir/a.txt", "version-id-marker" => ""}
        )
        |> call()

      assert res.status == 200
      refute res.resp_body =~ "<Key>dir/a.txt</Key>"
      assert res.resp_body =~ "<Key>dir/sub/b.txt</Key>"
      assert res.resp_body =~ "<Key>top.txt</Key>"
    end

    test "ListMultipartUploads：空 key-marker / upload-id-marker 等价于未指定" do
      bucket = "lec-uploads-empty"
      SigV4Request.signed_conn(:put, "/#{bucket}") |> call()

      for key <- ~w(top.bin dir/a.bin) do
        init =
          SigV4Request.signed_conn(:post, "/#{bucket}/#{key}", query: %{"uploads" => ""})
          |> call()

        assert init.status == 200
      end

      res =
        SigV4Request.signed_conn(:get, "/#{bucket}",
          query: %{"uploads" => "", "key-marker" => "", "upload-id-marker" => ""}
        )
        |> call()

      assert res.status == 200
      assert res.resp_body =~ "<Key>top.bin</Key>"
      assert res.resp_body =~ "<Key>dir/a.bin</Key>"
    end

    test "ListMultipartUploads：空 upload-id-marker 不得吃掉非空 key-marker" do
      bucket = "lec-uploads-shadow"
      SigV4Request.signed_conn(:put, "/#{bucket}") |> call()

      for key <- ~w(top.bin dir/a.bin) do
        init =
          SigV4Request.signed_conn(:post, "/#{bucket}/#{key}", query: %{"uploads" => ""})
          |> call()

        assert init.status == 200
      end

      res =
        SigV4Request.signed_conn(:get, "/#{bucket}",
          query: %{"uploads" => "", "key-marker" => "dir/a.bin", "upload-id-marker" => ""}
        )
        |> call()

      assert res.status == 200
      refute res.resp_body =~ "<Key>dir/a.bin</Key>"
      assert res.resp_body =~ "<Key>top.bin</Key>"
    end
  end
end
