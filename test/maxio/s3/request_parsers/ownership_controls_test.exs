defmodule Maxio.S3.RequestParsers.OwnershipControlsTest do
  use ExUnit.Case, async: true

  alias Maxio.S3.RequestParsers.OwnershipControls

  test "parses supported ObjectOwnership values" do
    for value <- ~w(BucketOwnerEnforced BucketOwnerPreferred ObjectWriter) do
      xml = """
      <OwnershipControls xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
        <Rule>
          <ObjectOwnership>#{value}</ObjectOwnership>
        </Rule>
      </OwnershipControls>
      """

      assert OwnershipControls.parse(xml) == {:ok, %{"ObjectOwnership" => value}}
    end
  end

  test "rejects missing or unsupported ObjectOwnership" do
    assert {:error, :malformed_xml} =
             OwnershipControls.parse("""
             <OwnershipControls>
               <Rule></Rule>
             </OwnershipControls>
             """)

    assert {:error, :malformed_xml} =
             OwnershipControls.parse("""
             <OwnershipControls>
               <Rule><ObjectOwnership>ACLsEnabled</ObjectOwnership></Rule>
             </OwnershipControls>
             """)
  end

  test "rejects wrong root unknown duplicate misnested mixed text and nested leaf nodes" do
    cases = [
      """
      <Wrapper>
        <OwnershipControls>
          <Rule><ObjectOwnership>BucketOwnerEnforced</ObjectOwnership></Rule>
        </OwnershipControls>
      </Wrapper>
      """,
      """
      <OwnershipControls>
        <Unknown>BucketOwnerEnforced</Unknown>
      </OwnershipControls>
      """,
      """
      <OwnershipControls>
        <Rule>
          <ObjectOwnership>BucketOwnerEnforced</ObjectOwnership>
          <ObjectOwnership>ObjectWriter</ObjectOwnership>
        </Rule>
      </OwnershipControls>
      """,
      """
      <OwnershipControls>
        <ObjectOwnership>BucketOwnerEnforced</ObjectOwnership>
      </OwnershipControls>
      """,
      """
      <OwnershipControls>
        text
        <Rule><ObjectOwnership>BucketOwnerEnforced</ObjectOwnership></Rule>
      </OwnershipControls>
      """,
      """
      <OwnershipControls>
        <Rule><ObjectOwnership><Value>BucketOwnerEnforced</Value></ObjectOwnership></Rule>
      </OwnershipControls>
      """,
      """
      <OwnershipControls>
        <Rule><ObjectOwnership>BucketOwnerPreferred</ObjectOwnership></Rule>
        <Rule><ObjectOwnership>ObjectWriter</ObjectOwnership></Rule>
      </OwnershipControls>
      """
    ]

    for xml <- cases do
      assert {:error, :malformed_xml} = OwnershipControls.parse(xml)
    end
  end
end
