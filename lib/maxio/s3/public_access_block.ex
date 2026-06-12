defmodule Maxio.S3.PublicAccessBlock do
  @moduledoc """
  Bucket-level S3 PublicAccessBlock helpers.

  只实现 bucket 级配置；AWS 的 account / organization / access point 叠加层后续再接入。
  语义依据 AWS S3 Block Public Access：
    * BlockPublicAcls 拒绝新公共 ACL 写入。
    * IgnorePublicAcls 忽略 bucket/object 上的公共 ACL 授权，但不改持久化 ACL。
    * BlockPublicPolicy 拒绝会公开访问的 bucket policy 写入。
    * RestrictPublicBuckets 对已存在公共 bucket policy 过滤公共 Allow statement。
  """
  alias Maxio.BucketConfigs
  alias Maxio.Policy.{ACL, Statement}
  alias Maxio.S3.Error

  @keys [
    "BlockPublicAcls",
    "IgnorePublicAcls",
    "BlockPublicPolicy",
    "RestrictPublicBuckets"
  ]
  @defaults Map.new(@keys, &{&1, false})

  @fixed_condition_keys ~w(
    aws:PrincipalOrgID
    aws:SourceIp
    aws:SourceArn
    aws:SourceVpc
    aws:SourceVpce
    aws:SourceOwner
    aws:SourceAccount
    aws:userid
    s3:DataAccessPointArn
    s3:DataAccessPointAccount
  )

  @fixed_condition_ops ~w(
    StringEquals
    ArnEquals
    IpAddress
    ForAnyValue:StringEquals
    ForAnyValue:ArnEquals
  )

  @spec keys() :: [String.t()]
  def keys, do: @keys

  @spec defaults() :: map()
  def defaults, do: @defaults

  @spec normalize(map()) :: map()
  def normalize(config) when is_map(config) do
    Enum.reduce(@keys, @defaults, fn key, acc ->
      Map.put(acc, key, truthy?(Map.get(config, key) || Map.get(config, atom_key(key))))
    end)
  end

  @spec get_config(String.t()) :: {:ok, map()} | :none
  def get_config(bucket) when is_binary(bucket) do
    case BucketConfigs.get(bucket, :public_access_block) do
      {:ok, config} -> {:ok, normalize(config)}
      :none -> :none
    end
  end

  @spec block_public_acls?(String.t()) :: boolean()
  def block_public_acls?(bucket), do: enabled?(bucket, "BlockPublicAcls")

  @spec ignore_public_acls?(String.t()) :: boolean()
  def ignore_public_acls?(bucket), do: enabled?(bucket, "IgnorePublicAcls")

  @spec block_public_policy?(String.t()) :: boolean()
  def block_public_policy?(bucket), do: enabled?(bucket, "BlockPublicPolicy")

  @spec restrict_public_buckets?(String.t()) :: boolean()
  def restrict_public_buckets?(bucket), do: enabled?(bucket, "RestrictPublicBuckets")

  @spec reject_public_acl_write!(String.t(), %{canned: String.t(), grants_doc: term()}) :: :ok
  def reject_public_acl_write!(bucket, %{canned: canned, grants_doc: grants_doc}) do
    if block_public_acls?(bucket) and ACL.public_acl?(canned, grants_doc) do
      raise Error.new(:access_denied,
              message: "Access denied because public ACLs are blocked by PublicAccessBlock",
              resource: "/" <> bucket
            )
    end

    :ok
  end

  @spec effective_acl(String.t(), String.t(), term()) :: {String.t(), map()}
  def effective_acl(bucket, canned, grants_doc) do
    if ignore_public_acls?(bucket) do
      ACL.without_public_access(canned, grants_doc)
    else
      {canned || "private", normalize_grants_doc(grants_doc)}
    end
  end

  @spec reject_public_policy_write!(String.t(), [Statement.t()]) :: :ok
  def reject_public_policy_write!(bucket, statements) do
    if block_public_policy?(bucket) and public_policy?(statements) do
      raise Error.new(:access_denied,
              message:
                "Access denied because public bucket policies are blocked by PublicAccessBlock",
              resource: "/" <> bucket
            )
    end

    :ok
  end

  @spec effective_bucket_policy_statements(String.t(), [Statement.t()]) :: [Statement.t()]
  def effective_bucket_policy_statements(bucket, statements) do
    if restrict_public_buckets?(bucket) and public_policy?(statements) do
      Enum.reject(statements, &allow_statement?/1)
    else
      statements
    end
  end

  @spec public_policy?([Statement.t()]) :: boolean()
  def public_policy?(statements) when is_list(statements),
    do: Enum.any?(statements, &public_allow?/1)

  defp enabled?(bucket, key) do
    case get_config(bucket) do
      {:ok, config} -> Map.get(config, key, false)
      :none -> false
    end
  end

  defp public_allow?(%Statement{effect: :allow, principals: :any} = statement),
    do: not fixed_limited?(statement)

  defp public_allow?(%Statement{effect: :allow, principals: {:aws, principals}}),
    do: Enum.any?(principals, &wildcard_or_variable?/1)

  defp public_allow?(_statement), do: false

  defp allow_statement?(%Statement{effect: :allow}), do: true
  defp allow_statement?(_statement), do: false

  defp fixed_limited?(%Statement{conditions: conditions}) when is_map(conditions) do
    Enum.any?(conditions, fn
      {op, key_values} when op in @fixed_condition_ops and is_map(key_values) ->
        Enum.any?(key_values, fn {key, value} ->
          key in @fixed_condition_keys and fixed_condition_value?(key, value)
        end)

      _ ->
        false
    end)
  end

  defp fixed_limited?(_statement), do: false

  defp fixed_condition_value?(key, values) when is_list(values),
    do: values != [] and Enum.all?(values, &fixed_condition_value?(key, &1))

  defp fixed_condition_value?("aws:SourceIp", value) when is_binary(value),
    do: fixed_string?(value) and fixed_source_ip?(value)

  defp fixed_condition_value?(_key, value) when is_binary(value), do: fixed_string?(value)
  defp fixed_condition_value?(_key, _value), do: false

  defp fixed_string?(value) do
    value = String.trim(value)
    value != "" and not String.contains?(value, ["*", "?", "${"])
  end

  defp fixed_source_ip?(value) do
    cond do
      String.contains?(value, ":") -> cidr_prefix_at_least?(value, 32)
      String.contains?(value, ".") -> cidr_prefix_at_least?(value, 8)
      true -> false
    end
  end

  defp cidr_prefix_at_least?(value, minimum) do
    case String.split(value, "/", parts: 2) do
      [_addr] ->
        true

      [_addr, prefix] ->
        case Integer.parse(prefix) do
          {n, ""} -> n >= minimum
          _ -> false
        end
    end
  end

  defp wildcard_or_variable?(value) when is_binary(value),
    do: String.contains?(value, ["*", "?", "${"])

  defp wildcard_or_variable?(_), do: false

  defp normalize_grants_doc(%{"grants" => grants}) when is_list(grants), do: %{"grants" => grants}
  defp normalize_grants_doc(%{grants: grants}) when is_list(grants), do: %{"grants" => grants}
  defp normalize_grants_doc(_), do: ACL.empty_grants_doc()

  defp truthy?(true), do: true
  defp truthy?(false), do: false

  defp truthy?(value) when is_binary(value) do
    value |> String.trim() |> String.downcase() |> Kernel.==("true")
  end

  defp truthy?(_value), do: false

  defp atom_key("BlockPublicAcls"), do: :block_public_acls
  defp atom_key("IgnorePublicAcls"), do: :ignore_public_acls
  defp atom_key("BlockPublicPolicy"), do: :block_public_policy
  defp atom_key("RestrictPublicBuckets"), do: :restrict_public_buckets
end
