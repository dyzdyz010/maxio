defmodule Maxio.S3.RequestParsers.Encryption do
  @moduledoc "PutBucketEncryption ServerSideEncryptionConfiguration XML parser."

  alias Maxio.S3.RequestParsers.XMLTree

  @unset {:__maxio_encryption_unset__, []}

  @type result :: %{
          algorithm: String.t() | nil,
          kms_key_id: String.t() | nil,
          bucket_key_enabled: boolean(),
          blocked_encryption_types: [String.t()],
          unsupported_multiple_rules?: boolean()
        }

  @spec parse(binary()) :: {:ok, result()} | {:error, :malformed_xml}
  def parse(xml) when is_binary(xml) do
    case XMLTree.parse(xml) do
      {:ok, {"ServerSideEncryptionConfiguration", _attrs, children}} ->
        build_config(children)

      _other ->
        {:error, :malformed_xml}
    end
  end

  defp build_config(children) do
    children = XMLTree.structural_children(children)

    if children != [] and Enum.all?(children, &match?({"Rule", _attrs, _children}, &1)) do
      parse_rules(children)
    else
      {:error, :malformed_xml}
    end
  end

  defp parse_rules([{"Rule", _attrs, children}]) do
    with {:ok, rule} <- parse_rule(children) do
      {:ok, rule}
    else
      :error -> {:error, :malformed_xml}
    end
  end

  defp parse_rules(rules) when length(rules) > 1 do
    {:ok,
     %{
       algorithm: nil,
       kms_key_id: nil,
       bucket_key_enabled: false,
       blocked_encryption_types: [],
       unsupported_multiple_rules?: true
     }}
  end

  defp parse_rule(children) do
    children
    |> XMLTree.structural_children()
    |> Enum.reduce_while(
      {:ok,
       %{
         apply_default: @unset,
         bucket_key_enabled: @unset,
         blocked_encryption_types: @unset
       }},
      fn
        {"ApplyServerSideEncryptionByDefault", _attrs, children}, {:ok, rule} ->
          put_once(rule, :apply_default, parse_apply_default(children))

        {"BucketKeyEnabled", _attrs, children}, {:ok, rule} ->
          put_once(rule, :bucket_key_enabled, parse_boolean(children))

        {"BlockedEncryptionTypes", _attrs, children}, {:ok, rule} ->
          put_once(rule, :blocked_encryption_types, parse_blocked_encryption_types(children))

        _other, _acc ->
          {:halt, :error}
      end
    )
    |> case do
      {:ok, rule} -> normalize_rule(rule)
      :error -> :error
    end
  end

  defp parse_apply_default(children) do
    children
    |> XMLTree.structural_children()
    |> Enum.reduce_while({:ok, %{algorithm: @unset, kms_key_id: @unset}}, fn
      {"SSEAlgorithm", _attrs, children}, {:ok, config} ->
        put_once(config, :algorithm, XMLTree.required_text(children, trim: true))

      {tag, _attrs, children}, {:ok, config} when tag in ["KMSMasterKeyID", "KMSKeyID"] ->
        put_once(config, :kms_key_id, XMLTree.text(children, trim: true))

      _other, _acc ->
        {:halt, :error}
    end)
    |> case do
      {:ok, config} ->
        config = normalize_unset_fields(config)

        if is_binary(config.algorithm) do
          {:ok, config}
        else
          :error
        end

      :error ->
        :error
    end
  end

  defp parse_blocked_encryption_types(children) do
    children
    |> XMLTree.structural_children()
    |> Enum.reduce_while({:ok, []}, fn
      {"EncryptionType", _attrs, children}, {:ok, values} ->
        case XMLTree.required_text(children, trim: true) do
          {:ok, value} -> {:cont, {:ok, values ++ [value]}}
          :error -> {:halt, :error}
        end

      _other, _acc ->
        {:halt, :error}
    end)
    |> case do
      {:ok, [_ | _] = values} -> {:ok, values}
      _other -> :error
    end
  end

  defp parse_boolean(children) do
    case XMLTree.required_text(children, trim: true) do
      {:ok, "true"} -> {:ok, true}
      {:ok, "false"} -> {:ok, false}
      _other -> :error
    end
  end

  defp normalize_rule(rule) do
    apply_default = Map.get(rule, :apply_default)
    blocked = Map.get(rule, :blocked_encryption_types)

    cond do
      apply_default == @unset and blocked == @unset ->
        :error

      true ->
        apply_default = if apply_default == @unset, do: %{}, else: apply_default
        normalized = normalize_unset_fields(rule)

        {:ok,
         %{
           algorithm: Map.get(apply_default, :algorithm),
           kms_key_id: Map.get(apply_default, :kms_key_id),
           bucket_key_enabled: normalized.bucket_key_enabled || false,
           blocked_encryption_types: normalized.blocked_encryption_types || [],
           unsupported_multiple_rules?: false
         }}
    end
  end

  defp put_once(map, :apply_default, {:ok, values}) do
    if map.apply_default == @unset do
      {:cont, {:ok, Map.put(map, :apply_default, values)}}
    else
      {:halt, :error}
    end
  end

  defp put_once(map, key, {:ok, value}) do
    if Map.fetch!(map, key) == @unset do
      {:cont, {:ok, Map.put(map, key, value)}}
    else
      {:halt, :error}
    end
  end

  defp put_once(_map, _key, :error), do: {:halt, :error}

  defp normalize_unset_fields(map) do
    Map.new(map, fn
      {key, @unset} -> {key, nil}
      {key, value} -> {key, value}
    end)
  end
end
