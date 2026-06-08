defmodule Maxio.S3.Views.VersioningConfiguration do
  @moduledoc """
  GetBucketVersioning 响应 XML。三态（官方核验 bake-in）：
    * never-set（Unversioned）→ 空自闭 <VersioningConfiguration/>（无 <Status>）。
    * Enabled/Suspended → 含 <Status>。
    * mfa_delete 非 nil → 追加 <MfaDelete>（仅曾配置时回显）。
  """
  import Saxy.XML
  alias Maxio.S3.XML

  @spec render(%{versioning: String.t(), mfa_delete: String.t() | nil}) :: iodata()
  def render(%{versioning: versioning, mfa_delete: mfa}) do
    children =
      []
      |> maybe_status(versioning)
      |> maybe_mfa(mfa)

    root = element("VersioningConfiguration", [{"xmlns", XML.namespace()}], children)
    XML.encode(root)
  end

  defp maybe_status(children, v) when v in ["Enabled", "Suspended"],
    do: children ++ [element("Status", [], characters(v))]

  defp maybe_status(children, _unversioned), do: children

  defp maybe_mfa(children, nil), do: children
  defp maybe_mfa(children, mfa), do: children ++ [element("MfaDelete", [], characters(mfa))]
end
