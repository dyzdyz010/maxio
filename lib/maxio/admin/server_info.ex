defmodule Maxio.Admin.ServerInfo do
  @moduledoc """
  madmin `InfoMessage` 的聚合层（`GET /minio/admin/v3/info`，设计 §10）。

  ## 诚实性纪律（本模块存在的第一理由）

  madmin 的 struct 字段远多于 maxio 拥有的概念。这里最容易发生的失败**不是崩溃**，
  而是用 `0` / 空串冒充"已测量"：在监控里 `0` 与"没有这个概念"是两个完全不同的信号，
  一个恒为 0 的 `rrSCParity` 会被读成"REDUCED_REDUNDANCY 存储类零冗余"，而 maxio
  根本没有这个存储类分级。于是本模块的规则是：

    1. **没有真实数据源的字段一律 omit**（键不出现），绝不填零值；
    2. **口径不同的数字绝不复用字段名**——BEAM 的内存/IO 计数器与 Go runtime、MinIO 的
       盘吞吐口径不可比，不可比就 omit；
    3. `:suspect` 盘**保守**计入 `offlineDisks` 且 state 绝不报 `"ok"`——健康度只允许
       被低估，不允许被夸大；
    4. `usage` 与 Prometheus / quota 共用 `Maxio.S3.Prometheus.usage_stats/1` 同一口径，
       绝不分叉（这是**逻辑字节**，不是物理占用）。

  Go 的 `json.Decode` 忽略未知字段、缺失字段取零值，所以 omit 对 madmin 是安全的。

  ## 与设计文档的两处**刻意**偏离（连同理由记在这里，便于复审对照）

  ### `mode` 恒为 `"online"`，不映射 `Ops.ClusterHealthConsole` 的 status

  设计 §10.1 建议把 `mode` 映射成集群健康控制台的 `:status`。落地时不这么做，两个理由：

    * **语义不对**。MinIO 的 `mode` 回答的是"这个 server 是否已初始化并在服务请求"，
      盘/集群健康在 `backend.offlineDisks` 与 `drives[].state` 里单独表达。而
      `ClusterHealthConsole` 的 status 表达的是**拓扑漂移证据**：默认 FS 单机部署下它是
      `"attention"`（因为没有配置集群拓扑）。把它塞进 `mode`，等于让一个健康的默认部署
      长期自报降级——这是反方向的不诚实（狼来了），运维很快就会学会无视这个字段。
    * **取值集合未核实**（V-A6）。往一个词汇表没核实过的字段里写 maxio 自造的
      `"attention"` / `"blocked"` 串，正是铁律 5 禁止的"凭记忆编造线格式"。

    `"online"` 则是**有证据**的：这个响应本身就是服务器在服务请求的证明——与设计给
    `servers[].state` 的理由逐字相同，两者保持一致。

  ### `onlineDisks` / `offlineDisks` 读 `DriveHealth.status/1`，不调 `probe_topology/1`

  设计 §10.2 写的是 `probe_topology/1`。那个函数会**主动向每个 endpoint 发探针**；
  挂在一个可能被监控系统高频轮询的 HTTP 端点上，等于把 `mc admin info` 变成一个放大器。
  本模块只读已观测状态（`DriveHealth` 是观测型注册表，未探过的 endpoint 视为 online），
  这是"如实报告我们已知的事"，而不是"为了回答问题去制造负载"。

  ## 缓存（设计 §10.1 脚注）

  `usage_stats/1` 每次调用都是一次 `objects` 全表 group-by 扫描；盘容量采样要走 os_mon。
  这两部分走短 TTL 快照缓存，`?no-cache=true`（madmin 自己就发这个参数）绕过。
  `uptime` / `deploymentID` 等便宜且必须新鲜的字段永远实时计算，绝不进缓存。
  """

  alias Maxio.Cluster.{DriveHealth, DriveStats, Topology}
  alias Maxio.Config.DeploymentId
  alias Maxio.S3.{Log, Prometheus}
  alias Maxio.Storage.Erasure

  @pt_cache {__MODULE__, :snapshot_cache}
  @default_cache_ttl_ms 30_000

  @doc """
  构建 `InfoMessage` 响应体（string-keyed map，可直接 `Jason.encode!`）。

  `opts`：
    * `:no_cache` —— 绕过 usage / 盘容量快照缓存
    * `:host` / `:scheme` —— 本节点 endpoint 的取值（HTTP 路径传 conn 的真实值）
    * `:topology` —— 注入拓扑（测试用；缺省读运行时拓扑）
    * `:repo` —— 注入 Repo（测试用）
    * `:drive_health_fun` / `:logical_processors_fun` —— 注入观测源（测试用）
  """
  @spec build(keyword()) :: map()
  def build(opts \\ []) do
    snapshot =
      if Keyword.get(opts, :no_cache, false) do
        collect(opts)
      else
        cached(opts)
      end

    render(snapshot, opts)
  end

  @doc "丢弃本节点的 usage / 盘容量快照缓存（测试与运维强制刷新用）。"
  @spec invalidate_cache() :: :ok
  def invalidate_cache do
    :persistent_term.erase(@pt_cache)
    :ok
  end

  # ── 渲染 ───────────────────────────────────────────────────────────────────

  # VERIFY-AT-IMPL V-A6：MinIO `InfoMessage.mode` 的合法取值集合未核实（需读
  # minio/cmd/admin-handlers.go）。核实前只发已确定存在的 `"online"`，绝不自造取值串。
  # VERIFY-AT-IMPL V-A11：往 `InfoMessage` 里加 maxio 自定义键是否安全（Go 应忽略未知键）
  # 未实测——本批**不加**任何自定义键，所以这一项在本批不构成风险，留给后续批次核实。
  defp render(snapshot, opts) do
    s3 = Application.get_env(:maxio, :s3, [])

    %{}
    # mode 恒 "online"：这个响应本身就是"服务器在服务请求"的证据（见 moduledoc）。
    |> put("mode", "online")
    # madmin 的 Domain 是 []string。
    |> put("domain", domain(s3))
    |> put("region", presence(s3[:region]))
    |> put("deploymentID", deployment_id(opts))
    |> put("buckets", %{"count" => snapshot.usage.bucket_count})
    |> put("objects", %{"count" => snapshot.usage.object_count})
    |> put("versions", %{"count" => snapshot.usage.version_count})
    |> put("deletemarkers", %{"count" => snapshot.usage.delete_marker_count})
    |> put("usage", %{"size" => snapshot.usage.total_bytes})
    |> put("backend", backend_section(snapshot))
    |> put("servers", [server_section(snapshot, opts)])
  end

  defp backend_section(snapshot) do
    %{}
    |> put("backendType", snapshot.backend_type)
    |> put("onlineDisks", snapshot.online_disks)
    |> put("offlineDisks", snapshot.offline_disks)
    |> put("standardSCParity", snapshot.parity_shards)
    |> put("totalSets", snapshot.total_sets)
    |> put("totalDrivesPerSet", snapshot.drives_per_set)

    # rrSCParity / rrSCData 永远不出现：maxio 没有 REDUCED_REDUNDANCY 的独立 parity。
    # 从 standardSCParity 回填等于宣称存在一个没实现的存储类分级——那是伪造能力，不是兼容。
  end

  defp server_section(snapshot, opts) do
    %{}
    |> put("state", "online")
    |> put("endpoint", endpoint(opts))
    |> put("scheme", scheme(opts))
    |> put("uptime", Maxio.Application.uptime_seconds())
    |> put("version", version())
    |> put("num_cpu", num_cpu(opts))
    |> put("runtime_version", "Elixir #{System.version()} / OTP #{System.otp_release()}")
    |> put("mem_stats", mem_stats())
    |> put("drives", snapshot.drives)

    # commitID：maxio 无 build 期 git sha 注入 → omit。
    # network：Maxio.Cluster.nodes/0 是 BEAM mesh 视图，不是 HTTP peer 探活，口径不同 → omit。
    # go_max_procs / minio_env_vars / edition / license / is_leader：maxio 无对应概念 → omit。
  end

  # Go 的 MemStats 里只有 Alloc（"已分配且仍在使用的字节数"）在 BEAM 有同口径对应物
  # （:erlang.memory(:total)）。mallocs / frees / total_alloc 是累计计数器，BEAM 不维护；
  # heap_alloc 的堆语义也与 BEAM 的进程/二进制/ETS 分区不可比。不可比就不填同名字段。
  # VERIFY-AT-IMPL V-A16 / V-A17：`InfoMessage` 与 `MemStats` 在 madmin **v3** 的逐字段
  # json tag 未逐条读源码核实（本文件的字段名取自设计文档 + 真实 mc RELEASE.2025-08-13 的
  # 活体解码验证：mc 能把本响应解码并渲染出 usage / uptime / version）。缺失字段在 Go 侧
  # 取零值，故 omit 对 madmin 安全；但"我们发的键名逐字正确"仍以源码核实为准。
  defp mem_stats, do: %{"alloc" => :erlang.memory(:total)}

  # `:erlang.system_info(:logical_processors)` 在判定不出 CPU 拓扑的平台上返回**原子**
  # `:unknown`，Jason 会把它编码成 JSON **字符串** `"unknown"`；而 madmin 的
  # `ServerProperties.NumCPU` 是 `int`，于是 `json.Decode` 不是"少一个字段"，而是**整体**报错
  # ——`mc admin info` 完全失败。omit 才是这里唯一诚实且安全的答案（与本模块 put/3 的
  # nil-omit 纪律一致）：没测出来就别说，缺失字段在 Go 侧取零值，不会毒死整个解码。
  defp num_cpu(opts) do
    fun =
      Keyword.get(opts, :logical_processors_fun, fn ->
        :erlang.system_info(:logical_processors)
      end)

    case fun.() do
      count when is_integer(count) -> count
      _unknown -> nil
    end
  end

  defp version do
    case Application.spec(:maxio, :vsn) do
      nil -> nil
      vsn -> to_string(vsn)
    end
  end

  defp domain(s3) do
    case presence(s3[:domain]) do
      nil -> nil
      domain -> [domain]
    end
  end

  # HTTP 路径传请求真实到达的 host（这是本节点确实被访问到的地址，最诚实的取值）；
  # CLI 路径没有请求，回落 S3 寻址根域名——刻意不用 MaxioWeb.Endpoint 的 url.host，
  # 那是 Console 的监听点，混用会让 ServerInfo 报出一个根本不服务 S3 的地址。
  defp endpoint(opts) do
    host = Keyword.get(opts, :host) || Application.get_env(:maxio, :s3, [])[:domain]
    port = Application.get_env(:maxio, Maxio.S3.Endpoint, [])[:port]

    case {presence(host), port} do
      {nil, _port} -> nil
      {host, nil} -> host
      {host, port} -> "#{host}:#{port}"
    end
  end

  defp scheme(opts) do
    case Keyword.get(opts, :scheme) do
      nil -> "http"
      scheme -> to_string(scheme)
    end
  end

  defp deployment_id(opts) do
    case DeploymentId.get_or_create(Keyword.take(opts, [:repo])) do
      {:ok, id} ->
        id

      {:error, reason} ->
        # 拿不到就 omit，绝不临时编一个：同一集群在不同请求里报出不同 deploymentID
        # 比缺这个字段有害得多（监控会把它当成两套部署）。
        Log.error("deployment id unavailable for ServerInfo; field omitted",
          action: "admin_server_info",
          code: "DeploymentIdUnavailable",
          reason: inspect(reason)
        )

        nil
    end
  end

  # ── 采集（可缓存的昂贵部分）──────────────────────────────────────────────

  defp cached(opts) do
    ttl = cache_ttl_ms()
    now = System.monotonic_time(:millisecond)

    case :persistent_term.get(@pt_cache, nil) do
      %{at_ms: at, snapshot: snapshot} when is_integer(at) and now - at < ttl ->
        snapshot

      _stale ->
        snapshot = collect(opts)
        :persistent_term.put(@pt_cache, %{at_ms: now, snapshot: snapshot})
        snapshot
    end
  end

  defp collect(opts) do
    usage = Prometheus.usage_stats(Keyword.take(opts, [:repo]))
    layout = layout(opts)

    %{
      usage: usage,
      backend_type: layout.backend_type,
      online_disks: layout.online,
      offline_disks: layout.offline,
      parity_shards: layout.parity_shards,
      total_sets: layout.total_sets,
      drives_per_set: layout.drives_per_set,
      drives: layout.drives
    }
  end

  # ── 存储布局的三种真实形态 ────────────────────────────────────────────────
  #
  # 1. 有拓扑（分布式）：盘来自 Topology；本节点只报**本地**盘（servers[] 只有本节点），
  #    但 online/offline 计数是集群级的——这与 MinIO 的语义一致。
  # 2. 单机纠删码（无拓扑）：盘来自 config :maxio, :erasure。
  # 3. FS：合成**一个** drive 条目指向 data_dir。这不是伪造——那确实就是 maxio 在 FS
  #    模式下唯一的真实存储位置（Storage.FS 的 Scanner 用的是同一手法）。
  defp layout(opts) do
    case topology(opts) do
      {:ok, topology} -> topology_layout(topology, opts)
      :no_topology -> local_layout(opts)
    end
  end

  defp topology_layout(topology, opts) do
    set_ids = Topology.all_set_ids_from(topology)
    endpoints = Enum.flat_map(set_ids, &Topology.endpoints_from(topology, &1))
    states = Map.new(endpoints, &{&1, drive_state(&1, opts)})

    local_endpoints = Enum.filter(endpoints, fn {node, _drive} -> node == Node.self() end)
    pool_ids = Topology.pool_ids_from(topology)
    counts = count_states(Map.values(states))

    %{
      backend_type: "Erasure",
      online: counts.online,
      offline: counts.offline,
      parity_shards: Keyword.get(Topology.ec_params_from(topology), :parity_shards),
      total_sets: Enum.map(pool_ids, &length(Topology.set_ids_for_pool_from(topology, &1))),
      drives_per_set: Enum.map(pool_ids, &drives_per_set(topology, &1)),
      drives:
        Enum.map(local_endpoints, fn {_node, drive} = endpoint ->
          drive_entry(drive, Map.fetch!(states, endpoint), opts)
        end)
    }
  end

  defp drives_per_set(topology, pool_id) do
    case Topology.set_ids_for_pool_from(topology, pool_id) do
      [set_id | _rest] -> length(Topology.endpoints_from(topology, set_id))
      [] -> 0
    end
  end

  defp local_layout(opts) do
    case Application.fetch_env!(:maxio, :storage_backend) do
      Maxio.Storage.FS -> fs_layout(opts)
      _erasure_backend -> single_node_erasure_layout(opts)
    end
  end

  defp fs_layout(opts) do
    data_dir = Application.fetch_env!(:maxio, :s3)[:data_dir]
    state = drive_state({Node.self(), data_dir}, opts)
    counts = count_states([state])

    %{
      backend_type: "FS",
      online: counts.online,
      offline: counts.offline,
      # FS 没有 parity 概念。填 0 会被读成 EC 语义下的"零冗余"——那是在回答一个
      # maxio 根本没被问到的问题。
      parity_shards: nil,
      total_sets: nil,
      drives_per_set: nil,
      drives: [drive_entry(data_dir, state, opts)]
    }
  end

  defp single_node_erasure_layout(opts) do
    config = Erasure.Config.load!()
    states = Enum.map(config.drives, &{&1, drive_state({Node.self(), &1}, opts)})
    counts = count_states(Enum.map(states, &elem(&1, 1)))

    %{
      backend_type: "Erasure",
      online: counts.online,
      offline: counts.offline,
      parity_shards: config.parity_shards,
      total_sets: nil,
      drives_per_set: nil,
      drives: Enum.map(states, fn {drive, state} -> drive_entry(drive, state, opts) end)
    }
  end

  # VERIFY-AT-IMPL V-A9：MinIO `Disk.state` 的合法取值串集合未核实（需读 madmin 常量）。
  # maxio 的 DriveHealth 是**三态**（online / suspect / offline），因此只用两个已确定的串，
  # 且 :suspect 保守归入
  # "offline"——把一块可疑盘报成 ok 会让运维以为冗余完好，那是最危险的方向。
  #
  # 第三种情况是 `nil`：**健康登记处根本没在跑**。`mix maxio.admin.info` 就在这种进程里
  # （Mix 任务只起 Repo，不起 supervision tree），此前它会以 GenServer.call no-process 崩掉。
  # 崩掉不可接受——这个 CLI 存在的意义正是"mc 报错时还能取证"；但更不可接受的是替它编一个
  # 答案：报 "ok" 是宣称观测到健康（没观测），报 "offline" 是宣称观测到故障（也没观测），
  # 两个方向都是伪造。于是返回 nil → `state` 键连同 onlineDisks/offlineDisks 一起 omit，
  # 语义正是"这台机器上没有这块盘的健康读数"。
  defp drive_state(endpoint, opts) do
    case drive_health_status(endpoint, opts) do
      {:ok, :online} -> "ok"
      {:ok, _suspect_or_offline} -> "offline"
      :unavailable -> nil
    end
  end

  defp drive_health_status(endpoint, opts) do
    case Keyword.get(opts, :drive_health_fun) do
      nil -> default_drive_health_status(endpoint)
      fun when is_function(fun, 1) -> fun.(endpoint)
    end
  end

  defp default_drive_health_status(endpoint) do
    if Process.whereis(DriveHealth) do
      {:ok, DriveHealth.status(endpoint).status}
    else
      Log.warn(
        "drive health registry is not running; ServerInfo omits drives[].state and " <>
          "backend.onlineDisks/offlineDisks instead of inventing a verdict. This is expected " <>
          "for `mix maxio.admin.info` (Mix tasks start Repo, not the supervision tree) and is " <>
          "a real problem anywhere else.",
        action: "admin_server_info",
        code: "DriveHealthRegistryUnavailable",
        reason: "drive_health_not_running"
      )

      :unavailable
    end
  end

  # 有任何一块盘读不到健康状态，整个 online/offline 计数就不可信——报一个"少数了一块盘"的
  # 数字比不报更糟（运维会拿它当冗余度用）。故一律 omit，不做部分统计。
  defp count_states(states) do
    if Enum.any?(states, &is_nil/1) do
      %{online: nil, offline: nil}
    else
      %{
        online: Enum.count(states, &(&1 == "ok")),
        offline: Enum.count(states, &(&1 != "ok"))
      }
    end
  end

  defp drive_entry(drive_path, state, opts) do
    %{}
    |> put("endpoint", drive_path)
    |> put("path", drive_path)
    |> put("state", state)
    |> put("uuid", drive_uuid(drive_path))
    |> merge_space(drive_path, opts)

    # uuid：DriveIdentity 的 marker 只写在纠删/分布式盘上；FS 模式没有记录 → omit。
    # VERIFY-AT-IMPL V-A10：maxio 的 DriveIO 计数器口径与 MinIO `Disk.readthroughput` 等
    #   是否可比未核实。不可比的数字绝不复用同名字段 → 一律 omit。
    # major / minor / used_inodes / free_inodes / model / pool_index / set_index / disk_index：
    #   maxio 无来源 → omit。
  end

  # 盘的软件身份标记（DriveIdentity）。没有记录就 omit，绝不合成一个 uuid——
  # 一个编出来的盘 id 会让"同路径换盘"检测在下游彻底失效。
  defp drive_uuid(drive_path) do
    case Maxio.Cluster.DriveIdentity.status({Node.self(), drive_path}) do
      {:ok, %{drive_uuid: uuid}} -> uuid
      {:error, :not_found} -> nil
    end
  rescue
    _e -> nil
  catch
    _kind, _reason -> nil
  end

  defp merge_space(entry, drive_path, opts) do
    case DriveStats.local(drive_path, Keyword.take(opts, [:provider])) do
      {:ok, sample} ->
        entry
        |> put("totalspace", sample.capacity_bytes)
        |> put("usedspace", sample.used_bytes)
        |> put("availspace", sample.free_bytes)

      {:error, _reason} ->
        # 采不到容量就不报容量。填 0 会让"这块盘满了"和"我们没测到"变得无法区分。
        entry
    end
  end

  defp topology(opts) do
    case Keyword.fetch(opts, :topology) do
      {:ok, :no_topology} -> :no_topology
      {:ok, topology} when is_map(topology) -> {:ok, topology}
      :error -> runtime_topology()
    end
  end

  defp runtime_topology do
    case Topology.current() do
      {:ok, topology} -> {:ok, topology}
      {:error, :no_topology} -> :no_topology
    end
  end

  defp cache_ttl_ms do
    :maxio
    |> Application.get_env(:admin_server_info, [])
    |> Keyword.get(:cache_ttl_ms, @default_cache_ttl_ms)
  end

  # omit 的唯一实现点：值为 nil 就不放键。整个响应里绝不出现 null 值的键。
  defp put(map, _key, nil), do: map
  defp put(map, key, value), do: Map.put(map, key, value)

  defp presence(value) when is_binary(value) and value != "", do: value
  defp presence(_other), do: nil
end
