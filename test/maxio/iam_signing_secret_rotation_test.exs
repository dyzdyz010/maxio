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

  test "rewrap failure carries the rewrap root cause into the rotation report errors" do
    keyring_file = Path.join(@data_dir, "rewrap-blocked-keyring.json")
    old_key = b64_secret("rotation-rewrap-old")
    new_key = b64_secret("rotation-rewrap-new")

    with_access_key_secret_config(
      [keyring_file: keyring_file, current_key_id: "old", secret_key: old_key],
      fn ->
        {:ok, access_key} =
          IAM.create_access_key(
            access_key_id: unique_ak("REWRAPFAIL"),
            secret_key: "rewrap-fail-secret"
          )

        # 真实的 rewrap 失败通道：信封前缀合法但载荷不是合法 url-safe base64，
        # `AccessKeySecret.unwrap/2` 返回结构化错误 → rewriter 计入 error_details。
        {1, _} =
          Repo.update_all(
            from(a in AccessKey, where: a.access_key_id == ^access_key.access_key_id),
            set: [secret_key: "maxio-ak-secret-v1:%%%not-base64%%%"]
          )

        assert {:error, report} =
                 SigningSecretRotation.rotate(
                   keyring_file: keyring_file,
                   key_id: "new",
                   key_b64: new_key,
                   now: @now,
                   dry_run: false
                 )

        assert report.status == :rewrap_blocked

        # 错误 term 必须自带 rewrap 摘要：scheduler / mix 任务只透出 errors，
        # 裸 atom 会让「为什么密钥没换成」在运维侧彻底丢失。
        assert {:signing_secret_rewrap_blocked, summary} =
                 Enum.find(report.errors, &match?({:signing_secret_rewrap_blocked, _summary}, &1))

        assert summary == report.rewrap
        assert summary.errors >= 1

        assert Enum.any?(summary.error_sample, fn detail ->
                 detail.scope == :access_keys and
                   detail.access_key_id == access_key.access_key_id and
                   detail.reason == :invalid_access_key_secret_envelope
               end)

        # 根因随 errors 一路进日志正文（scheduler 的 errors= 字段就是 inspect 这个列表）。
        assert inspect(report.errors) =~ "invalid_access_key_secret_envelope"
        refute inspect(report) =~ new_key
      end
    )
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
    # 两种失败终态的 errors 形态刻意与生产产出一致：`:blocked` 带写盘 OS 根因，
    # `:rewrap_blocked` 带 rewrap 摘要（含 error_sample 根因），见
    # `SigningSecretRotation.write_rotation/7`。
    for {status, errors} <- [
          {:blocked, [{:access_key_secret_keyring_file_write_failed, :eacces}]},
          {:rewrap_blocked,
           [
             {:signing_secret_rewrap_blocked,
              %{
                status: :blocked,
                scanned: 3,
                candidates: 2,
                rewrapped: 0,
                errors: 1,
                error_sample: [
                  %{
                    scope: :access_keys,
                    access_key_id: "AKIAROTATEEXAMPLE",
                    reason: :access_key_secret_decrypt_failed
                  }
                ]
              }}
           ]}
        ] do
      assert_scheduler_logs_failure_at_error_level(status, errors)
    end
  end

  test "scheduler treats an unrecognised ok status as a failed pass" do
    # 失败判据是「成功白名单」而不是「失败黑名单」：新增/未登记的终态默认按没换成处理，
    # 否则一个漏登记的失败状态就会静默降级成 info（AGENTS.md §3）。
    unknown =
      start_supervised!(
        {Scheduler,
         name: nil,
         enabled: false,
         runner: fn _opts -> {:ok, %{status: :some_new_terminal_state, errors: []}} end},
        id: :scheduler_unknown_status
      )

    log =
      capture_log(fn ->
        assert {:ok, %{status: :some_new_terminal_state}} =
                 Scheduler.run_now(unknown, keyring_file: "k")
      end)

    assert log =~ "[error]"
    assert log =~ "status=some_new_terminal_state"

    landed =
      start_supervised!(
        {Scheduler,
         name: nil, enabled: false, runner: fn _opts -> {:ok, %{status: :not_due, errors: []}} end},
        id: :scheduler_landed_status
      )

    # 反向守卫：真正落地的终态不得被这条判据误升级成 error（否则告警会被噪声淹没）。
    quiet =
      capture_log(fn ->
        assert {:ok, %{status: :not_due}} = Scheduler.run_now(landed, keyring_file: "k")
      end)

    refute quiet =~ "iam signing secret rotation scheduler pass complete"
  end

  test "scheduler logs an unusable runner result at error level with the raw value" do
    pid =
      start_supervised!(
        {Scheduler,
         name: nil, enabled: false, confirm_rotation: true, runner: fn _opts -> :not_a_report end}
      )

    log =
      capture_log(fn ->
        assert {:error, %{status: :bad_rotation_result, errors: [:not_a_report]}} =
                 Scheduler.run_now(pid, keyring_file: "k")
      end)

    # runner 返回垃圾值 = 密钥没换成，且没有报告可看：必须 error 级并原样带出该值。
    assert log =~ "[error]"
    assert log =~ "iam signing secret rotation scheduler returned unexpected result"
    assert log =~ ":not_a_report"
  end

  defp assert_scheduler_logs_failure_at_error_level(status, errors) do
    report = %{
      status: status,
      dry_run: false,
      previous_key_id: "old",
      next_key_id: "new",
      errors: errors
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

    # 防降级判据必须落在「pass complete 这一条记录本身」上：
    # `config/test.exs` 把 logger level 设成 :warning，info 级日志根本不进 capture，
    # 所以 `refute log =~ "[info]"` 恒真、守不住任何东西（`capture_log(level: :info)`
    # 也不会放宽 primary level）。改成锁定这一行：一旦降级成 `Log.info`，
    # 该行整条从 capture 里消失，下面第一条断言立刻失败。
    pass_line =
      log
      |> String.split("\n", trim: true)
      |> Enum.find(&(&1 =~ "iam signing secret rotation scheduler pass complete"))

    assert pass_line, "rotation pass was not logged at :warning or above (silently downgraded?)"
    assert pass_line =~ "[error]"
    assert pass_line =~ "status=#{status}"

    # 原样带出 reason（不是 errors 计数）：运维只看日志也能定位根因。
    assert pass_line =~ "errors=#{inspect(report.errors)}"
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
