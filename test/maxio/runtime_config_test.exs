defmodule Maxio.RuntimeConfigTest do
  use ExUnit.Case, async: false

  @dev_sse_master_key "bWF4aW8tc3NlLXMzLW1hc3Rlci1rZXktMzJieXRlcyE="
  @dev_access_key_secret_key "bWF4aW8tYWNjZXNzLWtleS1zZWNyZXQta2V5LTMyYiE="
  @watched_env ~w(
    MAXIO_SSE_MASTER_KEY
    MAXIO_KMS_MASTER_KEY
    MAXIO_KMS_DEFAULT_KEY_ID
    MAXIO_MFA_SECRET_KEY
    MAXIO_ACCESS_KEY_SECRET_KEY
    MAXIO_ACCESS_KEY_SECRET_KEY_ID
    MAXIO_ACCESS_KEY_SECRET_KEYRING
    MAXIO_ACCESS_KEY_SECRET_KEYRING_FILE
    DATABASE_URL
    SECRET_KEY_BASE
    MAXIO_S3_IP
    MAXIO_S3_PORT
  )

  setup do
    saved_env =
      Map.new(@watched_env, fn name ->
        {name, System.get_env(name)}
      end)

    Enum.each(@watched_env, &System.delete_env/1)

    on_exit(fn ->
      Enum.each(saved_env, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)
    end)

    :ok
  end

  test "prod runtime rejects the committed development SSE master key" do
    System.put_env("MAXIO_SSE_MASTER_KEY", @dev_sse_master_key)
    System.put_env("MAXIO_KMS_MASTER_KEY", secret("prod-kms"))

    assert_raise RuntimeError,
                 ~r/MAXIO_SSE_MASTER_KEY.*committed development SSE master key/s,
                 &read_prod_runtime!/0
  end

  test "prod runtime rejects the committed development key as KMS wrapping key" do
    System.put_env("MAXIO_SSE_MASTER_KEY", secret("prod-sse"))
    System.put_env("MAXIO_KMS_MASTER_KEY", @dev_sse_master_key)

    assert_raise RuntimeError,
                 ~r/MAXIO_KMS_MASTER_KEY.*committed development SSE master key/s,
                 &read_prod_runtime!/0
  end

  test "prod runtime configures IAM signing secret key ring" do
    put_required_prod_env!()

    current_key = secret("iam-current")
    old_key = secret("iam-old")

    System.put_env("MAXIO_ACCESS_KEY_SECRET_KEY", current_key)
    System.put_env("MAXIO_ACCESS_KEY_SECRET_KEY_ID", "iam-2026-07")
    System.put_env("MAXIO_ACCESS_KEY_SECRET_KEYRING", Jason.encode!(%{"iam-2026-06" => old_key}))

    config = read_prod_runtime!()
    access_key_secret = config |> Keyword.fetch!(:maxio) |> Keyword.fetch!(:access_key_secret)

    assert Keyword.fetch!(access_key_secret, :current_key_id) == "iam-2026-07"
    assert Keyword.fetch!(access_key_secret, :secret_key) == current_key

    keys = Keyword.fetch!(access_key_secret, :keys)
    assert keys["iam-2026-07"] == current_key
    assert keys["iam-2026-06"] == old_key
  end

  test "prod runtime rejects committed development IAM signing key in key ring" do
    put_required_prod_env!()

    System.put_env(
      "MAXIO_ACCESS_KEY_SECRET_KEYRING",
      Jason.encode!(%{"old" => @dev_access_key_secret_key})
    )

    assert_raise RuntimeError,
                 ~r/MAXIO_ACCESS_KEY_SECRET_KEYRING\[old\].*committed development access-key secret key/s,
                 &read_prod_runtime!/0
  end

  test "prod runtime configures IAM signing secret keyring file" do
    put_required_prod_env!()
    path = Path.join(System.tmp_dir!(), "maxio-runtime-iam-keyring.json")
    key = secret("file-iam")

    File.write!(
      path,
      Jason.encode!(%{
        "version" => 1,
        "current_key_id" => "file-current",
        "current_key_started_at" => "2026-07-01T00:00:00Z",
        "keys" => %{"file-current" => %{"secret_key" => key}}
      })
    )

    try do
      System.put_env("MAXIO_ACCESS_KEY_SECRET_KEYRING_FILE", path)
      config = read_prod_runtime!()
      access_key_secret = config |> Keyword.fetch!(:maxio) |> Keyword.fetch!(:access_key_secret)
      assert Keyword.fetch!(access_key_secret, :keyring_file) == path
    after
      File.rm(path)
    end
  end

  test "prod runtime rejects committed development IAM signing key in keyring file" do
    put_required_prod_env!()
    path = Path.join(System.tmp_dir!(), "maxio-runtime-dev-iam-keyring.json")

    File.write!(
      path,
      Jason.encode!(%{
        "version" => 1,
        "current_key_id" => "file-current",
        "current_key_started_at" => "2026-07-01T00:00:00Z",
        "keys" => %{"file-current" => %{"secret_key" => @dev_access_key_secret_key}}
      })
    )

    try do
      System.put_env("MAXIO_ACCESS_KEY_SECRET_KEYRING_FILE", path)

      assert_raise RuntimeError,
                   ~r/MAXIO_ACCESS_KEY_SECRET_KEYRING_FILE\[file-current\].*committed development access-key secret key/s,
                   &read_prod_runtime!/0
    after
      File.rm(path)
    end
  end

  test "MAXIO_S3_IP unset leaves the compile-time S3 bind address untouched" do
    endpoint = s3_endpoint_config(read_dev_runtime!())

    refute Keyword.has_key?(endpoint, :ip)
  end

  test "MAXIO_S3_IP overrides the S3 bind address at runtime" do
    System.put_env("MAXIO_S3_IP", "0.0.0.0")

    assert read_dev_runtime!() |> s3_endpoint_config() |> Keyword.fetch!(:ip) == {0, 0, 0, 0}
  end

  test "MAXIO_S3_IP accepts IPv6 literals" do
    System.put_env("MAXIO_S3_IP", "::")

    assert read_dev_runtime!() |> s3_endpoint_config() |> Keyword.fetch!(:ip) ==
             {0, 0, 0, 0, 0, 0, 0, 0}
  end

  test "MAXIO_S3_IP keeps the port override alongside the bind address" do
    System.put_env("MAXIO_S3_IP", "0.0.0.0")
    System.put_env("MAXIO_S3_PORT", "9910")

    endpoint = s3_endpoint_config(read_dev_runtime!())

    assert Keyword.fetch!(endpoint, :ip) == {0, 0, 0, 0}
    assert Keyword.fetch!(endpoint, :port) == 9910
  end

  test "MAXIO_S3_IP rejects values that are not IP addresses instead of silently defaulting" do
    System.put_env("MAXIO_S3_IP", "localhost")

    assert_raise RuntimeError, ~r/MAXIO_S3_IP/, &read_dev_runtime!/0
  end

  defp s3_endpoint_config(config) do
    config |> Keyword.get(:maxio, []) |> Keyword.get(Maxio.S3.Endpoint, [])
  end

  defp read_dev_runtime! do
    Config.Reader.read!(Path.expand("../../config/runtime.exs", __DIR__), env: :dev)
  end

  defp read_prod_runtime! do
    Config.Reader.read!(Path.expand("../../config/runtime.exs", __DIR__), env: :prod)
  end

  defp put_required_prod_env! do
    System.put_env("MAXIO_SSE_MASTER_KEY", secret("prod-sse"))
    System.put_env("MAXIO_KMS_MASTER_KEY", secret("prod-kms"))
    System.put_env("MAXIO_MFA_SECRET_KEY", secret("prod-mfa"))
    System.put_env("MAXIO_ACCESS_KEY_SECRET_KEY", secret("prod-iam"))
    System.put_env("DATABASE_URL", "ecto://user:pass@localhost/maxio_prod")
    System.put_env("SECRET_KEY_BASE", secret("secret-key-base") <> secret("secret-key-base-2"))
  end

  defp secret(label) do
    :crypto.hash(:sha256, label) |> Base.encode64()
  end
end
