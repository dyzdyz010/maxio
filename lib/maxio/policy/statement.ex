defmodule Maxio.Policy.Statement do
  @moduledoc """
  策略 statement 规范化结构 + 整篇 policy 解析/校验（铁律 5，对齐官方策略文档格式）。

  policy 文档（JSON）：{ "Version": "2012-10-17", "Id"?, "Statement": stmt | [stmt] }
    Version 只接受 "2012-10-17" 或 legacy "2008-10-17"；其余 → :malformed。
  statement：{ "Sid"?, "Effect": "Allow"|"Deny", ("Principal"|"NotPrincipal")?,
               ("Action"|"NotAction"): s|[s], ("Resource"|"NotResource"): s|[s], "Condition"? }
    bucket policy（resource-based）必须有 Principal 或 NotPrincipal；缺失判 :malformed（与 AWS 一致）。
    Effect 必须恰为 "Allow"/"Deny"（区分大小写）。
    Action/NotAction、Resource/NotResource、Principal/NotPrincipal 互斥且必须非空。
    NotPrincipal 仅支持 resource-based Deny statement；identity policy 仍禁止 Principal/NotPrincipal。

  本 MVP defer（识别即文档化，不静默）：Service principal、
  CanonicalUser principal 细粒度（保留串，评估时按非匿名特定账户处理）。
  """
  alias Maxio.Policy.{Arn, RequestContext, Variables}

  @type effect :: :allow | :deny
  @type principals :: :any | {:aws, [String.t()]}
  @type t :: %__MODULE__{
          sid: String.t() | nil,
          effect: effect(),
          actions: [String.t()],
          not_action?: boolean(),
          resources: [String.t()],
          not_resource?: boolean(),
          principals: principals(),
          not_principal?: boolean(),
          conditions: map(),
          variables_enabled?: boolean()
        }

  defstruct sid: nil,
            effect: :allow,
            actions: [],
            not_action?: false,
            resources: [],
            not_resource?: false,
            principals: :any,
            not_principal?: false,
            conditions: %{},
            variables_enabled?: false

  @allowed_versions ["2012-10-17", "2008-10-17"]

  @doc "解析整篇 policy JSON（不做 bucket 交叉校验）。成功 → {:ok, [t()]}；畸形 → {:error, :malformed}。"
  @spec parse_policy(binary()) :: {:ok, [t()]} | {:error, :malformed}
  def parse_policy(json) when is_binary(json), do: parse_policy(json, nil)

  @doc """
  解析 IAM identity-based policy。

  与 bucket policy 不同，identity policy 绑定在 principal 上，不能包含 `Principal`；
  授权评估时该 principal 由绑定关系隐式提供。为复用同一 Evaluator，这里把每条 statement
  规范化为 `Principal="*"`，但只会经 `Store.principal_policies/1` 返回给对应 principal。
  """
  @spec parse_identity_policy(binary()) :: {:ok, [t()]} | {:error, :malformed}
  def parse_identity_policy(json) when is_binary(json) do
    with {:ok, doc} <- decode(json),
         :ok <- check_version(doc),
         {:ok, raw_stmts} <- fetch_statements(doc),
         {:ok, stmts} <- normalize_identity_all(raw_stmts, variables_enabled?(doc)) do
      {:ok, stmts}
    else
      _ -> {:error, :malformed}
    end
  end

  @doc """
  解析整篇 policy JSON，并（当 bucket 非 nil 时）校验每条 statement 的每个 Resource ARN 都引用
  目标桶（对齐 minio/pkg Resource.ValidateBucket：桶段精确或通配匹配 bucket，允许 'bucket' 与
  'bucket/...'）。任一 Resource 桶段不匹配 → {:error, :malformed}（→ 400 MalformedPolicy）。
  bucket == nil（如 Store 回读路径 parse_policy/1）→ 跳过桶校验（向后兼容）。
  """
  @spec parse_policy(binary(), String.t() | nil) :: {:ok, [t()]} | {:error, :malformed}
  def parse_policy(json, bucket) when is_binary(json) do
    with {:ok, doc} <- decode(json),
         :ok <- check_version(doc),
         {:ok, raw_stmts} <- fetch_statements(doc),
         {:ok, stmts} <- normalize_all(raw_stmts, variables_enabled?(doc)),
         :ok <- validate_resources_bucket(stmts, bucket) do
      {:ok, stmts}
    else
      _ -> {:error, :malformed}
    end
  end

  @doc "规范化单条 statement map。"
  @spec from_json(map()) :: {:ok, t()} | {:error, :malformed}
  def from_json(stmt, opts \\ [])

  def from_json(%{} = stmt, opts) do
    with {:ok, effect} <- parse_effect(Map.get(stmt, "Effect")),
         {:ok, actions, not_action?} <- parse_selector(stmt, "Action", "NotAction"),
         {:ok, resources, not_resource?} <- parse_selector(stmt, "Resource", "NotResource"),
         {:ok, principals, not_principal?} <- parse_principal_selector(stmt, effect),
         {:ok, conditions} <- parse_conditions(Map.get(stmt, "Condition")) do
      {:ok,
       %__MODULE__{
         sid: Map.get(stmt, "Sid"),
         effect: effect,
         actions: actions,
         not_action?: not_action?,
         resources: resources,
         not_resource?: not_resource?,
         principals: principals,
         not_principal?: not_principal?,
         conditions: conditions,
         variables_enabled?: Keyword.get(opts, :variables_enabled?, false)
       }}
    else
      _ -> {:error, :malformed}
    end
  end

  def from_json(_stmt, _opts), do: {:error, :malformed}

  # ── 内部 ──
  defp decode(json) do
    case Jason.decode(json) do
      {:ok, %{} = doc} -> {:ok, doc}
      _ -> {:error, :malformed}
    end
  end

  defp check_version(doc) do
    case Map.get(doc, "Version") do
      nil -> :ok
      v when v in @allowed_versions -> :ok
      _ -> {:error, :malformed}
    end
  end

  defp variables_enabled?(doc), do: Map.get(doc, "Version") == "2012-10-17"

  defp fetch_statements(doc) do
    case Map.get(doc, "Statement") do
      %{} = single -> {:ok, [single]}
      list when is_list(list) and list != [] -> {:ok, list}
      _ -> {:error, :malformed}
    end
  end

  defp normalize_all(raw, variables_enabled?) do
    Enum.reduce_while(raw, {:ok, []}, fn stmt, {:ok, acc} ->
      case from_json(stmt, variables_enabled?: variables_enabled?) do
        {:ok, s} -> {:cont, {:ok, [s | acc]}}
        {:error, _} -> {:halt, {:error, :malformed}}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      err -> err
    end
  end

  defp normalize_identity_all(raw, variables_enabled?) do
    Enum.reduce_while(raw, {:ok, []}, fn
      %{} = stmt, {:ok, acc} ->
        if Map.has_key?(stmt, "Principal") or Map.has_key?(stmt, "NotPrincipal") do
          {:halt, {:error, :malformed}}
        else
          case from_json(Map.put(stmt, "Principal", "*"), variables_enabled?: variables_enabled?) do
            {:ok, s} -> {:cont, {:ok, [s | acc]}}
            {:error, _} -> {:halt, {:error, :malformed}}
          end
        end

      _stmt, _acc ->
        {:halt, {:error, :malformed}}
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      err -> err
    end
  end

  defp parse_effect("Allow"), do: {:ok, :allow}
  defp parse_effect("Deny"), do: {:ok, :deny}
  defp parse_effect(_), do: {:error, :malformed}

  defp to_nonempty_list(v) when is_binary(v) and v != "", do: {:ok, [v]}

  defp to_nonempty_list(list) when is_list(list) do
    if list != [] and Enum.all?(list, &(is_binary(&1) and &1 != "")) do
      {:ok, list}
    else
      {:error, :malformed}
    end
  end

  defp to_nonempty_list(_), do: {:error, :malformed}

  defp parse_selector(stmt, field, not_field) do
    has_field? = Map.has_key?(stmt, field)
    has_not_field? = Map.has_key?(stmt, not_field)

    cond do
      has_field? and has_not_field? ->
        {:error, :malformed}

      has_field? ->
        case to_nonempty_list(Map.get(stmt, field)) do
          {:ok, values} -> {:ok, values, false}
          error -> error
        end

      has_not_field? ->
        case to_nonempty_list(Map.get(stmt, not_field)) do
          {:ok, values} -> {:ok, values, true}
          error -> error
        end

      true ->
        {:error, :malformed}
    end
  end

  # Principal："*" | {"AWS": "*" | ak | [..]} | {"Service": ...}(defer→当特定) | 缺省(bucket policy 非法)
  defp parse_principal_selector(stmt, effect) do
    has_principal? = Map.has_key?(stmt, "Principal")
    has_not_principal? = Map.has_key?(stmt, "NotPrincipal")

    cond do
      has_principal? and has_not_principal? ->
        {:error, :malformed}

      has_principal? ->
        case parse_principal(Map.get(stmt, "Principal")) do
          {:ok, principals} -> {:ok, principals, false}
          error -> error
        end

      has_not_principal? and effect == :deny ->
        case parse_principal(Map.get(stmt, "NotPrincipal")) do
          {:ok, principals} -> {:ok, principals, true}
          error -> error
        end

      has_not_principal? ->
        {:error, :malformed}

      true ->
        {:error, :malformed}
    end
  end

  defp parse_principal("*"), do: {:ok, :any}
  defp parse_principal(%{"AWS" => "*"}), do: {:ok, :any}

  defp parse_principal(%{"AWS" => aws}) when is_binary(aws) and aws != "",
    do: {:ok, {:aws, [aws]}}

  defp parse_principal(%{"AWS" => list}) when is_list(list) do
    if list != [] and Enum.all?(list, &(is_binary(&1) and &1 != "")) do
      if "*" in list, do: {:ok, :any}, else: {:ok, {:aws, list}}
    else
      {:error, :malformed}
    end
  end

  # Service / CanonicalUser 等其它形态：MVP 不细评估，保留为特定 principal（不匹配匿名）。
  defp parse_principal(%{} = other) do
    values =
      other
      |> Map.values()
      |> Enum.reduce_while([], fn
        value, acc when is_binary(value) and value != "" ->
          {:cont, [value | acc]}

        list, acc when is_list(list) ->
          if list != [] and Enum.all?(list, &(is_binary(&1) and &1 != "")) do
            {:cont, Enum.reverse(list) ++ acc}
          else
            {:halt, :malformed}
          end

        _value, _acc ->
          {:halt, :malformed}
      end)

    case values do
      :malformed -> {:error, :malformed}
      [] -> {:error, :malformed}
      vals -> {:ok, {:aws, Enum.reverse(vals)}}
    end
  end

  # 缺省 Principal：bucket policy（resource-based）必须显式 Principal → 判畸形。
  defp parse_principal(nil), do: {:error, :malformed}
  defp parse_principal(_), do: {:error, :malformed}

  # Condition 校验（铁律 3/5，对齐 minio condition.UnmarshalJSON）：
  # 只拒绝**真正不存在于 AWS/MinIO** 的算子（不在 Maxio.Policy.Condition.known_operators/0 全量白名单内）
  # → {:error, :malformed} → PutBucketPolicy 回 400 MalformedPolicy。
  # 合法且由 Maxio.Policy.Condition 求值的算子（NumericLessThan / StringNotEquals /
  # DateLessThan / Null / *IfExists …）正常接受（HTTP 204）；真正不存在的算子才拒收。
  defp parse_conditions(nil), do: {:ok, %{}}

  defp parse_conditions(%{} = cond_map) when map_size(cond_map) > 0 do
    known = MapSet.new(Maxio.Policy.Condition.known_operators())

    if Enum.all?(cond_map, &valid_condition_operator?(&1, known)) do
      {:ok, cond_map}
    else
      {:error, :malformed}
    end
  end

  defp parse_conditions(%{}), do: {:error, :malformed}
  defp parse_conditions(_), do: {:error, :malformed}

  defp valid_condition_operator?({op, key_values}, known)
       when is_binary(op) and is_map(key_values) and map_size(key_values) > 0 do
    MapSet.member?(known, op) and
      Enum.all?(key_values, fn {key, value} ->
        is_binary(key) and key != "" and valid_condition_value?(value)
      end)
  end

  defp valid_condition_operator?(_entry, _known), do: false

  defp valid_condition_value?(values) when is_list(values),
    do: values != [] and Enum.all?(values, &valid_condition_scalar?/1)

  defp valid_condition_value?(value), do: valid_condition_scalar?(value)

  defp valid_condition_scalar?(value)
       when is_binary(value) or is_boolean(value) or is_integer(value) or is_float(value),
       do: true

  defp valid_condition_scalar?(_value), do: false

  @doc "便于测试/调试：判断某 action 串是否被本 statement 的 Action 命中（大小写不敏感）。"
  @spec action_match?(t(), String.t()) :: boolean()
  def action_match?(%__MODULE__{actions: actions, not_action?: not_action?}, action) do
    matched? = Enum.any?(actions, &Arn.glob_match?(&1, action, case_insensitive: true))
    if not_action?, do: not matched?, else: matched?
  end

  @doc "便于测试/调试：判断某 resource ARN 是否被本 statement 的 Resource 命中（大小写敏感）。"
  @spec resource_match?(t(), String.t() | RequestContext.t()) :: boolean()
  def resource_match?(%__MODULE__{variables_enabled?: false} = statement, %RequestContext{} = ctx) do
    resource_match?(statement, ctx.resource)
  end

  def resource_match?(%__MODULE__{variables_enabled?: true} = statement, %RequestContext{} = ctx) do
    {resources, unresolved?} = resolved_resource_patterns(statement.resources, ctx.conditions)

    if resources == [] or (statement.not_resource? and unresolved?) do
      false
    else
      matched? = Enum.any?(resources, &Arn.glob_match?(&1, ctx.resource))
      if statement.not_resource?, do: not matched?, else: matched?
    end
  end

  def resource_match?(%__MODULE__{resources: resources, not_resource?: not_resource?}, resource) do
    matched? = Enum.any?(resources, &Arn.glob_match?(&1, resource))
    if not_resource?, do: not matched?, else: matched?
  end

  defp resolved_resource_patterns(resources, ctx) do
    resources
    |> Enum.reduce({[], false}, fn resource, {acc, unresolved?} ->
      case Variables.expand_string(resource, ctx) do
        {:ok, expanded} -> {[expanded | acc], unresolved?}
        :unresolved -> {acc, true}
      end
    end)
    |> then(fn {resolved, unresolved?} -> {Enum.reverse(resolved), unresolved?} end)
  end

  # nil bucket（如 Store 回读路径 parse_policy/1）→ 跳过桶校验（向后兼容）。
  defp validate_resources_bucket(_stmts, nil), do: :ok

  defp validate_resources_bucket(stmts, bucket) do
    ok? =
      Enum.all?(stmts, fn %__MODULE__{resources: resources} ->
        Enum.all?(resources, &resource_references_bucket?(&1, bucket))
      end)

    if ok?, do: :ok, else: {:error, :malformed}
  end

  # Resource ARN 是否引用目标桶：剥 "arn:aws:s3:::" 前缀后取桶段（首个 '/' 之前），
  # 用 policy 通配语义匹配 bucket（pattern 可含 *、?）。无前缀 → 不匹配（畸形）。
  defp resource_references_bucket?("arn:aws:s3:::" <> rest, bucket) do
    bucket_segment = rest |> String.split("/", parts: 2) |> List.first()
    Arn.glob_match?(bucket_segment, bucket)
  end

  defp resource_references_bucket?(_other, _bucket), do: false
end
