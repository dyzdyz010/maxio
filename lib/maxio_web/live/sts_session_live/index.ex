defmodule MaxioWeb.StsSessionLive.Index do
  @moduledoc "Console STS temporary session credential management."
  use MaxioWeb, :live_view

  alias Maxio.IAM
  alias Maxio.STS

  @default_duration_seconds "3600"
  @role_session_name_pattern ~r/\A[A-Za-z0-9+=,.@_-]{2,64}\z/
  @source_identity_pattern ~r/\A(?!aws:)[A-Za-z0-9+=,.@_-]{2,64}\z/i
  @external_id_pattern ~r|\A[A-Za-z0-9_+=,.@:/-]{2,1224}\z|

  @impl true
  def mount(_params, _session, socket) do
    filters = default_filters()
    sessions = list_sessions(filters)

    {:ok,
     socket
     |> assign(:page_title, "STS Sessions")
     |> assign(:session_count, length(sessions))
     |> assign(:new_secret, nil)
     |> assign(:filters, filters)
     |> assign(:create_form, create_form())
     |> assign(:assume_role_form, assume_role_form())
     |> assign(:filter_form, filter_form(filters))
     |> stream(:sessions, sessions, dom_id: &session_dom_id/1)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_principal}>
      <.header>
        STS Sessions
        <:subtitle>{@session_count} temporary credentials</:subtitle>
        <:actions>
          <.button navigate={~p"/access-keys"}>
            <.icon name="hero-key" class="size-4" /> Access Keys
          </.button>
          <.button navigate={~p"/roles"}>
            <.icon name="hero-identification" class="size-4" /> Roles
          </.button>
        </:actions>
      </.header>

      <div :if={@new_secret} id="sts-new-secret-banner" class="alert alert-success mb-5 text-sm">
        <.icon name="hero-check-circle" class="size-5" />
        <div class="min-w-0">
          <p class="font-semibold">
            STS session issued. Secret material is shown only in this response.
          </p>
          <p class="break-all font-mono">AccessKeyId: {@new_secret.access_key_id}</p>
          <p :if={@new_secret.assumed_role_arn} class="break-all font-mono">
            AssumedRoleArn: {@new_secret.assumed_role_arn}
          </p>
          <p class="break-all font-mono">SecretAccessKey: {@new_secret.secret_key}</p>
          <p class="break-all font-mono">SessionToken: {@new_secret.session_token}</p>
          <p class="font-mono">Expires: {@new_secret.expires_at}</p>
        </div>
      </div>

      <section
        id="create-sts-session-panel"
        class="mb-6 rounded-box border border-base-300 bg-base-100 p-4"
      >
        <.form for={@create_form} id="create-sts-session-form" phx-submit="create_session">
          <div class="grid gap-3 lg:grid-cols-[minmax(0,1fr)_14rem_16rem]">
            <.input
              field={@create_form[:issuer_access_key_id]}
              type="text"
              label="Issuer access key"
              placeholder="AKIA..."
              required
            />
            <.input
              field={@create_form[:duration_seconds]}
              type="number"
              label="Duration seconds"
              min="900"
              max="129600"
              required
            />
            <.input
              field={@create_form[:session_name]}
              type="text"
              label="Session name"
              placeholder="console-session"
            />
          </div>
          <div class="mt-3 flex justify-end">
            <.button variant="primary" id="create-sts-session-submit" type="submit">
              <.icon name="hero-plus" class="size-4" /> Issue session
            </.button>
          </div>
        </.form>
      </section>

      <section
        id="assume-role-panel"
        class="mb-6 rounded-box border border-base-300 bg-base-100 p-4"
      >
        <.form for={@assume_role_form} id="assume-role-session-form" phx-submit="assume_role">
          <div class="grid gap-3 lg:grid-cols-[minmax(0,1fr)_minmax(0,1.2fr)_16rem_12rem]">
            <.input
              field={@assume_role_form[:caller_access_key_id]}
              type="text"
              label="Caller access key"
              placeholder="AKIA..."
              required
            />
            <.input
              field={@assume_role_form[:role_arn]}
              type="text"
              label="Role ARN"
              placeholder="arn:aws:iam:::role/app-writer"
              required
            />
            <.input
              field={@assume_role_form[:session_name]}
              type="text"
              label="Role session name"
              placeholder="console-role-session"
              required
            />
            <.input
              field={@assume_role_form[:duration_seconds]}
              type="number"
              label="Duration seconds"
              min="900"
              max="43200"
              required
            />
          </div>

          <div class="mt-3 grid gap-3 lg:grid-cols-2">
            <.input
              field={@assume_role_form[:external_id]}
              type="text"
              label="ExternalId"
              placeholder="optional"
            />
            <.input
              field={@assume_role_form[:source_identity]}
              type="text"
              label="SourceIdentity"
              placeholder="optional"
            />
            <.input
              field={@assume_role_form[:mfa_serial]}
              type="text"
              label="MFA serial"
              placeholder="optional"
            />
            <.input
              field={@assume_role_form[:mfa_token_code]}
              type="text"
              label="MFA token code"
              placeholder="optional"
            />
          </div>

          <div class="mt-3 grid gap-3 lg:grid-cols-2">
            <.input
              field={@assume_role_form[:session_tags]}
              type="textarea"
              rows="5"
              label="Session tags"
              placeholder="team=platform"
              class="w-full textarea font-mono text-xs"
            />
            <.input
              field={@assume_role_form[:transitive_tag_keys]}
              type="textarea"
              rows="5"
              label="Transitive tag keys"
              placeholder="team"
              class="w-full textarea font-mono text-xs"
            />
            <.input
              field={@assume_role_form[:policy_arns]}
              type="textarea"
              rows="5"
              label="Managed session policy ARNs"
              placeholder="arn:aws:iam:::policy/readonly"
              class="w-full textarea font-mono text-xs"
            />
            <.input
              field={@assume_role_form[:session_policy]}
              type="textarea"
              rows="5"
              label="Inline session policy JSON"
              placeholder={
                ~s({"Version":"2012-10-17","Statement":{"Effect":"Allow","Action":"s3:ListAllMyBuckets","Resource":"*"}})
              }
              class="w-full textarea font-mono text-xs"
            />
          </div>

          <div class="mt-3 flex justify-end">
            <.button variant="primary" id="assume-role-session-submit" type="submit">
              <.icon name="hero-shield-check" class="size-4" /> Assume role
            </.button>
          </div>
        </.form>
      </section>

      <section
        id="sts-session-filter-panel"
        class="mb-6 rounded-box border border-base-300 bg-base-100 p-4"
      >
        <.form for={@filter_form} id="sts-session-filter-form" phx-submit="filter_sessions">
          <div class="grid gap-3 lg:grid-cols-[minmax(0,1fr)_minmax(0,1fr)_auto_auto] lg:items-end">
            <.input
              field={@filter_form[:issuer_access_key_id]}
              type="text"
              label="Issuer access key"
              placeholder="Filter by parent AKIA..."
            />
            <.input
              field={@filter_form[:principal_arn]}
              type="text"
              label="Principal ARN"
              placeholder="arn:aws:iam:::user/alice"
            />
            <.button id="sts-session-filter-submit" type="submit">
              <.icon name="hero-funnel" class="size-4" /> Filter
            </.button>
            <.button id="sts-session-filter-clear" type="button" phx-click="clear_filters">
              <.icon name="hero-x-mark" class="size-4" /> Clear
            </.button>
          </div>
        </.form>
      </section>

      <table class="table table-zebra">
        <thead>
          <tr>
            <th>Session access key</th>
            <th>Status</th>
            <th>Principal</th>
            <th>Issuer</th>
            <th>Name</th>
            <th>Issued</th>
            <th>Expires</th>
            <th class="w-0"></th>
          </tr>
        </thead>
        <tbody id="sts-sessions" phx-update="stream">
          <tr class="hidden only:table-row" id="sts-sessions-empty">
            <td colspan="8" class="text-center text-base-content/60">No STS sessions yet.</td>
          </tr>
          <tr :for={{dom_id, session} <- @streams.sessions} id={dom_id}>
            <td class="break-all font-mono text-sm">{session.access_key_id}</td>
            <td>
              <span
                id={"sts-session-status-#{dom_suffix(session.access_key_id)}"}
                class={["badge badge-sm", status_badge_class(session)]}
              >
                {session.status}
              </span>
            </td>
            <td class="min-w-64">
              <div class="badge badge-ghost badge-sm">{session.principal_type}</div>
              <div class="mt-1 break-all font-mono text-xs text-base-content/60">
                {session.principal_arn}
              </div>
            </td>
            <td class="break-all font-mono text-xs text-base-content/60">
              {session.issuer_access_key_id}
            </td>
            <td class="font-mono text-sm">{session.session_name}</td>
            <td class="font-mono text-xs">{format_datetime(session.issued_at)}</td>
            <td class="font-mono text-xs">{format_datetime(session.expires_at)}</td>
            <td>
              <.button
                :if={session.status == "active"}
                id={"revoke-sts-session-#{dom_suffix(session.access_key_id)}"}
                phx-click="revoke_session"
                phx-value-access-key-id={session.access_key_id}
                data-confirm={"Revoke STS session #{session.access_key_id}?"}
                title="Revoke session"
                aria-label={"Revoke STS session #{session.access_key_id}"}
              >
                <.icon name="hero-x-circle" class="size-4" />
              </.button>
              <span
                :if={session.status != "active"}
                id={"sts-session-revoked-#{dom_suffix(session.access_key_id)}"}
                class="text-xs text-base-content/50"
              >
                Revoked
              </span>
            </td>
          </tr>
        </tbody>
      </table>
    </Layouts.app>
    """
  end

  @impl true
  def handle_event("create_session", %{"session" => params}, socket) do
    case issue_opts(params) do
      {:ok, opts} ->
        case STS.issue_session(opts) do
          {:ok, session} ->
            {:noreply,
             socket
             |> assign(:create_form, create_form())
             |> assign(:new_secret, new_secret_view(session))
             |> refresh_sessions()
             |> put_flash(:info, "Issued STS session #{session.access_key_id}")}

          {:error, reason} ->
            {:noreply,
             socket
             |> assign(:create_form, create_form(params))
             |> assign(:new_secret, nil)
             |> put_flash(:error, issue_error_message(reason))}
        end

      {:error, message} ->
        {:noreply,
         socket
         |> assign(:create_form, create_form(params))
         |> assign(:new_secret, nil)
         |> put_flash(:error, message)}
    end
  end

  def handle_event("create_session", _params, socket) do
    {:noreply,
     socket
     |> assign(:new_secret, nil)
     |> put_flash(:error, "Session form payload is required")}
  end

  @impl true
  def handle_event("assume_role", %{"assume_role" => params}, socket) do
    case assume_role_request(params) do
      {:ok, caller_principal, role, opts} ->
        case STS.assume_role(caller_principal, role, opts) do
          {:ok, session} ->
            {:noreply,
             socket
             |> assign(:assume_role_form, assume_role_form())
             |> assign(:new_secret, new_secret_view(session))
             |> refresh_sessions()
             |> put_flash(:info, "Issued assumed-role session #{session.access_key_id}")}

          {:error, reason} ->
            {:noreply,
             socket
             |> assign(:assume_role_form, assume_role_form(params))
             |> assign(:new_secret, nil)
             |> put_flash(:error, assume_role_error_message(reason))}
        end

      {:error, message} ->
        {:noreply,
         socket
         |> assign(:assume_role_form, assume_role_form(params))
         |> assign(:new_secret, nil)
         |> put_flash(:error, message)}
    end
  end

  def handle_event("assume_role", _params, socket) do
    {:noreply,
     socket
     |> assign(:new_secret, nil)
     |> put_flash(:error, "AssumeRole form payload is required")}
  end

  @impl true
  def handle_event("filter_sessions", %{"filter" => params}, socket) do
    filters = normalize_filters(params)

    {:noreply,
     socket
     |> assign(:filters, filters)
     |> assign(:filter_form, filter_form(filters))
     |> assign(:new_secret, nil)
     |> refresh_sessions()}
  end

  def handle_event("filter_sessions", _params, socket) do
    {:noreply,
     socket
     |> assign(:new_secret, nil)
     |> put_flash(:error, "Filter form payload is required")}
  end

  @impl true
  def handle_event("clear_filters", _params, socket) do
    filters = default_filters()

    {:noreply,
     socket
     |> assign(:filters, filters)
     |> assign(:filter_form, filter_form(filters))
     |> assign(:new_secret, nil)
     |> refresh_sessions()}
  end

  @impl true
  def handle_event("revoke_session", %{"access-key-id" => access_key_id}, socket) do
    case STS.revoke_session(access_key_id) do
      {:ok, nil} ->
        {:noreply,
         socket
         |> assign(:new_secret, nil)
         |> refresh_sessions()
         |> put_flash(:info, "STS session already revoked or missing")}

      {:ok, session} ->
        {:noreply,
         socket
         |> assign(:new_secret, nil)
         |> refresh_sessions()
         |> put_flash(:info, "Revoked STS session #{session.access_key_id}")}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(:new_secret, nil)
         |> put_flash(:error, "Revoke STS session failed: #{inspect(reason)}")}
    end
  end

  def handle_event("revoke_session", _params, socket) do
    {:noreply,
     socket
     |> assign(:new_secret, nil)
     |> put_flash(:error, "STS session access key is required")}
  end

  defp issue_opts(params) do
    issuer_access_key_id = params |> Map.get("issuer_access_key_id") |> trim()
    session_name = params |> Map.get("session_name") |> trim()

    with :ok <- require_nonempty(issuer_access_key_id, "Issuer access key is required"),
         {:ok, duration_seconds} <- parse_duration(Map.get(params, "duration_seconds")) do
      opts = [
        issuer_access_key_id: issuer_access_key_id,
        duration_seconds: duration_seconds
      ]

      {:ok, maybe_put_session_name(opts, session_name)}
    end
  end

  defp maybe_put_session_name(opts, ""), do: opts

  defp maybe_put_session_name(opts, session_name),
    do: Keyword.put(opts, :session_name, session_name)

  defp require_nonempty("", message), do: {:error, message}
  defp require_nonempty(_value, _message), do: :ok

  defp parse_duration(value) do
    case Integer.parse(to_string(value)) do
      {duration, ""} when duration >= 900 and duration <= 129_600 -> {:ok, duration}
      _other -> {:error, "Duration must be between 900 and 129600 seconds"}
    end
  end

  defp issue_error_message(:issuer_access_key_not_found),
    do: "Issuer access key is not active or does not exist"

  defp issue_error_message(:missing_issuer_access_key_id), do: "Issuer access key is required"
  defp issue_error_message(:invalid_session_duration), do: "Duration is invalid for this issuer"
  defp issue_error_message(reason), do: "Issue STS session failed: #{inspect(reason)}"

  defp assume_role_request(params) do
    with {:ok, caller_principal} <- caller_principal(params),
         {:ok, role} <- role(params),
         {:ok, opts} <- assume_role_opts(params) do
      {:ok, caller_principal, role, opts}
    end
  end

  defp caller_principal(params) do
    caller_access_key_id = params |> Map.get("caller_access_key_id") |> trim()

    with :ok <- require_nonempty(caller_access_key_id, "Caller access key is required"),
         {:ok, principal} <- active_long_term_principal(caller_access_key_id),
         {:ok, type} <- caller_principal_type(principal) do
      {:ok,
       %{
         type: type,
         access_key: principal.access_key,
         arn: principal.arn,
         credential_type: :long_term,
         tags: Map.get(principal, :tags, %{})
       }}
    end
  end

  defp active_long_term_principal(access_key_id) do
    case IAM.get_active_access_key_principal(access_key_id) do
      {:ok, %{access_key: ^access_key_id} = principal} -> {:ok, principal}
      :error -> {:error, "Caller access key is not active or does not exist"}
    end
  end

  # 原来的 `caller_principal_type(_key)` 兜底是可证不可达的死代码，已删：非长期凭据的拒绝
  # 发生在**上游**，本函数根本收不到它们。两道上游关卡（`IAM.public_active_access_key_principal/1`
  # 的总括 `%AccessKey{} -> :error`，以及 `AccessKey.changeset/2` 的
  # `validate_inclusion(:type, ["root", "iam_user"])`）保证进到这里的 `:type` 只可能是
  # `:root | :iam_user`；`active_long_term_principal/1` 又保证入参是 map。真正的安全拒绝在上游，
  # 不在这里（见 `test/maxio_web/live/sts_session_live_test.exs` 里钉住上游关卡的用例）。
  defp caller_principal_type(%{type: :root}), do: {:ok, :root}
  defp caller_principal_type(%{type: :iam_user}), do: {:ok, :iam_user}

  defp role(params) do
    role_arn = params |> Map.get("role_arn") |> trim()

    with :ok <- require_nonempty(role_arn, "Role ARN is required") do
      case IAM.get_role_by_arn(role_arn) do
        {:ok, role} -> {:ok, role}
        :error -> {:error, "IAM role does not exist"}
      end
    end
  end

  defp assume_role_opts(params) do
    with {:ok, session_name} <- role_session_name(params),
         {:ok, duration_seconds} <-
           parse_assume_role_duration(Map.get(params, "duration_seconds")),
         {:ok, external_id} <- external_id(params),
         {:ok, source_identity} <- source_identity(params),
         {:ok, mfa_opts} <- mfa_opts(params),
         {:ok, session_tags} <- session_tags(params),
         {:ok, transitive_tag_keys} <- transitive_tag_keys(params),
         {:ok, policy_arns} <- policy_arns(params),
         {:ok, session_policy} <- session_policy(params) do
      opts =
        [
          session_name: session_name,
          duration_seconds: duration_seconds,
          session_tags: session_tags,
          transitive_tag_keys: transitive_tag_keys,
          policy_arns: policy_arns
        ]
        |> maybe_put_option(:external_id, external_id)
        |> maybe_put_option(:source_identity, source_identity)
        |> maybe_put_option(:session_policy, session_policy)
        |> Keyword.merge(mfa_opts)

      {:ok, opts}
    end
  end

  defp role_session_name(params) do
    value = params |> Map.get("session_name") |> trim()

    cond do
      value == "" -> {:error, "Role session name is required"}
      Regex.match?(@role_session_name_pattern, value) -> {:ok, value}
      true -> {:error, "Role session name must be 2 to 64 allowed characters"}
    end
  end

  defp parse_assume_role_duration(value) do
    case Integer.parse(to_string(value)) do
      {duration, ""} when duration >= 900 and duration <= 43_200 -> {:ok, duration}
      _other -> {:error, "AssumeRole duration must be between 900 and 43200 seconds"}
    end
  end

  defp external_id(params) do
    case params |> Map.get("external_id") |> trim() do
      "" -> {:ok, nil}
      value -> validate_pattern(value, @external_id_pattern, "ExternalId is invalid")
    end
  end

  defp source_identity(params) do
    case params |> Map.get("source_identity") |> trim() do
      "" -> {:ok, nil}
      value -> validate_pattern(value, @source_identity_pattern, "SourceIdentity is invalid")
    end
  end

  defp validate_pattern(value, pattern, message) do
    if Regex.match?(pattern, value), do: {:ok, value}, else: {:error, message}
  end

  defp mfa_opts(params) do
    serial = params |> Map.get("mfa_serial") |> trim()
    token_code = params |> Map.get("mfa_token_code") |> trim()

    cond do
      serial == "" and token_code == "" ->
        {:ok, []}

      not valid_mfa_serial?(serial) ->
        {:error, "MFA serial is invalid"}

      not valid_mfa_token_code?(token_code) ->
        {:error, "MFA token code must be a six digit code"}

      true ->
        {:ok, [mfa_serial: serial, mfa_token_code: token_code]}
    end
  end

  defp valid_mfa_serial?(serial),
    do: serial != "" and byte_size(serial) <= 512 and not String.match?(serial, ~r/\s/)

  defp valid_mfa_token_code?(token_code), do: String.match?(token_code, ~r/\A\d{6}\z/)

  defp session_tags(params), do: parse_tag_lines(Map.get(params, "session_tags"))

  defp parse_tag_lines(value) do
    value
    |> lines()
    |> Enum.reduce_while({:ok, []}, fn line, {:ok, acc} ->
      case String.split(line, "=", parts: 2) do
        [key, tag_value] ->
          key = String.trim(key)
          tag_value = String.trim(tag_value)

          if key == "" do
            {:halt, {:error, "Session tag keys cannot be empty"}}
          else
            {:cont, {:ok, acc ++ [{key, tag_value}]}}
          end

        _other ->
          {:halt, {:error, "Session tags must use key=value lines"}}
      end
    end)
  end

  defp transitive_tag_keys(params),
    do: {:ok, split_values(Map.get(params, "transitive_tag_keys"))}

  defp policy_arns(params), do: {:ok, split_values(Map.get(params, "policy_arns"))}

  defp session_policy(params) do
    case params |> Map.get("session_policy") |> trim() do
      "" -> {:ok, nil}
      json -> {:ok, json}
    end
  end

  defp maybe_put_option(opts, _key, nil), do: opts
  defp maybe_put_option(opts, key, value), do: Keyword.put(opts, key, value)

  defp assume_role_error_message(:invalid_session_duration),
    do: "Duration is invalid for this role or caller"

  defp assume_role_error_message(:invalid_session_tags), do: "Session tags are invalid"

  defp assume_role_error_message(:invalid_transitive_tag_keys),
    do: "Transitive tag keys are invalid"

  defp assume_role_error_message(:invalid_session_policy), do: "Session policy is invalid"
  defp assume_role_error_message(:invalid_mfa_parameters), do: "MFA parameters are invalid"

  defp assume_role_error_message({:mfa_failed, reason}),
    do: "MFA validation failed: #{inspect(reason)}"

  defp assume_role_error_message({:pre_issue_failed, reason}),
    do: "MFA validation failed: #{inspect(reason)}"

  defp assume_role_error_message({:assume_role_denied, reason}),
    do: "AssumeRole denied: #{inspect(reason)}"

  defp assume_role_error_message({:caller_assume_role_denied, reason}),
    do: "Caller is not allowed to assume this role: #{inspect(reason)}"

  defp assume_role_error_message({:caller_tag_session_denied, reason}),
    do: "Caller is not allowed to tag this session: #{inspect(reason)}"

  defp assume_role_error_message({:caller_set_source_identity_denied, reason}),
    do: "Caller is not allowed to set source identity: #{inspect(reason)}"

  defp assume_role_error_message({:set_source_identity_denied, reason}),
    do: "Role trust policy does not allow source identity: #{inspect(reason)}"

  defp assume_role_error_message(reason), do: "AssumeRole failed: #{inspect(reason)}"

  defp new_secret_view(session) do
    %{
      access_key_id: session.access_key_id,
      assumed_role_arn: Map.get(session, :assumed_role_arn),
      secret_key: session.secret_key,
      session_token: session.session_token,
      expires_at: format_datetime(session.expires_at)
    }
  end

  defp refresh_sessions(socket) do
    sessions = list_sessions(socket.assigns.filters)

    socket
    |> assign(:session_count, length(sessions))
    |> stream(:sessions, sessions, reset: true, dom_id: &session_dom_id/1)
  end

  defp list_sessions(filters) do
    STS.list_sessions(
      issuer_access_key_id: Map.get(filters, "issuer_access_key_id", ""),
      principal_arn: Map.get(filters, "principal_arn", "")
    )
  end

  defp create_form do
    create_form(%{
      "issuer_access_key_id" => "",
      "duration_seconds" => @default_duration_seconds,
      "session_name" => ""
    })
  end

  defp create_form(params), do: to_form(params, as: :session)

  defp assume_role_form do
    assume_role_form(%{
      "caller_access_key_id" => "",
      "role_arn" => "",
      "session_name" => "",
      "duration_seconds" => @default_duration_seconds,
      "external_id" => "",
      "source_identity" => "",
      "mfa_serial" => "",
      "mfa_token_code" => "",
      "session_tags" => "",
      "transitive_tag_keys" => "",
      "policy_arns" => "",
      "session_policy" => ""
    })
  end

  defp assume_role_form(params), do: to_form(params, as: :assume_role)

  defp filter_form(params), do: to_form(params, as: :filter)

  defp default_filters do
    %{"issuer_access_key_id" => "", "principal_arn" => ""}
  end

  defp normalize_filters(params) do
    %{
      "issuer_access_key_id" => params |> Map.get("issuer_access_key_id") |> trim(),
      "principal_arn" => params |> Map.get("principal_arn") |> trim()
    }
  end

  defp session_dom_id(%{access_key_id: access_key_id}),
    do: "sts-session-#{dom_suffix(access_key_id)}"

  defp dom_suffix(value), do: Base.encode16(to_string(value), case: :lower)

  defp status_badge_class(%{status: "active"}), do: "badge-success"
  defp status_badge_class(%{status: "revoked"}), do: "badge-warning"
  defp status_badge_class(_session), do: "badge-ghost"

  defp format_datetime(nil), do: "n/a"

  defp format_datetime(%DateTime{} = value),
    do: value |> DateTime.truncate(:second) |> DateTime.to_iso8601()

  defp format_datetime(value), do: to_string(value)

  defp lines(value) do
    value
    |> to_string()
    |> String.split(["\r\n", "\n"], trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp split_values(value) do
    value
    |> to_string()
    |> String.split([",", "\r\n", "\n"], trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp trim(value) when is_binary(value), do: String.trim(value)
  defp trim(_value), do: ""
end
