defmodule Mix.Tasks.MaxioIamRotateSecretKeyTest do
  use Maxio.DataCase, async: false

  import ExUnit.CaptureIO

  alias Mix.Tasks.Maxio.Iam.RotateSecretKey

  @task "maxio.iam.rotate_secret_key"
  @data_dir Path.join(System.tmp_dir!(), "maxio_iam_rotate_secret_key_task")

  setup do
    File.rm_rf(@data_dir)
    File.mkdir_p!(@data_dir)
    original = Application.fetch_env!(:maxio, :access_key_secret)
    Mix.Task.reenable(@task)

    on_exit(fn ->
      Application.put_env(:maxio, :access_key_secret, original)
      Mix.Task.reenable(@task)
      File.rm_rf(@data_dir)
    end)

    :ok
  end

  test "dry-run json output does not create keyring file or expose key material" do
    keyring_file = Path.join(@data_dir, "dry-task.json")
    old_key = b64_secret("task-old")
    new_key = b64_secret("task-new")

    Application.put_env(:maxio, :access_key_secret,
      keyring_file: keyring_file,
      current_key_id: "old",
      secret_key: old_key
    )

    output =
      capture_io(fn ->
        RotateSecretKey.run([
          "--keyring-file",
          keyring_file,
          "--key-id",
          "new",
          "--key-b64",
          new_key,
          "--json"
        ])
      end)

    decoded = Jason.decode!(output)
    assert decoded["status"] == "dry_run"
    assert decoded["dry_run"] == true
    assert decoded["previous_key_id"] == "old"
    assert decoded["next_key_id"] == "new"
    refute output =~ new_key
    refute File.exists?(keyring_file)
  end

  test "keyring file option is authoritative even when app env only has bootstrap key" do
    keyring_file = Path.join(@data_dir, "explicit-task.json")
    old_key = b64_secret("task-explicit-old")
    new_key = b64_secret("task-explicit-new")

    Application.put_env(:maxio, :access_key_secret, current_key_id: "old", secret_key: old_key)

    output =
      capture_io(fn ->
        RotateSecretKey.run([
          "--keyring-file",
          keyring_file,
          "--key-id",
          "new",
          "--key-b64",
          new_key,
          "--confirm",
          "--no-rewrap",
          "--json"
        ])
      end)

    decoded = Jason.decode!(output)
    assert decoded["status"] == "rotated"
    assert decoded["previous_key_id"] == "old"

    decoded_file = keyring_file |> File.read!() |> Jason.decode!()
    assert decoded_file["current_key_id"] == "new"
    assert decoded_file["keys"]["old"]["secret_key"] == old_key
    assert decoded_file["keys"]["new"]["secret_key"] == new_key
  end

  test "confirm writes keyring file and can skip rewrap" do
    keyring_file = Path.join(@data_dir, "confirm-task.json")
    old_key = b64_secret("task-confirm-old")
    new_key = b64_secret("task-confirm-new")

    Application.put_env(:maxio, :access_key_secret,
      keyring_file: keyring_file,
      current_key_id: "old",
      secret_key: old_key
    )

    output =
      capture_io(fn ->
        RotateSecretKey.run([
          "--keyring-file",
          keyring_file,
          "--key-id",
          "new",
          "--key-b64",
          new_key,
          "--confirm",
          "--no-rewrap"
        ])
      end)

    assert output =~ "[maxio iam.rotate_secret_key] status=rotated"
    decoded = keyring_file |> File.read!() |> Jason.decode!()
    assert decoded["current_key_id"] == "new"
    assert decoded["keys"]["old"]["secret_key"] == old_key
    assert decoded["keys"]["new"]["secret_key"] == new_key
  end

  test "invalid arguments fail closed" do
    assert_raise Mix.Error, ~r/--dry-run and --confirm are mutually exclusive/, fn ->
      RotateSecretKey.run([
        "--keyring-file",
        Path.join(@data_dir, "bad.json"),
        "--dry-run",
        "--confirm"
      ])
    end

    assert_raise Mix.Error, ~r/usage: mix maxio\.iam\.rotate_secret_key/, fn ->
      RotateSecretKey.run(["--unknown"])
    end
  end

  defp b64_secret(label), do: :crypto.hash(:sha256, label) |> Base.encode64()
end
