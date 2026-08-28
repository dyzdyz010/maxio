defmodule Maxio.Test.ConfigPostcommitStore do
  @moduledoc false

  use Agent

  import Ecto.Query

  alias Maxio.Config.{RuntimeConfig, RuntimeConfigAudit, Store}
  alias Maxio.Repo

  def start_link(opts) do
    owner = Keyword.fetch!(opts, :owner)

    Agent.start_link(
      fn ->
        %{
          owner: owner,
          reload_outcome: :ok,
          attention_outcome: :ok,
          reload_calls: [],
          attention_calls: [],
          repo_calls: %{all: 0, one: 0}
        }
      end,
      name: __MODULE__
    )
  end

  def configure(opts) do
    Agent.update(__MODULE__, fn state ->
      state
      |> Map.put(:reload_outcome, Keyword.get(opts, :reload, state.reload_outcome))
      |> Map.put(:attention_outcome, Keyword.get(opts, :attention, state.attention_outcome))
    end)
  end

  def reset_observations do
    Agent.update(__MODULE__, fn state ->
      %{state | reload_calls: [], attention_calls: [], repo_calls: %{all: 0, one: 0}}
    end)
  end

  def observations do
    Agent.get(__MODULE__, fn state ->
      %{
        reload_calls: Enum.reverse(state.reload_calls),
        attention_calls: Enum.reverse(state.attention_calls),
        repo_calls: state.repo_calls
      }
    end)
  end

  def load_all!(opts \\ []) do
    evidence = commit_evidence()

    {owner, outcome} =
      Agent.get_and_update(__MODULE__, fn state ->
        call = %{opts: opts, commit: evidence}

        {{state.owner, state.reload_outcome},
         %{state | reload_calls: [call | state.reload_calls]}}
      end)

    send(owner, {:config_postcommit_dependency, :reload, evidence, Keyword.get(opts, :reason)})
    apply_outcome(outcome, fn -> Store.load_all!(opts) end)
  end

  def note_postcommit_attention(fields) do
    {owner, outcome} =
      Agent.get_and_update(__MODULE__, fn state ->
        {{state.owner, state.attention_outcome},
         %{state | attention_calls: [fields | state.attention_calls]}}
      end)

    send(owner, {:config_postcommit_dependency, :attention, fields})
    apply_outcome(outcome, fn -> Store.note_postcommit_attention(fields) end)
  end

  # Repo facade used by Store event tests. The real Repo still performs every query; this facade
  # only counts the aggregate+row pair so the test can prove one full load rather than one message.
  def one(queryable, opts \\ []) do
    record_repo_call(:one)
    Repo.one(queryable, opts)
  end

  def all(queryable, opts \\ []) do
    record_repo_call(:all)
    Repo.all(queryable, opts)
  end

  defp record_repo_call(kind) do
    Agent.update(__MODULE__, fn state ->
      update_in(state, [:repo_calls, kind], &(&1 + 1))
    end)
  end

  defp commit_evidence do
    %{
      transaction_open?: Repo.in_transaction?(),
      runtime_count: Repo.aggregate(RuntimeConfig, :count),
      audit_count: Repo.aggregate(RuntimeConfigAudit, :count),
      runtime_keys:
        Repo.all(
          from row in RuntimeConfig,
            order_by: [asc: row.subsystem, asc: row.key],
            select: {row.subsystem, row.key, row.version}
        )
    }
  end

  defp apply_outcome(:ok, success), do: success.()
  defp apply_outcome({:return, value}, _success), do: value
  defp apply_outcome({:raise, message}, _success), do: raise(RuntimeError, message: message)
  defp apply_outcome({:exit, reason}, _success), do: exit(reason)
end
