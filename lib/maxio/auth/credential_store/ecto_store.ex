defmodule Maxio.Auth.CredentialStore.EctoStore do
  @moduledoc """
  Postgres 凭据后端（铁律 1：实现既有 CredentialStore behaviour，换后端不动鉴权逻辑）。
  get_secret 按 access_key_id 查 active 密钥，返回 %{secret_key, principal}；
  principal map 形态与 MemoryStore 对齐（%{type, access_key, arn}）。inactive/缺失 → :error。
  """
  @behaviour Maxio.Auth.CredentialStore

  import Ecto.Query
  alias Maxio.Repo
  alias Maxio.IAM.AccessKey

  @impl true
  def get_secret(access_key) do
    case Repo.get_by(AccessKey, access_key_id: access_key, status: "active") do
      nil ->
        :error

      %AccessKey{} = row ->
        principal = %{
          type: String.to_existing_atom(row.type),
          access_key: row.access_key_id,
          arn: row.principal_arn
        }

        {:ok, %{secret_key: row.secret_key, principal: principal}}
    end
  end

  @impl true
  def put_access_key(%{access_key: ak, secret_key: sk} = attrs) do
    type = Map.get(attrs, :type, "iam_user")

    arn =
      Map.get(attrs, :arn) ||
        if type == "root", do: "arn:aws:iam:::root", else: "arn:aws:iam:::user/#{ak}"

    %AccessKey{}
    |> AccessKey.changeset(%{
      access_key_id: ak,
      secret_key: sk,
      principal_arn: arn,
      type: to_string(type),
      status: "active"
    })
    |> Repo.insert(
      on_conflict: {:replace, [:secret_key, :principal_arn, :type, :status, :updated_at]},
      conflict_target: :access_key_id
    )
    |> case do
      {:ok, _} -> :ok
      {:error, cs} -> {:error, cs}
    end
  end

  def put_access_key(_), do: {:error, :invalid_attrs}

  @impl true
  def list_keys do
    Repo.all(from(a in AccessKey))
    |> Enum.map(fn a ->
      %{
        access_key: a.access_key_id,
        principal: %{
          type: String.to_existing_atom(a.type),
          access_key: a.access_key_id,
          arn: a.principal_arn
        }
      }
    end)
  end
end
