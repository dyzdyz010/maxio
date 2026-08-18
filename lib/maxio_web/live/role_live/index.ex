defmodule MaxioWeb.RoleLive.Index do
  @moduledoc "Console IAM role and managed policy management."
  use MaxioWeb, :live_view

  alias Maxio.IAM

  @managed_policy_template """
  {
    "Version": "2012-10-17",
    "Statement": {
      "Effect": "Allow",
      "Action": "s3:ListAllMyBuckets",
      "Resource": "*"
    }
  }
  """

  @impl true
  def mount(_params, _session, socket) do
    roles = IAM.list_roles()
    managed_policies = IAM.list_managed_policies()

    {:ok,
     socket
     |> assign(:page_title, "Roles")
     |> assign(:role_count, length(roles))
     |> assign(:managed_policy_count, length(managed_policies))
     |> assign(:create_role_form, create_role_form())
     |> assign(:managed_policy_form, managed_policy_form())
     |> assign(:attach_form, attach_form())
     |> assign(:policy_options, policy_options(managed_policies))
     |> assign(:selected_role, nil)
     |> stream(:roles, roles, dom_id: &role_dom_id/1)
     |> stream(:role_policies, [], dom_id: &role_policy_dom_id/1)
     |> stream(:managed_policies, managed_policies, dom_id: &managed_policy_dom_id/1)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_principal}>
      <.header>
        Roles
        <:subtitle>{@role_count} IAM roles / {@managed_policy_count} managed policies</:subtitle>
        <:actions>
          <.button navigate={~p"/users"}>
            <.icon name="hero-user" class="size-4" /> Users
          </.button>
          <.button navigate={~p"/groups"}>
            <.icon name="hero-user-group" class="size-4" /> Groups
          </.button>
        </:actions>
      </.header>

      <section id="create-role-panel" class="mb-6 rounded-box border border-base-300 bg-base-100 p-4">
        <.form for={@create_role_form} id="create-role-form" phx-submit="create_role">
          <div class="grid gap-3 lg:grid-cols-[minmax(0,1fr)_12rem]">
            <.input
              field={@create_role_form[:name]}
              type="text"
              label="Role name"
              placeholder="console-writer"
              required
            />
            <.input
              field={@create_role_form[:duration]}
              type="number"
              label="Max session seconds"
              min="3600"
              max="43200"
            />
          </div>
          <div class="mt-3">
            <.input
              field={@create_role_form[:trust_policy]}
              type="textarea"
              rows="10"
              label="Trust policy JSON"
              class="w-full textarea font-mono text-xs"
            />
          </div>
          <div class="mt-3 flex justify-end">
            <.button variant="primary" id="create-role-submit" type="submit">
              <.icon name="hero-plus" class="size-4" /> Create role
            </.button>
          </div>
        </.form>
      </section>

      <div class="grid gap-6 xl:grid-cols-[minmax(0,1fr)_minmax(24rem,0.9fr)]">
        <section id="roles-panel">
          <table class="table table-zebra">
            <thead>
              <tr>
                <th>Role</th>
                <th>Max session</th>
                <th>ARN</th>
                <th class="w-0"></th>
              </tr>
            </thead>
            <tbody id="roles" phx-update="stream">
              <tr class="hidden only:table-row" id="roles-empty">
                <td colspan="4" class="text-center text-base-content/60">No IAM roles yet.</td>
              </tr>
              <tr :for={{dom_id, role} <- @streams.roles} id={dom_id}>
                <td class="font-medium">{role.role_name}</td>
                <td>{role.max_session_duration_seconds}s</td>
                <td class="break-all font-mono text-xs text-base-content/60">{role.role_arn}</td>
                <td>
                  <div class="flex justify-end gap-2">
                    <.button
                      id={"select-role-#{dom_suffix(role.role_name)}"}
                      phx-click="select_role"
                      phx-value-arn={role.role_arn}
                      title="Manage role"
                      aria-label={"Manage role #{role.role_name}"}
                    >
                      <.icon name="hero-adjustments-horizontal" class="size-4" />
                    </.button>
                    <.button
                      id={"delete-role-#{dom_suffix(role.role_name)}"}
                      phx-click="delete_role"
                      phx-value-arn={role.role_arn}
                      data-confirm={"Delete IAM role #{role.role_name}?"}
                    >
                      <.icon name="hero-trash" class="size-4" />
                    </.button>
                  </div>
                </td>
              </tr>
            </tbody>
          </table>

          <section
            :if={@selected_role}
            id="role-detail-panel"
            class="mt-6 rounded-box border border-base-300 bg-base-100 p-4"
          >
            <div class="mb-4 flex flex-col gap-1">
              <h2 class="text-base font-semibold">{@selected_role.role_name}</h2>
              <p id="selected-role-arn" class="break-all font-mono text-xs text-base-content/60">
                {@selected_role.role_arn}
              </p>
            </div>

            <div class="grid gap-5 lg:grid-cols-2">
              <div id="role-trust-policy-panel">
                <h3 class="mb-2 text-sm font-semibold">Trust policy</h3>
                <pre
                  id="role-trust-policy-json"
                  class="max-h-80 overflow-auto rounded-box bg-base-200 p-3 text-xs"
                ><code>{trust_policy_json(@selected_role)}</code></pre>
              </div>

              <div id="role-managed-policies-panel">
                <h3 class="mb-2 text-sm font-semibold">Attached managed policies</h3>
                <div id="role-policy-list" phx-update="stream" class="space-y-2">
                  <div id="role-policy-empty" class="hidden only:block text-sm text-base-content/60">
                    No managed policies are attached to this role.
                  </div>
                  <div
                    :for={{dom_id, policy} <- @streams.role_policies}
                    id={dom_id}
                    class="flex items-center justify-between gap-3 rounded-box border border-base-300 px-3 py-2"
                  >
                    <div class="min-w-0">
                      <div class="font-mono text-sm">{policy.policy_name}</div>
                      <div class="break-all font-mono text-xs text-base-content/60">
                        {policy.policy_arn}
                      </div>
                    </div>
                    <.button
                      id={"detach-role-policy-#{dom_suffix(policy.policy_arn)}"}
                      phx-click="detach_role_policy"
                      phx-value-policy-arn={policy.policy_arn}
                    >
                      <.icon name="hero-x-mark" class="size-4" />
                    </.button>
                  </div>
                </div>

                <.form
                  for={@attach_form}
                  id="role-attach-policy-form"
                  phx-submit="attach_role_policy"
                  class="mt-4"
                >
                  <div class="grid gap-3 sm:grid-cols-[minmax(0,1fr)_auto] sm:items-end">
                    <.input
                      field={@attach_form[:policy_arn]}
                      type="select"
                      label="Attach managed policy"
                      options={@policy_options}
                      prompt="Select a policy"
                    />
                    <.button id="role-attach-policy-submit" type="submit">
                      <.icon name="hero-plus" class="size-4" /> Attach
                    </.button>
                  </div>
                </.form>
              </div>
            </div>
          </section>
        </section>

        <section
          id="managed-policies-panel"
          class="rounded-box border border-base-300 bg-base-100 p-4"
        >
          <h2 class="mb-3 text-base font-semibold">Managed policies</h2>

          <.form
            for={@managed_policy_form}
            id="create-managed-policy-form"
            phx-submit="create_managed_policy"
            class="space-y-3"
          >
            <div class="grid gap-3 md:grid-cols-[minmax(0,1fr)_10rem]">
              <.input
                field={@managed_policy_form[:name]}
                type="text"
                label="Policy name"
                placeholder="readonly"
                required
              />
              <.input field={@managed_policy_form[:path]} type="text" label="Path" />
            </div>
            <.input
              field={@managed_policy_form[:json]}
              type="textarea"
              rows="10"
              label="Policy JSON"
              class="w-full textarea font-mono text-xs"
            />
            <.button variant="primary" id="create-managed-policy-submit" type="submit">
              <.icon name="hero-document-plus" class="size-4" /> Create policy
            </.button>
          </.form>

          <div id="managed-policy-list" phx-update="stream" class="mt-5 space-y-2">
            <div id="managed-policy-empty" class="hidden only:block text-sm text-base-content/60">
              No managed policies yet.
            </div>
            <div
              :for={{dom_id, policy} <- @streams.managed_policies}
              id={dom_id}
              class="flex items-center justify-between gap-3 rounded-box border border-base-300 px-3 py-2"
            >
              <div class="min-w-0">
                <div class="font-mono text-sm">{policy.policy_name}</div>
                <div class="break-all font-mono text-xs text-base-content/60">
                  {policy.policy_arn}
                </div>
              </div>
              <.button
                id={"delete-managed-policy-#{dom_suffix(policy.policy_arn)}"}
                phx-click="delete_managed_policy"
                phx-value-policy-arn={policy.policy_arn}
                data-confirm={"Delete managed policy #{policy.policy_name}?"}
              >
                <.icon name="hero-trash" class="size-4" />
              </.button>
            </div>
          </div>
        </section>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def handle_event("create_role", %{"role" => params}, socket) do
    name = params |> Map.get("name", "") |> String.trim()
    trust_policy = params |> Map.get("trust_policy", "") |> String.trim()

    with {:ok, duration} <- parse_duration(Map.get(params, "duration", "3600")),
         false <- name == "",
         false <- trust_policy == "",
         {:ok, role} <-
           IAM.create_role(
             role_name: name,
             trust_policy: trust_policy,
             max_session_duration_seconds: duration
           ) do
      {:noreply,
       socket
       |> stream_insert(:roles, role, at: 0)
       |> update(:role_count, &(&1 + 1))
       |> assign(:create_role_form, create_role_form())
       |> put_flash(:info, "Created IAM role #{role.role_name}")}
    else
      true ->
        {:noreply,
         socket
         |> assign(:create_role_form, create_role_form(params))
         |> put_flash(:error, "Role name and trust policy are required")}

      {:error, :duration} ->
        {:noreply,
         socket
         |> assign(:create_role_form, create_role_form(params))
         |> put_flash(:error, "Max session duration must be between 3600 and 43200 seconds")}

      {:error, _reason} ->
        {:noreply,
         socket
         |> assign(:create_role_form, create_role_form(params))
         |> put_flash(:error, "Create role failed")}
    end
  end

  @impl true
  def handle_event("delete_role", %{"arn" => role_arn}, socket) do
    role = current_role(role_arn)
    :ok = IAM.delete_role(role_arn)

    if role do
      {:noreply,
       socket
       |> stream_delete(:roles, role)
       |> update(:role_count, &max(&1 - 1, 0))
       |> maybe_clear_selected_role(role_arn)
       |> put_flash(:info, "Deleted IAM role #{role.role_name}")}
    else
      {:noreply, put_flash(socket, :error, "IAM role not found")}
    end
  end

  @impl true
  def handle_event("select_role", %{"arn" => role_arn}, socket) do
    case current_role(role_arn) do
      nil -> {:noreply, socket |> clear_role_detail() |> put_flash(:error, "IAM role not found")}
      role -> {:noreply, load_role_detail(socket, role)}
    end
  end

  @impl true
  def handle_event("create_managed_policy", %{"managed_policy" => params}, socket) do
    name = params |> Map.get("name", "") |> String.trim()
    path = params |> Map.get("path", "/") |> String.trim()
    json = params |> Map.get("json", "") |> String.trim()

    with false <- name == "",
         false <- json == "",
         {:ok, policy} <- IAM.create_managed_policy(name: name, path: path, policy: json) do
      managed_policies = IAM.list_managed_policies()

      {:noreply,
       socket
       |> stream_insert(:managed_policies, policy, at: 0)
       |> update(:managed_policy_count, &(&1 + 1))
       |> assign(:managed_policy_form, managed_policy_form())
       |> assign(:policy_options, policy_options(managed_policies))
       |> put_flash(:info, "Created managed policy #{policy.policy_name}")}
    else
      true ->
        {:noreply,
         socket
         |> assign(:managed_policy_form, managed_policy_form(params))
         |> put_flash(:error, "Policy name and JSON are required")}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(:managed_policy_form, managed_policy_form(params))
         |> put_flash(:error, "Create managed policy failed: #{inspect(reason)}")}
    end
  end

  @impl true
  def handle_event("delete_managed_policy", %{"policy-arn" => policy_arn}, socket) do
    policy = current_managed_policy(policy_arn)

    case IAM.delete_managed_policy(policy_arn) do
      :ok ->
        managed_policies = IAM.list_managed_policies()

        socket =
          socket
          |> assign(:policy_options, policy_options(managed_policies))
          |> assign(:managed_policy_count, length(managed_policies))

        socket =
          if policy do
            stream_delete(socket, :managed_policies, policy)
          else
            stream(socket, :managed_policies, managed_policies,
              reset: true,
              dom_id: &managed_policy_dom_id/1
            )
          end

        {:noreply, put_flash(socket, :info, "Deleted managed policy")}

      {:error, :policy_attached} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "Detach this policy from users, groups, or roles before deleting it"
         )}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Delete managed policy failed: #{inspect(reason)}")}
    end
  end

  @impl true
  def handle_event("attach_role_policy", %{"attachment" => %{"policy_arn" => policy_arn}}, socket) do
    policy_arn = String.trim(policy_arn || "")

    with %{role_arn: role_arn} = role <- socket.assigns.selected_role,
         false <- policy_arn == "",
         :ok <- IAM.attach_role_policy(role_arn, policy_arn) do
      {:noreply,
       socket
       |> load_role_detail(role)
       |> put_flash(:info, "Attached managed policy")}
    else
      nil ->
        {:noreply, put_flash(socket, :error, "Select a role first")}

      true ->
        {:noreply, put_flash(socket, :error, "Select a managed policy first")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Attach managed policy failed: #{inspect(reason)}")}
    end
  end

  def handle_event("attach_role_policy", _params, socket) do
    {:noreply, put_flash(socket, :error, "Select a role first")}
  end

  @impl true
  def handle_event("detach_role_policy", %{"policy-arn" => policy_arn}, socket) do
    case socket.assigns.selected_role do
      %{role_arn: role_arn} = role ->
        case IAM.detach_role_policy(role_arn, policy_arn) do
          :ok ->
            {:noreply,
             socket
             |> load_role_detail(role)
             |> put_flash(:info, "Detached managed policy")}

          {:error, reason} ->
            {:noreply,
             socket
             |> load_role_detail(role)
             |> put_flash(:error, "Detach managed policy failed: #{inspect(reason)}")}
        end

      nil ->
        {:noreply, put_flash(socket, :error, "Select a role first")}
    end
  end

  def handle_event("detach_role_policy", _params, socket) do
    case socket.assigns.selected_role do
      nil ->
        {:noreply, put_flash(socket, :error, "Select a role first")}

      role ->
        {:noreply,
         socket
         |> load_role_detail(role)
         |> put_flash(:error, "Detach managed policy failed: :malformed")}
    end
  end

  defp load_role_detail(socket, role) do
    attached_policies = IAM.list_attached_role_policies(role.role_arn)
    managed_policies = IAM.list_managed_policies()

    socket
    |> assign(:selected_role, role)
    |> assign(:attach_form, attach_form())
    |> assign(:policy_options, policy_options(managed_policies))
    |> stream(:role_policies, attached_policies, reset: true, dom_id: &role_policy_dom_id/1)
  end

  defp maybe_clear_selected_role(socket, role_arn) do
    case socket.assigns.selected_role do
      %{role_arn: ^role_arn} -> clear_role_detail(socket)
      _other -> socket
    end
  end

  defp clear_role_detail(socket) do
    socket
    |> assign(:selected_role, nil)
    |> assign(:attach_form, attach_form())
    |> stream(:role_policies, [], reset: true, dom_id: &role_policy_dom_id/1)
  end

  defp current_role(role_arn) do
    case IAM.get_role_by_arn(role_arn) do
      {:ok, role} -> role
      :error -> nil
    end
  end

  defp current_managed_policy(policy_arn) do
    IAM.list_managed_policies()
    |> Enum.find(&(&1.policy_arn == policy_arn))
  end

  defp policy_options(policies) do
    Enum.map(policies, &{"#{&1.policy_name} (#{&1.path})", &1.policy_arn})
  end

  defp trust_policy_json(%{trust_policy: trust_policy}) do
    Jason.encode!(trust_policy, pretty: true)
  end

  defp parse_duration(value) do
    case Integer.parse(to_string(value)) do
      {duration, ""} when duration >= 3600 and duration <= 43_200 -> {:ok, duration}
      _other -> {:error, :duration}
    end
  end

  defp create_role_form do
    create_role_form(%{
      "name" => "",
      "duration" => "3600",
      "trust_policy" => default_trust_policy()
    })
  end

  defp create_role_form(params), do: to_form(params, as: :role)

  defp managed_policy_form do
    managed_policy_form(%{"name" => "", "path" => "/", "json" => @managed_policy_template})
  end

  defp managed_policy_form(params), do: to_form(params, as: :managed_policy)

  defp attach_form, do: to_form(%{"policy_arn" => ""}, as: :attachment)

  defp default_trust_policy do
    Jason.encode!(
      %{
        "Version" => "2012-10-17",
        "Statement" => %{
          "Effect" => "Allow",
          "Principal" => %{"AWS" => IAM.root_principal_arn()},
          "Action" => "sts:AssumeRole"
        }
      },
      pretty: true
    )
  end

  defp role_dom_id(%{role_name: role_name}), do: "roles-#{dom_suffix(role_name)}"
  defp role_policy_dom_id(%{policy_arn: policy_arn}), do: "role-policy-#{dom_suffix(policy_arn)}"

  defp managed_policy_dom_id(%{policy_arn: policy_arn}),
    do: "managed-policy-#{dom_suffix(policy_arn)}"

  defp dom_suffix(value), do: Base.encode16(to_string(value), case: :lower)
end
