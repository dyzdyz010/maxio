defmodule Maxio.S3.RequestParsers.RequestPayment do
  @moduledoc "PutBucketRequestPayment RequestPaymentConfiguration XML parser."
  @behaviour Saxy.Handler

  alias Maxio.S3.RequestPayment

  @spec parse(binary()) :: {:ok, map()} | {:error, :malformed_xml}
  def parse(xml) when is_binary(xml) do
    init = %{
      root?: false,
      payer: nil,
      path: [],
      in: nil,
      text: nil,
      invalid?: false
    }

    case Saxy.parse_string(xml, __MODULE__, init) do
      {:ok, %{root?: true, invalid?: false, payer: payer}} ->
        if RequestPayment.valid_payer?(payer) do
          {:ok, %{"Payer" => payer}}
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
      parent_path == [] and tag == "RequestPaymentConfiguration" ->
        {:ok, %{state | root?: true}}

      parent_path == [] ->
        {:ok, invalid(state)}

      tag == "RequestPaymentConfiguration" ->
        {:ok, invalid(state)}

      tag == "Payer" and parent_path == ["RequestPaymentConfiguration"] ->
        {:ok, %{state | in: :payer, text: ""}}

      tag == "Payer" ->
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
      tag == "Payer" ->
        value = String.trim(state.text || "")

        cond do
          state.path != ["Payer", "RequestPaymentConfiguration"] ->
            {:ok, state |> invalid() |> clear_text() |> pop_path()}

          is_binary(state.payer) ->
            {:ok, state |> invalid() |> clear_text() |> pop_path()}

          RequestPayment.valid_payer?(value) ->
            {:ok, state |> Map.put(:payer, value) |> clear_text() |> pop_path()}

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
