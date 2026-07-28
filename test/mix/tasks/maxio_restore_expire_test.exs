defmodule Mix.Tasks.MaxioRestoreExpireTest do
  use Maxio.DataCase, async: false

  import ExUnit.CaptureIO

  alias Maxio.{Buckets, Objects}
  alias Mix.Tasks.Maxio.Restore.Expire

  @task "maxio.restore.expire"
  @owner "arn:aws:iam:::root"

  setup do
    prev_authoritative_source = Application.get_env(:maxio, :authoritative_source)
    Application.put_env(:maxio, :authoritative_source, read: :pg, list: :pg, write: :pg)
    Mix.Task.reenable(@task)

    on_exit(fn ->
      restore_env(:authoritative_source, prev_authoritative_source)
      Mix.Task.reenable(@task)
    end)

    :ok
  end

  test "dry-run json reports due restored copies without clearing metadata" do
    bucket = "restoreclidryrun"
    key = "cold.txt"
    seed_expired_restore!(bucket, key)

    output =
      capture_io(fn ->
        Expire.run(["--bucket", bucket, "--dry-run", "--json"])
      end)

    assert %{
             "scanned" => 1,
             "expired" => 1,
             "failed" => 0,
             "dry_run" => true
           } = Jason.decode!(output)

    {:ok, object} = Objects.get_metadata(bucket, key)
    assert object.restore_status == "restored"
    assert %DateTime{} = object.restore_expiry
  end

  test "text run clears due restored copies" do
    bucket = "restoreclirun"
    key = "cold.txt"
    seed_expired_restore!(bucket, key)

    output =
      capture_io(fn ->
        Expire.run(["--bucket", bucket])
      end)

    assert output =~ "[maxio restore.expire]"
    assert output =~ "scanned=1"
    assert output =~ "expired=1"
    assert output =~ "failed=0"

    {:ok, object} = Objects.get_metadata(bucket, key)
    assert object.restore_status == nil
    assert object.restore_expiry == nil
  end

  test "invalid args fail closed before scanning" do
    assert_raise Mix.Error, ~r/usage: mix maxio\.restore\.expire/, fn ->
      Expire.run(["--bad"])
    end

    assert_raise Mix.Error, ~r/--limit must be a positive integer/, fn ->
      Expire.run(["--limit", "0"])
    end
  end

  defp seed_expired_restore!(bucket, key) do
    {:ok, _bucket} = Buckets.create(bucket, @owner)

    {:ok, object} =
      Objects.put_metadata(bucket, key, %{
        size: 10,
        etag: "cold-etag",
        content_type: "application/octet-stream",
        storage_class: "GLACIER"
      })

    {:ok, _object} =
      Objects.put_restore_state(bucket, key, object.version_id, %{
        restore_status: "restored",
        restore_expiry: ~U[2026-06-01 00:00:00Z]
      })

    :ok
  end

  defp restore_env(key, nil), do: Application.delete_env(:maxio, key)
  defp restore_env(key, value), do: Application.put_env(:maxio, key, value)
end
