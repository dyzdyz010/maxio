defmodule Maxio.IAM do
  @moduledoc """
  访问密钥生命周期 context（铁律 4：CLI 可观测）。root 从 config 引导（boot 幂等 upsert）；
  create/list/delete access key。底层走 EctoStore（持久化）。principal map 形态与 MemoryStore 对齐：
    root     → %{type: :root, access_key: ak, arn: "arn:aws:iam:::root"}
    iam_user → %{type: :iam_user, access_key: ak, arn: "arn:aws:iam:::user/<ak>"}
  """
  import Ecto.Query
  alias Maxio.Repo
  alias Maxio.IAM.AccessKey

  @doc "从 config :maxio, :s3 的 root_user/root_password 幂等引导 root（boot 调用）。"
  @spec bootstrap_root() :: :ok
  def bootstrap_root do
    s3 = Application.fetch_env!(:maxio, :s3)
    ak = Keyword.fetch!(s3, :root_user)
    sk = Keyword.fetch!(s3, :root_password)

    %AccessKey{}
    |> AccessKey.changeset(%{
      access_key_id: ak,
      secret_key: sk,
      principal_arn: "arn:aws:iam:::root",
      type: "root",
      status: "active"
    })
    |> Repo.insert(
      on_conflict: {:replace, [:secret_key, :principal_arn, :type, :status, :updated_at]},
      conflict_target: :access_key_id
    )

    :ok
  end

  @doc "创建 access key。opts: :access_key_id（默认随机）、:secret_key（默认随机）、:type（默认 iam_user）。"
  @spec create_access_key(keyword()) :: {:ok, map()} | {:error, term()}
  def create_access_key(opts \\ []) do
    ak = Keyword.get(opts, :access_key_id) || gen_access_key_id()
    sk = Keyword.get(opts, :secret_key) || gen_secret_key()
    type = Keyword.get(opts, :type, "iam_user")
    arn = if type == "root", do: "arn:aws:iam:::root", else: "arn:aws:iam:::user/#{ak}"

    case %AccessKey{}
         |> AccessKey.changeset(%{
           access_key_id: ak,
           secret_key: sk,
           principal_arn: arn,
           type: type,
           status: "active"
         })
         |> Repo.insert() do
      {:ok, row} ->
        {:ok, %{access_key_id: row.access_key_id, secret_key: sk, principal_arn: arn, type: type}}

      {:error, cs} ->
        {:error, cs}
    end
  end

  @doc "列出全部 access key（不回 secret）。"
  @spec list_access_keys() :: [map()]
  def list_access_keys do
    Repo.all(from a in AccessKey, order_by: [asc: a.inserted_at])
    |> Enum.map(fn a ->
      %{
        access_key_id: a.access_key_id,
        principal_arn: a.principal_arn,
        type: a.type,
        status: a.status
      }
    end)
  end

  @doc "删除 access key（幂等）。拒绝删除最后一个 root（避免锁死，铁律 3 不静默放行也不让系统不可用）。"
  @spec delete_access_key(String.t()) :: :ok | {:error, :cannot_delete_last_root}
  def delete_access_key(access_key_id) do
    case Repo.get_by(AccessKey, access_key_id: access_key_id) do
      nil ->
        :ok

      %AccessKey{type: "root"} = row ->
        root_count = Repo.aggregate(from(a in AccessKey, where: a.type == "root"), :count, :id)

        if root_count <= 1 do
          {:error, :cannot_delete_last_root}
        else
          Repo.delete!(row)
          :ok
        end

      %AccessKey{} = row ->
        Repo.delete!(row)
        :ok
    end
  end

  defp gen_access_key_id,
    do: "AKIA" <> (:crypto.strong_rand_bytes(8) |> Base.encode32(padding: false))

  defp gen_secret_key, do: :crypto.strong_rand_bytes(30) |> Base.encode64() |> binary_part(0, 40)
end
