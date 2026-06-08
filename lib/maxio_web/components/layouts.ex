defmodule MaxioWeb.Layouts do
  @moduledoc """
  This module holds layouts and related functionality
  used by your application.
  """
  use MaxioWeb, :html

  # Embed all files in layouts/* within this module.
  # The default root.html.heex file contains the HTML
  # skeleton of your application, namely HTML headers
  # and other static content.
  embed_templates "layouts/*"

  @doc """
  Renders your app layout.

  This function is typically invoked from every template,
  and it often contains your application menu, sidebar,
  or similar.

  ## Examples

      <Layouts.app flash={@flash}>
        <h1>Content</h1>
      </Layouts.app>

  """
  attr :flash, :map, required: true, doc: "the map of flash messages"

  attr :current_scope, :map,
    default: nil,
    doc: "the current [scope](https://hexdocs.pm/phoenix/scopes.html)"

  slot :inner_block, required: true

  def app(assigns) do
    ~H"""
    <div class="min-h-screen flex bg-base-200">
      <aside
        id="console-sidebar"
        class="w-60 shrink-0 bg-base-100 border-r border-base-300 flex flex-col"
      >
        <div class="h-16 flex items-center gap-2 px-5 border-b border-base-300">
          <.icon name="hero-cube" class="size-6 text-primary" />
          <span class="font-semibold tracking-tight">maxio</span>
          <span class="text-xs text-base-content/50">Console</span>
        </div>

        <nav class="flex-1 px-3 py-4 space-y-1">
          <.nav_link id="nav-dashboard" navigate={~p"/"} icon="hero-chart-bar-square" label="Dashboard" />
          <.nav_link id="nav-buckets" navigate={~p"/buckets"} icon="hero-archive-box" label="Buckets" />
          <.nav_link
            id="nav-access-keys"
            navigate={~p"/access-keys"}
            icon="hero-key"
            label="Access Keys"
          />
        </nav>

        <div class="px-3 py-3 border-t border-base-300 text-xs text-base-content/50">
          M5 Console · S3 :9900
        </div>
      </aside>

      <div class="flex-1 flex flex-col min-w-0">
        <header class="h-16 shrink-0 flex items-center justify-end gap-4 px-6 border-b border-base-300 bg-base-100">
          <span :if={@current_scope} id="current-identity" class="text-sm text-base-content/70">
            <.icon name="hero-user-circle" class="size-4 inline" />
            {@current_scope.access_key}
          </span>
          <.theme_toggle />
          <.link
            :if={@current_scope}
            id="logout-link"
            href={~p"/logout"}
            method="delete"
            class="btn btn-ghost btn-sm"
          >
            <.icon name="hero-arrow-right-on-rectangle" class="size-4" /> 登出
          </.link>
        </header>

        <main class="flex-1 overflow-auto px-6 py-6">
          <div class="mx-auto max-w-6xl">
            {render_slot(@inner_block)}
          </div>
        </main>
      </div>
    </div>

    <.flash_group flash={@flash} />
    """
  end

  attr :id, :string, required: true
  attr :navigate, :string, required: true
  attr :icon, :string, required: true
  attr :label, :string, required: true

  defp nav_link(assigns) do
    ~H"""
    <.link
      id={@id}
      navigate={@navigate}
      class="flex items-center gap-3 rounded-lg px-3 py-2 text-sm font-medium text-base-content/80 hover:bg-base-200 hover:text-base-content transition-colors"
    >
      <.icon name={@icon} class="size-5" />
      {@label}
    </.link>
    """
  end

  @doc """
  Shows the flash group with standard titles and content.

  ## Examples

      <.flash_group flash={@flash} />
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :id, :string, default: "flash-group", doc: "the optional id of flash container"

  def flash_group(assigns) do
    ~H"""
    <div id={@id} aria-live="polite">
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />

      <.flash
        id="client-error"
        kind={:error}
        title={gettext("We can't find the internet")}
        phx-disconnected={show(".phx-client-error #client-error") |> JS.remove_attribute("hidden")}
        phx-connected={hide("#client-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>

      <.flash
        id="server-error"
        kind={:error}
        title={gettext("Something went wrong!")}
        phx-disconnected={show(".phx-server-error #server-error") |> JS.remove_attribute("hidden")}
        phx-connected={hide("#server-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>
    </div>
    """
  end

  @doc """
  Provides dark vs light theme toggle based on themes defined in app.css.

  See <head> in root.html.heex which applies the theme before page load.
  """
  def theme_toggle(assigns) do
    ~H"""
    <div class="card relative flex flex-row items-center border-2 border-base-300 bg-base-300 rounded-full">
      <div class="absolute w-1/3 h-full rounded-full border-1 border-base-200 bg-base-100 brightness-200 left-0 [[data-theme=light]_&]:left-1/3 [[data-theme=dark]_&]:left-2/3 transition-[left]" />

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="system"
      >
        <.icon name="hero-computer-desktop-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="light"
      >
        <.icon name="hero-sun-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="dark"
      >
        <.icon name="hero-moon-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>
    </div>
    """
  end
end
