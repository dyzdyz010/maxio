defmodule Maxio.S3.ListEmptyDelimiterTest do
  @moduledoc """
  空串 delimiter（`?delimiter=`，参数存在但值为空）的列举语义。

  真实 mc（MinIO client）递归列举/删除发的就是这种请求：
  `GET /<bucket>?delimiter=&encoding-type=url&fetch-owner=true&list-type=2`。
  AWS 语义：空 delimiter 等价于**没有 delimiter**——不做任何前缀折叠（递归平铺列举），
  且响应中不回显 `<Delimiter>` 元素。

  覆盖 ListObjectsV2 / ListObjects V1 / ListObjectVersions / ListMultipartUploads
  四条同样吃 delimiter 的列举路径，并回归 `delimiter=/` 的折叠不受影响。
  """
  use Maxio.DataCase, async: false

  alias Maxio.Auth.CredentialStore
  alias Maxio.Policy.Store
  alias Maxio.S3.Endpoint
  alias Maxio.Test.SigV4Request

  @data_dir Path.join(System.tmp_dir!(), "maxio_list_empty_delimiter")
  @alice_ak "AKIALISTEMPTYDELIM"
  @alice_secret "listemptydelimitersecret123"
  @alice_arn "arn:aws:iam:::user/" <> @alice_ak

  setup do
    %{user_arn: @alice_arn} =
      create_user_with_access_key!(
        user_name: @alice_ak,
        access_key_id: @alice_ak,
        secret_key: @alice_secret
      )

    File.rm_rf(@data_dir)
    File.mkdir_p!(@data_dir)
    prev = Application.get_env(:maxio, :s3)
    Application.put_env(:maxio, :s3, Keyword.put(prev, :data_dir, @data_dir))

    :ok =
      CredentialStore.put_access_key(%{
        access_key: @alice_ak,
        secret_key: @alice_secret,
        principal: %{type: :iam_user, access_key: @alice_ak, arn: @alice_arn}
      })

    on_exit(fn ->
      Application.put_env(:maxio, :s3, prev)
      File.rm_rf(@data_dir)
    end)

    :ok
  end

  defp call(conn), do: Endpoint.call(conn, Endpoint.init([]))

  defp seed_tree(bucket) do
    SigV4Request.signed_conn(:put, "/#{bucket}") |> call()

    for key <- ~w(top.txt dir/a.txt dir/sub/b.txt) do
      SigV4Request.signed_conn(:put, "/#{bucket}/#{key}", body: key) |> call()
    end

    :ok
  end

  test "ListObjectsV2：mc ls --recursive 的空 delimiter 递归平铺列举" do
    bucket = "led-v2"
    seed_tree(bucket)

    # mc 递归列举的逐字请求形态（delimiter 为空串，非缺省）
    res =
      SigV4Request.signed_conn(:get, "/#{bucket}",
        query: %{
          "delimiter" => "",
          "encoding-type" => "url",
          "fetch-owner" => "true",
          "list-type" => "2"
        }
      )
      |> call()

    assert res.status == 200
    assert res.resp_body =~ "<Key>top.txt</Key>"
    assert res.resp_body =~ "<Key>dir/a.txt</Key>"
    assert res.resp_body =~ "<Key>dir/sub/b.txt</Key>"
    assert res.resp_body =~ "<KeyCount>3</KeyCount>"
    refute res.resp_body =~ "<CommonPrefixes>"
    # 空 delimiter 等价于无 delimiter：不回显 <Delimiter>（与 MinIO omitempty 一致）
    refute res.resp_body =~ "<Delimiter>"
  end

  test "ListObjectsV2：delimiter=/ 仍正常折叠（回归）" do
    bucket = "led-v2-slash"
    seed_tree(bucket)

    res =
      SigV4Request.signed_conn(:get, "/#{bucket}",
        query: %{"delimiter" => "/", "list-type" => "2"}
      )
      |> call()

    assert res.status == 200
    assert res.resp_body =~ "<Key>top.txt</Key>"
    assert res.resp_body =~ "<CommonPrefixes><Prefix>dir/</Prefix></CommonPrefixes>"
    refute res.resp_body =~ "<Key>dir/a.txt</Key>"
    assert res.resp_body =~ "<Delimiter>/</Delimiter>"
  end

  test "ListObjectsV2：非字符串形态的 delimiter（?delimiter[]=）按未指定处理，不炸 500" do
    bucket = "led-v2-list-shape"
    seed_tree(bucket)

    res =
      SigV4Request.signed_conn(:get, "/#{bucket}",
        query: %{"list-type" => "2", "delimiter[]" => "/"}
      )
      |> call()

    assert res.status == 200
    assert res.resp_body =~ "<Key>dir/a.txt</Key>"
    refute res.resp_body =~ "<CommonPrefixes>"
    refute res.resp_body =~ "<Delimiter>"
  end

  test "ListObjects V1：空 delimiter 递归平铺列举" do
    bucket = "led-v1"
    seed_tree(bucket)

    res =
      SigV4Request.signed_conn(:get, "/#{bucket}", query: %{"delimiter" => ""}) |> call()

    assert res.status == 200
    assert res.resp_body =~ "<Key>top.txt</Key>"
    assert res.resp_body =~ "<Key>dir/a.txt</Key>"
    assert res.resp_body =~ "<Key>dir/sub/b.txt</Key>"
    refute res.resp_body =~ "<CommonPrefixes>"
    refute res.resp_body =~ "<Delimiter>"
  end

  test "ListObjects V1：空 delimiter + marker 分页不被空串折叠逻辑污染" do
    bucket = "led-v1-marker"
    seed_tree(bucket)

    res =
      SigV4Request.signed_conn(:get, "/#{bucket}",
        query: %{"delimiter" => "", "marker" => "dir/a.txt"}
      )
      |> call()

    assert res.status == 200
    assert res.resp_body =~ "<Marker>dir/a.txt</Marker>"
    assert res.resp_body =~ "<Key>dir/sub/b.txt</Key>"
    assert res.resp_body =~ "<Key>top.txt</Key>"
    refute res.resp_body =~ "<Key>dir/a.txt</Key>"
  end

  test "ListObjectVersions：空 delimiter 递归平铺列举" do
    bucket = "led-versions"
    seed_tree(bucket)

    res =
      SigV4Request.signed_conn(:get, "/#{bucket}",
        query: %{"versions" => "", "delimiter" => "", "encoding-type" => "url"}
      )
      |> call()

    assert res.status == 200
    assert res.resp_body =~ "ListVersionsResult"
    assert res.resp_body =~ "<Key>top.txt</Key>"
    assert res.resp_body =~ "<Key>dir/a.txt</Key>"
    assert res.resp_body =~ "<Key>dir/sub/b.txt</Key>"
    refute res.resp_body =~ "<CommonPrefixes>"
    refute res.resp_body =~ "<Delimiter>"
  end

  test "ListMultipartUploads：空 delimiter 递归平铺列举" do
    bucket = "led-uploads"
    SigV4Request.signed_conn(:put, "/#{bucket}") |> call()

    for key <- ~w(top.bin dir/a.bin) do
      init =
        SigV4Request.signed_conn(:post, "/#{bucket}/#{key}", query: %{"uploads" => ""}) |> call()

      assert init.status == 200
    end

    res =
      SigV4Request.signed_conn(:get, "/#{bucket}", query: %{"uploads" => "", "delimiter" => ""})
      |> call()

    assert res.status == 200
    assert res.resp_body =~ "ListMultipartUploadsResult"
    assert res.resp_body =~ "<Key>top.bin</Key>"
    assert res.resp_body =~ "<Key>dir/a.bin</Key>"
    refute res.resp_body =~ "<CommonPrefixes>"
    refute res.resp_body =~ "<Delimiter>"
  end

  test "s3:delimiter 条件键：空串 delimiter 与未指定同判（授权层与列举层不分叉）" do
    bucket = "led-authz"
    seed_tree(bucket)

    # 仅当请求**不带** delimiter 时放行 ListBucket（Null:true = 条件键必须缺席）
    policy =
      Jason.encode!(%{
        "Version" => "2012-10-17",
        "Statement" => [
          %{
            "Effect" => "Allow",
            "Action" => ["s3:ListBucket"],
            "Resource" => "arn:aws:s3:::#{bucket}",
            "Condition" => %{"Null" => %{"s3:delimiter" => "true"}}
          }
        ]
      })

    :ok = Store.put_principal_policy(@alice_arn, "list-empty-delimiter-#{bucket}", policy)

    empty =
      alice(:get, "/#{bucket}", query: %{"list-type" => "2", "delimiter" => ""}) |> call()

    assert empty.status == 200
    assert empty.resp_body =~ "<Key>dir/a.txt</Key>"

    slash =
      alice(:get, "/#{bucket}", query: %{"list-type" => "2", "delimiter" => "/"}) |> call()

    assert slash.status == 403
    assert slash.resp_body =~ "AccessDenied"
  end

  test "s3:delimiter 条件键：StringEqualsIfExists 区分「缺席」与「存在但为空」（归一化变异敏感）" do
    bucket = "led-authz-ifexists"
    seed_tree(bucket)

    # 为什么用 StringEqualsIfExists 而不是 Null：`Null` 对「缺席」与「存在但为空」本来就同判
    # （evaluator 把空的 context 值当缺席），所以 Null 那条测试**锁不住**归一化本身——把
    # authz.ex 的 ListQuery.delimiter(qp) 改回 Map.get(qp, "delimiter")，它照样通过。
    #
    # StringEqualsIfExists 是能区分两者的算子（Maxio.Policy.Condition）：
    #   * 条件键**缺席** → missing_key_holds?(_, if_exists?: true, ...) → true → Allow 生效；
    #   * 条件键**存在但为空** → eval("StringEquals", "/", "") → req_vals=[""] 不匹配 "/" → false
    #     → Allow 不生效 → 隐式拒绝 403。
    # 故 `?delimiter=`（空串）在归一化前被拒、归一化后放行——这条断言**只有**在
    # 条件键读归一化值时才成立，改回原样即失败。
    policy =
      Jason.encode!(%{
        "Version" => "2012-10-17",
        "Statement" => [
          %{
            "Effect" => "Allow",
            "Action" => ["s3:ListBucket"],
            "Resource" => "arn:aws:s3:::#{bucket}",
            "Condition" => %{"StringEqualsIfExists" => %{"s3:delimiter" => "/"}}
          }
        ]
      })

    :ok = Store.put_principal_policy(@alice_arn, "list-empty-delimiter-#{bucket}", policy)

    # 空串 delimiter 必须被判为「条件键缺席」→ IfExists 放行
    empty = alice(:get, "/#{bucket}", query: %{"list-type" => "2", "delimiter" => ""}) |> call()

    assert empty.status == 200
    assert empty.resp_body =~ "<Key>dir/a.txt</Key>"

    # 完全不带 delimiter：同样缺席 → 放行（空串与缺席同判的另一半）
    absent = alice(:get, "/#{bucket}", query: %{"list-type" => "2"}) |> call()
    assert absent.status == 200

    # delimiter=/ 存在且相等 → 放行（回归：非空值行为不变）
    slash = alice(:get, "/#{bucket}", query: %{"list-type" => "2", "delimiter" => "/"}) |> call()
    assert slash.status == 200
    assert slash.resp_body =~ "<CommonPrefixes>"

    # delimiter=| 存在但不等 → IfExists 不豁免 → 拒绝（证明该算子在本项目里确实会因值不符而拒，
    # 即上面 empty 的 200 不是"这条 policy 恒放行"的假阳性）
    other = alice(:get, "/#{bucket}", query: %{"list-type" => "2", "delimiter" => "|"}) |> call()
    assert other.status == 403
    assert other.resp_body =~ "AccessDenied"
  end

  defp alice(method, path, opts) do
    SigV4Request.signed_conn(
      method,
      path,
      Keyword.merge([access_key: @alice_ak, secret: @alice_secret], opts)
    )
  end
end
