defmodule Maxio.S3.RequestParsers.AccessControlPolicy do
  @moduledoc """
  PutBucketAcl/PutObjectAcl 的 AccessControlPolicy XML body 解析（saxy SAX）。
  产出规范化 grant 列表；legacy `parse/1` 保持返回 canned 标签，供旧测试与调用方兼容。
  """
  @behaviour Saxy.Handler
  alias Maxio.Policy.ACL

  @spec parse(binary()) :: {:ok, String.t()} | {:error, :malformed_xml}
  def parse(xml) when is_binary(xml) do
    case parse_grants(xml) do
      {:ok, grants} -> {:ok, ACL.classify_grants(grants)}
      {:error, _} -> {:error, :malformed_xml}
    end
  end

  @spec parse_grants(binary()) ::
          {:ok, [map()]}
          | {:error, :malformed_xml | :unsupported_email | :invalid_grant | :too_many_grants}
  def parse_grants(xml) when is_binary(xml) do
    init = %{
      grants: [],
      cur_type: nil,
      cur_id: nil,
      cur_display_name: nil,
      cur_uri: nil,
      cur_email: nil,
      cur_perm: nil,
      in: nil,
      text: nil
    }

    case Saxy.parse_string(xml, __MODULE__, init) do
      {:ok, %{grants: grants}} -> ACL.normalize_grants(Enum.reverse(grants))
      {:error, _} -> {:error, :malformed_xml}
    end
  end

  @impl true
  def handle_event(:start_document, _p, s), do: {:ok, s}

  @impl true
  def handle_event(:start_element, {name, attrs}, s) do
    case local(name) do
      "Grant" ->
        {:ok,
         %{
           s
           | cur_type: nil,
             cur_id: nil,
             cur_display_name: nil,
             cur_uri: nil,
             cur_email: nil,
             cur_perm: nil,
             in: nil
         }}

      "Grantee" ->
        {:ok, %{s | cur_type: grantee_type(attrs), in: nil}}

      "ID" ->
        {:ok, %{s | in: :id, text: ""}}

      "DisplayName" ->
        {:ok, %{s | in: :display_name, text: ""}}

      "URI" ->
        {:ok, %{s | in: :uri, text: ""}}

      "EmailAddress" ->
        {:ok, %{s | in: :email, text: ""}}

      "Permission" ->
        {:ok, %{s | in: :perm, text: ""}}

      _ ->
        {:ok, %{s | in: nil}}
    end
  end

  @impl true
  def handle_event(:characters, _c, %{in: nil} = s), do: {:ok, s}

  def handle_event(:characters, c, %{text: t} = s) when is_binary(t),
    do: {:ok, %{s | text: t <> c}}

  def handle_event(:characters, _c, s), do: {:ok, s}

  @impl true
  def handle_event(:end_element, name, s) do
    case local(name) do
      "ID" ->
        {:ok, %{s | cur_id: String.trim(s.text || ""), in: nil, text: nil}}

      "DisplayName" ->
        {:ok, %{s | cur_display_name: String.trim(s.text || ""), in: nil, text: nil}}

      "URI" ->
        {:ok, %{s | cur_uri: String.trim(s.text || ""), in: nil, text: nil}}

      "EmailAddress" ->
        {:ok, %{s | cur_email: String.trim(s.text || ""), in: nil, text: nil}}

      "Permission" ->
        {:ok, %{s | cur_perm: String.trim(s.text || ""), in: nil, text: nil}}

      "Grant" ->
        {:ok, %{s | grants: [grant(s) | s.grants], in: nil}}

      _ ->
        {:ok, %{s | in: nil, text: nil}}
    end
  end

  @impl true
  def handle_event(:end_document, _d, s), do: {:ok, s}

  defp local(name) do
    case String.split(name, ":") do
      [_ns, l] -> l
      [l] -> l
    end
  end

  defp grantee_type(attrs) do
    Enum.find_value(attrs, fn {name, value} ->
      if local(name) == "type", do: value
    end)
  end

  defp grant(%{cur_email: email, cur_perm: permission}) when is_binary(email) and email != "" do
    %{
      "grantee" => %{"type" => "AmazonCustomerByEmail", "email" => email},
      "permission" => permission
    }
  end

  defp grant(%{cur_uri: uri, cur_perm: permission}) when is_binary(uri) and uri != "" do
    %{"grantee" => %{"type" => "Group", "uri" => uri}, "permission" => permission}
  end

  defp grant(%{cur_id: id, cur_display_name: display_name, cur_perm: permission})
       when is_binary(id) and id != "" do
    grantee =
      %{"type" => "CanonicalUser", "id" => id}
      |> maybe_put("display_name", display_name)

    %{"grantee" => grantee, "permission" => permission}
  end

  defp grant(%{cur_type: type, cur_perm: permission}) do
    %{"grantee" => %{"type" => type}, "permission" => permission}
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, ""), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
