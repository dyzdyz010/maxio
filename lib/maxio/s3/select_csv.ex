defmodule Maxio.S3.SelectCSV do
  @moduledoc """
  Small, fail-closed CSV executor for SelectObjectContent.

  It supports an intentionally bounded unquoted UTF-8 CSV subset plus simple
  projection, filtering, and limit plans from `Maxio.S3.SelectSQL`.
  """

  alias Maxio.S3.{Error, SelectOutput, SelectSQL, SelectTimestamp, TempFile}

  @max_record_size 1_048_576
  @max_column_size 1_048_576
  @max_projection_count 1_000
  @default_max_result_size 128 * 1_024 * 1_024
  @input_options MapSet.new(~w(
    FileHeaderInfo
    RecordDelimiter
    FieldDelimiter
    QuoteCharacter
    QuoteEscapeCharacter
    Comments
    AllowQuotedRecordDelimiter
  ))

  @type result :: %{
          path: String.t(),
          cleanup: (-> :ok),
          bytes_scanned: non_neg_integer(),
          bytes_processed: non_neg_integer(),
          bytes_returned: non_neg_integer(),
          source_complete?: boolean(),
          halt_reason: nil | :limit | :scan_range
        }

  @spec stage_select_all!(Enumerable.t()) :: result()
  def stage_select_all!(stream) do
    stage!(
      stream,
      %{projections: :all, from: "S3Object", alias: nil, where: nil, limit: nil},
      %{},
      %{},
      nil
    )
  end

  @spec stage!(Enumerable.t(), SelectSQL.plan(), map(), map()) :: result()
  def stage!(stream, plan, input_options, output_options),
    do: stage!(stream, plan, input_options, output_options, nil)

  @spec stage!(Enumerable.t(), SelectSQL.plan(), map(), map(), map() | nil) :: result()
  def stage!(stream, plan, input_options, output_options, scan_range) do
    stage!(stream, plan, input_options, output_options, scan_range, [])
  end

  @spec stage!(Enumerable.t(), SelectSQL.plan(), map(), map(), map() | nil, keyword()) ::
          result()
  def stage!(stream, plan, input_options, output_options, scan_range, opts) do
    output_format = Keyword.get(opts, :output_format, "CSV")
    config = config!(input_options, output_options, output_format)
    config = %{config | scan_range: scan_range}
    validate_plan!(plan, config)
    drain_on_halt? = Keyword.get(opts, :drain_on_halt?, false)

    TempFile.stage!("maxio_s3_select_", output_extension(config.output), fn io ->
      stream
      |> Enum.reduce_while(init_state(plan, config, drain_on_halt?), fn chunk, state ->
        chunk = IO.iodata_to_binary(chunk)

        cond do
          state.done? and chunk != "" and state.drain_on_halt? ->
            {:cont, count_input(state, chunk)}

          state.done? and chunk != "" ->
            {:halt, %{state | halted_before_eof?: true}}

          state.done? ->
            {:cont, state}

          true ->
            state =
              state
              |> count_input(chunk)
              |> process_chunk(io, chunk)

            if state.done? and state.halted_before_eof? and not state.drain_on_halt? do
              {:halt, state}
            else
              {:cont, state}
            end
        end
      end)
      |> mark_source_complete()
      |> flush_buffer(io)
    end)
  end

  defp init_state(plan, config, drain_on_halt?) do
    %{
      buffer: "",
      bytes_scanned: 0,
      bytes_processed: 0,
      bytes_returned: 0,
      config: config,
      plan: plan,
      header: nil,
      header_seen?: false,
      header_skip: nil,
      emitted: 0,
      aggregate_acc: init_aggregate_acc(plan),
      record_start_offset: 0,
      record_scan: :field_start,
      done?: false,
      halted_before_eof?: false,
      source_complete?: false,
      halt_reason: nil,
      utc_now: SelectTimestamp.utc_now(),
      drain_on_halt?: drain_on_halt?
    }
  end

  defp count_input(state, chunk) do
    size = byte_size(chunk)

    state
    |> Map.update!(:bytes_scanned, &(&1 + size))
    |> Map.update!(:bytes_processed, &(&1 + size))
  end

  defp process_chunk(state, io, chunk) do
    consume_chunk(state, io, chunk, state.bytes_processed - byte_size(chunk))
  end

  defp reject_oversized_record!(line) do
    if byte_size(line) > @max_record_size do
      raise Error.new(:over_max_record_size)
    end

    :ok
  end

  defp consume_chunk(state, _io, "", _chunk_offset), do: state

  defp consume_chunk(state, io, chunk, chunk_offset) do
    cond do
      limit_reached?(state) ->
        halt_before_record(state, :limit)

      header_pending?(state) and header_must_parse?(state) ->
        consume_buffered_record(state, io, chunk, chunk_offset)

      header_pending?(state) ->
        skip_header_record(state, io, chunk, chunk_offset)

      true ->
        case scan_range_position(state.config.scan_range, state.record_start_offset) do
          :before -> skip_unscanned_record(state, io, chunk, chunk_offset)
          :after -> halt_before_record(state, :scan_range)
          :inside -> consume_buffered_record(state, io, chunk, chunk_offset)
        end
    end
  end

  defp consume_buffered_record(state, io, chunk, chunk_offset) do
    case next_record_segment(chunk, state.config.input, state.record_scan) do
      :nomatch ->
        %{state | buffer: append_to_buffer!(state.buffer, chunk)}

      {:more, segment, record_scan} ->
        %{state | buffer: append_to_buffer!(state.buffer, segment), record_scan: record_scan}

      {:record, before_newline, delimiter_size, rest, record_scan} ->
        rest_start = byte_size(before_newline) + delimiter_size

        line =
          state.buffer
          |> append_to_buffer!(before_newline)
          |> normalize_delimited_line(state.config.input)

        record_start = state.record_start_offset
        next_record_start = chunk_offset + rest_start

        state =
          state
          |> Map.put(:buffer, "")
          |> Map.put(:record_scan, record_scan)
          |> handle_record!(io, line, record_start)
          |> Map.put(:record_start_offset, next_record_start)

        state = mark_halt_before_eof(state, rest)

        if state.done? do
          state
        else
          consume_chunk(state, io, rest, next_record_start)
        end
    end
  end

  defp skip_header_record(state, io, chunk, chunk_offset) do
    skip_kind = state.header_skip || header_skip_kind(chunk, state.config.input)

    case next_record_segment(chunk, state.config.input, state.record_scan) do
      :nomatch ->
        %{state | buffer: "", header_skip: skip_kind}

      {:more, _segment, record_scan} ->
        %{state | buffer: "", header_skip: skip_kind, record_scan: record_scan}

      {:record, before_newline, delimiter_size, rest, record_scan} ->
        rest_start = byte_size(before_newline) + delimiter_size
        next_record_start = chunk_offset + rest_start

        state =
          state
          |> Map.put(:buffer, "")
          |> Map.put(:record_scan, record_scan)
          |> Map.put(:header_skip, nil)
          |> maybe_mark_header_seen(skip_kind)
          |> Map.put(:record_start_offset, next_record_start)

        consume_chunk(state, io, rest, next_record_start)
    end
  end

  defp skip_unscanned_record(state, io, chunk, chunk_offset) do
    case next_record_segment(chunk, state.config.input, state.record_scan) do
      :nomatch ->
        %{state | buffer: ""}

      {:more, _segment, record_scan} ->
        %{state | buffer: "", record_scan: record_scan}

      {:record, before_newline, delimiter_size, rest, record_scan} ->
        rest_start = byte_size(before_newline) + delimiter_size
        next_record_start = chunk_offset + rest_start

        state = %{
          state
          | buffer: "",
            record_scan: record_scan,
            record_start_offset: next_record_start
        }

        consume_chunk(state, io, rest, next_record_start)
    end
  end

  defp next_record_segment(chunk, %{allow_quoted_record_delimiter: true} = config, mode) do
    quoted_record_segment(chunk, config, mode, 0)
  end

  defp next_record_segment(chunk, config, _mode) do
    case :binary.match(chunk, config.record_delimiter) do
      :nomatch ->
        :nomatch

      {position, delimiter_size} ->
        before_newline = binary_part(chunk, 0, position)
        rest_start = position + delimiter_size
        rest_size = byte_size(chunk) - rest_start
        rest = binary_part(chunk, rest_start, rest_size)
        {:record, before_newline, delimiter_size, rest, :field_start}
    end
  end

  defp quoted_record_segment(<<>>, _config, mode, _offset), do: {:more, "", mode}

  defp quoted_record_segment(chunk, _config, mode, offset) when offset >= byte_size(chunk),
    do: {:more, chunk, mode}

  defp quoted_record_segment(chunk, config, mode, offset) do
    case quoted_record_step(chunk, config, mode, offset) do
      {:record, position, delimiter_size} ->
        before_newline = binary_part(chunk, 0, position)
        rest_start = position + delimiter_size
        rest_size = byte_size(chunk) - rest_start
        rest = binary_part(chunk, rest_start, rest_size)
        {:record, before_newline, delimiter_size, rest, :field_start}

      {:cont, mode, next_offset} ->
        quoted_record_segment(chunk, config, mode, next_offset)
    end
  end

  defp quoted_record_step(chunk, config, :quoted, offset) do
    cond do
      trailing_escape?(chunk, config, offset) and
          config.quote_escape_character == config.quote_character ->
        {:cont, :quoted_quote_boundary, offset + 1}

      trailing_escape?(chunk, config, offset) ->
        {:cont, :quoted_escape_boundary, offset + 1}

      matches_two_bytes?(chunk, offset, config.quote_escape_character, config.quote_character) ->
        {:cont, :quoted, offset + 2}

      matches_byte?(chunk, offset, config.quote_character) ->
        {:cont, :after_quote, offset + 1}

      true ->
        {:cont, :quoted, offset + 1}
    end
  end

  defp quoted_record_step(chunk, config, :quoted_escape_boundary, offset) do
    if matches_byte?(chunk, offset, config.quote_character) do
      {:cont, :quoted, offset + 1}
    else
      quoted_record_step(chunk, config, :quoted, offset)
    end
  end

  defp quoted_record_step(chunk, config, :quoted_quote_boundary, offset) do
    if matches_byte?(chunk, offset, config.quote_character) do
      {:cont, :quoted, offset + 1}
    else
      quoted_record_step(chunk, config, :after_quote, offset)
    end
  end

  defp quoted_record_step(chunk, config, mode, offset) when mode in [:field_start, :unquoted] do
    cond do
      matches_byte?(chunk, offset, config.record_delimiter) ->
        {:record, offset, byte_size(config.record_delimiter)}

      mode == :field_start and matches_byte?(chunk, offset, config.quote_character) ->
        {:cont, :quoted, offset + 1}

      matches_byte?(chunk, offset, config.field_delimiter) ->
        {:cont, :field_start, offset + 1}

      true ->
        {:cont, :unquoted, offset + 1}
    end
  end

  defp quoted_record_step(chunk, config, :after_quote, offset) do
    cond do
      matches_byte?(chunk, offset, config.record_delimiter) ->
        {:record, offset, byte_size(config.record_delimiter)}

      matches_byte?(chunk, offset, config.field_delimiter) ->
        {:cont, :field_start, offset + 1}

      true ->
        {:cont, :after_quote, offset + 1}
    end
  end

  defp matches_byte?(chunk, offset, <<byte>>) do
    offset < byte_size(chunk) and :binary.at(chunk, offset) == byte
  end

  defp trailing_escape?(chunk, config, offset) do
    offset == byte_size(chunk) - 1 and matches_byte?(chunk, offset, config.quote_escape_character)
  end

  defp matches_two_bytes?(chunk, offset, <<first>>, <<second>>) do
    offset + 1 < byte_size(chunk) and
      :binary.at(chunk, offset) == first and
      :binary.at(chunk, offset + 1) == second
  end

  defp halt_before_record(state, reason) do
    %{state | done?: true, halt_reason: reason, halted_before_eof?: true}
  end

  defp append_to_buffer!(buffer, segment) do
    if byte_size(buffer) + byte_size(segment) > @max_record_size do
      raise Error.new(:over_max_record_size)
    end

    buffer <> segment
  end

  defp flush_buffer(%{done?: true} = state, io), do: finalize(state, io)
  defp flush_buffer(%{buffer: ""} = state, io), do: finalize(state, io)

  defp flush_buffer(%{buffer: buffer} = state, io) do
    state
    |> handle_record!(io, buffer, state.record_start_offset)
    |> finalize(io)
  end

  defp normalize_delimited_line(line, %{record_delimiter: "\n"}) do
    if byte_size(line) > 0 and :binary.last(line) == ?\r do
      binary_part(line, 0, byte_size(line) - 1)
    else
      line
    end
  end

  defp normalize_delimited_line(line, _config), do: line

  defp handle_record!(state, io, line, record_start) do
    cond do
      comment_record?(line, state.config.input) ->
        state

      header_pending?(state) ->
        reject_unsupported_line!(line, state.config.input)
        consume_header!(state, line)

      true ->
        handle_scanned_record!(state, io, line, record_start)
    end
  end

  defp handle_scanned_record!(state, io, line, record_start) do
    case scan_range_position(state.config.scan_range, record_start) do
      :before ->
        state

      :after ->
        %{state | done?: true, halt_reason: :scan_range}

      :inside ->
        if limit_reached?(state) do
          %{state | done?: true, halt_reason: :limit}
        else
          reject_unsupported_line!(line, state.config.input)
          fields = parse_record!(line, state.config.input)

          handle_selected_record!(state, io, fields)
        end
    end
  end

  defp handle_selected_record!(state, io, fields) do
    cond do
      not where_matches?(fields, state) ->
        state

      SelectSQL.aggregate_plan?(state.plan) ->
        update_aggregate_record!(state, fields)

      true ->
        emit_record!(state, io, select_record!(fields, state))
    end
  end

  defp emit_record!(state, io, value) do
    record = SelectOutput.encode!(value, state.config.output)
    bytes_returned = ensure_result_size!(state, record)
    :ok = IO.binwrite(io, record)

    state
    |> Map.put(:bytes_returned, bytes_returned)
    |> Map.update!(:emitted, &(&1 + 1))
    |> maybe_mark_done()
  end

  defp init_aggregate_acc(%{projections: projections} = plan) do
    if SelectSQL.aggregate_plan?(plan) do
      projections
      |> Enum.with_index(1)
      |> Enum.map(fn {projection, index} -> init_aggregate(projection, index) end)
    else
      nil
    end
  end

  defp init_aggregate(projection, index) do
    %{kind: :aggregate, function: function, arg: arg} = SelectSQL.projection_expr(projection)

    %{
      function: function,
      arg: arg,
      output_name: SelectSQL.projection_output_name(projection, index),
      count: 0,
      sum: 0.0,
      value: nil
    }
  end

  defp update_aggregate_record!(%{aggregate_acc: aggregate_acc} = state, fields) do
    aggregate_acc =
      Enum.map(aggregate_acc, fn aggregate ->
        update_aggregate!(aggregate, fields, state)
      end)

    %{state | aggregate_acc: aggregate_acc}
  end

  defp update_aggregate!(%{function: :count, arg: :all} = aggregate, _fields, _state) do
    %{aggregate | count: aggregate.count + 1}
  end

  defp update_aggregate!(%{function: :count, arg: arg} = aggregate, fields, state) do
    case aggregate_value!(arg, fields, state) do
      {:ok, nil} -> aggregate
      {:ok, _value} -> %{aggregate | count: aggregate.count + 1}
      :missing -> aggregate
    end
  end

  defp update_aggregate!(%{function: function, arg: arg} = aggregate, fields, state)
       when function in [:avg, :sum] do
    case aggregate_value!(arg, fields, state) do
      {:ok, nil} ->
        aggregate

      {:ok, value} ->
        number = numeric_value!(value)
        %{aggregate | count: aggregate.count + 1, sum: aggregate.sum + number}

      :missing ->
        aggregate
    end
  end

  defp update_aggregate!(%{function: function, arg: arg} = aggregate, fields, state)
       when function in [:max, :min] do
    case aggregate_value!(arg, fields, state) do
      {:ok, nil} ->
        aggregate

      {:ok, value} ->
        number = numeric_value!(value)

        %{
          aggregate
          | count: aggregate.count + 1,
            value: aggregate_extreme(function, aggregate.value, number)
        }

      :missing ->
        aggregate
    end
  end

  defp aggregate_extreme(_function, nil, number), do: number
  defp aggregate_extreme(:max, current, number), do: max(current, number)
  defp aggregate_extreme(:min, current, number), do: min(current, number)

  defp aggregate_value!(expr, fields, state), do: where_value_expr!(fields, state, expr)

  defp cast_value!(value, :bool), do: cast_bool_value!(value)

  defp cast_value!(value, :int) do
    case Integer.parse(scalar_string(value)) do
      {integer, ""} -> integer
      _other -> raise Error.new(:cast_failed)
    end
  end

  defp cast_value!(value, :float), do: cast_numeric_value!(value)

  defp cast_value!(value, :string) when is_integer(value) or is_float(value),
    do: number_string(value)

  defp cast_value!(value, :string), do: scalar_string(value)
  defp cast_value!(value, :timestamp), do: timestamp_value!(value)

  defp cast_bool_value!(value) when is_boolean(value), do: value

  defp cast_bool_value!(value) do
    case String.downcase(scalar_string(value)) do
      "true" -> true
      "false" -> false
      _other -> raise Error.new(:cast_failed)
    end
  end

  defp cast_numeric_value!(value) when is_integer(value), do: value * 1.0
  defp cast_numeric_value!(value) when is_float(value), do: value

  defp cast_numeric_value!(value) do
    case Float.parse(scalar_string(value)) do
      {number, ""} -> number
      _other -> raise Error.new(:cast_failed)
    end
  end

  defp numeric_value!(value) when is_integer(value), do: value * 1.0
  defp numeric_value!(value) when is_float(value), do: value

  defp numeric_value!(value) do
    case Float.parse(scalar_string(value)) do
      {number, ""} ->
        number

      _other ->
        raise Error.new(:invalid_key_path)
    end
  end

  defp aggregate_result_record(aggregate_acc, %{config: %{output: %{format: "JSON"}}}) do
    Map.new(aggregate_acc, fn aggregate ->
      {aggregate.output_name, aggregate_result_json_field(aggregate)}
    end)
  end

  defp aggregate_result_record(aggregate_acc, _state),
    do: Enum.map(aggregate_acc, &aggregate_result_csv_field/1)

  defp aggregate_result_csv_field(%{function: :count, count: count}), do: Integer.to_string(count)
  defp aggregate_result_csv_field(%{function: :sum, count: 0}), do: ""
  defp aggregate_result_csv_field(%{function: :sum, sum: sum}), do: number_string(sum)
  defp aggregate_result_csv_field(%{function: :avg, count: 0}), do: ""

  defp aggregate_result_csv_field(%{function: :avg, count: count, sum: sum}),
    do: number_string(sum / count)

  defp aggregate_result_csv_field(%{function: function, count: 0}) when function in [:max, :min],
    do: ""

  defp aggregate_result_csv_field(%{function: function, value: value})
       when function in [:max, :min],
       do: number_string(value)

  defp aggregate_result_json_field(%{function: :count, count: count}), do: count
  defp aggregate_result_json_field(%{function: :sum, count: 0}), do: nil
  defp aggregate_result_json_field(%{function: :sum, sum: sum}), do: json_number(sum)
  defp aggregate_result_json_field(%{function: :avg, count: 0}), do: nil

  defp aggregate_result_json_field(%{function: :avg, count: count, sum: sum}),
    do: json_number(sum / count)

  defp aggregate_result_json_field(%{function: function, count: 0}) when function in [:max, :min],
    do: nil

  defp aggregate_result_json_field(%{function: function, value: value})
       when function in [:max, :min],
       do: json_number(value)

  defp number_string(number) when is_integer(number), do: Integer.to_string(number)

  defp number_string(number) when is_float(number) do
    if number == trunc(number) * 1.0 do
      Integer.to_string(trunc(number))
    else
      :erlang.float_to_binary(number, [:compact, decimals: 15])
    end
  end

  defp json_number(number) when is_integer(number), do: number

  defp json_number(number) when is_float(number) do
    if number == trunc(number) * 1.0, do: trunc(number), else: number
  end

  defp ensure_result_size!(state, record) do
    next_size = state.bytes_returned + byte_size(record)

    if next_size > state.config.result_max_bytes do
      raise Error.new(:invalid_request,
              message: "SelectObjectContent result exceeds configured staging limit"
            )
    end

    next_size
  end

  defp maybe_mark_done(%{plan: %{limit: limit}, emitted: emitted} = state)
       when is_integer(limit) and emitted >= limit do
    %{state | done?: true, halt_reason: :limit}
  end

  defp maybe_mark_done(state), do: state

  defp mark_halt_before_eof(%{done?: true} = state, rest) when rest != "" do
    %{state | halted_before_eof?: true}
  end

  defp mark_halt_before_eof(state, _rest), do: state

  defp scan_range_position(nil, _record_start), do: :inside
  defp scan_range_position(%{empty?: true}, _record_start), do: :after
  defp scan_range_position(%{start: start}, record_start) when record_start < start, do: :before
  defp scan_range_position(%{end: nil}, _record_start), do: :inside

  defp scan_range_position(%{end: end_offset}, record_start) when record_start > end_offset,
    do: :after

  defp scan_range_position(_scan_range, _record_start), do: :inside

  defp reject_unsupported_line!(line, config) do
    reject_oversized_record!(line)
    validate_utf8_record!(line)

    if not config.allow_quoted_record_delimiter and
         :binary.match(line, config.record_delimiter) != :nomatch do
      unsupported!("Embedded CSV record delimiters are not implemented for SelectObjectContent")
    end

    :ok
  end

  defp validate_utf8_record!(line) do
    unless String.valid?(line) do
      raise Error.new(:invalid_text_encoding)
    end

    :ok
  end

  defp comment_record?(_line, %{comments: nil}), do: false

  defp comment_record?(line, %{comments: comment}) do
    :binary.match(line, comment) == {0, byte_size(comment)}
  end

  defp header_pending?(%{header_seen?: false, config: %{input: %{file_header_info: header_info}}})
       when header_info in ["USE", "IGNORE"],
       do: true

  defp header_pending?(_state), do: false

  defp header_must_parse?(%{config: %{input: %{file_header_info: "USE"}}, plan: plan}),
    do: header_refs?(plan)

  defp header_must_parse?(_state), do: false

  defp header_skip_kind(chunk, input) do
    if comment_prefix?(chunk, input), do: :comment, else: :header
  end

  defp comment_prefix?(_chunk, %{comments: nil}), do: false

  defp comment_prefix?(chunk, %{comments: comment}) do
    byte_size(chunk) >= byte_size(comment) and
      binary_part(chunk, 0, byte_size(comment)) == comment
  end

  defp maybe_mark_header_seen(state, :header), do: %{state | header_seen?: true}
  defp maybe_mark_header_seen(state, :comment), do: state

  defp consume_header!(%{config: %{input: %{file_header_info: "USE"}}} = state, line) do
    header = parse_record!(line, state.config.input)
    validate_header_refs!(state.plan, header)
    %{state | header: header, header_seen?: true}
  end

  defp consume_header!(state, _line), do: %{state | header_seen?: true}

  defp parse_record!(line, config) do
    line
    |> parse_record_fields!(config, [], [], :field_start)
    |> Enum.reverse()
  end

  defp parse_record_fields!(<<>>, _config, fields, current, mode)
       when mode in [:field_start, :unquoted, :after_quote] do
    [finish_field!(current) | fields]
  end

  defp parse_record_fields!(<<>>, _config, _fields, _current, :quoted) do
    invalid!("Unterminated quoted CSV field")
  end

  defp parse_record_fields!(
         <<byte, rest::binary>>,
         %{quote_character: <<byte>>} = config,
         fields,
         current,
         :field_start
       ) do
    parse_record_fields!(rest, config, fields, current, :quoted)
  end

  defp parse_record_fields!(
         <<byte, rest::binary>>,
         %{field_delimiter: <<byte>>} = config,
         fields,
         current,
         mode
       )
       when mode in [:field_start, :unquoted, :after_quote] do
    parse_record_fields!(rest, config, [finish_field!(current) | fields], [], :field_start)
  end

  defp parse_record_fields!(
         <<byte, _rest::binary>>,
         %{quote_character: <<byte>>} = _config,
         _fields,
         _current,
         :unquoted
       ) do
    invalid!("Unexpected CSV quote character in unquoted field")
  end

  defp parse_record_fields!(
         <<byte, _rest::binary>>,
         %{quote_character: <<byte>>} = _config,
         _fields,
         _current,
         :after_quote
       ) do
    invalid!("Unexpected CSV quote character after quoted field")
  end

  defp parse_record_fields!(
         <<escape, quote, rest::binary>>,
         %{quote_escape_character: <<escape>>, quote_character: <<quote>>} = config,
         fields,
         current,
         :quoted
       ) do
    parse_record_fields!(rest, config, fields, [<<quote>> | current], :quoted)
  end

  defp parse_record_fields!(
         <<byte, rest::binary>>,
         %{quote_character: <<byte>>} = config,
         fields,
         current,
         :quoted
       ) do
    parse_record_fields!(rest, config, fields, current, :after_quote)
  end

  defp parse_record_fields!(
         <<byte, rest::binary>>,
         %{field_delimiter: <<byte>>} = config,
         fields,
         current,
         :quoted
       ) do
    parse_record_fields!(rest, config, fields, [<<byte>> | current], :quoted)
  end

  defp parse_record_fields!(<<byte, rest::binary>>, config, fields, current, mode)
       when mode in [:field_start, :unquoted] do
    parse_record_fields!(rest, config, fields, [<<byte>> | current], :unquoted)
  end

  defp parse_record_fields!(<<byte, rest::binary>>, config, fields, current, :quoted) do
    parse_record_fields!(rest, config, fields, [<<byte>> | current], :quoted)
  end

  defp parse_record_fields!(<<_byte, _rest::binary>>, _config, _fields, _current, :after_quote) do
    invalid!("Unexpected CSV data after quoted field")
  end

  defp finish_field!(current) do
    field =
      current
      |> Enum.reverse()
      |> IO.iodata_to_binary()

    if byte_size(field) > @max_column_size do
      raise Error.new(:column_too_long)
    end

    field
  end

  defp where_matches?(_fields, %{plan: %{where: nil}}), do: true

  defp where_matches?(fields, %{plan: %{where: where}} = state) do
    eval_where!(where, fields, state) == true
  end

  defp eval_where!(%{kind: :and, left: left, right: right}, fields, state) do
    and_result(eval_where!(left, fields, state), eval_where!(right, fields, state))
  end

  defp eval_where!(%{kind: :or, left: left, right: right}, fields, state) do
    or_result(eval_where!(left, fields, state), eval_where!(right, fields, state))
  end

  defp eval_where!(%{kind: :not, expr: expr}, fields, state) do
    not_result(eval_where!(expr, fields, state))
  end

  defp eval_where!(%{predicate: :is_null, left: expr}, fields, state) do
    where_value_expr!(fields, state, expr) == {:ok, nil}
  end

  defp eval_where!(%{predicate: :is_not_null, left: expr}, fields, state) do
    case where_value_expr!(fields, state, expr) do
      {:ok, nil} -> false
      {:ok, _value} -> true
      :missing -> false
    end
  end

  defp eval_where!(%{predicate: :in, left: expr, values: values}, fields, state) do
    case where_value_expr!(fields, state, expr) do
      {:ok, nil} -> :unknown
      {:ok, value} -> in_values!(value, values, fields, state)
      :missing -> :unknown
    end
  end

  defp eval_where!(%{predicate: :not_in, left: expr, values: values}, fields, state) do
    case where_value_expr!(fields, state, expr) do
      {:ok, nil} -> :unknown
      {:ok, value} -> not_result(in_values!(value, values, fields, state))
      :missing -> :unknown
    end
  end

  defp eval_where!(%{predicate: :between, left: expr, lower: lower, upper: upper}, fields, state) do
    case where_value_expr!(fields, state, expr) do
      {:ok, nil} -> :unknown
      {:ok, value} -> between_exprs!(value, lower, upper, fields, state)
      :missing -> :unknown
    end
  end

  defp eval_where!(
         %{predicate: :not_between, left: expr, lower: lower, upper: upper},
         fields,
         state
       ) do
    case where_value_expr!(fields, state, expr) do
      {:ok, nil} -> :unknown
      {:ok, value} -> not_result(between_exprs!(value, lower, upper, fields, state))
      :missing -> :unknown
    end
  end

  defp eval_where!(
         %{predicate: :like, left: expr, pattern: pattern, escape: escape},
         fields,
         state
       ) do
    case where_value_expr!(fields, state, expr) do
      {:ok, nil} -> :unknown
      {:ok, value} -> like_expr!(value, pattern, escape, fields, state)
      :missing -> :unknown
    end
  end

  defp eval_where!(where, fields, state) do
    case where_value_expr!(fields, state, where.left) do
      {:ok, nil} -> :unknown
      {:ok, value} -> compare_right!(value, where.op, where.right, fields, state)
      :missing -> :unknown
    end
  end

  defp and_result(false, _right), do: false
  defp and_result(_left, false), do: false
  defp and_result(true, true), do: true
  defp and_result(_left, _right), do: :unknown

  defp or_result(true, _right), do: true
  defp or_result(_left, true), do: true
  defp or_result(false, false), do: false
  defp or_result(_left, _right), do: :unknown

  defp not_result(true), do: false
  defp not_result(false), do: true
  defp not_result(:unknown), do: :unknown

  defp select_record!(fields, %{config: %{output: %{format: "JSON"}}} = state),
    do: select_json_value!(fields, state)

  defp select_record!(fields, state), do: select_csv_fields!(fields, state)

  defp select_csv_fields!(fields, %{plan: %{projections: :all}}), do: fields

  defp select_csv_fields!(fields, %{plan: %{projections: projections}} = state) do
    Enum.map(projections, fn projection ->
      case value_expr!(fields, state, SelectSQL.projection_expr(projection), :projection) do
        {:ok, nil} -> ""
        {:ok, value} -> output_field!(value)
        :missing -> ""
      end
    end)
  end

  defp select_json_value!(fields, %{plan: %{projections: :all}}) do
    fields
    |> Enum.with_index(1)
    |> Map.new(fn {value, index} -> {"_#{index}", value} end)
  end

  defp select_json_value!(fields, %{plan: %{projections: projections}} = state) do
    projections
    |> Enum.with_index(1)
    |> Enum.reduce(%{}, fn {projection, index}, acc ->
      name = SelectSQL.projection_output_name(projection, index)

      case value_expr!(fields, state, SelectSQL.projection_expr(projection), :projection) do
        {:ok, value} -> put_json_projected!(acc, name, output_json_value(value))
        :missing -> acc
      end
    end)
  end

  defp value_expr!(_fields, _state, %{kind: :literal, type: :timestamp, value: value}, _mode),
    do: parse_timestamp(value)

  defp value_expr!(_fields, _state, %{kind: :literal, value: value}, _mode), do: {:ok, value}

  defp value_expr!(fields, state, %{kind: :arithmetic, op: op, left: left, right: right}, mode) do
    arithmetic_value!(fields, state, left, op, right, arithmetic_expr_mode(mode))
  end

  defp value_expr!(fields, state, %{kind: :cast, expr: expr, type: type}, _mode) do
    case where_value_expr!(fields, state, expr) do
      {:ok, nil} -> {:ok, nil}
      {:ok, value} -> {:ok, cast_value!(value, type)}
      :missing -> :missing
    end
  end

  defp value_expr!(
         fields,
         state,
         %{kind: :case, clauses: clauses, else_expr: else_expr},
         mode
       ) do
    eval_case_clauses!(fields, state, clauses, else_expr, conditional_expr_mode(mode))
  end

  defp value_expr!(
         fields,
         state,
         %{kind: :simple_case, operand: operand, clauses: clauses, else_expr: else_expr},
         mode
       ) do
    eval_simple_case_clauses!(
      fields,
      state,
      operand,
      clauses,
      else_expr,
      conditional_expr_mode(mode)
    )
  end

  defp value_expr!(
         fields,
         state,
         %{kind: :conditional_function, function: :coalesce, args: args},
         mode
       ) do
    coalesce_value!(fields, state, args, conditional_expr_mode(mode))
  end

  defp value_expr!(
         fields,
         state,
         %{kind: :conditional_function, function: :nullif, left: left, right: right},
         mode
       ) do
    nullif_value!(fields, state, left, right, conditional_expr_mode(mode))
  end

  defp value_expr!(
         fields,
         state,
         %{kind: :date_function, function: :to_timestamp, arg: arg},
         mode
       ) do
    map_timestamp_arg!(fields, state, arg, mode, & &1)
  end

  defp value_expr!(
         fields,
         state,
         %{kind: :date_function, function: :to_string, timestamp: timestamp, pattern: pattern},
         mode
       ) do
    to_string_value!(fields, state, timestamp, pattern, date_expr_mode(mode))
  end

  defp value_expr!(
         _fields,
         %{utc_now: utc_now},
         %{kind: :date_function, function: :utcnow},
         _mode
       ) do
    {:ok, utc_now}
  end

  defp value_expr!(
         fields,
         state,
         %{kind: :date_function, function: :extract, part: part, arg: arg},
         mode
       ) do
    map_timestamp_arg!(fields, state, arg, mode, &SelectTimestamp.extract(part, &1))
  end

  defp value_expr!(
         fields,
         state,
         %{
           kind: :date_function,
           function: :date_add,
           part: part,
           quantity: quantity,
           timestamp: timestamp
         },
         mode
       ) do
    date_add_value!(fields, state, part, quantity, timestamp, date_expr_mode(mode))
  end

  defp value_expr!(
         fields,
         state,
         %{kind: :date_function, function: :date_diff, part: part, left: left, right: right},
         mode
       ) do
    date_diff_value!(fields, state, part, left, right, date_expr_mode(mode))
  end

  defp value_expr!(
         fields,
         state,
         %{kind: :string_function, function: :lower, arg: arg},
         mode
       ) do
    map_string_arg!(fields, state, arg, mode, &String.downcase/1)
  end

  defp value_expr!(
         fields,
         state,
         %{kind: :string_function, function: :upper, arg: arg},
         mode
       ) do
    map_string_arg!(fields, state, arg, mode, &String.upcase/1)
  end

  defp value_expr!(
         fields,
         state,
         %{kind: :string_function, function: :char_length, arg: arg},
         mode
       ) do
    map_string_arg!(fields, state, arg, mode, &String.length/1)
  end

  defp value_expr!(
         fields,
         state,
         %{kind: :string_function, function: :substring, arg: arg, start: start, length: length},
         mode
       ) do
    map_string_arg!(fields, state, arg, mode, &substring_value!(&1, start, length))
  end

  defp value_expr!(
         fields,
         state,
         %{
           kind: :string_function,
           function: :trim,
           arg: arg,
           direction: direction,
           characters: characters
         },
         mode
       ) do
    map_string_arg!(fields, state, arg, mode, &trim_value!(&1, direction, characters))
  end

  defp value_expr!(fields, state, %{kind: :unary_minus, expr: expr}, mode) do
    case value_expr!(fields, state, expr, arithmetic_expr_mode(mode)) do
      {:ok, nil} -> {:ok, nil}
      {:ok, value} -> {:ok, -numeric_value!(value)}
      :missing -> :missing
    end
  end

  defp value_expr!(fields, state, ref, :projection), do: ref_value(fields, state, ref)
  defp value_expr!(fields, state, ref, :where), do: where_ref_value(fields, state, ref)

  defp where_value_expr!(fields, state, expr), do: value_expr!(fields, state, expr, :where)

  defp conditional_expr_mode(_mode), do: :where
  defp arithmetic_expr_mode(_mode), do: :where
  defp date_expr_mode(_mode), do: :where

  defp eval_case_clauses!(
         fields,
         state,
         [%{condition: condition, result: result} | rest],
         else_expr,
         mode
       ) do
    case eval_where!(condition, fields, state) do
      true -> value_expr!(fields, state, result, mode)
      _not_true -> eval_case_clauses!(fields, state, rest, else_expr, mode)
    end
  end

  defp eval_case_clauses!(_fields, _state, [], nil, _mode), do: {:ok, nil}

  defp eval_case_clauses!(fields, state, [], else_expr, mode),
    do: value_expr!(fields, state, else_expr, mode)

  defp eval_simple_case_clauses!(fields, state, operand, clauses, else_expr, mode) do
    case value_expr!(fields, state, operand, mode) do
      {:ok, nil} ->
        eval_simple_case_no_match!(fields, state, else_expr, mode)

      {:ok, operand_value} ->
        eval_simple_case_matches!(fields, state, operand_value, clauses, else_expr, mode)

      :missing ->
        eval_simple_case_no_match!(fields, state, else_expr, mode)
    end
  end

  defp eval_simple_case_matches!(
         fields,
         state,
         operand_value,
         [%{when_expr: when_expr, result: result} | rest],
         else_expr,
         mode
       ) do
    case value_expr!(fields, state, when_expr, mode) do
      {:ok, nil} ->
        eval_simple_case_matches!(fields, state, operand_value, rest, else_expr, mode)

      {:ok, when_value} ->
        if value_equal!(operand_value, when_value) do
          value_expr!(fields, state, result, mode)
        else
          eval_simple_case_matches!(fields, state, operand_value, rest, else_expr, mode)
        end

      :missing ->
        eval_simple_case_matches!(fields, state, operand_value, rest, else_expr, mode)
    end
  end

  defp eval_simple_case_matches!(fields, state, _operand_value, [], else_expr, mode),
    do: eval_simple_case_no_match!(fields, state, else_expr, mode)

  defp eval_simple_case_no_match!(_fields, _state, nil, _mode), do: {:ok, nil}

  defp eval_simple_case_no_match!(fields, state, else_expr, mode),
    do: value_expr!(fields, state, else_expr, mode)

  defp coalesce_value!(_fields, _state, [], _mode), do: {:ok, nil}

  defp coalesce_value!(fields, state, [arg | rest], mode) do
    case value_expr!(fields, state, arg, mode) do
      {:ok, nil} -> coalesce_value!(fields, state, rest, mode)
      {:ok, value} -> {:ok, value}
      :missing -> coalesce_value!(fields, state, rest, mode)
    end
  end

  defp nullif_value!(fields, state, left, right, mode) do
    case value_expr!(fields, state, left, mode) do
      {:ok, nil} ->
        {:ok, nil}

      {:ok, left_value} ->
        case value_expr!(fields, state, right, mode) do
          {:ok, nil} ->
            {:ok, left_value}

          {:ok, right_value} ->
            if value_equal!(left_value, right_value), do: {:ok, nil}, else: {:ok, left_value}

          :missing ->
            {:ok, left_value}
        end

      :missing ->
        :missing
    end
  end

  defp arithmetic_value!(fields, state, left, op, right, mode) do
    case value_expr!(fields, state, left, mode) do
      {:ok, nil} ->
        {:ok, nil}

      {:ok, left_value} ->
        case value_expr!(fields, state, right, mode) do
          {:ok, nil} -> {:ok, nil}
          {:ok, right_value} -> {:ok, arithmetic_result!(left_value, op, right_value)}
          :missing -> :missing
        end

      :missing ->
        :missing
    end
  end

  defp arithmetic_result!(left, op, right) do
    left_number = numeric_value!(left)
    right_number = numeric_value!(right)

    case op do
      :add ->
        left_number + right_number

      :subtract ->
        left_number - right_number

      :multiply ->
        left_number * right_number

      :divide ->
        reject_zero_divisor!(right_number)
        left_number / right_number

      :mod ->
        reject_zero_divisor!(right_number)
        left_number - trunc(left_number / right_number) * right_number
    end
  end

  defp reject_zero_divisor!(number) when number == 0, do: raise(Error.new(:invalid_key_path))

  defp reject_zero_divisor!(_number), do: :ok

  defp date_add_value!(fields, state, part, quantity_expr, timestamp_expr, mode) do
    with {:ok, quantity} when not is_nil(quantity) <-
           value_expr!(fields, state, quantity_expr, mode),
         {:ok, timestamp} when not is_nil(timestamp) <-
           value_expr!(fields, state, timestamp_expr, mode) do
      {:ok, SelectTimestamp.add(part, integer_quantity!(quantity), timestamp_value!(timestamp))}
    else
      {:ok, nil} -> {:ok, nil}
      :missing -> :missing
    end
  end

  defp date_diff_value!(fields, state, part, left_expr, right_expr, mode) do
    with {:ok, left} when not is_nil(left) <- value_expr!(fields, state, left_expr, mode),
         {:ok, right} when not is_nil(right) <- value_expr!(fields, state, right_expr, mode) do
      {:ok, SelectTimestamp.diff(part, timestamp_value!(left), timestamp_value!(right))}
    else
      {:ok, nil} -> {:ok, nil}
      :missing -> :missing
    end
  end

  defp to_string_value!(fields, state, timestamp_expr, pattern_expr, mode) do
    with {:ok, timestamp} when not is_nil(timestamp) <-
           value_expr!(fields, state, timestamp_expr, mode),
         {:ok, pattern} when not is_nil(pattern) <-
           value_expr!(fields, state, pattern_expr, mode),
         {:ok, formatted} <-
           SelectTimestamp.format(timestamp_value!(timestamp), scalar_string(pattern)) do
      {:ok, formatted}
    else
      {:ok, nil} -> {:ok, nil}
      :missing -> :missing
      :error -> raise Error.new(:invalid_key_path)
    end
  end

  defp map_timestamp_arg!(fields, state, arg, mode, fun) do
    case value_expr!(fields, state, arg, mode) do
      {:ok, nil} -> {:ok, nil}
      {:ok, value} -> {:ok, value |> timestamp_value!() |> fun.()}
      :missing -> :missing
    end
  end

  defp parse_timestamp(value) do
    case SelectTimestamp.parse(value) do
      {:ok, timestamp} ->
        {:ok, timestamp}

      :error ->
        raise Error.new(:value_parse_failure)
    end
  end

  defp timestamp_value!(%SelectTimestamp{} = timestamp), do: timestamp

  defp timestamp_value!(value) do
    case SelectTimestamp.parse(scalar_string(value)) do
      {:ok, timestamp} ->
        timestamp

      :error ->
        raise Error.new(:value_parse_failure)
    end
  end

  defp integer_quantity!(value) when is_integer(value), do: value

  defp integer_quantity!(value) when is_float(value) and value == trunc(value) * 1.0,
    do: trunc(value)

  defp integer_quantity!(value) do
    case Integer.parse(scalar_string(value)) do
      {integer, ""} ->
        integer

      _other ->
        unsupported!("Only integer date quantities are implemented for SelectObjectContent")
    end
  end

  defp compare_right!(left, op, right_expr, fields, state) do
    case where_value_expr!(fields, state, right_expr) do
      {:ok, nil} -> :unknown
      {:ok, right} -> compare!(left, op, right)
      :missing -> :unknown
    end
  end

  defp in_values!(left, values, fields, state) do
    Enum.reduce_while(values, false, fn value_expr, result ->
      case where_value_expr!(fields, state, value_expr) do
        {:ok, nil} ->
          {:cont, :unknown}

        {:ok, right} ->
          if value_equal!(left, right), do: {:halt, true}, else: {:cont, result}

        :missing ->
          {:cont, :unknown}
      end
    end)
  end

  defp between_exprs!(value, lower_expr, upper_expr, fields, state) do
    with {:ok, lower} when not is_nil(lower) <- where_value_expr!(fields, state, lower_expr),
         {:ok, upper} when not is_nil(upper) <- where_value_expr!(fields, state, upper_expr) do
      between!(value, lower, upper)
    else
      _null_or_missing -> :unknown
    end
  end

  defp like_expr!(value, pattern_expr, escape_expr, fields, state) do
    with {:ok, pattern} when not is_nil(pattern) <- where_value_expr!(fields, state, pattern_expr),
         {:ok, escape} <- like_escape!(escape_expr, fields, state) do
      regex = SelectSQL.compile_like_regex!(scalar_string(pattern), escape)
      Regex.match?(regex, scalar_string(value))
    else
      _null_or_missing -> :unknown
    end
  end

  defp like_escape!(nil, _fields, _state), do: {:ok, nil}

  defp like_escape!(expr, fields, state) do
    case where_value_expr!(fields, state, expr) do
      {:ok, nil} -> :unknown
      {:ok, escape} -> {:ok, scalar_string(escape)}
      :missing -> :unknown
    end
  end

  defp map_string_arg!(fields, state, arg, mode, fun) do
    case value_expr!(fields, state, arg, mode) do
      {:ok, nil} -> {:ok, nil}
      {:ok, value} -> {:ok, value |> scalar_string() |> fun.()}
      :missing -> :missing
    end
  end

  defp output_field!(value) when is_binary(value), do: value
  defp output_field!(value) when is_boolean(value), do: scalar_string(value)
  defp output_field!(value) when is_integer(value) or is_float(value), do: number_string(value)
  defp output_field!(%SelectTimestamp{} = value), do: SelectTimestamp.to_string(value)

  defp output_json_value(%SelectTimestamp{} = value), do: SelectTimestamp.to_string(value)
  defp output_json_value(value), do: value

  defp put_json_projected!(acc, name, _value) when is_map_key(acc, name) do
    raise Error.new(:invalid_key_path)
  end

  defp put_json_projected!(acc, name, value), do: Map.put(acc, name, value)

  defp value_equal!(left, right) when is_number(left) or is_number(right) do
    case numeric_value_pair(left, right) do
      {:ok, left_number, right_number} -> left_number == right_number
      :error -> false
    end
  end

  defp value_equal!(%SelectTimestamp{} = left, right),
    do: timestamp_compare!(left, "=", timestamp_value!(right))

  defp value_equal!(left, %SelectTimestamp{} = right),
    do: timestamp_compare!(timestamp_value!(left), "=", right)

  defp value_equal!(left, right), do: scalar_string(left) == scalar_string(right)

  defp substring_value!(value, start, nil) do
    value
    |> String.graphemes()
    |> Enum.drop(max(start, 1) - 1)
    |> Enum.join()
  end

  defp substring_value!(value, start, length) do
    value
    |> String.graphemes()
    |> substring_graphemes(start, length)
    |> Enum.join()
  end

  defp substring_graphemes(_graphemes, _start, 0), do: []

  defp substring_graphemes(graphemes, start, length) when start < 1 do
    effective_length = start + length - 1

    if effective_length <= 0 do
      []
    else
      Enum.take(graphemes, effective_length)
    end
  end

  defp substring_graphemes(graphemes, start, length) do
    graphemes
    |> Enum.drop(start - 1)
    |> Enum.take(length)
  end

  defp trim_value!(value, direction, characters) do
    trim_set = characters |> String.graphemes() |> MapSet.new()
    graphemes = String.graphemes(value)

    graphemes =
      if direction in [:leading, :both],
        do: trim_leading_graphemes(graphemes, trim_set),
        else: graphemes

    graphemes =
      if direction in [:trailing, :both],
        do: graphemes |> Enum.reverse() |> trim_leading_graphemes(trim_set) |> Enum.reverse(),
        else: graphemes

    Enum.join(graphemes)
  end

  defp trim_leading_graphemes(graphemes, trim_set) when map_size(trim_set) == 0, do: graphemes

  defp trim_leading_graphemes([grapheme | rest], trim_set) do
    if MapSet.member?(trim_set, grapheme) do
      trim_leading_graphemes(rest, trim_set)
    else
      [grapheme | rest]
    end
  end

  defp trim_leading_graphemes([], _trim_set), do: []

  defp ref_value(fields, state, ref) do
    validate_qualifier!(ref, state.plan)

    if SelectSQL.positional_ref?(ref) do
      positional_value(fields, ref)
    else
      header_value(fields, state.header, ref)
    end
  end

  defp where_ref_value(fields, state, ref) do
    case ref_value(fields, state, ref) do
      {:ok, ""} -> {:ok, nil}
      other -> other
    end
  end

  defp positional_value(fields, %{name: "_" <> index}) do
    {position, ""} = Integer.parse(index)

    case Enum.at(fields, position - 1) do
      nil -> :missing
      value -> {:ok, value}
    end
  end

  defp header_value(_fields, nil, _ref), do: raise(Error.new(:missing_header_name))

  defp header_value(fields, header, %{name: name, quoted?: true}) do
    header
    |> matching_header_indexes(&(&1 == name))
    |> header_match_value(fields)
  end

  defp header_value(fields, header, %{name: name, quoted?: false}) do
    wanted = String.downcase(name)

    header
    |> matching_header_indexes(&(String.downcase(&1) == wanted))
    |> header_match_value(fields)
  end

  defp matching_header_indexes(header, predicate) do
    header
    |> Enum.with_index()
    |> Enum.filter(fn {name, _idx} -> predicate.(name) end)
    |> Enum.map(fn {_name, idx} -> idx end)
  end

  defp header_match_value([], _fields), do: raise(Error.new(:missing_header_name))

  defp header_match_value([_one, _two | _rest], _fields),
    do: raise(Error.new(:ambiguous_field_name))

  defp header_match_value([idx], fields) do
    case Enum.at(fields, idx) do
      nil -> :missing
      value -> {:ok, value}
    end
  end

  defp validate_qualifier!(%{qualifier: nil}, _plan), do: :ok

  defp validate_qualifier!(%{qualifier: qualifier}, %{alias: alias_name}) do
    qualifier = String.downcase(qualifier)
    alias_name = if alias_name, do: String.downcase(alias_name)

    if qualifier in Enum.reject([alias_name, "s3object", "object"], &is_nil/1) do
      :ok
    else
      unsupported!("Unsupported SelectObjectContent SQL field qualifier")
    end
  end

  defp compare!(left, op, right)
       when op in ["=", "=="] and
              (is_integer(left) or is_float(left) or is_integer(right) or is_float(right)) do
    case numeric_value_pair(left, right) do
      {:ok, left_number, right_number} -> left_number == right_number
      :error -> false
    end
  end

  defp compare!(%SelectTimestamp{} = left, op, right) do
    timestamp_compare!(left, op, timestamp_value!(right))
  end

  defp compare!(left, op, %SelectTimestamp{} = right) do
    timestamp_compare!(timestamp_value!(left), op, right)
  end

  defp compare!(left, op, right) when op in ["=", "=="], do: left == right

  defp compare!(left, op, right) when op in ["!=", "<>"], do: not compare!(left, "=", right)

  defp compare!(left, op, right) when is_integer(left) or is_float(left) do
    {left_number, right_number} = numeric_pair!(left, right)

    ordered_compare!(left_number, op, right_number)
  end

  defp compare!(left, op, right) do
    {left_number, right_number} = numeric_pair!(left, right)

    ordered_compare!(left_number, op, right_number)
  end

  defp ordered_compare!(left_number, op, right_number) do
    case op do
      "<" -> left_number < right_number
      "<=" -> left_number <= right_number
      ">" -> left_number > right_number
      ">=" -> left_number >= right_number
    end
  end

  defp timestamp_compare!(left, op, right) do
    comparison = SelectTimestamp.compare(left, right)

    case op do
      "=" -> comparison == :eq
      "==" -> comparison == :eq
      "!=" -> comparison != :eq
      "<>" -> comparison != :eq
      "<" -> comparison == :lt
      "<=" -> comparison in [:lt, :eq]
      ">" -> comparison == :gt
      ">=" -> comparison in [:gt, :eq]
    end
  end

  defp between!(value, lower, upper) do
    if match?(%SelectTimestamp{}, value) or match?(%SelectTimestamp{}, lower) or
         match?(%SelectTimestamp{}, upper) do
      timestamp_compare!(timestamp_value!(value), ">=", timestamp_value!(lower)) and
        timestamp_compare!(timestamp_value!(value), "<=", timestamp_value!(upper))
    else
      numeric_between!(value, lower, upper)
    end
  end

  defp numeric_between!(value, lower, upper) do
    {value_number, lower_number} = numeric_pair!(value, lower)
    {_value_number, upper_number} = numeric_pair!(value, upper)
    value_number >= lower_number and value_number <= upper_number
  end

  defp numeric_pair!(left, right) do
    case numeric_value_pair(left, right) do
      {:ok, left_number, right_number} ->
        {left_number, right_number}

      :error ->
        raise Error.new(:invalid_key_path)
    end
  end

  defp numeric_value_pair(left, right) do
    with {:ok, left_number} <- numeric_literal(scalar_string(left)),
         {:ok, right_number} <- numeric_literal(scalar_string(right)) do
      {:ok, left_number, right_number}
    else
      _other -> :error
    end
  end

  defp scalar_string(value) when is_binary(value), do: value
  defp scalar_string(value) when is_boolean(value), do: to_string(value)
  defp scalar_string(value) when is_integer(value), do: Integer.to_string(value)
  defp scalar_string(%SelectTimestamp{} = value), do: SelectTimestamp.to_string(value)

  defp scalar_string(value) when is_float(value),
    do: :erlang.float_to_binary(value, [:compact, decimals: 15])

  defp numeric_literal(value) do
    case Float.parse(value) do
      {number, ""} -> {:ok, number}
      _other -> :error
    end
  end

  defp limit_reached?(%{plan: %{limit: limit}, emitted: emitted})
       when is_integer(limit) and emitted >= limit,
       do: true

  defp limit_reached?(_state), do: false

  defp finalize(state, io) do
    validate_final_header!(state)

    state
    |> emit_aggregate_record_if_needed(io)
    |> Map.delete(:buffer)
    |> Map.delete(:config)
    |> Map.delete(:plan)
    |> Map.delete(:header)
    |> Map.delete(:header_seen?)
    |> Map.delete(:header_skip)
    |> Map.delete(:emitted)
    |> Map.delete(:aggregate_acc)
    |> Map.delete(:record_start_offset)
    |> Map.delete(:record_scan)
    |> Map.delete(:halted_before_eof?)
    |> Map.delete(:done?)
  end

  defp emit_aggregate_record_if_needed(%{aggregate_acc: nil} = state, _io), do: state
  defp emit_aggregate_record_if_needed(%{plan: %{limit: 0}} = state, _io), do: state

  defp emit_aggregate_record_if_needed(%{aggregate_acc: aggregate_acc, emitted: 0} = state, io) do
    emit_record!(state, io, aggregate_result_record(aggregate_acc, state))
  end

  defp emit_aggregate_record_if_needed(state, _io), do: state

  defp mark_source_complete(%{drain_on_halt?: true} = state),
    do: %{state | source_complete?: true}

  defp mark_source_complete(%{halted_before_eof?: true} = state), do: state
  defp mark_source_complete(state), do: %{state | source_complete?: true}

  defp validate_final_header!(%{plan: %{limit: 0}}), do: :ok

  defp validate_final_header!(
         %{header: nil, config: %{input: %{file_header_info: "USE"}}} = state
       ) do
    if header_refs?(state.plan), do: raise(Error.new(:missing_header_name)), else: :ok
  end

  defp validate_final_header!(_state), do: :ok

  defp config!(input_options, output_options, output_format) do
    input = input_config!(input_options || %{})
    output = SelectOutput.config!(output_format, output_options || %{})
    %{input: input, output: output, result_max_bytes: result_max_bytes!(), scan_range: nil}
  end

  defp result_max_bytes! do
    value =
      :maxio
      |> Application.get_env(:s3, [])
      |> Keyword.get(:select_result_max_bytes, @default_max_result_size)

    if is_integer(value) and value > 0 do
      value
    else
      raise Error.new(:internal_error,
              message: "SelectObjectContent result staging limit is misconfigured"
            )
    end
  end

  defp input_config!(options) do
    reject_unknown_options!(options, @input_options)

    config = %{
      file_header_info: enum_option!(options, "FileHeaderInfo", "NONE", ~w(NONE USE IGNORE)),
      record_delimiter: char_option!(options, "RecordDelimiter", "\n"),
      field_delimiter: char_option!(options, "FieldDelimiter", ","),
      quote_character: char_option!(options, "QuoteCharacter", "\""),
      quote_escape_character: char_option!(options, "QuoteEscapeCharacter", "\""),
      comments: char_option!(options, "Comments", "#"),
      allow_quoted_record_delimiter: bool_option!(options, "AllowQuotedRecordDelimiter", false)
    }

    validate_csv_config!(config)
  end

  defp validate_csv_config!(config) do
    cond do
      config.record_delimiter == config.field_delimiter ->
        invalid!("CSV RecordDelimiter and FieldDelimiter must differ")

      config.quote_character in [config.record_delimiter, config.field_delimiter] ->
        unsupported!(
          "CSV QuoteCharacter cannot match a delimiter for this SelectObjectContent slice"
        )

      true ->
        config
    end
  end

  defp validate_plan!(plan, %{input: input_config} = config) do
    if Map.get(plan, :from_wildcard?, false) do
      raise Error.new(:invalid_key_path)
    end

    validate_projection_count!(plan)
    validate_output_projection_names!(plan, config)
    validate_aggregate_plan!(plan)
    validate_where_predicate!(plan)

    Enum.each(SelectSQL.referenced_fields(plan), fn ref ->
      validate_ref_for_input!(ref, input_config)
      validate_qualifier!(ref, plan)
    end)

    :ok
  end

  defp validate_where_predicate!(%{where: where}), do: validate_where_expr!(where)
  defp validate_where_predicate!(_plan), do: :ok

  defp validate_where_expr!(nil), do: :ok

  defp validate_where_expr!(%{kind: kind, left: left, right: right}) when kind in [:and, :or] do
    validate_where_expr!(left)
    validate_where_expr!(right)
  end

  defp validate_where_expr!(%{kind: :not, expr: expr}), do: validate_where_expr!(expr)

  defp validate_where_expr!(%{predicate: predicate})
       when predicate in [:is_missing, :is_not_missing] do
    unsupported!("IS MISSING predicates are only implemented for JSON SelectObjectContent")
  end

  defp validate_where_expr!(_where), do: :ok

  defp validate_ref_for_input!(ref, %{file_header_info: "USE"}) do
    if simple_ref?(ref) and valid_ref_name?(ref) do
      :ok
    else
      raise Error.new(:invalid_key_path)
    end
  end

  defp validate_ref_for_input!(ref, _input_config) do
    unless simple_ref?(ref) and SelectSQL.positional_ref?(ref) do
      raise Error.new(:missing_header_name)
    end

    :ok
  end

  defp valid_ref_name?(ref), do: SelectSQL.positional_ref?(ref) or ref.name != ""

  defp simple_ref?(ref), do: length(SelectSQL.ref_path(ref)) == 1

  defp validate_projection_count!(%{projections: :all}), do: :ok

  defp validate_projection_count!(%{projections: projections}) do
    if length(projections) > @max_projection_count do
      raise Error.new(:over_max_column)
    end

    :ok
  end

  defp validate_output_projection_names!(%{projections: :all}, _config), do: :ok

  defp validate_output_projection_names!(
         %{projections: projections},
         %{output: %{format: "JSON"}}
       ) do
    projections
    |> Enum.with_index(1)
    |> Enum.reduce(MapSet.new(), fn {projection, index}, seen ->
      name = SelectSQL.projection_output_name(projection, index)

      if MapSet.member?(seen, name) do
        raise Error.new(:invalid_key_path)
      end

      MapSet.put(seen, name)
    end)

    :ok
  end

  defp validate_output_projection_names!(_plan, _config), do: :ok

  defp validate_aggregate_plan!(%{projections: projections} = plan) when is_list(projections) do
    if SelectSQL.aggregate_plan?(plan) and
         Enum.any?(projections, &(not SelectSQL.aggregate_projection?(&1))) do
      raise Error.new(:unsupported_sql_structure)
    end

    :ok
  end

  defp validate_aggregate_plan!(_plan), do: :ok

  defp validate_header_refs!(plan, header) do
    plan
    |> SelectSQL.referenced_fields()
    |> Enum.reject(&SelectSQL.positional_ref?/1)
    |> Enum.each(fn ref ->
      ref
      |> header_indexes_for_ref(header)
      |> validate_header_match!()
    end)
  end

  defp header_indexes_for_ref(%{name: name, quoted?: true}, header) do
    matching_header_indexes(header, &(&1 == name))
  end

  defp header_indexes_for_ref(%{name: name, quoted?: false}, header) do
    wanted = String.downcase(name)
    matching_header_indexes(header, &(String.downcase(&1) == wanted))
  end

  defp validate_header_match!([]), do: raise(Error.new(:missing_header_name))

  defp validate_header_match!([_one, _two | _rest]), do: raise(Error.new(:ambiguous_field_name))

  defp validate_header_match!([_idx]), do: :ok

  defp header_refs?(plan) do
    Enum.any?(SelectSQL.referenced_fields(plan), &(not SelectSQL.positional_ref?(&1)))
  end

  defp reject_unknown_options!(options, allowed) do
    case Enum.reject(Map.keys(options), &MapSet.member?(allowed, &1)) do
      [] -> :ok
      [key | _rest] -> invalid!("Unsupported CSV serialization option #{key}")
    end
  end

  defp enum_option!(options, key, default, allowed) do
    value =
      options
      |> Map.get(key, default)
      |> String.upcase()

    if value in allowed do
      value
    else
      invalid!("Invalid CSV #{key} value")
    end
  end

  defp bool_option!(options, key, default) do
    case Map.get(options, key) do
      nil ->
        default

      value ->
        case String.downcase(value) do
          "true" -> true
          "false" -> false
          _other -> invalid!("Invalid CSV #{key} value")
        end
    end
  end

  defp char_option!(options, key, default) do
    value = Map.get(options, key, default)

    case value do
      <<byte>> when byte <= 127 and byte != 0 ->
        value

      _other ->
        unsupported!("Only single-byte ASCII CSV #{key} is implemented for SelectObjectContent")
    end
  end

  defp invalid!(message), do: raise(Error.new(:invalid_argument, message: message))
  defp unsupported!(message), do: raise(Error.new(:not_implemented, message: message))

  defp output_extension(%{format: "JSON"}), do: ".json"
  defp output_extension(_output), do: ".csv"
end
