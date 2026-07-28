defmodule Maxio.S3.RequestParsers.InventoryTest do
  use ExUnit.Case, async: true

  alias Maxio.S3.RequestParsers.Inventory

  test "parses minimal and namespaced InventoryConfiguration" do
    assert {:ok, %{"Id" => "daily", "IsEnabled" => true}} =
             Inventory.parse("""
             <InventoryConfiguration xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
               <Destination><S3BucketDestination><AccountId>000000000000</AccountId><Bucket>arn:aws:s3:::dest</Bucket><Format>CSV</Format></S3BucketDestination></Destination>
               <IsEnabled>true</IsEnabled>
               <Id>daily</Id>
               <IncludedObjectVersions>All</IncludedObjectVersions>
               <Schedule><Frequency>Daily</Frequency></Schedule>
             </InventoryConfiguration>
             """)

    assert {:ok, %{"Id" => "weekly", "IsEnabled" => false}} =
             Inventory.parse("""
             <s3:InventoryConfiguration xmlns:s3="http://s3.amazonaws.com/doc/2006-03-01/">
               <s3:Destination><s3:S3BucketDestination><s3:AccountId>000000000000</s3:AccountId><s3:Bucket>arn:aws:s3:::dest</s3:Bucket><s3:Format>ORC</s3:Format></s3:S3BucketDestination></s3:Destination>
               <s3:IsEnabled>false</s3:IsEnabled>
               <s3:Id>weekly</s3:Id>
               <s3:IncludedObjectVersions>Current</s3:IncludedObjectVersions>
               <s3:Schedule><s3:Frequency>Weekly</s3:Frequency></s3:Schedule>
             </s3:InventoryConfiguration>
             """)

    assert {:ok, config} =
             Inventory.parse("""
             <InventoryConfiguration>
               <Destination><S3BucketDestination><Bucket>arn:aws:s3:::dest</Bucket><Format>CSV</Format></S3BucketDestination></Destination>
               <IsEnabled>true</IsEnabled>
               <Id>no-account</Id>
               <IncludedObjectVersions>Current</IncludedObjectVersions>
               <Schedule><Frequency>Daily</Frequency></Schedule>
             </InventoryConfiguration>
             """)

    refute Map.has_key?(get_in(config, ["Destination", "S3BucketDestination"]), "AccountId")
  end

  test "parses filter optional fields and encryption" do
    assert Inventory.parse("""
           <InventoryConfiguration>
             <Destination>
               <S3BucketDestination>
                 <AccountId>000000000000</AccountId>
                 <Bucket>arn:aws:s3:::dest</Bucket>
                 <Format>Parquet</Format>
                 <Prefix>reports/</Prefix>
                 <Encryption><SSE-KMS><KeyId>arn:aws:kms:us-east-1:000000000000:key/1</KeyId></SSE-KMS></Encryption>
               </S3BucketDestination>
             </Destination>
             <IsEnabled>true</IsEnabled>
             <Id>full</Id>
             <Filter><Prefix>logs/</Prefix></Filter>
             <IncludedObjectVersions>All</IncludedObjectVersions>
             <OptionalFields>
               <Field>Size</Field>
              <Field>ChecksumAlgorithm</Field>
              <Field>ObjectLockMode</Field>
              <Field>LifecycleExpirationDate</Field>
             </OptionalFields>
             <Schedule><Frequency>Daily</Frequency></Schedule>
           </InventoryConfiguration>
           """) ==
             {:ok,
              %{
                "Destination" => %{
                  "S3BucketDestination" => %{
                    "AccountId" => "000000000000",
                    "Bucket" => "arn:aws:s3:::dest",
                    "Format" => "Parquet",
                    "Prefix" => "reports/",
                    "Encryption" => %{
                      "SSE-KMS" => %{"KeyId" => "arn:aws:kms:us-east-1:000000000000:key/1"}
                    }
                  }
                },
                "Filter" => %{"Prefix" => "logs/"},
                "Id" => "full",
                "IncludedObjectVersions" => "All",
                "IsEnabled" => true,
                "OptionalFields" => [
                  "Size",
                  "ChecksumAlgorithm",
                  "ObjectLockMode",
                  "LifecycleExpirationDate"
                ],
                "Schedule" => %{"Frequency" => "Daily"}
              }}
  end

  test "rejects invalid required fields and unknown elements" do
    for xml <- [
          "<InventoryConfiguration />",
          "<InventoryConfiguration><Id>daily</Id></InventoryConfiguration>",
          """
          <InventoryConfiguration>
            <Destination><S3BucketDestination><AccountId>000000000000</AccountId><Bucket>arn:aws:s3:::dest</Bucket><Format>CSV</Format></S3BucketDestination></Destination>
            <IsEnabled>true</IsEnabled><Id>bad id</Id><IncludedObjectVersions>All</IncludedObjectVersions><Schedule><Frequency>Daily</Frequency></Schedule>
          </InventoryConfiguration>
          """,
          """
          <InventoryConfiguration>
            <Destination><S3BucketDestination><AccountId>000000000000</AccountId><Bucket>arn:aws:s3:::dest</Bucket><Format>JSON</Format></S3BucketDestination></Destination>
            <IsEnabled>true</IsEnabled><Id>daily</Id><IncludedObjectVersions>All</IncludedObjectVersions><Schedule><Frequency>Daily</Frequency></Schedule>
          </InventoryConfiguration>
          """,
          """
          <InventoryConfiguration>
            <Destination><S3BucketDestination><AccountId>000000000000</AccountId><Bucket>arn:aws:s3:::dest</Bucket><Format>CSV</Format></S3BucketDestination></Destination>
            <IsEnabled>true</IsEnabled><Id>daily</Id><IncludedObjectVersions>All</IncludedObjectVersions><OptionalFields><Field>NotAField</Field></OptionalFields><Schedule><Frequency>Daily</Frequency></Schedule>
          </InventoryConfiguration>
          """,
          """
          <InventoryConfiguration>
            <Destination><S3BucketDestination><AccountId>000000000000</AccountId><Bucket>arn:aws:s3:::dest</Bucket><Format>CSV</Format></S3BucketDestination></Destination>
            <IsEnabled>true</IsEnabled><Id>daily</Id><IncludedObjectVersions>All</IncludedObjectVersions><OptionalFields><Field>ObjectLockRetentionMode</Field></OptionalFields><Schedule><Frequency>Daily</Frequency></Schedule>
          </InventoryConfiguration>
          """,
          """
          <InventoryConfiguration>
            <Destination><S3BucketDestination><AccountId>000000000000</AccountId><Bucket>arn:aws:s3:::dest</Bucket><Format>CSV</Format></S3BucketDestination></Destination>
            <IsEnabled>true</IsEnabled><Id>daily</Id><IncludedObjectVersions>All</IncludedObjectVersions><Unknown /><Schedule><Frequency>Daily</Frequency></Schedule>
          </InventoryConfiguration>
          """
        ] do
      assert {:error, :malformed_xml} = Inventory.parse(xml)
    end
  end
end
