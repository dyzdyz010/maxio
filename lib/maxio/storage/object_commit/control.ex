defmodule Maxio.Storage.ObjectCommit.Control do
  @moduledoc false

  use GenServer

  # 协议 §5：Control 创建时立即持有 staging discard callback（覆盖 owner 在 publisher
  # 注册前死亡的窗口）。discard 只清 staging/tmp、绝不触碰 final 或 durable backup，
  # 因此在任何 rollback 收口（含 guard 拒绝回滚）后都安全执行。
  def start(owner, discard \\ nil)

  def start(owner, discard)
      when is_pid(owner) and (is_nil(discard) or is_function(discard, 0)),
      do: GenServer.start(__MODULE__, {owner, discard})

  def identity do
    24
    |> :crypto.strong_rand_bytes()
    |> Base.url_encode64(padding: false)
  end

  def arm_publisher(control, publisher) when is_pid(publisher) do
    GenServer.call(control, {:arm_publisher, publisher}, :infinity)
  end

  def register(control, identity, rollback, finalize)
      when is_binary(identity) and is_function(rollback, 0) and is_function(finalize, 0) do
    GenServer.call(control, {:register, identity, rollback, finalize}, :infinity)
  end

  def add_rollback(control, callback) when is_function(callback, 0) do
    GenServer.call(control, {:add_rollback, callback}, :infinity)
  end

  # 协议路径（ObjectMutation Phase 1 B5）：rollback 前置守卫。guard 由
  # `Maxio.ObjectMutation.Commit` 构造，内部调 `ObjectMutation.request_rollback/2`
  # （journal CAS）——返回 `:proceed` 才执行 backend restore 等回滚闭包；
  # `{:halt, reason}` 表示 journal 已过 metadata_committed 禁回滚线（或证据不可判），
  # 一律不触碰 final/backup，仅执行 staging discard。最终决定永远由 journal +
  # backend CAS 作出（协议 §5），Control 仅是进程内加速器。
  def arm_rollback_guard(control, guard) when is_function(guard, 0) do
    GenServer.call(control, {:arm_rollback_guard, guard}, :infinity)
  end

  # Called by the publisher worker immediately after metadata/notification
  # commit succeeds and before that worker returns. This closes the ambiguity
  # between a normal worker DOWN caused by success and one caused by a caught
  # metadata exception.
  def mark_committed(control), do: GenServer.call(control, :mark_committed, :infinity)

  def finalize(control), do: terminal_call(control, :finalize)
  def rollback(control), do: terminal_call(control, :rollback)

  @impl true
  def init({owner, discard}) do
    {:ok,
     %{
       owner: owner,
       owner_ref: Process.monitor(owner),
       owner_down?: false,
       publisher: nil,
       publisher_ref: nil,
       registration: nil,
       rollback_callbacks: [],
       rollback_guard: nil,
       discard: discard,
       status: :open
     }}
  end

  @impl true
  def handle_call({:arm_publisher, publisher}, _from, state) do
    state = clear_publisher_monitor(state)

    state =
      if publisher == state.owner do
        %{state | publisher: publisher}
      else
        %{state | publisher: publisher, publisher_ref: Process.monitor(publisher)}
      end

    {:reply, :ok, state}
  end

  def handle_call({:register, identity, rollback, finalize}, _from, %{registration: nil} = state) do
    registration = %{identity: identity, rollback: rollback, finalize: finalize}
    {:reply, :ok, %{state | registration: registration}}
  end

  def handle_call({:register, _identity, _rollback, _finalize}, _from, state) do
    {:reply, {:error, :already_registered}, state}
  end

  def handle_call({:add_rollback, callback}, _from, %{status: :open} = state) do
    {:reply, :ok, %{state | rollback_callbacks: [callback | state.rollback_callbacks]}}
  end

  def handle_call({:add_rollback, _callback}, _from, state) do
    {:reply, {:error, :already_completed}, state}
  end

  def handle_call({:arm_rollback_guard, guard}, _from, %{status: :open} = state) do
    {:reply, :ok, %{state | rollback_guard: guard}}
  end

  def handle_call({:arm_rollback_guard, _guard}, _from, state) do
    {:reply, {:error, :already_completed}, state}
  end

  def handle_call(:mark_committed, _from, %{registration: nil} = state) do
    {:reply, {:error, :not_registered}, state}
  end

  def handle_call(:mark_committed, _from, state) do
    {reply, state} = transition(state, :finalize)
    {:stop, :normal, reply, state}
  end

  def handle_call(:finalize, _from, state) do
    {reply, state} = transition(state, :finalize)
    {:stop, :normal, reply, state}
  end

  def handle_call(:rollback, _from, state) do
    {reply, state} = transition(state, :rollback)
    {:stop, :normal, reply, state}
  end

  @impl true
  def handle_info(
        {:DOWN, ref, :process, _pid, _reason},
        %{owner_ref: ref, publisher_ref: publisher_ref} = state
      )
      when is_reference(publisher_ref) do
    Process.exit(state.publisher, :kill)
    {:noreply, %{state | owner_down?: true}}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{owner_ref: ref} = state) do
    {_reply, state} = transition(state, :rollback)
    {:stop, :normal, state}
  end

  def handle_info(
        {:DOWN, ref, :process, _pid, _reason},
        %{publisher_ref: ref, owner_down?: true} = state
      ) do
    {_reply, state} = transition(state, :rollback)
    {:stop, :normal, state}
  end

  def handle_info(
        {:DOWN, ref, :process, _pid, :normal},
        %{publisher_ref: ref} = state
      ) do
    {:noreply, %{state | publisher: nil, publisher_ref: nil}}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{publisher_ref: ref} = state) do
    {_reply, state} = transition(state, :rollback)
    {:stop, :normal, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp transition(%{status: status} = state, _action)
       when status in [:finalized, :rolled_back],
       do: {:ok, state}

  defp transition(%{registration: nil} = state, :finalize),
    do: {{:error, :not_registered}, state}

  defp transition(%{registration: registration} = state, :finalize) do
    {invoke(registration.finalize), %{state | status: :finalized}}
  end

  defp transition(state, :rollback) do
    case check_rollback_guard(state) do
      :proceed ->
        result = state |> rollback_callbacks() |> invoke_all()
        run_discard(state)
        {result, %{state | status: :rolled_back}}

      {:halt, reason} ->
        # journal 拒绝回滚（metadata_committed 及之后）或证据不可判：绝不触碰
        # final/backup（回滚闭包一律不执行），仅清 staging（安全幂等）。
        run_discard(state)
        {{:error, {:rollback_refused, reason}}, %{state | status: :rolled_back}}
    end
  end

  defp rollback_callbacks(%{registration: nil} = state), do: state.rollback_callbacks

  defp rollback_callbacks(%{registration: registration} = state),
    do: [registration.rollback | state.rollback_callbacks]

  # guard 缺席（非协议路径）→ 维持既有行为直接回滚；guard 异常 → fail-closed halt
  # （无法证明回滚安全就不破坏，收敛交给 recovery 的 journal + backend CAS）。
  defp check_rollback_guard(%{rollback_guard: nil}), do: :proceed

  defp check_rollback_guard(%{rollback_guard: guard}) do
    case guard.() do
      :proceed -> :proceed
      {:halt, reason} -> {:halt, reason}
      other -> {:halt, {:invalid_rollback_guard_result, other}}
    end
  rescue
    error -> {:halt, {:guard_exception, error}}
  catch
    kind, reason -> {:halt, {:guard_catch, kind, reason}}
  end

  # staging discard：仅清 tmp（rename 后目录已消费，rm_rf 幂等），返回值/异常一律吞掉
  # ——discard 绝不影响回滚结果判定。
  defp run_discard(%{discard: nil}), do: :ok

  defp run_discard(%{discard: discard}) do
    _ = discard.()
    :ok
  rescue
    _error -> :ok
  catch
    _kind, _reason -> :ok
  end

  defp invoke_all(callbacks) do
    Enum.reduce(callbacks, :ok, fn callback, acc ->
      case {acc, invoke(callback)} do
        {:ok, :ok} -> :ok
        {:ok, {:error, reason}} -> {:error, reason}
        {{:error, reason}, _later_result} -> {:error, reason}
      end
    end)
  end

  defp invoke(callback) do
    case callback.() do
      :ok -> :ok
      {:error, _reason} = error -> error
      other -> {:error, {:invalid_control_callback_result, other}}
    end
  rescue
    error -> {:error, {:callback_exception, error, __STACKTRACE__}}
  catch
    kind, reason -> {:error, {:callback_catch, kind, reason, __STACKTRACE__}}
  end

  defp terminal_call(control, message) do
    GenServer.call(control, message, :infinity)
  catch
    :exit, _reason -> :ok
  end

  defp clear_publisher_monitor(%{publisher_ref: nil} = state), do: state

  defp clear_publisher_monitor(%{publisher_ref: ref} = state) do
    Process.demonitor(ref, [:flush])
    %{state | publisher: nil, publisher_ref: nil}
  end
end
