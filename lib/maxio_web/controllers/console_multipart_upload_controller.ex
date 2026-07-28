defmodule MaxioWeb.ConsoleMultipartUploadController do
  @moduledoc """
  Console JSON API for browser-direct S3 multipart uploads.

  The Console process never receives object bytes here. It only validates the
  requested key/upload metadata and returns short-lived presigned S3 requests
  that the browser executes against the S3 endpoint.
  """
  use MaxioWeb, :controller

  alias Maxio.Auth.CredentialStore
  alias Maxio.Auth.SigV4.Presigner
  alias Maxio.Console.DirectMultipartUpload
  alias MaxioWeb.ConsoleDirectMultipartUploadForm
  alias Maxio.{Buckets, Multipart}
  alias Maxio.S3.{Log, SSE}

  @console_presign_max_expires 900
  @max_object_size 5 * 1_024 * 1_024 * 1_024 * 1_024
  @max_parts 10_000
  @max_sign_parts 1_000
  @max_list_parts 1_000
  @default_part_size 8 * 1_024 * 1_024
  @max_part_size 5 * 1_024 * 1_024 * 1_024
  @default_content_type "application/octet-stream"

  def initiate(conn, %{"bucket" => bucket, "key" => key_segments} = params) do
    key = object_key(key_segments)

    with :ok <- ensure_bucket(bucket),
         :ok <- validate_key(key),
         {:ok, size} <- parse_size(Map.get(params, "size")),
         {:ok, part_size} <- parse_part_size(Map.get(params, "part_size"), size),
         {:ok, expires} <- parse_expires(Map.get(params, "expires_in")),
         {:ok, content_type} <- parse_content_type(Map.get(params, "content_type")),
         {:ok, advanced} <- ConsoleDirectMultipartUploadForm.parse(params, content_type),
         {:ok, file_name} <- parse_file_name(Map.get(params, "file_name")),
         {:ok, file_last_modified} <-
           parse_file_last_modified(Map.get(params, "file_last_modified")),
         {:ok, registry_query} <-
           DirectMultipartUpload.registry_intent_query(%{
             file_name: file_name,
             file_size: size,
             file_last_modified: file_last_modified,
             part_size: part_size,
             request_payer: advanced.request_payer
           }),
         {:ok, url, endpoint_source} <-
           presign(conn, :post, bucket, key,
             query: Map.put(registry_query, "uploads", ""),
             headers: advanced.create_headers,
             expires: expires
           ) do
      Log.info("console direct multipart initiate presigned",
        action: :console_direct_multipart_initiate,
        bucket: bucket,
        key: key,
        size: size,
        part_size: part_size,
        file_last_modified: file_last_modified,
        request_payer: advanced.request_payer,
        endpoint_source: endpoint_source,
        signed_headers: Enum.map(advanced.create_headers, &elem(&1, 0)),
        principal_arn: conn.assigns.current_principal.arn
      )

      json(conn, %{
        bucket: bucket,
        key: key,
        size: size,
        part_size: part_size,
        file_name: file_name,
        file_last_modified: file_last_modified,
        max_parts: @max_parts,
        expires_in: expires,
        request_payer: advanced.request_payer,
        sse_customer_key_required: advanced.sse_customer_key_required,
        create: request(:post, url, advanced.create_headers)
      })
    else
      {:error, reason} -> error(conn, reason)
    end
  end

  def sign_parts(conn, %{"bucket" => bucket, "key" => key_segments} = params) do
    key = object_key(key_segments)

    with :ok <- ensure_bucket(bucket),
         :ok <- validate_key(key),
         {:ok, upload_id} <- parse_upload_id(Map.get(params, "upload_id")),
         {:ok, upload} <- ensure_upload_owner(conn, bucket, key, upload_id),
         {:ok, request_headers, _registry} <-
           direct_request_headers(conn, bucket, key, upload_id, upload, params),
         {:ok, part_numbers} <- parse_part_numbers(Map.get(params, "part_numbers")),
         {:ok, expires} <- parse_expires(Map.get(params, "expires_in")),
         {:ok, part_requests, endpoint_source} <-
           presign_part_requests(
             conn,
             bucket,
             key,
             upload_id,
             part_numbers,
             request_headers,
             expires
           ) do
      Log.info("console direct multipart parts presigned",
        action: :console_direct_multipart_sign_parts,
        bucket: bucket,
        key: key,
        upload_id: upload_id,
        part_count: length(part_numbers),
        endpoint_source: endpoint_source,
        principal_arn: conn.assigns.current_principal.arn
      )

      json(conn, %{
        bucket: bucket,
        key: key,
        upload_id: upload_id,
        expires_in: expires,
        parts: part_requests
      })
    else
      {:error, reason} -> error(conn, reason)
    end
  end

  def list_parts(conn, %{"bucket" => bucket, "key" => key_segments} = params) do
    key = object_key(key_segments)

    with :ok <- ensure_bucket(bucket),
         :ok <- validate_key(key),
         {:ok, upload_id} <- parse_upload_id(Map.get(params, "upload_id")),
         {:ok, _upload} <- ensure_upload_owner(conn, bucket, key, upload_id),
         {:ok, request_headers, _registry} <-
           direct_request_headers(conn, bucket, key, upload_id),
         {:ok, marker} <- parse_part_number_marker(Map.get(params, "part_number_marker")),
         {:ok, max_parts} <- parse_list_max_parts(Map.get(params, "max_parts")),
         {:ok, expires} <- parse_expires(Map.get(params, "expires_in")),
         {:ok, url, endpoint_source} <-
           presign(conn, :get, bucket, key,
             query:
               marker_query(%{
                 "uploadId" => upload_id,
                 "part-number-marker" => marker,
                 "max-parts" => max_parts
               }),
             headers: request_headers,
             expires: expires
           ) do
      Log.info("console direct multipart list parts presigned",
        action: :console_direct_multipart_list_parts,
        bucket: bucket,
        key: key,
        upload_id: upload_id,
        part_number_marker: marker,
        max_parts: max_parts,
        endpoint_source: endpoint_source,
        principal_arn: conn.assigns.current_principal.arn
      )

      json(conn, %{
        bucket: bucket,
        key: key,
        upload_id: upload_id,
        expires_in: expires,
        part_number_marker: marker,
        max_parts: max_parts,
        list_parts: request(:get, url, request_headers)
      })
    else
      {:error, reason} -> error(conn, reason)
    end
  end

  def register(conn, %{"bucket" => bucket, "key" => key_segments} = params) do
    key = object_key(key_segments)

    with :ok <- ensure_bucket(bucket),
         :ok <- validate_key(key),
         {:ok, upload_id} <- parse_upload_id(Map.get(params, "upload_id")),
         {:ok, upload} <- ensure_upload_owner(conn, bucket, key, upload_id),
         {:ok, size} <- parse_size(Map.get(params, "size")),
         {:ok, part_size} <- parse_registered_part_size(Map.get(params, "part_size"), size),
         {:ok, file_name} <- parse_file_name(Map.get(params, "file_name")),
         {:ok, file_last_modified} <-
           parse_file_last_modified(Map.get(params, "file_last_modified")),
         {:ok, request_payer} <- parse_request_payer(Map.get(params, "request_payer")),
         {:ok, registry} <-
           DirectMultipartUpload.register(upload, %{
             principal_arn: conn.assigns.current_principal.arn,
             access_key: console_access_key(conn.assigns.current_principal),
             file_name: file_name,
             file_size: size,
             file_last_modified: file_last_modified,
             part_size: part_size,
             request_payer: request_payer
           }) do
      Log.info("console direct multipart registered",
        action: :console_direct_multipart_register,
        bucket: bucket,
        key: key,
        upload_id: upload_id,
        size: size,
        part_size: part_size,
        principal_arn: conn.assigns.current_principal.arn
      )

      json(conn, %{
        bucket: bucket,
        key: key,
        upload_id: upload_id,
        session: session_payload(registry)
      })
    else
      {:error, %Ecto.Changeset{}} -> error(conn, :invalid_registry)
      {:error, reason} -> error(conn, reason)
    end
  end

  def lookup(conn, %{"bucket" => bucket, "key" => key_segments} = params) do
    key = object_key(key_segments)

    with :ok <- ensure_bucket(bucket),
         :ok <- validate_key(key),
         {:ok, size} <- parse_size(Map.get(params, "size")),
         {:ok, file_last_modified} <-
           parse_file_last_modified(Map.get(params, "file_last_modified")),
         {:ok, registry} <-
           DirectMultipartUpload.lookup_for_file(
             bucket,
             key,
             conn.assigns.current_principal.arn,
             size,
             file_last_modified
           ) do
      Log.info("console direct multipart registry lookup",
        action: :console_direct_multipart_lookup,
        bucket: bucket,
        key: key,
        upload_id: registry.upload_id,
        principal_arn: conn.assigns.current_principal.arn,
        part_count: registry.part_count
      )

      json(conn, %{
        bucket: bucket,
        key: key,
        upload_id: registry.upload_id,
        session: session_payload(registry)
      })
    else
      {:error, :not_found} -> error(conn, :registered_upload_not_found)
      {:error, reason} -> error(conn, reason)
    end
  end

  def complete(conn, %{"bucket" => bucket, "key" => key_segments} = params) do
    key = object_key(key_segments)

    with :ok <- ensure_bucket(bucket),
         :ok <- validate_key(key),
         {:ok, upload_id} <- parse_upload_id(Map.get(params, "upload_id")),
         {:ok, upload} <- ensure_upload_owner(conn, bucket, key, upload_id),
         {:ok, request_headers, registry} <-
           direct_request_headers(conn, bucket, key, upload_id, upload, params),
         {:ok, parts} <- parse_complete_parts(Map.get(params, "parts")),
         {:ok, expires} <- parse_expires(Map.get(params, "expires_in")),
         complete_body = complete_xml(parts),
         complete_md5 = md5_b64(complete_body),
         complete_headers = complete_headers(complete_md5, request_headers, registry),
         {:ok, url, endpoint_source} <-
           presign(conn, :post, bucket, key,
             query: marker_query(%{"uploadId" => upload_id}),
             headers: complete_headers,
             expires: expires
           ) do
      Log.info("console direct multipart complete presigned",
        action: :console_direct_multipart_complete,
        bucket: bucket,
        key: key,
        upload_id: upload_id,
        part_count: length(parts),
        endpoint_source: endpoint_source,
        principal_arn: conn.assigns.current_principal.arn
      )

      json(conn, %{
        bucket: bucket,
        key: key,
        upload_id: upload_id,
        expires_in: expires,
        complete:
          request(
            :post,
            url,
            complete_headers,
            complete_body
          )
      })
    else
      {:error, reason} -> error(conn, reason)
    end
  end

  def abort(conn, %{"bucket" => bucket, "key" => key_segments} = params) do
    key = object_key(key_segments)

    with :ok <- ensure_bucket(bucket),
         :ok <- validate_key(key),
         {:ok, upload_id} <- parse_upload_id(Map.get(params, "upload_id")),
         {:ok, _upload} <- ensure_upload_owner(conn, bucket, key, upload_id),
         {:ok, request_headers, _registry} <-
           direct_request_headers(conn, bucket, key, upload_id),
         {:ok, expires} <- parse_expires(Map.get(params, "expires_in")),
         {:ok, url, endpoint_source} <-
           presign(conn, :delete, bucket, key,
             query: marker_query(%{"uploadId" => upload_id}),
             headers: request_headers,
             expires: expires
           ) do
      Log.info("console direct multipart abort presigned",
        action: :console_direct_multipart_abort,
        bucket: bucket,
        key: key,
        upload_id: upload_id,
        endpoint_source: endpoint_source,
        principal_arn: conn.assigns.current_principal.arn
      )

      json(conn, %{
        bucket: bucket,
        key: key,
        upload_id: upload_id,
        expires_in: expires,
        abort: request(:delete, url, request_headers)
      })
    else
      {:error, reason} -> error(conn, reason)
    end
  end

  defp presign_part_requests(
         conn,
         bucket,
         key,
         upload_id,
         part_numbers,
         request_headers,
         expires
       ) do
    Enum.reduce_while(part_numbers, {:ok, [], nil}, fn part_number, {:ok, acc, source} ->
      case presign(conn, :put, bucket, key,
             query:
               marker_query(%{
                 "partNumber" => part_number,
                 "uploadId" => upload_id
               }),
             headers: request_headers,
             expires: expires
           ) do
        {:ok, url, endpoint_source} ->
          part = request(:put, url, request_headers) |> Map.put(:part_number, part_number)
          {:cont, {:ok, [part | acc], source || endpoint_source}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, parts, endpoint_source} -> {:ok, Enum.reverse(parts), endpoint_source}
      {:error, _reason} = error -> error
    end
  end

  defp presign(conn, method, bucket, key, opts) do
    principal = conn.assigns.current_principal
    access_key = Map.get(principal, :session_access_key) || Map.fetch!(principal, :access_key)
    {base_url, endpoint_source} = s3_public_base_url()

    credentials_opts =
      case principal_session_token(principal) do
        nil -> []
        token -> [session_token: token]
      end

    with {:ok, %{secret_key: secret_key}} <-
           CredentialStore.get_secret(access_key, credentials_opts),
         {:ok, url} <-
           Presigner.presign_url(
             method,
             base_url,
             "/" <> bucket <> "/" <> key,
             presign_credentials(access_key, secret_key, principal),
             opts
           ) do
      {:ok, url, endpoint_source}
    else
      :error -> {:error, :credential_unavailable}
      {:error, :invalid_base_url} -> {:error, :invalid_public_url}
      {:error, reason} -> {:error, reason}
    end
  end

  defp presign_credentials(access_key, secret_key, principal) do
    credentials = %{access_key: access_key, secret_key: secret_key}

    case principal_session_token(principal) do
      nil -> credentials
      token -> Map.put(credentials, :session_token, token)
    end
  end

  defp principal_session_token(principal) do
    case Map.get(principal, :session_token) || Map.get(principal, "session_token") do
      token when is_binary(token) and token != "" -> token
      _other -> nil
    end
  end

  defp request(method, url, headers, body \\ nil) do
    %{
      method: method |> Atom.to_string() |> String.upcase(),
      url: url,
      headers: Enum.map(headers, fn {name, value} -> %{"name" => name, "value" => value} end)
    }
    |> maybe_put_body(body)
  end

  defp maybe_put_body(map, nil), do: map
  defp maybe_put_body(map, body), do: Map.put(map, :body, body)

  defp session_payload(registry) do
    %{
      registry_id: registry.id,
      upload_id: registry.upload_id,
      part_size: registry.part_size,
      size: registry.file_size,
      file_name: registry.file_name,
      file_last_modified: registry.file_last_modified,
      request_payer: registry.request_payer || false,
      sse_customer_key_required: registry_sse_customer_key_required?(registry),
      part_count: registry.part_count,
      uploaded_size: registry.uploaded_size,
      uploaded_parts: []
    }
  end

  defp registry_sse_customer_key_required?(%{multipart_upload: %{sse_algorithm: "SSE-C"}}),
    do: true

  defp registry_sse_customer_key_required?(%{
         bucket_name: bucket,
         key: key,
         upload_id: upload_id
       }) do
    case Multipart.get_upload(bucket, key, upload_id) do
      {:ok, %{sse_algorithm: "SSE-C"}} -> true
      _other -> false
    end
  end

  defp direct_request_headers(conn, bucket, key, upload_id) do
    case DirectMultipartUpload.get_owned(
           bucket,
           key,
           upload_id,
           conn.assigns.current_principal.arn
         ) do
      {:ok, registry} ->
        {:ok, registry_request_headers(registry), registry}

      {:error, :not_found} ->
        {:ok, [], nil}
    end
  end

  defp direct_request_headers(conn, bucket, key, upload_id, upload, params) do
    with {:ok, registry_headers, registry} <- direct_request_headers(conn, bucket, key, upload_id),
         {:ok, sse_headers} <- ConsoleDirectMultipartUploadForm.sse_customer_headers(params),
         :ok <- validate_sse_customer_headers(upload, sse_headers) do
      {:ok, registry_headers ++ sse_headers, registry}
    end
  end

  defp validate_sse_customer_headers(%{sse_algorithm: "SSE-C"}, []),
    do: {:error, :sse_customer_key_required}

  defp validate_sse_customer_headers(%{sse_algorithm: "SSE-C"} = upload, headers) do
    _customer_key =
      SSE.resolve_customer_read!(headers, upload.sse_envelope,
        resource: "/" <> upload.bucket_name <> "/" <> upload.key
      )

    :ok
  rescue
    _error in [Maxio.S3.Error] -> {:error, :invalid_sse}
  end

  defp validate_sse_customer_headers(_upload, []), do: :ok
  defp validate_sse_customer_headers(_upload, _headers), do: {:error, :invalid_sse}

  defp registry_request_headers(%{request_payer: true}),
    do: [{"x-amz-request-payer", "requester"}]

  defp registry_request_headers(_registry), do: []

  defp complete_headers(content_md5, request_headers, registry) do
    [{"content-type", "application/xml"}, {"content-md5", content_md5}]
    |> maybe_put_complete_object_size(registry)
    |> Kernel.++(request_headers)
  end

  defp maybe_put_complete_object_size(headers, %{file_size: size}) when is_integer(size) do
    headers ++ [{"x-amz-mp-object-size", Integer.to_string(size)}]
  end

  defp maybe_put_complete_object_size(headers, _registry), do: headers

  defp ensure_bucket(bucket) do
    case Buckets.lookup(bucket) do
      {:ok, _bucket} -> :ok
      {:error, :not_found} -> {:error, :not_found}
    end
  end

  defp validate_key(""), do: {:error, :invalid_key}

  defp validate_key(key) do
    case Maxio.Cluster.Paths.validate_key(key) do
      :ok -> :ok
      {:error, _reason} -> {:error, :invalid_key}
    end
  end

  defp ensure_upload_owner(conn, bucket, key, upload_id) do
    case Multipart.get_upload(bucket, key, upload_id) do
      {:ok, upload} ->
        if upload.owner == conn.assigns.current_principal.arn do
          {:ok, upload}
        else
          {:error, :access_denied}
        end

      {:error, :not_found} ->
        {:error, :no_such_upload}
    end
  end

  defp object_key(segments) when is_list(segments), do: Enum.join(segments, "/")

  defp console_access_key(principal) do
    Map.get(principal, :session_access_key) || Map.fetch!(principal, :access_key)
  end

  defp parse_size(value) when is_integer(value) and value in 1..@max_object_size, do: {:ok, value}

  defp parse_size(value) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} when integer in 1..@max_object_size -> {:ok, integer}
      _other -> {:error, :invalid_size}
    end
  end

  defp parse_size(_value), do: {:error, :invalid_size}

  defp parse_part_size(nil, size), do: parse_part_size(@default_part_size, size)
  defp parse_part_size("", size), do: parse_part_size(@default_part_size, size)

  defp parse_part_size(value, size) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} -> parse_part_size(integer, size)
      _other -> {:error, :invalid_part_size}
    end
  end

  defp parse_part_size(value, size) when is_integer(value) do
    min_part_size = multipart_min_part_size()
    required_by_part_count = div(size + @max_parts - 1, @max_parts)
    part_size = value |> max(min_part_size) |> max(required_by_part_count)

    cond do
      value < 1 ->
        {:error, :invalid_part_size}

      part_size > @max_part_size ->
        {:error, :invalid_part_size}

      div(size + part_size - 1, part_size) > @max_parts ->
        {:error, :too_many_parts}

      true ->
        {:ok, part_size}
    end
  end

  defp parse_part_size(_value, _size), do: {:error, :invalid_part_size}

  defp parse_registered_part_size(value, size) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} -> parse_registered_part_size(integer, size)
      _other -> {:error, :invalid_part_size}
    end
  end

  defp parse_registered_part_size(value, size) when is_integer(value) do
    cond do
      value < 1 ->
        {:error, :invalid_part_size}

      value > @max_part_size ->
        {:error, :invalid_part_size}

      div(size + value - 1, value) > @max_parts ->
        {:error, :too_many_parts}

      true ->
        {:ok, value}
    end
  end

  defp parse_registered_part_size(_value, _size), do: {:error, :invalid_part_size}

  defp multipart_min_part_size do
    Application.get_env(:maxio, :multipart_min_part_size, 5_242_880)
  end

  defp parse_expires(nil), do: {:ok, 900}
  defp parse_expires(""), do: {:ok, 900}

  defp parse_expires(value) when is_integer(value) and value in 1..@console_presign_max_expires,
    do: {:ok, value}

  defp parse_expires(value) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} when integer in 1..@console_presign_max_expires -> {:ok, integer}
      _other -> {:error, :invalid_expires}
    end
  end

  defp parse_expires(_value), do: {:error, :invalid_expires}

  defp parse_content_type(nil), do: {:ok, @default_content_type}
  defp parse_content_type(""), do: {:ok, @default_content_type}

  defp parse_content_type(value) when is_binary(value) do
    value = String.trim(value)

    cond do
      value == "" -> {:ok, @default_content_type}
      byte_size(value) > 512 -> {:error, :invalid_content_type}
      String.contains?(value, ["\r", "\n", <<0>>]) -> {:error, :invalid_content_type}
      true -> {:ok, value}
    end
  end

  defp parse_content_type(_value), do: {:error, :invalid_content_type}

  defp parse_file_name(value) when is_binary(value) do
    value = String.trim(value)

    cond do
      value == "" -> {:error, :invalid_file_name}
      byte_size(value) > 1024 -> {:error, :invalid_file_name}
      String.contains?(value, ["\r", "\n", <<0>>]) -> {:error, :invalid_file_name}
      true -> {:ok, value}
    end
  end

  defp parse_file_name(_value), do: {:error, :invalid_file_name}

  defp parse_file_last_modified(value) when is_integer(value) and value >= 0,
    do: {:ok, value}

  defp parse_file_last_modified(value) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} when integer >= 0 -> {:ok, integer}
      _other -> {:error, :invalid_file_last_modified}
    end
  end

  defp parse_file_last_modified(_value), do: {:error, :invalid_file_last_modified}

  defp parse_request_payer(value) when value in [true, "true", "1", "requester"],
    do: {:ok, true}

  defp parse_request_payer(value) when value in [false, nil, "", "false", "0"],
    do: {:ok, false}

  defp parse_request_payer(_value), do: {:error, :invalid_request_payer}

  defp parse_upload_id(value) when is_binary(value) do
    value = String.trim(value)

    cond do
      value == "" -> {:error, :invalid_upload_id}
      byte_size(value) > 512 -> {:error, :invalid_upload_id}
      String.contains?(value, ["\r", "\n", <<0>>]) -> {:error, :invalid_upload_id}
      true -> {:ok, value}
    end
  end

  defp parse_upload_id(_value), do: {:error, :invalid_upload_id}

  defp parse_part_numbers(part_numbers) when is_list(part_numbers) do
    part_numbers
    |> Enum.reduce_while({:ok, []}, fn value, {:ok, acc} ->
      case parse_part_number(value) do
        {:ok, number} -> {:cont, {:ok, [number | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, numbers} ->
        numbers = Enum.reverse(numbers)

        cond do
          numbers == [] -> {:error, :invalid_part_numbers}
          length(numbers) > @max_sign_parts -> {:error, :too_many_parts}
          length(Enum.uniq(numbers)) != length(numbers) -> {:error, :invalid_part_numbers}
          true -> {:ok, numbers}
        end

      {:error, _reason} = error ->
        error
    end
  end

  defp parse_part_numbers(_part_numbers), do: {:error, :invalid_part_numbers}

  defp parse_part_number(value) when is_integer(value) and value in 1..@max_parts,
    do: {:ok, value}

  defp parse_part_number(value) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} when integer in 1..@max_parts -> {:ok, integer}
      _other -> {:error, :invalid_part_numbers}
    end
  end

  defp parse_part_number(_value), do: {:error, :invalid_part_numbers}

  defp parse_part_number_marker(nil), do: {:ok, 0}
  defp parse_part_number_marker(""), do: {:ok, 0}

  defp parse_part_number_marker(value) when is_integer(value) and value in 0..@max_parts,
    do: {:ok, value}

  defp parse_part_number_marker(value) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} when integer in 0..@max_parts -> {:ok, integer}
      _other -> {:error, :invalid_part_number_marker}
    end
  end

  defp parse_part_number_marker(_value), do: {:error, :invalid_part_number_marker}

  defp parse_list_max_parts(nil), do: {:ok, @max_list_parts}
  defp parse_list_max_parts(""), do: {:ok, @max_list_parts}

  defp parse_list_max_parts(value)
       when is_integer(value) and value in 1..@max_list_parts,
       do: {:ok, value}

  defp parse_list_max_parts(value) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} when integer in 1..@max_list_parts -> {:ok, integer}
      _other -> {:error, :invalid_max_parts}
    end
  end

  defp parse_list_max_parts(_value), do: {:error, :invalid_max_parts}

  defp parse_complete_parts(parts) when is_list(parts) do
    parts
    |> Enum.reduce_while({:ok, []}, fn part, {:ok, acc} ->
      case parse_complete_part(part) do
        {:ok, parsed} -> {:cont, {:ok, [parsed | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, parsed} ->
        parsed = Enum.reverse(parsed)
        numbers = Enum.map(parsed, & &1.part_number)

        cond do
          parsed == [] -> {:error, :invalid_parts}
          length(parsed) > @max_parts -> {:error, :too_many_parts}
          numbers != Enum.sort(numbers) -> {:error, :invalid_part_order}
          length(Enum.uniq(numbers)) != length(numbers) -> {:error, :invalid_part_order}
          true -> {:ok, parsed}
        end

      {:error, _reason} = error ->
        error
    end
  end

  defp parse_complete_parts(_parts), do: {:error, :invalid_parts}

  defp parse_complete_part(%{"part_number" => part_number, "etag" => etag}) do
    with {:ok, part_number} <- parse_part_number(part_number),
         {:ok, etag} <- parse_etag(etag) do
      {:ok, %{part_number: part_number, etag: etag}}
    end
  end

  defp parse_complete_part(%{"PartNumber" => part_number, "ETag" => etag}) do
    parse_complete_part(%{"part_number" => part_number, "etag" => etag})
  end

  defp parse_complete_part(_part), do: {:error, :invalid_parts}

  defp parse_etag(value) when is_binary(value) do
    value = value |> String.trim() |> String.trim("\"")

    cond do
      value == "" -> {:error, :invalid_etag}
      not Regex.match?(~r/^[0-9a-fA-F]{32}$/, value) -> {:error, :invalid_etag}
      true -> {:ok, String.downcase(value)}
    end
  end

  defp parse_etag(_value), do: {:error, :invalid_etag}

  defp complete_xml(parts) do
    parts =
      Enum.map(parts, fn %{part_number: part_number, etag: etag} ->
        [
          "<Part><PartNumber>",
          Integer.to_string(part_number),
          "</PartNumber><ETag>\"",
          etag,
          "\"</ETag></Part>"
        ]
      end)

    IO.iodata_to_binary(["<CompleteMultipartUpload>", parts, "</CompleteMultipartUpload>"])
  end

  defp marker_query(query), do: DirectMultipartUpload.marker_query(query)

  defp md5_b64(body), do: :crypto.hash(:md5, body) |> Base.encode64()

  defp s3_public_base_url do
    console_config = Application.get_env(:maxio, :console, [])
    s3_config = Application.get_env(:maxio, :s3, [])

    cond do
      public_url?(Keyword.get(console_config, :s3_public_url)) ->
        {String.trim_trailing(Keyword.fetch!(console_config, :s3_public_url), "/"),
         :console_s3_public_url}

      public_url?(Keyword.get(s3_config, :public_url)) ->
        {String.trim_trailing(Keyword.fetch!(s3_config, :public_url), "/"), :s3_public_url}

      true ->
        scheme = Keyword.get(s3_config, :scheme, "http")
        host = Keyword.get(s3_config, :domain, "localhost")
        endpoint = Application.get_env(:maxio, Maxio.S3.Endpoint, [])
        port = Keyword.get(endpoint, :port, 9000)
        {scheme <> "://" <> host <> port_suffix(scheme, port), :derived}
    end
  end

  defp public_url?(url), do: is_binary(url) and url != ""

  defp port_suffix("http", 80), do: ""
  defp port_suffix("https", 443), do: ""
  defp port_suffix(_scheme, nil), do: ""
  defp port_suffix(_scheme, port), do: ":" <> to_string(port)

  defp error(conn, reason) do
    {status, message} = error_status_message(reason)

    Log.warn("console direct multipart request rejected",
      action: :console_direct_multipart_error,
      reason: reason,
      status: status
    )

    conn
    |> put_status(status)
    |> json(%{error: Atom.to_string(reason), message: message})
  end

  defp error_status_message(:not_found), do: {:not_found, "bucket not found"}
  defp error_status_message(:no_such_upload), do: {:not_found, "multipart upload not found"}

  defp error_status_message(:registered_upload_not_found),
    do: {:not_found, "registered upload not found"}

  defp error_status_message(:ambiguous_upload),
    do: {:conflict, "multiple registered uploads match this file"}

  defp error_status_message(:access_denied), do: {:forbidden, "multipart upload access denied"}

  defp error_status_message(:credential_unavailable),
    do: {:service_unavailable, "credential unavailable"}

  defp error_status_message(:invalid_public_url), do: {:bad_request, "S3 public URL is invalid"}
  defp error_status_message(:invalid_key), do: {:bad_request, "object key is invalid"}
  defp error_status_message(:invalid_size), do: {:bad_request, "object size is invalid"}

  defp error_status_message(:invalid_part_size),
    do: {:bad_request, "multipart part size is invalid"}

  defp error_status_message(:too_many_parts),
    do: {:bad_request, "multipart part count is too large"}

  defp error_status_message(:invalid_expires), do: {:bad_request, "expiration is invalid"}
  defp error_status_message(:invalid_content_type), do: {:bad_request, "content type is invalid"}
  defp error_status_message(:invalid_file_name), do: {:bad_request, "file name is invalid"}

  defp error_status_message(:invalid_file_last_modified),
    do: {:bad_request, "file last modified timestamp is invalid"}

  defp error_status_message(:invalid_registry), do: {:bad_request, "upload registry is invalid"}

  defp error_status_message(:invalid_request_payer),
    do: {:bad_request, "request payer is invalid"}

  defp error_status_message(:invalid_upload_id), do: {:bad_request, "upload id is invalid"}
  defp error_status_message(:invalid_part_numbers), do: {:bad_request, "part numbers are invalid"}

  defp error_status_message(:invalid_part_number_marker),
    do: {:bad_request, "part number marker is invalid"}

  defp error_status_message(:invalid_max_parts),
    do: {:bad_request, "max parts is invalid"}

  defp error_status_message(:invalid_part_order),
    do: {:bad_request, "parts must be sorted by part number"}

  defp error_status_message(:invalid_parts), do: {:bad_request, "complete parts are invalid"}
  defp error_status_message(:invalid_etag), do: {:bad_request, "part etag is invalid"}

  defp error_status_message(:invalid_storage_class),
    do: {:bad_request, "storage class is invalid"}

  defp error_status_message(:invalid_metadata), do: {:bad_request, "metadata is invalid"}
  defp error_status_message(:invalid_tag), do: {:bad_request, "tags are invalid"}
  defp error_status_message(:invalid_sse), do: {:bad_request, "SSE settings are invalid"}

  defp error_status_message(:sse_customer_key_required),
    do: {:bad_request, "SSE-C customer key is required for this multipart upload"}

  defp error_status_message(:invalid_checksum),
    do: {:bad_request, "checksum settings are invalid"}

  defp error_status_message(:invalid_field), do: {:bad_request, "advanced field is invalid"}
  defp error_status_message(:reserved_query_param), do: {:bad_request, "reserved query parameter"}
  defp error_status_message(:reserved_signed_header), do: {:bad_request, "reserved signed header"}

  defp error_status_message(:invalid_signed_header),
    do: {:bad_request, "signed header is invalid"}

  defp error_status_message(:duplicate_signed_header),
    do: {:bad_request, "duplicate signed header"}

  defp error_status_message(_reason), do: {:bad_request, "request is invalid"}
end
