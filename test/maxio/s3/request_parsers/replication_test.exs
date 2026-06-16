defmodule Maxio.S3.RequestParsers.ReplicationTest do
  use ExUnit.Case, async: true

  alias Maxio.S3.RequestParsers.Replication

  test "parses minimal and namespaced ReplicationConfiguration" do
    assert Replication.parse("""
           <ReplicationConfiguration xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
             <Role>arn:aws:iam::000000000000:role/replication</Role>
             <Rule>
               <ID>logs</ID>
               <Status>Enabled</Status>
               <Prefix>logs/</Prefix>
               <Destination><Bucket>arn:aws:s3:::replica-dest</Bucket></Destination>
             </Rule>
           </ReplicationConfiguration>
           """) ==
             {:ok,
              %{
                "Role" => "arn:aws:iam::000000000000:role/replication",
                "Rules" => [
                  %{
                    "ID" => "logs",
                    "Status" => "Enabled",
                    "Prefix" => "logs/",
                    "Destination" => %{"Bucket" => "arn:aws:s3:::replica-dest"}
                  }
                ]
              }}

    assert {:ok, %{"Rules" => [%{"ID" => "docs"}]}} =
             Replication.parse("""
             <s3:ReplicationConfiguration xmlns:s3="http://s3.amazonaws.com/doc/2006-03-01/">
               <s3:Role>arn:aws:iam::000000000000:role/replication</s3:Role>
               <s3:Rule>
                 <s3:ID>docs</s3:ID>
                 <s3:Priority>1</s3:Priority>
                 <s3:Status>Disabled</s3:Status>
                 <s3:Filter><s3:Prefix>documents/</s3:Prefix></s3:Filter>
                 <s3:DeleteMarkerReplication>
                   <s3:Status>Disabled</s3:Status>
                 </s3:DeleteMarkerReplication>
                 <s3:Destination><s3:Bucket>arn:aws:s3:::replica-dest</s3:Bucket></s3:Destination>
               </s3:Rule>
             </s3:ReplicationConfiguration>
             """)
  end

  test "parses filter variants and common destination controls" do
    assert Replication.parse("""
           <ReplicationConfiguration>
             <Role>arn:aws:iam::000000000000:role/replication</Role>
             <Rule>
               <ID>tagged</ID>
               <Priority>10</Priority>
               <Filter><Tag><Key>env</Key><Value>prod</Value></Tag></Filter>
               <Status>Enabled</Status>
               <DeleteMarkerReplication><Status>Disabled</Status></DeleteMarkerReplication>
               <Destination>
                 <Bucket>arn:aws:s3:::replica-dest</Bucket>
                 <Account>000000000000</Account>
                 <StorageClass>STANDARD_IA</StorageClass>
                 <EncryptionConfiguration>
                   <ReplicaKmsKeyID>arn:aws:kms:us-east-1:000000000000:key/1</ReplicaKmsKeyID>
                 </EncryptionConfiguration>
               </Destination>
               <SourceSelectionCriteria>
                 <SseKmsEncryptedObjects><Status>Enabled</Status></SseKmsEncryptedObjects>
               </SourceSelectionCriteria>
             </Rule>
             <Rule>
               <ID>and</ID>
               <Priority>20</Priority>
               <Filter>
                 <And>
                   <Prefix>docs/</Prefix>
                   <Tag><Key>class</Key><Value>blue</Value></Tag>
                 </And>
               </Filter>
               <Status>Enabled</Status>
               <DeleteMarkerReplication><Status>Disabled</Status></DeleteMarkerReplication>
               <Destination><Bucket>arn:aws:s3:::replica-dest</Bucket></Destination>
             </Rule>
           </ReplicationConfiguration>
           """) ==
             {:ok,
              %{
                "Role" => "arn:aws:iam::000000000000:role/replication",
                "Rules" => [
                  %{
                    "ID" => "tagged",
                    "Priority" => 10,
                    "Filter" => %{"Tag" => %{"Key" => "env", "Value" => "prod"}},
                    "Status" => "Enabled",
                    "DeleteMarkerReplication" => %{"Status" => "Disabled"},
                    "Destination" => %{
                      "Bucket" => "arn:aws:s3:::replica-dest",
                      "Account" => "000000000000",
                      "StorageClass" => "STANDARD_IA",
                      "EncryptionConfiguration" => %{
                        "ReplicaKmsKeyID" => "arn:aws:kms:us-east-1:000000000000:key/1"
                      }
                    },
                    "SourceSelectionCriteria" => %{
                      "SseKmsEncryptedObjects" => %{"Status" => "Enabled"}
                    }
                  },
                  %{
                    "ID" => "and",
                    "Priority" => 20,
                    "Filter" => %{
                      "And" => %{
                        "Prefix" => "docs/",
                        "Tags" => [%{"Key" => "class", "Value" => "blue"}]
                      }
                    },
                    "DeleteMarkerReplication" => %{"Status" => "Disabled"},
                    "Status" => "Enabled",
                    "Destination" => %{"Bucket" => "arn:aws:s3:::replica-dest"}
                  }
                ]
              }}
  end

  test "parses valid RTC when replication time and metrics are paired at 15 minutes" do
    assert {:ok,
            %{
              "Rules" => [
                %{
                  "Destination" => %{
                    "ReplicationTime" => %{"Status" => "Enabled", "Time" => %{"Minutes" => 15}},
                    "Metrics" => %{
                      "Status" => "Enabled",
                      "EventThreshold" => %{"Minutes" => 15}
                    }
                  }
                }
              ]
            }} =
             Replication.parse("""
             <ReplicationConfiguration>
               <Role>arn:aws:iam::000000000000:role/replication</Role>
               <Rule>
                 <ID>rtc</ID>
                 <Priority>1</Priority>
                 <Status>Enabled</Status>
                 <Filter><Prefix>logs/</Prefix></Filter>
                 <DeleteMarkerReplication><Status>Disabled</Status></DeleteMarkerReplication>
                 <Destination>
                   <Bucket>arn:aws:s3:::dest</Bucket>
                   <ReplicationTime>
                     <Status>Enabled</Status>
                     <Time><Minutes>15</Minutes></Time>
                   </ReplicationTime>
                   <Metrics>
                     <Status>Enabled</Status>
                     <EventThreshold><Minutes>15</Minutes></EventThreshold>
                   </Metrics>
                 </Destination>
               </Rule>
             </ReplicationConfiguration>
             """)
  end

  test "rejects invalid required fields duplicate fields wrong root and unknown elements" do
    for xml <- [
          "<ReplicationConfiguration />",
          "<ReplicationConfiguration><Role>r</Role></ReplicationConfiguration>",
          """
          <ReplicationConfiguration>
            <Role>arn:aws:iam::000000000000:role/replication</Role>
            <Rule><Status>Enabled</Status><Destination><Bucket>arn:aws:s3:::dest</Bucket></Destination></Rule>
          </ReplicationConfiguration>
          """,
          """
          <ReplicationConfiguration>
            <Role>arn:aws:iam::000000000000:role/replication</Role>
            <Rule><Status>Enabled</Status><Prefix></Prefix><Destination><Bucket>dest</Bucket></Destination></Rule>
          </ReplicationConfiguration>
          """,
          """
          <ReplicationConfiguration>
            <Role>arn:aws:iam::000000000000:role/replication</Role>
            <Rule><Status>Pending</Status><Prefix></Prefix><Destination><Bucket>arn:aws:s3:::dest</Bucket></Destination></Rule>
          </ReplicationConfiguration>
          """,
          """
          <ReplicationConfiguration>
            <Role>arn:aws:iam::000000000000:role/replication</Role>
            <Rule><Status>Enabled</Status><Filter><Prefix>a</Prefix></Filter><DeleteMarkerReplication><Status>Disabled</Status></DeleteMarkerReplication><Destination><Bucket>arn:aws:s3:::dest</Bucket></Destination></Rule>
          </ReplicationConfiguration>
          """,
          """
          <ReplicationConfiguration>
            <Role>arn:aws:iam::000000000000:role/replication</Role>
            <Rule><Status>Enabled</Status><Priority>1</Priority><Filter><Prefix>a</Prefix></Filter><Destination><Bucket>arn:aws:s3:::dest</Bucket></Destination></Rule>
          </ReplicationConfiguration>
          """,
          """
          <ReplicationConfiguration>
            <Role>arn:aws:iam::000000000000:role/replication</Role>
            <Rule><Status>Enabled</Status><Prefix></Prefix><Filter><Prefix>a</Prefix></Filter><Destination><Bucket>arn:aws:s3:::dest</Bucket></Destination></Rule>
          </ReplicationConfiguration>
          """,
          """
          <ReplicationConfiguration>
            <Role>arn:aws:iam::000000000000:role/replication</Role>
            <Rule><Status>Enabled</Status><Prefix></Prefix><Destination><Bucket>arn:aws:s3:::dest</Bucket></Destination><Unknown /></Rule>
          </ReplicationConfiguration>
          """,
          """
          <ReplicationConfiguration>
            <Role>arn:aws:iam::000000000000:role/replication</Role>
            <Rule><Status>Enabled</Status><Prefix></Prefix><Destination><Bucket>arn:aws:s3:::dest</Bucket><ReplicationTime><Status>Enabled</Status><Time><Minutes>15</Minutes></Time></ReplicationTime></Destination></Rule>
          </ReplicationConfiguration>
          """,
          """
          <ReplicationConfiguration>
            <Role>arn:aws:iam::000000000000:role/replication</Role>
            <Rule><Status>Enabled</Status><Prefix></Prefix><Destination><Bucket>arn:aws:s3:::dest</Bucket><Metrics><Status>Enabled</Status><EventThreshold><Minutes>15</Minutes></EventThreshold></Metrics></Destination></Rule>
          </ReplicationConfiguration>
          """,
          """
          <ReplicationConfiguration>
            <Role>arn:aws:iam::000000000000:role/replication</Role>
            <Rule><Status>Enabled</Status><Prefix></Prefix><Destination><Bucket>arn:aws:s3:::dest</Bucket><ReplicationTime><Status>Enabled</Status><Time><Minutes>10</Minutes></Time></ReplicationTime><Metrics><Status>Enabled</Status><EventThreshold><Minutes>15</Minutes></EventThreshold></Metrics></Destination></Rule>
          </ReplicationConfiguration>
          """,
          "<Wrapper><ReplicationConfiguration /></Wrapper>"
        ] do
      assert {:error, :malformed_xml} = Replication.parse(xml)
    end
  end
end
