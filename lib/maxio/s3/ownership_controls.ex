defmodule Maxio.S3.OwnershipControls do
  @moduledoc """
  Bucket-level S3 Object Ownership helpers.

  New buckets persist the modern S3 default, BucketOwnerEnforced. Buckets with no
  stored OwnershipControls row keep maxio's legacy ACL-enabled behavior, which is
  also what DeleteBucketOwnershipControls exposes for compatibility.
  """
  import Plug.Conn, only: [get_req_header: 2]

  alias Maxio.BucketConfigs
  alias Maxio.Buckets.Bucket
  alias Maxio.Policy.ACL
  alias Maxio.S3.Error

  @values ~w(BucketOwnerEnforced BucketOwnerPreferred ObjectWriter)
  @default "ObjectWriter"
  @create_default "BucketOwnerEnforced"

  @spec values() :: [String.t()]
  def values, do: @values

  @spec create_default() :: String.t()
  def create_default, do: @create_default

  @spec normalize(map()) :: map()
  def normalize(config) when is_map(config) do
    value =
      config["ObjectOwnership"] ||
        config[:object_ownership] ||
        config[:ObjectOwnership] ||
        @default

    %{"ObjectOwnership" => to_string(value)}
  end

  @spec valid_value?(term()) :: boolean()
  def valid_value?(value), do: value in @values

  @spec get_config(String.t()) :: {:ok, map()} | :none
  def get_config(bucket) when is_binary(bucket) do
    case BucketConfigs.get(bucket, :ownership_controls) do
      {:ok, config} -> {:ok, normalize(config)}
      :none -> :none
    end
  end

  @spec object_ownership(String.t()) :: String.t()
  def object_ownership(bucket) do
    case get_config(bucket) do
      {:ok, %{"ObjectOwnership" => value}} -> value
      :none -> @default
    end
  end

  @spec bucket_owner_enforced?(String.t()) :: boolean()
  def bucket_owner_enforced?(bucket), do: object_ownership(bucket) == "BucketOwnerEnforced"

  @spec effective_acl(String.t(), String.t(), term()) :: {String.t(), map()}
  def effective_acl(bucket, canned, grants_doc) do
    if bucket_owner_enforced?(bucket) do
      {"private", ACL.empty_grants_doc()}
    else
      {canned || "private", grants_doc_or_empty(grants_doc)}
    end
  end

  @spec reject_invalid_bucket_acl_for_enforced!(String.t(), Bucket.t(), map()) :: :ok
  def reject_invalid_bucket_acl_for_enforced!(bucket, %Bucket{} = bucket_meta, config) do
    if normalize(config)["ObjectOwnership"] == "BucketOwnerEnforced" and
         not owner_only_bucket_acl?(bucket_meta) do
      raise Error.new(:invalid_bucket_acl_with_object_ownership, resource: "/" <> bucket)
    end

    :ok
  end

  @spec reject_acl_input_for_enforced!(String.t(), map(), %{
          canned: String.t(),
          grants_doc: term()
        }) ::
          :ok
  def reject_acl_input_for_enforced!(bucket, config, %{canned: canned, grants_doc: grants_doc}) do
    if normalize(config)["ObjectOwnership"] == "BucketOwnerEnforced" and
         not owner_only_acl?(canned, grants_doc) do
      raise Error.new(:invalid_bucket_acl_with_object_ownership, resource: "/" <> bucket)
    end

    :ok
  end

  @spec reject_acl_update!(String.t()) :: :ok
  def reject_acl_update!(bucket) do
    if bucket_owner_enforced?(bucket), do: raise_acl_not_supported!(bucket)
    :ok
  end

  @spec reject_object_acl_headers!(String.t(), Plug.Conn.t(), %{
          canned: String.t(),
          grants_doc: term()
        }) ::
          :ok
  def reject_object_acl_headers!(bucket, conn, %{canned: canned, grants_doc: grants_doc}) do
    if bucket_owner_enforced?(bucket) and explicit_acl_headers?(conn) and
         not bucket_owner_full_control_only?(canned, grants_doc) do
      raise_acl_not_supported!(bucket)
    end

    :ok
  end

  defp explicit_acl_headers?(conn) do
    get_req_header(conn, "x-amz-acl") != [] or ACL.grant_headers?(conn.req_headers)
  end

  defp bucket_owner_full_control_only?("bucket-owner-full-control", grants_doc) do
    ACL.grants_from_doc(grants_doc) == []
  end

  defp bucket_owner_full_control_only?(_canned, _grants_doc), do: false

  defp owner_only_bucket_acl?(%Bucket{acl_canned: canned, acl_grants: grants_doc}) do
    owner_only_acl?(canned, grants_doc)
  end

  defp owner_only_acl?(canned, grants_doc),
    do: (is_nil(canned) or canned == "private") and ACL.grants_from_doc(grants_doc) == []

  defp grants_doc_or_empty(%{"grants" => grants}) when is_list(grants), do: %{"grants" => grants}
  defp grants_doc_or_empty(%{grants: grants}) when is_list(grants), do: %{"grants" => grants}
  defp grants_doc_or_empty(_), do: ACL.empty_grants_doc()

  defp raise_acl_not_supported!(bucket) do
    raise Error.new(:access_control_list_not_supported, resource: "/" <> bucket)
  end
end
