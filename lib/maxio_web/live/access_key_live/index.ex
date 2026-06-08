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

  @impl true
  def mount(_params, _session, socket) do
    keys = IAM.list_access_keys()

    {:ok,
     socket
     |> assign(:page_title, "Access Keys")
     |> assign(:key_count, length(keys))
     |> assign(:new_secret, nil)
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

      <.form for={%{}} as={:key} id="create-key-form" phx-submit="create_key" class="mb-6">
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
          </tr>
        </thead>
        <tbody id="access-keys" phx-update="stream">
          <tr class="hidden only:table-row" id="access-keys-empty">
            <td colspan="5" class="text-center text-base-content/60">暂无 access key</td>
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
         |> put_flash(:info, "已删除 #{ak}")}

      {:error, :cannot_delete_last_root} ->
        {:noreply, put_flash(socket, :error, "不能删除最后一个 root 密钥")}
    end
  end
end
