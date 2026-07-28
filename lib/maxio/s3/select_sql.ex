defmodule Maxio.S3.SelectSQL do
  @moduledoc """
  Small SQL subset parser for SelectObjectContent.

  It intentionally supports only the CSV-compatible subset that the local
  executor can run fail-closed before the event-stream response starts.
  """

  alias Maxio.S3.Error

  @max_expression_size 262_144

  @type ref_segment ::
          %{kind: :field, name: String.t(), quoted?: boolean()}
          | %{kind: :index, index: non_neg_integer()}
          | %{kind: :array_wildcard}
          | %{kind: :object_wildcard}
  @type ref :: %{
          qualifier: String.t() | nil,
          name: String.t(),
          quoted?: boolean(),
          path: [ref_segment()]
        }
  @type literal_expr :: %{
          kind: :literal,
          type: :boolean | :null | :number | :string | :timestamp,
          value: boolean() | nil | String.t()
        }
  @type case_clause :: %{condition: map(), result: value_expr()}
  @type simple_case_clause :: %{when_expr: value_expr(), result: value_expr()}
  @type value_expr ::
          ref()
          | literal_expr()
          | %{
              kind: :arithmetic,
              op: :add | :subtract | :multiply | :divide | :mod,
              left: value_expr(),
              right: value_expr()
            }
          | %{
              kind: :cast,
              expr: value_expr(),
              type: :bool | :float | :int | :string | :timestamp
            }
          | %{kind: :case, clauses: [case_clause()], else_expr: value_expr() | nil}
          | %{
              kind: :date_function,
              function: :date_add,
              part: atom(),
              quantity: value_expr(),
              timestamp: value_expr()
            }
          | %{
              kind: :date_function,
              function: :date_diff,
              part: atom(),
              left: value_expr(),
              right: value_expr()
            }
          | %{kind: :date_function, function: :extract, part: atom(), arg: value_expr()}
          | %{
              kind: :date_function,
              function: :to_string,
              timestamp: value_expr(),
              pattern: value_expr()
            }
          | %{kind: :date_function, function: :to_timestamp, arg: value_expr()}
          | %{kind: :date_function, function: :utcnow}
          | %{
              kind: :simple_case,
              operand: value_expr(),
              clauses: [simple_case_clause()],
              else_expr: value_expr() | nil
            }
          | %{kind: :conditional_function, function: :coalesce, args: [value_expr()]}
          | %{
              kind: :conditional_function,
              function: :nullif,
              left: value_expr(),
              right: value_expr()
            }
          | %{
              required(:kind) => :string_function,
              required(:function) => :char_length | :lower | :substring | :trim | :upper,
              optional(:arg) => value_expr(),
              optional(:start) => integer(),
              optional(:length) => non_neg_integer() | nil,
              optional(:direction) => :both | :leading | :trailing,
              optional(:characters) => String.t()
            }
          | %{kind: :unary_minus, expr: value_expr()}
  @type projection ::
          ref()
          | %{kind: :projection, expr: value_expr() | map(), alias: String.t() | nil}
          | %{
              kind: :aggregate,
              function: :avg | :count | :max | :min | :sum,
              arg: :all | value_expr()
            }
  @type plan :: %{
          projections: :all | [projection()],
          from: String.t(),
          from_path: [ref_segment()],
          from_wildcard?: boolean(),
          alias: String.t() | nil,
          where:
            nil
            | %{left: value_expr(), op: String.t(), right: value_expr()}
            | %{
                left: value_expr(),
                predicate: :is_missing | :is_not_missing | :is_null | :is_not_null
              }
            | %{left: value_expr(), predicate: :in | :not_in, values: [value_expr()]}
            | %{
                left: value_expr(),
                predicate: :between | :not_between,
                lower: value_expr(),
                upper: value_expr()
              }
            | %{
                left: value_expr(),
                predicate: :like,
                pattern: value_expr(),
                escape: value_expr() | nil
              }
            | %{kind: :and | :or, left: map(), right: map()}
            | %{kind: :not, expr: map()},
          limit: non_neg_integer() | nil
        }

  @spec parse!(String.t()) :: plan()
  def parse!(expression) when is_binary(expression) do
    if byte_size(expression) > @max_expression_size do
      raise Error.new(:expression_too_long)
    end

    tokens =
      expression
      |> String.trim()
      |> String.trim_trailing(";")
      |> tokenize!()

    {plan, rest} =
      tokens
      |> expect_keyword!("select")
      |> parse_projections()
      |> then(fn {projections, rest} ->
        rest
        |> expect_keyword!("from")
        |> parse_from()
        |> then(fn {from, alias_name, rest} ->
          {where, rest} = parse_optional_where(rest)
          {limit, rest} = parse_optional_limit(rest)

          {
            %{
              projections: projections,
              from: from.name,
              from_path: from.path,
              from_wildcard?: from.from_wildcard?,
              alias: alias_name,
              where: where,
              limit: limit
            },
            rest
          }
        end)
      end)

    case rest do
      [] -> plan
      _other -> unsupported!("Unsupported SelectObjectContent SQL expression")
    end
  end

  @spec referenced_fields(plan()) :: [ref()]
  def referenced_fields(%{projections: projections, where: where}) do
    projection_refs = projection_refs(projections)
    where_refs = where_refs(where)
    projection_refs ++ where_refs
  end

  @spec aggregate_plan?(plan()) :: boolean()
  def aggregate_plan?(%{projections: projections}) when is_list(projections),
    do: Enum.any?(projections, &aggregate_projection?/1)

  def aggregate_plan?(_plan), do: false

  @spec aggregate_projection?(projection()) :: boolean()
  def aggregate_projection?(%{kind: :projection, expr: expr}), do: aggregate_projection?(expr)
  def aggregate_projection?(%{kind: :aggregate}), do: true
  def aggregate_projection?(_projection), do: false

  @spec ref_projection?(projection()) :: boolean()
  def ref_projection?(%{kind: :projection, expr: expr}), do: ref_projection?(expr)
  def ref_projection?(%{path: path}) when is_list(path), do: true
  def ref_projection?(_projection), do: false

  @spec positional_ref?(ref()) :: boolean()
  def positional_ref?(%{name: <<?_, rest::binary>>, path: [_one]}) do
    case Integer.parse(rest) do
      {number, ""} when number >= 1 -> true
      _other -> false
    end
  end

  def positional_ref?(_ref), do: false

  @spec ref_path(ref()) :: [ref_segment()]
  def ref_path(%{path: path}) when is_list(path), do: path

  def ref_path(%{name: name, quoted?: quoted?}),
    do: [%{kind: :field, name: name, quoted?: quoted?}]

  @spec json_ref?(ref()) :: boolean()
  def json_ref?(ref), do: Enum.all?(ref_path(ref), &json_segment?/1)

  @spec json_from_path?([ref_segment()]) :: boolean()
  def json_from_path?(path) when is_list(path), do: Enum.all?(path, &json_from_segment?/1)

  @spec from_path_row_name(plan()) :: {String.t(), boolean()} | nil
  def from_path_row_name(%{from_path: path}) do
    case List.last(path || []) do
      %{kind: :field, name: name, quoted?: quoted?} -> {name, quoted?}
      _segment -> nil
    end
  end

  @spec from_path_ends_wildcard?(plan()) :: boolean()
  def from_path_ends_wildcard?(%{from_path: []}), do: false
  def from_path_ends_wildcard?(%{from_path: nil}), do: false

  def from_path_ends_wildcard?(%{from_path: path}) do
    case List.last(path) do
      %{kind: kind} when kind in [:array_wildcard, :object_wildcard] -> true
      _segment -> false
    end
  end

  @spec output_name(ref()) :: String.t()
  def output_name(ref) do
    ref
    |> ref_path()
    |> Enum.reverse()
    |> Enum.find_value(ref.name, fn
      %{kind: :field, name: name} -> name
      _segment -> nil
    end)
  end

  @spec projection_expr(projection()) :: value_expr() | map()
  def projection_expr(%{kind: :projection, expr: expr}), do: expr
  def projection_expr(projection), do: projection

  @spec projection_alias(projection()) :: String.t() | nil
  def projection_alias(%{kind: :projection, alias: alias}) when is_binary(alias), do: alias
  def projection_alias(_projection), do: nil

  @spec projection_output_name(projection(), pos_integer()) :: String.t()
  def projection_output_name(%{kind: :projection, alias: alias}, _index) when is_binary(alias),
    do: alias

  def projection_output_name(%{kind: :projection, expr: expr}, index),
    do: projection_output_name(expr, index)

  def projection_output_name(%{kind: :aggregate}, index), do: "_#{index}"
  def projection_output_name(%{kind: :arithmetic}, index), do: "_#{index}"
  def projection_output_name(%{kind: :cast}, index), do: "_#{index}"
  def projection_output_name(%{kind: :case}, index), do: "_#{index}"
  def projection_output_name(%{kind: :conditional_function}, index), do: "_#{index}"
  def projection_output_name(%{kind: :date_function}, index), do: "_#{index}"
  def projection_output_name(%{kind: :literal}, index), do: "_#{index}"
  def projection_output_name(%{kind: :simple_case}, index), do: "_#{index}"
  def projection_output_name(%{kind: :string_function}, index), do: "_#{index}"
  def projection_output_name(%{kind: :unary_minus}, index), do: "_#{index}"
  def projection_output_name(ref, _index), do: output_name(ref)

  defp parse_projections(["*" | rest]), do: {:all, rest}

  defp parse_projections(tokens) do
    {projection, rest} = parse_projection(tokens)
    parse_more_projections(rest, [projection])
  end

  defp parse_more_projections(["," | rest], acc) do
    {projection, rest} = parse_projection(rest)
    parse_more_projections(rest, [projection | acc])
  end

  defp parse_more_projections(rest, acc), do: {Enum.reverse(acc), rest}

  defp parse_projection(tokens) do
    {expr, rest} = parse_projection_expr(tokens)
    parse_projection_alias(expr, rest)
  end

  defp parse_projection_expr([{:identifier, function} = token, "(" | rest]) do
    case aggregate_function(function) do
      nil -> parse_value_expr([token, "(" | rest])
      function -> parse_aggregate_projection(function, rest)
    end
  end

  defp parse_projection_expr(tokens), do: parse_value_expr(tokens)

  defp parse_projection_alias(expr, tokens) do
    cond do
      match_keyword?(tokens, "as") ->
        {alias_token, rest} = tokens |> expect_keyword!("as") |> parse_identifier()
        {%{kind: :projection, expr: expr, alias: alias_token.name}, rest}

      projection_alias_start?(tokens) ->
        {alias_token, rest} = parse_identifier(tokens)
        {%{kind: :projection, expr: expr, alias: alias_token.name}, rest}

      projection_wrapper_needed?(expr) ->
        {%{kind: :projection, expr: expr, alias: nil}, tokens}

      true ->
        {expr, tokens}
    end
  end

  defp projection_alias_start?([{:quoted_identifier, _value} | _rest]), do: true

  defp projection_alias_start?([{:identifier, value} | _rest]) do
    String.downcase(value) not in ["from", "where", "limit"]
  end

  defp projection_alias_start?(_tokens), do: false

  defp projection_wrapper_needed?(%{kind: kind}) when kind in [:aggregate], do: false
  defp projection_wrapper_needed?(%{path: path}) when is_list(path), do: false
  defp projection_wrapper_needed?(_expr), do: true

  defp parse_aggregate_projection(:count, ["*", ")" | rest]) do
    {%{kind: :aggregate, function: :count, arg: :all}, rest}
  end

  defp parse_aggregate_projection(_function, ["*" | _rest]) do
    unsupported!("Unsupported SelectObjectContent aggregate expression")
  end

  defp parse_aggregate_projection(function, tokens) do
    {arg, rest} = parse_value_expr(tokens)
    {%{kind: :aggregate, function: function, arg: arg}, expect_token!(rest, ")")}
  end

  defp aggregate_function(function) do
    case String.downcase(function) do
      "avg" -> :avg
      "count" -> :count
      "max" -> :max
      "min" -> :min
      "sum" -> :sum
      _other -> nil
    end
  end

  defp parse_value_expr(tokens), do: parse_additive_expr(tokens)

  defp parse_additive_expr(tokens) do
    {left, rest} = parse_multiplicative_expr(tokens)
    parse_more_additive_expr(left, rest)
  end

  defp parse_more_additive_expr(left, [op | rest]) when op in ["+", "-"] do
    {right, rest} = parse_multiplicative_expr(rest)
    op = if op == "+", do: :add, else: :subtract
    parse_more_additive_expr(%{kind: :arithmetic, op: op, left: left, right: right}, rest)
  end

  defp parse_more_additive_expr(left, rest), do: {left, rest}

  defp parse_multiplicative_expr(tokens) do
    {left, rest} = parse_unary_expr(tokens)
    parse_more_multiplicative_expr(left, rest)
  end

  defp parse_more_multiplicative_expr(left, [op | rest]) when op in ["*", "/", "%"] do
    {right, rest} = parse_unary_expr(rest)

    op =
      case op do
        "*" -> :multiply
        "/" -> :divide
        "%" -> :mod
      end

    parse_more_multiplicative_expr(%{kind: :arithmetic, op: op, left: left, right: right}, rest)
  end

  defp parse_more_multiplicative_expr(left, rest), do: {left, rest}

  defp parse_unary_expr(["+" | rest]), do: parse_unary_expr(rest)

  defp parse_unary_expr(["-" | rest]) do
    {expr, rest} = parse_unary_expr(rest)
    {%{kind: :unary_minus, expr: expr}, rest}
  end

  defp parse_unary_expr(tokens), do: parse_value_primary(tokens)

  defp parse_value_primary(["(" | rest]) do
    {expr, rest} = parse_value_expr(rest)
    {expr, expect_token!(rest, ")")}
  end

  defp parse_value_primary([{:string, value} | rest]),
    do: {%{kind: :literal, type: :string, value: value}, rest}

  defp parse_value_primary([{:timestamp, value} | rest]),
    do: {%{kind: :literal, type: :timestamp, value: value}, rest}

  defp parse_value_primary([{:number, value} | rest]),
    do: {%{kind: :literal, type: :number, value: value}, rest}

  defp parse_value_primary([{:identifier, function}, "(" | rest]) do
    case String.downcase(function) do
      "cast" ->
        {expr, tokens} = parse_value_expr(rest)
        tokens = expect_keyword!(tokens, "as")
        {type, tokens} = parse_cast_type(tokens)
        {%{kind: :cast, expr: expr, type: type}, expect_token!(tokens, ")")}

      "coalesce" ->
        parse_coalesce_function(rest)

      "date_add" ->
        parse_date_add_function(rest)

      "date_diff" ->
        parse_date_diff_function(rest)

      "extract" ->
        parse_extract_function(rest)

      "nullif" ->
        parse_nullif_function(rest)

      "to_timestamp" ->
        parse_to_timestamp_function(rest)

      "to_string" ->
        parse_to_string_function(rest)

      "utcnow" ->
        parse_utcnow_function(rest)

      function when function in ["lower", "upper", "char_length", "character_length"] ->
        parse_unary_string_function(function, rest)

      "substring" ->
        parse_substring_function(rest)

      "trim" ->
        parse_trim_function(rest)

      _other ->
        unsupported!("Unsupported SelectObjectContent SQL function")
    end
  end

  defp parse_value_primary([{:identifier, value} | rest] = tokens) do
    case String.downcase(value) do
      "case" -> parse_case_expression(rest)
      "false" -> {%{kind: :literal, type: :boolean, value: false}, rest}
      "null" -> {%{kind: :literal, type: :null, value: nil}, rest}
      "true" -> {%{kind: :literal, type: :boolean, value: true}, rest}
      _other -> parse_ref(tokens)
    end
  end

  defp parse_value_primary(tokens), do: parse_ref(tokens)

  defp parse_coalesce_function(tokens) do
    {args, tokens} = parse_value_expr_args(tokens, [])

    if args == [] do
      unsupported!("Unsupported SelectObjectContent COALESCE expression")
    else
      {%{kind: :conditional_function, function: :coalesce, args: args},
       expect_token!(tokens, ")")}
    end
  end

  defp parse_nullif_function(tokens) do
    {left, tokens} = parse_value_expr(tokens)
    tokens = expect_token!(tokens, ",")
    {right, tokens} = parse_value_expr(tokens)

    {
      %{kind: :conditional_function, function: :nullif, left: left, right: right},
      expect_token!(tokens, ")")
    }
  end

  defp parse_to_timestamp_function(tokens) do
    {arg, tokens} = parse_value_expr(tokens)
    {%{kind: :date_function, function: :to_timestamp, arg: arg}, expect_token!(tokens, ")")}
  end

  defp parse_to_string_function(tokens) do
    {timestamp, tokens} = parse_value_expr(tokens)
    tokens = expect_token!(tokens, ",")
    {pattern, tokens} = parse_value_expr(tokens)

    {%{kind: :date_function, function: :to_string, timestamp: timestamp, pattern: pattern},
     expect_token!(tokens, ")")}
  end

  defp parse_utcnow_function(tokens) do
    {%{kind: :date_function, function: :utcnow}, expect_token!(tokens, ")")}
  end

  defp parse_extract_function(tokens) do
    {part, tokens} = parse_date_part(tokens, :extract)
    tokens = expect_keyword!(tokens, "from")
    {arg, tokens} = parse_value_expr(tokens)

    {%{kind: :date_function, function: :extract, part: part, arg: arg},
     expect_token!(tokens, ")")}
  end

  defp parse_date_add_function(tokens) do
    {part, tokens} = parse_date_part(tokens, :date_arithmetic)
    tokens = expect_token!(tokens, ",")
    {quantity, tokens} = parse_value_expr(tokens)
    tokens = expect_token!(tokens, ",")
    {timestamp, tokens} = parse_value_expr(tokens)

    {%{
       kind: :date_function,
       function: :date_add,
       part: part,
       quantity: quantity,
       timestamp: timestamp
     }, expect_token!(tokens, ")")}
  end

  defp parse_date_diff_function(tokens) do
    {part, tokens} = parse_date_part(tokens, :date_arithmetic)
    tokens = expect_token!(tokens, ",")
    {left, tokens} = parse_value_expr(tokens)
    tokens = expect_token!(tokens, ",")
    {right, tokens} = parse_value_expr(tokens)

    {%{kind: :date_function, function: :date_diff, part: part, left: left, right: right},
     expect_token!(tokens, ")")}
  end

  defp parse_date_part([{:identifier, value} | rest], mode) do
    part =
      value
      |> String.downcase()
      |> String.replace("-", "_")

    part =
      case part do
        "year" -> :year
        "month" -> :month
        "day" -> :day
        "hour" -> :hour
        "minute" -> :minute
        "second" -> :second
        "timezone_hour" when mode == :extract -> :timezone_hour
        "timezone_minute" when mode == :extract -> :timezone_minute
        _other -> unsupported!("Unsupported SelectObjectContent date part")
      end

    {part, rest}
  end

  defp parse_date_part(_tokens, _mode),
    do: unsupported!("Unsupported SelectObjectContent date part")

  defp parse_value_expr_args([")" | _rest] = tokens, acc), do: {Enum.reverse(acc), tokens}

  defp parse_value_expr_args(tokens, acc) do
    {arg, tokens} = parse_value_expr(tokens)

    case tokens do
      ["," | tokens] -> parse_value_expr_args(tokens, [arg | acc])
      [")" | _rest] -> {Enum.reverse([arg | acc]), tokens}
      _other -> unsupported!("Unsupported SelectObjectContent SQL expression")
    end
  end

  defp parse_case_expression(tokens) do
    if match_keyword?(tokens, "when") do
      parse_searched_case_clauses(tokens, [])
    else
      {operand, tokens} = parse_value_expr(tokens)
      parse_simple_case_clauses(operand, tokens, [])
    end
  end

  defp parse_searched_case_clauses(tokens, acc) do
    cond do
      match_keyword?(tokens, "when") ->
        tokens = expect_keyword!(tokens, "when")
        {condition, tokens} = parse_where_or(tokens)
        tokens = expect_keyword!(tokens, "then")
        {result, tokens} = parse_value_expr(tokens)
        parse_searched_case_clauses(tokens, [%{condition: condition, result: result} | acc])

      acc != [] ->
        {else_expr, tokens} = parse_optional_case_else(tokens)

        {
          %{kind: :case, clauses: Enum.reverse(acc), else_expr: else_expr},
          expect_keyword!(tokens, "end")
        }

      true ->
        unsupported!("Unsupported SelectObjectContent CASE expression")
    end
  end

  defp parse_simple_case_clauses(operand, tokens, acc) do
    cond do
      match_keyword?(tokens, "when") ->
        tokens = expect_keyword!(tokens, "when")
        {when_expr, tokens} = parse_value_expr(tokens)
        tokens = expect_keyword!(tokens, "then")
        {result, tokens} = parse_value_expr(tokens)
        clause = %{when_expr: when_expr, result: result}
        parse_simple_case_clauses(operand, tokens, [clause | acc])

      acc != [] ->
        {else_expr, tokens} = parse_optional_case_else(tokens)

        {
          %{
            kind: :simple_case,
            operand: operand,
            clauses: Enum.reverse(acc),
            else_expr: else_expr
          },
          expect_keyword!(tokens, "end")
        }

      true ->
        unsupported!("Unsupported SelectObjectContent CASE expression")
    end
  end

  defp parse_optional_case_else(tokens) do
    if match_keyword?(tokens, "else") do
      tokens = expect_keyword!(tokens, "else")
      parse_value_expr(tokens)
    else
      {nil, tokens}
    end
  end

  defp parse_unary_string_function(function, tokens) do
    {arg, tokens} = parse_value_expr(tokens)
    tokens = expect_token!(tokens, ")")

    function =
      case function do
        "char_length" -> :char_length
        "character_length" -> :char_length
        "lower" -> :lower
        "upper" -> :upper
      end

    {%{kind: :string_function, function: function, arg: arg}, tokens}
  end

  defp parse_substring_function(tokens) do
    {arg, tokens} = parse_value_expr(tokens)

    case tokens do
      ["," | tokens] ->
        {start, tokens} = parse_integer_literal(tokens)
        {length, tokens} = parse_optional_comma_length(tokens)

        {
          %{kind: :string_function, function: :substring, arg: arg, start: start, length: length},
          expect_token!(tokens, ")")
        }

      tokens when is_list(tokens) ->
        tokens = expect_keyword!(tokens, "from")
        {start, tokens} = parse_integer_literal(tokens)
        {length, tokens} = parse_optional_for_length(tokens)

        {
          %{kind: :string_function, function: :substring, arg: arg, start: start, length: length},
          expect_token!(tokens, ")")
        }
    end
  end

  defp parse_optional_comma_length(["," | tokens]) do
    {length, tokens} = parse_non_negative_integer_literal(tokens)
    {length, tokens}
  end

  defp parse_optional_comma_length(tokens), do: {nil, tokens}

  defp parse_optional_for_length(tokens) do
    if match_keyword?(tokens, "for") do
      tokens = expect_keyword!(tokens, "for")
      {length, tokens} = parse_non_negative_integer_literal(tokens)
      {length, tokens}
    else
      {nil, tokens}
    end
  end

  defp parse_trim_function(tokens) do
    cond do
      trim_direction_start?(tokens) ->
        {direction, tokens} = parse_trim_direction(tokens)
        {characters, tokens} = parse_optional_trim_characters(tokens)
        tokens = expect_keyword!(tokens, "from")
        {arg, tokens} = parse_value_expr(tokens)

        {
          %{
            kind: :string_function,
            function: :trim,
            arg: arg,
            direction: direction,
            characters: characters
          },
          expect_token!(tokens, ")")
        }

      true ->
        {first_arg, tokens} = parse_value_expr(tokens)

        if match_keyword?(tokens, "from") and literal_string_expr?(first_arg) do
          tokens = expect_keyword!(tokens, "from")
          {arg, tokens} = parse_value_expr(tokens)

          {
            %{
              kind: :string_function,
              function: :trim,
              arg: arg,
              direction: :both,
              characters: first_arg.value
            },
            expect_token!(tokens, ")")
          }
        else
          {
            %{
              kind: :string_function,
              function: :trim,
              arg: first_arg,
              direction: :both,
              characters: " "
            },
            expect_token!(tokens, ")")
          }
        end
    end
  end

  defp trim_direction_start?(tokens),
    do:
      match_keyword?(tokens, "leading") or match_keyword?(tokens, "trailing") or
        match_keyword?(tokens, "both")

  defp parse_trim_direction([{:identifier, direction} | rest]) do
    direction =
      case String.downcase(direction) do
        "leading" -> :leading
        "trailing" -> :trailing
        "both" -> :both
      end

    {direction, rest}
  end

  defp parse_optional_trim_characters(tokens) do
    if match_keyword?(tokens, "from") do
      {" ", tokens}
    else
      case tokens do
        [{:string, value} | rest] -> {value, rest}
        _other -> unsupported!("Unsupported SelectObjectContent TRIM characters")
      end
    end
  end

  defp literal_string_expr?(%{kind: :literal, type: :string}), do: true
  defp literal_string_expr?(_expr), do: false

  defp parse_integer_literal(["-" | rest]) do
    {integer, rest} = parse_integer_literal(rest)
    {-integer, rest}
  end

  defp parse_integer_literal(["+" | rest]), do: parse_integer_literal(rest)

  defp parse_integer_literal([{:number, value} | rest]) do
    case Integer.parse(value) do
      {integer, ""} -> {integer, rest}
      _other -> unsupported!("Unsupported SelectObjectContent integer literal")
    end
  end

  defp parse_integer_literal(_tokens),
    do: unsupported!("Unsupported SelectObjectContent integer literal")

  defp parse_non_negative_integer_literal(tokens) do
    {integer, rest} = parse_integer_literal(tokens)

    if integer >= 0 do
      {integer, rest}
    else
      unsupported!("Unsupported SelectObjectContent integer literal")
    end
  end

  defp parse_cast_type([{:identifier, value} | rest]) do
    type =
      case String.downcase(value) do
        value when value in ["bool", "boolean"] -> :bool
        value when value in ["int", "integer"] -> :int
        value when value in ["float", "double", "decimal", "numeric"] -> :float
        "string" -> :string
        "timestamp" -> :timestamp
        _other -> unsupported!("Unsupported SelectObjectContent CAST type")
      end

    {type, rest}
  end

  defp parse_cast_type(_tokens), do: unsupported!("Unsupported SelectObjectContent CAST type")

  defp parse_from(tokens) do
    {table, rest} = parse_identifier(tokens)
    table_name = String.downcase(table.name)

    unless table_name in ["s3object", "object"] do
      unsupported!("Only FROM S3Object is implemented for SelectObjectContent")
    end

    {path, wildcard?, rest} = parse_optional_from_path(rest)
    {alias_name, rest} = parse_optional_alias(rest)
    {table |> Map.put(:path, path) |> Map.put(:from_wildcard?, wildcard?), alias_name, rest}
  end

  defp parse_optional_from_path(["[", "*", "]" | rest]) do
    {path, rest} = parse_json_from_path(rest, [])
    {path, true, rest}
  end

  defp parse_optional_from_path(["." | _rest]),
    do: unsupported!("FROM S3Object key paths are not implemented")

  defp parse_optional_from_path(["[" | _rest]),
    do: unsupported!("FROM S3Object key paths are not implemented")

  defp parse_optional_from_path(rest), do: {[], false, rest}

  defp parse_json_from_path(["." | rest], acc) do
    case rest do
      ["*" | rest] ->
        parse_json_from_path(rest, [%{kind: :object_wildcard} | acc])

      _other ->
        {field, rest} = parse_identifier(rest)
        parse_json_from_path(rest, [field_segment(field) | acc])
    end
  end

  defp parse_json_from_path(["[", "*", "]" | rest], acc),
    do: parse_json_from_path(rest, [%{kind: :array_wildcard} | acc])

  defp parse_json_from_path(["[", {:number, value}, "]" | rest], acc) do
    case Integer.parse(value) do
      {index, ""} when index >= 0 ->
        parse_json_from_path(rest, [%{kind: :index, index: index} | acc])

      _other ->
        unsupported!("Unsupported SelectObjectContent key path index")
    end
  end

  defp parse_json_from_path(["[", {:string, value}, "]" | rest], acc),
    do:
      parse_json_from_path(rest, [
        %{kind: :field, name: value, quoted?: true} | acc
      ])

  defp parse_json_from_path(["[" | _rest], _acc),
    do: unsupported!("Unsupported SelectObjectContent key path")

  defp parse_json_from_path(rest, acc), do: {Enum.reverse(acc), rest}

  defp parse_optional_alias(tokens) do
    cond do
      match_keyword?(tokens, "where") or match_keyword?(tokens, "limit") or tokens == [] ->
        {nil, tokens}

      match_keyword?(tokens, "as") ->
        tokens
        |> expect_keyword!("as")
        |> parse_alias()

      true ->
        parse_alias(tokens)
    end
  end

  defp parse_alias(tokens) do
    {alias_token, rest} = parse_identifier(tokens)
    {alias_token.name, rest}
  end

  defp parse_optional_where(tokens) do
    if match_keyword?(tokens, "where") do
      tokens = expect_keyword!(tokens, "where")
      parse_where_or(tokens)
    else
      {nil, tokens}
    end
  end

  defp parse_where_or(tokens) do
    {expr, rest} = parse_where_and(tokens)
    parse_more_where_or(expr, rest)
  end

  defp parse_more_where_or(left, tokens) do
    if match_keyword?(tokens, "or") do
      tokens = expect_keyword!(tokens, "or")
      {right, rest} = parse_where_and(tokens)
      parse_more_where_or(%{kind: :or, left: left, right: right}, rest)
    else
      {left, tokens}
    end
  end

  defp parse_where_and(tokens) do
    {expr, rest} = parse_where_not(tokens)
    parse_more_where_and(expr, rest)
  end

  defp parse_more_where_and(left, tokens) do
    if match_keyword?(tokens, "and") do
      tokens = expect_keyword!(tokens, "and")
      {right, rest} = parse_where_not(tokens)
      parse_more_where_and(%{kind: :and, left: left, right: right}, rest)
    else
      {left, tokens}
    end
  end

  defp parse_where_not(tokens) do
    if match_keyword?(tokens, "not") do
      tokens = expect_keyword!(tokens, "not")
      {expr, rest} = parse_where_not(tokens)
      {%{kind: :not, expr: expr}, rest}
    else
      parse_where_atom(tokens)
    end
  end

  defp parse_where_atom(["(" | rest]) do
    {expr, rest} = parse_where_or(rest)
    {expr, expect_token!(rest, ")")}
  end

  defp parse_where_atom(tokens) do
    {left, rest} = parse_value_expr(tokens)
    parse_where_predicate(left, rest)
  end

  defp parse_where_predicate(left, tokens) do
    cond do
      match_keyword?(tokens, "is") ->
        tokens = expect_keyword!(tokens, "is")
        {negated?, tokens} = parse_optional_not(tokens)
        {predicate, tokens} = parse_nullish_predicate(tokens, negated?)
        {%{left: left, predicate: predicate}, tokens}

      match_keyword?(tokens, "not") ->
        tokens = expect_keyword!(tokens, "not")
        parse_negated_where_predicate(left, tokens)

      match_keyword?(tokens, "in") ->
        {values, rest} = tokens |> expect_keyword!("in") |> parse_in_values()
        {%{left: left, predicate: :in, values: values}, rest}

      match_keyword?(tokens, "between") ->
        parse_between_predicate(left, expect_keyword!(tokens, "between"), false)

      match_keyword?(tokens, "like") ->
        parse_like_predicate(left, expect_keyword!(tokens, "like"))

      true ->
        {op, rest} = parse_operator(tokens)
        {right, rest} = parse_value_expr(rest)
        {%{left: left, op: op, right: right}, rest}
    end
  end

  defp parse_negated_where_predicate(left, tokens) do
    cond do
      match_keyword?(tokens, "in") ->
        {values, rest} = tokens |> expect_keyword!("in") |> parse_in_values()
        {%{left: left, predicate: :not_in, values: values}, rest}

      match_keyword?(tokens, "between") ->
        parse_between_predicate(left, expect_keyword!(tokens, "between"), true)

      true ->
        unsupported!("Unsupported SelectObjectContent WHERE predicate")
    end
  end

  defp parse_nullish_predicate(tokens, negated?) do
    cond do
      match_keyword?(tokens, "missing") ->
        predicate = if negated?, do: :is_not_missing, else: :is_missing
        {predicate, tl(tokens)}

      match_keyword?(tokens, "null") ->
        predicate = if negated?, do: :is_not_null, else: :is_null
        {predicate, tl(tokens)}

      true ->
        unsupported!("Unsupported SelectObjectContent WHERE predicate")
    end
  end

  defp parse_optional_not(tokens) do
    if match_keyword?(tokens, "not") do
      {true, tl(tokens)}
    else
      {false, tokens}
    end
  end

  defp parse_in_values(["(" | rest]) do
    {value, rest} = parse_value_expr(rest)
    parse_more_in_values(rest, [value])
  end

  defp parse_in_values(_tokens),
    do: unsupported!("Unsupported SelectObjectContent IN predicate")

  defp parse_more_in_values(["," | rest], acc) do
    {value, rest} = parse_value_expr(rest)
    parse_more_in_values(rest, [value | acc])
  end

  defp parse_more_in_values([")" | rest], acc), do: {Enum.reverse(acc), rest}

  defp parse_more_in_values(_tokens, _acc),
    do: unsupported!("Unsupported SelectObjectContent IN predicate")

  defp parse_between_predicate(left, tokens, negated?) do
    {lower, rest} = parse_value_expr(tokens)
    rest = expect_keyword!(rest, "and")
    {upper, rest} = parse_value_expr(rest)
    predicate = if negated?, do: :not_between, else: :between
    {%{left: left, predicate: predicate, lower: lower, upper: upper}, rest}
  end

  defp parse_like_predicate(left, tokens) do
    {pattern, rest} = parse_value_expr(tokens)
    {escape, rest} = parse_optional_like_escape(rest)

    {
      %{
        left: left,
        predicate: :like,
        pattern: pattern,
        escape: escape
      },
      rest
    }
  end

  defp parse_optional_like_escape(tokens) do
    if match_keyword?(tokens, "escape") do
      tokens = expect_keyword!(tokens, "escape")
      parse_value_expr(tokens)
    else
      {nil, tokens}
    end
  end

  defp parse_optional_limit(tokens) do
    if match_keyword?(tokens, "limit") do
      tokens = expect_keyword!(tokens, "limit")

      case tokens do
        [{:number, value} | rest] ->
          case Integer.parse(value) do
            {number, ""} when number >= 0 -> {number, rest}
            _other -> unsupported!("Unsupported SelectObjectContent LIMIT value")
          end

        _other ->
          unsupported!("Unsupported SelectObjectContent LIMIT value")
      end
    else
      {nil, tokens}
    end
  end

  defp parse_ref(tokens) do
    {first, rest} = parse_identifier(tokens)

    {qualifier, first_segment, rest} =
      case rest do
        ["." | rest] ->
          {field, rest} = parse_identifier(rest)
          {first.name, field_segment(field), rest}

        _other ->
          {nil, field_segment(first), rest}
      end

    {path, rest} = parse_ref_path(rest, [first_segment])
    {first_field, first_quoted?} = first_field(path)

    {%{qualifier: qualifier, name: first_field, quoted?: first_quoted?, path: path}, rest}
  end

  defp parse_ref_path(["." | rest], acc) do
    {field, rest} = parse_identifier(rest)
    parse_ref_path(rest, [field_segment(field) | acc])
  end

  defp parse_ref_path(["[", {:number, value}, "]" | rest], acc) do
    case Integer.parse(value) do
      {index, ""} when index >= 0 -> parse_ref_path(rest, [%{kind: :index, index: index} | acc])
      _other -> unsupported!("Unsupported SelectObjectContent key path index")
    end
  end

  defp parse_ref_path(["[" | _rest], _acc),
    do: unsupported!("Unsupported SelectObjectContent key path")

  defp parse_ref_path(rest, acc), do: {Enum.reverse(acc), rest}

  defp field_segment(%{name: name, quoted?: quoted?}),
    do: %{kind: :field, name: name, quoted?: quoted?}

  defp first_field([%{kind: :field, name: name, quoted?: quoted?} | _rest]), do: {name, quoted?}
  defp first_field(_path), do: {"", false}

  defp parse_identifier([{:identifier, value} | rest]),
    do: {%{qualifier: nil, name: value, quoted?: false, path: []}, rest}

  defp parse_identifier([{:quoted_identifier, value} | rest]),
    do: {%{qualifier: nil, name: value, quoted?: true, path: []}, rest}

  defp parse_identifier(_tokens),
    do: unsupported!("Unsupported SelectObjectContent SQL identifier")

  defp parse_operator([op | rest]) when op in ["=", "!=", "<>", "<", "<=", ">", ">="],
    do: {op, rest}

  defp parse_operator(_tokens),
    do: unsupported!("Unsupported SelectObjectContent WHERE predicate")

  def compile_like_regex!(pattern, escape) do
    if is_binary(escape) and String.length(escape) != 1 do
      unsupported!("Unsupported SelectObjectContent LIKE ESCAPE value")
    end

    source = ["\\A", like_regex_source!(pattern, escape), "\\z"] |> IO.iodata_to_binary()

    case Regex.compile(source, "u") do
      {:ok, regex} -> regex
      {:error, _reason} -> unsupported!("Unsupported SelectObjectContent LIKE pattern")
    end
  end

  defp like_regex_source!(pattern, escape), do: like_regex_source!(pattern, escape, [])

  defp like_regex_source!("", _escape, acc), do: Enum.reverse(acc)

  defp like_regex_source!(pattern, escape, acc) do
    case next_grapheme(pattern) do
      {^escape, rest} when is_binary(escape) ->
        case next_grapheme(rest) do
          nil -> unsupported!("Unsupported SelectObjectContent LIKE pattern")
          {literal, rest} -> like_regex_source!(rest, escape, [Regex.escape(literal) | acc])
        end

      {"%", rest} ->
        like_regex_source!(rest, escape, [".*" | acc])

      {"_", rest} ->
        like_regex_source!(rest, escape, ["[\\s\\S]" | acc])

      {literal, rest} ->
        like_regex_source!(rest, escape, [Regex.escape(literal) | acc])
    end
  end

  defp next_grapheme(""), do: nil

  defp next_grapheme(binary) do
    [grapheme | rest] = String.graphemes(binary)
    {grapheme, Enum.join(rest)}
  end

  defp projection_refs(:all), do: []

  defp projection_refs(projections) when is_list(projections) do
    Enum.flat_map(projections, &projection_ref_list/1)
  end

  defp projection_ref_list(%{kind: :projection, expr: expr}), do: projection_ref_list(expr)
  defp projection_ref_list(%{kind: :aggregate, arg: :all}), do: []
  defp projection_ref_list(%{kind: :aggregate, arg: arg}), do: value_expr_refs(arg)
  defp projection_ref_list(%{kind: :arithmetic} = expr), do: value_expr_refs(expr)
  defp projection_ref_list(%{kind: :case} = expr), do: value_expr_refs(expr)
  defp projection_ref_list(%{kind: :cast} = expr), do: value_expr_refs(expr)
  defp projection_ref_list(%{kind: :conditional_function} = expr), do: value_expr_refs(expr)
  defp projection_ref_list(%{kind: :date_function} = expr), do: value_expr_refs(expr)
  defp projection_ref_list(%{kind: :literal}), do: []
  defp projection_ref_list(%{kind: :simple_case} = expr), do: value_expr_refs(expr)
  defp projection_ref_list(%{kind: :string_function} = expr), do: value_expr_refs(expr)
  defp projection_ref_list(%{kind: :unary_minus} = expr), do: value_expr_refs(expr)
  defp projection_ref_list(ref), do: [ref]

  defp value_expr_refs(%{kind: :arithmetic, left: left, right: right}),
    do: value_expr_refs(left) ++ value_expr_refs(right)

  defp value_expr_refs(%{kind: :case, clauses: clauses, else_expr: else_expr}) do
    clause_refs =
      Enum.flat_map(clauses, fn %{condition: condition, result: result} ->
        where_refs(condition) ++ value_expr_refs(result)
      end)

    clause_refs ++ maybe_value_expr_refs(else_expr)
  end

  defp value_expr_refs(%{kind: :cast, expr: expr}), do: value_expr_refs(expr)

  defp value_expr_refs(%{kind: :conditional_function, function: :coalesce, args: args}),
    do: Enum.flat_map(args, &value_expr_refs/1)

  defp value_expr_refs(%{
         kind: :conditional_function,
         function: :nullif,
         left: left,
         right: right
       }),
       do: value_expr_refs(left) ++ value_expr_refs(right)

  defp value_expr_refs(%{
         kind: :date_function,
         function: :date_add,
         quantity: quantity,
         timestamp: timestamp
       }),
       do: value_expr_refs(quantity) ++ value_expr_refs(timestamp)

  defp value_expr_refs(%{kind: :date_function, function: :date_diff, left: left, right: right}),
    do: value_expr_refs(left) ++ value_expr_refs(right)

  defp value_expr_refs(%{
         kind: :date_function,
         function: :to_string,
         timestamp: timestamp,
         pattern: pattern
       }),
       do: value_expr_refs(timestamp) ++ value_expr_refs(pattern)

  defp value_expr_refs(%{kind: :date_function, function: function, arg: arg})
       when function in [:extract, :to_timestamp],
       do: value_expr_refs(arg)

  defp value_expr_refs(%{kind: :date_function, function: :utcnow}), do: []

  defp value_expr_refs(%{kind: :literal}), do: []

  defp value_expr_refs(%{
         kind: :simple_case,
         operand: operand,
         clauses: clauses,
         else_expr: else_expr
       }) do
    clause_refs =
      Enum.flat_map(clauses, fn %{when_expr: when_expr, result: result} ->
        value_expr_refs(when_expr) ++ value_expr_refs(result)
      end)

    value_expr_refs(operand) ++ clause_refs ++ maybe_value_expr_refs(else_expr)
  end

  defp value_expr_refs(%{kind: :string_function, arg: arg}), do: value_expr_refs(arg)
  defp value_expr_refs(%{kind: :unary_minus, expr: expr}), do: value_expr_refs(expr)
  defp value_expr_refs(ref), do: [ref]

  defp maybe_value_expr_refs(nil), do: []
  defp maybe_value_expr_refs(expr), do: value_expr_refs(expr)

  defp where_refs(nil), do: []

  defp where_refs(%{kind: :and, left: left, right: right}),
    do: where_refs(left) ++ where_refs(right)

  defp where_refs(%{kind: :or, left: left, right: right}),
    do: where_refs(left) ++ where_refs(right)

  defp where_refs(%{kind: :not, expr: expr}), do: where_refs(expr)

  defp where_refs(%{left: left, op: _op, right: right}),
    do: value_expr_refs(left) ++ value_expr_refs(right)

  defp where_refs(%{left: left, predicate: predicate, values: values})
       when predicate in [:in, :not_in],
       do: value_expr_refs(left) ++ Enum.flat_map(values, &value_expr_refs/1)

  defp where_refs(%{left: left, predicate: predicate, lower: lower, upper: upper})
       when predicate in [:between, :not_between],
       do: value_expr_refs(left) ++ value_expr_refs(lower) ++ value_expr_refs(upper)

  defp where_refs(%{left: left, predicate: :like, pattern: pattern, escape: escape}),
    do: value_expr_refs(left) ++ value_expr_refs(pattern) ++ maybe_value_expr_refs(escape)

  defp where_refs(%{left: expr}), do: value_expr_refs(expr)

  defp expect_keyword!(tokens, keyword) do
    if match_keyword?(tokens, keyword) do
      tl(tokens)
    else
      unsupported!("Unsupported SelectObjectContent SQL expression")
    end
  end

  defp expect_token!([token | rest], token), do: rest

  defp expect_token!(_tokens, _token),
    do: unsupported!("Unsupported SelectObjectContent SQL expression")

  defp match_keyword?([{:identifier, value} | _rest], keyword),
    do: String.downcase(value) == keyword

  defp match_keyword?(_tokens, _keyword), do: false

  defp tokenize!(expression), do: tokenize!(expression, [])

  defp tokenize!(<<>>, acc), do: Enum.reverse(acc)

  defp tokenize!(<<char, rest::binary>>, acc) when char in [?\s, ?\t, ?\n, ?\r],
    do: tokenize!(rest, acc)

  defp tokenize!(<<?', rest::binary>>, acc) do
    {value, rest} = take_string_literal!(rest, [])
    tokenize!(rest, [{:string, value} | acc])
  end

  defp tokenize!(<<?`, rest::binary>>, acc) do
    {value, rest} = take_timestamp_literal!(rest, [])
    tokenize!(rest, [{:timestamp, value} | acc])
  end

  defp tokenize!(<<?", rest::binary>>, acc) do
    {value, rest} = take_quoted_identifier!(rest, [])
    tokenize!(rest, [{:quoted_identifier, value} | acc])
  end

  defp tokenize!(<<char, rest::binary>>, acc)
       when char in [?,, ?., ?*, ?[, ?], ?(, ?), ?+, ?-, ?/, ?%],
       do: tokenize!(rest, [<<char>> | acc])

  defp tokenize!(<<"<=", rest::binary>>, acc), do: tokenize!(rest, ["<=" | acc])
  defp tokenize!(<<">=", rest::binary>>, acc), do: tokenize!(rest, [">=" | acc])
  defp tokenize!(<<"<>", rest::binary>>, acc), do: tokenize!(rest, ["<>" | acc])
  defp tokenize!(<<"!=", rest::binary>>, acc), do: tokenize!(rest, ["!=" | acc])
  defp tokenize!(<<"=", rest::binary>>, acc), do: tokenize!(rest, ["=" | acc])
  defp tokenize!(<<"<", rest::binary>>, acc), do: tokenize!(rest, ["<" | acc])
  defp tokenize!(<<">", rest::binary>>, acc), do: tokenize!(rest, [">" | acc])

  defp tokenize!(<<char, _rest::binary>> = binary, acc) when char in ?0..?9 do
    {number, rest} = take_number(binary)
    tokenize!(rest, [{:number, number} | acc])
  end

  defp tokenize!(<<char, _rest::binary>> = binary, acc) do
    if identifier_start?(char) do
      {identifier, rest} = take_while(binary, &identifier_char?/1)
      tokenize!(rest, [{:identifier, identifier} | acc])
    else
      unsupported!("Unsupported SelectObjectContent SQL expression")
    end
  end

  defp take_string_literal!(<<?', ?', rest::binary>>, acc),
    do: take_string_literal!(rest, [?' | acc])

  defp take_string_literal!(<<?', rest::binary>>, acc),
    do: {acc |> Enum.reverse() |> IO.iodata_to_binary(), rest}

  defp take_string_literal!(<<char, rest::binary>>, acc),
    do: take_string_literal!(rest, [char | acc])

  defp take_string_literal!(<<>>, _acc),
    do: unsupported!("Unterminated SelectObjectContent SQL string literal")

  defp take_timestamp_literal!(<<?`, rest::binary>>, acc),
    do: {acc |> Enum.reverse() |> IO.iodata_to_binary(), rest}

  defp take_timestamp_literal!(<<char, rest::binary>>, acc),
    do: take_timestamp_literal!(rest, [char | acc])

  defp take_timestamp_literal!(<<>>, _acc),
    do: unsupported!("Unterminated SelectObjectContent SQL timestamp literal")

  defp take_quoted_identifier!(<<?", ?", rest::binary>>, acc),
    do: take_quoted_identifier!(rest, [?" | acc])

  defp take_quoted_identifier!(<<?", rest::binary>>, acc),
    do: {acc |> Enum.reverse() |> IO.iodata_to_binary(), rest}

  defp take_quoted_identifier!(<<char, rest::binary>>, acc),
    do: take_quoted_identifier!(rest, [char | acc])

  defp take_quoted_identifier!(<<>>, _acc),
    do: unsupported!("Unterminated SelectObjectContent SQL quoted identifier")

  defp take_while(binary, predicate), do: take_while(binary, predicate, [])
  defp take_while(<<>>, _predicate, acc), do: {acc |> Enum.reverse() |> IO.iodata_to_binary(), ""}

  defp take_while(<<char, rest::binary>>, predicate, acc) do
    if predicate.(char) do
      take_while(rest, predicate, [char | acc])
    else
      {acc |> Enum.reverse() |> IO.iodata_to_binary(), <<char, rest::binary>>}
    end
  end

  defp take_number(binary) do
    {whole, rest} = take_while(binary, &digit?/1)

    case rest do
      "." <> after_dot ->
        {fraction, rest} = take_while(after_dot, &digit?/1)

        if fraction == "" do
          {whole, "." <> after_dot}
        else
          {whole <> "." <> fraction, rest}
        end

      _other ->
        {whole, rest}
    end
  end

  defp digit?(char), do: char in ?0..?9

  defp identifier_start?(char),
    do: char in ?a..?z or char in ?A..?Z or char == ?_

  defp identifier_char?(char), do: identifier_start?(char) or digit?(char)

  defp json_segment?(%{kind: :field, name: name}) when is_binary(name), do: name != ""
  defp json_segment?(%{kind: :index, index: index}) when is_integer(index), do: index >= 0
  defp json_segment?(_segment), do: false

  defp json_from_segment?(%{kind: kind}) when kind in [:array_wildcard, :object_wildcard],
    do: true

  defp json_from_segment?(segment), do: json_segment?(segment)

  defp unsupported!(message), do: raise(Error.new(:not_implemented, message: message))
end
