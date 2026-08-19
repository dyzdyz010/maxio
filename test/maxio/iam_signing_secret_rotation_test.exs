defmodule Maxio.IAM.SigningSecretRotationTest do
  use Maxio.DataCase, async: false

  import ExUnit.CaptureLog

  alias Maxio.Auth.CredentialStore.EctoStore
  alias Maxio.IAM
  alias Maxio.IAM.{AccessKey, SigningSecretKeyring, SigningSecretRotation}
  alias Maxio.IAM.SigningSecretRotation.Scheduler

  @data_dir Path.join(System.tmp_dir!(), "maxio_iam_signing_secret_rotation")
  @now ~U[2026-07-01 08:00:00Z]

  setup do
    File.rm_rf(@data_dir)
    File.mkdir_p!(@data_dir)
    original = Application.fetch_env!(:maxio, :access_key_secret)
    rotation_cfg = Application.get_env(:maxio, :iam_signing_secret_rotation)

    on_exit(fn ->
      Application.put_env(:maxio, :access_key_secret, original)
      restore_env(:iam_signing_secret_rotation, rotation_cfg)
      File.rm_rf(@data_dir)
    end)

    :ok
  end

  test "confirmed rotation writes keyring file, updates runtime config, and rewraps stale rows" do
    keyring_file = Path.join(@data_dir, "iam-keyring.json")
    old_key = b64_secret("rotation-old")
    new_key = b64_secret("rotation-new")

    with_access_key_secret_config(
      [keyring_file: keyring_file, current_key_id: "old", secret_key: old_key],
      fn ->
        {:ok, access_key} =
          IAM.create_access_key(
            access_key_id: unique_ak("ROTATE"),
            secret_key: "rotated-secret"
          )

        assert row_key_id(Repo.get_by!(AccessKey, access_key_id: access_key.access_key_id)) ==
                 "old"

        assert {:ok, report} =
                 SigningSecretRotation.rotate(
                   keyring_file: keyring_file,
                   key_id: "new",
                   key_b64: new_key,
                   now: @now,
                   dry_run: false
                 )

        assert report.status == :rotated
        assert report.previous_key_id == "old"
        assert report.next_key_id == "new"
        assert report.rewrap.rewrapped == 1
        refute inspect(report) =~ new_key
        refute inspect(report) =~ "rotated-secret"

        decoded = keyring_file |> File.read!() |> Jason.decode!()
        assert decoded["version"] == 1
        assert decoded["current_key_id"] == "new"
        assert decoded["current_key_started_at"] == DateTime.to_iso8601(@now)
        assert decoded["keys"]["old"]["secret_key"] == old_key
        assert decoded["keys"]["new"]["secret_key"] == new_key

        assert row_key_id(Repo.get_by!(AccessKey, access_key_id: access_key.access_key_id)) ==
                 "new"

        Application.put_env(:maxio, :access_key_secret, keyring_file: keyring_file)

        assert {:ok, %{secret_key: "rotated-secret"}} =
                 EctoStore.get_secret(access_key.access_key_id)

        assert {:ok, snapshot} = SigningSecretKeyring.snapshot()
        assert snapshot.source == {:file, keyring_file}
        assert snapshot.current_key_id == "new"
      end
    )
  end

  test "dry-run plans rotation without creating a keyring file or changing runtime config" do
    keyring_file = Path.join(@data_dir, "dry-run-keyring.json")
    old_key = b64_secret("rotation-dry-old")
    new_key = b64_secret("rotation-dry-new")

    with_access_key_secret_config(
      [keyring_file: keyring_file, current_key_id: "old", secret_key: old_key],
      fn ->
        assert {:ok, report} =
                 SigningSecretRotation.rotate(
                   keyring_file: keyring_file,
                   key_id: "new",
                   key_b64: new_key
                 )

        assert report.status == :dry_run
        assert report.dry_run
        refute File.exists?(keyring_file)
        assert Application.fetch_env!(:maxio, :access_key_secret)[:current_key_id] == "old"
        refute inspect(report) =~ new_key
      end
    )
  end

  test "malformed keyring file blocks rotation instead of crashing" do
    keyring_file = Path.join(@data_dir, "bad-keys-array.json")

    File.write!(
      keyring_file,
      Jason.encode!(%{
        "version" => 1,
        "current_key_id" => "old",
        "keys" => ["not-a-key-map"]
      })
    )

    with_access_key_secret_config([keyring_file: keyring_file], fn ->
      assert {:error, report} =
               SigningSecretRotation.rotate(
                 keyring_file: keyring_file,
                 key_id: "new",
                 key_b64: b64_secret("rotation-bad-new"),
                 dry_run: false,
                 rewrap: false
               )

      assert report.status == :blocked
      assert :invalid_access_key_secret_keyring_file in report.errors
    end)
  end

  test "rotate_if_due rotates only when the current key age crosses threshold" do
    keyring_file = Path.join(@data_dir, "due-keyring.json")
    old_key = b64_secret("rotation-due-old")
    new_key = b64_secret("rotation-due-new")

    write_keyring!(keyring_file, "old", old_key, DateTime.add(@now, -100, :second))

    with_access_key_secret_config([keyring_file: keyring_file], fn ->
      assert {:ok, not_due} =
               SigningSecretRotation.rotate_if_due(
                 keyring_file: keyring_file,
                 rotate_after_seconds: 200,
                 now: @now
               )

      assert not_due.status == :not_due

      assert {:ok, rotated} =
               SigningSecretRotation.rotate_if_due(
                 keyring_file: keyring_file,
                 rotate_after_seconds: 60,
                 key_id: "new",
                 key_b64: new_key,
                 now: @now,
                 dry_run: false,
                 rewrap: false
               )

      assert rotated.status == :rotated

      assert keyring_file |> File.read!() |> Jason.decode!() |> Map.fetch!("current_key_id") ==
               "new"
    end)
  end

  test "rotation preserves existing key metadata when writing the next keyring" do
    keyring_file = Path.join(@data_dir, "metadata-keyring.json")
    old_key = b64_secret("rotation-metadata-old")
    new_key = b64_secret("rotation-metadata-new")
    old_created_at = DateTime.add(@now, -100, :second) |> DateTime.to_iso8601()

    File.write!(
      keyring_file,
      Jason.encode!(%{
        "version" => 1,
        "current_key_id" => "old",
        "current_key_started_at" => old_created_at,
        "keys" => %{
          "old" => %{
            "secret_key" => old_key,
            "created_at" => old_created_at,
            "operator_note" => "bootstrap"
          }
        }
      })
    )

    with_access_key_secret_config([keyring_file: keyring_file], fn ->
      assert {:ok, %{status: :rotated}} =
               SigningSecretRotation.rotate(
                 keyring_file: keyring_file,
                 key_id: "new",
                 key_b64: new_key,
                 now: @now,
                 dry_run: false,
                 rewrap: false
               )

      decoded = keyring_file |> File.read!() |> Jason.decode!()
      assert decoded["keys"]["old"]["secret_key"] == old_key
      assert decoded["keys"]["old"]["created_at"] == old_created_at
      assert decoded["keys"]["old"]["operator_note"] == "bootstrap"
      assert decoded["keys"]["new"]["created_at"] == DateTime.to_iso8601(@now)
    end)
  end

  test "force rotation bypasses missing key age metadata" do
    keyring_file = Path.join(@data_dir, "force-keyring.json")
    old_key = b64_secret("rotation-force-old")
    new_key = b64_secret("rotation-force-new")

    File.mkdir_p!(Path.dirname(keyring_file))

    File.write!(
      keyring_file,
      Jason.encode!(%{
        "version" => 1,
        "current_key_id" => "old",
        "keys" => %{"old" => %{"secret_key" => old_key}}
      })
    )

    with_access_key_secret_config([keyring_file: keyring_file], fn ->
      assert {:ok, rotated} =
               SigningSecretRotation.rotate_if_due(
                 keyring_file: keyring_file,
                 rotate_after_seconds: 60,
                 key_id: "new",
                 key_b64: new_key,
                 now: @now,
                 dry_run: false,
                 force: true,
                 rewrap: false
               )

      assert rotated.status == :rotated

      assert keyring_file |> File.read!() |> Jason.decode!() |> Map.fetch!("current_key_id") ==
               "new"
    end)
  end

  test "concurrent confirmed rotations preserve keys from earlier committed rotations" do
    keyring_file = Path.join(@data_dir, "concurrent-keyring.json")
    old_key = b64_secret("rotation-concurrent-old")
    first_key = b64_secret("rotation-concurrent-first")
    second_key = b64_secret("rotation-concurrent-second")

    write_keyring!(keyring_file, "old", old_key, DateTime.add(@now, -100, :second))

    with_access_key_secret_config([keyring_file: keyring_file], fn ->
      results =
        [
          {"new-a", first_key},
          {"new-b", second_key}
        ]
        |> Task.async_stream(
          fn {key_id, key_b64} ->
            SigningSecretRotation.rotate(
              keyring_file: keyring_file,
              key_id: key_id,
              key_b64: key_b64,
              now: @now,
              dry_run: false,
              rewrap: false
            )
          end,
          max_concurrency: 2,
          timeout: :infinity
        )
        |> Enum.map(fn {:ok, result} -> result end)

      assert Enum.all?(results, &match?({:ok, %{status: :rotated}}, &1))

      decoded = keyring_file |> File.read!() |> Jason.decode!()
      assert decoded["keys"]["old"]["secret_key"] == old_key
      assert decoded["keys"]["new-a"]["secret_key"] == first_key
      assert decoded["keys"]["new-b"]["secret_key"] == second_key
      assert decoded["current_key_id"] in ["new-a", "new-b"]
    end)
  end

  test "read-only secret file device blocks rotation instead of escaping as an exception" do
    keyring_file = Path.join(@data_dir, "readonly-io-keyring.json")

    # 打开成功但写入失败：`IO.binwrite/2` 的错误通道是异常（:eacces），不是 {:error, reason}。
    open_fun = fn path, _modes ->
      File.write!(path, "")
      File.open(path, [:read, :binary])
    end

    assert_write_failure_is_blocked(keyring_file, "rotation-readonly-io", open_fun)
  end

  test "terminated secret file device blocks rotation instead of escaping as an exception" do
    keyring_file = Path.join(@data_dir, "terminated-io-keyring.json")

    # 设备进程已终止：`IO.binwrite/2` 抛出 :terminated。
    open_fun = fn path, modes ->
      {:ok, io} = File.open(path, modes)
      :ok = File.close(io)
      {:ok, io}
    end

    assert_write_failure_is_blocked(keyring_file, "rotation-terminated-io", open_fun)
  end

  test "scheduler is disabled by default and manual run invokes configured runner" do
    parent = self()

    runner = fn opts ->
      send(parent, {:runner_called, opts})
      {:ok, %{status: :not_due, dry_run: Keyword.fetch!(opts, :dry_run), errors: []}}
    end

    pid =
      start_supervised!(
        {Scheduler,
         name: nil,
         enabled: false,
         runner: runner,
         confirm_rotation: true,
         rotate_after_seconds: 60}
      )

    assert %{enabled: false, scheduled?: false, last_result: nil} = Scheduler.status(pid)
    assert {:ok, %{status: :not_due, dry_run: false}} = Scheduler.run_now(pid, keyring_file: "k")

    assert_receive {:runner_called, opts}
    assert Keyword.fetch!(opts, :dry_run) == false
    assert Keyword.fetch!(opts, :rotate_after_seconds) == 60
  end

  test "enabled scheduler tick uses dry-run unless confirm_rotation is explicitly true" do
    parent = self()

    runner = fn opts ->
      send(parent, {:scheduled_runner_called, opts})
      {:ok, %{status: :dry_run, dry_run: Keyword.fetch!(opts, :dry_run), errors: []}}
    end

    pid =
      start_supervised!(
        {Scheduler,
         name: nil, enabled: true, initial_delay_ms: 60_000, interval_ms: 60_000, runner: runner}
      )

    token = :sys.get_state(pid).timer_token
    send(pid, {:rotate, token})
    _ = :sys.get_state(pid)

    assert_receive {:scheduled_runner_called, opts}
    assert Keyword.fetch!(opts, :dry_run) == true
    assert %{scheduled?: true, last_result: {:ok, %{status: :dry_run}}} = Scheduler.status(pid)
  end

  test "scheduler ignores dry_run false run_opts unless confirm_rotation is true" do
    parent = self()

    runner = fn opts ->
      send(parent, {:guarded_runner_called, opts})
      {:ok, %{status: :dry_run, dry_run: Keyword.fetch!(opts, :dry_run), errors: []}}
    end

    pid =
      start_supervised!(
        {Scheduler,
         name: nil,
         enabled: false,
         runner: runner,
         confirm_rotation: false,
         run_opts: [dry_run: false]}
      )

    assert {:ok, %{status: :dry_run, dry_run: true}} = Scheduler.run_now(pid, keyring_file: "k")

    assert_receive {:guarded_runner_called, opts}
    assert Keyword.fetch!(opts, :dry_run) == true
  end

  test "scheduler logs failed rotation passes at error level with the full root cause" do
    for status <- [:blocked, :rewrap_blocked] do
      assert_scheduler_logs_failure_at_error_level(status)
    end
  end

  defp assert_scheduler_logs_failure_at_error_level(status) do
    report = %{
      status: status,
      dry_run: false,
      previous_key_id: "old",
      next_key_id: "new",
      errors: [{:access_key_secret_keyring_file_write_failed, :eacces}]
    }

    pid =
      start_supervised!(
        {Scheduler,
         name: nil,
         enabled: false,
         confirm_rotation: true,
         runner: fn _opts -> {:error, report} end},
        id: {:scheduler, status}
      )

    log =
      capture_log(fn ->
        assert {:error, %{status: ^status}} = Scheduler.run_now(pid, keyring_file: "k")
      end)

    # 生产唯一自动路径上的失败不得降级成 info，且必须原样带出 reason（不是 errors 计数）。
    assert log =~ "[error]"
    assert log =~ "iam signing secret rotation scheduler pass complete"
    assert log =~ "status=#{status}"
    assert log =~ "errors=#{inspect(report.errors)}"
    assert log =~ "access_key_secret_keyring_file_write_failed"
    assert log =~ ":eacces"
    refute log =~ "[info]"
  end

  defp assert_write_failure_is_blocked(keyring_file, label, open_fun) do
    old_key = b64_secret("#{label}-old")
    new_key = b64_secret("#{label}-new")
    parent = self()

    with_access_key_secret_config(
      [keyring_file: keyring_file, current_key_id: "old", secret_key: old_key],
      fn ->
        log =
          capture_log(fn ->
            send(
              parent,
              {:rotate_result,
               SigningSecretRotation.rotate(
                 keyring_file: keyring_file,
                 key_id: "new",
                 key_b64: new_key,
                 now: @now,
                 dry_run: false,
                 rewrap: false,
                 open_fun: open_fun
               )}
            )
          end)

        assert_received {:rotate_result, {:error, report}}

        assert report.status == :blocked

        # 根因不得被丢弃：报告里带 OS 级 reason，日志里以 error 级别留痕。
        assert {:access_key_secret_keyring_file_write_failed, reason} =
                 Enum.find(
                   report.errors,
                   &match?({:access_key_secret_keyring_file_write_failed, _reason}, &1)
                 )

        assert log =~ "[error]"
        assert log =~ "iam signing secret keyring file write failed"
        assert log =~ inspect(reason)

        # 绝不静默落盘：失败后既不留下半截 keyring，也不改运行时配置。
        refute File.exists?(keyring_file)
        assert Application.fetch_env!(:maxio, :access_key_secret)[:current_key_id] == "old"

        # `Path.wildcard/1` 的 `*` 不跨 `.` 匹配，对 `<name>.json.tmp.<N>` 恒返回 []，
        # 是空转断言；必须直接列目录再按 `.tmp.` 过滤才有保护力。
        assert residual_tmp_files() == []
      end
    )
  end

  defp residual_tmp_files do
    @data_dir
    |> File.ls!()
    |> Enum.filter(&String.contains?(&1, ".tmp."))
    |> Enum.sort()
  end

  defp write_keyring!(path, key_id, key_b64, started_at) do
    File.mkdir_p!(Path.dirname(path))

    File.write!(
      path,
      Jason.encode!(%{
        "version" => 1,
        "current_key_id" => key_id,
        "current_key_started_at" => DateTime.to_iso8601(started_at),
        "keys" => %{key_id => %{"secret_key" => key_b64}}
      })
    )
  end

  defp with_access_key_secret_config(config, fun) do
    original = Application.fetch_env!(:maxio, :access_key_secret)

    try do
      Application.put_env(:maxio, :access_key_secret, config)
      fun.()
    after
      Application.put_env(:maxio, :access_key_secret, original)
    end
  end

  defp row_key_id(%AccessKey{secret_key: secret_key}) do
    secret_key
    |> String.replace_prefix("maxio-ak-secret-v1:", "")
    |> Base.url_decode64!(padding: false)
    |> Jason.decode!()
    |> Map.fetch!("key_id")
  end

  defp b64_secret(label), do: :crypto.hash(:sha256, label) |> Base.encode64()
  defp unique_ak(prefix), do: "AKIA#{prefix}#{System.unique_integer([:positive])}"

  defp restore_env(key, nil), do: Application.delete_env(:maxio, key)
  defp restore_env(key, value), do: Application.put_env(:maxio, key, value)
end
