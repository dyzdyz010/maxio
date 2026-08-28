defmodule Mix.Tasks.Maxio.Admin.User.Add do
  @shortdoc "Atomically create a MinIO-compatible IAM user"
  @moduledoc """
  Creates one active explicit IAM user and its same-name long-term access key.
  The new signing secret is read only from the named environment variable:

      mix maxio.admin.user.add ACCESS_KEY --secret-env ENV_NAME

  Literal secret arguments are deliberately unsupported so the secret does not
  enter process argv, shell history, Mix output, or structured logs.
  """

  use Mix.Task

  alias Maxio.Admin.UserAdapter
  alias Maxio.Config.CLI
  alias Maxio.S3.Log

  @switches [secret_env: :string]
  @aliases []
  @usage "usage: mix maxio.admin.user.add NAME --secret-env ENV_NAME"

  @impl true
  def run(argv) do
    {opts, args, invalid} = OptionParser.parse(argv, strict: @switches, aliases: @aliases)

    if invalid != [] or length(args) != 1 or blank?(opts[:secret_env]) do
      Mix.raise(@usage)
    end

    [name] = args
    secret_key = fetch_secret!(opts[:secret_env])

    with :ok <- CLI.boot(),
         {:ok, _created} <-
           UserAdapter.add(name, %{secret_key: secret_key, policy: "", status: "enabled"}) do
      Log.info("admin user added from CLI",
        action: "admin_user_add",
        admin_action: "admin_user_add",
        required_action: "admin:CreateUser",
        target_user: name,
        request_id: nil,
        surface: "cli"
      )

      Mix.shell().info(
        "[maxio admin.user.add] admin_action=admin_user_add " <>
          "required_action=admin:CreateUser target_user=#{name} surface=cli status=created"
      )
    else
      {:error, :invalid_access_key} ->
        Mix.raise("invalid admin user access key")

      {:error, :invalid_secret_key} ->
        Mix.raise("admin user secret must contain at least 8 bytes")

      {:error, :user_already_exists} ->
        Mix.raise("admin user already exists")

      {:error, _reason} ->
        Mix.raise("admin user add failed")
    end
  end

  defp fetch_secret!(secret_env_name) do
    case System.get_env(secret_env_name) do
      secret when is_binary(secret) and secret != "" -> secret
      _missing -> Mix.raise("admin user secret environment variable is not set")
    end
  end

  defp blank?(value), do: not is_binary(value) or value == ""
end
