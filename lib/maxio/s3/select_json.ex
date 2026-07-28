defmodule Maxio.S3.SelectJSON do
  @moduledoc """
  Streaming JSON executor for SelectObjectContent.

  Supports `JSON` input with `Type=LINES` or `Type=DOCUMENT` and CSV or JSON
  output. `DOCUMENT` is treated as one bounded input record and is parsed only
  after the source stream reaches EOF.
  """

  alias Maxio.S3.{Error, SelectOutput, SelectSQL, SelectTimestamp, TempFile}

  @max_record_size 1_048_576
  @max_projection_count 1_000
  @default_max_result_size 128 * 1_024 * 1_024
  @input_options MapSet.new(~w(Type))
  @missing :__maxio_s3_select_missing__

  @type result :: %{
          path: String.t(),
          cleanup: (-> :ok),
          bytes_scanned: non_neg_integer(),
          bytes_processed: non_neg_integer(),
          bytes_returned: non_neg_integer(),
          source_complete?: boolean(),
          halt_reason: nil | :limit | :scan_range
        }

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
    output_format = Keyword.get(opts, :output_format, "JSON")
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
              |> consume_chunk(io, chunk)

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
      emitted: 0,
      aggregate_acc: init_aggregate_acc(plan),
      record_start_offset: 0,
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

  defp consume_chunk(state, io, chunk) do
    consume_chunk(state, io, chunk, state.bytes_processed - byte_size(chunk))
  end

  defp consume_chunk(state, _io, "", _chunk_offset), do: state

  defp consume_chunk(%{config: %{input: %{type: "DOCUMENT"}}} = state, _io, chunk, _chunk_offset) do
    %{state | buffer: append_to_buffer!(state.buffer, chunk)}
  end

  defp consume_chunk(state, io, chunk, chunk_offset) do
    cond do
      limit_reached?(state) ->
        halt_before_record(state, :limit)

      true ->
        case scan_range_position(state.config.scan_range, state.record_start_offset) do
          :before -> skip_unscanned_record(state, io, chunk, chunk_offset)
          :after -> halt_before_record(state, :scan_range)
          :inside -> consume_buffered_record(state, io, chunk, chunk_offset)
        end
    end
  end

  defp consume_buffered_record(state, io, chunk, chunk_offset) do
    case :binary.match(chunk, "\n") do
      :nomatch ->
        %{state | buffer: append_to_buffer!(state.buffer, chunk)}

      {position, 1} ->
        before_newline = binary_part(chunk, 0, position)
        rest_start = position + 1
        rest_size = byte_size(chunk) - rest_start
        rest = binary_part(chunk, rest_start, rest_size)
        line = append_to_buffer!(state.buffer, before_newline)
        record_start = state.record_start_offset
        next_record_start = chunk_offset + rest_start

        state =
          state
          |> Map.put(:buffer, "")
          |> handle_record!(io, strip_cr(line), record_start)
          |> Map.put(:record_start_offset, next_record_start)

        state = mark_halt_before_eof(state, rest)

        if state.done? do
          state
        else
          consume_chunk(state, io, rest, next_record_start)
        end
    end
  end

  defp skip_unscanned_record(state, io, chunk, chunk_offset) do
    case :binary.match(chunk, "\n") do
      :nomatch ->
        %{state | buffer: ""}

      {position, 1} ->
        rest_start = position + 1
        rest_size = byte_size(chunk) - rest_start
        rest = binary_part(chunk, rest_start, rest_size)
        next_record_start = chunk_offset + rest_start

        state = %{state | buffer: "", record_start_offset: next_record_start}
        consume_chunk(state, io, rest, next_record_start)
    end
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

  defp strip_cr(line) do
    if byte_size(line) > 0 and :binary.last(line) == ?\r do
      binary_part(line, 0, byte_size(line) - 1)
    else
      line
    end
  end

  defp flush_buffer(%{config: %{input: %{type: "DOCUMENT"}}} = state, io) do
    state
    |> handle_document_record!(io)
    |> finalize(io)
  end

  defp flush_buffer(%{done?: true} = state, io), do: finalize(state, io)
  defp flush_buffer(%{buffer: ""} = state, io), do: finalize(state, io)

  defp flush_buffer(%{buffer: buffer} = state, io) do
    state
    |> handle_record!(io, strip_cr(buffer), state.record_start_offset)
    |> finalize(io)
  end

  defp handle_document_record!(%{buffer: buffer} = state, io) do
    handle_json_record!(state, io, buffer)
  end

  defp handle_record!(state, io, line, record_start) do
    case scan_range_position(state.config.scan_range, record_start) do
      :before ->
        state

      :after ->
        %{state | done?: true, halt_reason: :scan_range}

      :inside ->
        if limit_reached?(state) do
          %{state | done?: true, halt_reason: :limit}
        else
          handle_json_record!(state, io, line)
        end
    end
  end

  defp handle_json_record!(_state, _io, "") do
    raise Error.new(:json_parsing_error)
  end

  defp handle_json_record!(state, io, line) do
    reject_oversized_record!(line)
    value = decode_record!(line)

    value
    |> source_rows!(state.plan)
    |> Enum.reduce_while(state, fn row, acc ->
      cond do
        limit_reached?(acc) ->
          {:halt, %{acc | done?: true, halt_reason: :limit}}

        where_matches?(row, acc) ->
          acc = handle_selected_row!(acc, io, row)
          if acc.done?, do: {:halt, acc}, else: {:cont, acc}

        true ->
          {:cont, acc}
      end
    end)
  end

  defp handle_selected_row!(state, io, row) do
    if SelectSQL.aggregate_plan?(state.plan) do
      update_aggregate_record!(state, row)
    else
      handle_non_aggregate_row!(state, io, row)
    end
  end

  defp handle_non_aggregate_row!(state, io, row),
    do: emit_record!(state, io, project_record!(row, state))

  defp reject_oversized_record!(line) do
    if byte_size(line) > @max_record_size do
      raise Error.new(:over_max_record_size)
    end

    :ok
  end

  defp decode_record!(line) do
    case Jason.decode(line) do
      {:ok, value} -> value
      {:error, _reason} -> raise Error.new(:json_parsing_error)
    end
  end

  defp source_rows!(value, %{from_path: []}), do: [value]
  defp source_rows!(value, %{from_path: nil}), do: [value]

  defp source_rows!(value, %{from_wildcard?: true, from_path: path}) do
    expand_from_path(value, path)
  end

  defp source_rows!(_value, _plan), do: raise(Error.new(:invalid_key_path))

  defp expand_from_path(value, []), do: [value]

  defp expand_from_path(value, [%{kind: :field} = segment | rest]) when is_map(value) do
    case map_field(value, segment) do
      {:ok, next} -> expand_from_path(next, rest)
      :missing -> [@missing]
    end
  end

  defp expand_from_path(value, [%{kind: :index, index: index} | rest]) when is_list(value) do
    case Enum.fetch(value, index) do
      {:ok, next} -> expand_from_path(next, rest)
      :error -> [@missing]
    end
  end

  defp expand_from_path(values, [%{kind: :array_wildcard} | rest]) when is_list(values) do
    expand_wildcard_values(values, rest)
  end

  defp expand_from_path(value, [%{kind: :object_wildcard} | rest]) when is_map(value) do
    if map_size(value) == 0 do
      [@missing]
    else
      value
      |> Map.to_list()
      |> Stream.map(fn {_key, member} -> member end)
      |> expand_wildcard_values(rest)
    end
  end

  defp expand_from_path(_value, _path), do: [@missing]

  defp expand_wildcard_values([], _rest), do: [@missing]

  defp expand_wildcard_values(values, rest) do
    Stream.flat_map(values, &expand_from_path(&1, rest))
  end

  defp where_matches?(_value, %{plan: %{where: nil}}), do: true

  defp where_matches?(value, %{plan: %{where: where}} = state) do
    eval_where!(where, value, state) == true
  end

  defp eval_where!(%{kind: :and, left: left, right: right}, value, state) do
    and_result(eval_where!(left, value, state), eval_where!(right, value, state))
  end

  defp eval_where!(%{kind: :or, left: left, right: right}, value, state) do
    or_result(eval_where!(left, value, state), eval_where!(right, value, state))
  end

  defp eval_where!(%{kind: :not, expr: expr}, value, state) do
    not_result(eval_where!(expr, value, state))
  end

  defp eval_where!(%{predicate: :is_missing, left: expr}, value, state) do
    value_expr!(value, expr, state) == :missing
  end

  defp eval_where!(%{predicate: :is_not_missing, left: expr}, value, state) do
    match?({:ok, _value}, value_expr!(value, expr, state))
  end

  defp eval_where!(%{predicate: :is_null, left: expr}, value, state) do
    value_expr!(value, expr, state) == {:ok, nil}
  end

  defp eval_where!(%{predicate: :is_not_null, left: expr}, value, state) do
    case value_expr!(value, expr, state) do
      {:ok, nil} -> false
      {:ok, _value} -> true
      :missing -> false
    end
  end

  defp eval_where!(%{predicate: :in, left: expr, values: values}, value, state) do
    case value_expr!(value, expr, state) do
      {:ok, nil} -> :unknown
      {:ok, ref_value} -> in_values!(ref_value, values, value, state)
      :missing -> :unknown
    end
  end

  defp eval_where!(%{predicate: :not_in, left: expr, values: values}, value, state) do
    case value_expr!(value, expr, state) do
      {:ok, nil} -> :unknown
      {:ok, ref_value} -> not_result(in_values!(ref_value, values, value, state))
      :missing -> :unknown
    end
  end

  defp eval_where!(%{predicate: :between, left: expr, lower: lower, upper: upper}, value, state) do
    case value_expr!(value, expr, state) do
      {:ok, nil} -> :unknown
      {:ok, ref_value} -> between_exprs!(ref_value, lower, upper, value, state)
      :missing -> :unknown
    end
  end

  defp eval_where!(
         %{predicate: :not_between, left: expr, lower: lower, upper: upper},
         value,
         state
       ) do
    case value_expr!(value, expr, state) do
      {:ok, nil} -> :unknown
      {:ok, ref_value} -> not_result(between_exprs!(ref_value, lower, upper, value, state))
      :missing -> :unknown
    end
  end

  defp eval_where!(
         %{predicate: :like, left: expr, pattern: pattern, escape: escape},
         value,
         state
       ) do
    case value_expr!(value, expr, state) do
      {:ok, nil} -> :unknown
      {:ok, ref_value} -> like_expr!(ref_value, pattern, escape, value, state)
      :missing -> :unknown
    end
  end

  defp eval_where!(where, value, state) do
    case value_expr!(value, where.left, state) do
      {:ok, nil} -> :unknown
      {:ok, ref_value} -> compare_right!(ref_value, where.op, where.right, value, state)
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

  defp project_record!(value, %{config: %{output: %{format: "CSV"}}} = state),
    do: project_csv_fields!(value, state)

  defp project_record!(value, state), do: project_json_value!(value, state)

  defp project_json_value!(@missing, _state), do: %{}
  defp project_json_value!(value, %{plan: %{projections: :all}}), do: value

  defp project_json_value!(value, %{plan: %{projections: projections}} = state) do
    ensure_projection_count!(projections)

    projections
    |> Enum.with_index(1)
    |> Enum.reduce(%{}, fn {projection, index}, acc ->
      name = SelectSQL.projection_output_name(projection, index)

      case value_expr!(value, SelectSQL.projection_expr(projection), state) do
        {:ok, projected} -> put_projected!(acc, name, output_value(projected))
        :missing -> acc
      end
    end)
  end

  defp project_csv_fields!(@missing, _state), do: []

  defp project_csv_fields!(value, %{plan: %{projections: :all}}), do: [value]

  defp project_csv_fields!(value, %{plan: %{projections: projections}} = state) do
    ensure_projection_count!(projections)

    Enum.map(projections, fn projection ->
      case value_expr!(value, SelectSQL.projection_expr(projection), state) do
        {:ok, projected} -> projected
        :missing -> nil
      end
    end)
  end

  defp value_expr!(value, %{kind: :arithmetic, op: op, left: left, right: right}, state) do
    arithmetic_value!(value, state, left, op, right)
  end

  defp value_expr!(value, %{kind: :cast, expr: expr, type: type}, state) do
    case value_expr!(value, expr, state) do
      {:ok, nil} -> {:ok, nil}
      {:ok, ref_value} -> {:ok, cast_value!(ref_value, type)}
      :missing -> :missing
    end
  end

  defp value_expr!(
         value,
         %{kind: :case, clauses: clauses, else_expr: else_expr},
         state
       ) do
    eval_case_clauses!(value, state, clauses, else_expr)
  end

  defp value_expr!(
         value,
         %{kind: :simple_case, operand: operand, clauses: clauses, else_expr: else_expr},
         state
       ) do
    eval_simple_case_clauses!(value, state, operand, clauses, else_expr)
  end

  defp value_expr!(
         value,
         %{kind: :conditional_function, function: :coalesce, args: args},
         state
       ) do
    coalesce_value!(value, state, args)
  end

  defp value_expr!(
         value,
         %{kind: :conditional_function, function: :nullif, left: left, right: right},
         state
       ) do
    nullif_value!(value, state, left, right)
  end

  defp value_expr!(
         value,
         %{kind: :date_function, function: :to_timestamp, arg: arg},
         state
       ) do
    map_timestamp_arg!(value, arg, state, & &1)
  end

  defp value_expr!(
         value,
         %{kind: :date_function, function: :to_string, timestamp: timestamp, pattern: pattern},
         state
       ) do
    to_string_value!(value, state, timestamp, pattern)
  end

  defp value_expr!(_value, %{kind: :date_function, function: :utcnow}, %{utc_now: utc_now}) do
    {:ok, utc_now}
  end

  defp value_expr!(
         value,
         %{kind: :date_function, function: :extract, part: part, arg: arg},
         state
       ) do
    map_timestamp_arg!(value, arg, state, &SelectTimestamp.extract(part, &1))
  end

  defp value_expr!(
         value,
         %{
           kind: :date_function,
           function: :date_add,
           part: part,
           quantity: quantity,
           timestamp: timestamp
         },
         state
       ) do
    date_add_value!(value, state, part, quantity, timestamp)
  end

  defp value_expr!(
         value,
         %{kind: :date_function, function: :date_diff, part: part, left: left, right: right},
         state
       ) do
    date_diff_value!(value, state, part, left, right)
  end

  defp value_expr!(_value, %{kind: :literal, type: :null}, _state), do: {:ok, nil}

  defp value_expr!(_value, %{kind: :literal, type: :boolean, value: literal}, _state),
    do: {:ok, literal}

  defp value_expr!(_value, %{kind: :literal, type: :timestamp, value: literal}, _state),
    do: parse_timestamp(literal)

  defp value_expr!(_value, %{kind: :literal, type: :string, value: literal}, _state),
    do: {:ok, literal}

  defp value_expr!(_value, %{kind: :literal, type: :number, value: literal}, _state) do
    case numeric_literal(literal) do
      {:ok, number} -> {:ok, json_number(number)}
      :error -> raise Error.new(:invalid_key_path)
    end
  end

  defp value_expr!(
         value,
         %{kind: :string_function, function: :lower, arg: arg},
         state
       ) do
    map_string_arg!(value, arg, state, &String.downcase/1)
  end

  defp value_expr!(
         value,
         %{kind: :string_function, function: :upper, arg: arg},
         state
       ) do
    map_string_arg!(value, arg, state, &String.upcase/1)
  end

  defp value_expr!(
         value,
         %{kind: :string_function, function: :char_length, arg: arg},
         state
       ) do
    map_string_arg!(value, arg, state, &String.length/1)
  end

  defp value_expr!(
         value,
         %{kind: :string_function, function: :substring, arg: arg, start: start, length: length},
         state
       ) do
    map_string_arg!(value, arg, state, &substring_value!(&1, start, length))
  end

  defp value_expr!(
         value,
         %{
           kind: :string_function,
           function: :trim,
           arg: arg,
           direction: direction,
           characters: characters
         },
         state
       ) do
    map_string_arg!(value, arg, state, &trim_value!(&1, direction, characters))
  end

  defp value_expr!(value, %{kind: :unary_minus, expr: expr}, state) do
    case value_expr!(value, expr, state) do
      {:ok, nil} -> {:ok, nil}
      {:ok, expr_value} -> {:ok, json_number(-numeric_value!(expr_value))}
      :missing -> :missing
    end
  end

  defp value_expr!(value, ref, state), do: ref_value(value, ref, state.plan)

  defp eval_case_clauses!(
         value,
         state,
         [%{condition: condition, result: result} | rest],
         else_expr
       ) do
    case eval_where!(condition, value, state) do
      true -> value_expr!(value, result, state)
      _not_true -> eval_case_clauses!(value, state, rest, else_expr)
    end
  end

  defp eval_case_clauses!(_value, _state, [], nil), do: {:ok, nil}

  defp eval_case_clauses!(value, state, [], else_expr),
    do: value_expr!(value, else_expr, state)

  defp eval_simple_case_clauses!(value, state, operand, clauses, else_expr) do
    case value_expr!(value, operand, state) do
      {:ok, nil} ->
        eval_simple_case_no_match!(value, state, else_expr)

      {:ok, operand_value} ->
        eval_simple_case_matches!(value, state, operand_value, clauses, else_expr)

      :missing ->
        eval_simple_case_no_match!(value, state, else_expr)
    end
  end

  defp eval_simple_case_matches!(
         value,
         state,
         operand_value,
         [%{when_expr: when_expr, result: result} | rest],
         else_expr
       ) do
    case value_expr!(value, when_expr, state) do
      {:ok, nil} ->
        eval_simple_case_matches!(value, state, operand_value, rest, else_expr)

      {:ok, when_value} ->
        if value_equal!(operand_value, when_value) do
          value_expr!(value, result, state)
        else
          eval_simple_case_matches!(value, state, operand_value, rest, else_expr)
        end

      :missing ->
        eval_simple_case_matches!(value, state, operand_value, rest, else_expr)
    end
  end

  defp eval_simple_case_matches!(value, state, _operand_value, [], else_expr),
    do: eval_simple_case_no_match!(value, state, else_expr)

  defp eval_simple_case_no_match!(_value, _state, nil), do: {:ok, nil}

  defp eval_simple_case_no_match!(value, state, else_expr),
    do: value_expr!(value, else_expr, state)

  defp coalesce_value!(_value, _state, []), do: {:ok, nil}

  defp coalesce_value!(value, state, [arg | rest]) do
    case value_expr!(value, arg, state) do
      {:ok, nil} -> coalesce_value!(value, state, rest)
      {:ok, arg_value} -> {:ok, arg_value}
      :missing -> coalesce_value!(value, state, rest)
    end
  end

  defp nullif_value!(value, state, left, right) do
    case value_expr!(value, left, state) do
      {:ok, nil} ->
        {:ok, nil}

      {:ok, left_value} ->
        case value_expr!(value, right, state) do
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

  defp arithmetic_value!(value, state, left, op, right) do
    case value_expr!(value, left, state) do
      {:ok, nil} ->
        {:ok, nil}

      {:ok, left_value} ->
        case value_expr!(value, right, state) do
          {:ok, nil} ->
            {:ok, nil}

          {:ok, right_value} ->
            {:ok, json_number(arithmetic_result!(left_value, op, right_value))}

          :missing ->
            :missing
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

  defp date_add_value!(value, state, part, quantity_expr, timestamp_expr) do
    with {:ok, quantity} when not is_nil(quantity) <- value_expr!(value, quantity_expr, state),
         {:ok, timestamp} when not is_nil(timestamp) <- value_expr!(value, timestamp_expr, state) do
      {:ok, SelectTimestamp.add(part, integer_quantity!(quantity), timestamp_value!(timestamp))}
    else
      {:ok, nil} -> {:ok, nil}
      :missing -> :missing
    end
  end

  defp date_diff_value!(value, state, part, left_expr, right_expr) do
    with {:ok, left} when not is_nil(left) <- value_expr!(value, left_expr, state),
         {:ok, right} when not is_nil(right) <- value_expr!(value, right_expr, state) do
      {:ok, SelectTimestamp.diff(part, timestamp_value!(left), timestamp_value!(right))}
    else
      {:ok, nil} -> {:ok, nil}
      :missing -> :missing
    end
  end

  defp to_string_value!(value, state, timestamp_expr, pattern_expr) do
    with {:ok, timestamp} when not is_nil(timestamp) <- value_expr!(value, timestamp_expr, state),
         {:ok, pattern} when not is_nil(pattern) <- value_expr!(value, pattern_expr, state),
         {:ok, formatted} <-
           SelectTimestamp.format(timestamp_value!(timestamp), scalar_string(pattern)) do
      {:ok, formatted}
    else
      {:ok, nil} -> {:ok, nil}
      :missing -> :missing
      :error -> raise Error.new(:invalid_key_path)
    end
  end

  defp map_timestamp_arg!(value, arg, state, fun) do
    case value_expr!(value, arg, state) do
      {:ok, nil} -> {:ok, nil}
      {:ok, ref_value} -> {:ok, ref_value |> timestamp_value!() |> fun.()}
      :missing -> :missing
    end
  end

  defp parse_timestamp(value) do
    case SelectTimestamp.parse(value) do
      {:ok, timestamp} -> {:ok, timestamp}
      :error -> raise Error.new(:value_parse_failure)
    end
  end

  defp timestamp_value!(%SelectTimestamp{} = timestamp), do: timestamp

  defp timestamp_value!(value) do
    case SelectTimestamp.parse(scalar_string(value)) do
      {:ok, timestamp} -> timestamp
      :error -> raise Error.new(:value_parse_failure)
    end
  end

  defp integer_quantity!(value) when is_integer(value), do: value

  defp integer_quantity!(value) when is_float(value) and value == trunc(value) * 1.0,
    do: trunc(value)

  defp integer_quantity!(value) do
    case Integer.parse(scalar_string(value)) do
      {integer, ""} -> integer
      _other -> raise Error.new(:invalid_key_path)
    end
  end

  defp compare_right!(left, op, right_expr, value, state) do
    case value_expr!(value, right_expr, state) do
      {:ok, nil} -> :unknown
      {:ok, right} -> compare!(left, op, right)
      :missing -> :unknown
    end
  end

  defp in_values!(left, values, value, state) do
    Enum.reduce_while(values, false, fn value_expr, result ->
      case value_expr!(value, value_expr, state) do
        {:ok, nil} ->
          {:cont, :unknown}

        {:ok, right} ->
          if value_equal!(left, right), do: {:halt, true}, else: {:cont, result}

        :missing ->
          {:cont, :unknown}
      end
    end)
  end

  defp between_exprs!(ref_value, lower_expr, upper_expr, value, state) do
    with {:ok, lower} when not is_nil(lower) <- value_expr!(value, lower_expr, state),
         {:ok, upper} when not is_nil(upper) <- value_expr!(value, upper_expr, state) do
      between!(ref_value, lower, upper)
    else
      _null_or_missing -> :unknown
    end
  end

  defp like_expr!(ref_value, pattern_expr, escape_expr, value, state) do
    with {:ok, pattern} when not is_nil(pattern) <- value_expr!(value, pattern_expr, state),
         {:ok, escape} <- like_escape!(escape_expr, value, state) do
      regex = SelectSQL.compile_like_regex!(scalar_string(pattern), escape)
      Regex.match?(regex, scalar_string(ref_value))
    else
      _null_or_missing -> :unknown
    end
  end

  defp like_escape!(nil, _value, _state), do: {:ok, nil}

  defp like_escape!(expr, value, state) do
    case value_expr!(value, expr, state) do
      {:ok, nil} -> :unknown
      {:ok, escape} -> {:ok, scalar_string(escape)}
      :missing -> :unknown
    end
  end

  defp map_string_arg!(value, arg, state, fun) do
    case value_expr!(value, arg, state) do
      {:ok, nil} -> {:ok, nil}
      {:ok, ref_value} -> {:ok, ref_value |> scalar_string() |> fun.()}
      :missing -> :missing
    end
  end

  defp output_value(%SelectTimestamp{} = value), do: SelectTimestamp.to_string(value)
  defp output_value(value), do: value

  defp put_projected!(acc, name, _value) when is_map_key(acc, name) do
    raise Error.new(:invalid_key_path)
  end

  defp put_projected!(acc, name, value), do: Map.put(acc, name, value)

  defp ref_value(@missing, _ref, _plan), do: :missing

  defp ref_value(value, ref, plan) do
    case row_ref_path(ref, plan) do
      {:row, path} ->
        resolve_path(value, path)

      :normal ->
        validate_qualifier!(ref, plan)
        resolve_path(value, SelectSQL.ref_path(ref))
    end
  end

  defp resolve_path(value, []), do: {:ok, value}

  defp resolve_path(value, [%{kind: :field} = segment | rest]) when is_map(value) do
    case map_field(value, segment) do
      {:ok, next} -> resolve_path(next, rest)
      :missing -> :missing
    end
  end

  defp resolve_path(value, [%{kind: :index, index: index} | rest]) when is_list(value) do
    case Enum.fetch(value, index) do
      {:ok, next} -> resolve_path(next, rest)
      :error -> :missing
    end
  end

  defp resolve_path(_value, _path), do: :missing

  defp map_field(map, %{name: name, quoted?: true}) do
    if Map.has_key?(map, name), do: {:ok, Map.fetch!(map, name)}, else: :missing
  end

  defp map_field(map, %{name: name, quoted?: false}) do
    wanted = String.downcase(name)

    matches =
      map
      |> Map.keys()
      |> Enum.filter(&(is_binary(&1) and String.downcase(&1) == wanted))

    case matches do
      [] -> :missing
      [key] -> {:ok, Map.fetch!(map, key)}
      [_one, _two | _rest] -> raise Error.new(:ambiguous_field_name)
    end
  end

  defp validate_qualifier!(%{qualifier: nil}, _plan), do: :ok

  defp validate_qualifier!(%{qualifier: "_1"}, plan) do
    if implicit_row_qualifier?(plan) do
      :ok
    else
      raise Error.new(:invalid_key_path)
    end
  end

  defp validate_qualifier!(%{qualifier: qualifier}, %{alias: nil} = plan)
       when is_binary(qualifier) do
    qualifier_name = String.downcase(qualifier)

    if row_name?(%{name: qualifier, quoted?: false}, plan) or
         qualifier_name in ["s3object", "object"] do
      :ok
    else
      raise Error.new(:invalid_key_path)
    end
  end

  defp validate_qualifier!(%{qualifier: qualifier}, %{alias: alias_name}) do
    qualifier = String.downcase(qualifier)
    alias_name = if alias_name, do: String.downcase(alias_name)

    if qualifier in Enum.reject([alias_name, "s3object", "object"], &is_nil/1) do
      :ok
    else
      raise Error.new(:invalid_key_path)
    end
  end

  defp row_ref_path(%{qualifier: nil} = ref, %{alias: nil} = plan) do
    path = SelectSQL.ref_path(ref)

    cond do
      implicit_row_ref?(path, plan) ->
        {:row, tl(path)}

      row_name_ref?(path, plan) ->
        {:row, tl(path)}

      true ->
        :normal
    end
  end

  defp row_ref_path(%{qualifier: qualifier} = ref, %{alias: nil} = plan)
       when is_binary(qualifier) do
    if row_name?(%{name: qualifier, quoted?: false}, plan) do
      {:row, SelectSQL.ref_path(ref)}
    else
      :normal
    end
  end

  defp row_ref_path(_ref, _plan), do: :normal

  defp implicit_row_ref?([%{kind: :field, name: "_1", quoted?: false} | _rest], plan) do
    implicit_row_qualifier?(plan)
  end

  defp implicit_row_ref?(_path, _plan), do: false

  defp row_name_ref?([%{kind: :field} = segment | _rest], plan), do: row_name?(segment, plan)
  defp row_name_ref?(_path, _plan), do: false

  defp row_name?(segment, %{alias: nil} = plan) do
    case SelectSQL.from_path_row_name(plan) do
      {name, quoted?} ->
        same_field?(segment, name, quoted?)

      nil ->
        false
    end
  end

  defp row_name?(_segment, _plan), do: false

  defp implicit_row_qualifier?(%{alias: nil, from_wildcard?: true} = plan) do
    plan.from_path in [nil, []] or SelectSQL.from_path_ends_wildcard?(plan)
  end

  defp implicit_row_qualifier?(_plan), do: false

  defp same_field?(%{name: left, quoted?: left_quoted?}, right, right_quoted?) do
    if left_quoted? or right_quoted? do
      left == right
    else
      String.downcase(left) == String.downcase(right)
    end
  end

  defp compare!(nil, op, _right) when op in ["=", "==", "!=", "<>", "<", "<=", ">", ">="],
    do: false

  defp compare!(left, op, right)
       when op in ["=", "=="] and (is_number(left) or is_number(right)) do
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

  defp compare!(left, op, right) when op in ["=", "=="],
    do: scalar_string(left) == scalar_string(right)

  defp compare!(left, op, right) when op in ["!=", "<>"], do: not compare!(left, "=", right)

  defp compare!(left, op, right) do
    {left_number, right_number} = numeric_pair!(left, right)

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

  defp scalar_string(value) when is_binary(value), do: value
  defp scalar_string(value) when is_integer(value) or is_float(value), do: to_string(value)
  defp scalar_string(%SelectTimestamp{} = value), do: SelectTimestamp.to_string(value)
  defp scalar_string(true), do: "true"
  defp scalar_string(false), do: "false"
  defp scalar_string(nil), do: "null"
  defp scalar_string(_value), do: raise(Error.new(:invalid_key_path))

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

  defp numeric_pair!(left, right) do
    case numeric_value_pair(left, right) do
      {:ok, left_number, right_number} -> {left_number, right_number}
      :error -> raise Error.new(:invalid_key_path)
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

  defp numeric_literal(value) do
    case Float.parse(value) do
      {number, ""} -> {:ok, number}
      _other -> :error
    end
  end

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

  defp update_aggregate_record!(%{aggregate_acc: aggregate_acc} = state, row) do
    aggregate_acc =
      Enum.map(aggregate_acc, fn aggregate ->
        update_aggregate!(aggregate, row, state)
      end)

    %{state | aggregate_acc: aggregate_acc}
  end

  defp update_aggregate!(aggregate, @missing, _state), do: aggregate

  defp update_aggregate!(%{function: :count, arg: :all} = aggregate, _row, _state) do
    %{aggregate | count: aggregate.count + 1}
  end

  defp update_aggregate!(%{function: :count, arg: arg} = aggregate, row, state) do
    case aggregate_value!(arg, row, state) do
      {:ok, nil} -> aggregate
      {:ok, _value} -> %{aggregate | count: aggregate.count + 1}
      :missing -> aggregate
    end
  end

  defp update_aggregate!(%{function: function, arg: arg} = aggregate, row, state)
       when function in [:avg, :sum] do
    case aggregate_value!(arg, row, state) do
      {:ok, nil} ->
        aggregate

      {:ok, value} ->
        number = numeric_value!(value)
        %{aggregate | count: aggregate.count + 1, sum: aggregate.sum + number}

      :missing ->
        aggregate
    end
  end

  defp update_aggregate!(%{function: function, arg: arg} = aggregate, row, state)
       when function in [:max, :min] do
    case aggregate_value!(arg, row, state) do
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

  defp aggregate_value!(expr, row, state), do: value_expr!(row, expr, state)

  defp cast_value!(value, :bool), do: cast_bool_value!(value)

  defp cast_value!(value, :int) do
    case Integer.parse(scalar_string(value)) do
      {integer, ""} -> integer
      _other -> raise Error.new(:cast_failed)
    end
  end

  defp cast_value!(value, :float), do: cast_numeric_value!(value)
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
      {number, ""} -> number
      _other -> raise Error.new(:invalid_key_path)
    end
  end

  defp aggregate_result_value(aggregate_acc) do
    Map.new(aggregate_acc, fn aggregate ->
      {aggregate.output_name, aggregate_result_field(aggregate)}
    end)
  end

  defp aggregate_result_fields(aggregate_acc),
    do: Enum.map(aggregate_acc, &aggregate_result_field/1)

  defp aggregate_result_record(aggregate_acc, %{config: %{output: %{format: "CSV"}}}),
    do: aggregate_result_fields(aggregate_acc)

  defp aggregate_result_record(aggregate_acc, _state), do: aggregate_result_value(aggregate_acc)

  defp aggregate_result_field(%{function: :count, count: count}), do: count
  defp aggregate_result_field(%{function: :sum, count: 0}), do: nil
  defp aggregate_result_field(%{function: :sum, sum: sum}), do: json_number(sum)
  defp aggregate_result_field(%{function: :avg, count: 0}), do: nil

  defp aggregate_result_field(%{function: :avg, count: count, sum: sum}),
    do: json_number(sum / count)

  defp aggregate_result_field(%{function: function, count: 0}) when function in [:max, :min],
    do: nil

  defp aggregate_result_field(%{function: function, value: value}) when function in [:max, :min],
    do: json_number(value)

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

  defp limit_reached?(%{plan: %{limit: limit}, emitted: emitted})
       when is_integer(limit) and emitted >= limit,
       do: true

  defp limit_reached?(_state), do: false

  defp finalize(state, io) do
    state
    |> emit_aggregate_record_if_needed(io)
    |> Map.delete(:buffer)
    |> Map.delete(:config)
    |> Map.delete(:plan)
    |> Map.delete(:emitted)
    |> Map.delete(:aggregate_acc)
    |> Map.delete(:record_start_offset)
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

  defp config!(input_options, output_options, output_format) do
    %{
      input: input_config!(input_options || %{}),
      output: SelectOutput.config!(output_format, output_options || %{}),
      result_max_bytes: result_max_bytes!(),
      scan_range: nil
    }
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
    reject_unknown_options!(options, @input_options, "JSON input")

    type =
      options
      |> Map.get("Type", "DOCUMENT")
      |> String.upcase()

    case type do
      "LINES" ->
        %{type: "LINES"}

      "DOCUMENT" ->
        %{type: "DOCUMENT"}

      _other ->
        raise Error.new(:invalid_json_type)
    end
  end

  defp validate_plan!(plan, config) do
    validate_scan_range!(config)
    validate_from_path!(plan)
    validate_projection_count!(plan)
    validate_aggregate_plan!(plan)
    validate_projection_output_names!(plan, config)

    Enum.each(SelectSQL.referenced_fields(plan), fn ref ->
      unless SelectSQL.json_ref?(ref), do: raise(Error.new(:invalid_key_path))
      validate_qualifier!(ref, plan)
    end)

    :ok
  end

  defp validate_scan_range!(%{input: %{type: "DOCUMENT"}, scan_range: scan_range})
       when not is_nil(scan_range) do
    raise Error.new(:invalid_request, message: "ScanRange is only supported for JSON LINES input")
  end

  defp validate_scan_range!(_config), do: :ok

  defp validate_from_path!(%{from_path: []}), do: :ok
  defp validate_from_path!(%{from_path: nil}), do: :ok

  defp validate_from_path!(%{from_wildcard?: true, from_path: path}) do
    if SelectSQL.json_from_path?(path) do
      :ok
    else
      raise Error.new(:invalid_key_path)
    end
  end

  defp validate_from_path!(_plan),
    do: raise(Error.new(:invalid_key_path))

  defp validate_projection_count!(%{projections: :all}), do: :ok

  defp validate_projection_count!(%{projections: projections}) do
    ensure_projection_count!(projections)
    :ok
  end

  defp validate_aggregate_plan!(%{projections: projections} = plan) when is_list(projections) do
    if SelectSQL.aggregate_plan?(plan) and
         Enum.any?(projections, &(not SelectSQL.aggregate_projection?(&1))) do
      raise Error.new(:unsupported_sql_structure)
    end

    :ok
  end

  defp validate_aggregate_plan!(_plan), do: :ok

  defp validate_projection_output_names!(%{projections: :all}, _config), do: :ok

  defp validate_projection_output_names!(_plan, %{output: %{format: "CSV"}}), do: :ok

  defp validate_projection_output_names!(%{projections: projections}, _config) do
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

  defp ensure_projection_count!(fields) do
    if length(fields) > @max_projection_count do
      raise Error.new(:over_max_column)
    end

    fields
  end

  defp reject_unknown_options!(options, allowed, label) do
    case Enum.reject(Map.keys(options), &MapSet.member?(allowed, &1)) do
      [] ->
        :ok

      [key | _rest] ->
        raise Error.new(:invalid_request_parameter,
                message: "#{label} option #{key} is not supported"
              )
    end
  end

  defp output_extension(%{format: "CSV"}), do: ".csv"
  defp output_extension(_output), do: ".json"
end
