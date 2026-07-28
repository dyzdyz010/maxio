defmodule MaxioWeb.BucketLive.Index do
  @moduledoc """
  Buckets 列表 + 创建 + 删除（M5-4）。
  列表用 stream（`#buckets` 父 + `phx-update="stream"` + 子 `dom_id`），计数单独 assign；
  创建走 `Maxio.Buckets.create/3`（名校验），可选 Object Lock 时复用 S3 CreateBucket 语义
  （versioning=Enabled + ObjectLockEnabled），删除走 `Maxio.Buckets.delete/1`（非空守卫）。
  所有 context 错误（:invalid_bucket_name / :already_owned / changeset / :not_empty / :not_found）
  必须显式 flash 呈现，绝不静默吞掉（铁律 3）。
  """
  use MaxioWeb, :live_view

  alias Maxio.Buckets
  alias Maxio.S3.ObjectLock

  require Logger

  @impl true
  def mount(_params, _session, socket) do
    buckets = Buckets.list()

    {:ok,
     socket
     |> assign(:page_title, "Buckets")
     |> assign(:bucket_count, length(buckets))
     |> assign(:form, empty_form())
     |> stream(:buckets, buckets)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_principal}>
      <.header>
        Buckets
        <:subtitle>{@bucket_count} 个桶</:subtitle>
      </.header>

      <.form
        for={@form}
        id="create-bucket-form"
        phx-submit="create_bucket"
        class="mb-6"
      >
        <div class="flex flex-col gap-3 sm:flex-row sm:items-end">
          <div class="flex-1 max-w-sm">
            <.input field={@form[:name]} type="text" label="新建桶名" placeholder="my-bucket" />
          </div>
          <div class="sm:pb-2">
            <.input
              field={@form[:object_lock_enabled]}
              type="checkbox"
              label="启用 Object Lock（创建后不可关闭）"
            />
          </div>
          <.button variant="primary" id="create-bucket-submit" type="submit">
            <.icon name="hero-plus" class="size-4" /> 创建
          </.button>
        </div>
      </.form>

      <table class="table table-zebra">
        <thead>
          <tr>
            <th>名称</th>
            <th>区域</th>
            <th>版本化</th>
            <th>创建时间</th>
            <th class="w-0"></th>
          </tr>
        </thead>
        <tbody id="buckets" phx-update="stream">
          <tr class="hidden only:table-row" id="buckets-empty">
            <td colspan="5" class="text-center text-base-content/60">暂无桶，创建一个开始。</td>
          </tr>
          <tr :for={{dom_id, bucket} <- @streams.buckets} id={dom_id}>
            <td>
              <.link
                navigate={~p"/buckets/#{bucket.name}/browse"}
                class="link link-primary font-medium"
              >
                {bucket.name}
              </.link>
            </td>
            <td>{bucket.region}</td>
            <td>
              <span class={[
                "badge badge-sm",
                bucket.versioning == "Enabled" && "badge-success",
                bucket.versioning != "Enabled" && "badge-ghost"
              ]}>
                {bucket.versioning}
              </span>
            </td>
            <td class="text-sm text-base-content/70">
              {Calendar.strftime(bucket.inserted_at, "%Y-%m-%d %H:%M")}
            </td>
            <td>
              <div class="flex gap-2 justify-end">
                <.link
                  navigate={~p"/buckets/#{bucket.name}/settings"}
                  class="btn btn-ghost btn-sm"
                >
                  <.icon name="hero-cog-6-tooth" class="size-4" />
                </.link>
                <.button
                  id={"delete-bucket-#{bucket.name}"}
                  phx-click="delete_bucket"
                  phx-value-name={bucket.name}
                  data-confirm={"确定删除桶 #{bucket.name}？（须为空）"}
                >
                  <.icon name="hero-trash" class="size-4" />
                </.button>
              </div>
            </td>
          </tr>
        </tbody>
      </table>
    </Layouts.app>
    """
  end

  @impl true
  def handle_event("create_bucket", %{"bucket" => params}, socket) do
    name = Map.get(params, "name", "")
    object_lock_enabled? = checkbox_checked?(Map.get(params, "object_lock_enabled"))
    owner = socket.assigns.current_principal.arn

    case Buckets.create(name, owner) do
      {:ok, bucket} ->
        case maybe_enable_object_lock(bucket.name, object_lock_enabled?) do
          :ok ->
            bucket = reload_bucket!(bucket.name)

            message =
              if object_lock_enabled? do
                "已创建桶 #{bucket.name}，已启用 Object Lock"
              else
                "已创建桶 #{bucket.name}"
              end

            {:noreply, insert_created_bucket(socket, bucket, :info, message)}

          {:error, reason} ->
            Logger.error("console create bucket object lock enable failed",
              bucket: bucket.name,
              reason: inspect(reason)
            )

            bucket = reload_bucket!(bucket.name)

            {:noreply,
             insert_created_bucket(
               socket,
               bucket,
               :error,
               "桶 #{bucket.name} 已创建，但启用 Object Lock 失败；请删除该桶后重新创建，并查看结构化日志"
             )}
        end

      {:error, :invalid_bucket_name} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "桶名不符合 S3 命名规则（3-63 位，小写字母/数字/.-，首尾字母数字）"
         )}

      {:error, :already_owned} ->
        {:noreply, put_flash(socket, :error, "桶 #{name} 已存在")}

      {:error, %Ecto.Changeset{} = cs} ->
        {:noreply,
         socket
         |> put_flash(:error, "创建失败")
         |> assign(:form, to_form(cs, as: :bucket))}
    end
  end

  @impl true
  def handle_event("delete_bucket", %{"name" => name}, socket) do
    # stream_delete 需要带真实 id 的 struct——先 lookup 拿 %Bucket{}。
    case Buckets.lookup(name) do
      {:ok, bucket} ->
        case Buckets.delete(name) do
          :ok ->
            {:noreply,
             socket
             |> stream_delete(:buckets, bucket)
             |> update(:bucket_count, &max(&1 - 1, 0))
             |> put_flash(:info, "已删除桶 #{name}")}

          {:error, :not_empty} ->
            {:noreply, put_flash(socket, :error, "桶 #{name} 非空，无法删除")}

          {:error, :not_found} ->
            {:noreply, put_flash(socket, :error, "桶 #{name} 不存在")}
        end

      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, "桶 #{name} 不存在")}
    end
  end

  defp maybe_enable_object_lock(_bucket, false), do: :ok

  defp maybe_enable_object_lock(bucket, true) do
    object_lock_enabler().(bucket)
  rescue
    error -> {:error, error}
  end

  defp object_lock_enabler do
    Application.get_env(:maxio, :console_object_lock_enabler, &ObjectLock.enable_bucket!/1)
  end

  defp insert_created_bucket(socket, bucket, level, message) do
    socket
    |> stream_insert(:buckets, bucket, at: 0)
    |> update(:bucket_count, &(&1 + 1))
    |> put_flash(level, message)
    |> assign(:form, empty_form())
  end

  defp reload_bucket!(name) do
    {:ok, bucket} = Buckets.lookup(name)
    bucket
  end

  defp empty_form, do: to_form(%{"name" => "", "object_lock_enabled" => "false"}, as: :bucket)

  defp checkbox_checked?(value) when value in [true, "true", "on", "1"], do: true
  defp checkbox_checked?(_value), do: false
end
