defmodule Maxio.S3.RequestParsers.CompleteMultipartUploadTest do
  use ExUnit.Case, async: true

  alias Maxio.S3.RequestParsers.CompleteMultipartUpload, as: P

  test "解析多个 Part（按元素名取值，保留请求顺序）" do
    xml = """
    <?xml version="1.0" encoding="UTF-8"?>
    <CompleteMultipartUpload>
      <Part><PartNumber>1</PartNumber><ETag>"a54357aff0632cce46d942af68356b38"</ETag></Part>
      <Part><PartNumber>2</PartNumber><ETag>"0c78aef83f66abc1fa1e8477f296d394"</ETag></Part>
    </CompleteMultipartUpload>
    """

    assert {:ok, parts} = P.parse(xml)

    assert parts == [
             %{part_number: 1, etag: "\"a54357aff0632cce46d942af68356b38\""},
             %{part_number: 2, etag: "\"0c78aef83f66abc1fa1e8477f296d394\""}
           ]
  end

  test "ETag 在前 PartNumber 在后也能解析（元素顺序不敏感）" do
    xml =
      "<CompleteMultipartUpload><Part><ETag>\"x\"</ETag><PartNumber>3</PartNumber></Part></CompleteMultipartUpload>"

    assert {:ok, [%{part_number: 3, etag: "\"x\""}]} = P.parse(xml)
  end

  test "带命名空间也能解析" do
    xml =
      ~s(<CompleteMultipartUpload xmlns="http://s3.amazonaws.com/doc/2006-03-01/"><Part><PartNumber>1</PartNumber><ETag>"y"</ETag></Part></CompleteMultipartUpload>)

    assert {:ok, [%{part_number: 1, etag: "\"y\""}]} = P.parse(xml)
  end

  test "无 Part → :malformed_xml" do
    assert {:error, :malformed_xml} =
             P.parse("<CompleteMultipartUpload></CompleteMultipartUpload>")
  end

  test "畸形 XML → :malformed_xml" do
    assert {:error, :malformed_xml} = P.parse("<CompleteMultipartUpload><Part>")
    assert {:error, :malformed_xml} = P.parse("not xml at all <<<")
  end
end
