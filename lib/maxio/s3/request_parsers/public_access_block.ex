defmodule Maxio.S3.RequestParsers.PublicAccessBlock do
  @moduledoc """
  PutPublicAccessBlock XML parser.

  Parses PublicAccessBlockConfiguration with optional boolean children:
  BlockPublicAcls, IgnorePublicAcls, BlockPublicPolicy, RestrictPublicBuckets.
  Missing booleans default to false.
  """
  @behaviour Saxy.Handler

  alias Maxio.S3.PublicAccessBlock

  @keys ~w(BlockPublicAcls IgnorePublicAcls BlockPublicPolicy RestrictPublicBuckets)

  @spec parse(binary()) :: {:ok, map()} | {:error, :malformed_xml}
  def parse(xml) when is_binary(xml) do
    init = %{
      config: PublicAccessBlock.defaults(),
      root?: false,
      in: nil,
      text: nil,
      invalid?: false
    }

    case Saxy.parse_string(xml, __MODULE__, init) do
      {:ok, %{root?: true, invalid?: false, config: config}} -> {:ok, config}
      _ -> {:error, :malformed_xml}
    end
  end

  @impl true
  def handle_event(:start_document, _prolog, state), do: {:ok, state}

  @impl true
  def handle_event(:start_element, {name, _attrs}, state) do
    case local(name) do
      "PublicAccessBlockConfiguration" ->
        {:ok, %{state | root?: true, in: nil, text: nil}}

      key when key in @keys ->
        {:ok, %{state | in: key, text: ""}}

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
    key = local(name)

    if key in @keys and state.in == key do
      case parse_bool(state.text) do
        {:ok, value} ->
          {:ok,
           %{
             state
             | config: Map.put(state.config, key, value),
               in: nil,
               text: nil
           }}

        :error ->
          {:ok, %{state | invalid?: true, in: nil, text: nil}}
      end
    else
      {:ok, %{state | in: nil, text: nil}}
    end
  end

  @impl true
  def handle_event(:end_document, _data, state), do: {:ok, state}

  defp parse_bool(value) do
    case value |> to_string() |> String.trim() |> String.downcase() do
      "true" -> {:ok, true}
      "false" -> {:ok, false}
      _ -> :error
    end
  end

  defp local(name) do
    case String.split(name, ":") do
      [_ns, local] -> local
      [local] -> local
    end
  end
end
