defmodule Maxio.Test.ConfigPostcommitNotify do
  @moduledoc false

  use Agent

  def start_link(opts) do
    owner = Keyword.fetch!(opts, :owner)

    Agent.start_link(
      fn ->
        %{
          owner: owner,
          checked_outcome: :ok,
          legacy_outcome: :ok,
          checked_calls: [],
          legacy_calls: []
        }
      end,
      name: __MODULE__
    )
  end

  def configure(opts) do
    Agent.update(__MODULE__, fn state ->
      state
      |> Map.put(:checked_outcome, Keyword.get(opts, :checked, state.checked_outcome))
      |> Map.put(:legacy_outcome, Keyword.get(opts, :legacy, state.legacy_outcome))
    end)
  end

  def reset_observations do
    Agent.update(__MODULE__, fn state ->
      %{state | checked_calls: [], legacy_calls: []}
    end)
  end

  def observations do
    Agent.get(__MODULE__, fn state ->
      %{
        checked_calls: Enum.reverse(state.checked_calls),
        legacy_calls: Enum.reverse(state.legacy_calls)
      }
    end)
  end

  def broadcast_checked(event), do: dispatch(:checked, event)
  def broadcast(event), do: dispatch(:legacy, event)

  defp dispatch(kind, event) do
    {owner, outcome} =
      Agent.get_and_update(__MODULE__, fn state ->
        calls_key = if kind == :checked, do: :checked_calls, else: :legacy_calls
        outcome_key = if kind == :checked, do: :checked_outcome, else: :legacy_outcome

        {{state.owner, Map.fetch!(state, outcome_key)},
         Map.update!(state, calls_key, &[event | &1])}
      end)

    send(owner, {:config_postcommit_dependency, kind, event})
    apply_outcome(outcome)
  end

  defp apply_outcome(:ok), do: :ok
  defp apply_outcome({:return, value}), do: value
  defp apply_outcome({:raise, message}), do: raise(RuntimeError, message: message)
  defp apply_outcome({:exit, reason}), do: exit(reason)
end
