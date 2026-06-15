defmodule Maxio.S3.RequestParsers.OwnershipControls do
  @moduledoc "PutBucketOwnershipControls XML parser."
  @behaviour Saxy.Handler

  alias Maxio.S3.OwnershipControls

  @values ~w(BucketOwnerEnforced BucketOwnerPreferred ObjectWriter)

  @spec parse(binary()) :: {:ok, map()} | {:error, :malformed_xml}
  def parse(xml) when is_binary(xml) do
    init = %{
      root?: false,
      rule_depth: 0,
      object_ownership: nil,
      in: nil,
      text: nil,
      invalid?: false
    }

    case Saxy.parse_string(xml, __MODULE__, init) do
      {:ok, %{root?: true, invalid?: false, object_ownership: value}} when value in @values ->
        {:ok, %{"ObjectOwnership" => value}}

      _ ->
        {:error, :malformed_xml}
    end
  end

  @impl true
  def handle_event(:start_document, _prolog, state), do: {:ok, state}

  @impl true
  def handle_event(:start_element, {name, _attrs}, state) do
    case local(name) do
      "OwnershipControls" ->
        {:ok, %{state | root?: true, in: nil, text: nil}}

      "Rule" ->
        {:ok, %{state | rule_depth: state.rule_depth + 1, in: nil, text: nil}}

      "ObjectOwnership" ->
        {:ok, %{state | in: :object_ownership, text: ""}}

      _other ->
        {:ok, %{state | in: nil, text: nil}}
    end
  end

  @impl true
  def handle_event(:characters, chars, %{text: text} = state) when is_binary(text),
    do: {:ok, %{state | text: text <> chars}}

  def handle_event(:characters, _chars, state), do: {:ok, state}

  @impl true
  def handle_event(:end_element, name, state) do
    case local(name) do
      "ObjectOwnership" ->
        value = String.trim(state.text || "")

        cond do
          state.rule_depth != 1 ->
            {:ok, %{state | invalid?: true, in: nil, text: nil}}

          is_binary(state.object_ownership) ->
            {:ok, %{state | invalid?: true, in: nil, text: nil}}

          OwnershipControls.valid_value?(value) ->
            {:ok, %{state | object_ownership: value, in: nil, text: nil}}

          true ->
            {:ok, %{state | invalid?: true, in: nil, text: nil}}
        end

      "Rule" ->
        {:ok, %{state | rule_depth: max(state.rule_depth - 1, 0), in: nil, text: nil}}

      _other ->
        {:ok, %{state | in: nil, text: nil}}
    end
  end

  @impl true
  def handle_event(:end_document, _data, state), do: {:ok, state}

  defp local(name) do
    case String.split(name, ":") do
      [_ns, local] -> local
      [local] -> local
    end
  end
end
