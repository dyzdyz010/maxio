defmodule Maxio.S3.ConditionalTest do
  use ExUnit.Case, async: true
  alias Maxio.S3.Conditional

  @etag "9b2cf535f27731c974343645a3985328"
  @lm ~U[2009-10-12 17:50:30Z]

  defp headers(list), do: list

  test "If-Match 命中 → proceed" do
    assert :proceed =
             Conditional.evaluate(
               headers([{"if-match", "\"#{@etag}\""}]),
               %{etag: @etag, last_modified: @lm},
               "GET"
             )
  end

  test "If-Match 不符 → 412" do
    assert {:error, :precondition_failed} =
             Conditional.evaluate(
               headers([{"if-match", "\"other\""}]),
               %{etag: @etag, last_modified: @lm},
               "GET"
             )
  end

  test "If-None-Match 命中（GET）→ 304" do
    assert {:respond, 304} =
             Conditional.evaluate(
               headers([{"if-none-match", "\"#{@etag}\""}]),
               %{etag: @etag, last_modified: @lm},
               "GET"
             )
  end

  test "If-None-Match 命中（PUT，状态变更方法）→ 412" do
    assert {:error, :precondition_failed} =
             Conditional.evaluate(
               headers([{"if-none-match", "\"#{@etag}\""}]),
               %{etag: @etag, last_modified: @lm},
               "PUT"
             )
  end

  test "If-None-Match: * 且对象存在（PUT no-clobber）→ 412" do
    assert {:error, :precondition_failed} =
             Conditional.evaluate(
               headers([{"if-none-match", "*"}]),
               %{etag: @etag, last_modified: @lm},
               "PUT"
             )
  end

  test "If-Match 优先于 If-Unmodified-Since（If-Match true 覆盖）" do
    # 对象在 since 之后被改，但 If-Match 命中 → proceed
    headers = [
      {"if-match", "\"#{@etag}\""},
      {"if-unmodified-since", "Mon, 01 Jan 2001 00:00:00 GMT"}
    ]

    assert :proceed = Conditional.evaluate(headers, %{etag: @etag, last_modified: @lm}, "GET")
  end

  test "If-Unmodified-Since 已修改 → 412" do
    headers = [{"if-unmodified-since", "Mon, 01 Jan 2001 00:00:00 GMT"}]
    assert {:error, :precondition_failed} = Conditional.evaluate(headers, %{etag: @etag, last_modified: @lm}, "GET")
  end

  test "If-Modified-Since 未修改 → 304（GET）" do
    headers = [{"if-modified-since", "Sat, 01 Jan 2050 00:00:00 GMT"}]
    assert {:respond, 304} = Conditional.evaluate(headers, %{etag: @etag, last_modified: @lm}, "GET")
  end

  test "不可解析的日期被忽略（条件不应用）" do
    headers = [{"if-modified-since", "garbage"}]
    assert :proceed = Conditional.evaluate(headers, %{etag: @etag, last_modified: @lm}, "GET")
  end

  test "无条件头 → proceed" do
    assert :proceed = Conditional.evaluate([], %{etag: @etag, last_modified: @lm}, "GET")
  end
end
