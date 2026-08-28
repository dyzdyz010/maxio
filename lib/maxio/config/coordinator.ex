defmodule Maxio.Config.Coordinator do
  @moduledoc false

  import Ecto.Query

  alias Maxio.Config.{CorruptValueError, RuntimeConfig, RuntimeConfigAudit, Schema, Store}
  alias Maxio.Cluster.Notify
  alias Maxio.S3.Log

  @advisory_lock_sql "SELECT pg_advisory_xact_lock(1297638214, hashtext($1))"
  @test_env Mix.env() == :test

  @type operation :: {:set, atom(), term()} | {:reset, atom()}

  @spec mutate_subsystem(atom(), [operation()], keyword()) ::
          {:ok, map()} | {:error, term()}
  def mutate_subsystem(subsystem, operations, opts)
      when is_atom(subsystem) and is_list(operations) and is_list(opts) do
    dependencies = dependencies(opts)

    with {:ok, normalized} <- normalize_operations(subsystem, operations, dependencies.schema),
         {:ok, source} <- validate_source(opts) do
      transact(subsystem, normalized, source, dependencies, opts)
    end
  end

  def mutate_subsystem(subsystem, operations, _opts),
    do: {:error, {:invalid_config_mutation, subsystem, operations}}

  defp transact(subsystem, operations, source, dependencies, opts) do
    %{repo: repo, schema: schema} = dependencies

    result =
      repo.transaction(fn ->
        acquire_advisory_lock!(repo, subsystem)
        checkpoint(dependencies, :after_advisory_lock)

        {keys, current_by_key} = lock_and_load_subsystem(repo, subsystem, schema)

        with :ok <- check_expected_versions(current_by_key, opts) do
          fallback = fallback_snapshot(subsystem, keys)
          current_typed = decode_current!(current_by_key, subsystem, schema)
          authoritative = Map.merge(fallback, current_typed)
          {candidate, final_operations} = apply_operations(authoritative, fallback, operations)

          with :ok <- validate_candidate(candidate, opts) do
            plans = plan_diff(keys, current_by_key, current_typed, final_operations)
            outcomes = persist_plans(repo, subsystem, plans, source, opts, schema)
            changed_keys = changed_keys(plans)

            %{
              committed?: true,
              subsystem: subsystem,
              changed_count: length(changed_keys),
              changed_keys: changed_keys,
              outcomes: outcomes
            }
          else
            {:error, reason} -> repo.rollback(reason)
          end
        else
          {:error, reason} -> repo.rollback(reason)
        end
      end)

    case result do
      {:ok, mutation} -> finish_mutation(mutation, dependencies, opts)
      {:error, reason} -> {:error, reason}
    end
  end

  # Tests use two small Repo facades to inject deterministic write failures and the defensive
  # unique-row conflict. Real Ecto repos and the batch failure facade expose query!/3 and always
  # execute this SQL. The legacy conflict facade deliberately has no SQL boundary; only that
  # test-only facade may omit the lock because its transaction is not connected to PostgreSQL.
  defp acquire_advisory_lock!(repo, subsystem) do
    cond do
      function_exported?(repo, :query!, 3) ->
        repo.query!(@advisory_lock_sql, [Atom.to_string(subsystem)], [])

      function_exported?(repo, :query!, 2) ->
        repo.query!(@advisory_lock_sql, [Atom.to_string(subsystem)])

      true ->
        handle_missing_query!()
    end
  end

  if @test_env do
    defp handle_missing_query!, do: :ok
  else
    defp handle_missing_query! do
      raise ArgumentError, "config coordinator repo must expose query!/3"
    end
  end

  defp lock_and_load_subsystem(repo, subsystem, schema) do
    keys = subsystem_keys(schema, subsystem)
    key_names = Enum.map(keys, &Atom.to_string/1)
    name_to_key = Map.new(keys, &{Atom.to_string(&1), &1})
    subsystem_name = Atom.to_string(subsystem)

    rows =
      repo.all(
        from row in RuntimeConfig,
          where: row.subsystem == ^subsystem_name and row.key in ^key_names,
          order_by: [asc: row.key],
          lock: "FOR UPDATE"
      )

    current_by_key = Map.new(rows, fn row -> {Map.fetch!(name_to_key, row.key), row} end)
    {keys, current_by_key}
  end

  defp subsystem_keys(schema, subsystem) do
    schema.keys()
    |> Enum.filter(fn {candidate, _key} -> candidate == subsystem end)
    |> Enum.map(&elem(&1, 1))
  end

  defp normalize_operations(subsystem, operations, schema) do
    Enum.reduce_while(operations, {:ok, []}, fn operation, {:ok, normalized} ->
      case normalize_operation(subsystem, operation, schema) do
        {:ok, typed} -> {:cont, {:ok, [typed | normalized]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, normalized} -> {:ok, Enum.reverse(normalized)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp normalize_operation(subsystem, {:set, key, value}, schema) when is_atom(key) do
    with {:ok, entry} <- schema.fetch(subsystem, key),
         {:ok, casted} <- schema.cast(subsystem, key, value) do
      {:ok, %{kind: :set, key: key, value: casted, entry: entry}}
    end
  end

  defp normalize_operation(subsystem, {:reset, key}, schema) when is_atom(key) do
    with {:ok, entry} <- schema.fetch(subsystem, key) do
      {:ok, %{kind: :reset, key: key, value: nil, entry: entry}}
    end
  end

  defp normalize_operation(subsystem, operation, _schema),
    do: {:error, {:invalid_config_operation, subsystem, operation}}

  defp validate_source(opts) do
    case Keyword.get(opts, :source) do
      source when is_binary(source) ->
        if source in RuntimeConfig.sources() do
          {:ok, source}
        else
          {:error, {:invalid_config_source, source}}
        end

      other ->
        {:error, {:invalid_config_source, inspect(other)}}
    end
  end

  defp check_expected_versions(current_by_key, opts) do
    case Keyword.get(opts, :expected_versions, %{}) do
      expected when is_map(expected) ->
        expected
        |> Enum.sort_by(fn {key, _version} -> to_string(key) end)
        |> Enum.reduce_while(:ok, fn {key, version}, :ok ->
          case compare_version(Map.get(current_by_key, key), version) do
            :ok -> {:cont, :ok}
            {:error, reason} -> {:halt, {:error, reason}}
          end
        end)

      other ->
        {:error, {:invalid_expected_versions, other}}
    end
  end

  defp compare_version(nil, nil), do: :ok
  defp compare_version(%RuntimeConfig{version: version}, version), do: :ok
  defp compare_version(_current, _expected), do: {:error, :config_version_conflict}

  defp fallback_snapshot(subsystem, keys) do
    configured = Application.get_env(:maxio, subsystem)

    Map.new(keys, fn key ->
      value =
        cond do
          is_list(configured) and Keyword.keyword?(configured) -> Keyword.get(configured, key)
          is_map(configured) -> Map.get(configured, key)
          true -> nil
        end

      {key, value}
    end)
  end

  defp decode_current!(current_by_key, subsystem, schema) do
    Map.new(current_by_key, fn {key, row} ->
      case schema.decode_stored(subsystem, key, row.value) do
        {:ok, value} ->
          {key, value}

        {:error, reason} ->
          raise CorruptValueError, subsystem: subsystem, key: key, reason: reason
      end
    end)
  end

  defp apply_operations(authoritative, fallback, operations) do
    Enum.reduce(operations, {authoritative, %{}}, fn operation, {candidate, final} ->
      case operation do
        %{kind: :set, key: key, value: value} ->
          {Map.put(candidate, key, value), Map.put(final, key, operation)}

        %{kind: :reset, key: key} ->
          {Map.put(candidate, key, Map.fetch!(fallback, key)), Map.put(final, key, operation)}
      end
    end)
  end

  defp validate_candidate(candidate, opts) do
    case Keyword.get(opts, :validator) do
      nil ->
        :ok

      validator when is_function(validator, 1) ->
        case validator.(candidate) do
          :ok -> :ok
          {:error, reason} -> {:error, reason}
          other -> {:error, {:invalid_config_validator_result, other}}
        end

      other ->
        {:error, {:invalid_config_validator, other}}
    end
  end

  defp plan_diff(keys, current_by_key, current_typed, final_operations) do
    keys
    |> Enum.filter(&Map.has_key?(final_operations, &1))
    |> Enum.map(fn key ->
      operation = Map.fetch!(final_operations, key)
      current = Map.get(current_by_key, key)
      current_value = Map.get(current_typed, key)
      plan_operation(operation, current, current_value)
    end)
  end

  defp plan_operation(%{kind: :set, value: value} = operation, current, current_value) do
    changed? = is_nil(current) or current_value !== value
    version = if changed?, do: next_version(current), else: current.version

    Map.merge(operation, %{
      changed?: changed?,
      current: current,
      version: version,
      outcome: %{
        operation: :set,
        changed?: changed?,
        version: version,
        value: value,
        applied: operation.entry.apply
      }
    })
  end

  defp plan_operation(%{kind: :reset} = operation, current, _current_value) do
    changed? = not is_nil(current)

    Map.merge(operation, %{
      changed?: changed?,
      current: current,
      version: nil,
      outcome: %{
        operation: :reset,
        changed?: changed?,
        version: nil,
        value: nil,
        applied: operation.entry.apply
      }
    })
  end

  defp next_version(nil), do: 1
  defp next_version(%RuntimeConfig{version: version}), do: version + 1

  defp persist_plans(repo, subsystem, plans, source, opts, schema) do
    Map.new(plans, fn plan ->
      if plan.changed? do
        persist_plan(repo, subsystem, plan, source, opts, schema)
      end

      {plan.key, plan.outcome}
    end)
  end

  defp persist_plan(repo, subsystem, %{kind: :set} = plan, source, opts, schema) do
    stored = schema.encode_stored(plan.value)
    apply_mode = Atom.to_string(plan.entry.apply)

    attrs = %{
      subsystem: Atom.to_string(subsystem),
      key: Atom.to_string(plan.key),
      value: stored,
      previous_value: plan.current && plan.current.value,
      version: plan.version,
      apply_mode: apply_mode,
      updated_by: Keyword.get(opts, :principal_arn),
      source: source
    }

    case (plan.current || %RuntimeConfig{})
         |> RuntimeConfig.changeset(attrs)
         |> repo.insert_or_update() do
      {:ok, _row} ->
        insert_audit!(repo, subsystem, plan.key, "set", %{
          old_value: plan.current && plan.current.value,
          new_value: stored,
          from_version: plan.current && plan.current.version,
          to_version: plan.version,
          apply_mode: apply_mode,
          source: source,
          opts: opts
        })

      {:error, %Ecto.Changeset{} = changeset} ->
        if unique_key_conflict?(changeset) do
          repo.rollback(:config_version_conflict)
        else
          raise Ecto.InvalidChangesetError,
            action: :insert_or_update,
            changeset: changeset
        end
    end
  end

  defp persist_plan(repo, subsystem, %{kind: :reset} = plan, source, opts, _schema) do
    repo.delete!(plan.current)
    apply_mode = Atom.to_string(plan.entry.apply)

    insert_audit!(repo, subsystem, plan.key, "reset", %{
      old_value: plan.current.value,
      new_value: nil,
      from_version: plan.current.version,
      to_version: plan.current.version + 1,
      apply_mode: apply_mode,
      source: source,
      opts: opts
    })
  end

  defp unique_key_conflict?(%Ecto.Changeset{errors: errors}) do
    Enum.any?(errors, fn {_field, {_message, metadata}} ->
      Keyword.get(metadata, :constraint) == :unique
    end)
  end

  defp insert_audit!(repo, subsystem, key, operation, fields) do
    %RuntimeConfigAudit{}
    |> RuntimeConfigAudit.changeset(%{
      subsystem: Atom.to_string(subsystem),
      key: Atom.to_string(key),
      operation: operation,
      old_value: fields.old_value,
      new_value: fields.new_value,
      from_version: fields.from_version,
      to_version: fields.to_version,
      apply_mode: fields.apply_mode,
      principal_arn: Keyword.get(fields.opts, :principal_arn),
      access_key_id: Keyword.get(fields.opts, :access_key_id),
      request_id: Keyword.get(fields.opts, :request_id),
      source: fields.source
    })
    |> repo.insert!()
  end

  defp changed_keys(plans) do
    plans
    |> Enum.filter(& &1.changed?)
    |> Enum.map(& &1.key)
  end

  # Task 4 expands postcommit reporting. This task keeps the established synchronous reload and
  # best-effort notification, but performs each once per committed subsystem batch.
  defp finish_mutation(%{changed_count: 0} = mutation, _dependencies, _opts),
    do: {:ok, mutation}

  defp finish_mutation(mutation, dependencies, opts) do
    reason = {:write, mutation.subsystem, mutation.changed_keys}
    dependencies.store.load_all!(repo: dependencies.repo, reason: reason)

    [first_key | _rest] = mutation.changed_keys
    dependencies.notify.broadcast({:config_changed, mutation.subsystem, first_key})
    log_changes(mutation, opts)

    {:ok, mutation}
  end

  defp log_changes(mutation, opts) do
    Enum.each(mutation.changed_keys, fn key ->
      outcome = Map.fetch!(mutation.outcomes, key)

      Log.info("runtime config changed",
        action: "config_#{outcome.operation}",
        config_subsystem: Atom.to_string(mutation.subsystem),
        config_key: Atom.to_string(key),
        config_version: outcome.version,
        config_apply_mode: Atom.to_string(outcome.applied),
        config_source: Keyword.get(opts, :source),
        principal_arn: Keyword.get(opts, :principal_arn),
        access_key_id: Keyword.get(opts, :access_key_id),
        request_id: Keyword.get(opts, :request_id)
      )
    end)
  end

  defp dependencies(opts) do
    if @test_env do
      %{
        repo: Keyword.get(opts, :repo, Maxio.Repo),
        schema: Keyword.get(opts, :schema, Schema),
        store: Keyword.get(opts, :store, Store),
        notify: Keyword.get(opts, :notify, Notify),
        checkpoint: Keyword.get(opts, :checkpoint)
      }
    else
      %{repo: Maxio.Repo, schema: Schema, store: Store, notify: Notify, checkpoint: nil}
    end
  end

  defp checkpoint(%{checkpoint: nil}, _phase), do: :ok
  defp checkpoint(%{checkpoint: checkpoint}, phase), do: checkpoint.(phase)
end
