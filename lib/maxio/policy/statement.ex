defmodule Maxio.Policy.Statement do
  @moduledoc """
  策略 statement 规范化结构 + 整篇 policy 解析/校验（铁律 5，对齐官方策略文档格式）。

  policy 文档（JSON）：{ "Version": "2012-10-17", "Id"?, "Statement": stmt | [stmt] }
    Version 只接受 "2012-10-17" 或 legacy "2008-10-17"；其余 → :malformed。
  statement：{ "Sid"?, "Effect": "Allow"|"Deny", "Principal"?, "Action": s|[s],
               "Resource": s|[s], "Condition"? }
    bucket policy（resource-based）必须有 Principal；缺 Principal 判 :malformed（与 AWS 一致）。
    Effect 必须恰为 "Allow"/"Deny"（区分大小写）。
    Action/Resource 必须存在且非空（本 MVP 不支持 NotAction/NotResource → 出现即忽略该字段
    但若导致无 Action/Resource 则 :malformed）。

  本 MVP defer（识别即文档化，不静默）：NotAction/NotResource/NotPrincipal、Service principal、
  CanonicalUser principal 细粒度（保留串，评估时按非匿名特定账户处理）。
  """
  alias Maxio.Policy.Arn

  @type effect :: :allow | :deny
  @type principals :: :any | {:aws, [String.t()]}
  @type t :: %__MODULE__{
          sid: String.t() | nil,
          effect: effect(),
          actions: [String.t()],
          resources: [String.t()],
          principals: principals(),
          conditions: map()
        }

  defstruct sid: nil,
            effect: :allow,
            actions: [],
            resources: [],
            principals: :any,
            conditions: %{}

  @allowed_versions ["2012-10-17", "2008-10-17"]

  @doc "解析整篇 policy JSON（不做 bucket 交叉校验）。成功 → {:ok, [t()]}；畸形 → {:error, :malformed}。"
  @spec parse_policy(binary()) :: {:ok, [t()]} | {:error, :malformed}
  def parse_policy(json) when is_binary(json), do: parse_policy(json, nil)

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
         {:ok, stmts} <- normalize_all(raw_stmts),
         :ok <- validate_resources_bucket(stmts, bucket) do
      {:ok, stmts}
    else
      _ -> {:error, :malformed}
    end
  end

  @doc "规范化单条 statement map。"
  @spec from_json(map()) :: {:ok, t()} | {:error, :malformed}
  def from_json(%{} = stmt) do
    with {:ok, effect} <- parse_effect(Map.get(stmt, "Effect")),
         {:ok, actions} <- to_nonempty_list(Map.get(stmt, "Action")),
         {:ok, resources} <- to_nonempty_list(Map.get(stmt, "Resource")),
         {:ok, principals} <- parse_principal(Map.get(stmt, "Principal")),
         {:ok, conditions} <- parse_conditions(Map.get(stmt, "Condition")) do
      {:ok,
       %__MODULE__{
         sid: Map.get(stmt, "Sid"),
         effect: effect,
         actions: actions,
         resources: resources,
         principals: principals,
         conditions: conditions
       }}
    else
      _ -> {:error, :malformed}
    end
  end

  def from_json(_), do: {:error, :malformed}

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

  defp fetch_statements(doc) do
    case Map.get(doc, "Statement") do
      %{} = single -> {:ok, [single]}
      list when is_list(list) and list != [] -> {:ok, list}
      _ -> {:error, :malformed}
    end
  end

  defp normalize_all(raw) do
    Enum.reduce_while(raw, {:ok, []}, fn stmt, {:ok, acc} ->
      case from_json(stmt) do
        {:ok, s} -> {:cont, {:ok, [s | acc]}}
        {:error, _} -> {:halt, {:error, :malformed}}
      end
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
    strs = Enum.filter(list, &(is_binary(&1) and &1 != ""))
    if strs == [], do: {:error, :malformed}, else: {:ok, strs}
  end

  defp to_nonempty_list(_), do: {:error, :malformed}

  # Principal："*" | {"AWS": "*" | ak | [..]} | {"Service": ...}(defer→当特定) | 缺省(bucket policy 非法)
  defp parse_principal("*"), do: {:ok, :any}
  defp parse_principal(%{"AWS" => "*"}), do: {:ok, :any}

  defp parse_principal(%{"AWS" => aws}) when is_binary(aws), do: {:ok, {:aws, [aws]}}

  defp parse_principal(%{"AWS" => list}) when is_list(list) do
    strs = Enum.filter(list, &is_binary/1)

    cond do
      "*" in strs -> {:ok, :any}
      strs == [] -> {:error, :malformed}
      true -> {:ok, {:aws, strs}}
    end
  end

  # Service / CanonicalUser 等其它形态：MVP 不细评估，保留为特定 principal（不匹配匿名）。
  defp parse_principal(%{} = other) do
    vals = other |> Map.values() |> List.flatten() |> Enum.filter(&is_binary/1)
    if vals == [], do: {:error, :malformed}, else: {:ok, {:aws, vals}}
  end

  # 缺省 Principal：bucket policy（resource-based）必须显式 Principal → 判畸形。
  defp parse_principal(nil), do: {:error, :malformed}
  defp parse_principal(_), do: {:error, :malformed}

  # Condition 校验：算子必须在受支持集合内（复用 Maxio.Policy.Condition.supported_operators/0，
  # 单一事实来源），否则 {:error, :malformed} → PutBucketPolicy 回 400 MalformedPolicy（铁律 3/5，
  # 对齐 minio condition.UnmarshalJSON 在 parse 期拒绝未知算子，绝不存「行为与所写不符」的策略）。
  defp parse_conditions(nil), do: {:ok, %{}}

  defp parse_conditions(%{} = cond_map) do
    supported = MapSet.new(Maxio.Policy.Condition.supported_operators())

    if Enum.all?(Map.keys(cond_map), &MapSet.member?(supported, &1)) do
      {:ok, cond_map}
    else
      {:error, :malformed}
    end
  end

  defp parse_conditions(_), do: {:error, :malformed}

  @doc "便于测试/调试：判断某 action 串是否被本 statement 的 Action 命中（大小写不敏感）。"
  @spec action_match?(t(), String.t()) :: boolean()
  def action_match?(%__MODULE__{actions: actions}, action) do
    Enum.any?(actions, &Arn.glob_match?(&1, action, case_insensitive: true))
  end

  @doc "便于测试/调试：判断某 resource ARN 是否被本 statement 的 Resource 命中（大小写敏感）。"
  @spec resource_match?(t(), String.t()) :: boolean()
  def resource_match?(%__MODULE__{resources: resources}, resource) do
    Enum.any?(resources, &Arn.glob_match?(&1, resource))
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
