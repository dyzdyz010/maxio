defmodule Maxio.S3.Plugs.WebsiteEndpoint do
  @moduledoc """
  Static website endpoint data plane for bucket.<website_domain> hosts.

  Website requests are public HTTP GET/HEAD requests. They intentionally bypass
  SigV4 and are authorized as anonymous reads against the resolved object key.
  """

  @behaviour Plug

  import Plug.Conn

  alias Maxio.{BucketConfigs, Buckets, ObjectMeta, Objects, Storage}
  alias Maxio.Cluster.Placement

  alias Maxio.S3.{
    Authz,
    Conditional,
    Error,
    Log,
    RawPath,
    RequestPayment,
    SSEObjectReader,
    SystemHeaders,
    XML
  }

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%{assigns: %{s3_endpoint_kind: :website}} = conn, _opts) do
    Maxio.S3.InFlight.track(fn ->
      conn
      |> fetch_query_params()
      |> do_call()
      |> halt()
    end)
  end

  def call(conn, _opts), do: conn

  defp do_call(conn) do
    conn = assign_anonymous(conn)

    try do
      case conn.method do
        "GET" ->
          conn
          |> assign(:s3_action, :get_object)
          |> serve()

        "HEAD" ->
          conn
          |> assign(:s3_action, :head_object)
          |> serve()

        _other ->
          raise Error.new(:method_not_allowed)
      end
    rescue
      err in Error ->
        render_error(conn, err)

      other ->
        Log.error("unhandled exception in website endpoint",
          code: "InternalError",
          status: 500,
          reason: Exception.message(other)
        )

        render_error(conn, Error.new(:internal_error))
    end
  end

  defp assign_anonymous(conn) do
    conn
    |> assign(:principal, :anonymous)
    |> assign(:auth_type, :anonymous)
    |> assign(:payload_mode, :unsigned)
    |> assign(:sigv4_signed_headers, [])
  end

  defp serve(conn) do
    bucket = conn.assigns.s3_bucket
    key = conn.assigns[:s3_key] || ""
    _bucket_info = ensure_bucket!(bucket)
    :ok = reject_requester_pays_website!(bucket)
    config = website_config!(bucket)

    case config["redirect_all_requests_to"] do
      %{} = redirect ->
        send_redirect(conn, redirect_location(conn, redirect, key), 301)

      _other ->
        serve_configured(conn, bucket, key, config)
    end
  end

  defp serve_configured(conn, bucket, key, config) do
    case routing_redirect(conn, config, key, nil) do
      {:ok, conn} ->
        conn

      :none ->
        serve_index_or_object(conn, bucket, key, config)
    end
  end

  defp serve_index_or_object(conn, bucket, key, config) do
    suffix = index_suffix(config)

    cond do
      suffix == nil ->
        handle_object_error(conn, bucket, key, config, Error.new(:no_such_key))

      index_request?(key) ->
        key
        |> index_key(suffix)
        |> try_serve_or_handle(conn, bucket, key, config)

      true ->
        try_serve_or_handle(key, conn, bucket, key, config)
    end
  end

  defp try_serve_or_handle(target_key, conn, bucket, request_key, config) do
    case try_serve_object(conn, bucket, target_key) do
      {:ok, conn} -> conn
      {:error, %Error{} = err} -> handle_object_error(conn, bucket, request_key, config, err)
    end
  end

  defp try_serve_object(conn, bucket, key) do
    conn = assign(conn, :s3_key, key)

    try do
      :ok = validate_object_key!(bucket, key)
      object = object_for_website!(bucket, key)
      :ok = Authz.authorize(conn, conn.assigns.s3_action)
      :ok = reject_unsupported_website_encryption!(object, bucket, key)

      case object_redirect_location(object) do
        nil ->
          {:ok, serve_object(conn, bucket, key, object)}

        location ->
          {:ok, send_redirect(conn, location, 301)}
      end
    rescue
      err in Error -> {:error, err}
    end
  end

  defp handle_object_error(conn, bucket, key, config, %Error{} = err) do
    with :none <- directory_index_redirect(conn, bucket, key, config, err),
         :none <- routing_redirect(conn, config, key, err.http_status),
         :none <- error_document(conn, bucket, config, err) do
      render_error(conn, err)
    else
      {:ok, conn} -> conn
    end
  end

  defp directory_index_redirect(conn, bucket, key, config, %Error{code: "NoSuchKey"}) do
    suffix = index_suffix(config)

    cond do
      suffix == nil or key == "" or String.ends_with?(key, "/") ->
        :none

      website_object_accessible?(conn, bucket, index_key(key <> "/", suffix)) ->
        {:ok, send_redirect(conn, path_location(conn, key <> "/"), 302)}

      true ->
        :none
    end
  end

  defp directory_index_redirect(_conn, _bucket, _key, _config, _err), do: :none

  defp website_object_accessible?(conn, bucket, key) do
    conn = assign(conn, :s3_key, key)

    try do
      object = object_for_website!(bucket, key)
      :ok = Authz.authorize(conn, conn.assigns.s3_action)

      case object do
        %Objects.Object{} -> true
      end
    rescue
      _err in Error -> false
    end
  end

  defp routing_redirect(conn, config, key, status) do
    config
    |> Map.get("routing_rules", [])
    |> Enum.find_value(fn rule ->
      if routing_rule_matches?(rule, key, status) do
        redirect = Map.fetch!(rule, "redirect")
        condition = Map.get(rule, "condition", %{})
        location = redirect_location(conn, redirect, key, condition)
        status = redirect_status(redirect)
        {:ok, send_redirect(conn, location, status)}
      end
    end)
    |> case do
      nil -> :none
      {:ok, conn} -> {:ok, conn}
    end
  end

  defp routing_rule_matches?(%{"redirect" => redirect} = rule, key, nil) when is_map(redirect) do
    condition = Map.get(rule, "condition", %{})

    Map.get(condition, "http_error_code_returned_equals") == nil and
      prefix_matches?(condition, key)
  end

  defp routing_rule_matches?(%{"redirect" => redirect} = rule, key, status)
       when is_map(redirect) and is_integer(status) do
    condition = Map.get(rule, "condition", %{})

    Map.get(condition, "http_error_code_returned_equals") == Integer.to_string(status) and
      prefix_matches?(condition, key)
  end

  defp routing_rule_matches?(_rule, _key, _status), do: false

  defp prefix_matches?(condition, key) do
    case Map.get(condition || %{}, "key_prefix_equals") do
      nil -> true
      prefix -> String.starts_with?(key, prefix)
    end
  end

  defp error_document(conn, bucket, config, %Error{http_status: status} = original)
       when status >= 400 and status < 500 do
    case config["error_document"] do
      %{"key" => key} when is_binary(key) and key != "" ->
        try_error_document(conn, bucket, key, status, original)

      _other ->
        :none
    end
  end

  defp error_document(_conn, _bucket, _config, _err), do: :none

  defp try_error_document(conn, bucket, key, status, original) do
    conn = assign(conn, :s3_key, key)

    try do
      :ok = Authz.authorize(conn, conn.assigns.s3_action)
      object = object_for_website!(bucket, key)
      :ok = reject_unsupported_website_encryption!(object, bucket, key)

      {:ok,
       serve_object(conn, bucket, key, object, status: status, range?: false, conditional?: false)}
    rescue
      err in Error ->
        Log.warn("website error document unavailable",
          action: conn.assigns[:s3_action],
          bucket: bucket,
          key: key,
          code: original.code,
          status: original.http_status,
          reason: err.code
        )

        :none
    end
  end

  defp serve_object(conn, bucket, key, object, opts \\ []) do
    status = Keyword.get(opts, :status, 200)
    conditional? = Keyword.get(opts, :conditional?, true)

    if conditional? do
      case Conditional.evaluate(conn.req_headers, meta(object), conn.method) do
        :proceed ->
          do_serve_object(conn, bucket, key, object, status, opts)

        {:respond, 304} ->
          send_resp(conn, 304, "")

        {:error, :precondition_failed} ->
          raise Error.new(:precondition_failed, resource: "/#{bucket}/#{key}")
      end
    else
      do_serve_object(conn, bucket, key, object, status, opts)
    end
  end

  defp do_serve_object(%{method: "HEAD"} = conn, _bucket, _key, object, status, _opts) do
    conn
    |> put_website_object_headers(object, object.size)
    |> send_resp(status, "")
  end

  defp do_serve_object(%{method: "GET"} = conn, bucket, key, object, status, opts) do
    range =
      if Keyword.get(opts, :range?, true),
        do: parse_range(header(conn, "range"), object.size),
        else: nil

    case range do
      :invalid ->
        raise Error.new(:invalid_range,
                resource: "/#{bucket}/#{key}",
                extra: %{total: object.size}
              )

      _other ->
        {read_range, plain_slice} = website_storage_range(range, object)
        content_length = response_content_length(range, object.size)
        response_status = response_status(status, range)
        content_range = content_range(range, object.size)

        stream =
          bucket
          |> storage_stream!(key, object, read_range)
          |> maybe_decrypt_website_stream!(object, plain_slice)

        path = stage_stream!(stream, content_length)

        try do
          conn
          |> put_website_object_headers(object, content_length)
          |> maybe_put_content_range(content_range)
          |> send_chunked(response_status)
          |> stream_file_chunks(path)
        after
          _ = File.rm(path)
        end
    end
  end

  defp meta(object), do: %{etag: object.etag, last_modified: object.updated_at}

  defp response_status(status, {_, _}) when status == 200, do: 206
  defp response_status(status, _range), do: status

  defp response_content_length({first, last}, _total), do: last - first + 1
  defp response_content_length(_range, total), do: total

  defp content_range({first, last}, total), do: "bytes #{first}-#{last}/#{total}"
  defp content_range(_range, _total), do: nil

  defp maybe_put_content_range(conn, nil), do: conn
  defp maybe_put_content_range(conn, value), do: put_resp_header(conn, "content-range", value)

  defp storage_stream!(bucket, key, object, range) do
    case Storage.get(bucket, key, object.version_id, range, Placement.storage_opts(object)) do
      {:ok, stream} ->
        stream

      {:error, :enoent} ->
        raise Error.new(:no_such_key, resource: "/#{bucket}/#{key}")

      {:error, :read_quorum} ->
        raise Error.new(:slow_down_read, resource: "/#{bucket}/#{key}")

      {:error, reason} ->
        Log.warn("website object storage read failed",
          action: :website_get_object,
          bucket: bucket,
          key: key,
          reason: inspect(reason)
        )

        raise Error.new(:internal_error, resource: "/#{bucket}/#{key}")
    end
  end

  defp website_storage_range(range, %{sse_algorithm: "AES256", size: total}) do
    SSEObjectReader.storage_range(range, total, "AES256")
  end

  defp website_storage_range(range, _object), do: {range_tuple(range), nil}

  defp maybe_decrypt_website_stream!(
         stream,
         %{sse_algorithm: "AES256", sse_envelope: envelope},
         plain_slice
       ) do
    SSEObjectReader.decrypt_stream(stream, "AES256", envelope, plain_slice)
  end

  defp maybe_decrypt_website_stream!(stream, _object, _plain_slice), do: stream

  defp stage_stream!(stream, expected_length) do
    path = website_temp_path()
    counter = :counters.new(1, [])

    try do
      File.open!(path, [:write, :binary], fn io ->
        Enum.each(stream, fn chunk ->
          :counters.add(counter, 1, IO.iodata_length(chunk))
          IO.binwrite(io, chunk)
        end)
      end)

      if :counters.get(counter, 1) == expected_length do
        path
      else
        raise Error.new(:internal_error,
                message: "Website object read ended before expected length"
              )
      end
    rescue
      err in Error ->
        _ = File.rm(path)
        reraise(err, __STACKTRACE__)

      err ->
        _ = File.rm(path)

        Log.warn("website object staging failed",
          action: :website_get_object,
          reason: Exception.message(err)
        )

        raise Error.new(:internal_error)
    end
  end

  defp website_temp_path do
    name = "maxio_website_get_#{System.unique_integer([:monotonic, :positive])}.bin"
    Path.join(System.tmp_dir!(), name)
  end

  defp stream_file_chunks(conn, path) do
    stream_chunks(conn, File.stream!(path, 64 * 1024, [:read, :binary]))
  end

  defp reject_requester_pays_website!(bucket) do
    case RequestPayment.get_config(bucket) do
      {:ok, %{"Payer" => "Requester"}} ->
        raise Error.new(:access_denied, resource: "/" <> bucket)

      {:ok, _config} ->
        :ok
    end
  end

  defp reject_unsupported_website_encryption!(%{sse_algorithm: algorithm}, _bucket, _key)
       when algorithm in [nil, "", "AES256"] do
    :ok
  end

  defp reject_unsupported_website_encryption!(%{sse_algorithm: "SSE-C"}, bucket, key) do
    raise Error.new(:invalid_request,
            message: "SSE-C objects are not supported through the website endpoint",
            resource: "/#{bucket}/#{key}"
          )
  end

  defp reject_unsupported_website_encryption!(
         %{sse_algorithm: algorithm},
         bucket,
         key
       )
       when algorithm in ["aws:kms", "aws:kms:dsse"] do
    raise Error.new(:not_implemented,
            message: "SSE-KMS objects are not supported through the anonymous website endpoint",
            resource: "/#{bucket}/#{key}"
          )
  end

  defp reject_unsupported_website_encryption!(_object, bucket, key) do
    raise Error.new(:not_implemented,
            message: "Encrypted website objects are not supported",
            resource: "/#{bucket}/#{key}"
          )
  end

  defp object_for_website!(bucket, key) do
    case ObjectMeta.get(bucket, key, nil, []) do
      %Objects.Object{is_delete_marker: true} ->
        raise Error.new(:no_such_key, resource: "/#{bucket}/#{key}")

      %Objects.Object{} = object ->
        object

      {:error, :not_found} ->
        raise Error.new(:no_such_key, resource: "/#{bucket}/#{key}")

      {:error, :read_quorum} ->
        Log.warn("website object read unavailable: sidecar read_quorum unmet",
          action: :website_get_object,
          bucket: bucket,
          key: key,
          reason: :read_quorum
        )

        raise Error.new(:slow_down_read, resource: "/#{bucket}/#{key}")
    end
  end

  defp object_redirect_location(%{website_redirect_location: location})
       when is_binary(location) and location != "",
       do: location

  defp object_redirect_location(_object), do: nil

  defp send_redirect(conn, location, status) do
    conn
    |> put_resp_header("location", location)
    |> send_resp(status, "")
  end

  defp redirect_location(conn, redirect, key, condition \\ %{}) do
    path_key = redirected_key(key, redirect, condition)
    path = "/" <> encode_key(path_key)

    case {redirect["protocol"], redirect["host_name"]} do
      {nil, nil} ->
        path_location(conn, path_key)

      {protocol, host} ->
        protocol = protocol || scheme(conn)
        host = host || host_header(conn)
        append_query("#{protocol}://#{host}#{path}", conn)
    end
  end

  defp redirected_key(key, redirect, condition) do
    cond do
      present?(redirect["replace_key_with"]) ->
        redirect["replace_key_with"]

      present?(redirect["replace_key_prefix_with"]) ->
        prefix = Map.get(condition || %{}, "key_prefix_equals") || ""
        replacement = redirect["replace_key_prefix_with"]

        if prefix != "" and String.starts_with?(key, prefix) do
          replacement <> String.replace_prefix(key, prefix, "")
        else
          replacement <> key
        end

      true ->
        key
    end
  end

  defp redirect_status(%{"http_redirect_code" => code}) when is_binary(code) do
    case Integer.parse(code) do
      {status, ""} when status >= 300 and status <= 399 -> status
      _other -> 301
    end
  end

  defp redirect_status(_redirect), do: 301

  defp path_location(conn, key) do
    append_query("/" <> encode_key(key), conn)
  end

  defp append_query(location, %{query_string: query}) when is_binary(query) and query != "" do
    case website_redirect_query(query) do
      "" -> location
      filtered -> location <> "?" <> filtered
    end
  end

  defp append_query(location, _conn), do: location

  defp website_redirect_query(query) do
    query
    |> String.split("&", trim: true)
    |> Enum.reject(&s3_query_param?/1)
    |> Enum.join("&")
  end

  defp s3_query_param?(pair) do
    name =
      pair
      |> String.split("=", parts: 2)
      |> List.first()
      |> decode_query_name()
      |> String.downcase()

    String.starts_with?(name, "response-") or String.starts_with?(name, "x-amz-")
  end

  defp decode_query_name(name) do
    URI.decode(name)
  rescue
    ArgumentError -> name
  end

  defp encode_key(key) do
    URI.encode(key, fn char -> char == ?/ or URI.char_unreserved?(char) end)
  end

  defp host_header(conn), do: get_req_header(conn, "host") |> List.first() || conn.host
  defp scheme(%{scheme: :https}), do: "https"
  defp scheme(_conn), do: "http"

  defp present?(value), do: is_binary(value) and value != ""

  defp index_request?(""), do: true
  defp index_request?(key), do: String.ends_with?(key, "/")

  defp index_key("", suffix), do: suffix
  defp index_key(prefix, suffix), do: prefix <> suffix

  defp index_suffix(%{"index_document" => %{"suffix" => suffix}})
       when is_binary(suffix) and suffix != "",
       do: suffix

  defp index_suffix(_config), do: nil

  defp validate_object_key!(bucket, key) do
    case Maxio.Cluster.Paths.validate_key(key) do
      :ok ->
        :ok

      {:error, :invalid_key} ->
        raise Error.new(:invalid_object_name, resource: "/#{bucket}/#{key}")

      {:error, :key_too_long} ->
        raise Error.new(:key_too_long, resource: "/#{bucket}/#{key}")
    end
  end

  defp parse_range(nil, _total), do: nil

  defp parse_range("bytes=" <> spec, total) do
    if String.contains?(spec, ",") do
      :full
    else
      parse_single_range(spec, total)
    end
  end

  defp parse_range(_other, _total), do: :invalid

  defp parse_single_range(spec, total) do
    case String.split(spec, "-") do
      [a, ""] ->
        case Integer.parse(a) do
          {first, ""} when first < total -> {first, total - 1}
          _other -> :invalid
        end

      ["", suffix] ->
        case Integer.parse(suffix) do
          {n, ""} when n > 0 and total > 0 -> {max(total - n, 0), total - 1}
          _other -> :invalid
        end

      [a, b] ->
        with {first, ""} <- Integer.parse(a),
             {last, ""} <- Integer.parse(b),
             true <- first <= last and first < total do
          {first, min(last, total - 1)}
        else
          _other -> :invalid
        end

      _other ->
        :invalid
    end
  end

  defp range_tuple(nil), do: nil
  defp range_tuple(:full), do: nil
  defp range_tuple({first, last}), do: {first, last}

  defp put_website_object_headers(conn, object, content_length) do
    conn
    |> put_resp_header("content-type", object.content_type)
    |> put_resp_header("etag", XML.quote_etag(object.etag))
    |> put_resp_header("last-modified", http_date(object.updated_at))
    |> put_resp_header("accept-ranges", "bytes")
    |> put_resp_header("content-length", Integer.to_string(content_length))
    |> SystemHeaders.put_response_headers(object)
  end

  defp stream_chunks(conn, stream) do
    Enum.reduce_while(stream, conn, fn data, acc ->
      case chunk(acc, data) do
        {:ok, acc2} -> {:cont, acc2}
        {:error, :closed} -> {:halt, acc}
      end
    end)
  end

  defp ensure_bucket!(bucket) do
    case Buckets.lookup(bucket) do
      {:ok, b} -> b
      {:error, :not_found} -> raise Error.new(:no_such_bucket, resource: "/" <> bucket)
    end
  end

  defp website_config!(bucket) do
    case BucketConfigs.get(bucket, :website) do
      {:ok, config} -> config
      :none -> raise Error.new(:no_such_website_configuration, resource: "/" <> bucket)
    end
  end

  defp render_error(%{state: state} = conn, %Error{} = err)
       when state in [:sent, :chunked, :file] do
    Log.error("website endpoint error after response started",
      code: err.code,
      status: err.http_status,
      bucket: conn.assigns[:s3_bucket],
      key: conn.assigns[:s3_key]
    )

    conn
  end

  defp render_error(conn, %Error{} = err) do
    request_id = conn |> get_req_header("x-request-id") |> List.first()
    resource = RawPath.decoded_path(conn)
    err = %{err | request_id: request_id, resource: err.resource || resource}

    Log.warn("website endpoint error response",
      code: err.code,
      status: err.http_status,
      bucket: conn.assigns[:s3_bucket],
      key: conn.assigns[:s3_key]
    )

    if conn.method == "HEAD" do
      send_resp(conn, err.http_status, "")
    else
      conn
      |> put_resp_content_type("text/html")
      |> send_resp(err.http_status, default_error_html(err))
    end
  end

  defp default_error_html(%Error{} = err) do
    """
    <!DOCTYPE html>
    <html>
    <head><title>#{html_escape(err.http_status)} #{html_escape(err.code)}</title></head>
    <body>
      <h1>#{html_escape(err.code)}</h1>
      <p>#{html_escape(err.message)}</p>
      <p>Resource: #{html_escape(err.resource || "")}</p>
      <p>RequestId: #{html_escape(err.request_id || "")}</p>
    </body>
    </html>
    """
  end

  defp html_escape(value) do
    value
    |> to_string()
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
  end

  defp http_date(%DateTime{} = dt) do
    Calendar.strftime(dt, "%a, %d %b %Y %H:%M:%S GMT")
  end

  defp header(conn, name), do: conn |> get_req_header(name) |> List.first()
end
