defmodule MaxioWeb.ObjectLive.Show do
  @moduledoc """
  Object Detail（M5-6）：对象详情元数据（size/etag/content-type/storage-class/version_id/
  修改时间）+ 标签编辑（raw 文本 ↔ `[{k,v}]`，经 `Maxio.Tags.validate(_, :object)` 校验，
  `:invalid_tag` 显式 flash，绝不静默放行，铁律 3）+ 版本历史（`Objects.list_object_versions/2`，
  含 delete marker badge，per-version 流式下载经 `DownloadController` + 永久删除经
  `Objects.delete_version/3` + `Storage.delete/4`，删后 `stream(reset: true)` 重取以反映 promote_latest）。
  不存在的桶/对象 → `push_navigate` 回 browse（flash 不静默）。路由 `live "/buckets/:bucket/object/*key"`
  已在 M5-5 注册，本单元只「完整替换」占位实现，勿重复添加路由。
  """
  use MaxioWeb, :live_view

  alias Maxio.Auth.CredentialStore
  alias Maxio.Auth.SigV4.{PostPolicy, Presigner}
  alias Maxio.{Buckets, ObjectLockMetadata, Objects, Storage, Tags}
  alias Maxio.Cluster.Placement
  alias Maxio.S3.Log
  alias Maxio.S3.ObjectLock, as: S3ObjectLock
  alias Maxio.Versioning.VersionId
  alias MaxioWeb.ConsolePostObjectForm
  alias MaxioWeb.ObjectPreview

  @console_presign_max_expires 43_200
  @presign_response_header_fields [
    {"response_cache_control", "response-cache-control"},
    {"response_content_disposition", "response-content-disposition"},
    {"response_content_encoding", "response-content-encoding"},
    {"response_content_language", "response-content-language"},
    {"response_content_type", "response-content-type"},
    {"response_expires", "response-expires"}
  ]
  @presign_method_options [{"GET", "GET"}, {"PUT", "PUT"}]

  @impl true
  def mount(%{"bucket" => bucket, "key" => key_segments}, _session, socket) do
    key = Enum.join(key_segments, "/")

    with {:ok, b} <- Buckets.lookup(bucket),
         {:ok, obj} <- Objects.get_metadata(bucket, key) do
      versions = versions_for(bucket, key)
      object_lock_target = initial_object_lock_target(obj, versions)

      {:ok,
       socket
       |> assign(:bucket, bucket)
       |> assign(:versioning, b.versioning)
       |> assign(:key, key)
       |> assign_current_object(obj)
       |> assign(:object_lock_enabled?, ObjectLockMetadata.enabled_for_bucket?(b))
       |> assign(:page_title, key)
       |> assign(:console_presign_max_expires, @console_presign_max_expires)
       |> assign(:presign_method_options, @presign_method_options)
       |> assign(:presign_form, presign_form())
       |> assign(:presign_method, "GET")
       |> assign(:presigned_url, nil)
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
       |> assign_presign_versions(versions)
       |> assign_object_lock_forms(object_lock_target)
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
          <.link href={download_path(@bucket, @key, @object)} class="btn btn-primary btn-sm">
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
          <.form
            :if={@current_object_editable?}
            for={@tag_form}
            id="tags-form"
            phx-submit="save_tags"
            class="space-y-2"
          >
            <.input
              field={@tag_form[:raw]}
              type="textarea"
              rows="6"
              placeholder="env=prod&#10;team=storage"
            />
            <.button variant="primary" id="tags-submit" type="submit">保存标签</.button>
          </.form>
          <p
            :if={!@current_object_editable?}
            id="tags-unavailable"
            class="text-sm text-base-content/60"
          >
            Delete marker 不支持编辑标签。
          </p>
        </div>

        <div
          id="object-preview-panel"
          class="rounded-box bg-base-100 border border-base-300 p-4 space-y-3 lg:col-span-2"
        >
          <div class="flex flex-col gap-2 sm:flex-row sm:items-center sm:justify-between">
            <div>
              <h2 class="font-semibold text-sm text-base-content/70">Preview</h2>
              <p class="text-xs text-base-content/60">
                {@preview.content_type} - {preview_size_label(@object.size, @preview.max_bytes)}
              </p>
            </div>
            <span
              id="object-preview-state"
              class={[
                "badge badge-sm",
                @preview.mode in [:image, :frame] && "badge-success",
                @preview.mode == :unsupported && "badge-ghost"
              ]}
            >
              {preview_state_label(@preview)}
            </span>
          </div>

          <img
            :if={@preview.mode == :image}
            id="object-preview-image"
            src={preview_path(@bucket, @key, @object)}
            alt={@object.key}
            class="max-h-96 w-full rounded-box border border-base-300 bg-base-200 object-contain"
          />

          <iframe
            :if={@preview.mode == :frame}
            id="object-preview-frame"
            src={preview_path(@bucket, @key, @object)}
            sandbox=""
            referrerpolicy="no-referrer"
            loading="lazy"
            class="h-96 w-full rounded-box border border-base-300 bg-base-200"
          >
          </iframe>

          <div
            :if={@preview.mode == :unsupported}
            id="object-preview-unavailable"
            class="rounded-box border border-dashed border-base-300 p-6 text-sm text-base-content/60"
          >
            This object type is available for download only.
            <.link
              id="object-preview-download"
              href={download_path(@bucket, @key, @object)}
              class="btn btn-ghost btn-sm ml-2"
            >
              <.icon name="hero-arrow-down-tray" class="size-4" /> Download
            </.link>
          </div>
        </div>

        <div
          id="object-lock-panel"
          class="rounded-box bg-base-100 border border-base-300 p-4 lg:col-span-2"
        >
          <div class="flex flex-col gap-2 sm:flex-row sm:items-center sm:justify-between">
            <div>
              <h2 class="font-semibold text-sm text-base-content/70">Object Lock</h2>
              <p :if={@object_lock_target} class="text-xs text-base-content/60">
                编辑版本：<span id="object-lock-target-version" class="font-mono">
                  {@object_lock_target.version_id}
                </span>
                <span :if={@object_lock_target.is_latest} class="badge badge-xs ml-1">latest</span>
              </p>
              <p :if={!@object_lock_target} class="text-xs text-base-content/60">
                <span id="object-lock-target-version">无可编辑对象版本</span>
              </p>
            </div>
            <span
              id="object-lock-state"
              class={[
                "badge badge-sm",
                @object_lock_enabled? && "badge-success",
                !@object_lock_enabled? && "badge-ghost"
              ]}
            >
              {if @object_lock_enabled?, do: "Enabled", else: "Disabled"}
            </span>
          </div>

          <div
            :if={!@object_lock_enabled?}
            id="object-lock-disabled"
            class="mt-4 text-sm text-base-content/60"
          >
            当前 bucket 未启用 Object Lock，不能编辑对象级 Legal Hold 或 Retention。
          </div>

          <div
            :if={@object_lock_enabled? && !@object_lock_target}
            id="object-lock-no-target"
            class="mt-4 text-sm text-base-content/60"
          >
            当前对象只有 delete marker 版本，不能编辑对象级 Legal Hold 或 Retention。
          </div>

          <div
            :if={@object_lock_enabled? && @object_lock_target}
            class="mt-4 grid md:grid-cols-2 gap-4"
          >
            <div id="legal-hold-card" class="rounded-box border border-base-300 p-3">
              <div class="mb-3 text-sm">
                <span class="text-base-content/60">Legal Hold</span>
                <span id="legal-hold-current" class="ml-2 font-mono">
                  {@object_lock_target.object_lock_legal_hold || "OFF"}
                </span>
              </div>
              <.form
                for={@legal_hold_form}
                id="legal-hold-form"
                phx-submit="save_legal_hold"
                class="space-y-2"
              >
                <.input field={@legal_hold_form[:version_id]} type="hidden" />
                <.input
                  field={@legal_hold_form[:status]}
                  type="select"
                  label="Status"
                  options={legal_hold_options()}
                />
                <.button variant="primary" id="legal-hold-submit" type="submit">
                  保存 Legal Hold
                </.button>
              </.form>
            </div>

            <div id="retention-card" class="rounded-box border border-base-300 p-3">
              <div class="mb-3 text-sm">
                <span class="text-base-content/60">Retention</span>
                <span id="retention-current" class="ml-2 font-mono">
                  {retention_summary(@object_lock_target)}
                </span>
              </div>
              <.form
                for={@retention_form}
                id="retention-form"
                phx-submit="save_retention"
                data-confirm="确认修改对象 Retention？COMPLIANCE 模式在到期前不可解除或缩短。"
                class="space-y-2"
              >
                <.input field={@retention_form[:version_id]} type="hidden" />
                <.input
                  field={@retention_form[:mode]}
                  type="select"
                  label="Mode"
                  prompt="选择模式"
                  options={retention_mode_options()}
                />
                <.input
                  field={@retention_form[:retain_until]}
                  type="text"
                  label="Retain Until (UTC)"
                  placeholder="2035-01-01T00:00:00Z"
                />
                <p id="retention-warning" class="text-xs text-warning">
                  COMPLIANCE 模式在到期前不可解除或缩短；Console 不提供 governance bypass。
                </p>
                <.button
                  variant="primary"
                  id="retention-submit"
                  type="submit"
                >
                  保存 Retention
                </.button>
              </.form>
              <.form
                :if={retention_configured?(@object_lock_target)}
                for={@retention_clear_form}
                id="retention-clear-form"
                phx-submit="clear_retention"
                data-confirm="确认清除当前对象版本的 Retention？有效保留期内仍会被拒绝。"
                class="mt-3"
              >
                <.input field={@retention_clear_form[:version_id]} type="hidden" />
                <.button
                  id="retention-clear-submit"
                  type="submit"
                  class="btn btn-warning btn-soft btn-sm"
                >
                  <.icon name="hero-trash" class="size-4" /> 清除 Retention
                </.button>
              </.form>
            </div>
          </div>
        </div>
      </div>

      <div
        id="presign-panel"
        class="mt-6 rounded-box bg-base-100 border border-base-300 p-4 space-y-3"
      >
        <div>
          <h2 class="font-semibold text-sm text-base-content/70">预签名分享 URL</h2>
          <p class="text-xs text-base-content/60">
            生成指向 S3 Endpoint 的 GET/PUT URL；权限与当前 access key 相同，最长 12 小时。
          </p>
        </div>
        <.form
          for={@presign_form}
          id="presign-form"
          phx-change="change_presigned_url_method"
          phx-submit="create_presigned_url"
          class="grid gap-3 md:grid-cols-2 xl:grid-cols-6"
        >
          <div>
            <.input
              field={@presign_form[:method]}
              type="select"
              label="Method"
              options={@presign_method_options}
            />
          </div>
          <div>
            <.input
              field={@presign_form[:expires_in]}
              type="number"
              label="有效期（秒）"
              min="1"
              max={@console_presign_max_expires}
            />
          </div>
          <div :if={@presign_method == "GET"} class="xl:col-span-2">
            <.input
              field={@presign_form[:version_id]}
              type="select"
              label="版本"
              options={@presign_version_options}
            />
          </div>
          <div :if={@presign_method == "GET"}>
            <.input
              field={@presign_form[:response_content_type]}
              type="text"
              label="Content-Type"
              placeholder={@object.content_type}
            />
          </div>
          <div :if={@presign_method == "GET"}>
            <.input
              field={@presign_form[:response_content_disposition]}
              type="text"
              label="Content-Disposition"
              placeholder="attachment; filename=&quot;object.bin&quot;"
            />
          </div>
          <div :if={@presign_method == "GET"}>
            <.input
              field={@presign_form[:response_cache_control]}
              type="text"
              label="Cache-Control"
              placeholder="max-age=3600"
            />
          </div>
          <div :if={@presign_method == "GET"}>
            <.input
              field={@presign_form[:response_content_language]}
              type="text"
              label="Content-Language"
              placeholder="zh-CN"
            />
          </div>
          <div :if={@presign_method == "GET"}>
            <.input
              field={@presign_form[:response_content_encoding]}
              type="text"
              label="Content-Encoding"
              placeholder="identity"
            />
          </div>
          <div :if={@presign_method == "GET"} class="xl:col-span-2">
            <.input
              field={@presign_form[:response_expires]}
              type="text"
              label="Expires"
              placeholder="Wed, 21 Oct 2037 07:28:00 GMT"
            />
          </div>
          <.button variant="primary" id="presign-submit" type="submit" class="self-end">
            <.icon name="hero-link" class="size-4" /> 生成
          </.button>
        </.form>
        <textarea
          :if={@presigned_url}
          id="presign-url"
          readonly
          class="textarea textarea-bordered w-full font-mono text-xs"
          rows="4"
        >{@presigned_url}</textarea>
      </div>

      <div
        id="post-object-panel"
        class="mt-6 rounded-box bg-base-100 border border-base-300 p-4 space-y-3"
      >
        <div>
          <h2 class="font-semibold text-sm text-base-content/70">POST Object form</h2>
        </div>
        <.form
          for={@post_policy_form}
          id="post-object-policy-form"
          phx-submit="create_post_object_form"
          class="grid gap-3 md:grid-cols-2 xl:grid-cols-6"
        >
          <div>
            <.input
              field={@post_policy_form[:expires_in]}
              type="number"
              label="Expires"
              min="1"
              max={@console_presign_max_expires}
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
              placeholder={@object.content_type}
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
          <.button variant="primary" id="post-object-policy-submit" type="submit" class="self-end">
            <.icon name="hero-document-plus" class="size-4" /> Generate
          </.button>
        </.form>
        <textarea
          :if={@post_object_html}
          id="post-object-html"
          readonly
          class="textarea textarea-bordered w-full font-mono text-xs"
          rows="12"
        >{@post_object_html}</textarea>
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
                    :if={@object_lock_enabled? && !v.is_delete_marker}
                    id={"edit-lock-version-#{dom_id}"}
                    phx-click="select_object_lock_version"
                    phx-value-vid={v.version_id}
                    class="btn btn-ghost btn-xs"
                    title="编辑 Object Lock"
                  >
                    <.icon name="hero-lock-closed" class="size-3" />
                  </.button>
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
  def handle_event("change_presigned_url_method", %{"presign" => params}, socket) do
    method = presign_method_value(Map.get(params, "method"))

    {:noreply,
     socket
     |> assign(:presign_method, method)
     |> assign(:presign_form, presign_form(params))
     |> assign(:presigned_url, nil)}
  end

  @impl true
  def handle_event("create_presigned_url", %{"presign" => params}, socket) do
    method_value = presign_method_value(Map.get(params, "method"))
    response_overrides = presign_response_overrides(method_value, params)

    with {:ok, method} <- parse_presign_method(Map.get(params, "method")),
         {:ok, expires} <- parse_presign_expires(Map.get(params, "expires_in")),
         {:ok, version_id} <-
           parse_presign_version_id(method, socket, Map.get(params, "version_id")),
         {:ok, url, endpoint_source} <-
           create_presigned_url(socket, method, expires, version_id, response_overrides) do
      {:noreply,
       socket
       |> assign(:presign_method, Atom.to_string(method) |> String.upcase())
       |> assign(:presign_form, presign_form(params, expires_in: expires, version_id: version_id))
       |> assign(:presigned_url, url)
       |> put_flash(:info, presign_success_message(method, endpoint_source))}
    else
      {:error, :invalid_expires} ->
        {:noreply,
         socket
         |> assign(:presign_method, method_value)
         |> assign(
           :presign_form,
           presign_form(params)
         )
         |> put_flash(:error, "有效期必须是 1 到 #{@console_presign_max_expires} 秒")}

      {:error, :invalid_version_id} ->
        {:noreply,
         socket
         |> assign(:presign_method, method_value)
         |> assign(
           :presign_form,
           presign_form(params)
         )
         |> put_flash(:error, "版本 ID 非法或不属于该对象")}

      {:error, :invalid_method} ->
        {:noreply,
         socket
         |> assign(:presign_method, "GET")
         |> assign(:presign_form, presign_form(params))
         |> put_flash(:error, "预签名 Method 必须是 GET 或 PUT")}

      {:error, :credential_unavailable} ->
        {:noreply, put_flash(socket, :error, "当前凭据不可用于生成预签名 URL")}

      {:error, :invalid_public_url} ->
        {:noreply, put_flash(socket, :error, "S3 public URL 配置非法，无法生成预签名 URL")}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "预签名 URL 生成失败")}
    end
  end

  @impl true
  def handle_event("create_post_object_form", %{"post_policy" => params}, socket) do
    with {:ok,
          %{
            expires: expires,
            max_size: max_size,
            success_action_status: success_status,
            fields: fields
          }} <- ConsolePostObjectForm.parse(params),
         {:ok, form, endpoint_source} <-
           create_post_object_form(socket, expires, max_size, success_status, fields) do
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
  def handle_event(
        "save_tags",
        _params,
        %{assigns: %{current_object_editable?: false}} = socket
      ) do
    {:noreply, put_flash(socket, :error, "当前版本是 delete marker，不能编辑标签")}
  end

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
  def handle_event(
        "select_object_lock_version",
        _params,
        %{assigns: %{object_lock_enabled?: false}} = socket
      ) do
    {:noreply, put_flash(socket, :error, "当前 bucket 未启用 Object Lock")}
  end

  def handle_event("select_object_lock_version", %{"vid" => version_id}, socket) do
    bucket = socket.assigns.bucket
    key = socket.assigns.key

    with :ok <- require_object_lock_enabled(socket),
         {:ok, object} <- fetch_object_lock_target(bucket, key, version_id) do
      {:noreply,
       socket
       |> assign_object_lock_forms(object)
       |> put_flash(:info, "已选择版本 #{version_id}")}
    else
      {:error, reason} ->
        {:noreply, put_flash(socket, :error, object_lock_error_message(reason))}
    end
  end

  @impl true
  def handle_event(
        "save_legal_hold",
        _params,
        %{assigns: %{object_lock_enabled?: false}} = socket
      ) do
    {:noreply, put_flash(socket, :error, "当前 bucket 未启用 Object Lock")}
  end

  def handle_event("save_legal_hold", %{"legal_hold" => params}, socket) do
    bucket = socket.assigns.bucket
    key = socket.assigns.key

    with :ok <- require_object_lock_enabled(socket),
         {:ok, version_id} <- lock_form_version_id(params, socket),
         {:ok, attrs} <- normalize_legal_hold(Map.get(params, "status")),
         {:ok, object} <- ObjectLockMetadata.put_legal_hold(bucket, key, version_id, attrs) do
      {:noreply,
       socket
       |> refresh_object_lock_forms(object)
       |> put_flash(:info, "Legal Hold 已更新")}
    else
      {:error, reason} ->
        {:noreply, put_flash(socket, :error, object_lock_error_message(reason))}
    end
  end

  @impl true
  def handle_event("save_retention", _params, %{assigns: %{object_lock_enabled?: false}} = socket) do
    {:noreply, put_flash(socket, :error, "当前 bucket 未启用 Object Lock")}
  end

  def handle_event("save_retention", %{"retention" => params}, socket) do
    bucket = socket.assigns.bucket
    key = socket.assigns.key

    with :ok <- require_object_lock_enabled(socket),
         {:ok, version_id} <- lock_form_version_id(params, socket),
         {:ok, attrs} <-
           normalize_retention(Map.get(params, "mode"), Map.get(params, "retain_until")),
         {:ok, object} <-
           ObjectLockMetadata.put_retention(bucket, key, version_id, attrs,
             now: DateTime.utc_now(),
             bypass_governance?: false
           ) do
      {:noreply,
       socket
       |> refresh_object_lock_forms(object)
       |> put_flash(:info, "Retention 已更新")}
    else
      {:error, reason} ->
        {:noreply, put_flash(socket, :error, object_lock_error_message(reason))}
    end
  end

  @impl true
  def handle_event(
        "clear_retention",
        _params,
        %{assigns: %{object_lock_enabled?: false}} = socket
      ) do
    {:noreply, put_flash(socket, :error, "当前 bucket 未启用 Object Lock")}
  end

  def handle_event("clear_retention", %{"retention_clear" => params}, socket) do
    bucket = socket.assigns.bucket
    key = socket.assigns.key
    attrs = %{object_lock_mode: nil, object_lock_retain_until: nil}

    with :ok <- require_object_lock_enabled(socket),
         {:ok, version_id} <- lock_form_version_id(params, socket),
         {:ok, object} <-
           ObjectLockMetadata.put_retention(bucket, key, version_id, attrs,
             now: DateTime.utc_now(),
             bypass_governance?: false
           ) do
      {:noreply,
       socket
       |> refresh_object_lock_forms(object)
       |> put_flash(:info, "Retention 已清除")}
    else
      {:error, reason} ->
        {:noreply, put_flash(socket, :error, object_lock_error_message(reason))}
    end
  end

  @impl true
  def handle_event("delete_version", %{"vid" => vid}, socket) do
    bucket = socket.assigns.bucket
    key = socket.assigns.key

    storage_opts = storage_opts_for_version(bucket, key, vid)

    case Objects.delete_version(bucket, key, vid) do
      {:ok, _} ->
        _ = Storage.delete(bucket, key, vid, storage_opts)

        # 重取版本列表（promote_latest 可能改变其他行的 is_latest）+ 重取当前对象元数据。
        versions = versions_for(bucket, key)

        case Objects.get_metadata(bucket, key) do
          {:ok, obj} ->
            {:noreply,
             socket
             |> assign_current_object(obj)
             |> assign_object_lock_forms(initial_object_lock_target(obj, versions))
             |> assign_presign_versions(versions)
             |> stream(:versions, versions, reset: true)
             |> put_flash(:info, "已删除版本 #{vid}")}

          {:error, :not_found} ->
            {:noreply,
             socket
             |> put_flash(:info, "已删除版本 #{vid}")
             |> push_navigate(to: ~p"/buckets/#{bucket}/browse")}
        end

      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, "版本不存在")}
    end
  end

  # ── 辅助 ──

  defp preview_path(bucket, key, object), do: versioned_object_path(bucket, :preview, key, object)

  defp download_path(bucket, key, object),
    do: versioned_object_path(bucket, :download, key, object)

  defp versioned_object_path(bucket, :preview, key, %{version_id: version_id})
       when version_id in [nil, "null"] do
    ~p"/buckets/#{bucket}/preview/#{key}"
  end

  defp versioned_object_path(bucket, :preview, key, %{version_id: version_id}) do
    ~p"/buckets/#{bucket}/preview/#{key}?versionId=#{version_id}"
  end

  defp versioned_object_path(bucket, :download, key, %{version_id: version_id})
       when version_id in [nil, "null"] do
    ~p"/buckets/#{bucket}/download/#{key}"
  end

  defp versioned_object_path(bucket, :download, key, %{version_id: version_id}) do
    ~p"/buckets/#{bucket}/download/#{key}?versionId=#{version_id}"
  end

  defp preview_state_label(%{mode: :image}), do: "Image"
  defp preview_state_label(%{mode: :frame}), do: "Inline"
  defp preview_state_label(%{reason: :too_large}), do: "Too large"
  defp preview_state_label(_preview), do: "Download only"

  defp preview_size_label(size, max_bytes),
    do: "#{format_bytes(size)} / max #{format_bytes(max_bytes)}"

  defp format_bytes(bytes) when is_integer(bytes) and bytes >= 1_048_576 do
    "#{Float.round(bytes / 1_048_576, 1)} MiB"
  end

  defp format_bytes(bytes) when is_integer(bytes) and bytes >= 1024 do
    "#{Float.round(bytes / 1024, 1)} KiB"
  end

  defp format_bytes(bytes) when is_integer(bytes) and bytes >= 0, do: "#{bytes} B"
  defp format_bytes(_bytes), do: "unknown"

  defp initial_object_lock_target(%{is_delete_marker: false} = object, _versions), do: object

  defp initial_object_lock_target(_object, versions) do
    Enum.find(versions, &(not &1.is_delete_marker))
  end

  defp assign_object_lock_forms(socket, object) do
    socket
    |> assign(:object_lock_target, object)
    |> assign(:legal_hold_form, legal_hold_form(object))
    |> assign(:retention_form, retention_form(object))
    |> assign(:retention_clear_form, retention_clear_form(object))
  end

  defp refresh_object_lock_forms(socket, fallback_object) do
    object =
      case Objects.get_metadata(socket.assigns.bucket, socket.assigns.key) do
        {:ok, obj} -> obj
        {:error, :not_found} -> fallback_object
      end

    target =
      case Objects.get_version(
             socket.assigns.bucket,
             socket.assigns.key,
             fallback_object.version_id
           ) do
        {:ok, obj} -> obj
        {:error, :not_found} -> fallback_object
      end

    socket
    |> assign_current_object(object)
    |> assign_object_lock_forms(target)
  end

  defp assign_current_object(socket, object) do
    socket
    |> assign(:object, object)
    |> assign(:preview, ObjectPreview.preview(object))
    |> assign(:current_object_editable?, current_object_editable?(object))
    |> assign(:tag_form, tags_to_form(current_object_tags(object)))
  end

  defp current_object_editable?(%{is_delete_marker: false}), do: true
  defp current_object_editable?(_object), do: false

  defp current_object_tags(%{is_delete_marker: false, tags: tags}),
    do: Tags.map_to_list(tags || %{})

  defp current_object_tags(_object), do: []

  defp fetch_object_lock_target(bucket, key, version_id) when is_binary(version_id) do
    case Objects.get_version(bucket, key, version_id) do
      {:ok, %{is_delete_marker: true}} -> {:error, :not_found}
      {:ok, object} -> {:ok, object}
      {:error, :not_found} -> {:error, :no_such_version}
    end
  end

  defp fetch_object_lock_target(_bucket, _key, _version_id), do: {:error, :no_such_version}

  defp create_presigned_url(socket, method, expires, version_id, response_overrides) do
    principal = socket.assigns.current_principal
    access_key = presign_access_key(principal)
    {base_url, endpoint_source} = s3_public_base_url()

    with {:ok, %{secret_key: secret_key}} <-
           CredentialStore.get_secret(access_key, credential_secret_opts(principal)),
         {:ok, url} <-
           Presigner.presign_url(
             method,
             base_url,
             object_request_path(socket.assigns.bucket, socket.assigns.key),
             presign_credentials(access_key, secret_key, principal),
             expires: expires,
             query: presign_query(method, version_id, response_overrides)
           ) do
      Log.info(
        "console presigned url generated",
        action: presign_log_action(method),
        method: method |> Atom.to_string() |> String.upcase(),
        bucket: socket.assigns.bucket,
        key: socket.assigns.key,
        version_id: version_id || :latest,
        principal_arn: principal.arn,
        expires: expires,
        endpoint_source: endpoint_source
      )

      {:ok, url, endpoint_source}
    else
      {:error, :invalid_base_url} = error ->
        log_presign_failure(socket, method, version_id, expires, endpoint_source, error)
        {:error, :invalid_public_url}

      error ->
        log_presign_failure(socket, method, version_id, expires, endpoint_source, error)
        {:error, :credential_unavailable}
    end
  end

  defp create_post_object_form(socket, expires, max_size, success_status, fields) do
    principal = socket.assigns.current_principal
    access_key = presign_access_key(principal)
    {base_url, endpoint_source} = s3_public_base_url()

    with {:ok, %{secret_key: secret_key}} <-
           CredentialStore.get_secret(access_key, credential_secret_opts(principal)),
         {:ok, form} <-
           PostPolicy.build_form(
             base_url,
             socket.assigns.bucket,
             socket.assigns.key,
             presign_credentials(access_key, secret_key, principal),
             expires: expires,
             max_size: max_size,
             success_action_status: success_status,
             fields: fields
           ) do
      Log.info(
        "console post object form generated",
        action: :console_post_object_form,
        bucket: socket.assigns.bucket,
        key: socket.assigns.key,
        principal_arn: principal.arn,
        expires: expires,
        endpoint_source: endpoint_source,
        size: max_size,
        post_fields: Enum.map(fields, &elem(&1, 0))
      )

      {:ok, form, endpoint_source}
    else
      {:error, :invalid_base_url} = error ->
        log_post_object_form_failure(socket, expires, max_size, endpoint_source, error)
        {:error, :invalid_public_url}

      error ->
        log_post_object_form_failure(socket, expires, max_size, endpoint_source, error)

        case error do
          :error -> {:error, :credential_unavailable}
          {:error, reason} -> {:error, reason}
          _other -> {:error, :credential_unavailable}
        end
    end
  end

  defp log_post_object_form_failure(socket, expires, max_size, endpoint_source, error) do
    principal = socket.assigns.current_principal

    Log.warn(
      "console post object form generation failed",
      action: :console_post_object_form,
      bucket: socket.assigns.bucket,
      key: socket.assigns.key,
      principal_arn: principal.arn,
      expires: expires,
      endpoint_source: endpoint_source,
      size: max_size,
      reason: presign_failure_reason(error)
    )
  end

  defp log_presign_failure(socket, method, version_id, expires, endpoint_source, error) do
    principal = socket.assigns.current_principal

    Log.warn(
      "console presigned url generation failed",
      action: presign_log_action(method),
      method: method |> Atom.to_string() |> String.upcase(),
      bucket: socket.assigns.bucket,
      key: socket.assigns.key,
      version_id: version_id || :latest,
      principal_arn: principal.arn,
      expires: expires,
      endpoint_source: endpoint_source,
      reason: presign_failure_reason(error)
    )
  end

  defp presign_failure_reason({:error, :invalid_base_url}), do: :invalid_public_url
  defp presign_failure_reason({:error, reason}) when is_atom(reason), do: reason
  defp presign_failure_reason(:error), do: :credential_unavailable
  defp presign_failure_reason(_error), do: :unexpected_error

  defp presign_success_message(method, :derived) do
    method = method |> Atom.to_string() |> String.upcase()

    "预签名 #{method} URL 已生成；未配置 S3 public URL，已使用本机 S3 Endpoint 派生地址。"
  end

  defp presign_success_message(method, _endpoint_source) do
    method = method |> Atom.to_string() |> String.upcase()
    "预签名 #{method} URL 已生成"
  end

  defp post_object_form_success_message(:derived) do
    "POST Object form generated; using derived local S3 Endpoint."
  end

  defp post_object_form_success_message(_endpoint_source), do: "POST Object form generated"

  defp presign_log_action(:get), do: :console_presign_get
  defp presign_log_action(:put), do: :console_presign_put

  defp object_request_path(bucket, key), do: "/" <> bucket <> "/" <> key

  defp presign_query(:put, _version_id, _response_overrides), do: %{}
  defp presign_query(:get, nil, response_overrides), do: response_overrides

  defp presign_query(:get, version_id, response_overrides),
    do: Map.put(response_overrides, "versionId", version_id)

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

  defp parse_presign_expires(value) do
    case Integer.parse(to_string(value || "")) do
      {integer, ""} when integer in 1..@console_presign_max_expires -> {:ok, integer}
      _other -> {:error, :invalid_expires}
    end
  end

  defp parse_presign_method("GET"), do: {:ok, :get}
  defp parse_presign_method("PUT"), do: {:ok, :put}
  defp parse_presign_method(nil), do: {:ok, :get}
  defp parse_presign_method(_method), do: {:error, :invalid_method}

  defp presign_method_value("PUT"), do: "PUT"
  defp presign_method_value(_method), do: "GET"

  defp parse_presign_version_id(:put, _socket, _value), do: {:ok, nil}
  defp parse_presign_version_id(:get, _socket, value) when value in [nil, ""], do: {:ok, nil}

  defp parse_presign_version_id(:get, socket, value) do
    version_id = to_string(value)

    cond do
      not VersionId.valid?(version_id) ->
        {:error, :invalid_version_id}

      MapSet.member?(socket.assigns.presign_version_ids, version_id) ->
        {:ok, version_id}

      true ->
        {:error, :invalid_version_id}
    end
  end

  defp presign_response_overrides("PUT", _params), do: %{}

  defp presign_response_overrides(_method, params) do
    Enum.reduce(@presign_response_header_fields, %{}, fn {form_field, query_param}, acc ->
      case params |> Map.get(form_field) |> normalize_presign_response_override() do
        "" -> acc
        value -> Map.put(acc, query_param, value)
      end
    end)
  end

  defp normalize_presign_response_override(nil), do: ""
  defp normalize_presign_response_override(value), do: value |> to_string() |> String.trim()

  defp presign_form(params \\ %{}, opts \\ []) do
    expires_in = Keyword.get(opts, :expires_in, Map.get(params, "expires_in", 3_600))
    version_id = Keyword.get(opts, :version_id, Map.get(params, "version_id", ""))
    method = presign_method_value(Map.get(params, "method"))

    to_form(
      response_header_form_params(params)
      |> Map.merge(%{
        "method" => method,
        "expires_in" => to_string(expires_in),
        "version_id" => to_string(version_id || "")
      }),
      as: :presign
    )
  end

  defp response_header_form_params(params) do
    Map.new(@presign_response_header_fields, fn {form_field, _query_param} ->
      {form_field, normalize_presign_response_override(Map.get(params, form_field))}
    end)
  end

  defp assign_presign_versions(socket, versions) do
    non_delete_versions = Enum.reject(versions, & &1.is_delete_marker)

    socket
    |> assign(:presign_version_options, presign_version_options(non_delete_versions))
    |> assign(:presign_version_ids, MapSet.new(non_delete_versions, & &1.version_id))
  end

  defp presign_version_options(versions) do
    [{"当前版本 (latest)", ""}] ++
      Enum.map(versions, fn version ->
        suffix = if version.is_latest, do: " latest", else: ""
        {"#{version.version_id}#{suffix}", version.version_id}
      end)
  end

  defp legal_hold_form(object) do
    to_form(
      %{
        "version_id" => object_version_id(object),
        "status" => object_legal_hold(object) || "OFF"
      },
      as: :legal_hold
    )
  end

  defp retention_form(object) do
    to_form(
      %{
        "version_id" => object_version_id(object),
        "mode" => object_lock_mode(object) || "",
        "retain_until" => datetime_to_iso8601(object_retain_until(object))
      },
      as: :retention
    )
  end

  defp retention_clear_form(object) do
    to_form(%{"version_id" => object_version_id(object)}, as: :retention_clear)
  end

  defp retention_configured?(nil), do: false

  defp retention_configured?(object) do
    not is_nil(object.object_lock_mode) or not is_nil(object.object_lock_retain_until)
  end

  defp lock_form_version_id(params, socket) do
    with {:ok, target_version_id} <- object_lock_target_version_id(socket) do
      case Map.get(params, "version_id") do
        nil -> {:ok, target_version_id}
        "" -> {:ok, target_version_id}
        ^target_version_id -> {:ok, target_version_id}
        _submitted_version_id -> {:error, :stale_object_lock_target}
      end
    end
  end

  defp object_lock_target_version_id(socket) do
    case socket.assigns do
      %{object_lock_target: %{version_id: version_id}} when is_binary(version_id) ->
        {:ok, version_id}

      _assigns ->
        {:error, :no_object_lock_target}
    end
  end

  defp object_version_id(nil), do: ""
  defp object_version_id(%{version_id: version_id}), do: version_id

  defp object_legal_hold(nil), do: nil
  defp object_legal_hold(%{object_lock_legal_hold: legal_hold}), do: legal_hold

  defp object_lock_mode(nil), do: nil
  defp object_lock_mode(%{object_lock_mode: mode}), do: mode

  defp object_retain_until(nil), do: nil
  defp object_retain_until(%{object_lock_retain_until: retain_until}), do: retain_until

  defp require_object_lock_enabled(socket) do
    case Buckets.lookup(socket.assigns.bucket) do
      {:ok, bucket} ->
        if ObjectLockMetadata.enabled_for_bucket?(bucket),
          do: :ok,
          else: {:error, :invalid_bucket_state}

      {:error, :not_found} ->
        {:error, :invalid_bucket_state}
    end
  end

  defp normalize_legal_hold(status) do
    {:ok, S3ObjectLock.normalize_object_legal_hold(%{"Status" => status})}
  rescue
    _error in Maxio.S3.Error -> {:error, :invalid_legal_hold}
  end

  defp normalize_retention(mode, retain_until) do
    {:ok,
     S3ObjectLock.normalize_object_retention(%{
       "Mode" => mode,
       "RetainUntilDate" => retain_until
     })}
  rescue
    _error in Maxio.S3.Error -> {:error, :invalid_retention}
  end

  defp object_lock_error_message(:invalid_legal_hold),
    do: "Legal Hold 状态必须是 ON 或 OFF"

  defp object_lock_error_message(:invalid_retention),
    do: "Retention 需要 GOVERNANCE/COMPLIANCE 模式和 ISO8601 UTC 时间"

  defp object_lock_error_message(:invalid_bucket_state),
    do: "当前 bucket 未启用 Object Lock"

  defp object_lock_error_message(:locked),
    do: "对象当前处于 Legal Hold 或有效保留期内，Console 不允许修改 Retention"

  defp object_lock_error_message(:lock_timeout), do: "对象正在被其他请求修改，请稍后重试"
  defp object_lock_error_message(:no_such_version), do: "对象版本不存在"
  defp object_lock_error_message(:not_found), do: "对象不存在"
  defp object_lock_error_message(:no_object_lock_target), do: "没有可编辑的对象版本"
  defp object_lock_error_message(:stale_object_lock_target), do: "对象锁编辑版本已变化，请重新提交"
  defp object_lock_error_message(:slow_down_read), do: "对象锁元数据读取 quorum 不足，请稍后重试"
  defp object_lock_error_message(:slow_down_write), do: "对象锁元数据写入 quorum 不足，请稍后重试"
  defp object_lock_error_message(:invalid_key), do: "对象 key 非法"

  defp legal_hold_options, do: [{"OFF", "OFF"}, {"ON", "ON"}]
  defp retention_mode_options, do: [{"GOVERNANCE", "GOVERNANCE"}, {"COMPLIANCE", "COMPLIANCE"}]

  defp retention_summary(nil), do: "无可编辑版本"
  defp retention_summary(%{object_lock_mode: nil}), do: "未设置"
  defp retention_summary(%{object_lock_mode: mode, object_lock_retain_until: nil}), do: mode

  defp retention_summary(%{object_lock_mode: mode, object_lock_retain_until: retain_until}) do
    "#{mode} until #{datetime_to_iso8601(retain_until)}"
  end

  defp datetime_to_iso8601(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp datetime_to_iso8601(_dt), do: ""

  defp storage_opts_for_version(bucket, key, version_id) do
    case Objects.get_version(bucket, key, version_id) do
      {:ok, obj} -> Placement.storage_opts(obj)
      {:error, :not_found} -> []
    end
  end

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
