defmodule Mix.Tasks.Maxio.Admin.User.Show do
  @shortdoc "Inspect one IAM user through the partial MinIO admin projection"
  @moduledoc """
  Recomputes the same deliberately partial UserInfo projection served by
  `GET /minio/admin/v3/user-info?accessKey=NAME`.

      mix maxio.admin.user.show NAME
      mix maxio.admin.user.show NAME --json

  The command is read-only. It reports safe policy names, ARNs, and counts,
  never policy documents, secret keys, or session tokens.
  """

  use Mix.Task

  alias Maxio.Admin.UserAdapter
  alias Maxio.Config.CLI

  @switches [json: :boolean]
  @usage "usage: mix maxio.admin.user.show NAME [--json]"

  @impl true
  def run(argv) do
    {opts, args, invalid} = OptionParser.parse(argv, strict: @switches)

    if invalid != [] or length(args) != 1 do
      Mix.raise(@usage)
    end

    [name] = args

    with :ok <- CLI.boot(),
         {:ok, result} <- UserAdapter.info(name) do
      print(name, result, opts[:json])
    else
      {:error, :user_not_found} ->
        Mix.raise("admin user not found: #{name}")

      {:error, reason} when reason in [:invalid_argument, :invalid_resource_name] ->
        Mix.raise("invalid admin user name")

      {:error, reason} when is_binary(reason) ->
        Mix.raise(reason)

      {:error, _reason} ->
        Mix.raise("admin user lookup failed")
    end
  end

  defp print(_name, result, true), do: Mix.shell().info(Jason.encode!(result))

  defp print(name, %{wire: wire, evidence: evidence}, _json?) do
    Mix.shell().info(
      "[maxio admin.user.show] name=#{name} status=#{wire["status"]} " <>
        "credential_bearing=#{evidence.credential_bearing} " <>
        "minio_view_partial=#{evidence.minio_view_partial} " <>
        "updated_at=#{Map.get(wire, "updatedAt", "nil")}"
    )

    Mix.shell().info(
      "[maxio admin.user.direct_managed] visible_names=#{json(evidence.direct_managed.visible_names)} " <>
        "omitted_names=#{json(evidence.direct_managed.omitted_names)} " <>
        "arns=#{json(evidence.direct_managed.arns)} count=#{evidence.direct_managed.count}"
    )

    print_source("direct_inline", evidence.direct_inline)
    print_source("group_inline", evidence.group_inline)
    print_source("group_managed", evidence.group_managed)
    print_source("role_managed", evidence.role_managed)

    Mix.shell().info("[maxio admin.user.omitted] reasons=#{json(evidence.omitted_reason)}")
  end

  defp print_source(source, evidence) do
    arns = if Map.has_key?(evidence, :arns), do: " arns=#{json(evidence.arns)}", else: ""

    Mix.shell().info(
      "[maxio admin.user.#{source}] names=#{json(evidence.names)}" <>
        arns <> " count=#{evidence.count}"
    )
  end

  defp json(value), do: Jason.encode!(value)
end
