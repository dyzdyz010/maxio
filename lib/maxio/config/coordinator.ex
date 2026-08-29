defmodule Maxio.Config.Coordinator do
  @moduledoc false

  import Ecto.Query

  alias Maxio.Config.{CorruptValueError, RuntimeConfig, RuntimeConfigAudit, Schema, Store}
  alias Maxio.Cluster.Notify
  alias Maxio.S3.Log

  @advisory_lock_sql "SELECT pg_advisory_xact_lock(1297638214, hashtext($1))"
  @test_env Mix.env() == :test

  @type operation :: {:set, atom(), term()} | {:reset, atom()}

  @spec authoritative_snapshot([{atom(), atom()}], keyword()) ::
          {:ok, map()} | {:error, term()}
  def authoritative_snapshot(paths, opts) when is_list(paths) and is_list(opts) do
    %{repo: repo, schema: schema} = dependencies(opts)

    with {:ok, paths} <- validate_snapshot_paths(paths, schema) do
      rows = load_snapshot_rows(repo, paths)
      rows_by_path = snapshot_row_index(rows, paths)

      {:ok,
       Map.new(paths, fn {subsystem, key} = path ->
         case Map.get(rows_by_path, path) do
           nil ->
             {path,
              %{value: fallback_value!(subsystem, key, schema), source: :fallback, version: nil}}

           row ->
             {path,
              %{
                value: decode_row!(row, subsystem, key, schema),
                source: :runtime,
                version: row.version
              }}
         end
       end)}
    end
  end

  def authoritative_snapshot(paths, _opts),
    do: {:error, {:invalid_authoritative_snapshot_paths, paths}}

  @spec mutate_many([{atom(), [operation()]}], keyword()) ::
          {:ok, map()} | {:error, term()}
  def mutate_many(groups, opts) when is_list(groups) and is_list(opts) do
    dependencies = dependencies(opts)

    with :ok <- validate_batch_only_options(opts),
         {:ok, groups} <- normalize_groups(groups, dependencies.schema),
         {:ok, source} <- validate_source(opts),
         {:ok, expected_versions} <-
           validate_batch_expected_versions(groups, opts, dependencies.schema),
         {:ok, validators} <- validate_batch_validators(groups, opts),
         :ok <- validate_batch_checkpoint(dependencies.checkpoint) do
      case run_mutation_transaction(
             groups,
             source,
             expected_versions,
             validators,
             dependencies,
             opts
           ) do
        {:ok, mutation} -> finish_batch_mutation(mutation, dependencies, opts)
        {:error, reason} -> {:error, reason}
      end
    end
  end

  def mutate_many(groups, _opts), do: {:error, {:invalid_config_mutation_batch, groups}}

  @spec mutate_subsystem(atom(), [operation()], keyword()) ::
          {:ok, map()} | {:error, term()}
  def mutate_subsystem(subsystem, operations, opts)
      when is_atom(subsystem) and is_list(operations) and is_list(opts) do
    with {:ok, batch_opts} <- legacy_batch_options(subsystem, operations, opts) do
      dependencies = dependencies(batch_opts)

      with {:ok, groups} <- normalize_groups([{subsystem, operations}], dependencies.schema),
           {:ok, source} <- validate_source(batch_opts),
           {:ok, expected_versions} <-
             validate_legacy_expected_versions(subsystem, batch_opts, dependencies.schema),
           {:ok, validators} <- validate_batch_validators(groups, batch_opts),
           :ok <- validate_batch_checkpoint(dependencies.checkpoint) do
        case run_mutation_transaction(
               groups,
               source,
               expected_versions,
               validators,
               dependencies,
               batch_opts
             ) do
          {:ok, mutation} ->
            mutation
            |> legacy_result(subsystem)
            |> finish_legacy_mutation(dependencies, opts)

          {:error, reason} ->
            {:error, reason}
        end
      end
    end
  end

  def mutate_subsystem(subsystem, operations, _opts),
    do: {:error, {:invalid_config_mutation, subsystem, operations}}

  defp run_mutation_transaction(
         groups,
         source,
         expected_versions,
         validators,
         dependencies,
         opts
       ) do
    %{repo: repo, schema: schema} = dependencies

    result =
      repo.transaction(fn ->
        Enum.each(groups, fn {subsystem, _operations} ->
          acquire_advisory_lock!(repo, subsystem)
          checkpoint(dependencies, {:after_advisory_lock, subsystem})
        end)

        checkpoint(dependencies, :before_first_row_read)
        {keys_by_subsystem, current_by_path} = lock_and_load_groups(repo, groups, schema)

        with :ok <- check_batch_expected_versions(current_by_path, expected_versions),
             {:ok, plans_by_subsystem} <-
               build_batch_plans(groups, keys_by_subsystem, current_by_path, validators, schema) do
          outcomes =
            persist_batch_plans(repo, plans_by_subsystem, source, opts, schema)

          changed_paths =
            for {subsystem, plans} <- plans_by_subsystem,
                plan <- plans,
                plan.changed?,
                do: {subsystem, plan.key}

          %{
            committed?: true,
            touched_subsystems: Enum.map(groups, &elem(&1, 0)),
            changed_subsystems: changed_paths |> Enum.map(&elem(&1, 0)) |> Enum.uniq(),
            changed_count: length(changed_paths),
            changed_paths: changed_paths,
            outcomes: outcomes
          }
        else
          {:error, reason} -> repo.rollback(reason)
        end
      end)

    result
  end

  # Every Repo facade must expose a real SQL query boundary. Missing that boundary is a programmer
  # error and must fail before checkpoint, runtime reads, or mutations; no environment may silently
  # turn a missing advisory lock into success.
  defp acquire_advisory_lock!(repo, subsystem) do
    cond do
      function_exported?(repo, :query!, 3) ->
        repo.query!(@advisory_lock_sql, [Atom.to_string(subsystem)], [])

      function_exported?(repo, :query!, 2) ->
        repo.query!(@advisory_lock_sql, [Atom.to_string(subsystem)])

      true ->
        raise ArgumentError, "config coordinator repo must expose query!/2 or query!/3"
    end
  end

  defp validate_snapshot_paths(paths, schema) do
    Enum.reduce_while(paths, {:ok, []}, fn
      {subsystem, key} = path, {:ok, acc} when is_atom(subsystem) and is_atom(key) ->
        case schema.fetch(subsystem, key) do
          {:ok, _entry} -> {:cont, {:ok, [path | acc]}}
          {:error, reason} -> {:halt, {:error, reason}}
        end

      path, _acc ->
        {:halt, {:error, {:invalid_authoritative_snapshot_path, path}}}
    end)
    |> case do
      {:ok, valid} ->
        {:ok,
         valid
         |> Enum.uniq()
         |> Enum.sort_by(fn {subsystem, key} ->
           {Atom.to_string(subsystem), Atom.to_string(key)}
         end)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp load_snapshot_rows(_repo, []), do: []

  defp load_snapshot_rows(repo, paths) do
    predicate =
      Enum.reduce(paths, dynamic(false), fn {subsystem, key}, predicate ->
        subsystem_name = Atom.to_string(subsystem)
        key_name = Atom.to_string(key)

        dynamic(
          [row],
          ^predicate or (row.subsystem == ^subsystem_name and row.key == ^key_name)
        )
      end)

    repo.all(
      from row in RuntimeConfig,
        where: ^predicate,
        order_by: [asc: row.subsystem, asc: row.key]
    )
  end

  defp snapshot_row_index(rows, paths) do
    names =
      Map.new(paths, fn {subsystem, key} = path ->
        {{Atom.to_string(subsystem), Atom.to_string(key)}, path}
      end)

    Map.new(rows, fn row ->
      {Map.fetch!(names, {row.subsystem, row.key}), row}
    end)
  end

  defp fallback_value!(subsystem, key, schema) do
    configured = Application.get_env(:maxio, subsystem)

    raw =
      cond do
        is_list(configured) and Keyword.keyword?(configured) -> Keyword.get(configured, key)
        is_map(configured) -> Map.get(configured, key)
        true -> nil
      end

    case schema.cast(subsystem, key, raw) do
      {:ok, value} -> value
      {:error, reason} -> raise CorruptValueError, subsystem: subsystem, key: key, reason: reason
    end
  end

  defp decode_row!(row, subsystem, key, schema) do
    case schema.decode_stored(subsystem, key, row.value) do
      {:ok, value} -> value
      {:error, reason} -> raise CorruptValueError, subsystem: subsystem, key: key, reason: reason
    end
  end

  defp subsystem_keys(schema, subsystem) do
    schema.keys()
    |> Enum.filter(fn {candidate, _key} -> candidate == subsystem end)
    |> Enum.map(&elem(&1, 1))
  end

  defp lock_and_load_groups(repo, groups, schema) do
    subsystems = Enum.map(groups, &elem(&1, 0))

    keys_by_subsystem =
      Map.new(subsystems, fn subsystem ->
        {subsystem, subsystem_keys(schema, subsystem)}
      end)

    paths =
      for subsystem <- subsystems,
          key <- Map.fetch!(keys_by_subsystem, subsystem),
          do: {subsystem, key}

    rows =
      case paths do
        [] ->
          []

        _paths ->
          predicate =
            Enum.reduce(paths, dynamic(false), fn {subsystem, key}, predicate ->
              subsystem_name = Atom.to_string(subsystem)
              key_name = Atom.to_string(key)

              dynamic(
                [row],
                ^predicate or (row.subsystem == ^subsystem_name and row.key == ^key_name)
              )
            end)

          repo.all(
            from row in RuntimeConfig,
              where: ^predicate,
              order_by: [asc: row.subsystem, asc: row.key],
              lock: "FOR UPDATE"
          )
      end

    {keys_by_subsystem, snapshot_row_index(rows, paths)}
  end

  defp normalize_groups(groups, schema) do
    Enum.reduce_while(groups, {:ok, %{}}, fn
      {subsystem, operations}, {:ok, grouped}
      when is_atom(subsystem) and is_list(operations) ->
        with :ok <- validate_empty_group_subsystem(subsystem, operations, schema),
             {:ok, normalized} <- normalize_operations(subsystem, operations, schema) do
          {:cont, {:ok, Map.update(grouped, subsystem, normalized, &(&1 ++ normalized))}}
        else
          {:error, reason} -> {:halt, {:error, reason}}
        end

      group, _acc ->
        {:halt, {:error, {:invalid_config_mutation_group, group}}}
    end)
    |> case do
      {:ok, grouped} ->
        {:ok, Enum.sort_by(grouped, fn {subsystem, _operations} -> Atom.to_string(subsystem) end)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp validate_empty_group_subsystem(subsystem, [], schema) do
    case subsystem_keys(schema, subsystem) do
      [] -> {:error, {:unknown_config_subsystem, subsystem}}
      _registered_keys -> :ok
    end
  end

  defp validate_empty_group_subsystem(_subsystem, _operations, _schema), do: :ok

  defp validate_batch_expected_versions(groups, opts, schema) do
    registered_paths =
      groups
      |> Enum.flat_map(fn {subsystem, _operations} ->
        Enum.map(subsystem_keys(schema, subsystem), &{subsystem, &1})
      end)
      |> MapSet.new()

    validate_expected_versions(registered_paths, opts)
  end

  defp validate_legacy_expected_versions(subsystem, opts, schema) do
    registered_paths =
      schema
      |> subsystem_keys(subsystem)
      |> MapSet.new(&{subsystem, &1})

    validate_expected_versions(registered_paths, opts)
  end

  defp validate_expected_versions(allowed_paths, opts) do
    case Keyword.get(opts, :expected_versions, %{}) do
      expected when is_map(expected) ->
        Enum.reduce_while(expected, {:ok, %{}}, fn
          {{subsystem, key} = path, version}, {:ok, valid}
          when is_atom(subsystem) and is_atom(key) and
                 (is_nil(version) or (is_integer(version) and version >= 0)) ->
            if MapSet.member?(allowed_paths, path) do
              {:cont, {:ok, Map.put(valid, path, version)}}
            else
              {:halt, {:error, {:invalid_expected_versions, expected}}}
            end

          _entry, _acc ->
            {:halt, {:error, {:invalid_expected_versions, expected}}}
        end)

      other ->
        {:error, {:invalid_expected_versions, other}}
    end
  end

  defp validate_batch_validators(groups, opts) do
    touched = groups |> Enum.map(&elem(&1, 0)) |> MapSet.new()

    case Keyword.get(opts, :validators, %{}) do
      validators when is_map(validators) ->
        Enum.reduce_while(validators, {:ok, %{}}, fn
          {subsystem, validator}, {:ok, valid}
          when is_atom(subsystem) and is_function(validator, 1) ->
            if MapSet.member?(touched, subsystem) do
              {:cont, {:ok, Map.put(valid, subsystem, validator)}}
            else
              {:halt, {:error, {:invalid_config_validators, validators}}}
            end

          _entry, _acc ->
            {:halt, {:error, {:invalid_config_validators, validators}}}
        end)

      other ->
        {:error, {:invalid_config_validators, other}}
    end
  end

  defp validate_batch_checkpoint(nil), do: :ok
  defp validate_batch_checkpoint(checkpoint) when is_function(checkpoint, 1), do: :ok
  defp validate_batch_checkpoint(other), do: {:error, {:invalid_config_checkpoint, other}}

  defp validate_batch_only_options(opts) do
    case Enum.find([:expected_version, :validator], &Keyword.has_key?(opts, &1)) do
      nil -> :ok
      legacy_option -> {:error, {:invalid_config_batch_option, legacy_option}}
    end
  end

  defp legacy_batch_options(subsystem, operations, opts) do
    with {:ok, expected_versions} <- legacy_expected_versions(subsystem, operations, opts),
         {:ok, validators} <- legacy_validators(subsystem, opts),
         {:ok, checkpoint} <- legacy_checkpoint(subsystem, Keyword.get(opts, :checkpoint)) do
      {:ok,
       opts
       |> Keyword.delete(:expected_version)
       |> Keyword.delete(:validator)
       |> Keyword.put(:expected_versions, expected_versions)
       |> Keyword.put(:validators, validators)
       |> Keyword.put(:checkpoint, checkpoint)}
    end
  end

  defp legacy_expected_versions(subsystem, operations, opts) do
    case Keyword.fetch(opts, :expected_version) do
      {:ok, version} ->
        case legacy_operation_keys(operations) do
          [key] -> {:ok, %{{subsystem, key} => version}}
          _keys -> {:error, {:invalid_expected_version, version}}
        end

      :error ->
        case Keyword.get(opts, :expected_versions, %{}) do
          expected when is_map(expected) ->
            Enum.reduce_while(expected, {:ok, %{}}, fn
              {key, version}, {:ok, acc} when is_atom(key) ->
                {:cont, {:ok, Map.put(acc, {subsystem, key}, version)}}

              _entry, _acc ->
                {:halt, {:error, {:invalid_expected_versions, expected}}}
            end)

          other ->
            {:error, {:invalid_expected_versions, other}}
        end
    end
  end

  defp legacy_validators(subsystem, opts) do
    case Keyword.get(opts, :validator) do
      nil -> {:ok, %{}}
      validator when is_function(validator, 1) -> {:ok, %{subsystem => validator}}
      other -> {:error, {:invalid_config_validator, other}}
    end
  end

  defp legacy_checkpoint(_subsystem, nil), do: {:ok, nil}

  defp legacy_checkpoint(subsystem, checkpoint) when is_function(checkpoint, 1) do
    {:ok,
     fn
       {:after_advisory_lock, ^subsystem} -> checkpoint.(:after_advisory_lock)
       _batch_only_phase -> :ok
     end}
  end

  defp legacy_checkpoint(_subsystem, other),
    do: {:error, {:invalid_config_checkpoint, other}}

  defp legacy_operation_keys(operations) do
    operations
    |> Enum.flat_map(fn
      {:set, key, _value} when is_atom(key) -> [key]
      {:reset, key} when is_atom(key) -> [key]
      _invalid -> []
    end)
    |> Enum.uniq()
  end

  defp check_batch_expected_versions(current_by_path, expected_versions) do
    expected_versions
    |> Enum.sort_by(fn {{subsystem, key}, _version} ->
      {Atom.to_string(subsystem), Atom.to_string(key)}
    end)
    |> Enum.reduce_while(:ok, fn {path, expected}, :ok ->
      case compare_version(Map.get(current_by_path, path), expected) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp build_batch_plans(
         groups,
         keys_by_subsystem,
         current_by_path,
         validators,
         schema
       ) do
    Enum.reduce_while(groups, {:ok, []}, fn {subsystem, operations}, {:ok, acc} ->
      keys = Map.fetch!(keys_by_subsystem, subsystem)

      current_by_key =
        keys
        |> Enum.reduce(%{}, fn key, rows ->
          case Map.get(current_by_path, {subsystem, key}) do
            nil -> rows
            row -> Map.put(rows, key, row)
          end
        end)

      fallback = fallback_snapshot(subsystem, keys)
      current_typed = decode_current!(current_by_key, subsystem, schema)
      authoritative = Map.merge(fallback, current_typed)
      {candidate, final_operations} = apply_operations(authoritative, fallback, operations)

      case validate_batch_candidate(candidate, Map.get(validators, subsystem)) do
        :ok ->
          plans = plan_diff(keys, current_by_key, current_typed, final_operations)
          {:cont, {:ok, [{subsystem, plans} | acc]}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, plans} -> {:ok, Enum.reverse(plans)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_batch_candidate(_candidate, nil), do: :ok

  defp validate_batch_candidate(candidate, validator) do
    case validator.(candidate) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
      other -> {:error, {:invalid_config_validator_result, other}}
    end
  end

  defp persist_batch_plans(repo, plans_by_subsystem, source, opts, schema) do
    Enum.reduce(plans_by_subsystem, %{}, fn {subsystem, plans}, outcomes ->
      Enum.reduce(plans, outcomes, fn plan, outcomes ->
        if plan.changed?, do: persist_plan(repo, subsystem, plan, source, opts, schema)
        Map.put(outcomes, {subsystem, plan.key}, plan.outcome)
      end)
    end)
  end

  defp legacy_result(mutation, subsystem) do
    %{
      committed?: mutation.committed?,
      subsystem: subsystem,
      changed_count: mutation.changed_count,
      changed_keys: Enum.map(mutation.changed_paths, &elem(&1, 1)),
      outcomes: Map.new(mutation.outcomes, fn {{^subsystem, key}, outcome} -> {key, outcome} end)
    }
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

  defp finish_batch_mutation(%{changed_count: 0} = mutation, _dependencies, _opts) do
    mutation = batch_public_result(mutation)

    {:ok,
     Map.merge(mutation, %{
       local_reload: :not_needed,
       broadcast: :not_needed,
       attention?: false
     })}
  end

  defp finish_batch_mutation(mutation, dependencies, opts) do
    mutation = batch_public_result(mutation)

    local_reload =
      safe_reload(
        dependencies.store,
        dependencies.repo,
        {:write_batch, mutation.changed_paths}
      )

    identity = Store.next_batch_event_identity()

    broadcast =
      safe_broadcast(
        dependencies.notify,
        {:config_changed_batch,
         %{
           origin: identity.origin,
           epoch: identity.epoch,
           subsystems: mutation.changed_subsystems
         }}
      )

    attention? = postcommit_failed?(local_reload) or postcommit_failed?(broadcast)

    attention_record =
      if attention? do
        safe_record_attention(dependencies.store, %{
          subsystems: mutation.changed_subsystems,
          changed_paths: mutation.changed_paths,
          local_reload: local_reload,
          broadcast: broadcast
        })
      else
        :not_needed
      end

    log_batch_changes(mutation, opts)
    log_batch_postcommit(mutation, local_reload, broadcast, attention?, attention_record, opts)

    {:ok,
     Map.merge(mutation, %{
       local_reload: local_reload,
       broadcast: broadcast,
       attention?: attention?
     })}
  end

  defp batch_public_result(mutation) do
    outcomes =
      Map.new(mutation.outcomes, fn {path, outcome} ->
        {path, Map.delete(outcome, :value)}
      end)

    %{mutation | outcomes: outcomes}
  end

  defp finish_legacy_mutation(%{changed_count: 0} = mutation, _dependencies, _opts) do
    {:ok,
     Map.merge(mutation, %{
       local_reload: :not_needed,
       broadcast: :not_needed,
       attention?: false
     })}
  end

  defp finish_legacy_mutation(mutation, dependencies, opts) do
    reason = {:write, mutation.subsystem, mutation.changed_keys}
    local_reload = safe_reload(dependencies.store, dependencies.repo, reason)
    broadcast = safe_broadcast(dependencies.notify, {:config_changed, mutation.subsystem})
    attention? = postcommit_failed?(local_reload) or postcommit_failed?(broadcast)

    attention_record =
      if attention? do
        safe_record_attention(dependencies.store, %{
          subsystem: mutation.subsystem,
          local_reload: local_reload,
          broadcast: broadcast
        })
      else
        :not_needed
      end

    log_changes(mutation, opts)
    log_postcommit(mutation, local_reload, broadcast, attention?, attention_record, opts)

    {:ok,
     Map.merge(mutation, %{
       local_reload: local_reload,
       broadcast: broadcast,
       attention?: attention?
     })}
  end

  defp safe_reload(store, repo, reason) do
    case store.load_all!(repo: repo, reason: reason) do
      %{aggregate: _aggregate, orphan_config_keys: _orphans, subsystems: _subsystems} -> :ok
      _discarded -> {:error, :reload_failed}
    end
  rescue
    _error -> {:error, :reload_failed}
  catch
    _kind, _reason -> {:error, :reload_failed}
  end

  defp safe_broadcast(notify, event) do
    case notify.broadcast_checked(event) do
      :ok -> :ok
      _discarded -> {:error, :broadcast_failed}
    end
  rescue
    _error -> {:error, :broadcast_failed}
  catch
    _kind, _reason -> {:error, :broadcast_failed}
  end

  defp safe_record_attention(store, fields) do
    case store.note_postcommit_attention(fields) do
      :ok -> :ok
      {:error, :unavailable} -> {:error, :recorder_unavailable}
      {:error, :transport} -> {:error, :recorder_transport_failed}
      {:error, {:transport, _discarded}} -> {:error, :recorder_transport_failed}
      {:error, _discarded} -> {:error, :recorder_failed}
      _unexpected -> {:error, :recorder_failed}
    end
  rescue
    _error -> {:error, :recorder_raised}
  catch
    :exit, _reason -> {:error, :recorder_exited}
    _kind, _reason -> {:error, :recorder_failed}
  end

  defp postcommit_failed?({:error, _reason}), do: true
  defp postcommit_failed?(_result), do: false

  defp log_postcommit(_mutation, _local_reload, _broadcast, false, _attention_record, _opts),
    do: :ok

  defp log_postcommit(mutation, local_reload, broadcast, true, attention_record, opts) do
    fields = [
      action: "config_postcommit_attention",
      reason: postcommit_failure_reason(local_reload, broadcast),
      code: "ConfigPostcommitAttention",
      config_subsystem: Atom.to_string(mutation.subsystem),
      config_attention_record: attention_record_metadata(attention_record),
      principal_arn: Keyword.get(opts, :principal_arn),
      access_key_id: Keyword.get(opts, :access_key_id),
      auth_type: Keyword.get(opts, :auth_type),
      request_id: Keyword.get(opts, :request_id)
    ]

    message =
      "runtime config committed but postcommit convergence requires operator attention"

    if postcommit_failed?(local_reload) do
      Log.error(message, fields)
    else
      Log.warn(message, fields)
    end
  end

  defp postcommit_failure_reason({:error, :reload_failed}, {:error, :broadcast_failed}),
    do: :reload_and_broadcast_failed

  defp postcommit_failure_reason({:error, :reload_failed}, _broadcast), do: :reload_failed

  defp postcommit_failure_reason(_local_reload, {:error, :broadcast_failed}),
    do: :broadcast_failed

  defp attention_record_metadata(:ok), do: :ok
  defp attention_record_metadata(:not_needed), do: :not_needed
  defp attention_record_metadata({:error, reason}) when is_atom(reason), do: reason
  defp attention_record_metadata(_unexpected), do: :recorder_failed

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

  defp log_batch_changes(mutation, opts) do
    Enum.each(mutation.changed_paths, fn {subsystem, key} = path ->
      outcome = Map.fetch!(mutation.outcomes, path)

      Log.info("runtime config changed",
        action: "config_#{outcome.operation}",
        config_subsystem: Atom.to_string(subsystem),
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

  defp log_batch_postcommit(_mutation, _local_reload, _broadcast, false, _record, _opts),
    do: :ok

  defp log_batch_postcommit(mutation, local_reload, broadcast, true, record, opts) do
    fields = [
      action: "config_postcommit_attention",
      reason: postcommit_failure_reason(local_reload, broadcast),
      code: "ConfigPostcommitAttention",
      config_subsystems: Enum.map_join(mutation.changed_subsystems, ",", &Atom.to_string/1),
      config_attention_record: attention_record_metadata(record),
      principal_arn: Keyword.get(opts, :principal_arn),
      access_key_id: Keyword.get(opts, :access_key_id),
      auth_type: Keyword.get(opts, :auth_type),
      request_id: Keyword.get(opts, :request_id)
    ]

    message = "runtime config committed but postcommit convergence requires operator attention"

    if postcommit_failed?(local_reload),
      do: Log.error(message, fields),
      else: Log.warn(message, fields)
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
