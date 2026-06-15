defmodule Maxio.S3.Views.Website do
  @moduledoc "GetBucketWebsite response XML renderer."
  import Saxy.XML

  alias Maxio.S3.XML

  @spec render(map()) :: iodata()
  def render(config) when is_map(config) do
    root =
      element(
        "WebsiteConfiguration",
        [{"xmlns", XML.namespace()}],
        config
        |> root_children()
      )

    XML.encode(root)
  end

  defp root_children(config) do
    []
    |> add(index_document_elem(config["index_document"]), & &1)
    |> add(error_document_elem(config["error_document"]), & &1)
    |> add(redirect_all_elem(config["redirect_all_requests_to"]), & &1)
    |> add(routing_rules_elem(config["routing_rules"]), & &1)
  end

  defp index_document_elem(%{"suffix" => suffix}) when is_binary(suffix) and suffix != "" do
    element("IndexDocument", [], [
      element("Suffix", [], characters(suffix))
    ])
  end

  defp index_document_elem(_other), do: nil

  defp error_document_elem(%{"key" => key}) when is_binary(key) and key != "" do
    element("ErrorDocument", [], [
      element("Key", [], characters(key))
    ])
  end

  defp error_document_elem(_other), do: nil

  defp redirect_all_elem(redirect) when is_map(redirect) do
    children =
      []
      |> add_text("HostName", redirect["host_name"])
      |> add_text("Protocol", redirect["protocol"])

    if children == [], do: nil, else: element("RedirectAllRequestsTo", [], children)
  end

  defp redirect_all_elem(_other), do: nil

  defp routing_rules_elem(rules) when is_list(rules) and rules != [] do
    element("RoutingRules", [], Enum.map(rules, &routing_rule_elem/1))
  end

  defp routing_rules_elem(_other), do: nil

  defp routing_rule_elem(rule) when is_map(rule) do
    children =
      []
      |> add(condition_elem(rule["condition"]), & &1)
      |> add(redirect_elem(rule["redirect"]), & &1)

    element("RoutingRule", [], children)
  end

  defp condition_elem(condition) when is_map(condition) do
    children =
      []
      |> add_text("HttpErrorCodeReturnedEquals", condition["http_error_code_returned_equals"])
      |> add_text("KeyPrefixEquals", condition["key_prefix_equals"])

    if children == [], do: nil, else: element("Condition", [], children)
  end

  defp condition_elem(_other), do: nil

  defp redirect_elem(redirect) when is_map(redirect) do
    children =
      []
      |> add_text("Protocol", redirect["protocol"])
      |> add_text("HostName", redirect["host_name"])
      |> add_text("ReplaceKeyPrefixWith", redirect["replace_key_prefix_with"])
      |> add_text("ReplaceKeyWith", redirect["replace_key_with"])
      |> add_text("HttpRedirectCode", redirect["http_redirect_code"])

    if children == [], do: nil, else: element("Redirect", [], children)
  end

  defp redirect_elem(_other), do: nil

  defp add(children, nil, _fun), do: children
  defp add(children, value, fun), do: children ++ [fun.(value)]

  defp add_text(children, _tag, nil), do: children
  defp add_text(children, _tag, ""), do: children

  defp add_text(children, tag, value) do
    children ++ [element(tag, [], characters(to_string(value)))]
  end
end
