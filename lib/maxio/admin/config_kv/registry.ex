defmodule Maxio.Admin.ConfigKV.Registry do
  @moduledoc false

  alias Maxio.Config.Schema

  @subsystems [
    %{
      wire_subsystem: "s3",
      description: "Maxio extension: configure s3.clock_skew_ms.",
      multiple_targets?: false,
      order: 0,
      entries: [
        %{
          wire_subsystem: "s3",
          wire_key: "clock_skew_ms",
          core_subsystem: :s3,
          core_key: :clock_skew_ms,
          description:
            "Maximum allowed SigV4 header-signature clock skew in milliseconds; applied to the next authentication request.",
          optional?: true,
          multiple_targets?: false,
          sensitive?: false,
          order: 0
        }
      ]
    },
    %{
      wire_subsystem: "listing",
      description: "Maxio extension: configure listing.sql_hard_limit.",
      multiple_targets?: false,
      order: 1,
      entries: [
        %{
          wire_subsystem: "listing",
          wire_key: "sql_hard_limit",
          core_subsystem: :listing,
          core_key: :sql_hard_limit,
          description:
            "Hard upper bound on rows fetched by one SQL-backed listing operation; applied to the next listing request.",
          optional?: true,
          multiple_targets?: false,
          sensitive?: false,
          order: 0
        }
      ]
    },
    %{
      wire_subsystem: "prometheus_metrics",
      description: "Maxio extension: configure prometheus_metrics.public.",
      multiple_targets?: false,
      order: 2,
      entries: [
        %{
          wire_subsystem: "prometheus_metrics",
          wire_key: "public",
          core_subsystem: :prometheus_metrics,
          core_key: :public,
          description:
            "Allow unauthenticated access to the Prometheus metrics endpoint; enable only behind a trusted network or proxy.",
          optional?: true,
          multiple_targets?: false,
          sensitive?: false,
          order: 0
        }
      ]
    }
  ]

  @entries (for subsystem <- @subsystems, entry <- subsystem.entries do
              Map.take(entry, [
                :wire_subsystem,
                :wire_key,
                :core_subsystem,
                :core_key,
                :sensitive?,
                :order
              ])
            end)

  @wire_hidden_paths MapSet.new([{"cluster", "deployment_id"}])

  @spec entries() :: [map()]
  def entries, do: @entries

  @spec public_paths() :: [{atom(), atom()}]
  def public_paths do
    case public_paths(@entries) do
      {:ok, paths} -> paths
      {:error, reason} -> raise "unsafe public config registry: #{reason}"
    end
  end

  @doc false
  @spec public_paths([map()]) :: {:ok, [{atom(), atom()}]} | {:error, atom()}
  def public_paths(entries) when is_list(entries) do
    entries
    |> Enum.reduce_while({:ok, [], MapSet.new(), MapSet.new()}, &collect_public_path/2)
    |> finish_public_paths(entries)
  end

  def public_paths(_entries), do: {:error, :registry_drift}

  @spec subsystems() :: [map()]
  def subsystems, do: @subsystems

  @spec classify_subsystem(String.t()) ::
          {:ok, map()} | {:error, :forbidden | :unknown_subsystem}
  def classify_subsystem(wire_subsystem) when is_binary(wire_subsystem) do
    cond do
      MapSet.member?(forbidden_subsystems(), wire_subsystem) ->
        {:error, :forbidden}

      subsystem = Enum.find(@subsystems, &(&1.wire_subsystem == wire_subsystem)) ->
        {:ok, subsystem}

      true ->
        {:error, :unknown_subsystem}
    end
  end

  @spec exposed_subsystem(String.t()) :: {:ok, [map()]} | {:error, :unknown_subsystem}
  def exposed_subsystem(wire_subsystem) when is_binary(wire_subsystem) do
    case Enum.filter(@entries, &(&1.wire_subsystem == wire_subsystem)) do
      [] -> {:error, :unknown_subsystem}
      entries -> {:ok, entries}
    end
  end

  @spec classify_path(String.t(), String.t()) :: {:ok, map()} | {:error, atom()}
  def classify_path(wire_subsystem, wire_key)
      when is_binary(wire_subsystem) and is_binary(wire_key) do
    cond do
      MapSet.member?(forbidden_subsystems(), wire_subsystem) ->
        {:error, :forbidden}

      MapSet.member?(forbidden_paths(), {wire_subsystem, wire_key}) ->
        {:error, :forbidden}

      MapSet.member?(@wire_hidden_paths, {wire_subsystem, wire_key}) ->
        {:error, :wire_hidden}

      entry =
          Enum.find_value(@subsystems, fn subsystem ->
            Enum.find(subsystem.entries, fn entry ->
              entry.wire_subsystem == wire_subsystem and entry.wire_key == wire_key
            end)
          end) ->
        {:ok, entry}

      true ->
        {:error, :unknown_key}
    end
  end

  defp forbidden_subsystems do
    Schema.forbidden_subsystems()
    |> MapSet.new(&Atom.to_string/1)
  end

  defp forbidden_paths do
    Schema.forbidden_keys()
    |> MapSet.new(fn {subsystem, key} -> {Atom.to_string(subsystem), Atom.to_string(key)} end)
  end

  defp collect_public_path(entry, {:ok, paths, core_seen, wire_seen}) when is_map(entry) do
    with false <- Map.get(entry, :sensitive?, true),
         wire_subsystem when is_binary(wire_subsystem) <- Map.get(entry, :wire_subsystem),
         wire_key when is_binary(wire_key) <- Map.get(entry, :wire_key),
         core_subsystem when is_atom(core_subsystem) <- Map.get(entry, :core_subsystem),
         core_key when is_atom(core_key) <- Map.get(entry, :core_key),
         false <- MapSet.member?(core_seen, {core_subsystem, core_key}),
         false <- MapSet.member?(wire_seen, {wire_subsystem, wire_key}),
         {:ok, canonical} <- classify_path(wire_subsystem, wire_key),
         true <- archive_entry(canonical) == archive_entry(entry) do
      {:cont,
       {:ok, [{core_subsystem, core_key} | paths],
        MapSet.put(core_seen, {core_subsystem, core_key}),
        MapSet.put(wire_seen, {wire_subsystem, wire_key})}}
    else
      true -> {:halt, {:error, :duplicate_public_path}}
      {:error, :forbidden} -> {:halt, {:error, :forbidden_public_path}}
      {:error, :wire_hidden} -> {:halt, {:error, :hidden_public_path}}
      {:error, :unknown_key} -> {:halt, {:error, :unknown_public_path}}
      _other -> {:halt, {:error, :registry_drift}}
    end
  end

  defp collect_public_path(_entry, _acc), do: {:halt, {:error, :registry_drift}}

  defp finish_public_paths({:ok, paths, _core_seen, _wire_seen}, entries) do
    if entries == @entries do
      {:ok, Enum.reverse(paths)}
    else
      {:error, :registry_drift}
    end
  end

  defp finish_public_paths({:error, reason}, _entries), do: {:error, reason}

  defp archive_entry(entry) do
    Map.take(entry, [
      :wire_subsystem,
      :wire_key,
      :core_subsystem,
      :core_key,
      :sensitive?,
      :order
    ])
  end
end
