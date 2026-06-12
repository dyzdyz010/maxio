defmodule Maxio.S3.Views.AccessControlPolicy do
  @moduledoc """
  GetBucketAcl / GetObjectAcl 响应 XML（AccessControlPolicy）。
  对齐官方（§RESEARCH bake-in）：prolog + root xmlns；grantee 用 xsi:type 属性形式
  （xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"）；canned 名展开为具体 Grant。
  owner_id 为资源所有者 canonical user id（本系统用 "maxio" 合成 id）。
  """
  import Saxy.XML
  alias Maxio.Policy.ACL
  alias Maxio.S3.XML

  @all_users "http://acs.amazonaws.com/groups/global/AllUsers"
  @auth_users "http://acs.amazonaws.com/groups/global/AuthenticatedUsers"
  @xsi "http://www.w3.org/2001/XMLSchema-instance"

  @doc """
  render(%{canned, grants, owner_id, owner_display}) :: iodata()
  显式 grants 非空时逐条渲染；否则把 canned 名展开为 owner FULL_CONTROL + 公共/组 grant。
  """
  @spec render(map()) :: iodata()
  def render(%{canned: canned, owner_id: owner_id, owner_display: owner_display} = assigns) do
    explicit_grants =
      assigns
      |> Map.get(:grants, [])
      |> ACL.grants_from_doc()

    grants =
      [owner_full_control(owner_id, owner_display) | render_extra_grants(explicit_grants, canned)]

    root =
      element("AccessControlPolicy", [{"xmlns", XML.namespace()}], [
        element("Owner", [], [
          element("ID", [], characters(owner_id)),
          element("DisplayName", [], characters(owner_display))
        ]),
        element("AccessControlList", [], grants)
      ])

    XML.encode(root)
  end

  defp owner_full_control(id, display) do
    element("Grant", [], [
      element("Grantee", [{"xmlns:xsi", @xsi}, {"xsi:type", "CanonicalUser"}], [
        element("ID", [], characters(id)),
        element("DisplayName", [], characters(display))
      ]),
      element("Permission", [], characters("FULL_CONTROL"))
    ])
  end

  defp extra_grants("public-read"), do: [group_grant(@all_users, "READ")]

  defp extra_grants("public-read-write"),
    do: [group_grant(@all_users, "READ"), group_grant(@all_users, "WRITE")]

  defp extra_grants("authenticated-read"), do: [group_grant(@auth_users, "READ")]
  defp extra_grants(_private_or_other), do: []

  defp render_extra_grants([], canned), do: extra_grants(canned)
  defp render_extra_grants(grants, _canned), do: Enum.map(grants, &render_grant/1)

  defp render_grant(%{
         "grantee" => %{"type" => "CanonicalUser", "id" => id} = grantee,
         "permission" => permission
       }) do
    display = Map.get(grantee, "display_name")

    grantee_children =
      [element("ID", [], characters(id))]
      |> maybe_display(display)

    element("Grant", [], [
      element("Grantee", [{"xmlns:xsi", @xsi}, {"xsi:type", "CanonicalUser"}], grantee_children),
      element("Permission", [], characters(permission))
    ])
  end

  defp render_grant(%{
         "grantee" => %{"type" => "Group", "uri" => uri},
         "permission" => permission
       }) do
    group_grant(uri, permission)
  end

  defp maybe_display(children, nil), do: children
  defp maybe_display(children, ""), do: children

  defp maybe_display(children, display),
    do: children ++ [element("DisplayName", [], characters(display))]

  defp group_grant(uri, permission) do
    element("Grant", [], [
      element("Grantee", [{"xmlns:xsi", @xsi}, {"xsi:type", "Group"}], [
        element("URI", [], characters(uri))
      ]),
      element("Permission", [], characters(permission))
    ])
  end
end
