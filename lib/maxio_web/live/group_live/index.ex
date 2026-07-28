defmodule MaxioWeb.GroupLive.Index do
  @moduledoc "Console IAM group management."
  use MaxioWeb, :live_view

  alias Maxio.IAM

  @status_options [{"Active", "active"}, {"Inactive", "inactive"}]

  @policy_template """
  {
    "Version": "2012-10-17",
    "Statement": [
      {
        "Effect": "Allow",
        "Action": "s3:ListAllMyBuckets",
        "Resource": "*"
      }
    ]
  }
  """

  @impl true
  def mount(_params, _session, socket) do
    groups = IAM.list_groups()

    {:ok,
     socket
     |> assign(:page_title, "Groups")
     |> assign(:group_count, length(groups))
     |> assign(:status_options, @status_options)
     |> assign(:create_form, create_form())
     |> assign(:member_form, member_form())
     |> assign(:policy_form, policy_form())
     |> assign(:policy_attach_form, policy_attach_form())
     |> assign(:user_options, user_options())
     |> assign(:policy_options, policy_options())
     |> assign(:selected_group, nil)
     |> stream(:groups, groups, dom_id: &group_dom_id/1)
     |> stream(:group_members, [], dom_id: &group_member_dom_id/1)
     |> stream(:group_policies, [], dom_id: &policy_dom_id/1)
     |> stream(:group_managed_policies, [], dom_id: &group_managed_policy_dom_id/1)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_principal}>
      <.header>
        Groups
        <:subtitle>{@group_count} IAM groups</:subtitle>
        <:actions>
          <.button navigate={~p"/users"}>
            <.icon name="hero-user" class="size-4" /> Users
          </.button>
        </:actions>
      </.header>

      <section id="create-group-panel" class="mb-6 rounded-box border border-base-300 bg-base-100 p-4">
        <.form for={@create_form} id="create-group-form" phx-submit="create_group">
          <div class="grid gap-3 md:grid-cols-[minmax(0,1fr)_12rem_auto] md:items-end">
            <.input
              field={@create_form[:name]}
              type="text"
              label="Group name"
              placeholder="readers"
              required
            />
            <.input
              field={@create_form[:status]}
              type="select"
              label="Status"
              options={@status_options}
            />
            <.button variant="primary" id="create-group-submit" type="submit">
              <.icon name="hero-plus" class="size-4" /> Create group
            </.button>
          </div>
        </.form>
      </section>

      <table class="table table-zebra">
        <thead>
          <tr>
            <th>Group</th>
            <th>Status</th>
            <th>ARN</th>
            <th class="w-0"></th>
          </tr>
        </thead>
        <tbody id="groups" phx-update="stream">
          <tr class="hidden only:table-row" id="groups-empty">
            <td colspan="4" class="text-center text-base-content/60">No IAM groups yet.</td>
          </tr>
          <tr :for={{dom_id, group} <- @streams.groups} id={dom_id}>
            <td class="font-medium">{group.group_name}</td>
            <td>
              <span class={[
                "badge badge-sm",
                group.status == "active" && "badge-success",
                group.status != "active" && "badge-ghost"
              ]}>
                {group.status}
              </span>
            </td>
            <td class="break-all font-mono text-xs text-base-content/60">{group.group_arn}</td>
            <td>
              <div class="flex justify-end gap-2">
                <.button
                  id={"select-group-#{dom_suffix(group.group_name)}"}
                  phx-click="select_group"
                  phx-value-name={group.group_name}
                  title="Manage group"
                  aria-label={"Manage group #{group.group_name}"}
                >
                  <.icon name="hero-adjustments-horizontal" class="size-4" />
                </.button>
                <.button
                  id={"delete-group-#{dom_suffix(group.group_name)}"}
                  phx-click="delete_group"
                  phx-value-name={group.group_name}
                  data-confirm={"Delete IAM group #{group.group_name}?"}
                >
                  <.icon name="hero-trash" class="size-4" />
                </.button>
              </div>
            </td>
          </tr>
        </tbody>
      </table>

      <section
        :if={@selected_group}
        id="group-detail-panel"
        class="mt-6 rounded-box border border-base-300 bg-base-100 p-4"
      >
        <div class="mb-4 flex flex-col gap-1">
          <h2 class="text-base font-semibold">{@selected_group.group_name}</h2>
          <p id="selected-group-arn" class="break-all font-mono text-xs text-base-content/60">
            {@selected_group.group_arn}
          </p>
        </div>

        <div class="grid gap-5 lg:grid-cols-2">
          <div id="group-members-panel">
            <h3 class="mb-2 text-sm font-semibold">Members</h3>
            <div id="group-members-list" phx-update="stream" class="space-y-2">
              <div id="group-members-empty" class="hidden only:block text-sm text-base-content/60">
                This group has no members.
              </div>
              <div
                :for={{dom_id, user} <- @streams.group_members}
                id={dom_id}
                class="flex items-center justify-between gap-3 rounded-box border border-base-300 px-3 py-2"
              >
                <span class="font-mono text-sm">{user.user_name}</span>
                <.button
                  id={"remove-group-member-#{dom_suffix(user.user_name)}"}
                  phx-click="remove_group_member"
                  phx-value-user={user.user_name}
                >
                  <.icon name="hero-x-mark" class="size-4" />
                </.button>
              </div>
            </div>

            <.form
              for={@member_form}
              id="group-add-member-form"
              phx-submit="add_group_member"
              class="mt-4"
            >
              <div class="grid gap-3 sm:grid-cols-[minmax(0,1fr)_auto] sm:items-end">
                <.input
                  field={@member_form[:user]}
                  type="select"
                  label="Add user"
                  options={@user_options}
                  prompt="Select a user"
                />
                <.button id="group-add-member-submit" type="submit">
                  <.icon name="hero-plus" class="size-4" /> Add
                </.button>
              </div>
            </.form>
          </div>

          <div id="group-policy-panel">
            <h3 class="mb-2 text-sm font-semibold">Managed policies</h3>
            <div id="group-managed-policy-list" phx-update="stream" class="space-y-2">
              <div
                id="group-managed-policy-empty"
                class="hidden only:block text-sm text-base-content/60"
              >
                No managed policies are attached to this group.
              </div>
              <div
                :for={{dom_id, policy} <- @streams.group_managed_policies}
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
                  id={"detach-group-policy-#{dom_suffix(policy.policy_arn)}"}
                  phx-click="detach_group_policy"
                  phx-value-policy-arn={policy.policy_arn}
                >
                  <.icon name="hero-x-mark" class="size-4" />
                </.button>
              </div>
            </div>

            <.form
              for={@policy_attach_form}
              id="group-attach-policy-form"
              phx-submit="attach_group_policy"
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
                <.button id="group-attach-policy-submit" type="submit">
                  <.icon name="hero-plus" class="size-4" /> Attach
                </.button>
              </div>
            </.form>

            <h3 class="mb-2 mt-6 text-sm font-semibold">Inline group policies</h3>
            <div id="group-policy-list" phx-update="stream" class="space-y-2">
              <div id="group-policy-empty" class="hidden only:block text-sm text-base-content/60">
                No inline group policies are attached.
              </div>
              <div
                :for={{dom_id, policy} <- @streams.group_policies}
                id={dom_id}
                class="flex items-center justify-between gap-3 rounded-box border border-base-300 px-3 py-2"
              >
                <span class="font-mono text-sm">{policy.policy_name}</span>
                <div class="flex gap-2">
                  <.button
                    id={"edit-group-policy-#{dom_suffix(policy.policy_name)}"}
                    phx-click="edit_group_policy"
                    phx-value-name={policy.policy_name}
                  >
                    <.icon name="hero-pencil-square" class="size-4" />
                  </.button>
                  <.button
                    id={"delete-group-policy-#{dom_suffix(policy.policy_name)}"}
                    phx-click="delete_group_policy"
                    phx-value-name={policy.policy_name}
                    data-confirm={"Delete group policy #{policy.policy_name}?"}
                  >
                    <.icon name="hero-trash" class="size-4" />
                  </.button>
                </div>
              </div>
            </div>

            <.form
              for={@policy_form}
              id="group-policy-form"
              phx-submit="save_group_policy"
              class="mt-4 space-y-3"
            >
              <.input field={@policy_form[:name]} type="text" label="Policy name" />
              <.input
                field={@policy_form[:json]}
                type="textarea"
                rows="12"
                label="Policy JSON"
                class="w-full textarea font-mono text-xs"
              />
              <.button variant="primary" id="group-policy-save" type="submit">
                <.icon name="hero-document-check" class="size-4" /> Save policy
              </.button>
            </.form>
          </div>
        </div>
      </section>
    </Layouts.app>
    """
  end

  @impl true
  def handle_event("create_group", %{"group" => params}, socket) do
    name = params |> Map.get("name", "") |> String.trim()
    status = params |> Map.get("status", "active") |> normalize_status()

    case IAM.create_group(name: name, status: status) do
      {:ok, group} ->
        {:noreply,
         socket
         |> stream_insert(:groups, group, at: 0)
         |> update(:group_count, &(&1 + 1))
         |> assign(:create_form, create_form())
         |> put_flash(:info, "Created IAM group #{group.group_name}")}

      {:error, _changeset} ->
        {:noreply,
         socket
         |> assign(:create_form, create_form(params))
         |> put_flash(:error, "Create group failed")}
    end
  end

  @impl true
  def handle_event("delete_group", %{"name" => name}, socket) do
    group = current_group(name)
    :ok = IAM.delete_group(name)

    if group do
      {:noreply,
       socket
       |> stream_delete(:groups, group)
       |> update(:group_count, &max(&1 - 1, 0))
       |> maybe_clear_selected_group(name)
       |> put_flash(:info, "Deleted IAM group #{name}")}
    else
      {:noreply, put_flash(socket, :error, "IAM group not found")}
    end
  end

  @impl true
  def handle_event("select_group", %{"name" => name}, socket) do
    case current_group(name) do
      nil ->
        {:noreply, socket |> clear_group_detail() |> put_flash(:error, "IAM group not found")}

      group ->
        {:noreply, load_group_detail(socket, group)}
    end
  end

  @impl true
  def handle_event("add_group_member", %{"member" => %{"user" => user}}, socket) do
    user = String.trim(user || "")

    with %{group_name: group_name} <- socket.assigns.selected_group,
         false <- user == "",
         :ok <- IAM.add_user_to_group(user, group_name) do
      {:noreply,
       socket
       |> load_group_detail(socket.assigns.selected_group)
       |> put_flash(:info, "Added #{user} to #{group_name}")}
    else
      true ->
        {:noreply, put_flash(socket, :error, "Select a user first")}

      nil ->
        {:noreply, put_flash(socket, :error, "Select a group first")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Add member failed: #{inspect(reason)}")}
    end
  end

  def handle_event("add_group_member", _params, socket) do
    {:noreply, put_flash(socket, :error, "Select a group first")}
  end

  @impl true
  def handle_event("remove_group_member", %{"user" => user}, socket) do
    case socket.assigns.selected_group do
      %{group_name: group_name} = group ->
        :ok = IAM.remove_user_from_group(user, group_name)
        {:noreply, socket |> load_group_detail(group) |> put_flash(:info, "Removed #{user}")}

      nil ->
        {:noreply, put_flash(socket, :error, "Select a group first")}
    end
  end

  @impl true
  def handle_event("edit_group_policy", %{"name" => name}, socket) do
    form =
      case socket.assigns.selected_group do
        %{group_name: group_name} ->
          group_name
          |> IAM.list_group_policies()
          |> Enum.map(&policy_view/1)
          |> Enum.find(&(&1.policy_name == name))
          |> case do
            nil -> policy_form()
            %{policy_name: policy_name, document_json: json} -> policy_form(policy_name, json)
          end

        nil ->
          policy_form()
      end

    {:noreply, assign(socket, :policy_form, form)}
  end

  @impl true
  def handle_event("save_group_policy", %{"policy" => params}, socket) do
    name = params |> Map.get("name", "") |> String.trim()
    json = params |> Map.get("json", "") |> String.trim()

    with %{group_name: group_name} = group <- socket.assigns.selected_group,
         false <- name == "",
         false <- json == "",
         :ok <- IAM.put_group_policy(group_name, name, json) do
      {:noreply,
       socket
       |> load_group_detail(group)
       |> put_flash(:info, "Stored group policy #{name}")}
    else
      nil ->
        {:noreply, put_flash(socket, :error, "Select a group first")}

      true ->
        {:noreply,
         socket
         |> assign(:policy_form, policy_form(params))
         |> put_flash(:error, "Policy name and JSON are required")}

      {:error, _reason} ->
        {:noreply,
         socket
         |> assign(:policy_form, policy_form(params))
         |> put_flash(:error, "Invalid group policy JSON")}
    end
  end

  @impl true
  def handle_event("delete_group_policy", %{"name" => name}, socket) do
    case socket.assigns.selected_group do
      %{group_name: group_name} = group ->
        :ok = IAM.delete_group_policy(group_name, name)

        {:noreply,
         socket |> load_group_detail(group) |> put_flash(:info, "Deleted group policy #{name}")}

      nil ->
        {:noreply, put_flash(socket, :error, "Select a group first")}
    end
  end

  @impl true
  def handle_event(
        "attach_group_policy",
        %{"attachment" => %{"policy_arn" => policy_arn}},
        socket
      ) do
    policy_arn = String.trim(policy_arn || "")

    with %{group_name: group_name} = group <- socket.assigns.selected_group,
         false <- policy_arn == "",
         :ok <- IAM.attach_group_policy(group_name, policy_arn) do
      {:noreply,
       socket
       |> load_group_detail(group)
       |> put_flash(:info, "Attached managed policy")}
    else
      nil ->
        {:noreply, put_flash(socket, :error, "Select a group first")}

      true ->
        {:noreply, put_flash(socket, :error, "Select a managed policy first")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Attach managed policy failed: #{inspect(reason)}")}
    end
  end

  def handle_event("attach_group_policy", _params, socket) do
    {:noreply, put_flash(socket, :error, "Select a group first")}
  end

  @impl true
  def handle_event("detach_group_policy", %{"policy-arn" => policy_arn}, socket) do
    case socket.assigns.selected_group do
      %{group_name: group_name} = group ->
        case IAM.detach_group_policy(group_name, policy_arn) do
          :ok ->
            {:noreply,
             socket
             |> load_group_detail(group)
             |> put_flash(:info, "Detached managed policy")}

          {:error, reason} ->
            {:noreply,
             socket
             |> load_group_detail(group)
             |> put_flash(:error, "Detach managed policy failed: #{inspect(reason)}")}
        end

      nil ->
        {:noreply, put_flash(socket, :error, "Select a group first")}
    end
  end

  def handle_event("detach_group_policy", _params, socket) do
    case socket.assigns.selected_group do
      nil ->
        {:noreply, put_flash(socket, :error, "Select a group first")}

      group ->
        {:noreply,
         socket
         |> load_group_detail(group)
         |> put_flash(:error, "Detach managed policy failed: :malformed")}
    end
  end

  defp load_group_detail(socket, group) do
    members = IAM.list_users_in_group(group.group_name)
    policies = Enum.map(IAM.list_group_policies(group.group_name), &policy_view/1)
    managed_policies = IAM.list_attached_group_policies(group.group_name)

    socket
    |> assign(:selected_group, group)
    |> assign(:member_form, member_form())
    |> assign(:policy_form, policy_form())
    |> assign(:policy_attach_form, policy_attach_form())
    |> assign(:user_options, user_options())
    |> assign(:policy_options, policy_options())
    |> stream(:group_members, members, reset: true, dom_id: &group_member_dom_id/1)
    |> stream(:group_policies, policies, reset: true, dom_id: &policy_dom_id/1)
    |> stream(:group_managed_policies, managed_policies,
      reset: true,
      dom_id: &group_managed_policy_dom_id/1
    )
  end

  defp maybe_clear_selected_group(socket, name) do
    case socket.assigns.selected_group do
      %{group_name: ^name} -> clear_group_detail(socket)
      _other -> socket
    end
  end

  defp clear_group_detail(socket) do
    socket
    |> assign(:selected_group, nil)
    |> assign(:member_form, member_form())
    |> assign(:policy_form, policy_form())
    |> assign(:policy_attach_form, policy_attach_form())
    |> stream(:group_members, [], reset: true, dom_id: &group_member_dom_id/1)
    |> stream(:group_policies, [], reset: true, dom_id: &policy_dom_id/1)
    |> stream(:group_managed_policies, [],
      reset: true,
      dom_id: &group_managed_policy_dom_id/1
    )
  end

  defp current_group(name) do
    case IAM.get_group(name) do
      {:ok, group} -> group
      :error -> nil
    end
  end

  defp user_options do
    IAM.list_users()
    |> Enum.map(&{&1.user_name, &1.user_name})
  end

  defp policy_options do
    IAM.list_managed_policies()
    |> Enum.map(&{"#{&1.policy_name} (#{&1.path})", &1.policy_arn})
  end

  defp policy_view(%{policy_name: policy_name, document: document}) do
    %{
      policy_name: policy_name,
      document_json: Jason.encode!(document, pretty: true)
    }
  end

  defp create_form, do: create_form(%{"name" => "", "status" => "active"})
  defp create_form(params), do: to_form(params, as: :group)

  defp member_form, do: to_form(%{"user" => ""}, as: :member)

  defp policy_form, do: policy_form("", @policy_template)
  defp policy_form(params) when is_map(params), do: to_form(params, as: :policy)
  defp policy_form(name, json), do: to_form(%{"name" => name, "json" => json}, as: :policy)
  defp policy_attach_form, do: to_form(%{"policy_arn" => ""}, as: :attachment)

  defp normalize_status("inactive"), do: "inactive"
  defp normalize_status(_status), do: "active"

  defp group_dom_id(%{group_name: group_name}), do: "groups-#{dom_suffix(group_name)}"
  defp group_member_dom_id(%{user_name: user_name}), do: "group-member-#{dom_suffix(user_name)}"
  defp policy_dom_id(%{policy_name: policy_name}), do: "group-policy-#{dom_suffix(policy_name)}"

  defp group_managed_policy_dom_id(%{policy_arn: policy_arn}),
    do: "group-managed-policy-#{dom_suffix(policy_arn)}"

  defp dom_suffix(value), do: Base.encode16(to_string(value), case: :lower)
end
