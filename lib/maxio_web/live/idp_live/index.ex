defmodule MaxioWeb.IdpLive.Index do
  @moduledoc "Console IAM OpenID Connect identity provider management."
  use MaxioWeb, :live_view

  alias Maxio.IAM

  @status_options [{"Active", "active"}, {"Disabled", "disabled"}]
  @thumbprint_pattern ~r/\A[0-9A-Fa-f]{40}\z/

  @impl true
  def mount(_params, _session, socket) do
    if root_principal?(socket.assigns.current_principal) do
      providers = IAM.list_oidc_providers()

      {:ok,
       socket
       |> assign(:page_title, "Identity Providers")
       |> assign(:provider_count, length(providers))
       |> assign(:status_options, @status_options)
       |> assign(:create_form, create_form())
       |> assign(:client_id_form, client_id_form())
       |> assign(:thumbprints_form, thumbprints_form())
       |> assign(:jwks_form, jwks_form())
       |> assign(:status_form, status_form())
       |> assign(:selected_provider, nil)
       |> stream(:oidc_providers, providers, dom_id: &provider_dom_id/1)
       |> stream(:provider_client_ids, [], dom_id: &client_id_dom_id/1)
       |> stream(:provider_thumbprints, [], dom_id: &thumbprint_dom_id/1)}
    else
      {:ok,
       socket
       |> put_flash(:error, "Root console access is required")
       |> redirect(to: ~p"/")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_principal}>
      <.header>
        Identity Providers
        <:subtitle>{@provider_count} OIDC providers</:subtitle>
        <:actions>
          <.button navigate={~p"/roles"}>
            <.icon name="hero-identification" class="size-4" /> Roles
          </.button>
          <.button navigate={~p"/sts-sessions"}>
            <.icon name="hero-clock" class="size-4" /> STS Sessions
          </.button>
        </:actions>
      </.header>

      <section
        id="create-oidc-provider-panel"
        class="mb-6 rounded-box border border-base-300 bg-base-100 p-4"
      >
        <.form for={@create_form} id="create-oidc-provider-form" phx-submit="create_provider">
          <div class="grid gap-3 lg:grid-cols-[minmax(0,1fr)_12rem]">
            <.input
              field={@create_form[:issuer_url]}
              type="text"
              label="Issuer URL"
              placeholder="https://issuer.example.test/tenant"
              required
            />
            <.input
              field={@create_form[:status]}
              type="select"
              label="Status"
              options={@status_options}
            />
          </div>
          <div class="mt-3 grid gap-3 lg:grid-cols-2">
            <.input
              field={@create_form[:client_ids]}
              type="textarea"
              rows="4"
              label="Client IDs"
              placeholder="sts.amazonaws.com"
              class="w-full textarea font-mono text-xs"
              required
            />
            <.input
              field={@create_form[:thumbprints]}
              type="textarea"
              rows="4"
              label="Thumbprints"
              placeholder="40 character SHA1 hex"
              class="w-full textarea font-mono text-xs"
              required
            />
          </div>
          <div class="mt-3">
            <.input
              field={@create_form[:jwks_json]}
              type="textarea"
              rows="7"
              label="JWKS JSON"
              placeholder={~s({"keys":[...]})}
              class="w-full textarea font-mono text-xs"
            />
          </div>
          <div class="mt-3 flex justify-end">
            <.button variant="primary" id="create-oidc-provider-submit" type="submit">
              <.icon name="hero-plus" class="size-4" /> Create provider
            </.button>
          </div>
        </.form>
      </section>

      <div class="grid gap-6 xl:grid-cols-[minmax(0,1fr)_minmax(24rem,0.9fr)]">
        <section id="oidc-providers-panel">
          <table class="table table-zebra">
            <thead>
              <tr>
                <th>Issuer</th>
                <th>Status</th>
                <th>Client IDs</th>
                <th>Keys</th>
                <th class="w-0"></th>
              </tr>
            </thead>
            <tbody id="oidc-providers" phx-update="stream">
              <tr class="hidden only:table-row" id="oidc-providers-empty">
                <td colspan="5" class="text-center text-base-content/60">
                  No OIDC providers yet.
                </td>
              </tr>
              <tr :for={{dom_id, provider} <- @streams.oidc_providers} id={dom_id}>
                <td class="min-w-64">
                  <div class="break-all font-mono text-sm">{provider.issuer_url}</div>
                  <div class="mt-1 break-all font-mono text-xs text-base-content/60">
                    {provider.provider_arn}
                  </div>
                </td>
                <td>
                  <span class={["badge badge-sm", status_badge_class(provider)]}>
                    {provider.status}
                  </span>
                </td>
                <td class="font-mono text-sm">{length(provider.client_ids)}</td>
                <td class="font-mono text-sm">{jwks_key_count(provider)}</td>
                <td>
                  <div class="flex justify-end gap-2">
                    <.button
                      id={"select-oidc-provider-#{dom_suffix(provider.provider_arn)}"}
                      phx-click="select_provider"
                      phx-value-arn={provider.provider_arn}
                      title="Manage provider"
                      aria-label={"Manage OIDC provider #{provider.issuer_url}"}
                    >
                      <.icon name="hero-adjustments-horizontal" class="size-4" />
                    </.button>
                    <.button
                      id={"delete-oidc-provider-#{dom_suffix(provider.provider_arn)}"}
                      phx-click="delete_provider"
                      phx-value-arn={provider.provider_arn}
                      data-confirm={"Delete OIDC provider #{provider.issuer_url}?"}
                    >
                      <.icon name="hero-trash" class="size-4" />
                    </.button>
                  </div>
                </td>
              </tr>
            </tbody>
          </table>
        </section>

        <section
          :if={@selected_provider}
          id="oidc-provider-detail-panel"
          class="rounded-box border border-base-300 bg-base-100 p-4"
        >
          <div class="mb-4 flex flex-col gap-1">
            <div class="flex items-center justify-between gap-3">
              <h2 class="break-all text-base font-semibold">{@selected_provider.issuer_url}</h2>
              <span class={["badge badge-sm", status_badge_class(@selected_provider)]}>
                {@selected_provider.status}
              </span>
            </div>
            <p
              id="selected-oidc-provider-arn"
              class="break-all font-mono text-xs text-base-content/60"
            >
              {@selected_provider.provider_arn}
            </p>
            <p class="break-all font-mono text-xs text-base-content/60">
              {@selected_provider.issuer_host_path}
            </p>
          </div>

          <.form
            for={@status_form}
            id="oidc-provider-status-form"
            phx-submit="update_status"
            class="mb-5"
          >
            <div class="grid gap-3 sm:grid-cols-[minmax(0,1fr)_auto] sm:items-end">
              <.input
                field={@status_form[:status]}
                type="select"
                label="Status"
                options={@status_options}
              />
              <.button id="oidc-provider-status-submit" type="submit">
                <.icon name="hero-check" class="size-4" /> Save
              </.button>
            </div>
          </.form>

          <div class="grid gap-5 lg:grid-cols-2">
            <div id="oidc-client-ids-panel">
              <h3 class="mb-2 text-sm font-semibold">Client IDs</h3>
              <div id="oidc-client-id-list" phx-update="stream" class="space-y-2">
                <div id="oidc-client-ids-empty" class="hidden only:block text-sm text-base-content/60">
                  No client IDs.
                </div>
                <div
                  :for={{dom_id, client_id} <- @streams.provider_client_ids}
                  id={dom_id}
                  class="flex items-center justify-between gap-3 rounded-box border border-base-300 px-3 py-2"
                >
                  <span class="break-all font-mono text-sm">{client_id.value}</span>
                  <.button
                    id={"remove-oidc-client-id-#{dom_suffix(client_id.value)}"}
                    phx-click="remove_client_id"
                    phx-value-client-id={client_id.value}
                  >
                    <.icon name="hero-x-mark" class="size-4" />
                  </.button>
                </div>
              </div>

              <.form
                for={@client_id_form}
                id="oidc-client-id-form"
                phx-submit="add_client_id"
                class="mt-4"
              >
                <div class="grid gap-3 sm:grid-cols-[minmax(0,1fr)_auto] sm:items-end">
                  <.input
                    field={@client_id_form[:client_id]}
                    type="text"
                    label="Add client ID"
                    placeholder="sts.amazonaws.com"
                  />
                  <.button id="oidc-client-id-submit" type="submit">
                    <.icon name="hero-plus" class="size-4" /> Add
                  </.button>
                </div>
              </.form>
            </div>

            <div id="oidc-thumbprints-panel">
              <h3 class="mb-2 text-sm font-semibold">Thumbprints</h3>
              <div id="oidc-thumbprint-list" phx-update="stream" class="space-y-2">
                <div
                  id="oidc-thumbprints-empty"
                  class="hidden only:block text-sm text-base-content/60"
                >
                  No thumbprints.
                </div>
                <div
                  :for={{dom_id, thumbprint} <- @streams.provider_thumbprints}
                  id={dom_id}
                  class="rounded-box border border-base-300 px-3 py-2 font-mono text-sm"
                >
                  {thumbprint.value}
                </div>
              </div>

              <.form
                for={@thumbprints_form}
                id="oidc-thumbprints-form"
                phx-submit="update_thumbprints"
                class="mt-4"
              >
                <.input
                  field={@thumbprints_form[:values]}
                  type="textarea"
                  rows="4"
                  label="Replace thumbprints"
                  class="w-full textarea font-mono text-xs"
                />
                <div class="mt-3 flex justify-end">
                  <.button id="oidc-thumbprints-submit" type="submit">
                    <.icon name="hero-arrow-path" class="size-4" /> Replace
                  </.button>
                </div>
              </.form>
            </div>
          </div>

          <section id="oidc-jwks-panel" class="mt-5">
            <div class="mb-2 flex flex-wrap items-center justify-between gap-2">
              <h3 class="text-sm font-semibold">JWKS snapshot</h3>
              <span id="oidc-jwks-key-count" class="badge badge-ghost badge-sm">
                {jwks_key_count(@selected_provider)} keys
              </span>
            </div>
            <p id="oidc-jwks-fetched-at" class="mb-2 font-mono text-xs text-base-content/60">
              {format_datetime(@selected_provider.jwks_fetched_at)}
            </p>
            <.form for={@jwks_form} id="oidc-jwks-form" phx-submit="update_jwks">
              <.input
                field={@jwks_form[:json]}
                type="textarea"
                rows="9"
                label="Replace JWKS JSON"
                class="w-full textarea font-mono text-xs"
              />
              <div class="mt-3 flex justify-end">
                <.button id="oidc-jwks-submit" type="submit">
                  <.icon name="hero-key" class="size-4" /> Replace JWKS
                </.button>
              </div>
            </.form>
          </section>
        </section>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def handle_event("create_provider", %{"provider" => params}, socket) do
    case create_opts(params) do
      {:ok, opts} ->
        case IAM.create_oidc_provider(opts) do
          {:ok, provider} ->
            {:noreply,
             socket
             |> stream_insert(:oidc_providers, provider, at: 0)
             |> update(:provider_count, &(&1 + 1))
             |> assign(:create_form, create_form())
             |> put_flash(:info, "Created OIDC provider")}

          {:error, reason} ->
            {:noreply,
             socket
             |> assign(:create_form, create_form(params))
             |> put_flash(:error, provider_error_message("Create OIDC provider failed", reason))}
        end

      {:error, message} ->
        {:noreply,
         socket
         |> assign(:create_form, create_form(params))
         |> put_flash(:error, message)}
    end
  end

  def handle_event("create_provider", _params, socket) do
    {:noreply, put_flash(socket, :error, "OIDC provider form payload is required")}
  end

  @impl true
  def handle_event("select_provider", %{"arn" => provider_arn}, socket) do
    case current_provider(provider_arn) do
      nil ->
        {:noreply,
         socket |> clear_provider_detail() |> put_flash(:error, "OIDC provider not found")}

      provider ->
        {:noreply, load_provider_detail(socket, provider)}
    end
  end

  @impl true
  def handle_event("delete_provider", %{"arn" => provider_arn}, socket) do
    provider = current_provider(provider_arn)

    case IAM.delete_oidc_provider(provider_arn) do
      :ok ->
        socket =
          if provider do
            stream_delete(socket, :oidc_providers, provider)
          else
            refresh_providers(socket)
          end

        {:noreply,
         socket
         |> update(:provider_count, &max(&1 - 1, 0))
         |> maybe_clear_selected_provider(provider_arn)
         |> put_flash(:info, "Deleted OIDC provider")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Delete OIDC provider failed: #{inspect(reason)}")}
    end
  end

  def handle_event("delete_provider", _params, socket) do
    {:noreply, put_flash(socket, :error, "OIDC provider ARN is required")}
  end

  @impl true
  def handle_event("add_client_id", %{"client" => %{"client_id" => client_id}}, socket) do
    client_id = trim(client_id)

    with %{provider_arn: provider_arn} <- socket.assigns.selected_provider,
         :ok <- require_nonempty(client_id, "Client ID is required"),
         {:ok, provider} <- IAM.add_oidc_provider_client_id(provider_arn, client_id) do
      {:noreply,
       socket
       |> load_provider_detail(provider)
       |> refresh_provider_row(provider)
       |> put_flash(:info, "Added OIDC client ID")}
    else
      nil ->
        {:noreply, put_flash(socket, :error, "Select an OIDC provider first")}

      {:error, message} when is_binary(message) ->
        {:noreply, put_flash(socket, :error, message)}

      {:error, reason} ->
        {:noreply,
         put_flash(socket, :error, provider_error_message("Add OIDC client ID failed", reason))}
    end
  end

  def handle_event("add_client_id", _params, socket) do
    {:noreply, put_flash(socket, :error, "Select an OIDC provider first")}
  end

  @impl true
  def handle_event("remove_client_id", %{"client-id" => client_id}, socket) do
    case socket.assigns.selected_provider do
      %{provider_arn: provider_arn} ->
        case IAM.remove_oidc_provider_client_id(provider_arn, client_id) do
          {:ok, provider} ->
            {:noreply,
             socket
             |> load_provider_detail(provider)
             |> refresh_provider_row(provider)
             |> put_flash(:info, "Removed OIDC client ID")}

          {:error, reason} ->
            {:noreply,
             put_flash(
               socket,
               :error,
               provider_error_message("Remove OIDC client ID failed", reason)
             )}
        end

      nil ->
        {:noreply, put_flash(socket, :error, "Select an OIDC provider first")}
    end
  end

  def handle_event("remove_client_id", _params, socket) do
    {:noreply, put_flash(socket, :error, "OIDC client ID is required")}
  end

  @impl true
  def handle_event("update_thumbprints", %{"thumbprints" => params}, socket) do
    case socket.assigns.selected_provider do
      %{provider_arn: provider_arn} ->
        with {:ok, thumbprints} <- thumbprints(Map.get(params, "values")),
             {:ok, provider} <- IAM.update_oidc_provider_thumbprints(provider_arn, thumbprints) do
          {:noreply,
           socket
           |> load_provider_detail(provider)
           |> refresh_provider_row(provider)
           |> put_flash(:info, "Updated OIDC thumbprints")}
        else
          {:error, message} when is_binary(message) ->
            {:noreply,
             socket
             |> assign(:thumbprints_form, thumbprints_form(params))
             |> put_flash(:error, message)}

          {:error, reason} ->
            {:noreply,
             socket
             |> assign(:thumbprints_form, thumbprints_form(params))
             |> put_flash(
               :error,
               provider_error_message("Update OIDC thumbprints failed", reason)
             )}
        end

      nil ->
        {:noreply, put_flash(socket, :error, "Select an OIDC provider first")}
    end
  end

  def handle_event("update_thumbprints", _params, socket) do
    {:noreply, put_flash(socket, :error, "OIDC thumbprints form payload is required")}
  end

  @impl true
  def handle_event("update_jwks", %{"jwks" => params}, socket) do
    case socket.assigns.selected_provider do
      %{provider_arn: provider_arn} ->
        with {:ok, jwks} <- required_json_object(Map.get(params, "json"), "JWKS JSON is required"),
             {:ok, provider} <- IAM.set_oidc_provider_jwks(provider_arn, jwks) do
          {:noreply,
           socket
           |> load_provider_detail(provider)
           |> refresh_provider_row(provider)
           |> put_flash(:info, "Updated OIDC JWKS")}
        else
          {:error, message} when is_binary(message) ->
            {:noreply,
             socket
             |> assign(:jwks_form, jwks_form(params))
             |> put_flash(:error, message)}

          {:error, reason} ->
            {:noreply,
             socket
             |> assign(:jwks_form, jwks_form(params))
             |> put_flash(:error, provider_error_message("Update OIDC JWKS failed", reason))}
        end

      nil ->
        {:noreply, put_flash(socket, :error, "Select an OIDC provider first")}
    end
  end

  def handle_event("update_jwks", _params, socket) do
    {:noreply, put_flash(socket, :error, "OIDC JWKS form payload is required")}
  end

  @impl true
  def handle_event("update_status", %{"status" => %{"status" => status}}, socket) do
    case socket.assigns.selected_provider do
      %{provider_arn: provider_arn} ->
        with {:ok, status} <- status(status),
             {:ok, provider} <- IAM.update_oidc_provider_status(provider_arn, status) do
          {:noreply,
           socket
           |> load_provider_detail(provider)
           |> refresh_provider_row(provider)
           |> put_flash(:info, "Updated OIDC provider status")}
        else
          {:error, message} when is_binary(message) ->
            {:noreply, put_flash(socket, :error, message)}

          {:error, reason} ->
            {:noreply,
             put_flash(
               socket,
               :error,
               provider_error_message("Update OIDC status failed", reason)
             )}
        end

      nil ->
        {:noreply, put_flash(socket, :error, "Select an OIDC provider first")}
    end
  end

  def handle_event("update_status", _params, socket) do
    {:noreply, put_flash(socket, :error, "OIDC status form payload is required")}
  end

  defp create_opts(params) do
    issuer_url = params |> Map.get("issuer_url") |> trim()

    with :ok <- require_nonempty(issuer_url, "Issuer URL is required"),
         :ok <- require_https_url(issuer_url),
         {:ok, client_ids} <- client_ids(Map.get(params, "client_ids")),
         {:ok, thumbprints} <- thumbprints(Map.get(params, "thumbprints")),
         {:ok, status} <- status(Map.get(params, "status", "active")),
         {:ok, jwks} <- optional_json_object(Map.get(params, "jwks_json")) do
      opts = [
        url: issuer_url,
        client_ids: client_ids,
        thumbprints: thumbprints,
        status: status
      ]

      {:ok, maybe_put_jwks(opts, jwks)}
    end
  end

  defp maybe_put_jwks(opts, nil), do: opts
  defp maybe_put_jwks(opts, jwks), do: Keyword.put(opts, :jwks, jwks)

  defp client_ids(value) do
    values = split_values(value)

    if values == [] do
      {:error, "At least one client ID is required"}
    else
      {:ok, values}
    end
  end

  defp thumbprints(value) do
    thumbprints = split_values(value)

    cond do
      thumbprints == [] ->
        {:error, "At least one thumbprint is required"}

      length(thumbprints) > 5 ->
        {:error, "At most five thumbprints are allowed"}

      Enum.any?(thumbprints, &(not Regex.match?(@thumbprint_pattern, &1))) ->
        {:error, "Thumbprints must be 40 character SHA1 hex strings"}

      true ->
        {:ok, Enum.uniq_by(thumbprints, &String.downcase/1)}
    end
  end

  defp optional_json_object(value) do
    case trim(value) do
      "" -> {:ok, nil}
      json -> decode_json_object(json)
    end
  end

  defp required_json_object(value, empty_message) do
    case trim(value) do
      "" -> {:error, empty_message}
      json -> decode_json_object(json)
    end
  end

  defp decode_json_object(json) do
    case Jason.decode(json) do
      {:ok, %{} = object} -> {:ok, object}
      {:ok, _other} -> {:error, "JSON must be an object"}
      {:error, _reason} -> {:error, "JSON is malformed"}
    end
  end

  defp require_https_url(value) do
    uri = URI.parse(value)

    if uri.scheme == "https" and is_binary(uri.host) and uri.host != "" do
      :ok
    else
      {:error, "Issuer URL must be an HTTPS URL with a host"}
    end
  end

  defp require_nonempty("", message), do: {:error, message}
  defp require_nonempty(_value, _message), do: :ok

  defp status(value) do
    case trim(value) do
      "active" -> {:ok, "active"}
      "disabled" -> {:ok, "disabled"}
      _other -> {:error, "OIDC provider status is invalid"}
    end
  end

  defp load_provider_detail(socket, provider) do
    socket
    |> assign(:selected_provider, provider)
    |> assign(:client_id_form, client_id_form())
    |> assign(:thumbprints_form, thumbprints_form(provider))
    |> assign(:jwks_form, jwks_form(provider))
    |> assign(:status_form, status_form(provider))
    |> stream(:provider_client_ids, value_rows(provider.client_ids),
      reset: true,
      dom_id: &client_id_dom_id/1
    )
    |> stream(:provider_thumbprints, value_rows(provider.thumbprints),
      reset: true,
      dom_id: &thumbprint_dom_id/1
    )
  end

  defp clear_provider_detail(socket) do
    socket
    |> assign(:selected_provider, nil)
    |> assign(:client_id_form, client_id_form())
    |> assign(:thumbprints_form, thumbprints_form())
    |> assign(:jwks_form, jwks_form())
    |> assign(:status_form, status_form())
    |> stream(:provider_client_ids, [], reset: true, dom_id: &client_id_dom_id/1)
    |> stream(:provider_thumbprints, [], reset: true, dom_id: &thumbprint_dom_id/1)
  end

  defp maybe_clear_selected_provider(socket, provider_arn) do
    case socket.assigns.selected_provider do
      %{provider_arn: ^provider_arn} -> clear_provider_detail(socket)
      _other -> socket
    end
  end

  defp refresh_provider_row(socket, provider) do
    stream_insert(socket, :oidc_providers, provider)
  end

  defp refresh_providers(socket) do
    providers = IAM.list_oidc_providers()

    socket
    |> assign(:provider_count, length(providers))
    |> stream(:oidc_providers, providers, reset: true, dom_id: &provider_dom_id/1)
  end

  defp current_provider(provider_arn) do
    case IAM.get_oidc_provider(provider_arn) do
      {:ok, provider} -> provider
      _other -> nil
    end
  end

  defp root_principal?(%{type: :root, arn: "arn:aws:iam:::root"}), do: true
  defp root_principal?(%{type: "root", arn: "arn:aws:iam:::root"}), do: true
  defp root_principal?(_principal), do: false

  defp provider_error_message(prefix, %Ecto.Changeset{} = changeset) do
    "#{prefix}: #{changeset_message(changeset)}"
  end

  defp provider_error_message(prefix, reason), do: "#{prefix}: #{inspect(reason)}"

  defp changeset_message(changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {message, _opts} -> message end)
    |> Enum.flat_map(fn {field, messages} ->
      Enum.map(messages, &"#{field} #{&1}")
    end)
    |> case do
      [] -> "invalid provider"
      messages -> Enum.join(messages, "; ")
    end
  end

  defp create_form do
    create_form(%{
      "issuer_url" => "",
      "client_ids" => "sts.amazonaws.com",
      "thumbprints" => "",
      "jwks_json" => "",
      "status" => "active"
    })
  end

  defp create_form(params), do: to_form(params, as: :provider)
  defp client_id_form, do: to_form(%{"client_id" => ""}, as: :client)

  defp thumbprints_form do
    thumbprints_form(%{"values" => ""})
  end

  defp thumbprints_form(%{thumbprints: thumbprints}) do
    thumbprints_form(%{"values" => Enum.join(thumbprints || [], "\n")})
  end

  defp thumbprints_form(params), do: to_form(params, as: :thumbprints)

  defp jwks_form do
    jwks_form(%{"json" => ""})
  end

  defp jwks_form(%{jwks: _jwks}), do: jwks_form()
  defp jwks_form(params), do: to_form(params, as: :jwks)

  defp status_form do
    status_form(%{"status" => "active"})
  end

  defp status_form(%{status: status}) do
    status_form(%{"status" => status || "active"})
  end

  defp status_form(params), do: to_form(params, as: :status)

  defp value_rows(values) do
    values
    |> List.wrap()
    |> Enum.map(&%{value: &1})
  end

  defp provider_dom_id(%{provider_arn: provider_arn}),
    do: "oidc-provider-#{dom_suffix(provider_arn)}"

  defp client_id_dom_id(%{value: value}), do: "oidc-client-id-#{dom_suffix(value)}"
  defp thumbprint_dom_id(%{value: value}), do: "oidc-thumbprint-#{dom_suffix(value)}"

  defp status_badge_class(%{status: "active"}), do: "badge-success"
  defp status_badge_class(%{status: "disabled"}), do: "badge-warning"
  defp status_badge_class(_provider), do: "badge-ghost"

  defp jwks_key_count(%{jwks: %{"keys" => keys}}) when is_list(keys), do: length(keys)
  defp jwks_key_count(_provider), do: 0

  defp format_datetime(nil), do: "n/a"

  defp format_datetime(%DateTime{} = value),
    do: value |> DateTime.truncate(:second) |> DateTime.to_iso8601()

  defp format_datetime(value), do: to_string(value)

  defp split_values(value) do
    value
    |> to_string()
    |> String.split([",", "\r\n", "\n"], trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp trim(value) when is_binary(value), do: String.trim(value)
  defp trim(_value), do: ""

  defp dom_suffix(value), do: Base.encode16(to_string(value), case: :lower)
end
