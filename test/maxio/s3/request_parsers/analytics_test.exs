defmodule Maxio.S3.RequestParsers.AnalyticsTest do
  use ExUnit.Case, async: true

  alias Maxio.S3.RequestParsers.Analytics

  test "parses minimal and namespaced AnalyticsConfiguration" do
    assert Analytics.parse("""
           <AnalyticsConfiguration xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
             <Id>EntireBucket</Id>
             <StorageClassAnalysis />
           </AnalyticsConfiguration>
           """) == {:ok, %{"Id" => "EntireBucket", "StorageClassAnalysis" => %{}}}

    assert Analytics.parse("""
           <s3:AnalyticsConfiguration xmlns:s3="http://s3.amazonaws.com/doc/2006-03-01/">
             <s3:Id>daily.logs_01</s3:Id>
             <s3:StorageClassAnalysis />
           </s3:AnalyticsConfiguration>
           """) == {:ok, %{"Id" => "daily.logs_01", "StorageClassAnalysis" => %{}}}
  end

  test "parses filters and storage class analysis data export" do
    assert Analytics.parse("""
           <AnalyticsConfiguration>
             <Id>prefix</Id>
             <Filter><Prefix>logs/</Prefix></Filter>
             <StorageClassAnalysis />
           </AnalyticsConfiguration>
           """) ==
             {:ok,
              %{
                "Id" => "prefix",
                "Filter" => %{"Prefix" => "logs/"},
                "StorageClassAnalysis" => %{}
              }}

    assert Analytics.parse("""
           <AnalyticsConfiguration>
             <Id>tag</Id>
             <Filter><Tag><Key>env</Key><Value>prod</Value></Tag></Filter>
             <StorageClassAnalysis />
           </AnalyticsConfiguration>
           """) ==
             {:ok,
              %{
                "Id" => "tag",
                "Filter" => %{"Tag" => %{"Key" => "env", "Value" => "prod"}},
                "StorageClassAnalysis" => %{}
              }}

    assert {:ok,
            %{
              "Id" => "and",
              "Filter" => %{
                "And" => %{
                  "Prefix" => "docs/",
                  "Tags" => [
                    %{"Key" => "class", "Value" => "blue"},
                    %{"Key" => "priority", "Value" => "high"}
                  ]
                }
              },
              "StorageClassAnalysis" => %{}
            }} =
             Analytics.parse("""
             <AnalyticsConfiguration>
               <Id>and</Id>
               <Filter>
                 <And>
                   <Prefix>docs/</Prefix>
                   <Tag><Key>class</Key><Value>blue</Value></Tag>
                   <Tag><Key>priority</Key><Value>high</Value></Tag>
                 </And>
               </Filter>
               <StorageClassAnalysis />
             </AnalyticsConfiguration>
             """)

    assert Analytics.parse("""
           <AnalyticsConfiguration>
             <Id>export</Id>
             <StorageClassAnalysis>
               <DataExport>
                 <OutputSchemaVersion>V_1</OutputSchemaVersion>
                 <Destination>
                   <S3BucketDestination>
                     <Format>CSV</Format>
                     <BucketAccountId>000000000000</BucketAccountId>
                     <Bucket>arn:aws:s3:::analytics-dest</Bucket>
                     <Prefix>reports/</Prefix>
                   </S3BucketDestination>
                 </Destination>
               </DataExport>
             </StorageClassAnalysis>
           </AnalyticsConfiguration>
           """) ==
             {:ok,
              %{
                "Id" => "export",
                "StorageClassAnalysis" => %{
                  "DataExport" => %{
                    "OutputSchemaVersion" => "V_1",
                    "Destination" => %{
                      "S3BucketDestination" => %{
                        "Format" => "CSV",
                        "BucketAccountId" => "000000000000",
                        "Bucket" => "arn:aws:s3:::analytics-dest",
                        "Prefix" => "reports/"
                      }
                    }
                  }
                }
              }}
  end

  test "rejects invalid id missing analysis duplicate fields wrong root unknown elements" do
    for xml <- [
          "<AnalyticsConfiguration />",
          "<AnalyticsConfiguration><Id>a</Id></AnalyticsConfiguration>",
          "<AnalyticsConfiguration><Id></Id><StorageClassAnalysis /></AnalyticsConfiguration>",
          "<AnalyticsConfiguration><Id>bad id</Id><StorageClassAnalysis /></AnalyticsConfiguration>",
          "<AnalyticsConfiguration><Id>a</Id><Id>b</Id><StorageClassAnalysis /></AnalyticsConfiguration>",
          "<Wrapper><AnalyticsConfiguration><Id>a</Id></AnalyticsConfiguration></Wrapper>",
          "<AnalyticsConfiguration><Id>a</Id><Unknown /><StorageClassAnalysis /></AnalyticsConfiguration>",
          "<AnalyticsConfiguration>text<Id>a</Id><StorageClassAnalysis /></AnalyticsConfiguration>"
        ] do
      assert {:error, :malformed_xml} = Analytics.parse(xml)
    end
  end

  test "rejects invalid filter and data export shapes" do
    for xml <- [
          """
          <AnalyticsConfiguration>
            <Id>multi</Id>
            <Filter><Prefix>a</Prefix><Tag><Key>k</Key><Value>v</Value></Tag></Filter>
            <StorageClassAnalysis />
          </AnalyticsConfiguration>
          """,
          """
          <AnalyticsConfiguration>
            <Id>andone</Id>
            <Filter><And><Prefix>logs/</Prefix></And></Filter>
            <StorageClassAnalysis />
          </AnalyticsConfiguration>
          """,
          """
          <AnalyticsConfiguration>
            <Id>badexport</Id>
            <StorageClassAnalysis>
              <DataExport><OutputSchemaVersion>V_2</OutputSchemaVersion></DataExport>
            </StorageClassAnalysis>
          </AnalyticsConfiguration>
          """,
          """
          <AnalyticsConfiguration>
            <Id>baddest</Id>
            <StorageClassAnalysis>
              <DataExport>
                <OutputSchemaVersion>V_1</OutputSchemaVersion>
                <Destination><S3BucketDestination><Format>JSON</Format><Bucket>b</Bucket></S3BucketDestination></Destination>
              </DataExport>
            </StorageClassAnalysis>
          </AnalyticsConfiguration>
          """
        ] do
      assert {:error, :malformed_xml} = Analytics.parse(xml)
    end
  end
end
