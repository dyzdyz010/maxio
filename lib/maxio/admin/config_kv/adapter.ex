defmodule Maxio.Admin.ConfigKV.Adapter do
  @moduledoc false

  alias Maxio.Admin.ConfigKV.{Parser, Registry}
  alias Maxio.Config
  alias Maxio.Config.Schema

  @type reason ::
          :access_denied
          | :config_bad_json
          | :config_generic
          | :config_not_found
          | :invalid_argument
          | {:config_store_unavailable, atom()}

  @spec get(String.t(), keyword()) ::
          {:ok, %{plaintext: iodata(), subsystem: atom(), keys: [atom()]}}
          | {:error, reason()}
  def get(wire_subsystem, opts \\ [])

  def get(wire_subsystem, opts) when is_binary(wire_subsystem) and is_list(opts) do
    with :ok <- reject_target(wire_subsystem),
         :ok <- reject_forbidden_subsystem(wire_subsystem),
         {:ok, entries} <- exposed_subsystem(wire_subsystem),
         core_subsystem = hd(entries).core_subsystem,
         keys = Enum.map(entries, & &1.core_key),
         {:ok, effective} <- Config.authoritative_effective(core_subsystem, keys, opts) do
      values = project_redacted(entries, effective)

      {:ok,
       %{
         plaintext: Parser.render(wire_subsystem, values),
         subsystem: core_subsystem,
         keys: keys
       }}
    end
  end

  def get(_wire_subsystem, _opts), do: {:error, :invalid_argument}

  @spec set(String.t(), keyword()) :: {:ok, map()} | {:error, reason()}
  def set(plaintext, opts \\ [])

  def set(plaintext, opts) when is_binary(plaintext) and is_list(opts) do
    with :ok <- preflight_set(plaintext),
         {:ok, parsed} <- parse_set(plaintext),
         {:ok, entries} <- exposed_subsystem(parsed.wire_subsystem),
         {:ok, operations} <- set_operations(entries, parsed.patches) do
      mutate(hd(entries).core_subsystem, operations, opts)
    end
  end

  def set(_plaintext, _opts), do: {:error, :invalid_argument}

  @spec reset(String.t(), keyword()) :: {:ok, map()} | {:error, reason()}
  def reset(plaintext, opts \\ [])

  def reset(plaintext, opts) when is_binary(plaintext) and is_list(opts) do
    with :ok <- preflight_reset(plaintext),
         {:ok, parsed} <- parse_reset(plaintext),
         {:ok, entries} <- exposed_subsystem(parsed.wire_subsystem),
         {:ok, operations} <- reset_operations(entries, parsed.reset) do
      mutate(hd(entries).core_subsystem, operations, opts)
    end
  end

  def reset(_plaintext, _opts), do: {:error, :invalid_argument}

  @spec describe_error(term()) :: String.t()
  def describe_error(:access_denied), do: "access denied"
  def describe_error(:config_bad_json), do: "configuration has incorrect format"
  def describe_error(:config_generic), do: "configuration request is invalid"
  def describe_error(:config_not_found), do: "configuration key was not found"
  def describe_error(:invalid_argument), do: "invalid argument"

  def describe_error({:config_store_unavailable, _safe_reason}),
    do: "configuration store is unavailable"

  def describe_error(_reason), do: "configuration operation failed"

  defp parse_set(plaintext) do
    case Parser.parse_set(plaintext, Registry.entries()) do
      {:ok, parsed} -> {:ok, parsed}
      {:error, :bad_json} -> {:error, :config_bad_json}
      {:error, :invalid_argument} -> {:error, :invalid_argument}
      {:error, :unknown_key} -> {:error, :config_generic}
      {:error, _reason} -> {:error, :config_generic}
    end
  end

  defp parse_reset(plaintext) do
    case Parser.parse_reset(plaintext) do
      {:ok, parsed} -> {:ok, parsed}
      {:error, :bad_json} -> {:error, :config_bad_json}
      {:error, :invalid_argument} -> {:error, :invalid_argument}
      {:error, :unknown_key} -> {:error, :config_generic}
      {:error, _reason} -> {:error, :config_generic}
    end
  end

  defp exposed_subsystem(wire_subsystem) do
    case Registry.exposed_subsystem(wire_subsystem) do
      {:ok, entries} -> {:ok, entries}
      {:error, :unknown_subsystem} -> {:error, :config_generic}
    end
  end

  defp set_operations(entries, patches) do
    folded = Map.new(patches)

    Enum.reduce_while(entries, {:ok, []}, fn entry, {:ok, operations} ->
      case Map.fetch(folded, entry.wire_key) do
        {:ok, raw} ->
          case Schema.parse(entry.core_subsystem, entry.core_key, raw) do
            {:ok, value} ->
              {:cont, {:ok, [{:set, entry.core_key, value} | operations]}}

            {:error, _reason} ->
              {:halt, {:error, :config_bad_json}}
          end

        :error ->
          {:cont, {:ok, operations}}
      end
    end)
    |> reverse_operations()
  end

  defp reset_operations(entries, :all) do
    {:ok, Enum.map(entries, &{:reset, &1.core_key})}
  end

  defp reset_operations(entries, wire_keys) when is_list(wire_keys) do
    wire_subsystem = hd(entries).wire_subsystem

    with :ok <- classify_reset_keys(wire_subsystem, wire_keys) do
      requested = MapSet.new(wire_keys)

      {:ok,
       entries
       |> Enum.filter(&MapSet.member?(requested, &1.wire_key))
       |> Enum.map(&{:reset, &1.core_key})}
    end
  end

  defp classify_reset_keys(wire_subsystem, wire_keys) do
    Enum.reduce_while(wire_keys, :ok, fn wire_key, :ok ->
      case Registry.classify_path(wire_subsystem, wire_key) do
        {:ok, _entry} -> {:cont, :ok}
        {:error, :forbidden} -> {:halt, {:error, :access_denied}}
        {:error, :wire_hidden} -> {:halt, {:error, :config_generic}}
        {:error, :unknown_key} -> {:halt, {:error, :config_not_found}}
      end
    end)
  end

  defp reverse_operations({:ok, operations}), do: {:ok, Enum.reverse(operations)}
  defp reverse_operations({:error, reason}), do: {:error, reason}

  defp mutate(subsystem, operations, opts) do
    case Config.mutate_subsystem(subsystem, operations, opts) do
      {:ok, result} -> {:ok, result}
      {:error, reason} -> {:error, translate_config_error(reason)}
    end
  rescue
    _error -> {:error, {:config_store_unavailable, :mutation_failed}}
  catch
    :exit, _reason -> {:error, {:config_store_unavailable, :mutation_exited}}
    _kind, _reason -> {:error, {:config_store_unavailable, :mutation_failed}}
  end

  defp translate_config_error({:forbidden_config_key, _subsystem, _key}),
    do: :access_denied

  defp translate_config_error({:unknown_config_key, _subsystem, _key}),
    do: :config_generic

  defp translate_config_error({:invalid_config_value, _subsystem, _key, _reason}),
    do: :config_bad_json

  defp translate_config_error({:invalid_config_source, _source}), do: :invalid_argument

  defp translate_config_error({:config_store_unavailable, reason}) when is_atom(reason),
    do: {:config_store_unavailable, reason}

  defp translate_config_error(_reason), do: {:config_store_unavailable, :mutation_failed}

  defp project_redacted(entries, effective) do
    by_key = Map.new(effective, &{&1.key, &1.value})

    entries
    |> Enum.reject(& &1.sensitive?)
    |> Enum.map(fn entry -> {entry.wire_key, Map.fetch!(by_key, entry.core_key)} end)
  end

  defp preflight_set(plaintext) do
    plaintext
    |> command_lines()
    |> Enum.reduce_while(:ok, fn line, :ok ->
      case String.split(line, ~r/\s+/u, parts: 2) do
        [wire_subsystem] ->
          continue_or_halt(classify_explicit_path(wire_subsystem, ""))

        [wire_subsystem, fields] ->
          keys =
            ~r/(?:^|\s)([^\s=]+)=/u
            |> Regex.scan(fields, capture: :all_but_first)
            |> List.flatten()

          ["" | keys]
          |> Enum.reduce_while(:ok, fn wire_key, :ok ->
            continue_or_halt(classify_explicit_path(wire_subsystem, wire_key))
          end)
          |> continue_or_halt()
      end
    end)
  end

  defp preflight_reset(plaintext) do
    plaintext
    |> command_lines()
    |> Enum.reduce_while(:ok, fn line, :ok ->
      case String.split(line, ~r/\s+/u) do
        [wire_subsystem | wire_keys] ->
          ["" | wire_keys]
          |> Enum.reduce_while(:ok, fn wire_key, :ok ->
            continue_or_halt(classify_explicit_path(wire_subsystem, wire_key))
          end)
          |> continue_or_halt()

        [] ->
          {:cont, :ok}
      end
    end)
  end

  defp command_lines(plaintext) do
    plaintext
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == "" or String.starts_with?(&1, "#")))
  end

  defp classify_explicit_path(wire_subsystem, wire_key) do
    if String.contains?(wire_subsystem, ":") do
      :ok
    else
      case Registry.classify_path(wire_subsystem, wire_key) do
        {:error, :forbidden} -> {:error, :access_denied}
        {:error, :wire_hidden} -> {:error, :config_generic}
        {:ok, _entry} -> :ok
        {:error, :unknown_key} -> :ok
      end
    end
  end

  defp continue_or_halt(:ok), do: {:cont, :ok}
  defp continue_or_halt({:error, reason}), do: {:halt, {:error, reason}}

  defp reject_target(wire_subsystem) do
    if String.contains?(wire_subsystem, ":"), do: {:error, :invalid_argument}, else: :ok
  end

  defp reject_forbidden_subsystem(wire_subsystem) do
    case Registry.classify_path(wire_subsystem, "") do
      {:error, :forbidden} -> {:error, :access_denied}
      _other -> :ok
    end
  end
end
