defmodule MaxioWeb.BucketLive.Settings do
  @moduledoc """
  Bucket Settings tabbed 编辑器（M5-7）：单个 LiveView 经 `?tab=` query + `push_patch`
  在 7 个 tab 间切换——versioning / policy(JSON) / acl(canned) / tags / cors(JSON) /
  lifecycle(JSON，后台执行标 defer) / encryption(SSE-S3，KMS 拒绝)。全部复用 M2–M4
  context（`Maxio.Buckets` / `Maxio.BucketConfigs` / `Maxio.Tags` / `Maxio.Policy.{Store,Statement}`）
  + 其内置校验；所有 context 错误显式 flash 呈现，绝不静默吞掉（铁律 3）。
  """
  use MaxioWeb, :live_view

  alias Maxio.{Buckets, BucketConfigs, Tags}
  alias Maxio.Policy.{Store, Statement}

  @tabs ~w(versioning policy acl tags cors lifecycle encryption)
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
                生命周期规则仅存储/校验；后台过期/转储执行尚未实现（M4 defer）。
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
                  {"SSE-KMS（暂不支持）", "aws:kms"}
                ]}
              />
              <p class="text-xs text-base-content/50">SSE-KMS 尚未实现（选择将被拒绝）。</p>
              <.button variant="primary" id="encryption-submit" type="submit">保存加密</.button>
            </.form>
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
    encryption_algo = encryption_algo(bucket)
    {:ok, bucket_tags} = Buckets.get_tags(bucket)

    socket
    |> assign(:versioning_form, to_form(%{"status" => b.versioning}, as: :versioning))
    |> assign(:policy_form, to_form(%{"json" => policy_json}, as: :policy))
    |> assign(:acl_form, to_form(%{"canned" => b.acl_canned}, as: :acl))
    |> assign(:tags_form, to_form(%{"raw" => tags_raw(bucket_tags)}, as: :tags))
    |> assign(:cors_form, to_form(%{"json" => cors_json}, as: :cors))
    |> assign(:lifecycle_form, to_form(%{"json" => lifecycle_json}, as: :lifecycle))
    |> assign(:encryption_form, to_form(%{"algorithm" => encryption_algo}, as: :encryption))
  end

  defp config_json(bucket, kind) do
    case BucketConfigs.get(bucket, kind) do
      {:ok, value} -> Jason.encode!(value, pretty: true)
      :none -> ""
    end
  end

  defp encryption_algo(bucket) do
    case BucketConfigs.get(bucket, :encryption) do
      {:ok, %{"algorithm" => algo}} -> algo
      {:ok, _} -> "none"
      :none -> "none"
    end
  end

  defp tags_raw(tag_list), do: tag_list |> Enum.map(fn {k, v} -> "#{k}=#{v}" end) |> Enum.join("\n")

  # ── handle_event ──
  @impl true
  def handle_event("save_versioning", %{"versioning" => %{"status" => status}}, socket) do
    bucket = socket.assigns.bucket
    # "Unversioned" 不是 PutBucketVersioning 合法 status；映射为 Suspended（AWS 无法回退到 never-set）。
    arg = if status == "Unversioned", do: "Suspended", else: status
    :ok = Buckets.put_versioning(bucket, arg, nil)
    {:ok, b} = Buckets.lookup(bucket)
    {:noreply, socket |> assign(:bucket_struct, b) |> load_forms(b) |> put_flash(:info, "版本化已更新")}
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

  def handle_event("save_encryption", %{"encryption" => %{"algorithm" => algo}}, socket) do
    bucket = socket.assigns.bucket

    cond do
      algo == "none" ->
        :ok = BucketConfigs.delete(bucket, :encryption)
        {:noreply, put_flash(socket, :info, "默认加密已关闭")}

      algo == "AES256" ->
        :ok = BucketConfigs.put(bucket, :encryption, %{"algorithm" => "AES256"})
        {:noreply, put_flash(socket, :info, "默认加密已设为 SSE-S3 (AES256)")}

      true ->
        {:noreply, put_flash(socket, :error, "SSE-KMS 尚未实现（绝不静默当 AES256）")}
    end
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
            case BucketConfigs.put(bucket, kind, value) do
              :ok -> {:noreply, put_flash(socket, :info, "#{label} 已保存")}
              {:error, _} -> {:noreply, put_flash(socket, :error, "#{label} 保存失败")}
            end

          {:error, _} ->
            {:noreply, put_flash(socket, :error, "#{label} JSON 非法")}
        end
    end
  end

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
end
