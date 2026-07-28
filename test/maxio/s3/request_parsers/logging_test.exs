defmodule Maxio.S3.RequestParsers.LoggingTest do
  use ExUnit.Case, async: true

  alias Maxio.S3.RequestParsers.Logging

  test "parses empty BucketLoggingStatus" do
    assert Logging.parse("""
           <BucketLoggingStatus xmlns="http://s3.amazonaws.com/doc/2006-03-01/" />
           """) == {:ok, %{"LoggingEnabled" => nil}}
  end

  test "parses basic LoggingEnabled target" do
    xml = """
    <BucketLoggingStatus xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
      <LoggingEnabled>
        <TargetBucket>log-target</TargetBucket>
        <TargetPrefix>logs/</TargetPrefix>
      </LoggingEnabled>
    </BucketLoggingStatus>
    """

    assert {:ok, %{"LoggingEnabled" => enabled}} = Logging.parse(xml)
    assert enabled["TargetBucket"] == "log-target"
    assert enabled["TargetPrefix"] == "logs/"
    assert enabled["TargetGrants"] == []
    assert enabled["TargetObjectKeyFormat"] == %{"type" => "simple"}
  end

  test "parses empty TargetPrefix as an explicitly configured empty prefix" do
    xml = """
    <BucketLoggingStatus xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
      <LoggingEnabled>
        <TargetBucket>log-target</TargetBucket>
        <TargetPrefix></TargetPrefix>
      </LoggingEnabled>
    </BucketLoggingStatus>
    """

    assert {:ok, %{"LoggingEnabled" => enabled}} = Logging.parse(xml)
    assert enabled["TargetPrefix"] == ""
  end

  test "parses namespaced target grants and partitioned key format" do
    xml = """
    <s3:BucketLoggingStatus xmlns:s3="http://s3.amazonaws.com/doc/2006-03-01/">
      <s3:LoggingEnabled>
        <s3:TargetBucket>log-target</s3:TargetBucket>
        <s3:TargetPrefix>logs/</s3:TargetPrefix>
        <s3:TargetGrants>
          <s3:Grant>
            <s3:Grantee xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xsi:type="CanonicalUser">
              <s3:ID>abc123</s3:ID>
              <s3:DisplayName>owner</s3:DisplayName>
            </s3:Grantee>
            <s3:Permission>FULL_CONTROL</s3:Permission>
          </s3:Grant>
          <s3:Grant>
            <s3:Grantee xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xsi:type="Group">
              <s3:URI>http://acs.amazonaws.com/groups/s3/LogDelivery</s3:URI>
            </s3:Grantee>
            <s3:Permission>WRITE</s3:Permission>
          </s3:Grant>
        </s3:TargetGrants>
        <s3:TargetObjectKeyFormat>
          <s3:PartitionedPrefix>
            <s3:PartitionDateSource>EventTime</s3:PartitionDateSource>
          </s3:PartitionedPrefix>
        </s3:TargetObjectKeyFormat>
      </s3:LoggingEnabled>
    </s3:BucketLoggingStatus>
    """

    assert {:ok, %{"LoggingEnabled" => enabled}} = Logging.parse(xml)

    assert enabled["TargetGrants"] == [
             %{
               "Grantee" => %{
                 "type" => "CanonicalUser",
                 "ID" => "abc123",
                 "DisplayName" => "owner"
               },
               "Permission" => "FULL_CONTROL"
             },
             %{
               "Grantee" => %{
                 "type" => "Group",
                 "URI" => "http://acs.amazonaws.com/groups/s3/LogDelivery"
               },
               "Permission" => "WRITE"
             }
           ]

    assert enabled["TargetObjectKeyFormat"] == %{
             "type" => "partitioned",
             "partition_date_source" => "EventTime"
           }
  end

  test "rejects wrong root duplicate logging and duplicate target fields" do
    assert {:error, :malformed_xml} =
             Logging.parse("""
             <Wrapper><BucketLoggingStatus /></Wrapper>
             """)

    assert {:error, :malformed_xml} =
             Logging.parse("""
             <BucketLoggingStatus>
               <LoggingEnabled><TargetBucket>a</TargetBucket></LoggingEnabled>
               <LoggingEnabled><TargetBucket>b</TargetBucket></LoggingEnabled>
             </BucketLoggingStatus>
             """)

    assert {:error, :malformed_xml} =
             Logging.parse("""
             <BucketLoggingStatus>
               <LoggingEnabled>
                 <TargetBucket>a</TargetBucket>
                 <TargetBucket>b</TargetBucket>
               </LoggingEnabled>
             </BucketLoggingStatus>
             """)
  end

  test "rejects unknown misnested or mixed text elements" do
    assert {:error, :malformed_xml} =
             Logging.parse("""
             <BucketLoggingStatus>
               unexpected
               <LoggingEnabled><TargetBucket>a</TargetBucket></LoggingEnabled>
             </BucketLoggingStatus>
             """)

    assert {:error, :malformed_xml} =
             Logging.parse("""
             <BucketLoggingStatus>
               <LoggingEnabled><Wrapper><TargetBucket>a</TargetBucket></Wrapper></LoggingEnabled>
             </BucketLoggingStatus>
             """)

    assert {:error, :malformed_xml} =
             Logging.parse("""
             <BucketLoggingStatus>
               <LoggingEnabled><Unknown /></LoggingEnabled>
             </BucketLoggingStatus>
             """)
  end

  test "rejects missing required target fields" do
    assert {:error, :malformed_xml} =
             Logging.parse("""
             <BucketLoggingStatus>
               <LoggingEnabled>
                 <TargetBucket>log-target</TargetBucket>
               </LoggingEnabled>
             </BucketLoggingStatus>
             """)

    assert {:error, :malformed_xml} =
             Logging.parse("""
             <BucketLoggingStatus>
               <LoggingEnabled>
                 <TargetPrefix>logs/</TargetPrefix>
               </LoggingEnabled>
             </BucketLoggingStatus>
             """)
  end

  test "parses partitioned key format without explicit date source" do
    assert {:ok, %{"LoggingEnabled" => enabled}} =
             Logging.parse("""
             <BucketLoggingStatus>
               <LoggingEnabled>
                 <TargetBucket>log-target</TargetBucket>
                 <TargetPrefix>logs/</TargetPrefix>
                 <TargetObjectKeyFormat>
                   <PartitionedPrefix />
                 </TargetObjectKeyFormat>
               </LoggingEnabled>
             </BucketLoggingStatus>
             """)

    assert enabled["TargetObjectKeyFormat"] == %{
             "type" => "partitioned",
             "partition_date_source" => "EventTime"
           }
  end

  test "rejects invalid target object key format variants" do
    assert {:error, :malformed_xml} =
             Logging.parse("""
             <BucketLoggingStatus>
               <LoggingEnabled>
                 <TargetBucket>log-target</TargetBucket>
                 <TargetPrefix>logs/</TargetPrefix>
                 <TargetObjectKeyFormat>
                   <SimplePrefix />
                   <PartitionedPrefix>
                     <PartitionDateSource>DeliveryTime</PartitionDateSource>
                   </PartitionedPrefix>
                 </TargetObjectKeyFormat>
               </LoggingEnabled>
             </BucketLoggingStatus>
             """)

    assert {:error, :malformed_xml} =
             Logging.parse("""
             <BucketLoggingStatus>
               <LoggingEnabled>
                 <TargetBucket>log-target</TargetBucket>
                 <TargetPrefix>logs/</TargetPrefix>
                 <TargetObjectKeyFormat>
                   <PartitionedPrefix>
                     <PartitionDateSource>deliverytime</PartitionDateSource>
                   </PartitionedPrefix>
                 </TargetObjectKeyFormat>
               </LoggingEnabled>
             </BucketLoggingStatus>
             """)

    assert {:error, :malformed_xml} =
             Logging.parse("""
             <BucketLoggingStatus>
               <LoggingEnabled>
                 <TargetBucket>log-target</TargetBucket>
                 <TargetPrefix>logs/</TargetPrefix>
                 <TargetObjectKeyFormat>
                   <SimplePrefix>unexpected</SimplePrefix>
                 </TargetObjectKeyFormat>
               </LoggingEnabled>
             </BucketLoggingStatus>
             """)
  end

  test "rejects malformed grants and unsupported logging grant permissions" do
    invalid_cases = [
      """
      <BucketLoggingStatus>
        <LoggingEnabled>
          <TargetBucket>log-target</TargetBucket>
          <TargetPrefix>logs/</TargetPrefix>
          <TargetGrants />
        </LoggingEnabled>
      </BucketLoggingStatus>
      """,
      """
      <BucketLoggingStatus>
        <LoggingEnabled>
          <TargetBucket>log-target</TargetBucket>
          <TargetPrefix>logs/</TargetPrefix>
          <TargetGrants><Grant /></TargetGrants>
        </LoggingEnabled>
      </BucketLoggingStatus>
      """,
      """
      <BucketLoggingStatus>
        <LoggingEnabled>
          <TargetBucket>log-target</TargetBucket>
          <TargetPrefix>logs/</TargetPrefix>
          <TargetGrants>
            <Grant>
              <Grantee xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xsi:type="Group">
                <URI>http://acs.amazonaws.com/groups/s3/LogDelivery</URI>
              </Grantee>
              <Permission>READ_ACP</Permission>
            </Grant>
          </TargetGrants>
        </LoggingEnabled>
      </BucketLoggingStatus>
      """,
      """
      <BucketLoggingStatus>
        <LoggingEnabled>
          <TargetBucket>log-target</TargetBucket>
          <TargetPrefix>logs/</TargetPrefix>
          <TargetGrants>
            <Grant>
              <Grantee xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xsi:type="AmazonCustomerByEmail">
                <EmailAddress>owner@example.com</EmailAddress>
              </Grantee>
              <Permission>READ</Permission>
            </Grant>
          </TargetGrants>
        </LoggingEnabled>
      </BucketLoggingStatus>
      """,
      """
      <BucketLoggingStatus>
        <LoggingEnabled>
          <TargetBucket>log-target</TargetBucket>
          <TargetPrefix>logs/</TargetPrefix>
          <TargetGrants>
            <Grant>
              <Grantee xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xsi:type="CanonicalUser">
                <ID>abc123</ID>
                <URI>http://acs.amazonaws.com/groups/s3/LogDelivery</URI>
              </Grantee>
              <Permission>READ</Permission>
            </Grant>
          </TargetGrants>
        </LoggingEnabled>
      </BucketLoggingStatus>
      """
    ]

    for xml <- invalid_cases do
      assert {:error, :malformed_xml} = Logging.parse(xml)
    end
  end
end
