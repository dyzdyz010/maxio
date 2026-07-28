defmodule Maxio.Storage.EpochStore.Worker do
  @moduledoc false
  # EpochStore 的串行执行单元：无状态闭包执行器。异常折叠为结构化错误——一个损坏请求
  # 绝不杀死 partition worker（worker 同时串行其他路径的 epoch 操作，铁律 3）。
  use GenServer

  def start_link(arg), do: GenServer.start_link(__MODULE__, arg)

  @impl true
  def init(_arg), do: {:ok, :no_state}

  @impl true
  def handle_call({:run, fun}, _from, state) do
    result =
      try do
        fun.()
      rescue
        error -> {:error, {:epoch_store_exception, Exception.message(error)}}
      catch
        kind, reason -> {:error, {:epoch_store_exception, {kind, reason}}}
      end

    {:reply, result, state}
  end
end
