defmodule Maxio.S3.RequestParsers.AccessControlPolicy do
  @moduledoc """
  PutBucketAcl/PutObjectAcl 的 XML body 解析（saxy SAX）。MVP 把显式 grant XML 映射回最接近的
  canned 名（owner-only→private；AllUsers READ→public-read；AllUsers READ+WRITE→public-read-write；
  AuthenticatedUsers READ→authenticated-read）。容忍 xmlns="" 重置与 <Type> 元素变体（只读不产出）。
  无法识别的精细组合 → 退化为 private（保守，不静默放行更多权限）。
  返回 {:ok, canned :: String.t()} | {:error, :malformed_xml}。
  """
  @behaviour Saxy.Handler

  @all_users "http://acs.amazonaws.com/groups/global/AllUsers"
  @auth_users "http://acs.amazonaws.com/groups/global/AuthenticatedUsers"

  @spec parse(binary()) :: {:ok, String.t()} | {:error, :malformed_xml}
  def parse(xml) when is_binary(xml) do
    init = %{grants: [], cur_uri: nil, cur_perm: nil, in: nil, text: nil}

    case Saxy.parse_string(xml, __MODULE__, init) do
      {:ok, %{grants: grants}} -> {:ok, classify(grants)}
      {:error, _} -> {:error, :malformed_xml}
    end
  end

  @impl true
  def handle_event(:start_document, _p, s), do: {:ok, s}

  @impl true
  def handle_event(:start_element, {name, _attrs}, s) do
    case local(name) do
      "Grant" -> {:ok, %{s | cur_uri: nil, cur_perm: nil, in: nil}}
      "URI" -> {:ok, %{s | in: :uri, text: ""}}
      "Permission" -> {:ok, %{s | in: :perm, text: ""}}
      _ -> {:ok, %{s | in: nil}}
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
      "URI" -> {:ok, %{s | cur_uri: String.trim(s.text || ""), in: nil, text: nil}}
      "Permission" -> {:ok, %{s | cur_perm: String.trim(s.text || ""), in: nil, text: nil}}
      "Grant" -> {:ok, %{s | grants: [{s.cur_uri, s.cur_perm} | s.grants], in: nil}}
      _ -> {:ok, %{s | in: nil, text: nil}}
    end
  end

  @impl true
  def handle_event(:end_document, _d, s), do: {:ok, s}

  # 把抓到的 (uri, perm) 组 grant 分类回 canned。仅看组 grantee（CanonicalUser owner grant 忽略）。
  defp classify(grants) do
    group_perms =
      grants
      |> Enum.filter(fn {uri, _p} -> uri in [@all_users, @auth_users] end)
      |> Enum.map(fn {uri, p} -> {uri, String.upcase(to_string(p))} end)
      |> MapSet.new()

    cond do
      MapSet.member?(group_perms, {@all_users, "WRITE"}) and
          MapSet.member?(group_perms, {@all_users, "READ"}) ->
        "public-read-write"

      MapSet.member?(group_perms, {@all_users, "READ"}) ->
        "public-read"

      MapSet.member?(group_perms, {@auth_users, "READ"}) ->
        "authenticated-read"

      true ->
        "private"
    end
  end

  defp local(name) do
    case String.split(name, ":") do
      [_ns, l] -> l
      [l] -> l
    end
  end
end
