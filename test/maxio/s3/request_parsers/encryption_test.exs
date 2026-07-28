defmodule Maxio.S3.RequestParsers.EncryptionTest do
  use ExUnit.Case, async: true

  alias Maxio.S3.RequestParsers.Encryption

  test "parses namespaced AES256 and KMS bucket encryption configs" do
    aes_xml = """
    <s3:ServerSideEncryptionConfiguration xmlns:s3="http://s3.amazonaws.com/doc/2006-03-01/">
      <s3:Rule>
        <s3:ApplyServerSideEncryptionByDefault>
          <s3:SSEAlgorithm>AES256</s3:SSEAlgorithm>
        </s3:ApplyServerSideEncryptionByDefault>
      </s3:Rule>
    </s3:ServerSideEncryptionConfiguration>
    """

    assert {:ok,
            %{
              algorithm: "AES256",
              kms_key_id: nil,
              bucket_key_enabled: false,
              blocked_encryption_types: [],
              unsupported_multiple_rules?: false
            }} = Encryption.parse(aes_xml)

    kms_xml = """
    <ServerSideEncryptionConfiguration>
      <Rule>
        <ApplyServerSideEncryptionByDefault>
          <SSEAlgorithm>aws:kms</SSEAlgorithm>
          <KMSMasterKeyID>arn:aws:kms:us-east-1:000000000000:key/a</KMSMasterKeyID>
        </ApplyServerSideEncryptionByDefault>
        <BucketKeyEnabled>true</BucketKeyEnabled>
      </Rule>
    </ServerSideEncryptionConfiguration>
    """

    assert {:ok,
            %{
              algorithm: "aws:kms",
              kms_key_id: "arn:aws:kms:us-east-1:000000000000:key/a",
              bucket_key_enabled: true
            }} = Encryption.parse(kms_xml)
  end

  test "accepts KMSKeyID alias used by AWS examples" do
    xml = """
    <ServerSideEncryptionConfiguration>
      <Rule>
        <ApplyServerSideEncryptionByDefault>
          <SSEAlgorithm>aws:kms:dsse</SSEAlgorithm>
          <KMSKeyID>arn:aws:kms:us-east-1:000000000000:key/b</KMSKeyID>
        </ApplyServerSideEncryptionByDefault>
      </Rule>
    </ServerSideEncryptionConfiguration>
    """

    assert {:ok,
            %{algorithm: "aws:kms:dsse", kms_key_id: "arn:aws:kms:us-east-1:000000000000:key/b"}} =
             Encryption.parse(xml)
  end

  test "parses unsupported BlockedEncryptionTypes as an explicit unsupported shape" do
    xml = """
    <ServerSideEncryptionConfiguration>
      <Rule>
        <BlockedEncryptionTypes>
          <EncryptionType>SSE-C</EncryptionType>
        </BlockedEncryptionTypes>
      </Rule>
    </ServerSideEncryptionConfiguration>
    """

    assert {:ok,
            %{
              algorithm: nil,
              blocked_encryption_types: ["SSE-C"],
              unsupported_multiple_rules?: false
            }} = Encryption.parse(xml)
  end

  test "rejects wrong root empty config unknown elements misnested elements and mixed text" do
    assert {:error, :malformed_xml} = Encryption.parse("<Wrong/>")
    assert {:error, :malformed_xml} = Encryption.parse("<ServerSideEncryptionConfiguration/>")

    assert {:error, :malformed_xml} =
             Encryption.parse("""
             <ServerSideEncryptionConfiguration>
               <Rule><Unknown/></Rule>
             </ServerSideEncryptionConfiguration>
             """)

    assert {:error, :malformed_xml} =
             Encryption.parse("""
             <ServerSideEncryptionConfiguration>
               <SSEAlgorithm>AES256</SSEAlgorithm>
             </ServerSideEncryptionConfiguration>
             """)

    assert {:error, :malformed_xml} =
             Encryption.parse("""
             <ServerSideEncryptionConfiguration>
               junk
               <Rule>
                 <ApplyServerSideEncryptionByDefault>
                   <SSEAlgorithm>AES256</SSEAlgorithm>
                 </ApplyServerSideEncryptionByDefault>
               </Rule>
             </ServerSideEncryptionConfiguration>
             """)
  end

  test "rejects duplicate singleton fields invalid booleans and nested leaf text" do
    assert {:error, :malformed_xml} =
             Encryption.parse("""
             <ServerSideEncryptionConfiguration>
               <Rule>
                 <ApplyServerSideEncryptionByDefault>
                   <SSEAlgorithm>AES256</SSEAlgorithm>
                   <SSEAlgorithm>aws:kms</SSEAlgorithm>
                 </ApplyServerSideEncryptionByDefault>
               </Rule>
             </ServerSideEncryptionConfiguration>
             """)

    assert {:error, :malformed_xml} =
             Encryption.parse("""
             <ServerSideEncryptionConfiguration>
               <Rule>
                 <ApplyServerSideEncryptionByDefault>
                   <SSEAlgorithm>AES256</SSEAlgorithm>
                 </ApplyServerSideEncryptionByDefault>
                 <BucketKeyEnabled>yes</BucketKeyEnabled>
               </Rule>
             </ServerSideEncryptionConfiguration>
             """)

    assert {:error, :malformed_xml} =
             Encryption.parse("""
             <ServerSideEncryptionConfiguration>
               <Rule>
                 <ApplyServerSideEncryptionByDefault>
                   <SSEAlgorithm><Nested>AES256</Nested></SSEAlgorithm>
                 </ApplyServerSideEncryptionByDefault>
               </Rule>
             </ServerSideEncryptionConfiguration>
             """)
  end
end
