defmodule Maxio.S3.AuthzPrincipalTest do
  @moduledoc "回归：Authz.gather_statements 必须按真实 principal 取 identity policy（note 1）。"
  use Maxio.DataCase, async: false

  defmodule CapturingStore do
    @behaviour Maxio.Policy.Store
    @impl true
    def get_bucket_policy(_bucket), do: :none
    @impl true
    def put_bucket_policy(_bucket, _json), do: :ok
    @impl true
    def delete_bucket_policy(_bucket), do: :ok
    @impl true
    def principal_policies(principal) do
      send(Process.whereis(:authz_principal_test_pid), {:captured_principal, principal})
      []
    end
  end

  test "principal_policies 收到的是真实 principal 而非硬编码 :anonymous" do
    Process.register(self(), :authz_principal_test_pid)
    prev = Application.get_env(:maxio, :policy_store)

    try do
      Application.put_env(:maxio, :policy_store, CapturingStore)

      principal = %{
        type: :iam_user,
        access_key: "AKIATEST00000000TEST",
        arn: "arn:aws:iam:::user/AKIATEST00000000TEST"
      }

      conn =
        Plug.Test.conn(:get, "/somebucket/k.txt")
        |> Plug.Conn.assign(:s3_bucket, "somebucket")
        |> Plug.Conn.assign(:s3_key, "k.txt")
        |> Plug.Conn.assign(:s3_level, :object)
        |> Plug.Conn.assign(:principal, principal)
        |> Plug.Conn.fetch_query_params()

      # 桶不存在 → owner? false → 进入 gather_statements → 应以真实 principal 调 principal_policies。
      # 默认拒绝会 raise；用 try 包住只验证捕获到的 principal。
      try do
        Maxio.S3.Authz.authorize(conn, :get_object)
      rescue
        _ -> :ok
      end

      assert_received {:captured_principal, ^principal}
    after
      Application.put_env(:maxio, :policy_store, prev)
    end
  end
end
