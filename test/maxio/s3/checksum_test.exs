defmodule Maxio.S3.ChecksumTest do
  use ExUnit.Case, async: true

  alias Maxio.S3.Checksum

  test "wrap_stream cleans trailer getter on no-check success path" do
    parent = self()
    checksum = checksum_without_checks(fn -> send(parent, :trailers_read) end)

    {stream, get_context, _discard} = Checksum.wrap_stream(["data"], checksum)

    assert Enum.to_list(stream) == ["data"]
    context = get_context.()
    assert context.checks == []
    assert context.response_headers == []
    assert context.verify!.() == :ok
    assert_received :trailers_read
  end

  test "wrap_stream cleans trailer getter on no-check discard path" do
    parent = self()
    checksum = checksum_without_checks(fn -> send(parent, :trailers_discarded) end)

    {_stream, _get_context, discard} = Checksum.wrap_stream(["data"], checksum)

    assert discard.() == :ok
    assert_received :trailers_discarded
  end

  defp checksum_without_checks(on_trailers) do
    %{
      checks: [],
      get_trailers: fn ->
        on_trailers.()
        %{}
      end,
      response_headers: [],
      verify!: fn -> :ok end
    }
  end
end
