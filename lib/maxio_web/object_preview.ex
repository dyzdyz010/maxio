defmodule MaxioWeb.ObjectPreview do
  @moduledoc """
  Console object preview policy.

  Preview is intentionally allowlist-based because objects are untrusted user
  content. Unsafe browser-executable types such as HTML and SVG stay download-only.
  """

  @default_max_bytes 10 * 1024 * 1024
  @image_types MapSet.new(~w(image/png image/jpeg image/gif image/webp image/bmp))
  @frame_types MapSet.new(~w(application/pdf text/plain text/csv text/markdown application/json))

  def preview(object) do
    content_type = normalize_content_type(Map.get(object, :content_type))
    size = Map.get(object, :size)

    cond do
      not size_allowed?(size) ->
        %{
          mode: :unsupported,
          reason: :too_large,
          content_type: content_type,
          max_bytes: max_bytes()
        }

      MapSet.member?(@image_types, content_type) ->
        %{mode: :image, reason: nil, content_type: content_type, max_bytes: max_bytes()}

      MapSet.member?(@frame_types, content_type) ->
        %{mode: :frame, reason: nil, content_type: content_type, max_bytes: max_bytes()}

      true ->
        %{
          mode: :unsupported,
          reason: :unsupported_type,
          content_type: content_type,
          max_bytes: max_bytes()
        }
    end
  end

  def previewable?(object), do: preview(object).mode in [:image, :frame]

  def normalize_content_type(nil), do: "application/octet-stream"

  def normalize_content_type(content_type) when is_binary(content_type) do
    content_type
    |> String.split(";", parts: 2)
    |> List.first()
    |> String.trim()
    |> String.downcase()
    |> case do
      "" -> "application/octet-stream"
      type -> type
    end
  end

  def normalize_content_type(_), do: "application/octet-stream"

  def max_bytes do
    :maxio
    |> Application.get_env(:console, [])
    |> Keyword.get(:preview_max_bytes, @default_max_bytes)
  end

  defp size_allowed?(size) when is_integer(size) and size >= 0, do: size <= max_bytes()
  defp size_allowed?(_), do: false
end
