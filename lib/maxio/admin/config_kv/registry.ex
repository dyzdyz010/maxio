defmodule Maxio.Admin.ConfigKV.Registry do
  @moduledoc false

  @entries [
    %{
      wire_subsystem: "s3",
      wire_key: "clock_skew_ms",
      core_subsystem: :s3,
      core_key: :clock_skew_ms,
      sensitive?: false,
      order: 0
    },
    %{
      wire_subsystem: "listing",
      wire_key: "sql_hard_limit",
      core_subsystem: :listing,
      core_key: :sql_hard_limit,
      sensitive?: false,
      order: 0
    },
    %{
      wire_subsystem: "prometheus_metrics",
      wire_key: "public",
      core_subsystem: :prometheus_metrics,
      core_key: :public,
      sensitive?: false,
      order: 0
    }
  ]

  @wire_hidden_paths MapSet.new([{"cluster", "deployment_id"}])

  @forbidden_subsystems MapSet.new([
                          "storage_backend",
                          "credential_store",
                          "policy_store",
                          "mfa_delete_verifier",
                          "shard_transport",
                          "authoritative_source",
                          "topology_source",
                          "read_prefer_index",
                          "dev_routes",
                          "Elixir.Maxio.Repo"
                        ])

  @forbidden_paths MapSet.new([
                     {"sse", "master_key"},
                     {"kms", "master_key"},
                     {"kms", "provider"},
                     {"access_key_secret", "secret_key"},
                     {"access_key_secret", "keyring"},
                     {"access_key_secret", "keyring_file"},
                     {"mfa", "secret_key"},
                     {"s3", "root_user"},
                     {"s3", "root_password"},
                     {"erasure", "drives"},
                     {"erasure", "data_shards"},
                     {"erasure", "parity_shards"}
                   ])

  @spec entries() :: [map()]
  def entries, do: @entries

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
      MapSet.member?(@forbidden_subsystems, wire_subsystem) ->
        {:error, :forbidden}

      MapSet.member?(@forbidden_paths, {wire_subsystem, wire_key}) ->
        {:error, :forbidden}

      MapSet.member?(@wire_hidden_paths, {wire_subsystem, wire_key}) ->
        {:error, :wire_hidden}

      entry =
          Enum.find(@entries, fn entry ->
            entry.wire_subsystem == wire_subsystem and entry.wire_key == wire_key
          end) ->
        {:ok, entry}

      true ->
        {:error, :unknown_key}
    end
  end
end
