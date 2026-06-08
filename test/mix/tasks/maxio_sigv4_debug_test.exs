defmodule Mix.Tasks.Maxio.Sigv4.DebugTest do
  use ExUnit.Case, async: true

  alias Mix.Tasks.Maxio.Sigv4.Debug

  test "run_debug 用 VECTOR A 参数复算出官方签名" do
    result =
      Debug.run_debug(
        method: "GET",
        path: "/test.txt",
        region: "us-east-1",
        service: "s3",
        secret: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
        date: "20130524T000000Z",
        payload_hash: "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
        header: "host:examplebucket.s3.amazonaws.com",
        header: "range:bytes=0-9",
        header: "x-amz-content-sha256:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
        header: "x-amz-date:20130524T000000Z"
      )

    assert result.signature == "f0e8bdb87c964420e857bd35b5d6ed310bd44f0170aba48dd91039c6036bdb41"
    assert result.string_to_sign =~ "7344ae5b7ee6c3e7e6b0fe0640412a37625d1fbfff95c48bbb2dc43964946972"
    assert result.canonical_request =~ "GET\n/test.txt\n"
  end
end
