defmodule MaxioWeb.AccessKeyLive.Index do
  @moduledoc """
  Access Keys 管理（M5-8）：列表（`IAM.list_access_keys/0`，绝不回 secret）、创建
  （`IAM.create_access_key/1`，创建后 secret **仅在该次响应里显示一次**，不入 stream/session）、
  删除（`IAM.delete_access_key/1`，root 保护：删最后一个 root 返回
  `:cannot_delete_last_root` → 显式 flash，绝不静默放行，铁律 3）。

  列表用 stream（`#access-keys` 父，子 `dom_id` 取 `access_key_id`——access key 行 map
  无 `:id` 字段，故自定义 `dom_id`）；计数单独 `:key_count` assign。
  """
  use MaxioWeb, :live_view

  alias Maxio.IAM

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
    keys = IAM.list_access_keys()

    {:ok,
     socket
     |> assign(:page_title, "Access Keys")
     |> assign(:key_count, length(keys))
     |> assign(:new_secret, nil)
     |> assign(:create_form, to_form(%{}, as: :key))
     |> assign(:selected_key, nil)
     |> assign(:policies, [])
     |> assign(:policy_form, policy_form())
     |> stream(:keys, keys, dom_id: &"keys-#{&1.access_key_id}")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_principal}>
      <.header>
        Access Keys
        <:subtitle>{@key_count} 个密钥</:subtitle>
      </.header>

      <div :if={@new_secret} id="new-secret-banner" class="alert alert-success mb-4 text-sm">
        <.icon name="hero-check-circle" class="size-5" />
        <div>
          <p class="font-semibold">新密钥已创建（Secret 仅显示这一次，请妥善保存）：</p>
          <p class="font-mono">Access Key: {@new_secret.access_key_id}</p>
          <p class="font-mono">Secret Key: {@new_secret.secret_key}</p>
        </div>
      </div>

      <.form for={@create_form} id="create-key-form" phx-submit="create_key" class="mb-6">
        <.button variant="primary" id="create-key-submit" type="submit">
          <.icon name="hero-plus" class="size-4" /> 创建 Access Key
        </.button>
      </.form>

      <table class="table table-zebra">
        <thead>
          <tr>
            <th>Access Key ID</th>
            <th>类型</th>
            <th>状态</th>
            <th>ARN</th>
            <th class="w-0"></th>
            <th class="w-0"></th>
          </tr>
        </thead>
        <tbody id="access-keys" phx-update="stream">
          <tr class="hidden only:table-row" id="access-keys-empty">
            <td colspan="6" class="text-center text-base-content/60">暂无 access key</td>
          </tr>
          <tr :for={{dom_id, k} <- @streams.keys} id={dom_id}>
            <td class="font-mono text-sm">{k.access_key_id}</td>
            <td>
              <span class={[
                "badge badge-sm",
                k.type == "root" && "badge-primary",
                k.type != "root" && "badge-ghost"
              ]}>
                {k.type}
              </span>
            </td>
            <td>{k.status}</td>
            <td class="font-mono text-xs text-base-content/60">{k.principal_arn}</td>
            <td>
              <.button
                :if={policy_manageable?(k)}
                id={"manage-policies-#{k.access_key_id}"}
                phx-click="select_policy_key"
                phx-value-ak={k.access_key_id}
                title="Manage inline identity policies"
                aria-label={"Manage inline identity policies for #{k.access_key_id}"}
              >
                <.icon name="hero-document-text" class="size-4" />
              </.button>
            </td>
            <td>
              <.button
                id={"delete-key-#{k.access_key_id}"}
                phx-click="delete_key"
                phx-value-ak={k.access_key_id}
                data-confirm={"删除 access key #{k.access_key_id}？"}
              >
                <.icon name="hero-trash" class="size-4" />
              </.button>
            </td>
          </tr>
        </tbody>
      </table>

      <section
        :if={@selected_key}
        id="identity-policy-panel"
        class="mt-6 rounded-box border border-base-300 bg-base-100 p-4"
      >
        <div class="mb-4 flex flex-col gap-1">
          <h2 class="text-base font-semibold">Identity policies</h2>
          <p id="identity-policy-principal" class="break-all font-mono text-xs text-base-content/60">
            {@selected_key.principal_arn}
          </p>
        </div>

        <div id="identity-policy-list" class="mb-5 space-y-2">
          <div :if={@policies == []} id="identity-policy-empty" class="text-sm text-base-content/60">
            No inline identity policies are attached to this access key.
          </div>
          <div
            :for={policy <- @policies}
            id={policy_dom_id(policy.policy_name)}
            class="flex items-center justify-between gap-3 rounded-box border border-base-300 px-3 py-2"
          >
            <span class="font-mono text-sm">{policy.policy_name}</span>
            <div class="flex gap-2">
              <.button
                id={"edit-policy-#{policy_dom_suffix(policy.policy_name)}"}
                phx-click="edit_policy"
                phx-value-name={policy.policy_name}
              >
                <.icon name="hero-pencil-square" class="size-4" />
              </.button>
              <.button
                id={"delete-policy-#{policy_dom_suffix(policy.policy_name)}"}
                phx-click="delete_policy"
                phx-value-name={policy.policy_name}
                data-confirm={"Delete identity policy #{policy.policy_name}?"}
              >
                <.icon name="hero-trash" class="size-4" />
              </.button>
            </div>
          </div>
        </div>

        <.form for={@policy_form} id="identity-policy-form" phx-submit="save_policy" class="space-y-3">
          <.input field={@policy_form[:name]} type="text" label="Policy name" />
          <.input
            field={@policy_form[:json]}
            type="textarea"
            rows="12"
            label="Policy JSON"
            class="w-full textarea font-mono text-xs"
          />
          <.button variant="primary" id="identity-policy-save" type="submit">
            <.icon name="hero-document-check" class="size-4" /> Save policy
          </.button>
        </.form>
      </section>
    </Layouts.app>
    """
  end

  @impl true
  def handle_event("create_key", _params, socket) do
    case IAM.create_access_key() do
      {:ok, %{access_key_id: ak, principal_arn: arn, type: type} = created} ->
        row = %{access_key_id: ak, principal_arn: arn, type: type, status: "active"}

        {:noreply,
         socket
         |> stream_insert(:keys, row, at: 0)
         |> update(:key_count, &(&1 + 1))
         |> assign(:new_secret, created)
         |> put_flash(:info, "已创建 access key #{ak}")}

      {:error, _cs} ->
        {:noreply, put_flash(socket, :error, "创建失败")}
    end
  end

  @impl true
  def handle_event("delete_key", %{"ak" => ak}, socket) do
    case IAM.delete_access_key(ak) do
      :ok ->
        {:noreply,
         socket
         |> stream_delete(:keys, %{access_key_id: ak})
         |> update(:key_count, &max(&1 - 1, 0))
         |> assign(:new_secret, nil)
         |> maybe_clear_selected_key(ak)
         |> put_flash(:info, "已删除 #{ak}")}

      {:error, :cannot_delete_last_root} ->
        {:noreply, put_flash(socket, :error, "不能删除最后一个 root 密钥")}
    end
  end

  @impl true
  def handle_event("select_policy_key", %{"ak" => ak}, socket) do
    case find_key(ak) do
      nil ->
        {:noreply,
         socket
         |> clear_policy_panel()
         |> put_flash(:error, "Access key not found")}

      %{type: "root"} ->
        {:noreply,
         socket
         |> clear_policy_panel()
         |> put_flash(:error, "Root access keys are not constrained by identity policies")}

      key ->
        {:noreply, load_policy_panel(socket, key)}
    end
  end

  @impl true
  def handle_event("edit_policy", %{"name" => name}, %{assigns: %{selected_key: key}} = socket)
      when is_map(key) do
    form =
      case Enum.find(socket.assigns.policies, &(&1.policy_name == name)) do
        nil ->
          policy_form()

        %{policy_name: policy_name, document_json: document_json} ->
          policy_form(policy_name, document_json)
      end

    {:noreply, assign(socket, :policy_form, form)}
  end

  def handle_event("edit_policy", _params, socket) do
    {:noreply, put_flash(socket, :error, "Select an access key before editing a policy")}
  end

  @impl true
  def handle_event(
        "save_policy",
        %{"policy" => params},
        %{assigns: %{selected_key: key}} = socket
      )
      when is_map(key) do
    name = params |> Map.get("name", "") |> String.trim()
    json = params |> Map.get("json", "") |> String.trim()

    cond do
      name == "" ->
        {:noreply,
         socket
         |> assign(:policy_form, policy_form(params))
         |> put_flash(:error, "Policy name is required")}

      json == "" ->
        {:noreply,
         socket
         |> assign(:policy_form, policy_form(params))
         |> put_flash(:error, "Policy JSON is required")}

      true ->
        case IAM.put_principal_policy(key.principal_arn, name, json) do
          :ok ->
            {:noreply,
             socket
             |> load_policy_panel(key)
             |> put_flash(:info, "Stored identity policy #{name}")}

          {:error, _reason} ->
            {:noreply,
             socket
             |> assign(:policy_form, policy_form(params))
             |> put_flash(:error, "Invalid identity policy JSON")}
        end
    end
  end

  def handle_event("save_policy", _params, socket) do
    {:noreply, put_flash(socket, :error, "Select an access key before saving a policy")}
  end

  @impl true
  def handle_event("delete_policy", %{"name" => name}, %{assigns: %{selected_key: key}} = socket)
      when is_map(key) do
    :ok = IAM.delete_principal_policy(key.principal_arn, name)

    {:noreply,
     socket
     |> load_policy_panel(key)
     |> put_flash(:info, "Deleted identity policy #{name}")}
  end

  def handle_event("delete_policy", _params, socket) do
    {:noreply, put_flash(socket, :error, "Select an access key before deleting a policy")}
  end

  defp find_key(access_key_id) do
    Enum.find(IAM.list_access_keys(), &(&1.access_key_id == access_key_id))
  end

  defp load_policy_panel(socket, key) do
    policies =
      key.principal_arn
      |> IAM.list_principal_policies()
      |> Enum.map(&policy_view/1)

    socket
    |> assign(:selected_key, key)
    |> assign(:policies, policies)
    |> assign(:policy_form, policy_form())
  end

  defp clear_policy_panel(socket) do
    socket
    |> assign(:selected_key, nil)
    |> assign(:policies, [])
    |> assign(:policy_form, policy_form())
  end

  defp maybe_clear_selected_key(socket, access_key_id) do
    case socket.assigns.selected_key do
      %{access_key_id: ^access_key_id} -> clear_policy_panel(socket)
      _other -> socket
    end
  end

  defp policy_view(%{policy_name: policy_name, document: document}) do
    %{
      policy_name: policy_name,
      document_json: Jason.encode!(document, pretty: true)
    }
  end

  defp policy_form, do: policy_form("", @policy_template)
  defp policy_form(params) when is_map(params), do: to_form(params, as: :policy)
  defp policy_form(name, json), do: to_form(%{"name" => name, "json" => json}, as: :policy)

  defp policy_dom_id(name), do: "policy-" <> policy_dom_suffix(name)

  defp policy_dom_suffix(name), do: Base.encode16(name, case: :lower)

  defp policy_manageable?(%{type: "root"}), do: false
  defp policy_manageable?(_key), do: true
end
