defmodule Maxio.S3.InventoryReportTest do
  use Maxio.DataCase, async: false

  import ExUnit.CaptureIO

  alias Maxio.BucketConfigs
  alias Maxio.Cluster.Placement
  alias Maxio.Crypto.SSE
  alias Maxio.ObjectMeta
  alias Maxio.S3.Endpoint
  alias Maxio.S3.Inventory
  alias Maxio.S3.Inventory.Report
  alias Maxio.Storage
  alias Maxio.Test.SigV4Request

  @data_dir Path.join(System.tmp_dir!(), "maxio_inventory_report")
  @now ~U[2026-06-30 00:00:00Z]

  setup do
    File.rm_rf(@data_dir)
    File.mkdir_p!(@data_dir)

    prev = Application.get_env(:maxio, :s3)
    Application.put_env(:maxio, :s3, Keyword.put(prev, :data_dir, @data_dir))

    on_exit(fn ->
      Application.put_env(:maxio, :s3, prev)
      File.rm_rf(@data_dir)
      Mix.Task.reenable("maxio.inventory.run")
    end)

    :ok
  end

  test "generates current-version CSV gzip data manifest checksum and hive symlink" do
    assert create_bucket("inv-current") == 200
    assert create_bucket("inv-dest") == 200
    assert put_object("inv-current", "docs/a.txt", "alpha") == 200
    assert put_object("inv-current", "logs/b.txt", "bravo") == 200

    put_inventory_config!("inv-current", %{
      "Id" => "daily",
      "Destination" => destination("inv-dest", "reports/"),
      "IsEnabled" => true,
      "Filter" => %{"Prefix" => "docs/"},
      "IncludedObjectVersions" => "Current",
      "OptionalFields" => ["ChecksumAlgorithm"],
      "Schedule" => %{"Frequency" => "Daily"}
    })

    summary =
      Report.run(
        bucket: "inv-current",
        id: "daily",
        now: @now,
        run_id: "run-1",
        file_id: "part-1"
      )

    assert summary.errors == []
    assert summary.reports_written == 1
    assert summary.objects_written == 4
    assert summary.rows_written == 1

    report = hd(summary.reports)
    assert report.run_id == "run-1"
    assert report.data_key == "reports/inv-current/daily/data/run-1/part-1.csv.gz"

    assert report.manifest_key ==
             "reports/inv-current/daily/2026-06-30T00-00Z/run-1/manifest.json"

    assert report.checksum_key ==
             "reports/inv-current/daily/2026-06-30T00-00Z/run-1/manifest.checksum"

    assert report.symlink_key ==
             "reports/inv-current/daily/hive/dt=2026-06-30-00-00/run-1/symlink.txt"

    csv = read_object!("inv-dest", report.data_key) |> :zlib.gunzip()
    [row] = csv |> String.trim_trailing("\n") |> String.split("\n")
    fields = parse_csv_row(row)

    assert Enum.at(fields, 0) == "inv-current"
    assert Enum.at(fields, 1) == "docs%2Fa.txt"
    assert Enum.at(fields, 2) == "5"
    assert Enum.at(fields, 5) == "STANDARD"
    assert Enum.at(fields, 6) == "CRC64NVME"

    manifest = read_object!("inv-dest", report.manifest_key)
    checksum = read_object!("inv-dest", report.checksum_key)
    symlink = read_object!("inv-dest", report.symlink_key)

    assert checksum == md5_hex(manifest) <> "\n"
    assert symlink == "s3://inv-dest/#{report.data_key}\n"

    decoded = Jason.decode!(manifest)
    assert decoded["sourceBucket"] == "inv-current"
    assert decoded["destinationBucket"] == "arn:aws:s3:::inv-dest"
    assert decoded["fileFormat"] == "CSV"

    assert decoded["fileSchema"] ==
             "Bucket, Key, Size, LastModifiedDate, ETag, StorageClass, ChecksumAlgorithm"

    assert [%{"key" => data_key, "size" => size, "MD5checksum" => data_md5_hex}] =
             decoded["files"]

    assert data_key == report.data_key
    assert size == report.data_size

    assert data_md5_hex == md5_hex(read_object!("inv-dest", report.data_key))
  end

  test "all-version report includes delete markers and version columns" do
    assert create_bucket("inv-all") == 200
    assert create_bucket("inv-all-dest") == 200
    assert put_versioning("inv-all") == 200
    assert put_object("inv-all", "docs/a.txt", "one") == 200
    assert put_object("inv-all", "docs/a.txt", "two") == 200
    assert put_object("inv-all", "docs/deleted.txt", "gone") == 200
    assert delete_object("inv-all", "docs/deleted.txt") == 204

    put_inventory_config!("inv-all", %{
      "Id" => "all",
      "Destination" => destination("inv-all-dest", "inventory/"),
      "IsEnabled" => true,
      "Filter" => %{"Prefix" => "docs/"},
      "IncludedObjectVersions" => "All",
      "OptionalFields" => ["IsMultipartUploaded"],
      "Schedule" => %{"Frequency" => "Daily"}
    })

    summary = Report.run(bucket: "inv-all", id: "all", now: @now, file_id: "versions")

    assert summary.errors == []
    assert summary.rows_written == 4

    report = hd(summary.reports)
    csv = read_object!("inv-all-dest", report.data_key) |> :zlib.gunzip()
    rows = csv |> String.trim_trailing("\n") |> String.split("\n") |> Enum.map(&parse_csv_row/1)

    assert Enum.all?(rows, &(Enum.at(&1, 0) == "inv-all"))
    assert Enum.count(rows, &(Enum.at(&1, 1) == "docs%2Fa.txt")) == 2

    assert Enum.any?(rows, fn row ->
             Enum.at(row, 1) == "docs%2Fdeleted.txt" and
               Enum.at(row, 3) == "true" and
               Enum.at(row, 4) == "true"
           end)

    manifest = read_object!("inv-all-dest", report.manifest_key) |> Jason.decode!()

    assert manifest["fileSchema"] ==
             "Bucket, Key, VersionId, IsLatest, IsDeleteMarker, Size, LastModifiedDate, ETag, StorageClass, IsMultipartUploaded"
  end

  test "report scan paginates with small max_keys and accepts omitted destination AccountId" do
    assert create_bucket("inv-page") == 200
    assert create_bucket("inv-page-dest") == 200

    for key <- ["docs/a.txt", "docs/b.txt", "docs/c.txt"] do
      assert put_object("inv-page", key, key) == 200
    end

    put_inventory_config!("inv-page", %{
      "Id" => "daily",
      "Destination" => destination_without_account("inv-page-dest", "reports/"),
      "IsEnabled" => true,
      "Filter" => %{"Prefix" => "docs/"},
      "IncludedObjectVersions" => "Current",
      "Schedule" => %{"Frequency" => "Daily"}
    })

    {:ok, stored} = Inventory.get_config("inv-page", "daily")
    refute Map.has_key?(get_in(stored, ["Destination", "S3BucketDestination"]), "AccountId")

    summary =
      Report.run(
        bucket: "inv-page",
        id: "daily",
        now: @now,
        run_id: "page-run",
        max_keys: 1
      )

    assert summary.errors == []
    assert summary.rows_written == 3

    report = hd(summary.reports)
    csv = read_object!("inv-page-dest", report.data_key) |> :zlib.gunzip()
    rows = csv |> String.trim_trailing("\n") |> String.split("\n") |> Enum.map(&parse_csv_row/1)

    assert Enum.map(rows, &Enum.at(&1, 1)) == ["docs%2Fa.txt", "docs%2Fb.txt", "docs%2Fc.txt"]
  end

  test "destination default SSE and explicit SSE-KMS encrypt report objects" do
    assert create_bucket("inv-sse") == 200
    assert create_bucket("inv-sse-default-dest") == 200
    assert create_bucket("inv-sse-kms-dest") == 200
    assert put_object("inv-sse", "docs/a.txt", "alpha") == 200

    :ok = BucketConfigs.put("inv-sse-default-dest", :encryption, %{"algorithm" => "AES256"})

    put_inventory_config!("inv-sse", %{
      "Id" => "default-sse",
      "Destination" => destination("inv-sse-default-dest", "reports/"),
      "IsEnabled" => true,
      "Filter" => %{"Prefix" => "docs/"},
      "IncludedObjectVersions" => "Current",
      "Schedule" => %{"Frequency" => "Daily"}
    })

    put_inventory_config!("inv-sse", %{
      "Id" => "kms-sse",
      "Destination" =>
        destination("inv-sse-kms-dest", "reports/")
        |> put_in(
          ["S3BucketDestination", "Encryption"],
          %{"SSE-KMS" => %{"KeyId" => "alias/inventory-report"}}
        ),
      "IsEnabled" => true,
      "Filter" => %{"Prefix" => "docs/"},
      "IncludedObjectVersions" => "Current",
      "Schedule" => %{"Frequency" => "Daily"}
    })

    default_summary =
      Report.run(bucket: "inv-sse", id: "default-sse", now: @now, run_id: "default-sse")

    kms_summary = Report.run(bucket: "inv-sse", id: "kms-sse", now: @now, run_id: "kms-sse")

    assert default_summary.errors == []
    assert kms_summary.errors == []

    default_report = hd(default_summary.reports)
    kms_report = hd(kms_summary.reports)

    default_object = ObjectMeta.get("inv-sse-default-dest", default_report.data_key)
    kms_object = ObjectMeta.get("inv-sse-kms-dest", kms_report.data_key)

    assert default_object.sse_algorithm == "AES256"
    assert kms_object.sse_algorithm == "aws:kms"
    assert kms_object.sse_envelope["kms_key_id"] == "alias/inventory-report"

    default_plain = read_object!("inv-sse-default-dest", default_report.data_key)
    kms_plain = read_object!("inv-sse-kms-dest", kms_report.data_key)

    assert default_plain |> :zlib.gunzip() |> String.contains?("docs%2Fa.txt")
    assert kms_plain |> :zlib.gunzip() |> String.contains?("docs%2Fa.txt")
    refute read_raw_object!("inv-sse-default-dest", default_report.data_key) == default_plain
    refute read_raw_object!("inv-sse-kms-dest", kms_report.data_key) == kms_plain
  end

  test "unversioned rerun with same run id fails closed without replacing prior report" do
    assert create_bucket("inv-rerun") == 200
    assert create_bucket("inv-rerun-dest") == 200
    assert put_object("inv-rerun", "docs/a.txt", "alpha") == 200

    put_inventory_config!("inv-rerun", %{
      "Id" => "daily",
      "Destination" => destination("inv-rerun-dest", "reports/"),
      "IsEnabled" => true,
      "Filter" => %{"Prefix" => "docs/"},
      "IncludedObjectVersions" => "Current",
      "Schedule" => %{"Frequency" => "Daily"}
    })

    first =
      Report.run(
        bucket: "inv-rerun",
        id: "daily",
        now: @now,
        run_id: "same-run",
        file_id: "same-file"
      )

    assert first.errors == []
    first_report = hd(first.reports)
    first_manifest = read_object!("inv-rerun-dest", first_report.manifest_key)

    assert put_object("inv-rerun", "docs/a.txt", "changed") == 200

    second =
      Report.run(
        bucket: "inv-rerun",
        id: "daily",
        now: @now,
        run_id: "same-run",
        file_id: "same-file"
      )

    assert [%{reason: reason}] = second.errors
    assert reason =~ "report_target_exists"
    assert read_object!("inv-rerun-dest", first_report.manifest_key) == first_manifest
  end

  test "unversioned target collision checks storage even when metadata index is missing" do
    assert create_bucket("inv-stat") == 200
    assert create_bucket("inv-stat-dest") == 200
    assert put_object("inv-stat", "docs/a.txt", "alpha") == 200

    put_inventory_config!("inv-stat", %{
      "Id" => "daily",
      "Destination" => destination("inv-stat-dest", "reports/"),
      "IsEnabled" => true,
      "Filter" => %{"Prefix" => "docs/"},
      "IncludedObjectVersions" => "Current",
      "Schedule" => %{"Frequency" => "Daily"}
    })

    existing_key = "reports/inv-stat/daily/data/same-run/same-file.csv.gz"
    assert {:ok, _result} = Storage.put("inv-stat-dest", existing_key, "null", ["old-report"])
    assert ObjectMeta.get("inv-stat-dest", existing_key) in [nil, {:error, :not_found}]

    summary =
      Report.run(
        bucket: "inv-stat",
        id: "daily",
        now: @now,
        run_id: "same-run",
        file_id: "same-file"
      )

    assert [%{reason: reason}] = summary.errors
    assert reason =~ "report_target_exists"
    assert read_storage_object!("inv-stat-dest", existing_key, "null") == "old-report"
  end

  test "partial report write failure cleans objects from the failed run" do
    assert create_bucket("inv-fail") == 200
    assert create_bucket("inv-fail-dest") == 200
    assert put_object("inv-fail", "docs/a.txt", "alpha") == 200

    put_inventory_config!("inv-fail", %{
      "Id" => "daily",
      "Destination" => destination("inv-fail-dest", "reports/"),
      "IsEnabled" => true,
      "Filter" => %{"Prefix" => "docs/"},
      "IncludedObjectVersions" => "Current",
      "Schedule" => %{"Frequency" => "Daily"}
    })

    with_storage_backend(Maxio.Test.StorageInventoryManifestFailBackend, fn ->
      summary = Report.run(bucket: "inv-fail", id: "daily", now: @now, run_id: "fail-run")

      assert [%{reason: reason}] = summary.errors
      assert reason =~ "injected_manifest_put_failure"
    end)

    assert ObjectMeta.list("inv-fail-dest", %{prefix: "reports/inv-fail/daily/"}).objects == []
  end

  test "dry-run computes rows without writing report objects" do
    assert create_bucket("inv-dry") == 200
    assert create_bucket("inv-dry-dest") == 200
    assert put_object("inv-dry", "docs/a.txt", "alpha") == 200

    put_inventory_config!("inv-dry", %{
      "Id" => "daily",
      "Destination" => destination("inv-dry-dest", "reports/"),
      "IsEnabled" => true,
      "IncludedObjectVersions" => "Current",
      "Schedule" => %{"Frequency" => "Daily"}
    })

    summary =
      Report.run(bucket: "inv-dry", id: "daily", now: @now, file_id: "dry", dry_run: true)

    assert summary.reports_written == 0
    assert summary.objects_written == 0
    assert summary.rows_written == 1
    assert ObjectMeta.list("inv-dry-dest", %{prefix: "reports/"}).objects == []
  end

  test "unsupported formats and optional fields fail closed without report objects" do
    assert create_bucket("inv-bad") == 200
    assert create_bucket("inv-bad-dest") == 200
    assert put_object("inv-bad", "a.txt", "alpha") == 200

    put_inventory_config!("inv-bad", %{
      "Id" => "orc",
      "Destination" => destination("inv-bad-dest", "reports/", "ORC"),
      "IsEnabled" => true,
      "IncludedObjectVersions" => "Current",
      "Schedule" => %{"Frequency" => "Daily"}
    })

    put_inventory_config!("inv-bad", %{
      "Id" => "lifecycle",
      "Destination" => destination("inv-bad-dest", "reports/"),
      "IsEnabled" => true,
      "IncludedObjectVersions" => "Current",
      "OptionalFields" => ["LifecycleExpirationDate"],
      "Schedule" => %{"Frequency" => "Daily"}
    })

    summary = Report.run(bucket: "inv-bad", now: @now, file_id: "bad")

    assert summary.configs_unsupported_format == 1
    assert [%{inventory_id: "lifecycle", reason: reason}] = summary.errors
    assert reason =~ "unsupported_optional_fields"
    assert summary.reports_written == 0
    assert ObjectMeta.list("inv-bad-dest", %{prefix: "reports/"}).objects == []
  end

  test "mix task prints a json dry-run summary" do
    assert create_bucket("inv-task") == 200
    assert create_bucket("inv-task-dest") == 200
    assert put_object("inv-task", "a.txt", "alpha") == 200

    put_inventory_config!("inv-task", %{
      "Id" => "daily",
      "Destination" => destination("inv-task-dest", "reports/"),
      "IsEnabled" => true,
      "IncludedObjectVersions" => "Current",
      "Schedule" => %{"Frequency" => "Daily"}
    })

    Mix.Task.reenable("maxio.inventory.run")

    output =
      capture_io(fn ->
        Mix.Task.run("maxio.inventory.run", [
          "--bucket",
          "inv-task",
          "--id",
          "daily",
          "--report-date",
          "2026-06-30",
          "--dry-run",
          "--json"
        ])
      end)

    summary = Jason.decode!(output)
    assert summary["dry_run"] == true
    assert summary["rows_written"] == 1
    assert summary["reports_written"] == 0
  end

  defp call(conn), do: Endpoint.call(conn, Endpoint.init([]))

  defp create_bucket(bucket) do
    SigV4Request.signed_conn(:put, "/#{bucket}") |> call() |> Map.fetch!(:status)
  end

  defp put_object(bucket, key, body) do
    SigV4Request.signed_conn(:put, "/#{bucket}/#{key}", body: body)
    |> call()
    |> Map.fetch!(:status)
  end

  defp delete_object(bucket, key) do
    SigV4Request.signed_conn(:delete, "/#{bucket}/#{key}")
    |> call()
    |> Map.fetch!(:status)
  end

  defp put_versioning(bucket) do
    body = "<VersioningConfiguration><Status>Enabled</Status></VersioningConfiguration>"

    SigV4Request.signed_conn(:put, "/#{bucket}",
      query: %{"versioning" => ""},
      body: body
    )
    |> call()
    |> Map.fetch!(:status)
  end

  defp put_inventory_config!(bucket, config), do: :ok = Inventory.put_config(bucket, config)

  defp destination(bucket, prefix, format \\ "CSV") do
    %{
      "S3BucketDestination" => %{
        "AccountId" => "000000000000",
        "Bucket" => "arn:aws:s3:::" <> bucket,
        "Format" => format,
        "Prefix" => prefix
      }
    }
  end

  defp destination_without_account(bucket, prefix, format \\ "CSV") do
    %{
      "S3BucketDestination" => %{
        "Bucket" => "arn:aws:s3:::" <> bucket,
        "Format" => format,
        "Prefix" => prefix
      }
    }
  end

  defp read_object!(bucket, key) do
    object = ObjectMeta.get(bucket, key)

    bucket
    |> read_raw_object!(key, object)
    |> decrypt_body(object)
  end

  defp read_raw_object!(bucket, key) do
    object = ObjectMeta.get(bucket, key)
    read_raw_object!(bucket, key, object)
  end

  defp read_raw_object!(bucket, key, object) do
    {:ok, stream} =
      Storage.get(bucket, key, object.version_id, nil, Placement.storage_opts(object))

    IO.iodata_to_binary(Enum.to_list(stream))
  end

  defp read_storage_object!(bucket, key, version_id) do
    {:ok, stream} = Storage.get(bucket, key, version_id, nil, [])
    IO.iodata_to_binary(Enum.to_list(stream))
  end

  defp decrypt_body(body, %{sse_algorithm: nil}), do: body

  defp decrypt_body(body, %{sse_algorithm: "AES256", sse_envelope: envelope}) do
    [body] |> SSE.unwrap_stream(envelope) |> Enum.to_list() |> IO.iodata_to_binary()
  end

  defp decrypt_body(body, %{sse_algorithm: "aws:kms", sse_envelope: envelope}) do
    [body] |> SSE.unwrap_stream_with_kms_key(envelope) |> Enum.to_list() |> IO.iodata_to_binary()
  end

  defp decrypt_body(body, %{sse_algorithm: "aws:kms:dsse", sse_envelope: envelope}) do
    [body]
    |> SSE.unwrap_stream_with_dsse_kms_key(envelope)
    |> Enum.to_list()
    |> IO.iodata_to_binary()
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

  defp parse_csv_row(row) do
    row
    |> String.trim_leading("\"")
    |> String.trim_trailing("\"")
    |> String.split("\",\"")
  end

  defp md5_hex(body), do: :crypto.hash(:md5, body) |> Base.encode16(case: :lower)
end
