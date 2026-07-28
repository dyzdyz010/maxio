defmodule Maxio.S3.RequestParsers.Restore do
  @moduledoc "RestoreObject RestoreRequest XML parser."
  @behaviour Saxy.Handler
  alias Maxio.Policy.ACL
  alias Maxio.S3.RequestParsers.SelectObjectContent
  alias Maxio.S3.StorageClass

  @unset {:__maxio_restore_unset__, []}
  @tiers ~w(Expedited Standard Bulk)
  @select_output_canned_acls ~w(private public-read public-read-write authenticated-read
                                aws-exec-read bucket-owner-read bucket-owner-full-control)
  @select_output_encryption_types ~w(AES256 aws:fsx aws:kms aws:kms:dsse)

  @spec parse(binary()) :: {:ok, map()} | {:error, :malformed_xml}
  def parse(xml) when is_binary(xml) do
    case Saxy.parse_string(xml, __MODULE__, %{stack: [], root: nil, invalid?: false}) do
      {:ok, %{root: {"RestoreRequest", _attrs, children}, invalid?: false}} ->
        build_request(children)

      _other ->
        {:error, :malformed_xml}
    end
  end

  @impl true
  def handle_event(:start_document, _prolog, state), do: {:ok, state}

  @impl true
  def handle_event(:start_element, {name, attrs}, state) do
    tag = local(name)
    attrs = Enum.map(attrs, fn {name, value} -> {local(name), value} end)
    {:ok, %{state | stack: [{tag, attrs, []} | state.stack]}}
  end

  @impl true
  def handle_event(:characters, chars, state), do: {:ok, append_child(state, {:text, chars})}

  @impl true
  def handle_event(:end_element, name, %{stack: [{tag, attrs, children} | rest]} = state) do
    if local(name) == tag do
      node = {tag, attrs, Enum.reverse(children)}

      case rest do
        [] ->
          {:ok, %{state | root: node, stack: []}}

        [{parent_tag, parent_attrs, parent_children} | parent_rest] ->
          stack = [{parent_tag, parent_attrs, [node | parent_children]} | parent_rest]
          {:ok, %{state | stack: stack}}
      end
    else
      {:ok, %{state | invalid?: true}}
    end
  end

  def handle_event(:end_element, _name, state), do: {:ok, %{state | invalid?: true}}

  @impl true
  def handle_event(:end_document, _data, state), do: {:ok, state}

  defp append_child(%{stack: []} = state, _child), do: %{state | invalid?: true}

  defp append_child(%{stack: [{tag, attrs, children} | rest]} = state, child) do
    %{state | stack: [{tag, attrs, [child | children]} | rest]}
  end

  defp build_request(children) do
    children
    |> structural_children()
    |> Enum.reduce_while(
      {:ok,
       %{
         days: @unset,
         description: nil,
         tier: nil,
         type: nil,
         select_parameters: nil,
         output_location: nil,
         glacier_job_parameters?: false
       }},
      &parse_restore_child/2
    )
    |> case do
      {:ok,
       %{
         type: nil,
         days: days,
         description: description,
         tier: tier,
         glacier_job_parameters?: glacier_job_parameters?,
         select_parameters: nil,
         output_location: nil
       }}
      when is_integer(days) and
             (is_nil(tier) or (is_binary(tier) and glacier_job_parameters? == true)) ->
        {:ok, maybe_put(%{"Days" => days, "Tier" => tier}, "Description", description)}

      {:ok,
       %{
         type: "SELECT",
         days: @unset,
         description: description,
         tier: tier,
         select_parameters: select_parameters,
         output_location: output_location,
         glacier_job_parameters?: false
       }}
      when is_map(select_parameters) and is_map(output_location) ->
        {:ok,
         %{
           "Type" => "SELECT",
           "Tier" => tier,
           "SelectParameters" => select_parameters,
           "OutputLocation" => output_location
         }
         |> maybe_put("Description", description)}

      {:ok, _req} ->
        {:error, :malformed_xml}

      :error ->
        {:error, :malformed_xml}
    end
  end

  defp parse_restore_child({"Days", _attrs, children}, {:ok, req}),
    do: put_once(req, :days, positive_int(children))

  defp parse_restore_child({"GlacierJobParameters", _attrs, children}, {:ok, req}) do
    case {req.glacier_job_parameters?, req.tier, parse_glacier_job_parameters(children)} do
      {false, nil, {:ok, tier}} ->
        {:cont, {:ok, %{req | tier: tier, glacier_job_parameters?: true}}}

      _other ->
        {:halt, :error}
    end
  end

  defp parse_restore_child({"Description", _attrs, children}, {:ok, req}),
    do: put_once(req, :description, text(children))

  defp parse_restore_child({"Type", _attrs, children}, {:ok, req}) do
    case required_text(children) do
      {:ok, "SELECT"} -> put_once(req, :type, {:ok, "SELECT"})
      _other -> {:halt, :error}
    end
  end

  defp parse_restore_child({"Tier", _attrs, children}, {:ok, req}) do
    case required_text(children) do
      {:ok, tier} when tier in @tiers -> put_once(req, :tier, {:ok, tier})
      _other -> {:halt, :error}
    end
  end

  defp parse_restore_child({"SelectParameters", _attrs, children}, {:ok, req}),
    do: put_once(req, :select_parameters, SelectObjectContent.parse_select_parameters(children))

  defp parse_restore_child({"OutputLocation", _attrs, children}, {:ok, req}),
    do: put_once(req, :output_location, parse_output_location(children))

  defp parse_restore_child(_other, _acc), do: {:halt, :error}

  defp parse_glacier_job_parameters(children) do
    children
    |> structural_children()
    |> Enum.reduce_while({:ok, @unset}, fn
      {"Tier", _attrs, children}, {:ok, @unset} ->
        case required_text(children) do
          {:ok, tier} when tier in @tiers -> {:cont, {:ok, tier}}
          _other -> {:halt, :error}
        end

      {"Tier", _attrs, _children}, {:ok, _tier} ->
        {:halt, :error}

      _other, _acc ->
        {:halt, :error}
    end)
    |> case do
      {:ok, @unset} -> :error
      {:ok, tier} -> {:ok, tier}
      :error -> :error
    end
  end

  defp put_once(map, key, {:ok, value}) do
    if Map.fetch!(map, key) in [@unset, nil] do
      {:cont, {:ok, Map.put(map, key, value)}}
    else
      {:halt, :error}
    end
  end

  defp put_once(_map, _key, :error), do: {:halt, :error}

  defp parse_output_location(children) do
    case structural_children(children) do
      [{"S3", _attrs, s3_children}] -> parse_s3_output_location(s3_children)
      _other -> :error
    end
  end

  defp parse_s3_output_location(children) do
    children
    |> structural_children()
    |> Enum.reduce_while({:ok, %{"StorageClass" => "STANDARD", "Unsupported" => []}}, fn
      {"BucketName", _attrs, children}, {:ok, output} ->
        put_output_text(output, "BucketName", children)

      {"Prefix", _attrs, children}, {:ok, output} ->
        put_output_text(output, "Prefix", children)

      {"StorageClass", _attrs, children}, {:ok, output} ->
        case required_text(children) do
          {:ok, value} ->
            value = String.upcase(value)

            if value in StorageClass.valid_values() do
              {:cont, {:ok, Map.put(output, "StorageClass", value)}}
            else
              {:halt, :error}
            end

          :error ->
            {:halt, :error}
        end

      {"CannedACL", _attrs, children}, {:ok, output} ->
        case required_text(children) do
          {:ok, value} when value in @select_output_canned_acls ->
            put_output_acl_value(output, "CannedACL", value)

          _other ->
            {:halt, :error}
        end

      {"AccessControlList", _attrs, children}, {:ok, output} ->
        put_output_acl_value(
          output,
          "AccessControlList",
          parse_output_access_control_list(children)
        )

      {"Tagging", _attrs, children}, {:ok, output} ->
        put_output_value(output, "Tagging", parse_output_tagging(children))

      {"UserMetadata", _attrs, children}, {:ok, output} ->
        put_output_value(output, "UserMetadata", parse_output_user_metadata(children))

      {"Encryption", _attrs, children}, {:ok, output} ->
        put_output_value(output, "Encryption", parse_output_encryption(children))

      _other, _acc ->
        {:halt, :error}
    end)
    |> case do
      {:ok, %{"BucketName" => bucket, "Prefix" => prefix} = output}
      when is_binary(bucket) and bucket != "" and is_binary(prefix) and prefix != "" ->
        {:ok, %{output | "Unsupported" => Enum.reverse(output["Unsupported"])}}

      _other ->
        :error
    end
  end

  defp put_output_text(output, key, children) do
    if Map.has_key?(output, key) do
      {:halt, :error}
    else
      case required_text(children) do
        {:ok, value} -> {:cont, {:ok, Map.put(output, key, value)}}
        :error -> {:halt, :error}
      end
    end
  end

  defp put_output_value(output, key, {:ok, value}), do: put_output_value(output, key, value)
  defp put_output_value(_output, _key, :error), do: {:halt, :error}

  defp put_output_value(output, key, value) do
    if Map.has_key?(output, key) do
      {:halt, :error}
    else
      {:cont, {:ok, Map.put(output, key, value)}}
    end
  end

  defp put_output_acl_value(output, key, {:ok, value}),
    do: put_output_acl_value(output, key, value)

  defp put_output_acl_value(_output, _key, :error), do: {:halt, :error}
  defp put_output_acl_value(_output, _key, {:error, _reason}), do: {:halt, :error}

  defp put_output_acl_value(output, key, value) do
    other_key = if key == "CannedACL", do: "AccessControlList", else: "CannedACL"

    if Map.has_key?(output, key) or Map.has_key?(output, other_key) do
      {:halt, :error}
    else
      {:cont, {:ok, Map.put(output, key, value)}}
    end
  end

  defp parse_output_access_control_list(children) do
    children
    |> structural_children()
    |> Enum.reduce_while({:ok, []}, fn
      {"Grant", _attrs, grant_children}, {:ok, grants} ->
        case parse_acl_grant(grant_children) do
          {:ok, grant} -> {:cont, {:ok, [grant | grants]}}
          :error -> {:halt, :error}
        end

      _other, _acc ->
        {:halt, :error}
    end)
    |> case do
      {:ok, []} -> :error
      {:ok, grants} -> ACL.normalize_grants(Enum.reverse(grants))
      :error -> :error
    end
  end

  defp parse_acl_grant(children) do
    children
    |> structural_children()
    |> Enum.reduce_while({:ok, %{grantee: @unset, permission: @unset}}, fn
      {"Grantee", attrs, grantee_children}, {:ok, grant} ->
        put_once(grant, :grantee, parse_acl_grantee(attrs, grantee_children))

      {"Permission", _attrs, children}, {:ok, grant} ->
        put_once(grant, :permission, required_text(children))

      _other, _acc ->
        {:halt, :error}
    end)
    |> case do
      {:ok, %{grantee: grantee, permission: permission}}
      when is_map(grantee) and is_binary(permission) ->
        {:ok, %{"grantee" => grantee, "permission" => permission}}

      _other ->
        :error
    end
  end

  defp parse_acl_grantee(attrs, children) do
    children
    |> structural_children()
    |> Enum.reduce_while(
      {:ok,
       %{
         "type" => grantee_type(attrs),
         "id" => @unset,
         "display_name" => @unset,
         "uri" => @unset,
         "email" => @unset
       }},
      fn
        {"ID", _attrs, children}, {:ok, grantee} ->
          put_optional_output_value(grantee, "id", required_text(children))

        {"DisplayName", _attrs, children}, {:ok, grantee} ->
          put_optional_output_value(grantee, "display_name", text(children))

        {"URI", _attrs, children}, {:ok, grantee} ->
          put_optional_output_value(grantee, "uri", required_text(children))

        {"EmailAddress", _attrs, children}, {:ok, grantee} ->
          put_optional_output_value(grantee, "email", required_text(children))

        _other, _acc ->
          {:halt, :error}
      end
    )
    |> case do
      {:ok, grantee} -> {:ok, reject_unset_values(grantee)}
      :error -> :error
    end
  end

  defp grantee_type(attrs) do
    Enum.find_value(attrs, fn
      {"type", value} -> value
      _other -> nil
    end)
  end

  defp parse_output_tagging(children) do
    case structural_children(children) do
      [{"TagSet", _attrs, tag_children}] ->
        parse_tag_set(tag_children)

      _other ->
        :error
    end
  end

  defp parse_tag_set(children) do
    children
    |> structural_children()
    |> Enum.reduce_while({:ok, []}, fn
      {"Tag", _attrs, tag_children}, {:ok, tags} ->
        case parse_tag(tag_children) do
          {:ok, tag} -> {:cont, {:ok, [tag | tags]}}
          :error -> {:halt, :error}
        end

      _other, _acc ->
        {:halt, :error}
    end)
    |> case do
      {:ok, tags} -> {:ok, Enum.reverse(tags)}
      :error -> :error
    end
  end

  defp parse_tag(children) do
    children
    |> structural_children()
    |> Enum.reduce_while({:ok, %{key: @unset, value: @unset}}, fn
      {"Key", _attrs, children}, {:ok, tag} ->
        put_once(tag, :key, required_raw_text(children))

      {"Value", _attrs, children}, {:ok, tag} ->
        put_once(tag, :value, raw_text(children))

      _other, _acc ->
        {:halt, :error}
    end)
    |> case do
      {:ok, %{key: key, value: value}} when is_binary(key) and is_binary(value) ->
        {:ok, {key, value}}

      _other ->
        :error
    end
  end

  defp parse_output_user_metadata(children) do
    children
    |> structural_children()
    |> Enum.reduce_while({:ok, %{}}, fn
      {"MetadataEntry", _attrs, entry_children}, {:ok, metadata} ->
        case parse_metadata_entry(entry_children) do
          {:ok, {name, value}} ->
            if Map.has_key?(metadata, name) do
              {:halt, :error}
            else
              {:cont, {:ok, Map.put(metadata, name, value)}}
            end

          :error ->
            {:halt, :error}
        end

      _other, _acc ->
        {:halt, :error}
    end)
  end

  defp parse_metadata_entry(children) do
    children
    |> structural_children()
    |> Enum.reduce_while({:ok, %{name: @unset, value: @unset}}, fn
      {"Name", _attrs, children}, {:ok, entry} ->
        put_once(entry, :name, required_text(children))

      {"Value", _attrs, children}, {:ok, entry} ->
        put_once(entry, :value, raw_text(children))

      _other, _acc ->
        {:halt, :error}
    end)
    |> case do
      {:ok, %{name: name, value: value}} when is_binary(name) and is_binary(value) ->
        {:ok, {String.downcase(name), value}}

      _other ->
        :error
    end
  end

  defp parse_output_encryption(children) do
    children
    |> structural_children()
    |> Enum.reduce_while(
      {:ok, %{"EncryptionType" => @unset, "KMSKeyId" => @unset, "KMSContext" => @unset}},
      fn
        {"EncryptionType", _attrs, children}, {:ok, encryption} ->
          case required_text(children) do
            {:ok, value} when value in @select_output_encryption_types ->
              put_optional_output_value(encryption, "EncryptionType", value)

            _other ->
              {:halt, :error}
          end

        {"KMSKeyId", _attrs, children}, {:ok, encryption} ->
          put_optional_output_value(encryption, "KMSKeyId", optional_text(children))

        {"KMSContext", _attrs, children}, {:ok, encryption} ->
          put_optional_output_value(encryption, "KMSContext", optional_text(children))

        _other, _acc ->
          {:halt, :error}
      end
    )
    |> case do
      {:ok, %{"EncryptionType" => type} = encryption} when is_binary(type) ->
        {:ok, reject_unset_values(encryption)}

      _other ->
        :error
    end
  end

  defp optional_text(children) do
    case text(children) do
      {:ok, ""} -> {:ok, nil}
      other -> other
    end
  end

  defp put_optional_output_value(output, key, {:ok, value}),
    do: put_optional_output_value(output, key, value)

  defp put_optional_output_value(_output, _key, :error), do: {:halt, :error}

  defp put_optional_output_value(output, key, value) do
    if Map.get(output, key) == @unset do
      {:cont, {:ok, Map.put(output, key, value)}}
    else
      {:halt, :error}
    end
  end

  defp positive_int(children) do
    with {:ok, value} <- required_text(children),
         {int, ""} when int >= 1 <- Integer.parse(value) do
      {:ok, int}
    else
      _other -> :error
    end
  end

  defp required_text(children) do
    case text(children) do
      {:ok, ""} -> :error
      other -> other
    end
  end

  defp required_raw_text(children) do
    case raw_text(children) do
      {:ok, ""} -> :error
      other -> other
    end
  end

  defp reject_unset_values(map) when is_map(map) do
    Map.reject(map, fn {_key, value} -> value == @unset or is_nil(value) end)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp text([]), do: {:ok, ""}

  defp text(children) when is_list(children) do
    if Enum.all?(children, &match?({:text, value} when is_binary(value), &1)) do
      case raw_text(children) do
        {:ok, value} -> {:ok, String.trim(value)}
        :error -> :error
      end
    else
      :error
    end
  end

  defp raw_text([]), do: {:ok, ""}

  defp raw_text(children) when is_list(children) do
    if Enum.all?(children, &match?({:text, value} when is_binary(value), &1)) do
      {:ok, children |> Enum.map(fn {:text, value} -> value end) |> Enum.join()}
    else
      :error
    end
  end

  defp structural_children(children) do
    Enum.reject(children, fn
      {:text, value} -> String.trim(value) == ""
      _node -> false
    end)
  end

  defp local({_namespace, name}), do: local(name)

  defp local(name) do
    case String.split(to_string(name), ":") do
      [_namespace, local] -> local
      [local] -> local
    end
  end
end
