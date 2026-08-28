defmodule Mix.Tasks.Maxio.Admin.Config.Set do
  @shortdoc "Set one Admin Config KVS subsystem patch"
  @moduledoc """
  Applies one Admin Config KVS patch through the same Adapter used by the HTTP surface.

      mix maxio.admin.config.set "s3 clock_skew_ms=900000"
  """

  use Mix.Task

  alias Maxio.Admin.ConfigKV.Adapter
  alias Maxio.Config.CLI

  @usage "usage: mix maxio.admin.config.set <subsystem> <key=value> [key=value ...]"
  @apply_modes [:hot, :next_cycle, :restart]

  @impl true
  def run([]), do: Mix.raise(@usage)

  def run(args) when is_list(args) do
    boot!()
    command = Enum.join(args, " ")
    request_id = Ecto.UUID.generate()

    case Adapter.set(command, source: "cli", request_id: request_id) do
      {:ok, result} -> Mix.shell().info(format_result(result))
      {:error, reason} -> Mix.raise(Adapter.describe_error(reason))
      _unexpected -> Mix.raise("configuration operation failed")
    end
  end

  def run(_args), do: Mix.raise(@usage)

  @doc false
  @spec format_result(map()) :: String.t()
  def format_result(%{
        committed?: true,
        changed_count: changed_count,
        outcomes: outcomes,
        local_reload: local_reload,
        broadcast: broadcast,
        attention?: attention?
      })
      when is_integer(changed_count) and changed_count >= 0 and is_map(outcomes) and
             is_boolean(attention?) do
    with {:ok, apply_modes} <- validate_outcomes(outcomes, changed_count),
         :ok <- validate_postcommit(changed_count, local_reload, broadcast, attention?) do
      "committed=true changed_count=#{changed_count} " <>
        "apply_modes=#{format_apply_modes(apply_modes)} " <>
        "local_reload=#{format_local_reload(local_reload)} " <>
        "broadcast=#{format_broadcast(broadcast)} attention=#{attention?}"
    else
      _invalid -> invalid_result!()
    end
  end

  def format_result(_result), do: invalid_result!()

  defp boot! do
    case CLI.boot() do
      :ok -> :ok
      _failure -> Mix.raise("configuration CLI boot failed")
    end
  end

  defp validate_outcomes(outcomes, changed_count) do
    outcomes
    |> Map.values()
    |> Enum.reduce_while({:ok, 0, []}, fn
      %{changed?: changed?, applied: mode}, {:ok, count, modes}
      when is_boolean(changed?) and mode in @apply_modes ->
        if changed? do
          {:cont, {:ok, count + 1, [mode | modes]}}
        else
          {:cont, {:ok, count, modes}}
        end

      _outcome, _accumulator ->
        {:halt, :error}
    end)
    |> validate_changed_count(changed_count)
  end

  defp validate_changed_count({:ok, changed_count, modes}, changed_count) do
    {:ok, modes |> Enum.uniq() |> Enum.sort()}
  end

  defp validate_changed_count(_result, _changed_count), do: :error

  defp validate_postcommit(0, :not_needed, :not_needed, false), do: :ok

  defp validate_postcommit(changed_count, local_reload, broadcast, attention?)
       when changed_count > 0 do
    reload_valid? = local_reload in [:ok, {:error, :reload_failed}]
    broadcast_valid? = broadcast in [:ok, {:error, :broadcast_failed}]

    expected_attention? =
      local_reload == {:error, :reload_failed} or broadcast == {:error, :broadcast_failed}

    if reload_valid? and broadcast_valid? and attention? == expected_attention?,
      do: :ok,
      else: :error
  end

  defp validate_postcommit(_changed_count, _local_reload, _broadcast, _attention), do: :error

  defp format_apply_modes([]), do: "none"

  defp format_apply_modes(modes) do
    Enum.map_join(modes, ",", &Atom.to_string/1)
  end

  defp format_local_reload(:ok), do: "ok"
  defp format_local_reload(:not_needed), do: "not_needed"
  defp format_local_reload({:error, :reload_failed}), do: "reload_failed"

  defp format_broadcast(:ok), do: "ok"
  defp format_broadcast(:not_needed), do: "not_needed"
  defp format_broadcast({:error, :broadcast_failed}), do: "broadcast_failed"

  defp invalid_result!, do: Mix.raise("configuration operation returned an invalid result")
end
