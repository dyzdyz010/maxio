defmodule Maxio.Test.ConfigKVApplyModeSchema do
  @moduledoc false

  alias Maxio.Config.Schema

  def entries do
    Schema.entries()
    |> Map.update!({:s3, :clock_skew_ms}, &Map.put(&1, :apply, :restart))
    |> Map.update!({:listing, :sql_hard_limit}, &Map.put(&1, :apply, :next_cycle))
  end

  def keys, do: Schema.keys()
  def forbidden_keys, do: Schema.forbidden_keys()
  def forbidden_subsystems, do: Schema.forbidden_subsystems()
  def forbidden?(subsystem, key), do: Schema.forbidden?(subsystem, key)

  def fetch(:s3, :clock_skew_ms) do
    with {:ok, entry} <- Schema.fetch(:s3, :clock_skew_ms) do
      {:ok, Map.put(entry, :apply, :restart)}
    end
  end

  def fetch(:listing, :sql_hard_limit) do
    with {:ok, entry} <- Schema.fetch(:listing, :sql_hard_limit) do
      {:ok, Map.put(entry, :apply, :next_cycle)}
    end
  end

  def fetch(subsystem, key), do: Schema.fetch(subsystem, key)

  def fetch!(subsystem, key) do
    case fetch(subsystem, key) do
      {:ok, entry} -> entry
      {:error, reason} -> raise ArgumentError, "config schema lookup failed: #{inspect(reason)}"
    end
  end

  def apply_mode(subsystem, key), do: fetch!(subsystem, key).apply
  def env_var(subsystem, key), do: Schema.env_var(subsystem, key)
  def cast(subsystem, key, value), do: Schema.cast(subsystem, key, value)
  def encode_stored(value), do: Schema.encode_stored(value)
  def decode_stored(subsystem, key, stored), do: Schema.decode_stored(subsystem, key, stored)
end
