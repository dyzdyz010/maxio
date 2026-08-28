defmodule Maxio.IAM.AdminGroupProjectionTest do
  use Maxio.DataCase, async: false

  import Ecto.Query

  alias Maxio.IAM
  alias Maxio.IAM.User
  alias Maxio.Policy.ManagedPolicy

  @document %{
    "Version" => "2012-10-17",
    "Statement" => [
      %{"Effect" => "Allow", "Action" => "s3:ListAllMyBuckets", "Resource" => "*"}
    ]
  }

  test "one aggregate statement returns stable canonical projection and omission evidence" do
    assert {:ok, _zeta} = IAM.create_user(name: "zeta")
    assert {:ok, _alpha} = IAM.create_user(name: "Alpha")

    assert {:ok, created} =
             IAM.update_minio_group_members_strict(
               "devs",
               ["zeta", "ALPHA", "zeta"],
               false,
               ""
             )

    assert :ok = IAM.put_group_policy("devs", "inline-z", Jason.encode!(@document))
    assert :ok = IAM.put_group_policy("devs", "inline-a", Jason.encode!(@document))

    root_z = create_policy!("z-policy", "/")
    root_a = create_policy!("a-policy", "/")
    nested = create_policy!("hidden-policy", "/team/")
    assert :ok = IAM.attach_group_policy("devs", root_z.policy_arn)
    assert :ok = IAM.attach_group_policy("devs", nested.policy_arn)
    assert :ok = IAM.attach_group_policy("devs", root_a.policy_arn)

    owner = self()
    handler_id = {__MODULE__, make_ref()}

    :ok =
      :telemetry.attach(
        handler_id,
        [:maxio, :repo, :query],
        fn _event, _measurements, metadata, test_pid ->
          if String.contains?(metadata.query, "maxio_admin_group_description") do
            send(test_pid, {:group_projection_query, metadata.query, metadata.params})
          end
        end,
        owner
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    assert {:ok, description} = IAM.get_minio_group_description_strict("DEVS")
    assert_receive {:group_projection_query, sql, ["devs"]}
    refute_receive {:group_projection_query, _sql, _params}
    assert sql =~ "jsonb_agg"

    assert description.group_name == "devs"
    assert description.status == "active"
    assert description.updated_at == created.updated_at
    assert description.member_names == ["Alpha", "zeta"]
    assert description.managed_policy_names == ["a-policy", "z-policy"]
    assert description.inline_policy_names == ["inline-a", "inline-z"]
    assert description.non_root_managed_policy_names == ["team/hidden-policy"]
    assert description.evidence.snapshot == "single statement"
    assert description.evidence.member_order == "maxio-sorted-unique-members"
  end

  test "empty projection normalizes SQL null aggregates and missing uses group domain" do
    assert {:ok, group} = IAM.create_group(name: "empty", status: "inactive")

    assert {:ok, description} = IAM.get_minio_group_description_strict("empty")
    assert description.group_name == "empty"
    assert description.status == "inactive"
    assert description.updated_at == group.updated_at
    assert description.member_names == []
    assert description.managed_policy_names == []
    assert description.inline_policy_names == []
    assert description.non_root_managed_policy_names == []

    assert {:error, :group_not_found} = IAM.get_minio_group_description_strict("missing")
  end

  test "list uses one query, bytewise sorts names, and includes disabled groups" do
    assert {:ok, _group} = IAM.create_group(name: "z-group", status: "active")
    assert {:ok, _group} = IAM.create_group(name: "A-group", status: "inactive")

    owner = self()
    handler_id = {__MODULE__, :list, make_ref()}

    :ok =
      :telemetry.attach(
        handler_id,
        [:maxio, :repo, :query],
        fn _event, _measurements, metadata, test_pid ->
          if String.contains?(metadata.query, "maxio_admin_group_names") do
            send(test_pid, {:group_names_query, metadata.query})
          end
        end,
        owner
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    assert {:ok, ["A-group", "z-group"]} = IAM.list_minio_group_names()
    assert_receive {:group_names_query, query}
    assert query =~ ~s(COLLATE "C")
    refute_receive {:group_names_query, _query}
  end

  test "phase drift after the aggregate statement cannot tear members and policies" do
    suffix = Base.url_encode64(:crypto.strong_rand_bytes(6), padding: false)
    group_name = "snapshot-group-#{suffix}"
    first_name = "snapshot-a-#{suffix}"
    second_name = "snapshot-b-#{suffix}"
    policy_name = "snapshot-policy-#{suffix}"

    {first, second, policy} =
      unboxed(fn ->
        {:ok, first} = IAM.create_user(name: first_name)
        {:ok, second} = IAM.create_user(name: second_name)

        {:ok, _created} =
          IAM.update_minio_group_members_strict(group_name, [first_name], false, "")

        policy = create_policy!(policy_name, "/")
        {first, second, policy}
      end)

    on_exit(fn ->
      unboxed(fn ->
        :ok = IAM.delete_group(group_name)
        Repo.delete_all(from(u in User, where: u.id in ^[first.id, second.id]))
        Repo.delete_all(from(p in ManagedPolicy, where: p.policy_arn == ^policy.policy_arn))
      end)
    end)

    owner = self()
    barrier = make_ref()
    handler_id = {__MODULE__, :phase_drift, barrier}

    :ok =
      :telemetry.attach(
        handler_id,
        [:maxio, :iam, :admin_group_projection, :phase],
        fn _event, _measurements, metadata, {test_pid, ref, expected_group} ->
          if metadata.phase == :after_read and metadata.group_name == expected_group do
            send(test_pid, {:projection_after_read, ref, self()})

            receive do
              {:release_projection, ^ref} -> :ok
            after
              5_000 -> raise "projection phase barrier timed out"
            end
          end
        end,
        {owner, barrier, group_name}
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    task =
      Task.async(fn ->
        unboxed(fn -> IAM.get_minio_group_description_strict(group_name) end)
      end)

    assert_receive {:projection_after_read, ^barrier, projection_pid}, 5_000

    unboxed(fn ->
      assert {:ok, _updated} =
               IAM.update_minio_group_members_strict(group_name, [second_name], false, "")

      assert :ok = IAM.attach_group_policy(group_name, policy.policy_arn)
    end)

    send(projection_pid, {:release_projection, barrier})
    assert {:ok, before_change} = Task.await(task, 10_000)
    :ok = :telemetry.detach(handler_id)
    assert before_change.member_names == [first_name]
    assert before_change.managed_policy_names == []

    assert {:ok, after_change} =
             unboxed(fn -> IAM.get_minio_group_description_strict(group_name) end)

    assert after_change.member_names == [first_name, second_name]
    assert after_change.managed_policy_names == [policy_name]
  end

  defp create_policy!(name, path) do
    assert {:ok, policy} = IAM.create_managed_policy(name: name, path: path, document: @document)
    policy
  end

  defp unboxed(fun), do: Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fun)
end
