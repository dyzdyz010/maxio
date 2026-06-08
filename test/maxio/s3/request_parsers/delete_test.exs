defmodule Maxio.S3.RequestParsers.DeleteTest do
  use ExUnit.Case, async: true
  alias Maxio.S3.RequestParsers.Delete, as: P

  test "解析多个 Object（含 VersionId）+ Quiet" do
    xml = """
    <Delete>
      <Quiet>true</Quiet>
      <Object><Key>a.txt</Key></Object>
      <Object><Key>b.txt</Key><VersionId>v2</VersionId></Object>
    </Delete>
    """

    assert {:ok, %{quiet: true, objects: objs}} = P.parse(xml)
    assert objs == [%{key: "a.txt", version_id: nil}, %{key: "b.txt", version_id: "v2"}]
  end

  test "默认 verbose（无 Quiet）" do
    xml = "<Delete><Object><Key>k</Key></Object></Delete>"
    assert {:ok, %{quiet: false, objects: [%{key: "k", version_id: nil}]}} = P.parse(xml)
  end

  test "带命名空间解析" do
    xml =
      ~s(<Delete xmlns="http://s3.amazonaws.com/doc/2006-03-01/"><Object><Key>k</Key></Object></Delete>)

    assert {:ok, %{objects: [%{key: "k", version_id: nil}]}} = P.parse(xml)
  end

  test "无 Object → :malformed_xml" do
    assert {:error, :malformed_xml} = P.parse("<Delete></Delete>")
  end

  test "畸形 XML → :malformed_xml" do
    assert {:error, :malformed_xml} = P.parse("<Delete><Object>")
  end
end
