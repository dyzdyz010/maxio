defmodule Maxio.Policy.Condition do
  @moduledoc """
  策略 Condition 块求值（铁律 5，对齐官方条件算子语义）。

  这里区分两套算子集合（解耦「能否接受」与「能否求值」，对齐 minio condition.UnmarshalJSON）：

    * `known_operators/0` —— **AWS/MinIO 全量合法算子白名单**（~24 个 + 各 `*IfExists` 变体）。
      PutBucketPolicy parse 期只拒绝**真正不存在于 AWS/MinIO**的算子（→ 400 MalformedPolicy）；
      合法但本 MVP 未实现求值的算子（如 NumericLessThan / StringNotEquals / DateLessThan /
      NotIpAddress / Null …）**正常接受（HTTP 204）**，与 mc/aws-cli/boto3/MinIO 一致。
    * `implemented_operators/0` —— 本 MVP 真正实现求值逻辑的子集：
      StringEquals / StringLike / Bool / IpAddress / DateGreaterThan。

  求值语义（`hold?/2`）：
    * Condition 块 = %{ operator => %{ key => value | [values] } }；所有 operator/key 项须全真（AND）。
    * 单 key 内 policy 值为数组 → 任一命中即真（OR）。
    * 缺失 key（请求未提供该条件键）→ 该项为 false（statement 不命中）。MVP 无 *IfExists/Null。
    * Bool 的 policy 值是字符串 "true"/"false"，与请求实际布尔比较。
    * IpAddress 支持单 IP（视为 /32）与 CIDR。
    * DateGreaterThan：请求时间 > policy ISO8601 时间。
    * **合法但未实现求值**的算子 → 保守判「不成立」（statement 不命中，绝不静默放行），
      但绝不在 PutBucketPolicy parse 期拒绝（那会破坏携带这些算子的合法客户端策略）。
  """
  import Bitwise

  # 本 MVP 真正实现求值的算子。
  @implemented ~w(StringEquals StringLike Bool IpAddress DateGreaterThan)

  # AWS/MinIO 全量合法算子（minio/pkg policy/condition/func.go 支持集 + 各 *IfExists 变体）。
  # parse 期只用它判断「是否为真实存在的 AWS/MinIO 算子」；不在此集合内才畸形。
  @base_operators ~w(
    StringEquals StringNotEquals StringEqualsIgnoreCase StringNotEqualsIgnoreCase
    StringLike StringNotLike
    BinaryEquals
    IpAddress NotIpAddress
    Null Bool
    NumericEquals NumericNotEquals
    NumericLessThan NumericLessThanEquals NumericGreaterThan NumericGreaterThanEquals
    DateEquals DateNotEquals
    DateLessThan DateLessThanEquals DateGreaterThan DateGreaterThanEquals
    ArnEquals ArnNotEquals ArnLike ArnNotLike
  )

  @known @base_operators ++ Enum.map(@base_operators, &(&1 <> "IfExists"))

  @doc "AWS/MinIO 全量合法 Condition 算子白名单（含 *IfExists 变体；PutBucketPolicy parse 期校验复用）。"
  @spec known_operators() :: [String.t()]
  def known_operators, do: @known

  @doc "本 MVP 真正实现求值逻辑的 Condition 算子集合。"
  @spec implemented_operators() :: [String.t()]
  def implemented_operators, do: @implemented

  @doc "Condition 块是否全部成立。conditions = 请求上下文条件键值 map。"
  @spec hold?(map() | nil, map()) :: boolean()
  def hold?(nil, _ctx), do: true
  def hold?(block, _ctx) when block == %{}, do: true

  def hold?(block, ctx) when is_map(block) do
    Enum.all?(block, fn {operator, kv} ->
      # 合法但未实现求值的算子（如 NumericLessThan）→ 保守判 false（不放行），但已在 parse 期接受。
      operator in @implemented and operator_holds?(operator, kv, ctx)
    end)
  end

  def hold?(_block, _ctx), do: false

  defp operator_holds?(op, kv, ctx) when is_map(kv) do
    Enum.all?(kv, fn {key, policy_val} ->
      case Map.fetch(ctx, key) do
        # 缺失条件键 → false（MVP 无 IfExists/Null）。
        :error -> false
        {:ok, req_val} -> eval(op, policy_val, req_val)
      end
    end)
  end

  defp operator_holds?(_op, _kv, _ctx), do: false

  # policy 值数组 → OR
  defp eval(op, policy_vals, req_val) when is_list(policy_vals) do
    Enum.any?(policy_vals, &eval(op, &1, req_val))
  end

  defp eval("StringEquals", policy_val, req_val) do
    to_string(policy_val) == to_string(req_val)
  end

  defp eval("StringLike", policy_val, req_val) do
    Maxio.Policy.Arn.glob_match?(to_string(policy_val), to_string(req_val))
  end

  defp eval("Bool", policy_val, req_val) do
    norm_bool(policy_val) == norm_bool(req_val)
  end

  defp eval("IpAddress", cidr, req_ip) when is_binary(req_ip) do
    ip_in_cidr?(req_ip, to_string(cidr))
  end

  defp eval("IpAddress", _cidr, _req_ip), do: false

  defp eval("DateGreaterThan", policy_iso, %DateTime{} = req_dt) do
    case DateTime.from_iso8601(to_string(policy_iso)) do
      {:ok, policy_dt, _} -> DateTime.compare(req_dt, policy_dt) == :gt
      _ -> false
    end
  end

  defp eval("DateGreaterThan", _policy, _req), do: false
  defp eval(_op, _policy, _req), do: false

  defp norm_bool(true), do: true
  defp norm_bool(false), do: false
  defp norm_bool("true"), do: true
  defp norm_bool("false"), do: false
  defp norm_bool(_), do: :invalid

  # req_ip 在 cidr 范围内（IPv4；单 IP 视为 /32）。解析失败 → false（保守）。
  defp ip_in_cidr?(req_ip, cidr) do
    with {:ok, req} <- parse_ipv4(req_ip),
         {:ok, {net, bits}} <- parse_cidr(cidr) do
      mask = mask_for(bits)
      band(req, mask) == band(net, mask)
    else
      _ -> false
    end
  end

  defp parse_cidr(cidr) do
    case String.split(cidr, "/", parts: 2) do
      [ip, bits_str] ->
        with {:ok, net} <- parse_ipv4(ip),
             {bits, ""} <- Integer.parse(bits_str),
             true <- bits >= 0 and bits <= 32 do
          {:ok, {net, bits}}
        else
          _ -> :error
        end

      [ip] ->
        case parse_ipv4(ip) do
          {:ok, net} -> {:ok, {net, 32}}
          _ -> :error
        end
    end
  end

  defp parse_ipv4(str) do
    case String.split(str, ".") do
      [a, b, c, d] ->
        with {oa, ""} <- Integer.parse(a),
             {ob, ""} <- Integer.parse(b),
             {oc, ""} <- Integer.parse(c),
             {od, ""} <- Integer.parse(d),
             true <- Enum.all?([oa, ob, oc, od], &(&1 >= 0 and &1 <= 255)) do
          {:ok, (oa <<< 24) + (ob <<< 16) + (oc <<< 8) + od}
        else
          _ -> :error
        end

      _ ->
        :error
    end
  end

  defp mask_for(0), do: 0
  defp mask_for(bits), do: band(bxor(0xFFFFFFFF, (1 <<< (32 - bits)) - 1), 0xFFFFFFFF)
end
