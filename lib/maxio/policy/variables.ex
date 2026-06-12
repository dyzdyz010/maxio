defmodule Maxio.Policy.Variables do
  @moduledoc """
  IAM policy variable expansion for runtime policy evaluation.

  AWS substitutes `${key}` placeholders from the request context when a policy is
  evaluated. Only single-valued context keys can be used as policy variables. If
  a variable has no value, callers must treat it as no-match rather than as an
  empty string.
  """

  @unresolved {:maxio_policy_variable, :unresolved}
  @variable ~r/\$\{([^}]+)\}/
  @literal_star <<0, "maxio-policy-literal-star", 0>>
  @literal_question <<0, "maxio-policy-literal-question", 0>>
  @literal_dollar <<0, "maxio-policy-literal-dollar", 0>>
  @literal_markers [
    {@literal_star, "*"},
    {@literal_question, "?"},
    {@literal_dollar, "$"}
  ]

  @doc "Sentinel used inside condition evaluation for unresolved policy variables."
  @spec unresolved() :: tuple()
  def unresolved, do: @unresolved

  @spec unresolved?(term()) :: boolean()
  def unresolved?(value), do: value == @unresolved

  @doc """
  Converts internal literal wildcard markers back to ordinary characters.

  Use this for exact comparisons and scalar parsing. Glob matching must preserve
  the markers so `${*}` and `${?}` are not reinterpreted as wildcards.
  """
  @spec render_literals(String.t()) :: String.t()
  def render_literals(value) when is_binary(value) do
    Enum.reduce(@literal_markers, value, fn {marker, literal}, acc ->
      String.replace(acc, marker, literal)
    end)
  end

  @doc """
  Splits an expanded policy pattern into wildcard-enabled and literal segments.

  The returned segments let glob matchers treat ordinary `*`/`?` from the policy
  as wildcards while preserving `${*}`/`${?}` as literal characters.
  """
  @spec glob_segments(String.t()) :: [{:pattern | :literal, String.t()}]
  def glob_segments(value) when is_binary(value), do: do_glob_segments(value, [])

  @doc """
  Expands all variables in `value` using `ctx`.

  Returns `:unresolved` if any variable refers to a missing, null, or multivalued
  context key and does not provide a default value.
  """
  @spec expand_string(String.t(), map()) :: {:ok, String.t()} | :unresolved
  def expand_string(value, ctx) when is_binary(value) and is_map(ctx) do
    @variable
    |> Regex.scan(value)
    |> Enum.reduce_while({:ok, value}, fn [token, expr], {:ok, acc} ->
      case resolve_expr(expr, ctx) do
        {:ok, replacement} ->
          {:cont, {:ok, String.replace(acc, token, replacement, global: false)}}

        :unresolved ->
          {:halt, :unresolved}
      end
    end)
  end

  @doc """
  Expands one condition policy value.

  Non-binary policy values are returned unchanged. A binary value with an
  unresolved variable becomes `unresolved/0` so negated condition operators can
  apply AWS's null-variable semantics.
  """
  @spec expand_condition_value(term(), map()) :: term()
  def expand_condition_value(value, ctx) when is_binary(value) do
    case expand_string(value, ctx) do
      {:ok, expanded} -> expanded
      :unresolved -> @unresolved
    end
  end

  def expand_condition_value(value, _ctx), do: value

  defp resolve_expr("*", _ctx), do: {:ok, @literal_star}
  defp resolve_expr("?", _ctx), do: {:ok, @literal_question}
  defp resolve_expr("$", _ctx), do: {:ok, @literal_dollar}

  defp resolve_expr(expr, ctx) do
    {key, default} = parse_expr(expr)

    case fetch_context_value(ctx, key) do
      {:ok, value} ->
        {:ok, value}

      :error ->
        case default do
          {:ok, value} -> {:ok, value}
          nil -> :unresolved
        end
    end
  end

  defp parse_expr(expr) do
    case Regex.run(~r/^\s*([^,]+?)\s*,\s*'([^']*)'\s*$/, expr) do
      [_, key, default] -> {String.trim(key), {:ok, default}}
      _ -> {String.trim(expr), nil}
    end
  end

  defp fetch_context_value(ctx, key) do
    downcased = String.downcase(key)

    ctx
    |> Enum.find(fn
      {ctx_key, _value} when is_binary(ctx_key) -> String.downcase(ctx_key) == downcased
      _entry -> false
    end)
    |> case do
      {_ctx_key, value} -> scalar_context_value(value)
      nil -> :error
    end
  end

  defp scalar_context_value(value) when value in [nil, ""], do: :error
  defp scalar_context_value(value) when is_list(value), do: :error
  defp scalar_context_value(%DateTime{} = value), do: {:ok, DateTime.to_iso8601(value)}
  defp scalar_context_value(value) when is_binary(value), do: {:ok, value}
  defp scalar_context_value(value) when is_boolean(value), do: {:ok, to_string(value)}

  defp scalar_context_value(value) when is_integer(value) or is_float(value),
    do: {:ok, to_string(value)}

  defp scalar_context_value(_value), do: :error

  defp do_glob_segments("", acc), do: acc |> Enum.reverse() |> merge_adjacent_segments()

  defp do_glob_segments(value, acc) do
    case next_literal_marker(value) do
      {0, marker, literal} ->
        rest = binary_part(value, byte_size(marker), byte_size(value) - byte_size(marker))
        do_glob_segments(rest, [{:literal, literal} | acc])

      {index, marker, literal} ->
        pattern = binary_part(value, 0, index)
        rest_start = index + byte_size(marker)
        rest = binary_part(value, rest_start, byte_size(value) - rest_start)
        do_glob_segments(rest, [{:literal, literal}, {:pattern, pattern} | acc])

      nil ->
        do_glob_segments("", [{:pattern, value} | acc])
    end
  end

  defp next_literal_marker(value) do
    @literal_markers
    |> Enum.flat_map(fn {marker, literal} ->
      case :binary.match(value, marker) do
        {index, _len} -> [{index, marker, literal}]
        :nomatch -> []
      end
    end)
    |> Enum.min_by(fn {index, _marker, _literal} -> index end, fn -> nil end)
  end

  defp merge_adjacent_segments(segments) do
    segments
    |> Enum.reduce([], fn
      {type, value}, [{type, prev} | rest] -> [{type, prev <> value} | rest]
      segment, acc -> [segment | acc]
    end)
    |> Enum.reverse()
  end
end
