defmodule Maxio.S3.EventStreamTest do
  use ExUnit.Case, async: true

  alias Maxio.S3.EventStream

  test "records frame uses valid AWS event-stream framing and CRCs" do
    [message] = decode(EventStream.records("a,b\n"))

    assert message.headers[":message-type"] == "event"
    assert message.headers[":event-type"] == "Records"
    assert message.headers[":content-type"] == "application/octet-stream"
    assert message.payload == "a,b\n"
  end

  test "stats and end frames are encoded as event messages" do
    stats = %{bytes_scanned: 4, bytes_processed: 4, bytes_returned: 4}
    [stats_message, end_message] = decode(EventStream.stats(stats) <> EventStream.end_event())

    assert stats_message.headers[":event-type"] == "Stats"
    assert stats_message.payload =~ "<Details>"
    assert stats_message.payload =~ "<BytesScanned>4</BytesScanned>"
    assert stats_message.payload =~ "<BytesProcessed>4</BytesProcessed>"
    assert stats_message.payload =~ "<BytesReturned>4</BytesReturned>"
    assert stats_message.payload =~ "</Details>"

    assert end_message.headers[":message-type"] == "event"
    assert end_message.headers[":event-type"] == "End"
    assert end_message.payload == ""
  end

  defp decode(binary), do: decode(binary, [])

  defp decode("", acc), do: Enum.reverse(acc)

  defp decode(<<total::32, headers_len::32, prelude_crc::32, rest::binary>> = binary, acc) do
    prelude = binary_part(binary, 0, 8)
    assert :erlang.crc32(prelude) == prelude_crc

    payload_len = total - 16 - headers_len

    <<headers::binary-size(headers_len), payload::binary-size(payload_len), crc::32,
      tail::binary>> = rest

    assert :erlang.crc32(binary_part(binary, 0, total - 4)) == crc
    decode(tail, [%{headers: decode_headers(headers), payload: payload} | acc])
  end

  defp decode_headers(binary), do: decode_headers(binary, %{})
  defp decode_headers("", acc), do: acc

  defp decode_headers(
         <<name_len, name::binary-size(name_len), 7, value_len::16, value::binary-size(value_len),
           rest::binary>>,
         acc
       ) do
    decode_headers(rest, Map.put(acc, name, value))
  end
end
