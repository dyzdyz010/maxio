defmodule Maxio.S3.Views.Cors do
  @moduledoc "GetBucketCors 响应 XML（CORSConfiguration>CORSRule×N，带 xmlns）。"
  import Saxy.XML
  alias Maxio.S3.XML

  @spec render([map()]) :: iodata()
  def render(rules) when is_list(rules) do
    rule_elems = Enum.map(rules, &rule_elem/1)
    root = element("CORSConfiguration", [{"xmlns", XML.namespace()}], rule_elems)
    XML.encode(root)
  end

  defp rule_elem(r) do
    children =
      []
      |> maybe_one("ID", r["id"])
      |> many("AllowedMethod", r["allowed_methods"])
      |> many("AllowedOrigin", r["allowed_origins"])
      |> many("AllowedHeader", r["allowed_headers"])
      |> many("ExposeHeader", r["expose_headers"])
      |> maybe_one("MaxAgeSeconds", r["max_age_seconds"] && Integer.to_string(r["max_age_seconds"]))

    element("CORSRule", [], children)
  end

  defp many(children, tag, values) when is_list(values),
    do: children ++ Enum.map(values, fn v -> element(tag, [], characters(to_string(v))) end)

  defp many(children, _tag, _), do: children

  defp maybe_one(children, _tag, nil), do: children
  defp maybe_one(children, _tag, ""), do: children
  defp maybe_one(children, tag, v), do: children ++ [element(tag, [], characters(to_string(v)))]
end
