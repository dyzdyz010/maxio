defmodule Maxio.Admin.ConfigKV.Parser do
  @moduledoc false

  @type entry :: %{required(:wire_subsystem) => String.t(), required(:wire_key) => String.t()}
  @type patch :: {String.t(), String.t()}

  @spec parse_set(String.t(), [entry()]) ::
          {:ok, %{wire_subsystem: String.t(), patches: [patch()]}} | {:error, atom()}
  def parse_set(plaintext, entries) when is_binary(plaintext) and is_list(entries) do
    plaintext
    |> parse_set_detailed(entries)
    |> normalize_detailed_error()
  end

  @doc false
  @spec parse_set_detailed(String.t(), [entry()]) ::
          {:ok, %{wire_subsystem: String.t(), patches: [patch()]}} | {:error, atom()}
  def parse_set_detailed(plaintext, entries) when is_binary(plaintext) and is_list(entries) do
    plaintext
    |> String.split("\n")
    |> Enum.reduce_while({:ok, nil, []}, fn line, {:ok, subsystem, patches} ->
      case parse_set_line(line, entries, subsystem) do
        :skip ->
          {:cont, {:ok, subsystem, patches}}

        {:ok, line_subsystem, line_patches} ->
          {:cont, {:ok, subsystem || line_subsystem, patches ++ line_patches}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
    |> finish_set()
  end

  @spec parse_reset(String.t()) ::
          {:ok, %{wire_subsystem: String.t(), reset: :all | [String.t()]}} | {:error, atom()}
  def parse_reset(plaintext) when is_binary(plaintext) do
    plaintext
    |> parse_reset_detailed()
    |> normalize_detailed_error()
  end

  @doc false
  @spec parse_reset_detailed(String.t()) ::
          {:ok, %{wire_subsystem: String.t(), reset: :all | [String.t()]}} | {:error, atom()}
  def parse_reset_detailed(plaintext) when is_binary(plaintext) do
    plaintext
    |> String.split("\n")
    |> Enum.reduce_while({:ok, nil, :unset}, fn line, {:ok, subsystem, reset} ->
      case parse_reset_line(line, subsystem) do
        :skip ->
          {:cont, {:ok, subsystem, reset}}

        {:ok, line_subsystem, line_reset} ->
          {:cont, {:ok, subsystem || line_subsystem, merge_reset(reset, line_reset)}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
    |> finish_reset()
  end

  @spec render(String.t(), [{String.t(), boolean() | integer() | String.t()}]) :: iodata()
  def render(subsystem, kvs) when is_binary(subsystem) and is_list(kvs) do
    [subsystem, " ", Enum.map(kvs, fn {key, value} -> [key, "=", encode(value), " "] end), "\n"]
  end

  defp parse_set_line(line, entries, expected_subsystem) do
    trimmed = String.trim(line)

    if blank_or_comment?(trimmed) do
      :skip
    else
      with {:ok, subsystem, fields} <- split_subsystem(trimmed),
           :ok <- reject_target(subsystem),
           :ok <- require_same_subsystem(expected_subsystem, subsystem),
           {:ok, patches} <- parse_registered_fields(subsystem, fields, entries) do
        {:ok, subsystem, patches}
      end
    end
  end

  defp parse_registered_fields(subsystem, fields, entries) do
    markers =
      entries
      |> Enum.filter(&(&1.wire_subsystem == subsystem))
      |> Enum.reduce([], fn entry, found ->
        marker = entry.wire_key <> "="

        case :binary.match(fields, marker) do
          :nomatch -> found
          {index, _length} -> [{index, entry} | found]
        end
      end)
      |> Enum.sort_by(fn {index, _entry} -> index end)

    case markers do
      [] ->
        {:error, :unknown_key}

      [{first_index, _entry} | _rest] ->
        if String.trim(binary_part(fields, 0, first_index)) == "" do
          {:ok, marker_patches(fields, markers)}
        else
          {:error, :bad_json}
        end
    end
  end

  defp marker_patches(fields, markers) do
    markers
    |> Enum.with_index()
    |> Enum.map(fn {{start, entry}, index} ->
      finish =
        case Enum.at(markers, index + 1) do
          {next_start, _next_entry} -> next_start
          nil -> byte_size(fields)
        end

      segment = binary_part(fields, start, finish - start)
      [_key, raw_value] = String.split(segment, "=", parts: 2)
      {entry.wire_key, sanitize_value(raw_value)}
    end)
  end

  defp parse_reset_line(line, expected_subsystem) do
    trimmed = String.trim(line)

    if blank_or_comment?(trimmed) do
      :skip
    else
      case String.split(trimmed) do
        [] ->
          :skip

        [subsystem | keys] ->
          with :ok <- reject_target(subsystem),
               :ok <- require_same_subsystem(expected_subsystem, subsystem) do
            reset = if keys == [], do: :all, else: keys
            {:ok, subsystem, reset}
          end
      end
    end
  end

  defp split_subsystem(line) do
    case String.split(line, ~r/\s+/, parts: 2) do
      [subsystem, fields] -> {:ok, subsystem, fields}
      [subsystem] -> {:ok, subsystem, ""}
    end
  end

  defp reject_target(subsystem) do
    if String.contains?(subsystem, ":"), do: {:error, :invalid_argument}, else: :ok
  end

  defp require_same_subsystem(nil, _line_subsystem), do: :ok
  defp require_same_subsystem(subsystem, subsystem), do: :ok
  defp require_same_subsystem(_subsystem, _line_subsystem), do: {:error, :cross_subsystem}

  defp blank_or_comment?(trimmed), do: trimmed == "" or String.starts_with?(trimmed, "#")

  defp sanitize_value(raw_value) do
    raw_value
    |> String.trim()
    |> String.replace_prefix("\"", "")
    |> String.replace_suffix("\"", "")
    |> String.replace_prefix("'", "")
    |> String.replace_suffix("'", "")
  end

  defp merge_reset(:all, _line_reset), do: :all
  defp merge_reset(_reset, :all), do: :all
  defp merge_reset(:unset, line_reset), do: line_reset
  defp merge_reset(reset, line_reset), do: reset ++ line_reset

  defp finish_set({:ok, nil, _patches}), do: {:error, :unknown_key}

  defp finish_set({:ok, subsystem, patches}),
    do: {:ok, %{wire_subsystem: subsystem, patches: patches}}

  defp finish_set({:error, reason}), do: {:error, reason}

  defp finish_reset({:ok, nil, _reset}), do: {:error, :unknown_key}

  defp finish_reset({:ok, _subsystem, :unset}),
    do: {:error, :unknown_key}

  defp finish_reset({:ok, subsystem, reset}),
    do: {:ok, %{wire_subsystem: subsystem, reset: reset}}

  defp finish_reset({:error, reason}), do: {:error, reason}

  defp normalize_detailed_error({:error, :cross_subsystem}), do: {:error, :bad_json}
  defp normalize_detailed_error(result), do: result

  defp encode(value) when is_binary(value) do
    if String.match?(value, ~r/\s/u), do: ["\"", value, "\""], else: value
  end

  defp encode(value) when is_boolean(value), do: to_string(value)
  defp encode(value) when is_integer(value), do: Integer.to_string(value)
end
