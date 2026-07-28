defmodule Maxio.Console.ObjectUploadTest do
  use Maxio.DataCase, async: false

  import ExUnit.CaptureLog

  alias Maxio.{BucketQuota, Buckets, Multipart, Objects, Sidecar, Storage}
  alias Maxio.Cluster.Paths
  alias Maxio.Console.ObjectUpload

  setup do
    bucket = "console-upload-#{System.unique_integer([:positive])}"

    data_dir =
      Path.join(System.tmp_dir!(), "maxio-console-upload-#{System.unique_integer([:positive])}")

    File.rm_rf!(data_dir)
    File.mkdir_p!(data_dir)
    {:ok, _bucket} = Buckets.create(bucket, "arn:aws:iam:::root")

    on_exit(fn -> File.rm_rf(data_dir) end)

    {:ok, bucket: bucket, data_dir: data_dir, storage_opts: [data_dir: data_dir]}
  end

  test "small uploads use single streaming PUT and commit metadata", %{
    bucket: bucket,
    storage_opts: storage_opts
  } do
    tmp_path = write_tmp_file("small-object", "hello")

    assert {:ok, object} =
             ObjectUpload.upload_tmp_file(
               bucket,
               "small.txt",
               "Unversioned",
               tmp_path,
               %{content_type: "text/plain"},
               storage_opts: storage_opts,
               multipart_threshold: 100,
               min_part_size: 1
             )

    assert object.size == 5
    assert object.content_type == "text/plain"
    refute String.contains?(object.etag, "-")
    assert Multipart.list_uploads(bucket, %{}).uploads == []
    assert {:ok, ^object} = Objects.get_metadata(bucket, "small.txt")
    assert_object_bytes(bucket, "small.txt", object.version_id, "hello", storage_opts)
  end

  test "large uploads use internal multipart and clean the upload session", %{
    bucket: bucket,
    data_dir: data_dir,
    storage_opts: storage_opts
  } do
    tmp_path = write_tmp_file("multipart-object", "AAABBBCC")

    assert {:ok, object} =
             ObjectUpload.upload_tmp_file(
               bucket,
               "large.txt",
               "Enabled",
               tmp_path,
               %{
                 content_type: "application/octet-stream",
                 tags: %{"project" => "console"}
               },
               storage_opts: storage_opts,
               multipart_threshold: 4,
               multipart_part_size: 1,
               max_multipart_parts: 3,
               min_part_size: 1
             )

    assert object.size == 8
    assert object.version_id != "null"
    assert String.ends_with?(object.etag, "-3")
    assert object.tags == %{"project" => "console"}
    assert Multipart.list_uploads(bucket, %{}).uploads == []
    assert_object_bytes(bucket, "large.txt", object.version_id, "AAABBBCC", storage_opts)

    assert %{"tags" => %{"project" => "console"}} =
             read_sidecar_entry(data_dir, bucket, "large.txt", object.version_id)
  end

  test "multipart metadata failure aborts session and removes committed bytes", %{
    storage_opts: storage_opts
  } do
    missing_bucket = "missing-console-upload-#{System.unique_integer([:positive])}"
    tmp_path = write_tmp_file("orphan-object", "AABBCC")

    assert {:error, :no_such_bucket} =
             ObjectUpload.upload_tmp_file(
               missing_bucket,
               "orphan.txt",
               "Unversioned",
               tmp_path,
               %{content_type: "application/octet-stream"},
               storage_opts: storage_opts,
               multipart_threshold: 4,
               multipart_part_size: 3,
               min_part_size: 1
             )

    assert Multipart.list_uploads(missing_bucket, %{}).uploads == []

    assert {:error, :enoent} =
             Storage.get(missing_bucket, "orphan.txt", "null", nil, storage_opts)
  end

  test "single upload quota failure returns error and removes committed bytes", %{
    bucket: bucket,
    storage_opts: storage_opts
  } do
    assert :ok = BucketQuota.put_hard(bucket, 3)
    tmp_path = write_tmp_file("single-quota-object", "1234")

    assert {:error, %Maxio.S3.Error{code: "XMinioAdminBucketQuotaExceeded"}} =
             ObjectUpload.upload_tmp_file(
               bucket,
               "quota-single.txt",
               "Unversioned",
               tmp_path,
               %{content_type: "application/octet-stream"},
               storage_opts: storage_opts,
               multipart_threshold: 100,
               min_part_size: 1
             )

    assert {:error, :not_found} = Objects.get_metadata(bucket, "quota-single.txt")
    assert {:error, :enoent} = Storage.get(bucket, "quota-single.txt", "null", nil, storage_opts)
  end

  # ObjectMutation Phase 2A（C4）：single put 迁入 Commit seam 后 quota 在 claim/publish
  # 之前 fail-closed（do_put 同构预检），不再存在「metadata 失败后 plain Storage.delete」
  # 回滚点——即使 delete 后端注入失败也零孤儿字节（迁移前本用例断言 cleanup 失败日志 +
  # 字节残留，该机制已随 cleanup_uploaded_object single-put 分支删除）。
  test "single upload quota failure needs no rollback delete even with broken delete backend",
       %{
         bucket: bucket,
         storage_opts: storage_opts
       } do
    with_storage_backend(Maxio.Test.StorageDeleteErrorBackend, fn ->
      assert :ok = BucketQuota.put_hard(bucket, 3)
      tmp_path = write_tmp_file("single-quota-cleanup-fail-object", "1234")

      log =
        capture_log([level: :error], fn ->
          result =
            ObjectUpload.upload_tmp_file(
              bucket,
              "quota-single-cleanup-fail.txt",
              "Unversioned",
              tmp_path,
              %{content_type: "application/octet-stream"},
              storage_opts: storage_opts,
              multipart_threshold: 100,
              min_part_size: 1
            )

          send(self(), {:upload_result, result})
        end)

      assert_receive {:upload_result,
                      {:error, %Maxio.S3.Error{code: "XMinioAdminBucketQuotaExceeded"}}}

      assert log =~ "[maxio][Console] upload failed"
      assert {:error, :not_found} = Objects.get_metadata(bucket, "quota-single-cleanup-fail.txt")

      assert {:error, :enoent} =
               Storage.get(bucket, "quota-single-cleanup-fail.txt", "null", nil, storage_opts)
    end)
  end

  test "multipart upload quota failure cleans final bytes and terminal session", %{
    bucket: bucket,
    storage_opts: storage_opts
  } do
    assert :ok = BucketQuota.put_hard(bucket, 3)
    tmp_path = write_tmp_file("multipart-quota-object", "123456")

    assert {:error, %Maxio.S3.Error{code: "XMinioAdminBucketQuotaExceeded"}} =
             ObjectUpload.upload_tmp_file(
               bucket,
               "quota-multipart.txt",
               "Unversioned",
               tmp_path,
               %{content_type: "application/octet-stream"},
               storage_opts: storage_opts,
               multipart_threshold: 2,
               multipart_part_size: 2,
               min_part_size: 1
             )

    assert Multipart.list_uploads(bucket, %{}).uploads == []
    assert {:error, :not_found} = Objects.get_metadata(bucket, "quota-multipart.txt")

    assert {:error, :enoent} =
             Storage.get(bucket, "quota-multipart.txt", "null", nil, storage_opts)
  end

  test "multipart upload logs final object cleanup failure without hiding quota error", %{
    bucket: bucket,
    storage_opts: storage_opts
  } do
    with_storage_backend(Maxio.Test.StorageDeleteErrorBackend, fn ->
      assert :ok = BucketQuota.put_hard(bucket, 3)
      tmp_path = write_tmp_file("multipart-quota-cleanup-fail-object", "123456")

      log =
        capture_log([level: :error], fn ->
          result =
            ObjectUpload.upload_tmp_file(
              bucket,
              "quota-multipart-cleanup-fail.txt",
              "Unversioned",
              tmp_path,
              %{content_type: "application/octet-stream"},
              storage_opts: storage_opts,
              multipart_threshold: 2,
              multipart_part_size: 2,
              min_part_size: 1
            )

          send(self(), {:upload_result, result})
        end)

      assert_receive {:upload_result,
                      {:error, %Maxio.S3.Error{code: "XMinioAdminBucketQuotaExceeded"}}}

      assert log =~ "[maxio][Console] upload orphan bytes cleanup failed after metadata rollback"
      assert log =~ "injected_delete_failure"
      assert Multipart.list_uploads(bucket, %{}).uploads == []

      assert {:ok, _stream} =
               Storage.get(bucket, "quota-multipart-cleanup-fail.txt", "null", nil, storage_opts)
    end)
  end

  defp write_tmp_file(name, content) do
    path = Path.join(System.tmp_dir!(), "#{name}-#{System.unique_integer([:positive])}")
    File.write!(path, content)
    path
  end

  defp assert_object_bytes(bucket, key, version_id, expected, storage_opts) do
    assert {:ok, stream} = Storage.get(bucket, key, version_id, nil, storage_opts)
    assert IO.iodata_to_binary(Enum.to_list(stream)) == expected
  end

  defp read_sidecar_entry(data_dir, bucket, key, version_id) do
    {:ok, rel} = Paths.encode_key(key)

    meta_path =
      if version_id == "null" do
        Path.join([data_dir, bucket, rel, "meta.json"])
      else
        Path.join([data_dir, ".versions", bucket, rel, version_id, "meta.json"])
      end

    meta_path
    |> File.read!()
    |> Sidecar.decode!()
    |> Sidecar.find_version(version_id)
  end

  defp with_storage_backend(backend, fun) do
    previous = Application.get_env(:maxio, :storage_backend)
    Application.put_env(:maxio, :storage_backend, backend)

    try do
      fun.()
    after
      Application.put_env(:maxio, :storage_backend, previous)
    end
  end
end
