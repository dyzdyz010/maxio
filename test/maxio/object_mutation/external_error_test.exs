defmodule Maxio.ObjectMutation.ExternalErrorTest do
  # 纯投影模块：无 Repo、无 backend、无全局状态、无 IO，可以 async。
  use ExUnit.Case, async: true

  # --- Task 3 / G4-0：唯一的 stable-envelope → 外部安全投影 RED ---
  #
  # `Maxio.ObjectMutation.ExternalError` 是 G4 里**唯一**允许匹配 Commit/Recovery
  # 稳定外层错误信封的模块。它只暴露：
  #
  #     project(reason)
  #
  # 只返回：
  #
  #     {:ok, :retryable, safe_code}
  #     {:ok, :internal, safe_code}
  #     :unrelated
  #
  # 其中 `safe_code` 是 blueprint / amendment 里逐字冻结的 Elixir binary。
  #
  # canonical summary 是**内部能力**：只能绑定为 `_opaque`，绝不可被 inspect、遍历、
  # 编码、记录、持久化或回显。因此每个带 summary 的行都注入一个**新鲜的**、一旦被枚举
  # 或被 JSON 编码就抛异常的 opaque 探针。
  #
  # 本文件经 `apply/3` 调用尚未存在的模块：既避免 undefined-module 编译警告，也让
  # 「能力缺失」成为**独立**的失败签名，不会掩盖静态源边界断言。

  # 稳定外层信封的保留首元素（blueprint §3 G4-0 + amendment §2）。
  @proof_failed :published_proof_failed
  @proof_superseded :published_proof_superseded
  @contract_violation :published_proof_contract_violation
  @journal :object_mutation_journal

  # 逐字冻结的 fail-closed 固定 internal safe code。
  @proof_failed_invalid "published_proof_failed:invalid"
  @proof_superseded_invalid "published_proof_superseded:invalid"
  @contract_violation_invalid "published_proof_contract_violation:invalid"
  @journal_invalid "object_mutation_journal:invalid"

  # 固定 raw sentinel：任何投影结果里绝不允许出现它们。
  @raw_atom_sentinel :g4_0_external_error_raw_sentinel
  @raw_binary_sentinel "g4-0-external-error-raw-sentinel-3f9c17"

  @production_path "lib/maxio/object_mutation/external_error.ex"

  # --- 能力探针：缺失能力是独立且明确的失败签名 ---

  defp capability!() do
    assert Code.ensure_loaded?(Maxio.ObjectMutation.ExternalError),
           "T3-G4-0: Maxio.ObjectMutation.ExternalError 尚未实现（blueprint §3 G4-0）"

    assert function_exported?(Maxio.ObjectMutation.ExternalError, :project, 1),
           "T3-G4-0: Maxio.ObjectMutation.ExternalError.project/1 尚未实现"
  end

  defp project(reason) do
    capability!()
    apply(Maxio.ObjectMutation.ExternalError, :project, [reason])
  end

  # --- opaque 探针：被枚举/编码即失败；只允许绑定为 `_opaque` ---

  defp opaque_summary(tag) do
    Stream.resource(
      fn -> raise "opaque touched: #{tag}" end,
      fn acc -> {:halt, acc} end,
      fn _acc -> :ok end
    )
  end

  # =====================================================================
  # 4.1 九个精确投影行（严格 term identity）
  # =====================================================================

  test "g4-0 red: proof unavailable projects to the exact retryable safe code" do
    assert project({@proof_failed, :unavailable, opaque_summary("proof-unavailable")}) ===
             {:ok, :retryable, "published_proof_failed:unavailable"}
  end

  test "g4-0 red: proof mismatch projects to the exact internal safe code" do
    assert project({@proof_failed, :mismatch, opaque_summary("proof-mismatch")}) ===
             {:ok, :internal, "published_proof_failed:mismatch"}
  end

  test "g4-0 red: proof corrupt projects to the exact internal safe code" do
    assert project({@proof_failed, :corrupt, opaque_summary("proof-corrupt")}) ===
             {:ok, :internal, "published_proof_failed:corrupt"}
  end

  test "g4-0 red: proof placement_drift projects to the exact internal safe code" do
    assert project({@proof_failed, :placement_drift, opaque_summary("proof-placement-drift")}) ===
             {:ok, :internal, "published_proof_failed:placement_drift"}
  end

  test "g4-0 red: superseded projects to the exact retryable safe code without a suffix" do
    assert project({@proof_superseded, opaque_summary("superseded")}) ===
             {:ok, :retryable, "published_proof_superseded"}
  end

  test "g4-0 red: proof contract violation projects to the exact internal safe code" do
    assert project({@contract_violation, :proof}) ===
             {:ok, :internal, "published_proof_contract_violation:proof"}
  end

  test "g4-0 red: finalize contract violation projects to the exact internal safe code" do
    assert project({@contract_violation, :finalize}) ===
             {:ok, :internal, "published_proof_contract_violation:finalize"}
  end

  test "g4-0 red: journal publish_transition projects to the exact internal safe code" do
    assert project({@journal, :internal, :publish_transition}) ===
             {:ok, :internal, "object_mutation_journal:publish_transition"}
  end

  test "g4-0 red: journal finalize_outcome projects to the exact internal safe code" do
    assert project({@journal, :internal, :finalize_outcome}) ===
             {:ok, :internal, "object_mutation_journal:finalize_outcome"}
  end

  # 同一 class 下 summary 的具体形态不影响投影：投影只看保留 tag 与 class/mode/stage。
  test "g4-0 red: the summary shape never changes an exact proof projection" do
    for {class, category, safe_code} <- [
          {:unavailable, :retryable, "published_proof_failed:unavailable"},
          {:mismatch, :internal, "published_proof_failed:mismatch"},
          {:corrupt, :internal, "published_proof_failed:corrupt"},
          {:placement_drift, :internal, "published_proof_failed:placement_drift"}
        ],
        summary <- [
          opaque_summary("shape-#{class}"),
          @raw_atom_sentinel,
          @raw_binary_sentinel,
          %{"sentinel" => @raw_binary_sentinel},
          nil
        ] do
      assert project({@proof_failed, class, summary}) === {:ok, category, safe_code}
    end
  end

  test "g4-0 red: the summary shape never changes the exact superseded projection" do
    for summary <- [
          opaque_summary("shape-superseded"),
          @raw_atom_sentinel,
          @raw_binary_sentinel,
          %{"sentinel" => @raw_binary_sentinel},
          nil
        ] do
      assert project({@proof_superseded, summary}) ===
               {:ok, :retryable, "published_proof_superseded"}
    end
  end

  test "g4-0 red: project/1 is the only public function of the projection module" do
    capability!()

    functions =
      Maxio.ObjectMutation.ExternalError
      |> apply(:__info__, [:functions])
      |> Enum.sort()

    assert functions === [project: 1],
           "T3-G4-0: ExternalError 只允许暴露 project/1，实际为 #{inspect(functions)}"
  end

  # =====================================================================
  # 4.2 保留 tag 的畸形元组一律 fail closed（绝不 :unrelated、绝不回显 raw）
  # =====================================================================

  @proof_failed_malformed [
    {"arity 1", {:published_proof_failed}},
    {"arity 2 without summary", {:published_proof_failed, :unavailable}},
    {"arity 4 with extra raw payload",
     {:published_proof_failed, :unavailable, :g4_0_external_error_raw_sentinel,
      "g4-0-external-error-raw-sentinel-3f9c17"}},
    {"forged fenced aggregate class",
     {:published_proof_failed, :fenced, :g4_0_external_error_raw_sentinel}},
    {"unknown class", {:published_proof_failed, :bogus_class, :g4_0_external_error_raw_sentinel}},
    {"non-atom class",
     {:published_proof_failed, "unavailable", "g4-0-external-error-raw-sentinel-3f9c17"}},
    {"nil class", {:published_proof_failed, nil, :g4_0_external_error_raw_sentinel}},
    {"raw sentinel class",
     {:published_proof_failed, :g4_0_external_error_raw_sentinel,
      "g4-0-external-error-raw-sentinel-3f9c17"}}
  ]

  for {label, input} <- @proof_failed_malformed do
    test "g4-0 red: malformed published_proof_failed (#{label}) fails closed to the fixed invalid code" do
      assert project(unquote(Macro.escape(input))) ===
               {:ok, :internal, @proof_failed_invalid}
    end
  end

  @proof_superseded_malformed [
    {"arity 1", {:published_proof_superseded}},
    {"arity 3 with extra raw payload",
     {:published_proof_superseded, :g4_0_external_error_raw_sentinel,
      "g4-0-external-error-raw-sentinel-3f9c17"}},
    {"arity 4 with mode-like padding",
     {:published_proof_superseded, :proof, :g4_0_external_error_raw_sentinel,
      "g4-0-external-error-raw-sentinel-3f9c17"}}
  ]

  for {label, input} <- @proof_superseded_malformed do
    test "g4-0 red: malformed published_proof_superseded (#{label}) fails closed to the fixed invalid code" do
      assert project(unquote(Macro.escape(input))) ===
               {:ok, :internal, @proof_superseded_invalid}
    end
  end

  @contract_violation_malformed [
    {"arity 1", {:published_proof_contract_violation}},
    {"unknown mode", {:published_proof_contract_violation, :cleanup}},
    {"non-atom mode", {:published_proof_contract_violation, "proof"}},
    {"nil mode", {:published_proof_contract_violation, nil}},
    {"raw sentinel mode",
     {:published_proof_contract_violation, :g4_0_external_error_raw_sentinel}},
    {"arity 3 with extra raw payload",
     {:published_proof_contract_violation, :proof, "g4-0-external-error-raw-sentinel-3f9c17"}}
  ]

  for {label, input} <- @contract_violation_malformed do
    test "g4-0 red: malformed published_proof_contract_violation (#{label}) fails closed to the fixed invalid code" do
      assert project(unquote(Macro.escape(input))) ===
               {:ok, :internal, @contract_violation_invalid}
    end
  end

  @journal_malformed [
    {"arity 1", {:object_mutation_journal}},
    {"arity 2", {:object_mutation_journal, :internal}},
    {"unknown stage", {:object_mutation_journal, :internal, :bogus_stage}},
    {"wrong middle element", {:object_mutation_journal, :external, :publish_transition}},
    {"non-atom stage", {:object_mutation_journal, :internal, "publish_transition"}},
    {"raw sentinel stage",
     {:object_mutation_journal, :internal, :g4_0_external_error_raw_sentinel}},
    {"arity 4 with extra raw payload",
     {:object_mutation_journal, :internal, :finalize_outcome,
      "g4-0-external-error-raw-sentinel-3f9c17"}},
    {"proof-class shaped stage", {:object_mutation_journal, :internal, :unavailable}}
  ]

  for {label, input} <- @journal_malformed do
    test "g4-0 red: malformed object_mutation_journal (#{label}) fails closed to the fixed invalid code" do
      assert project(unquote(Macro.escape(input))) === {:ok, :internal, @journal_invalid}
    end
  end

  # 畸形保留元组即使携带「碰一下就炸」的 opaque 也必须 fail closed，且不得触碰它。
  test "g4-0 red: malformed reserved tuples carrying an opaque probe still fail closed untouched" do
    assert project({@proof_failed, :fenced, opaque_summary("malformed-proof-failed")}) ===
             {:ok, :internal, @proof_failed_invalid}

    assert project({@proof_superseded, :proof, opaque_summary("malformed-superseded")}) ===
             {:ok, :internal, @proof_superseded_invalid}

    assert project({@contract_violation, :cleanup, opaque_summary("malformed-violation")}) ===
             {:ok, :internal, @contract_violation_invalid}

    assert project({@journal, :internal, :bogus_stage, opaque_summary("malformed-journal")}) ===
             {:ok, :internal, @journal_invalid}
  end

  # amendment §4.3：sentinel 非回显只在**畸形** journal 信封上测，
  # 绝不改动精确的、无载荷的 finalize_outcome 信封。
  test "g4-0 red: a malformed journal envelope carrying a sentinel never echoes it" do
    for input <- [
          {@journal, :internal, @raw_atom_sentinel},
          {@journal, @raw_atom_sentinel, :finalize_outcome},
          {@journal, :internal, :finalize_outcome, @raw_binary_sentinel}
        ] do
      assert {:ok, :internal, safe_code} = project(input)
      assert safe_code === @journal_invalid
      refute safe_code =~ "sentinel"
    end
  end

  # =====================================================================
  # 4.3 unrelated 正向对照
  # =====================================================================

  @unrelated_terms [
    {"epoch fence tuple", {:fenced, "g4-0-epoch-token-7b21e4"}},
    {"epoch fence tuple with map token", {:fenced, %{"token" => "g4-0-epoch-token-7b21e4"}}},
    {"legacy epoch_fenced storage error",
     {:epoch_fenced, %{"token" => "g4-0-epoch-token-7b21e4"}}},
    {"legacy posix storage error", :enoent},
    {"legacy storage tuple", {:storage_unavailable, :timeout}},
    {"legacy not_found", {:not_found, "bucket/key"}},
    {"ordinary ok tuple", {:ok, :done}},
    {"ordinary map", %{reason: :whatever}},
    {"ordinary scalar atom", :some_other_error},
    {"binary that looks like a safe code", "published_proof_failed:unavailable"},
    {"integer", 42},
    {"list whose head is a reserved tag", [:published_proof_failed, :unavailable]},
    {"bare reserved atom published_proof_failed", :published_proof_failed},
    {"bare reserved atom published_proof_superseded", :published_proof_superseded},
    {"bare reserved atom published_proof_contract_violation",
     :published_proof_contract_violation},
    {"bare reserved atom object_mutation_journal", :object_mutation_journal}
  ]

  for {label, input} <- @unrelated_terms do
    test "g4-0 red: #{label} stays unrelated" do
      assert project(unquote(Macro.escape(input))) === :unrelated
    end
  end

  # =====================================================================
  # opaque 探针自身的非空转对照（RED 阶段即应通过）
  # =====================================================================

  test "g4-0 control: the opaque probe raises when enumerated" do
    probe = opaque_summary("enumerate-control")

    assert_raise RuntimeError, ~r/opaque touched: enumerate-control/, fn ->
      Enum.to_list(probe)
    end
  end

  test "g4-0 control: the opaque probe cannot be JSON encoded" do
    probe = opaque_summary("encode-control")

    assert_raise Protocol.UndefinedError, fn -> Jason.encode!(probe) end
  end

  # =====================================================================
  # 4.4 静态纯边界 oracle
  # =====================================================================

  @forbidden_modules [
    [:Maxio, :Storage],
    [:Maxio, :Storage, :PublishedProof],
    [:Maxio, :ObjectMutation, :StorageDisposition],
    [:Maxio, :ObjectMutation],
    [:Maxio, :ObjectMutation, :Commit],
    [:Maxio, :ObjectMutation, :Recovery],
    [:Maxio, :S3],
    [:Logger],
    [:Ecto],
    [:Repo],
    [:Jason]
  ]

  test "g4-0 red: the production source declares no forbidden module dependency" do
    hits = source_ast!() |> forbidden_module_refs()

    assert hits === [],
           "T3-G4-0: ExternalError 必须无 Storage/PublishedProof/StorageDisposition/ObjectMutation/" <>
             "Commit/Recovery/S3/Logger/Ecto/Repo/Jason 依赖，实际命中 #{inspect(hits)}"
  end

  test "g4-0 red: the production source contains no executable inspect call" do
    hits = source_ast!() |> inspect_refs()

    assert hits === [],
           "T3-G4-0: ExternalError 绝不可 inspect opaque summary 或任何 reason，实际命中 #{inspect(hits)}"
  end

  @forbidden_control_names [
    "Maxio.Storage",
    "Maxio.Storage.PublishedProof",
    "Maxio.ObjectMutation.StorageDisposition",
    "Maxio.ObjectMutation",
    "Maxio.ObjectMutation.Commit",
    "Maxio.ObjectMutation.Recovery",
    "Maxio.S3.Error",
    "Logger",
    "Ecto.Changeset",
    "Maxio.Repo",
    "Jason"
  ]

  for name <- @forbidden_control_names do
    test "g4-0 control: the dependency detector flags a remote call to #{name}" do
      source = """
      defmodule Sample do
        def f(term), do: #{unquote(name)}.call(term)
      end
      """

      refute analyzable_ast(source) |> forbidden_module_refs() === []
    end

    test "g4-0 control: the dependency detector flags an alias directive for #{name}" do
      source = """
      defmodule Sample do
        alias #{unquote(name)}
        def f(term), do: term
      end
      """

      refute analyzable_ast(source) |> forbidden_module_refs() === []
    end
  end

  test "g4-0 control: the dependency detector flags an aliased short-name call" do
    source = """
    defmodule Sample do
      alias Maxio.Storage.PublishedProof, as: Proof

      def f(term), do: PublishedProof.merge_failure(term)
    end
    """

    refute analyzable_ast(source) |> forbidden_module_refs() === []
  end

  test "g4-0 control: the inspect detector flags local, Kernel and IO inspect calls" do
    for body <- [
          "def f(term), do: {:error, inspect(term)}",
          "def f(term), do: {:error, Kernel.inspect(term, limit: 1)}",
          "def f(term), do: IO.inspect(term)"
        ] do
      source = """
      defmodule Sample do
        #{body}
      end
      """

      refute analyzable_ast(source) |> inspect_refs() === []
    end
  end

  test "g4-0 control: both detectors stay silent on a clean pure projection source" do
    source = """
    defmodule Maxio.ObjectMutation.ExternalError do
      @moduledoc \"\"\"
      alias Maxio.Storage; Logger.error(inspect(reason)); Jason.encode!(summary)
      \"\"\"

      @doc "Storage / Commit / Recovery / inspect 只出现在文档里。"
      @spec project(term()) :: {:ok, :retryable | :internal, binary()} | :unrelated
      def project({:published_proof_superseded, _opaque}),
        do: {:ok, :retryable, "published_proof_superseded"}

      def project({:published_proof_failed, _class, _opaque}),
        do: {:ok, :internal, "published_proof_failed:invalid"}

      def project(_other), do: :unrelated
    end
    """

    ast = analyzable_ast(source)

    assert forbidden_module_refs(ast) === []
    assert inspect_refs(ast) === []
  end

  # --- 静态 oracle 辅助 ---

  defp source_ast! do
    assert File.exists?(@production_path),
           "T3-G4-0: production source #{@production_path} 尚未创建（tests-only RED 的显式缺席断言）"

    @production_path |> File.read!() |> analyzable_ast()
  end

  # 文档与注释不计入依赖：注释不进 AST，`@moduledoc/@doc/@typedoc` 显式剥离；
  # `defmodule` 自身的模块名也剥离，避免把自我命名当成 ObjectMutation 依赖。
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

  # 可执行依赖：alias/import/require 指令、远程调用目标与裸模块引用都表现为
  # `__aliases__` 节点；字符串字面量不是 `__aliases__`，因此天然不计入。
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

  defp collect_nodes(ast, matcher) do
    {_ast, hits} =
      Macro.prewalk(ast, [], fn node, acc ->
        {node, if(matcher.(node), do: [Macro.to_string(node) | acc], else: acc)}
      end)

    Enum.reverse(hits)
  end
end
