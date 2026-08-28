defmodule Mix.Tasks.Maxio.Admin.Policy.Show do
  @shortdoc "Inspect one managed policy through the MinIO admin projection"
  @moduledoc """
  Prints the same four-field PolicyInfo projection served by
  `GET /minio/admin/v3/info-canned-policy?name=NAME&v=2`.

      mix maxio.admin.policy.show NAME
      mix maxio.admin.policy.show NAME --json
  """

  use Mix.Task

  alias Maxio.Admin.PolicyAdapter

  @switches [json: :boolean]
  @usage "usage: mix maxio.admin.policy.show NAME [--json]"

  @impl true
  def run(argv) do
    {opts, args, invalid} = OptionParser.parse(argv, strict: @switches)

    if invalid != [] or length(args) != 1 do
      Mix.raise(@usage)
    end

    [name] = args
    Mix.Task.run("app.start")

    case PolicyAdapter.info(name) do
      {:ok, info} ->
        print(info, opts[:json])

      {:error, :not_found} ->
        Mix.raise("admin policy not found: #{name}")

      {:error, reason} when reason in [:invalid_argument, :invalid_resource_name, :malformed] ->
        Mix.raise("invalid admin policy name")

      {:error, _reason} ->
        Mix.raise("admin policy lookup failed")
    end
  end

  defp print(info, true), do: Mix.shell().info(Jason.encode!(info))

  defp print(info, _json?) do
    Mix.shell().info(
      "[maxio admin.policy.show] name=#{info["PolicyName"]} " <>
        "create_date=#{date(info["CreateDate"])} update_date=#{date(info["UpdateDate"])} " <>
        "policy=#{Jason.encode!(info["Policy"])}"
    )
  end

  defp date(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp date(value), do: to_string(value)
end
