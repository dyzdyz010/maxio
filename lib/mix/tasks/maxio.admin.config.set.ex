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
    "committed=true changed_count=#{changed_count} " <>
      "apply_modes=#{format_apply_modes(outcomes)} " <>
      "local_reload=#{format_local_reload(local_reload)} " <>
      "broadcast=#{format_broadcast(broadcast)} attention=#{attention?}"
  end

  def format_result(_result), do: Mix.raise("configuration operation returned an invalid result")

  defp boot! do
    case CLI.boot() do
      :ok -> :ok
      {:error, _reason} -> Mix.raise("configuration CLI boot failed")
    end
  end

  defp format_apply_modes(outcomes) do
    modes =
      outcomes
      |> Map.values()
      |> Enum.filter(&match?(%{changed?: true}, &1))
      |> Enum.map(&format_apply_mode/1)
      |> Enum.uniq()
      |> Enum.sort()

    if modes == [], do: "none", else: Enum.join(modes, ",")
  end

  defp format_apply_mode(%{applied: mode}) when mode in @apply_modes, do: Atom.to_string(mode)
  defp format_apply_mode(_outcome), do: "unknown"

  defp format_local_reload(:ok), do: "ok"
  defp format_local_reload(:not_needed), do: "not_needed"
  defp format_local_reload({:error, :reload_failed}), do: "reload_failed"
  defp format_local_reload(_result), do: "failed"

  defp format_broadcast(:ok), do: "ok"
  defp format_broadcast(:not_needed), do: "not_needed"
  defp format_broadcast({:error, :broadcast_failed}), do: "broadcast_failed"
  defp format_broadcast(_result), do: "failed"
end
