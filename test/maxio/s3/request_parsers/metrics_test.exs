defmodule Maxio.S3.RequestParsers.MetricsTest do
  use ExUnit.Case, async: true

  alias Maxio.S3.RequestParsers.Metrics

  test "parses minimal and namespaced MetricsConfiguration" do
    assert Metrics.parse("""
           <MetricsConfiguration xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
             <Id>EntireBucket</Id>
           </MetricsConfiguration>
           """) == {:ok, %{"Id" => "EntireBucket"}}

    assert Metrics.parse("""
           <s3:MetricsConfiguration xmlns:s3="http://s3.amazonaws.com/doc/2006-03-01/">
             <s3:Id>daily.logs_01</s3:Id>
           </s3:MetricsConfiguration>
           """) == {:ok, %{"Id" => "daily.logs_01"}}
  end

  test "parses Prefix Tag AccessPointArn and And filters" do
    assert Metrics.parse("""
           <MetricsConfiguration>
             <Id>prefix</Id>
             <Filter><Prefix>logs/</Prefix></Filter>
           </MetricsConfiguration>
           """) == {:ok, %{"Id" => "prefix", "Filter" => %{"Prefix" => "logs/"}}}

    assert Metrics.parse("""
           <MetricsConfiguration>
             <Id>tag</Id>
             <Filter><Tag><Key>env</Key><Value>prod</Value></Tag></Filter>
           </MetricsConfiguration>
           """) ==
             {:ok, %{"Id" => "tag", "Filter" => %{"Tag" => %{"Key" => "env", "Value" => "prod"}}}}

    assert Metrics.parse("""
           <MetricsConfiguration>
             <Id>ap</Id>
             <Filter>
               <AccessPointArn>arn:aws:s3:us-east-1:000000000000:accesspoint/data</AccessPointArn>
             </Filter>
           </MetricsConfiguration>
           """) ==
             {:ok,
              %{
                "Id" => "ap",
                "Filter" => %{
                  "AccessPointArn" => "arn:aws:s3:us-east-1:000000000000:accesspoint/data"
                }
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
              }
            }} =
             Metrics.parse("""
             <MetricsConfiguration>
               <Id>and</Id>
               <Filter>
                 <And>
                   <Prefix>docs/</Prefix>
                   <Tag><Key>class</Key><Value>blue</Value></Tag>
                   <Tag><Key>priority</Key><Value>high</Value></Tag>
                 </And>
               </Filter>
             </MetricsConfiguration>
             """)
  end

  test "rejects invalid id duplicate fields wrong root unknown elements and mixed text" do
    for xml <- [
          "<MetricsConfiguration />",
          "<MetricsConfiguration><Id></Id></MetricsConfiguration>",
          "<MetricsConfiguration><Id>bad id</Id></MetricsConfiguration>",
          "<MetricsConfiguration><Id>a</Id><Id>b</Id></MetricsConfiguration>",
          "<Wrapper><MetricsConfiguration><Id>a</Id></MetricsConfiguration></Wrapper>",
          "<MetricsConfiguration><Id>a</Id><Unknown /></MetricsConfiguration>",
          "<MetricsConfiguration>text<Id>a</Id></MetricsConfiguration>"
        ] do
      assert {:error, :malformed_xml} = Metrics.parse(xml)
    end
  end

  test "rejects invalid filter shapes" do
    for xml <- [
          """
          <MetricsConfiguration>
            <Id>multi</Id>
            <Filter><Prefix>a</Prefix><Tag><Key>k</Key><Value>v</Value></Tag></Filter>
          </MetricsConfiguration>
          """,
          """
          <MetricsConfiguration>
            <Id>tagbad</Id>
            <Filter><Tag><Key></Key><Value>v</Value></Tag></Filter>
          </MetricsConfiguration>
          """,
          """
          <MetricsConfiguration>
            <Id>andone</Id>
            <Filter><And><Prefix>logs/</Prefix></And></Filter>
          </MetricsConfiguration>
          """,
          """
          <MetricsConfiguration>
            <Id>anddup</Id>
            <Filter><And><Prefix>a</Prefix><Prefix>b</Prefix><Tag><Key>k</Key><Value>v</Value></Tag></And></Filter>
          </MetricsConfiguration>
          """,
          """
          <MetricsConfiguration>
            <Id>badap</Id>
            <Filter><AccessPointArn></AccessPointArn></Filter>
          </MetricsConfiguration>
          """
        ] do
      assert {:error, :malformed_xml} = Metrics.parse(xml)
    end
  end
end
