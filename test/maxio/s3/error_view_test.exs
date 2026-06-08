defmodule Maxio.S3.ErrorViewTest do
  use ExUnit.Case, async: true

  alias Maxio.S3.{Error, ErrorView}

  test "render/1 输出 {status, xml iodata}，含 Code/Message/Resource/RequestId" do
    err = Error.new(:no_such_key, resource: "/b/k", request_id: "req-123")
    {status, iodata} = ErrorView.render(err)
    xml = IO.iodata_to_binary(iodata)

    assert status == 404
    assert xml =~ "<Error>"
    assert xml =~ "<Code>NoSuchKey</Code>"
    assert xml =~ "<Message>The specified key does not exist.</Message>"
    assert xml =~ "<Resource>/b/k</Resource>"
    assert xml =~ "<RequestId>req-123</RequestId>"
  end

  test "render/1 缺 resource/request_id 时省略对应元素" do
    {status, iodata} = ErrorView.render(Error.new(:internal_error))
    xml = IO.iodata_to_binary(iodata)
    assert status == 500
    assert xml =~ "<Code>InternalError</Code>"
    refute xml =~ "<Resource>"
  end
end
