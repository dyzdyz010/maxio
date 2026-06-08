defmodule Maxio.Auth.CredentialStore.MemoryStoreTest do
  use ExUnit.Case, async: false

  alias Maxio.Auth.CredentialStore.MemoryStore

  test "root 凭据从 config 引导可查到（test 配置的 AWS 示例密钥）" do
    {:ok, %{secret_key: sk, principal: principal}} = MemoryStore.get_secret("AKIAIOSFODNN7EXAMPLE")
    assert sk == "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"
    assert principal.type == :root
    assert principal.arn == "arn:aws:iam:::root"
  end

  test "未知 access key 返回 :error" do
    assert :error = MemoryStore.get_secret("UNKNOWNKEY")
  end

  test "put_access_key 后可查到" do
    :ok = MemoryStore.put_access_key(%{access_key: "AK2", secret_key: "SK2"})
    {:ok, %{secret_key: "SK2", principal: principal}} = MemoryStore.get_secret("AK2")
    assert principal.type == :iam_user
  end
end
