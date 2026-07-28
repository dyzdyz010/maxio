defmodule Maxio.BucketQuota do
  @moduledoc """
  Bucket hard quota configuration and write-path enforcement.

  Quota is stored in `bucket_configs.quota` and enforced from object metadata
  writes. The enforcement path locks the bucket config row inside the metadata
  transaction, so concurrent writes to different keys serialize on the quota row
  before the projected usage is accepted.
  """

  import Ecto.Query

  alias Maxio.BucketConfigs
  alias Maxio.BucketConfigs.BucketConfig
  alias Maxio.Objects.Object
  alias Maxio.Repo
  alias Maxio.S3.Error

  @type config :: %{required(String.t()) => term()}

  @max_size_bytes 9_223_372_036_854_775_807

  @spec max_size_bytes() :: pos_integer()
  def max_size_bytes, do: @max_size_bytes

  @spec get(String.t()) :: {:ok, config()} | :none | {:error, :invalid_quota}
  def get(bucket) when is_binary(bucket) do
    case BucketConfigs.get(bucket, :quota) do
      {:ok, config} -> normalize_config(config)
      :none -> :none
    end
  end

  @spec put_hard(String.t(), pos_integer()) :: :ok | {:error, term()}
  def put_hard(bucket, size_bytes) when is_binary(bucket) and is_integer(size_bytes) do
    case validate_size(size_bytes) do
      :ok ->
        BucketConfigs.put(bucket, :quota, %{"type" => "hard", "size_bytes" => size_bytes})

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec delete(String.t()) :: :ok
  def delete(bucket) when is_binary(bucket), do: BucketConfigs.delete(bucket, :quota)

  @spec usage(String.t()) :: non_neg_integer()
  def usage(bucket) when is_binary(bucket), do: usage(bucket, Repo)

  @spec ensure_write_allowed!(module(), String.t(), String.t(), String.t(), non_neg_integer()) ::
          :ok
  def ensure_write_allowed!(repo, bucket, key, version_id, new_size)
      when is_binary(bucket) and is_binary(key) and is_binary(version_id) and
             is_integer(new_size) and new_size >= 0 do
    case locked_quota(repo, bucket) do
      :none ->
        :ok

      {:ok, %{"type" => "hard", "size_bytes" => limit}} ->
        current = usage(bucket, repo)
        replaced = existing_version_size(repo, bucket, key, version_id)
        projected = current - replaced + new_size

        if projected > limit do
          raise Error.new(:bucket_quota_exceeded,
                  message:
                    "Bucket quota exceeded: projected usage #{projected} bytes is greater than #{limit} bytes.",
                  resource: "/" <> bucket,
                  extra: %{
                    "QuotaBytes" => Integer.to_string(limit),
                    "CurrentBytes" => Integer.to_string(current),
                    "ProjectedBytes" => Integer.to_string(projected)
                  }
                )
        end

        :ok

      {:error, :invalid_quota} ->
        raise Error.new(:invalid_bucket_state,
                message: "Bucket quota configuration is invalid.",
                resource: "/" <> bucket
              )
    end
  end

  @spec validate_size(term()) :: :ok | {:error, :invalid_quota}
  def validate_size(size) when is_integer(size) and size in 1..@max_size_bytes, do: :ok
  def validate_size(_size), do: {:error, :invalid_quota}

  defp locked_quota(repo, bucket) do
    from(c in BucketConfig,
      where: c.bucket_name == ^bucket,
      select: c.quota,
      lock: "FOR UPDATE"
    )
    |> repo.one()
    |> normalize_config_or_none()
  end

  defp normalize_config_or_none(nil), do: :none
  defp normalize_config_or_none(config), do: normalize_config(config)

  defp normalize_config(%{"type" => "hard", "size_bytes" => size})
       when is_integer(size) and size in 1..@max_size_bytes do
    {:ok, %{"type" => "hard", "size_bytes" => size}}
  end

  defp normalize_config(%{"type" => "hard", "size_bytes" => size}) when is_binary(size) do
    case Integer.parse(size) do
      {int, ""} -> normalize_config(%{"type" => "hard", "size_bytes" => int})
      _other -> {:error, :invalid_quota}
    end
  end

  defp normalize_config(_config), do: {:error, :invalid_quota}

  defp usage(bucket, repo) do
    from(o in Object,
      where: o.bucket_name == ^bucket and not o.is_delete_marker,
      select: sum(o.size)
    )
    |> repo.one()
    |> sum_to_integer()
  end

  defp existing_version_size(repo, bucket, key, version_id) do
    from(o in Object,
      where:
        o.bucket_name == ^bucket and o.key == ^key and o.version_id == ^version_id and
          not o.is_delete_marker,
      select: o.size,
      limit: 1
    )
    |> repo.one()
    |> case do
      nil -> 0
      size when is_integer(size) -> size
    end
  end

  defp sum_to_integer(nil), do: 0
  defp sum_to_integer(%Decimal{} = value), do: Decimal.to_integer(value)
  defp sum_to_integer(value) when is_integer(value), do: value
end
