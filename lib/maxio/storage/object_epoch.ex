defmodule Maxio.Storage.ObjectEpoch do
  @moduledoc """
  对象变更 fencing epoch 的纯数据契约。

  本模块只负责 target、token、fingerprint、JSON 编解码和相对路径；不读写磁盘，
  后端必须在对象锁内实现 epoch 的 quorum claim 与持久化。
  """

  alias Maxio.Buckets
  alias Maxio.Cluster.Paths

  @format "maxio/object-epoch/1"
  @root ".maxio-object-epochs"
  @target_format "maxio/object-target/1"
  @phases ~w(claimed published committed rolled_back deleted quarantined)
  @value_types ~w(object delete_marker deleted)
  @uuid ~r/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i
  @sha256 ~r/^[0-9a-f]{64}$/
  @payload_keys ~w(fingerprint format operation phase previous_token target token updated_at value_type)

  @enforce_keys [:target, :token, :operation, :phase, :value_type, :updated_at]
  defstruct format: @format,
            target: nil,
            token: nil,
            operation: nil,
            phase: nil,
            value_type: nil,
            fingerprint: nil,
            previous_token: nil,
            updated_at: nil

  @type target :: %{required(String.t()) => String.t() | pos_integer()}
  @type token :: %{required(String.t()) => non_neg_integer() | String.t()}
  @type fingerprint :: %{required(String.t()) => non_neg_integer() | String.t()}
  @type t :: %__MODULE__{}

  @doc "构造对象版本 target；`version_id` 包括字面值 `null`。"
  @spec object_target(String.t(), String.t(), String.t()) :: {:ok, target()} | {:error, term()}
  def object_target(bucket, key, version_id) do
    with :ok <- validate_bucket(bucket),
         :ok <- Paths.validate_key(key),
         :ok <- validate_locator(version_id, :version_id) do
      {:ok,
       %{
         "kind" => "object_version",
         "bucket" => bucket,
         "key" => key,
         "version_id" => version_id
       }}
    end
  end

  @doc "构造 multipart upload target。"
  @spec upload_target(String.t(), String.t(), String.t()) :: {:ok, target()} | {:error, term()}
  def upload_target(bucket, key, upload_id) do
    with :ok <- validate_bucket(bucket),
         :ok <- Paths.validate_key(key),
         :ok <- validate_locator(upload_id, :upload_id) do
      {:ok,
       %{
         "kind" => "multipart_upload",
         "bucket" => bucket,
         "key" => key,
         "upload_id" => upload_id
       }}
    end
  end

  @doc "构造 multipart part target。"
  @spec part_target(String.t(), String.t(), String.t(), pos_integer()) ::
          {:ok, target()} | {:error, term()}
  def part_target(bucket, key, upload_id, part_number) do
    with {:ok, target} <- upload_target(bucket, key, upload_id),
         true <- is_integer(part_number) and part_number in 1..10_000 do
      {:ok,
       target
       |> Map.put("kind", "multipart_part")
       |> Map.put("part_number", part_number)}
    else
      false -> {:error, :invalid_part_number}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "构造 fencing token；UUID 会规范为小写。"
  @spec token(non_neg_integer(), String.t()) :: {:ok, token()} | {:error, term()}
  def token(generation, mutation_id)
      when is_integer(generation) and generation >= 0 and is_binary(mutation_id) do
    if Regex.match?(@uuid, mutation_id) do
      {:ok, %{"generation" => generation, "mutation_id" => String.downcase(mutation_id)}}
    else
      {:error, :invalid_mutation_id}
    end
  end

  def token(_generation, _mutation_id), do: {:error, :invalid_token}

  @doc "按 `{generation, mutation_id}` 全序比较 token。"
  @spec compare_tokens(map(), map()) :: {:ok, :lt | :eq | :gt} | {:error, :invalid_token}
  def compare_tokens(left, right) do
    with {:ok, left} <- normalize_token(left),
         {:ok, right} <- normalize_token(right) do
      left_key = {left["generation"], left["mutation_id"]}
      right_key = {right["generation"], right["mutation_id"]}

      cond do
        left_key < right_key -> {:ok, :lt}
        left_key > right_key -> {:ok, :gt}
        true -> {:ok, :eq}
      end
    end
  end

  @doc "生成已发布值的精确 fingerprint；sidecar 哈希针对实际落盘字节。"
  @spec fingerprint(String.t(), non_neg_integer(), binary()) :: fingerprint()
  def fingerprint(etag, size, sidecar_bytes)
      when is_binary(etag) and is_integer(size) and size >= 0 and is_binary(sidecar_bytes) do
    %{
      "etag" => etag,
      "size" => size,
      "sidecar_sha256" => sha256_hex(sidecar_bytes)
    }
  end

  @doc "只有三个字段完全一致才视为同一个已发布值。"
  @spec fingerprint_matches?(fingerprint(), fingerprint()) :: boolean()
  def fingerprint_matches?(expected, actual) when is_map(expected) and is_map(actual) do
    with {:ok, expected} <- normalize_fingerprint(expected),
         {:ok, actual} <- normalize_fingerprint(actual) do
      expected == actual
    else
      {:error, _reason} -> false
    end
  end

  def fingerprint_matches?(_expected, _actual), do: false

  @doc "构造并校验 epoch。"
  @spec new(target(), token(), map()) :: {:ok, t()} | {:error, term()}
  def new(target, token, attrs) when is_map(attrs) do
    operation = value(attrs, :operation)
    phase = value(attrs, :phase)
    value_type = value(attrs, :value_type)
    fingerprint = value(attrs, :fingerprint)
    previous_token = value(attrs, :previous_token)
    updated_at = value(attrs, :updated_at)

    with {:ok, target} <- normalize_target(target),
         {:ok, token} <- normalize_token(token),
         :ok <- validate_nonempty(operation, :operation),
         :ok <- validate_member(phase, @phases, :phase),
         :ok <- validate_member(value_type, @value_types, :value_type),
         {:ok, fingerprint} <- normalize_fingerprint(fingerprint),
         :ok <- validate_published_fingerprint(phase, fingerprint),
         {:ok, previous_token} <- normalize_optional_token(previous_token),
         {:ok, updated_at} <- normalize_datetime(updated_at) do
      {:ok,
       %__MODULE__{
         target: target,
         token: token,
         operation: operation,
         phase: phase,
         value_type: value_type,
         fingerprint: fingerprint,
         previous_token: previous_token,
         updated_at: updated_at
       }}
    end
  end

  @doc "编码稳定版本标识的 JSON payload。"
  @spec encode(t()) :: {:ok, binary()} | {:error, term()}
  def encode(%__MODULE__{format: @format} = epoch) do
    with {:ok, epoch} <-
           new(epoch.target, epoch.token, %{
             operation: epoch.operation,
             phase: epoch.phase,
             value_type: epoch.value_type,
             fingerprint: epoch.fingerprint,
             previous_token: epoch.previous_token,
             updated_at: epoch.updated_at
           }) do
      Jason.encode(%{
        "format" => epoch.format,
        "target" => epoch.target,
        "token" => epoch.token,
        "operation" => epoch.operation,
        "phase" => epoch.phase,
        "value_type" => epoch.value_type,
        "fingerprint" => epoch.fingerprint,
        "previous_token" => epoch.previous_token,
        "updated_at" => DateTime.to_iso8601(epoch.updated_at)
      })
    end
  end

  def encode(%__MODULE__{format: format}), do: {:error, {:unsupported_epoch_format, format}}

  @doc "解码并完整重验 epoch；未知格式不会被静默接受。"
  @spec decode(binary()) :: {:ok, t()} | {:error, term()}
  def decode(bytes) when is_binary(bytes) do
    with {:ok, payload} when is_map(payload) <- Jason.decode(bytes),
         @format <- Map.get(payload, "format"),
         :ok <- validate_payload_keys(payload),
         {:ok, epoch} <-
           new(Map.get(payload, "target"), Map.get(payload, "token"), %{
             operation: Map.get(payload, "operation"),
             phase: Map.get(payload, "phase"),
             value_type: Map.get(payload, "value_type"),
             fingerprint: Map.get(payload, "fingerprint"),
             previous_token: Map.get(payload, "previous_token"),
             updated_at: Map.get(payload, "updated_at")
           }) do
      {:ok, epoch}
    else
      {:ok, _non_map} -> {:error, :invalid_epoch_payload}
      nil -> {:error, :invalid_epoch_format}
      format when is_binary(format) -> {:error, {:unsupported_epoch_format, format}}
      {:error, reason} -> {:error, reason}
      _other -> {:error, :invalid_epoch_format}
    end
  end

  @doc "计算 target 在每个 drive 下的 Unix 风格相对 epoch 路径。"
  @spec relative_path(target()) :: {:ok, String.t()} | {:error, term()}
  def relative_path(target) do
    with {:ok, target} <- normalize_target(target),
         {:ok, digest} <- target_digest(target) do
      shard = binary_part(digest, 0, 2)

      {:ok,
       join([
         @root,
         "v1",
         target["bucket"],
         target["kind"],
         shard,
         digest,
         "epoch.json"
       ])}
    end
  end

  @doc "按带长度前缀的固定字段序列编码 canonical target bytes。"
  @spec canonical_target_bytes(target()) :: {:ok, binary()} | {:error, term()}
  def canonical_target_bytes(target) do
    with {:ok, target} <- normalize_target(target) do
      identity =
        case target do
          %{"kind" => "object_version"} ->
            [frame(target["version_id"])]

          %{"kind" => "multipart_upload"} ->
            [frame(target["upload_id"])]

          %{"kind" => "multipart_part"} ->
            [frame(target["upload_id"]), frame(<<target["part_number"]::unsigned-big-64>>)]
        end

      {:ok,
       IO.iodata_to_binary([
         frame(@target_format),
         frame(target["kind"]),
         frame(target["bucket"]),
         frame(target["key"]),
         identity
       ])}
    end
  end

  @doc "计算 canonical target bytes 的小写 SHA-256。"
  @spec target_digest(target()) :: {:ok, String.t()} | {:error, term()}
  def target_digest(target) do
    with {:ok, bytes} <- canonical_target_bytes(target), do: {:ok, sha256_hex(bytes)}
  end

  defp normalize_target(
         %{
           "kind" => "object_version",
           "bucket" => bucket,
           "key" => key,
           "version_id" => version_id
         } = target
       )
       when map_size(target) == 4,
       do: object_target(bucket, key, version_id)

  defp normalize_target(
         %{
           "kind" => "multipart_upload",
           "bucket" => bucket,
           "key" => key,
           "upload_id" => upload_id
         } = target
       )
       when map_size(target) == 4,
       do: upload_target(bucket, key, upload_id)

  defp normalize_target(
         %{
           "kind" => "multipart_part",
           "bucket" => bucket,
           "key" => key,
           "upload_id" => upload_id,
           "part_number" => part_number
         } = target
       )
       when map_size(target) == 5,
       do: part_target(bucket, key, upload_id, part_number)

  defp normalize_target(_target), do: {:error, :invalid_target}

  defp normalize_token(%{"generation" => generation, "mutation_id" => mutation_id} = proposed)
       when map_size(proposed) == 2 do
    case token(generation, mutation_id) do
      {:ok, ^proposed} -> {:ok, proposed}
      _other -> {:error, :invalid_token}
    end
  end

  defp normalize_token(_token), do: {:error, :invalid_token}
  defp normalize_optional_token(nil), do: {:ok, nil}
  defp normalize_optional_token(token), do: normalize_token(token)

  defp normalize_fingerprint(nil), do: {:ok, nil}

  defp normalize_fingerprint(fingerprint) when is_map(fingerprint) do
    etag = value(fingerprint, :etag)
    size = value(fingerprint, :size)
    sidecar_sha256 = value(fingerprint, :sidecar_sha256)

    if map_size(fingerprint) == 3 and is_binary(etag) and etag != "" and
         is_integer(size) and size >= 0 and is_binary(sidecar_sha256) and
         Regex.match?(@sha256, sidecar_sha256) do
      {:ok,
       %{
         "etag" => etag,
         "size" => size,
         "sidecar_sha256" => String.downcase(sidecar_sha256)
       }}
    else
      {:error, :invalid_fingerprint}
    end
  end

  defp normalize_fingerprint(_fingerprint), do: {:error, :invalid_fingerprint}

  defp validate_published_fingerprint(phase, nil) when phase in ~w(published committed),
    do: {:error, :missing_published_fingerprint}

  defp validate_published_fingerprint(_phase, _fingerprint), do: :ok

  defp normalize_datetime(%DateTime{} = datetime), do: {:ok, datetime}

  defp normalize_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, 0} -> {:ok, datetime}
      _other -> {:error, :invalid_updated_at}
    end
  end

  defp normalize_datetime(_value), do: {:error, :invalid_updated_at}

  defp validate_bucket(bucket), do: Buckets.validate_name(bucket)

  defp validate_locator(value, field) when is_binary(value) do
    if String.trim(value) == "", do: {:error, {:invalid_locator, field}}, else: :ok
  end

  defp validate_locator(_value, field), do: {:error, {:invalid_locator, field}}

  defp validate_nonempty(value, field) when is_binary(value) do
    if String.trim(value) == "", do: {:error, {:invalid_field, field}}, else: :ok
  end

  defp validate_nonempty(_value, field), do: {:error, {:invalid_field, field}}

  defp validate_member(value, allowed, field) do
    if value in allowed, do: :ok, else: {:error, {:invalid_field, field}}
  end

  defp join(parts), do: Enum.join(parts, "/")
  defp frame(bytes) when is_binary(bytes), do: [<<byte_size(bytes)::unsigned-big-32>>, bytes]
  defp sha256_hex(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

  defp validate_payload_keys(payload) do
    if Map.keys(payload) |> Enum.sort() == @payload_keys,
      do: :ok,
      else: {:error, :invalid_epoch_payload}
  end

  defp value(map, key) when is_map(map),
    do: Map.get(map, Atom.to_string(key), Map.get(map, key))
end
