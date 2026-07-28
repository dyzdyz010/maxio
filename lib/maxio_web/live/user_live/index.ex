defmodule MaxioWeb.UserLive.Index do
  @moduledoc "Console IAM user management."
  use MaxioWeb, :live_view

  alias Maxio.IAM

  @status_options [{"Active", "active"}, {"Inactive", "inactive"}]

  @impl true
  def mount(_params, _session, socket) do
    users = IAM.list_users()

    {:ok,
     socket
     |> assign(:page_title, "Users")
     |> assign(:user_count, length(users))
     |> assign(:status_options, @status_options)
     |> assign(:create_form, create_form())
     |> assign(:membership_form, membership_form())
     |> assign(:policy_attach_form, policy_attach_form())
     |> assign(:group_options, group_options())
     |> assign(:policy_options, policy_options())
     |> assign(:selected_user, nil)
     |> assign(:new_secret, nil)
     |> stream(:users, users, dom_id: &user_dom_id/1)
     |> stream(:user_groups, [], dom_id: &user_group_dom_id/1)
     |> stream(:user_access_keys, [], dom_id: &user_access_key_dom_id/1)
     |> stream(:user_managed_policies, [], dom_id: &user_managed_policy_dom_id/1)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_principal}>
      <.header>
        Users
        <:subtitle>{@user_count} IAM users</:subtitle>
        <:actions>
          <.button navigate={~p"/groups"}>
            <.icon name="hero-user-group" class="size-4" /> Groups
          </.button>
        </:actions>
      </.header>

      <div :if={@new_secret} id="user-new-secret-banner" class="alert alert-success mb-4 text-sm">
        <.icon name="hero-check-circle" class="size-5" />
        <div>
          <p class="font-semibold">Access key created. The secret is shown only once.</p>
          <p class="font-mono">Access Key: {@new_secret.access_key_id}</p>
          <p class="font-mono">Secret Key: {@new_secret.secret_key}</p>
        </div>
      </div>

      <section id="create-user-panel" class="mb-6 rounded-box border border-base-300 bg-base-100 p-4">
        <.form for={@create_form} id="create-user-form" phx-submit="create_user">
          <div class="grid gap-3 md:grid-cols-[minmax(0,1fr)_12rem_auto] md:items-end">
            <.input
              field={@create_form[:name]}
              type="text"
              label="User name"
              placeholder="alice"
              required
            />
            <.input
              field={@create_form[:status]}
              type="select"
              label="Status"
              options={@status_options}
            />
            <.button variant="primary" id="create-user-submit" type="submit">
              <.icon name="hero-plus" class="size-4" /> Create user
            </.button>
          </div>
        </.form>
      </section>

      <table class="table table-zebra">
        <thead>
          <tr>
            <th>User</th>
            <th>Status</th>
            <th>ARN</th>
            <th class="w-0"></th>
          </tr>
        </thead>
        <tbody id="users" phx-update="stream">
          <tr class="hidden only:table-row" id="users-empty">
            <td colspan="4" class="text-center text-base-content/60">No IAM users yet.</td>
          </tr>
          <tr :for={{dom_id, user} <- @streams.users} id={dom_id}>
            <td class="font-medium">{user.user_name}</td>
            <td>
              <span class={[
                "badge badge-sm",
                user.status == "active" && "badge-success",
                user.status != "active" && "badge-ghost"
              ]}>
                {user.status}
              </span>
            </td>
            <td class="break-all font-mono text-xs text-base-content/60">{user.user_arn}</td>
            <td>
              <div class="flex justify-end gap-2">
                <.button
                  id={"select-user-#{dom_suffix(user.user_name)}"}
                  phx-click="select_user"
                  phx-value-name={user.user_name}
                  title="Manage user"
                  aria-label={"Manage user #{user.user_name}"}
                >
                  <.icon name="hero-adjustments-horizontal" class="size-4" />
                </.button>
                <.button
                  id={"create-user-key-#{dom_suffix(user.user_name)}"}
                  phx-click="create_user_key"
                  phx-value-name={user.user_name}
                  disabled={user.status != "active"}
                  title="Create access key for user"
                  aria-label={"Create access key for #{user.user_name}"}
                >
                  <.icon name="hero-key" class="size-4" />
                </.button>
                <.button
                  id={"delete-user-#{dom_suffix(user.user_name)}"}
                  phx-click="delete_user"
                  phx-value-name={user.user_name}
                  data-confirm={"Delete IAM user #{user.user_name}?"}
                >
                  <.icon name="hero-trash" class="size-4" />
                </.button>
              </div>
            </td>
          </tr>
        </tbody>
      </table>

      <section
        :if={@selected_user}
        id="user-detail-panel"
        class="mt-6 rounded-box border border-base-300 bg-base-100 p-4"
      >
        <div class="mb-4 flex flex-col gap-1">
          <h2 class="text-base font-semibold">{@selected_user.user_name}</h2>
          <p id="selected-user-arn" class="break-all font-mono text-xs text-base-content/60">
            {@selected_user.user_arn}
          </p>
        </div>

        <div class="grid gap-5 xl:grid-cols-3">
          <div id="user-groups-panel">
            <h3 class="mb-2 text-sm font-semibold">Groups</h3>
            <div id="user-groups-list" phx-update="stream" class="space-y-2">
              <div id="user-groups-empty" class="hidden only:block text-sm text-base-content/60">
                This user is not in any group.
              </div>
              <div
                :for={{dom_id, group} <- @streams.user_groups}
                id={dom_id}
                class="flex items-center justify-between gap-3 rounded-box border border-base-300 px-3 py-2"
              >
                <span class="font-mono text-sm">{group.group_name}</span>
                <.button
                  id={"remove-user-group-#{dom_suffix(group.group_name)}"}
                  phx-click="remove_user_group"
                  phx-value-group={group.group_name}
                >
                  <.icon name="hero-x-mark" class="size-4" />
                </.button>
              </div>
            </div>

            <.form
              for={@membership_form}
              id="user-add-group-form"
              phx-submit="add_user_group"
              class="mt-4"
            >
              <div class="grid gap-3 sm:grid-cols-[minmax(0,1fr)_auto] sm:items-end">
                <.input
                  field={@membership_form[:group]}
                  type="select"
                  label="Add group"
                  options={@group_options}
                  prompt="Select a group"
                />
                <.button id="user-add-group-submit" type="submit">
                  <.icon name="hero-plus" class="size-4" /> Add
                </.button>
              </div>
            </.form>
          </div>

          <div id="user-access-keys-panel">
            <h3 class="mb-2 text-sm font-semibold">Access keys</h3>
            <div id="user-access-keys-list" phx-update="stream" class="space-y-2">
              <div
                id="user-access-keys-empty"
                class="hidden only:block text-sm text-base-content/60"
              >
                This user has no bound access keys.
              </div>
              <div
                :for={{dom_id, key} <- @streams.user_access_keys}
                id={dom_id}
                class="rounded-box border border-base-300 px-3 py-2"
              >
                <div class="font-mono text-sm">{key.access_key_id}</div>
                <div class="text-xs text-base-content/60">{key.status}</div>
              </div>
            </div>
          </div>

          <div id="user-managed-policies-panel">
            <h3 class="mb-2 text-sm font-semibold">Managed policies</h3>
            <div id="user-managed-policy-list" phx-update="stream" class="space-y-2">
              <div
                id="user-managed-policy-empty"
                class="hidden only:block text-sm text-base-content/60"
              >
                No managed policies are attached to this user.
              </div>
              <div
                :for={{dom_id, policy} <- @streams.user_managed_policies}
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
                  id={"detach-user-policy-#{dom_suffix(policy.policy_arn)}"}
                  phx-click="detach_user_policy"
                  phx-value-policy-arn={policy.policy_arn}
                >
                  <.icon name="hero-x-mark" class="size-4" />
                </.button>
              </div>
            </div>

            <.form
              for={@policy_attach_form}
              id="user-attach-policy-form"
              phx-submit="attach_user_policy"
              class="mt-4"
            >
              <div class="grid gap-3 sm:grid-cols-[minmax(0,1fr)_auto] sm:items-end">
                <.input
                  field={@policy_attach_form[:policy_arn]}
                  type="select"
                  label="Attach policy"
                  options={@policy_options}
                  prompt="Select a policy"
                />
                <.button id="user-attach-policy-submit" type="submit">
                  <.icon name="hero-plus" class="size-4" /> Attach
                </.button>
              </div>
            </.form>
          </div>
        </div>
      </section>
    </Layouts.app>
    """
  end

  @impl true
  def handle_event("create_user", %{"user" => params}, socket) do
    name = params |> Map.get("name", "") |> String.trim()
    status = params |> Map.get("status", "active") |> normalize_status()

    case IAM.create_user(name: name, status: status) do
      {:ok, user} ->
        {:noreply,
         socket
         |> stream_insert(:users, user, at: 0)
         |> update(:user_count, &(&1 + 1))
         |> assign(:create_form, create_form())
         |> put_flash(:info, "Created IAM user #{user.user_name}")}

      {:error, _changeset} ->
        {:noreply,
         socket
         |> assign(:create_form, create_form(params))
         |> put_flash(:error, "Create user failed")}
    end
  end

  @impl true
  def handle_event("delete_user", %{"name" => name}, socket) do
    user = current_user(name)
    :ok = IAM.delete_user(name)

    if user do
      {:noreply,
       socket
       |> stream_delete(:users, user)
       |> update(:user_count, &max(&1 - 1, 0))
       |> assign(:new_secret, nil)
       |> maybe_clear_selected_user(name)
       |> put_flash(:info, "Deleted IAM user #{name}")}
    else
      {:noreply, put_flash(socket, :error, "IAM user not found")}
    end
  end

  @impl true
  def handle_event("select_user", %{"name" => name}, socket) do
    case current_user(name) do
      nil ->
        {:noreply, socket |> clear_user_detail() |> put_flash(:error, "IAM user not found")}

      user ->
        {:noreply, load_user_detail(socket, user)}
    end
  end

  @impl true
  def handle_event("create_user_key", %{"name" => name}, socket) do
    case IAM.create_access_key(user_name: name) do
      {:ok, secret} ->
        {:noreply,
         socket
         |> assign(:new_secret, secret)
         |> refresh_selected_user_detail(name)
         |> put_flash(:info, "Created access key for #{name}")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Create access key failed: #{inspect(reason)}")}
    end
  end

  @impl true
  def handle_event("add_user_group", %{"membership" => %{"group" => group}}, socket) do
    group = String.trim(group || "")

    with %{user_name: user_name} <- socket.assigns.selected_user,
         false <- group == "",
         :ok <- IAM.add_user_to_group(user_name, group) do
      {:noreply,
       socket
       |> load_user_detail(socket.assigns.selected_user)
       |> put_flash(:info, "Added #{user_name} to #{group}")}
    else
      true ->
        {:noreply, put_flash(socket, :error, "Select a group first")}

      nil ->
        {:noreply, put_flash(socket, :error, "Select a user first")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Add group failed: #{inspect(reason)}")}
    end
  end

  def handle_event("add_user_group", _params, socket) do
    {:noreply, put_flash(socket, :error, "Select a user first")}
  end

  @impl true
  def handle_event("remove_user_group", %{"group" => group}, socket) do
    case socket.assigns.selected_user do
      %{user_name: user_name} = user ->
        :ok = IAM.remove_user_from_group(user_name, group)
        {:noreply, socket |> load_user_detail(user) |> put_flash(:info, "Removed #{group}")}

      nil ->
        {:noreply, put_flash(socket, :error, "Select a user first")}
    end
  end

  @impl true
  def handle_event("attach_user_policy", %{"attachment" => %{"policy_arn" => policy_arn}}, socket) do
    policy_arn = String.trim(policy_arn || "")

    with %{user_name: user_name} = user <- socket.assigns.selected_user,
         false <- policy_arn == "",
         :ok <- IAM.attach_user_policy(user_name, policy_arn) do
      {:noreply,
       socket
       |> load_user_detail(user)
       |> put_flash(:info, "Attached managed policy")}
    else
      nil ->
        {:noreply, put_flash(socket, :error, "Select a user first")}

      true ->
        {:noreply, put_flash(socket, :error, "Select a managed policy first")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Attach managed policy failed: #{inspect(reason)}")}
    end
  end

  def handle_event("attach_user_policy", _params, socket) do
    {:noreply, put_flash(socket, :error, "Select a user first")}
  end

  @impl true
  def handle_event("detach_user_policy", %{"policy-arn" => policy_arn}, socket) do
    case socket.assigns.selected_user do
      %{user_name: user_name} = user ->
        case IAM.detach_user_policy(user_name, policy_arn) do
          :ok ->
            {:noreply,
             socket
             |> load_user_detail(user)
             |> put_flash(:info, "Detached managed policy")}

          {:error, reason} ->
            {:noreply,
             socket
             |> load_user_detail(user)
             |> put_flash(:error, "Detach managed policy failed: #{inspect(reason)}")}
        end

      nil ->
        {:noreply, put_flash(socket, :error, "Select a user first")}
    end
  end

  def handle_event("detach_user_policy", _params, socket) do
    case socket.assigns.selected_user do
      nil ->
        {:noreply, put_flash(socket, :error, "Select a user first")}

      user ->
        {:noreply,
         socket
         |> load_user_detail(user)
         |> put_flash(:error, "Detach managed policy failed: :malformed")}
    end
  end

  defp load_user_detail(socket, user) do
    groups = IAM.list_groups_for_user(user.user_name)
    access_keys = access_keys_for_user(user.user_arn)
    managed_policies = IAM.list_attached_user_policies(user.user_name)

    socket
    |> assign(:selected_user, user)
    |> assign(:membership_form, membership_form())
    |> assign(:policy_attach_form, policy_attach_form())
    |> assign(:group_options, group_options())
    |> assign(:policy_options, policy_options())
    |> assign(:new_secret, nil)
    |> stream(:user_groups, groups, reset: true, dom_id: &user_group_dom_id/1)
    |> stream(:user_access_keys, access_keys, reset: true, dom_id: &user_access_key_dom_id/1)
    |> stream(:user_managed_policies, managed_policies,
      reset: true,
      dom_id: &user_managed_policy_dom_id/1
    )
  end

  defp refresh_selected_user_detail(socket, user_name) do
    case socket.assigns.selected_user do
      %{user_name: ^user_name} = user ->
        groups = IAM.list_groups_for_user(user.user_name)
        access_keys = access_keys_for_user(user.user_arn)
        managed_policies = IAM.list_attached_user_policies(user.user_name)

        socket
        |> assign(:membership_form, membership_form())
        |> assign(:policy_attach_form, policy_attach_form())
        |> assign(:group_options, group_options())
        |> assign(:policy_options, policy_options())
        |> stream(:user_groups, groups, reset: true, dom_id: &user_group_dom_id/1)
        |> stream(:user_access_keys, access_keys, reset: true, dom_id: &user_access_key_dom_id/1)
        |> stream(:user_managed_policies, managed_policies,
          reset: true,
          dom_id: &user_managed_policy_dom_id/1
        )

      _other ->
        socket
    end
  end

  defp maybe_clear_selected_user(socket, name) do
    case socket.assigns.selected_user do
      %{user_name: ^name} -> clear_user_detail(socket)
      _other -> socket
    end
  end

  defp clear_user_detail(socket) do
    socket
    |> assign(:selected_user, nil)
    |> assign(:membership_form, membership_form())
    |> assign(:policy_attach_form, policy_attach_form())
    |> assign(:new_secret, nil)
    |> stream(:user_groups, [], reset: true, dom_id: &user_group_dom_id/1)
    |> stream(:user_access_keys, [], reset: true, dom_id: &user_access_key_dom_id/1)
    |> stream(:user_managed_policies, [], reset: true, dom_id: &user_managed_policy_dom_id/1)
  end

  defp current_user(name) do
    case IAM.get_user(name) do
      {:ok, user} -> user
      :error -> nil
    end
  end

  defp access_keys_for_user(user_arn) do
    IAM.list_access_keys()
    |> Enum.filter(&(&1.principal_arn == user_arn))
    |> Enum.sort_by(& &1.access_key_id)
  end

  defp group_options do
    IAM.list_groups()
    |> Enum.map(&{&1.group_name, &1.group_name})
  end

  defp policy_options do
    IAM.list_managed_policies()
    |> Enum.map(&{"#{&1.policy_name} (#{&1.path})", &1.policy_arn})
  end

  defp create_form, do: create_form(%{"name" => "", "status" => "active"})
  defp create_form(params), do: to_form(params, as: :user)

  defp membership_form, do: to_form(%{"group" => ""}, as: :membership)
  defp policy_attach_form, do: to_form(%{"policy_arn" => ""}, as: :attachment)

  defp normalize_status("inactive"), do: "inactive"
  defp normalize_status(_status), do: "active"

  defp user_dom_id(%{user_name: user_name}), do: "users-#{dom_suffix(user_name)}"
  defp user_group_dom_id(%{group_name: group_name}), do: "user-group-#{dom_suffix(group_name)}"

  defp user_access_key_dom_id(%{access_key_id: access_key_id}),
    do: "user-access-key-#{access_key_id}"

  defp user_managed_policy_dom_id(%{policy_arn: policy_arn}),
    do: "user-managed-policy-#{dom_suffix(policy_arn)}"

  defp dom_suffix(value), do: Base.encode16(to_string(value), case: :lower)
end
