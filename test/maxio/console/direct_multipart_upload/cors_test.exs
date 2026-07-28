defmodule Maxio.Console.DirectMultipartUpload.CorsTest do
  use Maxio.DataCase, async: false

  alias Maxio.BucketConfigs
  alias Maxio.Buckets
  alias Maxio.Console.DirectMultipartUpload.Cors, as: DirectMultipartCors
  alias Maxio.S3.Handlers.Cors, as: S3Cors
  alias Maxio.S3.RequestParsers.Cors, as: Parser
  alias Maxio.S3.Views.Cors, as: View

  @origin "http://console.example.test:4000"

  test "required direct multipart rule validates and round-trips through S3 CORS XML" do
    assert {:ok, rule} = DirectMultipartCors.rule(@origin)

    assert rule == %{
             "id" => DirectMultipartCors.rule_id(),
             "allowed_origins" => [@origin],
             "allowed_methods" => ["POST", "PUT", "GET", "DELETE"],
             "allowed_headers" => [
               "content-type",
               "content-md5",
               "cache-control",
               "content-disposition",
               "content-encoding",
               "expires",
               "x-amz-*"
             ],
             "expose_headers" => ["ETag"],
             "max_age_seconds" => 3000
           }

    assert :ok = S3Cors.validate!([rule])

    xml = rule |> List.wrap() |> View.render() |> IO.iodata_to_binary()
    assert {:ok, [^rule]} = Parser.parse(xml)
  end

  test "merge is no-op when first-match CORS already supports direct multipart" do
    rules = [sufficient_user_rule()]

    assert DirectMultipartCors.configured?(rules, @origin)
    assert {:ok, ^rules} = DirectMultipartCors.merge(rules, @origin)
  end

  test "merge prepends owned rule before an existing first-match blocker" do
    blocker =
      sufficient_user_rule(%{
        "id" => "custom-without-etag",
        "expose_headers" => []
      })

    later = sufficient_user_rule(%{"id" => "later-good-rule"})
    assert not DirectMultipartCors.configured?([blocker, later], @origin)

    assert {:ok, [owned, ^blocker, ^later]} =
             DirectMultipartCors.merge([blocker, later], @origin)

    assert owned["id"] == DirectMultipartCors.rule_id()
    assert owned["allowed_origins"] == [@origin]
    assert DirectMultipartCors.configured?([owned, blocker, later], @origin)
  end

  test "merge replaces stale owned rule and preserves user rules" do
    user_rule =
      sufficient_user_rule(%{"id" => "user-rule", "allowed_origins" => ["https://app.test"]})

    stale_owned =
      DirectMultipartCors.rule!("https://old-console.test")
      |> Map.put("expose_headers", [])

    assert {:ok, [owned, ^user_rule]} =
             DirectMultipartCors.merge([user_rule, stale_owned], @origin)

    assert owned["id"] == DirectMultipartCors.rule_id()
    assert owned["allowed_origins"] == [@origin]
  end

  test "merge refuses to exceed the 100-rule S3 CORS limit" do
    rules =
      for index <- 1..100 do
        sufficient_user_rule(%{
          "id" => "user-#{index}",
          "allowed_origins" => ["https://app-#{index}.test"]
        })
      end

    assert {:error, :cors_rule_limit} = DirectMultipartCors.merge(rules, @origin)
  end

  test "ensure_bucket_rule stores once and is idempotent" do
    bucket = "direct-cors-helper"
    assert {:ok, _bucket} = Buckets.create(bucket, "arn:aws:iam:::root")

    user_rule =
      sufficient_user_rule(%{"id" => "user-rule", "allowed_origins" => ["https://app.test"]})

    assert :ok = BucketConfigs.put(bucket, :cors, [user_rule])

    assert {:ok, [owned, ^user_rule], :updated} =
             DirectMultipartCors.ensure_bucket_rule(bucket, @origin)

    assert owned["id"] == DirectMultipartCors.rule_id()

    assert {:ok, [^owned, ^user_rule], :unchanged} =
             DirectMultipartCors.ensure_bucket_rule(bucket, @origin)
  end

  test "invalid origins are rejected" do
    assert {:error, :invalid_origin} = DirectMultipartCors.rule("https://console.test/path")
    assert {:error, :invalid_origin} = DirectMultipartCors.merge([], "ftp://console.test")
  end

  test "IPv6 origins keep required brackets" do
    origin = "http://[::1]:4000"

    assert {:ok, rule} = DirectMultipartCors.rule(origin)
    assert rule["allowed_origins"] == [origin]
    assert {:ok, [^rule]} = DirectMultipartCors.merge([], origin)
    assert DirectMultipartCors.configured?([rule], origin)
  end

  defp sufficient_user_rule(overrides \\ %{}) do
    Map.merge(
      %{
        "id" => "custom",
        "allowed_origins" => [@origin],
        "allowed_methods" => ["POST", "PUT", "GET", "DELETE"],
        "allowed_headers" => ["*"],
        "expose_headers" => ["ETag"],
        "max_age_seconds" => 3000
      },
      overrides
    )
  end
end
