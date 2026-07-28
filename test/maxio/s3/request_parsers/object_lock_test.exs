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
            <Rule><DefaultRetention><Mode>governance</Mode><Days>1</Days></DefaultRetention></Rule>
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
          """
          <ObjectLockConfiguration>
            text
            <ObjectLockEnabled>Enabled</ObjectLockEnabled>
          </ObjectLockConfiguration>
          """,
          """
          <ObjectLockConfiguration>
            <ObjectLockEnabled><Value>Enabled</Value></ObjectLockEnabled>
          </ObjectLockConfiguration>
          """,
          """
          <ObjectLockConfiguration>
            <ObjectLockEnabled>Enabled</ObjectLockEnabled>
            <ObjectLockEnabled>Enabled</ObjectLockEnabled>
          </ObjectLockConfiguration>
          """,
          """
          <ObjectLockConfiguration>
            <ObjectLockEnabled>Enabled</ObjectLockEnabled>
            <Rule><DefaultRetention><Mode>GOVERNANCE</Mode><Days>1</Days></DefaultRetention></Rule>
            <Rule><DefaultRetention><Mode>GOVERNANCE</Mode><Days>2</Days></DefaultRetention></Rule>
          </ObjectLockConfiguration>
          """,
          """
          <ObjectLockConfiguration>
            <ObjectLockEnabled>Enabled</ObjectLockEnabled>
            <Rule>
              <DefaultRetention>
                <Mode>GOVERNANCE</Mode>
                <Mode>COMPLIANCE</Mode>
                <Days>1</Days>
              </DefaultRetention>
            </Rule>
          </ObjectLockConfiguration>
          """,
          """
          <ObjectLockConfiguration>
            <ObjectLockEnabled>Enabled</ObjectLockEnabled>
            <Rule><DefaultRetention><Mode>GOVERNANCE</Mode><Days></Days></DefaultRetention></Rule>
          </ObjectLockConfiguration>
          """,
          "<Wrapper><ObjectLockConfiguration /></Wrapper>"
        ] do
      assert {:error, :malformed_xml} = ObjectLock.parse(xml)
    end
  end

  test "parses object retention XML" do
    assert {:ok,
            %{
              object_lock_mode: "GOVERNANCE",
              object_lock_retain_until: ~U[2030-01-02 03:04:05Z]
            }} =
             ObjectLock.parse_retention("""
             <Retention xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
               <Mode>GOVERNANCE</Mode>
               <RetainUntilDate>2030-01-02T03:04:05Z</RetainUntilDate>
             </Retention>
             """)
  end

  test "parses object legal hold XML" do
    assert {:ok, %{object_lock_legal_hold: "ON"}} =
             ObjectLock.parse_legal_hold("""
             <LegalHold xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
               <Status>ON</Status>
             </LegalHold>
             """)
  end

  test "rejects invalid object retention and legal hold shapes" do
    for xml <- [
          "<Retention><Mode>GOVERNANCE</Mode></Retention>",
          "<Retention><Mode>LEGAL</Mode><RetainUntilDate>2030-01-02T03:04:05Z</RetainUntilDate></Retention>",
          "<Retention><Mode>governance</Mode><RetainUntilDate>2030-01-02T03:04:05Z</RetainUntilDate></Retention>",
          "<ObjectLockConfiguration><Mode>GOVERNANCE</Mode><RetainUntilDate>2030-01-02T03:04:05Z</RetainUntilDate></ObjectLockConfiguration>",
          "<Retention><Mode></Mode><RetainUntilDate>2030-01-02T03:04:05Z</RetainUntilDate></Retention>",
          "<Retention><Mode><Value>GOVERNANCE</Value></Mode><RetainUntilDate>2030-01-02T03:04:05Z</RetainUntilDate></Retention>",
          "<Retention>text<Mode>GOVERNANCE</Mode><RetainUntilDate>2030-01-02T03:04:05Z</RetainUntilDate></Retention>",
          "<Retention><Mode>GOVERNANCE</Mode><Mode>COMPLIANCE</Mode><RetainUntilDate>2030-01-02T03:04:05Z</RetainUntilDate></Retention>",
          "<Retention><Mode>GOVERNANCE</Mode><RetainUntilDate>2030-01-02T03:04:05Z</RetainUntilDate><Unknown /></Retention>"
        ] do
      assert {:error, :malformed_xml} = ObjectLock.parse_retention(xml)
    end

    for xml <- [
          "<LegalHold><Status>MAYBE</Status></LegalHold>",
          "<LegalHold><Status>on</Status></LegalHold>",
          "<Retention><Status>ON</Status></Retention>",
          "<LegalHold><Status></Status></LegalHold>",
          "<LegalHold><Status><Value>ON</Value></Status></LegalHold>",
          "<LegalHold>text<Status>ON</Status></LegalHold>",
          "<LegalHold><Status>ON</Status><Status>OFF</Status></LegalHold>",
          "<LegalHold><Status>ON</Status><Unknown /></LegalHold>"
        ] do
      assert {:error, :malformed_xml} = ObjectLock.parse_legal_hold(xml)
    end
  end
end
