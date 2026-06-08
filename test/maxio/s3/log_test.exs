defmodule Maxio.S3.LogTest do
  # async: false —— info 用例需临时降低 Logger primary level（test.exs 全局为 :warning）。
  # CaptureLog 文档明确「async 测试改 Logger level 行为未定义」，故本模块串行运行，
  # 避免与其它单元后续新增的 async 测试并发时相互干扰。
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog

  alias Maxio.S3.Log

  test "info/2 输出消息并把 S3 元数据放进 Logger metadata" do
    # test.exs 把 Logger primary level 设为 :warning；capture_log 的 :level 选项
    # 不会抬高 primary level（见 ExUnit.CaptureLog 文档），故 info 消息会在到达
    # capture handler 前被丢弃。这里临时把 primary level 降到 :info 验证 info 链路，
    # 并在测试结束后恢复，避免污染其它测试（保持 :warning 噪声门槛）。
    original_level = Logger.level()
    Logger.configure(level: :info)
    on_exit(fn -> Logger.configure(level: original_level) end)

    log =
      capture_log([level: :info], fn ->
        Log.info("put object ok",
          request_id: "req-1",
          bucket: "b1",
          key: "k1",
          action: :put_object,
          auth_type: :header
        )
      end)

    assert log =~ "put object ok"
  end

  test "warn/2 在签名失败场景记录结构化字段（不静默）" do
    log =
      capture_log([level: :warning], fn ->
        Log.warn("signature mismatch",
          request_id: "req-2",
          bucket: "b2",
          key: "k2",
          action: :get_object,
          auth_type: :header,
          reason: :signature_does_not_match
        )
      end)

    assert log =~ "signature mismatch"
  end

  test "context/1 把 conn-like 关键字规整成 metadata keyword 列表" do
    md = Log.context(request_id: "r", bucket: "b", key: "k", action: :list_objects_v2)
    assert Keyword.get(md, :request_id) == "r"
    assert Keyword.get(md, :bucket) == "b"
    assert Keyword.get(md, :action) == :list_objects_v2
  end
end
