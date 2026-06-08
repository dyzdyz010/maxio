defmodule Maxio.CorsTest do
  use ExUnit.Case, async: true
  alias Maxio.Cors

  @rules [
    %{
      "allowed_methods" => ["PUT", "POST", "DELETE"],
      "allowed_origins" => ["http://www.example.com"],
      "allowed_headers" => ["*"],
      "expose_headers" => ["x-amz-request-id"],
      "max_age_seconds" => 3000
    },
    %{
      "allowed_methods" => ["GET"],
      "allowed_origins" => ["*"],
      "allowed_headers" => [],
      "expose_headers" => [],
      "max_age_seconds" => nil
    }
  ]

  test "preflight 命中第一条 rule（origin + method + headers 全匹配）" do
    assert {:ok, rule} =
             Cors.match_preflight(@rules, "http://www.example.com", "PUT", ["x-amz-meta-foo"])

    assert rule["max_age_seconds"] == 3000
  end

  test "preflight：请求头不被允许 → :no_match" do
    rules = [
      %{
        "allowed_methods" => ["PUT"],
        "allowed_origins" => ["http://x.com"],
        "allowed_headers" => ["content-type"],
        "expose_headers" => [],
        "max_age_seconds" => nil
      }
    ]

    assert :no_match = Cors.match_preflight(rules, "http://x.com", "PUT", ["authorization"])
  end

  test "preflight：通配 origin 命中 GET" do
    assert {:ok, _} = Cors.match_preflight(@rules, "http://any.com", "GET", [])
  end

  test "preflight：AllowedHeader 大小写不敏感" do
    rules = [
      %{
        "allowed_methods" => ["PUT"],
        "allowed_origins" => ["http://x.com"],
        "allowed_headers" => ["Content-Type"],
        "expose_headers" => [],
        "max_age_seconds" => nil
      }
    ]

    assert {:ok, _} = Cors.match_preflight(rules, "http://x.com", "PUT", ["content-type"])
  end

  test "实际请求匹配（origin + method）" do
    assert {:ok, rule} = Cors.match_actual(@rules, "http://any.com", "GET")
    assert rule["allowed_origins"] == ["*"]
  end

  test "origin 不匹配 → :no_match" do
    rules = [
      %{
        "allowed_methods" => ["GET"],
        "allowed_origins" => ["http://only.com"],
        "allowed_headers" => [],
        "expose_headers" => [],
        "max_age_seconds" => nil
      }
    ]

    assert :no_match = Cors.match_actual(rules, "http://other.com", "GET")
  end

  test "单 * 通配 origin（http://*.example.com）" do
    rules = [
      %{
        "allowed_methods" => ["GET"],
        "allowed_origins" => ["http://*.example.com"],
        "allowed_headers" => [],
        "expose_headers" => [],
        "max_age_seconds" => nil
      }
    ]

    assert {:ok, _} = Cors.match_actual(rules, "http://sub.example.com", "GET")
    assert :no_match = Cors.match_actual(rules, "http://example.org", "GET")
  end

  test "实际请求方法不匹配 → :no_match" do
    # @rules: rule1 origin=http://www.example.com 允许 PUT/POST/DELETE（不含 GET）；
    # rule2 origin=* 允许 GET。HEAD 任何 rule 都不允许 → :no_match。
    assert :no_match = Cors.match_actual(@rules, "http://www.example.com", "HEAD")
  end
end
