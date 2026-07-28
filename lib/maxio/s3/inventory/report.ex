defmodule Maxio.S3.Inventory.Report do
  @moduledoc """
  Local S3 Inventory report generator.

  The control-plane API stores InventoryConfiguration XML. This module performs
  one explicit report run, writing AWS-shaped manifest/checksum/data objects
  into the configured destination bucket through the normal Maxio object write
  path.
  """

  require Logger

  alias Maxio.{Buckets, ObjectMeta, Objects, Storage}
  alias Maxio.Cluster.Placement
  alias Maxio.ObjectMutation.Commit, as: ObjectMutationCommit
  alias Maxio.Objects.Object
  alias Maxio.S3.{Inventory, Log, SSE}
  alias Maxio.Storage.ObjectCommit.Control
  alias Maxio.Versioning.VersionId

  @chunk_size 1_048_576
  @default_max_keys 1_000
  @default_acl_grants %{"grants" => []}
  @manifest_version "2016-11-30"
  @csv_content_type "application/gzip"
  @json_content_type "application/json"
  @text_content_type "text/plain"

  @current_default_fields ~w(Bucket Key Size LastModifiedDate ETag StorageClass)
  @all_version_default_fields ~w(
    Bucket Key VersionId IsLatest IsDeleteMarker Size LastModifiedDate ETag StorageClass
  )
  @supported_optional_fields ~w(
    IsMultipartUploaded ReplicationStatus EncryptionStatus ObjectLockRetainUntilDate
    ObjectLockMode ObjectLockLegalHoldStatus ChecksumAlgorithm BucketKeyStatus
  )

  @checksum_algorithms %{
    "ChecksumCRC32" => "CRC32",
    "ChecksumCRC32C" => "CRC32C",
    "ChecksumCRC64NVME" => "CRC64NVME",
    "ChecksumMD5" => "MD5",
    "ChecksumSHA1" => "SHA1",
    "ChecksumSHA256" => "SHA256",
    "ChecksumSHA512" => "SHA512"
  }

  @type run_opts :: [
          bucket: String.t(),
          id: String.t(),
          dry_run: boolean(),
          now: DateTime.t(),
          report_date: Date.t() | String.t(),
          max_keys: pos_integer(),
          tmp_dir: Path.t(),
          run_id: String.t(),
          storage_opts: keyword(),
          file_id: String.t()
        ]

  @spec run(run_opts()) :: map()
  def run(opts \\ []) do
    opts = normalize_opts(opts)

    opts.bucket
    |> bucket_names()
    |> Enum.reduce(new_summary(opts), fn bucket, summary ->
      run_bucket(bucket, summary, opts)
    end)
  end

  defp normalize_opts(opts) do
    now = Keyword.get(opts, :now) || now_from_report_date(Keyword.get(opts, :report_date))

    %{
      bucket: blank_to_nil(Keyword.get(opts, :bucket)),
      id: blank_to_nil(Keyword.get(opts, :id)),
      dry_run: Keyword.get(opts, :dry_run, false),
      now: now || DateTime.utc_now(),
      max_keys: positive_integer(Keyword.get(opts, :max_keys), @default_max_keys),
      tmp_dir: Keyword.get(opts, :tmp_dir) || System.tmp_dir!(),
      run_id: blank_to_nil(Keyword.get(opts, :run_id)),
      storage_opts: Keyword.get(opts, :storage_opts, []),
      file_id: blank_to_nil(Keyword.get(opts, :file_id))
    }
  end

  defp now_from_report_date(nil), do: nil

  defp now_from_report_date(%Date{} = date) do
    DateTime.new!(date, ~T[00:00:00], "Etc/UTC")
  end

  defp now_from_report_date(date) when is_binary(date) do
    case Date.from_iso8601(date) do
      {:ok, parsed} -> now_from_report_date(parsed)
      {:error, _reason} -> nil
    end
  end

  defp bucket_names(nil), do: Buckets.list() |> Enum.map(& &1.name)
  defp bucket_names(bucket), do: [bucket]

  defp new_summary(opts) do
    %{
      dry_run: opts.dry_run,
      buckets_scanned: 0,
      configs_seen: 0,
      configs_matched: 0,
      configs_skipped_disabled: 0,
      configs_unsupported_format: 0,
      reports_attempted: 0,
      reports_written: 0,
      objects_written: 0,
      rows_written: 0,
      reports: [],
      errors: []
    }
  end

  defp run_bucket(bucket, summary, opts) do
    case Buckets.lookup(bucket) do
      {:ok, _bucket} ->
        configs = Inventory.all_configs(bucket)
        matched = maybe_filter_config_id(configs, opts.id)

        summary =
          summary
          |> inc(:buckets_scanned)
          |> inc(:configs_seen, length(configs))
          |> inc(:configs_matched, length(matched))

        summary =
          if opts.id && matched == [] do
            add_error(summary, bucket, opts.id, :inventory_config_not_found)
          else
            summary
          end

        Enum.reduce(matched, summary, fn config, acc ->
          run_config(bucket, config, acc, opts)
        end)

      {:error, :not_found} ->
        add_error(summary, bucket, opts.id, :source_bucket_missing)
    end
  rescue
    err ->
      add_error(summary, bucket, opts.id, err)
  end

  defp maybe_filter_config_id(configs, nil), do: configs
  defp maybe_filter_config_id(configs, id), do: Enum.filter(configs, &(&1["Id"] == id))

  defp run_config(source_bucket, config, summary, opts) do
    config = Inventory.normalize_config(config)
    inventory_id = config["Id"]

    cond do
      not config["IsEnabled"] ->
        inc(summary, :configs_skipped_disabled)

      destination(config)["Format"] != "CSV" ->
        Log.warn("inventory report skipped unsupported destination format",
          action: :inventory_report_run,
          bucket: source_bucket,
          inventory_id: inventory_id,
          format: destination(config)["Format"]
        )

        inc(summary, :configs_unsupported_format)

      unsupported_optional_fields(config) != [] ->
        add_error(
          summary,
          source_bucket,
          inventory_id,
          {:unsupported_optional_fields, unsupported_optional_fields(config)}
        )

      true ->
        summary = inc(summary, :reports_attempted)

        case build_report(source_bucket, config, opts) do
          {:ok, report} ->
            Log.info("inventory report generated",
              action: :inventory_report_run,
              bucket: source_bucket,
              inventory_id: inventory_id,
              destination_bucket: report.destination_bucket,
              manifest_key: report.manifest_key,
              rows: report.rows,
              dry_run: opts.dry_run
            )

            summary =
              if report.dry_run do
                summary
              else
                inc(summary, :reports_written)
              end

            summary
            |> inc(:objects_written, report.objects_written)
            |> inc(:rows_written, report.rows)
            |> append_report(report)

          {:error, reason} ->
            add_error(summary, source_bucket, inventory_id, reason)
        end
    end
  end

  defp build_report(source_bucket, config, opts) do
    dest = destination(config)

    with {:ok, destination_bucket} <- destination_bucket_name(dest["Bucket"]),
         {:ok, destination_info} <- Buckets.lookup(destination_bucket),
         {:ok, sse_target} <- destination_sse_target(destination_bucket, dest) do
      schema = schema_fields(config)
      base_root = report_base_root(dest["Prefix"], source_bucket, config["Id"])
      run_id = opts.run_id || random_file_id()
      run_root = base_root <> "/" <> report_timestamp(opts.now) <> "/" <> run_id
      file_id = opts.file_id || run_id
      data_key = base_root <> "/data/" <> run_id <> "/" <> file_id <> ".csv.gz"

      symlink_key =
        base_root <> "/hive/dt=" <> hive_timestamp(opts.now) <> "/" <> run_id <> "/symlink.txt"

      manifest_key = run_root <> "/manifest.json"
      checksum_key = run_root <> "/manifest.checksum"
      tmp_path = tmp_path(opts.tmp_dir, source_bucket, config["Id"], file_id)

      try do
        {rows, data_size, data_md5} =
          write_csv_gzip!(tmp_path, source_bucket, config, schema, opts)

        manifest =
          manifest_json(
            source_bucket,
            dest["Bucket"],
            data_key,
            data_size,
            data_md5,
            schema,
            opts.now
          )

        manifest_checksum = md5_hex(manifest) <> "\n"
        symlink_body = "s3://" <> destination_bucket <> "/" <> data_key <> "\n"

        report = %{
          source_bucket: source_bucket,
          inventory_id: config["Id"],
          destination_bucket: destination_bucket,
          destination_bucket_arn: dest["Bucket"],
          run_id: run_id,
          report_root: run_root,
          manifest_key: manifest_key,
          checksum_key: checksum_key,
          data_key: data_key,
          symlink_key: symlink_key,
          rows: rows,
          data_size: data_size,
          file_schema: Enum.join(schema, ", "),
          objects_written: 0,
          dry_run: opts.dry_run
        }

        if opts.dry_run do
          {:ok, report}
        else
          objects = [
            {:file, data_key, tmp_path, data_size, @csv_content_type, nil},
            {:binary, symlink_key, symlink_body, byte_size(symlink_body), @text_content_type,
             nil},
            {:binary, checksum_key, manifest_checksum, byte_size(manifest_checksum),
             @text_content_type, nil},
            {:binary, manifest_key, manifest, byte_size(manifest), @json_content_type, nil}
          ]

          with :ok <- ensure_safe_report_targets(destination_info, objects, opts),
               {:ok, written} <-
                 write_report_objects(
                   destination_info,
                   objects,
                   source_bucket,
                   sse_target,
                   opts
                 ) do
            {:ok,
             report
             |> Map.put(:objects_written, length(written))
             |> Map.put(:manifest_version_id, version_id_for_key(written, manifest_key))
             |> Map.put(:checksum_version_id, version_id_for_key(written, checksum_key))
             |> Map.put(:data_version_id, version_id_for_key(written, data_key))
             |> Map.put(:symlink_version_id, version_id_for_key(written, symlink_key))}
          end
          |> case do
            {:ok, report} ->
              {:ok, report}

            {:error, reason} ->
              {:error, reason}
          end
        end
      after
        _ = File.rm(tmp_path)
      end
    else
      {:error, :not_found} -> {:error, {:destination_bucket_missing, dest["Bucket"]}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp destination(config), do: get_in(config, ["Destination", "S3BucketDestination"]) || %{}

  defp destination_bucket_name("arn:aws:s3:::" <> rest) do
    bucket =
      rest
      |> String.split("/", parts: 2)
      |> List.first()

    if bucket in [nil, ""], do: {:error, :invalid_destination_bucket_arn}, else: {:ok, bucket}
  end

  defp destination_bucket_name(_bucket_arn), do: {:error, :invalid_destination_bucket_arn}

  defp destination_sse_target(destination_bucket, dest) do
    case Map.get(dest, "Encryption") do
      nil ->
        {:ok, SSE.resolve_target!([], destination_bucket)}

      %{"SSE-S3" => %{}} ->
        {:ok, "AES256"}

      %{"SSE-KMS" => %{"KeyId" => key_id}} when is_binary(key_id) and key_id != "" ->
        {:ok, {:kms, key_id, nil, false}}

      _other ->
        {:error, :unsupported_inventory_destination_encryption}
    end
  rescue
    err -> {:error, err}
  end

  defp schema_fields(%{"IncludedObjectVersions" => "All"} = config) do
    dedupe(@all_version_default_fields ++ Map.get(config, "OptionalFields", []))
  end

  defp schema_fields(config) do
    dedupe(@current_default_fields ++ Map.get(config, "OptionalFields", []))
  end

  defp unsupported_optional_fields(config) do
    supported =
      @current_default_fields ++ @all_version_default_fields ++ @supported_optional_fields

    config
    |> Map.get("OptionalFields", [])
    |> Enum.reject(&(&1 in supported))
  end

  defp dedupe(fields), do: Enum.reduce(fields, [], &append_unique/2)

  defp append_unique(field, acc) do
    if field in acc, do: acc, else: acc ++ [field]
  end

  defp report_base_root(prefix, source_bucket, inventory_id) do
    [prefix || "", source_bucket, inventory_id]
    |> Enum.flat_map(&s3_path_parts/1)
    |> Enum.join("/")
  end

  defp s3_path_parts(nil), do: []

  defp s3_path_parts(part) do
    part
    |> to_string()
    |> String.split("/", trim: true)
  end

  defp report_timestamp(%DateTime{} = now), do: Calendar.strftime(now, "%Y-%m-%dT%H-%MZ")
  defp hive_timestamp(%DateTime{} = now), do: Calendar.strftime(now, "%Y-%m-%d-%H-%M")

  defp random_file_id do
    12
    |> :crypto.strong_rand_bytes()
    |> Base.url_encode64(padding: false)
  end

  defp tmp_path(tmp_dir, source_bucket, inventory_id, file_id) do
    File.mkdir_p!(tmp_dir)
    Path.join(tmp_dir, "maxio-inventory-#{source_bucket}-#{inventory_id}-#{file_id}.csv.gz")
  end

  defp write_csv_gzip!(path, source_bucket, config, schema, opts) do
    z = :zlib.open()

    try do
      rows = write_gzip_rows!(path, z, source_bucket, config, schema, opts)
      {:ok, %{size: size}} = File.stat(path)
      {rows, size, file_md5_raw!(path)}
    after
      :zlib.close(z)
    end
  end

  defp write_gzip_rows!(path, z, source_bucket, config, schema, opts) do
    {:ok, file} = File.open(path, [:write, :binary])

    try do
      :ok = :zlib.deflateInit(z, :default, :deflated, 31, 8, :default)

      rows =
        source_bucket
        |> row_stream(config, opts)
        |> Enum.reduce(0, fn object, count ->
          chunk = object |> row_values(source_bucket, schema) |> csv_row()
          :ok = IO.binwrite(file, :zlib.deflate(z, chunk))
          count + 1
        end)

      :ok = IO.binwrite(file, :zlib.deflate(z, <<>>, :finish))
      :ok = :zlib.deflateEnd(z)
      rows
    after
      File.close(file)
    end
  end

  defp row_stream(source_bucket, config, opts) do
    prefix = get_in(config, ["Filter", "Prefix"]) || ""

    if config["IncludedObjectVersions"] == "All" do
      version_stream(source_bucket, prefix, opts)
    else
      current_stream(source_bucket, prefix, opts)
    end
  end

  defp current_stream(bucket, prefix, opts) do
    Stream.resource(
      fn -> nil end,
      fn
        :done ->
          {:halt, :done}

        continuation_token ->
          result =
            ObjectMeta.list(
              bucket,
              %{
                prefix: prefix,
                max_keys: opts.max_keys,
                continuation_token: continuation_token
              },
              opts.storage_opts
            )

          next = if result.is_truncated, do: result.next_continuation_token, else: :done
          {result.objects, next}
      end,
      fn _state -> :ok end
    )
  end

  defp version_stream(bucket, prefix, opts) do
    Stream.resource(
      fn -> {nil, nil} end,
      fn
        :done ->
          {:halt, :done}

        {key_marker, version_id_marker} ->
          result =
            ObjectMeta.list_versions(
              bucket,
              %{
                prefix: prefix,
                max_keys: opts.max_keys,
                key_marker: key_marker,
                version_id_marker: version_id_marker
              },
              opts.storage_opts
            )

          next =
            if result.is_truncated do
              {result.next_key_marker, result.next_version_id_marker}
            else
              :done
            end

          {result.versions, next}
      end,
      fn _state -> :ok end
    )
  end

  defp row_values(object, source_bucket, schema) do
    Enum.map(schema, &field_value(&1, object, source_bucket))
  end

  defp field_value("Bucket", _object, source_bucket), do: source_bucket

  defp field_value("Key", object, _source_bucket),
    do: object |> value(:key) |> encode_inventory_key()

  defp field_value("VersionId", object, _source_bucket), do: value(object, :version_id)
  defp field_value("IsLatest", object, _source_bucket), do: bool(value(object, :is_latest))

  defp field_value("IsDeleteMarker", object, _source_bucket),
    do: bool(value(object, :is_delete_marker))

  defp field_value("Size", object, _source_bucket), do: int(value(object, :size))

  defp field_value("LastModifiedDate", object, _source_bucket),
    do: iso8601(value(object, :updated_at))

  defp field_value("ETag", object, _source_bucket), do: value(object, :etag)

  defp field_value("StorageClass", object, _source_bucket),
    do: value(object, :storage_class) || "STANDARD"

  defp field_value("IsMultipartUploaded", object, _source_bucket),
    do: multipart?(object) |> bool()

  defp field_value("ReplicationStatus", object, _source_bucket),
    do: value(object, :replication_status)

  defp field_value("EncryptionStatus", object, _source_bucket), do: encryption_status(object)

  defp field_value("ObjectLockRetainUntilDate", object, _source_bucket),
    do: iso8601(value(object, :object_lock_retain_until))

  defp field_value("ObjectLockMode", object, _source_bucket), do: value(object, :object_lock_mode)

  defp field_value("ObjectLockLegalHoldStatus", object, _source_bucket),
    do: value(object, :object_lock_legal_hold)

  defp field_value("ChecksumAlgorithm", object, _source_bucket), do: checksum_algorithms(object)
  defp field_value("BucketKeyStatus", object, _source_bucket), do: bucket_key_status(object)
  defp field_value("ObjectAccessControlList", object, _source_bucket), do: acl_json(object)
  defp field_value("ObjectOwner", object, _source_bucket), do: owner(object)
  defp field_value(_field, _object, _source_bucket), do: ""

  defp encode_inventory_key(nil), do: ""
  defp encode_inventory_key(key), do: URI.encode(to_string(key), &URI.char_unreserved?/1)

  defp bool(true), do: "true"
  defp bool(false), do: "false"
  defp bool(_other), do: ""

  defp int(value) when is_integer(value), do: Integer.to_string(value)
  defp int(_value), do: ""

  defp iso8601(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp iso8601(nil), do: ""
  defp iso8601(value), do: to_string(value)

  defp multipart?(object) do
    case value(object, :object_parts) do
      %{} = parts -> map_size(parts) > 0
      _other -> false
    end
  end

  defp encryption_status(object) do
    case value(object, :sse_algorithm) do
      nil -> ""
      "AES256" -> "SSE-S3"
      "SSE-C" -> "SSE-C"
      "aws:kms" -> "SSE-KMS"
      "aws:kms:dsse" -> "DSSE-KMS"
      other -> other
    end
  end

  defp checksum_algorithms(object) do
    object
    |> SSE.visible_checksum_metadata()
    |> Map.keys()
    |> Enum.flat_map(fn field ->
      case Map.fetch(@checksum_algorithms, field) do
        {:ok, algorithm} -> [algorithm]
        :error -> []
      end
    end)
    |> Enum.uniq()
    |> Enum.join("|")
  end

  defp bucket_key_status(object) do
    envelope = value(object, :sse_envelope) || %{}

    if SSE.kms_bucket_key_enabled?(envelope), do: "ENABLED", else: ""
  end

  defp acl_json(object) do
    case value(object, :acl_grants) do
      %{} = grants -> Jason.encode!(grants)
      _other -> ""
    end
  end

  defp owner(%Object{bucket: %{owner: owner}}), do: owner
  defp owner(_object), do: ""

  defp value(%{} = map, key), do: Map.get(map, key)
  defp value(_object, _key), do: nil

  defp csv_row(values) do
    values
    |> Enum.map(&csv_cell/1)
    |> Enum.join(",")
    |> Kernel.<>("\n")
  end

  defp csv_cell(nil), do: "\"\""

  defp csv_cell(value) do
    escaped =
      value
      |> to_string()
      |> String.replace("\"", "\"\"")

    "\"" <> escaped <> "\""
  end

  defp file_md5_raw!(path) do
    ctx0 = :crypto.hash_init(:md5)

    path
    |> File.stream!([], @chunk_size)
    |> Enum.reduce(ctx0, fn chunk, ctx -> :crypto.hash_update(ctx, chunk) end)
    |> :crypto.hash_final()
  end

  defp md5_hex(data), do: :crypto.hash(:md5, data) |> Base.encode16(case: :lower)

  defp manifest_json(
         source_bucket,
         destination_bucket_arn,
         data_key,
         data_size,
         data_md5,
         schema,
         now
       ) do
    Jason.encode!(%{
      "sourceBucket" => source_bucket,
      "destinationBucket" => destination_bucket_arn,
      "version" => @manifest_version,
      "creationTimestamp" => DateTime.to_unix(now, :millisecond) |> Integer.to_string(),
      "fileFormat" => "CSV",
      "fileSchema" => Enum.join(schema, ", "),
      "files" => [
        %{
          "key" => data_key,
          "size" => data_size,
          "MD5checksum" => Base.encode16(data_md5, case: :lower)
        }
      ]
    }) <> "\n"
  end

  defp ensure_safe_report_targets(%{versioning: "Enabled"}, _objects, _opts), do: :ok

  defp ensure_safe_report_targets(destination_info, objects, opts) do
    Enum.reduce_while(objects, :ok, fn spec, :ok ->
      key = object_spec_key(spec)

      case report_target_state(destination_info.name, key, opts) do
        :missing -> {:cont, :ok}
        :exists -> {:halt, {:error, {:report_target_exists, key}}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp report_target_state(bucket, key, opts) do
    cond do
      metadata_report_target_exists?(bucket, key, opts) ->
        :exists

      true ->
        storage_report_target_state(bucket, key, opts)
    end
  end

  defp metadata_report_target_exists?(bucket, key, opts) do
    case ObjectMeta.get(bucket, key, nil, opts.storage_opts) do
      %Object{} -> true
      %{key: ^key} -> true
      _other -> false
    end
  end

  defp storage_report_target_state(bucket, key, opts) do
    case Storage.stat(bucket, key, "null", opts.storage_opts) do
      {:ok, _stat} -> :exists
      {:error, :enoent} -> :missing
      {:error, reason} -> {:error, {:report_target_stat_failed, key, reason}}
    end
  end

  defp object_spec_key({:file, key, _path, _size, _content_type, _content_encoding}), do: key

  defp object_spec_key({:binary, key, _body, _size, _content_type, _content_encoding}),
    do: key

  defp write_report_objects(destination_info, objects, source_bucket, sse_target, opts) do
    Enum.reduce_while(objects, {:ok, []}, fn object_spec, {:ok, written} ->
      case write_report_object(destination_info, object_spec, source_bucket, sse_target, opts) do
        {:ok, object} ->
          {:cont, {:ok, [object | written]}}

        {:error, reason} ->
          cleanup_written_objects(written, destination_info.name, opts)
          {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, written} -> {:ok, Enum.reverse(written)}
      {:error, reason} -> {:error, reason}
    end
  end

  # 公开仅为测试可直接驱动（绕过 ensure_safe_report_targets 预检模拟 TOCTOU 命中，
  # Phase 2A C2 验收断言 2）；生产路径唯一调用者是 write_report_objects/5。
  @doc false
  def write_report_object(destination_info, spec, source_bucket, sse_target, opts) do
    {key, stream, visible_size, content_type, content_encoding} =
      case spec do
        {:file, key, path, size, content_type, content_encoding} ->
          {key, File.stream!(path, [], @chunk_size), size, content_type, content_encoding}

        {:binary, key, body, size, content_type, content_encoding} ->
          {key, [body], size, content_type, content_encoding}
      end

    version_id = version_id_for(destination_info)

    case Maxio.Lock.with_object_lock({destination_info.name, key}, fn ->
           do_write_report_object(
             destination_info.name,
             key,
             version_id,
             stream,
             visible_size,
             content_type,
             content_encoding,
             source_bucket,
             sse_target,
             opts
           )
         end) do
      {:ok, result} -> result
      {:error, :locked} -> {:error, :locked}
    end
  end

  defp do_write_report_object(
         destination_bucket,
         key,
         version_id,
         stream,
         visible_size,
         content_type,
         content_encoding,
         source_bucket,
         sse_target,
         opts
       ) do
    {payload_stream, sse_attrs, sse_object_meta} = prepare_payload(stream, sse_target)

    object_meta =
      %{
        size: visible_size,
        content_type: content_type,
        content_encoding: content_encoding,
        storage_class: "STANDARD",
        user_metadata: %{"maxio-inventory-source-bucket" => source_bucket},
        acl_canned: "private",
        acl_grants: @default_acl_grants,
        tags: %{}
      }
      |> Map.merge(sse_object_meta)

    # 元数据 attrs 构造对两条提交路径同源（published_result 携 placement 快照）。
    committed_attrs = fn write_info, published_result ->
      %{
        size: visible_size,
        etag: write_info.etag,
        content_type: content_type,
        content_encoding: content_encoding,
        storage_class: "STANDARD",
        metadata: %{"maxio-inventory-source-bucket" => source_bucket},
        acl_canned: "private",
        acl_grants: @default_acl_grants,
        tags: %{}
      }
      |> Map.merge(sse_attrs)
      |> Map.merge(Placement.attrs_from_result(published_result))
      |> reject_nil_values()
    end

    # ObjectMutation Phase 2A（C2）：PG 写权威（默认）下每个 report object 独立 journal
    # （operation="generated_put"；journal 量 = 每次 run 固定 4 行，D2 裁决可忽略）。外层
    # write_report_object 已持对象锁——seam 在锁内直跑（D5）。:sidecar 写权威维持既有
    # 非协议路径逐字节不变（D1，协议化归 Phase 2B）。原「metadata 失败后 plain
    # Storage.delete + delete_version_index」回滚点（cleanup_report_object）随迁移删除，
    # 本对象的回滚由 seam restore 接管（unversioned 覆盖时旧对象逐字节恢复）。
    around_object_commit = fn write_info, publish ->
      case ObjectMeta.authoritative_source(:write, opts.storage_opts) do
        :sidecar ->
          commit_sidecar_report(
            destination_bucket,
            key,
            version_id,
            object_meta,
            committed_attrs,
            write_info,
            publish
          )

        _pg ->
          commit_pg_report(
            destination_bucket,
            key,
            version_id,
            object_meta,
            committed_attrs,
            write_info,
            publish,
            opts
          )
      end
    end

    put_opts =
      opts.storage_opts
      |> Keyword.put(:object_meta, object_meta)
      |> Keyword.put(:around_object_commit, around_object_commit)

    case Storage.put(destination_bucket, key, version_id, payload_stream, put_opts) do
      {:ok, %{} = write_result} ->
        {:ok, Map.fetch!(write_result, :around_object_commit_result)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp prepare_payload(stream, nil), do: {stream, %{}, %{}}

  defp prepare_payload(stream, "AES256") do
    {cipher_stream, envelope} = Maxio.Crypto.SSE.wrap_stream(stream)

    {cipher_stream, %{sse_algorithm: "AES256", sse_envelope: envelope},
     sse_meta("AES256", envelope)}
  end

  defp prepare_payload(stream, {:kms, key_id, context_b64, bucket_key_enabled}) do
    {cipher_stream, envelope} =
      Maxio.Crypto.SSE.wrap_stream_with_kms_key(stream, key_id, context_b64,
        bucket_key_enabled: bucket_key_enabled
      )

    {cipher_stream, %{sse_algorithm: "aws:kms", sse_envelope: envelope},
     sse_meta("aws:kms", envelope)}
  end

  defp prepare_payload(stream, {:kms_dsse, key_id, context_b64}) do
    {cipher_stream, envelope} =
      Maxio.Crypto.SSE.wrap_stream_with_dsse_kms_key(stream, key_id, context_b64)

    {cipher_stream, %{sse_algorithm: "aws:kms:dsse", sse_envelope: envelope},
     sse_meta("aws:kms:dsse", envelope)}
  end

  defp sse_meta(algo, envelope), do: %{sse: %{"algo" => algo, "envelope" => envelope}}

  # :sidecar 写权威（D1）：publish 即权威提交（盘上 sidecar 为事实来源），PG index
  # best-effort——失败仅记日志、绝不回删字节；行为与迁移前逐字节一致（协议化归 Phase 2B）。
  # rescue/catch 维持迁移前值语义（S3 语义错误如 hard quota 由 put_version_index 重抛）：
  # 转 {:error, err} 令本次 run abort，字节回滚交 ObjectCommit rollback（不再 plain delete）。
  defp commit_sidecar_report(
         destination_bucket,
         key,
         version_id,
         object_meta,
         committed_attrs,
         write_info,
         publish
       ) do
    case publish.(version_id: version_id, object_meta: object_meta) do
      {:ok, published_result} ->
        try do
          attrs = committed_attrs.(write_info, published_result)

          case Objects.put_version_index(destination_bucket, key, version_id, attrs) do
            :ok ->
              :ok

            {:error, reason} ->
              Logger.error("inventory report pg index update failed",
                action: :inventory_report_run,
                destination_bucket: destination_bucket,
                key: key,
                version_id: version_id,
                reason: inspect(reason)
              )
          end

          accelerate_mark_committed(write_info, destination_bucket, key, version_id)

          {:ok,
           Map.put(
             published_result,
             :around_object_commit_result,
             report_object(key, version_id, attrs, published_result)
           )}
        rescue
          err -> {:error, err}
        catch
          kind, reason -> {:error, {kind, reason}}
        end

      {:error, _reason} = error ->
        error
    end
  end

  # PG 写权威：ObjectMutation seam。metadata_tx = put_version_with_id +
  # Commit.transaction_hook(journal)——journal metadata_committed 与 PG row 同一事务，
  # CAS 失败整体回滚；publish 后 metadata 失败由 seam restore 收敛（旧对象恢复、backup
  # 保留），绝不 plain delete。metadata_tx 内 rescue/catch 转 {:error, err}（协议契约：
  # closure 不 raise），维持迁移前「单对象失败 → 本次 run abort 可重试」的值语义。
  defp commit_pg_report(
         destination_bucket,
         key,
         version_id,
         object_meta,
         committed_attrs,
         write_info,
         publish,
         opts
       ) do
    with :ok <- recheck_unversioned_report_target(destination_bucket, key, version_id) do
      plan = %{
        bucket: destination_bucket,
        key: key,
        version_id: version_id,
        operation: "generated_put",
        authority_mode: "pg",
        storage_opts: Keyword.merge(opts.storage_opts, Placement.storage_opts(write_info)),
        write_info: write_info,
        publish: fn extra_commit_opts ->
          publish.(
            Keyword.merge([version_id: version_id, object_meta: object_meta], extra_commit_opts)
          )
        end,
        metadata_tx: fn journal, published_result ->
          try do
            attrs = committed_attrs.(write_info, published_result)

            case Objects.put_version_with_id(destination_bucket, key, version_id, attrs,
                   transaction_hook: ObjectMutationCommit.transaction_hook(journal)
                 ) do
              {:ok, {%Object{} = object, :ok}} ->
                {:ok, report_object(key, object.version_id, attrs, published_result)}

              {:error, _reason} = error ->
                error
            end
          rescue
            err -> {:error, err}
          catch
            kind, reason -> {:error, {kind, reason}}
          end
        end
      }

      case ObjectMutationCommit.run(plan) do
        {:ok, %{published: published_result, metadata: report_obj}} ->
          {:ok, Map.put(published_result, :around_object_commit_result, report_obj)}

        {:error, _reason} = error ->
          error
      end
    end
  end

  # ensure_safe_report_targets 的锁内复检（TOCTOU 收窄，Phase 2A C2）：预检在对象锁外，
  # 预检通过与实际写入之间存在竞争窗口；此处已持锁、在 claim 之前对 unversioned 目标复检
  # PG 行不存在（Objects.get_version 同等检查），命中即 abort 本次 run（write_report_objects
  # 停机 + 既有 cleanup 语义），绝不覆盖已存在的报表目标。仅 PG 写权威路径生效（:sidecar
  # 分支逐字节不变，D1）。
  defp recheck_unversioned_report_target(destination_bucket, key, "null") do
    case Objects.get_version(destination_bucket, key, "null") do
      {:ok, %Object{is_delete_marker: false}} -> {:error, {:report_target_exists, key}}
      _other -> :ok
    end
  end

  defp recheck_unversioned_report_target(_destination_bucket, _key, _version_id), do: :ok

  # 与 do_put :sidecar 分支同构：metadata（best-effort index）完成后立即关闭进程内提交
  # 窗口——此后 publisher DOWN 不再触发字节回滚（sidecar 权威下 publish 已是提交点）。
  defp accelerate_mark_committed(write_info, destination_bucket, key, version_id) do
    case write_info
         |> Map.fetch!(:object_commit_control)
         |> Control.mark_committed() do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.error("object commit finalize failed after metadata commit",
          action: :inventory_report_run,
          destination_bucket: destination_bucket,
          key: key,
          version_id: version_id,
          commit_identity: Map.fetch!(write_info, :object_commit_identity),
          reason: inspect(reason)
        )
    end
  end

  defp report_object(key, version_id, attrs, write_result) do
    %{
      key: key,
      version_id: version_id,
      size: attrs.size,
      etag: attrs.etag,
      storage_opts: Placement.storage_opts(write_result)
    }
  end

  # 跨对象 run abort：对「先前已成功 finalize 的报表对象」执行正常 delete 清理（目标对象
  # journal 已 metadata_committed/finalized——metadata_committed 是 rollback 禁止线，不得
  # 也无法经 ObjectMutation seam 回滚）。这是对已提交对象的常规 delete 操作，其协议化
  # （durable tombstone）归 Phase 2B；与「publish 后 metadata 失败的 plain delete 回滚」
  # （已由 seam restore 取代、本文件不复存在）语义不同。
  defp cleanup_written_objects(written, bucket, opts) do
    Enum.each(written, fn object ->
      delete_opts = Keyword.merge(opts.storage_opts, object.storage_opts)

      case Storage.delete(bucket, object.key, object.version_id, delete_opts) do
        :ok ->
          case Objects.delete_version_index(bucket, object.key, object.version_id) do
            :ok ->
              :ok

            {:error, reason} ->
              Logger.error("inventory report partial write index cleanup failed",
                action: :inventory_report_run,
                destination_bucket: bucket,
                key: object.key,
                version_id: object.version_id,
                reason: inspect(reason)
              )
          end

        {:error, reason} ->
          Logger.error("inventory report partial write cleanup failed",
            action: :inventory_report_run,
            destination_bucket: bucket,
            key: object.key,
            version_id: object.version_id,
            reason: inspect(reason)
          )
      end
    end)
  end

  defp version_id_for_key(written, key) do
    case Enum.find(written, &(&1.key == key)) do
      nil -> nil
      object -> object.version_id
    end
  end

  defp version_id_for(%{versioning: "Enabled"}), do: VersionId.generate()
  defp version_id_for(_bucket), do: "null"

  defp reject_nil_values(map) do
    Map.reject(map, fn {_key, value} -> is_nil(value) end)
  end

  defp inc(summary, key, amount \\ 1), do: Map.update!(summary, key, &(&1 + amount))

  defp append_report(summary, report) do
    Map.update!(summary, :reports, &(&1 ++ [report]))
  end

  defp add_error(summary, bucket, inventory_id, reason) do
    Log.error("inventory report run failed",
      action: :inventory_report_run,
      bucket: bucket,
      inventory_id: inventory_id,
      reason: format_reason(reason)
    )

    error = %{
      bucket: bucket,
      inventory_id: inventory_id,
      reason: format_reason(reason)
    }

    Map.update!(summary, :errors, &(&1 ++ [error]))
  end

  defp format_reason(%{__struct__: _} = err) do
    Exception.message(err)
  rescue
    _other -> inspect(err)
  end

  defp format_reason(reason), do: inspect(reason)

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

  defp positive_integer(value, _default) when is_integer(value) and value > 0, do: value
  defp positive_integer(_value, default), do: default
end
