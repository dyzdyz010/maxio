defmodule Maxio.S3.InventoryE2ETest do
  use Maxio.DataCase, async: false

  import Plug.Conn

  alias Maxio.Auth.CredentialStore
  alias Maxio.BucketConfigs
  alias Maxio.Policy.Store
  alias Maxio.S3.Endpoint
  alias Maxio.Test.SigV4Request

  @data_dir Path.join(System.tmp_dir!(), "maxio_inventory_e2e")
  @alice_ak "AKIAINVENTORY0001"
  @alice_secret "inventoryinventory123"
  @alice_arn "arn:aws:iam:::user/" <> @alice_ak

  @daily """
  <InventoryConfiguration xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
    <Destination>
      <S3BucketDestination>
        <AccountId>000000000000</AccountId>
        <Bucket>arn:aws:s3:::inventory-dest</Bucket>
        <Format>CSV</Format>
        <Prefix>reports/</Prefix>
      </S3BucketDestination>
    </Destination>
    <IsEnabled>true</IsEnabled>
    <Id>daily</Id>
    <IncludedObjectVersions>All</IncludedObjectVersions>
    <OptionalFields>
      <Field>Size</Field>
      <Field>ChecksumAlgorithm</Field>
      <Field>LifecycleExpirationDate</Field>
    </OptionalFields>
    <Schedule><Frequency>Daily</Frequency></Schedule>
  </InventoryConfiguration>
  """
  @weekly """
  <InventoryConfiguration xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
    <Destination>
      <S3BucketDestination>
        <AccountId>000000000000</AccountId>
        <Bucket>arn:aws:s3:::inventory-dest</Bucket>
        <Format>ORC</Format>
      </S3BucketDestination>
    </Destination>
    <IsEnabled>false</IsEnabled>
    <Id>weekly</Id>
    <Filter><Prefix>logs/</Prefix></Filter>
    <IncludedObjectVersions>Current</IncludedObjectVersions>
    <Schedule><Frequency>Weekly</Frequency></Schedule>
  </InventoryConfiguration>
  """

  setup do
    File.rm_rf(@data_dir)
    File.mkdir_p!(@data_dir)
    prev = Application.get_env(:maxio, :s3)
    Application.put_env(:maxio, :s3, Keyword.put(prev, :data_dir, @data_dir))

    :ok =
      CredentialStore.put_access_key(%{
        access_key: @alice_ak,
        secret_key: @alice_secret,
        principal: %{type: :iam_user, access_key: @alice_ak, arn: @alice_arn}
      })

    on_exit(fn ->
      Application.put_env(:maxio, :s3, prev)
      File.rm_rf(@data_dir)
    end)

    :ok
  end

  defp call(conn), do: Endpoint.call(conn, Endpoint.init([]))

  defp alice(method, path, opts) do
    SigV4Request.signed_conn(
      method,
      path,
      Keyword.merge([access_key: @alice_ak, secret: @alice_secret], opts)
    )
  end

  defp create_bucket(bucket), do: SigV4Request.signed_conn(:put, "/#{bucket}") |> call()

  defp put_inventory(bucket, id, body, opts \\ []) do
    SigV4Request.signed_conn(:put, "/#{bucket}",
      query: %{"inventory" => "", "id" => id},
      body: body,
      headers: Keyword.get(opts, :headers, [])
    )
    |> call()
  end

  defp get_inventory(bucket, id, opts \\ []) do
    SigV4Request.signed_conn(:get, "/#{bucket}",
      query: %{"inventory" => "", "id" => id},
      headers: Keyword.get(opts, :headers, [])
    )
    |> call()
  end

  defp delete_inventory(bucket, id, opts \\ []) do
    SigV4Request.signed_conn(:delete, "/#{bucket}",
      query: %{"inventory" => "", "id" => id},
      headers: Keyword.get(opts, :headers, [])
    )
    |> call()
  end

  test "put get list and delete inventory configurations by id" do
    assert create_bucket("inventorycfg").status == 200

    missing = get_inventory("inventorycfg", "daily")
    assert missing.status == 404
    assert missing.resp_body =~ "NoSuchConfiguration"

    put = put_inventory("inventorycfg", "daily", @daily)
    assert put.status == 200
    assert put.resp_body == ""

    assert {:ok, %{"Configurations" => [%{"Id" => "daily"}]}} =
             BucketConfigs.get("inventorycfg", :inventory)

    get = get_inventory("inventorycfg", "daily")
    assert get.status == 200
    assert get_resp_header(get, "content-type") |> hd() =~ "application/xml"
    assert get.resp_body =~ "<InventoryConfiguration"
    assert get.resp_body =~ "<OptionalFields>"
    assert get.resp_body =~ "<Field>ChecksumAlgorithm</Field>"
    assert get.resp_body =~ "<Field>LifecycleExpirationDate</Field>"
    assert get.resp_body =~ "<Prefix>reports/</Prefix>"

    assert put_inventory("inventorycfg", "weekly", @weekly).status == 200

    list =
      SigV4Request.signed_conn(:get, "/inventorycfg", query: %{"inventory" => ""})
      |> call()

    assert list.status == 200
    assert list.resp_body =~ "<ListInventoryConfigurationsResult"
    assert list.resp_body =~ "<Id>daily</Id>"
    assert list.resp_body =~ "<Id>weekly</Id>"
    assert list.resp_body =~ "<IsTruncated>false</IsTruncated>"

    deleted = delete_inventory("inventorycfg", "daily")
    assert deleted.status == 204

    assert {:ok, %{"Configurations" => [%{"Id" => "weekly"}]}} =
             BucketConfigs.get("inventorycfg", :inventory)

    assert get_inventory("inventorycfg", "daily").status == 404
    assert get_inventory("inventorycfg", "weekly").status == 200
  end

  test "list paginates at 100 configurations with continuation token" do
    assert create_bucket("inventorypage").status == 200

    configs =
      for n <- 1..101 do
        id = "cfg#{String.pad_leading(Integer.to_string(n), 3, "0")}"

        %{
          "Id" => id,
          "Destination" => %{
            "S3BucketDestination" => %{
              "AccountId" => "000000000000",
              "Bucket" => "arn:aws:s3:::inventory-dest",
              "Format" => "CSV"
            }
          },
          "IsEnabled" => true,
          "IncludedObjectVersions" => "All",
          "Schedule" => %{"Frequency" => "Daily"}
        }
      end

    assert :ok = BucketConfigs.put("inventorypage", :inventory, %{"Configurations" => configs})

    first =
      SigV4Request.signed_conn(:get, "/inventorypage", query: %{"inventory" => ""})
      |> call()

    assert first.status == 200
    assert first.resp_body =~ "<IsTruncated>true</IsTruncated>"
    assert first.resp_body =~ "<NextContinuationToken>cfg100</NextContinuationToken>"
    refute first.resp_body =~ "<Id>cfg101</Id>"

    second =
      SigV4Request.signed_conn(:get, "/inventorypage",
        query: %{"inventory" => "", "continuation-token" => "cfg100"}
      )
      |> call()

    assert second.status == 200
    assert second.resp_body =~ "<ContinuationToken>cfg100</ContinuationToken>"
    assert second.resp_body =~ "<Id>cfg101</Id>"
    assert second.resp_body =~ "<IsTruncated>false</IsTruncated>"

    invalid =
      SigV4Request.signed_conn(:get, "/inventorypage",
        query: %{"inventory" => "", "continuation-token" => "missing"}
      )
      |> call()

    assert invalid.status == 400
    assert invalid.resp_body =~ "InvalidArgument"
  end

  test "missing id mismatched XML id malformed XML and checksums fail closed" do
    assert create_bucket("inventorybad").status == 200
    assert put_inventory("inventorybad", "daily", @daily).status == 200

    missing_id =
      SigV4Request.signed_conn(:put, "/inventorybad",
        query: %{"inventory" => ""},
        body: @daily
      )
      |> call()

    assert missing_id.status == 400
    assert missing_id.resp_body =~ "InvalidArgument"

    mismatch = put_inventory("inventorybad", "weekly", @daily)
    assert mismatch.status == 400
    assert mismatch.resp_body =~ "MalformedXML"

    bad_xml =
      put_inventory(
        "inventorybad",
        "weekly",
        "<InventoryConfiguration><Id>weekly</Id><Bad /></InventoryConfiguration>"
      )

    assert bad_xml.status == 400
    assert bad_xml.resp_body =~ "MalformedXML"

    bad_checksum =
      put_inventory("inventorybad", "weekly", @weekly,
        headers: [
          {"x-amz-sdk-checksum-algorithm", "SHA256"},
          {"x-amz-checksum-sha256", :crypto.hash(:sha256, "different") |> Base.encode64()}
        ]
      )

    assert bad_checksum.status == 400
    assert bad_checksum.resp_body =~ "BadDigest"

    bad_content_md5 =
      put_inventory("inventorybad", "weekly", @weekly,
        headers: [{"content-md5", :crypto.hash(:md5, "different") |> Base.encode64()}]
      )

    assert bad_content_md5.status == 400
    assert bad_content_md5.resp_body =~ "BadDigest"

    assert {:ok, %{"Configurations" => [%{"Id" => "daily"}]}} =
             BucketConfigs.get("inventorybad", :inventory)
  end

  test "checksum trailers and aws-chunked XML bodies are rejected" do
    assert create_bucket("inventorychunked").status == 200

    trailer =
      put_inventory("inventorychunked", "daily", @daily,
        headers: [
          {"x-amz-sdk-checksum-algorithm", "SHA256"},
          {"x-amz-trailer", "x-amz-checksum-sha256"}
        ]
      )

    assert trailer.status == 501
    assert trailer.resp_body =~ "NotImplemented"

    conn =
      SigV4Request.signed_chunked_conn(:put, "/inventorychunked", @daily,
        query: %{"inventory" => "", "id" => "daily"}
      )

    rejected = call(conn)
    assert rejected.status == 501
    assert rejected.resp_body =~ "NotImplemented"
    assert BucketConfigs.get("inventorychunked", :inventory) == :none
  end

  test "expected bucket owner missing bucket and method boundaries are enforced" do
    assert create_bucket("inventoryowner").status == 200
    assert put_inventory("inventoryowner", "daily", @daily).status == 200

    wrong_get =
      get_inventory("inventoryowner", "daily",
        headers: [{"x-amz-expected-bucket-owner", "999999999999"}]
      )

    assert wrong_get.status == 403
    assert wrong_get.resp_body =~ "AccessDenied"

    wrong_put =
      put_inventory("inventoryowner", "weekly", @weekly,
        headers: [{"x-amz-expected-bucket-owner", "999999999999"}]
      )

    assert wrong_put.status == 403

    wrong_delete =
      delete_inventory("inventoryowner", "daily",
        headers: [{"x-amz-expected-bucket-owner", "999999999999"}]
      )

    assert wrong_delete.status == 403

    missing = put_inventory("missing-inventory", "daily", @daily)
    assert missing.status == 404
    assert missing.resp_body =~ "NoSuchBucket"

    object_get =
      SigV4Request.signed_conn(:get, "/inventoryowner/object.txt", query: %{"inventory" => ""})
      |> call()

    assert object_get.status == 405
    assert object_get.resp_body =~ "MethodNotAllowed"

    post =
      SigV4Request.signed_conn(:post, "/inventoryowner", query: %{"inventory" => ""})
      |> call()

    assert post.status == 405
  end

  test "inventory IAM actions resource tags and optional fields condition behavior match AWS action map" do
    assert create_bucket("inventoryauthz").status == 200
    assert put_inventory("inventoryauthz", "daily", @daily).status == 200

    get_policy =
      ~s({"Version":"2012-10-17","Statement":{"Effect":"Allow","Action":"s3:GetInventoryConfiguration","Resource":"arn:aws:s3:::inventoryauthz"}})

    assert :ok = Store.put_principal_policy(@alice_arn, "get-inventory-only", get_policy)

    assert (alice(:get, "/inventoryauthz", query: %{"inventory" => ""}) |> call()).status == 200

    assert (alice(:get, "/inventoryauthz", query: %{"inventory" => "", "id" => "daily"})
            |> call()).status == 200

    denied_put =
      alice(:put, "/inventoryauthz", query: %{"inventory" => "", "id" => "weekly"}, body: @weekly)
      |> call()

    assert denied_put.status == 403

    denied_delete =
      alice(:delete, "/inventoryauthz", query: %{"inventory" => "", "id" => "daily"})
      |> call()

    assert denied_delete.status == 403

    assert :ok = Store.delete_principal_policy(@alice_arn, "get-inventory-only")

    optional_policy =
      ~s({"Version":"2012-10-17","Statement":{"Effect":"Allow","Action":"s3:PutInventoryConfiguration","Resource":"arn:aws:s3:::inventoryauthz","Condition":{"ForAllValues:StringEquals":{"s3:InventoryAccessibleOptionalFields":["Size","ChecksumAlgorithm","LifecycleExpirationDate"]}}}})

    assert :ok = Store.put_principal_policy(@alice_arn, "put-inventory-optional", optional_policy)

    allowed_put =
      alice(:put, "/inventoryauthz", query: %{"inventory" => "", "id" => "daily"}, body: @daily)
      |> call()

    assert allowed_put.status == 200

    disallowed_optional =
      String.replace(@daily, "<Field>ChecksumAlgorithm</Field>", "<Field>ETag</Field>")

    denied_by_optional =
      alice(:put, "/inventoryauthz",
        query: %{"inventory" => "", "id" => "daily"},
        body: disallowed_optional
      )
      |> call()

    assert denied_by_optional.status == 403

    assert :ok = Store.delete_principal_policy(@alice_arn, "put-inventory-optional")

    put_policy =
      ~s({"Version":"2012-10-17","Statement":{"Effect":"Allow","Action":"s3:PutInventoryConfiguration","Resource":"arn:aws:s3:::inventoryauthz"}})

    assert :ok = Store.put_principal_policy(@alice_arn, "put-inventory", put_policy)

    allowed_delete =
      alice(:delete, "/inventoryauthz", query: %{"inventory" => "", "id" => "daily"})
      |> call()

    assert allowed_delete.status == 204

    tag_xml = "<Tagging><TagSet><Tag><Key>env</Key><Value>prod</Value></Tag></TagSet></Tagging>"

    assert (SigV4Request.signed_conn(:put, "/inventoryauthz",
              query: %{"tagging" => ""},
              body: tag_xml
            )
            |> call()).status == 204

    assert :ok = Store.delete_principal_policy(@alice_arn, "put-inventory")

    resource_tag_policy =
      ~s({"Version":"2012-10-17","Statement":{"Effect":"Allow","Action":"s3:GetInventoryConfiguration","Resource":"arn:aws:s3:::inventoryauthz","Condition":{"StringEquals":{"aws:ResourceTag/env":"prod"}}}})

    assert :ok =
             Store.put_principal_policy(
               @alice_arn,
               "get-inventory-resource-tag",
               resource_tag_policy
             )

    denied_by_tag_condition =
      alice(:get, "/inventoryauthz", query: %{"inventory" => "", "id" => "daily"}) |> call()

    assert denied_by_tag_condition.status == 403
  end
end
