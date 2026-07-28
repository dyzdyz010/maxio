defmodule Maxio.S3.RequestParsers.SelectObjectContent do
  @moduledoc """
  Strict XML parser for SelectObjectContent and RestoreObject SelectParameters.

  The parser preserves the existing internal request shape and rejects malformed
  control XML before the handler reaches object data or response streaming.
  """

  alias Maxio.S3.RequestParsers.XMLTree

  @type request :: %{
          expression: String.t(),
          expression_type: String.t(),
          input: map(),
          output: map(),
          request_progress: boolean(),
          scan_range?: boolean(),
          scan_range: nil | %{start: non_neg_integer() | nil, end: non_neg_integer() | nil}
        }

  @unset {:__maxio_select_unset__, []}
  @compression_types ~w(NONE GZIP BZIP2)
  @csv_input_options ~w(
    AllowQuotedRecordDelimiter
    Comments
    FieldDelimiter
    FileHeaderInfo
    QuoteCharacter
    QuoteEscapeCharacter
    RecordDelimiter
  )
  @json_input_options ~w(Type)
  @csv_output_options ~w(
    FieldDelimiter
    QuoteCharacter
    QuoteEscapeCharacter
    QuoteFields
    RecordDelimiter
  )
  @json_output_options ~w(RecordDelimiter)

  @spec parse(binary()) :: {:ok, request()} | {:error, :malformed_xml}
  def parse(xml) when is_binary(xml) do
    with {:ok, {"SelectObjectContentRequest", _attrs, children}} <- XMLTree.parse(xml),
         {:ok, request} <-
           parse_select_parameters(children, request_progress?: true, scan_range?: true) do
      {:ok, request}
    else
      _other -> {:error, :malformed_xml}
    end
  end

  @doc false
  @spec parse_select_parameters([XMLTree.xml_node() | {:text, String.t()}], keyword()) ::
          {:ok, request()} | :error
  def parse_select_parameters(children, opts \\ []) when is_list(children) do
    allow_request_progress? = Keyword.get(opts, :request_progress?, false)
    allow_scan_range? = Keyword.get(opts, :scan_range?, false)

    children
    |> XMLTree.structural_children()
    |> Enum.reduce_while({:ok, initial_request()}, fn
      {"Expression", _attrs, children}, {:ok, request} ->
        put_once(request, :expression, trimmed_required_text(children))

      {"ExpressionType", _attrs, children}, {:ok, request} ->
        put_once(request, :expression_type, expression_type(children))

      {"InputSerialization", _attrs, children}, {:ok, request} ->
        put_once(request, :input, parse_input_serialization(children))

      {"OutputSerialization", _attrs, children}, {:ok, request} ->
        put_once(request, :output, parse_output_serialization(children))

      {"RequestProgress", _attrs, children}, {:ok, request} when allow_request_progress? ->
        put_once(request, :request_progress, parse_request_progress(children))

      {"ScanRange", _attrs, children}, {:ok, request} when allow_scan_range? ->
        put_once(request, :scan_range, parse_scan_range(children))

      _other, _acc ->
        {:halt, :error}
    end)
    |> case do
      {:ok, request} -> finalize_request(request)
      :error -> :error
    end
  end

  defp initial_request do
    %{
      expression: @unset,
      expression_type: @unset,
      input: @unset,
      output: @unset,
      request_progress: @unset,
      scan_range: @unset
    }
  end

  defp finalize_request(%{
         expression: expression,
         expression_type: "SQL",
         input: input,
         output: output,
         request_progress: request_progress,
         scan_range: scan_range
       })
       when is_binary(expression) and expression != "" and is_map(input) and is_map(output) do
    case {request_progress_value(request_progress), scan_range_value(scan_range)} do
      {{:ok, request_progress?}, {:ok, scan_range?, scan_range}} ->
        {:ok,
         %{
           expression: expression,
           expression_type: "SQL",
           input: input,
           output: output,
           request_progress: request_progress?,
           scan_range?: scan_range?,
           scan_range: scan_range
         }}

      _other ->
        :error
    end
  end

  defp finalize_request(_request), do: :error

  defp request_progress_value(@unset), do: {:ok, false}
  defp request_progress_value(value) when is_boolean(value), do: {:ok, value}
  defp request_progress_value(_value), do: :error

  defp scan_range_value(@unset), do: {:ok, false, nil}

  defp scan_range_value(%{start: start, end: end_offset}),
    do: {:ok, true, %{start: start, end: end_offset}}

  defp scan_range_value(_value), do: :error

  defp expression_type(children) do
    case trimmed_required_text(children) do
      {:ok, "SQL"} -> {:ok, "SQL"}
      _other -> :error
    end
  end

  defp parse_input_serialization(children) do
    children
    |> XMLTree.structural_children()
    |> Enum.reduce_while(
      {:ok,
       %{
         format: @unset,
         compression_type: @unset,
         csv_options: %{},
         json_options: %{}
       }},
      fn
        {"CompressionType", _attrs, children}, {:ok, input} ->
          put_optional_once(input, :compression_type, compression_type(children))

        {"CSV", _attrs, children}, {:ok, input} ->
          put_input_format(input, "CSV", parse_csv_input_options(children))

        {"JSON", _attrs, children}, {:ok, input} ->
          put_input_format(input, "JSON", parse_json_input_options(children))

        {"Parquet", _attrs, children}, {:ok, input} ->
          if XMLTree.structural_children(children) == [] do
            put_input_format(input, "Parquet", {:ok, %{}})
          else
            {:halt, :error}
          end

        _other, _acc ->
          {:halt, :error}
      end
    )
    |> case do
      {:ok, %{format: format, compression_type: compression_type} = input}
      when is_binary(format) ->
        {:ok,
         %{
           format: format,
           compression_type: if(compression_type == @unset, do: nil, else: compression_type),
           csv_options: input.csv_options,
           json_options: input.json_options
         }}

      _other ->
        :error
    end
  end

  defp parse_output_serialization(children) do
    children
    |> XMLTree.structural_children()
    |> Enum.reduce_while({:ok, %{format: @unset, csv_options: %{}, json_options: %{}}}, fn
      {"CSV", _attrs, children}, {:ok, output} ->
        put_output_format(output, "CSV", parse_csv_output_options(children))

      {"JSON", _attrs, children}, {:ok, output} ->
        put_output_format(output, "JSON", parse_json_output_options(children))

      _other, _acc ->
        {:halt, :error}
    end)
    |> case do
      {:ok, %{format: format} = output} when is_binary(format) ->
        {:ok, output}

      _other ->
        :error
    end
  end

  defp put_input_format(%{format: @unset} = input, "CSV", {:ok, options}),
    do: {:cont, {:ok, %{input | format: "CSV", csv_options: options}}}

  defp put_input_format(%{format: @unset} = input, "JSON", {:ok, options}),
    do: {:cont, {:ok, %{input | format: "JSON", json_options: options}}}

  defp put_input_format(%{format: @unset} = input, "Parquet", {:ok, _options}),
    do: {:cont, {:ok, %{input | format: "Parquet"}}}

  defp put_input_format(_input, _format, _result), do: {:halt, :error}

  defp put_output_format(%{format: @unset} = output, "CSV", {:ok, options}),
    do: {:cont, {:ok, %{output | format: "CSV", csv_options: options}}}

  defp put_output_format(%{format: @unset} = output, "JSON", {:ok, options}),
    do: {:cont, {:ok, %{output | format: "JSON", json_options: options}}}

  defp put_output_format(_output, _format, _result), do: {:halt, :error}

  defp compression_type(children) do
    with {:ok, value} <- trimmed_required_text(children),
         normalized <- String.upcase(value),
         true <- normalized in @compression_types do
      {:ok, normalized}
    else
      _other -> :error
    end
  end

  defp parse_csv_input_options(children) do
    parse_options(children, @csv_input_options, &csv_input_option/2)
  end

  defp csv_input_option("AllowQuotedRecordDelimiter", children) do
    case boolean_text(children) do
      {:ok, true} -> {:ok, "true"}
      {:ok, false} -> {:ok, "false"}
      :error -> :error
    end
  end

  defp csv_input_option("FileHeaderInfo", children) do
    enum_text(children, ~w(USE IGNORE NONE))
  end

  defp csv_input_option(_name, children), do: XMLTree.text(children)

  defp parse_json_input_options(children) do
    parse_options(children, @json_input_options, fn
      "Type", children -> enum_text(children, ~w(DOCUMENT LINES))
    end)
  end

  defp parse_csv_output_options(children) do
    parse_options(children, @csv_output_options, &csv_output_option/2)
  end

  defp csv_output_option("QuoteFields", children) do
    enum_text(children, ~w(ALWAYS ASNEEDED))
  end

  defp csv_output_option(_name, children), do: XMLTree.text(children)

  defp parse_json_output_options(children) do
    parse_options(children, @json_output_options, fn
      "RecordDelimiter", children -> XMLTree.text(children)
    end)
  end

  defp parse_options(children, allowed, parser) do
    children
    |> XMLTree.structural_children()
    |> Enum.reduce_while({:ok, %{}}, fn
      {name, _attrs, children}, {:ok, options} ->
        cond do
          name not in allowed ->
            {:halt, :error}

          Map.has_key?(options, name) ->
            {:halt, :error}

          true ->
            case parser.(name, children) do
              {:ok, value} -> {:cont, {:ok, Map.put(options, name, value)}}
              :error -> {:halt, :error}
            end
        end

      _other, _acc ->
        {:halt, :error}
    end)
    |> case do
      {:ok, options} -> {:ok, options}
      :error -> :error
    end
  end

  defp parse_request_progress(children) do
    case XMLTree.structural_children(children) do
      [{"Enabled", _attrs, enabled_children}] -> boolean_text(enabled_children)
      _other -> :error
    end
  end

  defp parse_scan_range(children) do
    children
    |> XMLTree.structural_children()
    |> Enum.reduce_while({:ok, %{start: @unset, end: @unset}}, fn
      {"Start", _attrs, children}, {:ok, range} ->
        put_optional_once(range, :start, non_negative_int(children))

      {"End", _attrs, children}, {:ok, range} ->
        put_optional_once(range, :end, non_negative_int(children))

      _other, _acc ->
        {:halt, :error}
    end)
    |> case do
      {:ok, %{start: @unset, end: @unset}} ->
        :error

      {:ok, range} ->
        {:ok,
         %{
           start: if(range.start == @unset, do: nil, else: range.start),
           end: if(range.end == @unset, do: nil, else: range.end)
         }}

      :error ->
        :error
    end
  end

  defp non_negative_int(children) do
    with {:ok, value} <- trimmed_required_text(children),
         {int, ""} when int >= 0 <- Integer.parse(value) do
      {:ok, int}
    else
      _other -> :error
    end
  end

  defp enum_text(children, allowed) do
    with {:ok, value} <- trimmed_required_text(children),
         normalized <- String.upcase(value),
         true <- normalized in allowed do
      {:ok, normalized}
    else
      _other -> :error
    end
  end

  defp boolean_text(children) do
    case trimmed_required_text(children) do
      {:ok, value} ->
        case String.downcase(value) do
          "true" -> {:ok, true}
          "false" -> {:ok, false}
          _other -> :error
        end

      :error ->
        :error
    end
  end

  defp trimmed_required_text(children), do: XMLTree.required_text(children, trim: true)

  defp put_once(map, key, {:ok, value}) do
    if Map.fetch!(map, key) == @unset do
      {:cont, {:ok, Map.put(map, key, value)}}
    else
      {:halt, :error}
    end
  end

  defp put_once(_map, _key, :error), do: {:halt, :error}

  defp put_optional_once(map, key, {:ok, value}) do
    if Map.fetch!(map, key) == @unset do
      {:cont, {:ok, Map.put(map, key, value)}}
    else
      {:halt, :error}
    end
  end

  defp put_optional_once(_map, _key, :error), do: {:halt, :error}
end
