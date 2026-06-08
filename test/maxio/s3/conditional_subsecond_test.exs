defmodule Maxio.S3.ConditionalSubsecondTest do
  use ExUnit.Case, async: true
  alias Maxio.S3.Conditional

  test "If-Unmodified-Since 同秒（亚秒被截断）→ proceed 而非 412" do
    lm = ~U[2026-06-08 12:00:00.500000Z]
    headers = [{"if-unmodified-since", "Mon, 08 Jun 2026 12:00:00 GMT"}]
    assert Conditional.evaluate(headers, %{etag: "abc", last_modified: lm}, "PUT") == :proceed
  end

  test "If-Modified-Since 同秒（亚秒被截断）→ 304 而非 proceed（GET）" do
    lm = ~U[2026-06-08 12:00:00.999000Z]
    headers = [{"if-modified-since", "Mon, 08 Jun 2026 12:00:00 GMT"}]
    assert Conditional.evaluate(headers, %{etag: "abc", last_modified: lm}, "GET") == {:respond, 304}
  end
end
