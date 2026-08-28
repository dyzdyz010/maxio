defmodule Maxio.Admin.ConfigKV.Adapter do
  @moduledoc false

  alias Maxio.Admin.ConfigKV.{Parser, Registry}
  alias Maxio.Config
  alias Maxio.Config.Schema

  @error_evidence_option :return_error_evidence
  @safe_identifier ~r/\A[a-z0-9][a-z0-9_.:-]{0,127}\z/
  @safe_command ~r/\A[a-z0-9][a-z0-9_.-]{0,63}(?: [a-z0-9][a-z0-9_.-]{0,63}(?:=[A-Za-z0-9_.:+\/-]{0,128})?)*\z/
  @sensitive_marker ~r/(?:secret|password|token|credential|access[_-]?key|private|cipher|plaintext|root[_-]?user)/i

  @type adapter_reason ::
          :access_denied
          | :config_bad_json
          | :config_generic
          | :config_not_found
          | :invalid_argument
          | {:config_store_unavailable, atom()}

  @type reason ::
          adapter_reason()
          | {:config_generic, String.t()}
          | {:config_not_found, String.t()}

  @type error_evidence :: %{
          required(:reason) => reason(),
          required(:subsystem) => String.t(),
          required(:key_count) => non_neg_integer(),
          required(:stage) => :parser | :exposure | :type | :database
        }

  @type error_result :: {:error, adapter_reason()} | {:error, error_evidence()}

  @spec get(String.t(), keyword()) ::
          {:ok, %{plaintext: iodata(), subsystem: atom(), keys: [atom()]}}
          | error_result()
  def get(wire_subsystem, opts \\ [])

  def get(wire_subsystem, opts) when is_binary(wire_subsystem) and is_list(opts) do
    wire_subsystem
    |> do_get(Keyword.delete(opts, @error_evidence_option))
    |> finalize_result(opts)
  end

  def get(_wire_subsystem, _opts), do: {:error, :invalid_argument}

  defp do_get(wire_subsystem, opts) do
    with :ok <- reject_target(wire_subsystem),
         :ok <- reject_forbidden_subsystem(wire_subsystem),
         {:ok, entries} <- exposed_subsystem(wire_subsystem) do
      core_subsystem = hd(entries).core_subsystem
      keys = Enum.map(entries, & &1.core_key)
      context = evidence_context(wire_subsystem, length(keys))

      case Config.authoritative_effective(core_subsystem, keys, opts) do
        {:ok, effective} ->
          values = project_redacted(entries, effective)

          {:ok,
           %{
             plaintext: Parser.render(wire_subsystem, values),
             subsystem: core_subsystem,
             keys: keys
           }}

        {:error, reason} ->
          adapter_error(reason, reason, context, :database)
      end
    else
      {:error, :invalid_argument} ->
        adapter_error(
          :invalid_argument,
          :invalid_argument,
          evidence_context("unknown", 0),
          :parser
        )

      {:error, :access_denied} ->
        adapter_error(
          :access_denied,
          :access_denied,
          evidence_context(wire_subsystem, 0),
          :exposure
        )

      {:error, :config_generic} ->
        adapter_error(
          :config_generic,
          generic_public_reason(:get, wire_subsystem, wire_subsystem),
          evidence_context(wire_subsystem, 0),
          :exposure
        )
    end
  end

  @spec set(String.t(), keyword()) :: {:ok, map()} | error_result()
  def set(plaintext, opts \\ [])

  def set(plaintext, opts) when is_binary(plaintext) and is_list(opts) do
    plaintext
    |> do_set(Keyword.delete(opts, @error_evidence_option))
    |> finalize_result(opts)
  end

  def set(_plaintext, _opts), do: {:error, :invalid_argument}

  @spec reset(String.t(), keyword()) :: {:ok, map()} | error_result()
  def reset(plaintext, opts \\ [])

  def reset(plaintext, opts) when is_binary(plaintext) and is_list(opts) do
    plaintext
    |> do_reset(Keyword.delete(opts, @error_evidence_option))
    |> finalize_result(opts)
  end

  def reset(_plaintext, _opts), do: {:error, :invalid_argument}

  defp do_set(plaintext, opts) do
    if String.valid?(plaintext) do
      parsed = Parser.parse_set_detailed(plaintext, Registry.entries())
      context = set_evidence_context(plaintext, parsed)

      case parsed do
        {:error, :cross_subsystem} ->
          adapter_error(:config_bad_json, :config_bad_json, context, :parser)

        parsed ->
          with :ok <- preflight_set(plaintext) do
            continue_set(parsed, plaintext, context, opts)
          else
            {:error, reason} ->
              adapter_error(
                reason,
                public_reason(reason, :set, plaintext, context.subsystem),
                context,
                :exposure
              )
          end
      end
    else
      adapter_error(
        :config_bad_json,
        :config_bad_json,
        evidence_context("unknown", 0),
        :parser
      )
    end
  end

  defp continue_set({:ok, parsed}, plaintext, context, opts) do
    with {:ok, entries} <- exposed_subsystem(parsed.wire_subsystem),
         {:ok, operations} <- set_operations(entries, parsed.patches) do
      entries
      |> hd()
      |> Map.fetch!(:core_subsystem)
      |> mutate(operations, opts)
      |> mutation_result(context)
    else
      {:error, :config_generic} ->
        adapter_error(
          :config_generic,
          generic_public_reason(:set, plaintext, context.subsystem),
          context,
          :exposure
        )

      {:error, :config_bad_json} ->
        adapter_error(:config_bad_json, :config_bad_json, context, :type)
    end
  end

  defp continue_set({:error, :unknown_key}, plaintext, context, _opts) do
    adapter_error(
      :config_generic,
      generic_public_reason(:set, plaintext, context.subsystem),
      context,
      :exposure
    )
  end

  defp continue_set({:error, reason}, _plaintext, context, _opts)
       when reason in [:bad_json, :invalid_argument] do
    public_reason = if reason == :invalid_argument, do: :invalid_argument, else: :config_bad_json
    adapter_error(public_reason, public_reason, context, :parser)
  end

  defp continue_set({:error, _reason}, _plaintext, context, _opts) do
    adapter_error(:config_generic, :config_generic, context, :exposure)
  end

  defp do_reset(plaintext, opts) do
    if String.valid?(plaintext) do
      parsed = Parser.parse_reset_detailed(plaintext)
      context = reset_evidence_context(plaintext, parsed)

      case parsed do
        {:error, :cross_subsystem} ->
          adapter_error(:config_bad_json, :config_bad_json, context, :parser)

        parsed ->
          with :ok <- preflight_reset(plaintext) do
            continue_reset(parsed, plaintext, context, opts)
          else
            {:error, reason} ->
              adapter_error(
                reason,
                public_reason(reason, :reset, plaintext, context.subsystem),
                context,
                :exposure
              )
          end
      end
    else
      adapter_error(
        :config_bad_json,
        :config_bad_json,
        evidence_context("unknown", 0),
        :parser
      )
    end
  end

  defp continue_reset({:ok, parsed}, plaintext, context, opts) do
    with {:ok, entries} <- exposed_subsystem(parsed.wire_subsystem),
         {:ok, operations} <- reset_operations(entries, parsed.reset) do
      entries
      |> hd()
      |> Map.fetch!(:core_subsystem)
      |> mutate(operations, opts)
      |> mutation_result(context)
    else
      {:error, :config_generic} ->
        adapter_error(
          :config_generic,
          generic_public_reason(:reset, plaintext, context.subsystem),
          context,
          :exposure
        )

      {:error, {:reset_key, :forbidden, _wire_key, _index}} ->
        adapter_error(:access_denied, :access_denied, context, :exposure)

      {:error, {:reset_key, :wire_hidden, _wire_key, _index}} ->
        adapter_error(
          :config_generic,
          generic_public_reason(:reset, plaintext, context.subsystem),
          context,
          :exposure
        )

      {:error, {:reset_key, :unknown_key, wire_key, _index}} ->
        description = safe_not_found_reason(wire_key)
        adapter_error(:config_not_found, description, context, :exposure)
    end
  end

  defp continue_reset({:error, :unknown_key}, plaintext, context, _opts) do
    adapter_error(
      :config_generic,
      generic_public_reason(:reset, plaintext, context.subsystem),
      context,
      :exposure
    )
  end

  defp continue_reset({:error, reason}, _plaintext, context, _opts)
       when reason in [:bad_json, :invalid_argument] do
    public_reason = if reason == :invalid_argument, do: :invalid_argument, else: :config_bad_json
    adapter_error(public_reason, public_reason, context, :parser)
  end

  defp continue_reset({:error, _reason}, _plaintext, context, _opts) do
    adapter_error(:config_generic, :config_generic, context, :exposure)
  end

  @spec describe_error(term()) :: String.t()
  def describe_error(%{reason: reason}), do: describe_error(reason)
  def describe_error(:access_denied), do: "access denied"
  def describe_error(:config_bad_json), do: "configuration has incorrect format"
  def describe_error(:config_generic), do: "configuration request is invalid"
  def describe_error({:config_generic, _safe_description}), do: "configuration request is invalid"
  def describe_error(:config_not_found), do: "configuration key was not found"

  def describe_error({:config_not_found, _safe_description}),
    do: "configuration key was not found"

  def describe_error(:invalid_argument), do: "invalid argument"

  def describe_error({:config_store_unavailable, _safe_reason}),
    do: "configuration store is unavailable"

  def describe_error(_reason), do: "configuration operation failed"

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
    wire_keys
    |> Enum.with_index()
    |> Enum.reduce_while(:ok, fn {wire_key, index}, :ok ->
      case Registry.classify_path(wire_subsystem, wire_key) do
        {:ok, _entry} ->
          {:cont, :ok}

        {:error, reason} when reason in [:forbidden, :wire_hidden, :unknown_key] ->
          {:halt, {:error, {:reset_key, reason, wire_key, index}}}
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

  defp mutation_result({:ok, _mutation} = success, _context), do: success

  defp mutation_result({:error, reason}, context) do
    adapter_error(reason, reason, context, mutation_failure_stage(reason))
  end

  defp mutation_failure_stage(:access_denied), do: :exposure
  defp mutation_failure_stage(:config_generic), do: :exposure
  defp mutation_failure_stage(:config_not_found), do: :exposure
  defp mutation_failure_stage(:config_bad_json), do: :type
  defp mutation_failure_stage(:invalid_argument), do: :parser
  defp mutation_failure_stage({:config_store_unavailable, _reason}), do: :database
  defp mutation_failure_stage(_reason), do: :database

  defp adapter_error(adapter_reason, public_reason, context, stage) do
    {:adapter_error, adapter_reason,
     %{
       reason: public_reason,
       subsystem: context.subsystem,
       key_count: context.key_count,
       stage: stage
     }}
  end

  defp finalize_result({:adapter_error, adapter_reason, evidence}, opts) do
    if Keyword.get(opts, @error_evidence_option) == true do
      {:error, evidence}
    else
      {:error, adapter_reason}
    end
  end

  defp finalize_result(result, _opts), do: result

  defp set_evidence_context(_plaintext, {:ok, parsed}) do
    key_count = parsed.patches |> Enum.map(&elem(&1, 0)) |> MapSet.new() |> MapSet.size()
    evidence_context(parsed.wire_subsystem, key_count)
  end

  defp set_evidence_context(plaintext, _parsed), do: command_evidence_context(plaintext, :set)

  defp reset_evidence_context(_plaintext, {:ok, %{reset: :all} = parsed}) do
    key_count =
      case Registry.exposed_subsystem(parsed.wire_subsystem) do
        {:ok, entries} -> length(entries)
        {:error, :unknown_subsystem} -> 0
      end

    evidence_context(parsed.wire_subsystem, key_count)
  end

  defp reset_evidence_context(_plaintext, {:ok, parsed}) do
    key_count = parsed.reset |> MapSet.new() |> MapSet.size()
    evidence_context(parsed.wire_subsystem, key_count)
  end

  defp reset_evidence_context(plaintext, _parsed), do: command_evidence_context(plaintext, :reset)

  defp command_evidence_context(plaintext, operation) do
    subsystem = first_command_subsystem(plaintext)

    key_count =
      case {operation, Registry.exposed_subsystem(subsystem)} do
        {:set, {:ok, entries}} ->
          Enum.count(entries, &String.contains?(plaintext, &1.wire_key <> "="))

        {:reset, {:ok, entries}} ->
          case first_command_tokens(plaintext) do
            [_subsystem] -> length(entries)
            [_subsystem | keys] -> keys |> MapSet.new() |> MapSet.size()
            [] -> 0
          end

        {_operation, {:error, :unknown_subsystem}} ->
          0
      end

    evidence_context(subsystem, key_count)
  end

  defp evidence_context(subsystem, key_count) do
    %{subsystem: safe_config_label(subsystem), key_count: max(key_count, 0)}
  end

  defp public_reason(:config_generic, operation, plaintext, subsystem),
    do: generic_public_reason(operation, plaintext, subsystem)

  defp public_reason(reason, _operation, _plaintext, _subsystem), do: reason

  defp generic_public_reason(:get, wire_subsystem, _subsystem) do
    if wire_subsystem == "" or safe_identifier?(wire_subsystem) do
      {:config_generic, "unknown subsystem: #{wire_subsystem}"}
    else
      :config_generic
    end
  end

  defp generic_public_reason(:set, plaintext, subsystem) do
    case Registry.exposed_subsystem(subsystem) do
      {:ok, _entries} when subsystem != "unknown" ->
        if safe_identifier?(subsystem) do
          {:config_generic, "sub-system '#{subsystem}' cannot have empty keys"}
        else
          :config_generic
        end

      {:error, :unknown_subsystem} ->
        generic_unknown_command_reason(plaintext)
    end
  end

  defp generic_public_reason(operation, plaintext, _subsystem)
       when operation in [:set, :reset] do
    generic_unknown_command_reason(plaintext)
  end

  defp generic_unknown_command_reason(plaintext) do
    command = String.trim(plaintext)

    if safe_command?(command) do
      {:config_generic, "unknown sub-system #{command}"}
    else
      :config_generic
    end
  end

  defp safe_not_found_reason(wire_key) do
    if safe_identifier?(wire_key) do
      {:config_not_found, "key #{wire_key} doesn't exist"}
    else
      :config_not_found
    end
  end

  defp safe_config_label(value) when is_binary(value) do
    if safe_identifier?(value), do: value, else: "unknown"
  end

  defp safe_config_label(_value), do: "unknown"

  defp safe_identifier?(value) when is_binary(value) do
    Regex.match?(@safe_identifier, value) and not Regex.match?(@sensitive_marker, value)
  end

  defp safe_command?(value) when is_binary(value) do
    Regex.match?(@safe_command, value) and not Regex.match?(@sensitive_marker, value)
  end

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

  defp first_command_subsystem(plaintext) do
    case first_command_tokens(plaintext) do
      [subsystem | _keys] -> subsystem
      [] -> "unknown"
    end
  end

  defp first_command_tokens(plaintext) do
    case command_lines(plaintext) do
      [line | _rest] -> String.split(line, ~r/\s+/u)
      [] -> []
    end
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
