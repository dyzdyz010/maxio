defmodule Maxio.S3.RequestParsers.Replication do
  @moduledoc """
  Strict PutBucketReplication ReplicationConfiguration XML parser.

  The parser owns XML shape, duplicate-field, and scalar syntax validation. The
  `Maxio.S3.Replication` domain module still owns the cross-field S3 semantics
  and stores the normalized configuration contract.
  """

  alias Maxio.S3.Replication
  alias Maxio.S3.RequestParsers.XMLTree

  @unset {:__maxio_replication_unset__, []}
  @valid_statuses ~w(Enabled Disabled)
  @valid_storage_classes ~w(
    STANDARD REDUCED_REDUNDANCY STANDARD_IA ONEZONE_IA INTELLIGENT_TIERING
    GLACIER DEEP_ARCHIVE OUTPOSTS GLACIER_IR SNOW EXPRESS_ONEZONE FSX_ONTAP
  )

  @spec parse(binary()) :: {:ok, map()} | {:error, :malformed_xml}
  def parse(xml) when is_binary(xml) do
    with {:ok, {"ReplicationConfiguration", _attrs, children}} <- XMLTree.parse(xml),
         {:ok, config} <- parse_config(children),
         {:ok, config} <- Replication.validate_client_config(config) do
      {:ok, config}
    else
      _other -> {:error, :malformed_xml}
    end
  end

  defp parse_config(children) do
    children
    |> XMLTree.structural_children()
    |> Enum.reduce_while({:ok, %{"Rules" => []}, MapSet.new()}, fn
      {"Role", _attrs, children}, {:ok, config, seen} ->
        put_once(config, seen, :role, "Role", required_text(children))

      {"Rule", _attrs, children}, {:ok, config, seen} ->
        case parse_rule(children) do
          {:ok, rule} -> {:cont, {:ok, Map.update!(config, "Rules", &(&1 ++ [rule])), seen}}
          :error -> {:halt, :error}
        end

      _other, _acc ->
        {:halt, :error}
    end)
    |> unwrap_acc()
  end

  defp parse_rule(children) do
    children
    |> XMLTree.structural_children()
    |> Enum.reduce_while({:ok, %{}, MapSet.new()}, fn
      {"ID", _attrs, children}, {:ok, rule, seen} ->
        put_once(rule, seen, :id, "ID", required_text(children))

      {"Priority", _attrs, children}, {:ok, rule, seen} ->
        put_once(rule, seen, :priority, "Priority", integer(children))

      {"Prefix", _attrs, children}, {:ok, rule, seen} ->
        put_once(rule, seen, :prefix, "Prefix", text(children))

      {"Filter", _attrs, children}, {:ok, rule, seen} ->
        with {:ok, filter} <- parse_filter(children) do
          put_once(rule, seen, :filter, "Filter", {:ok, filter})
        else
          _other -> {:halt, :error}
        end

      {"Status", _attrs, children}, {:ok, rule, seen} ->
        put_once(rule, seen, :status, "Status", status(children))

      {"Destination", _attrs, children}, {:ok, rule, seen} ->
        with {:ok, destination} <- parse_destination(children) do
          put_once(rule, seen, :destination, "Destination", {:ok, destination})
        else
          _other -> {:halt, :error}
        end

      {"DeleteMarkerReplication", _attrs, children}, {:ok, rule, seen} ->
        parse_status_block(
          rule,
          seen,
          :delete_marker_replication,
          "DeleteMarkerReplication",
          children
        )

      {"DeleteReplication", _attrs, children}, {:ok, rule, seen} ->
        parse_status_block(rule, seen, :delete_replication, "DeleteReplication", children)

      {"ExistingObjectReplication", _attrs, children}, {:ok, rule, seen} ->
        parse_status_block(
          rule,
          seen,
          :existing_object_replication,
          "ExistingObjectReplication",
          children
        )

      {"SourceSelectionCriteria", _attrs, children}, {:ok, rule, seen} ->
        with {:ok, criteria} <- parse_source_selection_criteria(children) do
          put_once(
            rule,
            seen,
            :source_selection_criteria,
            "SourceSelectionCriteria",
            {:ok, criteria}
          )
        else
          _other -> {:halt, :error}
        end

      _other, _acc ->
        {:halt, :error}
    end)
    |> unwrap_acc()
  end

  defp parse_filter(children) do
    case XMLTree.structural_children(children) do
      [] ->
        {:ok, %{}}

      [{"Prefix", _attrs, children}] ->
        with {:ok, prefix} <- text(children), do: {:ok, %{"Prefix" => prefix}}

      [{"Tag", _attrs, children}] ->
        with {:ok, tag} <- parse_tag(children), do: {:ok, %{"Tag" => tag}}

      [{"And", _attrs, children}] ->
        with {:ok, and_operator} <- parse_and(children), do: {:ok, %{"And" => and_operator}}

      _other ->
        :error
    end
  end

  defp parse_and(children) do
    children
    |> XMLTree.structural_children()
    |> Enum.reduce_while({:ok, %{"Tags" => []}, MapSet.new(), 0}, fn
      {"Prefix", _attrs, children}, {:ok, and_operator, seen, count} ->
        with {:ok, prefix} <- text(children),
             {:ok, and_operator, seen} <-
               put_once_value(and_operator, seen, :prefix, "Prefix", prefix) do
          {:cont, {:ok, and_operator, seen, count + 1}}
        else
          _other -> {:halt, :error}
        end

      {"Tag", _attrs, children}, {:ok, and_operator, seen, count} ->
        with {:ok, tag} <- parse_tag(children),
             {:ok, and_operator, seen} <- put_tag(and_operator, seen, tag) do
          {:cont, {:ok, and_operator, seen, count + 1}}
        else
          _other -> {:halt, :error}
        end

      _other, _acc ->
        {:halt, :error}
    end)
    |> case do
      {:ok, and_operator, _seen, count} when count >= 2 -> {:ok, and_operator}
      _other -> :error
    end
  end

  defp parse_tag(children) do
    children
    |> XMLTree.structural_children()
    |> Enum.reduce_while({:ok, %{"Key" => @unset, "Value" => @unset}}, fn
      {"Key", _attrs, children}, {:ok, tag} ->
        put_tag_field(tag, "Key", required_text(children))

      {"Value", _attrs, children}, {:ok, tag} ->
        put_tag_field(tag, "Value", text(children))

      _other, _acc ->
        {:halt, :error}
    end)
    |> case do
      {:ok, %{"Key" => key, "Value" => value}} when is_binary(key) and is_binary(value) ->
        {:ok, %{"Key" => key, "Value" => value}}

      _other ->
        :error
    end
  end

  defp parse_destination(children) do
    children
    |> XMLTree.structural_children()
    |> Enum.reduce_while({:ok, %{}, MapSet.new()}, fn
      {"Bucket", _attrs, children}, {:ok, destination, seen} ->
        put_once(destination, seen, :bucket, "Bucket", required_text(children))

      {"Account", _attrs, children}, {:ok, destination, seen} ->
        put_once(destination, seen, :account, "Account", required_text(children))

      {"StorageClass", _attrs, children}, {:ok, destination, seen} ->
        put_once(destination, seen, :storage_class, "StorageClass", storage_class(children))

      {"EncryptionConfiguration", _attrs, children}, {:ok, destination, seen} ->
        with {:ok, encryption} <- parse_encryption(children) do
          put_once(
            destination,
            seen,
            :encryption_configuration,
            "EncryptionConfiguration",
            {:ok, encryption}
          )
        else
          _other -> {:halt, :error}
        end

      {"Metrics", _attrs, children}, {:ok, destination, seen} ->
        with {:ok, metrics} <- parse_metrics(children) do
          put_once(destination, seen, :metrics, "Metrics", {:ok, metrics})
        else
          _other -> {:halt, :error}
        end

      {"ReplicationTime", _attrs, children}, {:ok, destination, seen} ->
        with {:ok, replication_time} <- parse_replication_time(children) do
          put_once(
            destination,
            seen,
            :replication_time,
            "ReplicationTime",
            {:ok, replication_time}
          )
        else
          _other -> {:halt, :error}
        end

      {"AccessControlTranslation", _attrs, children}, {:ok, destination, seen} ->
        with {:ok, translation} <- parse_access_control_translation(children) do
          put_once(
            destination,
            seen,
            :access_control_translation,
            "AccessControlTranslation",
            {:ok, translation}
          )
        else
          _other -> {:halt, :error}
        end

      _other, _acc ->
        {:halt, :error}
    end)
    |> unwrap_acc()
  end

  defp parse_encryption(children) do
    children
    |> XMLTree.structural_children()
    |> Enum.reduce_while({:ok, %{}, MapSet.new()}, fn
      {"ReplicaKmsKeyID", _attrs, children}, {:ok, encryption, seen} ->
        put_once(
          encryption,
          seen,
          :replica_kms_key_id,
          "ReplicaKmsKeyID",
          required_text(children)
        )

      _other, _acc ->
        {:halt, :error}
    end)
    |> unwrap_acc()
  end

  defp parse_metrics(children) do
    children
    |> XMLTree.structural_children()
    |> Enum.reduce_while({:ok, %{}, MapSet.new()}, fn
      {"Status", _attrs, children}, {:ok, metrics, seen} ->
        put_once(metrics, seen, :status, "Status", status(children))

      {"EventThreshold", _attrs, children}, {:ok, metrics, seen} ->
        with {:ok, threshold} <- parse_minutes_block(children) do
          put_once(metrics, seen, :event_threshold, "EventThreshold", {:ok, threshold})
        else
          _other -> {:halt, :error}
        end

      _other, _acc ->
        {:halt, :error}
    end)
    |> unwrap_acc()
  end

  defp parse_replication_time(children) do
    children
    |> XMLTree.structural_children()
    |> Enum.reduce_while({:ok, %{}, MapSet.new()}, fn
      {"Status", _attrs, children}, {:ok, replication_time, seen} ->
        put_once(replication_time, seen, :status, "Status", status(children))

      {"Time", _attrs, children}, {:ok, replication_time, seen} ->
        with {:ok, time} <- parse_minutes_block(children) do
          put_once(replication_time, seen, :time, "Time", {:ok, time})
        else
          _other -> {:halt, :error}
        end

      _other, _acc ->
        {:halt, :error}
    end)
    |> unwrap_acc()
  end

  defp parse_minutes_block(children) do
    children
    |> XMLTree.structural_children()
    |> Enum.reduce_while({:ok, %{}, MapSet.new()}, fn
      {"Minutes", _attrs, children}, {:ok, time, seen} ->
        put_once(time, seen, :minutes, "Minutes", minutes(children))

      _other, _acc ->
        {:halt, :error}
    end)
    |> unwrap_acc()
  end

  defp parse_access_control_translation(children) do
    children
    |> XMLTree.structural_children()
    |> Enum.reduce_while({:ok, %{}, MapSet.new()}, fn
      {"Owner", _attrs, children}, {:ok, translation, seen} ->
        put_once(translation, seen, :owner, "Owner", owner(children))

      _other, _acc ->
        {:halt, :error}
    end)
    |> unwrap_acc()
  end

  defp parse_source_selection_criteria(children) do
    children
    |> XMLTree.structural_children()
    |> Enum.reduce_while({:ok, %{}, MapSet.new()}, fn
      {"SseKmsEncryptedObjects", _attrs, children}, {:ok, criteria, seen} ->
        with {:ok, block} <- parse_plain_status_block(children) do
          put_once(
            criteria,
            seen,
            :sse_kms_encrypted_objects,
            "SseKmsEncryptedObjects",
            {:ok, block}
          )
        else
          _other -> {:halt, :error}
        end

      {"ReplicaModifications", _attrs, children}, {:ok, criteria, seen} ->
        with {:ok, block} <- parse_plain_status_block(children) do
          put_once(criteria, seen, :replica_modifications, "ReplicaModifications", {:ok, block})
        else
          _other -> {:halt, :error}
        end

      _other, _acc ->
        {:halt, :error}
    end)
    |> unwrap_acc()
  end

  defp parse_status_block(rule, seen, seen_key, key, children) do
    with {:ok, block} <- parse_plain_status_block(children) do
      put_once(rule, seen, seen_key, key, {:ok, block})
    else
      _other -> {:halt, :error}
    end
  end

  defp parse_plain_status_block(children) do
    children
    |> XMLTree.structural_children()
    |> Enum.reduce_while({:ok, %{}, MapSet.new()}, fn
      {"Status", _attrs, children}, {:ok, block, seen} ->
        put_once(block, seen, :status, "Status", status(children))

      _other, _acc ->
        {:halt, :error}
    end)
    |> unwrap_acc()
  end

  defp put_once(map, seen, seen_key, key, {:ok, value}) do
    with {:ok, map, seen} <- put_once_value(map, seen, seen_key, key, value) do
      {:cont, {:ok, map, seen}}
    else
      :error -> {:halt, :error}
    end
  end

  defp put_once(_map, _seen, _seen_key, _key, :error), do: {:halt, :error}

  defp put_once_value(map, seen, seen_key, key, value) do
    if MapSet.member?(seen, seen_key) do
      :error
    else
      {:ok, Map.put(map, key, value), MapSet.put(seen, seen_key)}
    end
  end

  defp put_tag(%{"Tags" => tags} = and_operator, seen, %{"Key" => key} = tag) do
    seen_key = {:tag, key}

    if MapSet.member?(seen, seen_key) do
      :error
    else
      {:ok, %{and_operator | "Tags" => tags ++ [tag]}, MapSet.put(seen, seen_key)}
    end
  end

  defp put_tag_field(tag, key, {:ok, value}) do
    if Map.fetch!(tag, key) == @unset do
      {:cont, {:ok, Map.put(tag, key, value)}}
    else
      {:halt, :error}
    end
  end

  defp put_tag_field(_tag, _key, :error), do: {:halt, :error}

  defp unwrap_acc({:ok, map, _seen}), do: {:ok, map}
  defp unwrap_acc(:error), do: :error

  defp text(children), do: XMLTree.text(children, trim: true)
  defp required_text(children), do: XMLTree.required_text(children, trim: true)

  defp status(children) do
    with {:ok, value} <- required_text(children),
         true <- value in @valid_statuses do
      {:ok, value}
    else
      _other -> :error
    end
  end

  defp storage_class(children) do
    with {:ok, value} <- required_text(children),
         true <- value in @valid_storage_classes do
      {:ok, value}
    else
      _other -> :error
    end
  end

  defp integer(children) do
    with {:ok, value} <- required_text(children),
         {integer, ""} <- Integer.parse(value) do
      {:ok, integer}
    else
      _other -> :error
    end
  end

  defp minutes(children) do
    with {:ok, 15} <- integer(children) do
      {:ok, 15}
    else
      _other -> :error
    end
  end

  defp owner(children) do
    with {:ok, "Destination"} <- required_text(children) do
      {:ok, "Destination"}
    else
      _other -> :error
    end
  end
end
