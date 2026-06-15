defmodule Maxio.S3.RequestParsers.Accelerate do
  @moduledoc "PutBucketAccelerateConfiguration XML parser."
  @behaviour Saxy.Handler

  alias Maxio.S3.Accelerate

  @spec parse(binary()) :: {:ok, map()} | {:error, :malformed_xml}
  def parse(xml) when is_binary(xml) do
    init = %{
      root?: false,
      status: nil,
      status_seen?: false,
      path: [],
      in: nil,
      text: nil,
      invalid?: false
    }

    case Saxy.parse_string(xml, __MODULE__, init) do
      {:ok, %{root?: true, invalid?: false, status_seen?: false}} ->
        {:ok, %{"Status" => nil}}

      {:ok, %{root?: true, invalid?: false, status: status}} ->
        if Accelerate.valid_status?(status) do
          {:ok, %{"Status" => status}}
        else
          {:error, :malformed_xml}
        end

      _other ->
        {:error, :malformed_xml}
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
      parent_path == [] and tag == "AccelerateConfiguration" ->
        {:ok, %{state | root?: true}}

      parent_path == [] ->
        {:ok, invalid(state)}

      tag == "AccelerateConfiguration" ->
        {:ok, invalid(state)}

      tag == "Status" and parent_path == ["AccelerateConfiguration"] ->
        {:ok, %{state | in: :status, text: ""}}

      tag == "Status" ->
        {:ok, invalid(state)}

      true ->
        {:ok, invalid(state)}
    end
  end

  @impl true
  def handle_event(:characters, chars, %{text: text} = state) when is_binary(text),
    do: {:ok, %{state | text: text <> chars}}

  def handle_event(:characters, chars, state) do
    if String.trim(chars) == "" do
      {:ok, state}
    else
      {:ok, invalid(state)}
    end
  end

  @impl true
  def handle_event(:end_element, name, state) do
    tag = local(name)

    cond do
      tag == "Status" ->
        value = String.trim(state.text || "")

        cond do
          state.path != ["Status", "AccelerateConfiguration"] ->
            {:ok, state |> invalid() |> clear_text() |> pop_path()}

          state.status_seen? ->
            {:ok, state |> invalid() |> clear_text() |> pop_path()}

          Accelerate.valid_status?(value) ->
            {:ok,
             state
             |> Map.put(:status, value)
             |> Map.put(:status_seen?, true)
             |> clear_text()
             |> pop_path()}

          true ->
            {:ok, state |> invalid() |> clear_text() |> pop_path()}
        end

      true ->
        {:ok, state |> clear_text() |> pop_path()}
    end
  end

  @impl true
  def handle_event(:end_document, _data, state), do: {:ok, state}

  defp clear_text(state), do: %{state | in: nil, text: nil}

  defp pop_path(%{path: []} = state), do: state
  defp pop_path(%{path: [_tag | rest]} = state), do: %{state | path: rest}

  defp invalid(state), do: %{state | invalid?: true, in: nil, text: nil}

  defp local(name) do
    case String.split(name, ":") do
      [_namespace, local] -> local
      [local] -> local
    end
  end
end
