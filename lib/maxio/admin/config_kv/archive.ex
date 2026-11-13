defmodule Maxio.Admin.ConfigKV.Archive do
  @moduledoc false

  alias Maxio.Admin.ConfigKV.{Parser, Registry}
  alias Maxio.Config
  alias Maxio.Config.Schema

  @test_config_injection Mix.env() == :test
  @safe_identifier ~r/\A[A-Za-z0-9][A-Za-z0-9_.:-]{0,127}\z/
  @sensitive_marker ~r/(?:secret|password|token|credential|access[_-]?key|private|cipher|plaintext|root[_-]?user)/i

  @type operation :: {:set, atom(), term()} | {:reset, atom()}
  @type operation_group :: {atom(), [operation()]}
  @type error_evidence :: %{
          required(:reason) => atom() | {:config_store_unavailable, atom()},
          required(:subsystem) => String.t(),
          required(:key_count) => non_neg_integer(),
          required(:stage) => :parser | :exposure | :type | :database
        }

  @spec export(keyword()) :: {:ok, binary()} | {:error, error_evidence()}
  def export(opts) when is_list(opts) do
    paths = Registry.public_paths()
    config = config_facade(opts)
    config_opts = Keyword.delete(opts, :config)

    case apply(config, :authoritative_snapshot, [paths, config_opts]) do
      {:ok, snapshot} when is_map(snapshot) -> encode_snapshot(snapshot)
      {:error, reason} -> {:error, database_evidence(reason)}
      _other -> {:error, database_evidence(:invalid_snapshot_result)}
    end
  rescue
    _error -> {:error, database_evidence(:snapshot_failed)}
  catch
    :exit, _reason -> {:error, database_evidence(:snapshot_exited)}
    _kind, _reason -> {:error, database_evidence(:snapshot_failed)}
  end

  def export(_opts), do: {:error, evidence(:invalid_argument, :parser, "unknown", 0)}

  @spec decode_and_plan(binary()) :: {:ok, [operation_group()]} | {:error, error_evidence()}
  def decode_and_plan(plaintext) when is_binary(plaintext) do
    entries = Registry.entries()

    with true <- String.valid?(plaintext),
         {:ok, _paths} <- Registry.public_paths(entries),
         :ok <- validate_document_syntax(plaintext),
         :ok <- preflight_exposure(plaintext, entries),
         {:ok, lines} <- parse_document(plaintext, entries),
         {:ok, folded} <- fold_document(lines),
         {:ok, operations} <- typed_operations(entries, folded) do
      {:ok, group_operations(operations)}
    else
      false -> {:error, evidence(:config_bad_json, :parser, "unknown", 0)}
      {:error, %{reason: _reason} = error} -> {:error, error}
      {:error, _registry_reason} -> {:error, evidence(:config_generic, :exposure, "unknown", 0)}
    end
  end

  def decode_and_plan(_plaintext),
    do: {:error, evidence(:invalid_argument, :parser, "unknown", 0)}

  @spec import_config(binary(), keyword()) :: {:ok, map()} | {:error, error_evidence()}
  def import_config(plaintext, opts) when is_binary(plaintext) and is_list(opts) do
    with :ok <- validate_source(opts),
         {:ok, groups} <- decode_and_plan(plaintext) do
      config = config_facade(opts)
      config_opts = Keyword.delete(opts, :config)

      case apply(config, :mutate_many, [groups, config_opts]) do
        {:ok, _result} = success -> success
        {:error, reason} -> {:error, mutation_evidence(reason)}
        _other -> {:error, database_evidence(:invalid_mutation_result)}
      end
    end
  rescue
    _error -> {:error, database_evidence(:mutation_failed)}
  catch
    :exit, _reason -> {:error, database_evidence(:mutation_exited)}
    _kind, _reason -> {:error, database_evidence(:mutation_failed)}
  end

  def import_config(_plaintext, _opts),
    do: {:error, evidence(:invalid_argument, :parser, "unknown", 0)}

  defp encode_snapshot(snapshot) do
    Registry.entries()
    |> Enum.reduce_while({:ok, []}, fn entry, {:ok, rendered} ->
      path = {entry.core_subsystem, entry.core_key}

      with {:ok, %{value: value}} <- Map.fetch(snapshot, path),
           {:ok, typed_value} <- Schema.cast(entry.core_subsystem, entry.core_key, value) do
        line = Parser.render(entry.wire_subsystem, [{entry.wire_key, typed_value}])
        {:cont, {:ok, [line | rendered]}}
      else
        _error -> {:halt, {:error, database_evidence(:invalid_snapshot)}}
      end
    end)
    |> case do
      {:ok, rendered} -> {:ok, rendered |> Enum.reverse() |> IO.iodata_to_binary()}
      {:error, error} -> {:error, error}
    end
  end

  defp parse_document(plaintext, entries) do
    case Parser.parse_document(plaintext, entries) do
      {:ok, lines} ->
        {:ok, lines}

      {:error, :invalid_argument} ->
        {:error, evidence(:invalid_argument, :parser, "unknown", 0)}

      {:error, _reason} ->
        {:error, evidence(:config_bad_json, :parser, "unknown", 0)}
    end
  end

  # The public Parser resolves registered keys while it tokenizes. Archive import
  # has a stricter staged contract: document syntax is decided before any path is
  # classified as public, hidden, forbidden, or unknown. Keep this first pass
  # deliberately registry-neutral; the exposure pass and Parser remain the
  # authoritative path and scalar decoders afterwards.
  defp validate_document_syntax(plaintext) do
    plaintext
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == "" or String.starts_with?(&1, "#")))
    |> Enum.reduce_while(:ok, fn line, :ok ->
      case String.split(line, ~r/\s+/u, parts: 2) do
        [_wire_subsystem, fields] ->
          if Regex.match?(~r/\A[^\s=]+=/u, fields) do
            {:cont, :ok}
          else
            {:halt, {:error, evidence(:config_bad_json, :parser, "unknown", 0)}}
          end

        [_wire_subsystem] ->
          # A subsystem-only line is lexically complete. Exposure decides
          # whether it is a target/unknown/empty-key command at the next stage.
          {:cont, :ok}
      end
    end)
  end

  defp fold_document(lines) do
    Enum.reduce_while(lines, {:ok, %{}}, fn line, {:ok, folded} ->
      line_result =
        Enum.reduce_while(line.patches, {:ok, folded}, fn {wire_key, raw}, {:ok, line_folded} ->
          case Registry.classify_path(line.wire_subsystem, wire_key) do
            {:ok, entry} ->
              path = {entry.core_subsystem, entry.core_key}
              {:cont, {:ok, Map.put(line_folded, path, raw)}}

            {:error, reason} ->
              {:halt, {:error, exposure_evidence(reason, line.wire_subsystem, 0)}}
          end
        end)

      case line_result do
        {:ok, line_folded} -> {:cont, {:ok, line_folded}}
        {:error, _evidence} = error -> {:halt, error}
      end
    end)
  end

  defp typed_operations(entries, folded) do
    Enum.reduce_while(entries, {:ok, []}, fn entry, {:ok, operations} ->
      path = {entry.core_subsystem, entry.core_key}

      case Map.fetch(folded, path) do
        {:ok, raw} ->
          case Schema.parse(entry.core_subsystem, entry.core_key, raw) do
            {:ok, value} ->
              operation = {entry.core_subsystem, {:set, entry.core_key, value}}
              {:cont, {:ok, [operation | operations]}}

            {:error, _reason} ->
              key_count = count_seen_for_subsystem(folded, entry.core_subsystem)

              {:halt,
               {:error, evidence(:config_bad_json, :type, entry.wire_subsystem, key_count)}}
          end

        :error ->
          operation = {entry.core_subsystem, {:reset, entry.core_key}}
          {:cont, {:ok, [operation | operations]}}
      end
    end)
    |> reverse_operations()
  end

  defp group_operations(operations) do
    subsystems =
      operations
      |> Enum.map(&elem(&1, 0))
      |> Enum.uniq()
      |> Enum.sort_by(&Atom.to_string/1)

    Enum.map(subsystems, fn subsystem ->
      subsystem_operations =
        for {^subsystem, operation} <- operations do
          operation
        end

      {subsystem, subsystem_operations}
    end)
  end

  defp reverse_operations({:ok, operations}), do: {:ok, Enum.reverse(operations)}
  defp reverse_operations({:error, reason}), do: {:error, reason}

  defp count_seen_for_subsystem(folded, subsystem) do
    Enum.count(folded, fn {{candidate, _key}, _raw} -> candidate == subsystem end)
  end

  defp preflight_exposure(plaintext, entries) do
    plaintext
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == "" or String.starts_with?(&1, "#")))
    |> Enum.reduce_while(:ok, fn line, :ok ->
      case preflight_line(line, entries) do
        :ok -> {:cont, :ok}
        {:error, _evidence} = error -> {:halt, error}
      end
    end)
  end

  defp preflight_line(line, entries) do
    case String.split(line, ~r/\s+/u, parts: 2) do
      [wire_subsystem] -> preflight_fields(wire_subsystem, "", entries)
      [wire_subsystem, fields] -> preflight_fields(wire_subsystem, fields, entries)
    end
  end

  defp preflight_fields(wire_subsystem, fields, entries) do
    cond do
      String.contains?(wire_subsystem, ":") ->
        {:error, evidence(:invalid_argument, :exposure, "unknown", 0)}

      sensitive_identifier?(wire_subsystem) ->
        {:error, evidence(:access_denied, :exposure, "unknown", 0)}

      true ->
        case Registry.classify_subsystem(wire_subsystem) do
          {:ok, _subsystem} ->
            preflight_public_fields(wire_subsystem, fields, entries)

          {:error, :forbidden} ->
            {:error, evidence(:access_denied, :exposure, "unknown", 0)}

          {:error, :unknown_subsystem} ->
            preflight_unknown_subsystem(wire_subsystem, fields)
        end
    end
  end

  defp preflight_public_fields(wire_subsystem, fields, entries) do
    markers = registered_markers(wire_subsystem, fields, entries)
    key_count = length(markers)

    if classify_identifiers(wire_subsystem, field_identifiers(fields)) == :access_denied do
      {:error, evidence(:access_denied, :exposure, "unknown", key_count)}
    else
      case markers do
        [] ->
          {:error, evidence(:config_generic, :exposure, wire_subsystem, 0)}

        [{0, _entry} | _rest] ->
          :ok

        [{first_index, _entry} | _rest] ->
          prefix = binary_part(fields, 0, first_index)

          case classify_identifiers(wire_subsystem, field_identifiers(prefix)) do
            :access_denied ->
              {:error, evidence(:access_denied, :exposure, "unknown", key_count)}

            _other ->
              {:error, evidence(:config_bad_json, :exposure, wire_subsystem, key_count)}
          end
      end
    end
  end

  defp preflight_unknown_subsystem(wire_subsystem, fields) do
    classification = classify_identifiers(wire_subsystem, field_identifiers(fields))

    cond do
      classification == :access_denied ->
        {:error, evidence(:access_denied, :exposure, "unknown", 0)}

      classification == :unknown and safe_identifier?(wire_subsystem) ->
        {:error, evidence(:config_generic, :exposure, wire_subsystem, 0)}

      true ->
        {:error, evidence(:config_generic, :exposure, "unknown", 0)}
    end
  end

  defp registered_markers(wire_subsystem, fields, entries) do
    entries
    |> Enum.filter(&(&1.wire_subsystem == wire_subsystem))
    |> Enum.reduce([], fn entry, found ->
      case :binary.match(fields, entry.wire_key <> "=") do
        :nomatch -> found
        {index, _length} -> [{index, entry} | found]
      end
    end)
    |> Enum.sort_by(&elem(&1, 0))
  end

  defp field_identifiers(fields) do
    ~r/(?:^|\s)([^\s=]+)=/u
    |> Regex.scan(fields, capture: :all_but_first)
    |> List.flatten()
  end

  defp classify_identifiers(wire_subsystem, wire_keys) do
    Enum.reduce_while(wire_keys, :unknown, fn wire_key, classification ->
      cond do
        sensitive_identifier?(wire_key) ->
          {:halt, :access_denied}

        true ->
          case Registry.classify_path(wire_subsystem, wire_key) do
            {:error, :forbidden} -> {:halt, :access_denied}
            {:error, :wire_hidden} -> {:cont, :hidden}
            {:error, :unknown_key} -> {:cont, classification}
            {:ok, _entry} -> {:cont, preserve_hidden(classification, :public)}
          end
      end
    end)
  end

  defp preserve_hidden(:hidden, _classification), do: :hidden
  defp preserve_hidden(_previous, classification), do: classification

  defp exposure_evidence(:forbidden, subsystem, key_count),
    do: evidence(:access_denied, :exposure, safe_public_subsystem(subsystem), key_count)

  defp exposure_evidence(:wire_hidden, _subsystem, key_count),
    do: evidence(:config_generic, :exposure, "unknown", key_count)

  defp exposure_evidence(_reason, subsystem, key_count),
    do: evidence(:config_generic, :exposure, safe_public_subsystem(subsystem), key_count)

  defp mutation_evidence({:forbidden_config_key, subsystem, _key}),
    do: evidence(:access_denied, :exposure, safe_core_subsystem(subsystem), 0)

  defp mutation_evidence({:unknown_config_key, subsystem, _key}),
    do: evidence(:config_generic, :exposure, safe_core_subsystem(subsystem), 0)

  defp mutation_evidence({:invalid_config_value, subsystem, _key, _reason}),
    do: evidence(:config_bad_json, :type, safe_core_subsystem(subsystem), 1)

  defp mutation_evidence({:invalid_config_source, _source}),
    do: evidence(:invalid_argument, :parser, "unknown", 0)

  defp mutation_evidence({:config_store_unavailable, reason}) when is_atom(reason),
    do: database_evidence(reason)

  defp mutation_evidence(_reason), do: database_evidence(:mutation_failed)

  defp database_evidence(reason) when is_atom(reason),
    do: evidence({:config_store_unavailable, reason}, :database, "unknown", 0)

  defp database_evidence(_reason), do: database_evidence(:operation_failed)

  defp validate_source(opts) do
    case Keyword.get(opts, :source) do
      source when is_binary(source) -> :ok
      _other -> {:error, evidence(:invalid_argument, :parser, "unknown", 0)}
    end
  end

  defp config_facade(opts) do
    if @test_config_injection do
      Keyword.get(opts, :config, Config)
    else
      Config
    end
  end

  defp safe_public_subsystem(subsystem) when is_binary(subsystem) do
    case Registry.classify_subsystem(subsystem) do
      {:ok, _entry} -> subsystem
      _other -> "unknown"
    end
  end

  defp safe_public_subsystem(_subsystem), do: "unknown"

  defp safe_core_subsystem(subsystem) when is_atom(subsystem) do
    subsystem
    |> Atom.to_string()
    |> safe_public_subsystem()
  end

  defp safe_core_subsystem(_subsystem), do: "unknown"

  defp sensitive_identifier?(identifier) when is_binary(identifier),
    do: Regex.match?(@sensitive_marker, identifier)

  defp safe_identifier?(identifier) when is_binary(identifier),
    do: Regex.match?(@safe_identifier, identifier) and not sensitive_identifier?(identifier)

  defp evidence(reason, stage, subsystem, key_count) do
    %{reason: reason, stage: stage, subsystem: subsystem, key_count: max(key_count, 0)}
  end
end
