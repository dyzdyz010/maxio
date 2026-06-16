defmodule Maxio.S3.RequestParsers.ObjectLockTest do
  use ExUnit.Case, async: true

  alias Maxio.S3.RequestParsers.ObjectLock

  test "parses enabled ObjectLockConfiguration with optional default retention" do
    assert ObjectLock.parse("""
           <ObjectLockConfiguration xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
             <ObjectLockEnabled>Enabled</ObjectLockEnabled>
           </ObjectLockConfiguration>
           """) == {:ok, %{"ObjectLockEnabled" => "Enabled"}}

    assert ObjectLock.parse("""
           <ObjectLockConfiguration>
             <ObjectLockEnabled>Enabled</ObjectLockEnabled>
             <Rule>
               <DefaultRetention>
                 <Mode>GOVERNANCE</Mode>
                 <Days>7</Days>
               </DefaultRetention>
             </Rule>
           </ObjectLockConfiguration>
           """) ==
             {:ok,
              %{
                "ObjectLockEnabled" => "Enabled",
                "Rule" => %{
                  "DefaultRetention" => %{"Mode" => "GOVERNANCE", "Days" => 7}
                }
              }}

    assert ObjectLock.parse("""
           <s3:ObjectLockConfiguration xmlns:s3="http://s3.amazonaws.com/doc/2006-03-01/">
             <s3:ObjectLockEnabled>Enabled</s3:ObjectLockEnabled>
             <s3:Rule>
               <s3:DefaultRetention>
                 <s3:Mode>COMPLIANCE</s3:Mode>
                 <s3:Years>1</s3:Years>
               </s3:DefaultRetention>
             </s3:Rule>
           </s3:ObjectLockConfiguration>
           """) ==
             {:ok,
              %{
                "ObjectLockEnabled" => "Enabled",
                "Rule" => %{
                  "DefaultRetention" => %{"Mode" => "COMPLIANCE", "Years" => 1}
                }
              }}
  end

  test "rejects invalid ObjectLockConfiguration shapes" do
    for xml <- [
          "<ObjectLockConfiguration />",
          """
          <ObjectLockConfiguration>
            <ObjectLockEnabled>Disabled</ObjectLockEnabled>
          </ObjectLockConfiguration>
          """,
          """
          <ObjectLockConfiguration>
            <ObjectLockEnabled>Enabled</ObjectLockEnabled>
            <Rule></Rule>
          </ObjectLockConfiguration>
          """,
          """
          <ObjectLockConfiguration>
            <ObjectLockEnabled>Enabled</ObjectLockEnabled>
            <Rule><DefaultRetention><Days>1</Days></DefaultRetention></Rule>
          </ObjectLockConfiguration>
          """,
          """
          <ObjectLockConfiguration>
            <ObjectLockEnabled>Enabled</ObjectLockEnabled>
            <Rule><DefaultRetention><Mode>LEGAL</Mode><Days>1</Days></DefaultRetention></Rule>
          </ObjectLockConfiguration>
          """,
          """
          <ObjectLockConfiguration>
            <ObjectLockEnabled>Enabled</ObjectLockEnabled>
            <Rule><DefaultRetention><Mode>GOVERNANCE</Mode><Days>0</Days></DefaultRetention></Rule>
          </ObjectLockConfiguration>
          """,
          """
          <ObjectLockConfiguration>
            <ObjectLockEnabled>Enabled</ObjectLockEnabled>
            <Rule><DefaultRetention><Mode>GOVERNANCE</Mode><Days>1</Days><Years>1</Years></DefaultRetention></Rule>
          </ObjectLockConfiguration>
          """,
          """
          <ObjectLockConfiguration>
            <ObjectLockEnabled>Enabled</ObjectLockEnabled>
            <Unknown />
          </ObjectLockConfiguration>
          """,
          "<Wrapper><ObjectLockConfiguration /></Wrapper>"
        ] do
      assert {:error, :malformed_xml} = ObjectLock.parse(xml)
    end
  end
end
