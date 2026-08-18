defmodule Maxio.S3.ObjectWriterExternalErrorTest do
  # R1/R2/R3 起本文件同时承载「静态源码 oracle」与三个动态映射 test（pre-proof unavailable
  # → 503、真实 FS pre-proof mismatch → 500、unrelated metadata-CAS 失败 → 500）：
  # 后者需要真实 PG journal / FS 字节 / scripted backend，故整模块 `Maxio.DataCase, async: false`。
  # 全程无 HTTP、无 Process.sleep。
  use Maxio.DataCase, async: false

  import ExUnit.CaptureLog

  alias Maxio.Buckets
  alias Maxio.Cluster.Paths
  alias Maxio.Objects
  alias Maxio.ObjectMutation
  alias Maxio.ObjectMutation.Journal
  alias Maxio.S3.ObjectWriter
  alias Maxio.Storage
  alias Maxio.Storage.ObjectEpoch
  alias Maxio.Storage.PublishedProof
  alias Maxio.Test.StoragePublishedProofScriptBackend, as: Script

  setup do
    data_dir =
      Path.join(System.tmp_dir!(), "maxio_ow_extern_#{System.unique_integer([:positive])}")

    File.rm_rf(data_dir)
    File.mkdir_p!(data_dir)

    prev_s3 = Application.get_env(:maxio, :s3)
    Application.put_env(:maxio, :s3, Keyword.put(prev_s3, :data_dir, data_dir))

    prev_backend = Application.fetch_env!(:maxio, :storage_backend)
    Application.put_env(:maxio, :storage_backend, Script)

    on_exit(fn ->
      Application.put_env(:maxio, :storage_backend, prev_backend)
      Application.put_env(:maxio, :s3, prev_s3)
      Maxio.Failpoint.disarm(:object_mutation_before_metadata_commit)
      Maxio.Failpoint.disarm(:object_mutation_after_metadata_commit)
      File.rm_rf(data_dir)
    end)

    start_supervised!(Script)

    bucket = "owext-#{System.unique_integer([:positive])}"
    {:ok, _bucket} = Buckets.create(bucket, "arn:aws:iam:::root")

    %{data_dir: data_dir, bucket: bucket}
  end

  # --- Task 3 / G4a-2W：ObjectWriter 复用唯一共享适配器的静态 scope oracle（RED，R0）---
  #
  # 本文件总计**四个** test：一个静态 oracle（本节）+ 三个动态 test（R1/R2/R3）。
  # 本节这**唯一的静态** test 断言未来的 `lib/maxio/s3/object_writer.ex` 在
  # `raise_storage_write_error/3` 内**恰好一次**调用解析到
  # `Maxio.S3.ObjectMutationError.to_error/2`，且：
  #
  #   * 全文件没有任何其它（foreign）`to_error/2` 远程调用；
  #   * 该 helper 内不出现保留稳定信封 tag（published_proof_* / object_mutation_journal）；
  #   * **整个适配器决策边界**内不出现可执行 `inspect`——不仅是 `{:ok, error}` 投影分支，
  #     也包括 ObjectWriter 最终「未知 `:unrelated`」兜底分支：该兜底必须走目录默认
  #     InternalError（`Error.new(:internal_error, resource: ...)`），绝不可 `inspect(reason)`
  #     把原始 reason 塞进公共 message；已知的 quorum / placement legacy 分类照旧保留，
  #     且同样不带 raw inspect。唯一仍保留 legacy `inspect` 的是 handler 侧另一个
  #     非 G4 的共享 helper，不在本 oracle 的 scope 内；
  #   * 该 helper 内不直接依赖 Commit / Recovery / Storage / PublishedProof /
  #     StorageDisposition / Journal —— 类别决策只能来自共享适配器。
  #
  # 非空转对照写在**同一个 test 内**并先于生产断言执行：探测器必须拒绝「调用两次」、
  # 「alias 了 ObjectMutationError 但实际调用 Other.to_error/2」、「目标 arity 错误」，
  # 并且对只出现在 @moduledoc / @doc / 注释里的禁词零误报；四种 alias 写法
  # （完全限定 / 普通 alias / alias ..., as: / 分组 alias）都必须解析到同一目标。

  @production_path "lib/maxio/s3/object_writer.ex"

  @adapter_parts [:Maxio, :S3, :ObjectMutationError]
  @helper_name :raise_storage_write_error
  @helper_arity 3

  @reserved_tags [
    :published_proof_failed,
    :published_proof_superseded,
    :published_proof_contract_violation,
    :object_mutation_journal
  ]

  @forbidden_modules [
    [:Maxio, :ObjectMutation, :Commit],
    [:Maxio, :ObjectMutation, :Recovery],
    [:Maxio, :ObjectMutation, :Journal],
    [:Maxio, :ObjectMutation, :StorageDisposition],
    [:Maxio, :Storage],
    [:Maxio, :Storage, :PublishedProof]
  ]

  test "g4a-2w red: object_writer delegates exactly once, inside raise_storage_write_error/3, to Maxio.S3.ObjectMutationError.to_error/2" do
    # =================================================================
    # 非空转对照（先跑：生产 RED 失败时这些已被证明通过）
    # =================================================================

    # --- 合法：四种 alias 写法都解析到同一目标，且计为恰好一次 ---
    for {label, source} <- alias_style_controls() do
      ast = analyzable_ast(source)
      helper = helper_body!(ast)

      assert length(adapter_to_error_calls(ast, helper)) === 1,
             "T3-G4a-2W control(#{label}): #{label} 写法必须解析为恰好一次委派"

      assert foreign_to_error_calls(ast) === [],
             "T3-G4a-2W control(#{label}): 合法委派不得被记为 foreign 调用"
    end

    # --- 拒绝：同一 helper 内调用两次 ---
    twice = """
    defmodule Sample do
      alias Maxio.S3.ObjectMutationError

      defp raise_storage_write_error(reason, bucket, key) do
        case ObjectMutationError.to_error(reason, "/\#{bucket}/\#{key}") do
          {:ok, error} -> raise error
          :unrelated -> retry(reason, bucket, key)
        end
      end

      defp retry(reason, bucket, key) do
        case Maxio.S3.ObjectMutationError.to_error(reason, "/\#{bucket}/\#{key}") do
          {:ok, error} -> raise error
          :unrelated -> :ok
        end
      end
    end
    """

    twice_ast = analyzable_ast(twice)

    assert length(adapter_to_error_calls(twice_ast, helper_body!(twice_ast))) === 1 and
             length(adapter_to_error_calls(twice_ast, twice_ast)) === 2,
           "T3-G4a-2W control: 重复委派必须被计数识别，绝不能被「至少一次」的探测器放过"

    # --- 拒绝：alias 了 ObjectMutationError，实际把决策交给 Other.to_error/2 ---
    foreign = """
    defmodule Sample do
      alias Maxio.S3.ObjectMutationError
      alias Maxio.S3.OtherPolicy, as: Other

      defp raise_storage_write_error(reason, bucket, key) do
        case Other.to_error(reason, "/\#{bucket}/\#{key}") do
          {:ok, error} -> raise error
          :unrelated -> :ok
        end
      end
    end
    """

    foreign_ast = analyzable_ast(foreign)

    assert adapter_to_error_calls(foreign_ast, helper_body!(foreign_ast)) === [],
           "T3-G4a-2W control: 仅 alias/提及 ObjectMutationError 不得被当成委派"

    refute foreign_to_error_calls(foreign_ast) === [],
           "T3-G4a-2W control: 非共享适配器的 to_error 调用必须被识别为 foreign"

    # --- 拒绝：目标 arity 错误 ---
    wrong_arity = """
    defmodule Sample do
      alias Maxio.S3.ObjectMutationError

      defp raise_storage_write_error(reason, bucket, key) do
        ObjectMutationError.to_error(reason, bucket, key)
      end
    end
    """

    wrong_arity_ast = analyzable_ast(wrong_arity)

    assert adapter_to_error_calls(wrong_arity_ast, helper_body!(wrong_arity_ast)) === [],
           "T3-G4a-2W control: 错误 arity 不得被当成合法委派"

    refute foreign_to_error_calls(wrong_arity_ast) === [],
           "T3-G4a-2W control: 错误 arity 的 to_error 调用必须被识别为 foreign"

    # --- 拒绝：委派分支内的可执行 inspect / 保留 tag / 禁止依赖 ---
    dirty = """
    defmodule Sample do
      alias Maxio.S3.ObjectMutationError
      alias Maxio.ObjectMutation.Commit

      defp raise_storage_write_error(reason, bucket, key) do
        case ObjectMutationError.to_error(reason, "/\#{bucket}/\#{key}") do
          {:ok, error} -> raise %{error | message: inspect(reason)}
          :unrelated -> Commit.classify({:published_proof_failed, :unavailable, reason})
        end
      end
    end
    """

    dirty_ast = analyzable_ast(dirty)
    dirty_helper = helper_body!(dirty_ast)

    refute delegating_branch_inspect_refs(dirty_ast, dirty_helper) === [],
           "T3-G4a-2W control: 委派分支内的可执行 inspect 必须被识别"

    refute reserved_tag_refs(dirty_helper) === [],
           "T3-G4a-2W control: helper 内的保留稳定信封 tag 必须被识别"

    refute forbidden_module_refs(dirty_helper) === [],
           "T3-G4a-2W control: helper 内的 Commit/Recovery/Storage/... 直连依赖必须被识别"

    # --- 拒绝：投影分支干净，但最终未知 :unrelated 兜底 inspect(reason) ---
    # 裁定：该兜底必须走目录默认 InternalError，绝不可把 raw reason 塞进公共 message。
    unrelated_inspect = """
    defmodule Sample do
      alias Maxio.S3.{Error, ObjectMutationError}

      defp raise_storage_write_error(reason, bucket, key) do
        case ObjectMutationError.to_error(reason, "/\#{bucket}/\#{key}") do
          {:ok, error} ->
            raise error

          :unrelated ->
            raise Error.new(:internal_error,
                    message: inspect(reason),
                    resource: "/\#{bucket}/\#{key}"
                  )
        end
      end
    end
    """

    unrelated_ast = analyzable_ast(unrelated_inspect)
    unrelated_helper = helper_body!(unrelated_ast)

    assert length(adapter_to_error_calls(unrelated_ast, unrelated_helper)) === 1,
           "T3-G4a-2W control: 该样本必须仍被认作一次合法委派，失败点只能是 inspect"

    refute delegating_branch_inspect_refs(unrelated_ast, unrelated_helper) === [],
           "T3-G4a-2W control: 最终未知 :unrelated 兜底分支里的 inspect(reason) 必须被识别"

    # --- 零误报：只出现在 @moduledoc / @doc / 注释里的禁词 ---
    docs_only = """
    defmodule Sample do
      @moduledoc "委派给 Maxio.S3.ObjectMutationError.to_error/2；published_proof_failed 归 ExternalError。"

      @doc "Commit / Recovery / Storage / PublishedProof / Journal 只出现在文档里；绝不 inspect。"
      # ObjectMutationError.to_error(reason, resource) 只是注释。
      defp raise_storage_write_error(_reason, bucket, key) do
        raise Error.new(:internal_error, resource: "/\#{bucket}/\#{key}")
      end
    end
    """

    docs_ast = analyzable_ast(docs_only)
    docs_helper = helper_body!(docs_ast)

    assert adapter_to_error_calls(docs_ast, docs_helper) === []
    assert foreign_to_error_calls(docs_ast) === []
    assert delegating_branch_inspect_refs(docs_ast, docs_helper) === []
    assert reserved_tag_refs(docs_helper) === []
    assert forbidden_module_refs(docs_helper) === []

    # =================================================================
    # 生产断言（当前应且只应因「目标调用缺席」而失败）
    # =================================================================

    assert File.exists?(@production_path),
           "T3-G4a-2W: production source #{@production_path} 不存在"

    ast = @production_path |> File.read!() |> analyzable_ast()
    helper = helper_body!(ast)

    # 先锁「不该有的东西」：这些当前已满足，绝不构成 RED 噪声。
    assert reserved_tag_refs(helper) === [],
           "T3-G4a-2W: 稳定信封只能由冻结的 ExternalError 匹配，#{@helper_name}/#{@helper_arity} 不得直接匹配"

    assert delegating_branch_inspect_refs(ast, helper) === [],
           "T3-G4a-2W: 承载委派的分支绝不可 inspect reason"

    assert forbidden_module_refs(helper) === [],
           "T3-G4a-2W: #{@helper_name}/#{@helper_arity} 不得直连 Commit/Recovery/Storage/PublishedProof/" <>
             "StorageDisposition/Journal —— 类别决策只能来自共享适配器"

    assert foreign_to_error_calls(ast) === [],
           "T3-G4a-2W: 除共享适配器外不允许任何其它 to_error/2 远程调用"

    # 唯一应当失败的断言：委派尚未接线。
    in_helper = adapter_to_error_calls(ast, helper)
    in_file = adapter_to_error_calls(ast, ast)

    assert length(in_helper) === 1,
           "T3-G4a-2W: #{@helper_name}/#{@helper_arity} 必须恰好一次调用 " <>
             "Maxio.S3.ObjectMutationError.to_error/2，实际解析到 #{inspect(in_helper)}"

    assert length(in_file) === 1,
           "T3-G4a-2W: 全文件只允许一次共享适配器委派，且必须位于 " <>
             "#{@helper_name}/#{@helper_arity}，实际解析到 #{inspect(in_file)}"
  end

  # =====================================================================
  # G4a-2W 动态 RED：pre-metadata proof unavailable → 公共 503 SlowDownWrite
  # =====================================================================
  #
  # 先证明**内部不变量**（seam 已按协议收敛：verify +1 / finalize +0 / FIFO 精确消费 /
  # 旧字节·sidecar·PG 逐字节恢复 / journal gen2 rolled_back / epoch rolled_back /
  # 无遗留 backup ⇒ 无需 handler 或 Recovery 动作），再断言**公共错误**。因此当前生产
  # 只应在最后的公共映射处 RED，绝不在 setup / fixture / 不变量处失败。

  @dynamic_key "generated/g4a2w-unavailable.bin"
  @old_body "g4a-2w old generated body"
  @new_body "g4a-2w new body must not commit"

  @slow_down_write_code "SlowDownWrite"
  @slow_down_write_status 503
  @slow_down_write_message "Resource requested is unwritable, please reduce your request rate"

  test "g4a-2w red: a pre-metadata unavailable proof surfaces as 503 SlowDownWrite without leaking material",
       ctx do
    # --- baseline：脚本尚未编排前先写入旧对象 ---
    _old = ObjectWriter.put_generated!(ctx.bucket, @dynamic_key, [@old_body], sse_target: nil)

    final = final_dir(ctx, ctx.bucket, @dynamic_key)
    old_bytes = File.read!(Path.join(final, "part.0"))
    old_sidecar = File.read!(Path.join(final, "meta.json"))
    assert {:ok, %Objects.Object{etag: old_etag}} = Objects.get_metadata(ctx.bucket, @dynamic_key)

    baseline_verify = Script.call_count(:verify_published)
    baseline_finalize = Script.call_count(:finalize_if_current)

    # --- canonical 的 pre-metadata unavailable proof 失败（携唯一 opaque endpoint sentinel）---
    endpoint_sentinel = "g4a2w-endpoint-#{System.unique_integer([:positive])}-0f3c91"

    # endpoint identity 受冻结的 `local` / `ordinal:N` 词法约束，故 sentinel 落在 endpoint
    # detail（`:code`）上：它同样是唯一、opaque 的原始材料，绝不得进入公共错误。
    scripted =
      PublishedProof.classify(1, [
        {"local",
         PublishedProof.failed(:unavailable, "local", %{owned: true, code: endpoint_sentinel})}
      ])

    assert {:error, {:published_proof_failed, :unavailable, _summary}} = scripted

    # baseline 之后**只**编排这一条 verify_published。
    Script.script(:verify_published, {:return, scripted})

    {error, log} =
      with_log(fn ->
        try do
          _ =
            ObjectWriter.put_generated!(ctx.bucket, @dynamic_key, [@new_body], sse_target: nil)

          flunk("put_generated!/4 必须在 pre-metadata proof 失败时抛出 Maxio.S3.Error")
        rescue
          raised in Maxio.S3.Error -> raised
        end
      end)

    # === 内部不变量（必须先于公共映射断言通过）===

    assert Script.call_count(:verify_published) === baseline_verify + 1,
           "T3-G4a-2W: scripted verify_published 必须恰好被消费一次"

    assert Script.call_count(:finalize_if_current) === baseline_finalize,
           "T3-G4a-2W: pre-metadata proof 失败绝不允许发生 finalize"

    assert Script.remaining_all() ===
             %{
               verify_published: 0,
               finalize_if_current: 0,
               current_epoch: 0,
               restore_if_current: 0
             },
           "T3-G4a-2W: FIFO 必须被精确消费完"

    # 旧对象逐字节恢复、PG 行原样。
    assert File.read!(Path.join(final, "part.0")) === old_bytes
    assert File.read!(Path.join(final, "meta.json")) === old_sidecar

    assert {:ok, %Objects.Object{etag: ^old_etag}} =
             Objects.get_metadata(ctx.bucket, @dynamic_key)

    # journal / epoch 双双收敛到 rollback 终态；backup 已清空 ⇒ 无需 handler / Recovery 动作。
    journal = journal_for(ctx.bucket, @dynamic_key)
    assert journal.generation === 2
    assert journal.phase === "rolled_back"

    assert {:ok, %ObjectEpoch{phase: "rolled_back"}} =
             Storage.current_epoch(epoch_target(ctx.bucket, @dynamic_key))

    assert mutation_dirs(ctx) === []

    # === 公共错误映射（当前生产唯一应当 RED 的地方）===

    assert error.code === @slow_down_write_code,
           "T3-G4a-2W: pre-metadata unavailable proof 必须映射为 SlowDownWrite，实际 #{error.code}"

    assert error.http_status === @slow_down_write_status
    assert error.message === @slow_down_write_message
    assert error.resource === "/#{ctx.bucket}/#{@dynamic_key}"

    # === 公共面零泄漏 ===

    rendered = Exception.message(error) <> " " <> inspect(error)

    for leak <- [endpoint_sentinel, ctx.data_dir, @new_body] do
      refute String.contains?(rendered, leak),
             "T3-G4a-2W: 公共异常渲染泄漏了原始材料 #{leak}"
    end

    for leak <- [endpoint_sentinel, @new_body] do
      refute String.contains?(log, leak), "T3-G4a-2W: 日志泄漏了原始材料 #{leak}"
    end

    # 服务端日志**允许**出现冻结的安全 code：它不是原始材料，不得被全局禁词误伤。
    assert is_binary(log)
  end

  # =====================================================================
  # G4a-2W 动态 RED：pre-metadata proof mismatch → 公共 500 InternalError（默认 message）
  # =====================================================================
  #
  # 与 R1 不同，这里**不伪造** verify 结果：Script FIFO 保持为空、verify_published 真实
  # 委派给 FS。经正式挂点 `:object_mutation_after_publish_before_proof` 在 proof 之前
  # 往刚 publish 的 final `part.0` 追加一段唯一注入 sentinel（不 raise），于是真实 FS
  # 校验必然判定 integrity mismatch——确定性、无权限竞态、无 sleep。

  @mismatch_key "generated/g4a2w-mismatch.bin"
  @mismatch_old_body "g4a-2w mismatch old generated body"
  @mismatch_new_body "g4a-2w mismatch new body must not commit"

  @internal_code "InternalError"
  @internal_status 500
  @internal_message "An internal error occurred. Try again."
  @mismatch_stable_code "published_proof_failed:proof:mismatch"

  test "g4a-2w red: a real-FS pre-metadata mismatch proof surfaces as 500 InternalError with the default message",
       ctx do
    _old =
      ObjectWriter.put_generated!(ctx.bucket, @mismatch_key, [@mismatch_old_body],
        sse_target: nil
      )

    final = final_dir(ctx, ctx.bucket, @mismatch_key)
    old_bytes = File.read!(Path.join(final, "part.0"))
    old_sidecar = File.read!(Path.join(final, "meta.json"))

    assert {:ok, %Objects.Object{etag: old_etag}} =
             Objects.get_metadata(ctx.bucket, @mismatch_key)

    baseline_verify = Script.call_count(:verify_published)
    baseline_finalize = Script.call_count(:finalize_if_current)

    injected_sentinel = "g4a2w-injected-#{System.unique_integer([:positive])}-7b21e4"
    arm_final_corruption!(Path.join(final, "part.0"), injected_sentinel)

    {error, log} =
      with_log(fn ->
        try do
          _ =
            ObjectWriter.put_generated!(ctx.bucket, @mismatch_key, [@mismatch_new_body],
              sse_target: nil
            )

          flunk("put_generated!/4 必须在 pre-metadata proof mismatch 时抛出 Maxio.S3.Error")
        rescue
          raised in Maxio.S3.Error -> raised
        end
      end)

    # === 内部不变量（必须先于公共映射断言通过）===

    assert Script.call_count(:verify_published) === baseline_verify + 1,
           "T3-G4a-2W: verify_published 必须真实委派 FS 且恰好一次"

    assert Script.call_count(:finalize_if_current) === baseline_finalize,
           "T3-G4a-2W: pre-metadata mismatch 绝不允许发生 finalize"

    assert Script.remaining_all() ===
             %{
               verify_published: 0,
               finalize_if_current: 0,
               current_epoch: 0,
               restore_if_current: 0
             },
           "T3-G4a-2W: 本用例不编排任何伪造结果，FIFO 必须始终为空"

    assert File.read!(Path.join(final, "part.0")) === old_bytes
    assert File.read!(Path.join(final, "meta.json")) === old_sidecar

    assert {:ok, %Objects.Object{etag: ^old_etag}} =
             Objects.get_metadata(ctx.bucket, @mismatch_key)

    journal = journal_for(ctx.bucket, @mismatch_key)
    assert journal.generation === 2
    assert journal.phase === "rolled_back"

    assert journal.last_error === @mismatch_stable_code,
           "T3-G4a-2W: 必须写入精确、未加引号的 mismatch 稳定 code"

    assert {:ok, %ObjectEpoch{phase: "rolled_back"}} =
             Storage.current_epoch(epoch_target(ctx.bucket, @mismatch_key))

    assert mutation_dirs(ctx) === []

    # === 公共错误映射 ===

    assert error.code === @internal_code
    assert error.http_status === @internal_status
    assert error.resource === "/#{ctx.bucket}/#{@mismatch_key}"

    assert error.message === @internal_message,
           "T3-G4a-2W: mismatch 必须使用目录默认 message，绝不可 inspect 原始 reason"

    # === 公共面零泄漏 ===

    rendered = Exception.message(error) <> " " <> inspect(error)

    for leak <- [injected_sentinel, ctx.data_dir, @mismatch_new_body, "published_proof_failed"] do
      refute String.contains?(rendered, leak),
             "T3-G4a-2W: 公共异常渲染泄漏了原始材料 #{leak}"
    end

    for leak <- [injected_sentinel, ctx.data_dir, @mismatch_new_body] do
      refute String.contains?(log, leak), "T3-G4a-2W: 日志泄漏了原始材料 #{leak}"
    end

    # 服务端日志**允许**出现冻结的安全 code。
    assert is_binary(log)
  end

  # =====================================================================
  # G4a-2W 动态 RED：unrelated metadata-CAS 失败 → 公共 500 InternalError（默认 message）
  # =====================================================================
  #
  # 与 R1/R2 不同，这里的失败**完全不在 published proof 语义之内**：proof 真实通过，
  # 随后正式挂点 `:object_mutation_before_metadata_commit` 扰动刚 published 的 journal
  # （保留取证的 `ObjectMutation.mark_operational_error/3`，attempts+1），使 metadata 事务内基于旧 journal 行的
  # CAS 必然 stale → 真实 metadata_tx 失败 → 走 ObjectWriter 的「未知 `:unrelated`」兜底。
  # 该兜底当前把 raw reason `inspect` 进公共 message，这正是本用例唯一应当 RED 的能力点。

  @cas_key "generated/g4a2w-metadata-cas.bin"
  @cas_old_body "g4a-2w metadata-cas old generated body"
  @cas_new_body "g4a-2w metadata-cas new body must not commit"

  # raw metadata-CAS reason 的稳定字面片段：绝不允许出现在公共渲染里。
  @cas_raw_reason_tokens ["stale_journal", "object_mutation_metadata_commit_failed"]

  test "g4a-2w red: an unrelated metadata-CAS failure surfaces as 500 InternalError with the default message",
       ctx do
    _old =
      ObjectWriter.put_generated!(ctx.bucket, @cas_key, [@cas_old_body], sse_target: nil)

    final = final_dir(ctx, ctx.bucket, @cas_key)
    old_bytes = File.read!(Path.join(final, "part.0"))
    old_sidecar = File.read!(Path.join(final, "meta.json"))

    assert {:ok, %Objects.Object{etag: old_etag}} = Objects.get_metadata(ctx.bucket, @cas_key)

    baseline_verify = Script.call_count(:verify_published)
    baseline_finalize = Script.call_count(:finalize_if_current)

    perturb_sentinel = "g4a2w-cas-#{System.unique_integer([:positive])}-4d8ae0"
    arm_stale_metadata_perturbation!(ctx.bucket, @cas_key, perturb_sentinel)

    {error, log} =
      with_log(fn ->
        try do
          _ =
            ObjectWriter.put_generated!(ctx.bucket, @cas_key, [@cas_new_body], sse_target: nil)

          flunk("put_generated!/4 必须在 metadata CAS 失败时抛出 Maxio.S3.Error")
        rescue
          raised in Maxio.S3.Error -> raised
        end
      end)

    # === 内部不变量（必须先于公共映射断言通过）===

    assert Script.call_count(:verify_published) === baseline_verify + 1,
           "T3-G4a-2W: proof 必须真实通过且 verify_published 恰好一次"

    assert Script.call_count(:finalize_if_current) === baseline_finalize,
           "T3-G4a-2W: metadata CAS 失败绝不允许发生 finalize"

    assert Script.remaining_all() ===
             %{
               verify_published: 0,
               finalize_if_current: 0,
               current_epoch: 0,
               restore_if_current: 0
             },
           "T3-G4a-2W: 本用例不编排任何伪造结果，FIFO 必须始终为空"

    # 旧对象逐字节恢复、PG 行原样。
    assert File.read!(Path.join(final, "part.0")) === old_bytes
    assert File.read!(Path.join(final, "meta.json")) === old_sidecar

    assert {:ok, %Objects.Object{etag: ^old_etag}} =
             Objects.get_metadata(ctx.bucket, @cas_key)

    journal = journal_for(ctx.bucket, @cas_key)
    assert journal.generation === 2
    assert journal.phase === "rolled_back"

    assert {:ok, %ObjectEpoch{phase: "rolled_back"}} =
             Storage.current_epoch(epoch_target(ctx.bucket, @cas_key))

    assert mutation_dirs(ctx) === []

    # === 公共错误映射 ===

    assert error.code === @internal_code
    assert error.http_status === @internal_status
    assert error.resource === "/#{ctx.bucket}/#{@cas_key}"

    assert error.message === @internal_message,
           "T3-G4a-2W: 未知 :unrelated 兜底必须使用目录默认 message，绝不可 inspect 原始 reason"

    # === 公共面零泄漏 ===

    rendered = Exception.message(error) <> " " <> inspect(error)

    for leak <- [perturb_sentinel, ctx.data_dir, @cas_new_body | @cas_raw_reason_tokens] do
      refute String.contains?(rendered, leak),
             "T3-G4a-2W: 公共异常渲染泄漏了原始材料 #{leak}"
    end

    for leak <- [perturb_sentinel, ctx.data_dir, @cas_new_body] do
      refute String.contains?(log, leak), "T3-G4a-2W: 日志泄漏了原始材料 #{leak}"
    end

    # 服务端日志**允许**出现冻结的安全 G2/G3 code。
    assert is_binary(log)
  end

  # --- 动态测试辅助 ---

  # publish 之后、metadata 事务之前扰动目标 journal（attempts+1）：事务 hook 内基于
  # 请求手中旧 journal 行的 CAS 必然 stale → 整个 metadata 事务回滚（与
  # object_writer_mutation_test 同源注入手段）。
  #
  # 必须用**保留取证的** operational CAS probe `mark_operational_error/3`（design D6 §3.3）：
  # 只动 attempts / next_attempt_at / bounded last_error / updated_at，逐字保留 published 行
  # 上的 `published_fingerprint` 与 canonical successful wrapper，于是随后的
  # `request_rollback/3` 仍持有合法 durable evidence，可同步 restore 旧对象。legacy
  # `mark_error/4` 会替换 recovery_evidence 并被 published-origin 校验合法拒绝。
  #
  # reason 直接用唯一 probe sentinel（稳定 binary）：它随即被 bounded 写进 journal
  # last_error，因此下面的公开异常/日志零泄漏反证依然是真实、有意义的反证。
  defp arm_stale_metadata_perturbation!(bucket, key, sentinel) do
    Maxio.Failpoint.arm(
      :object_mutation_before_metadata_commit,
      {:fun,
       fn ->
         journal =
           Repo.one!(
             from j in Journal,
               where: j.bucket_name == ^bucket and j.object_key == ^key and j.phase == "published"
           )

         {:ok, _} = ObjectMutation.mark_operational_error(journal, sentinel)
       end}
    )

    on_exit(fn -> Maxio.Failpoint.disarm(:object_mutation_before_metadata_commit) end)
  end

  # proof 之前的正式挂点：不 raise，只把唯一 sentinel 追加进刚 publish 的 final part.0，
  # 让真实 FS verify_published 确定性地判定 integrity mismatch。
  defp arm_final_corruption!(part_path, sentinel) do
    Maxio.Failpoint.arm(
      :object_mutation_after_publish_before_proof,
      {:fun, fn -> File.write!(part_path, sentinel, [:append]) end}
    )

    on_exit(fn -> Maxio.Failpoint.disarm(:object_mutation_after_publish_before_proof) end)
  end

  defp journal_for(bucket, key) do
    Repo.one!(
      from j in Journal,
        where: j.bucket_name == ^bucket and j.object_key == ^key,
        order_by: [desc: j.generation],
        limit: 1
    )
  end

  defp epoch_target(bucket, key) do
    {:ok, target} = ObjectEpoch.object_target(bucket, key, "null")
    target
  end

  defp final_dir(ctx, bucket, key) do
    {:ok, rel} = Paths.object_rel(bucket, key, "null")
    Path.join(ctx.data_dir, rel)
  end

  defp mutation_dirs(ctx) do
    case File.ls(Path.join(ctx.data_dir, ".maxio-object-mutations")) do
      {:ok, entries} -> entries
      {:error, :enoent} -> []
    end
  end

  # --- 合法 alias 写法对照样本 ---

  defp alias_style_controls do
    [
      {"fully qualified",
       """
       defmodule Sample do
         defp raise_storage_write_error(reason, bucket, key) do
           case Maxio.S3.ObjectMutationError.to_error(reason, "/\#{bucket}/\#{key}") do
             {:ok, error} -> raise error
             :unrelated -> :ok
           end
         end
       end
       """},
      {"plain alias",
       """
       defmodule Sample do
         alias Maxio.S3.ObjectMutationError

         defp raise_storage_write_error(reason, bucket, key) do
           case ObjectMutationError.to_error(reason, "/\#{bucket}/\#{key}") do
             {:ok, error} -> raise error
             :unrelated -> :ok
           end
         end
       end
       """},
      {"renamed alias",
       """
       defmodule Sample do
         alias Maxio.S3.ObjectMutationError, as: Adapter

         defp raise_storage_write_error(reason, bucket, key) do
           case Adapter.to_error(reason, "/\#{bucket}/\#{key}") do
             {:ok, error} -> raise error
             :unrelated -> :ok
           end
         end
       end
       """},
      {"grouped alias",
       """
       defmodule Sample do
         alias Maxio.S3.{Error, ObjectMutationError}

         defp raise_storage_write_error(reason, bucket, key) do
           case ObjectMutationError.to_error(reason, "/\#{bucket}/\#{key}") do
             {:ok, error} -> raise error
             :unrelated -> raise Error.new(:internal_error, resource: "/\#{bucket}/\#{key}")
           end
         end
       end
       """}
    ]
  end

  # --- 静态 oracle 辅助 ---

  defp analyzable_ast(source) do
    source
    |> Code.string_to_quoted!()
    |> strip_defmodule_name()
    |> strip_docs()
  end

  defp strip_defmodule_name(ast) do
    Macro.prewalk(ast, fn
      {:defmodule, meta, [{:__aliases__, _alias_meta, _parts} | rest]} ->
        {:defmodule, meta, [:__module_name_stripped__ | rest]}

      node ->
        node
    end)
  end

  defp strip_docs(ast) do
    Macro.prewalk(ast, fn
      {:@, _meta, [{doc, _doc_meta, _args}]} when doc in [:moduledoc, :doc, :typedoc] ->
        :__doc_stripped__

      node ->
        node
    end)
  end

  # `raise_storage_write_error/3` 的定义子树（含所有 clause）；缺席即失败。
  defp helper_body!(ast) do
    {_ast, defs} =
      Macro.prewalk(ast, [], fn
        {def_kind, _meta, [{@helper_name, _name_meta, args} | _rest]} = node, acc
        when def_kind in [:def, :defp] and is_list(args) ->
          if length(args) === @helper_arity, do: {node, [node | acc]}, else: {node, acc}

        {def_kind, _meta,
         [{:when, _when_meta, [{@helper_name, _name_meta, args} | _guards]} | _rest]} =
            node,
        acc
        when def_kind in [:def, :defp] and is_list(args) ->
          if length(args) === @helper_arity, do: {node, [node | acc]}, else: {node, acc}

        node, acc ->
          {node, acc}
      end)

    refute defs === [],
           "T3-G4a-2W: 找不到 #{@helper_name}/#{@helper_arity} 定义"

    Enum.reverse(defs)
  end

  # 解析到 Maxio.S3.ObjectMutationError.to_error/2 的执行调用（scope 内）。
  defp adapter_to_error_calls(root_ast, scope) do
    env = alias_env(root_ast)

    scope
    |> to_error_call_targets(env)
    |> Enum.filter(&(&1 === {@adapter_parts, 2}))
  end

  # 任何其它 to_error 远程调用（别的模块 / 错误 arity）都不是合法委派。
  defp foreign_to_error_calls(root_ast) do
    env = alias_env(root_ast)

    root_ast
    |> to_error_call_targets(env)
    |> Enum.reject(&(&1 === {@adapter_parts, 2}))
  end

  defp to_error_call_targets(ast, env) do
    {_ast, targets} =
      Macro.prewalk(ast, [], fn
        {{:., _dot_meta, [{:__aliases__, _alias_meta, parts}, :to_error]}, _meta, args} = node,
        acc
        when is_list(args) ->
          if Enum.all?(parts, &is_atom/1),
            do: {node, [{resolve_alias(parts, env), length(args)} | acc]},
            else: {node, acc}

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(targets)
  end

  # 覆盖**整个适配器决策边界**：以委派结果为 subject 的 `case`/`with` 的**全部** clause
  # （`{:ok, error}` 投影分支与最终未知 `:unrelated` 兜底分支一视同仁），以及委派调用本身
  # 所在的 `->` 分支。裁定：未知 `:unrelated` 兜底必须用目录默认 InternalError，绝不可
  # `inspect(reason)`；已知 quorum / placement legacy 分类保留但同样不得 raw inspect。
  # 仍保留 legacy inspect 的只有 handler 侧另一个非 G4 共享 helper——它不在本 scope 内。
  defp delegating_branch_inspect_refs(root_ast, scope) do
    env = alias_env(root_ast)

    {_ast, hits} =
      Macro.prewalk(scope, [], fn
        {branch_kind, _meta, [subject, blocks]} = node, acc
        when branch_kind in [:case, :with] and is_list(blocks) ->
          if delegates?(subject, env),
            do: {node, acc ++ inspect_refs(blocks)},
            else: {node, acc}

        {:->, _meta, [_head, branch_body]} = node, acc ->
          if delegates?(branch_body, env),
            do: {node, acc ++ inspect_refs(branch_body)},
            else: {node, acc}

        node, acc ->
          {node, acc}
      end)

    hits
  end

  defp delegates?(ast, env) do
    ast
    |> to_error_call_targets(env)
    |> Enum.any?(&(&1 === {@adapter_parts, 2}))
  end

  defp inspect_refs(ast) do
    collect_nodes(ast, fn
      {:inspect, _meta, args} when is_list(args) and length(args) in [1, 2] ->
        true

      {{:., _dot_meta, [_target, :inspect]}, _meta, args} when is_list(args) ->
        true

      _node ->
        false
    end)
  end

  defp reserved_tag_refs(ast), do: collect_nodes(ast, &(&1 in @reserved_tags))

  defp forbidden_module_refs(ast) do
    collect_nodes(ast, fn
      {:__aliases__, _meta, parts} ->
        Enum.all?(parts, &is_atom/1) and forbidden_parts?(parts)

      _node ->
        false
    end)
  end

  defp forbidden_parts?(parts) do
    Enum.any?(@forbidden_modules, fn forbidden ->
      List.starts_with?(parts, forbidden) or List.last(forbidden) in parts
    end)
  end

  # `alias A.B.C`、`alias A.B.C, as: D`、`alias A.B.{C, E}` 都还原成短名 → 完整 parts。
  defp alias_env(ast) do
    {_ast, env} =
      Macro.prewalk(ast, %{}, fn
        {:alias, _meta, args} = node, env when is_list(args) -> {node, merge_alias(env, args)}
        node, env -> {node, env}
      end)

    env
  end

  defp merge_alias(env, [{{:., _dot_meta, [{:__aliases__, _base_meta, base}, :{}]}, _meta, group}])
       when is_list(base) and is_list(group) do
    Enum.reduce(group, env, fn
      {:__aliases__, _meta, parts}, acc when is_list(parts) ->
        Map.put(acc, List.last(parts), base ++ parts)

      _other, acc ->
        acc
    end)
  end

  defp merge_alias(env, [{:__aliases__, _meta, parts} | rest]) when is_list(parts) do
    if Enum.all?(parts, &is_atom/1),
      do: Map.put(env, alias_short_name(parts, rest), parts),
      else: env
  end

  defp merge_alias(env, _args), do: env

  defp alias_short_name(parts, [opts]) when is_list(opts) do
    case Keyword.get(opts, :as) do
      {:__aliases__, _meta, as_parts} when is_list(as_parts) -> List.last(as_parts)
      _other -> List.last(parts)
    end
  end

  defp alias_short_name(parts, _rest), do: List.last(parts)

  defp resolve_alias([head | tail], env), do: Map.get(env, head, [head]) ++ tail
  defp resolve_alias([], _env), do: []

  defp collect_nodes(ast, matcher) do
    {_ast, hits} =
      Macro.prewalk(ast, [], fn node, acc ->
        {node, if(matcher.(node), do: [Macro.to_string(node) | acc], else: acc)}
      end)

    Enum.reverse(hits)
  end
end
