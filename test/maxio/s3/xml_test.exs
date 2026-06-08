defmodule Maxio.S3.XMLTest do
  use ExUnit.Case, async: true

  alias Maxio.S3.XML

  test "iso8601/1 渲染为带毫秒 Z 的 UTC（列举 XML 体格式）" do
    dt = ~U[2019-12-11 23:32:47.000000Z]
    assert XML.iso8601(dt) == "2019-12-11T23:32:47.000Z"
  end

  test "quote_etag/1 给 etag 加引号（幂等）" do
    assert XML.quote_etag("abc") == "\"abc\""
    assert XML.quote_etag("\"abc\"") == "\"abc\""
  end

  test "encode/1 输出带 prolog 与 root 命名空间的 XML iodata" do
    import Saxy.XML
    root = element("LocationConstraint", [{"xmlns", XML.namespace()}], characters("us-west-2"))
    xml = root |> XML.encode() |> IO.iodata_to_binary()
    assert xml =~ "<?xml version=\"1.0\" encoding=\"UTF-8\"?>"
    assert xml =~ "xmlns=\"http://s3.amazonaws.com/doc/2006-03-01/\""
    assert xml =~ ">us-west-2</LocationConstraint>"
  end
end
