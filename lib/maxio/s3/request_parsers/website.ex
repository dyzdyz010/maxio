defmodule Maxio.S3.RequestParsers.Website do
  @moduledoc "PutBucketWebsite WebsiteConfiguration XML parser."
  @behaviour Saxy.Handler

  @type config :: map()

  @leaf_tags ~w(Suffix Key HostName Protocol HttpErrorCodeReturnedEquals KeyPrefixEquals
                ReplaceKeyPrefixWith ReplaceKeyWith HttpRedirectCode)

  @spec parse(binary()) :: {:ok, config()} | {:error, :malformed_xml}
  def parse(xml) when is_binary(xml) do
    init = %{
      root?: false,
      config: new_config(),
      current_rule: nil,
      routing_rule_depth: 0,
      path: [],
      in: nil,
      text: nil,
      invalid?: false
    }

    case Saxy.parse_string(xml, __MODULE__, init) do
      {:ok, %{root?: true, invalid?: false, config: config}} -> {:ok, config}
      _other -> {:error, :malformed_xml}
    end
  end

  @impl true
  def handle_event(:start_document, _prolog, state), do: {:ok, state}

  @impl true
  def handle_event(:start_element, {name, _attrs}, state) do
    tag = local(name)
    parent_path = state.path
    state = %{state | path: [tag | parent_path], in: nil, text: nil}

    cond do
      parent_path == [] and tag == "WebsiteConfiguration" ->
        {:ok, %{state | root?: true}}

      parent_path == [] ->
        {:ok, invalid(state)}

      tag == "WebsiteConfiguration" ->
        {:ok, invalid(state)}

      tag in ~w(IndexDocument ErrorDocument RedirectAllRequestsTo RoutingRules) ->
        if parent_path == ["WebsiteConfiguration"] do
          {:ok, state}
        else
          {:ok, invalid(state)}
        end

      tag == "RoutingRule" ->
        if parent_path == ["RoutingRules", "WebsiteConfiguration"] do
          {:ok,
           %{
             state
             | current_rule: new_rule(),
               routing_rule_depth: state.routing_rule_depth + 1
           }}
        else
          {:ok, invalid(state)}
        end

      tag == "Condition" and is_map(state.current_rule) ->
        if parent_path == ["RoutingRule", "RoutingRules", "WebsiteConfiguration"] do
          {:ok, %{state | current_rule: put_new_section(state.current_rule, "condition")}}
        else
          {:ok, invalid(state)}
        end

      tag == "Redirect" and is_map(state.current_rule) ->
        if parent_path == ["RoutingRule", "RoutingRules", "WebsiteConfiguration"] do
          {:ok, %{state | current_rule: put_new_section(state.current_rule, "redirect")}}
        else
          {:ok, invalid(state)}
        end

      tag in ~w(Condition Redirect) ->
        {:ok, invalid(state)}

      tag in @leaf_tags ->
        if valid_leaf_parent?(tag, parent_path) do
          {:ok, %{state | in: tag, text: ""}}
        else
          {:ok, invalid(state)}
        end

      true ->
        {:ok, state}
    end
  end

  @impl true
  def handle_event(:characters, chars, %{text: text} = state) when is_binary(text),
    do: {:ok, %{state | text: text <> chars}}

  def handle_event(:characters, _chars, state), do: {:ok, state}

  @impl true
  def handle_event(:end_element, name, state) do
    tag = local(name)

    cond do
      tag in @leaf_tags ->
        value = trim(state.text)

        {:ok,
         state
         |> store_leaf(tag, value)
         |> clear_text()
         |> pop_path()}

      tag == "RoutingRule" ->
        {:ok,
         state
         |> append_current_rule()
         |> Map.update!(:routing_rule_depth, &max(&1 - 1, 0))
         |> Map.put(:current_rule, nil)
         |> clear_text()
         |> pop_path()}

      true ->
        {:ok, state |> clear_text() |> pop_path()}
    end
  end

  @impl true
  def handle_event(:end_document, _data, state), do: {:ok, state}

  defp new_config do
    %{
      "index_document" => nil,
      "error_document" => nil,
      "redirect_all_requests_to" => nil,
      "routing_rules" => []
    }
  end

  defp new_rule do
    %{
      "condition" => nil,
      "redirect" => nil
    }
  end

  defp put_new_section(rule, section), do: Map.put(rule, section, Map.get(rule, section) || %{})

  defp store_leaf(
         %{path: ["Suffix", "IndexDocument", "WebsiteConfiguration"]} = state,
         "Suffix",
         value
       ),
       do: put_config_path(state, ["index_document", "suffix"], value)

  defp store_leaf(
         %{path: ["Key", "ErrorDocument", "WebsiteConfiguration"]} = state,
         "Key",
         value
       ),
       do: put_config_path(state, ["error_document", "key"], value)

  defp store_leaf(
         %{path: [_, "RedirectAllRequestsTo", "WebsiteConfiguration"]} = state,
         tag,
         value
       )
       when tag in ["HostName", "Protocol"] do
    put_config_path(state, ["redirect_all_requests_to", field_name(tag)], value)
  end

  defp store_leaf(
         %{
           path: [_, "Condition", "RoutingRule", "RoutingRules", "WebsiteConfiguration"],
           current_rule: rule
         } =
           state,
         tag,
         value
       )
       when is_map(rule) and tag in ["HttpErrorCodeReturnedEquals", "KeyPrefixEquals"] do
    put_rule_path(state, ["condition", field_name(tag)], value)
  end

  defp store_leaf(
         %{
           path: [_, "Redirect", "RoutingRule", "RoutingRules", "WebsiteConfiguration"],
           current_rule: rule
         } =
           state,
         tag,
         value
       )
       when is_map(rule) and
              tag in [
                "HostName",
                "Protocol",
                "ReplaceKeyPrefixWith",
                "ReplaceKeyWith",
                "HttpRedirectCode"
              ] do
    put_rule_path(state, ["redirect", field_name(tag)], value)
  end

  defp store_leaf(state, _tag, _value), do: state

  defp put_config_path(%{config: config} = state, [section, field], value) do
    section_value = Map.get(config, section) || %{}
    %{state | config: Map.put(config, section, Map.put(section_value, field, value))}
  end

  defp put_rule_path(%{current_rule: rule} = state, [section, field], value) do
    section_value = Map.get(rule, section) || %{}
    %{state | current_rule: Map.put(rule, section, Map.put(section_value, field, value))}
  end

  defp append_current_rule(%{current_rule: rule, config: config} = state) when is_map(rule) do
    rules = Map.get(config, "routing_rules", [])
    %{state | config: Map.put(config, "routing_rules", rules ++ [rule])}
  end

  defp append_current_rule(state), do: state

  defp clear_text(state), do: %{state | in: nil, text: nil}

  defp pop_path(%{path: []} = state), do: state
  defp pop_path(%{path: [_tag | rest]} = state), do: %{state | path: rest}

  defp field_name("HttpErrorCodeReturnedEquals"), do: "http_error_code_returned_equals"
  defp field_name("KeyPrefixEquals"), do: "key_prefix_equals"
  defp field_name("ReplaceKeyPrefixWith"), do: "replace_key_prefix_with"
  defp field_name("ReplaceKeyWith"), do: "replace_key_with"
  defp field_name("HttpRedirectCode"), do: "http_redirect_code"
  defp field_name("HostName"), do: "host_name"
  defp field_name("Protocol"), do: "protocol"

  defp valid_leaf_parent?("Suffix", path), do: path == ["IndexDocument", "WebsiteConfiguration"]
  defp valid_leaf_parent?("Key", path), do: path == ["ErrorDocument", "WebsiteConfiguration"]

  defp valid_leaf_parent?(tag, ["RedirectAllRequestsTo", "WebsiteConfiguration"]),
    do: tag in ["HostName", "Protocol"]

  defp valid_leaf_parent?(tag, [
         "Condition",
         "RoutingRule",
         "RoutingRules",
         "WebsiteConfiguration"
       ]),
       do: tag in ["HttpErrorCodeReturnedEquals", "KeyPrefixEquals"]

  defp valid_leaf_parent?(tag, ["Redirect", "RoutingRule", "RoutingRules", "WebsiteConfiguration"]),
       do:
         tag in [
           "HostName",
           "Protocol",
           "ReplaceKeyPrefixWith",
           "ReplaceKeyWith",
           "HttpRedirectCode"
         ]

  defp valid_leaf_parent?(_tag, _path), do: false

  defp invalid(state), do: %{state | invalid?: true, in: nil, text: nil}

  defp trim(nil), do: ""
  defp trim(text), do: String.trim(text)

  defp local(name) do
    case String.split(name, ":") do
      [_namespace, local] -> local
      [local] -> local
    end
  end
end
