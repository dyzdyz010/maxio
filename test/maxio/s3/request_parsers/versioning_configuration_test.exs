defmodule Maxio.S3.RequestParsers.VersioningConfigurationTest do
  use ExUnit.Case, async: true
  alias Maxio.S3.RequestParsers.VersioningConfiguration, as: P

  test "Enabled" do
    xml =
      ~s(<VersioningConfiguration xmlns="http://s3.amazonaws.com/doc/2006-03-01/"><Status>Enabled</Status></VersioningConfiguration>)

    assert {:ok, %{status: "Enabled", mfa_delete: nil}} = P.parse(xml)
  end

  test "Suspended" do
    xml = ~s(<VersioningConfiguration><Status>Suspended</Status></VersioningConfiguration>)
    assert {:ok, %{status: "Suspended", mfa_delete: nil}} = P.parse(xml)
  end

  test "Enabled + MfaDelete" do
    xml =
      ~s(<VersioningConfiguration><Status>Enabled</Status><MfaDelete>Enabled</MfaDelete></VersioningConfiguration>)

    assert {:ok, %{status: "Enabled", mfa_delete: "Enabled"}} = P.parse(xml)
  end

  test "空 body（无 Status）→ status nil" do
    xml = ~s(<VersioningConfiguration></VersioningConfiguration>)
    assert {:ok, %{status: nil, mfa_delete: nil}} = P.parse(xml)
  end

  test "MfaDelete without Status parses and is rejected by handler MFA gate" do
    xml = ~s(<VersioningConfiguration><MfaDelete>Enabled</MfaDelete></VersioningConfiguration>)
    assert {:ok, %{status: nil, mfa_delete: "Enabled"}} = P.parse(xml)
  end

  test "非法 XML → malformed_xml" do
    assert {:error, :malformed_xml} = P.parse("<bad")
  end

  test "非法 Status 值（非 Enabled/Suspended）→ malformed_xml" do
    xml = ~s(<VersioningConfiguration><Status>Bogus</Status></VersioningConfiguration>)
    assert {:error, :malformed_xml} = P.parse(xml)
  end

  test "rejects wrong root unknown elements duplicate elements misnested elements and mixed text" do
    assert {:error, :malformed_xml} = P.parse("<Wrong><Status>Enabled</Status></Wrong>")

    assert {:error, :malformed_xml} =
             P.parse(
               "<VersioningConfiguration><Unknown>Enabled</Unknown></VersioningConfiguration>"
             )

    assert {:error, :malformed_xml} =
             P.parse(
               "<VersioningConfiguration><Status>Enabled</Status><Status>Suspended</Status></VersioningConfiguration>"
             )

    assert {:error, :malformed_xml} =
             P.parse(
               "<VersioningConfiguration><Wrapper><Status>Enabled</Status></Wrapper></VersioningConfiguration>"
             )

    assert {:error, :malformed_xml} =
             P.parse("""
             <VersioningConfiguration>
               text
               <Status>Enabled</Status>
             </VersioningConfiguration>
             """)
  end

  test "rejects empty singleton values and nested leaf text" do
    assert {:error, :malformed_xml} =
             P.parse("<VersioningConfiguration><Status></Status></VersioningConfiguration>")

    assert {:error, :malformed_xml} =
             P.parse(
               "<VersioningConfiguration><Status><Nested>Enabled</Nested></Status></VersioningConfiguration>"
             )
  end
end
