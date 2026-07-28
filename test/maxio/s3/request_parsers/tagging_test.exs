defmodule Maxio.S3.RequestParsers.TaggingTest do
  use ExUnit.Case, async: true

  alias Maxio.S3.RequestParsers.Tagging

  test "parses namespaced tags and preserves empty values" do
    xml = """
    <s3:Tagging xmlns:s3="http://s3.amazonaws.com/doc/2006-03-01/">
      <s3:TagSet>
        <s3:Tag><s3:Key>env</s3:Key><s3:Value>prod</s3:Value></s3:Tag>
        <s3:Tag><s3:Key>empty</s3:Key><s3:Value></s3:Value></s3:Tag>
      </s3:TagSet>
    </s3:Tagging>
    """

    assert {:ok, [{"env", "prod"}, {"empty", ""}]} = Tagging.parse(xml)
  end

  test "parses empty TagSet as empty tags" do
    assert {:ok, []} = Tagging.parse("<Tagging><TagSet></TagSet></Tagging>")
  end

  test "rejects wrong root missing TagSet unknown elements misnested elements and mixed text" do
    assert {:error, :malformed_xml} = Tagging.parse("<Wrong><TagSet/></Wrong>")
    assert {:error, :malformed_xml} = Tagging.parse("<Tagging/>")

    assert {:error, :malformed_xml} =
             Tagging.parse("<Tagging><TagSet><Unknown/></TagSet></Tagging>")

    assert {:error, :malformed_xml} =
             Tagging.parse("<Tagging><Tag><Key>env</Key><Value>prod</Value></Tag></Tagging>")

    assert {:error, :malformed_xml} =
             Tagging.parse("""
             <Tagging>
               junk
               <TagSet><Tag><Key>env</Key><Value>prod</Value></Tag></TagSet>
             </Tagging>
             """)
  end

  test "rejects duplicate singleton fields missing required elements and nested leaf text" do
    assert {:error, :malformed_xml} =
             Tagging.parse("""
             <Tagging>
               <TagSet>
                 <Tag><Key>env</Key><Key>team</Key><Value>prod</Value></Tag>
               </TagSet>
             </Tagging>
             """)

    assert {:error, :malformed_xml} =
             Tagging.parse("<Tagging><TagSet><Tag><Key>env</Key></Tag></TagSet></Tagging>")

    assert {:error, :malformed_xml} =
             Tagging.parse("""
             <Tagging>
               <TagSet>
                 <Tag><Key><Nested>env</Nested></Key><Value>prod</Value></Tag>
               </TagSet>
             </Tagging>
             """)
  end

  test "lets empty keys reach tag validation rather than rewriting them" do
    assert {:ok, [{"", "value"}]} =
             Tagging.parse(
               "<Tagging><TagSet><Tag><Key></Key><Value>value</Value></Tag></TagSet></Tagging>"
             )
  end
end
