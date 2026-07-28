defmodule Maxio.S3.AWSQueryAttributesParser do
  @moduledoc """
  Parses AWS Query API responses that return an `Attributes` entry list.

  SNS `GetTopicAttributes` uses this shape:

      <Attributes>
        <entry><key>Policy</key><value>{...}</value></entry>
      </Attributes>
  """

  @behaviour Saxy.Handler

  @spec parse(String.t()) :: {:ok, map()} | {:error, term()}
  def parse(xml) when is_binary(xml) do
    state = %{
      stack: [],
      text: "",
      key: nil,
      value: nil,
      attributes: %{}
    }

    case Saxy.parse_string(xml, __MODULE__, state) do
      {:ok, %{attributes: attributes}} -> {:ok, attributes}
      {:error, reason} -> {:error, {:bad_aws_query_xml, reason}}
    end
  end

  @impl true
  def handle_event(:start_element, {name, _attrs}, state) do
    {:ok, %{state | stack: [local_name(name) | state.stack], text: ""}}
  end

  @impl true
  def handle_event(:characters, chars, state) do
    case state.stack do
      ["key" | _rest] -> {:ok, %{state | text: state.text <> chars}}
      ["value" | _rest] -> {:ok, %{state | text: state.text <> chars}}
      _other -> {:ok, state}
    end
  end

  @impl true
  def handle_event(:end_element, name, state) do
    tag = local_name(name)
    text = String.trim(state.text)

    state =
      case tag do
        "key" ->
          %{state | key: text, text: ""}

        "value" ->
          %{state | value: text, text: ""}

        "entry" ->
          put_entry(state)

        _other ->
          %{state | text: ""}
      end

    {:ok, %{state | stack: tl(state.stack)}}
  end

  @impl true
  def handle_event(:start_document, _prolog, state), do: {:ok, state}

  @impl true
  def handle_event(:end_document, _data, state), do: {:ok, state}

  defp put_entry(%{key: key, value: value, attributes: attributes} = state)
       when is_binary(key) and key != "" and is_binary(value) do
    %{state | key: nil, value: nil, attributes: Map.put(attributes, key, value), text: ""}
  end

  defp put_entry(state), do: %{state | key: nil, value: nil, text: ""}

  defp local_name({_, name}), do: to_string(name)
  defp local_name(name), do: to_string(name)
end
