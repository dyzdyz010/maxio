defmodule Maxio.Cluster.Transport do
  @moduledoc """
  跨节点分片传输契约（M7）。prod = :erpc 到每节点 Maxio.Cluster.ShardServer；
  test = 进程内多盘（Maxio.Cluster.Transport.InProcess，可注入端点宕机）。
  铁律 2：分布式后端只认本 behaviour，换传输（:erpc / gRPC / HTTP）不动后端。
  铁律 4：put_shard/get_shard 逐 (block, shard)，绝不一次传整对象/整文件。

  约定：drive_obj_dir = Path.join(drive, obj_rel)，由后端用 Topology 端点的 drive +
  Maxio.Cluster.Paths.object_rel/3 组装后传入；node 决定调哪个节点。
  节点宕机/超时/远端异常：get_shard -> nil（交 EC 重建）；get_sidecar/put_shard/put_sidecar ->
  {:error, :unavailable}。
  """
  @callback put_shard(node(), String.t(), non_neg_integer(), binary(), pos_integer()) ::
              :ok | {:error, term()}
  @callback get_shard(node(), String.t(), non_neg_integer(), pos_integer()) :: binary() | nil
  @callback put_sidecar(node(), String.t(), map()) :: :ok | {:error, term()}
  @callback get_sidecar(node(), String.t()) :: {:ok, map()} | {:error, term()}
  @callback stat_shard(node(), String.t()) :: {:ok, non_neg_integer()} | {:error, :enoent}
  @callback stat_shard_info(node(), String.t()) ::
              {:ok, %{size: non_neg_integer(), mtime_ms: integer()}} | {:error, :enoent}
  @callback delete_shard(node(), String.t()) :: :ok
  @callback move_shard(node(), String.t(), String.t(), keyword()) :: :ok | {:error, term()}
  @callback delete_part_file(node(), String.t()) :: :ok | {:error, term()}
  @callback quarantine_layout_roots(node(), String.t(), [String.t()], String.t(), map()) ::
              {:ok, map()} | {:error, term()}
  @callback purge_quarantine_root(node(), String.t(), String.t(), map()) ::
              {:ok, map()} | {:error, term()}
  @callback preflight_quarantine_purge_root(node(), String.t(), String.t(), map()) ::
              {:ok, map()} | {:error, term()}
  @callback heal_shard(node(), String.t(), %{non_neg_integer() => binary()}, pos_integer(), map()) ::
              {:ok, non_neg_integer()}

  # 原子提交（ROUTE B B1-2）：begin_tmp 在端点 drive_root 下建同卷 temp obj-dir；逐块 put_shard /
  # put_sidecar 写进该 tmp_dir；commit_object fsync + 数据先于元数据原子 rename 到 final。
  @callback begin_tmp(node(), String.t()) :: {:ok, String.t()} | {:error, term()}
  @callback commit_object(node(), String.t(), String.t(), keyword()) :: :ok | {:error, term()}

  # 走盘 LIST 单层目录原语（ROUTE B P3）：读单端点 drive_dir 下一层条目并标记每个子目录是否为对象。
  # opts[:include_layout_files] 为 scanner orphan-shard 取证专用；默认 false 时保持只返回目录。
  # 节点宕机/超时/远端异常 -> {:error, :unavailable}（铁律 3：结构化降级，绝不上抛炸列举路径）。
  @callback list_dir(node(), String.t(), keyword()) ::
              {:ok, [%{name: String.t(), object?: boolean()}]} | {:error, term()}

  # ── ObjectMutation per-endpoint 原语（协议 §3.2/§3.3，Phase 1 B4）──
  # 把 B1 落在 ShardServer 的 epoch 原语寻址到端点 {node, drive_root}；请求/响应均为可
  # erpc 序列化的纯数据（epoch payload / request map，形状见 ShardServer 同名函数）。
  # 节点宕机/超时/远端异常 -> {:error, :unavailable}（铁律 3：quorum 编排在后端，绝不上抛）。
  @callback read_epoch(node(), String.t(), map()) ::
              {:ok, map()} | {:ok, :absent} | {:error, term()}
  @callback cas_epoch(node(), String.t(), map()) :: {:ok, :applied} | {:error, term()}
  @callback restore_mutation(node(), String.t(), map()) ::
              {:ok, :restored} | {:ok, :superseded} | {:error, term()}
  @callback verify_mutation(node(), String.t(), map()) ::
              Maxio.Storage.PublishedProof.endpoint_proof_result()
  @callback finalize_mutation(node(), String.t(), map()) ::
              Maxio.Storage.PublishedProof.endpoint_finalize_result()
  # durable backup manifest 写原语（协议 §3.2）：Distributed 的协议化 publish 必须把每端点
  # manifest 落在**该端点 drive** 上并 fsync（先于该盘任何 destructive IO）；既有原语无法
  # 表达（put_sidecar 固定 meta.json 文件名且无 fsync 语义）。request 形状见
  # ShardServer.put_mutation_manifest/3。
  @callback put_mutation_manifest(node(), String.t(), map()) :: :ok | {:error, term()}

  @callback probe_drive(node(), String.t()) :: :ok | {:error, term()}
  @callback probe_drive_identity(node(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  @callback drive_hardware_evidence(node(), String.t(), keyword()) ::
              {:ok, map()} | {:error, term()}
  @callback drive_stats(node(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  @callback pressure_snapshot(node(), keyword()) :: {:ok, map()} | {:error, term()}

  @doc "当前配置的传输实现（test 经 opts[:transport] 覆盖；缺省 config :maxio, :shard_transport）。"
  @spec impl(keyword()) :: module()
  def impl(opts \\ []) do
    Keyword.get(opts, :transport) ||
      Application.get_env(:maxio, :shard_transport, Maxio.Cluster.Transport.Erpc)
  end

  @doc """
  Transport 的 wire outer-envelope seam（proof / finalize 共用）。它**只**守住线上外层信封，
  绝不复制 classifier 的语义校验：

    * 不具 endpoint result 外层信封的正常返回（旧 tuple、裸原子、裸 `{:error, reason}`）、
      以及 error/exit/throw/pre-RPC 故障，一律归一化为该 request 捕获 identity 的 canonical
      endpoint unavailable，raw term / reason 绝不外泄；
    * 具备 endpoint result 外层信封的值——即使 identity/scope/mode/outcome/status/class/count
      伪造或是 aggregate 重入——必须 **term-identical** 透传，交由公共
      `PublishedProof` classifier 判成 `:placement_drift`，Transport 不得把它洗成 unavailable。
  """
  @spec normalize_mutation_proof(map(), term()) ::
          Maxio.Storage.PublishedProof.endpoint_proof_result()
  def normalize_mutation_proof(request, result) do
    if endpoint_envelope?(result), do: result, else: mutation_proof_unavailable(request)
  end

  @doc "finalize 侧的同一 outer-envelope seam。见 `normalize_mutation_proof/2`。"
  @spec normalize_mutation_finalize(map(), term()) ::
          Maxio.Storage.PublishedProof.endpoint_finalize_result()
  def normalize_mutation_finalize(request, result) do
    if endpoint_envelope?(result), do: result, else: mutation_finalize_unavailable(request)
  end

  @doc """
  proof 侧的**惰性调用边界**：整段端点调用（含 outage 判定与 pre-RPC 组装）都必须在 `fun`
  内求值，使 error/exit/throw 无法在归一化之前逃逸。闭包内的正常 term 再交
  `normalize_mutation_proof/2` 处理外层信封。

  这是与 `normalize_mutation_proof/2` **分离**的 API：零元闭包与普通 wire term 绝不混用，
  避免把远端传来的 function term 当作代码执行。
  """
  @spec call_mutation_proof(map(), (-> term())) ::
          Maxio.Storage.PublishedProof.endpoint_proof_result()
  def call_mutation_proof(request, fun) when is_function(fun, 0) do
    case guarded_call(fun) do
      {:wire, result} -> normalize_mutation_proof(request, result)
      :transport_fault -> mutation_proof_unavailable(request)
    end
  end

  @doc "finalize 侧的同一惰性调用边界。见 `call_mutation_proof/2`。"
  @spec call_mutation_finalize(map(), (-> term())) ::
          Maxio.Storage.PublishedProof.endpoint_finalize_result()
  def call_mutation_finalize(request, fun) when is_function(fun, 0) do
    case guarded_call(fun) do
      {:wire, result} -> normalize_mutation_finalize(request, result)
      :transport_fault -> mutation_finalize_unavailable(request)
    end
  end

  # 三类异常统一收敛为 transport fault；raw reason / stacktrace 永不离开本函数。
  defp guarded_call(fun) do
    {:wire, fun.()}
  rescue
    _error -> :transport_fault
  catch
    :exit, _reason -> :transport_fault
    :throw, _value -> :transport_fault
  end

  # 只判定外层信封形状：`{:ok, {outcome_atom, map}}` 与
  # `{:error, {:published_proof_failed, class_atom, map}}`。内部字段一律不看。
  defp endpoint_envelope?({:ok, {outcome, summary}})
       when is_atom(outcome) and is_map(summary),
       do: true

  defp endpoint_envelope?({:error, {:published_proof_failed, class, summary}})
       when is_atom(class) and is_map(summary),
       do: true

  defp endpoint_envelope?(_result), do: false

  @doc false
  @spec mutation_proof_unavailable(map()) :: Maxio.Storage.PublishedProof.endpoint_proof_result()
  def mutation_proof_unavailable(%{layout: %{kind: "fs"} = layout})
      when map_size(layout) == 1 do
    Maxio.Storage.PublishedProof.failed(:unavailable, "local", %{
      code: :rpc_unavailable,
      layout: "fs",
      owned: false
    })
  end

  def mutation_proof_unavailable(%{layout: %{kind: "shard", index: index} = layout})
      when map_size(layout) == 2 and is_integer(index) and index >= 0 do
    Maxio.Storage.PublishedProof.failed(:unavailable, index, %{
      code: :rpc_unavailable,
      layout: "shard:#{index}",
      owned: false
    })
  end

  def mutation_proof_unavailable(_request) do
    Maxio.Storage.PublishedProof.failed(:placement_drift, "local", %{
      code: :invalid_endpoint_layout,
      owned: false
    })
  end

  @doc false
  @spec mutation_finalize_unavailable(map()) ::
          Maxio.Storage.PublishedProof.endpoint_finalize_result()
  def mutation_finalize_unavailable(%{layout: %{kind: "fs"} = layout})
      when map_size(layout) == 1 do
    Maxio.Storage.PublishedProof.endpoint_finalize_failed(:unavailable, "local", %{
      code: :rpc_unavailable,
      layout: "fs",
      owned: false
    })
  end

  def mutation_finalize_unavailable(%{layout: %{kind: "shard", index: index} = layout})
      when map_size(layout) == 2 and is_integer(index) and index >= 0 do
    Maxio.Storage.PublishedProof.endpoint_finalize_failed(:unavailable, index, %{
      code: :rpc_unavailable,
      layout: "shard:#{index}",
      owned: false
    })
  end

  def mutation_finalize_unavailable(_request) do
    Maxio.Storage.PublishedProof.endpoint_finalize_failed(:placement_drift, "local", %{
      code: :invalid_endpoint_layout,
      owned: false
    })
  end
end

defmodule Maxio.Cluster.Transport.Erpc do
  @moduledoc """
  :erpc 分片传输（prod，M7）。把每个端点 op 作为一条 :erpc 调用到该 node 的 Maxio.Cluster.ShardServer。
  铁律 3：节点 down（{:erpc, :noconnection}）/ 超时（{:erpc, :timeout}）/ 远端异常 ->
  get_shard nil、写 {:error, :unavailable}（绝不静默成功，绝不把异常上抛炸后端）。
  本地节点（node == Node.self()）直接函数调用，跳过 :erpc（省序列化）。
  """
  @behaviour Maxio.Cluster.Transport

  alias Maxio.Cluster.ShardServer

  @timeout 5_000
  @pressure_timeout 50

  @impl true
  def put_shard(node, dir, j, shard, shard_len) do
    call(node, :put_shard, [dir, j, shard, shard_len], fn -> {:error, :unavailable} end)
  end

  @impl true
  def get_shard(node, dir, j, shard_len) do
    call(node, :get_shard, [dir, j, shard_len], fn -> nil end)
  end

  @impl true
  def put_sidecar(node, dir, meta) do
    call(node, :put_sidecar, [dir, meta], fn -> {:error, :unavailable} end)
  end

  @impl true
  def get_sidecar(node, dir) do
    call(node, :get_sidecar, [dir], fn -> {:error, :unavailable} end)
  end

  @impl true
  def stat_shard(node, dir) do
    call(node, :stat_shard, [dir], fn -> {:error, :enoent} end)
  end

  @impl true
  def stat_shard_info(node, dir) do
    call(node, :stat_shard_info, [dir], fn -> {:error, :enoent} end)
  end

  @impl true
  def delete_shard(node, dir) do
    call(node, :delete_shard, [dir], fn -> :ok end)
  end

  @impl true
  def move_shard(node, source_dir, destination_dir, opts \\ []) do
    call(node, :move_shard, [source_dir, destination_dir, opts], fn ->
      {:error, :unavailable}
    end)
  end

  @impl true
  def delete_part_file(node, dir) do
    call(node, :delete_part_file, [dir], fn -> {:error, :unavailable} end)
  end

  @impl true
  def quarantine_layout_roots(node, drive_root, bucket_names, quarantine_id, marker) do
    call(
      node,
      :quarantine_layout_roots,
      [drive_root, bucket_names, quarantine_id, marker],
      fn -> {:error, :unavailable} end
    )
  end

  @impl true
  def purge_quarantine_root(node, drive_root, quarantine_id, expected_marker) do
    call(
      node,
      :purge_quarantine_root,
      [drive_root, quarantine_id, expected_marker],
      fn -> {:error, :unavailable} end
    )
  end

  @impl true
  def preflight_quarantine_purge_root(node, drive_root, quarantine_id, expected_marker) do
    call(
      node,
      :preflight_quarantine_purge_root,
      [drive_root, quarantine_id, expected_marker],
      fn -> {:error, :unavailable} end
    )
  end

  @impl true
  def heal_shard(node, dir, block_map, shard_len, meta) do
    call(node, :heal_shard, [dir, block_map, shard_len, meta], fn -> {:ok, 0} end)
  end

  @impl true
  def begin_tmp(node, drive_root) do
    call(node, :begin_tmp, [drive_root], fn -> {:error, :unavailable} end)
  end

  @impl true
  def commit_object(node, tmp_dir, final_obj_dir, opts) do
    call(node, :commit, [tmp_dir, final_obj_dir, opts], fn -> {:error, :unavailable} end)
  end

  @impl true
  def list_dir(node, drive_dir, opts) do
    call(node, :list_dir, [drive_dir, opts], fn -> {:error, :unavailable} end)
  end

  @impl true
  def read_epoch(node, drive_root, target) do
    call(node, :read_epoch, [drive_root, target], fn -> {:error, :unavailable} end)
  end

  @impl true
  def cas_epoch(node, drive_root, request) do
    call(node, :cas_epoch, [drive_root, request], fn -> {:error, :unavailable} end)
  end

  @impl true
  def restore_mutation(node, drive_root, request) do
    call(node, :restore_mutation, [drive_root, request], fn -> {:error, :unavailable} end)
  end

  @impl true
  def verify_mutation(node, drive_root, request) do
    Maxio.Cluster.Transport.call_mutation_proof(request, fn ->
      call(node, :verify_mutation, [drive_root, request], fn -> :rpc_unavailable end)
    end)
  end

  # 正常 malformed 返回与 error/exit/throw/pre-RPC 故障走同一个 outer-envelope seam。
  @impl true
  def finalize_mutation(node, drive_root, request) do
    Maxio.Cluster.Transport.call_mutation_finalize(request, fn ->
      call(node, :finalize_mutation, [drive_root, request], fn -> :rpc_unavailable end)
    end)
  end

  @impl true
  def put_mutation_manifest(node, drive_root, request) do
    call(node, :put_mutation_manifest, [drive_root, request], fn -> {:error, :unavailable} end)
  end

  @impl true
  def probe_drive(node, drive_root) do
    call(node, :probe_drive, [drive_root], fn -> {:error, :unavailable} end)
  end

  @impl true
  def probe_drive_identity(node, drive_root, opts \\ []) do
    call(node, :probe_drive_identity, [drive_root, opts], fn -> {:error, :unavailable} end)
  end

  @impl true
  def drive_hardware_evidence(node, drive_root, opts \\ []) do
    call(node, :drive_hardware_evidence, [drive_root, opts], fn -> {:error, :unavailable} end)
  end

  @impl true
  def drive_stats(node, drive_root, opts \\ []) do
    call(node, :drive_stats, [drive_root, opts], fn -> {:error, :unavailable} end)
  end

  @impl true
  def pressure_snapshot(node, opts \\ []) do
    timeout = Keyword.get(opts, :timeout_ms, @pressure_timeout)

    if node == Node.self() do
      {:ok, Maxio.Cluster.IOPressure.local_snapshot()}
    else
      try do
        {:ok, :erpc.call(node, Maxio.Cluster.IOPressure, :local_snapshot, [], timeout)}
      catch
        :error, _reason -> {:error, :unavailable}
        :exit, _reason -> {:error, :unavailable}
        :throw, _reason -> {:error, :unavailable}
      end
    end
  end

  # 本地直接调；远端 :erpc。任何宕机/超时/异常 -> on_fail 兜底（铁律 3：结构化降级，绝不上抛）。
  defp call(node, fun, args, on_fail) do
    try do
      if node == Node.self() do
        apply(ShardServer, fun, args)
      else
        :erpc.call(node, ShardServer, fun, args, @timeout)
      end
    catch
      # 本地 direct apply 与远端 :erpc 的 error/exit/throw 都必须归一为调用方提供的
      # bounded fallback，不能让本地节点成为异常上抛的特殊路径。
      :error, _reason -> on_fail.()
      :exit, _reason -> on_fail.()
      :throw, _reason -> on_fail.()
    end
  end
end
