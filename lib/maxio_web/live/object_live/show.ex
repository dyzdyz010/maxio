defmodule MaxioWeb.ObjectLive.Show do
  @moduledoc """
  Object Detail（M5-6）：对象详情元数据（size/etag/content-type/storage-class/version_id/
  修改时间）+ 标签编辑（raw 文本 ↔ `[{k,v}]`，经 `Maxio.Tags.validate(_, :object)` 校验，
  `:invalid_tag` 显式 flash，绝不静默放行，铁律 3）+ 版本历史（`Objects.list_object_versions/2`，
  含 delete marker badge，per-version 流式下载经 `DownloadController` + 永久删除经
  `Objects.delete_version/3`，删后 `stream(reset: true)` 重取以反映 promote_latest）。
  不存在的桶/对象 → `push_navigate` 回 browse（flash 不静默）。路由 `live "/buckets/:bucket/object/*key"`
  已在 M5-5 注册，本单元只「完整替换」占位实现，勿重复添加路由。
  """
  use MaxioWeb, :live_view

  alias Maxio.{Buckets, Objects, Tags}

  @impl true
  def mount(%{"bucket" => bucket, "key" => key_segments}, _session, socket) do
    key = Enum.join(key_segments, "/")

    with {:ok, b} <- Buckets.lookup(bucket),
         {:ok, obj} <- Objects.get_metadata(bucket, key) do
      {:ok, tag_list} = Objects.get_tags(bucket, key)
      versions = versions_for(bucket, key)

      {:ok,
       socket
       |> assign(:bucket, bucket)
       |> assign(:versioning, b.versioning)
       |> assign(:key, key)
       |> assign(:object, obj)
       |> assign(:page_title, key)
       |> assign(:tag_form, tags_to_form(tag_list))
       |> stream(:versions, versions)}
    else
      _ ->
        {:ok,
         socket
         |> put_flash(:error, "对象不存在")
         |> push_navigate(to: ~p"/buckets/#{bucket}/browse")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_principal}>
      <.header>
        <span class="font-mono text-base">{@key}</span>
        <:subtitle>
          <.link navigate={~p"/buckets/#{@bucket}/browse"} class="link">← 返回 {@bucket}</.link>
        </:subtitle>
        <:actions>
          <.link href={~p"/buckets/#{@bucket}/download/#{@key}"} class="btn btn-primary btn-sm">
            <.icon name="hero-arrow-down-tray" class="size-4" /> 下载
          </.link>
        </:actions>
      </.header>

      <div id="object-detail" class="grid lg:grid-cols-2 gap-6">
        <%!-- 元数据 --%>
        <div class="rounded-box bg-base-100 border border-base-300 p-4 space-y-2">
          <h2 class="font-semibold text-sm text-base-content/70 mb-2">元数据</h2>
          <.meta label="Key" value={@object.key} />
          <.meta label="大小" value={"#{@object.size} 字节"} />
          <.meta label="ETag" value={@object.etag} />
          <.meta label="Content-Type" value={@object.content_type} />
          <.meta label="Storage Class" value={@object.storage_class} />
          <.meta label="Version ID" value={@object.version_id} />
          <.meta
            label="修改时间"
            value={Calendar.strftime(@object.updated_at, "%Y-%m-%d %H:%M:%S")}
          />
        </div>

        <%!-- tags 编辑 --%>
        <div class="rounded-box bg-base-100 border border-base-300 p-4">
          <h2 class="font-semibold text-sm text-base-content/70 mb-2">标签（key=value，每行一对）</h2>
          <.form for={@tag_form} id="tags-form" phx-submit="save_tags" class="space-y-2">
            <.input
              field={@tag_form[:raw]}
              type="textarea"
              rows="6"
              placeholder="env=prod&#10;team=storage"
            />
            <.button variant="primary" id="tags-submit" type="submit">保存标签</.button>
          </.form>
        </div>
      </div>

      <%!-- 版本列表 --%>
      <div class="mt-6">
        <h2 class="font-semibold text-sm text-base-content/70 mb-2">版本历史</h2>
        <table class="table table-zebra">
          <thead>
            <tr>
              <th>Version ID</th>
              <th>类型</th>
              <th class="text-right">大小</th>
              <th>时间</th>
              <th class="w-0"></th>
            </tr>
          </thead>
          <tbody id="versions" phx-update="stream">
            <tr class="hidden only:table-row" id="versions-empty">
              <td colspan="5" class="text-center text-base-content/60">无版本历史</td>
            </tr>
            <tr :for={{dom_id, v} <- @streams.versions} id={dom_id}>
              <td class="font-mono text-xs">
                {v.version_id}{if v.is_latest, do: " (latest)", else: ""}
              </td>
              <td>
                <span :if={v.is_delete_marker} class="badge badge-sm badge-warning">
                  delete marker
                </span>
                <span :if={!v.is_delete_marker} class="badge badge-sm badge-ghost">version</span>
              </td>
              <td class="text-right">{v.size}</td>
              <td class="text-sm text-base-content/70">
                {Calendar.strftime(v.updated_at, "%Y-%m-%d %H:%M")}
              </td>
              <td>
                <div class="flex gap-2 justify-end">
                  <.link
                    :if={!v.is_delete_marker}
                    href={~p"/buckets/#{@bucket}/download/#{@key}?versionId=#{v.version_id}"}
                    class="btn btn-ghost btn-xs"
                    id={"download-version-#{dom_id}"}
                  >
                    <.icon name="hero-arrow-down-tray" class="size-3" />
                  </.link>
                  <.button
                    id={"delete-version-#{dom_id}"}
                    phx-click="delete_version"
                    phx-value-vid={v.version_id}
                    data-confirm="永久删除该版本？"
                  >
                    <.icon name="hero-trash" class="size-3" />
                  </.button>
                </div>
              </td>
            </tr>
          </tbody>
        </table>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def handle_event("save_tags", %{"tags" => %{"raw" => raw}}, socket) do
    bucket = socket.assigns.bucket
    key = socket.assigns.key
    tag_list = parse_raw_tags(raw)

    case Tags.validate(tag_list, :object) do
      :ok ->
        case Objects.put_tags(bucket, key, tag_list) do
          :ok ->
            {:noreply,
             socket
             |> assign(:tag_form, tags_to_form(tag_list))
             |> put_flash(:info, "标签已保存")}

          {:error, :not_found} ->
            {:noreply, put_flash(socket, :error, "对象不存在")}
        end

      {:error, :invalid_tag} ->
        {:noreply, put_flash(socket, :error, "标签非法（对象 ≤10 个，键 1-128 / 值 0-256，不可 aws: 前缀）")}
    end
  end

  @impl true
  def handle_event("delete_version", %{"vid" => vid}, socket) do
    bucket = socket.assigns.bucket
    key = socket.assigns.key

    case Objects.delete_version(bucket, key, vid) do
      {:ok, _} ->
        # 重取版本列表（promote_latest 可能改变其他行的 is_latest）+ 重取当前对象元数据。
        versions = versions_for(bucket, key)

        socket =
          case Objects.get_metadata(bucket, key) do
            {:ok, obj} -> assign(socket, :object, obj)
            {:error, :not_found} -> socket
          end

        {:noreply,
         socket
         |> stream(:versions, versions, reset: true)
         |> put_flash(:info, "已删除版本 #{vid}")}

      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, "版本不存在")}
    end
  end

  # ── 辅助 ──

  # 取该 (bucket, key) 的全部版本行（list_object_versions 以 prefix 查询，再精确过滤同名 key）。
  defp versions_for(bucket, key) do
    %{versions: versions} = Objects.list_object_versions(bucket, %{prefix: key, max_keys: 1000})
    Enum.filter(versions, &(&1.key == key))
  end

  # tag list → 表单（raw 文本：每行 key=value）。
  defp tags_to_form(tag_list) do
    raw = tag_list |> Enum.map(fn {k, v} -> "#{k}=#{v}" end) |> Enum.join("\n")
    to_form(%{"raw" => raw}, as: :tags)
  end

  # raw 文本（每行 key=value）→ [{k,v}]（忽略空行，按 = 分一次）。
  defp parse_raw_tags(raw) do
    raw
    |> String.split(~r/\r?\n/, trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(fn line ->
      case String.split(line, "=", parts: 2) do
        [k, v] -> {String.trim(k), String.trim(v)}
        [k] -> {String.trim(k), ""}
      end
    end)
  end

  attr :label, :string, required: true
  attr :value, :any, required: true

  defp meta(assigns) do
    ~H"""
    <div class="flex gap-3 text-sm">
      <span class="w-32 shrink-0 text-base-content/60">{@label}</span>
      <span class="font-mono break-all">{@value}</span>
    </div>
    """
  end
end
