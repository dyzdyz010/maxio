defmodule Maxio.Policy.Store.EctoStore do
  @moduledoc """
  Postgres 策略后端（实现 Maxio.Policy.Store behaviour）。document 存 jsonb（解析后的 map），
  get 时 Jason.encode! 回放为 JSON 字节（round-trip 语义等价）。principal_policies/1 读取绑定到
  principal ARN 的 identity policy，并与 bucket policy / ACL 一起交给统一 Evaluator。
  """
  @behaviour Maxio.Policy.Store

  import Ecto.Query

  alias Maxio.Repo
  alias Maxio.Policy.{BucketPolicy, PrincipalPolicy, Statement}

  @impl true
  def get_bucket_policy(bucket) do
    case Repo.get_by(BucketPolicy, bucket_name: bucket) do
      nil -> :none
      %BucketPolicy{document: doc} -> {:ok, Jason.encode!(doc)}
    end
  end

  @impl true
  def put_bucket_policy(bucket, json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, %{} = doc} ->
        %BucketPolicy{}
        |> BucketPolicy.changeset(%{bucket_name: bucket, document: doc})
        |> Repo.insert(
          on_conflict: {:replace, [:document, :updated_at]},
          conflict_target: :bucket_name
        )
        |> case do
          {:ok, _} -> :ok
          {:error, cs} -> {:error, cs}
        end

      _ ->
        {:error, :malformed}
    end
  end

  @impl true
  def delete_bucket_policy(bucket) do
    Repo.delete_all(from p in BucketPolicy, where: p.bucket_name == ^bucket)
    :ok
  end

  @impl true
  def principal_policies(:anonymous), do: []

  def principal_policies(%{arn: principal_arn}) when is_binary(principal_arn) do
    from(p in PrincipalPolicy,
      where: p.principal_arn == ^principal_arn,
      order_by: [asc: p.policy_name]
    )
    |> Repo.all()
    |> Enum.flat_map(fn %PrincipalPolicy{document: doc, policy_name: name} ->
      doc
      |> Jason.encode!()
      |> Statement.parse_identity_policy()
      |> case do
        {:ok, statements} ->
          statements

        {:error, _} ->
          require Logger

          Logger.warning("stored principal policy failed to parse",
            principal_arn: principal_arn,
            policy_name: name
          )

          []
      end
    end)
  end

  def principal_policies(_principal), do: []

  @impl true
  def put_principal_policy(principal_arn, name, json)
      when is_binary(principal_arn) and is_binary(name) and is_binary(json) do
    with {:ok, statements} <- Statement.parse_identity_policy(json),
         true <- statements != [],
         {:ok, %{} = doc} <- Jason.decode(json) do
      %PrincipalPolicy{}
      |> PrincipalPolicy.changeset(%{
        principal_arn: principal_arn,
        policy_name: name,
        document: doc
      })
      |> Repo.insert(
        on_conflict: {:replace, [:document, :updated_at]},
        conflict_target: [:principal_arn, :policy_name]
      )
      |> case do
        {:ok, _} -> :ok
        {:error, cs} -> {:error, cs}
      end
    else
      _ -> {:error, :malformed}
    end
  end

  def put_principal_policy(_principal_arn, _name, _json), do: {:error, :malformed}

  @impl true
  def delete_principal_policy(principal_arn, name)
      when is_binary(principal_arn) and is_binary(name) do
    Repo.delete_all(
      from p in PrincipalPolicy,
        where: p.principal_arn == ^principal_arn and p.policy_name == ^name
    )

    :ok
  end

  def delete_principal_policy(_principal_arn, _name), do: :ok

  @impl true
  def list_principal_policies(principal_arn) when is_binary(principal_arn) do
    from(p in PrincipalPolicy,
      where: p.principal_arn == ^principal_arn,
      order_by: [asc: p.policy_name]
    )
    |> Repo.all()
    |> Enum.map(fn p ->
      %{
        principal_arn: p.principal_arn,
        policy_name: p.policy_name,
        document: p.document
      }
    end)
  end

  def list_principal_policies(_principal_arn), do: []
end
