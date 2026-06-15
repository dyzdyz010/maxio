defmodule Maxio.S3.RequestParsers.WebsiteTest do
  use ExUnit.Case, async: true

  alias Maxio.S3.Error
  alias Maxio.S3.Handlers.Website, as: Handler
  alias Maxio.S3.RequestParsers.Website, as: Parser
  alias Maxio.S3.Views.Website, as: View

  test "parses index and error documents and renders them back" do
    xml =
      ~s(<WebsiteConfiguration xmlns="http://s3.amazonaws.com/doc/2006-03-01/"><IndexDocument><Suffix>index.html</Suffix></IndexDocument><ErrorDocument><Key>404.html</Key></ErrorDocument></WebsiteConfiguration>)

    assert {:ok, config} = Parser.parse(xml)
    assert config["index_document"] == %{"suffix" => "index.html"}
    assert config["error_document"] == %{"key" => "404.html"}
    assert config["redirect_all_requests_to"] == nil
    assert config["routing_rules"] == []
    assert :ok = Handler.validate!(config)

    out = config |> View.render() |> IO.iodata_to_binary()
    assert out =~ ~s(<WebsiteConfiguration xmlns="http://s3.amazonaws.com/doc/2006-03-01/">)
    assert out =~ "<Suffix>index.html</Suffix>"
    assert out =~ "<Key>404.html</Key>"
  end

  test "parses redirect-all website configuration" do
    xml =
      ~s(<WebsiteConfiguration><RedirectAllRequestsTo><HostName>example.com</HostName><Protocol>https</Protocol></RedirectAllRequestsTo></WebsiteConfiguration>)

    assert {:ok, config} = Parser.parse(xml)

    assert config["redirect_all_requests_to"] == %{
             "host_name" => "example.com",
             "protocol" => "https"
           }

    assert :ok = Handler.validate!(config)

    out = config |> View.render() |> IO.iodata_to_binary()
    assert out =~ "<RedirectAllRequestsTo>"
    assert out =~ "<HostName>example.com</HostName>"
    assert out =~ "<Protocol>https</Protocol>"
  end

  test "parses routing rules in order" do
    xml = """
    <WebsiteConfiguration>
      <IndexDocument><Suffix>index.html</Suffix></IndexDocument>
      <RoutingRules>
        <RoutingRule>
          <Condition><KeyPrefixEquals>docs/</KeyPrefixEquals></Condition>
          <Redirect><ReplaceKeyPrefixWith>documents/</ReplaceKeyPrefixWith></Redirect>
        </RoutingRule>
        <RoutingRule>
          <Condition><HttpErrorCodeReturnedEquals>404</HttpErrorCodeReturnedEquals></Condition>
          <Redirect>
            <HostName>errors.example.com</HostName>
            <Protocol>https</Protocol>
            <HttpRedirectCode>302</HttpRedirectCode>
          </Redirect>
        </RoutingRule>
      </RoutingRules>
    </WebsiteConfiguration>
    """

    assert {:ok, config} = Parser.parse(xml)
    assert :ok = Handler.validate!(config)
    assert [first, second] = config["routing_rules"]
    assert first["condition"] == %{"key_prefix_equals" => "docs/"}
    assert first["redirect"] == %{"replace_key_prefix_with" => "documents/"}

    assert second["condition"] == %{"http_error_code_returned_equals" => "404"}

    assert second["redirect"] == %{
             "host_name" => "errors.example.com",
             "protocol" => "https",
             "http_redirect_code" => "302"
           }

    out = config |> View.render() |> IO.iodata_to_binary()
    assert out =~ "<RoutingRules>"
    assert out =~ "<ReplaceKeyPrefixWith>documents/</ReplaceKeyPrefixWith>"
    assert out =~ "<HttpRedirectCode>302</HttpRedirectCode>"
  end

  test "rejects malformed XML" do
    assert {:error, :malformed_xml} = Parser.parse("<WebsiteConfiguration><IndexDocument>")
  end

  test "rejects WebsiteConfiguration outside the document root" do
    xml =
      ~s(<Wrapper><WebsiteConfiguration></WebsiteConfiguration><IndexDocument><Suffix>index.html</Suffix></IndexDocument></Wrapper>)

    assert {:error, :malformed_xml} = Parser.parse(xml)
  end

  test "rejects RoutingRule outside RoutingRules" do
    xml =
      ~s(<WebsiteConfiguration><IndexDocument><Suffix>index.html</Suffix></IndexDocument><RoutingRule><Condition><KeyPrefixEquals>docs/</KeyPrefixEquals></Condition><Redirect><ReplaceKeyPrefixWith>documents/</ReplaceKeyPrefixWith></Redirect></RoutingRule></WebsiteConfiguration>)

    assert {:error, :malformed_xml} = Parser.parse(xml)
  end

  test "validation rejects invalid website combinations" do
    redirect_with_index = %{
      "index_document" => %{"suffix" => "index.html"},
      "error_document" => nil,
      "redirect_all_requests_to" => %{"host_name" => "example.com"},
      "routing_rules" => []
    }

    assert_raise Error, ~r/RedirectAllRequestsTo/, fn ->
      Handler.validate!(redirect_with_index)
    end

    missing_index = %{
      "index_document" => nil,
      "error_document" => %{"key" => "404.html"},
      "redirect_all_requests_to" => nil,
      "routing_rules" => []
    }

    assert_raise Error, ~r/requires IndexDocument/, fn -> Handler.validate!(missing_index) end

    suffix_with_slash = %{
      "index_document" => %{"suffix" => "public/index.html"},
      "error_document" => nil,
      "redirect_all_requests_to" => nil,
      "routing_rules" => []
    }

    assert_raise Error, ~r/Invalid IndexDocument/, fn -> Handler.validate!(suffix_with_slash) end

    empty_condition = %{
      "index_document" => %{"suffix" => "index.html"},
      "error_document" => nil,
      "redirect_all_requests_to" => nil,
      "routing_rules" => [%{"condition" => %{}, "redirect" => %{"host_name" => "example.com"}}]
    }

    assert_raise Error, ~r/Invalid RoutingRule/, fn -> Handler.validate!(empty_condition) end

    replace_conflict = %{
      "index_document" => %{"suffix" => "index.html"},
      "error_document" => nil,
      "redirect_all_requests_to" => nil,
      "routing_rules" => [
        %{
          "condition" => %{"key_prefix_equals" => "docs/"},
          "redirect" => %{
            "replace_key_prefix_with" => "documents/",
            "replace_key_with" => "index.html"
          }
        }
      ]
    }

    assert_raise Error, ~r/Invalid RoutingRule/, fn -> Handler.validate!(replace_conflict) end
  end

  test "validation rejects more than 50 routing rules" do
    rules =
      for n <- 1..51 do
        %{
          "condition" => %{"key_prefix_equals" => "old-#{n}/"},
          "redirect" => %{"replace_key_prefix_with" => "new-#{n}/"}
        }
      end

    config = %{
      "index_document" => %{"suffix" => "index.html"},
      "error_document" => nil,
      "redirect_all_requests_to" => nil,
      "routing_rules" => rules
    }

    assert_raise Error, ~r/max 50/, fn -> Handler.validate!(config) end
  end
end
