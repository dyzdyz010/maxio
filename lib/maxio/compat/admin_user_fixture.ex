defmodule Maxio.Compat.AdminUserFixture do
  @moduledoc """
  Creates one short-lived IAM user for the external MinIO admin user-info smoke.

  Setup and cleanup use the public IAM facade. The callback receives only the
  public user projection; no access key or secret is created. Cleanup evidence
  uses the same step/blocker shape as `Maxio.Compat.ExternalSmoke`.
  """

  alias Maxio.Config.CLI
  alias Maxio.IAM

  @cleanup_step "admin_user_fixture_cleanup"

  @type cleanup_component :: %{steps: [map()], blockers: [map()]}

  @spec with_user(keyword(), (map() -> term())) ::
          {:ok, term(), cleanup_component()}
          | {:error, map(), cleanup_component()}
  def with_user(opts, callback) when is_list(opts) and is_function(callback, 1) do
    start_repo = Keyword.get(opts, :start_repo, &CLI.start_repo/0)
    create_user = Keyword.get(opts, :create_user, &default_create_user/1)
    cleanup_user = Keyword.get(opts, :cleanup_user, &IAM.delete_user/1)
    name = Keyword.get(opts, :name, unique_name())

    case setup_user(start_repo, create_user, name) do
      {:ok, user} ->
        primary = invoke_callback(callback, user)
        cleanup = cleanup_user(cleanup_user, user.user_name)

        case primary do
          {:ok, result} -> {:ok, result, cleanup}
          {:error, blocker} -> {:error, blocker, cleanup}
        end

      {:error, blocker} ->
        {:error, blocker, %{steps: [], blockers: []}}
    end
  end

  defp setup_user(start_repo, create_user, name) do
    with :ok <- start_repo.(),
         {:ok, %{user_name: user_name} = user} when is_binary(user_name) <- create_user.(name) do
      {:ok, user}
    else
      failure -> {:error, setup_blocker(failure)}
    end
  rescue
    error -> {:error, setup_exception_blocker(error)}
  catch
    kind, reason -> {:error, setup_catch_blocker(kind, reason)}
  end

  defp invoke_callback(callback, user) do
    {:ok, callback.(user)}
  rescue
    error ->
      {:error,
       %{
         "reason" => "external_smoke_fixture_callback_failed",
         "message" => Exception.message(error)
       }}
  catch
    kind, reason ->
      {:error,
       %{
         "reason" => "external_smoke_fixture_callback_failed",
         "message" => Exception.format(kind, reason, [])
       }}
  end

  defp cleanup_user(cleanup_user, user_name) do
    started = System.monotonic_time(:millisecond)

    result =
      try do
        cleanup_user.(user_name)
      rescue
        error -> {:exception, Exception.message(error)}
      catch
        kind, reason -> {:exception, Exception.format(kind, reason, [])}
      end

    duration_ms = System.monotonic_time(:millisecond) - started

    case result do
      :ok -> cleanup_success(duration_ms)
      {:ok, _value} -> cleanup_success(duration_ms)
      failure -> cleanup_failure(duration_ms, failure)
    end
  end

  defp cleanup_success(duration_ms) do
    %{
      steps: [cleanup_step("ok", 0, "temporary IAM user removed", duration_ms)],
      blockers: []
    }
  end

  defp cleanup_failure(duration_ms, failure) do
    %{
      steps: [cleanup_step("blocked", 1, "temporary IAM user cleanup failed", duration_ms)],
      blockers: [
        %{
          "reason" => "external_smoke_cleanup_failed",
          "step" => @cleanup_step,
          "message" => safe_reason(failure)
        }
      ]
    }
  end

  defp cleanup_step(status, exit_status, output, duration_ms) do
    %{
      "id" => @cleanup_step,
      "scenario" => "cleanup",
      "command" => "Maxio.IAM.delete_user",
      "exit_status" => exit_status,
      "duration_ms" => duration_ms,
      "status" => status,
      "output_snippet" => output,
      "assertion" => "temporary IAM user is absent after the external smoke"
    }
  end

  defp setup_blocker(failure) do
    %{
      "reason" => "external_smoke_fixture_setup_failed",
      "message" => safe_reason(failure)
    }
  end

  defp setup_exception_blocker(error) do
    %{
      "reason" => "external_smoke_fixture_setup_failed",
      "message" => Exception.message(error)
    }
  end

  defp setup_catch_blocker(kind, reason) do
    %{
      "reason" => "external_smoke_fixture_setup_failed",
      "message" => Exception.format(kind, reason, [])
    }
  end

  defp default_create_user(name), do: IAM.create_user(name: name, status: "active")

  defp safe_reason({:exception, message}), do: message
  defp safe_reason(reason), do: inspect(reason)

  defp unique_name do
    "maxio-compat-user-#{System.unique_integer([:positive, :monotonic])}"
  end
end
