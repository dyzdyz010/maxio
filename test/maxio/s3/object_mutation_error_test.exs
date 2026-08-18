defmodule Maxio.S3.ObjectMutationErrorTest do
  # 纯 HTTP 边界适配器：无 Repo、无 backend、无 I/O，可以 async。
  use ExUnit.Case, async: true

  alias Maxio.ObjectMutation.ExternalError
  alias Maxio.S3.Error
  alias Maxio.S3.ErrorView

  # --- Task 3 / G4a-1：唯一共享的 ObjectMutation → S3 错误适配器 RED ---
  #
  # `Maxio.S3.ObjectMutationError` 是 PutObject / CopyObject / ObjectWriter 共用的**唯一**
  # 映射点。它只暴露：
  #
  #     to_error(reason, resource)
  #
  # 返回 `{:ok, %Maxio.S3.Error{}}` 或 `:unrelated`。
  #
  # 它调用冻结的 `Maxio.ObjectMutation.ExternalError.project/1` **一次**，并只按类别映射：
  #
  #     retryable -> Error.new(:slow_down_write, resource: resource)
  #     internal  -> Error.new(:internal_error, resource: resource)
  #     unrelated -> :unrelated
  #
  # 完整的保留信封分类矩阵属于冻结的 ExternalError 测试，本文件**不重复**它：这里只锁
  # 类别接线、unrelated 透传、默认 message / resource / XML 安全，以及源码静态边界。
  #
  # 本文件经 `apply/3` 调用尚未存在的模块：让「能力缺失」成为独立的失败签名。

  # 目录冻结的公共契约（SlowDownWrite 逐字对齐 MinIO cmd/api-errors.go ErrSlowDownWrite）。
  @slow_down_write_code "SlowDownWrite"
  @slow_down_write_status 503
  @slow_down_write_message "Resource requested is unwritable, please reduce your request rate"

  @internal_code "InternalError"
  @internal_status 500
  @internal_message "An internal error occurred. Try again."

  @resource "/mybucket/objects/report.bin"

  # 绝不允许进入 %Error{} 或 XML 的原始基础设施材料。
  @opaque_sentinel "g4a-1-opaque-sentinel-5d21c8"
  @node_sentinel "maxio-node-7.internal.example"
  @drive_sentinel "D:\\maxio\\data\\drive3"
  @path_sentinel "/var/lib/maxio/data/mybucket/report.bin"
  @backup_sentinel "backup-2026-07-28T00-00-00Z-report.bin"

  @sentinels [
    @opaque_sentinel,
    @node_sentinel,
    @drive_sentinel,
    @path_sentinel,
    @backup_sentinel
  ]

  @production_path "lib/maxio/s3/object_mutation_error.ex"

  # --- 能力探针 ---

  defp capability!() do
    assert Code.ensure_loaded?(Maxio.S3.ObjectMutationError),
           "T3-G4a-1: Maxio.S3.ObjectMutationError 尚未实现（s3-adapter amendment §1）"

    assert function_exported?(Maxio.S3.ObjectMutationError, :to_error, 2),
           "T3-G4a-1: Maxio.S3.ObjectMutationError.to_error/2 尚未实现"
  end

  defp to_error(reason, resource) do
    capability!()
    apply(Maxio.S3.ObjectMutationError, :to_error, [reason, resource])
  end

  # 带 raw 基础设施材料的 summary：适配器绝不可读取它，更不可让它进入公共输出。
  defp infra_summary do
    %{
      "sentinel" => @opaque_sentinel,
      "node" => @node_sentinel,
      "drive" => @drive_sentinel,
      "data_path" => @path_sentinel,
      "backup" => @backup_sentinel
    }
  end

  # 碰一下就炸的 opaque 探针：被枚举/编码即失败。
  defp opaque_summary(tag) do
    Stream.resource(
      fn -> raise "opaque touched: #{tag}" end,
      fn acc -> {:halt, acc} end,
      fn _acc -> :ok end
    )
  end

  # =====================================================================
  # 公共 API 面
  # =====================================================================

  test "g4a-1 red: to_error/2 is the only public function of the adapter" do
    capability!()

    functions =
      Maxio.S3.ObjectMutationError
      |> apply(:__info__, [:functions])
      |> Enum.sort()

    assert functions === [to_error: 2],
           "T3-G4a-1: 适配器只允许暴露 to_error/2，实际为 #{inspect(functions)}"

    refute function_exported?(Maxio.S3.ObjectMutationError, :to_error, 3),
           "T3-G4a-1: 绝不接受调用方自带的公共 message（不得有 to_error/3）"
  end

  # =====================================================================
  # 类别接线：retryable → 503 SlowDownWrite（默认 message）
  # =====================================================================

  test "g4a-1 red: a retryable proof-unavailable reason maps to the default-message 503 SlowDownWrite" do
    assert {:ok, %Error{} = error} =
             to_error({:published_proof_failed, :unavailable, infra_summary()}, @resource)

    assert error.code === @slow_down_write_code
    assert error.http_status === @slow_down_write_status
    assert error.message === @slow_down_write_message
    assert error.resource === @resource
  end

  test "g4a-1 red: a retryable superseded reason maps to the default-message 503 SlowDownWrite" do
    assert {:ok, %Error{} = error} =
             to_error({:published_proof_superseded, infra_summary()}, @resource)

    assert error.code === @slow_down_write_code
    assert error.http_status === @slow_down_write_status
    assert error.message === @slow_down_write_message
    assert error.resource === @resource
  end

  # =====================================================================
  # 类别接线：internal → 500 InternalError（默认 message）
  # =====================================================================

  test "g4a-1 red: an integrity-failure reason maps to the default-message 500 InternalError" do
    assert {:ok, %Error{} = error} =
             to_error({:published_proof_failed, :mismatch, infra_summary()}, @resource)

    assert error.code === @internal_code
    assert error.http_status === @internal_status
    assert error.message === @internal_message
    assert error.resource === @resource
  end

  test "g4a-1 red: a proof contract violation maps to the default-message 500 InternalError" do
    assert {:ok, %Error{} = error} =
             to_error({:published_proof_contract_violation, :proof}, @resource)

    assert error.code === @internal_code
    assert error.http_status === @internal_status
    assert error.message === @internal_message
    assert error.resource === @resource
  end

  test "g4a-1 red: a journal finalize_outcome envelope maps to the default-message 500 InternalError" do
    assert {:ok, %Error{} = error} =
             to_error({:object_mutation_journal, :internal, :finalize_outcome}, @resource)

    assert error.code === @internal_code
    assert error.http_status === @internal_status
    assert error.message === @internal_message
    assert error.resource === @resource
  end

  test "g4a-1 red: a forged fenced aggregate stays internal through the frozen fail-closed policy" do
    assert {:ok, %Error{} = error} =
             to_error({:published_proof_failed, :fenced, infra_summary()}, @resource)

    assert error.code === @internal_code
    assert error.http_status === @internal_status
    assert error.message === @internal_message
  end

  # =====================================================================
  # unrelated 透传：既有 legacy 分类路径原样保留
  # =====================================================================

  @unrelated_reasons [
    {"independent epoch fence", {:fenced, "g4a-1-epoch-token-6c1f90"}},
    {"legacy epoch_fenced storage error", {:epoch_fenced, %{"token" => "g4a-1-epoch-token"}}},
    {"legacy write quorum error", {:write_quorum, 2, 3}},
    {"legacy posix error", :enoent},
    {"legacy metadata CAS error", {:stale_metadata, "etag-mismatch"}},
    {"arbitrary map", %{reason: :whatever}},
    {"arbitrary scalar", :totally_unrelated_reason},
    {"bare reserved atom", :published_proof_failed}
  ]

  for {label, reason} <- @unrelated_reasons do
    test "g4a-1 red: #{label} stays unrelated so its legacy mapping is preserved" do
      assert to_error(unquote(Macro.escape(reason)), @resource) === :unrelated
    end
  end

  # =====================================================================
  # 接线一致性：类别决策必须来自冻结的 ExternalError，而非重复的本地表
  # =====================================================================

  test "g4a-1 red: every representative category agrees with the frozen ExternalError projection" do
    representatives = [
      {:published_proof_failed, :unavailable, infra_summary()},
      {:published_proof_superseded, infra_summary()},
      {:published_proof_failed, :corrupt, infra_summary()},
      {:published_proof_contract_violation, :finalize},
      {:object_mutation_journal, :internal, :publish_transition},
      {:object_mutation_journal, :internal, :bogus_stage},
      {:fenced, "g4a-1-epoch-token-6c1f90"},
      :enoent
    ]

    for reason <- representatives do
      case ExternalError.project(reason) do
        {:ok, :retryable, _safe_code} ->
          assert {:ok, %Error{code: @slow_down_write_code, http_status: @slow_down_write_status}} =
                   to_error(reason, @resource)

        {:ok, :internal, _safe_code} ->
          assert {:ok, %Error{code: @internal_code, http_status: @internal_status}} =
                   to_error(reason, @resource)

        :unrelated ->
          assert to_error(reason, @resource) === :unrelated
      end
    end
  end

  # =====================================================================
  # opaque summary：绑定但绝不触碰
  # =====================================================================

  test "g4a-1 red: the opaque summary is never enumerated on the retryable path" do
    assert {:ok, %Error{code: @slow_down_write_code}} =
             to_error(
               {:published_proof_failed, :unavailable, opaque_summary("retryable")},
               @resource
             )
  end

  test "g4a-1 red: the opaque summary is never enumerated on the internal path" do
    assert {:ok, %Error{code: @internal_code}} =
             to_error(
               {:published_proof_superseded, :proof, opaque_summary("internal")},
               @resource
             )
  end

  # =====================================================================
  # resource 透传
  # =====================================================================

  test "g4a-1 red: the caller resource is passed through verbatim, including nil" do
    other = "/otherbucket/deep/prefix/object%20name"

    assert {:ok, %Error{resource: ^other}} =
             to_error({:published_proof_failed, :unavailable, infra_summary()}, other)

    assert {:ok, %Error{resource: nil}} =
             to_error({:published_proof_failed, :mismatch, infra_summary()}, nil)
  end

  # =====================================================================
  # XML 渲染安全
  # =====================================================================

  test "g4a-1 red: the retryable error renders exact XML without any infrastructure material" do
    assert {:ok, error} =
             to_error({:published_proof_failed, :unavailable, infra_summary()}, @resource)

    {status, iodata} = ErrorView.render(error)
    xml = IO.iodata_to_binary(iodata)

    assert status === @slow_down_write_status
    assert xml =~ "<Code>#{@slow_down_write_code}</Code>"
    assert xml =~ "<Message>#{@slow_down_write_message}</Message>"
    assert xml =~ "<Resource>#{@resource}</Resource>"

    for sentinel <- @sentinels do
      refute xml =~ sentinel, "T3-G4a-1: XML 泄漏了原始基础设施材料 #{sentinel}"
    end
  end

  test "g4a-1 red: the internal error renders exact XML without any infrastructure material" do
    assert {:ok, error} =
             to_error({:published_proof_failed, :corrupt, infra_summary()}, @resource)

    {status, iodata} = ErrorView.render(error)
    xml = IO.iodata_to_binary(iodata)

    assert status === @internal_status
    assert xml =~ "<Code>#{@internal_code}</Code>"
    assert xml =~ "<Message>#{@internal_message}</Message>"
    assert xml =~ "<Resource>#{@resource}</Resource>"

    for sentinel <- @sentinels do
      refute xml =~ sentinel, "T3-G4a-1: XML 泄漏了原始基础设施材料 #{sentinel}"
    end
  end

  # =====================================================================
  # 静态源码边界
  # =====================================================================

  # 允许且**必需**的唯一 ObjectMutation 依赖是冻结的 ExternalError；其余一律禁止。
  @forbidden_modules [
    [:Maxio, :Storage],
    [:Maxio, :Storage, :PublishedProof],
    [:Maxio, :ObjectMutation, :Commit],
    [:Maxio, :ObjectMutation, :Recovery],
    [:Maxio, :ObjectMutation, :StorageDisposition],
    [:Maxio, :ObjectMutation, :Journal],
    [:Logger],
    [:Ecto],
    [:Repo],
    [:Jason],
    [:Application],
    [:File],
    [:IO],
    [:System],
    [:Process]
  ]

  # 保留稳定信封 tag 只允许出现在冻结的 ExternalError 里，绝不允许适配器直接匹配。
  @reserved_tags [
    :published_proof_failed,
    :published_proof_superseded,
    :published_proof_contract_violation,
    :object_mutation_journal
  ]

  test "g4a-1 red: the adapter source declares no forbidden dependency" do
    hits = source_ast!() |> forbidden_module_refs()

    assert hits === [],
           "T3-G4a-1: 适配器禁止依赖 Storage/PublishedProof/Commit/Recovery/StorageDisposition/" <>
             "Journal/Logger/Ecto/Repo/Jason/config/IO，实际命中 #{inspect(hits)}"
  end

  test "g4a-1 red: the adapter source never matches a reserved stable envelope tag" do
    hits = source_ast!() |> reserved_tag_refs()

    assert hits === [],
           "T3-G4a-1: 稳定信封只能由冻结的 ExternalError 匹配，适配器命中 #{inspect(hits)}"
  end

  test "g4a-1 red: the adapter source contains no executable inspect call" do
    hits = source_ast!() |> inspect_refs()

    assert hits === [], "T3-G4a-1: 适配器绝不可 inspect reason 或 summary，实际命中 #{inspect(hits)}"
  end

  # 目标解析而非「提到即可」：调用目标必须**解析**到完整的
  # `Maxio.ObjectMutation.ExternalError.project/1`（完全限定、`alias` 或 `alias ..., as:`
  # 均可），且执行路径上**恰好一次**；任何其它 `project` 远程调用都不允许。
  test "g4a-1 red: the adapter delegates exactly once to Maxio.ObjectMutation.ExternalError.project/1" do
    ast = source_ast!()
    delegations = external_error_project_calls(ast)
    foreign = foreign_project_calls(ast)

    assert length(delegations) === 1,
           "T3-G4a-1: 必须恰好调用一次 Maxio.ObjectMutation.ExternalError.project/1，实际解析到 " <>
             "#{inspect(delegations)}"

    assert foreign === [],
           "T3-G4a-1: 类别决策只能来自冻结的 ExternalError.project/1，实际还有其它 project 调用 " <>
             "#{inspect(foreign)}"
  end

  # --- 静态探测器的非空转对照 ---

  @forbidden_control_names [
    "Maxio.Storage",
    "Maxio.Storage.PublishedProof",
    "Maxio.ObjectMutation.Commit",
    "Maxio.ObjectMutation.Recovery",
    "Maxio.ObjectMutation.StorageDisposition",
    "Logger",
    "Maxio.Repo",
    "Jason",
    "Application",
    "IO"
  ]

  for name <- @forbidden_control_names do
    test "g4a-1 control: the dependency detector flags #{name}" do
      source = """
      defmodule Sample do
        def f(term), do: #{unquote(name)}.call(term)
      end
      """

      refute analyzable_ast(source) |> forbidden_module_refs() === []
    end
  end

  test "g4a-1 control: the reserved-tag detector flags a direct envelope match" do
    for body <- [
          "def f({:published_proof_failed, _class, _opaque}), do: :hit",
          "def f({:published_proof_superseded, _opaque}), do: :hit",
          "def f({:published_proof_contract_violation, :proof}), do: :hit",
          "def f({:object_mutation_journal, :internal, :publish_transition}), do: :hit"
        ] do
      source = """
      defmodule Sample do
        #{body}
        def f(_other), do: :unrelated
      end
      """

      refute analyzable_ast(source) |> reserved_tag_refs() === []
    end
  end

  test "g4a-1 control: the inspect detector flags local, Kernel and IO inspect calls" do
    for body <- [
          "def f(term), do: {:error, inspect(term)}",
          "def f(term), do: {:error, Kernel.inspect(term)}",
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

  # 所有合法的 alias 风格都必须解析到同一个目标，且计为恰好一次。
  @delegation_good_controls [
    {"fully qualified",
     """
     defmodule Sample do
       def to_error(reason, _resource),
         do: Maxio.ObjectMutation.ExternalError.project(reason)
     end
     """},
    {"plain alias",
     """
     defmodule Sample do
       alias Maxio.ObjectMutation.ExternalError

       def to_error(reason, resource) do
         case ExternalError.project(reason) do
           {:ok, :retryable, _safe} -> {:ok, Error.new(:slow_down_write, resource: resource)}
           :unrelated -> :unrelated
         end
       end
     end
     """},
    {"renamed alias",
     """
     defmodule Sample do
       alias Maxio.ObjectMutation.ExternalError, as: Projection

       def to_error(reason, _resource), do: Projection.project(reason)
     end
     """},
    {"grouped alias",
     """
     defmodule Sample do
       alias Maxio.ObjectMutation.{ExternalError}

       def to_error(reason, _resource), do: ExternalError.project(reason)
     end
     """}
  ]

  for {label, source} <- @delegation_good_controls do
    test "g4a-1 control: the delegation oracle resolves a #{label} target as exactly one call" do
      ast = analyzable_ast(unquote(source))

      assert length(external_error_project_calls(ast)) === 1
      assert foreign_project_calls(ast) === []
    end
  end

  test "g4a-1 control: the delegation oracle rejects a foreign project/1 call behind an ExternalError alias" do
    source = """
    defmodule Sample do
      alias Maxio.ObjectMutation.ExternalError
      alias Maxio.S3.OtherPolicy, as: Other

      @moduledoc "看似依赖 ExternalError，实际把类别决策交给了别处。"
      def to_error(reason, _resource), do: Other.project(reason)
    end
    """

    ast = analyzable_ast(source)

    assert external_error_project_calls(ast) === [],
           "T3-G4a-1: 仅 alias/提及 ExternalError 不得被当成委派"

    refute foreign_project_calls(ast) === [],
           "T3-G4a-1: 非 ExternalError 的 project 调用必须被识别"
  end

  test "g4a-1 control: the delegation oracle rejects a duplicated ExternalError.project/1 call" do
    source = """
    defmodule Sample do
      alias Maxio.ObjectMutation.ExternalError

      def to_error(reason, resource) do
        case ExternalError.project(reason) do
          {:ok, :retryable, _safe} -> {:ok, Error.new(:slow_down_write, resource: resource)}
          _other -> requalify(reason, resource)
        end
      end

      defp requalify(reason, resource) do
        case Maxio.ObjectMutation.ExternalError.project(reason) do
          {:ok, :internal, _safe} -> {:ok, Error.new(:internal_error, resource: resource)}
          :unrelated -> :unrelated
        end
      end
    end
    """

    ast = analyzable_ast(source)

    assert length(external_error_project_calls(ast)) === 2,
           "T3-G4a-1: 重复委派必须被计数识别，绝不能被 `至少一次` 的探测器放过"
  end

  test "g4a-1 control: the delegation oracle rejects a wrong-arity ExternalError.project call" do
    source = """
    defmodule Sample do
      alias Maxio.ObjectMutation.ExternalError

      def to_error(reason, resource), do: ExternalError.project(reason, resource)
    end
    """

    ast = analyzable_ast(source)

    assert external_error_project_calls(ast) === []
    refute foreign_project_calls(ast) === []
  end

  test "g4a-1 control: every static detector ignores documentation and comments" do
    doc_only = """
    defmodule Sample do
      @moduledoc "调用 Maxio.ObjectMutation.ExternalError.project/1；绝不 inspect。"
      @doc "published_proof_failed / Logger / Storage 只出现在文档里。"
      # ExternalError.project(reason) 只是注释。
      def to_error(_reason, _resource), do: :unrelated
    end
    """

    doc_ast = analyzable_ast(doc_only)

    assert external_error_project_calls(doc_ast) === []
    assert foreign_project_calls(doc_ast) === []
    assert forbidden_module_refs(doc_ast) === []
    assert reserved_tag_refs(doc_ast) === []
    assert inspect_refs(doc_ast) === []
  end

  # --- 静态 oracle 辅助 ---

  defp source_ast! do
    assert File.exists?(@production_path),
           "T3-G4a-1: production source #{@production_path} 尚未创建（tests-only RED 的显式缺席断言）"

    @production_path |> File.read!() |> analyzable_ast()
  end

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

  defp reserved_tag_refs(ast), do: collect_nodes(ast, &(&1 in @reserved_tags))

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

  # --- 委派目标解析：短名经 alias 环境还原成完整模块 parts ---

  @external_error_parts [:Maxio, :ObjectMutation, :ExternalError]

  # 解析到 `Maxio.ObjectMutation.ExternalError.project/1` 的执行调用。
  defp external_error_project_calls(ast) do
    ast
    |> project_call_targets()
    |> Enum.filter(&(&1 === {@external_error_parts, 1}))
  end

  # 任何其它 `project` 远程调用（别的模块、错误 arity）都不是合法委派。
  defp foreign_project_calls(ast) do
    ast
    |> project_call_targets()
    |> Enum.reject(&(&1 === {@external_error_parts, 1}))
  end

  defp project_call_targets(ast) do
    env = alias_env(ast)

    {_ast, targets} =
      Macro.prewalk(ast, [], fn
        {{:., _dot_meta, [{:__aliases__, _alias_meta, parts}, :project]}, _meta, args} = node, acc
        when is_list(args) ->
          if Enum.all?(parts, &is_atom/1),
            do: {node, [{resolve_alias(parts, env), length(args)} | acc]},
            else: {node, acc}

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(targets)
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
