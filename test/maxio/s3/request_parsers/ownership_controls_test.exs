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
end
