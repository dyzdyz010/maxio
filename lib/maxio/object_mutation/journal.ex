defmodule Maxio.ObjectMutation.Journal do
  @moduledoc "对象变更协议的一次持久化执行记录；阶段只能由 CAS context 推进。"

  use Ecto.Schema
  import Ecto.Changeset

  alias Maxio.DurableJSON
  alias Maxio.Storage.ObjectEpoch

  @type t :: %__MODULE__{}
  @phases ~w(prepared claimed published metadata_committed finalize_pending finalized rollback_pending rolled_back quarantined)
  @target_kinds ~w(object_version multipart_upload multipart_part)
  @authority_modes ~w(pg sidecar)
  @json_fields ~w(placement_snapshot previous_epoch published_fingerprint recovery_evidence)a
  @epoch_keys ~w(fingerprint format operation phase previous_token target token updated_at value_type)
  @fingerprint_phases ~w(published metadata_committed finalize_pending finalized)
  @sha256 ~r/^[0-9a-f]{64}$/

  # design D6 冻结的 Journal 调用 profile。root-zero 深度 15 与既有 root-one、
  # `depth > 16` 拒绝语义完全等价（leaf 在 m 层嵌套下旧为 depth m+1、新为 depth m），
  # 不得暗中扩缩可接受的嵌套。
  @durable_profile [max_depth: 15, max_encoded_bytes: 65_536]

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "object_mutations" do
    field :target_kind, :string
    field :bucket_name, :string
    field :object_key, :string
    field :version_id, :string
    field :upload_id, :string
    field :part_number, :integer
    field :generation, :integer
    field :operation, :string
    field :authority_mode, :string
    field :phase, :string, default: "prepared"
    field :backend, :string
    field :placement_snapshot, :map
    field :previous_epoch, :map
    field :published_fingerprint, :map
    field :recovery_evidence, :map
    field :attempts, :integer, default: 0
    field :next_attempt_at, :utc_datetime_usec
    field :lease_owner, :string
    field :lease_expires_at, :utc_datetime_usec
    field :last_error, :string
    field :metadata_committed_at, :utc_datetime_usec
    field :finalized_at, :utc_datetime_usec
    field :rolled_back_at, :utc_datetime_usec
    field :quarantined_at, :utc_datetime_usec
    timestamps(type: :utc_datetime_usec)
  end

  @required ~w(target_kind bucket_name object_key generation operation authority_mode phase backend attempts next_attempt_at)a
  @optional ~w(version_id upload_id part_number placement_snapshot previous_epoch published_fingerprint recovery_evidence lease_owner lease_expires_at last_error metadata_committed_at finalized_at rolled_back_at quarantined_at)a

  @spec phases() :: [String.t()]
  def phases, do: @phases

  @doc """
  journal JSON 列的既有 string-key / JSON-safe / depth / 65,536-byte 门，可在 changeset
  之外独立复用。

  `request_rollback/3` 需要它：当调用方提交的 evidence 与已观察值逐字相同时，changeset
  不会把该列计为 change，`validate_change/3` 因而不会运行——但尺寸/JSON 门必须照常判定
  已观察到的取证 term。
  """
  @spec json_evidence_valid?(term()) :: boolean()
  def json_evidence_valid?(value), do: json_object(value) == :ok

  @doc false
  # schema 权威的 exact fingerprint 形态谓词，供 `request_rollback/3` 的信任边界复用：
  # 绝不在 ObjectMutation 里复制第二套 etag/size/sidecar_sha256 schema。
  @spec fingerprint_valid?(term()) :: boolean()
  def fingerprint_valid?(value), do: valid_fingerprint?(value)

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(journal, attrs) do
    journal
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> validate_inclusion(:phase, @phases)
    |> validate_inclusion(:target_kind, @target_kinds)
    |> validate_inclusion(:authority_mode, @authority_modes)
    |> validate_number(:generation, greater_than_or_equal_to: 0)
    |> validate_number(:attempts, greater_than_or_equal_to: 0)
    |> validate_number(:part_number, greater_than: 0, less_than_or_equal_to: 10_000)
    |> validate_format(:operation, ~r/\S/)
    |> validate_format(:backend, ~r/\S/)
    |> validate_target_shape()
    |> validate_json_fields()
    |> validate_previous_epoch()
    |> validate_published_fingerprint()
    |> check_constraint(:lease_owner, name: :object_mutations_lease_pair_check)
    |> check_constraint(:object_key, name: :object_mutations_locator_nonblank_check)
    |> check_constraint(:phase, name: :object_mutations_phase_timestamp_check)
    |> check_constraint(:published_fingerprint,
      name: :object_mutations_published_fingerprint_check
    )
  end

  defp validate_target_shape(changeset) do
    case get_field(changeset, :target_kind) do
      "object_version" ->
        changeset
        |> forbid_fields([:upload_id, :part_number])
        |> validate_epoch_target(:object_version)

      "multipart_upload" ->
        changeset
        |> forbid_fields([:version_id, :part_number])
        |> validate_epoch_target(:multipart_upload)

      "multipart_part" ->
        changeset
        |> forbid_fields([:version_id])
        |> validate_epoch_target(:multipart_part)

      _other ->
        changeset
    end
  end

  defp validate_epoch_target(changeset, :object_version) do
    validate_epoch_target_result(
      changeset,
      ObjectEpoch.object_target(
        get_field(changeset, :bucket_name),
        get_field(changeset, :object_key),
        get_field(changeset, :version_id)
      )
    )
  end

  defp validate_epoch_target(changeset, :multipart_upload) do
    validate_epoch_target_result(
      changeset,
      ObjectEpoch.upload_target(
        get_field(changeset, :bucket_name),
        get_field(changeset, :object_key),
        get_field(changeset, :upload_id)
      )
    )
  end

  defp validate_epoch_target(changeset, :multipart_part) do
    validate_epoch_target_result(
      changeset,
      ObjectEpoch.part_target(
        get_field(changeset, :bucket_name),
        get_field(changeset, :object_key),
        get_field(changeset, :upload_id),
        get_field(changeset, :part_number)
      )
    )
  end

  defp validate_epoch_target_result(changeset, {:ok, _target}), do: changeset

  defp validate_epoch_target_result(changeset, {:error, :invalid_bucket_name}),
    do: add_error(changeset, :bucket_name, "is not a valid S3 bucket name")

  defp validate_epoch_target_result(changeset, {:error, reason})
       when reason in [:invalid_key, :key_too_long],
       do: add_error(changeset, :object_key, "is not a valid S3 object key")

  defp validate_epoch_target_result(changeset, {:error, {:invalid_locator, field}}),
    do: add_error(changeset, field, "can't be blank")

  defp validate_epoch_target_result(changeset, {:error, :invalid_part_number}),
    do: add_error(changeset, :part_number, "must be between 1 and 10000")

  defp validate_epoch_target_result(changeset, {:error, _reason}),
    do: add_error(changeset, :target_kind, "has invalid target identity")

  defp forbid_fields(changeset, fields) do
    Enum.reduce(fields, changeset, fn field, acc ->
      if is_nil(get_field(acc, field)) do
        acc
      else
        add_error(acc, field, "is not valid for this target kind")
      end
    end)
  end

  defp validate_json_fields(changeset) do
    Enum.reduce(@json_fields, changeset, fn field, acc ->
      validate_change(acc, field, fn ^field, value ->
        case json_object(value) do
          :ok -> []
          {:error, message} -> [{field, message}]
        end
      end)
    end)
  end

  defp validate_previous_epoch(changeset) do
    validate_change(changeset, :previous_epoch, fn :previous_epoch, epoch ->
      valid? =
        Map.keys(epoch) |> Enum.sort() == @epoch_keys and
          match?({:ok, _}, Jason.encode(epoch)) and
          match?({:ok, %ObjectEpoch{}}, epoch |> Jason.encode!() |> ObjectEpoch.decode())

      if valid?,
        do: [],
        else: [previous_epoch: "must be a complete maxio/object-epoch/1 payload"]
    end)
  end

  defp validate_published_fingerprint(changeset) do
    changeset =
      validate_change(changeset, :published_fingerprint, fn
        :published_fingerprint, fingerprint ->
          if valid_fingerprint?(fingerprint),
            do: [],
            else: [
              published_fingerprint: "must be an exact etag/size/sidecar_sha256 fingerprint"
            ]
      end)

    if get_field(changeset, :phase) in @fingerprint_phases and
         not valid_fingerprint?(get_field(changeset, :published_fingerprint)) do
      add_error(changeset, :published_fingerprint, "is required after publish")
    else
      changeset
    end
  end

  defp valid_fingerprint?(
         %{"etag" => etag, "size" => size, "sidecar_sha256" => sidecar_sha256} =
           fingerprint
       ) do
    map_size(fingerprint) == 3 and is_binary(etag) and etag != "" and
      is_integer(size) and size >= 0 and is_binary(sidecar_sha256) and
      Regex.match?(@sha256, sidecar_sha256)
  end

  defp valid_fingerprint?(_fingerprint), do: false

  # Journal 的 JSONB 列 root 必须是 map：中立 helper 允许 scalar/list root，schema 不允许。
  # 除此之外，durable domain 的唯一事实来源是共享的 `Maxio.DurableJSON`——本模块不再保留
  # 第二套 traversal，避免两处规则悄悄分叉。
  defp json_object(value) when is_map(value) do
    case DurableJSON.validate(value, @durable_profile) do
      {:ok, _encoded} ->
        :ok

      {:error, :invalid_durable_json} ->
        {:error, "must use string keys and JSON-safe values within depth/size limits"}
    end
  end

  defp json_object(_value), do: {:error, "must be a JSON object"}
end
