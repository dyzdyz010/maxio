defmodule Maxio.S3.WebsiteE2ETest do
  use Maxio.DataCase, async: false

  import Plug.Conn

  alias Maxio.Auth.CredentialStore
  alias Maxio.BucketConfigs
  alias Maxio.Policy.Store
  alias Maxio.S3.Endpoint
  alias Maxio.Test.SigV4Request

  @data_dir Path.join(System.tmp_dir!(), "maxio_website_e2e")
  @alice_ak "AKIAWEBSITEPOLICY01"
  @alice_secret "websitewebsitewebsiteweb12"
  @alice_arn "arn:aws:iam:::user/" <> @alice_ak
  @website """
  <WebsiteConfiguration xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
    <IndexDocument><Suffix>index.html</Suffix></IndexDocument>
    <ErrorDocument><Key>404.html</Key></ErrorDocument>
    <RoutingRules>
      <RoutingRule>
        <Condition><KeyPrefixEquals>docs/</KeyPrefixEquals></Condition>
        <Redirect><ReplaceKeyPrefixWith>documents/</ReplaceKeyPrefixWith></Redirect>
      </RoutingRule>
    </RoutingRules>
  </WebsiteConfiguration>
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

  test "PutBucketWebsite, GetBucketWebsite, and DeleteBucketWebsite round-trip" do
    assert (SigV4Request.signed_conn(:put, "/webcfg") |> call()).status == 200

    put =
      SigV4Request.signed_conn(:put, "/webcfg", query: %{"website" => ""}, body: @website)
      |> call()

    assert put.status == 200
    assert put.resp_body == ""

    assert {:ok, config} = BucketConfigs.get("webcfg", :website)
    assert config["index_document"] == %{"suffix" => "index.html"}
    assert config["error_document"] == %{"key" => "404.html"}
    assert [rule] = config["routing_rules"]
    assert rule["condition"] == %{"key_prefix_equals" => "docs/"}

    get =
      SigV4Request.signed_conn(:get, "/webcfg", query: %{"website" => ""})
      |> call()

    assert get.status == 200
    assert get_resp_header(get, "content-type") |> hd() =~ "application/xml"
    assert get.resp_body =~ "<WebsiteConfiguration"
    assert get.resp_body =~ "<Suffix>index.html</Suffix>"
    assert get.resp_body =~ "<ReplaceKeyPrefixWith>documents/</ReplaceKeyPrefixWith>"

    delete =
      SigV4Request.signed_conn(:delete, "/webcfg", query: %{"website" => ""})
      |> call()

    assert delete.status == 204
    assert delete.resp_body == ""
    assert BucketConfigs.get("webcfg", :website) == :none

    missing =
      SigV4Request.signed_conn(:get, "/webcfg", query: %{"website" => ""})
      |> call()

    assert missing.status == 404
    assert missing.resp_body =~ "NoSuchWebsiteConfiguration"

    idempotent =
      SigV4Request.signed_conn(:delete, "/webcfg", query: %{"website" => ""})
      |> call()

    assert idempotent.status == 204
  end

  test "missing bucket returns NoSuchBucket" do
    put =
      SigV4Request.signed_conn(:put, "/missing-webcfg", query: %{"website" => ""}, body: @website)
      |> call()

    assert put.status == 404
    assert put.resp_body =~ "NoSuchBucket"
  end

  test "invalid website XML fails closed and does not overwrite existing config" do
    assert (SigV4Request.signed_conn(:put, "/webbad") |> call()).status == 200

    good =
      SigV4Request.signed_conn(:put, "/webbad", query: %{"website" => ""}, body: @website)
      |> call()

    assert good.status == 200

    bad_xml =
      ~s(<WebsiteConfiguration><RedirectAllRequestsTo><HostName>example.com</HostName></RedirectAllRequestsTo><IndexDocument><Suffix>index.html</Suffix></IndexDocument></WebsiteConfiguration>)

    bad =
      SigV4Request.signed_conn(:put, "/webbad", query: %{"website" => ""}, body: bad_xml)
      |> call()

    assert bad.status == 400
    assert bad.resp_body =~ "MalformedXML"

    assert {:ok, config} = BucketConfigs.get("webbad", :website)
    assert config["index_document"] == %{"suffix" => "index.html"}
    assert config["redirect_all_requests_to"] == nil
  end

  test "too many routing rules returns MalformedXML" do
    assert (SigV4Request.signed_conn(:put, "/webmany") |> call()).status == 200

    rules =
      1..51
      |> Enum.map(fn n ->
        """
        <RoutingRule>
          <Condition><KeyPrefixEquals>old-#{n}/</KeyPrefixEquals></Condition>
          <Redirect><ReplaceKeyPrefixWith>new-#{n}/</ReplaceKeyPrefixWith></Redirect>
        </RoutingRule>
        """
      end)
      |> Enum.join()

    xml =
      "<WebsiteConfiguration><IndexDocument><Suffix>index.html</Suffix></IndexDocument><RoutingRules>" <>
        rules <> "</RoutingRules></WebsiteConfiguration>"

    put =
      SigV4Request.signed_conn(:put, "/webmany", query: %{"website" => ""}, body: xml)
      |> call()

    assert put.status == 400
    assert put.resp_body =~ "MalformedXML"
    assert BucketConfigs.get("webmany", :website) == :none
  end

  test "object-level website subresource is method not allowed" do
    assert (SigV4Request.signed_conn(:put, "/webobj") |> call()).status == 200

    get =
      SigV4Request.signed_conn(:get, "/webobj/object.txt", query: %{"website" => ""})
      |> call()

    assert get.status == 405
    assert get.resp_body =~ "MethodNotAllowed"
  end

  test "DeleteBucketWebsite requires its own IAM action" do
    assert (SigV4Request.signed_conn(:put, "/webauthz") |> call()).status == 200

    put_policy =
      ~s({"Version":"2012-10-17","Statement":{"Effect":"Allow","Action":"s3:PutBucketWebsite","Resource":"arn:aws:s3:::webauthz"}})

    assert :ok = Store.put_principal_policy(@alice_arn, "put-website-only", put_policy)

    put =
      alice(:put, "/webauthz", query: %{"website" => ""}, body: @website)
      |> call()

    assert put.status == 200

    denied =
      alice(:delete, "/webauthz", query: %{"website" => ""})
      |> call()

    assert denied.status == 403
    assert denied.resp_body =~ "AccessDenied"
    assert {:ok, _config} = BucketConfigs.get("webauthz", :website)

    delete_policy =
      ~s({"Version":"2012-10-17","Statement":{"Effect":"Allow","Action":"s3:DeleteBucketWebsite","Resource":"arn:aws:s3:::webauthz"}})

    assert :ok = Store.put_principal_policy(@alice_arn, "delete-website", delete_policy)

    allowed =
      alice(:delete, "/webauthz", query: %{"website" => ""})
      |> call()

    assert allowed.status == 204
    assert BucketConfigs.get("webauthz", :website) == :none
  end
end
