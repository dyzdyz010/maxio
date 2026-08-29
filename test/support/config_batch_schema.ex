defmodule Maxio.Test.ConfigBatchSchema do
  @moduledoc false

  @entries %{
    {:batch_alpha, :shared} => %{
      type: {:integer, 0, 10_000},
      apply: :hot,
      env_var: nil,
      doc: "Coordinator-only same-name fixture key in the alpha subsystem."
    },
    {:batch_fixture, :left} => %{
      type: {:integer, 0, 10_000},
      apply: :hot,
      env_var: nil,
      doc: "Coordinator-only left fixture key."
    },
    {:batch_fixture, :right} => %{
      type: {:integer, 0, 10_000},
      apply: :hot,
      env_var: nil,
      doc: "Coordinator-only right fixture key."
    },
    {:batch_omega, :shared} => %{
      type: {:integer, 0, 10_000},
      apply: :hot,
      env_var: nil,
      doc: "Coordinator-only same-name fixture key in the omega subsystem."
    }
  }

  def entries, do: @entries

  def keys do
    @entries
    |> Map.keys()
    |> Enum.sort_by(fn {subsystem, key} -> {to_string(subsystem), to_string(key)} end)
  end

  def fetch(subsystem, key) do
    case Map.fetch(@entries, {subsystem, key}) do
      {:ok, entry} -> {:ok, entry}
      :error -> {:error, {:unknown_config_key, subsystem, key}}
    end
  end

  def fetch!(subsystem, key) do
    case fetch(subsystem, key) do
      {:ok, entry} -> entry
      {:error, reason} -> raise ArgumentError, "batch fixture lookup failed: #{inspect(reason)}"
    end
  end

  def apply_mode(subsystem, key), do: fetch!(subsystem, key).apply
  def env_var(_subsystem, _key), do: nil

  def cast(subsystem, key, value) do
    with {:ok, _entry} <- fetch(subsystem, key) do
      if is_integer(value) and value >= 0 and value <= 10_000 do
        {:ok, value}
      else
        {:error,
         {:invalid_config_value, subsystem, key,
          "expected integer in 0..10000, got: #{inspect(value)}"}}
      end
    end
  end

  def encode_stored(value), do: %{"v" => value}

  def decode_stored(subsystem, key, %{"v" => value}) do
    case cast(subsystem, key, value) do
      {:ok, casted} -> {:ok, casted}
      {:error, {:invalid_config_value, _subsystem, _key, reason}} -> {:error, reason}
      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  def decode_stored(_subsystem, _key, other),
    do: {:error, "stored batch fixture value is malformed: #{inspect(other)}"}

  # Coordinator postcommit dependencies are inert for synthetic rows: production Store cannot
  # decode test-only keys, and these callbacks are never assertions or behavior under test.
  def load_all!(_opts \\ []),
    do: %{aggregate: "batch-fixture", orphan_config_keys: [], subsystems: 3}

  def broadcast(_event), do: :ok
  def broadcast_checked(_event), do: :ok
end
