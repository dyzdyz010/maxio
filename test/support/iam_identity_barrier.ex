defmodule Maxio.Test.IAMIdentityBarrier do
  @moduledoc false

  def attach(kind, name) when kind in [:group, :user] and is_binary(name) do
    owner = self()
    id = {__MODULE__, kind, make_ref()}
    event = [:maxio, :iam, identity_event(kind), :lock_wait]
    metadata_key = if kind == :group, do: :case_folded_group_name, else: :case_folded_user_name
    expected_name = String.downcase(name)

    :ok =
      :telemetry.attach(
        id,
        event,
        fn _event, _measurements, metadata, {test_pid, barrier, key, expected} ->
          if Map.fetch!(metadata, key) == expected do
            send(test_pid, {:iam_identity_wait, barrier, self()})

            receive do
              {:release_iam_identity, ^barrier} -> :ok
            after
              5_000 -> raise "IAM identity barrier timed out"
            end
          end
        end,
        {owner, id, metadata_key, expected_name}
      )

    id
  end

  def detach(id), do: :telemetry.detach(id)

  defp identity_event(:group), do: :group_identity
  defp identity_event(:user), do: :user_identity
end
