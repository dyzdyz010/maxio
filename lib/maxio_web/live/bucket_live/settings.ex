defmodule MaxioWeb.BucketLive.Settings do
  @moduledoc """
  Bucket Settings tabbed 编辑器（M5-7）：单个 LiveView 经 `?tab=` query + `push_patch`
  在 12 个 tab 间切换——versioning / policy(JSON) / acl(canned) / tags / cors(JSON) /
  lifecycle(JSON，CLI/后台 scheduler 执行支持动作，Transition 做 storage_class 元数据迁移) /
  encryption(SSE-S3，KMS 拒绝) / public_access_block / quota / object_lock(default retention) /
  replication(JSON control-plane) / notification(JSON)。全部复用 M2–M4 context
  （`Maxio.Buckets` / `Maxio.BucketConfigs` / `Maxio.Tags` / `Maxio.Policy.{Store,Statement}`）
  + 其内置校验；所有 context 错误显式 flash 呈现，绝不静默吞掉（铁律 3）。
  """
  use MaxioWeb, :live_view

  alias Maxio.{BucketQuota, Buckets, BucketConfigs, KMS, Tags}
  alias Maxio.Policy.{Store, Statement}
  alias Maxio.S3.Error, as: S3Error
  alias Maxio.S3.{Notification, NotificationDestinationValidator, ObjectLock, Replication}
  alias Maxio.S3.Handlers.{Cors, Lifecycle}
  alias Maxio.S3.PublicAccessBlock

  @tabs ~w(versioning policy acl tags cors lifecycle encryption public_access_block quota object_lock replication notification)
  @canned ~w(private public-read public-read-write authenticated-read)

  @impl true
  def mount(%{"bucket" => bucket}, _session, socket) do
    case Buckets.lookup(bucket) do
      {:ok, b} ->
        {:ok,
         socket
         |> assign(:bucket, bucket)
         |> assign(:bucket_struct, b)
         |> assign(:page_title, "#{bucket} · 设置")
         |> load_forms(b)}

      {:error, :not_found} ->
        {:ok, socket |> put_flash(:error, "桶不存在") |> push_navigate(to: ~p"/buckets")}
    end
  end

  @impl true
  def handle_params(params, _uri, socket) do
    tab = Map.get(params, "tab", "versioning")
    tab = if tab in @tabs, do: tab, else: "versioning"
    {:noreply, assign(socket, :tab, tab)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_principal}>
      <.header>
        {@bucket} · 设置
        <:subtitle>
          <.link navigate={~p"/buckets/#{@bucket}/browse"} class="link">← 返回浏览</.link>
        </:subtitle>
      </.header>

      <div id="settings-tabs" class="tabs tabs-bordered mb-6">
        <.tab bucket={@bucket} tab={@tab} key="versioning" label="版本化" />
        <.tab bucket={@bucket} tab={@tab} key="policy" label="策略" />
        <.tab bucket={@bucket} tab={@tab} key="acl" label="ACL" />
        <.tab bucket={@bucket} tab={@tab} key="tags" label="标签" />
        <.tab bucket={@bucket} tab={@tab} key="cors" label="CORS" />
        <.tab bucket={@bucket} tab={@tab} key="lifecycle" label="生命周期" />
        <.tab bucket={@bucket} tab={@tab} key="encryption" label="加密" />
        <.tab bucket={@bucket} tab={@tab} key="public_access_block" label="公共访问" />
        <.tab bucket={@bucket} tab={@tab} key="quota" label="配额" />
        <.tab bucket={@bucket} tab={@tab} key="object_lock" label="对象锁" />
        <.tab bucket={@bucket} tab={@tab} key="replication" label="复制" />
        <.tab bucket={@bucket} tab={@tab} key="notification" label="通知" />
      </div>

      <div class="rounded-box bg-base-100 border border-base-300 p-5">
        <%= case @tab do %>
          <% "versioning" -> %>
            <.form
              for={@versioning_form}
              id="versioning-form"
              phx-submit="save_versioning"
              class="space-y-3"
            >
              <.input
                field={@versioning_form[:status]}
                type="select"
                label="版本化状态"
                options={[
                  {"未启用（Unversioned）", "Unversioned"},
                  {"启用（Enabled）", "Enabled"},
                  {"暂停（Suspended）", "Suspended"}
                ]}
              />
              <.button variant="primary" id="versioning-submit" type="submit">保存</.button>
            </.form>
          <% "policy" -> %>
            <.form for={@policy_form} id="policy-form" phx-submit="save_policy" class="space-y-3">
              <p class="text-sm text-base-content/60">桶策略 JSON（留空保存 = 删除策略）。</p>
              <.input
                field={@policy_form[:json]}
                type="textarea"
                rows="14"
                class="w-full textarea font-mono text-xs"
              />
              <.button variant="primary" id="policy-submit" type="submit">保存策略</.button>
            </.form>
          <% "acl" -> %>
            <.form for={@acl_form} id="acl-form" phx-submit="save_acl" class="space-y-3">
              <.input
                field={@acl_form[:canned]}
                type="select"
                label="Canned ACL"
                options={[
                  {"private", "private"},
                  {"public-read", "public-read"},
                  {"public-read-write", "public-read-write"},
                  {"authenticated-read", "authenticated-read"}
                ]}
              />
              <.button variant="primary" id="acl-submit" type="submit">保存 ACL</.button>
            </.form>
          <% "tags" -> %>
            <.form
              for={@tags_form}
              id="bucket-tags-form"
              phx-submit="save_bucket_tags"
              class="space-y-3"
            >
              <p class="text-sm text-base-content/60">桶标签（每行 key=value，桶 ≤50 个）。</p>
              <.input field={@tags_form[:raw]} type="textarea" rows="8" placeholder="env=prod" />
              <.button variant="primary" id="bucket-tags-submit" type="submit">保存标签</.button>
            </.form>
          <% "cors" -> %>
            <.form for={@cors_form} id="cors-form" phx-submit="save_cors" class="space-y-3">
              <p class="text-sm text-base-content/60">
                CORS 规则 JSON 数组（留空保存 = 删除）。形态对齐 S3 端解析结果：每条规则含
                <code class="text-xs">allowed_origins</code>
                / <code class="text-xs">allowed_methods</code>
                / <code class="text-xs">allowed_headers</code>
                / <code class="text-xs">expose_headers</code>
                / <code class="text-xs">max_age_seconds</code>。
              </p>
              <.input
                field={@cors_form[:json]}
                type="textarea"
                rows="14"
                class="w-full textarea font-mono text-xs"
              />
              <.button variant="primary" id="cors-submit" type="submit">保存 CORS</.button>
            </.form>
          <% "lifecycle" -> %>
            <div class="space-y-3">
              <div id="lifecycle-defer-alert" class="alert alert-warning text-sm">
                <.icon name="hero-exclamation-triangle" class="size-4" />
                生命周期规则可由 mix maxio.lifecycle.run 执行一轮，或通过 config :maxio, :lifecycle_scheduler 开启后台调度；Transition 与 NoncurrentVersionTransition 会更新 storage_class 元数据，真实 tier 字节迁移仍 defer。
              </div>
              <.form
                for={@lifecycle_form}
                id="lifecycle-form"
                phx-submit="save_lifecycle"
                class="space-y-3"
              >
                <.input
                  field={@lifecycle_form[:json]}
                  type="textarea"
                  rows="14"
                  class="w-full textarea font-mono text-xs"
                />
                <.button variant="primary" id="lifecycle-submit" type="submit">保存生命周期</.button>
              </.form>
            </div>
          <% "encryption" -> %>
            <.form
              for={@encryption_form}
              id="encryption-form"
              phx-submit="save_encryption"
              class="space-y-3"
            >
              <.input
                field={@encryption_form[:algorithm]}
                type="select"
                label="默认加密"
                options={[
                  {"无", "none"},
                  {"SSE-S3（AES256）", "AES256"},
                  {"SSE-KMS（aws:kms）", "aws:kms"}
                ]}
              />
              <p class="text-xs text-base-content/50">SSE-KMS 使用本地默认 KMS key id。</p>
              <.button variant="primary" id="encryption-submit" type="submit">保存加密</.button>
            </.form>
          <% "public_access_block" -> %>
            <div class="space-y-4">
              <div id="public-access-block-context" class="alert alert-info text-sm">
                <.icon name="hero-shield-check" class="size-4" />
                当前只编辑 bucket-level PublicAccessBlock；account / organization / access point 叠加仍由后续 IAM/多租户扩展接入。
              </div>
              <.form
                for={@public_access_block_form}
                id="public-access-block-form"
                phx-submit="save_public_access_block"
                class="space-y-3"
              >
                <div class="grid gap-2 md:grid-cols-2">
                  <.input
                    field={@public_access_block_form[:block_public_acls]}
                    type="checkbox"
                    label="BlockPublicAcls：拒绝新的公共 ACL 写入"
                  />
                  <.input
                    field={@public_access_block_form[:ignore_public_acls]}
                    type="checkbox"
                    label="IgnorePublicAcls：授权时忽略公共 ACL"
                  />
                  <.input
                    field={@public_access_block_form[:block_public_policy]}
                    type="checkbox"
                    label="BlockPublicPolicy：拒绝公共 bucket policy"
                  />
                  <.input
                    field={@public_access_block_form[:restrict_public_buckets]}
                    type="checkbox"
                    label="RestrictPublicBuckets：公共 policy 仅保留 Deny"
                  />
                </div>
                <div class="flex flex-wrap gap-2">
                  <.button variant="primary" id="public-access-block-submit" type="submit">
                    保存 PublicAccessBlock
                  </.button>
                  <.button
                    id="public-access-block-delete"
                    type="button"
                    phx-click="delete_public_access_block"
                  >
                    删除配置
                  </.button>
                </div>
              </.form>
            </div>
          <% "quota" -> %>
            <div class="space-y-4">
              <div id="quota-context" class="alert alert-info text-sm">
                <.icon name="hero-circle-stack" class="size-4" />
                Hard quota 按所有已提交非 delete-marker 版本的逻辑字节统计，PutObject、POST Object、CopyObject 与 CompleteMultipartUpload 在提交元数据前 fail-closed。
              </div>
              <div id="quota-usage" class="text-sm text-base-content/70">
                当前 PG usage：<span class="font-mono">{format_bytes(@quota_usage_bytes)}</span>
              </div>
              <.form for={@quota_form} id="quota-form" phx-submit="save_quota" class="space-y-3">
                <.input
                  field={@quota_form[:enabled]}
                  type="checkbox"
                  label="启用 hard quota"
                />
                <.input
                  field={@quota_form[:size_bytes]}
                  type="number"
                  label="Quota bytes"
                  min="1"
                />
                <div class="flex flex-wrap gap-2">
                  <.button variant="primary" id="quota-submit" type="submit">保存配额</.button>
                  <.button id="quota-delete" type="button" phx-click="delete_quota">
                    删除配额
                  </.button>
                </div>
              </.form>
            </div>
          <% "object_lock" -> %>
            <div class="space-y-4">
              <div id="object-lock-context" class="alert alert-info text-sm">
                <.icon name="hero-lock-closed" class="size-4" />
                Object Lock 一旦为 bucket 启用就不能关闭；本页只管理已启用 bucket 的默认 Retention rule，不提供后置启用/关闭 Object Lock。
              </div>

              <div
                :if={!@object_lock_enabled?}
                id="object-lock-disabled"
                class="alert alert-warning text-sm"
              >
                当前 bucket 未通过 Object Lock 创建入口启用，不能设置 bucket 默认 Retention。
              </div>

              <div
                :if={@object_lock_enabled? && !@object_lock_configurable?}
                id="object-lock-versioning-disabled"
                class="alert alert-error text-sm"
              >
                当前 bucket 有 Object Lock 配置，但 versioning 不是 Enabled；请先修复元数据，不允许继续修改默认 Retention。
              </div>

              <div :if={@object_lock_configurable?} id="object-lock-enabled" class="space-y-3">
                <div class="text-sm text-base-content/70">
                  ObjectLockEnabled: <span class="font-mono text-success">Enabled</span>
                </div>
                <.form
                  for={@object_lock_form}
                  id="object-lock-form"
                  phx-submit="save_object_lock"
                  data-confirm="确认修改 bucket 默认 Retention？COMPLIANCE 默认保留会影响之后写入的新对象。"
                  class="space-y-3"
                >
                  <.input
                    field={@object_lock_form[:mode]}
                    type="select"
                    label="默认 Retention 模式"
                    prompt="不设置默认 Retention"
                    options={object_lock_mode_options()}
                  />
                  <div class="grid gap-3 md:grid-cols-2">
                    <.input
                      field={@object_lock_form[:duration_type]}
                      type="select"
                      label="Duration 单位"
                      options={object_lock_duration_type_options()}
                    />
                    <.input
                      field={@object_lock_form[:duration_value]}
                      type="number"
                      label="Duration"
                      min="1"
                    />
                  </div>
                  <p id="object-lock-warning" class="text-xs text-warning">
                    留空模式会移除默认 Retention rule，但不会关闭 bucket Object Lock，也不会修改已有对象版本。
                  </p>
                  <.button variant="primary" id="object-lock-submit" type="submit">
                    保存 Object Lock
                  </.button>
                </.form>
              </div>
            </div>
          <% "replication" -> %>
            <div class="space-y-4">
              <div id="replication-context" class="alert alert-info text-sm">
                <.icon name="hero-arrow-path" class="size-4" />
                配置 Bucket Replication 控制面 JSON；本页只保存规则，不执行真实对象复制。
              </div>
              <div
                :if={@bucket_struct.versioning != "Enabled"}
                id="replication-versioning-disabled"
                class="alert alert-warning text-sm"
              >
                S3 要求源 bucket versioning 为 Enabled 才能保存 Replication 配置；删除配置不受此限制。
              </div>
              <.form
                for={@replication_form}
                id="replication-form"
                phx-submit="save_replication"
                class="space-y-3"
              >
                <.input
                  field={@replication_form[:json]}
                  type="textarea"
                  rows="16"
                  class="w-full textarea font-mono text-xs"
                />
                <div class="flex flex-wrap gap-2">
                  <.button variant="primary" id="replication-submit" type="submit">
                    保存复制配置
                  </.button>
                  <.button id="replication-delete" type="button" phx-click="delete_replication">
                    删除配置
                  </.button>
                </div>
              </.form>
            </div>
          <% "notification" -> %>
            <div class="space-y-4">
              <div id="notification-context" class="alert alert-info text-sm">
                <.icon name="hero-bell-alert" class="size-4" />
                配置 bucket notification JSON。EventBridge-only 可直接保存；Topic/Queue/Lambda 目的地默认需要验证器，或显式跳过目的地验证。
              </div>
              <.form
                for={@notification_form}
                id="notification-form"
                phx-submit="save_notification"
                class="space-y-3"
              >
                <.input
                  field={@notification_form[:json]}
                  type="textarea"
                  rows="16"
                  class="w-full textarea font-mono text-xs"
                />
                <.input
                  field={@notification_form[:skip_destination_validation]}
                  type="checkbox"
                  label="跳过 SNS/SQS/Lambda 目的地验证"
                />
                <div class="flex flex-wrap gap-2">
                  <.button variant="primary" id="notification-submit" type="submit">
                    保存通知配置
                  </.button>
                  <.button id="notification-delete" type="button" phx-click="delete_notification">
                    删除配置
                  </.button>
                </div>
              </.form>
            </div>
        <% end %>
      </div>
    </Layouts.app>
    """
  end

  attr :bucket, :string, required: true
  attr :tab, :string, required: true
  attr :key, :string, required: true
  attr :label, :string, required: true

  defp tab(assigns) do
    ~H"""
    <.link
      id={"tab-#{@key}"}
      patch={~p"/buckets/#{@bucket}/settings?tab=#{@key}"}
      class={["tab", @tab == @key && "tab-active"]}
    >
      {@label}
    </.link>
    """
  end

  # ── 表单装配 ──
  defp load_forms(socket, b) do
    bucket = b.name

    policy_json =
      case Store.get_bucket_policy(bucket) do
        {:ok, json} -> json
        :none -> ""
      end

    cors_json = config_json(bucket, :cors)
    lifecycle_json = config_json(bucket, :lifecycle)
    replication_json = replication_config_json(bucket)
    notification_json = notification_config_json(bucket)
    encryption_algo = encryption_algo(bucket)
    public_access_block_config = public_access_block_config(bucket)
    object_lock_config = object_lock_config(bucket)
    quota_config = quota_config(bucket)
    {:ok, bucket_tags} = Buckets.get_tags(bucket)

    socket
    |> assign(:versioning_form, to_form(%{"status" => b.versioning}, as: :versioning))
    |> assign(:policy_form, to_form(%{"json" => policy_json}, as: :policy))
    |> assign(:acl_form, to_form(%{"canned" => b.acl_canned}, as: :acl))
    |> assign(:tags_form, to_form(%{"raw" => tags_raw(bucket_tags)}, as: :tags))
    |> assign(:cors_form, to_form(%{"json" => cors_json}, as: :cors))
    |> assign(:lifecycle_form, to_form(%{"json" => lifecycle_json}, as: :lifecycle))
    |> assign(:replication_form, replication_form(replication_json))
    |> assign(:notification_form, notification_form(notification_json))
    |> assign(:encryption_form, to_form(%{"algorithm" => encryption_algo}, as: :encryption))
    |> assign(:public_access_block_form, public_access_block_form(public_access_block_config))
    |> assign(:quota_usage_bytes, BucketQuota.usage(bucket))
    |> assign(:quota_form, quota_form(quota_config))
    |> assign(:object_lock_enabled?, object_lock_enabled_config?(object_lock_config))
    |> assign(
      :object_lock_configurable?,
      object_lock_enabled_config?(object_lock_config) and b.versioning == "Enabled"
    )
    |> assign(:object_lock_form, object_lock_form(object_lock_config))
  end

  defp config_json(bucket, kind) do
    case BucketConfigs.get(bucket, kind) do
      {:ok, value} -> Jason.encode!(value, pretty: true)
      :none -> ""
    end
  end

  defp replication_config_json(bucket) do
    case Replication.get_config(bucket) do
      {:ok, config} -> Jason.encode!(config, pretty: true)
      :none -> ""
    end
  rescue
    _error -> config_json(bucket, :replication)
  end

  defp notification_config_json(bucket) do
    case Notification.get_config(bucket) do
      {:ok, config} ->
        if Notification.empty_config?(config), do: "", else: Jason.encode!(config, pretty: true)
    end
  rescue
    _error -> config_json(bucket, :notification)
  end

  defp encryption_algo(bucket) do
    case BucketConfigs.get(bucket, :encryption) do
      {:ok, %{"algorithm" => algo}} -> algo
      {:ok, _} -> "none"
      :none -> "none"
    end
  end

  defp public_access_block_config(bucket) do
    case PublicAccessBlock.get_config(bucket) do
      {:ok, config} -> config
      :none -> PublicAccessBlock.defaults()
    end
  end

  defp quota_config(bucket), do: BucketQuota.get(bucket)

  defp object_lock_config(bucket) do
    ObjectLock.get_config(bucket)
  end

  defp object_lock_enabled_config?({:ok, %{"ObjectLockEnabled" => "Enabled"}}), do: true
  defp object_lock_enabled_config?(_config), do: false

  defp public_access_block_form(config) do
    to_form(
      %{
        "block_public_acls" => Map.get(config, "BlockPublicAcls", false),
        "ignore_public_acls" => Map.get(config, "IgnorePublicAcls", false),
        "block_public_policy" => Map.get(config, "BlockPublicPolicy", false),
        "restrict_public_buckets" => Map.get(config, "RestrictPublicBuckets", false)
      },
      as: :public_access_block
    )
  end

  defp notification_form(json, skip_destination_validation \\ false) do
    to_form(
      %{
        "json" => json,
        "skip_destination_validation" => skip_destination_validation
      },
      as: :notification
    )
  end

  defp replication_form(json), do: to_form(%{"json" => json}, as: :replication)

  defp quota_form({:ok, %{"size_bytes" => size_bytes}}) do
    to_form(%{"enabled" => true, "size_bytes" => Integer.to_string(size_bytes)}, as: :quota)
  end

  defp quota_form(_config) do
    to_form(%{"enabled" => false, "size_bytes" => ""}, as: :quota)
  end

  defp object_lock_form({:ok, %{"Rule" => %{"DefaultRetention" => retention}}}) do
    {duration_type, duration_value} = object_lock_duration(retention)

    to_form(
      %{
        "mode" => Map.get(retention, "Mode", ""),
        "duration_type" => duration_type,
        "duration_value" => duration_value
      },
      as: :object_lock
    )
  end

  defp object_lock_form(_config) do
    to_form(
      %{
        "mode" => "",
        "duration_type" => "Days",
        "duration_value" => ""
      },
      as: :object_lock
    )
  end

  defp object_lock_duration(%{"Days" => days}), do: {"Days", to_string(days)}
  defp object_lock_duration(%{"Years" => years}), do: {"Years", to_string(years)}
  defp object_lock_duration(_retention), do: {"Days", ""}

  defp tags_raw(tag_list),
    do: tag_list |> Enum.map(fn {k, v} -> "#{k}=#{v}" end) |> Enum.join("\n")

  defp format_bytes(n) when is_integer(n) and n >= 0 do
    cond do
      n >= 1_099_511_627_776 -> "#{Float.round(n / 1_099_511_627_776, 2)} TiB"
      n >= 1_073_741_824 -> "#{Float.round(n / 1_073_741_824, 2)} GiB"
      n >= 1_048_576 -> "#{Float.round(n / 1_048_576, 2)} MiB"
      n >= 1024 -> "#{Float.round(n / 1024, 2)} KiB"
      true -> "#{n} B"
    end
  end

  defp format_bytes(_n), do: "0 B"

  # ── handle_event ──
  @impl true
  def handle_event("save_versioning", %{"versioning" => %{"status" => status}}, socket) do
    bucket = socket.assigns.bucket

    # "Unversioned" 不是 PutBucketVersioning 合法 status；映射为 Suspended（AWS 无法回退到 never-set）。
    arg = if status == "Unversioned", do: "Suspended", else: status

    case reject_object_lock_versioning_suspend(bucket, arg) do
      :ok ->
        :ok = Buckets.put_versioning(bucket, arg, nil)
        {:ok, b} = Buckets.lookup(bucket)

        {:noreply,
         socket |> assign(:bucket_struct, b) |> load_forms(b) |> put_flash(:info, "版本化已更新")}

      {:error, :object_lock_versioning_suspend} ->
        {:noreply, put_flash(socket, :error, "Object Lock bucket 不能暂停版本化")}
    end
  end

  def handle_event("save_policy", %{"policy" => %{"json" => json}}, socket) do
    bucket = socket.assigns.bucket
    trimmed = String.trim(json)

    cond do
      trimmed == "" ->
        :ok = Store.delete_bucket_policy(bucket)
        {:noreply, put_flash(socket, :info, "策略已删除")}

      true ->
        case Statement.parse_policy(trimmed) do
          {:ok, _stmts} ->
            :ok = Store.put_bucket_policy(bucket, trimmed)
            {:noreply, put_flash(socket, :info, "策略已保存")}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, "策略 JSON 非法（MalformedPolicy）")}
        end
    end
  end

  def handle_event("save_acl", %{"acl" => %{"canned" => canned}}, socket) do
    bucket = socket.assigns.bucket

    if canned in @canned do
      :ok = Buckets.put_acl(bucket, canned)
      {:noreply, put_flash(socket, :info, "ACL 已更新为 #{canned}")}
    else
      {:noreply, put_flash(socket, :error, "不支持的 canned ACL")}
    end
  end

  def handle_event("save_bucket_tags", %{"tags" => %{"raw" => raw}}, socket) do
    bucket = socket.assigns.bucket
    tag_list = parse_raw_tags(raw)

    case Tags.validate(tag_list, :bucket) do
      :ok ->
        :ok = Buckets.put_tags(bucket, tag_list)
        {:noreply, put_flash(socket, :info, "桶标签已保存")}

      {:error, :invalid_tag} ->
        {:noreply, put_flash(socket, :error, "标签非法（桶 ≤50 个，不可 aws: 前缀）")}
    end
  end

  def handle_event("save_cors", %{"cors" => %{"json" => json}}, socket) do
    bucket = socket.assigns.bucket
    save_config_json(socket, bucket, :cors, json, "CORS")
  end

  def handle_event("save_lifecycle", %{"lifecycle" => %{"json" => json}}, socket) do
    bucket = socket.assigns.bucket
    save_config_json(socket, bucket, :lifecycle, json, "生命周期")
  end

  def handle_event("save_replication", %{"replication" => %{"json" => json}}, socket) do
    bucket = socket.assigns.bucket
    save_replication_config(socket, bucket, json || "")
  end

  def handle_event("save_notification", %{"notification" => params}, socket) do
    bucket = socket.assigns.bucket
    skip_destination_validation? = checkbox_value(params["skip_destination_validation"])
    save_notification_config(socket, bucket, params["json"] || "", skip_destination_validation?)
  end

  def handle_event("save_encryption", %{"encryption" => %{"algorithm" => algo}}, socket) do
    bucket = socket.assigns.bucket

    cond do
      algo == "none" ->
        :ok = BucketConfigs.delete(bucket, :encryption)
        {:noreply, put_flash(socket, :info, "默认加密已关闭")}

      algo == "AES256" ->
        :ok = BucketConfigs.put(bucket, :encryption, %{"algorithm" => "AES256"})
        {:noreply, put_flash(socket, :info, "默认加密已设为 SSE-S3 (AES256)")}

      algo == "aws:kms" ->
        :ok =
          BucketConfigs.put(bucket, :encryption, %{
            "algorithm" => "aws:kms",
            "kms_key_id" => KMS.default_key_id(),
            "bucket_key_enabled" => false
          })

        {:noreply, put_flash(socket, :info, "默认加密已设为 SSE-KMS (aws:kms)")}

      true ->
        {:noreply, put_flash(socket, :error, "默认加密算法非法")}
    end
  end

  def handle_event(
        "save_public_access_block",
        %{"public_access_block" => params},
        socket
      ) do
    bucket = socket.assigns.bucket
    config = public_access_block_params(params)

    case BucketConfigs.put(bucket, :public_access_block, config) do
      :ok ->
        {:noreply,
         socket
         |> assign(:public_access_block_form, public_access_block_form(config))
         |> put_flash(:info, "PublicAccessBlock 已保存")}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "PublicAccessBlock 保存失败")}
    end
  end

  def handle_event("delete_public_access_block", _params, socket) do
    bucket = socket.assigns.bucket
    :ok = BucketConfigs.delete(bucket, :public_access_block)

    {:noreply,
     socket
     |> assign(:public_access_block_form, public_access_block_form(PublicAccessBlock.defaults()))
     |> put_flash(:info, "PublicAccessBlock 已删除")}
  end

  def handle_event("save_quota", %{"quota" => params}, socket) do
    bucket = socket.assigns.bucket

    case quota_from_params(params) do
      {:ok, :none} ->
        :ok = BucketQuota.delete(bucket)

        {:noreply,
         socket
         |> assign(:quota_form, quota_form(:none))
         |> assign(:quota_usage_bytes, BucketQuota.usage(bucket))
         |> put_flash(:info, "Bucket hard quota 已删除")}

      {:ok, size_bytes} ->
        case BucketQuota.put_hard(bucket, size_bytes) do
          :ok ->
            {:noreply,
             socket
             |> assign(
               :quota_form,
               quota_form({:ok, %{"type" => "hard", "size_bytes" => size_bytes}})
             )
             |> assign(:quota_usage_bytes, BucketQuota.usage(bucket))
             |> put_flash(:info, "Bucket hard quota 已保存")}

          {:error, _reason} ->
            {:noreply, put_flash(socket, :error, "Bucket quota 保存失败")}
        end

      {:error, :invalid_quota} ->
        {:noreply, put_flash(socket, :error, "Bucket quota 必须是正整数 bytes")}
    end
  end

  def handle_event("delete_quota", _params, socket) do
    bucket = socket.assigns.bucket
    :ok = BucketQuota.delete(bucket)

    {:noreply,
     socket
     |> assign(:quota_form, quota_form(:none))
     |> assign(:quota_usage_bytes, BucketQuota.usage(bucket))
     |> put_flash(:info, "Bucket hard quota 已删除")}
  end

  def handle_event("delete_replication", _params, socket) do
    bucket = socket.assigns.bucket
    :ok = Replication.delete_config(bucket)

    {:noreply,
     socket
     |> assign(:replication_form, replication_form(""))
     |> put_flash(:info, "复制配置已删除")}
  end

  def handle_event("save_object_lock", %{"object_lock" => params}, socket) do
    bucket = socket.assigns.bucket

    with :ok <- require_console_object_lock_configurable(bucket),
         {:ok, config} <- object_lock_config_from_params(params),
         :ok <- persist_object_lock_config(bucket, config) do
      {:ok, saved_config} = ObjectLock.get_config(bucket)

      {:noreply,
       socket
       |> assign(:object_lock_enabled?, true)
       |> assign(:object_lock_form, object_lock_form({:ok, saved_config}))
       |> put_flash(:info, "Object Lock 默认 Retention 已保存")}
    else
      {:error, :object_lock_disabled} ->
        {:noreply, put_flash(socket, :error, "当前 bucket 未启用 Object Lock")}

      {:error, :object_lock_versioning_disabled} ->
        {:noreply, put_flash(socket, :error, "Object Lock bucket 的版本化必须保持 Enabled")}

      {:error, :invalid_object_lock} ->
        {:noreply, put_flash(socket, :error, "Object Lock 配置非法")}

      {:error, :persist_failed} ->
        {:noreply, put_flash(socket, :error, "Object Lock 配置保存失败")}
    end
  end

  def handle_event("delete_notification", _params, socket) do
    bucket = socket.assigns.bucket
    :ok = BucketConfigs.delete(bucket, :notification)

    {:noreply,
     socket
     |> assign(:notification_form, notification_form(""))
     |> put_flash(:info, "通知配置已删除")}
  end

  # 通用 JSON 配置保存（cors/lifecycle）：空 = 删除；非法 JSON = 错误 flash。
  defp save_config_json(socket, bucket, kind, json, label) do
    trimmed = String.trim(json)

    cond do
      trimmed == "" ->
        :ok = BucketConfigs.delete(bucket, kind)
        {:noreply, put_flash(socket, :info, "#{label} 已删除")}

      true ->
        case Jason.decode(trimmed) do
          {:ok, value} ->
            case validate_config(kind, value) do
              :ok ->
                case BucketConfigs.put(bucket, kind, value) do
                  :ok -> {:noreply, put_flash(socket, :info, "#{label} 已保存")}
                  {:error, _} -> {:noreply, put_flash(socket, :error, "#{label} 保存失败")}
                end

              {:error, %S3Error{} = error} ->
                {:noreply, put_flash(socket, :error, "#{label} 规则非法（#{error.code}）")}
            end

          {:error, _} ->
            {:noreply, put_flash(socket, :error, "#{label} JSON 非法")}
        end
    end
  end

  defp validate_config(:cors, value), do: validate_s3_config(fn -> Cors.validate!(value) end)

  defp validate_config(:lifecycle, value),
    do: validate_s3_config(fn -> Lifecycle.validate!(value) end)

  defp validate_config(_kind, _value), do: :ok

  defp quota_from_params(params) do
    enabled? = checkbox_value(params["enabled"])

    if enabled? do
      parse_quota_size(params["size_bytes"])
    else
      {:ok, :none}
    end
  end

  defp parse_quota_size(value) do
    case Integer.parse(to_string(value || "")) do
      {size, ""} ->
        case BucketQuota.validate_size(size) do
          :ok -> {:ok, size}
          {:error, reason} -> {:error, reason}
        end

      _other ->
        {:error, :invalid_quota}
    end
  end

  defp validate_s3_config(fun) do
    fun.()
  rescue
    error in S3Error -> {:error, error}
  end

  defp save_replication_config(socket, bucket, json) do
    trimmed = String.trim(json)

    cond do
      trimmed == "" ->
        :ok = Replication.delete_config(bucket)

        {:noreply,
         socket
         |> assign(:replication_form, replication_form(""))
         |> put_flash(:info, "复制配置已删除")}

      true ->
        with {:ok, value} <- decode_replication_json(trimmed),
             {:ok, config} <- Replication.validate_client_config(value),
             :ok <- require_replication_versioning_enabled(bucket),
             :ok <- persist_replication_config(bucket, config) do
          {:noreply,
           socket
           |> assign(:replication_form, replication_form(Jason.encode!(config, pretty: true)))
           |> put_flash(:info, "复制配置已保存")}
        else
          {:error, :invalid_json} ->
            {:noreply, put_flash(socket, :error, "复制配置 JSON 非法")}

          {:error, :invalid_shape} ->
            {:noreply, put_flash(socket, :error, "复制配置必须是 JSON 对象")}

          {:error, :malformed_xml} ->
            {:noreply, put_flash(socket, :error, "复制配置非法（MalformedXML）")}

          {:error, :versioning_disabled} ->
            {:noreply, put_flash(socket, :error, "Replication 要求 bucket versioning 为 Enabled")}

          {:error, :bucket_not_found} ->
            {:noreply, put_flash(socket, :error, "桶不存在")}

          {:error, :persist_failed} ->
            {:noreply, put_flash(socket, :error, "复制配置保存失败")}
        end
    end
  end

  defp decode_replication_json(json) do
    case Jason.decode(json) do
      {:ok, value} when is_map(value) -> {:ok, value}
      {:ok, _value} -> {:error, :invalid_shape}
      {:error, _reason} -> {:error, :invalid_json}
    end
  end

  defp require_replication_versioning_enabled(bucket) do
    case Buckets.lookup(bucket) do
      {:ok, %{versioning: "Enabled"}} -> :ok
      {:ok, _bucket} -> {:error, :versioning_disabled}
      {:error, :not_found} -> {:error, :bucket_not_found}
    end
  end

  defp persist_replication_config(bucket, config) do
    Replication.put_config(bucket, config)
  rescue
    _error -> {:error, :persist_failed}
  end

  defp save_notification_config(socket, bucket, json, skip_destination_validation?) do
    trimmed = String.trim(json)

    cond do
      trimmed == "" ->
        :ok = BucketConfigs.delete(bucket, :notification)

        {:noreply,
         socket
         |> assign(:notification_form, notification_form(""))
         |> put_flash(:info, "通知配置已删除")}

      true ->
        with {:ok, value} <- decode_notification_json(trimmed),
             {:ok, config} <- Notification.validate_client_config(value),
             :ok <-
               validate_notification_destinations(bucket, config, skip_destination_validation?),
             :ok <- persist_notification_config(bucket, config) do
          {:noreply,
           socket
           |> assign(
             :notification_form,
             notification_form(Jason.encode!(config, pretty: true), skip_destination_validation?)
           )
           |> put_flash(:info, "通知配置已保存")}
        else
          {:error, :invalid_json} ->
            {:noreply, put_flash(socket, :error, "通知配置 JSON 非法")}

          {:error, :invalid_shape} ->
            {:noreply, put_flash(socket, :error, "通知配置必须是 JSON 对象")}

          {:error, :malformed_xml} ->
            {:noreply, put_flash(socket, :error, "通知配置非法（MalformedXML）")}

          {:error, :no_validator} ->
            {:noreply,
             put_flash(
               socket,
               :error,
               "通知目的地验证器未配置；请配置 validator 或显式跳过目的地验证"
             )}

          {:error, :validation_failed} ->
            {:noreply, put_flash(socket, :error, "通知目的地验证失败")}

          {:error, :persist_failed} ->
            {:noreply, put_flash(socket, :error, "通知配置保存失败")}
        end
    end
  end

  defp decode_notification_json(json) do
    case Jason.decode(json) do
      {:ok, value} when is_map(value) -> {:ok, value}
      {:ok, _value} -> {:error, :invalid_shape}
      {:error, _reason} -> {:error, :invalid_json}
    end
  end

  defp validate_notification_destinations(bucket, config, skip_destination_validation?) do
    cond do
      Notification.empty_config?(config) ->
        :ok

      skip_destination_validation? ->
        :ok

      true ->
        case NotificationDestinationValidator.validate(bucket, config) do
          {:ok, _metadata} -> :ok
          {:error, :no_validator} -> {:error, :no_validator}
          {:error, _reason} -> {:error, :validation_failed}
        end
    end
  end

  defp persist_notification_config(bucket, config) do
    if Notification.empty_config?(config) do
      BucketConfigs.delete(bucket, :notification)
    else
      BucketConfigs.put(bucket, :notification, config)
    end
    |> case do
      :ok -> :ok
      {:error, _reason} -> {:error, :persist_failed}
    end
  end

  defp reject_object_lock_versioning_suspend(bucket, "Suspended") do
    if ObjectLock.bucket_enabled?(bucket),
      do: {:error, :object_lock_versioning_suspend},
      else: :ok
  end

  defp reject_object_lock_versioning_suspend(_bucket, _status), do: :ok

  defp require_console_object_lock_configurable(bucket) do
    if ObjectLock.bucket_enabled?(bucket) do
      case Buckets.lookup(bucket) do
        {:ok, %{versioning: "Enabled"}} -> :ok
        {:ok, _bucket} -> {:error, :object_lock_versioning_disabled}
        {:error, :not_found} -> {:error, :object_lock_disabled}
      end
    else
      {:error, :object_lock_disabled}
    end
  end

  defp object_lock_config_from_params(params) do
    mode = params |> Map.get("mode", "") |> to_string() |> String.trim()

    config =
      if mode == "" do
        ObjectLock.enabled_config()
      else
        duration_type = Map.get(params, "duration_type", "Days")
        duration_value = params |> Map.get("duration_value", "") |> to_string() |> String.trim()

        with true <- duration_type in ["Days", "Years"],
             {:ok, duration} <- parse_positive_integer(duration_value) do
          %{
            "ObjectLockEnabled" => "Enabled",
            "Rule" => %{
              "DefaultRetention" => %{
                "Mode" => mode,
                duration_type => duration
              }
            }
          }
        else
          _ -> :invalid
        end
      end

    case config do
      :invalid -> {:error, :invalid_object_lock}
      config -> ObjectLock.validate_client_config(config) |> map_object_lock_validation()
    end
  end

  defp map_object_lock_validation({:ok, config}), do: {:ok, config}

  # 所有失败形态（`{:error, :malformed_xml}` 与任何未来新增的错误）产出同一结构化错误，
  # 因此不再单列 `:malformed_xml` 子句 —— 那一支被兜底逐字覆盖，且反过来让兜底不可达。
  defp map_object_lock_validation(_other), do: {:error, :invalid_object_lock}

  defp persist_object_lock_config(bucket, config) do
    ObjectLock.put_config(bucket, config)
  rescue
    _error -> {:error, :persist_failed}
  end

  defp parse_positive_integer(value) do
    case Integer.parse(value) do
      {integer, ""} when integer > 0 -> {:ok, integer}
      _other -> {:error, :invalid_integer}
    end
  end

  defp object_lock_mode_options,
    do: [{"GOVERNANCE", "GOVERNANCE"}, {"COMPLIANCE", "COMPLIANCE"}]

  defp object_lock_duration_type_options, do: [{"Days", "Days"}, {"Years", "Years"}]

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

  defp public_access_block_params(params) do
    %{
      "BlockPublicAcls" => checkbox_value(params["block_public_acls"]),
      "IgnorePublicAcls" => checkbox_value(params["ignore_public_acls"]),
      "BlockPublicPolicy" => checkbox_value(params["block_public_policy"]),
      "RestrictPublicBuckets" => checkbox_value(params["restrict_public_buckets"])
    }
  end

  defp checkbox_value(value) when value in [true, "true", "on", "1"], do: true
  defp checkbox_value(_value), do: false
end
