defmodule Maxio.S3.SelectObjectContentE2ETest do
  use Maxio.DataCase, async: false

  import Plug.Conn

  alias Maxio.Auth.CredentialStore
  alias Maxio.Policy.Store
  alias Maxio.S3.Endpoint
  alias Maxio.S3.SelectCSV
  alias Maxio.Test.SigV4Request

  @data_dir Path.join(System.tmp_dir!(), "maxio_select_object_content_test")
  @alice_ak "AKIASELECTALICE001"
  @alice_secret "selectalicealicesecret12345"
  @alice_arn "arn:aws:iam:::user/" <> @alice_ak
  @owner "000000000000"
  @other_owner "999999999999"
  @requester """
  <RequestPaymentConfiguration xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
    <Payer>Requester</Payer>
  </RequestPaymentConfiguration>
  """
  @select_xml """
  <SelectObjectContentRequest xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
    <Expression>SELECT * FROM S3Object</Expression>
    <ExpressionType>SQL</ExpressionType>
    <InputSerialization><CSV /></InputSerialization>
    <OutputSerialization><CSV /></OutputSerialization>
  </SelectObjectContentRequest>
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

  test "POST ?select returns Records, Stats, and End event-stream messages for simple CSV" do
    assert create_bucket("selectb").status == 200
    assert put_object("selectb", "data.csv", "a,b\nc,d\n").status == 200

    resp = select_object("selectb", "data.csv", @select_xml)

    assert resp.status == 200
    assert get_resp_header(resp, "content-type") == ["application/vnd.amazon.eventstream"]

    events = decode_events(resp.resp_body)
    assert Enum.map(events, & &1.headers[":event-type"]) == ["Records", "Stats", "End"]

    records = Enum.find(events, &(&1.headers[":event-type"] == "Records"))
    assert records.payload == "a,b\nc,d\n"

    stats = events |> Enum.find(&(&1.headers[":event-type"] == "Stats")) |> Map.fetch!(:payload)
    assert stats =~ "<BytesScanned>8</BytesScanned>"
    assert stats =~ "<BytesProcessed>8</BytesProcessed>"
    assert stats =~ "<BytesReturned>8</BytesReturned>"
  end

  test "request progress emits Progress before Stats" do
    assert create_bucket("selectprogress").status == 200
    assert put_object("selectprogress", "data.csv", "a,b\n").status == 200

    xml =
      String.replace(
        @select_xml,
        "</OutputSerialization>",
        "</OutputSerialization><RequestProgress><Enabled>true</Enabled></RequestProgress>"
      )

    resp = select_object("selectprogress", "data.csv", xml)

    assert resp.status == 200

    assert Enum.map(decode_events(resp.resp_body), & &1.headers[":event-type"]) == [
             "Records",
             "Progress",
             "Stats",
             "End"
           ]
  end

  test "projects positional CSV columns" do
    assert create_bucket("selectproject").status == 200
    assert put_object("selectproject", "data.csv", "a,b\nc,d\n").status == 200

    resp = select_object("selectproject", "data.csv", select_xml("SELECT _2, _1 FROM S3Object"))

    assert resp.status == 200
    assert records_payload(resp) == "b,a\nd,c\n"
  end

  test "filters and limits CSV rows before event-stream response" do
    assert create_bucket("selectwhere").status == 200
    assert put_object("selectwhere", "data.csv", "a,keep\nb,drop\nc,keep\n").status == 200

    resp =
      select_object(
        "selectwhere",
        "data.csv",
        select_xml("SELECT _1 FROM S3Object s WHERE s._2 = 'keep' LIMIT 1")
      )

    assert resp.status == 200
    assert records_payload(resp) == "a\n"
  end

  test "CSV WHERE supports boolean AND OR NOT and parentheses" do
    assert create_bucket("selectcsvbool").status == 200
    assert put_object("selectcsvbool", "data.csv", "a,1\nb,2\nc,3\n").status == 200

    resp =
      select_object(
        "selectcsvbool",
        "data.csv",
        select_xml("SELECT _1 FROM S3Object WHERE (_2 = '1' OR _2 = '3') AND NOT _1 = 'c'")
      )

    assert resp.status == 200
    assert records_payload(resp) == "a\n"
  end

  test "CSV WHERE supports IS NULL and IS NOT NULL for nullable fields" do
    assert create_bucket("selectcsvnotnull").status == 200
    assert put_object("selectcsvnotnull", "data.csv", "a,\nb\nc,value\n").status == 200

    null_resp =
      select_object(
        "selectcsvnotnull",
        "data.csv",
        select_xml("SELECT _1 FROM S3Object WHERE _2 IS NULL")
      )

    assert null_resp.status == 200
    assert records_payload(null_resp) == "a\n"

    not_null_resp =
      select_object(
        "selectcsvnotnull",
        "data.csv",
        select_xml("SELECT _1 FROM S3Object WHERE _2 IS NOT NULL")
      )

    assert not_null_resp.status == 200
    assert records_payload(not_null_resp) == "c\n"
  end

  test "CSV WHERE supports IN BETWEEN and LIKE predicates" do
    assert create_bucket("selectcsvpredicates").status == 200

    assert put_object(
             "selectcsvpredicates",
             "data.csv",
             "alpha,10,A_da\nbeta,15,Ada\ngamma,30,A_x\n"
           ).status == 200

    resp =
      select_object(
        "selectcsvpredicates",
        "data.csv",
        select_xml(
          "SELECT _1 FROM S3Object WHERE _1 IN ('alpha', 'beta', 'delta') AND _2 BETWEEN 9 AND 20 AND _3 LIKE 'A!_%' ESCAPE '!'"
        )
      )

    assert resp.status == 200
    assert records_payload(resp) == "alpha\n"
  end

  test "CSV WHERE supports NOT IN and NOT BETWEEN predicates without matching missing fields" do
    assert create_bucket("selectcsvnotpredicates").status == 200

    assert put_object(
             "selectcsvnotpredicates",
             "data.csv",
             "alpha,10\nbeta,25\ngamma\ndelta,25\n"
           ).status ==
             200

    resp =
      select_object(
        "selectcsvnotpredicates",
        "data.csv",
        select_xml("SELECT _1 FROM S3Object WHERE _1 NOT IN ('beta') AND _2 NOT BETWEEN 9 AND 20")
      )

    assert resp.status == 200
    assert records_payload(resp) == "delta\n"
  end

  test "CSV WHERE NOT does not match missing or null comparison operands" do
    assert create_bucket("selectcsvnotunknown").status == 200

    assert put_object("selectcsvnotunknown", "data.csv", "alpha,x\nmissing\nempty,\nbeta,y\n").status ==
             200

    resp =
      select_object(
        "selectcsvnotunknown",
        "data.csv",
        select_xml("SELECT _1 FROM S3Object WHERE NOT _2 = 'x'")
      )

    assert resp.status == 200
    assert records_payload(resp) == "beta\n"
  end

  test "CSV Select supports CAST projections and CAST WHERE predicates" do
    assert create_bucket("selectcsvcastprojection").status == 200

    assert put_object("selectcsvcastprojection", "data.csv", "a,10,2.5\nb,7,2.4\nc,11,1.0\n").status ==
             200

    resp =
      select_object(
        "selectcsvcastprojection",
        "data.csv",
        select_xml("SELECT cast(_2 AS INT), _1 FROM S3Object WHERE cast(_3 AS FLOAT) >= 2.5")
      )

    assert resp.status == 200
    assert records_payload(resp) == "10,a\n"
  end

  test "CSV Select projection aliases do not alter CSV output fields" do
    assert create_bucket("selectcsvaliasprojection").status == 200
    assert put_object("selectcsvaliasprojection", "data.csv", "a,b\n").status == 200

    resp =
      select_object(
        "selectcsvaliasprojection",
        "data.csv",
        select_xml("SELECT _2 AS second, _1 AS first FROM S3Object")
      )

    assert resp.status == 200
    assert records_payload(resp) == "b,a\n"
  end

  test "CSV Select supports string function projections and WHERE predicates" do
    assert create_bucket("selectcsvstringfunctions").status == 200

    assert put_object(
             "selectcsvstringfunctions",
             "data.csv",
             "Ada, Keep ,xxHelloYY\nBob,drop,skip\n"
           ).status == 200

    resp =
      select_object(
        "selectcsvstringfunctions",
        "data.csv",
        select_xml(
          "SELECT lower(_1), upper(_1), char_length(trim(_2)), substring(_3, 3, 5), trim(both 'xy' from _3) FROM S3Object WHERE lower(trim(_2)) = 'keep'"
        )
      )

    assert resp.status == 200
    assert records_payload(resp) == "ada,ADA,4,Hello,HelloYY\n"
  end

  test "CSV Select string functions preserve null semantics in WHERE" do
    assert create_bucket("selectcsvstringnull").status == 200

    assert put_object("selectcsvstringnull", "data.csv", "empty,\nmissing\nkeep,KEEP\n").status ==
             200

    resp =
      select_object(
        "selectcsvstringnull",
        "data.csv",
        select_xml("SELECT _1 FROM S3Object WHERE lower(_2) = 'keep'")
      )

    assert resp.status == 200
    assert records_payload(resp) == "keep\n"
  end

  test "CSV Select SUBSTRING handles zero and negative starts" do
    assert create_bucket("selectcsvsubstringbounds").status == 200
    assert put_object("selectcsvsubstringbounds", "data.csv", "abcdef\n").status == 200

    resp =
      select_object(
        "selectcsvsubstringbounds",
        "data.csv",
        select_xml(
          "SELECT substring(_1, 0, 3), substring(_1, -1, 3), substring(_1 FROM 0), substring(_1 FROM -1 FOR 3) FROM S3Object"
        )
      )

    assert resp.status == 200
    assert records_payload(resp) == "ab,a,abcdef,a\n"
  end

  test "CSV Select TRIM supports leading and trailing character sets" do
    assert create_bucket("selectcsvtrimbounds").status == 200
    assert put_object("selectcsvtrimbounds", "data.csv", "xyxyHellozz\n").status == 200

    resp =
      select_object(
        "selectcsvtrimbounds",
        "data.csv",
        select_xml("SELECT trim(leading 'xy' from _1), trim(trailing 'z' from _1) FROM S3Object")
      )

    assert resp.status == 200
    assert records_payload(resp) == "Hellozz,xyxyHello\n"
  end

  test "CSV Select supports conditional expressions in projections and WHERE predicates" do
    assert create_bucket("selectcsvconditionals").status == 200

    assert put_object(
             "selectcsvconditionals",
             "data.csv",
             "Ada,,active\nBob,label,skip\nCid,,active\n"
           ).status == 200

    resp =
      select_object(
        "selectcsvconditionals",
        "data.csv",
        select_xml(
          "SELECT CASE WHEN lower(_3) = 'active' THEN upper(_1) ELSE 'NO' END, CASE _1 WHEN 'Bob' THEN 'B' ELSE 'X' END, coalesce(_2, 'fallback'), coalesce(_4, 'missing'), nullif(_2, 'label') FROM S3Object WHERE coalesce(_2, 'keep') = 'keep' OR nullif(_1, 'Bob') IS NULL"
        )
      )

    assert resp.status == 200

    assert records_payload(resp) ==
             "ADA,X,fallback,missing,\nNO,B,label,missing,\nCID,X,fallback,missing,\n"
  end

  test "CSV Select CASE without ELSE returns null output" do
    assert create_bucket("selectcsvcasenullelse").status == 200
    assert put_object("selectcsvcasenullelse", "data.csv", "Ada\nBob\n").status == 200

    resp =
      select_object(
        "selectcsvcasenullelse",
        "data.csv",
        select_xml("SELECT CASE WHEN _1 = 'Ada' THEN 'hit' END FROM S3Object")
      )

    assert resp.status == 200
    assert records_payload(resp) == "hit\n\n"
  end

  test "CSV Select supports arithmetic projections and RHS comparison expressions" do
    assert create_bucket("selectcsvarithmetic").status == 200

    assert put_object(
             "selectcsvarithmetic",
             "data.csv",
             "Ada,6,3,14\nBob,5,1,0\nNull,,2,3\n"
           ).status == 200

    resp =
      select_object(
        "selectcsvarithmetic",
        "data.csv",
        select_xml(
          "SELECT _2 + _3 * 2, (_2 + _3) * 2, -_2, _2 / _3, _2 % _3 FROM S3Object WHERE _2 + _3 = _4 - 5"
        )
      )

    assert resp.status == 200
    assert records_payload(resp) == "12,18,-6,2,0\n"
  end

  test "CSV Select arithmetic treats empty fields as SQL null in projections" do
    assert create_bucket("selectcsvarithmeticnull").status == 200
    assert put_object("selectcsvarithmeticnull", "data.csv", "empty,\nvalue,2\n").status == 200

    resp =
      select_object(
        "selectcsvarithmeticnull",
        "data.csv",
        select_xml("SELECT _2 + 1, -_2 FROM S3Object")
      )

    assert resp.status == 200
    assert records_payload(resp) == ",\n3,-2\n"
  end

  test "CSV Select rejects arithmetic division by zero before event-stream response" do
    assert create_bucket("selectcsvarithmeticzero").status == 200
    assert put_object("selectcsvarithmeticzero", "data.csv", "a,1,0\n").status == 200

    resp =
      select_object(
        "selectcsvarithmeticzero",
        "data.csv",
        select_xml("SELECT _2 / _3 FROM S3Object")
      )

    assert resp.status == 400
    assert get_resp_header(resp, "content-type") |> List.first() =~ "application/xml"
    assert resp.resp_body =~ "<Code>InvalidKeyPath</Code>"
  end

  test "CSV Select rejects nonnumeric arithmetic before event-stream response" do
    assert create_bucket("selectcsvbadarithmetic").status == 200
    assert put_object("selectcsvbadarithmetic", "data.csv", "a,not-a-number\n").status == 200

    resp =
      select_object(
        "selectcsvbadarithmetic",
        "data.csv",
        select_xml("SELECT _2 + 1 FROM S3Object")
      )

    assert resp.status == 400
    assert get_resp_header(resp, "content-type") |> List.first() =~ "application/xml"
    assert resp.resp_body =~ "<Code>InvalidKeyPath</Code>"
  end

  test "CSV Select rejects nonnumeric ordered comparisons before event-stream response" do
    assert create_bucket("selectcsvbadordered").status == 200
    assert put_object("selectcsvbadordered", "data.csv", "a,b\n").status == 200

    resp =
      select_object(
        "selectcsvbadordered",
        "data.csv",
        select_xml("SELECT _1 FROM S3Object WHERE _1 &lt; _2")
      )

    assert resp.status == 400
    assert get_resp_header(resp, "content-type") |> List.first() =~ "application/xml"
    assert resp.resp_body =~ "<Code>InvalidKeyPath</Code>"
  end

  test "CSV Select supports predicate value expressions and CAST expression operands" do
    assert create_bucket("selectcsvdynamicpredicates").status == 200

    assert put_object(
             "selectcsvdynamicpredicates",
             "data.csv",
             "A_da,6,3,7,9,A!_%,!,true\nBob,4,3,1,6,B!_%,!,false\nNull,,3,1,9,A!_%,!,true\n"
           ).status == 200

    resp =
      select_object(
        "selectcsvdynamicpredicates",
        "data.csv",
        select_xml(
          "SELECT cast(_2 + _3 AS STRING), cast(_8 AS BOOL), true, false FROM S3Object WHERE _2 + _3 IN (_4 + 2, 99) AND _2 + _3 BETWEEN _4 + 1 AND _5 AND _1 LIKE _6 ESCAPE _7 AND cast(_8 AS BOOL) = true"
        )
      )

    assert resp.status == 200
    assert records_payload(resp) == "9,true,true,false\n"
  end

  test "CSV Select supports date functions in projections and WHERE predicates" do
    assert create_bucket("selectcsvdatefunctions").status == 200

    assert put_object(
             "selectcsvdatefunctions",
             "data.csv",
             "Ada,2026-07-03T10:30:00Z\nBob,2026-07-01T23:00:00Z\nNull,\n"
           ).status == 200

    resp =
      select_object(
        "selectcsvdatefunctions",
        "data.csv",
        select_xml(
          "SELECT extract(year FROM to_timestamp(_2)), extract(month FROM to_timestamp(_2)), date_add(day, 2, to_timestamp(_2)), date_diff(day, `2026-07-01T00:00:00Z`, to_timestamp(_2)), date_add(month, 1, `2026-01-31T`), date_diff(month, `2026-01-01T`, `2026-04-01T`) FROM S3Object WHERE to_timestamp(_2) BETWEEN `2026-07-02T00:00:00Z` AND date_add(day, 2, `2026-07-02T00:00:00Z`)"
        )
      )

    assert resp.status == 200
    assert records_payload(resp) == "2026,7,2026-07-05T10:30:00Z,2,2026-02-28T,3\n"
  end

  test "CSV Select preserves nanosecond timestamp precision and ordering" do
    assert create_bucket("selectcsvtimestampnanos").status == 200

    assert put_object(
             "selectcsvtimestampnanos",
             "data.csv",
             "Ada,2026-07-03T10:30:00.123456900Z\nBob,2026-07-03T10:30:00.123456100Z\nCara,2026-07-03T10:30:00.100000000Z\n"
           ).status == 200

    resp =
      select_object(
        "selectcsvtimestampnanos",
        "data.csv",
        select_xml(
          "SELECT to_timestamp(_2) FROM S3Object WHERE to_timestamp(_2) > `2026-07-03T10:30:00.123456500Z`"
        )
      )

    assert resp.status == 200
    assert records_payload(resp) == "2026-07-03T10:30:00.123456900Z\n"

    equal_resp =
      select_object(
        "selectcsvtimestampnanos",
        "data.csv",
        select_xml(
          "SELECT to_timestamp(_2) FROM S3Object WHERE to_timestamp(_2) = `2026-07-03T10:30:00.1Z`"
        )
      )

    assert equal_resp.status == 200
    assert records_payload(equal_resp) == "2026-07-03T10:30:00.100000000Z\n"
  end

  test "CSV Select date arithmetic preserves precision and normalizes offset diffs" do
    assert create_bucket("selectcsvdateedgecases").status == 200
    assert put_object("selectcsvdateedgecases", "data.csv", "row\n").status == 200

    resp =
      select_object(
        "selectcsvdateedgecases",
        "data.csv",
        select_xml(
          "SELECT date_add(year, 1, `2024-02-29T`), date_add(month, -1, `2026-03-31T`), date_diff(month, `2026-01-31T23:30-01:00`, `2026-02-01T00:45Z`), date_diff(year, `2025-12-31T23:30-01:00`, `2026-01-01T00:45Z`), date_add(second, 1, `2026-07-03T10:30:00.006789123Z`) FROM S3Object"
        )
      )

    assert resp.status == 200
    assert records_payload(resp) == "2025-02-28T,2026-02-28T,0,0,2026-07-03T10:30:01.006789123Z\n"
  end

  test "CSV Select supports TO_STRING date formatting and UTCNOW" do
    assert create_bucket("selectcsvtostring").status == 200
    assert put_object("selectcsvtostring", "data.csv", "row\n").status == 200

    resp =
      select_object(
        "selectcsvtostring",
        "data.csv",
        select_xml(
          "SELECT to_string(`1969-07-20T20:18Z`, 'MMMM d y h:m a'), to_string(`1969-07-20T20:18Z`, 'y-MM-dd''T''H:m:ssX'), to_string(`1969-07-20T20:18+08:00`, 'y-MM-dd''T''H:m:ssXXXX'), to_string(`1969-07-20T20:18+08:00`, 'y-MM-dd''T''H:m:ssXXXXX'), to_string(`2026-07-03T10:30:00.060000000-03:30`, 'S'), to_string(`2026-07-03T10:30:00.060000000-03:30`, 'SS'), to_string(`2026-07-03T10:30:00.060000000-03:30`, 'SSS'), to_string(`2026-07-03T10:30:00.060000000-03:30`, 'SSSSSSSSS'), to_string(`2026-07-03T10:30:00.006789123-03:30`, 'n'), to_string(`2026-07-03T10:30:00.006789123-03:30`, 'x'), to_string(`2026-07-03T10:30:00.006789123-03:30`, 'xx'), to_string(`2026-07-03T10:30:00.006789123-03:30`, 'xxx') FROM S3Object"
        )
      )

    assert resp.status == 200

    assert records_payload(resp) ==
             "July 20 1969 8:18 PM,1969-07-20T20:18:00Z,1969-07-20T20:18:00+0800,1969-07-20T20:18:00+08:00,0,6,60,60000000,6789123,-3,-330,-03:30\n"

    utcnow_resp =
      select_object(
        "selectcsvtostring",
        "data.csv",
        select_xml(
          "SELECT date_diff(second, utcnow(), utcnow()), to_string(utcnow(), 'yyyy-MM-dd''T''HH:mm:ssX') FROM S3Object"
        )
      )

    assert utcnow_resp.status == 200
    assert records_payload(utcnow_resp) =~ ~r/^0,\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z\n$/
  end

  test "CSV Select rejects invalid TO_STRING format patterns before event-stream response" do
    assert create_bucket("selectcsvtostringbad").status == 200
    assert put_object("selectcsvtostringbad", "data.csv", "row\n").status == 200

    resp =
      select_object(
        "selectcsvtostringbad",
        "data.csv",
        select_xml("SELECT to_string(`1969-07-20T20:18Z`, 'Q') FROM S3Object")
      )

    assert resp.status == 400
    assert get_resp_header(resp, "content-type") |> List.first() =~ "application/xml"
    assert resp.resp_body =~ "<Code>InvalidKeyPath</Code>"
  end

  test "CSV Select rejects invalid timestamp inputs before event-stream response" do
    assert create_bucket("selectcsvbadtimestamp").status == 200
    assert put_object("selectcsvbadtimestamp", "data.csv", "bad,not-a-timestamp\n").status == 200

    resp =
      select_object(
        "selectcsvbadtimestamp",
        "data.csv",
        select_xml("SELECT to_timestamp(_2) FROM S3Object")
      )

    assert resp.status == 400
    assert get_resp_header(resp, "content-type") |> List.first() =~ "application/xml"
    assert resp.resp_body =~ "<Code>ValueParseFailure</Code>"
  end

  test "CSV Select supports CAST AS TIMESTAMP and numeric type aliases" do
    assert create_bucket("selectcsvcasttimestamp").status == 200

    assert put_object(
             "selectcsvcasttimestamp",
             "data.csv",
             "Ada,2026-07-03T10:30:00.123Z,2,3.5\nBob,2026-07-03T11:00Z,4,5.25\n"
           ).status == 200

    resp =
      select_object(
        "selectcsvcasttimestamp",
        "data.csv",
        select_xml(
          "SELECT cast(_2 AS TIMESTAMP), to_string(cast(_2 AS TIMESTAMP), 'HH:mmX'), cast(_3 AS INTEGER) + cast(_4 AS DECIMAL), cast(_4 AS DOUBLE) FROM S3Object WHERE cast(_2 AS TIMESTAMP) &gt;= `2026-07-03T10:45Z`"
        )
      )

    assert resp.status == 200
    assert records_payload(resp) == "2026-07-03T11:00Z,11:00Z,9.25,5.25\n"
  end

  test "CSV Select rejects invalid CAST timestamp inputs before event-stream response" do
    assert create_bucket("selectcsvbadcasttimestamp").status == 200

    assert put_object("selectcsvbadcasttimestamp", "data.csv", "bad,not-a-timestamp\n").status ==
             200

    resp =
      select_object(
        "selectcsvbadcasttimestamp",
        "data.csv",
        select_xml("SELECT cast(_2 AS TIMESTAMP) FROM S3Object")
      )

    assert resp.status == 400
    assert get_resp_header(resp, "content-type") |> List.first() =~ "application/xml"
    assert resp.resp_body =~ "<Code>ValueParseFailure</Code>"
  end

  test "CSV Select supports CAST with header-name references" do
    assert create_bucket("selectcsvcastheaders").status == 200

    assert put_object(
             "selectcsvcastheaders",
             "data.csv",
             "name,age,score\nAda,36,1.5\nBob,40,2.5\n"
           ).status == 200

    resp =
      select_object(
        "selectcsvcastheaders",
        "data.csv",
        select_xml(
          "SELECT cast(age AS INT) FROM S3Object WHERE cast(score AS FLOAT) &gt; 2",
          "<FileHeaderInfo>USE</FileHeaderInfo>"
        )
      )

    assert resp.status == 200
    assert records_payload(resp) == "40\n"
  end

  test "CSV Select supports string functions with header-name references" do
    assert create_bucket("selectcsvstringheaders").status == 200

    assert put_object(
             "selectcsvstringheaders",
             "data.csv",
             "name,status\nAda, Keep \nBob,drop\n"
           ).status == 200

    resp =
      select_object(
        "selectcsvstringheaders",
        "data.csv",
        select_xml(
          "SELECT upper(name), char_length(trim(status)) FROM S3Object WHERE lower(trim(status)) = 'keep'",
          "<FileHeaderInfo>USE</FileHeaderInfo>"
        )
      )

    assert resp.status == 200
    assert records_payload(resp) == "ADA,4\n"
  end

  test "CSV Select supports aggregate projections with CAST and null skipping" do
    assert create_bucket("selectcsvaggregate").status == 200
    assert put_object("selectcsvaggregate", "data.csv", "a,10\nb,\nc\nd,20\n").status == 200

    resp =
      select_object(
        "selectcsvaggregate",
        "data.csv",
        select_xml(
          "SELECT count(*), count(_2), sum(cast(_2 AS INT)), avg(cast(_2 AS FLOAT)), min(_2), max(_2) FROM S3Object"
        )
      )

    assert resp.status == 200
    assert records_payload(resp) == "4,2,30,15,10,20\n"
  end

  test "CSV Select rejects mixed aggregate and non-aggregate projections before event-stream response" do
    assert create_bucket("selectcsvmixedaggregate").status == 200
    assert put_object("selectcsvmixedaggregate", "data.csv", "a,10\n").status == 200

    resp =
      select_object(
        "selectcsvmixedaggregate",
        "data.csv",
        select_xml("SELECT _1, count(*) FROM S3Object")
      )

    assert resp.status == 400
    assert get_resp_header(resp, "content-type") |> List.first() =~ "application/xml"
    assert resp.resp_body =~ "<Code>UnsupportedSqlStructure</Code>"
  end

  test "CSV Select rejects nonnumeric aggregate inputs before event-stream response" do
    assert create_bucket("selectcsvbadaggregate").status == 200
    assert put_object("selectcsvbadaggregate", "data.csv", "a,not-a-number\n").status == 200

    resp =
      select_object(
        "selectcsvbadaggregate",
        "data.csv",
        select_xml("SELECT sum(_2) FROM S3Object")
      )

    assert resp.status == 400
    assert get_resp_header(resp, "content-type") |> List.first() =~ "application/xml"
    assert resp.resp_body =~ "<Code>InvalidKeyPath</Code>"
  end

  test "CSV Select rejects nonnumeric CAST projections before event-stream response" do
    assert create_bucket("selectcsvbadcast").status == 200
    assert put_object("selectcsvbadcast", "data.csv", "a,not-a-number\n").status == 200

    resp =
      select_object(
        "selectcsvbadcast",
        "data.csv",
        select_xml("SELECT cast(_2 AS INT) FROM S3Object")
      )

    assert resp.status == 400
    assert get_resp_header(resp, "content-type") |> List.first() =~ "application/xml"
    assert resp.resp_body =~ "<Code>CastFailed</Code>"
  end

  test "LIMIT short-circuits large objects without source length mismatch" do
    assert create_bucket("selectlimitbig").status == 200

    body = "a,keep\n" <> String.duplicate("b,drop\n", 250_000)
    assert put_object("selectlimitbig", "data.csv", body).status == 200

    resp =
      select_object(
        "selectlimitbig",
        "data.csv",
        select_xml("SELECT _1 FROM S3Object WHERE _2 = 'keep' LIMIT 1")
      )

    assert resp.status == 200
    assert records_payload(resp) == "a\n"
  end

  test "LIMIT 0 does not buffer oversized CSV records" do
    assert create_bucket("selectlimitzero").status == 200

    assert put_object("selectlimitzero", "data.csv", String.duplicate("x", 1_048_577)).status ==
             200

    resp =
      select_object(
        "selectlimitzero",
        "data.csv",
        select_xml("SELECT * FROM S3Object LIMIT 0")
      )

    assert resp.status == 200
    refute records_event?(resp)
  end

  test "LIMIT 0 does not buffer ignored oversized CSV headers" do
    assert create_bucket("selectlimitzerohead").status == 200

    assert put_object("selectlimitzerohead", "data.csv", String.duplicate("x", 1_048_577)).status ==
             200

    resp =
      select_object(
        "selectlimitzerohead",
        "data.csv",
        select_xml("SELECT * FROM S3Object LIMIT 0", "<FileHeaderInfo>IGNORE</FileHeaderInfo>")
      )

    assert resp.status == 200
    refute records_event?(resp)
  end

  test "LIMIT 0 does not require CSV header names to be parsed" do
    assert create_bucket("selectlimitzerouse").status == 200

    assert put_object("selectlimitzerouse", "data.csv", String.duplicate("x", 1_048_577)).status ==
             200

    resp =
      select_object(
        "selectlimitzerouse",
        "data.csv",
        select_xml("SELECT name FROM S3Object LIMIT 0", "<FileHeaderInfo>USE</FileHeaderInfo>")
      )

    assert resp.status == 200
    refute records_event?(resp)
  end

  test "LIMIT 0 with CSV header names succeeds for empty objects" do
    assert create_bucket("selectlimitzerouseempty").status == 200
    assert put_object("selectlimitzerouseempty", "data.csv", "").status == 200

    resp =
      select_object(
        "selectlimitzerouseempty",
        "data.csv",
        select_xml("SELECT name FROM S3Object LIMIT 0", "<FileHeaderInfo>USE</FileHeaderInfo>")
      )

    assert resp.status == 200
    refute records_event?(resp)
  end

  test "ScanRange Start and End selects records whose first byte is in range" do
    assert create_bucket("selectscanbounded").status == 200
    assert put_object("selectscanbounded", "data.csv", "a,b\nc,d\ne,f\n").status == 200

    resp =
      select_object(
        "selectscanbounded",
        "data.csv",
        select_xml(
          "SELECT * FROM S3Object",
          "",
          "",
          "<ScanRange><Start>1</Start><End>4</End></ScanRange>"
        )
      )

    assert resp.status == 200
    assert records_payload(resp) == "c,d\n"
  end

  test "ScanRange Start-only scans through EOF and End-only scans the last N bytes" do
    assert create_bucket("selectscanopen").status == 200
    assert put_object("selectscanopen", "data.csv", "a,b\nc,d\ne,f\n").status == 200

    start_resp =
      select_object(
        "selectscanopen",
        "data.csv",
        select_xml("SELECT * FROM S3Object", "", "", "<ScanRange><Start>8</Start></ScanRange>")
      )

    assert start_resp.status == 200
    assert records_payload(start_resp) == "e,f\n"

    end_resp =
      select_object(
        "selectscanopen",
        "data.csv",
        select_xml("SELECT * FROM S3Object", "", "", "<ScanRange><End>4</End></ScanRange>")
      )

    assert end_resp.status == 200
    assert records_payload(end_resp) == "e,f\n"
  end

  test "ScanRange can stop before EOF without source length mismatch" do
    assert create_bucket("selectscanearly").status == 200

    body = "a,b\n" <> String.duplicate("c,d\n", 250_000)
    assert put_object("selectscanearly", "data.csv", body).status == 200

    resp =
      select_object(
        "selectscanearly",
        "data.csv",
        select_xml(
          "SELECT * FROM S3Object",
          "",
          "",
          "<ScanRange><Start>0</Start><End>0</End></ScanRange>"
        )
      )

    assert resp.status == 200
    assert records_payload(resp) == "a,b\n"
  end

  test "ScanRange does not parse unsupported CSV records outside the selected range" do
    assert create_bucket("selectscanskipsbad").status == 200
    assert put_object("selectscanskipsbad", "data.csv", ~s(a,b\n"bad",row\n)).status == 200

    resp =
      select_object(
        "selectscanskipsbad",
        "data.csv",
        select_xml(
          "SELECT * FROM S3Object",
          "",
          "",
          "<ScanRange><Start>0</Start><End>0</End></ScanRange>"
        )
      )

    assert resp.status == 200
    assert records_payload(resp) == "a,b\n"
  end

  test "ScanRange skips oversized CSV records before and after the selected range" do
    oversized = String.duplicate("x", 1_048_577)

    assert create_bucket("selectscanhugeafter").status == 200

    assert put_object("selectscanhugeafter", "data.csv", "a,b\n" <> oversized <> "\n").status ==
             200

    after_resp =
      select_object(
        "selectscanhugeafter",
        "data.csv",
        select_xml(
          "SELECT * FROM S3Object",
          "",
          "",
          "<ScanRange><Start>0</Start><End>0</End></ScanRange>"
        )
      )

    assert after_resp.status == 200
    assert records_payload(after_resp) == "a,b\n"

    assert create_bucket("selectscanhugebefore").status == 200
    assert put_object("selectscanhugebefore", "data.csv", oversized <> "\na,b\n").status == 200

    start_offset = byte_size(oversized) + 1

    before_resp =
      select_object(
        "selectscanhugebefore",
        "data.csv",
        select_xml(
          "SELECT * FROM S3Object",
          "",
          "",
          "<ScanRange><Start>#{start_offset}</Start></ScanRange>"
        )
      )

    assert before_resp.status == 200
    assert records_payload(before_resp) == "a,b\n"
  end

  test "ScanRange skips oversized CSV headers when header names are not needed" do
    oversized = String.duplicate("x", 1_048_577)
    start_offset = byte_size(oversized) + 1

    assert create_bucket("selectscanignorehead").status == 200
    assert put_object("selectscanignorehead", "data.csv", oversized <> "\na,b\n").status == 200

    ignore_resp =
      select_object(
        "selectscanignorehead",
        "data.csv",
        select_xml(
          "SELECT _1 FROM S3Object",
          "<FileHeaderInfo>IGNORE</FileHeaderInfo>",
          "",
          "<ScanRange><Start>#{start_offset}</Start></ScanRange>"
        )
      )

    assert ignore_resp.status == 200
    assert records_payload(ignore_resp) == "a\n"

    assert create_bucket("selectscanusepos").status == 200
    assert put_object("selectscanusepos", "data.csv", oversized <> "\na,b\n").status == 200

    use_resp =
      select_object(
        "selectscanusepos",
        "data.csv",
        select_xml(
          "SELECT _1 FROM S3Object",
          "<FileHeaderInfo>USE</FileHeaderInfo>",
          "",
          "<ScanRange><Start>#{start_offset}</Start></ScanRange>"
        )
      )

    assert use_resp.status == 200
    assert records_payload(use_resp) == "a\n"
  end

  test "ScanRange with CSV header-name references parses header before selected records" do
    assert create_bucket("selectscanheaderref").status == 200

    body = "name,group\nAda,keep\nBob,drop\n"
    assert put_object("selectscanheaderref", "data.csv", body).status == 200

    start_offset = byte_size("name,group\n")

    resp =
      select_object(
        "selectscanheaderref",
        "data.csv",
        select_xml(
          "SELECT name FROM S3Object WHERE group = 'keep'",
          "<FileHeaderInfo>USE</FileHeaderInfo>",
          "",
          "<ScanRange><Start>#{start_offset}</Start></ScanRange>"
        )
      )

    assert resp.status == 200
    assert records_payload(resp) == "Ada\n"
  end

  test "ScanRange with CSV header-name references validates missing and ambiguous headers" do
    assert create_bucket("selectscanheadermissing").status == 200
    assert put_object("selectscanheadermissing", "data.csv", "name\nAda\n").status == 200

    missing_resp =
      select_object(
        "selectscanheadermissing",
        "data.csv",
        select_xml(
          "SELECT missing FROM S3Object",
          "<FileHeaderInfo>USE</FileHeaderInfo>",
          "",
          "<ScanRange><Start>5</Start></ScanRange>"
        )
      )

    assert missing_resp.status == 400
    assert missing_resp.resp_body =~ "<Code>MissingHeaderName</Code>"

    assert create_bucket("selectscanheaderambig").status == 200

    assert put_object("selectscanheaderambig", "data.csv", "Name,name\nAda,Lovelace\n").status ==
             200

    ambiguous_resp =
      select_object(
        "selectscanheaderambig",
        "data.csv",
        select_xml(
          "SELECT name FROM S3Object",
          "<FileHeaderInfo>USE</FileHeaderInfo>",
          "",
          "<ScanRange><Start>10</Start></ScanRange>"
        )
      )

    assert ambiguous_resp.status == 400
    assert ambiguous_resp.resp_body =~ "<Code>AmbiguousFieldName</Code>"
  end

  test "ScanRange with CSV header-name references must parse oversized headers" do
    oversized = String.duplicate("x", 1_048_577)
    start_offset = byte_size(oversized) + 1

    assert create_bucket("selectscanheaderhuge").status == 200
    assert put_object("selectscanheaderhuge", "data.csv", oversized <> "\nAda\n").status == 200

    resp =
      select_object(
        "selectscanheaderhuge",
        "data.csv",
        select_xml(
          "SELECT name FROM S3Object",
          "<FileHeaderInfo>USE</FileHeaderInfo>",
          "",
          "<ScanRange><Start>#{start_offset}</Start></ScanRange>"
        )
      )

    assert resp.status == 400
    assert resp.resp_body =~ "<Code>OverMaxRecordSize</Code>"
  end

  test "ScanRange Start greater than End is rejected before event-stream response" do
    assert create_bucket("selectscaninvalid").status == 200
    assert put_object("selectscaninvalid", "data.csv", "a,b\n").status == 200

    resp =
      select_object(
        "selectscaninvalid",
        "data.csv",
        select_xml(
          "SELECT * FROM S3Object",
          "",
          "",
          "<ScanRange><Start>4</Start><End>1</End></ScanRange>"
        )
      )

    assert resp.status == 400
    assert get_resp_header(resp, "content-type") |> List.first() =~ "application/xml"
    assert resp.resp_body =~ "<Code>InvalidArgument</Code>"
    assert resp.resp_body =~ "ScanRange Start must be less than or equal to End"
  end

  test "GZIP CSV input is decompressed before selection" do
    assert create_bucket("selectgzipcsv").status == 200

    assert put_object("selectgzipcsv", "data.csv.gz", :zlib.gzip("a,keep\nb,drop\n")).status ==
             200

    resp =
      select_object(
        "selectgzipcsv",
        "data.csv.gz",
        select_gzip_xml("SELECT _1 FROM S3Object WHERE _2 = 'keep'")
      )

    assert resp.status == 200
    assert records_payload(resp) == "a\n"
  end

  test "GZIP CSV input supports concatenated gzip members" do
    assert create_bucket("selectgzipmembers").status == 200

    body = :zlib.gzip("a,keep\n") <> :zlib.gzip("b,keep\n")
    assert put_object("selectgzipmembers", "data.csv.gz", body).status == 200

    resp =
      select_object(
        "selectgzipmembers",
        "data.csv.gz",
        select_gzip_xml("SELECT _1 FROM S3Object WHERE _2 = 'keep'")
      )

    assert resp.status == 200
    assert records_payload(resp) == "a\nb\n"
  end

  test "GZIP CSV LIMIT validates compressed EOF without source length mismatch" do
    assert create_bucket("selectgziplimit").status == 200

    body = "a,keep\n" <> String.duplicate("b,drop\n", 250_000)
    assert put_object("selectgziplimit", "data.csv.gz", :zlib.gzip(body)).status == 200

    resp =
      select_object(
        "selectgziplimit",
        "data.csv.gz",
        select_gzip_xml("SELECT _1 FROM S3Object WHERE _2 = 'keep' LIMIT 1")
      )

    assert resp.status == 200
    assert records_payload(resp) == "a\n"
  end

  test "GZIP input with ScanRange is rejected before event-stream response" do
    assert create_bucket("selectgzipscan").status == 200
    assert put_object("selectgzipscan", "data.csv.gz", :zlib.gzip("a,b\nc,d\n")).status == 200

    resp =
      select_object(
        "selectgzipscan",
        "data.csv.gz",
        select_gzip_xml(
          "SELECT * FROM S3Object",
          "",
          "",
          "<ScanRange><Start>0</Start><End>0</End></ScanRange>"
        )
      )

    assert resp.status == 400
    assert get_resp_header(resp, "content-type") |> List.first() =~ "application/xml"
    assert resp.resp_body =~ "<Code>InvalidRequest</Code>"
    assert resp.resp_body =~ "ScanRange is not supported for compressed SelectObjectContent input"
  end

  test "BZIP2 input remains fail-closed before event-stream response" do
    assert create_bucket("selectbzip2").status == 200
    assert put_object("selectbzip2", "data.csv.bz2", "not-really-bzip2").status == 200

    resp =
      select_object(
        "selectbzip2",
        "data.csv.bz2",
        select_compressed_xml("SELECT * FROM S3Object", "BZIP2")
      )

    assert get_resp_header(resp, "content-type") |> List.first() =~ "application/xml"
    assert resp.resp_body =~ "<Code>NotImplemented</Code>"
    assert resp.resp_body =~ "BZIP2 SelectObjectContent input is not implemented"
  end

  test "invalid GZIP input returns structured XML before event-stream response" do
    assert create_bucket("selectgzipbad").status == 200
    assert put_object("selectgzipbad", "data.csv.gz", "not-gzip").status == 200

    resp =
      select_object(
        "selectgzipbad",
        "data.csv.gz",
        select_gzip_xml("SELECT * FROM S3Object")
      )

    assert resp.status == 400
    assert get_resp_header(resp, "content-type") |> List.first() =~ "application/xml"
    assert resp.resp_body =~ "<Code>InvalidRequest</Code>"
    assert resp.resp_body =~ "Invalid GZIP SelectObjectContent input"
  end

  test "truncated GZIP input fails before event-stream response when fully consumed" do
    assert create_bucket("selectgziptruncated").status == 200

    gzip = :zlib.gzip("a,b\n")
    truncated = binary_part(gzip, 0, byte_size(gzip) - 2)
    assert put_object("selectgziptruncated", "data.csv.gz", truncated).status == 200

    resp =
      select_object(
        "selectgziptruncated",
        "data.csv.gz",
        select_gzip_xml("SELECT * FROM S3Object")
      )

    assert resp.status == 400
    assert resp.resp_body =~ "<Code>InvalidRequest</Code>"
    assert resp.resp_body =~ "Invalid GZIP SelectObjectContent input"
  end

  test "truncated GZIP input with LIMIT fails before event-stream response" do
    assert create_bucket("selectgziptruncatedlimit").status == 200

    gzip = :zlib.gzip("a,keep\n" <> String.duplicate("b,drop\n", 20_000))
    truncated = binary_part(gzip, 0, byte_size(gzip) - 2)
    assert put_object("selectgziptruncatedlimit", "data.csv.gz", truncated).status == 200

    resp =
      select_object(
        "selectgziptruncatedlimit",
        "data.csv.gz",
        select_gzip_xml("SELECT _1 FROM S3Object WHERE _2 = 'keep' LIMIT 1")
      )

    assert resp.status == 400
    assert get_resp_header(resp, "content-type") |> List.first() =~ "application/xml"
    assert resp.resp_body =~ "<Code>InvalidRequest</Code>"
    assert resp.resp_body =~ "Invalid GZIP SelectObjectContent input"
  end

  test "GZIP source length mismatch fails before event-stream response" do
    assert create_bucket("selectgzipshortsrc").status == 200

    original = :zlib.gzip("a,b\nc,d\n")
    replacement = :zlib.gzip("a,b\n")
    assert put_object("selectgzipshortsrc", "data.csv.gz", original).status == 200
    overwrite_backend_part!("selectgzipshortsrc", "data.csv.gz", replacement)

    resp =
      select_object(
        "selectgzipshortsrc",
        "data.csv.gz",
        select_gzip_xml("SELECT * FROM S3Object")
      )

    assert resp.status == 500
    assert get_resp_header(resp, "content-type") |> List.first() =~ "application/xml"
    assert resp.resp_body =~ "<Code>InternalError</Code>"
  end

  test "non-LIMIT source length mismatch fails before event-stream response" do
    assert create_bucket("selectshortsrc").status == 200
    assert put_object("selectshortsrc", "data.csv", "a,b\nc,d\n").status == 200

    overwrite_backend_part!("selectshortsrc", "data.csv", "a,b\n")

    resp = select_object("selectshortsrc", "data.csv", @select_xml)

    assert resp.status == 500
    assert get_resp_header(resp, "content-type") |> List.first() =~ "application/xml"
    assert resp.resp_body =~ "<Code>InternalError</Code>"
  end

  test "LIMIT on truncated final unterminated record still fails source length check" do
    assert create_bucket("selectlimitshortsrc").status == 200
    assert put_object("selectlimitshortsrc", "data.csv", "a,b\nc,d\n").status == 200

    overwrite_backend_part!("selectlimitshortsrc", "data.csv", "a,b")

    resp =
      select_object(
        "selectlimitshortsrc",
        "data.csv",
        select_xml("SELECT * FROM S3Object LIMIT 1")
      )

    assert resp.status == 500
    assert get_resp_header(resp, "content-type") |> List.first() =~ "application/xml"
    assert resp.resp_body =~ "<Code>InternalError</Code>"
  end

  test "LIMIT on truncated final delimited record still fails source length check" do
    assert create_bucket("selectlimitshortdelim").status == 200
    assert put_object("selectlimitshortdelim", "data.csv", "a,b\nc,d\n").status == 200

    overwrite_backend_part!("selectlimitshortdelim", "data.csv", "a,b\n")

    resp =
      select_object(
        "selectlimitshortdelim",
        "data.csv",
        select_xml("SELECT * FROM S3Object LIMIT 1")
      )

    assert resp.status == 500
    assert get_resp_header(resp, "content-type") |> List.first() =~ "application/xml"
    assert resp.resp_body =~ "<Code>InternalError</Code>"
  end

  test "selected output staging has a bounded total size before event-stream response" do
    Application.put_env(
      :maxio,
      :s3,
      Keyword.put(Application.get_env(:maxio, :s3), :select_result_max_bytes, 3)
    )

    assert create_bucket("selectresultcap").status == 200
    assert put_object("selectresultcap", "data.csv", "a,b\n").status == 200

    resp = select_object("selectresultcap", "data.csv", @select_xml)

    assert resp.status == 400
    assert get_resp_header(resp, "content-type") |> List.first() =~ "application/xml"
    assert resp.resp_body =~ "<Code>InvalidRequest</Code>"
    assert resp.resp_body =~ "SelectObjectContent result exceeds configured staging limit"
  end

  test "FileHeaderInfo USE exposes header names and skips the header row" do
    assert create_bucket("selectheaders").status == 200
    assert put_object("selectheaders", "people.csv", "name,age\nAda,36\nBob,40\n").status == 200

    resp =
      select_object(
        "selectheaders",
        "people.csv",
        select_xml(
          "SELECT s.name FROM S3Object AS s WHERE age &gt; 35",
          "<FileHeaderInfo>USE</FileHeaderInfo>"
        )
      )

    assert resp.status == 200
    assert records_payload(resp) == "Ada\nBob\n"
  end

  test "FileHeaderInfo IGNORE skips the first non-comment row without exposing names" do
    assert create_bucket("selectignore").status == 200
    assert put_object("selectignore", "data.csv", "#comment\nname,age\nAda,36\n").status == 200

    resp =
      select_object(
        "selectignore",
        "data.csv",
        select_xml("SELECT _1 FROM S3Object", "<FileHeaderInfo>IGNORE</FileHeaderInfo>")
      )

    assert resp.status == 200
    assert records_payload(resp) == "Ada\n"
  end

  test "custom CSV delimiters and quote fields are honored for the supported unquoted subset" do
    assert create_bucket("selectdelim").status == 200
    assert put_object("selectdelim", "data.csv", "a|b~c|d~").status == 200

    resp =
      select_object(
        "selectdelim",
        "data.csv",
        select_xml(
          "SELECT _2, _1 FROM S3Object",
          "<FieldDelimiter>|</FieldDelimiter><RecordDelimiter>~</RecordDelimiter>",
          "<FieldDelimiter>;</FieldDelimiter><QuoteFields>ALWAYS</QuoteFields>"
        )
      )

    assert resp.status == 200
    assert records_payload(resp) == ~s("b";"a"\n"d";"c"\n)
  end

  test "CSV input can serialize positional and typed projections as JSON Lines" do
    assert create_bucket("selectcsvtojson").status == 200
    assert put_object("selectcsvtojson", "data.csv", "Ada,36\nBob,40\n").status == 200

    resp =
      select_object(
        "selectcsvtojson",
        "data.csv",
        select_csv_to_json_xml(
          "SELECT _1 AS name, CAST(_2 AS INT) AS age FROM S3Object WHERE _1 = 'Ada'"
        )
      )

    assert resp.status == 200
    assert json_record_payloads(resp) == [%{"name" => "Ada", "age" => 36}]
  end

  test "CSV input JSON output uses positional names for SELECT star" do
    assert create_bucket("selectcsvalljson").status == 200
    assert put_object("selectcsvalljson", "data.csv", "a,b\nc,d\n").status == 200

    resp =
      select_object(
        "selectcsvalljson",
        "data.csv",
        select_csv_to_json_xml("SELECT * FROM S3Object")
      )

    assert resp.status == 200

    assert json_record_payloads(resp) == [
             %{"_1" => "a", "_2" => "b"},
             %{"_1" => "c", "_2" => "d"}
           ]
  end

  test "CSV header projections keep output names when serialized as JSON Lines" do
    assert create_bucket("selectcsvheaderjson").status == 200

    assert put_object("selectcsvheaderjson", "people.csv", "name,age\nAda,36\nBob,40\n").status ==
             200

    resp =
      select_object(
        "selectcsvheaderjson",
        "people.csv",
        select_csv_to_json_xml(
          "SELECT name, CAST(age AS INT) AS years FROM S3Object WHERE age &gt; 35",
          "<FileHeaderInfo>USE</FileHeaderInfo>",
          "<RecordDelimiter>|</RecordDelimiter>"
        )
      )

    assert resp.status == 200

    assert json_record_payloads(resp, "|") == [
             %{"name" => "Ada", "years" => 36},
             %{"name" => "Bob", "years" => 40}
           ]
  end

  test "CSV input JSON output rejects duplicate projection aliases before event-stream response" do
    assert create_bucket("selectcsvjsondupe").status == 200
    assert put_object("selectcsvjsondupe", "data.csv", "a,b\n").status == 200

    resp =
      select_object(
        "selectcsvjsondupe",
        "data.csv",
        select_csv_to_json_xml("SELECT _1 AS x, _2 AS x FROM S3Object")
      )

    assert resp.status == 400
    assert get_resp_header(resp, "content-type") |> List.first() =~ "application/xml"
    assert resp.resp_body =~ "<Code>InvalidKeyPath</Code>"
  end

  test "CSV input JSON output rejects duplicate natural output names before event-stream response" do
    assert create_bucket("selectcsvjsonnaturaldupe").status == 200
    assert put_object("selectcsvjsonnaturaldupe", "data.csv", "a,b\n").status == 200

    resp =
      select_object(
        "selectcsvjsonnaturaldupe",
        "data.csv",
        select_csv_to_json_xml("SELECT _1, _1 FROM S3Object")
      )

    assert resp.status == 400
    assert get_resp_header(resp, "content-type") |> List.first() =~ "application/xml"
    assert resp.resp_body =~ "<Code>InvalidKeyPath</Code>"
  end

  test "CSV input JSON output rejects duplicate aggregate aliases before event-stream response" do
    assert create_bucket("selectcsvjsonaggdupe").status == 200
    assert put_object("selectcsvjsonaggdupe", "data.csv", "a,10\nb,20\n").status == 200

    resp =
      select_object(
        "selectcsvjsonaggdupe",
        "data.csv",
        select_csv_to_json_xml("SELECT count(*) AS x, sum(CAST(_2 AS INT)) AS x FROM S3Object")
      )

    assert resp.status == 400
    assert get_resp_header(resp, "content-type") |> List.first() =~ "application/xml"
    assert resp.resp_body =~ "<Code>InvalidKeyPath</Code>"
  end

  test "quoted CSV fields support delimiters and escaped quotes" do
    assert create_bucket("selectquoted").status == 200

    assert put_object(
             "selectquoted",
             "data.csv",
             ~s("Ada, A","says ""hi"""\nBob,plain\n)
           ).status == 200

    resp =
      select_object(
        "selectquoted",
        "data.csv",
        select_xml(~s(SELECT _1, _2 FROM S3Object WHERE _1 = 'Ada, A'))
      )

    assert resp.status == 200
    assert records_payload(resp) == ~s("Ada, A","says ""hi"""\n)
  end

  test "quoted CSV header names participate in FileHeaderInfo USE" do
    assert create_bucket("selectquotedheaders").status == 200

    assert put_object(
             "selectquotedheaders",
             "people.csv",
             ~s("Display Name",age\n"Ada, A",36\nBob,40\n)
           ).status == 200

    resp =
      select_object(
        "selectquotedheaders",
        "people.csv",
        select_xml(
          ~s(SELECT "Display Name" FROM S3Object WHERE age &gt; 35),
          "<FileHeaderInfo>USE</FileHeaderInfo>"
        )
      )

    assert resp.status == 200
    assert records_payload(resp) == ~s("Ada, A"\nBob\n)
  end

  test "CSV CRLF records are accepted with the default newline record delimiter" do
    assert create_bucket("selectcrlf").status == 200
    assert put_object("selectcrlf", "data.csv", "a,b\r\nc,d\r\n").status == 200

    resp = select_object("selectcrlf", "data.csv", select_xml("SELECT _2 FROM S3Object"))

    assert resp.status == 200
    assert records_payload(resp) == "b\nd\n"
  end

  test "custom CSV QuoteEscapeCharacter is honored" do
    assert create_bucket("selectquoteescape").status == 200
    assert put_object("selectquoteescape", "data.csv", ~s("says \\"hi\\"",ok\n)).status == 200

    resp =
      select_object(
        "selectquoteescape",
        "data.csv",
        select_xml(
          "SELECT _1 FROM S3Object WHERE _2 = 'ok'",
          "<QuoteEscapeCharacter>\\</QuoteEscapeCharacter>"
        )
      )

    assert resp.status == 200
    assert records_payload(resp) == ~s("says ""hi"""\n)
  end

  test "JSON Lines input returns JSON Records for select star" do
    assert create_bucket("selectjsonall").status == 200

    assert put_object(
             "selectjsonall",
             "data.jsonl",
             ~s({"name":"Ada","age":36}\n{"name":"Bob","age":40}\n)
           ).status == 200

    resp = select_object("selectjsonall", "data.jsonl", select_json_xml("SELECT * FROM S3Object"))

    assert resp.status == 200

    assert json_record_payloads(resp) == [
             %{"name" => "Ada", "age" => 36},
             %{"name" => "Bob", "age" => 40}
           ]
  end

  test "JSON Lines supports projection, WHERE, LIMIT, aliases, and custom record delimiter" do
    assert create_bucket("selectjsonfilter").status == 200

    assert put_object(
             "selectjsonfilter",
             "data.jsonl",
             ~s({"name":"Ada","age":36}\n{"name":"Bob","age":40}\n{"name":"Eve","age":41}\n)
           ).status == 200

    resp =
      select_object(
        "selectjsonfilter",
        "data.jsonl",
        select_json_xml(
          "SELECT s.name, s.age FROM S3Object[*] AS s WHERE s.age &gt; 36 LIMIT 1",
          "<Type>LINES</Type>",
          "<RecordDelimiter>|</RecordDelimiter>"
        )
      )

    assert resp.status == 200
    assert json_record_payloads(resp, "|") == [%{"name" => "Bob", "age" => 40}]
  end

  test "JSON Lines input can serialize scalar projections as CSV" do
    assert create_bucket("selectjsontocsv").status == 200

    assert put_object(
             "selectjsontocsv",
             "data.jsonl",
             ~s({"name":"Ada","age":36,"note":"hello, csv"}\n{"name":"Bob","age":40,"note":"plain"}\n)
           ).status == 200

    resp =
      select_object(
        "selectjsontocsv",
        "data.jsonl",
        select_json_to_csv_xml(
          "SELECT name, note, CAST(age AS INT) FROM S3Object WHERE age &gt;= 36"
        )
      )

    assert resp.status == 200
    assert records_payload(resp) == ~s(Ada,"hello, csv",36\nBob,plain,40\n)
  end

  test "JSON Lines CSV output permits duplicate projection aliases as positional columns" do
    assert create_bucket("selectjsoncsvaliasdupe").status == 200
    assert put_object("selectjsoncsvaliasdupe", "data.jsonl", ~s({"a":1,"b":2}\n)).status == 200

    resp =
      select_object(
        "selectjsoncsvaliasdupe",
        "data.jsonl",
        select_json_to_csv_xml("SELECT a AS x, b AS x FROM S3Object")
      )

    assert resp.status == 200
    assert records_payload(resp) == "1,2\n"
  end

  test "JSON Lines CSV output permits duplicate natural projection names as positional columns" do
    assert create_bucket("selectjsoncsvnaturaldupe").status == 200
    assert put_object("selectjsoncsvnaturaldupe", "data.jsonl", ~s({"a":1}\n)).status == 200

    resp =
      select_object(
        "selectjsoncsvnaturaldupe",
        "data.jsonl",
        select_json_to_csv_xml("SELECT a, a FROM S3Object")
      )

    assert resp.status == 200
    assert records_payload(resp) == "1,1\n"
  end

  test "JSON Lines aggregate projections can serialize as CSV with custom delimiters" do
    assert create_bucket("selectjsonaggcsv").status == 200

    assert put_object(
             "selectjsonaggcsv",
             "data.jsonl",
             ~s({"age":36}\n{"age":40}\n{"age":null}\n)
           ).status == 200

    resp =
      select_object(
        "selectjsonaggcsv",
        "data.jsonl",
        select_json_to_csv_xml(
          "SELECT count(*), count(age), sum(age), avg(age) FROM S3Object",
          "<Type>LINES</Type>",
          "<FieldDelimiter>|</FieldDelimiter>"
        )
      )

    assert resp.status == 200
    assert records_payload(resp) == "3|2|76|38\n"
  end

  test "JSON Lines aggregate projections skip MISSING rows from FROM paths" do
    assert create_bucket("selectjsonaggmissing").status == 200

    assert put_object(
             "selectjsonaggmissing",
             "data.jsonl",
             ~s({"items":[{"n":1},{"n":2}]}\n{"other":true}\n)
           ).status == 200

    resp =
      select_object(
        "selectjsonaggmissing",
        "data.jsonl",
        select_json_to_csv_xml(
          "SELECT count(*), count(n), sum(n) FROM S3Object[*].items[*]",
          "<Type>LINES</Type>",
          "<FieldDelimiter>|</FieldDelimiter>"
        )
      )

    assert resp.status == 200
    assert records_payload(resp) == "2|2|3\n"
  end

  test "JSON Lines SELECT star can serialize scalar rows as CSV" do
    assert create_bucket("selectjsonstarscalarcsv").status == 200

    assert put_object(
             "selectjsonstarscalarcsv",
             "data.jsonl",
             ~s(1\n"two,too"\ntrue\nnull\n)
           ).status == 200

    resp =
      select_object(
        "selectjsonstarscalarcsv",
        "data.jsonl",
        select_json_to_csv_xml("SELECT * FROM S3Object")
      )

    assert resp.status == 200
    assert records_payload(resp) == ~s(1\n"two,too"\ntrue\n\n)
  end

  test "JSON Lines SELECT star to CSV still rejects nested rows before event-stream response" do
    assert create_bucket("selectjsonstarcsvnested").status == 200

    assert put_object(
             "selectjsonstarcsvnested",
             "data.jsonl",
             ~s({"name":"Ada"}\n["nested"]\n)
           ).status == 200

    object_resp =
      select_object(
        "selectjsonstarcsvnested",
        "data.jsonl",
        select_json_to_csv_xml("SELECT * FROM S3Object")
      )

    assert object_resp.status == 501
    assert get_resp_header(object_resp, "content-type") |> List.first() =~ "application/xml"
    assert object_resp.resp_body =~ "<Code>NotImplemented</Code>"
    assert object_resp.resp_body =~ "Nested SelectObjectContent values require JSON output"

    assert create_bucket("selectjsonstarcsvarray").status == 200
    assert put_object("selectjsonstarcsvarray", "data.jsonl", ~s(["nested"]\n)).status == 200

    array_resp =
      select_object(
        "selectjsonstarcsvarray",
        "data.jsonl",
        select_json_to_csv_xml("SELECT * FROM S3Object")
      )

    assert array_resp.status == 501
    assert array_resp.resp_body =~ "<Code>NotImplemented</Code>"
    assert array_resp.resp_body =~ "Nested SelectObjectContent values require JSON output"
  end

  test "JSON Lines SELECT star to CSV rejects nested rows after scalar rows before event-stream response" do
    assert create_bucket("selectjsonstarcsvlate").status == 200

    assert put_object(
             "selectjsonstarcsvlate",
             "data.jsonl",
             ~s(1\n{"nested":true}\n)
           ).status == 200

    resp =
      select_object(
        "selectjsonstarcsvlate",
        "data.jsonl",
        select_json_to_csv_xml("SELECT * FROM S3Object")
      )

    assert resp.status == 501
    assert get_resp_header(resp, "content-type") |> List.first() =~ "application/xml"
    assert resp.resp_body =~ "<Code>NotImplemented</Code>"
    assert resp.resp_body =~ "Nested SelectObjectContent values require JSON output"
  end

  test "JSON Lines CSV output rejects explicit nested projections before event-stream response" do
    assert create_bucket("selectjsoncsvnestedprojection").status == 200

    assert put_object(
             "selectjsoncsvnestedprojection",
             "data.jsonl",
             ~s({"payload":{"nested":true}}\n)
           ).status == 200

    resp =
      select_object(
        "selectjsoncsvnestedprojection",
        "data.jsonl",
        select_json_to_csv_xml("SELECT payload FROM S3Object")
      )

    assert resp.status == 501
    assert get_resp_header(resp, "content-type") |> List.first() =~ "application/xml"
    assert resp.resp_body =~ "<Code>NotImplemented</Code>"
    assert resp.resp_body =~ "Nested SelectObjectContent values require JSON output"
  end

  test "default JSON DOCUMENT SELECT star can serialize scalar root as CSV" do
    assert create_bucket("selectjsondocstarcsv").status == 200
    assert put_object("selectjsondocstarcsv", "data.json", ~s("document,scalar")).status == 200

    resp =
      select_object(
        "selectjsondocstarcsv",
        "data.json",
        select_json_to_csv_xml("SELECT * FROM S3Object", "")
      )

    assert resp.status == 200
    assert records_payload(resp) == ~s("document,scalar"\n)
  end

  test "default JSON DOCUMENT SELECT star to CSV rejects nested root before event-stream response" do
    assert create_bucket("selectjsondocstarcsvnested").status == 200

    assert put_object("selectjsondocstarcsvnested", "data.json", ~s({"nested":true})).status ==
             200

    resp =
      select_object(
        "selectjsondocstarcsvnested",
        "data.json",
        select_json_to_csv_xml("SELECT * FROM S3Object", "")
      )

    assert resp.status == 501
    assert get_resp_header(resp, "content-type") |> List.first() =~ "application/xml"
    assert resp.resp_body =~ "<Code>NotImplemented</Code>"
    assert resp.resp_body =~ "Nested SelectObjectContent values require JSON output"
  end

  test "JSON Lines supports CAST projections, CAST WHERE predicates, and output aliases" do
    assert create_bucket("selectjsoncastalias").status == 200

    assert put_object(
             "selectjsoncastalias",
             "data.jsonl",
             ~s({"name":"Ada","age":"36","score":"8.5"}\n{"name":"Bob","age":"40","score":"9.5"}\n)
           ).status == 200

    resp =
      select_object(
        "selectjsoncastalias",
        "data.jsonl",
        select_json_xml(
          "SELECT cast(score AS FLOAT) AS score_num, name AS display FROM S3Object WHERE cast(age AS INT) &gt;= 40"
        )
      )

    assert resp.status == 200
    assert json_record_payloads(resp) == [%{"score_num" => 9.5, "display" => "Bob"}]
  end

  test "JSON Lines supports string function projections, WHERE predicates, and aliases" do
    assert create_bucket("selectjsonstringfunctions").status == 200

    assert put_object(
             "selectjsonstringfunctions",
             "data.jsonl",
             ~s({"name":" Ada ","status":" Keep ","code":"xxHelloYY"}\n{"name":"Bob","status":"drop","code":"skip"}\n)
           ).status == 200

    resp =
      select_object(
        "selectjsonstringfunctions",
        "data.jsonl",
        select_json_xml(
          "SELECT lower(trim(name)) AS display, upper(name) AS shout, character_length(trim(status)) AS status_len, substring(code FROM 3 FOR 5) AS part, trim(both 'xy' FROM code) AS trimmed FROM S3Object WHERE lower(trim(status)) = 'keep'"
        )
      )

    assert resp.status == 200

    assert json_record_payloads(resp) == [
             %{
               "display" => "ada",
               "shout" => " ADA ",
               "status_len" => 4,
               "part" => "Hello",
               "trimmed" => "HelloYY"
             }
           ]
  end

  test "JSON Lines string functions preserve null and missing semantics" do
    assert create_bucket("selectjsonstringnull").status == 200

    assert put_object(
             "selectjsonstringnull",
             "data.jsonl",
             ~s({"name":"Empty","status":null}\n{"name":"Missing"}\n{"name":"Keep","status":"KEEP"}\n)
           ).status == 200

    resp =
      select_object(
        "selectjsonstringnull",
        "data.jsonl",
        select_json_xml(
          "SELECT lower(status) AS status FROM S3Object WHERE lower(status) = 'keep'"
        )
      )

    assert resp.status == 200
    assert json_record_payloads(resp) == [%{"status" => "keep"}]
  end

  test "JSON Lines SUBSTRING handles zero and negative starts" do
    assert create_bucket("selectjsonsubstringbounds").status == 200

    assert put_object("selectjsonsubstringbounds", "data.jsonl", ~s({"code":"abcdef"}\n)).status ==
             200

    resp =
      select_object(
        "selectjsonsubstringbounds",
        "data.jsonl",
        select_json_xml(
          "SELECT substring(code, 0, 3) AS zero_len, substring(code, -1, 3) AS neg_len, substring(code FROM 0) AS zero_all, substring(code FROM -1 FOR 3) AS neg_for FROM S3Object"
        )
      )

    assert resp.status == 200

    assert json_record_payloads(resp) == [
             %{
               "zero_len" => "ab",
               "neg_len" => "a",
               "zero_all" => "abcdef",
               "neg_for" => "a"
             }
           ]
  end

  test "JSON Lines supports conditional expressions in projections and WHERE predicates" do
    assert create_bucket("selectjsonconditionals").status == 200

    assert put_object(
             "selectjsonconditionals",
             "data.jsonl",
             ~s({"name":"Ada","status":null,"tier":"gold","score":10}\n{"name":"Bob","tier":"silver","score":10}\n{"name":"Cid","status":"skip","tier":"bronze","score":11}\n)
           ).status == 200

    resp =
      select_object(
        "selectjsonconditionals",
        "data.jsonl",
        select_json_xml(
          "SELECT coalesce(status, 'fallback') AS status_value, nullif(score, 10) AS score_value, CASE WHEN coalesce(status, 'keep') = 'keep' THEN upper(name) WHEN tier = 'silver' THEN 'S' ELSE 'other' END AS bucket, CASE tier WHEN 'gold' THEN 'G' WHEN 'silver' THEN 'S' ELSE null END AS tier_code FROM S3Object WHERE coalesce(status, 'keep') = 'keep' OR nullif(score, 10) IS NULL"
        )
      )

    assert resp.status == 200

    assert json_record_payloads(resp) == [
             %{
               "status_value" => "fallback",
               "score_value" => nil,
               "bucket" => "ADA",
               "tier_code" => "G"
             },
             %{
               "status_value" => "fallback",
               "score_value" => nil,
               "bucket" => "BOB",
               "tier_code" => "S"
             }
           ]
  end

  test "JSON Lines CASE without ELSE returns null output" do
    assert create_bucket("selectjsoncasenullelse").status == 200

    assert put_object(
             "selectjsoncasenullelse",
             "data.jsonl",
             ~s({"name":"Ada"}\n{"name":"Bob"}\n)
           ).status == 200

    resp =
      select_object(
        "selectjsoncasenullelse",
        "data.jsonl",
        select_json_xml("SELECT CASE WHEN name = 'Ada' THEN 'hit' END AS marker FROM S3Object")
      )

    assert resp.status == 200
    assert json_record_payloads(resp) == [%{"marker" => "hit"}, %{"marker" => nil}]
  end

  test "JSON Lines supports arithmetic projections and RHS comparison expressions" do
    assert create_bucket("selectjsonarithmetic").status == 200

    assert put_object(
             "selectjsonarithmetic",
             "data.jsonl",
             ~s({"name":"Ada","a":6,"b":3,"c":14}\n{"name":"Bob","a":5,"b":1,"c":0}\n)
           ).status == 200

    resp =
      select_object(
        "selectjsonarithmetic",
        "data.jsonl",
        select_json_xml(
          "SELECT a + b * 2 AS total, (a + b) * 2 AS grouped, -a AS neg, a / b AS div, a % b AS rem FROM S3Object WHERE a + b = c - 5"
        )
      )

    assert resp.status == 200

    assert json_record_payloads(resp) == [
             %{"total" => 12, "grouped" => 18, "neg" => -6, "div" => 2, "rem" => 0}
           ]
  end

  test "JSON Lines arithmetic preserves null and missing semantics" do
    assert create_bucket("selectjsonarithmeticnull").status == 200

    assert put_object(
             "selectjsonarithmeticnull",
             "data.jsonl",
             ~s({"name":"Null","a":null,"b":1}\n{"name":"Missing","b":1}\n{"name":"Hit","a":2,"b":3}\n)
           ).status == 200

    resp =
      select_object(
        "selectjsonarithmeticnull",
        "data.jsonl",
        select_json_xml("SELECT a + b AS total FROM S3Object")
      )

    assert resp.status == 200
    assert json_record_payloads(resp) == [%{"total" => nil}, %{}, %{"total" => 5}]
  end

  test "JSON Lines rejects arithmetic division by zero before event-stream response" do
    assert create_bucket("selectjsonarithmeticzero").status == 200
    assert put_object("selectjsonarithmeticzero", "data.jsonl", ~s({"a":1,"b":0}\n)).status == 200

    resp =
      select_object(
        "selectjsonarithmeticzero",
        "data.jsonl",
        select_json_xml("SELECT a / b AS div FROM S3Object")
      )

    assert resp.status == 400
    assert get_resp_header(resp, "content-type") |> List.first() =~ "application/xml"
    assert resp.resp_body =~ "<Code>InvalidKeyPath</Code>"
  end

  test "JSON Lines supports predicate value expressions and CAST expression operands" do
    assert create_bucket("selectjsondynamicpredicates").status == 200

    assert put_object(
             "selectjsondynamicpredicates",
             "data.jsonl",
             ~s({"name":"A_da","a":6,"b":3,"lo":7,"hi":9,"pattern":"A!_%","escape":"!","flag":"true"}\n{"name":"Bob","a":4,"b":3,"lo":1,"hi":6,"pattern":"B!_%","escape":"!","flag":"false"}\n{"name":"Null","a":null,"b":3,"lo":1,"hi":9,"pattern":"A!_%","escape":"!","flag":"true"}\n)
           ).status == 200

    resp =
      select_object(
        "selectjsondynamicpredicates",
        "data.jsonl",
        select_json_xml(
          "SELECT cast(a + b AS STRING) AS score_text, cast(flag AS BOOL) AS enabled, TRUE AS t, FALSE AS f FROM S3Object WHERE a + b IN (lo + 2, 99) AND a + b BETWEEN lo + 1 AND hi AND name LIKE pattern ESCAPE escape AND cast(flag AS BOOL) = TRUE"
        )
      )

    assert resp.status == 200

    assert json_record_payloads(resp) == [
             %{"score_text" => "9", "enabled" => true, "t" => true, "f" => false}
           ]
  end

  test "JSON Lines supports date functions in projections and WHERE predicates" do
    assert create_bucket("selectjsondatefunctions").status == 200

    assert put_object(
             "selectjsondatefunctions",
             "data.jsonl",
             ~s({"name":"Ada","ts":"2026-07-03T10:30:00+02:00"}\n{"name":"Bob","ts":"2026-07-01T23:00:00Z"}\n{"name":"Null","ts":null}\n{"name":"Missing"}\n)
           ).status == 200

    resp =
      select_object(
        "selectjsondatefunctions",
        "data.jsonl",
        select_json_xml(
          "SELECT extract(year FROM to_timestamp(ts)) AS year, extract(timezone_hour FROM to_timestamp(ts)) AS tz_hour, date_add(day, 1, to_timestamp(ts)) AS plus_one, date_diff(hour, `2026-07-03T07:30:00Z`, to_timestamp(ts)) AS hour_delta FROM S3Object WHERE to_timestamp(ts) &gt; `2026-07-03T08:00:00Z` AND to_timestamp(ts) &lt; date_add(hour, 2, `2026-07-03T08:00:00Z`)"
        )
      )

    assert resp.status == 200

    assert json_record_payloads(resp) == [
             %{
               "year" => 2026,
               "tz_hour" => 2,
               "plus_one" => "2026-07-04T10:30:00+02:00",
               "hour_delta" => 1
             }
           ]
  end

  test "JSON Lines preserves nanosecond timestamp precision and timezone minute extraction" do
    assert create_bucket("selectjsontimestampnanos").status == 200

    assert put_object(
             "selectjsontimestampnanos",
             "data.jsonl",
             ~s({"ts":"2026-07-03T10:30:00.123456900Z"}\n{"ts":"2026-07-03T10:30:00.123456100Z"}\n{"ts":"2026-07-03T10:30:00.100000000Z"}\n)
           ).status == 200

    resp =
      select_object(
        "selectjsontimestampnanos",
        "data.jsonl",
        select_json_xml(
          "SELECT to_timestamp(ts) AS ts, extract(timezone_minute FROM `2026-07-03T10:30:00-03:30`) AS tz_minute FROM S3Object WHERE to_timestamp(ts) &gt; `2026-07-03T10:30:00.123456500Z`"
        )
      )

    assert resp.status == 200

    assert json_record_payloads(resp) == [
             %{
               "ts" => "2026-07-03T10:30:00.123456900Z",
               "tz_minute" => -30
             }
           ]

    equal_resp =
      select_object(
        "selectjsontimestampnanos",
        "data.jsonl",
        select_json_xml(
          "SELECT to_timestamp(ts) AS ts FROM S3Object WHERE to_timestamp(ts) = `2026-07-03T10:30:00.1Z`"
        )
      )

    assert equal_resp.status == 200

    assert json_record_payloads(equal_resp) == [
             %{"ts" => "2026-07-03T10:30:00.100000000Z"}
           ]
  end

  test "JSON Lines supports TO_STRING date formatting and UTCNOW" do
    assert create_bucket("selectjsontostring").status == 200

    assert put_object(
             "selectjsontostring",
             "data.jsonl",
             ~s({"ts":"1969-07-20T20:18Z","fmt":"MMMM d, y h:m a"}\n)
           ).status == 200

    resp =
      select_object(
        "selectjsontostring",
        "data.jsonl",
        select_json_xml(
          "SELECT to_string(to_timestamp(ts), fmt) AS formatted, to_string(`1969-07-20T20:18Z`, 'MMM d, yyyy') AS short, to_string(`1969-07-20T20:18+08:00`, 'y-MM-dd''T''H:m:ssXXXXX') AS offset_text, date_diff(second, utcnow(), utcnow()) AS stable_now FROM S3Object"
        )
      )

    assert resp.status == 200

    assert json_record_payloads(resp) == [
             %{
               "formatted" => "July 20, 1969 8:18 PM",
               "offset_text" => "1969-07-20T20:18:00+08:00",
               "short" => "Jul 20, 1969",
               "stable_now" => 0
             }
           ]
  end

  test "JSON Lines rejects invalid timestamp inputs before event-stream response" do
    assert create_bucket("selectjsonbadtimestamp").status == 200
    assert put_object("selectjsonbadtimestamp", "data.jsonl", ~s({"ts":"bad"}\n)).status == 200

    resp =
      select_object(
        "selectjsonbadtimestamp",
        "data.jsonl",
        select_json_xml("SELECT to_timestamp(ts) AS ts FROM S3Object")
      )

    assert resp.status == 400
    assert get_resp_header(resp, "content-type") |> List.first() =~ "application/xml"
    assert resp.resp_body =~ "<Code>ValueParseFailure</Code>"
  end

  test "JSON Lines supports CAST AS TIMESTAMP and numeric type aliases" do
    assert create_bucket("selectjsoncasttimestamp").status == 200

    assert put_object(
             "selectjsoncasttimestamp",
             "data.jsonl",
             ~s({"name":"Ada","ts":"2026-07-03T10:30:00.123Z","whole":"2","decimal":"3.5"}\n{"name":"Bob","ts":"2026-07-03T11:00Z","whole":"4","decimal":"5.25"}\n)
           ).status == 200

    resp =
      select_object(
        "selectjsoncasttimestamp",
        "data.jsonl",
        select_json_xml(
          "SELECT cast(ts AS TIMESTAMP) AS ts_cast, to_string(cast(ts AS TIMESTAMP), 'HH:mmX') AS clock, cast(whole AS INTEGER) + cast(decimal AS NUMERIC) AS total, cast(decimal AS DOUBLE) AS double_value FROM S3Object WHERE cast(ts AS TIMESTAMP) &gt;= `2026-07-03T10:45Z`"
        )
      )

    assert resp.status == 200

    assert json_record_payloads(resp) == [
             %{
               "clock" => "11:00Z",
               "double_value" => 5.25,
               "total" => 9.25,
               "ts_cast" => "2026-07-03T11:00Z"
             }
           ]
  end

  test "JSON Lines rejects invalid CAST timestamp inputs before event-stream response" do
    assert create_bucket("selectjsonbadcasttimestamp").status == 200

    assert put_object("selectjsonbadcasttimestamp", "data.jsonl", ~s({"ts":"bad"}\n)).status ==
             200

    resp =
      select_object(
        "selectjsonbadcasttimestamp",
        "data.jsonl",
        select_json_xml("SELECT cast(ts AS TIMESTAMP) AS ts FROM S3Object")
      )

    assert resp.status == 400
    assert get_resp_header(resp, "content-type") |> List.first() =~ "application/xml"
    assert resp.resp_body =~ "<Code>ValueParseFailure</Code>"
  end

  test "JSON Lines WHERE supports boolean expressions and NULL predicates" do
    assert create_bucket("selectjsonbool").status == 200

    assert put_object(
             "selectjsonbool",
             "data.jsonl",
             ~s({"name":"Ada","age":36,"active":true}\n{"name":"Bob","age":40,"active":false}\n{"name":"Null","age":null,"active":true}\n)
           ).status == 200

    resp =
      select_object(
        "selectjsonbool",
        "data.jsonl",
        select_json_xml(
          "SELECT name FROM S3Object WHERE (age &gt; 36 OR active = 'true') AND NOT age IS NULL"
        )
      )

    assert resp.status == 200
    assert json_record_payloads(resp) == [%{"name" => "Ada"}, %{"name" => "Bob"}]
  end

  test "JSON Lines equality predicates do not coerce null to the string null" do
    assert create_bucket("selectjsonnullstring").status == 200

    assert put_object(
             "selectjsonnullstring",
             "data.jsonl",
             ~s({"name":"String","age":"null"}\n{"name":"ActualNull","age":null}\n{"name":"Number","age":1}\n)
           ).status == 200

    eq_resp =
      select_object(
        "selectjsonnullstring",
        "data.jsonl",
        select_json_xml("SELECT name FROM S3Object WHERE age = 'null'")
      )

    assert eq_resp.status == 200
    assert json_record_payloads(eq_resp) == [%{"name" => "String"}]

    neq_resp =
      select_object(
        "selectjsonnullstring",
        "data.jsonl",
        select_json_xml("SELECT name FROM S3Object WHERE age != 'null'")
      )

    assert neq_resp.status == 200
    assert json_record_payloads(neq_resp) == [%{"name" => "Number"}]
  end

  test "JSON Lines WHERE NOT does not match missing or null comparison operands" do
    assert create_bucket("selectjsonnotunknown").status == 200

    assert put_object(
             "selectjsonnotunknown",
             "data.jsonl",
             ~s({"name":"Ada","flag":"x"}\n{"name":"Missing"}\n{"name":"ActualNull","flag":null}\n{"name":"Bob","flag":"y"}\n)
           ).status == 200

    resp =
      select_object(
        "selectjsonnotunknown",
        "data.jsonl",
        select_json_xml("SELECT name FROM S3Object WHERE NOT flag = 'x'")
      )

    assert resp.status == 200
    assert json_record_payloads(resp) == [%{"name" => "Bob"}]
  end

  test "JSON Lines WHERE supports IN BETWEEN and LIKE predicates" do
    assert create_bucket("selectjsonpredicates").status == 200

    assert put_object(
             "selectjsonpredicates",
             "data.jsonl",
             ~s({"name":"Ada","age":36,"code":"A_da"}\n{"name":"Bob","age":40,"code":"Ada"}\n{"name":"Eve","age":null,"code":"A_x"}\n)
           ).status == 200

    resp =
      select_object(
        "selectjsonpredicates",
        "data.jsonl",
        select_json_xml(
          "SELECT name FROM S3Object WHERE name IN ('Ada', 'Bob') AND age BETWEEN 30 AND 37 AND code LIKE 'A!_%' ESCAPE '!'"
        )
      )

    assert resp.status == 200
    assert json_record_payloads(resp) == [%{"name" => "Ada"}]

    not_resp =
      select_object(
        "selectjsonpredicates",
        "data.jsonl",
        select_json_xml(
          "SELECT name FROM S3Object WHERE name NOT IN ('Bob') AND age NOT BETWEEN 30 AND 37"
        )
      )

    assert not_resp.status == 200
    refute records_event?(not_resp)
  end

  test "JSON Lines Select supports aggregate projections with CAST and null skipping" do
    assert create_bucket("selectjsonaggregate").status == 200

    assert put_object(
             "selectjsonaggregate",
             "data.jsonl",
             ~s({"name":"Ada","score":10}\n{"name":"Bob","score":null}\n{"name":"Cid"}\n{"name":"Dee","score":20}\n)
           ).status == 200

    resp =
      select_object(
        "selectjsonaggregate",
        "data.jsonl",
        select_json_xml(
          "SELECT count(*), count(score), sum(cast(score AS FLOAT)), avg(score), min(score), max(score) FROM S3Object"
        )
      )

    assert resp.status == 200

    assert json_record_payloads(resp) == [
             %{"_1" => 4, "_2" => 2, "_3" => 30, "_4" => 15, "_5" => 10, "_6" => 20}
           ]
  end

  test "JSON Lines rejects mixed aggregate and non-aggregate projections before event-stream response" do
    assert create_bucket("selectjsonmixedaggregate").status == 200

    assert put_object("selectjsonmixedaggregate", "data.jsonl", ~s({"name":"Ada","score":10}\n)).status ==
             200

    resp =
      select_object(
        "selectjsonmixedaggregate",
        "data.jsonl",
        select_json_xml("SELECT name, count(*) FROM S3Object")
      )

    assert resp.status == 400
    assert get_resp_header(resp, "content-type") |> List.first() =~ "application/xml"
    assert resp.resp_body =~ "<Code>UnsupportedSqlStructure</Code>"
  end

  test "JSON Lines FROM wildcard rows support aggregate projections" do
    assert create_bucket("selectjsonfromaggregate").status == 200

    assert put_object(
             "selectjsonfromaggregate",
             "data.jsonl",
             ~s({"items":[{"n":1},{"m":0},{"n":3}]}\n)
           ).status == 200

    resp =
      select_object(
        "selectjsonfromaggregate",
        "data.jsonl",
        select_json_xml("SELECT count(*), count(n), sum(n) FROM S3Object[*].items[*]")
      )

    assert resp.status == 200
    assert json_record_payloads(resp) == [%{"_1" => 3, "_2" => 2, "_3" => 4}]
  end

  test "JSON Lines rejects duplicate projection aliases before event-stream response" do
    assert create_bucket("selectjsonaliasdupe").status == 200
    assert put_object("selectjsonaliasdupe", "data.jsonl", ~s({"a":1,"b":2}\n)).status == 200

    resp =
      select_object(
        "selectjsonaliasdupe",
        "data.jsonl",
        select_json_xml("SELECT a AS x, b AS x FROM S3Object")
      )

    assert resp.status == 400
    assert get_resp_header(resp, "content-type") |> List.first() =~ "application/xml"
    assert resp.resp_body =~ "<Code>InvalidKeyPath</Code>"
  end

  test "JSON Lines rejects duplicate natural projection output names before event-stream response" do
    assert create_bucket("selectjsonnaturaldupe").status == 200
    assert put_object("selectjsonnaturaldupe", "data.jsonl", ~s({"a":1}\n)).status == 200

    resp =
      select_object(
        "selectjsonnaturaldupe",
        "data.jsonl",
        select_json_xml("SELECT a, a FROM S3Object")
      )

    assert resp.status == 400
    assert get_resp_header(resp, "content-type") |> List.first() =~ "application/xml"
    assert resp.resp_body =~ "<Code>InvalidKeyPath</Code>"
  end

  test "JSON Lines rejects duplicate aggregate aliases before event-stream response" do
    assert create_bucket("selectjsonaggregatedupe").status == 200
    assert put_object("selectjsonaggregatedupe", "data.jsonl", ~s({"a":1}\n)).status == 200

    resp =
      select_object(
        "selectjsonaggregatedupe",
        "data.jsonl",
        select_json_xml("SELECT count(*) AS x, sum(a) AS x FROM S3Object")
      )

    assert resp.status == 400
    assert get_resp_header(resp, "content-type") |> List.first() =~ "application/xml"
    assert resp.resp_body =~ "<Code>InvalidKeyPath</Code>"
  end

  test "JSON Lines rejects duplicate string function output names before event-stream response" do
    assert create_bucket("selectjsonstringdupe").status == 200
    assert put_object("selectjsonstringdupe", "data.jsonl", ~s({"name":"Ada"}\n)).status == 200

    resp =
      select_object(
        "selectjsonstringdupe",
        "data.jsonl",
        select_json_xml("SELECT name, lower(name) AS name FROM S3Object")
      )

    assert resp.status == 400
    assert get_resp_header(resp, "content-type") |> List.first() =~ "application/xml"
    assert resp.resp_body =~ "<Code>InvalidKeyPath</Code>"
  end

  test "JSON Lines rejects duplicate conditional output names before event-stream response" do
    assert create_bucket("selectjsonconditionaldupe").status == 200

    assert put_object("selectjsonconditionaldupe", "data.jsonl", ~s({"name":"Ada"}\n)).status ==
             200

    resp =
      select_object(
        "selectjsonconditionaldupe",
        "data.jsonl",
        select_json_xml("SELECT name, coalesce(missing_name, 'fallback') AS name FROM S3Object")
      )

    assert resp.status == 400
    assert get_resp_header(resp, "content-type") |> List.first() =~ "application/xml"
    assert resp.resp_body =~ "<Code>InvalidKeyPath</Code>"
  end

  test "JSON Lines rejects string functions over non-scalar values before event-stream response" do
    assert create_bucket("selectjsonstringbad").status == 200

    assert put_object("selectjsonstringbad", "data.jsonl", ~s({"name":{"first":"Ada"}}\n)).status ==
             200

    resp =
      select_object(
        "selectjsonstringbad",
        "data.jsonl",
        select_json_xml("SELECT lower(name) AS lowered FROM S3Object")
      )

    assert resp.status == 400
    assert get_resp_header(resp, "content-type") |> List.first() =~ "application/xml"
    assert resp.resp_body =~ "<Code>InvalidKeyPath</Code>"
  end

  test "JSON Lines rejects string functions over arrays before event-stream response" do
    assert create_bucket("selectjsonstringarraybad").status == 200

    assert put_object("selectjsonstringarraybad", "data.jsonl", ~s({"name":["Ada"]}\n)).status ==
             200

    resp =
      select_object(
        "selectjsonstringarraybad",
        "data.jsonl",
        select_json_xml("SELECT lower(name) AS lowered FROM S3Object")
      )

    assert resp.status == 400
    assert get_resp_header(resp, "content-type") |> List.first() =~ "application/xml"
    assert resp.resp_body =~ "<Code>InvalidKeyPath</Code>"
  end

  test "JSON Lines rejects NULLIF comparisons over non-scalar values before event-stream response" do
    assert create_bucket("selectjsonnullifbad").status == 200

    assert put_object("selectjsonnullifbad", "data.jsonl", ~s({"payload":{"value":"Ada"}}\n)).status ==
             200

    resp =
      select_object(
        "selectjsonnullifbad",
        "data.jsonl",
        select_json_xml("SELECT nullif(payload, 'x') AS payload FROM S3Object")
      )

    assert resp.status == 400
    assert get_resp_header(resp, "content-type") |> List.first() =~ "application/xml"
    assert resp.resp_body =~ "<Code>InvalidKeyPath</Code>"
  end

  test "JSON Lines rejects nonnumeric CAST projections before event-stream response" do
    assert create_bucket("selectjsonbadcast").status == 200
    assert put_object("selectjsonbadcast", "data.jsonl", ~s({"score":"bad"}\n)).status == 200

    resp =
      select_object(
        "selectjsonbadcast",
        "data.jsonl",
        select_json_xml("SELECT cast(score AS INT) AS score_int FROM S3Object")
      )

    assert resp.status == 400
    assert get_resp_header(resp, "content-type") |> List.first() =~ "application/xml"
    assert resp.resp_body =~ "<Code>CastFailed</Code>"
  end

  test "GZIP JSON Lines input is decompressed before selection" do
    assert create_bucket("selectjsongzip").status == 200

    assert put_object(
             "selectjsongzip",
             "data.jsonl.gz",
             :zlib.gzip(~s({"id":1}\n{"id":2}\n))
           ).status == 200

    resp =
      select_object(
        "selectjsongzip",
        "data.jsonl.gz",
        select_gzip_json_xml("SELECT id FROM S3Object WHERE id > 1")
      )

    assert resp.status == 200
    assert json_record_payloads(resp) == [%{"id" => 2}]
  end

  test "JSON Lines LIMIT 0 does not buffer oversized records" do
    assert create_bucket("selectjsonlimitzero").status == 200

    assert put_object("selectjsonlimitzero", "data.jsonl", String.duplicate("x", 1_048_577)).status ==
             200

    resp =
      select_object(
        "selectjsonlimitzero",
        "data.jsonl",
        select_json_xml("SELECT * FROM S3Object LIMIT 0")
      )

    assert resp.status == 200
    refute records_event?(resp)
  end

  test "JSON Lines ScanRange selects records whose first byte is in range" do
    assert create_bucket("selectjsonscan").status == 200

    assert put_object(
             "selectjsonscan",
             "data.jsonl",
             ~s({"id":1}\n{"id":2}\n{"id":3}\n)
           ).status == 200

    resp =
      select_object(
        "selectjsonscan",
        "data.jsonl",
        select_json_xml(
          "SELECT id FROM S3Object",
          "<Type>LINES</Type>",
          "",
          "<ScanRange><Start>1</Start><End>9</End></ScanRange>"
        )
      )

    assert resp.status == 200
    assert json_record_payloads(resp) == [%{"id" => 2}]
  end

  test "JSON Lines ScanRange does not parse malformed records outside the selected range" do
    assert create_bucket("selectjsonskipsbad").status == 200
    assert put_object("selectjsonskipsbad", "data.jsonl", ~s({"id":1}\n{broken}\n)).status == 200

    resp =
      select_object(
        "selectjsonskipsbad",
        "data.jsonl",
        select_json_xml(
          "SELECT id FROM S3Object",
          "<Type>LINES</Type>",
          "",
          "<ScanRange><Start>0</Start><End>0</End></ScanRange>"
        )
      )

    assert resp.status == 200
    assert json_record_payloads(resp) == [%{"id" => 1}]
  end

  test "JSON Lines ScanRange skips oversized records before and after the selected range" do
    oversized = String.duplicate("x", 1_048_577)

    assert create_bucket("selectjsonhugeafter").status == 200

    assert put_object("selectjsonhugeafter", "data.jsonl", ~s({"id":1}\n) <> oversized <> "\n").status ==
             200

    after_resp =
      select_object(
        "selectjsonhugeafter",
        "data.jsonl",
        select_json_xml(
          "SELECT id FROM S3Object",
          "<Type>LINES</Type>",
          "",
          "<ScanRange><Start>0</Start><End>0</End></ScanRange>"
        )
      )

    assert after_resp.status == 200
    assert json_record_payloads(after_resp) == [%{"id" => 1}]

    assert create_bucket("selectjsonhugebefore").status == 200

    assert put_object("selectjsonhugebefore", "data.jsonl", oversized <> "\n" <> ~s({"id":2}\n)).status ==
             200

    start_offset = byte_size(oversized) + 1

    before_resp =
      select_object(
        "selectjsonhugebefore",
        "data.jsonl",
        select_json_xml(
          "SELECT id FROM S3Object",
          "<Type>LINES</Type>",
          "",
          "<ScanRange><Start>#{start_offset}</Start></ScanRange>"
        )
      )

    assert before_resp.status == 200
    assert json_record_payloads(before_resp) == [%{"id" => 2}]
  end

  test "JSON Lines supports no-alias wildcard row references" do
    assert create_bucket("selectjsonwildrow").status == 200

    assert put_object(
             "selectjsonwildrow",
             "data.jsonl",
             ~s({"name":"Ada","age":36}\n{"name":"Bob","age":40}\n)
           ).status == 200

    resp =
      select_object(
        "selectjsonwildrow",
        "data.jsonl",
        select_json_xml("SELECT _1.name FROM S3Object[*] WHERE _1.age = '40'")
      )

    assert resp.status == 200
    assert json_record_payloads(resp) == [%{"name" => "Bob"}]
  end

  test "JSON Lines preserves array null values instead of treating them as missing" do
    assert create_bucket("selectjsonnull").status == 200
    assert put_object("selectjsonnull", "data.jsonl", ~s({"items":[null]}\n)).status == 200

    resp =
      select_object(
        "selectjsonnull",
        "data.jsonl",
        select_json_xml("SELECT items[0] FROM S3Object WHERE items[0] IS NULL")
      )

    assert resp.status == 200
    assert json_record_payloads(resp) == [%{"items" => nil}]
  end

  test "JSON Lines supports nested fields, quoted keys, and array indexes" do
    assert create_bucket("selectjsonnested").status == 200

    assert put_object(
             "selectjsonnested",
             "data.jsonl",
             ~s({"projects":[{"Project Name":"compiler"}]}\n)
           ).status == 200

    resp =
      select_object(
        "selectjsonnested",
        "data.jsonl",
        select_json_xml(~s(SELECT s.projects[0]."Project Name" FROM S3Object AS s))
      )

    assert resp.status == 200
    assert json_record_payloads(resp) == [%{"Project Name" => "compiler"}]
  end

  test "JSON Lines FROM path expands array wildcards and emits missing rows" do
    assert create_bucket("selectjsonfrompath").status == 200

    assert put_object(
             "selectjsonfrompath",
             "data.jsonl",
             ~s({"Rules":[{"id":"1"},{"expr":"y > x"},{"id":"2","expr":"z"}]}\n{"created":"today"}\n)
           ).status == 200

    resp =
      select_object(
        "selectjsonfrompath",
        "data.jsonl",
        select_json_xml("SELECT id FROM S3Object[*].Rules[*].id")
      )

    assert resp.status == 200
    assert json_record_payloads(resp) == [%{"id" => "1"}, %{}, %{"id" => "2"}, %{}]
  end

  test "JSON Lines FROM path filters missing rows with IS NOT MISSING" do
    assert create_bucket("selectjsonnotmissing").status == 200

    assert put_object(
             "selectjsonnotmissing",
             "data.jsonl",
             ~s({"Rules":[{"id":"1"},{"expr":"y > x"},{"id":"2"}]}\n{"created":"today"}\n)
           ).status == 200

    resp =
      select_object(
        "selectjsonnotmissing",
        "data.jsonl",
        select_json_xml("SELECT id FROM S3Object[*].Rules[*].id WHERE id IS NOT MISSING")
      )

    assert resp.status == 200
    assert json_record_payloads(resp) == [%{"id" => "1"}, %{"id" => "2"}]
  end

  test "JSON Lines FROM path can select only missing rows" do
    assert create_bucket("selectjsonmissing").status == 200

    assert put_object(
             "selectjsonmissing",
             "data.jsonl",
             ~s({"Rules":[{"id":"1"},{"expr":"y > x"}]}\n{"created":"today"}\n)
           ).status == 200

    resp =
      select_object(
        "selectjsonmissing",
        "data.jsonl",
        select_json_xml("SELECT * FROM S3Object[*].Rules[*].id WHERE id IS MISSING")
      )

    assert resp.status == 200
    assert json_record_payloads(resp) == [%{}, %{}]
  end

  test "JSON Lines FROM path supports aliases, filters, object wildcards, and LIMIT" do
    assert create_bucket("selectjsonfromalias").status == 200

    assert put_object(
             "selectjsonfromalias",
             "data.jsonl",
             ~s({"groups":{"one":{"name":"alpha","score":1},"two":{"name":"beta","score":3}}}\n)
           ).status == 200

    resp =
      select_object(
        "selectjsonfromalias",
        "data.jsonl",
        select_json_xml("SELECT g.name FROM S3Object[*].groups.* AS g WHERE g.score > 1 LIMIT 1")
      )

    assert resp.status == 200
    assert json_record_payloads(resp) == [%{"name" => "beta"}]
  end

  test "JSON Lines FROM path supports last-element row qualifiers" do
    assert create_bucket("selectjsonfromrowname").status == 200

    assert put_object(
             "selectjsonfromrowname",
             "data.jsonl",
             ~s({"books":[{"author":{"name":"Ada","age":36}},{"author":{"name":"Bob","age":40}}]}\n)
           ).status == 200

    resp =
      select_object(
        "selectjsonfromrowname",
        "data.jsonl",
        select_json_xml(
          "SELECT author.name FROM S3Object[*].books[*].author WHERE author.age > 36"
        )
      )

    assert resp.status == 200
    assert json_record_payloads(resp) == [%{"name" => "Bob"}]
  end

  test "JSON Lines FROM wildcard rows support no-alias _1 references" do
    assert create_bucket("selectjsonfromrow").status == 200

    assert put_object(
             "selectjsonfromrow",
             "data.jsonl",
             ~s({"books":[{"name":"cheap","price":10},{"name":"expensive","price":25}]}\n)
           ).status == 200

    resp =
      select_object(
        "selectjsonfromrow",
        "data.jsonl",
        select_json_xml("SELECT _1.name FROM S3Object[*].books[*] WHERE _1.price > 20")
      )

    assert resp.status == 200
    assert json_record_payloads(resp) == [%{"name" => "expensive"}]
  end

  test "JSON Lines FROM wildcard rows support direct _1 projection with LIMIT" do
    assert create_bucket("selectjsonfromdirectrow").status == 200

    assert put_object(
             "selectjsonfromdirectrow",
             "data.jsonl",
             ~s({"numbers":[1,2,3,4]}\n)
           ).status == 200

    resp =
      select_object(
        "selectjsonfromdirectrow",
        "data.jsonl",
        select_json_xml("SELECT _1 FROM S3Object[*].numbers[*] WHERE _1 > 1 LIMIT 1")
      )

    assert resp.status == 200
    assert json_record_payloads(resp) == [%{"_1" => 2}]
  end

  test "JSON Lines FROM wildcard rows support _1 bracket indexing" do
    assert create_bucket("selectjsonfromrowindex").status == 200

    assert put_object(
             "selectjsonfromrowindex",
             "data.jsonl",
             ~s({"pairs":[[1,"drop"],[2,"keep"]]}\n)
           ).status == 200

    resp =
      select_object(
        "selectjsonfromrowindex",
        "data.jsonl",
        select_json_xml("SELECT _1[0] FROM S3Object[*].pairs[*] WHERE _1[1] = 'keep'")
      )

    assert resp.status == 200
    assert json_record_payloads(resp) == [%{"_1" => 2}]
  end

  test "JSON Lines wildcard-ended FROM paths reject prior field names as row qualifiers" do
    assert create_bucket("selectjsonfrombadqualifier").status == 200

    assert put_object(
             "selectjsonfrombadqualifier",
             "data.jsonl",
             ~s({"books":[{"name":"one"}]}\n)
           ).status == 200

    resp =
      select_object(
        "selectjsonfrombadqualifier",
        "data.jsonl",
        select_json_xml("SELECT books.name FROM S3Object[*].books[*]")
      )

    assert resp.status == 400
    assert resp.resp_body =~ "<Code>InvalidKeyPath</Code>"
  end

  test "CSV rejects JSON missing predicates before event-stream response" do
    assert create_bucket("selectcsvmissingpredicate").status == 200
    assert put_object("selectcsvmissingpredicate", "data.csv", "a,b\n").status == 200

    resp =
      select_object(
        "selectcsvmissingpredicate",
        "data.csv",
        select_xml("SELECT _1 FROM S3Object WHERE _1 IS NOT MISSING")
      )

    assert resp.status == 501
    assert get_resp_header(resp, "content-type") |> List.first() =~ "application/xml"
    assert resp.resp_body =~ "<Code>NotImplemented</Code>"
    assert resp.resp_body =~ "IS MISSING predicates are only implemented for JSON"
  end

  test "CSV rejects nested JSON missing predicates before event-stream response" do
    assert create_bucket("selectcsvnestedmissing").status == 200
    assert put_object("selectcsvnestedmissing", "data.csv", "a,b\n").status == 200

    resp =
      select_object(
        "selectcsvnestedmissing",
        "data.csv",
        select_xml("SELECT _1 FROM S3Object WHERE _1 = 'a' OR _2 IS MISSING")
      )

    assert resp.status == 501
    assert resp.resp_body =~ "<Code>NotImplemented</Code>"
    assert resp.resp_body =~ "IS MISSING predicates are only implemented for JSON"
  end

  test "JSON DOCUMENT input is the default JSON type and selects a root document" do
    assert create_bucket("selectjsondocroot").status == 200

    assert put_object(
             "selectjsondocroot",
             "data.json",
             ~s({"name":"Ada","age":36,"city":"London"})
           ).status == 200

    resp =
      select_object(
        "selectjsondocroot",
        "data.json",
        select_json_xml("SELECT s.name, s.age FROM S3Object AS s WHERE s.city = 'London'", "")
      )

    assert resp.status == 200
    assert json_record_payloads(resp) == [%{"name" => "Ada", "age" => 36}]
  end

  test "JSON DOCUMENT input expands FROM paths and preserves missing rows" do
    assert create_bucket("selectjsondocpath").status == 200

    assert put_object(
             "selectjsondocpath",
             "data.json",
             ~s({"Rules":[{"id":"1"},{"expr":"skip"},{"id":"2"}],"created":"today"})
           ).status == 200

    resp =
      select_object(
        "selectjsondocpath",
        "data.json",
        select_json_xml(
          "SELECT id FROM S3Object[*].Rules[*].id",
          "<Type>DOCUMENT</Type>"
        )
      )

    assert resp.status == 200
    assert json_record_payloads(resp) == [%{"id" => "1"}, %{}, %{"id" => "2"}]
  end

  test "JSON DOCUMENT input expands top-level arrays with explicit array wildcard" do
    assert create_bucket("selectjsondocarray").status == 200

    assert put_object(
             "selectjsondocarray",
             "data.json",
             ~s([{"name":"Ada","score":1},{"name":"Bob","score":3}])
           ).status == 200

    resp =
      select_object(
        "selectjsondocarray",
        "data.json",
        select_json_xml(
          "SELECT _1.name FROM S3Object[*][*] WHERE _1.score &gt; 1 LIMIT 1",
          "<Type>DOCUMENT</Type>"
        )
      )

    assert resp.status == 200
    assert json_record_payloads(resp) == [%{"name" => "Bob"}]
  end

  test "JSON DOCUMENT aggregate projections skip MISSING rows and can serialize as CSV" do
    assert create_bucket("selectjsondoccsvagg").status == 200

    assert put_object(
             "selectjsondoccsvagg",
             "data.json",
             ~s({"groups":[{"items":[{"n":1},{"n":2}]},{"other":true}]})
           ).status == 200

    resp =
      select_object(
        "selectjsondoccsvagg",
        "data.json",
        select_json_to_csv_xml(
          "SELECT count(*), count(n), sum(n), avg(n) FROM S3Object[*].groups[*].items[*]",
          "<Type>DOCUMENT</Type>",
          "<FieldDelimiter>|</FieldDelimiter>"
        )
      )

    assert resp.status == 200
    assert records_payload(resp) == "2|2|3|1.5\n"
  end

  test "GZIP JSON DOCUMENT input is decompressed before selection" do
    assert create_bucket("selectjsondocgzip").status == 200

    assert put_object(
             "selectjsondocgzip",
             "data.json.gz",
             :zlib.gzip(~s({"items":[{"id":1},{"id":2}]}))
           ).status == 200

    resp =
      select_object(
        "selectjsondocgzip",
        "data.json.gz",
        select_gzip_json_xml(
          "SELECT id FROM S3Object[*].items[*] WHERE id &gt; 1",
          "<Type>DOCUMENT</Type>"
        )
      )

    assert resp.status == 200
    assert json_record_payloads(resp) == [%{"id" => 2}]
  end

  test "JSON DOCUMENT input rejects ScanRange before event-stream response" do
    assert create_bucket("selectjsondocscan").status == 200
    assert put_object("selectjsondocscan", "data.json", ~s({"id":1})).status == 200

    resp =
      select_object(
        "selectjsondocscan",
        "data.json",
        select_json_xml(
          "SELECT * FROM S3Object",
          "<Type>DOCUMENT</Type>",
          "",
          "<ScanRange><Start>0</Start></ScanRange>"
        )
      )

    assert resp.status == 400
    assert get_resp_header(resp, "content-type") |> List.first() =~ "application/xml"
    assert resp.resp_body =~ "<Code>InvalidRequest</Code>"
    assert resp.resp_body =~ "ScanRange is only supported for JSON LINES input"
  end

  test "default JSON DOCUMENT input rejects ScanRange before event-stream response" do
    assert create_bucket("selectjsondocscandefault").status == 200
    assert put_object("selectjsondocscandefault", "data.json", ~s({"id":1})).status == 200

    resp =
      select_object(
        "selectjsondocscandefault",
        "data.json",
        select_json_xml(
          "SELECT * FROM S3Object",
          "",
          "",
          "<ScanRange><Start>0</Start></ScanRange>"
        )
      )

    assert resp.status == 400
    assert get_resp_header(resp, "content-type") |> List.first() =~ "application/xml"
    assert resp.resp_body =~ "<Code>InvalidRequest</Code>"
    assert resp.resp_body =~ "ScanRange is only supported for JSON LINES input"
  end

  test "malformed JSON DOCUMENT input fails before event-stream response" do
    assert create_bucket("selectjsondocbad").status == 200
    assert put_object("selectjsondocbad", "data.json", "{broken}").status == 200

    resp =
      select_object(
        "selectjsondocbad",
        "data.json",
        select_json_xml("SELECT * FROM S3Object", "<Type>DOCUMENT</Type>")
      )

    assert resp.status == 400
    assert get_resp_header(resp, "content-type") |> List.first() =~ "application/xml"
    assert resp.resp_body =~ "<Code>JSONParsingError</Code>"
  end

  test "oversized JSON DOCUMENT input is bounded before event-stream response" do
    assert create_bucket("selectjsondoclarge").status == 200

    document = ~s({"payload":") <> String.duplicate("x", 1_048_577) <> ~s("})
    assert put_object("selectjsondoclarge", "data.json", document).status == 200

    resp =
      select_object(
        "selectjsondoclarge",
        "data.json",
        select_json_xml("SELECT * FROM S3Object", "<Type>DOCUMENT</Type>")
      )

    assert resp.status == 400
    assert get_resp_header(resp, "content-type") |> List.first() =~ "application/xml"
    assert resp.resp_body =~ "<Code>OverMaxRecordSize</Code>"
  end

  test "malformed JSON Lines input fails before event-stream response" do
    assert create_bucket("selectjsonbad").status == 200
    assert put_object("selectjsonbad", "data.jsonl", "{broken}\n").status == 200

    resp = select_object("selectjsonbad", "data.jsonl", select_json_xml("SELECT * FROM S3Object"))

    assert resp.status == 400
    assert resp.resp_body =~ "<Code>JSONParsingError</Code>"
  end

  test "ambiguous unquoted JSON field names fail before event-stream response" do
    assert create_bucket("selectjsonambig").status == 200

    assert put_object("selectjsonambig", "data.jsonl", ~s({"Name":"Ada","name":"Lovelace"}\n)).status ==
             200

    resp =
      select_object("selectjsonambig", "data.jsonl", select_json_xml("SELECT name FROM S3Object"))

    assert resp.status == 400
    assert resp.resp_body =~ "<Code>AmbiguousFieldName</Code>"
  end

  test "CSV rejects JSON-only FROM wildcard syntax" do
    assert create_bucket("selectcsvwild").status == 200
    assert put_object("selectcsvwild", "data.csv", "a,b\n").status == 200

    resp = select_object("selectcsvwild", "data.csv", select_xml("SELECT * FROM S3Object[*]"))

    assert resp.status == 400
    assert resp.resp_body =~ "<Code>InvalidKeyPath</Code>"
  end

  test "missing header names fail before event-stream response" do
    assert create_bucket("selectmissingheader").status == 200
    assert put_object("selectmissingheader", "data.csv", "name\n").status == 200

    resp =
      select_object(
        "selectmissingheader",
        "data.csv",
        select_xml("SELECT missing FROM S3Object", "<FileHeaderInfo>USE</FileHeaderInfo>")
      )

    assert resp.status == 400
    assert resp.resp_body =~ "<Code>MissingHeaderName</Code>"
  end

  test "too many projected columns are rejected before event-stream response" do
    assert create_bucket("selecttoomanycols").status == 200
    assert put_object("selecttoomanycols", "data.csv", "a\n").status == 200

    expression = Enum.map_join(1..1001, ", ", fn _idx -> "_1" end)

    resp =
      select_object(
        "selecttoomanycols",
        "data.csv",
        select_xml("SELECT #{expression} FROM S3Object")
      )

    assert resp.status == 400
    assert resp.resp_body =~ "<Code>OverMaxColumn</Code>"
  end

  test "expanded output records are bounded before event-stream response" do
    assert create_bucket("selectoverrecord").status == 200

    assert put_object("selectoverrecord", "data.csv", String.duplicate("a", 600_000) <> "\n").status ==
             200

    resp =
      select_object(
        "selectoverrecord",
        "data.csv",
        select_xml("SELECT _1, _1 FROM S3Object")
      )

    assert resp.status == 400
    assert resp.resp_body =~ "<Code>OverMaxRecordSize</Code>"
  end

  test "ambiguous header names fail before event-stream response" do
    assert create_bucket("selectambiguous").status == 200
    assert put_object("selectambiguous", "data.csv", "Name,name\nAda,Lovelace\n").status == 200

    resp =
      select_object(
        "selectambiguous",
        "data.csv",
        select_xml("SELECT name FROM S3Object", "<FileHeaderInfo>USE</FileHeaderInfo>")
      )

    assert resp.status == 400
    assert resp.resp_body =~ "<Code>AmbiguousFieldName</Code>"
  end

  test "SSE-S3 objects are selected as plaintext before event-stream response" do
    assert create_bucket("selectsse").status == 200

    before_files = select_temp_files()

    assert put_object("selectsse", "secret.csv", "x,y\n", [
             {"x-amz-server-side-encryption", "AES256"}
           ]).status == 200

    resp = select_object("selectsse", "secret.csv", @select_xml)

    assert resp.status == 200

    records =
      resp.resp_body |> decode_events() |> Enum.find(&(&1.headers[":event-type"] == "Records"))

    assert records.payload == "x,y\n"
    assert select_temp_files() == before_files
  end

  test "versioned current objects do not expose version id headers in SelectObjectContent" do
    assert create_bucket("selectversioned").status == 200
    assert enable_versioning("selectversioned").status == 200
    assert put_object("selectversioned", "data.csv", "a,b\n").status == 200

    resp = select_object("selectversioned", "data.csv", @select_xml)

    assert resp.status == 200
    assert get_resp_header(resp, "x-amz-version-id") == []
  end

  test "current delete markers do not expose version id headers in SelectObjectContent" do
    assert create_bucket("selectdm").status == 200
    assert enable_versioning("selectdm").status == 200
    assert put_object("selectdm", "data.csv", "a,b\n").status == 200
    assert delete_object("selectdm", "data.csv").status == 204

    resp = select_object("selectdm", "data.csv", @select_xml)

    assert resp.status == 404
    assert get_resp_header(resp, "x-amz-delete-marker") == ["true"]
    assert get_resp_header(resp, "x-amz-version-id") == []
    assert get_resp_header(resp, "content-type") |> List.first() =~ "application/xml"
    assert resp.resp_body =~ "<Code>NoSuchKey</Code>"
  end

  test "unsupported SQL expression fails before event-stream response" do
    assert create_bucket("selectexpr").status == 200
    assert put_object("selectexpr", "data.csv", "a,b\n").status == 200

    xml =
      String.replace(
        @select_xml,
        "SELECT * FROM S3Object",
        "SELECT abs(_1) FROM S3Object"
      )

    resp = select_object("selectexpr", "data.csv", xml)

    assert resp.status == 501
    assert get_resp_header(resp, "content-type") |> List.first() =~ "application/xml"
    assert resp.resp_body =~ "<Code>NotImplemented</Code>"
  end

  test "malformed quoted CSV fails before a 200 event stream" do
    assert create_bucket("selectbadquoted").status == 200
    assert put_object("selectbadquoted", "data.csv", ~s("unterminated,b\n)).status == 200

    resp = select_object("selectbadquoted", "data.csv", @select_xml)

    assert resp.status == 400
    assert get_resp_header(resp, "content-type") |> List.first() =~ "application/xml"
    assert resp.resp_body =~ "<Code>InvalidArgument</Code>"
    assert resp.resp_body =~ "Unterminated quoted CSV field"
  end

  test "quoted CSV record delimiters are honored when explicitly enabled" do
    assert create_bucket("selectquotedrecorddelimiter").status == 200
    assert put_object("selectquotedrecorddelimiter", "data.csv", ~s("a\nb",c\n)).status == 200

    resp =
      select_object(
        "selectquotedrecorddelimiter",
        "data.csv",
        select_xml(
          "SELECT * FROM S3Object",
          "<AllowQuotedRecordDelimiter>true</AllowQuotedRecordDelimiter>"
        )
      )

    assert resp.status == 200
    assert records_payload(resp) == ~s("a\nb",c\n)
  end

  test "ScanRange skips oversized quoted multiline CSV records without parsing them" do
    assert create_bucket("selectquotedscan").status == 200

    skipped = ~s(") <> String.duplicate("x", 1_048_577) <> "\ny\",skip\n"
    body = skipped <> "ok,keep\n"
    assert put_object("selectquotedscan", "data.csv", body).status == 200

    resp =
      select_object(
        "selectquotedscan",
        "data.csv",
        select_xml(
          "SELECT _1 FROM S3Object",
          "<AllowQuotedRecordDelimiter>true</AllowQuotedRecordDelimiter>",
          "",
          "<ScanRange><Start>#{byte_size(skipped)}</Start></ScanRange>"
        )
      )

    assert resp.status == 200
    assert records_payload(resp) == "ok\n"
  end

  test "quoted CSV escape pairs can be split across source chunks" do
    before_files = select_temp_files()

    result =
      SelectCSV.stage!(
        [~s("a"), ~s("b",ok\n)],
        %{projections: :all, from: "S3Object", alias: nil, where: nil, limit: nil},
        %{"AllowQuotedRecordDelimiter" => "true"},
        %{}
      )

    assert File.read!(result.path) == ~s("a""b",ok\n)
    assert result.cleanup.() == :ok
    assert select_temp_files() == before_files
  end

  test "oversized single CSV record is rejected before a 200 event stream" do
    assert create_bucket("selectlarge").status == 200
    assert put_object("selectlarge", "data.csv", String.duplicate("a", 1_048_577)).status == 200

    resp = select_object("selectlarge", "data.csv", @select_xml)

    assert resp.status == 400
    assert resp.resp_body =~ "<Code>OverMaxRecordSize</Code>"
  end

  test "oversized CSV record inside one backend chunk is rejected before staging" do
    before_files = select_temp_files()
    chunk = String.duplicate("a", 1_048_577) <> "\n"

    assert_raise Maxio.S3.Error, ~r/OverMaxRecordSize/, fn ->
      SelectCSV.stage_select_all!([chunk])
    end

    assert select_temp_files() == before_files
  end

  test "CSV Select validates UTF-8 after stream chunks are reassembled into records" do
    beijing = <<0xE5, 0x8C, 0x97, 0xE4, 0xBA, 0xAC>>
    <<first_byte::binary-size(1), rest::binary>> = beijing
    body = "#{beijing},city\n"

    result = SelectCSV.stage_select_all!([first_byte, rest <> ",city\n"])

    try do
      assert File.read!(result.path) == body
      assert result.bytes_processed == byte_size(body)
    after
      result.cleanup.()
    end
  end

  test "staged CSV cleanup removes the private temp directory" do
    before_files = select_temp_files()

    result = SelectCSV.stage_select_all!(["a,b\n"])
    dir = Path.dirname(result.path)

    assert File.exists?(result.path)
    assert File.dir?(dir)
    assert result.cleanup.() == :ok
    refute File.exists?(result.path)
    refute File.exists?(dir)
    assert select_temp_files() == before_files
  end

  test "CSV Select accepts UTF-8 records" do
    beijing = <<0xE5, 0x8C, 0x97, 0xE4, 0xBA, 0xAC>>
    tokyo = <<0xE6, 0x9D, 0xB1, 0xE4, 0xBA, 0xAC>>
    smile = <<0xF0, 0x9F, 0x98, 0x80>>
    body = "#{beijing},city\n#{tokyo},city\nsmile,#{smile}\n"

    assert create_bucket("selectutf8csv").status == 200
    assert put_object("selectutf8csv", "data.csv", body).status == 200

    resp = select_object("selectutf8csv", "data.csv", @select_xml)

    assert resp.status == 200
    assert records_payload(resp) == body
  end

  test "CSV Select filters UTF-8 string values" do
    beijing = <<0xE5, 0x8C, 0x97, 0xE4, 0xBA, 0xAC>>
    shanghai = <<0xE4, 0xB8, 0x8A, 0xE6, 0xB5, 0xB7>>

    assert create_bucket("selectutf8where").status == 200

    assert put_object("selectutf8where", "data.csv", "#{beijing},keep\n#{shanghai},drop\n").status ==
             200

    resp =
      select_object(
        "selectutf8where",
        "data.csv",
        select_xml("SELECT _1 FROM S3Object WHERE _1 = '#{beijing}'")
      )

    assert resp.status == 200
    assert records_payload(resp) == "#{beijing}\n"
  end

  test "CSV Select filters UTF-8 values with header-name references" do
    beijing = <<0xE5, 0x8C, 0x97, 0xE4, 0xBA, 0xAC>>
    shanghai = <<0xE4, 0xB8, 0x8A, 0xE6, 0xB5, 0xB7>>

    assert create_bucket("selectutf8header").status == 200

    assert put_object(
             "selectutf8header",
             "data.csv",
             "city,status\n#{beijing},keep\n#{shanghai},drop\n"
           ).status == 200

    resp =
      select_object(
        "selectutf8header",
        "data.csv",
        select_xml(
          "SELECT city FROM S3Object WHERE status = 'keep'",
          "<FileHeaderInfo>USE</FileHeaderInfo>"
        )
      )

    assert resp.status == 200
    assert records_payload(resp) == "#{beijing}\n"
  end

  test "GZIP CSV Select accepts UTF-8 records after decompression" do
    beijing = <<0xE5, 0x8C, 0x97, 0xE4, 0xBA, 0xAC>>

    assert create_bucket("selectgziputf8").status == 200

    assert put_object("selectgziputf8", "data.csv.gz", :zlib.gzip("#{beijing},keep\n")).status ==
             200

    resp =
      select_object(
        "selectgziputf8",
        "data.csv.gz",
        select_gzip_xml("SELECT _1 FROM S3Object WHERE _2 = 'keep'")
      )

    assert resp.status == 200
    assert records_payload(resp) == "#{beijing}\n"
  end

  test "ScanRange skips invalid UTF-8 CSV records outside the selected range" do
    skipped = <<0xFF, ?,, ?b, ?\n>>
    selected = "ok,keep\n"

    assert create_bucket("selectscaninvalidutf8").status == 200
    assert put_object("selectscaninvalidutf8", "data.csv", skipped <> selected).status == 200

    resp =
      select_object(
        "selectscaninvalidutf8",
        "data.csv",
        select_xml(
          "SELECT _1 FROM S3Object",
          "",
          "",
          "<ScanRange><Start>#{byte_size(skipped)}</Start></ScanRange>"
        )
      )

    assert resp.status == 200
    assert records_payload(resp) == "ok\n"
  end

  test "invalid UTF-8 CSV bytes are rejected as InvalidTextEncoding" do
    assert create_bucket("selectinvalidutf8").status == 200
    assert put_object("selectinvalidutf8", "data.csv", <<0xFF, ?,, ?b, ?\n>>).status == 200

    resp = select_object("selectinvalidutf8", "data.csv", @select_xml)

    assert resp.status == 400
    assert resp.resp_body =~ "<Code>InvalidTextEncoding</Code>"
    assert resp.resp_body =~ "Only UTF-8 encoding is supported"
  end

  test "anonymous SelectObjectContent is rejected even when GetObject is public" do
    assert create_bucket("selectpublic").status == 200
    assert put_object("selectpublic", "data.csv", "a,b\n").status == 200

    policy =
      ~s({"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":"*","Action":"s3:GetObject","Resource":"arn:aws:s3:::selectpublic/*"}]})

    assert (SigV4Request.signed_conn(:put, "/selectpublic",
              query: %{"policy" => ""},
              body: policy,
              headers: [{"content-type", "application/json"}]
            )
            |> call()).status in [200, 204]

    resp =
      SigV4Request.anon_conn(:post, "/selectpublic/data.csv",
        query: %{"select" => "", "select-type" => "2"},
        body: @select_xml,
        headers: [{"content-type", "application/xml"}]
      )
      |> call()

    assert resp.status == 403
    assert resp.resp_body =~ "<Code>AccessDenied</Code>"
  end

  test "Requester Pays SelectObjectContent requires signed or query payer for non-owner" do
    bucket = "selectrequesterpays"
    key = "data.csv"

    assert create_bucket(bucket).status == 200
    assert put_object(bucket, key, "a,b\n").status == 200
    assert put_request_payment(bucket).status == 200
    assert :ok = allow_alice_get_object(bucket)

    missing = alice_select_object(bucket, key, @select_xml)

    assert_xml_error(missing, 403, "AccessDenied")
    refute_charged(missing)

    signed_header =
      alice_select_object(bucket, key, @select_xml,
        headers: [{"x-amz-request-payer", "requester"}]
      )

    assert_select_ok(signed_header, "a,b\n")
    assert_charged(signed_header)

    query_payer =
      alice_select_object(bucket, key, @select_xml,
        query: %{"x-amz-request-payer" => "requester"}
      )

    assert_select_ok(query_payer, "a,b\n")
    assert_charged(query_payer)

    invalid_signed =
      alice_select_object(bucket, key, @select_xml, headers: [{"x-amz-request-payer", "owner"}])

    assert_xml_error(invalid_signed, 403, "AccessDenied")
    refute_charged(invalid_signed)

    unsigned_header =
      bucket
      |> signed_select_conn(key, @select_xml, access_key: @alice_ak, secret: @alice_secret)
      |> put_req_header("x-amz-request-payer", "requester")
      |> call()

    assert_xml_error(unsigned_header, 403, "AccessDenied")
    refute_charged(unsigned_header)
  end

  test "Requester Pays SelectObjectContent does not charge bucket owner" do
    bucket = "selectownerrequester"
    key = "data.csv"

    assert create_bucket(bucket).status == 200
    assert put_object(bucket, key, "owner,bypass\n").status == 200
    assert put_request_payment(bucket).status == 200

    resp = select_object(bucket, key, @select_xml)

    assert_select_ok(resp, "owner,bypass\n")
    refute_charged(resp)
  end

  test "SelectObjectContent enforces expected bucket owner before streaming" do
    bucket = "selectexpectedowner"
    key = "data.csv"

    assert create_bucket(bucket).status == 200
    assert put_object(bucket, key, "a,b\n").status == 200

    wrong_owner =
      select_object(bucket, key, @select_xml,
        headers: [{"x-amz-expected-bucket-owner", @other_owner}]
      )

    assert_xml_error(wrong_owner, 403, "AccessDenied")

    correct_owner =
      select_object(bucket, key, @select_xml, headers: [{"x-amz-expected-bucket-owner", @owner}])

    assert_select_ok(correct_owner, "a,b\n")
  end

  test "missing select-type=2 is rejected as invalid argument" do
    assert create_bucket("selecttype").status == 200
    assert put_object("selecttype", "data.csv", "a,b\n").status == 200

    resp =
      SigV4Request.signed_conn(:post, "/selecttype/data.csv",
        query: %{"select" => ""},
        body: @select_xml,
        headers: [{"content-type", "application/xml"}]
      )
      |> call()

    assert resp.status == 400
    assert resp.resp_body =~ "<Code>InvalidArgument</Code>"
  end

  test "versionId is rejected for SelectObjectContent" do
    assert create_bucket("selectversion").status == 200
    assert put_object("selectversion", "data.csv", "a,b\n").status == 200

    resp =
      SigV4Request.signed_conn(:post, "/selectversion/data.csv",
        query: %{"select" => "", "select-type" => "2", "versionId" => "null"},
        body: @select_xml,
        headers: [{"content-type", "application/xml"}]
      )
      |> call()

    assert resp.status == 400
    assert resp.resp_body =~ "<Code>InvalidArgument</Code>"
    assert resp.resp_body =~ "versionId is not supported"
  end

  defp create_bucket(bucket), do: SigV4Request.signed_conn(:put, "/#{bucket}") |> call()

  defp put_request_payment(bucket) do
    SigV4Request.signed_conn(:put, "/#{bucket}",
      query: %{"requestPayment" => ""},
      body: @requester,
      headers: [{"content-md5", content_md5(@requester)}]
    )
    |> call()
  end

  defp allow_alice_get_object(bucket) do
    policy =
      Jason.encode!(%{
        "Version" => "2012-10-17",
        "Statement" => [
          %{
            "Effect" => "Allow",
            "Action" => "s3:GetObject",
            "Resource" => "arn:aws:s3:::#{bucket}/*"
          }
        ]
      })

    Store.put_principal_policy(@alice_arn, "select-get-#{bucket}", policy)
  end

  defp put_object(bucket, key, body, headers \\ []) do
    SigV4Request.signed_conn(:put, "/#{bucket}/#{key}",
      body: body,
      headers: [{"content-type", "text/csv"} | headers]
    )
    |> call()
  end

  defp delete_object(bucket, key) do
    SigV4Request.signed_conn(:delete, "/#{bucket}/#{key}") |> call()
  end

  defp enable_versioning(bucket) do
    SigV4Request.signed_conn(:put, "/#{bucket}",
      query: %{"versioning" => ""},
      body: "<VersioningConfiguration><Status>Enabled</Status></VersioningConfiguration>"
    )
    |> call()
  end

  defp alice_select_object(bucket, key, xml, opts \\ []) do
    opts = Keyword.merge([access_key: @alice_ak, secret: @alice_secret], opts)
    select_object(bucket, key, xml, opts)
  end

  defp select_object(bucket, key, xml, opts \\ []) do
    bucket
    |> signed_select_conn(key, xml, opts)
    |> call()
  end

  defp signed_select_conn(bucket, key, xml, opts) do
    query = Map.merge(%{"select" => "", "select-type" => "2"}, Keyword.get(opts, :query, %{}))
    headers = [{"content-type", "application/xml"} | Keyword.get(opts, :headers, [])]

    signed_opts =
      [query: query, body: xml, headers: headers]
      |> Keyword.merge(
        Keyword.take(opts, [:access_key, :secret, :session_token, :content_sha256_override])
      )

    SigV4Request.signed_conn(:post, "/#{bucket}/#{key}", signed_opts)
  end

  defp content_md5(body), do: :crypto.hash(:md5, body) |> Base.encode64()

  defp assert_select_ok(resp, records) do
    assert resp.status == 200
    assert get_resp_header(resp, "content-type") == ["application/vnd.amazon.eventstream"]
    assert records_payload(resp) == records
  end

  defp assert_xml_error(resp, status, code) do
    assert resp.status == status
    assert get_resp_header(resp, "content-type") |> Enum.join(";") =~ "application/xml"
    assert resp.resp_body =~ "<Code>#{code}</Code>"
    refute get_resp_header(resp, "content-type") == ["application/vnd.amazon.eventstream"]
  end

  defp assert_charged(resp),
    do: assert(get_resp_header(resp, "x-amz-request-charged") == ["requester"])

  defp refute_charged(resp), do: assert(get_resp_header(resp, "x-amz-request-charged") == [])

  defp overwrite_backend_part!(bucket, key, body) do
    {:ok, rel} = Maxio.Cluster.Paths.object_rel(bucket, key, "null")

    [@data_dir, rel, "part.0"]
    |> Path.join()
    |> File.write!(body)
  end

  defp select_xml(
         expression,
         input_csv_options \\ "",
         output_csv_options \\ "",
         scan_range_xml \\ ""
       ) do
    """
    <SelectObjectContentRequest xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
      <Expression>#{expression}</Expression>
      <ExpressionType>SQL</ExpressionType>
      <InputSerialization><CSV>#{input_csv_options}</CSV></InputSerialization>
      <OutputSerialization><CSV>#{output_csv_options}</CSV></OutputSerialization>
      #{scan_range_xml}
    </SelectObjectContentRequest>
    """
  end

  defp select_csv_to_json_xml(
         expression,
         input_csv_options \\ "",
         output_json_options \\ "",
         scan_range_xml \\ ""
       ) do
    """
    <SelectObjectContentRequest xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
      <Expression>#{expression}</Expression>
      <ExpressionType>SQL</ExpressionType>
      <InputSerialization><CSV>#{input_csv_options}</CSV></InputSerialization>
      <OutputSerialization><JSON>#{output_json_options}</JSON></OutputSerialization>
      #{scan_range_xml}
    </SelectObjectContentRequest>
    """
  end

  defp select_gzip_xml(
         expression,
         input_csv_options \\ "",
         output_csv_options \\ "",
         scan_range_xml \\ ""
       ) do
    select_compressed_xml(
      expression,
      "GZIP",
      input_csv_options,
      output_csv_options,
      scan_range_xml
    )
  end

  defp select_compressed_xml(
         expression,
         compression_type,
         input_csv_options \\ "",
         output_csv_options \\ "",
         scan_range_xml \\ ""
       ) do
    """
    <SelectObjectContentRequest xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
      <Expression>#{expression}</Expression>
      <ExpressionType>SQL</ExpressionType>
      <InputSerialization>
        <CompressionType>#{compression_type}</CompressionType>
        <CSV>#{input_csv_options}</CSV>
      </InputSerialization>
      <OutputSerialization><CSV>#{output_csv_options}</CSV></OutputSerialization>
      #{scan_range_xml}
    </SelectObjectContentRequest>
    """
  end

  defp select_json_xml(
         expression,
         input_json_options \\ "<Type>LINES</Type>",
         output_json_options \\ "",
         scan_range_xml \\ ""
       ) do
    """
    <SelectObjectContentRequest xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
      <Expression>#{expression}</Expression>
      <ExpressionType>SQL</ExpressionType>
      <InputSerialization><JSON>#{input_json_options}</JSON></InputSerialization>
      <OutputSerialization><JSON>#{output_json_options}</JSON></OutputSerialization>
      #{scan_range_xml}
    </SelectObjectContentRequest>
    """
  end

  defp select_json_to_csv_xml(
         expression,
         input_json_options \\ "<Type>LINES</Type>",
         output_csv_options \\ "",
         scan_range_xml \\ ""
       ) do
    """
    <SelectObjectContentRequest xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
      <Expression>#{expression}</Expression>
      <ExpressionType>SQL</ExpressionType>
      <InputSerialization><JSON>#{input_json_options}</JSON></InputSerialization>
      <OutputSerialization><CSV>#{output_csv_options}</CSV></OutputSerialization>
      #{scan_range_xml}
    </SelectObjectContentRequest>
    """
  end

  defp select_gzip_json_xml(
         expression,
         input_json_options \\ "<Type>LINES</Type>",
         output_json_options \\ "",
         scan_range_xml \\ ""
       ) do
    """
    <SelectObjectContentRequest xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
      <Expression>#{expression}</Expression>
      <ExpressionType>SQL</ExpressionType>
      <InputSerialization>
        <CompressionType>GZIP</CompressionType>
        <JSON>#{input_json_options}</JSON>
      </InputSerialization>
      <OutputSerialization><JSON>#{output_json_options}</JSON></OutputSerialization>
      #{scan_range_xml}
    </SelectObjectContentRequest>
    """
  end

  defp records_payload(resp) do
    resp.resp_body
    |> decode_events()
    |> Enum.find(&(&1.headers[":event-type"] == "Records"))
    |> Map.fetch!(:payload)
  end

  defp records_event?(resp) do
    resp.resp_body
    |> decode_events()
    |> Enum.any?(&(&1.headers[":event-type"] == "Records"))
  end

  defp json_record_payloads(resp, delimiter \\ "\n") do
    resp
    |> records_payload()
    |> String.split(delimiter, trim: true)
    |> Enum.map(&Jason.decode!/1)
  end

  defp call(conn), do: Endpoint.call(conn, Endpoint.init([]))

  defp decode_events(binary), do: decode_events(binary, [])
  defp decode_events("", acc), do: Enum.reverse(acc)

  defp decode_events(<<total::32, headers_len::32, prelude_crc::32, rest::binary>> = binary, acc) do
    assert :erlang.crc32(binary_part(binary, 0, 8)) == prelude_crc
    payload_len = total - 16 - headers_len

    <<headers::binary-size(headers_len), payload::binary-size(payload_len), crc::32,
      tail::binary>> = rest

    assert :erlang.crc32(binary_part(binary, 0, total - 4)) == crc
    decode_events(tail, [%{headers: decode_headers(headers), payload: payload} | acc])
  end

  defp decode_headers(binary), do: decode_headers(binary, %{})
  defp decode_headers("", acc), do: acc

  defp decode_headers(
         <<name_len, name::binary-size(name_len), 7, value_len::16, value::binary-size(value_len),
           rest::binary>>,
         acc
       ) do
    decode_headers(rest, Map.put(acc, name, value))
  end

  defp select_temp_files do
    System.tmp_dir!()
    |> Path.join("maxio_s3_select*")
    |> Path.wildcard()
    |> Enum.sort()
  end
end
