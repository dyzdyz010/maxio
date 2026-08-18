defmodule Maxio.StoragePublishedProofFacadeTest do
  # 切换全局 backend + 使用脚本进程：必须 async: false。
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Maxio.Storage
  alias Maxio.Storage.{MutationContext, ObjectEpoch, PublishedProof}
  alias Maxio.Test.StoragePublishedProofScriptBackend, as: Script

  # --- Task 3 / G2 §4.3：Storage facade callback 异常边界 ---
  #
  # `Maxio.Storage` 是插件 trust boundary。它当前只校验**已返回的 term**：
  #
  #     def verify_published(ctx, opts \\ []) do
  #       guard_callback_result(:proof, backend().verify_published(ctx, opts))
  #     end
  #
  # backend callback 作为实参先被求值，因此 raise / catchable exit / throw 发生在
  # `guard_callback_result/2` 之前并原样逃逸。本文件把该缺口冻结成精确 oracle：
  # 两个 mode × 三种异常，全部必须折叠为固定的 contract violation，且 raw sentinel
  # 绝不出现在结果或日志中。
  #
  # 这是 G2 生产修复（§5.1，只属于 `Maxio.Storage` 的窄边界）的 RED；本轮不得为了让它
  # 变绿而给 Commit 或测试 backend 加 rescue/catch。

  @bucket "g2-facade-test"
  @proof_violation {:error, {:published_proof_contract_violation, :proof}}
  @finalize_violation {:error, {:published_proof_contract_violation, :finalize}}

  # 固定 raw sentinel：必须既不出现在返回值里，也不出现在捕获的日志里。
  @raise_sentinel "g2_facade_raw_raise_sentinel"
  @exit_sentinel :g2_facade_raw_exit_sentinel
  @throw_sentinel :g2_facade_raw_throw_sentinel

  setup do
    previous = Application.fetch_env!(:maxio, :storage_backend)
    Application.put_env(:maxio, :storage_backend, Script)
    on_exit(fn -> Application.put_env(:maxio, :storage_backend, previous) end)

    start_supervised!(Script)

    dir = Path.join(System.tmp_dir!(), "maxio_g2_facade_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    {:ok, dir: dir, previous_backend: previous}
  end

  defp ctx(key) do
    version_id = "null"
    {:ok, final_rel} = Maxio.Cluster.Paths.object_rel(@bucket, key, version_id)
    {:ok, target} = ObjectEpoch.object_target(@bucket, key, version_id)
    {:ok, token} = ObjectEpoch.token(7, "00000000-0000-0000-0000-0000000000f1")

    %MutationContext{
      mutation_id: "00000000-0000-0000-0000-0000000000f1",
      target: target,
      token: token,
      operation: "put",
      authority_mode: "pg",
      backend: "fs",
      final_rel: final_rel,
      bucket: @bucket,
      key: key,
      version_id: version_id
    }
  end

  defp canonical_proof_success do
    {:ok, {:verified, summary}} =
      PublishedProof.classify(1, [{"local", PublishedProof.verified("local", %{})}])

    {:ok, {:verified, summary}}
  end

  defp canonical_finalize_success do
    {:ok, {:finalized, summary}} =
      PublishedProof.classify_finalize(1, [
        {"local", PublishedProof.endpoint_finalized("local", %{})}
      ])

    {:ok, {:finalized, summary}}
  end

  defp refute_sentinel_leak!(result, log) do
    rendered = inspect(result)

    for sentinel <- [@raise_sentinel, to_string(@exit_sentinel), to_string(@throw_sentinel)] do
      refute String.contains?(rendered, sentinel),
             "raw sentinel #{sentinel} 泄漏进返回值：#{rendered}"

      refute String.contains?(log, sentinel),
             "raw sentinel #{sentinel} 泄漏进日志"
    end
  end

  # --- §4.3 异常边界矩阵：2 mode × 3 异常 = 六个**独立**测试 ---
  #
  # 刻意不把六格写进一个 `for`：在旧生产代码下，循环里的第一个 assert 会直接中止该测试，
  # 后两种异常根本不会被执行，`raise` 之外的四格就被静默掩盖了。六个独立用例保证每一格
  # 都真实执行、都有自己无歧义的失败签名，并各自证明 backend callback 确实被消费了一次。

  defp invoke(:proof, key, dir) do
    with_log(fn ->
      try do
        Storage.verify_published(ctx(key), data_dir: dir)
      rescue
        error -> {:escaped_raise, error}
      catch
        kind, reason -> {:escaped, kind, reason}
      end
    end)
  end

  defp invoke(:finalize, key, dir) do
    with_log(fn ->
      try do
        Storage.finalize_if_current(ctx(key), data_dir: dir)
      rescue
        error -> {:escaped_raise, error}
      catch
        kind, reason -> {:escaped, kind, reason}
      end
    end)
  end

  # 每格共用的完整 oracle：精确折叠结果 + 无 sentinel 泄漏 + callback 恰好执行一次。
  defp assert_folded!(mode, operation, expected, key, dir) do
    {result, log} = invoke(mode, key, dir)

    assert result == expected,
           "backend 异常必须在 Storage 边界折叠为 #{inspect(expected)}，实际：#{inspect(result)}"

    refute_sentinel_leak!(result, log)

    # 即使在 RED 下也要证明该 callback 真的被调用并消费了脚本条目。
    assert Script.call_count(operation) == 1
    assert Script.remaining(operation) == 0
  end

  @tag :task3_g2_commit_red
  test "g2 red: verify_published folds a backend raise into the proof violation", %{dir: dir} do
    Script.script(:verify_published, {:raise, @raise_sentinel})
    assert_folded!(:proof, :verify_published, @proof_violation, "facade-proof-raise", dir)
  end

  @tag :task3_g2_commit_red
  test "g2 red: verify_published folds a backend exit into the proof violation", %{dir: dir} do
    Script.script(:verify_published, {:exit, @exit_sentinel})
    assert_folded!(:proof, :verify_published, @proof_violation, "facade-proof-exit", dir)
  end

  @tag :task3_g2_commit_red
  test "g2 red: verify_published folds a backend throw into the proof violation", %{dir: dir} do
    Script.script(:verify_published, {:throw, @throw_sentinel})
    assert_folded!(:proof, :verify_published, @proof_violation, "facade-proof-throw", dir)
  end

  @tag :task3_g2_commit_red
  test "g2 red: finalize_if_current folds a backend raise into the finalize violation", %{
    dir: dir
  } do
    Script.script(:finalize_if_current, {:raise, @raise_sentinel})
    assert_folded!(:finalize, :finalize_if_current, @finalize_violation, "facade-fin-raise", dir)
  end

  @tag :task3_g2_commit_red
  test "g2 red: finalize_if_current folds a backend exit into the finalize violation", %{dir: dir} do
    Script.script(:finalize_if_current, {:exit, @exit_sentinel})
    assert_folded!(:finalize, :finalize_if_current, @finalize_violation, "facade-fin-exit", dir)
  end

  @tag :task3_g2_commit_red
  test "g2 red: finalize_if_current folds a backend throw into the finalize violation", %{
    dir: dir
  } do
    Script.script(:finalize_if_current, {:throw, @throw_sentinel})
    assert_folded!(:finalize, :finalize_if_current, @finalize_violation, "facade-fin-throw", dir)
  end

  # --- 保留控制：正常返回路径必须完全不变 ---

  @tag :task3_g2_commit_red
  test "g2 control: a canonical result is returned strictly identical", %{dir: dir} do
    proof = canonical_proof_success()
    finalize = canonical_finalize_success()

    Script.script(:verify_published, {:return, proof})
    Script.script(:finalize_if_current, {:return, finalize})

    assert Storage.verify_published(ctx("facade-ok-proof"), data_dir: dir) === proof
    assert Storage.finalize_if_current(ctx("facade-ok-finalize"), data_dir: dir) === finalize

    assert Script.remaining_all() == %{
             verify_published: 0,
             finalize_if_current: 0,
             current_epoch: 0,
             restore_if_current: 0
           }
  end

  @tag :task3_g2_commit_red
  test "g2 control: a malformed return is folded by the existing validate_callback_result", %{
    dir: dir
  } do
    malformed = [
      {:ok, :finalized},
      {:ok, {:verified, %{"scope" => "endpoint"}}},
      {:error, {:published_proof_failed, :fenced, %{}}},
      :ok,
      {:ok, {:bogus, %{}}}
    ]

    for {term, index} <- Enum.with_index(malformed) do
      Script.script(:verify_published, {:return, term})

      assert Storage.verify_published(ctx("facade-malformed-#{index}"), data_dir: dir) ==
               @proof_violation
    end

    assert Script.remaining(:verify_published) == 0
  end

  @tag :task3_g2_commit_red
  test "g2 control: proof and finalize modes do not accept each other's canonical result", %{
    dir: dir
  } do
    proof = canonical_proof_success()
    finalize = canonical_finalize_success()

    # finalize 的 canonical 结果送进 proof mode，反之亦然：都必须折叠。
    Script.script(:verify_published, {:return, finalize})
    Script.script(:finalize_if_current, {:return, proof})

    assert Storage.verify_published(ctx("facade-cross-proof"), data_dir: dir) == @proof_violation

    assert Storage.finalize_if_current(ctx("facade-cross-finalize"), data_dir: dir) ==
             @finalize_violation

    assert Script.remaining(:verify_published) == 0
    assert Script.remaining(:finalize_if_current) == 0
  end

  @tag :task3_g2_commit_red
  test "g2 control: the facade calls the configured backend exactly once per public call", %{
    dir: dir
  } do
    proof = canonical_proof_success()
    Script.script(:verify_published, {:return, proof})

    assert Storage.verify_published(ctx("facade-once"), data_dir: dir) === proof

    assert Script.call_count(:verify_published) == 1
    assert Script.call_count(:finalize_if_current) == 0

    # 记录到的 ctx/opts 就是调用方传入的那一组。
    assert [%{ctx: recorded_ctx, opts: recorded_opts}] = Script.calls(:verify_published)
    assert recorded_ctx.key == "facade-once"
    assert Keyword.fetch!(recorded_opts, :data_dir) == dir
  end

  @tag :task3_g2_commit_red
  test "g2 control: the script seam is live and the configured backend is the script backend" do
    assert Script.seam_live?()
    assert Application.fetch_env!(:maxio, :storage_backend) == Script
    assert Storage.backend() == Script

    assert Script.remaining_all() == %{
             verify_published: 0,
             finalize_if_current: 0,
             current_epoch: 0,
             restore_if_current: 0
           }
  end

  @tag :task3_g2_commit_red
  test "g2 control: unscripted operations delegate to FS unchanged", %{
    dir: dir,
    previous_backend: previous
  } do
    # 控制：on_exit 会精确恢复的原始 backend 值确实被记录下来了。
    assert previous == Maxio.Storage.FS

    {:ok, target} = ObjectEpoch.object_target(@bucket, "delegate-probe", "null")

    # current_epoch 未编排 → 委派 FS；空目录下 FS 返回 absent。
    assert Storage.current_epoch(target, data_dir: dir) == {:ok, :absent}

    assert Script.call_count(:current_epoch) == 1
    assert Script.remaining(:current_epoch) == 0
  end
end
