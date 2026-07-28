defmodule Maxio.S3.RequestParsers.CompleteMultipartUploadTest do
  use ExUnit.Case, async: true

  alias Maxio.S3.RequestParsers.CompleteMultipartUpload, as: P

  test "parses multiple parts by element name while preserving request order" do
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

  test "parses ETag before PartNumber" do
    xml =
      "<CompleteMultipartUpload><Part><ETag>\"x\"</ETag><PartNumber>3</PartNumber></Part></CompleteMultipartUpload>"

    assert {:ok, [%{part_number: 3, etag: "\"x\""}]} = P.parse(xml)
  end

  test "parses optional part checksum elements" do
    xml =
      "<CompleteMultipartUpload><Part><PartNumber>1</PartNumber><ETag>\"x\"</ETag><ChecksumSHA256>abc=</ChecksumSHA256><ChecksumCRC32>def=</ChecksumCRC32></Part></CompleteMultipartUpload>"

    assert {:ok,
            [
              %{
                "ChecksumSHA256" => "abc=",
                "ChecksumCRC32" => "def=",
                part_number: 1,
                etag: "\"x\""
              }
            ]} = P.parse(xml)
  end

  test "parses namespaced complete XML" do
    xml =
      ~s(<CompleteMultipartUpload xmlns="http://s3.amazonaws.com/doc/2006-03-01/"><Part><PartNumber>1</PartNumber><ETag>"y"</ETag></Part></CompleteMultipartUpload>)

    assert {:ok, [%{part_number: 1, etag: "\"y\""}]} = P.parse(xml)
  end

  test "returns malformed_xml when no part is present" do
    assert {:error, :malformed_xml} =
             P.parse("<CompleteMultipartUpload></CompleteMultipartUpload>")
  end

  test "returns malformed_xml for wrong root, unknown, misnested, and mixed text" do
    assert {:error, :malformed_xml} =
             P.parse(
               "<NotComplete><Part><PartNumber>1</PartNumber><ETag>\"x\"</ETag></Part></NotComplete>"
             )

    assert {:error, :malformed_xml} =
             P.parse(
               "<CompleteMultipartUpload><Part><PartNumber>1</PartNumber><ETag>\"x\"</ETag></Part><Extra/></CompleteMultipartUpload>"
             )

    assert {:error, :malformed_xml} =
             P.parse(
               "<CompleteMultipartUpload><Part><PartNumber>1</PartNumber><ETag>\"x\"</ETag><Extra/></Part></CompleteMultipartUpload>"
             )

    assert {:error, :malformed_xml} =
             P.parse(
               "<CompleteMultipartUpload>text<Part><PartNumber>1</PartNumber><ETag>\"x\"</ETag></Part></CompleteMultipartUpload>"
             )
  end

  test "returns malformed_xml for missing empty duplicate or nested required fields" do
    invalid = [
      "<CompleteMultipartUpload><Part><ETag>\"x\"</ETag></Part></CompleteMultipartUpload>",
      "<CompleteMultipartUpload><Part><PartNumber>1</PartNumber></Part></CompleteMultipartUpload>",
      "<CompleteMultipartUpload><Part><PartNumber></PartNumber><ETag>\"x\"</ETag></Part></CompleteMultipartUpload>",
      "<CompleteMultipartUpload><Part><PartNumber>1</PartNumber><ETag></ETag></Part></CompleteMultipartUpload>",
      "<CompleteMultipartUpload><Part><PartNumber>1</PartNumber><PartNumber>2</PartNumber><ETag>\"x\"</ETag></Part></CompleteMultipartUpload>",
      "<CompleteMultipartUpload><Part><PartNumber>1</PartNumber><ETag>\"x\"</ETag><ETag>\"y\"</ETag></Part></CompleteMultipartUpload>",
      "<CompleteMultipartUpload><Part><PartNumber><Value>1</Value></PartNumber><ETag>\"x\"</ETag></Part></CompleteMultipartUpload>",
      "<CompleteMultipartUpload><Part><PartNumber>1</PartNumber><ETag><Value>\"x\"</Value></ETag></Part></CompleteMultipartUpload>"
    ]

    for xml <- invalid do
      assert {:error, :malformed_xml} = P.parse(xml)
    end
  end

  test "returns malformed_xml for invalid or out-of-range part numbers" do
    for part_number <- ["0", "10001", "-1", "1x", "1.0"] do
      xml =
        "<CompleteMultipartUpload><Part><PartNumber>#{part_number}</PartNumber><ETag>\"x\"</ETag></Part></CompleteMultipartUpload>"

      assert {:error, :malformed_xml} = P.parse(xml)
    end
  end

  test "returns malformed_xml for duplicate or empty checksum elements" do
    assert {:error, :malformed_xml} =
             P.parse(
               "<CompleteMultipartUpload><Part><PartNumber>1</PartNumber><ETag>\"x\"</ETag><ChecksumSHA256>abc=</ChecksumSHA256><ChecksumSHA256>def=</ChecksumSHA256></Part></CompleteMultipartUpload>"
             )

    assert {:error, :malformed_xml} =
             P.parse(
               "<CompleteMultipartUpload><Part><PartNumber>1</PartNumber><ETag>\"x\"</ETag><ChecksumSHA256></ChecksumSHA256></Part></CompleteMultipartUpload>"
             )
  end

  test "returns malformed_xml for invalid XML" do
    assert {:error, :malformed_xml} = P.parse("<CompleteMultipartUpload><Part>")
    assert {:error, :malformed_xml} = P.parse("not xml at all <<<")
  end
end
