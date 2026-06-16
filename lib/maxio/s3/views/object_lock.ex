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
end
