defmodule Mix.Tasks.Maxio.Admin.Config.Get do
  @shortdoc "Read one Admin Config KVS subsystem"
  @moduledoc """
  Reads one Admin Config KVS subsystem through the same Adapter used by the HTTP surface.

      mix maxio.admin.config.get s3
  """

  use Mix.Task

  alias Maxio.Admin.ConfigKV.Adapter
  alias Maxio.Config.CLI

  @usage "usage: mix maxio.admin.config.get <subsystem>"

  @impl true
  def run([]), do: Mix.raise(@usage)

  def run(args) when is_list(args) do
    boot!()
    command = Enum.join(args, " ")
    request_id = Ecto.UUID.generate()

    case Adapter.get(command, source: "cli", request_id: request_id) do
      {:ok, %{plaintext: plaintext}} -> IO.write(plaintext)
      {:error, reason} -> Mix.raise(Adapter.describe_error(reason))
    end
  end

  def run(_args), do: Mix.raise(@usage)

  defp boot! do
    case CLI.boot() do
      :ok -> :ok
      {:error, _reason} -> Mix.raise("configuration CLI boot failed")
    end
  end
end
