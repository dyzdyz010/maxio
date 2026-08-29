defmodule Mix.Tasks.Maxio.Admin.Config.Help do
  @shortdoc "Show the Admin Config KVS help catalog"
  @moduledoc """
  Shows the static Admin Config KVS help catalog without starting Maxio or connecting to its
  database.

      mix maxio.admin.config.help [--env] [subsystem [key]]
  """

  use Mix.Task

  alias Maxio.Admin.ConfigKV.Help

  @usage "usage: mix maxio.admin.config.help [--env] [subsystem [key]]"

  @impl true
  def run(args) when is_list(args) do
    with {opts, positional, []} <- OptionParser.parse(args, strict: [env: :boolean]),
         {:ok, subsystem, key} <- positional_arguments(positional) do
      env_only? = Keyword.get(opts, :env, false)

      case Help.project(subsystem, key, env_only?) do
        {:ok, result} -> IO.write(Help.encode_line(result.wire))
        {:error, %{reason: reason}} -> Mix.raise(Help.describe_error(reason))
      end
    else
      _invalid -> Mix.raise(@usage)
    end
  end

  def run(_args), do: Mix.raise(@usage)

  defp positional_arguments([]), do: {:ok, "", ""}
  defp positional_arguments([subsystem]), do: {:ok, subsystem, ""}
  defp positional_arguments([subsystem, key]), do: {:ok, subsystem, key}
  defp positional_arguments(_other), do: :error
end
