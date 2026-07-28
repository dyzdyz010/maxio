defmodule Maxio.S3.VersioningObjectTest do
  use Maxio.DataCase, async: false

  import Ecto.Query
  import Plug.Conn
  alias Maxio.{Objects.Object, Repo}
  alias Maxio.Test.SigV4Request
  alias Maxio.S3.Endpoint

  @data_dir Path.join(System.tmp_dir!(), "maxio_versioning_obj_test")

  setup do
    File.rm_rf(@data_dir)
    File.mkdir_p!(@data_dir)
    prev = Application.get_env(:maxio, :s3)
    Application.put_env(:maxio, :s3, Keyword.put(prev, :data_dir, @data_dir))

    on_exit(fn ->
      Application.put_env(:maxio, :s3, prev)
      File.rm_rf(@data_dir)
    end)

    :ok
  end

  defp call(conn), do: Endpoint.call(conn, Endpoint.init([]))

  defp touch_version(bucket, key, version_id, at) do
    from(o in Object,
      where: o.bucket_name == ^bucket and o.key == ^key and o.version_id == ^version_id
    )
    |> Repo.update_all(set: [inserted_at: at, updated_at: at])
  end

  defp set_index_generation(bucket, key, version_id, generation) do
    from(o in Object,
      where: o.bucket_name == ^bucket and o.key == ^key and o.version_id == ^version_id
    )
    |> Repo.update_all(set: [index_generation: generation])
  end

  defp enable_versioning(bucket) do
    body = ~s(<VersioningConfiguration><Status>Enabled</Status></VersioningConfiguration>)

    SigV4Request.signed_conn(:put, "/#{bucket}", query: %{"versioning" => ""}, body: body)
    |> call()
  end

  defp suspend_versioning(bucket) do
    body = ~s(<VersioningConfiguration><Status>Suspended</Status></VersioningConfiguration>)

    SigV4Request.signed_conn(:put, "/#{bucket}", query: %{"versioning" => ""}, body: body)
    |> call()
  end

  test "未版本化桶：PUT 不回 x-amz-version-id；GET 取当前" do
    SigV4Request.signed_conn(:put, "/uvb") |> call()
    put = SigV4Request.signed_conn(:put, "/uvb/k.txt", body: "v1") |> call()
    assert put.status == 200
    assert get_resp_header(put, "x-amz-version-id") == []
    get = SigV4Request.signed_conn(:get, "/uvb/k.txt") |> call()
    assert get.resp_body == "v1"
  end

  test "Enabled：两次 PUT 产生两个版本，latest 是第二个；?versionId 取旧版本" do
    SigV4Request.signed_conn(:put, "/verb") |> call()
    assert enable_versioning("verb").status == 200

    p1 = SigV4Request.signed_conn(:put, "/verb/k.txt", body: "first") |> call()
    assert p1.status == 200
    [vid1] = get_resp_header(p1, "x-amz-version-id")
    assert vid1 != "null"

    p2 = SigV4Request.signed_conn(:put, "/verb/k.txt", body: "second") |> call()
    [vid2] = get_resp_header(p2, "x-amz-version-id")
    assert vid2 != vid1

    latest = SigV4Request.signed_conn(:get, "/verb/k.txt") |> call()
    assert latest.resp_body == "second"
    assert get_resp_header(latest, "x-amz-version-id") == [vid2]

    old = SigV4Request.signed_conn(:get, "/verb/k.txt", query: %{"versionId" => vid1}) |> call()
    assert old.resp_body == "first"
    assert get_resp_header(old, "x-amz-version-id") == [vid1]
  end

  test "Enabled：简单 DELETE 插入 delete marker；后续 GET → 404 + x-amz-delete-marker" do
    SigV4Request.signed_conn(:put, "/delb") |> call()
    enable_versioning("delb")
    SigV4Request.signed_conn(:put, "/delb/k.txt", body: "data") |> call()

    del = SigV4Request.signed_conn(:delete, "/delb/k.txt") |> call()
    assert del.status == 204
    assert [_dm_vid] = get_resp_header(del, "x-amz-version-id")
    assert get_resp_header(del, "x-amz-delete-marker") == ["true"]

    get = SigV4Request.signed_conn(:get, "/delb/k.txt") |> call()
    assert get.status == 404
    assert get_resp_header(get, "x-amz-delete-marker") == ["true"]
  end

  test "Enabled：DELETE ?versionId 永久删该版本；删 delete marker 让旧版本重现" do
    SigV4Request.signed_conn(:put, "/perv") |> call()
    enable_versioning("perv")
    p1 = SigV4Request.signed_conn(:put, "/perv/k.txt", body: "alive") |> call()
    [vid1] = get_resp_header(p1, "x-amz-version-id")
    written_at = ~U[2026-06-28 00:00:00.000000Z]
    touch_version("perv", "k.txt", vid1, written_at)

    del = SigV4Request.signed_conn(:delete, "/perv/k.txt") |> call()
    [dm_vid] = get_resp_header(del, "x-amz-version-id")

    # 删 delete marker → 旧版本重现为 latest
    deldm =
      SigV4Request.signed_conn(:delete, "/perv/k.txt", query: %{"versionId" => dm_vid}) |> call()

    assert deldm.status == 204

    get = SigV4Request.signed_conn(:get, "/perv/k.txt") |> call()
    assert get.status == 200
    assert get.resp_body == "alive"
    assert get_resp_header(get, "x-amz-version-id") == [vid1]
    {:ok, restored} = Maxio.Objects.get_version("perv", "k.txt", vid1)
    assert DateTime.compare(restored.updated_at, written_at) == :eq
  end

  test "Enabled：删除 latest ULID 后按写入时间提升，不把历史 null 当最新" do
    bucket = "mixpromote"
    key = "k.txt"
    SigV4Request.signed_conn(:put, "/#{bucket}") |> call()

    legacy = SigV4Request.signed_conn(:put, "/#{bucket}/#{key}", body: "legacy-null") |> call()
    assert legacy.status == 200
    assert get_resp_header(legacy, "x-amz-version-id") == []

    assert enable_versioning(bucket).status == 200

    p1 = SigV4Request.signed_conn(:put, "/#{bucket}/#{key}", body: "version-one") |> call()
    [vid1] = get_resp_header(p1, "x-amz-version-id")

    p2 = SigV4Request.signed_conn(:put, "/#{bucket}/#{key}", body: "version-two") |> call()
    [vid2] = get_resp_header(p2, "x-amz-version-id")

    assert vid1 != "null"
    assert vid2 != "null"
    assert vid2 != vid1

    base = ~U[2026-06-28 00:00:00.000000Z]
    touch_version(bucket, key, "null", base)
    # 同一时间戳下也不能让历史 "null" 因字典序压过正常 ULID 版本。
    touch_version(bucket, key, vid1, base)
    touch_version(bucket, key, vid2, DateTime.add(base, 1, :second))
    set_index_generation(bucket, key, "null", 1)
    :ok = Maxio.Objects.put_tags(bucket, key, [{"edited", "yes"}], "null")

    del =
      SigV4Request.signed_conn(:delete, "/#{bucket}/#{key}", query: %{"versionId" => vid2})
      |> call()

    assert del.status == 204

    current = SigV4Request.signed_conn(:get, "/#{bucket}/#{key}") |> call()
    assert current.status == 200
    assert current.resp_body == "version-one"
    assert get_resp_header(current, "x-amz-version-id") == [vid1]

    null_version =
      SigV4Request.signed_conn(:get, "/#{bucket}/#{key}", query: %{"versionId" => "null"})
      |> call()

    assert null_version.status == 200
    assert null_version.resp_body == "legacy-null"
  end

  test "Suspended：DELETE 插入 null delete marker（替换 null 版本）；GET → 404" do
    SigV4Request.signed_conn(:put, "/suspok") |> call()
    assert suspend_versioning("suspok").status == 200
    put = SigV4Request.signed_conn(:put, "/suspok/k.txt", body: "to be replaced") |> call()
    assert put.status == 200

    del = SigV4Request.signed_conn(:delete, "/suspok/k.txt") |> call()
    assert del.status == 204
    assert get_resp_header(del, "x-amz-delete-marker") == ["true"]

    {:ok, row} = Maxio.Objects.get_version("suspok", "k.txt", "null")
    assert row.is_delete_marker == true
    assert row.is_latest == true

    get = SigV4Request.signed_conn(:get, "/suspok/k.txt") |> call()
    assert get.status == 404
    assert get_resp_header(get, "x-amz-delete-marker") == ["true"]
  end

  test "Suspended + :pg 写权威：PG marker 提交失败 → 500 且字节分毫未动（绝无撕裂态）" do
    SigV4Request.signed_conn(:put, "/susptorn") |> call()
    assert suspend_versioning("susptorn").status == 200
    put = SigV4Request.signed_conn(:put, "/susptorn/k.txt", body: "alive bytes") |> call()
    assert put.status == 200

    # 注入 PG 故障（sandbox 事务内 DDL，测试结束随事务回滚；失败查询经 sandbox savepoint 隔离，
    # 不毒化外层事务）：objects 表改名 → :pg 权威的权威提交 insert_delete_marker_with_id 必败。
    Repo.query!("ALTER TABLE objects RENAME TO objects_pg_down")
    del = SigV4Request.signed_conn(:delete, "/susptorn/k.txt") |> call()
    Repo.query!("ALTER TABLE objects_pg_down RENAME TO objects")

    # 权威提交失败 → 500（绝不静默吞），权威 PG 行原样存活（对象仍 live，非 delete marker）。
    assert del.status == 500
    {:ok, row} = Maxio.Objects.get_version("susptorn", "k.txt", "null")
    assert row.is_delete_marker == false
    assert row.is_latest == true

    # 关键取证：null 版本字节未被破坏——GET 仍 200 原文。
    # （修前：commit_delete_marker 在权威提交前先 Storage.delete 毁字节，PG 提交失败 = 永久撕裂态：
    #  权威 PG 说对象存活而字节已无 → GET 5xx。）
    get = SigV4Request.signed_conn(:get, "/susptorn/k.txt") |> call()
    assert get.status == 200
    assert get.resp_body == "alive bytes"
  end

  test "Enabled：GET ?versionId 指向 delete marker → 405" do
    SigV4Request.signed_conn(:put, "/mark") |> call()
    enable_versioning("mark")
    SigV4Request.signed_conn(:put, "/mark/k.txt", body: "x") |> call()
    del = SigV4Request.signed_conn(:delete, "/mark/k.txt") |> call()
    [dm_vid] = get_resp_header(del, "x-amz-version-id")

    get = SigV4Request.signed_conn(:get, "/mark/k.txt", query: %{"versionId" => dm_vid}) |> call()
    assert get.status == 405
    assert get_resp_header(get, "x-amz-delete-marker") == ["true"]
    assert get_resp_header(get, "allow") == ["DELETE"]
    assert [_] = get_resp_header(get, "last-modified")
  end

  test "Enabled：HEAD ?versionId 指向 delete marker → 405 + Allow DELETE" do
    SigV4Request.signed_conn(:put, "/headmark") |> call()
    enable_versioning("headmark")
    SigV4Request.signed_conn(:put, "/headmark/k.txt", body: "x") |> call()
    del = SigV4Request.signed_conn(:delete, "/headmark/k.txt") |> call()
    [dm_vid] = get_resp_header(del, "x-amz-version-id")

    head =
      SigV4Request.signed_conn(:head, "/headmark/k.txt", query: %{"versionId" => dm_vid})
      |> call()

    assert head.status == 405
    assert head.resp_body == ""
    assert get_resp_header(head, "x-amz-delete-marker") == ["true"]
    assert get_resp_header(head, "allow") == ["DELETE"]
    assert [_] = get_resp_header(head, "last-modified")
  end
end
