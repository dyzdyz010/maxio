defmodule Maxio.S3.Views.ObjectLock do
  @moduledoc "GetBucketObjectLockConfiguration response XML renderer."
  import Saxy.XML

  alias Maxio.S3.{ObjectLock, XML}

  @spec render(map()) :: iodata()
  def render(config) when is_map(config) do
    config = ObjectLock.normalize_config(config)

    children =
      [
        element("ObjectLockEnabled", [], characters(config["ObjectLockEnabled"]))
      ] ++ maybe_rule(config["Rule"])

    XML.encode(element("ObjectLockConfiguration", [{"xmlns", XML.namespace()}], children))
  end

  @spec render_retention(map()) :: iodata()
  def render_retention(object) when is_map(object) do
    children =
      case retention(object) do
        nil ->
          []

        {mode, retain_until} ->
          [
            element("Mode", [], characters(mode)),
            element("RetainUntilDate", [], characters(DateTime.to_iso8601(retain_until)))
          ]
      end

    XML.encode(element("Retention", [{"xmlns", XML.namespace()}], children))
  end

  @spec render_legal_hold(map()) :: iodata()
  def render_legal_hold(object) when is_map(object) do
    status = object_value(object, :object_lock_legal_hold) || "OFF"

    XML.encode(
      element("LegalHold", [{"xmlns", XML.namespace()}], [
        element("Status", [], characters(status))
      ])
    )
  end

  defp maybe_rule(nil), do: []

  defp maybe_rule(%{"DefaultRetention" => retention}) do
    [
      element("Rule", [], [
        element(
          "DefaultRetention",
          [],
          [element("Mode", [], characters(retention["Mode"]))] ++ duration(retention)
        )
      ])
    ]
  end

  defp duration(%{"Days" => days}), do: [element("Days", [], characters(to_string(days)))]
  defp duration(%{"Years" => years}), do: [element("Years", [], characters(to_string(years)))]

  defp retention(object) do
    mode = object_value(object, :object_lock_mode)
    retain_until = object_value(object, :object_lock_retain_until)

    if is_binary(mode) and match?(%DateTime{}, retain_until) do
      {mode, retain_until}
    end
  end

  defp object_value(object, key), do: Map.get(object, key) || Map.get(object, Atom.to_string(key))
end
