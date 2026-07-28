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

  test "Quiet=false explicitly selects verbose responses" do
    xml = "<Delete><Quiet>false</Quiet><Object><Key>k</Key></Object></Delete>"

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

  test "wrong root unknown elements misnesting and mixed text fail closed" do
    invalid = [
      "<NotDelete><Object><Key>k</Key></Object></NotDelete>",
      "<Delete><Object><Key>k</Key></Object><Extra/></Delete>",
      "<Delete>text<Object><Key>k</Key></Object></Delete>",
      "<Delete><Key>k</Key><Object><Key>k</Key></Object></Delete>",
      "<Delete><Object><Key>k</Key><Extra/></Object></Delete>",
      "<Delete><Object><Quiet>true</Quiet><Key>k</Key></Object></Delete>"
    ]

    for xml <- invalid do
      assert {:error, :malformed_xml} = P.parse(xml)
    end
  end

  test "missing empty duplicate or nested object fields fail closed" do
    invalid = [
      "<Delete><Object></Object></Delete>",
      "<Delete><Object><Key></Key></Object></Delete>",
      "<Delete><Object><Key><Value>k</Value></Key></Object></Delete>",
      "<Delete><Object><Key>k</Key><Key>other</Key></Object></Delete>",
      "<Delete><Object><Key>k</Key><VersionId>v1</VersionId><VersionId>v2</VersionId></Object></Delete>",
      "<Delete><Object><Key>k</Key><VersionId><Value>v1</Value></VersionId></Object></Delete>"
    ]

    for xml <- invalid do
      assert {:error, :malformed_xml} = P.parse(xml)
    end
  end

  test "Quiet must be a singleton boolean value" do
    invalid = [
      "<Delete><Quiet></Quiet><Object><Key>k</Key></Object></Delete>",
      "<Delete><Quiet>true</Quiet><Quiet>true</Quiet><Object><Key>k</Key></Object></Delete>",
      "<Delete><Quiet>false</Quiet><Quiet>true</Quiet><Object><Key>k</Key></Object></Delete>",
      "<Delete><Quiet>false</Quiet><Quiet>false</Quiet><Object><Key>k</Key></Object></Delete>",
      "<Delete><Quiet>TRUE</Quiet><Object><Key>k</Key></Object></Delete>",
      "<Delete><Quiet>0</Quiet><Object><Key>k</Key></Object></Delete>",
      "<Delete><Quiet><Value>true</Value></Quiet><Object><Key>k</Key></Object></Delete>"
    ]

    for xml <- invalid do
      assert {:error, :malformed_xml} = P.parse(xml)
    end
  end

  test "conditional delete object fields fail closed as unsupported instead of being ignored" do
    for field <- ["ETag", "LastModifiedTime", "Size"] do
      xml = "<Delete><Object><Key>k</Key><#{field}>value</#{field}></Object></Delete>"
      assert {:error, :unsupported_conditional_delete} = P.parse(xml)
    end
  end

  test "畸形 XML → :malformed_xml" do
    assert {:error, :malformed_xml} = P.parse("<Delete><Object>")
  end
end
