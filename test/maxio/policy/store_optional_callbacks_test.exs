defmodule Maxio.Policy.StoreOptionalCallbacksTest do
  use ExUnit.Case, async: false

  alias Maxio.Policy.Store

  defmodule LegacyStore do
    @behaviour Maxio.Policy.Store

    @impl true
    def get_bucket_policy(_bucket), do: :none

    @impl true
    def put_bucket_policy(_bucket, _json), do: :ok

    @impl true
    def delete_bucket_policy(_bucket), do: :ok

    @impl true
    def principal_policies(_principal), do: []
  end

  test "principal policy facade handles stores without optional callbacks" do
    previous_store = Application.fetch_env!(:maxio, :policy_store)

    try do
      Application.put_env(:maxio, :policy_store, LegacyStore)

      assert {:error, :not_supported} =
               Store.put_principal_policy("arn:aws:iam:::user/legacy", "policy", "{}")

      assert :ok = Store.delete_principal_policy("arn:aws:iam:::user/legacy", "policy")
      assert [] = Store.list_principal_policies("arn:aws:iam:::user/legacy")
    after
      Application.put_env(:maxio, :policy_store, previous_store)
    end
  end
end
