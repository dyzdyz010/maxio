defmodule Maxio.S3.Logging do
  @moduledoc """
  Bucket-level server access logging configuration helpers.

  This stores and renders the S3 BucketLoggingStatus control-plane document.
  Emitting server access log objects is a separate data-plane feature.
  """

  alias Maxio.BucketConfigs
  alias Maxio.Policy.ACL
  alias Maxio.S3.Error

  @permissions ~w(READ WRITE FULL_CONTROL)
  @grantee_types ~w(CanonicalUser Group)
  @target_object_key_formats ~w(simple partitioned)
  @partition_date_sources ~w(EventTime DeliveryTime)
  @default_partition_date_source "EventTime"
  @empty %{"LoggingEnabled" => nil}

  @spec empty() :: map()
  def empty, do: @empty

  @spec permissions() :: [String.t()]
  def permissions, do: @permissions

  @spec valid_permission?(term()) :: boolean()
  def valid_permission?(permission), do: permission in @permissions

  @spec valid_grantee_type?(term()) :: boolean()
  def valid_grantee_type?(type), do: type in @grantee_types

  @spec valid_target_object_key_format?(term()) :: boolean()
  def valid_target_object_key_format?(format), do: format in @target_object_key_formats

  @spec valid_partition_date_source?(term()) :: boolean()
  def valid_partition_date_source?(source), do: source in @partition_date_sources

  @spec target_grants_to_acl(term()) ::
          {:ok, [map()]} | {:error, :unsupported_email | :invalid_grant | :too_many_grants}
  def target_grants_to_acl(grants) when is_list(grants) do
    grants
    |> Enum.reduce_while({:ok, []}, fn grant, {:ok, acc} ->
      case target_grant_to_acl(grant) do
        {:ok, normalized} -> {:cont, {:ok, [normalized | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, normalized} -> ACL.normalize_grants(Enum.reverse(normalized))
      {:error, _reason} = error -> error
    end
  end

  def target_grants_to_acl(_grants), do: {:error, :invalid_grant}

  @spec normalize(map()) :: map()
  def normalize(config) when is_map(config) do
    case value(config, ["LoggingEnabled", "logging_enabled"]) do
      nil ->
        @empty

      enabled when is_map(enabled) ->
        %{"LoggingEnabled" => normalize_enabled!(enabled)}

      _other ->
        invalid_stored!()
    end
  end

  @spec validate_client_config(map()) :: {:ok, map()} | {:error, :malformed_xml}
  def validate_client_config(config) when is_map(config) do
    {:ok, normalize_client(config)}
  rescue
    _err in Error -> {:error, :malformed_xml}
  end

  @spec get_config(String.t()) :: {:ok, map()}
  def get_config(bucket) when is_binary(bucket) do
    case BucketConfigs.get(bucket, :logging) do
      {:ok, config} -> {:ok, normalize(config)}
      :none -> {:ok, @empty}
    end
  end

  defp normalize_client(%{"LoggingEnabled" => nil}), do: @empty

  defp normalize_client(%{"LoggingEnabled" => enabled}) when is_map(enabled) do
    %{"LoggingEnabled" => normalize_enabled!(enabled)}
  end

  defp normalize_client(_config), do: invalid_client!()

  defp normalize_enabled!(enabled) do
    target_bucket = value(enabled, ["TargetBucket", "target_bucket"])
    target_prefix = value(enabled, ["TargetPrefix", "target_prefix"])
    target_grants = value(enabled, ["TargetGrants", "target_grants"], [])

    target_object_key_format =
      value(enabled, ["TargetObjectKeyFormat", "target_object_key_format"], %{"type" => "simple"})

    cond do
      not non_empty_string?(target_bucket) ->
        invalid_stored!()

      not is_binary(target_prefix) ->
        invalid_stored!()

      not is_list(target_grants) ->
        invalid_stored!()

      not is_map(target_object_key_format) ->
        invalid_stored!()

      not valid_target_object_key_format?(target_object_key_format["type"]) ->
        invalid_stored!()

      target_object_key_format["type"] == "partitioned" and
          not valid_partition_date_source?(partition_date_source(target_object_key_format)) ->
        invalid_stored!()

      true ->
        target_grants = Enum.map(target_grants, &normalize_target_grant!/1)
        :ok = validate_target_grants!(target_grants)

        %{
          "TargetBucket" => target_bucket,
          "TargetPrefix" => target_prefix,
          "TargetGrants" => target_grants,
          "TargetObjectKeyFormat" => normalize_target_object_key_format(target_object_key_format)
        }
    end
  end

  defp normalize_target_grant!(grant) when is_map(grant) do
    grantee = value(grant, ["Grantee", "grantee"])
    permission = value(grant, ["Permission", "permission"])

    cond do
      not valid_permission?(permission) ->
        invalid_stored!()

      not is_map(grantee) ->
        invalid_stored!()

      true ->
        %{
          "Grantee" => normalize_grantee!(grantee),
          "Permission" => permission
        }
    end
  end

  defp normalize_target_grant!(_grant),
    do: invalid_stored!()

  defp normalize_grantee!(grantee) do
    type = value(grantee, ["type", "Type"])

    cond do
      type == "CanonicalUser" and non_empty_string?(value(grantee, ["ID", "id"])) ->
        %{"type" => "CanonicalUser", "ID" => value(grantee, ["ID", "id"])}
        |> maybe_put("DisplayName", value(grantee, ["DisplayName", "display_name"]))

      type == "Group" and non_empty_string?(value(grantee, ["URI", "uri"])) ->
        %{"type" => "Group", "URI" => value(grantee, ["URI", "uri"])}

      true ->
        invalid_stored!()
    end
  end

  defp validate_target_grants!(grants) do
    case target_grants_to_acl(grants) do
      {:ok, _normalized} -> :ok
      {:error, _reason} -> invalid_stored!()
    end
  end

  defp target_grant_to_acl(%{
         "Grantee" => %{"type" => "CanonicalUser", "ID" => id} = grantee,
         "Permission" => permission
       }) do
    {:ok,
     %{
       "grantee" =>
         %{"type" => "CanonicalUser", "id" => id}
         |> maybe_put("display_name", Map.get(grantee, "DisplayName")),
       "permission" => permission
     }}
  end

  defp target_grant_to_acl(%{
         "Grantee" => %{"type" => "Group", "URI" => uri},
         "Permission" => permission
       }) do
    {:ok, %{"grantee" => %{"type" => "Group", "uri" => uri}, "permission" => permission}}
  end

  defp target_grant_to_acl(_grant), do: {:error, :invalid_grant}

  defp normalize_target_object_key_format(%{"type" => "partitioned"} = format) do
    %{
      "type" => "partitioned",
      "partition_date_source" => partition_date_source(format)
    }
  end

  defp normalize_target_object_key_format(_format), do: %{"type" => "simple"}

  defp partition_date_source(format) do
    case Map.fetch(format, "partition_date_source") do
      {:ok, source} when is_binary(source) and source != "" -> source
      _other -> @default_partition_date_source
    end
  end

  defp value(map, keys, default \\ nil) do
    Enum.reduce_while(keys, default, fn key, fallback ->
      case Map.fetch(map, key) do
        {:ok, value} -> {:halt, value}
        :error -> {:cont, fallback}
      end
    end)
  end

  defp non_empty_string?(value), do: is_binary(value) and value != ""

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, ""), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp invalid_client!, do: raise(Error.new(:malformed_xml))

  defp invalid_stored!,
    do: raise(Error.new(:internal_error, message: "Invalid stored BucketLoggingStatus"))
end
