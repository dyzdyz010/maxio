defmodule Maxio.S3.PostObjectForm do
  @moduledoc """
  Streaming parser and SigV4 policy verifier for S3 POST Object forms.

  The parser buffers only form fields that appear before the `file` part. The
  file bytes are returned as an enumerable that strips the terminating multipart
  boundary while it is consumed by the normal PutObject storage path.
  """

  import Plug.Conn

  alias Maxio.Auth.CredentialStore
  alias Maxio.Auth.SigV4.Signer
  alias Maxio.S3.{Error, Log}
  alias Maxio.S3.RequestParsers.Tagging, as: TaggingParser

  @algorithm "AWS4-HMAC-SHA256"
  @service "s3"
  @read_opts [length: 1_048_576, read_length: 1_048_576, read_timeout: 30_000]
  @field_limit 20_480
  @field_count_limit 128
  @policy_limit 65_536
  @boundary_limit 200

  @auth_fields ~w(policy x-amz-signature x-amz-algorithm x-amz-credential x-amz-date x-amz-security-token)
  @coverage_exempt ~w(file policy x-amz-signature)
  @control_fields MapSet.new(
                    ~w(key bucket file policy x-amz-signature x-amz-algorithm x-amz-credential x-amz-date x-amz-security-token success_action_status success_action_redirect redirect)
                  )
  @direct_header_fields %{
    "acl" => "x-amz-acl",
    "Cache-Control" => "cache-control",
    "cache-control" => "cache-control",
    "Content-Type" => "content-type",
    "content-type" => "content-type",
    "Content-Disposition" => "content-disposition",
    "content-disposition" => "content-disposition",
    "Content-Encoding" => "content-encoding",
    "content-encoding" => "content-encoding",
    "Expires" => "expires",
    "expires" => "expires",
    "Content-MD5" => "content-md5",
    "content-md5" => "content-md5"
  }
  @case_insensitive_control_fields MapSet.new(MapSet.to_list(@control_fields) ++ @coverage_exempt)

  @type prepared :: %{
          required(:fields) => map(),
          required(:key) => String.t(),
          required(:filename) => String.t(),
          required(:file_stream) => Enumerable.t(),
          required(:principal) => map() | :anonymous,
          required(:auth_type) => :anonymous | :post,
          required(:object_headers) => [{String.t(), String.t()}],
          required(:signed_headers) => [String.t()],
          required(:content_length_range) => nil | {non_neg_integer(), non_neg_integer()},
          required(:success) => map()
        }

  @spec prepare!(Plug.Conn.t(), String.t()) :: prepared()
  def prepare!(conn, bucket) when is_binary(bucket) do
    parsed = parse!(conn)
    key = expand_key!(Map.get(parsed.fields, "key"), parsed.filename, bucket)
    now = conn.private[:maxio_now] || DateTime.utc_now()

    auth =
      authenticate!(parsed.fields, bucket, key, now)

    object_headers = object_headers!(parsed.fields, conn.req_headers)
    signed_headers = signed_headers(object_headers, auth.covered_fields)

    %{
      fields: parsed.fields,
      key: key,
      filename: parsed.filename,
      file_stream: parsed.file_stream,
      principal: auth.principal,
      auth_type: auth.auth_type,
      object_headers: object_headers,
      signed_headers: signed_headers,
      content_length_range: auth.content_length_range,
      success: success_action!(parsed.fields)
    }
  end

  @spec body_source(prepared()) ::
          {Enumerable.t(), (-> %{String.t() => String.t()}), (-> :ok)}
  def body_source(%{file_stream: stream, content_length_range: nil}) do
    {stream, fn -> %{} end, fn -> :ok end}
  end

  def body_source(%{file_stream: stream, content_length_range: {min, max}}) do
    {:ok, agent} = Agent.start_link(fn -> 0 end)

    counted =
      Stream.map(stream, fn chunk ->
        size = IO.iodata_length(chunk)

        total =
          Agent.get_and_update(agent, fn current ->
            updated = current + size
            {updated, updated}
          end)

        if total > max do
          stop_agent(agent)
          raise Error.new(:entity_too_large)
        end

        chunk
      end)

    final =
      Stream.resource(
        fn -> :check end,
        fn
          :check ->
            total = Agent.get(agent, & &1)
            stop_agent(agent)

            if total < min do
              raise Error.new(:entity_too_small)
            end

            {:halt, :done}

          :done ->
            {:halt, :done}
        end,
        fn _ -> stop_agent(agent) end
      )

    {Stream.concat(counted, final), fn -> %{} end, fn -> stop_agent(agent) end}
  end

  defp parse!(conn) do
    boundary = boundary!(header(conn, "content-type"))
    reader = %{conn: conn, boundary: boundary, buffer: "", eof?: false}

    reader
    |> expect_initial_boundary!()
    |> read_parts(%{}, nil, new_field_budget())
  end

  defp read_parts(_reader, _fields, %{stream: _stream} = _file, _field_budget) do
    raise Error.new(:malformed_post_request, message: "Multiple file fields are not supported")
  end

  defp read_parts(reader, fields, nil, field_budget) do
    {headers, header_bytes, reader} = read_part_headers!(reader)
    disposition = parse_content_disposition!(Map.get(headers, "content-disposition"))
    name = Map.fetch!(disposition, "name")

    if canonical_form_field_name(name) == "file" do
      filename = safe_filename(Map.get(disposition, "filename", ""))

      %{
        fields: fields,
        filename: filename,
        file_stream: file_stream(reader)
      }
    else
      field_budget =
        field_budget
        |> count_form_field!()
        |> add_form_field_bytes!(multipart_field_overhead(reader.boundary, header_bytes, name))

      {value, reader, final?} = read_field_value!(reader)
      field_budget = add_form_field_bytes!(field_budget, byte_size(value) + 2)

      fields = put_field!(fields, name, value)

      if final? do
        raise Error.new(:malformed_post_request, message: "POST form is missing file field")
      end

      read_parts(reader, fields, nil, field_budget)
    end
  end

  defp new_field_budget, do: %{bytes: 0, count: 0}

  defp count_form_field!(budget) do
    budget = %{budget | count: budget.count + 1}

    if budget.count > @field_count_limit do
      raise Error.new(:malformed_post_request, message: "POST form has too many fields")
    end

    budget
  end

  defp add_form_field_bytes!(budget, bytes) do
    budget = %{budget | bytes: budget.bytes + bytes}

    if budget.bytes > @field_limit do
      raise Error.new(:malformed_post_request, message: "POST form fields are too large")
    end

    budget
  end

  defp multipart_field_overhead(boundary, header_bytes, name) do
    byte_size("--") + byte_size(boundary) + byte_size("\r\n") + header_bytes + byte_size(name)
  end

  defp expect_initial_boundary!(reader) do
    {line, reader} = read_until!(reader, "\r\n", @boundary_limit + 4)
    expected = "--" <> reader.boundary

    if line == expected do
      reader
    else
      raise Error.new(:malformed_post_request, message: "POST body does not start with boundary")
    end
  end

  defp read_part_headers!(reader) do
    {raw, reader} = read_until!(reader, "\r\n\r\n", @field_limit)
    header_bytes = byte_size(raw) + byte_size("\r\n\r\n")

    headers =
      raw
      |> String.split("\r\n", trim: true)
      |> Enum.reduce(%{}, fn line, acc ->
        case String.split(line, ":", parts: 2) do
          [name, value] ->
            key = name |> String.trim() |> String.downcase()

            if key == "" or Map.has_key?(acc, key) do
              raise Error.new(:malformed_post_request, message: "Invalid multipart headers")
            end

            Map.put(acc, key, String.trim_leading(value))

          _other ->
            raise Error.new(:malformed_post_request, message: "Invalid multipart headers")
        end
      end)

    {headers, header_bytes, reader}
  end

  defp read_field_value!(reader) do
    marker = "\r\n--" <> reader.boundary
    {value, reader} = read_until!(reader, marker, @field_limit)
    {boundary_state, reader} = consume_boundary_suffix!(reader)
    {value, reader, boundary_state == :final}
  end

  defp file_stream(reader) do
    marker = "\r\n--" <> reader.boundary
    keep = byte_size(marker) - 1

    Stream.resource(
      fn -> {:data, reader} end,
      fn
        :done ->
          {:halt, :done}

        {:finish, reader} ->
          finish_file_stream!(reader)
          {:halt, :done}

        {:data, reader} ->
          file_stream_step(reader, marker, keep)
      end,
      fn _ -> :ok end
    )
  end

  defp file_stream_step(reader, marker, keep) do
    reader = ensure_search_buffer(reader, marker)

    case :binary.match(reader.buffer, marker) do
      {idx, len} ->
        prefix = binary_part(reader.buffer, 0, idx)
        rest = binary_part(reader.buffer, idx + len, byte_size(reader.buffer) - idx - len)
        reader = %{reader | buffer: rest}

        if prefix == "" do
          finish_file_stream!(reader)
          {[], :done}
        else
          {[prefix], {:finish, reader}}
        end

      :nomatch ->
        cond do
          reader.eof? ->
            raise Error.new(:malformed_post_request, message: "POST file boundary is missing")

          byte_size(reader.buffer) > keep ->
            emit = byte_size(reader.buffer) - keep
            chunk = binary_part(reader.buffer, 0, emit)
            rest = binary_part(reader.buffer, emit, keep)
            {[chunk], {:data, %{reader | buffer: rest}}}

          true ->
            file_stream_step(fill!(reader), marker, keep)
        end
    end
  end

  defp ensure_search_buffer(%{eof?: true} = reader, _marker), do: reader

  defp ensure_search_buffer(reader, marker) do
    if byte_size(reader.buffer) >= byte_size(marker) do
      reader
    else
      reader |> fill!() |> ensure_search_buffer(marker)
    end
  end

  defp finish_file_stream!(reader) do
    {state, reader} = consume_boundary_suffix!(reader)

    if state == :final do
      drain_after_final_boundary!(reader)
    else
      raise Error.new(:malformed_post_request, message: "The file field must be the last field")
    end
  end

  defp consume_boundary_suffix!(reader) do
    reader = ensure_buffer!(reader, 2)

    cond do
      String.starts_with?(reader.buffer, "--") ->
        rest = binary_part(reader.buffer, 2, byte_size(reader.buffer) - 2)
        {:final, %{reader | buffer: rest}}

      String.starts_with?(reader.buffer, "\r\n") ->
        rest = binary_part(reader.buffer, 2, byte_size(reader.buffer) - 2)
        {:next, %{reader | buffer: rest}}

      true ->
        raise Error.new(:malformed_post_request, message: "Invalid multipart boundary")
    end
  end

  defp drain_after_final_boundary!(reader) do
    reader = drain_to_eof!(reader, @boundary_limit)
    buffer = consume_optional_crlf(reader.buffer)

    if buffer != "" do
      raise Error.new(:malformed_post_request, message: "Unexpected bytes after final boundary")
    end

    :ok
  end

  defp drain_to_eof!(reader, limit) do
    cond do
      byte_size(reader.buffer) > limit ->
        raise Error.new(:malformed_post_request, message: "Unexpected bytes after final boundary")

      reader.eof? ->
        reader

      true ->
        reader |> fill!() |> drain_to_eof!(limit)
    end
  end

  defp consume_optional_crlf("\r\n" <> rest), do: rest
  defp consume_optional_crlf(buffer), do: buffer

  defp read_until!(reader, token, limit) do
    case :binary.match(reader.buffer, token) do
      {idx, len} ->
        if idx > limit do
          raise Error.new(:malformed_post_request, message: "POST form field exceeds limit")
        end

        value = binary_part(reader.buffer, 0, idx)
        rest = binary_part(reader.buffer, idx + len, byte_size(reader.buffer) - idx - len)
        {value, %{reader | buffer: rest}}

      :nomatch ->
        cond do
          byte_size(reader.buffer) > limit + byte_size(token) ->
            raise Error.new(:malformed_post_request, message: "POST form field exceeds limit")

          reader.eof? ->
            raise Error.new(:malformed_post_request, message: "Unexpected end of POST body")

          true ->
            reader |> fill!() |> read_until!(token, limit)
        end
    end
  end

  defp ensure_buffer!(reader, size) do
    cond do
      byte_size(reader.buffer) >= size -> reader
      reader.eof? -> reader
      true -> reader |> fill!() |> ensure_buffer!(size)
    end
  end

  defp fill!(reader) do
    case Plug.Conn.read_body(reader.conn, @read_opts) do
      {:more, chunk, conn} ->
        %{reader | conn: conn, buffer: reader.buffer <> chunk}

      {:ok, chunk, conn} ->
        %{reader | conn: conn, buffer: reader.buffer <> chunk, eof?: true}

      {:error, _reason} ->
        raise Error.new(:incomplete_body)
    end
  end

  defp boundary!(nil) do
    raise Error.new(:malformed_post_request, message: "Missing multipart/form-data content type")
  end

  defp boundary!(content_type) do
    [media | params] = String.split(content_type, ";")

    unless String.downcase(String.trim(media)) == "multipart/form-data" do
      raise Error.new(:malformed_post_request,
              message: "Missing multipart/form-data content type"
            )
    end

    boundary =
      Enum.find_value(params, fn param ->
        case String.split(param, "=", parts: 2) do
          [name, value] ->
            if String.downcase(String.trim(name)) == "boundary" do
              value |> String.trim() |> unquote_header_value()
            end

          _other ->
            nil
        end
      end)

    cond do
      is_nil(boundary) or boundary == "" ->
        raise Error.new(:malformed_post_request, message: "Missing multipart boundary")

      byte_size(boundary) > @boundary_limit ->
        raise Error.new(:malformed_post_request, message: "Multipart boundary is too long")

      String.contains?(boundary, ["\r", "\n"]) ->
        raise Error.new(:malformed_post_request, message: "Invalid multipart boundary")

      true ->
        boundary
    end
  end

  defp parse_content_disposition!(nil) do
    raise Error.new(:malformed_post_request, message: "Missing Content-Disposition")
  end

  defp parse_content_disposition!(value) do
    [kind | params] = value |> String.split(";") |> Enum.map(&String.trim/1)

    unless String.downcase(kind) == "form-data" do
      raise Error.new(:malformed_post_request, message: "Invalid Content-Disposition")
    end

    parsed =
      Enum.reduce(params, %{}, fn param, acc ->
        case String.split(param, "=", parts: 2) do
          [name, value] ->
            Map.put(
              acc,
              String.downcase(String.trim(name)),
              unquote_header_value(String.trim(value))
            )

          _other ->
            acc
        end
      end)

    case Map.get(parsed, "name") do
      name when is_binary(name) and name != "" ->
        parsed

      _other ->
        raise Error.new(:malformed_post_request, message: "Missing multipart field name")
    end
  end

  defp unquote_header_value("\"" <> rest) do
    if String.ends_with?(rest, "\"") do
      rest |> String.slice(0, byte_size(rest) - 1) |> String.replace("\\\"", "\"")
    else
      "\"" <> rest
    end
  end

  defp unquote_header_value(value), do: value

  defp put_field!(fields, name, value) do
    name = canonical_form_field_name(name)

    if Map.has_key?(fields, name) do
      raise Error.new(:malformed_post_request, message: "Duplicate POST form field: #{name}")
    end

    Map.put(fields, name, value)
  end

  defp canonical_form_field_name(name) when is_binary(name) do
    lower = String.downcase(name)

    cond do
      MapSet.member?(@case_insensitive_control_fields, lower) -> lower
      lower == "acl" -> "acl"
      lower == "tagging" -> "tagging"
      lower == "content-md5" -> "Content-MD5"
      lower == "content-type" -> "Content-Type"
      lower == "cache-control" -> "Cache-Control"
      lower == "content-disposition" -> "Content-Disposition"
      lower == "content-encoding" -> "Content-Encoding"
      lower == "expires" -> "Expires"
      String.starts_with?(lower, "x-amz-") -> lower
      String.starts_with?(lower, "x-ignore-") -> lower
      true -> name
    end
  end

  defp safe_filename(filename) when is_binary(filename) do
    filename
    |> String.replace("\\", "/")
    |> Path.basename()
  end

  defp expand_key!(nil, _filename, bucket) do
    raise Error.new(:malformed_post_request,
            message: "Missing key field",
            resource: "/" <> bucket
          )
  end

  defp expand_key!(key, filename, _bucket) when is_binary(key) do
    String.replace(key, "${filename}", filename || "")
  end

  defp authenticate!(fields, bucket, key, now) do
    if signed_post?(fields) do
      authenticate_signed_policy!(fields, bucket, key, now)
    else
      %{
        principal: :anonymous,
        auth_type: :anonymous,
        covered_fields: MapSet.new(),
        content_length_range: nil
      }
    end
  end

  defp signed_post?(fields), do: Enum.any?(@auth_fields, &Map.has_key?(fields, &1))

  defp authenticate_signed_policy!(fields, bucket, key, now) do
    required = ~w(policy x-amz-algorithm x-amz-credential x-amz-date x-amz-signature)

    missing = Enum.find(required, fn field -> not present?(Map.get(fields, field)) end)

    if missing do
      raise Error.new(:malformed_post_request, message: "Missing POST form field: #{missing}")
    end

    if Map.fetch!(fields, "x-amz-algorithm") != @algorithm do
      raise Error.new(:authorization_header_malformed, message: "Invalid x-amz-algorithm")
    end

    credential = parse_credential!(Map.fetch!(fields, "x-amz-credential"))
    :ok = verify_amz_date!(Map.fetch!(fields, "x-amz-date"), credential.scope_date)

    policy_b64 = Map.fetch!(fields, "policy")
    policy = decode_policy!(policy_b64)
    :ok = verify_policy_expiration!(policy, now)

    unless credential.service == @service do
      raise Error.new(:authorization_header_malformed, message: "Invalid credential service")
    end

    %{secret_key: secret, principal: principal} =
      lookup_secret!(credential.access_key, Map.get(fields, "x-amz-security-token"), now)

    signing_key =
      Signer.derive_signing_key(
        secret,
        credential.scope_date,
        credential.region,
        credential.service
      )

    computed = Signer.signature(signing_key, policy_b64)
    provided = Map.fetch!(fields, "x-amz-signature")

    unless secure_equal?(computed, provided) do
      Log.warn("post policy signature mismatch",
        auth_type: :post,
        reason: :signature_does_not_match
      )

      raise Error.new(:signature_does_not_match)
    end

    conditions = policy_conditions!(policy)
    result = verify_policy_conditions!(conditions, fields, bucket, key)

    %{
      principal: principal,
      auth_type: :post,
      covered_fields: result.covered_fields,
      content_length_range: result.content_length_range
    }
  end

  defp parse_credential!(credential) do
    case String.split(credential, "/") do
      [access_key, scope_date, region, service, "aws4_request"]
      when access_key != "" and scope_date != "" and region != "" and service != "" ->
        %{access_key: access_key, scope_date: scope_date, region: region, service: service}

      _other ->
        raise Error.new(:authorization_header_malformed, message: "Invalid x-amz-credential")
    end
  end

  defp verify_amz_date!(amz_date, scope_date) do
    with <<date::binary-size(8), "T", _rest::binary>> <- amz_date,
         true <- date == scope_date,
         {:ok, _dt} <- parse_amz_date(amz_date) do
      :ok
    else
      _ -> raise Error.new(:authorization_header_malformed, message: "Invalid x-amz-date")
    end
  end

  defp decode_policy!(policy_b64) when byte_size(policy_b64) <= @policy_limit * 2 do
    with {:ok, json} <- Base.decode64(policy_b64, ignore: :whitespace),
         true <- byte_size(json) <= @policy_limit,
         {:ok, policy} <- Jason.decode(json),
         true <- is_map(policy) do
      policy
    else
      _other ->
        raise Error.new(:invalid_policy_document,
                message: "POST policy must be valid base64 JSON"
              )
    end
  end

  defp decode_policy!(_policy_b64) do
    raise Error.new(:invalid_policy_document, message: "POST policy is too large")
  end

  defp verify_policy_expiration!(%{"expiration" => expiration}, now) when is_binary(expiration) do
    case DateTime.from_iso8601(expiration) do
      {:ok, expires_at, _offset} ->
        if DateTime.compare(expires_at, now) == :gt do
          :ok
        else
          raise Error.new(:access_denied, message: "Policy has expired")
        end

      _other ->
        raise Error.new(:invalid_policy_document, message: "Invalid POST policy expiration")
    end
  end

  defp verify_policy_expiration!(_policy, _now) do
    raise Error.new(:invalid_policy_document, message: "POST policy missing expiration")
  end

  defp policy_conditions!(%{"conditions" => conditions}) when is_list(conditions),
    do: conditions

  defp policy_conditions!(_policy) do
    raise Error.new(:invalid_policy_document, message: "POST policy missing conditions")
  end

  defp verify_policy_conditions!(conditions, fields, bucket, key) do
    context = %{fields: fields, bucket: bucket, key: key}

    result =
      Enum.reduce(conditions, %{covered_fields: MapSet.new(), content_length_range: nil}, fn
        condition, acc when is_map(condition) ->
          Enum.reduce(condition, acc, fn {field, expected}, inner_acc ->
            verify_exact_condition!(context, field, expected)
            cover(inner_acc, field)
          end)

        ["eq", "$" <> field, expected], acc ->
          verify_exact_condition!(context, field, expected)
          cover(acc, field)

        ["starts-with", "$" <> field, expected], acc ->
          verify_starts_with_condition!(context, field, expected)
          cover(acc, field)

        ["content-length-range", min, max], acc ->
          %{acc | content_length_range: content_length_range!(min, max)}

        _other, _acc ->
          raise Error.new(:invalid_policy_document, message: "Unsupported POST policy condition")
      end)

    ensure_bucket_condition!(result.covered_fields)
    ensure_form_field_coverage!(fields, result.covered_fields)
    result
  end

  defp verify_exact_condition!(context, field, expected) do
    actual = field_value(context, field)

    unless present?(actual) and actual == to_string(expected) do
      raise Error.new(:access_denied, message: "Policy condition failed")
    end
  end

  defp verify_starts_with_condition!(context, field, expected) do
    canonical_field = canonical_form_field_name(field)
    prefix = to_string(expected)
    value = field_value(context, field) || ""

    ok? =
      if canonical_field == "Content-Type" do
        value
        |> String.split(",", trim: false)
        |> Enum.map(&String.trim/1)
        |> Enum.all?(&String.starts_with?(&1, prefix))
      else
        String.starts_with?(value, prefix)
      end

    unless ok?, do: raise(Error.new(:access_denied, message: "Policy condition failed"))
  end

  defp field_value(context, field) do
    case canonical_form_field_name(field) do
      "bucket" -> context.bucket
      "key" -> context.key
      canonical -> Map.get(context.fields, canonical)
    end
  end

  defp content_length_range!(min, max) do
    min = integer_condition_value!(min)
    max = integer_condition_value!(max)

    if min < 0 or max < min do
      raise Error.new(:invalid_policy_document, message: "Invalid content-length-range")
    end

    {min, max}
  end

  defp integer_condition_value!(value) when is_integer(value), do: value

  defp integer_condition_value!(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} -> int
      _other -> raise Error.new(:invalid_policy_document, message: "Invalid integer condition")
    end
  end

  defp integer_condition_value!(_value) do
    raise Error.new(:invalid_policy_document, message: "Invalid integer condition")
  end

  defp ensure_bucket_condition!(covered_fields) do
    unless MapSet.member?(covered_fields, "bucket") do
      raise Error.new(:invalid_policy_document, message: "POST policy must constrain bucket")
    end
  end

  defp ensure_form_field_coverage!(fields, covered_fields) do
    case Enum.find(
           Map.keys(fields),
           &(not coverage_exempt?(&1) and not MapSet.member?(covered_fields, &1))
         ) do
      nil ->
        :ok

      field ->
        raise Error.new(:access_denied,
                message: "Policy condition missing for form field: #{field}"
              )
    end
  end

  defp coverage_exempt?(field) do
    field in @coverage_exempt or String.starts_with?(field, "x-ignore-")
  end

  defp cover(acc, field),
    do: %{acc | covered_fields: MapSet.put(acc.covered_fields, canonical_form_field_name(field))}

  defp lookup_secret!(access_key, session_token, now) do
    case CredentialStore.get_secret(access_key, session_token: session_token, now: now) do
      {:ok, found} ->
        found

      :error ->
        Log.warn("unknown access key", auth_type: :post, reason: :invalid_access_key_id)
        raise Error.new(:invalid_access_key_id)

      {:error, :expired_token} ->
        Log.warn("expired session token", auth_type: :post, reason: :expired_token)
        raise Error.new(:expired_token)

      {:error, reason} when reason in [:missing_session_token, :invalid_token] ->
        Log.warn("invalid session token", auth_type: :post, reason: reason)
        raise Error.new(:invalid_token)
    end
  end

  defp object_headers!(fields, original_headers) do
    headers =
      fields
      |> Enum.flat_map(fn {name, value} -> form_field_headers!(name, value) end)
      |> maybe_copy_request_id(original_headers)

    dedupe_headers!(headers)
  end

  defp form_field_headers!(name, value) when is_binary(name) do
    cond do
      MapSet.member?(@control_fields, name) or String.starts_with?(name, "x-ignore-") ->
        []

      Map.has_key?(@direct_header_fields, name) ->
        [{Map.fetch!(@direct_header_fields, name), value}]

      name == "tagging" ->
        [{"x-amz-tagging", tagging_header!(value)}]

      String.starts_with?(String.downcase(name), "x-amz-") ->
        [{String.downcase(name), value}]

      true ->
        []
    end
  end

  defp tagging_header!(xml) do
    with {:ok, tags} <- TaggingParser.parse(xml),
         :ok <- Maxio.Tags.validate(tags, :object) do
      tags
      |> Enum.map(fn {key, value} ->
        URI.encode_www_form(key) <> "=" <> URI.encode_www_form(value)
      end)
      |> Enum.join("&")
    else
      _other -> raise Error.new(:invalid_tag)
    end
  end

  defp maybe_copy_request_id(headers, original_headers) do
    request_id_headers =
      original_headers
      |> Enum.filter(fn {name, _value} -> String.downcase(name) == "x-request-id" end)
      |> Enum.map(fn {_name, value} -> {"x-request-id", value} end)

    headers ++ request_id_headers
  end

  defp dedupe_headers!(headers) do
    {result, _seen} =
      Enum.reduce(headers, {[], MapSet.new()}, fn {name, value}, {acc, seen} ->
        lower = String.downcase(name)

        if MapSet.member?(seen, lower) do
          raise Error.new(:invalid_request,
                  message: "Duplicate object header from POST form: #{lower}"
                )
        end

        {[{lower, value} | acc], MapSet.put(seen, lower)}
      end)

    Enum.reverse(result)
  end

  defp signed_headers(headers, covered_fields) do
    if MapSet.size(covered_fields) == 0 do
      []
    else
      headers
      |> Enum.map(&elem(&1, 0))
      |> Enum.reject(&(&1 == "x-request-id"))
      |> Enum.uniq()
    end
  end

  defp success_action!(fields) do
    redirect = Map.get(fields, "success_action_redirect") || Map.get(fields, "redirect")
    status = Map.get(fields, "success_action_status")

    cond do
      present?(redirect) ->
        %{redirect: redirect, status: 303}

      status in [nil, "", "204"] ->
        %{status: 204}

      status in ["200", "201"] ->
        %{status: String.to_integer(status)}

      true ->
        raise Error.new(:invalid_request, message: "Invalid success_action_status")
    end
  end

  defp parse_amz_date(
         <<y::binary-4, mo::binary-2, d::binary-2, "T", h::binary-2, mi::binary-2, s::binary-2,
           "Z">>
       ) do
    with {year, ""} <- Integer.parse(y),
         {month, ""} <- Integer.parse(mo),
         {day, ""} <- Integer.parse(d),
         {hour, ""} <- Integer.parse(h),
         {minute, ""} <- Integer.parse(mi),
         {second, ""} <- Integer.parse(s),
         {:ok, naive} <- NaiveDateTime.new(year, month, day, hour, minute, second) do
      {:ok, DateTime.from_naive!(naive, "Etc/UTC")}
    else
      _other -> :error
    end
  end

  defp parse_amz_date(_), do: :error

  defp secure_equal?(left, right)
       when is_binary(left) and is_binary(right) and byte_size(left) == byte_size(right),
       do: Signer.secure_compare(left, right)

  defp secure_equal?(_left, _right), do: false

  defp present?(nil), do: false
  defp present?(""), do: false
  defp present?(_value), do: true

  defp header(conn, name), do: conn |> get_req_header(name) |> List.first()

  defp stop_agent(agent) do
    Agent.stop(agent)
  catch
    :exit, _reason -> :ok
  end
end
