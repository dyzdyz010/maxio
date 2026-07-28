defmodule Maxio.S3.RequestParsers.PublicAccessBlockTest do
  use ExUnit.Case, async: true

  alias Maxio.S3.PublicAccessBlock
  alias Maxio.S3.RequestParsers.PublicAccessBlock, as: Parser

  test "parses namespaced booleans with AWS uppercase lexical values" do
    xml = """
    <PublicAccessBlockConfiguration xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
      <BlockPublicAcls>TRUE</BlockPublicAcls>
      <IgnorePublicAcls>false</IgnorePublicAcls>
      <BlockPublicPolicy>False</BlockPublicPolicy>
      <RestrictPublicBuckets>true</RestrictPublicBuckets>
    </PublicAccessBlockConfiguration>
    """

    assert {:ok,
            %{
              "BlockPublicAcls" => true,
              "IgnorePublicAcls" => false,
              "BlockPublicPolicy" => false,
              "RestrictPublicBuckets" => true
            }} = Parser.parse(xml)
  end

  test "missing optional booleans default to false" do
    assert Parser.parse("<PublicAccessBlockConfiguration/>") ==
             {:ok, PublicAccessBlock.defaults()}
  end

  test "rejects invalid boolean values" do
    for value <- ["", "1", "yes"] do
      xml =
        "<PublicAccessBlockConfiguration><BlockPublicAcls>#{value}</BlockPublicAcls></PublicAccessBlockConfiguration>"

      assert {:error, :malformed_xml} = Parser.parse(xml)
    end
  end

  test "rejects wrong root unknown duplicate misnested mixed text and nested leaf nodes" do
    cases = [
      "<Wrapper><PublicAccessBlockConfiguration/></Wrapper>",
      "<PublicAccessBlockConfiguration><Unknown>false</Unknown></PublicAccessBlockConfiguration>",
      "<PublicAccessBlockConfiguration><BlockPublicAcls>true</BlockPublicAcls><BlockPublicAcls>false</BlockPublicAcls></PublicAccessBlockConfiguration>",
      "<PublicAccessBlockConfiguration><Wrapper><BlockPublicAcls>true</BlockPublicAcls></Wrapper></PublicAccessBlockConfiguration>",
      "<PublicAccessBlockConfiguration>text<BlockPublicAcls>true</BlockPublicAcls></PublicAccessBlockConfiguration>",
      "<PublicAccessBlockConfiguration><BlockPublicAcls><Value>true</Value></BlockPublicAcls></PublicAccessBlockConfiguration>"
    ]

    for xml <- cases do
      assert {:error, :malformed_xml} = Parser.parse(xml)
    end
  end
end
