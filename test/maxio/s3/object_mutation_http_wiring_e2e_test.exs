defmodule Maxio.S3.ObjectMutationHTTPWiringE2ETest do
  @moduledoc """
  Task 3 / G4a-2H —— 真实 HTTP 边界接线矩阵。

  **最终矩阵共 13 个 test：1 个静态 scope oracle + 10 个 Put 动态格 + 2 个 Copy 动态格。**
  本微批（R0）只落地其中**唯一的静态 oracle**；R1–R4 的 live Bandit 动态格在后续微批
  逐批追加，本文件此刻**没有**任何运行期 HTTP harness 或动态矩阵。

  静态 oracle 冻结 G4a-2H Green 必须达成的**边界拓扑**（见
  `task-3-g4a2-object-boundary-wiring-amendment.md` §2.1 与
  `task-3-g4a2h-http-execution-microbatches.md`）：

    * 新增 G4 专用私有边界 `raise_object_mutation_write_error/3`，**独占**整个文件里
      唯一一次 `Maxio.S3.ObjectMutationError.to_error/2` 委派；
    * 该专用边界恰好有 **2** 个消费者：`do_put/1` 的最终 ObjectMutation 通用兜底、
      `raise_copy_object_write_error/3` 的最终目标提交兜底；
    * 遗留共享 helper `raise_storage_write_error/3` 的最终 callsite 收敛到 **3** 个
      （当前基线是 5）：self-copy staging、delete marker、current delete 的 :sidecar 分支。
      H Green **只**改道 Put 最终与 Copy 最终两处，绝不动其余非 G4 路径。

  C1 已冻结的 current-delete 事务安全代码（`Failpoint.hit`、`Log.error` + `inspect`、
  目录默认 `InternalError`、成功后的 `Storage.delete`、以及那一次遗留共享 helper 调用）
  是**合法的非 G4 代码**，本 oracle 必须对它零误报——G4 禁令只作用于专用边界自身，
  绝不做全文件禁词。
  """

  use Maxio.DataCase, async: false

  @production_path "lib/maxio/s3/handlers/object.ex"

  # 共享纯适配器（G4a-1 冻结）。
  @adapter_parts [:Maxio, :S3, :ObjectMutationError]
  @adapter_fun :to_error
  @adapter_arity 2

  # 未来的 G4 专用私有边界。
  @g4_helper :raise_object_mutation_write_error
  @g4_helper_arity 3

  # 遗留共享 helper（服务 self-copy staging / delete marker / current delete 等非 G4 路径）。
  @legacy_helper :raise_storage_write_error
  @legacy_helper_arity 3

  # G4 Green 之后，专用边界的**唯一**两个消费者。
  @expected_g4_consumers [{:do_put, 1}, {:raise_copy_object_write_error, 3}]

  # G4 Green 之后，遗留共享 helper 仅剩的三个非 G4 消费者。
  @expected_legacy_consumers [
    {:commit_current_delete, 3},
    {:commit_delete_marker, 4},
    {:prepare_copy_source, 7}
  ]

  # 当前（G4a-2H 之前）的遗留基线：上述 3 个 + Put 最终 + Copy 最终。
  @legacy_baseline_count 5

  @reserved_envelope_atoms [
    :published_proof_failed,
    :published_proof_superseded,
    :published_proof_contract_violation,
    :object_mutation_journal
  ]

  @forbidden_classification_modules [
    [:Maxio, :ObjectMutation, :Commit],
    [:Maxio, :ObjectMutation, :Recovery],
    [:Maxio, :ObjectMutation, :Journal],
    [:Maxio, :ObjectMutation, :StorageDisposition],
    [:Maxio, :Storage],
    [:Maxio, :Storage, :PublishedProof]
  ]

  test "g4a-2h r0: the dedicated G4 boundary owns the only adapter delegation and the final call-ownership split" do
    # =================================================================
    # 非空转对照（先跑：生产 RED 时这些已被证明通过）
    # =================================================================

    # --- 四种 alias 写法都解析到同一适配器目标，且计为恰好一次 ---
    for {label, source} <- alias_style_controls() do
      ast = analyzable_ast(source)

      assert adapter_call_count(ast, ast) === 1,
             "R0 control(#{label}): #{label} 写法必须解析为恰好一次适配器委派"

      assert foreign_to_error_calls(ast) === [],
             "R0 control(#{label}): 合法委派不得被记为 foreign 调用"

      assert adapter_call_count(ast, def_body!(ast, @g4_helper, @g4_helper_arity)) === 1,
             "R0 control(#{label}): 该次委派必须归属专用边界"
    end

    # --- 拒绝：适配器调用被放进遗留共享 helper ---
    in_shared = analyzable_ast(sample_adapter_in_shared_helper())

    assert adapter_call_count(in_shared, def_body!(in_shared, @g4_helper, @g4_helper_arity)) === 0,
           "R0 control: 专用边界没有委派时不得被记为已接线"

    assert adapter_call_count(
             in_shared,
             def_body!(in_shared, @legacy_helper, @legacy_helper_arity)
           ) ===
             1,
           "R0 control: 放进共享 helper 的适配器调用必须被识别"

    # --- 拒绝：专用边界内重复委派 ---
    twice = analyzable_ast(sample_duplicate_adapter())

    assert adapter_call_count(twice, def_body!(twice, @g4_helper, @g4_helper_arity)) === 2,
           "R0 control: 重复委派必须被计数识别，绝不能被「至少一次」的探测器放过"

    # --- 拒绝：foreign 同名函数与错误 arity 都不满足目标 ---
    foreign = analyzable_ast(sample_foreign_and_wrong_arity())

    assert adapter_call_count(foreign, foreign) === 0,
           "R0 control: Other.to_error/2 与错误 arity 都不得被当成目标适配器委派"

    refute foreign_to_error_calls(foreign) === [],
           "R0 control: foreign / 错误 arity 的 to_error 调用必须被识别"

    # --- 零误报：只出现在注释 / @doc / @moduledoc 里的名字一律计零 ---
    docs = analyzable_ast(sample_docs_only())

    assert adapter_call_count(docs, docs) === 0
    assert foreign_to_error_calls(docs) === []
    assert local_call_owners(docs, @g4_helper, @g4_helper_arity) === []
    assert local_call_owners(docs, @legacy_helper, @legacy_helper_arity) === []

    # --- 定义头本身绝不计为调用 ---
    heads_only = analyzable_ast(sample_definition_heads_only())

    assert local_call_owners(heads_only, @g4_helper, @g4_helper_arity) === [],
           "R0 control: `defp #{@g4_helper}/#{@g4_helper_arity}` 的定义头不得被计为调用"

    assert local_call_owners(heads_only, @legacy_helper, @legacy_helper_arity) === [],
           "R0 control: 遗留 helper 的定义头（含 when 子句头）不得被计为调用"

    # --- 拒绝：来自非 G4 消费者的第三次专用边界调用 ---
    third = analyzable_ast(sample_third_g4_consumer())

    assert local_call_owners(third, @g4_helper, @g4_helper_arity) |> Enum.sort() ===
             Enum.sort([
               {:do_put, 1},
               {:raise_copy_object_write_error, 3},
               {:commit_delete_marker, 4}
             ]),
           "R0 control: 第三个非 G4 消费者必须被 owner multiset 识别，而不是只看总数"

    refute local_call_owners(third, @g4_helper, @g4_helper_arity) |> Enum.sort() ===
             Enum.sort(@expected_g4_consumers),
           "R0 control: 多出的消费者绝不能通过 owner multiset 断言"

    # --- I1 变异对照：同一合法样本，defp 通过可见性检查，仅改成 def 必须被拒 ---
    private_helper = analyzable_ast(sample_visibility(:defp))

    assert def_kinds(private_helper, @g4_helper, @g4_helper_arity) === [:defp],
           "R0 control: 合法样本里的专用边界必须被识别为 defp"

    assert adapter_call_count(
             private_helper,
             def_body!(private_helper, @g4_helper, @g4_helper_arity)
           ) === 1,
           "R0 control: 可见性变异对照的基线样本必须在其余方面完全合法（否则是空转）"

    public_helper = analyzable_ast(sample_visibility(:def))

    assert def_kinds(public_helper, @g4_helper, @g4_helper_arity) === [:def],
           "R0 control: 仅把专用边界改成 public def 必须被 definition kind 识别"

    refute def_kinds(public_helper, @g4_helper, @g4_helper_arity) === [:defp],
           "R0 control: public def 绝不能通过 defp 可见性断言"

    # 变异体除 kind 外与基线逐字同构：委派次数仍为 1，证明拒绝**只**来自可见性。
    assert adapter_call_count(
             public_helper,
             def_body!(public_helper, @g4_helper, @g4_helper_arity)
           ) === 1,
           "R0 control: 可见性变异必须只改 kind，其余保持合法"

    # --- I2 变异对照：renamed forbidden alias 必须被解析后拒绝 ---
    renamed_forbidden = analyzable_ast(sample_renamed_forbidden_alias())
    renamed_body = def_body!(renamed_forbidden, @g4_helper, @g4_helper_arity)

    refute forbidden_module_refs(renamed_forbidden, renamed_body) === [],
           "R0 control: `alias Maxio.ObjectMutation.Commit, as: ObjectMutationCommit` 之后，" <>
             "专用边界里的 ObjectMutationCommit.* 必须被解析并拒绝"

    # 同一样本里合法的 adapter alias 不得被误伤。
    assert adapter_call_count(renamed_forbidden, renamed_body) === 1,
           "R0 control: renamed forbidden alias 样本中的合法 adapter 委派仍必须被正确解析"

    assert foreign_to_error_calls(renamed_forbidden) === [],
           "R0 control: renamed forbidden alias 不得把合法 adapter 委派误记为 foreign"

    # 四种 alias 写法的 forbidden 依赖都必须被解析到同一 canonical 目标。
    for {label, source} <- forbidden_alias_style_controls() do
      forbidden_ast = analyzable_ast(source)

      refute forbidden_module_refs(
               forbidden_ast,
               def_body!(forbidden_ast, @g4_helper, @g4_helper_arity)
             ) === [],
             "R0 control(#{label}): #{label} 写法的禁用依赖必须被识别"
    end

    # --- C1 形状的 current-delete 是合法非 G4 代码：零误报 ---
    c1 = analyzable_ast(sample_c1_shaped_current_delete())
    c1_body = def_body!(c1, :commit_current_delete, 3)

    assert adapter_call_count(c1, c1_body) === 0,
           "R0 control: C1 形状的 current-delete 不得被记为适配器委派"

    assert local_call_owners(c1, @g4_helper, @g4_helper_arity) === [],
           "R0 control: C1 形状的 current-delete 不得被记为专用边界消费者"

    assert length(local_call_owners(c1, @legacy_helper, @legacy_helper_arity)) === 1,
           "R0 control: C1 形状的 current-delete 必须恰好保留一次遗留共享 helper 调用"

    # C1 的 Failpoint.hit / Log.error+inspect / 默认 InternalError / 成功后的 Storage.delete
    # 都**不是** G4 违规——G4 禁令只作用于专用边界自身。
    assert inspect_refs(c1_body) !== [],
           "R0 control: 样本必须真的含 inspect（否则该零误报对照是空转）"

    assert forbidden_module_refs(c1, c1_body) !== [],
           "R0 control: 样本必须真的含 Storage 引用（否则该零误报对照是空转）"

    # --- 但同一样本插入适配器 / 专用边界调用后必须被拒 ---
    c1_adapter = analyzable_ast(sample_c1_shaped_current_delete(:adapter))

    refute adapter_call_count(c1_adapter, def_body!(c1_adapter, :commit_current_delete, 3)) === 0,
           "R0 control: current-delete 内插入的适配器调用必须被识别"

    c1_g4 = analyzable_ast(sample_c1_shaped_current_delete(:g4_helper))

    refute local_call_owners(c1_g4, @g4_helper, @g4_helper_arity) === [],
           "R0 control: current-delete 内插入的专用边界调用必须被识别"

    # =================================================================
    # 生产断言（当前应且只应因「专用边界 / 改道 / 最终调用归属」尚未实现而失败）
    # =================================================================

    assert File.exists?(@production_path),
           "R0: production source #{@production_path} 不存在"

    ast = @production_path |> File.read!() |> analyzable_ast()

    # 先锁「当前已满足、绝不构成 RED 噪声」的负面不变量。
    assert foreign_to_error_calls(ast) === [],
           "R0: 除共享适配器外不允许任何其它 to_error 远程调用"

    legacy_body = def_body!(ast, @legacy_helper, @legacy_helper_arity)

    assert adapter_call_count(ast, legacy_body) === 0,
           "R0: 遗留共享 helper 绝不可直接调用适配器"

    assert local_calls_in(legacy_body, @g4_helper, @g4_helper_arity) === 0,
           "R0: 遗留共享 helper 绝不可调用 G4 专用边界"

    for {name, arity} <- @expected_legacy_consumers do
      body = def_body!(ast, name, arity)

      assert adapter_call_count(ast, body) === 0,
             "R0: 非 G4 路径 #{name}/#{arity} 绝不可直接调用适配器"

      assert local_calls_in(body, @g4_helper, @g4_helper_arity) === 0,
             "R0: 非 G4 路径 #{name}/#{arity} 绝不可调用 G4 专用边界"
    end

    assert local_calls_in(
             def_body!(ast, :commit_current_delete, 3),
             @legacy_helper,
             @legacy_helper_arity
           ) ===
             1,
           "R0: C1 冻结的 current-delete 必须恰好保留一次遗留共享 helper 调用（:sidecar 分支）"

    # 当前遗留基线必须确实是 5——否则说明改道范围与本 oracle 的前提不符。
    assert length(local_call_owners(ast, @legacy_helper, @legacy_helper_arity)) in [
             @legacy_baseline_count,
             length(@expected_legacy_consumers)
           ],
           "R0: 遗留共享 helper 的 callsite 只能是改道前基线 #{@legacy_baseline_count} 或改道后 " <>
             "#{length(@expected_legacy_consumers)}，实际 " <>
             "#{inspect(local_call_owners(ast, @legacy_helper, @legacy_helper_arity))}"

    # --- 唯一应当失败的能力缺口：专用边界尚不存在 / 尚未改道 ---

    assert defs(ast, @g4_helper, @g4_helper_arity) !== [],
           "R0: 必须新增 G4 专用私有边界 #{@g4_helper}/#{@g4_helper_arity}——" <>
             "禁止把适配器接进服务 self-copy staging / delete marker / current delete 的共享 helper"

    # I1：专用边界必须是**私有** helper，可见性判定只认 AST definition kind。
    assert def_kinds(ast, @g4_helper, @g4_helper_arity) === [:defp],
           "R0: #{@g4_helper}/#{@g4_helper_arity} 必须恰为 defp——G4 专用边界是私有实现细节，" <>
             "绝不可暴露成公共 API，实际 kind #{inspect(def_kinds(ast, @g4_helper, @g4_helper_arity))}"

    g4_body = def_body!(ast, @g4_helper, @g4_helper_arity)

    assert adapter_call_count(ast, g4_body) === 1,
           "R0: #{@g4_helper}/#{@g4_helper_arity} 必须恰好一次调用 " <>
             "Maxio.S3.ObjectMutationError.to_error/2"

    assert adapter_call_count(ast, ast) === 1,
           "R0: 全文件只允许一次共享适配器委派，且必须位于专用边界内"

    assert Enum.sort(local_call_owners(ast, @g4_helper, @g4_helper_arity)) ===
             Enum.sort(@expected_g4_consumers),
           "R0: 专用边界的消费者必须恰好是 Put 最终兜底与 Copy 最终兜底"

    assert Enum.sort(local_call_owners(ast, @legacy_helper, @legacy_helper_arity)) ===
             Enum.sort(@expected_legacy_consumers),
           "R0: 改道后遗留共享 helper 只能剩 self-copy staging / delete marker / current delete"

    # --- 专用边界自身的 G4 禁令（**只**作用于它自己）---

    assert inspect_refs(g4_body) === [],
           "R0: G4 专用边界内不得出现可执行 inspect——raw reason 绝不进公共 message"

    assert reserved_envelope_refs(g4_body) === [],
           "R0: G4 专用边界不得直接匹配稳定信封 tag，类别决策只能来自共享适配器"

    assert forbidden_module_refs(ast, g4_body) === [],
           "R0: G4 专用边界不得直连 Commit/Recovery/Storage/PublishedProof/StorageDisposition/Journal" <>
             "（含 renamed alias，如 handler 既有的 ObjectMutationCommit）"
  end

  # =====================================================================
  # 对照样本
  # =====================================================================

  defp alias_style_controls do
    [
      {"fully qualified",
       g4_sample(
         """
             case Maxio.S3.ObjectMutationError.to_error(reason, resource) do
               {:ok, error} -> raise error
               :unrelated -> raise Error.new(:internal_error, resource: resource)
             end
         """,
         ""
       )},
      {"plain alias",
       g4_sample(
         """
             case ObjectMutationError.to_error(reason, resource) do
               {:ok, error} -> raise error
               :unrelated -> raise Error.new(:internal_error, resource: resource)
             end
         """,
         "alias Maxio.S3.ObjectMutationError"
       )},
      {"renamed alias",
       g4_sample(
         """
             case Adapter.to_error(reason, resource) do
               {:ok, error} -> raise error
               :unrelated -> raise Error.new(:internal_error, resource: resource)
             end
         """,
         "alias Maxio.S3.ObjectMutationError, as: Adapter"
       )},
      {"grouped alias",
       g4_sample(
         """
             case ObjectMutationError.to_error(reason, resource) do
               {:ok, error} -> raise error
               :unrelated -> raise Error.new(:internal_error, resource: resource)
             end
         """,
         "alias Maxio.S3.{Error, ObjectMutationError}"
       )}
    ]
  end

  # 专用边界样本骨架：G4 helper + 两个合法消费者。
  defp g4_sample(helper_body, alias_line) do
    """
    defmodule Sample do
      #{alias_line}

      def do_put(conn) do
        case commit(conn) do
          {:ok, result} -> result
          {:error, reason} -> raise_object_mutation_write_error(reason, "b", "k")
        end
      end

      defp raise_copy_object_write_error(reason, bucket, key),
        do: raise_object_mutation_write_error(reason, bucket, key)

      defp raise_object_mutation_write_error(reason, bucket, key) do
        resource = "/\#{bucket}/\#{key}"
    #{helper_body}  end

      defp raise_storage_write_error(reason, bucket, key) do
        raise Error.new(:internal_error, message: inspect(reason), resource: "/\#{bucket}/\#{key}")
      end
    end
    """
  end

  # I1 变异对：两个样本**只**在专用边界的定义 kind 上不同，其余逐字同构。
  defp sample_visibility(kind) when kind in [:def, :defp] do
    """
    defmodule Sample do
      alias Maxio.S3.ObjectMutationError

      def do_put(conn) do
        case commit(conn) do
          {:ok, result} -> result
          {:error, reason} -> raise_object_mutation_write_error(reason, "b", "k")
        end
      end

      defp raise_copy_object_write_error(reason, bucket, key),
        do: raise_object_mutation_write_error(reason, bucket, key)

      #{kind} raise_object_mutation_write_error(reason, bucket, key) do
        resource = "/\#{bucket}/\#{key}"

        case ObjectMutationError.to_error(reason, resource) do
          {:ok, error} -> raise error
          :unrelated -> raise Error.new(:internal_error, resource: resource)
        end
      end
    end
    """
  end

  # I2 变异：handler 既有的 renamed alias 形状——字面上既不含 `Commit`、也不以
  # `Maxio.ObjectMutation` 开头，只有经 alias env 归一化才抓得到。
  defp sample_renamed_forbidden_alias do
    """
    defmodule Sample do
      alias Maxio.ObjectMutation.Commit, as: ObjectMutationCommit
      alias Maxio.S3.ObjectMutationError

      defp raise_object_mutation_write_error(reason, bucket, key) do
        resource = "/\#{bucket}/\#{key}"

        case ObjectMutationError.to_error(reason, resource) do
          {:ok, error} ->
            raise error

          :unrelated ->
            ObjectMutationCommit.run(reason, resource)
        end
      end
    end
    """
  end

  # 四种 alias 写法下的禁用依赖都必须归一化到同一 canonical 目标。
  defp forbidden_alias_style_controls do
    [
      {"fully qualified",
       forbidden_sample("", "Maxio.ObjectMutation.Commit.run(reason, resource)")},
      {"plain alias",
       forbidden_sample("alias Maxio.ObjectMutation.Commit", "Commit.run(reason, resource)")},
      {"renamed alias",
       forbidden_sample(
         "alias Maxio.ObjectMutation.Recovery, as: Rec",
         "Rec.drain(reason, resource)"
       )},
      {"grouped alias",
       forbidden_sample(
         "alias Maxio.Storage.{MutationContext, PublishedProof}",
         "PublishedProof.classify(reason, resource)"
       )}
    ]
  end

  defp forbidden_sample(alias_line, call) do
    """
    defmodule Sample do
      #{alias_line}

      defp raise_object_mutation_write_error(reason, bucket, key) do
        resource = "/\#{bucket}/\#{key}"
        _ = #{call}
        raise Error.new(:internal_error, resource: resource)
      end
    end
    """
  end

  defp sample_adapter_in_shared_helper do
    """
    defmodule Sample do
      alias Maxio.S3.ObjectMutationError

      defp raise_object_mutation_write_error(reason, bucket, key) do
        raise Error.new(:internal_error, resource: "/\#{bucket}/\#{key}")
      end

      defp raise_storage_write_error(reason, bucket, key) do
        case ObjectMutationError.to_error(reason, "/\#{bucket}/\#{key}") do
          {:ok, error} -> raise error
          :unrelated -> raise Error.new(:internal_error, resource: "/\#{bucket}/\#{key}")
        end
      end
    end
    """
  end

  defp sample_duplicate_adapter do
    """
    defmodule Sample do
      alias Maxio.S3.ObjectMutationError

      defp raise_object_mutation_write_error(reason, bucket, key) do
        resource = "/\#{bucket}/\#{key}"

        case ObjectMutationError.to_error(reason, resource) do
          {:ok, error} ->
            raise error

          :unrelated ->
            case Maxio.S3.ObjectMutationError.to_error(reason, resource) do
              {:ok, error} -> raise error
              :unrelated -> raise Error.new(:internal_error, resource: resource)
            end
        end
      end
    end
    """
  end

  defp sample_foreign_and_wrong_arity do
    """
    defmodule Sample do
      alias Maxio.S3.ObjectMutationError
      alias Maxio.S3.OtherPolicy, as: Other

      defp raise_object_mutation_write_error(reason, bucket, key) do
        resource = "/\#{bucket}/\#{key}"
        _ = Other.to_error(reason, resource)
        ObjectMutationError.to_error(reason, bucket, key)
      end
    end
    """
  end

  defp sample_docs_only do
    """
    defmodule Sample do
      @moduledoc "委派给 Maxio.S3.ObjectMutationError.to_error/2；raise_object_mutation_write_error/3 是专用边界。"

      @doc "raise_storage_write_error/3 仍服务 self-copy staging；ObjectMutationError.to_error(reason, resource) 只是文档。"
      # raise_object_mutation_write_error(reason, bucket, key) 只是注释。
      def do_put(conn), do: conn
    end
    """
  end

  defp sample_definition_heads_only do
    """
    defmodule Sample do
      defp raise_object_mutation_write_error(reason, bucket, key)

      defp raise_object_mutation_write_error(reason, bucket, key),
        do: raise(Error.new(:internal_error, resource: "/\#{bucket}/\#{key}"))

      defp raise_storage_write_error(reason, bucket, key)
           when reason in [:write_quorum, :rename_busy],
           do: raise(Error.new(:slow_down_write, resource: "/\#{bucket}/\#{key}"))

      defp raise_storage_write_error(_reason, bucket, key),
        do: raise(Error.new(:internal_error, resource: "/\#{bucket}/\#{key}"))
    end
    """
  end

  defp sample_third_g4_consumer do
    """
    defmodule Sample do
      def do_put(conn) do
        case commit(conn) do
          {:error, reason} -> raise_object_mutation_write_error(reason, "b", "k")
          other -> other
        end
      end

      defp raise_copy_object_write_error(reason, bucket, key),
        do: raise_object_mutation_write_error(reason, bucket, key)

      defp commit_delete_marker(bucket, key, versioning, notification_fun) do
        case Storage.put_delete_marker(bucket, key, versioning, notification_fun, []) do
          {:ok, vid} -> vid
          {:error, reason} -> raise_object_mutation_write_error(reason, bucket, key)
        end
      end

      defp raise_object_mutation_write_error(reason, bucket, key) do
        raise Error.new(:internal_error, resource: "/\#{bucket}/\#{key}")
      end
    end
    """
  end

  # C1 冻结形状：Failpoint.hit + Log.error/inspect + 目录默认 InternalError +
  # 成功后的 Storage.delete + 恰好一次遗留共享 helper 调用（:sidecar 分支）。
  defp sample_c1_shaped_current_delete(inject \\ :none) do
    injected =
      case inject do
        :adapter ->
          "        _ = Maxio.S3.ObjectMutationError.to_error(reason, \"/#\{bucket}/#\{key}\")\n"

        :g4_helper ->
          "        _ = raise_object_mutation_write_error(reason, bucket, key)\n"

        :none ->
          ""
      end

    """
    defmodule Sample do
      defp commit_current_delete(bucket, key, notification_fun) do
        case Maxio.ObjectMeta.authoritative_source(:write) do
          :sidecar ->
            case Storage.delete_version(bucket, key, "null", []) do
              :ok -> :ok
              {:error, reason} -> raise_storage_write_error(reason, bucket, key)
            end

          _pg ->
            {target, notification_delivery} =
              case Objects.delete_metadata(
                     bucket,
                     key,
                     notification_transaction_opts(fn target ->
                       Failpoint.hit(:current_delete_metadata_before_notification_enqueue)
                       current_delete_notification(notification_fun, target)
                     end)
                   ) do
                {:error, reason} ->
    #{injected}              Log.error("current object metadata delete transaction failed",
                    action: :delete_object,
                    bucket: bucket,
                    key: key,
                    reason: inspect(reason)
                  )

                  raise Error.new(:internal_error, resource: "/\#{bucket}/\#{key}")

                {%{} = target, enqueued} ->
                  {target, {:enqueued, enqueued}}

                %{} = target ->
                  {target, :none}

                other ->
                  Log.error("invalid current object metadata delete result",
                    action: :delete_object,
                    bucket: bucket,
                    key: key,
                    result: inspect(other)
                  )

                  raise Error.new(:internal_error, resource: "/\#{bucket}/\#{key}")
              end

            _ = Storage.delete(bucket, key, "null", [])
            {target, notification_delivery}
        end
      end
    end
    """
  end

  # =====================================================================
  # AST 探测器（只认可执行调用；注释/文档/alias/定义头一律计零）
  # =====================================================================

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

  # @moduledoc/@doc/@typedoc 整体剥除：文档里出现的目标名字永远计零。
  defp strip_docs(ast) do
    Macro.prewalk(ast, fn
      {:@, _meta, [{doc, _doc_meta, _args}]} when doc in [:moduledoc, :doc, :typedoc] ->
        :__doc_stripped__

      node ->
        node
    end)
  end

  # 所有 def/defp 子树，附带 `{name, arity}`、**定义 kind**（`:def | :defp`）与**仅函数体**
  # （定义头已剥除）。
  #
  # I1：kind 必须逐条保留。若把 `def` 与 `defp` 合并丢弃可见性，则
  # `def raise_object_mutation_write_error/3` 这种把 G4 专用边界暴露成公共 API 的写法
  # 会被误判合法。可见性判定**只能**来自 AST definition kind，绝不用源码字符串 grep 代替。
  defp all_defs(ast) do
    {_ast, defs} =
      Macro.prewalk(ast, [], fn
        {kind, _meta, [head | rest]} = node, acc when kind in [:def, :defp] ->
          case def_identity(head) do
            {name, arity} ->
              {node, [%{kind: kind, name: name, arity: arity, body: rest} | acc]}

            :error ->
              {node, acc}
          end

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(defs)
  end

  # 指定函数全部 clause 的定义 kind 集合（去重后排序）。
  defp def_kinds(ast, name, arity) do
    ast
    |> defs(name, arity)
    |> Enum.map(& &1.kind)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp def_identity({:when, _meta, [inner | _guards]}), do: def_identity(inner)

  defp def_identity({name, _meta, args}) when is_atom(name) and is_list(args),
    do: {name, length(args)}

  defp def_identity({name, _meta, nil}) when is_atom(name), do: {name, 0}
  defp def_identity(_other), do: :error

  defp defs(ast, name, arity) do
    ast
    |> all_defs()
    |> Enum.filter(&(&1.name === name and &1.arity === arity))
  end

  # 指定函数**全部 clause 的函数体**（缺席即失败）。
  defp def_body!(ast, name, arity) do
    bodies = defs(ast, name, arity)

    refute bodies === [], "R0: 找不到 #{name}/#{arity} 的定义"

    Enum.map(bodies, & &1.body)
  end

  # --- 适配器远程调用 ---

  defp adapter_call_count(root_ast, scope) do
    root_ast
    |> to_error_targets(scope)
    |> Enum.count(&(&1 === {@adapter_parts, @adapter_arity}))
  end

  defp foreign_to_error_calls(root_ast) do
    root_ast
    |> to_error_targets(root_ast)
    |> Enum.reject(&(&1 === {@adapter_parts, @adapter_arity}))
  end

  defp to_error_targets(root_ast, scope) do
    env = alias_env(root_ast)

    {_ast, targets} =
      Macro.prewalk(scope, [], fn
        {{:., _dot_meta, [{:__aliases__, _alias_meta, parts}, @adapter_fun]}, _meta, args} = node,
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

  # --- 本地私有 helper 的**可执行**调用及其 owner ---
  #
  # 定义头（含 `when` 子句头与无 body 的函数头）永远不计：只在**函数体**里找调用。
  defp local_call_owners(ast, name, arity) do
    ast
    |> all_defs()
    |> Enum.flat_map(fn %{name: owner, arity: owner_arity, body: body} ->
      List.duplicate({owner, owner_arity}, count_local_calls(body, name, arity))
    end)
  end

  # 任意 scope（含 `def_body!/3` 返回的 body 列表）内的可执行本地调用计数。
  defp local_calls_in(scope, name, arity), do: count_local_calls(scope, name, arity)

  defp count_local_calls(body, name, arity) do
    {_ast, hits} =
      Macro.prewalk(body, 0, fn
        {^name, _meta, args} = node, acc when is_list(args) ->
          if length(args) === arity, do: {node, acc + 1}, else: {node, acc}

        node, acc ->
          {node, acc}
      end)

    hits
  end

  # --- G4 专用边界自身的禁令探测（只在传入的 scope 内生效）---

  defp inspect_refs(scope) do
    collect_nodes(scope, fn
      {:inspect, _meta, args} when is_list(args) and length(args) in [1, 2] -> true
      {{:., _dot_meta, [_target, :inspect]}, _meta, args} when is_list(args) -> true
      _node -> false
    end)
  end

  defp reserved_envelope_refs(scope),
    do: collect_nodes(scope, &(&1 in @reserved_envelope_atoms))

  # I2：禁用依赖判定必须先经**整个模块的 alias env** 归一化，再比对 forbidden 列表。
  #
  # 只看字面 parts 会漏掉 renamed alias——handler 里本来就有
  # `alias Maxio.ObjectMutation.Commit, as: ObjectMutationCommit`，于是 G4 helper 里的
  # `ObjectMutationCommit.run(...)` 字面上既不含 `Commit` 也不以 `Maxio.ObjectMutation`
  # 开头，会被静默放行。归一化后 fully-qualified / plain alias / alias-as / grouped alias
  # 四种写法都解析到同一 canonical parts。
  defp forbidden_module_refs(root_ast, scope) do
    env = alias_env(root_ast)

    collect_nodes(scope, fn
      {:__aliases__, _meta, parts} ->
        Enum.all?(parts, &is_atom/1) and forbidden_parts?(resolve_alias(parts, env))

      _node ->
        false
    end)
  end

  # `resolve_alias/2` 归一化之后再判定：既接受完整前缀（含 renamed alias 展开的结果），
  # 也保留「未 alias 的裸短名」这一既有语义（例如样本里直接写 `Storage.delete`）。
  defp forbidden_parts?(parts) do
    Enum.any?(@forbidden_classification_modules, fn forbidden ->
      List.starts_with?(parts, forbidden) or List.last(forbidden) in parts
    end)
  end

  # --- alias 解析：完全限定 / 普通 alias / alias-as / 分组 alias ---

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

  defp collect_nodes(scope, matcher) do
    {_ast, hits} =
      Macro.prewalk(scope, [], fn node, acc ->
        {node, if(matcher.(node), do: [Macro.to_string(node) | acc], else: acc)}
      end)

    Enum.reverse(hits)
  end
end
