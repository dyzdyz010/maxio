defmodule Maxio.S3.SelectOutput do
  @moduledoc """
  Output serialization for SelectObjectContent executor rows.
  """

  alias Maxio.S3.{Error, SelectTimestamp}

  @max_record_size 1_048_576
  @max_column_size 1_048_576
  @max_projection_count 1_000
  @csv_options MapSet.new(~w(
    RecordDelimiter
    FieldDelimiter
    QuoteCharacter
    QuoteEscapeCharacter
    QuoteFields
  ))
  @json_options MapSet.new(~w(RecordDelimiter))

  @spec config!(String.t(), map()) :: map()
  def config!("CSV", options) do
    %{format: "CSV", csv: csv_config!(options || %{})}
  end

  def config!("JSON", options) do
    %{format: "JSON", json: json_config!(options || %{})}
  end

  def config!(_format, _options), do: raise(Error.new(:invalid_argument))

  @spec encode!(list() | map(), map()) :: binary()
  def encode!(fields, %{format: "CSV", csv: config}) when is_list(fields) do
    fields
    |> Enum.map(&csv_field!/1)
    |> format_csv_record!(config)
  end

  def encode!(value, %{format: "CSV", csv: config}) do
    encode!([value], %{format: "CSV", csv: config})
  end

  def encode!(value, %{format: "JSON", json: config}) do
    record =
      value
      |> json_value()
      |> Jason.encode!()
      |> Kernel.<>(config.record_delimiter)

    if byte_size(record) > @max_record_size do
      raise Error.new(:over_max_record_size)
    end

    record
  end

  @spec csv_field!(term()) :: binary()
  def csv_field!(nil), do: ""
  def csv_field!(value) when is_binary(value), do: value
  def csv_field!(value) when is_boolean(value), do: to_string(value)
  def csv_field!(value) when is_integer(value), do: Integer.to_string(value)
  def csv_field!(%SelectTimestamp{} = value), do: SelectTimestamp.to_string(value)

  def csv_field!(value) when is_float(value) do
    if value == trunc(value) * 1.0 do
      Integer.to_string(trunc(value))
    else
      :erlang.float_to_binary(value, [:compact, decimals: 15])
    end
  end

  def csv_field!(_value) do
    raise Error.new(:not_implemented,
            message: "Nested SelectObjectContent values require JSON output"
          )
  end

  defp json_value(%SelectTimestamp{} = value), do: SelectTimestamp.to_string(value)

  defp json_value(value) when is_list(value), do: Enum.map(value, &json_value/1)

  defp json_value(value) when is_map(value) do
    Map.new(value, fn {key, member} -> {key, json_value(member)} end)
  end

  defp json_value(value), do: value

  defp format_csv_record!(fields, config) do
    fields = ensure_column_count!(fields)

    {parts, size, _first?} =
      Enum.reduce(fields, {[], 0, true}, fn field, {parts, size, first?} ->
        formatted = format_csv_field!(field, config)

        if byte_size(formatted) > @max_column_size do
          raise Error.new(:column_too_long)
        end

        delimiter_size = if first?, do: 0, else: byte_size(config.field_delimiter)
        next_size = size + delimiter_size + byte_size(formatted)

        if next_size > @max_record_size do
          raise Error.new(:over_max_record_size)
        end

        parts =
          if first? do
            [formatted | parts]
          else
            [formatted, config.field_delimiter | parts]
          end

        {parts, next_size, false}
      end)

    record_size = size + byte_size(config.record_delimiter)

    if record_size > @max_record_size do
      raise Error.new(:over_max_record_size)
    end

    [Enum.reverse(parts), config.record_delimiter]
    |> IO.iodata_to_binary()
  end

  defp format_csv_field!(field, %{quote_fields: "ALWAYS"} = config),
    do: quote_csv_field!(field, config)

  defp format_csv_field!(field, %{quote_fields: "ASNEEDED"} = config) do
    if needs_quote?(field, config), do: quote_csv_field!(field, config), else: field
  end

  defp needs_quote?(field, config) do
    :binary.match(field, config.field_delimiter) != :nomatch or
      :binary.match(field, config.record_delimiter) != :nomatch or
      :binary.match(field, config.quote_character) != :nomatch
  end

  defp quote_csv_field!(field, config) do
    escaped =
      String.replace(
        field,
        config.quote_character,
        config.quote_escape_character <> config.quote_character
      )

    config.quote_character <> escaped <> config.quote_character
  end

  defp csv_config!(options) do
    reject_unknown_csv_options!(options)

    %{
      record_delimiter: char_option!(options, "RecordDelimiter", "\n", "CSV"),
      field_delimiter: char_option!(options, "FieldDelimiter", ",", "CSV"),
      quote_character: char_option!(options, "QuoteCharacter", "\"", "CSV"),
      quote_escape_character: char_option!(options, "QuoteEscapeCharacter", "\"", "CSV"),
      quote_fields: enum_option!(options, "QuoteFields", "ASNEEDED", ~w(ALWAYS ASNEEDED))
    }
    |> validate_csv_config!()
  end

  defp json_config!(options) do
    reject_unknown_json_options!(options)
    %{record_delimiter: char_option!(options, "RecordDelimiter", "\n", "JSON")}
  end

  defp validate_csv_config!(config) do
    cond do
      config.record_delimiter == config.field_delimiter ->
        invalid!("CSV RecordDelimiter and FieldDelimiter must differ")

      config.quote_character in [config.record_delimiter, config.field_delimiter] ->
        raise Error.new(:not_implemented,
                message:
                  "CSV QuoteCharacter cannot match a delimiter for this SelectObjectContent slice"
              )

      true ->
        config
    end
  end

  defp reject_unknown_csv_options!(options) do
    case Enum.reject(Map.keys(options), &MapSet.member?(@csv_options, &1)) do
      [] -> :ok
      [key | _rest] -> invalid!("Unsupported CSV serialization option #{key}")
    end
  end

  defp reject_unknown_json_options!(options) do
    case Enum.reject(Map.keys(options), &MapSet.member?(@json_options, &1)) do
      [] ->
        :ok

      [key | _rest] ->
        raise Error.new(:invalid_request_parameter,
                message: "JSON output option #{key} is not supported"
              )
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

  defp char_option!(options, key, default, label) do
    value = Map.get(options, key, default)

    case value do
      <<byte>> when byte <= 127 and byte != 0 ->
        value

      _other ->
        raise Error.new(:not_implemented,
                message:
                  "Only single-byte ASCII #{label} #{key} is implemented for SelectObjectContent"
              )
    end
  end

  defp ensure_column_count!(fields) do
    if length(fields) > @max_projection_count do
      raise Error.new(:over_max_column)
    end

    fields
  end

  defp invalid!(message), do: raise(Error.new(:invalid_argument, message: message))
end
