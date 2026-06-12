defmodule Maxio.Policy.Condition do
  @moduledoc """
  策略 Condition 块求值（铁律 5，对齐官方条件算子语义）。

  这里区分两套算子集合（解耦「能否接受」与「能否求值」，对齐 minio condition.UnmarshalJSON）：

    * `known_operators/0` —— **AWS/MinIO 条件算子白名单**（基础算子 + `*IfExists` 变体 +
      `ForAnyValue:`/`ForAllValues:` 集合限定符）。
      PutBucketPolicy parse 期只拒绝**真正不存在于 AWS/MinIO**的算子（→ 400 MalformedPolicy）；
    * `implemented_operators/0` —— 本模块已实现求值逻辑的算子集合。String/Arn/Date/Numeric
      正反向比较、Bool、IpAddress/NotIpAddress、Null、`*IfExists` 与集合限定符均可求值。

  求值语义（`hold?/2`）：
    * Condition 块 = %{ operator => %{ key => value | [values] } }；所有 operator/key 项须全真（AND）。
    * 单 key 内 policy 值为数组 → 任一命中即真（OR）；请求上下文值也可为数组。
    * `ForAnyValue:` 要求至少一个请求值满足条件；缺失 key 或空请求值为 false（除非带 `IfExists`）。
    * `ForAllValues:` 要求所有请求值满足条件；缺失 key 或空请求值按 AWS 语义为 true
      （需要强制存在时由 `Null` 另行约束）。
    * 缺失 key（请求未提供该条件键）→ 正向算子为 false，否定算子（如 StringNotEquals）
      为 true；`*IfExists` 缺失为 true；`Null` 按存在性/null dataset 判断。
    * Bool 的 policy 值是字符串 "true"/"false"，与请求实际布尔比较。
    * IpAddress 支持 IPv4/IPv6 单 IP（视为 /32 或 /128）与 CIDR。
    * Date 算子支持请求上下文中的 DateTime、ISO8601 字符串或 Unix epoch 秒。
    * 真正未知或无法解析的值 → 保守判 false（statement 不命中，绝不静默放行）。
  """
  import Bitwise
  alias Maxio.Policy.Variables

  # AWS/MinIO 条件基础算子。Null 不存在 IfExists 变体（AWS 文档明确 IfExists 不适用于 Null）。
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

  @if_exists_operators Enum.reject(@base_operators, &(&1 == "Null"))
  @if_exists_operator_variants Enum.map(@if_exists_operators, &(&1 <> "IfExists"))
  @operator_variants @base_operators ++ @if_exists_operator_variants
  @set_operator_prefixes ["ForAnyValue:", "ForAllValues:"]
  @set_operators for prefix <- @set_operator_prefixes,
                     op <- @if_exists_operators ++ @if_exists_operator_variants,
                     do: prefix <> op
  @known @operator_variants ++ @set_operators
  @implemented @known

  @negated_operators ~w(
    StringNotEquals StringNotEqualsIgnoreCase StringNotLike
    NotIpAddress
    NumericNotEquals
    DateNotEquals
    ArnNotEquals ArnNotLike
  )

  @positive_for_negated %{
    "StringNotEquals" => "StringEquals",
    "StringNotEqualsIgnoreCase" => "StringEqualsIgnoreCase",
    "StringNotLike" => "StringLike",
    "NotIpAddress" => "IpAddress",
    "NumericNotEquals" => "NumericEquals",
    "DateNotEquals" => "DateEquals",
    "ArnNotEquals" => "ArnEquals",
    "ArnNotLike" => "ArnLike"
  }

  @variable_condition_operators ~w(
    StringEquals StringNotEquals StringEqualsIgnoreCase StringNotEqualsIgnoreCase
    StringLike StringNotLike
    ArnEquals ArnNotEquals ArnLike ArnNotLike
  )

  @doc "AWS/MinIO 合法 Condition 算子白名单（含 *IfExists 与集合限定符；PutBucketPolicy parse 期校验复用）。"
  @spec known_operators() :: [String.t()]
  def known_operators, do: @known

  @doc "当前真正实现求值逻辑的 Condition 算子集合。"
  @spec implemented_operators() :: [String.t()]
  def implemented_operators, do: @implemented

  @doc "Condition 块是否全部成立。conditions = 请求上下文条件键值 map。"
  @spec hold?(map() | nil, map(), keyword()) :: boolean()
  def hold?(block, ctx, opts \\ [])
  def hold?(nil, _ctx, _opts), do: true
  def hold?(block, _ctx, _opts) when block == %{}, do: true

  def hold?(block, ctx, opts) when is_map(block) do
    variables_enabled? = Keyword.get(opts, :variables_enabled?, true)

    Enum.all?(block, fn {operator, kv} ->
      operator in @implemented and operator_holds?(operator, kv, ctx, variables_enabled?)
    end)
  end

  def hold?(_block, _ctx, _opts), do: false

  defp operator_holds?(op, kv, ctx, variables_enabled?) when is_map(kv) and map_size(kv) > 0 do
    {base_op, if_exists?, set_qualifier} = normalize_operator(op)

    Enum.all?(kv, fn {key, policy_val} ->
      case Map.fetch(ctx, key) do
        :error ->
          missing_key_holds?(
            base_op,
            if_exists?,
            set_qualifier,
            policy_val,
            ctx,
            variables_enabled?
          )

        {:ok, req_val} ->
          eval(base_op, policy_val, req_val, set_qualifier, ctx, variables_enabled?)
      end
    end)
  end

  defp operator_holds?(_op, _kv, _ctx, _variables_enabled?), do: false

  defp normalize_operator(op) do
    {set_qualifier, op_without_set} = normalize_set_operator(op)
    {base_op, if_exists?} = normalize_if_exists(op_without_set)

    {base_op, if_exists?, set_qualifier}
  end

  defp normalize_set_operator("ForAnyValue:" <> op), do: {:any, op}
  defp normalize_set_operator("ForAllValues:" <> op), do: {:all, op}
  defp normalize_set_operator(op), do: {nil, op}

  defp normalize_if_exists(op) do
    if String.ends_with?(op, "IfExists") do
      {String.replace_suffix(op, "IfExists", ""), true}
    else
      {op, false}
    end
  end

  defp missing_key_holds?(
         "Null",
         _if_exists?,
         _set_qualifier,
         policy_val,
         _ctx,
         _variables_enabled?
       ),
       do: eval_null(policy_val, :missing)

  defp missing_key_holds?(
         op,
         true = _if_exists?,
         _set_qualifier,
         policy_val,
         ctx,
         variables_enabled?
       ),
       do: policy_values_parseable?(op, policy_val, ctx, variables_enabled?)

  defp missing_key_holds?(op, false = _if_exists?, :all, policy_val, ctx, variables_enabled?),
    do: policy_values_parseable?(op, policy_val, ctx, variables_enabled?)

  defp missing_key_holds?(_op, false = _if_exists?, :any, _policy_val, _ctx, _variables_enabled?),
    do: false

  defp missing_key_holds?(op, false = _if_exists?, nil, policy_val, ctx, variables_enabled?) do
    op in @negated_operators and policy_values_parseable?(op, policy_val, ctx, variables_enabled?)
  end

  defp eval("Null", policy_val, req_val, _set_qualifier, _ctx, _variables_enabled?),
    do: eval_null(policy_val, request_value_presence(req_val))

  defp eval(op, policy_val, req_val, nil, ctx, variables_enabled?) do
    req_vals = values(req_val)
    policy_vals = policy_values(op, policy_val, ctx, variables_enabled?)

    req_vals != [] and policy_vals != [] and
      if op in @negated_operators do
        Enum.all?(req_vals, &request_value_holds?(op, policy_vals, &1))
      else
        Enum.any?(req_vals, &request_value_holds?(op, policy_vals, &1))
      end
  end

  defp eval(op, policy_val, req_val, :any, ctx, variables_enabled?) do
    req_vals = set_values(req_val)
    policy_vals = policy_values(op, policy_val, ctx, variables_enabled?)

    req_vals != [] and policy_vals != [] and
      Enum.any?(req_vals, &request_value_holds?(op, policy_vals, &1))
  end

  defp eval(op, policy_val, req_val, :all, ctx, variables_enabled?) do
    req_vals = set_values(req_val)
    policy_vals = policy_values(op, policy_val, ctx, variables_enabled?)

    req_vals == [] or
      (policy_vals != [] and Enum.all?(req_vals, &request_value_holds?(op, policy_vals, &1)))
  end

  defp values(list) when is_list(list), do: list
  defp values(nil), do: []
  defp values(value), do: [value]

  defp policy_values(_op, value, _ctx, false = _variables_enabled?), do: values(value)
  defp policy_values(_op, value, nil, true = _variables_enabled?), do: values(value)

  defp policy_values(op, value, ctx, true = _variables_enabled?)
       when op in @variable_condition_operators,
       do: value |> values() |> Enum.map(&Variables.expand_condition_value(&1, ctx))

  defp policy_values(_op, value, _ctx, true = _variables_enabled?), do: values(value)

  defp policy_values_parseable?(op, policy_val, ctx, variables_enabled?) do
    vals = policy_values(op, policy_val, ctx, variables_enabled?)
    vals != [] and Enum.all?(vals, &policy_value_parseable?(op, &1))
  end

  defp policy_value_parseable?(op, value) do
    if Variables.unresolved?(value) do
      true
    else
      policy_value_parseable_resolved(op, value)
    end
  end

  defp policy_value_parseable_resolved(op, value) when op in @negated_operators do
    @positive_for_negated
    |> Map.fetch!(op)
    |> policy_value_parseable_resolved(value)
  end

  defp policy_value_parseable_resolved(op, value)
       when op in ["StringEquals", "StringEqualsIgnoreCase", "BinaryEquals"],
       do: match?({:ok, _}, scalar_string(value))

  defp policy_value_parseable_resolved(op, value)
       when op in ["StringLike", "ArnEquals", "ArnLike"],
       do: match?({:ok, _}, scalar_pattern_string(value))

  defp policy_value_parseable_resolved("Bool", value), do: norm_bool(value) != :invalid

  defp policy_value_parseable_resolved("IpAddress", value) do
    with {:ok, cidr_str} <- scalar_string(value),
         {:ok, _parsed} <- parse_cidr(cidr_str) do
      true
    else
      _ -> false
    end
  end

  defp policy_value_parseable_resolved(op, value)
       when op in [
              "NumericEquals",
              "NumericLessThan",
              "NumericLessThanEquals",
              "NumericGreaterThan",
              "NumericGreaterThanEquals"
            ],
       do: match?({:ok, _}, parse_number(value))

  defp policy_value_parseable_resolved(op, value)
       when op in [
              "DateEquals",
              "DateLessThan",
              "DateLessThanEquals",
              "DateGreaterThan",
              "DateGreaterThanEquals"
            ],
       do: match?({:ok, _}, parse_datetime(value))

  defp policy_value_parseable_resolved(_op, _value), do: false

  defp set_values(list) when is_list(list), do: Enum.reject(list, &null_dataset_value?/1)
  defp set_values(value), do: if(null_dataset_value?(value), do: [], else: [value])

  defp null_dataset_value?(nil), do: true
  defp null_dataset_value?(""), do: true
  defp null_dataset_value?([]), do: true
  defp null_dataset_value?(_value), do: false

  defp request_value_holds?(op, policy_vals, req_val) when op in @negated_operators do
    positive_op = Map.fetch!(@positive_for_negated, op)

    Enum.all?(policy_vals, fn policy_val ->
      case positive_match_result(positive_op, policy_val, req_val) do
        {:ok, true} -> false
        {:ok, false} -> true
        :error -> false
      end
    end)
  end

  defp request_value_holds?(op, policy_vals, req_val) do
    Enum.any?(policy_vals, &positive_match?(op, &1, req_val))
  end

  defp positive_match?(op, policy_val, req_val) do
    case positive_match_result(op, policy_val, req_val) do
      {:ok, true} -> true
      _ -> false
    end
  end

  defp positive_match_result(op, policy_val, req_val) do
    if Variables.unresolved?(policy_val) do
      {:ok, false}
    else
      positive_match_result_resolved(op, policy_val, req_val)
    end
  end

  defp positive_match_result_resolved(op, policy_val, req_val)
       when op in ["StringEquals", "BinaryEquals"] do
    with {:ok, policy_str} <- scalar_string(policy_val),
         {:ok, req_str} <- scalar_string(req_val) do
      {:ok, policy_str == req_str}
    else
      _ -> :error
    end
  end

  defp positive_match_result_resolved("StringEqualsIgnoreCase", policy_val, req_val) do
    with {:ok, policy_str} <- scalar_string(policy_val),
         {:ok, req_str} <- scalar_string(req_val) do
      {:ok, String.downcase(policy_str) == String.downcase(req_str)}
    else
      _ -> :error
    end
  end

  defp positive_match_result_resolved(op, policy_val, req_val)
       when op in ["StringLike", "ArnEquals", "ArnLike"] do
    with {:ok, policy_str} <- scalar_pattern_string(policy_val),
         {:ok, req_str} <- scalar_string(req_val) do
      {:ok, Maxio.Policy.Arn.glob_match?(policy_str, req_str)}
    else
      _ -> :error
    end
  end

  defp positive_match_result_resolved("Bool", policy_val, req_val) do
    policy_bool = norm_bool(policy_val)
    req_bool = norm_bool(req_val)

    if policy_bool == :invalid or req_bool == :invalid do
      :error
    else
      {:ok, policy_bool == req_bool}
    end
  end

  defp positive_match_result_resolved("IpAddress", cidr, req_ip) do
    with {:ok, cidr_str} <- scalar_string(cidr),
         true <- is_binary(req_ip),
         {:ok, req} <- parse_ip(req_ip),
         {:ok, {net, bits}} <- parse_cidr(cidr_str) do
      {:ok, same_ip_family?(req, net) and ip_in_prefix?(req, net, bits)}
    else
      _ -> :error
    end
  end

  defp positive_match_result_resolved(op, policy_val, req_val)
       when op in [
              "NumericEquals",
              "NumericLessThan",
              "NumericLessThanEquals",
              "NumericGreaterThan",
              "NumericGreaterThanEquals"
            ] do
    with {:ok, policy_num} <- parse_number(policy_val),
         {:ok, req_num} <- parse_number(req_val) do
      {:ok, compare_number(op, req_num, policy_num)}
    else
      _ -> :error
    end
  end

  defp positive_match_result_resolved(op, policy_val, req_val)
       when op in [
              "DateEquals",
              "DateLessThan",
              "DateLessThanEquals",
              "DateGreaterThan",
              "DateGreaterThanEquals"
            ] do
    with {:ok, policy_dt} <- parse_datetime(policy_val),
         {:ok, req_dt} <- parse_datetime(req_val) do
      {:ok, compare_datetime(op, req_dt, policy_dt)}
    else
      _ -> :error
    end
  end

  defp positive_match_result_resolved(_op, _policy, _req), do: :error

  defp scalar_string(value) when is_binary(value), do: {:ok, Variables.render_literals(value)}
  defp scalar_string(value) when is_boolean(value), do: {:ok, to_string(value)}
  defp scalar_string(value) when is_integer(value) or is_float(value), do: {:ok, to_string(value)}
  defp scalar_string(_value), do: :error

  defp scalar_pattern_string(value) when is_binary(value), do: {:ok, value}
  defp scalar_pattern_string(value) when is_boolean(value), do: {:ok, to_string(value)}

  defp scalar_pattern_string(value) when is_integer(value) or is_float(value),
    do: {:ok, to_string(value)}

  defp scalar_pattern_string(_value), do: :error

  defp request_value_presence(req_val) when is_list(req_val) do
    if set_values(req_val) == [], do: :null, else: :present
  end

  defp request_value_presence(req_val),
    do: if(null_dataset_value?(req_val), do: :null, else: :present)

  defp eval_null(policy_val, presence) do
    case norm_bool(policy_val) do
      true -> presence in [:missing, :null]
      false -> presence == :present
      _invalid -> false
    end
  end

  defp parse_number(value) when is_integer(value) or is_float(value), do: {:ok, value / 1}

  defp parse_number(value) do
    with {:ok, value_str} <- scalar_string(value),
         {number, ""} <- Float.parse(value_str) do
      {:ok, number}
    else
      _ -> :error
    end
  end

  defp compare_number("NumericEquals", req, policy), do: req == policy
  defp compare_number("NumericLessThan", req, policy), do: req < policy
  defp compare_number("NumericLessThanEquals", req, policy), do: req <= policy
  defp compare_number("NumericGreaterThan", req, policy), do: req > policy
  defp compare_number("NumericGreaterThanEquals", req, policy), do: req >= policy

  defp parse_datetime(%DateTime{} = dt), do: {:ok, dt}

  defp parse_datetime(value) when is_integer(value), do: DateTime.from_unix(value)

  defp parse_datetime(value) do
    with {:ok, value_str} <- scalar_string(value) do
      case DateTime.from_iso8601(value_str) do
        {:ok, dt, _offset} -> {:ok, dt}
        _ -> parse_epoch_time(value_str)
      end
    else
      _ -> :error
    end
  end

  defp parse_epoch_time(value) do
    case Integer.parse(value) do
      {unix, ""} -> DateTime.from_unix(unix)
      _ -> :error
    end
  end

  defp compare_datetime("DateEquals", req, policy), do: DateTime.compare(req, policy) == :eq
  defp compare_datetime("DateLessThan", req, policy), do: DateTime.compare(req, policy) == :lt

  defp compare_datetime("DateLessThanEquals", req, policy),
    do: DateTime.compare(req, policy) in [:lt, :eq]

  defp compare_datetime("DateGreaterThan", req, policy), do: DateTime.compare(req, policy) == :gt

  defp compare_datetime("DateGreaterThanEquals", req, policy),
    do: DateTime.compare(req, policy) in [:gt, :eq]

  defp norm_bool(true), do: true
  defp norm_bool(false), do: false
  defp norm_bool("true"), do: true
  defp norm_bool("false"), do: false
  defp norm_bool(_), do: :invalid

  defp parse_cidr(cidr) do
    case String.split(cidr, "/", parts: 2) do
      [ip, bits_str] ->
        with {:ok, net} <- parse_ip(ip),
             {bits, ""} <- Integer.parse(bits_str),
             true <- bits >= 0 and bits <= net.max_bits do
          {:ok, {net, bits}}
        else
          _ -> :error
        end

      [ip] ->
        case parse_ip(ip) do
          {:ok, net} -> {:ok, {net, net.max_bits}}
          _ -> :error
        end
    end
  end

  defp parse_ip(str) do
    with {:ok, tuple} <- :inet.parse_address(String.to_charlist(str)) do
      tuple_to_ip(tuple)
    else
      _ -> :error
    end
  end

  defp tuple_to_ip({a, b, c, d}) do
    int = Enum.reduce([a, b, c, d], 0, fn octet, acc -> (acc <<< 8) + octet end)
    {:ok, %{family: :ipv4, int: int, max_bits: 32}}
  end

  defp tuple_to_ip({a, b, c, d, e, f, g, h}) do
    int = Enum.reduce([a, b, c, d, e, f, g, h], 0, fn segment, acc -> (acc <<< 16) + segment end)
    {:ok, %{family: :ipv6, int: int, max_bits: 128}}
  end

  defp tuple_to_ip(_tuple), do: :error

  defp same_ip_family?(left, right), do: left.family == right.family

  defp ip_in_prefix?(req, net, 0), do: req.max_bits == net.max_bits

  defp ip_in_prefix?(req, net, bits) do
    mask = mask_for(req.max_bits, bits)
    band(req.int, mask) == band(net.int, mask)
  end

  defp mask_for(max_bits, bits),
    do: band(bxor((1 <<< max_bits) - 1, (1 <<< (max_bits - bits)) - 1), (1 <<< max_bits) - 1)
end
