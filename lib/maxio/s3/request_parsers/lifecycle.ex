defmodule Maxio.S3.RequestParsers.Lifecycle do
  @moduledoc """
  Strict PutBucketLifecycleConfiguration XML parser.

  The public contract intentionally stays as the existing flat lifecycle rule
  map consumed by the handler, view, and runner. XML shape that cannot be
  represented by that contract, such as repeated Transition containers, fails
  closed instead of being silently flattened.
  """

  alias Maxio.S3.RequestParsers.XMLTree
  alias Maxio.S3.StorageClass

  @root_tags ~w(LifecycleConfiguration LifeCycleConfiguration)
  @unset {:__maxio_lifecycle_unset__, []}

  @spec parse(binary()) :: {:ok, [map()]} | {:error, :malformed_xml}
  def parse(xml) when is_binary(xml) do
    with {:ok, {root, _attrs, children}} when root in @root_tags <- XMLTree.parse(xml),
         {:ok, rules} <- parse_rules(children) do
      {:ok, rules}
    else
      _other -> {:error, :malformed_xml}
    end
  end

  defp parse_rules(children) do
    children = XMLTree.structural_children(children)

    if Enum.all?(children, &match?({"Rule", _attrs, _children}, &1)) do
      Enum.reduce_while(children, {:ok, []}, fn {"Rule", _attrs, rule_children}, {:ok, rules} ->
        case parse_rule(rule_children) do
          {:ok, rule} -> {:cont, {:ok, [rule | rules]}}
          :error -> {:halt, :error}
        end
      end)
      |> case do
        {:ok, rules} -> {:ok, Enum.reverse(rules)}
        :error -> {:error, :malformed_xml}
      end
    else
      {:error, :malformed_xml}
    end
  end

  defp new_rule do
    %{
      "id" => nil,
      "status" => nil,
      "prefix" => nil,
      "filter_prefix" => nil,
      "filter_tags" => [],
      "filter_size_gt" => nil,
      "filter_size_lt" => nil,
      "has_filter" => false,
      "expiration_days" => nil,
      "expiration_date" => nil,
      "expired_object_delete_marker" => nil,
      "noncurrent_days" => nil,
      "newer_noncurrent_versions" => nil,
      "abort_days_after_initiation" => nil,
      "transition_days" => nil,
      "transition_date" => nil,
      "transition_storage_class" => nil,
      "noncurrent_transition_days" => nil,
      "noncurrent_transition_newer_noncurrent_versions" => nil,
      "noncurrent_transition_storage_class" => nil,
      "parse_errors" => []
    }
  end

  defp parse_rule(children) do
    children
    |> XMLTree.structural_children()
    |> Enum.reduce_while({:ok, new_rule(), MapSet.new()}, fn
      {"ID", _attrs, children}, {:ok, rule, seen} ->
        put_once(rule, seen, :id, "id", text(children, trim: true))

      {"Status", _attrs, children}, {:ok, rule, seen} ->
        put_once(rule, seen, :status, "status", status(children))

      {"Prefix", _attrs, children}, {:ok, rule, seen} ->
        put_once(rule, seen, :prefix, "prefix", text(children, trim: true))

      {"Filter", _attrs, children}, {:ok, rule, seen} ->
        with {:ok, filter} <- parse_filter(children),
             {:ok, rule, seen} <- put_once_value(rule, seen, :filter, filter) do
          {:cont, {:ok, rule, seen}}
        else
          _other -> {:halt, :error}
        end

      {"Expiration", _attrs, children}, {:ok, rule, seen} ->
        put_once_parsed(rule, seen, :expiration, parse_expiration(children))

      {"NoncurrentVersionExpiration", _attrs, children}, {:ok, rule, seen} ->
        put_once_parsed(
          rule,
          seen,
          :noncurrent_version_expiration,
          parse_noncurrent_version_expiration(children)
        )

      {"AbortIncompleteMultipartUpload", _attrs, children}, {:ok, rule, seen} ->
        put_once_parsed(
          rule,
          seen,
          :abort_incomplete_multipart_upload,
          parse_abort_incomplete_multipart_upload(children)
        )

      {"Transition", _attrs, children}, {:ok, rule, seen} ->
        put_once_parsed(rule, seen, :transition, parse_transition(children))

      {"NoncurrentVersionTransition", _attrs, children}, {:ok, rule, seen} ->
        put_once_parsed(
          rule,
          seen,
          :noncurrent_version_transition,
          parse_noncurrent_version_transition(children)
        )

      _other, _acc ->
        {:halt, :error}
    end)
    |> finalize_rule()
  end

  defp finalize_rule({:ok, rule, seen}) do
    if MapSet.member?(seen, :prefix) and MapSet.member?(seen, :filter) do
      :error
    else
      {:ok, rule}
    end
  end

  defp finalize_rule(_other), do: :error

  defp parse_filter(children) do
    children = XMLTree.structural_children(children)

    case children do
      [] ->
        {:ok, %{"has_filter" => true}}

      [{"And", _attrs, and_children}] ->
        parse_and_filter(and_children)

      [{tag, _attrs, leaf_children}]
      when tag in ~w(Prefix Tag ObjectSizeGreaterThan ObjectSizeLessThan) ->
        parse_direct_filter(tag, leaf_children)

      _other ->
        :error
    end
  end

  defp parse_direct_filter("Prefix", children) do
    with {:ok, prefix} <- text(children, trim: true) do
      {:ok, %{"has_filter" => true, "filter_prefix" => prefix}}
    end
  end

  defp parse_direct_filter("Tag", children) do
    with {:ok, tag} <- parse_tag(children) do
      {:ok, %{"has_filter" => true, "filter_tags" => [tag]}}
    end
  end

  defp parse_direct_filter("ObjectSizeGreaterThan", children) do
    with {:ok, value} <- nonnegative_integer(children) do
      {:ok, %{"has_filter" => true, "filter_size_gt" => value}}
    end
  end

  defp parse_direct_filter("ObjectSizeLessThan", children) do
    with {:ok, value} <- positive_integer(children) do
      {:ok, %{"has_filter" => true, "filter_size_lt" => value}}
    end
  end

  defp parse_and_filter(children) do
    children = XMLTree.structural_children(children)

    children
    |> Enum.reduce_while({:ok, %{"has_filter" => true, "filter_tags" => []}, MapSet.new(), 0}, fn
      {"Prefix", _attrs, leaf_children}, {:ok, filter, seen, count} ->
        with {:ok, prefix} <- text(leaf_children, trim: true),
             {:ok, filter, seen} <-
               put_filter_once(filter, seen, :prefix, "filter_prefix", prefix) do
          {:cont, {:ok, filter, seen, count + 1}}
        else
          _other -> {:halt, :error}
        end

      {"Tag", _attrs, tag_children}, {:ok, filter, seen, count} ->
        with {:ok, tag} <- parse_tag(tag_children),
             {:ok, filter, seen} <- put_filter_tag(filter, seen, tag) do
          {:cont, {:ok, filter, seen, count + 1}}
        else
          _other -> {:halt, :error}
        end

      {"ObjectSizeGreaterThan", _attrs, leaf_children}, {:ok, filter, seen, count} ->
        with {:ok, value} <- nonnegative_integer(leaf_children),
             {:ok, filter, seen} <-
               put_filter_once(filter, seen, :size_gt, "filter_size_gt", value) do
          {:cont, {:ok, filter, seen, count + 1}}
        else
          _other -> {:halt, :error}
        end

      {"ObjectSizeLessThan", _attrs, leaf_children}, {:ok, filter, seen, count} ->
        with {:ok, value} <- positive_integer(leaf_children),
             {:ok, filter, seen} <-
               put_filter_once(filter, seen, :size_lt, "filter_size_lt", value) do
          {:cont, {:ok, filter, seen, count + 1}}
        else
          _other -> {:halt, :error}
        end

      _other, _acc ->
        {:halt, :error}
    end)
    |> case do
      {:ok, filter, _seen, count} when count >= 2 -> {:ok, filter}
      _other -> :error
    end
  end

  defp parse_tag(children) do
    children
    |> XMLTree.structural_children()
    |> Enum.reduce_while({:ok, %{"key" => @unset, "value" => @unset}}, fn
      {"Key", _attrs, children}, {:ok, tag} ->
        put_required_tag_field(tag, "key", children)

      {"Value", _attrs, children}, {:ok, tag} ->
        put_tag_field(tag, "value", children)

      _other, _acc ->
        {:halt, :error}
    end)
    |> case do
      {:ok, %{"key" => key, "value" => value}} when is_binary(key) and is_binary(value) ->
        {:ok, %{"key" => key, "value" => value}}

      _other ->
        :error
    end
  end

  defp parse_expiration(children) do
    children
    |> XMLTree.structural_children()
    |> Enum.reduce_while({:ok, %{}, MapSet.new()}, fn
      {"Days", _attrs, children}, {:ok, expiration, seen} ->
        put_once_value_reduced(expiration, seen, :days, %{
          "expiration_days" => positive_integer(children)
        })

      {"Date", _attrs, children}, {:ok, expiration, seen} ->
        put_once_value_reduced(expiration, seen, :date, %{
          "expiration_date" => lifecycle_date(children)
        })

      {"ExpiredObjectDeleteMarker", _attrs, children}, {:ok, expiration, seen} ->
        put_once_value_reduced(expiration, seen, :eodm, %{
          "expired_object_delete_marker" => boolean(children)
        })

      _other, _acc ->
        {:halt, :error}
    end)
    |> unwrap_single_action()
  end

  defp parse_noncurrent_version_expiration(children) do
    children
    |> XMLTree.structural_children()
    |> Enum.reduce_while({:ok, %{}, MapSet.new()}, fn
      {"NoncurrentDays", _attrs, children}, {:ok, expiration, seen} ->
        put_once_value_reduced(expiration, seen, :noncurrent_days, %{
          "noncurrent_days" => positive_integer(children)
        })

      {"NewerNoncurrentVersions", _attrs, children}, {:ok, expiration, seen} ->
        put_once_value_reduced(expiration, seen, :newer_noncurrent_versions, %{
          "newer_noncurrent_versions" => bounded_integer(children, 1, 100)
        })

      _other, _acc ->
        {:halt, :error}
    end)
    |> case do
      {:ok, expiration, seen} ->
        if MapSet.member?(seen, :noncurrent_days), do: {:ok, expiration}, else: :error

      _other ->
        :error
    end
  end

  defp parse_abort_incomplete_multipart_upload(children) do
    children
    |> XMLTree.structural_children()
    |> case do
      [{"DaysAfterInitiation", _attrs, days_children}] ->
        with {:ok, days} <- positive_integer(days_children) do
          {:ok, %{"abort_days_after_initiation" => days}}
        end

      _other ->
        :error
    end
  end

  defp parse_transition(children) do
    children
    |> XMLTree.structural_children()
    |> Enum.reduce_while({:ok, %{}, MapSet.new()}, fn
      {"Days", _attrs, children}, {:ok, transition, seen} ->
        put_once_value_reduced(transition, seen, :days, %{
          "transition_days" => nonnegative_integer(children)
        })

      {"Date", _attrs, children}, {:ok, transition, seen} ->
        put_once_value_reduced(transition, seen, :date, %{
          "transition_date" => lifecycle_date(children)
        })

      {"StorageClass", _attrs, children}, {:ok, transition, seen} ->
        put_once_value_reduced(transition, seen, :storage_class, %{
          "transition_storage_class" => storage_class(children)
        })

      _other, _acc ->
        {:halt, :error}
    end)
    |> case do
      {:ok, transition, seen} ->
        day_or_date? =
          one_seen?(seen, :days, :date)

        if day_or_date? and MapSet.member?(seen, :storage_class) do
          {:ok, transition}
        else
          :error
        end

      _other ->
        :error
    end
  end

  defp parse_noncurrent_version_transition(children) do
    children
    |> XMLTree.structural_children()
    |> Enum.reduce_while({:ok, %{}, MapSet.new()}, fn
      {"NoncurrentDays", _attrs, children}, {:ok, transition, seen} ->
        put_once_value_reduced(transition, seen, :noncurrent_days, %{
          "noncurrent_transition_days" => nonnegative_integer(children)
        })

      {"NewerNoncurrentVersions", _attrs, children}, {:ok, transition, seen} ->
        put_once_value_reduced(transition, seen, :newer_noncurrent_versions, %{
          "noncurrent_transition_newer_noncurrent_versions" => bounded_integer(children, 1, 100)
        })

      {"StorageClass", _attrs, children}, {:ok, transition, seen} ->
        put_once_value_reduced(transition, seen, :storage_class, %{
          "noncurrent_transition_storage_class" => storage_class(children)
        })

      _other, _acc ->
        {:halt, :error}
    end)
    |> case do
      {:ok, transition, seen} ->
        if MapSet.member?(seen, :noncurrent_days) and MapSet.member?(seen, :storage_class) do
          {:ok, transition}
        else
          :error
        end

      _other ->
        :error
    end
  end

  defp unwrap_single_action({:ok, action, seen}) when map_size(action) > 0 do
    if MapSet.size(seen) == 1, do: {:ok, action}, else: :error
  end

  defp unwrap_single_action(_other), do: :error

  defp one_seen?(seen, left, right) do
    MapSet.member?(seen, left) != MapSet.member?(seen, right)
  end

  defp put_once(rule, seen, seen_key, field, {:ok, value}) do
    if MapSet.member?(seen, seen_key) do
      {:halt, :error}
    else
      {:cont, {:ok, Map.put(rule, field, value), MapSet.put(seen, seen_key)}}
    end
  end

  defp put_once(_rule, _seen, _seen_key, _field, :error), do: {:halt, :error}

  defp put_once_parsed(rule, seen, seen_key, {:ok, fields}) do
    with {:ok, rule, seen} <- put_once_value(rule, seen, seen_key, fields) do
      {:cont, {:ok, rule, seen}}
    else
      _other -> {:halt, :error}
    end
  end

  defp put_once_parsed(_rule, _seen, _seen_key, :error), do: {:halt, :error}

  defp put_once_value(target, seen, seen_key, fields) when is_map(fields) do
    if MapSet.member?(seen, seen_key) do
      :error
    else
      with {:ok, resolved} <- resolve_fields(fields) do
        {:ok, Map.merge(target, resolved), MapSet.put(seen, seen_key)}
      end
    end
  end

  defp put_once_value_reduced(target, seen, seen_key, fields) do
    with {:ok, target, seen} <- put_once_value(target, seen, seen_key, fields) do
      {:cont, {:ok, target, seen}}
    else
      _other -> {:halt, :error}
    end
  end

  defp put_filter_once(filter, seen, seen_key, field, value) do
    if MapSet.member?(seen, seen_key) do
      :error
    else
      {:ok, Map.put(filter, field, value), MapSet.put(seen, seen_key)}
    end
  end

  defp put_filter_tag(%{"filter_tags" => tags} = filter, seen, %{"key" => key} = tag) do
    tag_seen_key = {:tag, key}

    if MapSet.member?(seen, tag_seen_key) do
      :error
    else
      {:ok, %{filter | "filter_tags" => tags ++ [tag]}, MapSet.put(seen, tag_seen_key)}
    end
  end

  defp put_required_tag_field(tag, field, children) do
    case required_text(children) do
      {:ok, value} -> put_tag_field(tag, field, {:ok, value})
      :error -> {:halt, :error}
    end
  end

  defp put_tag_field(tag, field, children) when is_list(children),
    do: put_tag_field(tag, field, text(children, trim: true))

  defp put_tag_field(tag, field, {:ok, value}) do
    if Map.fetch!(tag, field) == @unset do
      {:cont, {:ok, Map.put(tag, field, value)}}
    else
      {:halt, :error}
    end
  end

  defp put_tag_field(_tag, _field, :error), do: {:halt, :error}

  defp resolve_fields(fields) do
    Enum.reduce_while(fields, {:ok, %{}}, fn
      {key, {:ok, value}}, {:ok, resolved} ->
        {:cont, {:ok, Map.put(resolved, key, value)}}

      {_key, :error}, _acc ->
        {:halt, :error}

      {key, value}, {:ok, resolved} ->
        {:cont, {:ok, Map.put(resolved, key, value)}}
    end)
  end

  defp text(children, opts), do: XMLTree.text(children, opts)
  defp required_text(children), do: XMLTree.required_text(children, trim: true)

  defp positive_integer(children), do: integer(children, 1, nil)
  defp nonnegative_integer(children), do: integer(children, 0, nil)
  defp bounded_integer(children, min, max), do: integer(children, min, max)

  defp integer(children, min, max) do
    with {:ok, value} <- required_text(children),
         {integer, ""} <- Integer.parse(value),
         true <- integer >= min,
         true <- is_nil(max) or integer <= max do
      {:ok, integer}
    else
      _other -> :error
    end
  end

  defp boolean(children) do
    case required_text(children) do
      {:ok, "true"} -> {:ok, true}
      {:ok, "false"} -> {:ok, false}
      _other -> :error
    end
  end

  defp status(children) do
    case required_text(children) do
      {:ok, status} when status in ["Enabled", "Disabled"] -> {:ok, status}
      _other -> :error
    end
  end

  defp storage_class(children) do
    with {:ok, value} <- required_text(children),
         true <- value in StorageClass.lifecycle_transition_values() do
      {:ok, value}
    else
      _other -> :error
    end
  end

  defp lifecycle_date(children) do
    with {:ok, value} <- required_text(children),
         true <- lifecycle_midnight_utc?(value) do
      {:ok, value}
    else
      _other -> :error
    end
  end

  defp lifecycle_midnight_utc?(value) do
    case DateTime.from_iso8601(value) do
      {:ok, %DateTime{hour: 0, minute: 0, second: 0, microsecond: {0, _}}, 0} -> true
      _other -> false
    end
  end
end
