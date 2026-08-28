defmodule Maxio.Compat.AdminUserFixture do
  @moduledoc """
  Creates one short-lived credential-bearing IAM user for external admin smoke.

  Setup and cleanup use public IAM facades. The plaintext secret exists only in
  the closure environment of a zero-argument S3 probe capability; it is never
  returned in fixture maps, argv, logs, or artifact evidence.
  """

  alias Maxio.Config.CLI
  alias Maxio.IAM
  alias Maxio.S3.AWSClient

  @cleanup_step "admin_user_fixture_cleanup"

  @type cleanup_component :: %{steps: [map()], blockers: [map()]}

  @spec with_user(keyword(), function()) ::
          {:ok, term(), cleanup_component()}
          | {:error, map(), cleanup_component()}
  def with_user(opts, callback)
      when is_list(opts) and (is_function(callback, 1) or is_function(callback, 2)) do
    start_repo = Keyword.get(opts, :start_repo, &CLI.start_repo/0)
    create_user = Keyword.get(opts, :create_user, fn name -> default_create_user(name, opts) end)
    cleanup_user = Keyword.get(opts, :cleanup_user, &IAM.delete_user/1)
    name = Keyword.get(opts, :name, unique_name())
    injected_probe = Keyword.get(opts, :s3_probe, &unconfigured_probe/0)

    case setup_user(start_repo, create_user, name, injected_probe) do
      {:ok, user, s3_probe} ->
        primary = invoke_callback(callback, user, s3_probe)
        cleanup = cleanup_user(cleanup_user, user.user_name)

        case primary do
          {:ok, result} -> {:ok, result, cleanup}
          {:error, blocker} -> {:error, blocker, cleanup}
        end

      {:error, blocker} ->
        {:error, blocker, %{steps: [], blockers: []}}
    end
  end

  defp setup_user(start_repo, create_user, name, injected_probe) do
    with :ok <- start_repo.(),
         {:ok, created} <- create_user.(name),
         {:ok, user, s3_probe} <- normalize_created(created, injected_probe) do
      {:ok, user, s3_probe}
    else
      failure -> {:error, setup_blocker(failure)}
    end
  rescue
    error -> {:error, setup_exception_blocker(error)}
  catch
    kind, reason -> {:error, setup_catch_blocker(kind, reason)}
  end

  defp normalize_created(%{user: %{user_name: user_name} = user, s3_probe: s3_probe}, _injected)
       when is_binary(user_name) and is_function(s3_probe, 0),
       do: {:ok, user, s3_probe}

  defp normalize_created(%{user_name: user_name} = user, injected_probe)
       when is_binary(user_name) and is_function(injected_probe, 0),
       do: {:ok, user, injected_probe}

  defp normalize_created(_created, _injected_probe), do: {:error, :invalid_fixture_user}

  defp invoke_callback(callback, user, s3_probe) do
    result =
      if is_function(callback, 2), do: callback.(user, s3_probe), else: callback.(user)

    {:ok, result}
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

  defp default_create_user(name, opts) do
    secret_key = Base.url_encode64(:crypto.strong_rand_bytes(30), padding: false)

    with {:ok, %{user: user}} <- IAM.create_minio_user_strict(name, secret_key, "active"),
         :ok <- maybe_put_list_buckets_policy(name, opts) do
      {:ok,
       %{
         user: user,
         s3_probe: s3_probe(name, secret_key, Keyword.get(opts, :endpoint))
       }}
    else
      failure ->
        _cleanup = IAM.delete_user(name)
        failure
    end
  end

  defp maybe_put_list_buckets_policy(name, opts) do
    if Keyword.get(opts, :initial_list_buckets_policy, true) do
      IAM.put_user_policy_strict(name, "maxio-compat-list-buckets", list_buckets_policy())
    else
      :ok
    end
  end

  defp s3_probe(access_key_id, secret_key, configured_endpoint) do
    endpoint = configured_endpoint || System.get_env("MAXIO_COMPAT_ENDPOINT")

    fn ->
      if is_binary(endpoint) and endpoint != "" do
        url = String.trim_trailing(endpoint, "/") <> "/"

        with {:ok, request} <-
               AWSClient.signed_request(:get, url, "s3", "", %{}, "",
                 access_key_id: access_key_id,
                 secret_access_key: secret_key
               ),
             {:ok, response} <-
               Req.request(
                 method: request.method,
                 url: request.url,
                 headers: request.headers,
                 body: request.body
               ) do
          %{
            status: response.status,
            code: response_error_field(response.body, "Code"),
            message: response_error_field(response.body, "Message")
          }
        else
          {:error, _reason} -> %{status: nil, code: "probe_failed", message: nil}
        end
      else
        %{status: nil, code: "probe_not_configured", message: nil}
      end
    end
  end

  defp response_error_field(body, field) when is_binary(body) do
    case Regex.run(~r/<#{field}>([^<]+)<\/#{field}>/, body, capture: :all_but_first) do
      [value] -> value
      _other -> nil
    end
  end

  defp response_error_field(_body, _field), do: nil

  defp unconfigured_probe,
    do: %{status: nil, code: "probe_not_configured", message: nil}

  defp list_buckets_policy do
    Jason.encode!(%{
      "Version" => "2012-10-17",
      "Statement" => %{
        "Effect" => "Allow",
        "Action" => "s3:ListAllMyBuckets",
        "Resource" => "*"
      }
    })
  end

  defp safe_reason({:exception, message}), do: message
  defp safe_reason(reason), do: inspect(reason)

  defp unique_name do
    "maxio-compat-user-#{System.unique_integer([:positive, :monotonic])}"
  end
end
