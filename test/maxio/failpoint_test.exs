defmodule Maxio.FailpointTest do
  use ExUnit.Case, async: true

  alias Maxio.Failpoint

  defp unique_name, do: :"failpoint_test_#{System.unique_integer([:positive])}"

  test "未 arm 的挂点 hit 为 no-op" do
    assert :ok = Failpoint.hit(unique_name())
  end

  test "{:raise, message} 命中即抛 RuntimeError；disarm 后恢复 no-op" do
    name = unique_name()
    on_exit(fn -> Failpoint.disarm(name) end)

    assert :ok = Failpoint.arm(name, {:raise, "boom"})
    assert_raise RuntimeError, "boom", fn -> Failpoint.hit(name) end

    assert :ok = Failpoint.disarm(name)
    assert :ok = Failpoint.hit(name)
    # disarm 幂等
    assert :ok = Failpoint.disarm(name)
  end

  test "{:fun, fun} 执行注入函数并返回 :ok" do
    name = unique_name()
    on_exit(fn -> Failpoint.disarm(name) end)
    parent = self()

    assert :ok = Failpoint.arm(name, {:fun, fn -> send(parent, {:hit, name}) end})
    assert :ok = Failpoint.hit(name)
    assert_received {:hit, ^name}
  end

  test ":kill_self 精确杀死命中进程（monitor 同步，零 sleep）" do
    name = unique_name()
    on_exit(fn -> Failpoint.disarm(name) end)
    assert :ok = Failpoint.arm(name, :kill_self)

    {pid, ref} =
      spawn_monitor(fn ->
        receive do
          :go -> Failpoint.hit(name)
        end
      end)

    send(pid, :go)
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}
  end

  test "非法 action 立即 ArgumentError（绝不静默存入不可执行注入）" do
    assert_raise ArgumentError, fn -> Failpoint.arm(unique_name(), :bogus) end
    assert_raise ArgumentError, fn -> Failpoint.arm(unique_name(), {:raise, :not_binary}) end
    assert_raise ArgumentError, fn -> Failpoint.arm(unique_name(), {:fun, fn _x -> :ok end}) end
  end

  test "重复 arm 覆盖旧动作" do
    name = unique_name()
    on_exit(fn -> Failpoint.disarm(name) end)

    assert :ok = Failpoint.arm(name, {:raise, "first"})
    assert :ok = Failpoint.arm(name, {:fun, fn -> :ok end})
    assert :ok = Failpoint.hit(name)
  end
end
