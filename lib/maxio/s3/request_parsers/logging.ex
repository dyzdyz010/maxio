defmodule Maxio.S3.RequestParsers.Logging do
  @moduledoc """
  Strict PutBucketLogging BucketLoggingStatus XML parser.

  The parser owns XML shape, duplicate-field, and scalar syntax validation. The
  `Maxio.S3.Logging` domain module still owns normalized storage semantics and
  target grant ACL compatibility checks.
  """

  alias Maxio.S3.Logging
  alias Maxio.S3.RequestParsers.XMLTree

  @unset {:__maxio_logging_unset__, []}

  @spec parse(binary()) :: {:ok, map()} | {:error, :malformed_xml}
  def parse(xml) when is_binary(xml) do
    with {:ok, {"BucketLoggingStatus", _attrs, children}} <- XMLTree.parse(xml),
         {:ok, config} <- parse_config(children),
         {:ok, config} <- Logging.validate_client_config(config) do
      {:ok, config}
    else
      _other -> {:error, :malformed_xml}
    end
  end

  defp parse_config(children) do
    case XMLTree.structural_children(children) do
      [] ->
        {:ok, Logging.empty()}

      [{"LoggingEnabled", _attrs, children}] ->
        with {:ok, enabled} <- parse_enabled(children) do
          {:ok, %{"LoggingEnabled" => enabled}}
        end

      _other ->
        :error
    end
  end

  defp parse_enabled(children) do
    initial = %{
      "TargetBucket" => @unset,
      "TargetPrefix" => @unset,
      "TargetGrants" => @unset,
      "TargetObjectKeyFormat" => @unset
    }

    children
    |> XMLTree.structural_children()
    |> Enum.reduce_while({:ok, initial}, fn
      {"TargetBucket", _attrs, children}, {:ok, enabled} ->
        put_once(enabled, "TargetBucket", required_text(children))

      {"TargetPrefix", _attrs, children}, {:ok, enabled} ->
        put_once(enabled, "TargetPrefix", text(children))

      {"TargetGrants", _attrs, children}, {:ok, enabled} ->
        with {:ok, grants} <- parse_target_grants(children) do
          put_once(enabled, "TargetGrants", {:ok, grants})
        else
          _other -> {:halt, :error}
        end

      {"TargetObjectKeyFormat", _attrs, children}, {:ok, enabled} ->
        with {:ok, format} <- parse_target_object_key_format(children) do
          put_once(enabled, "TargetObjectKeyFormat", {:ok, format})
        else
          _other -> {:halt, :error}
        end

      _other, _acc ->
        {:halt, :error}
    end)
    |> case do
      {:ok, enabled} -> complete_enabled(enabled)
      :error -> :error
    end
  end

  defp complete_enabled(%{"TargetBucket" => @unset}), do: :error
  defp complete_enabled(%{"TargetPrefix" => @unset}), do: :error

  defp complete_enabled(enabled) do
    {:ok,
     %{
       "TargetBucket" => enabled["TargetBucket"],
       "TargetPrefix" => enabled["TargetPrefix"],
       "TargetGrants" => default_unset(enabled["TargetGrants"], []),
       "TargetObjectKeyFormat" =>
         default_unset(enabled["TargetObjectKeyFormat"], %{"type" => "simple"})
     }}
  end

  defp parse_target_grants(children) do
    children
    |> XMLTree.structural_children()
    |> Enum.reduce_while({:ok, []}, fn
      {"Grant", _attrs, children}, {:ok, grants} ->
        case parse_grant(children) do
          {:ok, grant} -> {:cont, {:ok, grants ++ [grant]}}
          :error -> {:halt, :error}
        end

      _other, _acc ->
        {:halt, :error}
    end)
    |> case do
      {:ok, grants} when grants != [] -> {:ok, grants}
      _other -> :error
    end
  end

  defp parse_grant(children) do
    initial = %{"Grantee" => @unset, "Permission" => @unset}

    children
    |> XMLTree.structural_children()
    |> Enum.reduce_while({:ok, initial}, fn
      {"Grantee", attrs, children}, {:ok, grant} ->
        with {:ok, grantee} <- parse_grantee(attrs, children) do
          put_once(grant, "Grantee", {:ok, grantee})
        else
          _other -> {:halt, :error}
        end

      {"Permission", _attrs, children}, {:ok, grant} ->
        put_once(grant, "Permission", permission(children))

      _other, _acc ->
        {:halt, :error}
    end)
    |> case do
      {:ok, %{"Grantee" => grantee, "Permission" => permission}}
      when grantee != @unset and permission != @unset ->
        {:ok, %{"Grantee" => grantee, "Permission" => permission}}

      _other ->
        :error
    end
  end

  defp parse_grantee(attrs, children) do
    case attr(attrs, "type") do
      "CanonicalUser" -> parse_canonical_grantee(children)
      "Group" -> parse_group_grantee(children)
      _other -> :error
    end
  end

  defp parse_canonical_grantee(children) do
    initial = %{"ID" => @unset, "DisplayName" => @unset}

    children
    |> XMLTree.structural_children()
    |> Enum.reduce_while({:ok, initial}, fn
      {"ID", _attrs, children}, {:ok, grantee} ->
        put_once(grantee, "ID", required_text(children))

      {"DisplayName", _attrs, children}, {:ok, grantee} ->
        put_once(grantee, "DisplayName", optional_text(children))

      _other, _acc ->
        {:halt, :error}
    end)
    |> case do
      {:ok, %{"ID" => id, "DisplayName" => display_name}} when id != @unset ->
        {:ok,
         %{"type" => "CanonicalUser", "ID" => id}
         |> maybe_put("DisplayName", display_name)}

      _other ->
        :error
    end
  end

  defp parse_group_grantee(children) do
    initial = %{"URI" => @unset}

    children
    |> XMLTree.structural_children()
    |> Enum.reduce_while({:ok, initial}, fn
      {"URI", _attrs, children}, {:ok, grantee} ->
        put_once(grantee, "URI", required_text(children))

      _other, _acc ->
        {:halt, :error}
    end)
    |> case do
      {:ok, %{"URI" => uri}} when uri != @unset ->
        {:ok, %{"type" => "Group", "URI" => uri}}

      _other ->
        :error
    end
  end

  defp parse_target_object_key_format(children) do
    case XMLTree.structural_children(children) do
      [{"SimplePrefix", _attrs, children}] ->
        parse_simple_prefix(children)

      [{"PartitionedPrefix", _attrs, children}] ->
        parse_partitioned_prefix(children)

      _other ->
        :error
    end
  end

  defp parse_simple_prefix(children) do
    case XMLTree.structural_children(children) do
      [] -> {:ok, %{"type" => "simple"}}
      _other -> :error
    end
  end

  defp parse_partitioned_prefix(children) do
    initial = %{"partition_date_source" => @unset}

    children
    |> XMLTree.structural_children()
    |> Enum.reduce_while({:ok, initial}, fn
      {"PartitionDateSource", _attrs, children}, {:ok, format} ->
        put_once(format, "partition_date_source", partition_date_source(children))

      _other, _acc ->
        {:halt, :error}
    end)
    |> case do
      {:ok, format} ->
        {:ok,
         %{
           "type" => "partitioned",
           "partition_date_source" => default_unset(format["partition_date_source"], nil)
         }}

      :error ->
        :error
    end
  end

  defp put_once(map, key, {:ok, value}) do
    case put_once_value(map, key, value) do
      {:ok, map} -> {:cont, {:ok, map}}
      :error -> {:halt, :error}
    end
  end

  defp put_once(_map, _key, :error), do: {:halt, :error}

  defp put_once_value(map, key, value) do
    if Map.fetch!(map, key) == @unset do
      {:ok, Map.put(map, key, value)}
    else
      :error
    end
  end

  defp permission(children) do
    with {:ok, value} <- required_text(children),
         true <- Logging.valid_permission?(value) do
      {:ok, value}
    else
      _other -> :error
    end
  end

  defp partition_date_source(children) do
    with {:ok, value} <- required_text(children),
         true <- Logging.valid_partition_date_source?(value) do
      {:ok, value}
    else
      _other -> :error
    end
  end

  defp attr(attrs, name) do
    Enum.find_value(attrs, fn
      {^name, value} -> value
      _other -> nil
    end)
  end

  defp default_unset(@unset, default), do: default
  defp default_unset(value, _default), do: value

  defp text(children), do: XMLTree.text(children)
  defp required_text(children), do: XMLTree.required_text(children, trim: true)

  defp optional_text(children) do
    case XMLTree.text(children, trim: true) do
      {:ok, ""} -> {:ok, nil}
      other -> other
    end
  end

  defp maybe_put(map, _key, @unset), do: map
  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
