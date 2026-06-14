defmodule Maxio.Auth.CredentialStore.MemoryStoreTest do
  use ExUnit.Case, async: false

  alias Maxio.Auth.CredentialStore.MemoryStore

  setup do
    MemoryStore.invalidate(:all)
    :ok
  end

  test "root credentials are bootstrapped from config" do
    {:ok, %{secret_key: sk, principal: principal}} =
      MemoryStore.get_secret("AKIAIOSFODNN7EXAMPLE")

    assert sk == "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"
    assert principal.type == :root
    assert principal.arn == "arn:aws:iam:::root"
  end

  test "unknown access key returns error" do
    assert :error = MemoryStore.get_secret("UNKNOWNKEY")
  end

  test "put_access_key stores a long-term credential" do
    :ok = MemoryStore.put_access_key(%{access_key: "AK2", secret_key: "SK2"})
    {:ok, %{secret_key: "SK2", principal: principal}} = MemoryStore.get_secret("AK2")
    assert principal.type == :iam_user
  end

  test "invalidate deletes an access key" do
    :ok = MemoryStore.put_access_key(%{access_key: "AKINVALIDATE", secret_key: "SK"})
    assert {:ok, %{secret_key: "SK"}} = MemoryStore.get_secret("AKINVALIDATE")

    assert :ok = MemoryStore.invalidate({:access_key, "AKINVALIDATE"})

    assert :error = MemoryStore.get_secret("AKINVALIDATE")
  end

  test "long-term access key rejects stale session token" do
    :ok = MemoryStore.put_access_key(%{access_key: "AKLONGTERM", secret_key: "SK"})

    assert {:error, :invalid_token} =
             MemoryStore.get_secret("AKLONGTERM", session_token: "stale-token")
  end

  test "session credentials require matching non-expired token" do
    now = DateTime.utc_now()
    expires_at = DateTime.add(now, 900, :second)

    assert :ok =
             MemoryStore.put_access_key(%{
               access_key: "ASIAMEMSESSION",
               secret_key: "SESSIONSECRET",
               session_token: "SESSIONTOKEN",
               expires_at: expires_at,
               principal: %{
                 type: :iam_user,
                 access_key: "AKIAISSUER",
                 arn: "arn:aws:iam:::user/AKIAISSUER"
               }
             })

    assert {:error, :missing_session_token} =
             MemoryStore.get_secret("ASIAMEMSESSION", now: now)

    assert {:error, :invalid_token} =
             MemoryStore.get_secret("ASIAMEMSESSION",
               session_token: "wrong",
               now: now
             )

    assert {:ok,
            %{
              secret_key: "SESSIONSECRET",
              principal: %{credential_type: :session, session_access_key: "ASIAMEMSESSION"}
            }} =
             MemoryStore.get_secret("ASIAMEMSESSION",
               session_token: "SESSIONTOKEN",
               now: now
             )

    assert {:error, :expired_token} =
             MemoryStore.get_secret("ASIAMEMSESSION",
               session_token: "SESSIONTOKEN",
               now: DateTime.add(expires_at, 1, :second)
             )
  end
end
