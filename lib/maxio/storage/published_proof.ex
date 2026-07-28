defmodule Maxio.Storage.PublishedProof do
  @moduledoc """
  已发布对象取证的唯一纯数据契约。

  本模块同时负责 endpoint 结果、全局 quorum 裁决和 journal evidence 的限界/脱敏。
  对外结果只含 JSON-safe 的 string-key map；endpoint 身份只接受 node/ordinal 标签，
  绝不接受 drive、对象或备份的绝对路径。
  """

  @classes [:unavailable, :mismatch, :corrupt, :fenced, :placement_drift]
  @integrity_classes [:placement_drift, :corrupt, :mismatch]
  @max_endpoints 32
  @max_encoded_bytes 60 * 1024
  @max_label_bytes 128
  @identity ~r/\A[a-zA-Z0-9@_.:-]+\z/
  @safe_text ~r/\A[a-zA-Z0-9@_.:-]+\z/
  @attr_keys [:code, :layout, :owned, :phase]
  @summary_keys ~w(class degraded observed_owned omitted required status unavailable verified)
  @statuses ~w(verified degraded superseded failed)

  @type proof_class :: :unavailable | :mismatch | :corrupt | :fenced | :placement_drift
  @type summary :: %{required(String.t()) => term()}
  @type proof_result ::
          {:ok, {:verified | :degraded | :superseded, summary()}}
          | {:error, {:published_proof_failed, proof_class(), summary()}}

  @doc "构造单 endpoint 已验证结果。"
  @spec verified(String.t() | atom() | non_neg_integer(), map()) :: proof_result()
  def verified(identity, attrs \\ %{}) do
    case endpoint(identity, "verified", nil, attrs) do
      {:ok, _endpoint} ->
        {:ok, {:verified, summary("verified", 1, 1, owned_count(attrs), 0, [])}}

      {:error, _reason} ->
        invalid_constructor(identity)
    end
  end

  @doc "构造单 endpoint successor 结果；全局聚合时它拥有最高优先级。"
  @spec superseded(String.t() | atom() | non_neg_integer()) :: proof_result()
  def superseded(identity) do
    case endpoint(identity, "superseded", :fenced, %{owned: true}) do
      {:ok, endpoint} ->
        {:ok, {:superseded, summary("superseded", 1, 0, 1, 0, [endpoint])}}

      {:error, _reason} ->
        invalid_constructor(identity)
    end
  end

  @doc "构造单 endpoint proof failure。"
  @spec failed(proof_class(), String.t() | atom() | non_neg_integer(), map()) :: proof_result()
  def failed(class, identity, attrs \\ %{})

  def failed(class, identity, attrs) when class in @classes do
    case endpoint(identity, "failed", class, attrs) do
      {:ok, endpoint} ->
        unavailable = if class == :unavailable, do: 1, else: 0

        failure =
          summary("failed", 1, 0, owned_count(attrs), unavailable, [endpoint])
          |> Map.put("class", Atom.to_string(class))

        {:error, {:published_proof_failed, class, failure}}

      {:error, _reason} ->
        invalid_constructor(identity)
    end
  end

  def failed(_class, identity, _attrs), do: invalid_constructor(identity)

  @doc """
  按冻结顺序裁决 endpoint 结果：
  successor → verified quorum → 仍可能由 unavailable 补足 → 确定性完整性失败 → unavailable。
  """
  @spec classify(pos_integer(), [proof_result()]) :: proof_result()
  def classify(required, results)
      when is_integer(required) and required > 0 and is_list(results) do
    observations = Enum.map(results, &normalize_result/1)
    verified = Enum.sum(Enum.map(observations, & &1.verified))
    observed_owned = Enum.sum(Enum.map(observations, & &1.observed_owned))
    unavailable = Enum.sum(Enum.map(observations, & &1.unavailable))
    degraded = Enum.flat_map(observations, & &1.degraded)
    successor? = Enum.any?(observations, & &1.superseded?)

    cond do
      successor? ->
        {:ok,
         {:superseded,
          summary("superseded", required, verified, observed_owned, unavailable, degraded)}}

      verified >= required ->
        status = if Enum.any?(observations, & &1.failure?), do: "degraded", else: "verified"
        outcome = if status == "verified", do: :verified, else: :degraded

        {:ok,
         {outcome, summary(status, required, verified, observed_owned, unavailable, degraded)}}

      verified + unavailable >= required ->
        global_failure(
          :unavailable,
          required,
          verified,
          observed_owned,
          unavailable,
          degraded
        )

      class = deterministic_integrity_class(observations) ->
        global_failure(class, required, verified, observed_owned, unavailable, degraded)

      true ->
        global_failure(
          :unavailable,
          required,
          verified,
          observed_owned,
          unavailable,
          degraded
        )
    end
  end

  def classify(_required, results) do
    invalid_constructor(if(is_list(results), do: "quorum", else: "invalid"))
  end

  @doc "构造固定 journal evidence，并执行 JSON-safe/大小门。"
  @spec journal_evidence(map(), map() | nil) :: {:ok, map()} | {:error, :invalid_proof_evidence}
  def journal_evidence(proof_summary, failure_summary \\ nil) do
    evidence = %{
      "published_proof" => proof_summary,
      "last_failure" => failure_summary
    }

    with true <- valid_published_summary?(proof_summary),
         true <- is_nil(failure_summary) or valid_failure_summary?(failure_summary) do
      validate_evidence(evidence)
    else
      false -> {:error, :invalid_proof_evidence}
    end
  end

  @doc "保留初始 published proof，只替换 last_failure。"
  @spec merge_failure(map(), map() | nil) :: {:ok, map()} | {:error, :invalid_proof_evidence}
  def merge_failure(
        %{"published_proof" => proof_summary, "last_failure" => _old},
        failure_summary
      ) do
    journal_evidence(proof_summary, failure_summary)
  end

  def merge_failure(_evidence, _failure), do: {:error, :invalid_proof_evidence}

  @doc "是否为允许的 proof class。"
  @spec proof_class?(term()) :: boolean()
  def proof_class?(class), do: class in @classes

  @doc "端点恢复后可直接重试的 proof class。"
  @spec retryable_class?(term()) :: boolean()
  def retryable_class?(class), do: class in [:unavailable, :fenced]

  @doc "需要 quarantine/人工修复的确定性完整性 class。"
  @spec integrity_class?(term()) :: boolean()
  def integrity_class?(class), do: class in @integrity_classes

  defp global_failure(class, required, verified, observed_owned, unavailable, degraded) do
    failure =
      summary("failed", required, verified, observed_owned, unavailable, degraded)
      |> Map.put("class", Atom.to_string(class))

    {:error, {:published_proof_failed, class, failure}}
  end

  defp deterministic_integrity_class(observations) do
    Enum.find(@integrity_classes, fn class ->
      Enum.any?(observations, &(&1.class == class))
    end)
  end

  defp normalize_result({:ok, {outcome, summary}})
       when outcome in [:verified, :degraded, :superseded] and is_map(summary) do
    case normalize_summary(summary) do
      {:ok, normalized} ->
        %{
          class: if(outcome == :superseded, do: :fenced, else: nil),
          degraded: normalized.degraded,
          failure?: outcome in [:degraded, :superseded],
          observed_owned: normalized.observed_owned,
          superseded?: outcome == :superseded,
          unavailable: normalized.unavailable,
          verified: normalized.verified
        }

      :error ->
        invalid_observation()
    end
  end

  defp normalize_result({:error, {:published_proof_failed, class, summary}})
       when class in @classes and is_map(summary) do
    case normalize_summary(summary) do
      {:ok, normalized} ->
        %{
          class: class,
          degraded: normalized.degraded,
          failure?: true,
          observed_owned: normalized.observed_owned,
          superseded?: class == :fenced,
          unavailable: max(normalized.unavailable, if(class == :unavailable, do: 1, else: 0)),
          verified: normalized.verified
        }

      :error ->
        invalid_observation()
    end
  end

  defp normalize_result(_result), do: invalid_observation()

  defp normalize_summary(summary) do
    with true <- valid_summary?(summary),
         verified when is_integer(verified) and verified >= 0 <- Map.get(summary, "verified"),
         owned when is_integer(owned) and owned >= 0 <- Map.get(summary, "observed_owned"),
         unavailable when is_integer(unavailable) and unavailable >= 0 <-
           Map.get(summary, "unavailable"),
         degraded when is_list(degraded) <- Map.get(summary, "degraded"),
         true <- Enum.all?(degraded, &valid_endpoint?/1) do
      {:ok,
       %{
         verified: verified,
         observed_owned: owned,
         unavailable: unavailable,
         degraded: degraded
       }}
    else
      _invalid -> :error
    end
  end

  defp invalid_observation do
    endpoint =
      elem(
        endpoint("invalid", "failed", :corrupt, %{code: "invalid_result", owned: false}),
        1
      )

    %{
      class: :corrupt,
      degraded: [endpoint],
      failure?: true,
      observed_owned: 0,
      superseded?: false,
      unavailable: 0,
      verified: 0
    }
  end

  defp invalid_constructor(identity) do
    safe_identity = if valid_identity?(identity), do: identity, else: "invalid"

    {:ok, endpoint} =
      endpoint(safe_identity, "failed", :corrupt, %{code: "invalid_evidence", owned: false})

    failure =
      summary("failed", 1, 0, 0, 0, [endpoint])
      |> Map.put("class", "corrupt")

    {:error, {:published_proof_failed, :corrupt, failure}}
  end

  defp endpoint(identity, status, class, attrs)
       when status in ["verified", "failed", "superseded"] and is_map(attrs) do
    with {:ok, identity} <- normalize_identity(identity),
         :ok <- validate_attrs(attrs),
         {:ok, code} <- optional_safe_text(attrs, :code),
         {:ok, layout} <- optional_safe_text(attrs, :layout),
         {:ok, phase} <- optional_safe_text(attrs, :phase) do
      endpoint =
        %{
          "endpoint" => identity,
          "status" => status,
          "owned" => Map.get(attrs, :owned, true)
        }
        |> maybe_put("class", if(class, do: Atom.to_string(class), else: nil))
        |> maybe_put("code", code)
        |> maybe_put("layout", layout)
        |> maybe_put("phase", phase)

      {:ok, endpoint}
    else
      _invalid -> {:error, :invalid_proof_evidence}
    end
  end

  defp validate_attrs(attrs) do
    keys = Map.keys(attrs)

    if Enum.all?(keys, &(&1 in @attr_keys)) and
         is_boolean(Map.get(attrs, :owned, true)) do
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

  defp normalize_identity(value) when is_integer(value) and value >= 0,
    do: {:ok, "ordinal:#{value}"}

  defp normalize_identity(value) when is_atom(value),
    do: normalize_identity(Atom.to_string(value))

  defp normalize_identity(value) when is_binary(value) do
    if valid_identity?(value), do: {:ok, value}, else: {:error, :invalid_proof_evidence}
  end

  defp normalize_identity(_value), do: {:error, :invalid_proof_evidence}

  defp valid_identity?(value) when is_integer(value), do: value >= 0
  defp valid_identity?(value) when is_atom(value), do: valid_identity?(Atom.to_string(value))

  defp valid_identity?(value) when is_binary(value) do
    byte_size(value) in 1..@max_label_bytes and Regex.match?(@identity, value) and
      not Regex.match?(~r/\A[A-Za-z]:/, value)
  end

  defp valid_identity?(_value), do: false

  defp summary(status, required, verified, observed_owned, unavailable, degraded) do
    {bounded, omitted} = bounded_endpoints(degraded)

    %{
      "status" => status,
      "required" => required,
      "verified" => verified,
      "observed_owned" => observed_owned,
      "unavailable" => unavailable,
      "degraded" => bounded,
      "omitted" => omitted
    }
  end

  defp bounded_endpoints(endpoints) do
    bounded = Enum.take(endpoints, @max_endpoints)
    {bounded, max(length(endpoints) - length(bounded), 0)}
  end

  defp valid_endpoint?(%{"endpoint" => identity, "status" => status, "owned" => owned} = endpoint)
       when status in ["verified", "failed", "superseded"] and is_boolean(owned) do
    valid_identity?(identity) and
      Enum.all?(Map.keys(endpoint), &(&1 in ~w(endpoint status owned class code layout phase))) and
      Enum.all?(Map.take(endpoint, ~w(class code layout phase)), fn {_key, value} ->
        is_binary(value) and byte_size(value) in 1..@max_label_bytes and
          Regex.match?(@safe_text, value)
      end)
  end

  defp valid_endpoint?(_endpoint), do: false

  defp valid_summary?(summary) when is_map(summary) do
    keys = Map.keys(summary)
    degraded = Map.get(summary, "degraded")
    class = Map.get(summary, "class")

    Enum.all?(keys, &(&1 in @summary_keys)) and
      Enum.all?(@summary_keys -- ["class"], &Map.has_key?(summary, &1)) and
      Map.get(summary, "status") in @statuses and
      positive_integer?(Map.get(summary, "required")) and
      non_negative_integer?(Map.get(summary, "verified")) and
      non_negative_integer?(Map.get(summary, "observed_owned")) and
      non_negative_integer?(Map.get(summary, "unavailable")) and
      non_negative_integer?(Map.get(summary, "omitted")) and
      is_list(degraded) and length(degraded) <= @max_endpoints and
      Enum.all?(degraded, &valid_endpoint?/1) and
      (is_nil(class) or class in Enum.map(@classes, &Atom.to_string/1))
  end

  defp valid_summary?(_summary), do: false

  defp valid_failure_summary?(%{"status" => "failed", "class" => class} = summary)
       when class in ~w(unavailable mismatch corrupt fenced placement_drift),
       do: valid_summary?(summary)

  defp valid_failure_summary?(_summary), do: false

  defp valid_published_summary?(%{"status" => status} = summary)
       when status in ~w(verified degraded),
       do: valid_summary?(summary)

  defp valid_published_summary?(_summary), do: false

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

  defp owned_count(attrs), do: if(Map.get(attrs, :owned, true), do: 1, else: 0)
  defp positive_integer?(value), do: is_integer(value) and value > 0
  defp non_negative_integer?(value), do: is_integer(value) and value >= 0
  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
