defmodule Maxio.S3.RequestParsers.Website do
  @moduledoc "PutBucketWebsite WebsiteConfiguration XML parser."

  @type config :: map()

  alias Maxio.S3.RequestParsers.XMLTree

  @unset {:__maxio_website_unset__, []}

  @spec parse(binary()) :: {:ok, config()} | {:error, :malformed_xml}
  def parse(xml) when is_binary(xml) do
    case XMLTree.parse(xml) do
      {:ok, {"WebsiteConfiguration", _attrs, children}} ->
        parse_root(children)

      _other ->
        {:error, :malformed_xml}
    end
  end

  defp new_config do
    %{
      "index_document" => nil,
      "error_document" => nil,
      "redirect_all_requests_to" => nil,
      "routing_rules" => []
    }
  end

  defp new_acc do
    %{
      index_document: @unset,
      error_document: @unset,
      redirect_all_requests_to: @unset,
      routing_rules: @unset
    }
  end

  defp parse_root(children) do
    children
    |> XMLTree.structural_children()
    |> Enum.reduce_while({:ok, new_acc()}, fn
      {"IndexDocument", _attrs, children}, {:ok, acc} ->
        put_once(acc, :index_document, parse_index_document(children))

      {"ErrorDocument", _attrs, children}, {:ok, acc} ->
        put_once(acc, :error_document, parse_error_document(children))

      {"RedirectAllRequestsTo", _attrs, children}, {:ok, acc} ->
        put_once(acc, :redirect_all_requests_to, parse_redirect_all(children))

      {"RoutingRules", _attrs, children}, {:ok, acc} ->
        put_once(acc, :routing_rules, parse_routing_rules(children))

      _other, _acc ->
        {:halt, :error}
    end)
    |> case do
      {:ok, acc} -> {:ok, normalize_config(acc)}
      :error -> {:error, :malformed_xml}
    end
  end

  defp parse_index_document(children) do
    case XMLTree.structural_children(children) do
      [{"Suffix", _attrs, children}] ->
        with {:ok, value} <- leaf_text(children) do
          {:ok, %{"suffix" => value}}
        end

      _other ->
        :error
    end
  end

  defp parse_error_document(children) do
    case XMLTree.structural_children(children) do
      [{"Key", _attrs, children}] ->
        with {:ok, value} <- leaf_text(children) do
          {:ok, %{"key" => value}}
        end

      _other ->
        :error
    end
  end

  defp parse_redirect_all(children) do
    parse_unique_fields(children, ~w(HostName Protocol), fn
      "HostName", value -> {"host_name", value}
      "Protocol", value -> {"protocol", value}
    end)
  end

  defp parse_routing_rules(children) do
    children
    |> XMLTree.structural_children()
    |> Enum.reduce_while({:ok, []}, fn
      {"RoutingRule", _attrs, children}, {:ok, rules} ->
        case parse_routing_rule(children) do
          {:ok, rule} -> {:cont, {:ok, rules ++ [rule]}}
          :error -> {:halt, :error}
        end

      _other, _acc ->
        {:halt, :error}
    end)
    |> case do
      {:ok, rules} -> {:ok, rules}
      :error -> :error
    end
  end

  defp parse_routing_rule(children) do
    children
    |> XMLTree.structural_children()
    |> Enum.reduce_while({:ok, %{condition: @unset, redirect: @unset}}, fn
      {"Condition", _attrs, children}, {:ok, rule} ->
        put_once(rule, :condition, parse_condition(children))

      {"Redirect", _attrs, children}, {:ok, rule} ->
        put_once(rule, :redirect, parse_redirect(children))

      _other, _acc ->
        {:halt, :error}
    end)
    |> case do
      {:ok, rule} ->
        {:ok,
         %{
           "condition" => normalize_optional(rule.condition),
           "redirect" => normalize_optional(rule.redirect)
         }}

      :error ->
        :error
    end
  end

  defp parse_condition(children) do
    parse_unique_fields(children, ~w(HttpErrorCodeReturnedEquals KeyPrefixEquals), fn
      "HttpErrorCodeReturnedEquals", value -> {"http_error_code_returned_equals", value}
      "KeyPrefixEquals", value -> {"key_prefix_equals", value}
    end)
  end

  defp parse_redirect(children) do
    parse_unique_fields(
      children,
      ~w(HostName Protocol ReplaceKeyPrefixWith ReplaceKeyWith HttpRedirectCode),
      fn
        "HostName", value -> {"host_name", value}
        "Protocol", value -> {"protocol", value}
        "ReplaceKeyPrefixWith", value -> {"replace_key_prefix_with", value}
        "ReplaceKeyWith", value -> {"replace_key_with", value}
        "HttpRedirectCode", value -> {"http_redirect_code", value}
      end
    )
  end

  defp parse_unique_fields(children, allowed_tags, mapper) do
    children
    |> XMLTree.structural_children()
    |> Enum.reduce_while({:ok, Map.new(allowed_tags, &{&1, @unset})}, fn
      {tag, _attrs, children}, {:ok, acc} ->
        if tag in allowed_tags do
          case leaf_text(children) do
            {:ok, value} ->
              if Map.fetch!(acc, tag) == @unset do
                {:cont, {:ok, Map.put(acc, tag, value)}}
              else
                {:halt, :error}
              end

            :error ->
              {:halt, :error}
          end
        else
          {:halt, :error}
        end

      _other, _acc ->
        {:halt, :error}
    end)
    |> case do
      {:ok, acc} ->
        {:ok,
         acc
         |> Enum.reject(&match?({_key, @unset}, &1))
         |> Map.new(fn {tag, value} -> mapper.(tag, value) end)}

      :error ->
        :error
    end
  end

  defp leaf_text(children), do: XMLTree.text(children, trim: true)

  defp put_once(map, key, {:ok, value}) do
    if Map.fetch!(map, key) == @unset do
      {:cont, {:ok, Map.put(map, key, value)}}
    else
      {:halt, :error}
    end
  end

  defp put_once(_map, _key, :error), do: {:halt, :error}

  defp normalize_config(acc) do
    new_config()
    |> Map.put("index_document", normalize_optional(acc.index_document))
    |> Map.put("error_document", normalize_optional(acc.error_document))
    |> Map.put("redirect_all_requests_to", normalize_optional(acc.redirect_all_requests_to))
    |> Map.put("routing_rules", if(acc.routing_rules == @unset, do: [], else: acc.routing_rules))
  end

  defp normalize_optional(@unset), do: nil
  defp normalize_optional(value), do: value
end
