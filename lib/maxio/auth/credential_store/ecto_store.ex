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
          arn: row.principal_arn,
          tags: row.tags || %{}
        }

        {:ok, %{secret_key: row.secret_key, principal: principal}}
    end
  end

  @impl true
  def put_access_key(%{access_key: ak, secret_key: sk} = attrs) do
    principal = Map.get(attrs, :principal, %{})
    type = principal |> Map.get(:type, Map.get(attrs, :type, "iam_user")) |> to_string()

    arn =
      Map.get(principal, :arn) ||
        Map.get(attrs, :arn) ||
        if type == "root", do: "arn:aws:iam:::root", else: "arn:aws:iam:::user/#{ak}"

    tags =
      attrs
      |> Map.get(:tags, Map.get(principal, :tags, %{}))
      |> normalize_tags()

    %AccessKey{}
    |> AccessKey.changeset(%{
      access_key_id: ak,
      secret_key: sk,
      principal_arn: arn,
      type: type,
      status: "active",
      tags: tags
    })
    |> Repo.insert(
      on_conflict: {:replace, [:secret_key, :principal_arn, :type, :status, :tags, :updated_at]},
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
          arn: a.principal_arn,
          tags: a.tags || %{}
        }
      }
    end)
  end

  @impl true
  def invalidate(_scope), do: :ok

  defp normalize_tags(tags) when is_map(tags) do
    Map.new(tags, fn {key, value} -> {to_string(key), tag_value(value)} end)
  end

  defp normalize_tags(_tags), do: %{}

  defp tag_value(nil), do: ""
  defp tag_value(value), do: to_string(value)
end
