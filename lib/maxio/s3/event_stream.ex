defmodule Maxio.S3.EventStream do
  @moduledoc """
  AWS event-stream encoder used by S3 SelectObjectContent responses.
  """

  import Saxy.XML

  alias Maxio.S3.XML

  @content_type "application/vnd.amazon.eventstream"
  @header_string_type 7

  @type stats :: %{
          required(:bytes_scanned) => non_neg_integer(),
          required(:bytes_processed) => non_neg_integer(),
          required(:bytes_returned) => non_neg_integer()
        }

  @doc "HTTP Content-Type for AWS event-stream payloads."
  @spec content_type() :: String.t()
  def content_type, do: @content_type

  @doc "Encode a Records event with raw record bytes."
  @spec records(iodata()) :: binary()
  def records(payload) do
    message(
      [
        {":message-type", "event"},
        {":event-type", "Records"},
        {":content-type", "application/octet-stream"}
      ],
      payload
    )
  end

  @doc "Encode a Progress event."
  @spec progress(stats()) :: binary()
  def progress(stats) do
    message(
      [
        {":message-type", "event"},
        {":event-type", "Progress"},
        {":content-type", "text/xml"}
      ],
      progress_xml(stats)
    )
  end

  @doc "Encode a Stats event."
  @spec stats(stats()) :: binary()
  def stats(stats) do
    message(
      [
        {":message-type", "event"},
        {":event-type", "Stats"},
        {":content-type", "text/xml"}
      ],
      stats_xml(stats)
    )
  end

  @doc "Encode an End event."
  @spec end_event() :: binary()
  def end_event do
    message(
      [
        {":message-type", "event"},
        {":event-type", "End"}
      ],
      ""
    )
  end

  @spec message([{String.t(), String.t()}], iodata()) :: binary()
  def message(headers, payload) when is_list(headers) do
    headers = IO.iodata_to_binary(Enum.map(headers, &encode_header/1))
    payload = IO.iodata_to_binary(payload)
    total_len = 16 + byte_size(headers) + byte_size(payload)

    prelude =
      <<total_len::unsigned-big-integer-size(32),
        byte_size(headers)::unsigned-big-integer-size(32)>>

    prelude_crc = <<:erlang.crc32(prelude)::unsigned-big-integer-size(32)>>
    message_without_crc = [prelude, prelude_crc, headers, payload] |> IO.iodata_to_binary()
    message_without_crc <> <<:erlang.crc32(message_without_crc)::unsigned-big-integer-size(32)>>
  end

  defp encode_header({name, value}) when is_binary(name) and is_binary(value) do
    name_len = byte_size(name)
    value_len = byte_size(value)

    if name_len > 255 do
      raise ArgumentError, "event-stream header name too long"
    end

    <<name_len::unsigned-big-integer-size(8), name::binary, @header_string_type,
      value_len::unsigned-big-integer-size(16), value::binary>>
  end

  defp stats_xml(stats) do
    XML.encode(
      element("Stats", [{"xmlns", XML.namespace()}], [
        details_element(stats)
      ])
    )
  end

  defp progress_xml(stats) do
    XML.encode(
      element("Progress", [{"xmlns", XML.namespace()}], [
        details_element(stats)
      ])
    )
  end

  defp details_element(stats) do
    element("Details", [], [
      stat_element("BytesScanned", stats.bytes_scanned),
      stat_element("BytesProcessed", stats.bytes_processed),
      stat_element("BytesReturned", stats.bytes_returned)
    ])
  end

  defp stat_element(name, value), do: element(name, [], characters(Integer.to_string(value)))
end
