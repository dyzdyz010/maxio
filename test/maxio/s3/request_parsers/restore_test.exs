defmodule Maxio.S3.RequestParsers.RestoreTest do
  use ExUnit.Case, async: true

  alias Maxio.S3.RequestParsers.Restore

  test "parses restore request days and optional tier" do
    xml =
      ~s(<RestoreRequest><Days>7</Days><GlacierJobParameters><Tier>Bulk</Tier></GlacierJobParameters></RestoreRequest>)

    assert {:ok, request} = Restore.parse(xml)
    assert request["Days"] == 7
    assert request["Tier"] == "Bulk"
  end

  test "parses optional restore description" do
    xml =
      ~s(<RestoreRequest><Days>7</Days><Description>restore job</Description><GlacierJobParameters><Tier>Standard</Tier></GlacierJobParameters></RestoreRequest>)

    assert {:ok, request} = Restore.parse(xml)
    assert request["Days"] == 7
    assert request["Tier"] == "Standard"
    assert request["Description"] == "restore job"
  end

  test "rejects missing or invalid days" do
    assert {:error, :malformed_xml} = Restore.parse(~s(<RestoreRequest></RestoreRequest>))

    assert {:error, :malformed_xml} =
             Restore.parse(~s(<RestoreRequest><Days>0</Days></RestoreRequest>))
  end

  test "rejects duplicate or empty restore singleton fields" do
    cases = [
      ~s(<RestoreRequest><Days>1</Days><Tier>Bulk</Tier><Tier>Standard</Tier></RestoreRequest>),
      ~s(<RestoreRequest><Days>1</Days><Tier>Bulk</Tier></RestoreRequest>),
      ~s(<RestoreRequest><Days>1</Days><Description>a</Description><Description>b</Description></RestoreRequest>),
      ~s(<RestoreRequest><Days>1</Days><GlacierJobParameters /></RestoreRequest>),
      ~s(<RestoreRequest><Days>1</Days><GlacierJobParameters><Tier>Bulk</Tier><Tier>Standard</Tier></GlacierJobParameters></RestoreRequest>),
      ~s(<RestoreRequest><Days>1</Days><Tier>Bulk</Tier><GlacierJobParameters><Tier>Standard</Tier></GlacierJobParameters></RestoreRequest>)
    ]

    for xml <- cases do
      assert {:error, :malformed_xml} = Restore.parse(xml)
    end
  end

  test "parses select restore parameters and output location" do
    xml =
      """
      <RestoreRequest>
        <Type>SELECT</Type>
        <SelectParameters>
          <Expression>SELECT _1 FROM S3Object</Expression>
          <ExpressionType>SQL</ExpressionType>
          <InputSerialization>
            <CSV><FileHeaderInfo>NONE</FileHeaderInfo></CSV>
          </InputSerialization>
          <OutputSerialization>
            <CSV><FieldDelimiter>|</FieldDelimiter></CSV>
          </OutputSerialization>
        </SelectParameters>
        <OutputLocation>
          <S3>
            <BucketName>restore-out</BucketName>
            <Prefix>results</Prefix>
            <StorageClass>GLACIER_IR</StorageClass>
          </S3>
        </OutputLocation>
      </RestoreRequest>
      """

    assert {:ok, request} = Restore.parse(xml)
    assert request["Type"] == "SELECT"
    assert request["SelectParameters"].expression == "SELECT _1 FROM S3Object"
    assert request["SelectParameters"].input.format == "CSV"
    assert request["SelectParameters"].input.csv_options["FileHeaderInfo"] == "NONE"
    assert request["SelectParameters"].output.format == "CSV"
    assert request["SelectParameters"].output.csv_options["FieldDelimiter"] == "|"

    assert request["OutputLocation"] == %{
             "BucketName" => "restore-out",
             "Prefix" => "results",
             "StorageClass" => "GLACIER_IR",
             "Unsupported" => []
           }
  end

  test "select restore rejects Days and empty output access control list" do
    with_days =
      ~s(<RestoreRequest><Days>1</Days><Type>SELECT</Type><SelectParameters></SelectParameters><OutputLocation><S3><BucketName>b</BucketName><Prefix>p</Prefix></S3></OutputLocation></RestoreRequest>)

    assert {:error, :malformed_xml} = Restore.parse(with_days)

    with_access_control_list =
      """
      <RestoreRequest>
        <Type>SELECT</Type>
        <SelectParameters>
          <Expression>SELECT * FROM S3Object</Expression>
          <ExpressionType>SQL</ExpressionType>
          <InputSerialization><CSV/></InputSerialization>
          <OutputSerialization><CSV/></OutputSerialization>
        </SelectParameters>
        <OutputLocation>
          <S3>
            <BucketName>b</BucketName>
            <Prefix>p</Prefix>
            <AccessControlList></AccessControlList>
          </S3>
        </OutputLocation>
      </RestoreRequest>
      """

    assert {:error, :malformed_xml} = Restore.parse(with_access_control_list)
  end

  test "select restore preserves top-level tier" do
    assert {:ok, request} =
             Restore.parse(
               select_restore_xml(valid_select_parameters(), "<Tier>Expedited</Tier>")
             )

    assert request["Type"] == "SELECT"
    assert request["Tier"] == "Expedited"
  end

  test "select restore rejects strict SelectParameters violations" do
    cases = [
      select_restore_xml("""
      <Expression>SELECT * FROM S3Object</Expression>
      <Expression>SELECT count(*) FROM S3Object</Expression>
      <ExpressionType>SQL</ExpressionType>
      <InputSerialization><CSV /></InputSerialization>
      <OutputSerialization><CSV /></OutputSerialization>
      """),
      select_restore_xml("""
      <Expression>SELECT * FROM S3Object</Expression>
      <ExpressionType>PQL</ExpressionType>
      <InputSerialization><CSV /></InputSerialization>
      <OutputSerialization><CSV /></OutputSerialization>
      """),
      select_restore_xml("""
      <Expression>SELECT * FROM S3Object</Expression>
      <ExpressionType>SQL</ExpressionType>
      <InputSerialization><CSV /><JSON /></InputSerialization>
      <OutputSerialization><CSV /></OutputSerialization>
      """),
      select_restore_xml("""
      <Expression>SELECT * FROM S3Object</Expression>
      <ExpressionType>SQL</ExpressionType>
      <InputSerialization><CSV /></InputSerialization>
      <OutputSerialization><Parquet /></OutputSerialization>
      """),
      select_restore_xml("""
      <Expression>SELECT * FROM S3Object</Expression>
      <ExpressionType>SQL</ExpressionType>
      <InputSerialization><CSV /></InputSerialization>
      <OutputSerialization><CSV /></OutputSerialization>
      <RequestProgress><Enabled>true</Enabled></RequestProgress>
      """),
      select_restore_xml("""
      <Expression>SELECT * FROM S3Object</Expression>
      <ExpressionType>SQL</ExpressionType>
      <InputSerialization><CSV /></InputSerialization>
      <OutputSerialization><CSV /></OutputSerialization>
      <ScanRange><Start>0</Start></ScanRange>
      """),
      select_restore_xml(valid_select_parameters(), """
      <GlacierJobParameters><Tier>Bulk</Tier></GlacierJobParameters>
      """)
    ]

    for xml <- cases do
      assert {:error, :malformed_xml} = Restore.parse(xml)
    end
  end

  test "parses select restore output access control list grants" do
    xml =
      """
      <RestoreRequest>
        <Type>SELECT</Type>
        <SelectParameters>
          <Expression>SELECT * FROM S3Object</Expression>
          <ExpressionType>SQL</ExpressionType>
          <InputSerialization><CSV/></InputSerialization>
          <OutputSerialization><CSV/></OutputSerialization>
        </SelectParameters>
        <OutputLocation>
          <S3>
            <BucketName>b</BucketName>
            <Prefix>p</Prefix>
            <AccessControlList>
              <Grant>
                <Grantee xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xsi:type="Group">
                  <URI>http://acs.amazonaws.com/groups/global/AllUsers</URI>
                </Grantee>
                <Permission>READ</Permission>
              </Grant>
              <Grant>
                <Grantee xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xsi:type="CanonicalUser">
                  <ID>arn:aws:iam:::user/alice</ID>
                  <DisplayName>Alice</DisplayName>
                </Grantee>
                <Permission>READ_ACP</Permission>
              </Grant>
            </AccessControlList>
          </S3>
        </OutputLocation>
      </RestoreRequest>
      """

    assert {:ok, request} = Restore.parse(xml)

    assert request["OutputLocation"]["AccessControlList"] == [
             %{
               "grantee" => %{
                 "type" => "Group",
                 "uri" => "http://acs.amazonaws.com/groups/global/AllUsers"
               },
               "permission" => "READ"
             },
             %{
               "grantee" => %{
                 "type" => "CanonicalUser",
                 "id" => "arn:aws:iam:::user/alice",
                 "display_name" => "Alice"
               },
               "permission" => "READ_ACP"
             }
           ]
  end

  test "rejects select restore output canned acl mixed with grant list" do
    xml =
      """
      <RestoreRequest>
        <Type>SELECT</Type>
        <SelectParameters>
          <Expression>SELECT * FROM S3Object</Expression>
          <ExpressionType>SQL</ExpressionType>
          <InputSerialization><CSV/></InputSerialization>
          <OutputSerialization><CSV/></OutputSerialization>
        </SelectParameters>
        <OutputLocation>
          <S3>
            <BucketName>b</BucketName>
            <Prefix>p</Prefix>
            <CannedACL>private</CannedACL>
            <AccessControlList>
              <Grant>
                <Grantee xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xsi:type="Group">
                  <URI>http://acs.amazonaws.com/groups/global/AllUsers</URI>
                </Grantee>
                <Permission>READ</Permission>
              </Grant>
            </AccessControlList>
          </S3>
        </OutputLocation>
      </RestoreRequest>
      """

    assert {:error, :malformed_xml} = Restore.parse(xml)
  end

  test "rejects invalid select restore output access control list grants" do
    cases = [
      """
      <Grant>
        <Grantee xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xsi:type="Group">
          <URI>http://acs.amazonaws.com/groups/global/AllUsers</URI>
        </Grantee>
        <Permission>INVALID</Permission>
      </Grant>
      """,
      """
      <Grant>
        <Grantee xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xsi:type="Group">
          <URI>http://example.com/not-an-s3-group</URI>
        </Grantee>
        <Permission>READ</Permission>
      </Grant>
      """,
      """
      <Grant>
        <Grantee>
          <URI>http://acs.amazonaws.com/groups/global/AllUsers</URI>
        </Grantee>
        <Permission>READ</Permission>
      </Grant>
      """,
      """
      <Grant>
        <Grantee xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xsi:type="AmazonCustomerByEmail">
          <EmailAddress>nobody@example.com</EmailAddress>
        </Grantee>
        <Permission>READ</Permission>
      </Grant>
      """
    ]

    too_many =
      1..101
      |> Enum.map_join("", fn index ->
        """
        <Grant>
          <Grantee xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xsi:type="CanonicalUser">
            <ID>canonical-#{index}</ID>
          </Grantee>
          <Permission>READ</Permission>
        </Grant>
        """
      end)

    for grants <- [too_many | cases] do
      xml =
        """
        <RestoreRequest>
          <Type>SELECT</Type>
          <SelectParameters>
            <Expression>SELECT * FROM S3Object</Expression>
            <ExpressionType>SQL</ExpressionType>
            <InputSerialization><CSV/></InputSerialization>
            <OutputSerialization><CSV/></OutputSerialization>
          </SelectParameters>
          <OutputLocation>
            <S3>
              <BucketName>b</BucketName>
              <Prefix>p</Prefix>
              <AccessControlList>#{grants}</AccessControlList>
            </S3>
          </OutputLocation>
        </RestoreRequest>
        """

      assert {:error, :malformed_xml} = Restore.parse(xml)
    end
  end

  test "parses select restore output acl tags metadata and encryption" do
    context = %{"purpose" => "restore"} |> Jason.encode!() |> Base.encode64()

    xml =
      """
      <RestoreRequest>
        <Type>SELECT</Type>
        <SelectParameters>
          <Expression>SELECT * FROM S3Object</Expression>
          <ExpressionType>SQL</ExpressionType>
          <InputSerialization><CSV/></InputSerialization>
          <OutputSerialization><CSV/></OutputSerialization>
        </SelectParameters>
        <OutputLocation>
          <S3>
            <BucketName>b</BucketName>
            <Prefix>p</Prefix>
            <CannedACL>bucket-owner-full-control</CannedACL>
            <Tagging>
              <TagSet>
                <Tag><Key>job</Key><Value>restore</Value></Tag>
                <Tag><Key>empty</Key><Value></Value></Tag>
              </TagSet>
            </Tagging>
            <UserMetadata>
              <MetadataEntry><Name>Trace</Name><Value>abc</Value></MetadataEntry>
            </UserMetadata>
            <Encryption>
              <EncryptionType>aws:kms</EncryptionType>
              <KMSKeyId>restore-key</KMSKeyId>
              <KMSContext>#{context}</KMSContext>
            </Encryption>
          </S3>
        </OutputLocation>
      </RestoreRequest>
      """

    assert {:ok, request} = Restore.parse(xml)

    assert request["OutputLocation"]["CannedACL"] == "bucket-owner-full-control"
    assert request["OutputLocation"]["Tagging"] == [{"job", "restore"}, {"empty", ""}]
    assert request["OutputLocation"]["UserMetadata"] == %{"trace" => "abc"}

    assert request["OutputLocation"]["Encryption"] == %{
             "EncryptionType" => "aws:kms",
             "KMSKeyId" => "restore-key",
             "KMSContext" => context
           }
  end

  test "preserves select restore output tag and metadata user values without trimming" do
    xml =
      """
      <RestoreRequest>
        <Type>SELECT</Type>
        <SelectParameters>
          <Expression>SELECT * FROM S3Object</Expression>
          <ExpressionType>SQL</ExpressionType>
          <InputSerialization><CSV/></InputSerialization>
          <OutputSerialization><CSV/></OutputSerialization>
        </SelectParameters>
        <OutputLocation>
          <S3>
            <BucketName>b</BucketName>
            <Prefix>p</Prefix>
            <Tagging>
              <TagSet>
                <Tag><Key> key with spaces </Key><Value> value with spaces </Value></Tag>
              </TagSet>
            </Tagging>
            <UserMetadata>
              <MetadataEntry><Name>Trace</Name><Value> value with spaces </Value></MetadataEntry>
            </UserMetadata>
          </S3>
        </OutputLocation>
      </RestoreRequest>
      """

    assert {:ok, request} = Restore.parse(xml)
    assert request["OutputLocation"]["Tagging"] == [{" key with spaces ", " value with spaces "}]
    assert request["OutputLocation"]["UserMetadata"] == %{"trace" => " value with spaces "}
  end

  defp select_restore_xml(select_parameters, extra \\ "") do
    """
    <RestoreRequest>
      <Type>SELECT</Type>
      <SelectParameters>
        #{select_parameters}
      </SelectParameters>
      <OutputLocation>
        <S3>
          <BucketName>b</BucketName>
          <Prefix>p</Prefix>
        </S3>
      </OutputLocation>
      #{extra}
    </RestoreRequest>
    """
  end

  defp valid_select_parameters do
    """
    <Expression>SELECT * FROM S3Object</Expression>
    <ExpressionType>SQL</ExpressionType>
    <InputSerialization><CSV /></InputSerialization>
    <OutputSerialization><CSV /></OutputSerialization>
    """
  end
end
