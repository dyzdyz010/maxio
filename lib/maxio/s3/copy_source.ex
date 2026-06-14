defmodule Maxio.S3.CopySource do
  @moduledoc """
  Shared parsing for S3 copy-source style headers.

  `x-amz-copy-source` is used by CopyObject and UploadPartCopy. This module
  keeps the URL decoding, optional versionId, source conditional headers and
  byte range parsing in one place so multipart copy does not duplicate private
  Object handler helpers.
  """

  alias Maxio.S3.{Conditional, Error}

  @type t :: %{bucket: String.t(), key: String.t(), version_id: String.t() | nil}
  @type range :: nil | {non_neg_integer(), non_neg_integer()}

  @spec parse!(String.t() | nil) :: t()
  def parse!(raw) when is_binary(raw) and raw != "" do
    trimmed = String.replace_prefix(raw, "/", "")

    {path, version_id} =
      case String.split(trimmed, "?", parts: 2) do
        [p] ->
          {p, nil}

        [p, q] ->
          {p, q |> URI.decode_query() |> Map.get("versionId") |> normalize_version_id()}
      end

    case String.split(path, "/", parts: 2) do
      [bucket, key] when bucket != "" and key != "" ->
        %{bucket: URI.decode(bucket), key: URI.decode(key), version_id: version_id}

      _ ->
        raise Error.new(:invalid_argument, message: "Invalid x-amz-copy-source")
    end
  end

  def parse!(_raw), do: raise(Error.new(:invalid_argument, message: "Invalid x-amz-copy-source"))

  @spec validate_version_id!(t()) :: :ok
  def validate_version_id!(%{version_id: nil}), do: :ok

  def validate_version_id!(%{bucket: bucket, key: key, version_id: version_id}) do
    if Maxio.Versioning.VersionId.valid?(version_id) do
      :ok
    else
      raise Error.new(:invalid_argument,
              message: "Invalid version id specified",
              resource: "/#{bucket}/#{key}"
            )
    end
  end

  @spec conditional_result(Plug.Conn.t(), %{etag: String.t(), updated_at: DateTime.t()}) ::
          :proceed | {:error, :precondition_failed}
  def conditional_result(conn, src_obj) do
    conn.req_headers
    |> source_condition_headers()
    |> Conditional.evaluate(
      %{etag: src_obj.etag, last_modified: src_obj.updated_at},
      "COPY"
    )
    |> case do
      :proceed -> :proceed
      {:respond, 304} -> {:error, :precondition_failed}
      {:error, :precondition_failed} -> {:error, :precondition_failed}
    end
  end

  @spec parse_range!(String.t() | nil, non_neg_integer()) :: range()
  def parse_range!(nil, _total), do: nil
  def parse_range!("", _total), do: nil

  def parse_range!("bytes=" <> spec, total) do
    cond do
      String.contains?(spec, ",") ->
        invalid_range!()

      true ->
        case parse_single_range(spec, total) do
          :invalid -> invalid_range!()
          range -> range
        end
    end
  end

  def parse_range!(_other, _total), do: invalid_range!()

  @spec source_condition_headers([{String.t(), String.t()}]) :: [{String.t(), String.t()}]
  def source_condition_headers(req_headers) do
    Enum.flat_map(req_headers, fn {name, value} ->
      case String.downcase(name) do
        "x-amz-copy-source-if-match" -> [{"if-match", value}]
        "x-amz-copy-source-if-none-match" -> [{"if-none-match", value}]
        "x-amz-copy-source-if-modified-since" -> [{"if-modified-since", value}]
        "x-amz-copy-source-if-unmodified-since" -> [{"if-unmodified-since", value}]
        _ -> []
      end
    end)
  end

  defp normalize_version_id(""), do: nil
  defp normalize_version_id(version_id), do: version_id

  defp parse_single_range(spec, total) do
    case String.split(spec, "-") do
      [a, b] ->
        with {first, ""} <- Integer.parse(a),
             {last, ""} <- Integer.parse(b),
             true <- first <= last and first < total do
          {first, min(last, total - 1)}
        else
          _ -> :invalid
        end

      _ ->
        :invalid
    end
  end

  defp invalid_range!, do: raise(Error.new(:invalid_range))
end
