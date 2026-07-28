defmodule Maxio.Storage.PublishedProof do
  @moduledoc """
  已发布对象取证的唯一纯数据契约。

  endpoint observation 与 backend aggregate evidence 是两个严格分离的域。每个 summary
  都携带固定 scope/mode；聚合器先验证完整输入集合，再允许任何 endpoint 投票。持久化
  evidence 只接受本模块可重验的 aggregate sum type，并保持在 Journal 64 KiB 门以下。
  """

  @classes [:unavailable, :mismatch, :corrupt, :fenced, :placement_drift]
  @endpoint_failure_classes [:unavailable, :mismatch, :corrupt, :placement_drift]
  @integrity_classes [:placement_drift, :corrupt, :mismatch]
  @orphan_reasons [:epoch_absent, :older_token]

  @max_endpoints 32
  # 一个 journal wrapper 中 published proof 与 last failure 的 detail 合计上限；初次持久化
  # 成功 proof 只用 31 条，为后续 merge 的强制 witness 预留一条。
  @max_wrapper_details 32
  @max_published_details @max_wrapper_details - 1
  @max_encoded_bytes 60 * 1024
  @max_label_bytes 128
  @identity ~r/\A(?:local|ordinal:(?:0|[1-9][0-9]*))\z/
  @safe_text ~r/\A[a-zA-Z0-9@_.:-]+\z/

  @attrs [:code, :layout, :owned, :phase]
  @endpoint_proof_keys ~w(scope mode endpoint status owned class code layout phase)
  @endpoint_finalize_keys (@endpoint_proof_keys ++
                             ~w(proof_passed finalized orphan_reason))
                          |> Enum.uniq()
  @aggregate_proof_keys ~w(scope mode status required verified observed_owned unavailable degraded omitted debt)
  @aggregate_finalize_keys (@aggregate_proof_keys ++
                              ~w(finalized orphaned orphan_hints orphan_omitted))
                           |> Enum.uniq()

  @proof_required_phases ~w(published metadata_committed finalize_pending finalized)
  @rollback_evidence_phases ~w(rollback_pending rolled_back quarantined)
  @proof_evidence_phases (@proof_required_phases ++ @rollback_evidence_phases) |> Enum.uniq()
  @finalize_failure_phases ~w(metadata_committed finalize_pending finalized quarantined)

  @type proof_class :: :unavailable | :mismatch | :corrupt | :fenced | :placement_drift
  @type endpoint_summary :: %{required(String.t()) => term()}
  @type aggregate_summary :: %{required(String.t()) => term()}
  @type endpoint_finalize_summary :: %{required(String.t()) => term()}
  @type aggregate_finalize_summary :: %{required(String.t()) => term()}

  @type endpoint_proof_result ::
          {:ok, {:verified | :superseded, endpoint_summary()}}
          | {:error, {:published_proof_failed, proof_class(), endpoint_summary()}}

  @type aggregate_proof_result ::
          {:ok, {:verified | :degraded | :superseded, aggregate_summary()}}
          | {:error, {:published_proof_failed, proof_class(), aggregate_summary()}}

  @type endpoint_finalize_result ::
          {:ok,
           {:finalized | :cleanup_pending | :orphan | :superseded, endpoint_finalize_summary()}}
          | {:error, {:published_proof_failed, proof_class(), endpoint_finalize_summary()}}

  @type aggregate_finalize_result ::
          {:ok, {:finalized | :cleanup_pending | :superseded, aggregate_finalize_summary()}}
          | {:error, {:published_proof_failed, proof_class(), aggregate_finalize_summary()}}

  @type proof_result :: endpoint_proof_result() | aggregate_proof_result()
  @type finalize_result :: endpoint_finalize_result() | aggregate_finalize_result()

  @doc "构造单 endpoint 已验证 proof observation。"
  @spec verified(String.t() | non_neg_integer(), map()) :: endpoint_proof_result()
  def verified(identity, attrs \\ %{})

  def verified(identity, attrs) when is_map(attrs) do
    attrs = Map.put(attrs, :owned, true)

    case build_endpoint(identity, :proof, "verified", nil, attrs, %{}) do
      {:ok, summary} -> {:ok, {:verified, summary}}
      {:error, _reason} -> invalid_endpoint_result(:proof)
    end
  end

  def verified(_identity, _attrs), do: invalid_endpoint_result(:proof)

  @doc "构造单 endpoint successor proof observation。"
  @spec superseded(String.t() | non_neg_integer()) :: endpoint_proof_result()
  def superseded(identity) do
    case build_endpoint(identity, :proof, "superseded", :fenced, %{owned: false}, %{}) do
      {:ok, summary} -> {:ok, {:superseded, summary}}
      {:error, _reason} -> invalid_endpoint_result(:proof)
    end
  end

  @doc "构造单 endpoint proof failure。fenced 必须用 superseded/1 表达。"
  @spec failed(proof_class(), String.t() | non_neg_integer(), map()) ::
          endpoint_proof_result()
  def failed(class, identity, attrs \\ %{})

  def failed(class, identity, attrs)
      when class in @endpoint_failure_classes and is_map(attrs) do
    with {:ok, attrs} <- endpoint_failure_attrs(class, attrs),
         {:ok, summary} <- build_endpoint(identity, :proof, "failed", class, attrs, %{}) do
      {:error, {:published_proof_failed, class, summary}}
    else
      _invalid -> invalid_endpoint_result(:proof)
    end
  end

  def failed(_class, _identity, _attrs), do: invalid_endpoint_result(:proof)

  @doc "构造 proof 与 cleanup 均完成的 endpoint finalize observation。"
  @spec endpoint_finalized(String.t() | non_neg_integer(), map()) ::
          endpoint_finalize_result()
  def endpoint_finalized(identity, attrs) when is_map(attrs) do
    extras = %{"proof_passed" => true, "finalized" => true}

    case build_endpoint(
           identity,
           :finalize,
           "finalized",
           nil,
           Map.put(attrs, :owned, true),
           extras
         ) do
      {:ok, summary} -> {:ok, {:finalized, summary}}
      {:error, _reason} -> invalid_endpoint_result(:finalize)
    end
  end

  def endpoint_finalized(_identity, _attrs), do: invalid_endpoint_result(:finalize)

  @doc "构造 proof 已通过但 cleanup 尚欠债的 endpoint finalize observation。"
  @spec endpoint_cleanup_pending(String.t() | non_neg_integer(), map()) ::
          endpoint_finalize_result()
  def endpoint_cleanup_pending(identity, attrs) when is_map(attrs) do
    extras = %{"proof_passed" => true, "finalized" => false}

    case build_endpoint(
           identity,
           :finalize,
           "cleanup_pending",
           nil,
           Map.put(attrs, :owned, true),
           extras
         ) do
      {:ok, summary} -> {:ok, {:cleanup_pending, summary}}
      {:error, _reason} -> invalid_endpoint_result(:finalize)
    end
  end

  def endpoint_cleanup_pending(_identity, _attrs), do: invalid_endpoint_result(:finalize)

  @doc "构造 finalize-only 非破坏性 orphan hint。"
  @spec endpoint_orphan(String.t() | non_neg_integer(), :epoch_absent | :older_token) ::
          endpoint_finalize_result()
  def endpoint_orphan(identity, reason) when reason in @orphan_reasons do
    extras = %{
      "proof_passed" => false,
      "finalized" => false,
      "orphan_reason" => Atom.to_string(reason)
    }

    case build_endpoint(identity, :finalize, "orphan", nil, %{owned: false}, extras) do
      {:ok, summary} -> {:ok, {:orphan, summary}}
      {:error, _reason} -> invalid_endpoint_result(:finalize)
    end
  end

  def endpoint_orphan(_identity, _reason), do: invalid_endpoint_result(:finalize)

  @doc "构造 finalize 阶段的 endpoint successor observation。"
  @spec endpoint_finalize_superseded(String.t() | non_neg_integer()) ::
          endpoint_finalize_result()
  def endpoint_finalize_superseded(identity) do
    extras = %{"proof_passed" => false, "finalized" => false}

    case build_endpoint(
           identity,
           :finalize,
           "superseded",
           :fenced,
           %{owned: false},
           extras
         ) do
      {:ok, summary} -> {:ok, {:superseded, summary}}
      {:error, _reason} -> invalid_endpoint_result(:finalize)
    end
  end

  @doc "构造 finalize 阶段的 endpoint proof failure。fenced 必须用 superseded 表达。"
  @spec endpoint_finalize_failed(
          proof_class(),
          String.t() | non_neg_integer(),
          map()
        ) :: endpoint_finalize_result()
  def endpoint_finalize_failed(class, identity, attrs \\ %{})

  def endpoint_finalize_failed(class, identity, attrs)
      when class in @endpoint_failure_classes and is_map(attrs) do
    extras = %{"proof_passed" => false, "finalized" => false}

    with {:ok, attrs} <- endpoint_failure_attrs(class, attrs),
         {:ok, summary} <- build_endpoint(identity, :finalize, "failed", class, attrs, extras) do
      {:error, {:published_proof_failed, class, summary}}
    else
      _invalid -> invalid_endpoint_result(:finalize)
    end
  end

  def endpoint_finalize_failed(_class, _identity, _attrs),
    do: invalid_endpoint_result(:finalize)

  @doc """
  按冻结顺序裁决 endpoint proof：
  完整结构预检 → successor → placement drift → quorum → potential unavailable →
  owned corrupt → owned mismatch → unavailable。
  """
  @spec classify(
          pos_integer(),
          [{String.t() | non_neg_integer(), endpoint_proof_result()}]
        ) :: aggregate_proof_result()
  def classify(required, results)
      when is_integer(required) and required > 0 and is_list(results) do
    case preflight_observations(results, :proof) do
      {:ok, observations} -> classify_proof_observations(required, observations)
      {:error, identity} -> structural_failure(required, :proof, identity)
    end
  end

  def classify(required, results),
    do: structural_failure(safe_required(required), :proof, first_expected_identity(results))

  @doc "裁决 endpoint finalize observations；orphan 不投票、不计 debt。"
  @spec classify_finalize(
          pos_integer(),
          [{String.t() | non_neg_integer(), endpoint_finalize_result()}]
        ) :: aggregate_finalize_result()
  def classify_finalize(required, results)
      when is_integer(required) and required > 0 and is_list(results) do
    case preflight_observations(results, :finalize) do
      {:ok, observations} -> classify_finalize_observations(required, observations)
      {:error, identity} -> structural_failure(required, :finalize, identity)
    end
  end

  def classify_finalize(required, results),
    do: structural_failure(safe_required(required), :finalize, first_expected_identity(results))

  @doc "构造 phase-aware journal evidence，并执行 sum type/JSON-safe/大小门。"
  @spec journal_evidence(String.t(), map() | nil, map() | nil) ::
          {:ok, map()} | {:error, :invalid_proof_evidence}
  def journal_evidence(target_phase, proof_summary, failure_summary) do
    proof_summary = trim_published_proof(proof_summary)
    failure_summary = trim_last_failure(failure_summary, wrapper_budget(proof_summary))

    evidence = %{
      "published_proof" => proof_summary,
      "last_failure" => failure_summary
    }

    with true <- valid_journal_combination?(target_phase, proof_summary, failure_summary) do
      validate_evidence(evidence)
    else
      false -> {:error, :invalid_proof_evidence}
    end
  end

  @doc "保留初始 aggregate published proof，只按目标 phase 替换 last_failure。"
  @spec merge_failure(String.t(), map(), map() | nil) ::
          {:ok, map()} | {:error, :invalid_proof_evidence}
  def merge_failure(
        target_phase,
        %{"published_proof" => proof_summary, "last_failure" => _old} = evidence,
        failure_summary
      )
      when map_size(evidence) == 2 do
    journal_evidence(target_phase, proof_summary, failure_summary)
  end

  def merge_failure(_target_phase, _evidence, _failure),
    do: {:error, :invalid_proof_evidence}

  @spec proof_class?(term()) :: boolean()
  def proof_class?(class), do: class in @classes

  @spec retryable_class?(term()) :: boolean()
  def retryable_class?(class), do: class in [:unavailable, :fenced]

  @spec integrity_class?(term()) :: boolean()
  def integrity_class?(class), do: class in @integrity_classes

  defp classify_proof_observations(required, observations) do
    cond do
      witness = Enum.find(observations, &(&1.kind == :superseded)) ->
        aggregate_superseded(required, :proof, witness.summary)

      witness = Enum.find(observations, &(&1.class == :placement_drift)) ->
        canonical_failure(:placement_drift, required, :proof, witness.summary)

      true ->
        counts = proof_counts(observations)

        cond do
          counts.verified >= required ->
            status = if counts.debt == 0, do: "verified", else: "degraded"
            outcome = if status == "verified", do: :verified, else: :degraded
            {:ok, {outcome, aggregate_summary(status, required, counts)}}

          counts.verified + counts.unavailable >= required ->
            aggregate_failure(:unavailable, required, :proof, counts)

          owned_class?(observations, :corrupt) ->
            aggregate_failure(:corrupt, required, :proof, counts)

          owned_class?(observations, :mismatch) ->
            aggregate_failure(:mismatch, required, :proof, counts)

          true ->
            aggregate_failure(:unavailable, required, :proof, counts)
        end
    end
  end

  defp classify_finalize_observations(required, observations) do
    cond do
      witness = Enum.find(observations, &(&1.kind == :superseded)) ->
        aggregate_superseded(required, :finalize, witness.summary)

      witness = Enum.find(observations, &(&1.class == :placement_drift)) ->
        canonical_failure(:placement_drift, required, :finalize, witness.summary)

      true ->
        counts = finalize_counts(observations)

        cond do
          counts.verified >= required ->
            if counts.finalized >= required and counts.debt == 0 and
                 counts.unavailable == 0 do
              {:ok, {:finalized, finalize_summary("finalized", required, counts)}}
            else
              {:ok, {:cleanup_pending, finalize_summary("cleanup_pending", required, counts)}}
            end

          counts.verified + counts.unavailable >= required ->
            aggregate_failure(:unavailable, required, :finalize, counts)

          owned_class?(observations, :corrupt) ->
            aggregate_failure(:corrupt, required, :finalize, counts)

          owned_class?(observations, :mismatch) ->
            aggregate_failure(:mismatch, required, :finalize, counts)

          true ->
            aggregate_failure(:unavailable, required, :finalize, counts)
        end
    end
  end

  defp preflight_observations(results, mode) do
    result =
      Enum.reduce_while(results, {:ok, []}, fn
        {expected_identity, endpoint_result}, {:ok, pairs} ->
          with {:ok, expected} <- normalize_identity(expected_identity),
               {:ok, observation} <- decode_observation(endpoint_result, mode),
               true <- observation.identity == expected do
            {:cont, {:ok, [{expected, observation} | pairs]}}
          else
            _invalid -> {:halt, {:error, safe_identity(expected_identity)}}
          end

        _invalid, _acc ->
          {:halt, {:error, "local"}}
      end)

    case result do
      {:ok, reversed} ->
        pairs = Enum.reverse(reversed)
        identities = Enum.map(pairs, &elem(&1, 0))

        case duplicate_identity(identities) do
          nil -> {:ok, Enum.map(pairs, &elem(&1, 1))}
          identity -> {:error, identity}
        end

      {:error, identity} ->
        {:error, identity}
    end
  end

  defp duplicate_identity(identities) do
    identities
    |> Enum.frequencies()
    |> Enum.find_value(fn
      {identity, count} when count > 1 -> identity
      _entry -> nil
    end)
  end

  defp decode_observation({:ok, {:verified, summary}}, :proof) do
    if valid_verified_endpoint?(summary),
      do: {:ok, observation(summary, :verified, true, true, false, nil)},
      else: :error
  end

  defp decode_observation({:ok, {:superseded, summary}}, :proof) do
    if valid_superseded_endpoint?(summary, :proof),
      do: {:ok, observation(summary, :superseded, false, false, false, :fenced)},
      else: :error
  end

  defp decode_observation({:ok, {:finalized, summary}}, :finalize) do
    if valid_finalized_endpoint?(summary),
      do: {:ok, observation(summary, :finalized, true, true, true, nil)},
      else: :error
  end

  defp decode_observation({:ok, {:cleanup_pending, summary}}, :finalize) do
    if valid_cleanup_endpoint?(summary),
      do: {:ok, observation(summary, :cleanup_pending, true, true, false, nil)},
      else: :error
  end

  defp decode_observation({:ok, {:orphan, summary}}, :finalize) do
    if valid_orphan_endpoint?(summary),
      do: {:ok, observation(summary, :orphan, false, false, false, nil)},
      else: :error
  end

  defp decode_observation({:ok, {:superseded, summary}}, :finalize) do
    if valid_superseded_endpoint?(summary, :finalize),
      do: {:ok, observation(summary, :superseded, false, false, false, :fenced)},
      else: :error
  end

  defp decode_observation(
         {:error, {:published_proof_failed, class, summary}},
         mode
       )
       when class in @endpoint_failure_classes and mode in [:proof, :finalize] do
    if valid_failed_endpoint?(summary, class, mode),
      do: {:ok, observation(summary, :failed, summary["owned"], false, false, class)},
      else: :error
  end

  defp decode_observation(_result, _mode), do: :error

  defp observation(summary, kind, owned?, proof_passed?, finalized?, class) do
    %{
      identity: summary["endpoint"],
      summary: summary,
      kind: kind,
      owned: owned?,
      proof_passed?: proof_passed?,
      finalized?: finalized?,
      class: class
    }
  end

  defp proof_counts(observations) do
    details = Enum.reject(observations, &(&1.kind == :verified))

    %{
      verified: Enum.count(observations, &(&1.kind == :verified)),
      finalized: 0,
      observed_owned: Enum.count(observations, & &1.owned),
      unavailable: Enum.count(observations, &(&1.class == :unavailable)),
      debt: length(details),
      details: Enum.map(details, & &1.summary),
      orphans: [],
      orphaned: 0
    }
  end

  defp finalize_counts(observations) do
    details = Enum.reject(observations, &(&1.kind in [:finalized, :orphan]))
    orphans = Enum.filter(observations, &(&1.kind == :orphan))

    %{
      verified: Enum.count(observations, & &1.proof_passed?),
      finalized: Enum.count(observations, & &1.finalized?),
      observed_owned: Enum.count(observations, & &1.owned),
      unavailable: Enum.count(observations, &(&1.class == :unavailable)),
      debt: length(details),
      details: Enum.map(details, & &1.summary),
      orphans: Enum.map(orphans, & &1.summary),
      orphaned: length(orphans)
    }
  end

  defp owned_class?(observations, class) do
    Enum.any?(observations, &(&1.class == class and &1.owned))
  end

  defp aggregate_failure(class, required, mode, counts) do
    counts = %{counts | details: prioritize_failure_witness(counts.details, class)}

    summary =
      case mode do
        :proof -> aggregate_summary("failed", required, counts)
        :finalize -> finalize_summary("failed", required, counts)
      end
      |> Map.put("class", Atom.to_string(class))

    {:error, {:published_proof_failed, class, summary}}
  end

  defp canonical_failure(class, required, mode, witness) do
    counts = zero_counts([witness])
    aggregate_failure(class, required, mode, counts)
  end

  defp structural_failure(required, mode, identity) do
    witness =
      internal_endpoint(
        safe_identity(identity),
        mode,
        "failed",
        :placement_drift,
        false,
        %{code: :invalid_evidence},
        finalize_failure_extras(mode)
      )

    canonical_failure(:placement_drift, required, mode, witness)
  end

  defp aggregate_superseded(required, mode, witness) do
    counts = zero_counts([witness])

    summary =
      case mode do
        :proof -> aggregate_summary("superseded", required, counts)
        :finalize -> finalize_summary("superseded", required, counts)
      end

    {:ok, {:superseded, summary}}
  end

  defp zero_counts(details) do
    %{
      verified: 0,
      finalized: 0,
      observed_owned: 0,
      unavailable: 0,
      debt: length(details),
      details: details,
      orphans: [],
      orphaned: 0
    }
  end

  defp prioritize_failure_witness(details, class)
       when class in [:placement_drift, :corrupt, :mismatch] do
    move_first(details, fn detail ->
      detail["status"] == "failed" and detail["class"] == Atom.to_string(class) and
        (class == :placement_drift or detail["owned"] == true)
    end)
  end

  defp prioritize_failure_witness(details, _class), do: details

  defp move_first(details, predicate) do
    case Enum.split_while(details, &(not predicate.(&1))) do
      {_prefix, []} ->
        details

      {prefix, [witness | suffix]} ->
        [witness | prefix ++ suffix]
    end
  end

  defp aggregate_summary(status, required, counts) do
    {degraded, omitted} = bounded_details(counts.details, @max_endpoints)

    %{
      "scope" => "aggregate",
      "mode" => "proof",
      "status" => status,
      "required" => required,
      "verified" => counts.verified,
      "observed_owned" => counts.observed_owned,
      "unavailable" => counts.unavailable,
      "degraded" => degraded,
      "omitted" => omitted,
      "debt" => counts.debt
    }
  end

  defp finalize_summary(status, required, counts) do
    {degraded, omitted} = bounded_details(counts.details, @max_endpoints)
    remaining = @max_endpoints - length(degraded)
    {orphan_hints, orphan_omitted} = bounded_details(counts.orphans, remaining)

    %{
      "scope" => "aggregate",
      "mode" => "finalize",
      "status" => status,
      "required" => required,
      "verified" => counts.verified,
      "finalized" => counts.finalized,
      "observed_owned" => counts.observed_owned,
      "unavailable" => counts.unavailable,
      "degraded" => degraded,
      "omitted" => omitted,
      "debt" => counts.debt,
      "orphaned" => counts.orphaned,
      "orphan_hints" => orphan_hints,
      "orphan_omitted" => orphan_omitted
    }
  end

  defp bounded_details(details, limit) do
    bounded = Enum.take(details, limit)
    {bounded, max(length(details) - length(bounded), 0)}
  end

  defp build_endpoint(identity, mode, status, class, attrs, extras)
       when mode in [:proof, :finalize] and is_map(attrs) and is_map(extras) do
    with {:ok, identity} <- normalize_identity(identity),
         :ok <- validate_attrs(attrs),
         {:ok, code} <- optional_safe_text(attrs, :code),
         {:ok, layout} <- optional_safe_text(attrs, :layout),
         {:ok, phase} <- optional_safe_text(attrs, :phase) do
      {:ok,
       internal_endpoint(
         identity,
         mode,
         status,
         class,
         Map.fetch!(attrs, :owned),
         %{code: code, layout: layout, phase: phase},
         extras
       )}
    else
      _invalid -> {:error, :invalid_proof_evidence}
    end
  end

  defp build_endpoint(_identity, _mode, _status, _class, _attrs, _extras),
    do: {:error, :invalid_proof_evidence}

  defp internal_endpoint(identity, mode, status, class, owned, attrs, extras) do
    %{
      "scope" => "endpoint",
      "mode" => Atom.to_string(mode),
      "endpoint" => identity,
      "status" => status,
      "owned" => owned
    }
    |> maybe_put("class", if(class, do: Atom.to_string(class), else: nil))
    |> maybe_put("code", safe_attr(attrs, :code))
    |> maybe_put("layout", safe_attr(attrs, :layout))
    |> maybe_put("phase", safe_attr(attrs, :phase))
    |> Map.merge(extras)
  end

  defp finalize_failure_extras(:proof), do: %{}
  defp finalize_failure_extras(:finalize), do: %{"proof_passed" => false, "finalized" => false}

  defp safe_attr(attrs, key) do
    case Map.get(attrs, key) do
      nil -> nil
      value when is_atom(value) -> Atom.to_string(value)
      value -> value
    end
  end

  # placement drift 永远是结构性裁决，绝不是 owned-token 事实：owned drift 既不能由 public
  # constructor 产生，也不能作为 canonical aggregate 的 witness 被保留。
  defp endpoint_failure_attrs(class, attrs) do
    attrs = Map.put_new(attrs, :owned, false)

    if class == :placement_drift and Map.get(attrs, :owned) != false,
      do: :error,
      else: {:ok, attrs}
  end

  defp validate_attrs(attrs) do
    if Enum.all?(Map.keys(attrs), &(&1 in @attrs)) and
         Map.has_key?(attrs, :owned) and is_boolean(attrs.owned) do
      :ok
    else
      {:error, :invalid_proof_evidence}
    end
  end

  defp optional_safe_text(attrs, key) do
    case Map.get(attrs, key) do
      nil -> {:ok, nil}
      value when is_atom(value) -> validate_safe_text(Atom.to_string(value))
      value when is_binary(value) -> validate_safe_text(value)
      _invalid -> {:error, :invalid_proof_evidence}
    end
  end

  defp validate_safe_text(value) do
    if byte_size(value) in 1..@max_label_bytes and Regex.match?(@safe_text, value),
      do: {:ok, value},
      else: {:error, :invalid_proof_evidence}
  end

  defp normalize_identity(value) when is_integer(value) and value >= 0 do
    normalize_identity("ordinal:" <> Integer.to_string(value))
  end

  defp normalize_identity(value) when is_binary(value) do
    if byte_size(value) in 1..@max_label_bytes and Regex.match?(@identity, value),
      do: {:ok, value},
      else: {:error, :invalid_identity}
  end

  defp normalize_identity(_value), do: {:error, :invalid_identity}

  defp safe_identity(value) do
    case normalize_identity(value) do
      {:ok, identity} -> identity
      {:error, _reason} -> "local"
    end
  end

  defp first_expected_identity(results) when is_list(results) do
    case results do
      [{identity, _result} | _rest] -> safe_identity(identity)
      _other -> "local"
    end
  end

  defp first_expected_identity(_results), do: "local"
  defp safe_required(required) when is_integer(required) and required > 0, do: required
  defp safe_required(_required), do: 1

  defp invalid_endpoint_result(mode) do
    summary =
      internal_endpoint(
        "local",
        mode,
        "failed",
        :placement_drift,
        false,
        %{code: :invalid_evidence},
        finalize_failure_extras(mode)
      )

    {:error, {:published_proof_failed, :placement_drift, summary}}
  end

  defp valid_verified_endpoint?(summary) do
    endpoint_shape?(summary, @endpoint_proof_keys, :proof) and
      summary["status"] == "verified" and summary["owned"] == true and
      not Map.has_key?(summary, "class")
  end

  defp valid_failed_endpoint?(summary, class, mode)
       when class in @endpoint_failure_classes and mode in [:proof, :finalize] do
    endpoint_shape?(summary, endpoint_keys(mode), mode) and
      summary["status"] == "failed" and summary["class"] == Atom.to_string(class) and
      valid_finalize_failure_flags?(summary, mode) and
      (class != :placement_drift or summary["owned"] == false)
  end

  defp valid_failed_endpoint?(_summary, _class, _mode), do: false

  defp valid_finalize_failure_flags?(_summary, :proof), do: true

  defp valid_finalize_failure_flags?(summary, :finalize),
    do: summary["proof_passed"] == false and summary["finalized"] == false

  defp valid_superseded_endpoint?(summary, :proof) do
    endpoint_shape?(summary, @endpoint_proof_keys, :proof) and
      superseded_semantics?(summary)
  end

  defp valid_superseded_endpoint?(summary, :finalize) do
    endpoint_shape?(summary, @endpoint_finalize_keys, :finalize) and
      superseded_semantics?(summary) and summary["proof_passed"] == false and
      summary["finalized"] == false
  end

  defp superseded_semantics?(summary) do
    summary["status"] == "superseded" and summary["owned"] == false and
      summary["class"] == "fenced" and not Map.has_key?(summary, "orphan_reason")
  end

  defp valid_finalized_endpoint?(summary) do
    endpoint_shape?(summary, @endpoint_finalize_keys, :finalize) and
      summary["status"] == "finalized" and summary["owned"] == true and
      summary["proof_passed"] == true and summary["finalized"] == true and
      not Map.has_key?(summary, "class") and not Map.has_key?(summary, "orphan_reason")
  end

  defp valid_cleanup_endpoint?(summary) do
    endpoint_shape?(summary, @endpoint_finalize_keys, :finalize) and
      summary["status"] == "cleanup_pending" and summary["owned"] == true and
      summary["proof_passed"] == true and summary["finalized"] == false and
      not Map.has_key?(summary, "class") and not Map.has_key?(summary, "orphan_reason")
  end

  defp valid_orphan_endpoint?(summary) do
    endpoint_shape?(summary, @endpoint_finalize_keys, :finalize) and
      summary["status"] == "orphan" and summary["owned"] == false and
      summary["proof_passed"] == false and summary["finalized"] == false and
      summary["orphan_reason"] in Enum.map(@orphan_reasons, &Atom.to_string/1) and
      not Map.has_key?(summary, "class")
  end

  defp endpoint_keys(:proof), do: @endpoint_proof_keys
  defp endpoint_keys(:finalize), do: @endpoint_finalize_keys

  defp endpoint_shape?(summary, allowed_keys, mode) when is_map(summary) do
    Map.get(summary, "scope") == "endpoint" and
      Map.get(summary, "mode") == Atom.to_string(mode) and
      valid_identity?(Map.get(summary, "endpoint")) and
      is_binary(Map.get(summary, "status")) and
      is_boolean(Map.get(summary, "owned")) and
      Enum.all?(Map.keys(summary), &(&1 in allowed_keys)) and
      optional_endpoint_text_safe?(summary)
  end

  defp endpoint_shape?(_summary, _allowed_keys, _mode), do: false

  defp optional_endpoint_text_safe?(summary) do
    Enum.all?(Map.take(summary, ~w(class code layout phase orphan_reason)), fn {_key, value} ->
      is_binary(value) and byte_size(value) in 1..@max_label_bytes and
        Regex.match?(@safe_text, value)
    end)
  end

  defp valid_identity?(value), do: match?({:ok, _identity}, normalize_identity(value))

  # 冻结的 wrapper 预算分配：published proof 先裁到 31 条（裁剪幂等，故 merge 时逐字节不变），
  # 剩余名额按 last failure 的 degraded、再 orphan_hints 的既有确定顺序填充。decisive/debt
  # witness 已由 classifier 置于 degraded 首位，因此始终随首名额保留。
  defp trim_published_proof(summary),
    do: trim_details(summary, "degraded", "omitted", @max_published_details)

  defp wrapper_budget(%{"degraded" => degraded}) when is_list(degraded),
    do: max(@max_wrapper_details - length(degraded), 0)

  defp wrapper_budget(_summary), do: @max_wrapper_details

  defp trim_last_failure(%{"degraded" => degraded} = summary, budget) when is_list(degraded) do
    summary = trim_details(summary, "degraded", "omitted", budget)
    remaining = max(budget - length(summary["degraded"]), 0)
    trim_details(summary, "orphan_hints", "orphan_omitted", remaining)
  end

  defp trim_last_failure(summary, _budget), do: summary

  defp trim_details(summary, list_key, omitted_key, limit) when is_map(summary) do
    details = Map.get(summary, list_key)
    omitted = Map.get(summary, omitted_key)

    if is_list(details) and is_integer(omitted) and length(details) > limit do
      kept = Enum.take(details, limit)

      summary
      |> Map.put(list_key, kept)
      |> Map.put(omitted_key, omitted + length(details) - length(kept))
    else
      summary
    end
  end

  defp trim_details(summary, _list_key, _omitted_key, _limit), do: summary

  defp valid_journal_combination?(target_phase, proof_summary, failure_summary)
       when is_binary(target_phase) do
    proof_valid? = valid_published_summary?(proof_summary)
    failure_kind = failure_summary_kind(failure_summary)

    cond do
      is_nil(proof_summary) ->
        target_phase in @rollback_evidence_phases and
          failure_kind in [:proof_failed, :proof_superseded]

      proof_valid? and target_phase in @proof_evidence_phases ->
        valid_failure_kind_for_phase?(target_phase, failure_kind)

      true ->
        false
    end
  end

  defp valid_journal_combination?(_target_phase, _proof_summary, _failure_summary), do: false

  defp valid_failure_kind_for_phase?(_target_phase, :none), do: true

  defp valid_failure_kind_for_phase?(_target_phase, kind)
       when kind in [:proof_failed, :proof_superseded],
       do: true

  defp valid_failure_kind_for_phase?(target_phase, kind)
       when kind in [:finalize_failed, :finalize_cleanup_pending, :finalize_superseded],
       do: target_phase in @finalize_failure_phases

  defp valid_failure_kind_for_phase?(_target_phase, _kind), do: false

  defp failure_summary_kind(nil), do: :none

  defp failure_summary_kind(%{"mode" => "proof", "status" => "failed"} = summary) do
    if valid_aggregate_proof_summary?(summary), do: :proof_failed, else: :invalid
  end

  defp failure_summary_kind(%{"mode" => "proof", "status" => "superseded"} = summary) do
    if valid_aggregate_proof_summary?(summary), do: :proof_superseded, else: :invalid
  end

  defp failure_summary_kind(%{"mode" => "finalize", "status" => "failed"} = summary) do
    if valid_aggregate_finalize_summary?(summary), do: :finalize_failed, else: :invalid
  end

  defp failure_summary_kind(%{"mode" => "finalize", "status" => "cleanup_pending"} = summary) do
    if valid_aggregate_finalize_summary?(summary),
      do: :finalize_cleanup_pending,
      else: :invalid
  end

  defp failure_summary_kind(%{"mode" => "finalize", "status" => "superseded"} = summary) do
    if valid_aggregate_finalize_summary?(summary), do: :finalize_superseded, else: :invalid
  end

  defp failure_summary_kind(_summary), do: :invalid

  defp valid_published_summary?(%{"mode" => "proof", "status" => status} = summary)
       when status in ~w(verified degraded),
       do: valid_aggregate_proof_summary?(summary)

  defp valid_published_summary?(_summary), do: false

  defp valid_aggregate_proof_summary?(summary) when is_map(summary) do
    class = Map.get(summary, "class")
    expected_keys = keys_with_optional_class(@aggregate_proof_keys, class)

    aggregate_common_valid?(summary, expected_keys, :proof) and
      aggregate_proof_status_valid?(summary)
  end

  defp valid_aggregate_finalize_summary?(summary) when is_map(summary) do
    class = Map.get(summary, "class")
    expected_keys = keys_with_optional_class(@aggregate_finalize_keys, class)

    aggregate_common_valid?(summary, expected_keys, :finalize) and
      finalize_common_valid?(summary) and aggregate_finalize_status_valid?(summary)
  end

  defp keys_with_optional_class(keys, nil), do: keys
  defp keys_with_optional_class(keys, _class), do: keys ++ ["class"]

  defp aggregate_common_valid?(summary, expected_keys, mode) do
    degraded = Map.get(summary, "degraded")
    omitted = Map.get(summary, "omitted")
    debt = Map.get(summary, "debt")
    verified = Map.get(summary, "verified")
    owned = Map.get(summary, "observed_owned")
    unavailable = Map.get(summary, "unavailable")

    Map.keys(summary) |> Enum.sort() == Enum.sort(expected_keys) and
      summary["scope"] == "aggregate" and summary["mode"] == Atom.to_string(mode) and
      positive_integer?(summary["required"]) and
      non_negative_integer?(verified) and non_negative_integer?(owned) and
      non_negative_integer?(unavailable) and non_negative_integer?(omitted) and
      non_negative_integer?(debt) and is_list(degraded) and
      length(degraded) <= @max_endpoints and
      Enum.all?(degraded, &valid_degraded_endpoint?(&1, mode)) and
      unique_detail_identities?(degraded) and
      debt == length(degraded) + omitted and unavailable <= debt and
      visible_counters_valid?(summary, mode)
  end

  defp finalize_common_valid?(summary) do
    finalized = summary["finalized"]
    orphaned = summary["orphaned"]
    orphan_hints = summary["orphan_hints"]
    orphan_omitted = summary["orphan_omitted"]
    degraded = summary["degraded"]

    non_negative_integer?(finalized) and finalized <= summary["verified"] and
      summary["verified"] - finalized <= summary["debt"] and
      non_negative_integer?(orphaned) and is_list(orphan_hints) and
      non_negative_integer?(orphan_omitted) and
      Enum.all?(orphan_hints, &valid_orphan_endpoint?/1) and
      orphaned == length(orphan_hints) + orphan_omitted and
      length(degraded) + length(orphan_hints) <= @max_endpoints and
      unique_detail_identities?(orphan_hints) and
      disjoint_detail_identities?(degraded, orphan_hints)
  end

  defp visible_counters_valid?(summary, mode) do
    additional_owned =
      Enum.count(summary["degraded"], fn detail ->
        detail["owned"] == true and
          not (mode == :finalize and detail["proof_passed"] == true)
      end)

    visible_unavailable =
      Enum.count(summary["degraded"], &(&1["class"] == "unavailable"))

    min_owned = summary["verified"] + additional_owned
    max_owned = min_owned + summary["omitted"]

    summary["observed_owned"] >= min_owned and summary["observed_owned"] <= max_owned and
      summary["unavailable"] >= visible_unavailable and
      summary["unavailable"] <= visible_unavailable + summary["omitted"]
  end

  defp aggregate_proof_status_valid?(summary) do
    required = summary["required"]
    verified = summary["verified"]
    debt = summary["debt"]
    class = Map.get(summary, "class")

    case summary["status"] do
      "verified" ->
        verified >= required and debt == 0 and is_nil(class)

      "degraded" ->
        verified >= required and debt > 0 and is_nil(class) and
          no_priority_short_circuit_detail?(summary)

      "failed" ->
        verified < required and class in Enum.map(@endpoint_failure_classes, &Atom.to_string/1) and
          valid_failure_relation?(summary) and canonical_drift_summary?(summary, :proof)

      "superseded" ->
        is_nil(class) and canonical_superseded_summary?(summary, :proof)

      _other ->
        false
    end
  end

  defp aggregate_finalize_status_valid?(summary) do
    required = summary["required"]
    verified = summary["verified"]
    finalized = summary["finalized"]
    debt = summary["debt"]
    unavailable = summary["unavailable"]
    class = Map.get(summary, "class")

    terminal? =
      verified >= required and finalized >= required and debt == 0 and unavailable == 0

    case summary["status"] do
      # 零债务终态里，proof-passed endpoint 不可能凭空消失。
      "finalized" ->
        terminal? and is_nil(class) and verified == finalized and
          verified == summary["observed_owned"]

      # cleanup pending 必须真的欠着可指认的清理债务，不能只靠 status/计数改写伪造。
      "cleanup_pending" ->
        verified >= required and debt > 0 and summary["degraded"] != [] and is_nil(class) and
          no_priority_short_circuit_detail?(summary)

      "failed" ->
        verified < required and class in Enum.map(@endpoint_failure_classes, &Atom.to_string/1) and
          valid_failure_relation?(summary) and canonical_drift_summary?(summary, :finalize)

      "superseded" ->
        is_nil(class) and canonical_superseded_summary?(summary, :finalize)

      _other ->
        false
    end
  end

  # placement drift 的聚合计数被结构预检刻意归零；durable 校验必须重新推导这一事实，
  # 而不是只相信 outer class。
  defp canonical_drift_summary?(%{"class" => "placement_drift"} = summary, mode) do
    summary["verified"] == 0 and summary["observed_owned"] == 0 and
      summary["unavailable"] == 0 and canonical_drift_finalize_zero?(summary, mode) and
      Enum.any?(summary["degraded"], fn detail ->
        detail["status"] == "failed" and detail["class"] == "placement_drift" and
          detail["owned"] == false
      end)
  end

  defp canonical_drift_summary?(_summary, _mode), do: true

  defp canonical_drift_finalize_zero?(_summary, :proof), do: true

  defp canonical_drift_finalize_zero?(summary, :finalize) do
    summary["finalized"] == 0 and summary["orphaned"] == 0 and
      summary["orphan_hints"] == [] and summary["orphan_omitted"] == 0
  end

  defp no_priority_short_circuit_detail?(summary) do
    Enum.all?(summary["degraded"], fn detail ->
      detail["status"] != "superseded" and detail["class"] != "placement_drift"
    end)
  end

  defp valid_failure_relation?(summary) do
    expected = decisive_failure_class(summary)
    summary["class"] == expected
  end

  defp decisive_failure_class(summary) do
    cond do
      has_failure_witness?(summary, "placement_drift", false) ->
        "placement_drift"

      summary["verified"] + summary["unavailable"] >= summary["required"] ->
        "unavailable"

      has_failure_witness?(summary, "corrupt", true) ->
        "corrupt"

      has_failure_witness?(summary, "mismatch", true) ->
        "mismatch"

      true ->
        "unavailable"
    end
  end

  defp has_failure_witness?(summary, class, owned_required?) do
    Enum.any?(summary["degraded"], fn detail ->
      detail["status"] == "failed" and detail["class"] == class and
        (not owned_required? or detail["owned"] == true)
    end)
  end

  defp canonical_superseded_summary?(summary, mode) do
    zero_semantic_counts? =
      summary["verified"] == 0 and summary["observed_owned"] == 0 and
        summary["unavailable"] == 0

    finalize_zero? =
      mode == :proof or
        (summary["finalized"] == 0 and summary["orphaned"] == 0 and
           summary["orphan_hints"] == [] and summary["orphan_omitted"] == 0)

    zero_semantic_counts? and finalize_zero? and summary["debt"] >= 1 and
      Enum.any?(summary["degraded"], &valid_superseded_endpoint?(&1, mode))
  end

  defp valid_degraded_endpoint?(%{"status" => "failed", "class" => class} = summary, mode) do
    case class_atom(class) do
      {:ok, parsed} -> valid_failed_endpoint?(summary, parsed, mode)
      :error -> false
    end
  end

  defp valid_degraded_endpoint?(%{"status" => "superseded"} = summary, mode),
    do: valid_superseded_endpoint?(summary, mode)

  defp valid_degraded_endpoint?(%{"status" => "cleanup_pending"} = summary, :finalize),
    do: valid_cleanup_endpoint?(summary)

  defp valid_degraded_endpoint?(_summary, _mode), do: false

  defp class_atom("unavailable"), do: {:ok, :unavailable}
  defp class_atom("mismatch"), do: {:ok, :mismatch}
  defp class_atom("corrupt"), do: {:ok, :corrupt}
  defp class_atom("placement_drift"), do: {:ok, :placement_drift}
  defp class_atom(_class), do: :error

  defp unique_detail_identities?(details) do
    identities = Enum.map(details, & &1["endpoint"])
    length(identities) == MapSet.size(MapSet.new(identities))
  end

  defp disjoint_detail_identities?(left, right) do
    left_ids = MapSet.new(Enum.map(left, & &1["endpoint"]))
    right_ids = MapSet.new(Enum.map(right, & &1["endpoint"]))
    MapSet.disjoint?(left_ids, right_ids)
  end

  defp validate_evidence(evidence) do
    with true <- json_safe?(evidence, 0),
         {:ok, bytes} <- Jason.encode(evidence),
         true <- byte_size(bytes) <= @max_encoded_bytes do
      {:ok, evidence}
    else
      _invalid -> {:error, :invalid_proof_evidence}
    end
  end

  defp json_safe?(_value, depth) when depth > 6, do: false
  defp json_safe?(nil, _depth), do: true
  defp json_safe?(value, _depth) when is_boolean(value) or is_number(value), do: true
  defp json_safe?(value, _depth) when is_binary(value), do: byte_size(value) <= 1024

  defp json_safe?(value, depth) when is_list(value) do
    length(value) <= @max_endpoints and Enum.all?(value, &json_safe?(&1, depth + 1))
  end

  defp json_safe?(value, depth) when is_map(value) do
    map_size(value) <= 32 and
      Enum.all?(value, fn
        {key, nested} when is_binary(key) ->
          byte_size(key) <= 64 and json_safe?(nested, depth + 1)

        _invalid ->
          false
      end)
  end

  defp json_safe?(_value, _depth), do: false

  defp positive_integer?(value), do: is_integer(value) and value > 0
  defp non_negative_integer?(value), do: is_integer(value) and value >= 0
  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
