defmodule MaxioWeb.ConsoleDirectMultipartHistoryController do
  @moduledoc """
  Console CSV export for browser-direct multipart terminal history.

  This controller only reads the non-secret history snapshot table. It never
  returns presigned URLs, SigV4 signatures, S3 headers, or SSE-C customer keys.
  """
  use MaxioWeb, :controller

  alias Maxio.Buckets
  alias Maxio.Console.DirectMultipartUpload

  @csv_headers [
    "terminal_state",
    "bucket",
    "key",
    "upload_id",
    "file_name",
    "file_size",
    "file_last_modified",
    "part_size",
    "part_count",
    "uploaded_size",
    "etag",
    "version_id",
    "content_type",
    "storage_class",
    "request_payer",
    "sse_algorithm",
    "sse_customer_key_required",
    "terminal_at"
  ]

  def export(conn, %{"bucket" => bucket} = params) do
    with {:ok, _bucket} <- Buckets.lookup(bucket) do
      prefix = Map.get(params, "prefix", "") || ""
      scope = DirectMultipartUpload.normalize_scope(Map.get(params, "mpu_scope"), "folder")

      terminal_state =
        DirectMultipartUpload.normalize_terminal_state(Map.get(params, "mpu_state"))

      query = DirectMultipartUpload.normalize_search_query(Map.get(params, "mpu_q"))
      limit = export_limit(Map.get(params, "mpu_limit"))

      rows =
        DirectMultipartUpload.list_history(
          bucket,
          prefix,
          conn.assigns.current_principal.arn,
          scope: scope,
          terminal_state: terminal_state,
          query: query,
          limit: limit
        )

      conn
      |> put_resp_content_type("text/csv")
      |> put_resp_header(
        "content-disposition",
        ~s(attachment; filename="maxio-direct-multipart-history.csv")
      )
      |> send_resp(200, render_csv(rows))
    else
      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> text("bucket not found")
    end
  end

  defp render_csv(rows) do
    rows =
      Enum.map(rows, fn row ->
        [
          row.terminal_state,
          row.bucket_name,
          row.key,
          row.upload_id,
          row.file_name,
          row.file_size,
          row.file_last_modified,
          row.part_size,
          row.part_count,
          row.uploaded_size,
          row.etag,
          row.version_id,
          row.content_type,
          row.storage_class,
          row.request_payer,
          row.sse_algorithm,
          row.sse_customer_key_required,
          row.terminal_at
        ]
      end)

    [@csv_headers | rows]
    |> Enum.map(&csv_row/1)
    |> Enum.join("")
  end

  defp csv_row(values) do
    values
    |> Enum.map(&csv_cell/1)
    |> Enum.join(",")
    |> Kernel.<>("\r\n")
  end

  defp csv_cell(nil), do: ~s("")
  defp csv_cell(%DateTime{} = value), do: value |> DateTime.to_iso8601() |> csv_cell()
  defp csv_cell(value) when is_boolean(value), do: value |> to_string() |> csv_cell()
  defp csv_cell(value) when is_integer(value), do: Integer.to_string(value)

  defp csv_cell(value) do
    value =
      value
      |> to_string()
      |> spreadsheet_safe()
      |> String.replace("\"", "\"\"")

    "\"" <> value <> "\""
  end

  defp spreadsheet_safe(<<first::utf8, _rest::binary>> = value)
       when first in [?=, ?+, ?-, ?@, ?\t, ?\r, ?\n],
       do: "'" <> value

  defp spreadsheet_safe(value), do: value

  defp export_limit(value) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} when integer > 0 ->
        min(integer, DirectMultipartUpload.history_export_limit())

      _other ->
        DirectMultipartUpload.history_export_limit()
    end
  end

  defp export_limit(_value), do: DirectMultipartUpload.history_export_limit()
end
