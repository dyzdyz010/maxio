defmodule Maxio.S3.RequestParsers.ObjectLock do
  @moduledoc "PutBucketObjectLockConfiguration ObjectLockConfiguration XML parser."

  alias Maxio.S3.ObjectLock
  alias Maxio.S3.RequestParsers.XMLTree

  @unset {:__maxio_object_lock_unset__, []}

  @spec parse(binary()) :: {:ok, map()} | {:error, :malformed_xml}
  def parse(xml) when is_binary(xml) do
    with {:ok, {"ObjectLockConfiguration", _attrs, children}} <- XMLTree.parse(xml),
         {:ok, config} <- build_config(children) do
      {:ok, config}
    else
      _other -> {:error, :malformed_xml}
    end
  end

  @spec parse_retention(binary()) :: {:ok, map()} | {:error, :malformed_xml}
  def parse_retention(xml) when is_binary(xml) do
    with {:ok, {"Retention", _attrs, children}} <- XMLTree.parse(xml),
         {:ok, retention} <- build_retention(children) do
      {:ok, retention}
    else
      _other -> {:error, :malformed_xml}
    end
  end

  @spec parse_legal_hold(binary()) :: {:ok, map()} | {:error, :malformed_xml}
  def parse_legal_hold(xml) when is_binary(xml) do
    with {:ok, {"LegalHold", _attrs, children}} <- XMLTree.parse(xml),
         {:ok, legal_hold} <- build_legal_hold(children) do
      {:ok, legal_hold}
    else
      _other -> {:error, :malformed_xml}
    end
  end

  defp build_config(children) do
    children
    |> XMLTree.structural_children()
    |> Enum.reduce_while({:ok, %{"ObjectLockEnabled" => @unset, "Rule" => @unset}}, fn
      {"ObjectLockEnabled", _attrs, children}, {:ok, config} ->
        put_once(config, "ObjectLockEnabled", required_text(children))

      {"Rule", _attrs, children}, {:ok, config} ->
        with {:ok, rule} <- parse_rule(children),
             {:cont, {:ok, config}} <- put_once(config, "Rule", {:ok, rule}) do
          {:cont, {:ok, config}}
        else
          _other -> {:halt, :error}
        end

      _other, _acc ->
        {:halt, :error}
    end)
    |> case do
      {:ok, config} ->
        config = normalize_unset_fields(config)

        case ObjectLock.validate_client_config(config) do
          {:ok, config} -> {:ok, config}
          {:error, :malformed_xml} -> {:error, :malformed_xml}
        end

      :error ->
        {:error, :malformed_xml}
    end
  end

  defp parse_rule(children) do
    children
    |> XMLTree.structural_children()
    |> Enum.reduce_while({:ok, %{"DefaultRetention" => @unset}}, fn
      {"DefaultRetention", _attrs, children}, {:ok, rule} ->
        with {:ok, retention} <- parse_default_retention(children),
             {:cont, {:ok, rule}} <- put_once(rule, "DefaultRetention", {:ok, retention}) do
          {:cont, {:ok, rule}}
        else
          _other -> {:halt, :error}
        end

      _other, _acc ->
        {:halt, :error}
    end)
    |> normalize_result()
  end

  defp parse_default_retention(children) do
    children
    |> XMLTree.structural_children()
    |> Enum.reduce_while({:ok, %{"Mode" => @unset, "Days" => @unset, "Years" => @unset}}, fn
      {"Mode", _attrs, children}, {:ok, retention} ->
        put_once(retention, "Mode", mode_text(children))

      {"Days", _attrs, children}, {:ok, retention} ->
        put_once(retention, "Days", required_text(children))

      {"Years", _attrs, children}, {:ok, retention} ->
        put_once(retention, "Years", required_text(children))

      _other, _acc ->
        {:halt, :error}
    end)
    |> normalize_result()
  end

  defp build_retention(children) do
    children
    |> XMLTree.structural_children()
    |> Enum.reduce_while({:ok, %{"Mode" => @unset, "RetainUntilDate" => @unset}}, fn
      {"Mode", _attrs, children}, {:ok, retention} ->
        put_once(retention, "Mode", mode_text(children))

      {"RetainUntilDate", _attrs, children}, {:ok, retention} ->
        put_once(retention, "RetainUntilDate", required_text(children))

      _other, _acc ->
        {:halt, :error}
    end)
    |> normalize_result()
    |> case do
      {:ok, retention} ->
        try do
          {:ok, ObjectLock.normalize_object_retention(retention)}
        rescue
          _err -> {:error, :malformed_xml}
        end

      :error ->
        {:error, :malformed_xml}
    end
  end

  defp build_legal_hold(children) do
    children
    |> XMLTree.structural_children()
    |> Enum.reduce_while({:ok, %{"Status" => @unset}}, fn
      {"Status", _attrs, children}, {:ok, legal_hold} ->
        put_once(legal_hold, "Status", legal_hold_status_text(children))

      _other, _acc ->
        {:halt, :error}
    end)
    |> normalize_result()
    |> case do
      {:ok, legal_hold} ->
        try do
          {:ok, ObjectLock.normalize_object_legal_hold(legal_hold)}
        rescue
          _err -> {:error, :malformed_xml}
        end

      :error ->
        {:error, :malformed_xml}
    end
  end

  defp normalize_result({:ok, value}), do: {:ok, normalize_unset_fields(value)}
  defp normalize_result(:error), do: :error

  defp normalize_unset_fields(map) do
    Map.new(map, fn
      {key, @unset} -> {key, nil}
      {key, value} -> {key, value}
    end)
  end

  defp put_once(map, key, {:ok, value}) do
    if Map.fetch!(map, key) == @unset do
      {:cont, {:ok, Map.put(map, key, value)}}
    else
      {:halt, :error}
    end
  end

  defp put_once(_map, _key, :error), do: {:halt, :error}

  defp required_text(children), do: XMLTree.required_text(children, trim: true)

  defp mode_text(children) do
    case required_text(children) do
      {:ok, mode} when mode in ["GOVERNANCE", "COMPLIANCE"] -> {:ok, mode}
      _other -> :error
    end
  end

  defp legal_hold_status_text(children) do
    case required_text(children) do
      {:ok, status} when status in ["ON", "OFF"] -> {:ok, status}
      _other -> :error
    end
  end
end
