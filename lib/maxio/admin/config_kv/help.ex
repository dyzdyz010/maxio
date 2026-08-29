defmodule Maxio.Admin.ConfigKV.Help do
  @moduledoc false

  alias Maxio.Admin.ConfigKV.Registry
  alias Maxio.Config.Schema

  @safe_identifier ~r/\A[A-Za-z0-9][A-Za-z0-9_.:-]{0,127}\z/
  @sensitive_marker ~r/(?:secret|password|token|credential|access[_-]?key|private|cipher|plaintext|root[_-]?user)/i

  @spec project(String.t(), String.t(), boolean()) :: {:ok, map()} | {:error, map()}
  def project(sub_sys, key, env_only?)
      when is_binary(sub_sys) and is_binary(key) and is_boolean(env_only?) do
    cond do
      sub_sys == "" -> project_catalog(env_only?)
      String.contains?(sub_sys, ":") -> error(:invalid_argument, sub_sys, :parser)
      key == "" -> project_subsystem(sub_sys, env_only?)
      true -> project_key(sub_sys, key, env_only?)
    end
  end

  @spec encode_line(Jason.OrderedObject.t()) :: iodata()
  def encode_line(%Jason.OrderedObject{} = wire), do: [Jason.encode_to_iodata!(wire), "\n"]

  @spec describe_error(term()) :: String.t()
  def describe_error(:invalid_argument), do: "configuration help request is invalid"
  def describe_error(:access_denied), do: "configuration help path is not exposed"
  def describe_error(:config_generic), do: "configuration help entry was not found"

  def describe_error({:config_generic, _description}),
    do: "configuration help entry was not found"

  def describe_error(_reason), do: "configuration help failed"

  defp project_catalog(env_only?) do
    keys_help =
      Registry.subsystems()
      |> Enum.filter(&public_subsystem?/1)
      |> Enum.map(&catalog_wire/1)

    success(help_wire("", "", keys_help), "all", :catalog, env_only?, length(keys_help))
  end

  defp project_subsystem(sub_sys, env_only?) do
    case Registry.classify_subsystem(sub_sys) do
      {:ok, subsystem} ->
        keys_help =
          subsystem.entries
          |> Enum.filter(&public_entry?/1)
          |> Enum.filter(&(not env_only? or bound_to_env?(&1)))
          |> Enum.map(&entry_wire(&1, env_only?))

        success(
          help_wire(subsystem.wire_subsystem, subsystem.description, keys_help),
          subsystem.wire_subsystem,
          :subsystem,
          env_only?,
          length(keys_help)
        )

      {:error, :forbidden} ->
        error(:access_denied, "unknown", :exposure)

      {:error, :unknown_subsystem} ->
        unknown_subsystem_error(sub_sys)
    end
  end

  defp project_key(sub_sys, key, env_only?) do
    case Registry.classify_subsystem(sub_sys) do
      {:ok, subsystem} -> project_known_subsystem_key(subsystem, key, env_only?)
      {:error, :forbidden} -> error(:access_denied, "unknown", :exposure)
      {:error, :unknown_subsystem} -> project_unknown_subsystem_key(sub_sys, key)
    end
  end

  defp project_known_subsystem_key(subsystem, key, env_only?) do
    sub_sys = subsystem.wire_subsystem

    case Registry.classify_path(sub_sys, key) do
      {:ok, entry} -> project_exposed_key(subsystem, entry, key, env_only?)
      {:error, :forbidden} -> forbidden_error(sub_sys)
      {:error, :wire_hidden} -> error(:config_generic, sub_sys, :exposure)
      {:error, :unknown_key} -> unknown_key_error(sub_sys, key)
    end
  end

  defp project_unknown_subsystem_key(sub_sys, key) do
    case Registry.classify_path(sub_sys, key) do
      {:error, :forbidden} -> forbidden_error(sub_sys)
      {:error, :wire_hidden} -> error(:config_generic, sub_sys, :exposure)
      _other -> unknown_subsystem_error(sub_sys)
    end
  end

  defp project_exposed_key(subsystem, entry, key, env_only?) do
    cond do
      not public_entry?(entry) ->
        error(:config_generic, subsystem.wire_subsystem, :exposure)

      env_only? and not bound_to_env?(entry) ->
        unknown_key_error(subsystem.wire_subsystem, key)

      true ->
        keys_help = [entry_wire(entry, env_only?)]

        success(
          help_wire(subsystem.wire_subsystem, subsystem.description, keys_help),
          subsystem.wire_subsystem,
          :key,
          env_only?,
          1
        )
    end
  end

  defp catalog_wire(subsystem) do
    Jason.OrderedObject.new(
      key: subsystem.wire_subsystem,
      description: subsystem.description,
      optional: false,
      type: "",
      multipleTargets: subsystem.multiple_targets?
    )
  end

  defp entry_wire(entry, env_only?) do
    {:ok, schema_entry} = Schema.fetch(entry.core_subsystem, entry.core_key)

    wire_key =
      if env_only?,
        do: Schema.env_var(entry.core_subsystem, entry.core_key),
        else: entry.wire_key

    Jason.OrderedObject.new(
      key: wire_key,
      description: entry.description,
      optional: entry.optional?,
      type: Schema.describe_type(schema_entry.type),
      multipleTargets: entry.multiple_targets?
    )
  end

  defp help_wire(sub_sys, description, keys_help) do
    Jason.OrderedObject.new(
      subSys: sub_sys,
      description: description,
      multipleTargets: false,
      keysHelp: keys_help
    )
  end

  defp success(wire, subsystem, scope, env_only?, key_count) do
    {:ok,
     %{
       wire: wire,
       subsystem: subsystem,
       key_count: key_count,
       scope: scope,
       env_only?: env_only?
     }}
  end

  defp unknown_subsystem_error(sub_sys) do
    if safe_identifier?(sub_sys) do
      error({:config_generic, "unknown sub-system #{sub_sys}"}, sub_sys, :exposure)
    else
      error(:config_generic, sub_sys, :exposure)
    end
  end

  defp unknown_key_error(sub_sys, key) do
    if safe_identifier?(sub_sys) and safe_identifier?(key) do
      error(
        {:config_generic, "unknown key #{key} for sub-system #{sub_sys}"},
        sub_sys,
        :exposure
      )
    else
      error(:config_generic, sub_sys, :exposure)
    end
  end

  defp error(reason, sub_sys, stage) do
    {:error,
     %{
       reason: reason,
       subsystem: safe_subsystem(sub_sys),
       key_count: 0,
       stage: stage
     }}
  end

  defp forbidden_error(sub_sys) do
    case Registry.classify_subsystem(sub_sys) do
      {:error, :forbidden} -> error(:access_denied, "unknown", :exposure)
      _other -> error(:access_denied, sub_sys, :exposure)
    end
  end

  defp public_subsystem?(subsystem), do: Enum.any?(subsystem.entries, &public_entry?/1)
  defp public_entry?(entry), do: not entry.sensitive?

  defp bound_to_env?(entry),
    do: not is_nil(Schema.env_var(entry.core_subsystem, entry.core_key))

  defp safe_subsystem(sub_sys) do
    base_subsystem = sub_sys |> String.split(":", parts: 2) |> hd()
    if safe_identifier?(base_subsystem), do: base_subsystem, else: "unknown"
  end

  defp safe_identifier?(value) when is_binary(value) do
    Regex.match?(@safe_identifier, value) and not Regex.match?(@sensitive_marker, value)
  end
end
