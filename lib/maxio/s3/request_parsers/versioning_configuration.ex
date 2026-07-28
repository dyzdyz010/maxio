defmodule Maxio.S3.RequestParsers.VersioningConfiguration do
  @moduledoc "PutBucketVersioning VersioningConfiguration XML parser."

  alias Maxio.S3.RequestParsers.XMLTree

  @unset {:__maxio_versioning_unset__, []}

  @spec parse(binary()) ::
          {:ok, %{status: String.t() | nil, mfa_delete: String.t() | nil}}
          | {:error, :malformed_xml}
  def parse(xml) when is_binary(xml) do
    with {:ok, {"VersioningConfiguration", _attrs, children}} <- XMLTree.parse(xml),
         {:ok, %{status: status, mfa_delete: mfa_delete}} <- build_config(children),
         :ok <- validate(status, ["Enabled", "Suspended"]),
         :ok <- validate(mfa_delete, ["Enabled", "Disabled"]) do
      {:ok, %{status: status, mfa_delete: mfa_delete}}
    else
      _other -> {:error, :malformed_xml}
    end
  end

  defp build_config(children) do
    children
    |> XMLTree.structural_children()
    |> Enum.reduce_while({:ok, %{status: @unset, mfa_delete: @unset}}, fn
      {"Status", _attrs, children}, {:ok, config} ->
        put_once(config, :status, XMLTree.required_text(children, trim: true))

      {"MfaDelete", _attrs, children}, {:ok, config} ->
        put_once(config, :mfa_delete, XMLTree.required_text(children, trim: true))

      _other, _acc ->
        {:halt, :error}
    end)
    |> case do
      {:ok, config} ->
        {:ok,
         %{
           status: normalize_unset(config.status),
           mfa_delete: normalize_unset(config.mfa_delete)
         }}

      :error ->
        :error
    end
  end

  defp validate(nil, _allowed), do: :ok

  defp validate(value, allowed) when is_binary(value),
    do: if(value in allowed, do: :ok, else: :error)

  defp put_once(map, key, {:ok, value}) do
    if Map.fetch!(map, key) == @unset do
      {:cont, {:ok, Map.put(map, key, value)}}
    else
      {:halt, :error}
    end
  end

  defp put_once(_map, _key, :error), do: {:halt, :error}

  defp normalize_unset(@unset), do: nil
  defp normalize_unset(value), do: value
end
