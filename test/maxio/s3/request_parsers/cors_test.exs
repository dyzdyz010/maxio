defmodule Maxio.S3.RequestParsers.CorsTest do
  use ExUnit.Case, async: true

  alias Maxio.S3.Error
  alias Maxio.S3.Handlers.Cors, as: Handler
  alias Maxio.S3.RequestParsers.Cors, as: Parser
  alias Maxio.S3.Views.Cors, as: View

  test "parses namespaced CORSConfiguration and renders it back" do
    xml = """
    <s3:CORSConfiguration xmlns:s3="http://s3.amazonaws.com/doc/2006-03-01/">
      <s3:CORSRule>
        <s3:ID>browser-uploads</s3:ID>
        <s3:AllowedOrigin>https://app.example.com</s3:AllowedOrigin>
        <s3:AllowedMethod>PUT</s3:AllowedMethod>
        <s3:AllowedMethod>GET</s3:AllowedMethod>
        <s3:AllowedHeader>x-amz-*</s3:AllowedHeader>
        <s3:AllowedHeader>content-type</s3:AllowedHeader>
        <s3:ExposeHeader>ETag</s3:ExposeHeader>
        <s3:MaxAgeSeconds>3600</s3:MaxAgeSeconds>
      </s3:CORSRule>
    </s3:CORSConfiguration>
    """

    assert {:ok, [rule]} = Parser.parse(xml)

    assert rule == %{
             "id" => "browser-uploads",
             "allowed_origins" => ["https://app.example.com"],
             "allowed_methods" => ["PUT", "GET"],
             "allowed_headers" => ["x-amz-*", "content-type"],
             "expose_headers" => ["ETag"],
             "max_age_seconds" => 3600
           }

    assert :ok = Handler.validate!([rule])

    out = rule |> List.wrap() |> View.render() |> IO.iodata_to_binary()
    assert out =~ ~s(<CORSConfiguration xmlns="http://s3.amazonaws.com/doc/2006-03-01/">)
    assert out =~ "<AllowedOrigin>https://app.example.com</AllowedOrigin>"
    assert out =~ "<AllowedHeader>x-amz-*</AllowedHeader>"
    assert out =~ "<MaxAgeSeconds>3600</MaxAgeSeconds>"
  end

  test "rejects wrong root empty config unknown elements misnested elements and mixed text" do
    for xml <- [
          "<Wrapper><CORSConfiguration><CORSRule /></CORSConfiguration></Wrapper>",
          "<CORSConfiguration />",
          "<CORSConfiguration><Unknown /></CORSConfiguration>",
          """
          <CORSConfiguration>
            <CORSRule>
              <AllowedOrigin>https://app.example.com</AllowedOrigin>
              <Wrapper><AllowedMethod>GET</AllowedMethod></Wrapper>
            </CORSRule>
          </CORSConfiguration>
          """,
          """
          <CORSConfiguration>
            unexpected
            <CORSRule>
              <AllowedOrigin>https://app.example.com</AllowedOrigin>
              <AllowedMethod>GET</AllowedMethod>
            </CORSRule>
          </CORSConfiguration>
          """,
          """
          <CORSConfiguration>
            <CORSRule>
              <AllowedOrigin>https://app.example.com</AllowedOrigin>
              <AllowedMethod>GET</AllowedMethod>
              <Unknown>value</Unknown>
            </CORSRule>
          </CORSConfiguration>
          """
        ] do
      assert {:error, :malformed_xml} = Parser.parse(xml)
    end
  end

  test "rejects duplicate singleton fields invalid max age nested text and empty required values" do
    for xml <- [
          """
          <CORSConfiguration>
            <CORSRule>
              <ID>one</ID><ID>two</ID>
              <AllowedOrigin>https://app.example.com</AllowedOrigin>
              <AllowedMethod>GET</AllowedMethod>
            </CORSRule>
          </CORSConfiguration>
          """,
          """
          <CORSConfiguration>
            <CORSRule>
              <AllowedOrigin>https://app.example.com</AllowedOrigin>
              <AllowedMethod>GET</AllowedMethod>
              <MaxAgeSeconds>300</MaxAgeSeconds>
              <MaxAgeSeconds>400</MaxAgeSeconds>
            </CORSRule>
          </CORSConfiguration>
          """,
          """
          <CORSConfiguration>
            <CORSRule>
              <AllowedOrigin>https://app.example.com</AllowedOrigin>
              <AllowedMethod>GET</AllowedMethod>
              <MaxAgeSeconds>abc</MaxAgeSeconds>
            </CORSRule>
          </CORSConfiguration>
          """,
          """
          <CORSConfiguration>
            <CORSRule>
              <AllowedOrigin><Value>https://app.example.com</Value></AllowedOrigin>
              <AllowedMethod>GET</AllowedMethod>
            </CORSRule>
          </CORSConfiguration>
          """,
          """
          <CORSConfiguration>
            <CORSRule>
              <AllowedOrigin>   </AllowedOrigin>
              <AllowedMethod>GET</AllowedMethod>
            </CORSRule>
          </CORSConfiguration>
          """
        ] do
      assert {:error, :malformed_xml} = Parser.parse(xml)
    end
  end

  test "handler validation rejects empty rules invalid wildcards negative max age and long IDs" do
    assert_raise Error, ~r/at least one rule/, fn -> Handler.validate!([]) end

    assert_raise Error, ~r/Invalid CORS rule/, fn ->
      Handler.validate!([
        %{
          "id" => String.duplicate("x", 256),
          "allowed_origins" => ["https://app.example.com"],
          "allowed_methods" => ["GET"],
          "allowed_headers" => [],
          "expose_headers" => [],
          "max_age_seconds" => nil
        }
      ])
    end

    for rule <- [
          %{
            "id" => nil,
            "allowed_origins" => ["https://*.example.*"],
            "allowed_methods" => ["GET"],
            "allowed_headers" => [],
            "expose_headers" => [],
            "max_age_seconds" => nil
          },
          %{
            "id" => nil,
            "allowed_origins" => ["https://app.example.com"],
            "allowed_methods" => ["GET"],
            "allowed_headers" => ["x-*-*"],
            "expose_headers" => [],
            "max_age_seconds" => nil
          },
          %{
            "id" => nil,
            "allowed_origins" => ["https://app.example.com"],
            "allowed_methods" => ["GET"],
            "allowed_headers" => [],
            "expose_headers" => [],
            "max_age_seconds" => -1
          }
        ] do
      assert_raise Error, ~r/Invalid CORS rule/, fn -> Handler.validate!([rule]) end
    end
  end
end
