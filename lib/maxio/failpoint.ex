defmodule Maxio.Failpoint do
  @moduledoc """
  最小 failpoint 设施（ObjectMutation 协议实现计划 B1）。

  `:persistent_term` 支撑：未 arm 时 `hit/1` 只有一次 persistent_term 读，近零成本，
  生产路径可长期保留挂点。测试/演练用 `arm/2` 注入动作（含真实 Bandit e2e 崩溃注入：
  `:kill_self` 精确杀死命中进程，配合 monitor 同步断言，零 sleep）。

  arm/disarm 只应在测试/演练中调用（persistent_term 写会触发全局扫描，绝不进请求路径）。
  """

  @type action :: :kill_self | {:raise, String.t()} | {:fun, (-> any())}

  @doc "给挂点注入动作；非法动作立即 ArgumentError（绝不静默存入不可执行的注入）。"
  @spec arm(atom(), action()) :: :ok
  def arm(name, action) when is_atom(name) do
    validate_action!(action)
    :persistent_term.put(key(name), action)
  end

  @doc "解除挂点注入；未 arm 时幂等 no-op。"
  @spec disarm(atom()) :: :ok
  def disarm(name) when is_atom(name) do
    _ = :persistent_term.erase(key(name))
    :ok
  end

  @doc """
  命中挂点：未 arm → `:ok`；`:kill_self` → `Process.exit(self(), :kill)`（不可捕获，
  模拟进程硬崩）；`{:raise, message}` → raise RuntimeError；`{:fun, fun}` → 执行后返回 `:ok`。
  """
  @spec hit(atom()) :: :ok
  def hit(name) when is_atom(name) do
    case :persistent_term.get(key(name), :__disarmed__) do
      :__disarmed__ ->
        :ok

      :kill_self ->
        Process.exit(self(), :kill)
        :ok

      {:raise, message} ->
        raise RuntimeError, message

      {:fun, fun} ->
        fun.()
        :ok
    end
  end

  defp validate_action!(:kill_self), do: :ok
  defp validate_action!({:raise, message}) when is_binary(message), do: :ok
  defp validate_action!({:fun, fun}) when is_function(fun, 0), do: :ok

  defp validate_action!(other),
    do: raise(ArgumentError, "invalid failpoint action: #{inspect(other)}")

  defp key(name), do: {__MODULE__, name}
end
