defmodule Mix.Tasks.Maxio.Admin.Config.Reset do
  @shortdoc "Reset Admin Config KVS keys or a full subsystem"
  @moduledoc """
  Resets Admin Config KVS keys through the same Adapter used by the HTTP surface.

      mix maxio.admin.config.reset "s3 clock_skew_ms"
      mix maxio.admin.config.reset s3
  """

  use Mix.Task

  alias Maxio.Admin.ConfigKV.Adapter
  alias Maxio.Config.CLI
  alias Mix.Tasks.Maxio.Admin.Config.Set, as: SetTask

  @usage "usage: mix maxio.admin.config.reset <subsystem> [key ...]"

  @impl true
  def run([]), do: Mix.raise(@usage)

  def run(args) when is_list(args) do
    boot!()
    command = Enum.join(args, " ")
    request_id = Ecto.UUID.generate()

    case Adapter.reset(command, source: "cli", request_id: request_id) do
      {:ok, result} -> Mix.shell().info(SetTask.format_result(result))
      {:error, reason} -> Mix.raise(Adapter.describe_error(reason))
      _unexpected -> Mix.raise("configuration operation failed")
    end
  end

  def run(_args), do: Mix.raise(@usage)

  defp boot! do
    case CLI.boot() do
      :ok -> :ok
      _failure -> Mix.raise("configuration CLI boot failed")
    end
  end
end
