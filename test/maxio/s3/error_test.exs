defmodule Maxio.S3.ErrorTest do
  use ExUnit.Case, async: true

  alias Maxio.S3.Error

  test "new/2 按错误码自动填 HTTP 状态与默认 message" do
    err = Error.new(:no_such_bucket, resource: "/mybucket")
    assert %Error{code: "NoSuchBucket", http_status: 404, resource: "/mybucket"} = err
    assert err.message =~ "does not exist"
  end

  test "new/2 覆盖 message" do
    err = Error.new(:access_denied, message: "custom msg")
    assert err.code == "AccessDenied"
    assert err.http_status == 403
    assert err.message == "custom msg"
  end

  test "代表性错误码状态映射正确（官方核验）" do
    assert Error.new(:no_such_key).http_status == 404
    assert Error.new(:signature_does_not_match).http_status == 403
    assert Error.new(:invalid_access_key_id).http_status == 403
    assert Error.new(:request_time_too_skewed).http_status == 403
    assert Error.new(:bucket_already_owned_by_you).http_status == 409
    assert Error.new(:bucket_not_empty).http_status == 409
    assert Error.new(:invalid_bucket_name).http_status == 400
    assert Error.new(:malformed_xml).http_status == 400
    assert Error.new(:invalid_range).http_status == 416
    assert Error.new(:method_not_allowed).http_status == 405
    assert Error.new(:not_implemented).http_status == 501
    assert Error.new(:internal_error).http_status == 500
    assert Error.new(:authorization_header_malformed).http_status == 400
    assert Error.new(:missing_security_header).http_status == 400
  end

  test "RequestTimeout 与 SlowDown* 均为可重试 503（对齐 MinIO）" do
    rt = Error.new(:request_timeout)
    assert rt.code == "RequestTimeout"
    assert rt.http_status == 503

    assert rt.message ==
             "A timeout occurred while trying to lock a resource, please reduce your request rate"

    sd = Error.new(:slow_down)
    assert sd.code == "SlowDown"
    assert sd.http_status == 503

    sdw = Error.new(:slow_down_write)
    assert sdw.code == "SlowDownWrite"
    assert sdw.http_status == 503

    sdr = Error.new(:slow_down_read)
    assert sdr.code == "SlowDownRead"
    assert sdr.http_status == 503
  end

  test "未知错误码兜底 InternalError 500" do
    err = Error.new(:totally_unknown_code_xyz)
    assert err.code == "InternalError"
    assert err.http_status == 500
  end

  test "Error 是可 raise 的异常（Exception 行为）" do
    assert_raise Error, fn -> raise Error.new(:no_such_key) end
  end
end
