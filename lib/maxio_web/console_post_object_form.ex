defmodule MaxioWeb.ConsolePostObjectForm do
  @moduledoc """
  Console helpers for generating signed S3 POST Object HTML snippets.

  The data-plane parser treats POST form fields as PutObject headers, so this
  module keeps the UI-generated field set explicit and validates it before the
  SigV4 POST policy is signed.
  """

  import Phoenix.Component, only: [to_form: 2]

  alias Maxio.Metadata
  alias Maxio.Policy.ACL
  alias Maxio.S3.{ExpectedBucketOwner, StorageClass}
  alias Maxio.S3.Views.Tagging
  alias Maxio.Tags

  @max_expires 43_200
  @max_object_size 5_368_709_120
  @max_field_value_size 4_096
  @content_md5_bytes 16
  @success_statuses ~w(200 201 204)
  @success_status_options [{"201", "201"}, {"204", "204"}, {"200", "200"}]
  @sse_customer_key_bytes 32
  @acl_options [
    {"None", ""},
    {"private", "private"},
    {"public-read", "public-read"},
    {"public-read-write", "public-read-write"},
    {"authenticated-read", "authenticated-read"},
    {"bucket-owner-read", "bucket-owner-read"},
    {"bucket-owner-full-control", "bucket-owner-full-control"},
    {"aws-exec-read", "aws-exec-read"},
    {"log-delivery-write", "log-delivery-write"}
  ]
  @sse_algorithm_options [
    {"None", ""},
    {"AES256", "AES256"},
    {"aws:kms", "aws:kms"},
    {"aws:kms:dsse", "aws:kms:dsse"}
  ]
  @checksum_algorithm_options [
    {"None", ""},
    {"CRC32", "CRC32"},
    {"CRC32C", "CRC32C"},
    {"CRC64NVME", "CRC64NVME"},
    {"SHA1", "SHA1"},
    {"SHA256", "SHA256"}
  ]
  @checksum_headers %{
    "CRC32" => "x-amz-checksum-crc32",
    "CRC32C" => "x-amz-checksum-crc32c",
    "CRC64NVME" => "x-amz-checksum-crc64nvme",
    "SHA1" => "x-amz-checksum-sha1",
    "SHA256" => "x-amz-checksum-sha256"
  }
  @system_header_fields [
    {"content_type", "Content-Type"},
    {"cache_control", "Cache-Control"},
    {"content_disposition", "Content-Disposition"},
    {"content_encoding", "Content-Encoding"},
    {"expires", "Expires"}
  ]
  @raw_amz_allowed_fields MapSet.new([
                            "x-amz-storage-class",
                            "x-amz-website-redirect-location",
                            "x-amz-expected-bucket-owner",
                            "x-amz-object-lock-mode",
                            "x-amz-object-lock-retain-until-date",
                            "x-amz-object-lock-legal-hold",
                            "x-amz-grant-read",
                            "x-amz-grant-write",
                            "x-amz-grant-read-acp",
                            "x-amz-grant-write-acp",
                            "x-amz-grant-full-control"
                          ])
  @object_lock_raw_fields MapSet.new([
                            "x-amz-object-lock-mode",
                            "x-amz-object-lock-retain-until-date",
                            "x-amz-object-lock-legal-hold"
                          ])
  @sensitive_form_fields ~w(sse_customer_key sse_customer_key_md5)
  @defaults %{
    "expires_in" => "3600",
    "max_size" => Integer.to_string(@max_object_size),
    "success_action_status" => "201",
    "success_action_redirect" => "",
    "acl" => "",
    "content_md5" => "",
    "content_type" => "",
    "cache_control" => "",
    "content_disposition" => "",
    "content_encoding" => "",
    "expires" => "",
    "metadata" => "",
    "tagging" => "",
    "sse_algorithm" => "",
    "sse_kms_key_id" => "",
    "sse_context" => "",
    "sse_bucket_key" => "false",
    "sse_customer_key" => "",
    "sse_customer_key_md5" => "",
    "request_payer" => "false",
    "checksum_algorithm" => "",
    "checksum_value" => "",
    "raw_amz_fields" => ""
  }

  @type parsed :: %{
          required(:expires) => pos_integer(),
          required(:max_size) => pos_integer(),
          required(:success_action_status) => String.t(),
          required(:fields) => [{String.t(), String.t()}]
        }

  @spec max_object_size() :: pos_integer()
  def max_object_size, do: @max_object_size

  @spec max_expires() :: pos_integer()
  def max_expires, do: @max_expires

  @spec success_status_options() :: [{String.t(), String.t()}]
  def success_status_options, do: @success_status_options

  @spec acl_options() :: [{String.t(), String.t()}]
  def acl_options, do: @acl_options

  @spec sse_algorithm_options() :: [{String.t(), String.t()}]
  def sse_algorithm_options, do: @sse_algorithm_options

  @spec checksum_algorithm_options() :: [{String.t(), String.t()}]
  def checksum_algorithm_options, do: @checksum_algorithm_options

  @spec form(map(), keyword()) :: Phoenix.HTML.Form.t()
  def form(params \\ %{}, opts \\ []) do
    values =
      @defaults
      |> Map.merge(params |> string_params() |> scrub_sensitive_params())
      |> Map.merge(string_opts(opts))

    to_form(values, as: :post_policy)
  end

  @spec parse(map()) :: {:ok, parsed()} | {:error, atom()}
  def parse(params) when is_map(params) do
    with {:ok, expires} <- parse_expires(Map.get(params, "expires_in")),
         {:ok, max_size} <- parse_max_size(Map.get(params, "max_size")),
         {:ok, success_status} <- parse_success_status(Map.get(params, "success_action_status")),
         {:ok, fields} <- parse_extra_fields(params) do
      {:ok,
       %{
         expires: expires,
         max_size: max_size,
         success_action_status: success_status,
         fields: fields
       }}
    end
  end

  def parse(_params), do: {:error, :invalid_field}

  @spec error_message(atom()) :: String.t()
  def error_message(:invalid_expires),
    do: "POST form expiration must be 1 to #{@max_expires} seconds"

  def error_message(:invalid_max_size),
    do: "POST form max size must be 1 to #{@max_object_size} bytes"

  def error_message(:invalid_success_action_status),
    do: "POST form success status must be 200, 201, or 204"

  def error_message(:credential_unavailable), do: "Current credentials cannot generate POST form"
  def error_message(:invalid_public_url), do: "S3 public URL is invalid"
  def error_message(:invalid_bucket_key), do: "POST form key cannot contain ${filename}"
  def error_message(:invalid_redirect), do: "POST form redirect URL must be absolute http(s) URL"
  def error_message(:invalid_acl), do: "POST form ACL is invalid"
  def error_message(:invalid_content_md5), do: "POST form Content-MD5 is invalid"
  def error_message(:invalid_metadata), do: "POST form metadata is invalid"
  def error_message(:invalid_tag), do: "POST form tags are invalid"
  def error_message(:invalid_sse), do: "POST form SSE settings are invalid"
  def error_message(:invalid_checksum), do: "POST form checksum settings are invalid"
  def error_message(:invalid_raw_amz_field), do: "POST form raw x-amz field is invalid"
  def error_message(:invalid_field), do: "POST form advanced field is invalid"
  def error_message(_reason), do: "POST Object form generation failed"

  @spec html(map()) :: String.t()
  def html(%{url: url, fields: fields}) do
    hidden_fields =
      fields
      |> Enum.map_join("\n", fn {name, value} ->
        ~s(  <input type="hidden" name="#{html_attr(name)}" value="#{html_attr(value)}" />)
      end)

    [
      ~s(<form action="#{html_attr(url)}" method="post" enctype="multipart/form-data">),
      hidden_fields,
      ~s(  <input type="file" name="file" />),
      ~s(</form>)
    ]
    |> Enum.join("\n")
  end

  defp parse_expires(value) do
    case Integer.parse(to_string(value || "")) do
      {integer, ""} when integer in 1..@max_expires -> {:ok, integer}
      _other -> {:error, :invalid_expires}
    end
  end

  defp parse_max_size(value) do
    case Integer.parse(to_string(value || "")) do
      {integer, ""} when integer in 1..@max_object_size -> {:ok, integer}
      _other -> {:error, :invalid_max_size}
    end
  end

  defp parse_success_status(value) do
    value = to_string(value || "201")

    if value in @success_statuses do
      {:ok, value}
    else
      {:error, :invalid_success_action_status}
    end
  end

  defp parse_extra_fields(params) do
    with {:ok, fields} <- add_redirect([], params),
         {:ok, fields} <- add_acl(fields, params),
         {:ok, fields} <- add_content_md5(fields, params),
         {:ok, fields} <- add_system_headers(fields, params),
         {:ok, fields} <- add_metadata(fields, params),
         {:ok, fields} <- add_tagging(fields, params),
         {:ok, fields} <- add_sse(fields, params),
         {:ok, fields} <- add_request_payer(fields, params),
         {:ok, fields} <- add_checksum(fields, params),
         {:ok, fields} <- add_raw_amz_fields(fields, params),
         :ok <- validate_cross_field_constraints(fields) do
      {:ok, Enum.reverse(fields)}
    end
  end

  defp add_redirect(fields, params) do
    case trim(params["success_action_redirect"]) do
      "" ->
        {:ok, fields}

      redirect ->
        with :ok <- validate_plain_value(redirect),
             :ok <- validate_redirect_url(redirect),
             :ok <- validate_redirect_allowlist(redirect) do
          {:ok, [{"success_action_redirect", redirect} | fields]}
        else
          _error -> {:error, :invalid_redirect}
        end
    end
  end

  defp validate_redirect_url(url) do
    uri = URI.parse(url)

    cond do
      uri.scheme not in ["http", "https"] -> {:error, :invalid_redirect}
      is_nil(uri.host) or uri.host == "" -> {:error, :invalid_redirect}
      not is_nil(uri.userinfo) -> {:error, :invalid_redirect}
      true -> :ok
    end
  end

  defp validate_redirect_allowlist(url) do
    allowlist =
      :maxio
      |> Application.get_env(:console, [])
      |> Keyword.get(:post_object_redirect_allowlist, [])

    case allowlist do
      entries when entries in [nil, []] ->
        :ok

      entries when is_list(entries) ->
        uri = URI.parse(url)

        if Enum.any?(entries, &redirect_allowlist_match?(uri, &1)) do
          :ok
        else
          {:error, :not_allowed}
        end

      _other ->
        {:error, :invalid_allowlist}
    end
  end

  defp redirect_allowlist_match?(%URI{} = uri, entry) when is_binary(entry) do
    allowed = URI.parse(String.trim_trailing(entry, "/"))

    cond do
      allowed.scheme not in ["http", "https"] ->
        false

      is_nil(allowed.host) or allowed.host == "" or not is_nil(allowed.userinfo) ->
        false

      uri.scheme != allowed.scheme or uri.host != allowed.host or uri.port != allowed.port ->
        false

      true ->
        allowed_path = normalize_allowlist_path(allowed.path)
        redirect_path_allowed?(uri.path || "/", allowed_path)
    end
  end

  defp redirect_allowlist_match?(_uri, _entry), do: false

  defp normalize_allowlist_path(nil), do: "/"
  defp normalize_allowlist_path(""), do: "/"
  defp normalize_allowlist_path(path), do: path

  defp redirect_path_allowed?(_path, "/"), do: true

  defp redirect_path_allowed?(path, allowed_path) do
    path == allowed_path or String.starts_with?(path, allowed_path <> "/")
  end

  defp add_acl(fields, params) do
    case trim(params["acl"]) do
      "" ->
        {:ok, fields}

      acl ->
        if ACL.known?(acl) do
          {:ok, [{"acl", acl} | fields]}
        else
          {:error, :invalid_acl}
        end
    end
  end

  defp add_content_md5(fields, params) do
    case trim(params["content_md5"]) do
      "" ->
        {:ok, fields}

      md5 ->
        with :ok <- validate_plain_value(md5),
             :ok <- validate_base64_bytes(md5, @content_md5_bytes) do
          {:ok, [{"Content-MD5", md5} | fields]}
        else
          _error -> {:error, :invalid_content_md5}
        end
    end
  end

  defp add_system_headers(fields, params) do
    Enum.reduce_while(@system_header_fields, {:ok, fields}, fn {param, field}, {:ok, acc} ->
      case trim(params[param]) do
        "" ->
          {:cont, {:ok, acc}}

        value ->
          case validate_plain_value(value) do
            :ok -> {:cont, {:ok, [{field, value} | acc]}}
            {:error, _reason} -> {:halt, {:error, :invalid_field}}
          end
      end
    end)
  end

  defp add_metadata(fields, params) do
    case trim(params["metadata"]) do
      "" ->
        {:ok, fields}

      raw ->
        with {:ok, metadata_fields} <- raw_metadata(raw),
             :ok <- validate_metadata_headers(metadata_fields) do
          fields =
            Enum.reduce(metadata_fields, fields, fn field, acc ->
              [field | acc]
            end)

          {:ok, fields}
        else
          _error -> {:error, :invalid_metadata}
        end
    end
  end

  defp raw_metadata(raw) do
    raw
    |> String.split(~r/\r?\n/, trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.reduce_while({:ok, [], MapSet.new()}, fn line, {:ok, acc, seen} ->
      with {:ok, name, value} <- raw_metadata_line(line),
           :ok <- validate_metadata_name(name),
           :ok <- validate_plain_value(value),
           false <- MapSet.member?(seen, name) do
        {:cont, {:ok, [{"x-amz-meta-" <> name, value} | acc], MapSet.put(seen, name)}}
      else
        true -> {:halt, {:error, :invalid_metadata}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, metadata_fields, _seen} -> {:ok, Enum.reverse(metadata_fields)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp raw_metadata_line(line) do
    case String.split(line, "=", parts: 2) do
      [raw_name, raw_value] ->
        with {:ok, name} <- normalize_metadata_name(raw_name) do
          value = String.trim(raw_value)

          if value == "" do
            {:error, :invalid_metadata}
          else
            {:ok, name, value}
          end
        end

      _other ->
        {:error, :invalid_metadata}
    end
  end

  defp normalize_metadata_name(raw_name) do
    name =
      raw_name
      |> trim()
      |> String.downcase()

    cond do
      String.starts_with?(name, "x-amz-meta-") ->
        {:ok, String.replace_prefix(name, "x-amz-meta-", "")}

      String.starts_with?(name, "x-amz-") or String.starts_with?(name, "x-minio-") ->
        {:error, :invalid_metadata}

      true ->
        {:ok, name}
    end
  end

  defp validate_metadata_name(name) do
    cond do
      name == "" ->
        {:error, :invalid_metadata}

      String.contains?(name, ["\0", "\r", "\n", "\"", ":"]) ->
        {:error, :invalid_metadata}

      not Regex.match?(~r/^[!#$%&'*+\-.^_`|~0-9a-z]+$/, name) ->
        {:error, :invalid_metadata}

      true ->
        :ok
    end
  end

  defp validate_metadata_headers(metadata_fields) do
    Metadata.validate_headers!(metadata_fields)
  rescue
    _error in [Maxio.S3.Error] -> {:error, :invalid_metadata}
  end

  defp add_tagging(fields, params) do
    case trim(params["tagging"]) do
      "" ->
        {:ok, fields}

      raw ->
        with {:ok, tags} <- raw_tags(raw),
             :ok <- Tags.validate(tags, :object) do
          tagging_xml = Tagging.render(tags) |> IO.iodata_to_binary()
          {:ok, [{"tagging", tagging_xml} | fields]}
        else
          _error -> {:error, :invalid_tag}
        end
    end
  end

  defp raw_tags(raw) do
    tags =
      raw
      |> String.split(~r/\r?\n/, trim: true)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.map(fn line ->
        case String.split(line, "=", parts: 2) do
          [key, value] -> {String.trim(key), String.trim(value)}
          [key] -> {String.trim(key), ""}
        end
      end)

    {:ok, tags}
  end

  defp add_sse(fields, params) do
    algorithm = trim(params["sse_algorithm"])
    key_id = trim(params["sse_kms_key_id"])
    context = trim(params["sse_context"])
    bucket_key_enabled = truthy?(params["sse_bucket_key"])
    customer_key = trim(params["sse_customer_key"])
    customer_key_md5 = trim(params["sse_customer_key_md5"])

    cond do
      customer_key != "" or customer_key_md5 != "" ->
        add_sse_customer(
          fields,
          algorithm,
          key_id,
          context,
          bucket_key_enabled,
          customer_key,
          customer_key_md5
        )

      algorithm == "" and key_id == "" and context == "" and not bucket_key_enabled ->
        {:ok, fields}

      algorithm == "" ->
        {:error, :invalid_sse}

      algorithm not in ["AES256", "aws:kms", "aws:kms:dsse"] ->
        {:error, :invalid_sse}

      algorithm == "AES256" and (key_id != "" or context != "" or bucket_key_enabled) ->
        {:error, :invalid_sse}

      algorithm == "aws:kms:dsse" and bucket_key_enabled ->
        {:error, :invalid_sse}

      key_id != "" and validate_plain_value(key_id) != :ok ->
        {:error, :invalid_sse}

      context != "" and validate_plain_value(context) != :ok ->
        {:error, :invalid_sse}

      context != "" and validate_kms_context(context) != :ok ->
        {:error, :invalid_sse}

      true ->
        fields = [{"x-amz-server-side-encryption", algorithm} | fields]

        fields =
          if key_id == "" do
            fields
          else
            [{"x-amz-server-side-encryption-aws-kms-key-id", key_id} | fields]
          end

        fields =
          if context == "" do
            fields
          else
            [{"x-amz-server-side-encryption-context", context} | fields]
          end

        fields =
          if bucket_key_enabled do
            [{"x-amz-server-side-encryption-bucket-key-enabled", "true"} | fields]
          else
            fields
          end

        {:ok, fields}
    end
  end

  defp add_sse_customer(
         fields,
         algorithm,
         key_id,
         context,
         bucket_key_enabled,
         customer_key,
         customer_key_md5
       ) do
    with true <- algorithm == "" and key_id == "" and context == "" and not bucket_key_enabled,
         :ok <- validate_plain_value(customer_key),
         :ok <- validate_plain_value(customer_key_md5),
         {:ok, raw_key} <- decode_base64_bytes(customer_key, @sse_customer_key_bytes),
         {:ok, key_md5_b64} <- validate_customer_key_md5(raw_key, customer_key_md5) do
      {:ok,
       [
         {"x-amz-server-side-encryption-customer-algorithm", "AES256"},
         {"x-amz-server-side-encryption-customer-key", Base.encode64(raw_key)},
         {"x-amz-server-side-encryption-customer-key-md5", key_md5_b64}
         | fields
       ]}
    else
      _error -> {:error, :invalid_sse}
    end
  end

  defp add_request_payer(fields, params) do
    case truthy?(params["request_payer"]) do
      true -> {:ok, [{"x-amz-request-payer", "requester"} | fields]}
      false -> {:ok, fields}
    end
  end

  defp add_checksum(fields, params) do
    algorithm = trim(params["checksum_algorithm"])
    checksum = trim(params["checksum_value"])

    cond do
      algorithm == "" and checksum == "" ->
        {:ok, fields}

      algorithm == "" or checksum == "" ->
        {:error, :invalid_checksum}

      not Map.has_key?(@checksum_headers, algorithm) ->
        {:error, :invalid_checksum}

      validate_plain_value(checksum) != :ok ->
        {:error, :invalid_checksum}

      true ->
        {:ok,
         [
           {Map.fetch!(@checksum_headers, algorithm), checksum},
           {"x-amz-sdk-checksum-algorithm", algorithm}
           | fields
         ]}
    end
  end

  defp add_raw_amz_fields(fields, params) do
    case trim(params["raw_amz_fields"]) do
      "" ->
        {:ok, fields}

      raw ->
        with {:ok, raw_fields} <- raw_amz_fields(raw),
             :ok <- validate_no_raw_collisions(fields, raw_fields),
             :ok <- validate_raw_grants(raw_fields) do
          {:ok, Enum.reduce(raw_fields, fields, fn field, acc -> [field | acc] end)}
        else
          _error -> {:error, :invalid_raw_amz_field}
        end
    end
  end

  defp raw_amz_fields(raw) do
    raw
    |> String.split(~r/\r?\n/, trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.reduce_while({:ok, [], MapSet.new()}, fn line, {:ok, acc, seen} ->
      with {:ok, name, value} <- raw_amz_line(line),
           :ok <- validate_raw_amz_name(name),
           :ok <- validate_plain_value(value),
           :ok <- validate_raw_amz_value(name, value),
           false <- MapSet.member?(seen, name) do
        {:cont, {:ok, [{name, value} | acc], MapSet.put(seen, name)}}
      else
        true -> {:halt, {:error, :duplicate_raw_amz_field}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, raw_fields, _seen} -> {:ok, Enum.reverse(raw_fields)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp raw_amz_line(line) do
    case String.split(line, "=", parts: 2) do
      [raw_name, raw_value] ->
        name = raw_name |> trim() |> String.downcase()
        value = String.trim(raw_value)

        if value == "" do
          {:error, :invalid_raw_amz_field}
        else
          {:ok, name, value}
        end

      _other ->
        {:error, :invalid_raw_amz_field}
    end
  end

  defp validate_raw_amz_name(name) do
    cond do
      name == "" ->
        {:error, :invalid_raw_amz_field}

      String.contains?(name, ["\0", "\r", "\n", "\"", ":"]) ->
        {:error, :invalid_raw_amz_field}

      not Regex.match?(~r/^[!#$%&'*+\-.^_`|~0-9a-z]+$/, name) ->
        {:error, :invalid_raw_amz_field}

      not String.starts_with?(name, "x-amz-") ->
        {:error, :invalid_raw_amz_field}

      not MapSet.member?(@raw_amz_allowed_fields, name) ->
        {:error, :invalid_raw_amz_field}

      true ->
        :ok
    end
  end

  defp validate_raw_amz_value("x-amz-storage-class", value) do
    _ = StorageClass.parse!(value)
    :ok
  rescue
    _error in [Maxio.S3.Error] -> {:error, :invalid_raw_amz_field}
  end

  defp validate_raw_amz_value("x-amz-expected-bucket-owner", value) do
    if value == ExpectedBucketOwner.account_id(),
      do: :ok,
      else: {:error, :invalid_raw_amz_field}
  end

  defp validate_raw_amz_value("x-amz-object-lock-mode", value) do
    if value in ["COMPLIANCE", "GOVERNANCE"],
      do: :ok,
      else: {:error, :invalid_raw_amz_field}
  end

  defp validate_raw_amz_value("x-amz-object-lock-legal-hold", value) do
    if value in ["ON", "OFF"],
      do: :ok,
      else: {:error, :invalid_raw_amz_field}
  end

  defp validate_raw_amz_value("x-amz-object-lock-retain-until-date", value) do
    case DateTime.from_iso8601(value) do
      {:ok, _dt, _offset} -> :ok
      _other -> {:error, :invalid_raw_amz_field}
    end
  end

  defp validate_raw_amz_value(_name, _value), do: :ok

  defp validate_no_raw_collisions(fields, raw_fields) do
    existing =
      fields
      |> Enum.map(fn {name, _value} -> effective_header_name(name) end)
      |> Enum.reject(&is_nil/1)
      |> MapSet.new()

    duplicate =
      Enum.find(raw_fields, fn {name, _value} ->
        MapSet.member?(existing, effective_header_name(name))
      end)

    if duplicate, do: {:error, :duplicate_raw_amz_field}, else: :ok
  end

  defp effective_header_name("acl"), do: "x-amz-acl"
  defp effective_header_name("tagging"), do: "x-amz-tagging"
  defp effective_header_name("Content-MD5"), do: "content-md5"

  defp effective_header_name(name) when is_binary(name) do
    down = String.downcase(name)

    cond do
      String.starts_with?(down, "x-amz-") -> down
      true -> nil
    end
  end

  defp validate_raw_grants(raw_fields) do
    grant_fields =
      Enum.filter(raw_fields, fn {name, _value} ->
        String.starts_with?(name, "x-amz-grant-")
      end)

    if grant_fields == [] do
      :ok
    else
      case ACL.parse_grant_headers(grant_fields) do
        {:ok, _grants} -> :ok
        {:error, _reason} -> {:error, :invalid_raw_amz_field}
      end
    end
  end

  defp validate_cross_field_constraints(fields) do
    field_map = Map.new(fields)

    cond do
      Map.has_key?(field_map, "acl") and raw_grant_fields?(field_map) ->
        {:error, :invalid_raw_amz_field}

      object_lock_fields?(field_map) and not checksum_guard?(field_map) ->
        {:error, :invalid_raw_amz_field}

      retention_pair_incomplete?(field_map) ->
        {:error, :invalid_raw_amz_field}

      true ->
        :ok
    end
  end

  defp object_lock_fields?(field_map) do
    Enum.any?(@object_lock_raw_fields, &Map.has_key?(field_map, &1))
  end

  defp raw_grant_fields?(field_map) do
    field_map
    |> Map.keys()
    |> Enum.any?(&String.starts_with?(&1, "x-amz-grant-"))
  end

  defp checksum_guard?(field_map) do
    Map.has_key?(field_map, "Content-MD5") or
      Map.has_key?(field_map, "x-amz-sdk-checksum-algorithm")
  end

  defp retention_pair_incomplete?(field_map) do
    mode? = Map.has_key?(field_map, "x-amz-object-lock-mode")
    retain_until? = Map.has_key?(field_map, "x-amz-object-lock-retain-until-date")
    mode? != retain_until?
  end

  defp validate_base64_bytes(value, bytes) do
    case decode_base64_bytes(value, bytes) do
      {:ok, _decoded} -> :ok
      {:error, _reason} -> {:error, :invalid_base64}
    end
  end

  defp decode_base64_bytes(value, bytes) do
    case Base.decode64(value) do
      {:ok, decoded} when byte_size(decoded) == bytes -> {:ok, decoded}
      _other -> {:error, :invalid_base64}
    end
  end

  defp validate_customer_key_md5(raw_key, "") do
    {:ok, :crypto.hash(:md5, raw_key) |> Base.encode64()}
  end

  defp validate_customer_key_md5(raw_key, key_md5_b64) do
    with {:ok, provided_md5} <- decode_base64_bytes(key_md5_b64, @content_md5_bytes) do
      expected_md5 = :crypto.hash(:md5, raw_key)

      if Plug.Crypto.secure_compare(provided_md5, expected_md5) do
        {:ok, Base.encode64(expected_md5)}
      else
        {:error, :invalid_customer_key_md5}
      end
    end
  end

  defp validate_kms_context(context) do
    with {:ok, decoded} <- Base.decode64(context),
         {:ok, %{} = _json} <- Jason.decode(decoded) do
      :ok
    else
      _other -> {:error, :invalid_context}
    end
  end

  defp validate_plain_value(value) do
    cond do
      byte_size(value) > @max_field_value_size -> {:error, :too_large}
      String.contains?(value, ["\0", "\r", "\n"]) -> {:error, :control_character}
      true -> :ok
    end
  end

  defp truthy?(value) when value in [true, "true", "on", "1", "requester"], do: true
  defp truthy?(_value), do: false

  defp trim(value) when is_binary(value), do: String.trim(value)
  defp trim(nil), do: ""
  defp trim(value), do: value |> to_string() |> String.trim()

  defp string_params(params) do
    Map.new(params, fn {key, value} -> {to_string(key), to_string(value || "")} end)
  end

  defp scrub_sensitive_params(params), do: Map.drop(params, @sensitive_form_fields)

  defp string_opts(opts) do
    Map.new(opts, fn {key, value} -> {to_string(key), to_string(value || "")} end)
  end

  defp html_attr(value) do
    value
    |> to_string()
    |> String.replace("&", "&amp;")
    |> String.replace("\"", "&quot;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
  end
end
