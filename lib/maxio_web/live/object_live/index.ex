defmodule MaxioWeb.ObjectLive.Index do
  @moduledoc """
  Object Browser（M5-5）：per-bucket 对象列表 + prefix/folder 面包屑导航
  （`list_objects_v2/2` delimiter，common_prefixes 非 stream 渲染、对象走 stream）；
  上传（`allow_upload` + `consume_uploaded_entries` + Console upload 编排，按阈值走单 PUT 或内部
  multipart，版本化感知 version_id，失败 `{:postpone}` + 标签日志 + flash 不静默，铁律 3/4）；
  新建文件夹（零字节 `prefix/` 对象）；删除（Enabled → `insert_delete_marker`，
  否则 `delete_metadata` + `Storage.delete`）。下载走 `MaxioWeb.DownloadController`。
  """
  use MaxioWeb, :live_view

  alias Maxio.Auth.CredentialStore
  alias Maxio.Auth.SigV4.PostPolicy
  alias Maxio.{Buckets, Objects, Storage}
  alias Maxio.Cluster.Placement
  alias Maxio.Console.DirectMultipartUpload
  alias Maxio.Console.DirectMultipartUpload.Cors, as: DirectMultipartCors
  alias Maxio.Console.ObjectUpload
  alias Maxio.Objects.Object
  alias Maxio.S3.Log
  alias Maxio.Versioning.VersionId
  alias MaxioWeb.ConsoleDirectMultipartUploadForm
  alias MaxioWeb.ConsolePostObjectForm

  @max_file_size 5 * 1024 * 1024 * 1024 * 1024
  @chunk_bytes 1_048_576
  @direct_multipart_part_size 8 * 1_024 * 1_024
  @direct_multipart_expires 900
  @direct_multipart_concurrency 3
  @direct_multipart_file_concurrency 2

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
         |> assign(:direct_multipart_part_size, @direct_multipart_part_size)
         |> assign(:direct_multipart_expires, @direct_multipart_expires)
         |> assign(:direct_multipart_concurrency, @direct_multipart_concurrency)
         |> assign(:direct_multipart_file_concurrency, @direct_multipart_file_concurrency)
         |> assign(:direct_multipart_uploads, [])
         |> assign(:direct_multipart_history, [])
         |> assign(:direct_multipart_filters, direct_multipart_filters(%{}))
         |> assign(
           :direct_multipart_filter_form,
           to_form(direct_multipart_filter_form_data(direct_multipart_filters(%{})),
             as: :direct_multipart_filters
           )
         )
         |> assign(:direct_multipart_bulk_form, to_form(%{}, as: :direct_multipart_bulk))
         |> assign(:direct_multipart_cors_ready?, false)
         |> assign(:console_origin, nil)
         |> assign(
           :direct_multipart_storage_class_options,
           ConsoleDirectMultipartUploadForm.storage_class_options()
         )
         |> assign(
           :direct_multipart_sse_options,
           ConsoleDirectMultipartUploadForm.sse_algorithm_options()
         )
         |> assign(
           :direct_multipart_checksum_options,
           ConsoleDirectMultipartUploadForm.checksum_algorithm_options()
         )
         |> assign(
           :direct_multipart_checksum_type_options,
           ConsoleDirectMultipartUploadForm.checksum_type_options()
         )
         |> assign(:post_policy_form, ConsolePostObjectForm.form())
         |> assign(:post_object_html, nil)
         |> assign(:post_object_max_size, ConsolePostObjectForm.max_object_size())
         |> assign(
           :post_policy_success_status_options,
           ConsolePostObjectForm.success_status_options()
         )
         |> assign(:post_policy_acl_options, ConsolePostObjectForm.acl_options())
         |> assign(:post_policy_sse_options, ConsolePostObjectForm.sse_algorithm_options())
         |> assign(
           :post_policy_checksum_options,
           ConsolePostObjectForm.checksum_algorithm_options()
         )
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
  def handle_params(params, uri, socket) do
    prefix = Map.get(params, "prefix", "") || ""
    bucket = socket.assigns.bucket
    old_prefix = Map.get(socket.assigns, :prefix)
    console_origin = console_origin(uri)
    direct_filters = direct_multipart_filters(params)

    %{objects: objects, common_prefixes: prefixes} =
      Objects.list_objects_v2(bucket, %{prefix: prefix, delimiter: "/", max_keys: 1000})

    direct_uploads = list_direct_multipart_uploads(bucket, prefix, socket, direct_filters)
    direct_history = list_direct_multipart_history(bucket, prefix, socket, direct_filters)

    post_object_html =
      if old_prefix in [nil, prefix], do: socket.assigns.post_object_html, else: nil

    {:noreply,
     socket
     |> assign(:prefix, prefix)
     |> assign(:prefixes, prefixes)
     |> assign(:object_count, length(objects))
     |> assign(:direct_multipart_uploads, direct_uploads)
     |> assign(:direct_multipart_history, direct_history)
     |> assign(:direct_multipart_filters, direct_filters)
     |> assign(
       :direct_multipart_filter_form,
       to_form(direct_multipart_filter_form_data(direct_filters), as: :direct_multipart_filters)
     )
     |> assign(:console_origin, console_origin)
     |> assign(
       :direct_multipart_cors_ready?,
       direct_multipart_cors_ready?(bucket, console_origin)
     )
     |> assign(:post_object_html, post_object_html)
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
      <div
        id="direct-multipart-cors-helper"
        class="mb-3 flex flex-col gap-3 rounded-box border border-base-300 bg-base-100 p-3 md:flex-row md:items-center md:justify-between"
      >
        <div
          id="direct-multipart-cors-state"
          class={[
            "flex min-w-0 items-center gap-2 text-sm font-medium",
            @direct_multipart_cors_ready? && "text-success",
            not @direct_multipart_cors_ready? && "text-warning"
          ]}
        >
          <.icon
            name={
              if(@direct_multipart_cors_ready?,
                do: "hero-check-circle",
                else: "hero-exclamation-triangle"
              )
            }
            class="size-5 shrink-0"
          />
          <span>
            {if(@direct_multipart_cors_ready?,
              do: "Direct upload CORS ready",
              else: "Direct upload CORS needs ETag"
            )}
          </span>
        </div>
        <div class="flex flex-wrap items-center gap-2">
          <.button
            id="direct-multipart-apply-cors"
            phx-click="apply_direct_multipart_cors"
            disabled={is_nil(@console_origin)}
          >
            <.icon name="hero-arrow-path" class="size-4" /> Apply CORS rule
          </.button>
          <.link
            id="direct-multipart-cors-settings"
            navigate={~p"/buckets/#{@bucket}/settings?tab=cors"}
            class="btn btn-ghost btn-sm"
          >
            <.icon name="hero-adjustments-horizontal" class="size-4" /> CORS JSON
          </.link>
        </div>
      </div>

      <div
        id="direct-multipart-upload-panel"
        phx-hook="DirectMultipartUpload"
        phx-update="ignore"
        data-bucket={@bucket}
        data-prefix={@prefix}
        data-part-size={@direct_multipart_part_size}
        data-expires-in={@direct_multipart_expires}
        data-concurrency={@direct_multipart_concurrency}
        data-file-concurrency={@direct_multipart_file_concurrency}
        class="mb-4 rounded-box bg-base-100 border border-base-300 p-4 space-y-3"
      >
        <div class="flex flex-col gap-2 md:flex-row md:items-end">
          <div class="flex-1">
            <label class="label" for="direct-multipart-file-input">
              <span class="label-text">Direct multipart upload</span>
            </label>
            <input
              id="direct-multipart-file-input"
              data-role="file-input"
              type="file"
              multiple
              class="file-input file-input-bordered w-full"
            />
          </div>
          <button
            id="direct-multipart-start"
            data-role="start"
            type="button"
            class="btn btn-primary"
          >
            <.icon name="hero-arrow-up-tray" class="size-4" /> Start
          </button>
          <button
            id="direct-multipart-pause"
            data-role="pause"
            type="button"
            class="btn btn-ghost"
          >
            <.icon name="hero-pause" class="size-4" /> Pause
          </button>
          <button
            id="direct-multipart-resume"
            data-role="resume"
            type="button"
            class="btn btn-ghost"
          >
            <.icon name="hero-play" class="size-4" /> Resume
          </button>
          <button
            id="direct-multipart-abort"
            data-role="abort"
            type="button"
            class="btn btn-ghost"
          >
            <.icon name="hero-x-mark" class="size-4" /> Abort
          </button>
        </div>
        <details
          id="direct-multipart-advanced"
          class="rounded-box border border-base-300 bg-base-200/40"
        >
          <summary class="cursor-pointer px-3 py-2 text-sm font-semibold text-base-content/70">
            Advanced S3 headers
          </summary>
          <div class="grid gap-3 p-3 md:grid-cols-2 xl:grid-cols-6">
            <label class="form-control">
              <span class="label-text">Content-Type</span>
              <input
                id="direct-multipart-content-type"
                data-role="content-type"
                type="text"
                class="input input-bordered input-sm w-full"
                placeholder="file type"
              />
            </label>
            <label class="form-control">
              <span class="label-text">Storage Class</span>
              <select
                id="direct-multipart-storage-class"
                data-role="storage-class"
                class="select select-bordered select-sm w-full"
              >
                <option
                  :for={{label, value} <- @direct_multipart_storage_class_options}
                  value={value}
                >
                  {label}
                </option>
              </select>
            </label>
            <label class="form-control">
              <span class="label-text">Cache-Control</span>
              <input
                id="direct-multipart-cache-control"
                data-role="cache-control"
                type="text"
                class="input input-bordered input-sm w-full"
                placeholder="max-age=3600"
              />
            </label>
            <label class="form-control xl:col-span-2">
              <span class="label-text">Content-Disposition</span>
              <input
                id="direct-multipart-content-disposition"
                data-role="content-disposition"
                type="text"
                class="input input-bordered input-sm w-full"
                placeholder="attachment; filename=&quot;object.bin&quot;"
              />
            </label>
            <label class="form-control">
              <span class="label-text">Content-Encoding</span>
              <input
                id="direct-multipart-content-encoding"
                data-role="content-encoding"
                type="text"
                class="input input-bordered input-sm w-full"
                placeholder="identity"
              />
            </label>
            <label class="form-control">
              <span class="label-text">Expires</span>
              <input
                id="direct-multipart-expires"
                data-role="expires"
                type="text"
                class="input input-bordered input-sm w-full"
                placeholder="Wed, 21 Oct 2037 07:28:00 GMT"
              />
            </label>
            <label class="form-control">
              <span class="label-text">SSE</span>
              <select
                id="direct-multipart-sse-algorithm"
                data-role="sse-algorithm"
                class="select select-bordered select-sm w-full"
              >
                <option :for={{label, value} <- @direct_multipart_sse_options} value={value}>
                  {label}
                </option>
              </select>
            </label>
            <label class="form-control xl:col-span-2">
              <span class="label-text">SSE-C Key</span>
              <input
                id="direct-multipart-sse-customer-key"
                data-role="sse-customer-key"
                type="password"
                autocomplete="off"
                class="input input-bordered input-sm w-full"
                placeholder="base64 256-bit key"
              />
            </label>
            <label class="form-control xl:col-span-2">
              <span class="label-text">SSE-C Key MD5</span>
              <input
                id="direct-multipart-sse-customer-key-md5"
                data-role="sse-customer-key-md5"
                type="text"
                autocomplete="off"
                class="input input-bordered input-sm w-full"
                placeholder="optional base64 MD5"
              />
            </label>
            <label class="form-control xl:col-span-2">
              <span class="label-text">KMS Key ID</span>
              <input
                id="direct-multipart-sse-kms-key-id"
                data-role="sse-kms-key-id"
                type="text"
                class="input input-bordered input-sm w-full"
                placeholder="alias/maxio-local"
              />
            </label>
            <label class="form-control xl:col-span-2">
              <span class="label-text">KMS Context</span>
              <input
                id="direct-multipart-sse-context"
                data-role="sse-context"
                type="text"
                class="input input-bordered input-sm w-full"
                placeholder="base64 JSON"
              />
            </label>
            <label class="flex items-center gap-2 pt-6 text-sm">
              <input
                id="direct-multipart-sse-bucket-key"
                data-role="sse-bucket-key"
                type="checkbox"
                class="checkbox checkbox-sm"
              />
              <span>Bucket Key</span>
            </label>
            <label class="flex items-center gap-2 pt-6 text-sm">
              <input
                id="direct-multipart-request-payer"
                data-role="request-payer"
                type="checkbox"
                class="checkbox checkbox-sm"
              />
              <span>Requester Pays</span>
            </label>
            <label class="form-control">
              <span class="label-text">Checksum</span>
              <select
                id="direct-multipart-checksum-algorithm"
                data-role="checksum-algorithm"
                class="select select-bordered select-sm w-full"
              >
                <option :for={{label, value} <- @direct_multipart_checksum_options} value={value}>
                  {label}
                </option>
              </select>
            </label>
            <label class="form-control">
              <span class="label-text">Checksum Type</span>
              <select
                id="direct-multipart-checksum-type"
                data-role="checksum-type"
                class="select select-bordered select-sm w-full"
              >
                <option
                  :for={{label, value} <- @direct_multipart_checksum_type_options}
                  value={value}
                >
                  {label}
                </option>
              </select>
            </label>
            <label class="form-control xl:col-span-3">
              <span class="label-text">Metadata</span>
              <textarea
                id="direct-multipart-metadata"
                data-role="metadata"
                rows="4"
                class="textarea textarea-bordered textarea-sm w-full"
                placeholder="origin=console&#10;team=storage"
              ></textarea>
            </label>
            <label class="form-control xl:col-span-3">
              <span class="label-text">Tags</span>
              <textarea
                id="direct-multipart-tagging"
                data-role="tagging"
                rows="4"
                class="textarea textarea-bordered textarea-sm w-full"
                placeholder="env=prod&#10;team=storage"
              ></textarea>
            </label>
          </div>
        </details>
        <progress
          id="direct-multipart-progress"
          data-role="progress"
          class="progress progress-primary w-full"
          value="0"
          max="1"
        >
        </progress>
        <p
          id="direct-multipart-status"
          data-role="status"
          class="text-sm text-base-content/70"
        >
          Ready
        </p>
      </div>

      <div
        id="direct-multipart-operations"
        class="mb-4 rounded-box bg-base-100 border border-base-300 p-4"
      >
        <div class="mb-3 flex flex-wrap items-center justify-between gap-3">
          <div>
            <h2 class="text-sm font-semibold text-base-content/70">Direct upload operations</h2>
            <p id="direct-multipart-filter-summary" class="text-xs text-base-content/60">
              {direct_multipart_scope_label(@direct_multipart_filters.scope)}
            </p>
          </div>
          <.link
            id="direct-multipart-history-export"
            href={direct_multipart_history_export_path(@bucket, @prefix, @direct_multipart_filters)}
            class="btn btn-ghost btn-sm"
          >
            <.icon name="hero-arrow-down-tray" class="size-4" /> Export CSV
          </.link>
        </div>
        <.form
          for={@direct_multipart_filter_form}
          id="direct-multipart-filter-form"
          phx-submit="filter_direct_multipart"
          class="grid gap-3 md:grid-cols-[minmax(9rem,1fr)_minmax(9rem,1fr)_minmax(12rem,2fr)_minmax(8rem,1fr)_auto]"
        >
          <.input
            field={@direct_multipart_filter_form[:scope]}
            type="select"
            label="Scope"
            options={direct_multipart_scope_options()}
            class="select select-bordered select-sm w-full"
          />
          <.input
            field={@direct_multipart_filter_form[:state]}
            type="select"
            label="History state"
            options={direct_multipart_state_options()}
            class="select select-bordered select-sm w-full"
          />
          <.input
            field={@direct_multipart_filter_form[:query]}
            type="search"
            label="Search"
            placeholder="key, file, upload id"
            maxlength="256"
            class="input input-bordered input-sm w-full"
          />
          <.input
            field={@direct_multipart_filter_form[:limit]}
            type="select"
            label="Rows"
            options={direct_multipart_limit_options()}
            class="select select-bordered select-sm w-full"
          />
          <div class="flex items-end">
            <.button id="direct-multipart-filter-apply" type="submit" class="btn btn-sm w-full">
              <.icon name="hero-funnel" class="size-4" /> Apply
            </.button>
          </div>
        </.form>
      </div>

      <div
        :if={@direct_multipart_uploads != []}
        id="direct-multipart-active-uploads"
        class="mb-4 rounded-box bg-base-100 border border-base-300 p-4"
      >
        <div class="mb-3 flex items-center justify-between gap-3">
          <h2 class="text-sm font-semibold text-base-content/70">Unfinished direct uploads</h2>
          <div class="flex items-center gap-2">
            <span id="direct-multipart-active-count" class="badge badge-ghost">
              {length(@direct_multipart_uploads)}
            </span>
          </div>
        </div>
        <.form
          for={@direct_multipart_bulk_form}
          id="direct-multipart-bulk-form"
          phx-submit="abort_direct_multipart_uploads"
        >
          <div class="mb-2 flex justify-end">
            <.button
              id="abort-selected-direct-multipart-uploads"
              type="submit"
              data-confirm="Abort selected multipart uploads?"
            >
              <.icon name="hero-x-mark" class="size-4" /> Abort selected
            </.button>
          </div>
          <table class="table table-sm">
            <thead>
              <tr>
                <th class="w-0">Select</th>
                <th>Key</th>
                <th>Parts</th>
                <th>Uploaded</th>
                <th>Started</th>
                <th class="w-0"></th>
              </tr>
            </thead>
            <tbody>
              <tr
                :for={upload <- @direct_multipart_uploads}
                id={"direct-multipart-upload-#{upload.id}"}
              >
                <td>
                  <input
                    id={"direct-multipart-select-#{upload.id}"}
                    type="checkbox"
                    name="direct_multipart_bulk[upload_ids][]"
                    value={upload.id}
                    class="checkbox checkbox-sm"
                  />
                </td>
                <td class="font-mono text-xs">{object_label(upload.key, @prefix)}</td>
                <td>{upload.part_count}</td>
                <td>{upload.uploaded_size} / {upload.file_size}</td>
                <td class="text-xs text-base-content/60">
                  {Calendar.strftime(upload.inserted_at, "%Y-%m-%d %H:%M")}
                </td>
                <td>
                  <.button
                    id={"abort-direct-multipart-upload-#{upload.id}"}
                    type="button"
                    phx-click="abort_direct_multipart_upload"
                    phx-value-id={upload.id}
                    data-confirm={"Abort multipart upload #{upload.upload_id}?"}
                  >
                    <.icon name="hero-x-mark" class="size-4" />
                  </.button>
                </td>
              </tr>
            </tbody>
          </table>
        </.form>
      </div>

      <div
        :if={@direct_multipart_history != []}
        id="direct-multipart-history"
        class="mb-4 rounded-box bg-base-100 border border-base-300 p-4"
      >
        <div class="mb-3 flex items-center justify-between gap-3">
          <h2 class="text-sm font-semibold text-base-content/70">Recent direct uploads</h2>
          <span id="direct-multipart-history-count" class="badge badge-ghost">
            {length(@direct_multipart_history)}
          </span>
        </div>
        <table class="table table-sm">
          <thead>
            <tr>
              <th>Key</th>
              <th>State</th>
              <th>Parts</th>
              <th>Size</th>
              <th>Finished</th>
            </tr>
          </thead>
          <tbody>
            <tr
              :for={history <- @direct_multipart_history}
              id={"direct-multipart-history-#{history.id}"}
            >
              <td class="font-mono text-xs">{object_label(history.key, @prefix)}</td>
              <td>
                <span class={direct_multipart_history_badge_class(history.terminal_state)}>
                  {history.terminal_state}
                </span>
              </td>
              <td>{history.part_count}</td>
              <td>{history.uploaded_size} / {history.file_size}</td>
              <td class="text-xs text-base-content/60">
                {Calendar.strftime(history.terminal_at, "%Y-%m-%d %H:%M")}
              </td>
            </tr>
          </tbody>
        </table>
      </div>

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

      <div
        id="prefix-post-object-panel"
        class="mb-4 rounded-box bg-base-100 border border-base-300 p-4 space-y-3"
      >
        <h2 class="font-semibold text-sm text-base-content/70">POST Object form</h2>
        <.form
          for={@post_policy_form}
          id="prefix-post-object-policy-form"
          phx-submit="create_prefix_post_object_form"
          class="grid gap-3 md:grid-cols-2 xl:grid-cols-6"
        >
          <div>
            <.input
              field={@post_policy_form[:expires_in]}
              type="number"
              label="Expires"
              min="1"
              max="43200"
            />
          </div>
          <div>
            <.input
              field={@post_policy_form[:max_size]}
              type="number"
              label="Max Size"
              min="1"
              max={@post_object_max_size}
            />
          </div>
          <div>
            <.input
              field={@post_policy_form[:success_action_status]}
              type="select"
              label="Success"
              options={@post_policy_success_status_options}
            />
          </div>
          <div class="xl:col-span-2">
            <.input
              field={@post_policy_form[:success_action_redirect]}
              type="text"
              label="Redirect"
              placeholder="https://example.com/uploaded"
            />
          </div>
          <div>
            <.input
              field={@post_policy_form[:acl]}
              type="select"
              label="ACL"
              options={@post_policy_acl_options}
            />
          </div>
          <div>
            <.input
              field={@post_policy_form[:content_md5]}
              type="text"
              label="Content-MD5"
              placeholder="base64 md5"
            />
          </div>
          <div>
            <.input
              field={@post_policy_form[:content_type]}
              type="text"
              label="Content-Type"
              placeholder="application/octet-stream"
            />
          </div>
          <div>
            <.input
              field={@post_policy_form[:cache_control]}
              type="text"
              label="Cache-Control"
              placeholder="max-age=3600"
            />
          </div>
          <div class="xl:col-span-2">
            <.input
              field={@post_policy_form[:content_disposition]}
              type="text"
              label="Content-Disposition"
              placeholder="attachment; filename=&quot;object.bin&quot;"
            />
          </div>
          <div>
            <.input
              field={@post_policy_form[:content_encoding]}
              type="text"
              label="Content-Encoding"
              placeholder="identity"
            />
          </div>
          <div>
            <.input
              field={@post_policy_form[:expires]}
              type="text"
              label="Expires"
              placeholder="Wed, 21 Oct 2037 07:28:00 GMT"
            />
          </div>
          <div>
            <.input
              field={@post_policy_form[:sse_algorithm]}
              type="select"
              label="SSE"
              options={@post_policy_sse_options}
            />
          </div>
          <div class="xl:col-span-2">
            <.input
              field={@post_policy_form[:sse_kms_key_id]}
              type="text"
              label="KMS Key ID"
              placeholder="alias/maxio-local"
            />
          </div>
          <div class="xl:col-span-2">
            <.input
              field={@post_policy_form[:sse_context]}
              type="text"
              label="KMS Context"
              placeholder="base64 JSON"
            />
          </div>
          <div>
            <.input
              field={@post_policy_form[:sse_bucket_key]}
              type="checkbox"
              label="Bucket Key"
            />
          </div>
          <div class="xl:col-span-2">
            <.input
              field={@post_policy_form[:sse_customer_key]}
              type="password"
              label="SSE-C Key"
              placeholder="base64 256-bit key"
            />
          </div>
          <div class="xl:col-span-2">
            <.input
              field={@post_policy_form[:sse_customer_key_md5]}
              type="text"
              label="SSE-C Key MD5"
              placeholder="optional base64 md5"
            />
          </div>
          <div>
            <.input
              field={@post_policy_form[:request_payer]}
              type="checkbox"
              label="Requester Pays"
            />
          </div>
          <div>
            <.input
              field={@post_policy_form[:checksum_algorithm]}
              type="select"
              label="Checksum"
              options={@post_policy_checksum_options}
            />
          </div>
          <div class="xl:col-span-2">
            <.input
              field={@post_policy_form[:checksum_value]}
              type="text"
              label="Checksum Value"
              placeholder="base64 checksum"
            />
          </div>
          <div class="xl:col-span-3">
            <.input
              field={@post_policy_form[:metadata]}
              type="textarea"
              rows="4"
              label="Metadata"
              placeholder="origin=console&#10;team=storage"
            />
          </div>
          <div class="xl:col-span-3">
            <.input
              field={@post_policy_form[:tagging]}
              type="textarea"
              rows="4"
              label="Tags"
              placeholder="env=prod&#10;team=storage"
            />
          </div>
          <div class="xl:col-span-6">
            <.input
              field={@post_policy_form[:raw_amz_fields]}
              type="textarea"
              rows="4"
              label="Raw x-amz fields"
              placeholder="x-amz-storage-class=STANDARD_IA&#10;x-amz-website-redirect-location=/index.html"
            />
          </div>
          <.button
            variant="primary"
            id="prefix-post-object-policy-submit"
            type="submit"
            class="self-end"
          >
            <.icon name="hero-document-plus" class="size-4" /> Generate
          </.button>
        </.form>
        <textarea
          :if={@post_object_html}
          id="prefix-post-object-html"
          readonly
          class="textarea textarea-bordered w-full font-mono text-xs"
          rows="12"
        >{@post_object_html}</textarea>
      </div>

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

        case ObjectUpload.upload_tmp_file(bucket, key, versioning, tmp_path, %{
               content_type: entry.client_type || "binary/octet-stream",
               storage_class: "STANDARD"
             }) do
          {:ok, obj} ->
            {:ok, obj}

          {:error, reason} ->
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
  def handle_event("filter_direct_multipart", %{"direct_multipart_filters" => params}, socket) do
    filters = direct_multipart_filters_from_form(params)

    {:noreply, push_patch(socket, to: direct_multipart_patch_path(socket, filters))}
  end

  @impl true
  def handle_event("direct_multipart_uploaded", %{"key" => key}, socket) do
    prefix = socket.assigns.prefix

    socket =
      if String.starts_with?(key, prefix) do
        refresh_object_listing(socket)
      else
        socket
      end

    {:noreply,
     socket
     |> refresh_direct_multipart_state()
     |> put_flash(:info, "Direct multipart upload complete")}
  end

  @impl true
  def handle_event("direct_multipart_aborted", _params, socket) do
    {:noreply,
     socket
     |> refresh_direct_multipart_state()
     |> put_flash(:info, "Direct multipart upload aborted")}
  end

  @impl true
  def handle_event("apply_direct_multipart_cors", _params, socket) do
    bucket = socket.assigns.bucket
    origin = socket.assigns.console_origin

    case DirectMultipartCors.ensure_bucket_rule(bucket, origin) do
      {:ok, _rules, status} ->
        Log.info("console direct multipart cors ensured",
          action: :console_direct_multipart_cors,
          bucket: bucket,
          principal_arn: socket.assigns.current_principal.arn,
          origin: origin,
          status: status
        )

        {:noreply,
         socket
         |> assign(:direct_multipart_cors_ready?, true)
         |> put_flash(:info, direct_multipart_cors_success(status))}

      {:error, reason} ->
        Log.warn("console direct multipart cors failed",
          action: :console_direct_multipart_cors,
          bucket: bucket,
          principal_arn: socket.assigns.current_principal.arn,
          origin: origin,
          reason: reason
        )

        {:noreply,
         socket
         |> refresh_direct_multipart_cors()
         |> put_flash(:error, direct_multipart_cors_error(reason))}
    end
  end

  @impl true
  def handle_event("abort_direct_multipart_upload", %{"id" => id}, socket) do
    filters = socket.assigns.direct_multipart_filters

    case DirectMultipartUpload.abort_scoped(
           id,
           socket.assigns.bucket,
           socket.assigns.prefix,
           socket.assigns.current_principal.arn,
           scope: filters.scope,
           query: filters.query
         ) do
      :ok ->
        {:noreply,
         socket
         |> refresh_direct_multipart_state()
         |> put_flash(:info, "Direct multipart upload aborted")}

      {:error, :not_found} ->
        {:noreply,
         socket
         |> refresh_direct_multipart_state()
         |> put_flash(:error, "Direct multipart upload no longer exists")}

      {:error, _reason} ->
        {:noreply,
         socket
         |> refresh_direct_multipart_state()
         |> put_flash(:error, "Direct multipart upload abort failed")}
    end
  end

  @impl true
  def handle_event(
        "abort_direct_multipart_uploads",
        %{"direct_multipart_bulk" => %{"upload_ids" => ids}},
        socket
      ) do
    filters = socket.assigns.direct_multipart_filters

    result =
      DirectMultipartUpload.abort_many_scoped(
        ids,
        socket.assigns.bucket,
        socket.assigns.prefix,
        socket.assigns.current_principal.arn,
        scope: filters.scope,
        query: filters.query
      )

    {:noreply,
     socket
     |> refresh_direct_multipart_state()
     |> put_flash(:info, direct_multipart_bulk_abort_message(result))}
  end

  def handle_event("abort_direct_multipart_uploads", _params, socket) do
    {:noreply, put_flash(socket, :error, "Select at least one direct multipart upload")}
  end

  @impl true
  def handle_event("create_prefix_post_object_form", %{"post_policy" => params}, socket) do
    with {:ok,
          %{
            expires: expires,
            max_size: max_size,
            success_action_status: success_status,
            fields: fields
          }} <- ConsolePostObjectForm.parse(params),
         {:ok, form, endpoint_source} <-
           create_prefix_post_object_form(socket, expires, max_size, success_status, fields) do
      {:noreply,
       socket
       |> assign(
         :post_policy_form,
         ConsolePostObjectForm.form(params,
           expires_in: expires,
           max_size: max_size,
           success_action_status: success_status
         )
       )
       |> assign(:post_object_html, ConsolePostObjectForm.html(form))
       |> put_flash(:info, post_object_form_success_message(endpoint_source))}
    else
      {:error, reason} ->
        {:noreply,
         socket
         |> assign(:post_policy_form, ConsolePostObjectForm.form(params))
         |> assign(:post_object_html, nil)
         |> put_flash(:error, ConsolePostObjectForm.error_message(reason))}
    end
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

  defp direct_multipart_filters(params) do
    scope = DirectMultipartUpload.normalize_scope(Map.get(params, "mpu_scope"), "folder")
    state = direct_multipart_state(Map.get(params, "mpu_state"))
    query = DirectMultipartUpload.normalize_search_query(Map.get(params, "mpu_q")) || ""
    limit = direct_multipart_limit(Map.get(params, "mpu_limit"))

    %{scope: scope, state: state, query: query, limit: limit}
  end

  defp direct_multipart_filters_from_form(params) do
    direct_multipart_filters(%{
      "mpu_scope" => Map.get(params, "scope"),
      "mpu_state" => Map.get(params, "state"),
      "mpu_q" => Map.get(params, "query"),
      "mpu_limit" => Map.get(params, "limit")
    })
  end

  defp direct_multipart_filter_form_data(filters) do
    %{
      "scope" => filters.scope,
      "state" => filters.state,
      "query" => filters.query || "",
      "limit" => Integer.to_string(filters.limit)
    }
  end

  defp direct_multipart_patch_path(socket, filters) do
    query = direct_multipart_query_params(socket.assigns.prefix, filters)
    ~p"/buckets/#{socket.assigns.bucket}/browse?#{query}"
  end

  defp direct_multipart_history_export_path(bucket, prefix, filters) do
    query = direct_multipart_query_params(prefix, filters)
    ~p"/buckets/#{bucket}/direct-multipart/history.csv?#{query}"
  end

  defp direct_multipart_query_params(prefix, filters) do
    %{
      "mpu_scope" => filters.scope,
      "mpu_state" => filters.state,
      "mpu_limit" => Integer.to_string(filters.limit)
    }
    |> maybe_put_query("prefix", prefix)
    |> maybe_put_query("mpu_q", filters.query)
  end

  defp maybe_put_query(query, _key, value) when value in [nil, ""], do: query
  defp maybe_put_query(query, key, value), do: Map.put(query, key, value)

  defp direct_multipart_state(value) do
    case DirectMultipartUpload.normalize_terminal_state(value) do
      nil -> "all"
      state -> state
    end
  end

  defp direct_multipart_terminal_state(%{state: "all"}), do: nil
  defp direct_multipart_terminal_state(%{state: state}), do: state

  defp direct_multipart_limit(value) when is_integer(value) and value in [25, 50, 100, 200],
    do: value

  defp direct_multipart_limit(value) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} -> direct_multipart_limit(integer)
      _other -> 50
    end
  end

  defp direct_multipart_limit(_value), do: 50

  defp direct_multipart_scope_options do
    [
      {"Current folder", "folder"},
      {"Prefix subtree", "recursive"},
      {"Whole bucket", "bucket"}
    ]
  end

  defp direct_multipart_state_options do
    [
      {"All states", "all"},
      {"Completed", "completed"},
      {"Aborted", "aborted"}
    ]
  end

  defp direct_multipart_limit_options do
    [{"25", "25"}, {"50", "50"}, {"100", "100"}, {"200", "200"}]
  end

  defp direct_multipart_scope_label("folder"), do: "Current folder"
  defp direct_multipart_scope_label("recursive"), do: "Prefix subtree"
  defp direct_multipart_scope_label("bucket"), do: "Whole bucket"
  defp direct_multipart_scope_label(_scope), do: "Current folder"

  defp direct_multipart_cors_ready?(_bucket, nil), do: false

  defp direct_multipart_cors_ready?(bucket, origin) do
    DirectMultipartCors.configured?(bucket, origin)
  end

  defp refresh_direct_multipart_cors(socket) do
    assign(
      socket,
      :direct_multipart_cors_ready?,
      direct_multipart_cors_ready?(socket.assigns.bucket, socket.assigns.console_origin)
    )
  end

  defp console_origin(uri) when is_binary(uri) do
    case URI.parse(uri) do
      %URI{scheme: scheme, host: host, port: port}
      when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        scheme <> "://" <> console_origin_host(host) <> console_origin_port(scheme, port)

      _other ->
        nil
    end
  end

  defp console_origin(_uri), do: nil

  defp console_origin_host(host) do
    if String.contains?(host, ":") do
      "[" <> host <> "]"
    else
      host
    end
  end

  defp console_origin_port("http", port) when port in [nil, 80], do: ""
  defp console_origin_port("https", port) when port in [nil, 443], do: ""

  defp console_origin_port(_scheme, port) when is_integer(port),
    do: ":" <> Integer.to_string(port)

  defp console_origin_port(_scheme, _port), do: ""

  defp direct_multipart_cors_success(:updated), do: "Direct upload CORS updated"
  defp direct_multipart_cors_success(:unchanged), do: "Direct upload CORS already ready"

  defp direct_multipart_cors_error(:cors_rule_limit),
    do: "Bucket CORS already has 100 rules; remove or edit one in CORS JSON"

  defp direct_multipart_cors_error(:invalid_origin),
    do: "Console origin is not available for CORS rule generation"

  defp direct_multipart_cors_error(:invalid_cors_configuration),
    do: "Bucket CORS configuration is invalid"

  defp direct_multipart_cors_error(:store_failed), do: "Could not save bucket CORS"
  defp direct_multipart_cors_error(_reason), do: "Could not update direct upload CORS"

  defp list_direct_multipart_uploads(bucket, prefix, socket, filters) do
    if filters.state == "all" do
      DirectMultipartUpload.list_active(
        bucket,
        prefix,
        socket.assigns.current_principal.arn,
        scope: filters.scope,
        query: filters.query
      )
    else
      []
    end
  end

  defp list_direct_multipart_history(bucket, prefix, socket, filters) do
    DirectMultipartUpload.list_history(
      bucket,
      prefix,
      socket.assigns.current_principal.arn,
      scope: filters.scope,
      terminal_state: direct_multipart_terminal_state(filters),
      query: filters.query,
      limit: filters.limit
    )
  end

  defp refresh_direct_multipart_uploads(socket) do
    filters = socket.assigns.direct_multipart_filters

    assign(
      socket,
      :direct_multipart_uploads,
      list_direct_multipart_uploads(socket.assigns.bucket, socket.assigns.prefix, socket, filters)
    )
  end

  defp refresh_direct_multipart_history(socket) do
    filters = socket.assigns.direct_multipart_filters

    assign(
      socket,
      :direct_multipart_history,
      list_direct_multipart_history(socket.assigns.bucket, socket.assigns.prefix, socket, filters)
    )
  end

  defp refresh_direct_multipart_state(socket) do
    socket
    |> refresh_direct_multipart_uploads()
    |> refresh_direct_multipart_history()
  end

  defp refresh_object_listing(socket) do
    %{bucket: bucket, prefix: prefix} = socket.assigns

    %{objects: objects, common_prefixes: prefixes} =
      Objects.list_objects_v2(bucket, %{prefix: prefix, delimiter: "/", max_keys: 1000})

    socket
    |> assign(:prefixes, prefixes)
    |> assign(:object_count, length(objects))
    |> stream(:objects, objects, reset: true)
  end

  defp direct_multipart_history_badge_class("completed"),
    do: "badge badge-success badge-sm"

  defp direct_multipart_history_badge_class("aborted"),
    do: "badge badge-warning badge-sm"

  defp direct_multipart_history_badge_class(_state),
    do: "badge badge-ghost badge-sm"

  defp direct_multipart_bulk_abort_message(%{
         aborted: aborted,
         not_found: not_found,
         failed: failed,
         skipped: skipped
       }) do
    details =
      [
        aborted > 0 && "#{aborted} aborted",
        not_found > 0 && "#{not_found} already gone",
        failed > 0 && "#{failed} failed",
        skipped > 0 && "#{skipped} skipped"
      ]
      |> Enum.filter(& &1)
      |> Enum.join(", ")

    if details == "", do: "No direct multipart uploads were aborted", else: details
  end

  defp error_to_string(:too_large), do: "文件超出大小上限（5 TiB）"
  defp error_to_string(:too_many_files), do: "选择的文件过多（最多 5 个）"
  defp error_to_string(:not_accepted), do: "不接受的文件类型"
  defp error_to_string(other), do: "上传错误: #{inspect(other)}"

  defp create_prefix_post_object_form(socket, expires, max_size, success_status, fields) do
    principal = socket.assigns.current_principal
    access_key = presign_access_key(principal)
    {base_url, endpoint_source} = s3_public_base_url()
    prefix = socket.assigns.prefix || ""
    form_key = prefix <> "${filename}"

    with {:ok, %{secret_key: secret_key}} <-
           CredentialStore.get_secret(access_key, credential_secret_opts(principal)),
         {:ok, form} <-
           PostPolicy.build_form(
             base_url,
             socket.assigns.bucket,
             {:starts_with, prefix, form_key},
             presign_credentials(access_key, secret_key, principal),
             expires: expires,
             max_size: max_size,
             success_action_status: success_status,
             fields: fields
           ) do
      Log.info(
        "console prefix post object form generated",
        action: :console_prefix_post_object_form,
        bucket: socket.assigns.bucket,
        key: form_key,
        principal_arn: principal.arn,
        expires: expires,
        endpoint_source: endpoint_source,
        size: max_size,
        post_fields: Enum.map(fields, &elem(&1, 0))
      )

      {:ok, form, endpoint_source}
    else
      {:error, :invalid_base_url} = error ->
        log_prefix_post_object_form_failure(
          socket,
          form_key,
          expires,
          max_size,
          endpoint_source,
          error
        )

        {:error, :invalid_public_url}

      error ->
        log_prefix_post_object_form_failure(
          socket,
          form_key,
          expires,
          max_size,
          endpoint_source,
          error
        )

        case error do
          :error -> {:error, :credential_unavailable}
          {:error, reason} -> {:error, reason}
          _other -> {:error, :credential_unavailable}
        end
    end
  end

  defp log_prefix_post_object_form_failure(
         socket,
         form_key,
         expires,
         max_size,
         endpoint_source,
         error
       ) do
    principal = socket.assigns.current_principal

    Log.warn(
      "console prefix post object form generation failed",
      action: :console_prefix_post_object_form,
      bucket: socket.assigns.bucket,
      key: form_key,
      principal_arn: principal.arn,
      expires: expires,
      endpoint_source: endpoint_source,
      size: max_size,
      reason: post_object_form_failure_reason(error)
    )
  end

  defp post_object_form_failure_reason({:error, :invalid_base_url}), do: :invalid_public_url
  defp post_object_form_failure_reason({:error, reason}) when is_atom(reason), do: reason
  defp post_object_form_failure_reason(:error), do: :credential_unavailable
  defp post_object_form_failure_reason(_error), do: :unexpected_error

  defp post_object_form_success_message(:derived) do
    "POST Object form generated; using derived local S3 Endpoint."
  end

  defp post_object_form_success_message(_endpoint_source), do: "POST Object form generated"

  defp presign_access_key(principal) do
    Map.get(principal, :session_access_key) || Map.fetch!(principal, :access_key)
  end

  defp credential_secret_opts(principal) do
    case principal_session_token(principal) do
      nil -> []
      token -> [session_token: token]
    end
  end

  defp presign_credentials(access_key, secret_key, principal) do
    credentials = %{access_key: access_key, secret_key: secret_key}

    case principal_session_token(principal) do
      nil -> credentials
      token -> Map.put(credentials, :session_token, token)
    end
  end

  defp principal_session_token(principal) do
    case Map.get(principal, :session_token) || Map.get(principal, "session_token") do
      token when is_binary(token) and token != "" -> token
      _other -> nil
    end
  end

  defp s3_public_base_url do
    console_config = Application.get_env(:maxio, :console, [])
    s3_config = Application.get_env(:maxio, :s3, [])

    cond do
      public_url?(Keyword.get(console_config, :s3_public_url)) ->
        {String.trim_trailing(Keyword.fetch!(console_config, :s3_public_url), "/"),
         :console_s3_public_url}

      public_url?(Keyword.get(s3_config, :public_url)) ->
        {String.trim_trailing(Keyword.fetch!(s3_config, :public_url), "/"), :s3_public_url}

      true ->
        scheme = Keyword.get(s3_config, :scheme, "http")
        host = Keyword.get(s3_config, :domain, "localhost")
        endpoint = Application.get_env(:maxio, Maxio.S3.Endpoint, [])
        port = Keyword.get(endpoint, :port, 9000)
        {scheme <> "://" <> host <> port_suffix(scheme, port), :derived}
    end
  end

  defp public_url?(url), do: is_binary(url) and url != ""

  defp port_suffix("http", 80), do: ""
  defp port_suffix("https", 443), do: ""
  defp port_suffix(_scheme, nil), do: ""
  defp port_suffix(_scheme, port), do: ":" <> to_string(port)
end
