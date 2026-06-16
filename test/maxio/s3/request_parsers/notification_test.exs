defmodule Maxio.S3.RequestParsers.NotificationTest do
  use ExUnit.Case, async: true

  alias Maxio.S3.RequestParsers.Notification

  test "parses empty NotificationConfiguration" do
    assert Notification.parse("""
           <NotificationConfiguration xmlns="http://s3.amazonaws.com/doc/2006-03-01/" />
           """) ==
             {:ok,
              %{
                "TopicConfigurations" => [],
                "QueueConfigurations" => [],
                "LambdaFunctionConfigurations" => [],
                "EventBridgeConfiguration" => nil
              }}
  end

  test "parses queue topic cloud function event bridge and filters" do
    xml = """
    <s3:NotificationConfiguration xmlns:s3="http://s3.amazonaws.com/doc/2006-03-01/">
      <s3:QueueConfiguration>
        <s3:Id>queue-images</s3:Id>
        <s3:Queue>arn:aws:sqs:us-east-1:000000000000:images</s3:Queue>
        <s3:Event>s3:ObjectCreated:*</s3:Event>
        <s3:Event>s3:ObjectRemoved:Delete</s3:Event>
        <s3:Filter>
          <s3:S3Key>
            <s3:FilterRule>
              <s3:Name>prefix</s3:Name>
              <s3:Value>images/</s3:Value>
            </s3:FilterRule>
            <s3:FilterRule>
              <s3:Name>suffix</s3:Name>
              <s3:Value>.jpg</s3:Value>
            </s3:FilterRule>
          </s3:S3Key>
        </s3:Filter>
      </s3:QueueConfiguration>
      <s3:TopicConfiguration>
        <s3:Topic>arn:aws:sns:us-east-1:000000000000:events</s3:Topic>
        <s3:Event>s3:ObjectTagging:Put</s3:Event>
      </s3:TopicConfiguration>
      <s3:CloudFunctionConfiguration>
        <s3:CloudFunction>arn:aws:lambda:us-east-1:000000000000:function:ingest</s3:CloudFunction>
        <s3:Event>s3:ObjectRestore:Completed</s3:Event>
      </s3:CloudFunctionConfiguration>
      <s3:EventBridgeConfiguration />
    </s3:NotificationConfiguration>
    """

    assert {:ok, config} = Notification.parse(xml)

    assert [
             %{
               "Id" => "queue-images",
               "Queue" => "arn:aws:sqs:us-east-1:000000000000:images",
               "Events" => ["s3:ObjectCreated:*", "s3:ObjectRemoved:Delete"],
               "Filter" => %{
                 "S3Key" => %{
                   "FilterRules" => [
                     %{"Name" => "prefix", "Value" => "images/"},
                     %{"Name" => "suffix", "Value" => ".jpg"}
                   ]
                 }
               }
             }
           ] = config["QueueConfigurations"]

    assert [%{"Topic" => "arn:aws:sns:us-east-1:000000000000:events"}] =
             config["TopicConfigurations"]

    assert [%{"LambdaFunction" => "arn:aws:lambda:us-east-1:000000000000:function:ingest"}] =
             config["LambdaFunctionConfigurations"]

    assert config["EventBridgeConfiguration"] == %{}
  end

  test "rejects wrong root unknown elements and mixed text" do
    assert {:error, :malformed_xml} =
             Notification.parse("<Wrapper><NotificationConfiguration /></Wrapper>")

    assert {:error, :malformed_xml} =
             Notification.parse("""
             <NotificationConfiguration>
               text
               <QueueConfiguration />
             </NotificationConfiguration>
             """)

    assert {:error, :malformed_xml} =
             Notification.parse("""
             <NotificationConfiguration>
               <QueueConfiguration><Unknown /></QueueConfiguration>
             </NotificationConfiguration>
             """)
  end

  test "rejects duplicate singular fields and duplicate EventBridgeConfiguration" do
    assert {:error, :malformed_xml} =
             Notification.parse("""
             <NotificationConfiguration>
               <QueueConfiguration>
                 <Id></Id>
                 <Id></Id>
                 <Queue>arn:aws:sqs:us-east-1:000000000000:a</Queue>
                 <Event>s3:ObjectCreated:*</Event>
               </QueueConfiguration>
             </NotificationConfiguration>
             """)

    assert {:error, :malformed_xml} =
             Notification.parse("""
             <NotificationConfiguration>
               <QueueConfiguration>
                 <Queue>arn:aws:sqs:us-east-1:000000000000:a</Queue>
                 <Queue>arn:aws:sqs:us-east-1:000000000000:b</Queue>
                 <Event>s3:ObjectCreated:*</Event>
               </QueueConfiguration>
             </NotificationConfiguration>
             """)

    assert {:error, :malformed_xml} =
             Notification.parse("""
             <NotificationConfiguration>
               <EventBridgeConfiguration />
               <EventBridgeConfiguration />
             </NotificationConfiguration>
             """)
  end

  test "rejects invalid event and malformed filter rules" do
    assert {:error, :malformed_xml} =
             Notification.parse("""
             <NotificationConfiguration>
               <QueueConfiguration>
                 <Queue>arn:aws:sqs:us-east-1:000000000000:a</Queue>
                 <Event>s3:ObjectCreated:DoesNotExist</Event>
               </QueueConfiguration>
             </NotificationConfiguration>
             """)

    assert {:error, :malformed_xml} =
             Notification.parse("""
             <NotificationConfiguration>
               <QueueConfiguration>
                 <Queue>arn:aws:sqs:us-east-1:000000000000:a</Queue>
                 <Event>s3:ObjectCreated:*</Event>
                 <Filter>
                   <S3Key>
                     <FilterRule><Name>tag</Name><Value>x</Value></FilterRule>
                   </S3Key>
                 </Filter>
               </QueueConfiguration>
             </NotificationConfiguration>
             """)
  end

  test "rejects overlapping filters for the same event family" do
    assert {:error, :malformed_xml} =
             Notification.parse("""
             <NotificationConfiguration>
               <QueueConfiguration>
                 <Queue>arn:aws:sqs:us-east-1:000000000000:all</Queue>
                 <Event>s3:ObjectCreated:*</Event>
               </QueueConfiguration>
               <QueueConfiguration>
                 <Queue>arn:aws:sqs:us-east-1:000000000000:images</Queue>
                 <Event>s3:ObjectCreated:Put</Event>
                 <Filter>
                   <S3Key>
                     <FilterRule><Name>prefix</Name><Value>images/</Value></FilterRule>
                   </S3Key>
                 </Filter>
               </QueueConfiguration>
             </NotificationConfiguration>
             """)

    assert {:error, :malformed_xml} =
             Notification.parse("""
             <NotificationConfiguration>
               <QueueConfiguration>
                 <Queue>arn:aws:sqs:us-east-1:000000000000:images</Queue>
                 <Event>s3:ObjectCreated:*</Event>
                 <Filter>
                   <S3Key>
                     <FilterRule><Name>prefix</Name><Value>images/</Value></FilterRule>
                     <FilterRule><Name>suffix</Name><Value>.jpg</Value></FilterRule>
                   </S3Key>
                 </Filter>
               </QueueConfiguration>
               <TopicConfiguration>
                 <Topic>arn:aws:sns:us-east-1:000000000000:photos</Topic>
                 <Event>s3:ObjectCreated:Copy</Event>
                 <Filter>
                   <S3Key>
                     <FilterRule><Name>prefix</Name><Value>images/raw/</Value></FilterRule>
                     <FilterRule><Name>suffix</Name><Value>jpg</Value></FilterRule>
                   </S3Key>
                 </Filter>
               </TopicConfiguration>
             </NotificationConfiguration>
             """)
  end

  test "accepts non-overlapping filters across overlapping event families" do
    assert {:ok, config} =
             Notification.parse("""
             <NotificationConfiguration>
               <QueueConfiguration>
                 <Queue>arn:aws:sqs:us-east-1:000000000000:jpg</Queue>
                 <Event>s3:ObjectCreated:*</Event>
                 <Filter>
                   <S3Key>
                     <FilterRule><Name>suffix</Name><Value>.jpg</Value></FilterRule>
                   </S3Key>
                 </Filter>
               </QueueConfiguration>
               <QueueConfiguration>
                 <Queue>arn:aws:sqs:us-east-1:000000000000:png</Queue>
                 <Event>s3:ObjectCreated:Put</Event>
                 <Filter>
                   <S3Key>
                     <FilterRule><Name>suffix</Name><Value>.png</Value></FilterRule>
                   </S3Key>
                 </Filter>
               </QueueConfiguration>
               <QueueConfiguration>
                 <Queue>arn:aws:sqs:us-east-1:000000000000:removed</Queue>
                 <Event>s3:ObjectRemoved:*</Event>
               </QueueConfiguration>
             </NotificationConfiguration>
             """)

    assert length(config["QueueConfigurations"]) == 3
  end

  test "rejects wildcard and unencoded filter values" do
    assert {:error, :malformed_xml} =
             Notification.parse("""
             <NotificationConfiguration>
               <QueueConfiguration>
                 <Queue>arn:aws:sqs:us-east-1:000000000000:a</Queue>
                 <Event>s3:ObjectCreated:*</Event>
                 <Filter>
                   <S3Key>
                     <FilterRule><Name>prefix</Name><Value>images/*</Value></FilterRule>
                   </S3Key>
                 </Filter>
               </QueueConfiguration>
             </NotificationConfiguration>
             """)

    assert {:error, :malformed_xml} =
             Notification.parse("""
             <NotificationConfiguration>
               <QueueConfiguration>
                 <Queue>arn:aws:sqs:us-east-1:000000000000:a</Queue>
                 <Event>s3:ObjectCreated:*</Event>
                 <Filter>
                   <S3Key>
                     <FilterRule><Name>prefix</Name><Value>images/%GG</Value></FilterRule>
                   </S3Key>
                 </Filter>
               </QueueConfiguration>
             </NotificationConfiguration>
             """)

    assert {:error, :malformed_xml} =
             Notification.parse("""
             <NotificationConfiguration>
               <QueueConfiguration>
                 <Queue>arn:aws:sqs:us-east-1:000000000000:a</Queue>
                 <Event>s3:ObjectCreated:*</Event>
                 <Filter>
                   <S3Key>
                     <FilterRule><Name>prefix</Name><Value>images/{raw}/</Value></FilterRule>
                   </S3Key>
                 </Filter>
               </QueueConfiguration>
             </NotificationConfiguration>
             """)

    assert {:error, :malformed_xml} =
             Notification.parse("""
             <NotificationConfiguration>
               <QueueConfiguration>
                 <Queue>arn:aws:sqs:us-east-1:000000000000:a</Queue>
                 <Event>s3:ObjectCreated:*</Event>
                 <Filter>
                   <S3Key>
                     <FilterRule><Name>prefix</Name><Value> </Value></FilterRule>
                   </S3Key>
                 </Filter>
               </QueueConfiguration>
             </NotificationConfiguration>
             """)

    assert {:error, :malformed_xml} =
             Notification.parse("""
             <NotificationConfiguration>
               <QueueConfiguration>
                 <Queue>arn:aws:sqs:us-east-1:000000000000:a</Queue>
                 <Event>s3:ObjectCreated:*</Event>
                 <Filter>
                   <S3Key>
                     <FilterRule><Name>prefix</Name><Value>%FF</Value></FilterRule>
                   </S3Key>
                 </Filter>
               </QueueConfiguration>
             </NotificationConfiguration>
             """)
  end

  test "compares overlapping filters after URL decoding" do
    assert {:error, :malformed_xml} =
             Notification.parse("""
             <NotificationConfiguration>
               <QueueConfiguration>
                 <Queue>arn:aws:sqs:us-east-1:000000000000:raw</Queue>
                 <Event>s3:ObjectCreated:*</Event>
                 <Filter>
                   <S3Key>
                     <FilterRule><Name>prefix</Name><Value>images/~</Value></FilterRule>
                   </S3Key>
                 </Filter>
               </QueueConfiguration>
               <QueueConfiguration>
                 <Queue>arn:aws:sqs:us-east-1:000000000000:encoded</Queue>
                 <Event>s3:ObjectCreated:Put</Event>
                 <Filter>
                   <S3Key>
                     <FilterRule><Name>prefix</Name><Value>images/%7E/raw/</Value></FilterRule>
                   </S3Key>
                 </Filter>
               </QueueConfiguration>
             </NotificationConfiguration>
             """)

    assert {:error, :malformed_xml} =
             Notification.parse("""
             <NotificationConfiguration>
               <QueueConfiguration>
                 <Queue>arn:aws:sqs:us-east-1:000000000000:plus</Queue>
                 <Event>s3:ObjectCreated:*</Event>
                 <Filter>
                   <S3Key>
                     <FilterRule><Name>prefix</Name><Value>images+a/</Value></FilterRule>
                   </S3Key>
                 </Filter>
               </QueueConfiguration>
               <QueueConfiguration>
                 <Queue>arn:aws:sqs:us-east-1:000000000000:space</Queue>
                 <Event>s3:ObjectCreated:Put</Event>
                 <Filter>
                   <S3Key>
                     <FilterRule><Name>prefix</Name><Value>images%20a/raw/</Value></FilterRule>
                   </S3Key>
                 </Filter>
               </QueueConfiguration>
             </NotificationConfiguration>
             """)
  end
end
