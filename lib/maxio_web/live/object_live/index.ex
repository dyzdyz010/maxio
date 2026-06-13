defmodule MaxioWeb.ObjectLive.Index do
  @moduledoc """
  Object Browser（M5-5）：per-bucket 对象列表 + prefix/folder 面包屑导航
  （`list_objects_v2/2` delimiter，common_prefixes 非 stream 渲染、对象走 stream）；
  上传（`allow_upload` + `consume_uploaded_entries` + `File.stream!` 流式喂 `Storage.put`，
  版本化感知 version_id，失败 `{:postpone}` + 标签日志 + flash 不静默，铁律 3/4）；
  新建文件夹（零字节 `prefix/` 对象）；删除（Enabled → `insert_delete_marker`，
  否则 `delete_metadata` + `Storage.delete`）。下载走 `MaxioWeb.DownloadController`。
  """
  use MaxioWeb, :live_view

  require Logger

  alias Maxio.{Buckets, Objects, Storage}
  alias Maxio.Cluster.Placement
  alias Maxio.Objects.Object
  alias Maxio.Versioning.VersionId

  @max_file_size 5 * 1024 * 1024 * 1024
  @chunk_bytes 1_048_576

  @impl true
  def mount(%{"bucket" => bucket}, _session, socket) do
    case Buckets.lookup(bucket) do
      {:ok, b} ->
        {:ok,
         socket
         |> assign(:bucket, bucket)
         |> assign(:versioning, b.versioning)
         |> assign(:page_title, bucket)
         |> assign(:folder_form, to_form(%{"folder" => ""}, as: :folder))
         |> allow_upload(:object,
           accept: :any,
           max_entries: 5,
           max_file_size: @max_file_size,
           chunk_size: @chunk_bytes,
           auto_upload: false
         )}

      {:error, :not_found} ->
        {:ok,
         socket
         |> put_flash(:error, "桶 #{bucket} 不存在")
         |> push_navigate(to: ~p"/buckets")}
    end
  end

  @impl true
  def handle_params(params, _uri, socket) do
    prefix = Map.get(params, "prefix", "") || ""
    bucket = socket.assigns.bucket

    %{objects: objects, common_prefixes: prefixes} =
      Objects.list_objects_v2(bucket, %{prefix: prefix, delimiter: "/", max_keys: 1000})

    {:noreply,
     socket
     |> assign(:prefix, prefix)
     |> assign(:prefixes, prefixes)
     |> assign(:object_count, length(objects))
     |> stream(:objects, objects, reset: true)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_principal}>
      <.header>
        <span id="breadcrumb">
          <.link navigate={~p"/buckets/#{@bucket}/browse"} class="link">{@bucket}</.link>
          <span :if={@prefix != ""} class="text-base-content/50">/ {@prefix}</span>
        </span>
        <:subtitle>{@object_count} 个对象 · {length(@prefixes)} 个文件夹</:subtitle>
        <:actions>
          <.link navigate={~p"/buckets/#{@bucket}/settings"} class="btn btn-ghost btn-sm">
            <.icon name="hero-cog-6-tooth" class="size-4" /> 设置
          </.link>
        </:actions>
      </.header>

      <%!-- 上传 --%>
      <form
        id="upload-form"
        phx-change="validate_upload"
        phx-submit="save_upload"
        class="mb-4 space-y-2"
      >
        <div
          phx-drop-target={@uploads.object.ref}
          class="border-2 border-dashed border-base-300 rounded-box p-6 text-center bg-base-100"
        >
          <.live_file_input upload={@uploads.object} class="file-input file-input-bordered" />
          <p class="text-sm text-base-content/60 mt-2">拖拽文件到此处或点击选择（上传到前缀 {@prefix}）</p>
        </div>

        <div
          :for={entry <- @uploads.object.entries}
          id={"entry-#{entry.ref}"}
          class="flex items-center gap-3"
        >
          <span class="flex-1 truncate text-sm">{entry.client_name}</span>
          <progress class="progress progress-primary w-40" value={entry.progress} max="100">
            {entry.progress}%
          </progress>
          <button
            type="button"
            phx-click="cancel_upload"
            phx-value-ref={entry.ref}
            aria-label="取消"
          >
            <.icon name="hero-x-mark" class="size-4" />
          </button>
          <p :for={err <- upload_errors(@uploads.object, entry)} class="text-error text-sm">
            {error_to_string(err)}
          </p>
        </div>
        <p :for={err <- upload_errors(@uploads.object)} class="text-error text-sm">
          {error_to_string(err)}
        </p>

        <.button
          variant="primary"
          type="submit"
          id="upload-submit"
          disabled={@uploads.object.entries == []}
        >
          <.icon name="hero-arrow-up-tray" class="size-4" /> 上传
        </.button>
      </form>

      <%!-- 新建文件夹 --%>
      <.form
        for={@folder_form}
        id="create-folder-form"
        phx-submit="create_folder"
        class="flex gap-2 items-end mb-6"
      >
        <div class="max-w-xs">
          <.input
            field={@folder_form[:folder]}
            type="text"
            label="新建文件夹"
            placeholder="reports"
          />
        </div>
        <.button id="create-folder-submit" type="submit">
          <.icon name="hero-folder-plus" class="size-4" /> 创建文件夹
        </.button>
      </.form>

      <table class="table table-zebra">
        <thead>
          <tr>
            <th>名称</th>
            <th class="text-right">大小</th>
            <th>修改时间</th>
            <th class="w-0"></th>
          </tr>
        </thead>
        <tbody>
          <%!-- 文件夹（common prefixes）非 stream，直接渲染 --%>
          <tr :for={cp <- @prefixes}>
            <td colspan="4">
              <.link
                patch={~p"/buckets/#{@bucket}/browse?prefix=#{cp}"}
                class="link flex items-center gap-2"
              >
                <.icon name="hero-folder" class="size-4" /> {folder_label(cp, @prefix)}
              </.link>
            </td>
          </tr>
        </tbody>
        <tbody id="objects" phx-update="stream">
          <tr class="hidden only:table-row" id="objects-empty">
            <td colspan="4" class="text-center text-base-content/60">此前缀下暂无对象</td>
          </tr>
          <tr :for={{dom_id, obj} <- @streams.objects} id={dom_id}>
            <td class="font-mono text-sm">
              <.link navigate={~p"/buckets/#{@bucket}/object/#{obj.key}"} class="link">
                {object_label(obj.key, @prefix)}
              </.link>
            </td>
            <td class="text-right">{obj.size}</td>
            <td class="text-sm text-base-content/70">
              {Calendar.strftime(obj.updated_at, "%Y-%m-%d %H:%M")}
            </td>
            <td>
              <div class="flex gap-2 justify-end">
                <.link
                  href={~p"/buckets/#{@bucket}/download/#{obj.key}"}
                  class="btn btn-ghost btn-sm"
                  id={"download-#{dom_id}"}
                >
                  <.icon name="hero-arrow-down-tray" class="size-4" />
                </.link>
                <.button
                  id={"delete-object-#{dom_id}"}
                  phx-click="delete_object"
                  phx-value-key={obj.key}
                  data-confirm={"删除对象 #{obj.key}？"}
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
  def handle_event("validate_upload", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_event("cancel_upload", %{"ref" => ref}, socket) do
    {:noreply, cancel_upload(socket, :object, ref)}
  end

  @impl true
  def handle_event("save_upload", _params, socket) do
    bucket = socket.assigns.bucket
    prefix = socket.assigns.prefix
    versioning = socket.assigns.versioning

    consumed =
      consume_uploaded_entries(socket, :object, fn %{path: tmp_path}, entry ->
        key = prefix <> entry.client_name
        version_id = if versioning == "Enabled", do: VersionId.generate(), else: "null"
        chunks = File.stream!(tmp_path, @chunk_bytes)

        case Storage.put(bucket, key, version_id, chunks) do
          {:ok, %{size: size, etag: etag} = write_result} ->
            {:ok, obj} =
              Objects.put_version_with_id(
                bucket,
                key,
                version_id,
                %{
                  size: size,
                  etag: etag,
                  content_type: entry.client_type || "binary/octet-stream",
                  storage_class: "STANDARD"
                }
                |> Map.merge(Placement.attrs_from_result(write_result))
              )

            {:ok, obj}

          {:error, reason} ->
            Logger.error("[maxio][Console] upload failed",
              bucket: bucket,
              key: key,
              reason: inspect(reason)
            )

            {:postpone, {:error, reason}}
        end
      end)

    socket =
      Enum.reduce(consumed, socket, fn
        %Object{} = obj, acc ->
          # 仅当对象落在当前前缀的直接层级才插 stream（深层归当前文件夹视图外）。
          if direct_child?(obj.key, prefix) do
            acc |> stream_insert(:objects, obj, at: 0) |> update(:object_count, &(&1 + 1))
          else
            acc
          end

        {:error, _reason}, acc ->
          put_flash(acc, :error, "部分文件上传失败")
      end)

    {:noreply, put_flash(socket, :info, "上传完成")}
  end

  @impl true
  def handle_event("create_folder", %{"folder" => %{"folder" => folder}}, socket) do
    bucket = socket.assigns.bucket
    prefix = socket.assigns.prefix
    name = String.trim(folder)

    cond do
      name == "" ->
        {:noreply, put_flash(socket, :error, "文件夹名不能为空")}

      String.contains?(name, "/") ->
        {:noreply, put_flash(socket, :error, "文件夹名不能含 /")}

      true ->
        key = prefix <> name <> "/"

        case Storage.put(bucket, key, "null", []) do
          {:ok, %{size: size, etag: etag} = write_result} ->
            {:ok, _obj} =
              Objects.put_version_with_id(
                bucket,
                key,
                "null",
                %{
                  size: size,
                  etag: etag,
                  content_type: "application/x-directory"
                }
                |> Map.merge(Placement.attrs_from_result(write_result))
              )

            {:noreply,
             socket
             |> put_flash(:info, "已创建文件夹 #{name}/")
             |> push_patch(to: ~p"/buckets/#{bucket}/browse?prefix=#{key}")}

          {:error, _reason} ->
            {:noreply, put_flash(socket, :error, "创建文件夹失败")}
        end
    end
  end

  @impl true
  def handle_event("delete_object", %{"key" => key}, socket) do
    bucket = socket.assigns.bucket
    versioning = socket.assigns.versioning

    case Objects.get_metadata(bucket, key) do
      {:ok, obj} ->
        if versioning == "Enabled" do
          version_id = VersionId.generate()

          {:ok, _} =
            Objects.insert_delete_marker_with_id(
              bucket,
              key,
              version_id,
              Placement.attrs_for_write(bucket, key)
            )
        else
          storage_opts = Placement.storage_opts(obj)
          :ok = Objects.delete_metadata(bucket, key)
          _ = Storage.delete(bucket, key, "null", storage_opts)
        end

        {:noreply,
         socket
         |> stream_delete(:objects, obj)
         |> update(:object_count, &max(&1 - 1, 0))
         |> put_flash(:info, "已删除 #{key}")}

      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, "对象不存在")}
    end
  end

  # ── 辅助 ──
  # common prefix 是完整 "prefix.../folder/"——展示去掉当前 prefix 后的末段。
  defp folder_label(cp, prefix) do
    cp |> String.replace_prefix(prefix, "") |> String.trim_trailing("/")
  end

  # 对象展示去掉当前 prefix 的末段。
  defp object_label(key, prefix), do: String.replace_prefix(key, prefix, "")

  # 该 key 是否是当前 prefix 的直接子（去 prefix 后不含 "/"，即非深层）。
  defp direct_child?(key, prefix) do
    rest = String.replace_prefix(key, prefix, "")
    rest != "" and not String.contains?(rest, "/")
  end

  defp error_to_string(:too_large), do: "文件超出大小上限（5 GiB）"
  defp error_to_string(:too_many_files), do: "选择的文件过多（最多 5 个）"
  defp error_to_string(:not_accepted), do: "不接受的文件类型"
  defp error_to_string(other), do: "上传错误: #{inspect(other)}"
end
