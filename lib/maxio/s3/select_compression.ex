defmodule Maxio.S3.SelectCompression do
  @moduledoc """
  Streaming input decompression for SelectObjectContent.

  The selected records are still staged by the CSV/JSON executors. This module
  only turns supported compressed object bytes into the uncompressed stream those
  executors already understand, while preserving a counter for the compressed
  source bytes read from storage.
  """

  alias Maxio.S3.Error

  @output_chunk_size 64 * 1024

  @type wrapped :: %{
          stream: Enumerable.t(),
          compressed?: boolean(),
          source_bytes_processed: (-> non_neg_integer() | nil),
          cleanup: (-> :ok)
        }

  @spec wrap!(Enumerable.t(), String.t() | nil) :: wrapped()
  def wrap!(stream, compression_type) do
    case normalize_type(compression_type) do
      "NONE" -> identity(stream)
      "GZIP" -> gzip(stream)
      "BZIP2" -> unsupported!("BZIP2 SelectObjectContent input is not implemented")
      _other -> invalid!("Invalid SelectObjectContent CompressionType")
    end
  end

  @spec normalize_type(String.t() | nil) :: String.t()
  def normalize_type(nil), do: "NONE"
  def normalize_type(""), do: "NONE"
  def normalize_type(value) when is_binary(value), do: value |> String.trim() |> String.upcase()

  defp identity(stream) do
    %{
      stream: stream,
      compressed?: false,
      source_bytes_processed: fn -> nil end,
      cleanup: fn -> :ok end
    }
  end

  defp gzip(source_stream) do
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    stream =
      Stream.resource(
        fn -> init_gzip_state!(source_stream, counter) end,
        &next_gzip_chunk/1,
        &close_gzip_state/1
      )

    %{
      stream: stream,
      compressed?: true,
      source_bytes_processed: fn -> Agent.get(counter, & &1) end,
      cleanup: fn -> stop_counter(counter) end
    }
  end

  defp init_gzip_state!(source_stream, counter) do
    z = :zlib.open()

    try do
      :ok = :zlib.inflateInit(z, 31, :reset)

      %{
        z: z,
        source: {:initial, source_stream},
        counter: counter,
        pending: [],
        mode: :need_input
      }
    rescue
      _error ->
        close_zlib_port(z)
        invalid!("Invalid GZIP SelectObjectContent input")
    end
  end

  defp next_gzip_chunk(%{pending: [chunk | rest]} = state),
    do: {[chunk], %{state | pending: rest}}

  defp next_gzip_chunk(%{mode: :drain_pending} = state), do: inflate_next!(state, [])

  defp next_gzip_chunk(%{mode: :need_input} = state) do
    case pull_source_chunk(state) do
      {:chunk, chunk, state} ->
        inflate_next!(state, chunk)

      {:done, state} ->
        finish_inflate!(state.z)
        {:halt, state}
    end
  end

  defp inflate_next!(state, input) do
    case safe_inflate(state.z, input) do
      {:ok, status, iodata} ->
        state = %{state | mode: next_inflate_mode(status)}

        iodata
        |> IO.iodata_to_binary()
        |> chunk_outputs()
        |> emit_or_continue(state)

      :error ->
        close_gzip_state(state)
        invalid!("Invalid GZIP SelectObjectContent input")
    end
  end

  defp next_inflate_mode(:continue), do: :drain_pending
  defp next_inflate_mode(:finished), do: :need_input

  defp emit_or_continue([], state), do: next_gzip_chunk(state)
  defp emit_or_continue([chunk | rest], state), do: {[chunk], %{state | pending: rest}}

  defp pull_source_chunk(%{source: :done} = state), do: {:done, state}

  defp pull_source_chunk(%{source: {:initial, source_stream}} = state) do
    source_stream
    |> Enumerable.reduce({:cont, nil}, &suspend_source_chunk/2)
    |> handle_source_pull(state)
  end

  defp pull_source_chunk(%{source: {:cont, cont}} = state) do
    cont.({:cont, nil})
    |> handle_source_pull(state)
  end

  defp suspend_source_chunk(chunk, _acc), do: {:suspend, chunk}

  defp handle_source_pull({:suspended, chunk, cont}, state) do
    chunk = IO.iodata_to_binary(chunk)
    Agent.update(state.counter, &(&1 + byte_size(chunk)))
    {:chunk, chunk, %{state | source: {:cont, cont}}}
  end

  defp handle_source_pull({:done, _acc}, state), do: {:done, %{state | source: :done}}
  defp handle_source_pull({:halted, _acc}, state), do: {:done, %{state | source: :done}}

  defp close_gzip_state(state) do
    close_source(state.source)
    close_zlib_port(state.z)
    :ok
  end

  defp close_source({:cont, cont}) do
    cont.({:halt, nil})
    :ok
  rescue
    _error -> :ok
  catch
    _kind, _reason -> :ok
  end

  defp close_source(_source), do: :ok

  defp chunk_outputs(""), do: []
  defp chunk_outputs(binary), do: chunk_outputs(binary, [])
  defp chunk_outputs("", acc), do: Enum.reverse(acc)

  defp chunk_outputs(<<chunk::binary-size(@output_chunk_size), rest::binary>>, acc) do
    chunk_outputs(rest, [:binary.copy(chunk) | acc])
  end

  defp chunk_outputs(rest, acc), do: Enum.reverse([:binary.copy(rest) | acc])

  defp finish_inflate!(z) do
    case safe_inflate_end(z) do
      :ok -> :ok
      :error -> invalid!("Invalid GZIP SelectObjectContent input")
    end
  end

  defp safe_inflate(z, chunk) do
    case :zlib.safeInflate(z, chunk) do
      {state, iodata} when state in [:continue, :finished] -> {:ok, state, iodata}
      {:need_dictionary, _adler32, _iodata} -> :error
      _other -> :error
    end
  rescue
    _error -> :error
  catch
    _kind, _reason -> :error
  end

  defp safe_inflate_end(z) do
    case :zlib.inflateEnd(z) do
      :ok -> :ok
      _other -> :error
    end
  rescue
    _error -> :error
  catch
    _kind, _reason -> :error
  end

  defp close_zlib_port(z), do: safe_zlib_close(z)

  defp safe_zlib_close(z) do
    :zlib.close(z)
  rescue
    _error -> :ok
  catch
    _kind, _reason -> :ok
  end

  defp stop_counter(counter) do
    if Process.alive?(counter), do: Agent.stop(counter, :normal, 1_000)
    :ok
  end

  defp invalid!(message), do: raise(Error.new(:invalid_request, message: message))
  defp unsupported!(message), do: raise(Error.new(:not_implemented, message: message))
end
