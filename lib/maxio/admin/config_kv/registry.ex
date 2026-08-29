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
end
