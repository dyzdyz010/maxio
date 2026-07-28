defmodule Maxio.S3.RequestParsers.SelectObjectContentTest do
  use ExUnit.Case, async: true

  alias Maxio.S3.RequestParsers.SelectObjectContent

  test "parses minimal CSV SELECT request" do
    xml = """
    <SelectObjectContentRequest xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
      <Expression>SELECT * FROM S3Object</Expression>
      <ExpressionType>SQL</ExpressionType>
      <InputSerialization><CSV /></InputSerialization>
      <OutputSerialization><CSV /></OutputSerialization>
    </SelectObjectContentRequest>
    """

    assert {:ok, request} = SelectObjectContent.parse(xml)
    assert request.expression == "SELECT * FROM S3Object"
    assert request.expression_type == "SQL"
    assert request.input.format == "CSV"
    assert request.output.format == "CSV"
    refute request.request_progress
    refute request.scan_range?
    assert request.scan_range == nil
  end

  test "captures unsupported request features for handler-level rejection" do
    xml = """
    <SelectObjectContentRequest>
      <Expression>SELECT * FROM S3Object</Expression>
      <ExpressionType>SQL</ExpressionType>
      <InputSerialization>
        <CompressionType>GZIP</CompressionType>
        <CSV><FileHeaderInfo>USE</FileHeaderInfo></CSV>
      </InputSerialization>
      <OutputSerialization><JSON /></OutputSerialization>
      <RequestProgress><Enabled>true</Enabled></RequestProgress>
      <ScanRange><Start>0</Start><End>10</End></ScanRange>
    </SelectObjectContentRequest>
    """

    assert {:ok, request} = SelectObjectContent.parse(xml)
    assert request.input.compression_type == "GZIP"
    assert request.input.csv_options == %{"FileHeaderInfo" => "USE"}
    assert request.output.format == "JSON"
    assert request.request_progress
    assert request.scan_range?
    assert request.scan_range == %{start: 0, end: 10}
  end

  test "captures open-ended ScanRange bounds" do
    assert {:ok, %{scan_range?: true, scan_range: %{start: 5, end: nil}}} =
             SelectObjectContent.parse("""
             <SelectObjectContentRequest>
               <Expression>SELECT * FROM S3Object</Expression>
               <ExpressionType>SQL</ExpressionType>
               <InputSerialization><CSV /></InputSerialization>
               <OutputSerialization><CSV /></OutputSerialization>
               <ScanRange><Start>5</Start></ScanRange>
             </SelectObjectContentRequest>
             """)

    assert {:ok, %{scan_range?: true, scan_range: %{start: nil, end: 8}}} =
             SelectObjectContent.parse("""
             <SelectObjectContentRequest>
               <Expression>SELECT * FROM S3Object</Expression>
               <ExpressionType>SQL</ExpressionType>
               <InputSerialization><CSV /></InputSerialization>
               <OutputSerialization><CSV /></OutputSerialization>
               <ScanRange><End>8</End></ScanRange>
             </SelectObjectContentRequest>
             """)
  end

  test "captures JSON input and output serialization options" do
    xml = """
    <SelectObjectContentRequest>
      <Expression>SELECT s.name FROM S3Object AS s</Expression>
      <ExpressionType>SQL</ExpressionType>
      <InputSerialization><JSON><Type>LINES</Type></JSON></InputSerialization>
      <OutputSerialization><JSON><RecordDelimiter>|</RecordDelimiter></JSON></OutputSerialization>
    </SelectObjectContentRequest>
    """

    assert {:ok, request} = SelectObjectContent.parse(xml)
    assert request.input.format == "JSON"
    assert request.input.json_options == %{"Type" => "LINES"}
    assert request.output.format == "JSON"
    assert request.output.json_options == %{"RecordDelimiter" => "|"}
  end

  test "accepts Parquet input serialization while keeping output formats strict" do
    assert {:ok, request} =
             SelectObjectContent.parse(
               select_request(
                 input: "<CompressionType>NONE</CompressionType><Parquet />",
                 output: "<JSON />"
               )
             )

    assert request.input.format == "Parquet"
    assert request.input.compression_type == "NONE"
    assert request.output.format == "JSON"

    assert {:error, :malformed_xml} =
             SelectObjectContent.parse(select_request(output: "<Parquet />"))
  end

  test "preserves JSON output whitespace record delimiters" do
    xml = """
    <SelectObjectContentRequest>
      <Expression>SELECT * FROM S3Object</Expression>
      <ExpressionType>SQL</ExpressionType>
      <InputSerialization><JSON><Type>LINES</Type></JSON></InputSerialization>
      <OutputSerialization><JSON><RecordDelimiter>&#10;</RecordDelimiter></JSON></OutputSerialization>
    </SelectObjectContentRequest>
    """

    assert {:ok, request} = SelectObjectContent.parse(xml)
    assert request.output.json_options == %{"RecordDelimiter" => "\n"}
  end

  test "rejects malformed or incomplete XML" do
    assert {:error, :malformed_xml} = SelectObjectContent.parse("<broken>")

    assert {:error, :malformed_xml} =
             SelectObjectContent.parse("""
             <SelectObjectContentRequest>
               <Expression>SELECT * FROM S3Object</Expression>
               <ExpressionType>SQL</ExpressionType>
             </SelectObjectContentRequest>
             """)
  end

  test "rejects wrong roots, wrappers, unknown elements, and mixed content" do
    cases = [
      String.replace(select_request(), "SelectObjectContentRequest", "SelectRequest"),
      "<Envelope>#{select_request()}</Envelope>",
      select_request(extra: "<Unknown>value</Unknown>"),
      select_request(input: "<CSV><Unknown>value</Unknown></CSV>"),
      select_request(input: "unexpected-text<CSV />")
    ]

    for xml <- cases do
      assert {:error, :malformed_xml} = SelectObjectContent.parse(xml)
    end
  end

  test "rejects duplicate singleton fields and serialization choices" do
    cases = [
      select_request(extra: "<Expression>SELECT count(*) FROM S3Object</Expression>"),
      """
      <SelectObjectContentRequest>
        <Expression>SELECT * FROM S3Object</Expression>
        <ExpressionType>SQL</ExpressionType>
        <InputSerialization><CSV /></InputSerialization>
        <InputSerialization><JSON /></InputSerialization>
        <OutputSerialization><CSV /></OutputSerialization>
      </SelectObjectContentRequest>
      """,
      select_request(input: "<CSV /><JSON />"),
      select_request(
        input:
          "<CSV><FileHeaderInfo>NONE</FileHeaderInfo><FileHeaderInfo>USE</FileHeaderInfo></CSV>"
      ),
      select_request(output: "<CSV /><JSON />"),
      select_request(
        extra:
          "<RequestProgress><Enabled>true</Enabled></RequestProgress><RequestProgress><Enabled>false</Enabled></RequestProgress>"
      ),
      select_request(extra: "<ScanRange><Start>1</Start><Start>2</Start></ScanRange>")
    ]

    for xml <- cases do
      assert {:error, :malformed_xml} = SelectObjectContent.parse(xml)
    end
  end

  test "rejects invalid enum values" do
    cases = [
      select_request(expression_type: "PQL"),
      select_request(input: "<CompressionType>SNAPPY</CompressionType><CSV />"),
      select_request(input: "<JSON><Type>ROWS</Type></JSON>"),
      select_request(output: "<CSV><QuoteFields>SOMETIMES</QuoteFields></CSV>"),
      select_request(
        input: "<CSV><AllowQuotedRecordDelimiter>yes</AllowQuotedRecordDelimiter></CSV>"
      )
    ]

    for xml <- cases do
      assert {:error, :malformed_xml} = SelectObjectContent.parse(xml)
    end
  end

  test "rejects nested leaf nodes" do
    cases = [
      select_request(expression: "<Value>SELECT * FROM S3Object</Value>"),
      select_request(input: "<CompressionType><Value>GZIP</Value></CompressionType><CSV />"),
      select_request(output: "<JSON><RecordDelimiter><Value>|</Value></RecordDelimiter></JSON>"),
      select_request(
        extra: "<RequestProgress><Enabled><Value>true</Value></Enabled></RequestProgress>"
      )
    ]

    for xml <- cases do
      assert {:error, :malformed_xml} = SelectObjectContent.parse(xml)
    end
  end

  test "rejects invalid RequestProgress booleans" do
    assert {:error, :malformed_xml} =
             SelectObjectContent.parse("""
             <SelectObjectContentRequest>
               <Expression>SELECT * FROM S3Object</Expression>
               <ExpressionType>SQL</ExpressionType>
               <InputSerialization><CSV /></InputSerialization>
               <OutputSerialization><CSV /></OutputSerialization>
               <RequestProgress><Enabled>yes</Enabled></RequestProgress>
             </SelectObjectContentRequest>
             """)
  end

  test "rejects invalid ScanRange XML values" do
    assert {:error, :malformed_xml} =
             SelectObjectContent.parse("""
             <SelectObjectContentRequest>
               <Expression>SELECT * FROM S3Object</Expression>
               <ExpressionType>SQL</ExpressionType>
               <InputSerialization><CSV /></InputSerialization>
               <OutputSerialization><CSV /></OutputSerialization>
               <ScanRange />
             </SelectObjectContentRequest>
             """)

    assert {:error, :malformed_xml} =
             SelectObjectContent.parse("""
             <SelectObjectContentRequest>
               <Expression>SELECT * FROM S3Object</Expression>
               <ExpressionType>SQL</ExpressionType>
               <InputSerialization><CSV /></InputSerialization>
               <OutputSerialization><CSV /></OutputSerialization>
               <ScanRange><Start>-1</Start></ScanRange>
             </SelectObjectContentRequest>
             """)
  end

  defp select_request(opts \\ []) do
    expression = Keyword.get(opts, :expression, "SELECT * FROM S3Object")
    expression_type = Keyword.get(opts, :expression_type, "SQL")
    input = Keyword.get(opts, :input, "<CSV />")
    output = Keyword.get(opts, :output, "<CSV />")
    extra = Keyword.get(opts, :extra, "")

    """
    <SelectObjectContentRequest>
      <Expression>#{expression}</Expression>
      <ExpressionType>#{expression_type}</ExpressionType>
      <InputSerialization>#{input}</InputSerialization>
      <OutputSerialization>#{output}</OutputSerialization>
      #{extra}
    </SelectObjectContentRequest>
    """
  end
end
