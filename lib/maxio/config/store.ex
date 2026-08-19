defmodule Maxio.Config.Store do
  @moduledoc """
  运行时配置的**节点本地快照**：把 `runtime_configs` 全量物化进 `:persistent_term`，
  让读路径永不打 DB（设计 D2）。

  ## 为什么读必须是 `:persistent_term`

  被纳入白名单的键里有 S3 请求**每请求都读**的项（`s3.clock_skew_ms` 每次验签、
  `listing.sql_hard_limit` 每次 LIST）。Application env 本身就是 `:persistent_term` 支撑的
  O(1) 无锁读；任何"改成 DB 支撑"的方案都必须保住同一量级，绝不允许退化成每请求一次
  `Repo` 查询。per-subsystem 一个 term 让一次写只让一个 term 参与全局 GC，把
  `:persistent_term` 的写代价限制在低频写路径上。

  ## 为什么 DB 查询跑在**调用方进程**里

  `load_all!/1` / `reconcile!/1` 都是普通函数，在调用者进程里执行查询、再写
  `:persistent_term`。GenServer 只负责两件事：订阅失效广播、跑周期对账定时器。
  这样：

    * 写路径（`Maxio.Config.set/4`）提交事务后**同步**重装本节点快照，本节点的正确性
      完全不依赖广播送达；
    * CLI（`mix maxio.config.*`）在没有 Store 进程的 Mix 环境里照样能用同一套函数；
    * 测试可以在 sandbox 拥有的进程里直接调用，无需为 GenServer 单独授权连接。

  ## 广播是快路径，周期对账是**兜底**（D5）

  `Maxio.Cluster.Notify.broadcast/1` 自陈 best-effort：PubSub 未起时它静默返回 `:ok`。
  也就是说广播**不保证送达**。只靠广播的话，一次丢失就会让某节点长期用旧配置——这正是
  "静默失败"。因此本模块每 `refresh_interval_ms` 拉一次 PG 的**内容指纹**与本地快照比对；
  不一致就整体重载，并打结构化 warning（丢广播必须**可见**）。
  最坏情况从"永久分歧"收敛成"最多落后一个周期"。

  ## 为什么指纹必须是**内容摘要**，而不是"行数 + 版本和"

  第一版对账用 `(行数, 版本和)` 判断是否落后。那是个**会碰撞**的判据，而碰撞的后果不是
  "晚一个周期"，是**永久**看不见分歧：`reset` 掉一个 v1 的键 + 首次 `set` 另一个键，
  行数与版本和逐字不变，于是本节点会一直报出 PG 里早已不存在的值（活体复现：
  `{cluster.deployment_id v2}` 变成 `{listing.sql_hard_limit v2}` 后，`mc admin info` 22 秒
  仍报旧 deploymentID，一条 drift warning 都不打）。这种形态一点都不刁钻，而且
  `Cluster.Notify` 眼下只是节点本地传输（V-C2），跨节点唯一的收敛通路就是这次对账——
  漏判即等于设计承诺作废。

  故指纹改成整表内容摘要 `md5(string_agg(subsystem/key/version/md5(value)))`：它是**被比较的
  那张表本身**的函数，代价仍是一次廉价聚合查询。覆盖范围如实说清楚——任何一行的**增、删，
  以及对 `subsystem` / `key` / `value` / `version` 四列的修改**都会改变它；`apply_mode` /
  `source` / `updated_by` / `previous_value` / 时间戳的变化**不会**，因为它们既不参与快照
  物化也不改变任何键的生效值，装不装载它们都一样（`md5` 的碰撞概率同样不在承诺之内）。

  ## 摘要里必须**含 value**——因为版本号会被**复用**

  只摘 `subsystem/key/version` 是不够的，而且漏判**不需要任何"直接改库"**：`Maxio.Config`
  的 `reset` 是**删行**（`repo.delete!/1`），`set` 又是 `if current, do: version + 1, else: 1`
  —— 于是版本号会回到 1：

      mix maxio.config.set   listing sql_hard_limit 111   # → v1
      （本节点丢广播）
      mix maxio.config.reset listing sql_hard_limit       # 删行
      mix maxio.config.set   listing sql_hard_limit 999   # → 又是 v1

  `(subsystem, key, version)` 三元组逐字不变 ⇒ 老摘要恒等 ⇒ `drifted?/1` 永远是 `false`，
  本节点永远报 111 而 PG 里是 999。这是纯门面操作造出的**永久**静默分歧，正是铁律 3 禁止的。
  （活体形态：改 value 不动 version，5.5 分钟 18 次对账、0 条 drift warning，`mc admin info`
  报的 deploymentID 与 PG 完全不同。）

  `value` 是 `jsonb`，`::text` 是**规范化**表示（键排序、空白归一），所以同一逻辑值的不同书写
  形式给出同一摘要，不会引入假漂移；套一层 `md5()` 只是把聚合中间串的长度锚成定长，与判据
  强度无关。真出现假漂移（比如有人手写 `1.00` 这种保留标度的 numeric）后果也只是**多重载
  一次**——那个方向是自愈的，与漏判不对称。

  刻意**不**用"全局单调 config epoch"：epoch 是写路径的旁路计数器，只反映"经门面发生过的
  写"。而对账要防的恰恰是快照与 PG **实际内容**分歧——直接改库、回滚恢复、手工修数据都
  不会动 epoch，那些场景下 epoch 会一直说"没变"。用旁路计数器给权威内容背书，等于把一个
  能被绕过的判据当成完整性证据。

  ## 指纹只有**一处**定义（SQL），且**先取指纹再取行**

  `authoritative_aggregate/1` 是指纹的唯一实现。刻意不在 Elixir 侧再算一份"本地指纹"：
  两份自称权威的实现只会在排序规则（DB collation vs 字节序）或整数格式化上悄悄分叉——
  这与 `Maxio.Config.Schema` 拒绝重写一份默认值是同一条纪律。

  于是 `load_all!/1` 记录的指纹来自另一次查询，两次查询之间可能有别的节点提交。顺序因此是
  **先查指纹、后查行**，不能反过来：

    * 先指纹后行 → 中间的提交让**记录的指纹比快照旧** → 下个周期判为漂移 → 多重载一次（收敛）；
    * 先行后指纹 → 中间的提交让**记录的指纹比快照新** → 对账永远满意，而快照里是旧值——
      正是本节这一整段要消灭的静默失败。

  ## 为什么**没有**"只重装一个子系统"的装载器

  曾经有过 `load_subsystem!/2`：写路径与广播路径只重装那一个子系统，理由是"避免误判漂移 +
  无谓整体重载"。但它取的是**整表**指纹、装的是**一个**子系统的行，于是把"我核对过整张表"
  这句话记进了 meta，而它根本没读过其余的行。后果是**兜底对账被永久关掉**，且全程走正常路径：

      t1  丢 listing 广播                    → drifted? = true（对账本该救场）
      t2  收到 s3 广播 → 只重装 s3，却记下整表指纹 → drifted? = false（漂移证据被抹掉）
      t3  周期对账 reloaded? = false          → listing 永远停在旧值

  这个权衡做反了：多重载一次是廉价且自愈的，而"指纹被误记成已核对"是**永久**静默失败。

  修法不是"广播路径改走 `load_all!/1`"——那只是把同一个 bug 挪到写路径（节点 A 为 `s3`
  写入时，同样会把别人刚提交、自己没读过的 `listing` 记成已核对）。根因是"存在一个能记录
  比自己实际装载范围更宽的断言的装载器"，所以**装载器只剩一个**：任何重载都是整体重载，
  `meta().aggregate` 于是**结构上**恒等于"本快照物化自的那次整表状态"，不再是一条纪律。

  整体重载的代价被两件事摁住：白名单是编译期数据结构（表行数上界 = 白名单键数），以及
  **等值写不触发全局 GC**——一次只改一个子系统的写入，仍然只让一个子系统 term 参与全局 GC
  （V-C1 的代价论证因此原样成立）。后半句的功劳要如实记给 **ERTS 自己**：
  `:persistent_term.put/2` 在新值与旧值相同时本就直接返回、不做 GC（实测 OTP 29、200 个
  持大堆进程：300 次等值 put 102 µs，300 次异值 put 302 182 µs，约 3000×）。本模块的
  `put_term/2` 与这条运行时行为**完全重合**，它只是把这条依赖写在明处，并不是它创造了
  这个约束。

  ## 启动期严格性（§5）

    * PG 里有**白名单外**的 orphan 键 → 忽略该行 + `Log.error` + 在
      `mix maxio.config.status` 里报出来（这只是版本漂移，不是完整性问题）；
    * PG 里**白名单内**的键值无法按 Schema 解码 → `raise Maxio.Config.CorruptValueError`
      （写路径校验被绕过了，绝不静默替换成默认值继续跑）；
    * PG 不可达 → 结构化 error + 空快照 + 下一个周期重试。配置存储绝不能成为
      "节点起不来"的新原因（与 `Maxio.S3.ReservedBucketAudit` 的启动期取舍一致），
      而空快照的语义恰好就是"全部回落 Application env"，即改造前的行为。
  """

  use GenServer

  import Ecto.Query

  alias Maxio.Config.{CorruptValueError, RuntimeConfig, Schema}
  alias Maxio.Cluster.Notify
  alias Maxio.S3.Log

  @pt_namespace Maxio.Config
  @pt_meta {Maxio.Config, :__meta__}
  @pt_subsystems {Maxio.Config, :__subsystems__}

  # VERIFY-AT-IMPL V-C1：per-subsystem 大 term 写入触发的 :persistent_term 全局 GC 代价，
  # 在 maxio 的实际负载下是否可接受，尚未基准测试（需在高并发 S3 读写下做一次配置变更、
  # 测 p99 抖动）。当前设计把写限制在低频路径上，但这不是"已量化"，只是"已限制"。
  # VERIFY-AT-IMPL V-C2：Phoenix.PubSub 在 maxio 当前的 libcluster 配置下是否**真能跨节点**
  # 送达未实测（Cluster.Notify 的 moduledoc 自陈 M8 只是本地 transport）。正因为如此，
  # 下面的周期对账不是可选优化而是正确性兜底；若多节点实测不达标，升级路径是 PG
  # LISTEN/NOTIFY（V-C3，Postgrex 支持度亦未核实）。
  @default_refresh_interval_ms 30_000
  @stale_cycles_before_alarm 3

  @type aggregate :: %{
          count: non_neg_integer(),
          version_sum: non_neg_integer(),
          digest: String.t() | nil
        }

  # ── 快照读（热路径）────────────────────────────────────────────────────────

  @doc "读本节点快照里的某个键。未命中即 `:error`（调用方回落 Application env）。"
  @spec lookup(atom(), atom()) :: {:ok, term()} | :error
  def lookup(subsystem, key) do
    case :persistent_term.get({@pt_namespace, subsystem}, nil) do
      nil -> :error
      map -> Map.fetch(map, key)
    end
  end

  @doc "本节点快照里某个子系统的全部覆盖值。"
  @spec snapshot(atom()) :: %{atom() => term()}
  def snapshot(subsystem), do: :persistent_term.get({@pt_namespace, subsystem}, %{})

  @doc """
  本节点快照的元信息：内容指纹、装载时间、上次重载原因。

  从未装载过时 `digest` 是 `nil`——那不是"指纹为空"，是"本节点还没有指纹可比"。写成
  `md5("")`（空表的指纹）会让一个从未读过 PG 的节点自称与空库一致；真要是空库，第一次
  对账重载一次就收敛了，多这一次远比冒充"已核对过"便宜。
  """
  @spec meta() :: map()
  def meta do
    :persistent_term.get(@pt_meta, %{
      aggregate: %{count: 0, version_sum: 0, digest: nil},
      loaded_at: nil,
      last_reload_reason: :never_loaded,
      orphan_config_keys: []
    })
  end

  @doc "本节点快照当前持有覆盖值的子系统。"
  @spec loaded_subsystems() :: [atom()]
  def loaded_subsystems, do: :persistent_term.get(@pt_subsystems, [])

  # ── 快照写（低频）──────────────────────────────────────────────────────────

  @doc """
  从 PG 全量重装本节点快照。白名单内值无法解码即 raise（fail-fast）。

  返回 `%{aggregate:, orphan_config_keys:, subsystems:}`。
  """
  @spec load_all!(keyword()) :: map()
  def load_all!(opts \\ []) do
    repo = repo(opts)

    # 先指纹、后行（见 moduledoc「指纹只有一处定义」）：反过来会把并发提交记成"已核对"。
    aggregate = authoritative_aggregate(opts)
    rows = repo.all(from r in RuntimeConfig, order_by: [asc: r.subsystem, asc: r.key])

    {by_subsystem, orphans} = materialize(rows)

    previous = loaded_subsystems()
    Enum.each(previous -- Map.keys(by_subsystem), &:persistent_term.erase({@pt_namespace, &1}))
    Enum.each(by_subsystem, fn {subsystem, map} -> put_subsystem(subsystem, map) end)
    put_term(@pt_subsystems, Map.keys(by_subsystem))

    put_meta(%{
      aggregate: aggregate,
      loaded_at: DateTime.utc_now(),
      last_reload_reason: Keyword.get(opts, :reason, :load_all),
      orphan_config_keys: orphans
    })

    report_orphans(orphans)

    %{aggregate: aggregate, orphan_config_keys: orphans, subsystems: map_size(by_subsystem)}
  end

  @doc """
  清空本节点快照（全部键回落 Application env）。

  给测试与 IEx 应急用（回到"只认 Application env"的已知状态，再 `load_all!/1` 重装）。
  刻意**不**给它一个 CLI 开关：Mix 任务每次都在自己的进程里从 PG 重新装载快照，
  "清掉再装"在那里是个无意义的动作；而对**正在服务请求的节点**，清快照等于让它悄悄
  回退到 env 值——那种事必须是有意为之的 IEx 操作，不能是一个顺手敲的 flag。
  """
  @spec reset_local!() :: :ok
  def reset_local! do
    Enum.each(loaded_subsystems(), &:persistent_term.erase({@pt_namespace, &1}))
    :persistent_term.erase(@pt_subsystems)
    :persistent_term.erase(@pt_meta)
    :ok
  end

  # ── 对账（周期兜底 / CLI 取证）────────────────────────────────────────────

  @doc """
  PG 权威侧的**内容指纹**：行数 + 版本和 + 整表内容摘要。

  判据是 `digest`——`(行数, 版本和)` 会碰撞（删一行 + 插一行即恒等），而碰撞在这里的后果是
  永久漏判（见 moduledoc）。另两个数字纯粹是取证可读性：运维在 `mix maxio.config.status`
  里先看 count/sum 建立直觉，指纹负责判定。

  摘要的每行 fragment 是 `subsystem/key/version/md5(value)`。**`value` 不能省**：`reset` 删行
  让版本号复用（下一次 `set` 又是 v1），少了 value 的话"set → reset → set 成别的值"这套纯
  门面操作会让摘要逐字不变（见 moduledoc「摘要里必须含 value」）。

  `COLLATE "C"` 不是装饰：`string_agg` 的 `ORDER BY` 若走 DB 默认 collation，同一份数据在
  不同 locale 的实例上会算出不同指纹（下划线在 `en_US.UTF-8` 下的权重与字节序不同）。
  锚死字节序，指纹才是"内容的函数"而不是"内容与 locale 的函数"。
  """
  @spec authoritative_aggregate(keyword()) :: aggregate()
  def authoritative_aggregate(opts \\ []) do
    repo = repo(opts)

    %{count: count, version_sum: sum, digest: digest} =
      repo.one(
        from r in RuntimeConfig,
          select: %{
            count: count(r.id),
            version_sum: coalesce(sum(r.version), 0),
            # fragment 的第一个参数必须是**字面量**（Ecto 的 SQL 注入防线），不能拼接。
            digest:
              fragment(
                "md5(coalesce(string_agg(? || '/' || ? || '/' || ?::text || '/' || md5(?::text), ',' ORDER BY ? COLLATE \"C\", ? COLLATE \"C\"), ''))",
                r.subsystem,
                r.key,
                r.version,
                r.value,
                r.subsystem,
                r.key
              )
          }
      )

    %{count: count, version_sum: sum, digest: digest}
  end

  @doc "本节点快照与 PG 权威是否漂移（丢广播的直接证据）。"
  @spec drifted?(keyword()) :: boolean()
  def drifted?(opts \\ []), do: meta().aggregate != authoritative_aggregate(opts)

  @doc """
  一次对账：内容指纹不一致就整体重载。返回 `%{reloaded?:, local:, authoritative:}`。
  """
  @spec reconcile!(keyword()) :: map()
  def reconcile!(opts \\ []) do
    local = meta().aggregate
    authoritative = authoritative_aggregate(opts)

    if local == authoritative do
      %{reloaded?: false, local: local, authoritative: authoritative}
    else
      Log.warn(
        "runtime config snapshot drifted from Postgres; reloading. A drift here means an " <>
          "invalidation broadcast was lost (Cluster.Notify is best-effort), not that the " <>
          "config is wrong — the periodic reconcile is exactly the backstop for that.",
        action: "config_reconcile",
        reason: "config_snapshot_drift",
        config_version: authoritative.version_sum,
        config_digest: authoritative.digest,
        # `nil`（从未装载过）必须落成显式占位串：Logger 的 metadata 渲染会把 nil 值的键
        # 整个丢掉，于是**第一次**漂移的日志正好缺掉"本地指纹"那一半——而那一半恰恰是
        # 区分"丢广播"与"本节点从没装载成功过"的唯一线索。
        config_local_digest: local.digest || "never_loaded"
      )

      load_all!(Keyword.put(opts, :reason, :reconcile))
      %{reloaded?: true, local: local, authoritative: authoritative}
    end
  end

  @doc "本节点配置面的完整取证视图（`mix maxio.config.status` / ServerInfo 健康视图用）。"
  @spec status(keyword()) :: map()
  def status(opts \\ []) do
    local = meta()

    {authoritative, unreachable} =
      try do
        {authoritative_aggregate(opts), nil}
      rescue
        e -> {nil, Exception.message(e)}
      catch
        kind, reason -> {nil, Exception.format(kind, reason, [])}
      end

    %{
      node: to_string(Node.self()),
      local: local.aggregate,
      loaded_at: local.loaded_at,
      last_reload_reason: local.last_reload_reason,
      orphan_config_keys: local.orphan_config_keys,
      authoritative: authoritative,
      store_unavailable_reason: unreachable,
      drifted: authoritative != nil and authoritative != local.aggregate
    }
  end

  # ── GenServer：订阅广播 + 周期对账 ─────────────────────────────────────────

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(opts) do
    state = %{
      refresh_interval_ms: Keyword.get(opts, :refresh_interval_ms, refresh_interval_ms()),
      load_on_boot: Keyword.get(opts, :load_on_boot, load_on_boot?()),
      subscribe: Keyword.get(opts, :subscribe, subscribe?()),
      repo: Keyword.get(opts, :repo, Maxio.Repo),
      stale_cycles: 0
    }

    {:ok, state, {:continue, :boot}}
  end

  @impl true
  def handle_continue(:boot, state) do
    if state.subscribe, do: subscribe()

    state =
      if state.load_on_boot do
        guarded_reload(state, fn -> load_all!(repo: state.repo, reason: :boot) end, "boot")
      else
        state
      end

    {:noreply, schedule_refresh(state)}
  end

  # 广播只带"哪个键变了"，但重装的是**整张表**：广播是 best-effort，收到一条不等于没漏另一条。
  # 只重装被点名的子系统，就会把"整表已核对"记进 meta 而实际没读过其余的行——一次丢广播 +
  # 一次任意其它子系统的广播即可永久关掉兜底对账（见 moduledoc「为什么没有只重装一个子系统
  # 的装载器」）。subsystem/key 只进 reason，供 `mix maxio.config.status` 取证。
  @impl true
  def handle_info({:config_changed, subsystem, key}, state) when is_atom(subsystem) do
    state =
      guarded_reload(
        state,
        fn -> load_all!(repo: state.repo, reason: {:broadcast, subsystem, key}) end,
        "broadcast"
      )

    {:noreply, state}
  end

  def handle_info(:refresh, state) do
    state =
      guarded_reload(state, fn -> reconcile!(repo: state.repo) end, "periodic reconcile")

    {:noreply, schedule_refresh(state)}
  end

  def handle_info(_message, state), do: {:noreply, state}

  # 重载失败不能让 Store 崩掉（崩掉 = 丢定时器 = 再也不对账了），但**连续**失败必须
  # 升级成 error 级告警：那说明这个节点已经在用一份可能过期的配置服务请求。
  defp guarded_reload(state, fun, phase) do
    fun.()
    %{state | stale_cycles: 0}
  rescue
    # 完整性问题绝不降级成一条 warning。CorruptValueError 说明写路径校验被绕过了，
    # 此时"继续用旧快照跑下去"会让一个被篡改过的配置面看起来完全健康（§5 明确要求
    # fail-fast）。原样上抛 → Store 崩 → supervisor 重启 → 启动失败，运维立刻看见。
    err in CorruptValueError ->
      reraise err, __STACKTRACE__

    e ->
      note_reload_failure(state, phase, Exception.format(:error, e, __STACKTRACE__))
  catch
    kind, reason -> note_reload_failure(state, phase, Exception.format(kind, reason, []))
  end

  defp note_reload_failure(state, phase, formatted) do
    stale = state.stale_cycles + 1

    message =
      "runtime config snapshot reload failed during #{phase}; this node keeps serving with the " <>
        "previously loaded snapshot (empty snapshot = plain Application env behaviour)"

    fields = [
      action: "config_reload_failed",
      reason: formatted,
      code: "ConfigStoreUnavailable"
    ]

    if stale >= @stale_cycles_before_alarm do
      Log.error(message <> "; #{stale} consecutive failures", fields)
    else
      Log.warn(message, fields)
    end

    %{state | stale_cycles: stale}
  end

  defp schedule_refresh(%{refresh_interval_ms: ms} = state) when is_integer(ms) and ms > 0 do
    Process.send_after(self(), :refresh, ms)
    state
  end

  defp schedule_refresh(state), do: state

  defp subscribe do
    if Process.whereis(Maxio.PubSub) do
      Phoenix.PubSub.subscribe(Maxio.PubSub, Notify.topic())
    end

    :ok
  catch
    :exit, _ -> :ok
  end

  # ── 内部 ───────────────────────────────────────────────────────────────────

  defp materialize(rows) do
    Enum.reduce(rows, {%{}, []}, fn row, {acc, orphans} ->
      # to_existing_atom（不是 to_atom）：一行被手改过的 runtime_configs 绝不能成为
      # 无界 atom 注入面。白名单里的名字在编译期就已存在，所以合法键永远解得开；
      # 解不开的一律走 orphan 通路（忽略 + 告警 + status 报出），语义与"白名单外的键"一致。
      case existing_key(row) do
        {:ok, subsystem, key} -> put_or_orphan(acc, orphans, row, subsystem, key)
        :error -> {acc, [{row.subsystem, row.key} | orphans]}
      end
    end)
    |> then(fn {acc, orphans} -> {acc, Enum.reverse(orphans)} end)
  end

  defp existing_key(row) do
    {:ok, String.to_existing_atom(row.subsystem), String.to_existing_atom(row.key)}
  rescue
    ArgumentError -> :error
  end

  defp put_or_orphan(acc, orphans, row, subsystem, key) do
    case Schema.fetch(subsystem, key) do
      {:ok, _entry} ->
        case Schema.decode_stored(subsystem, key, row.value) do
          {:ok, value} ->
            {Map.update(acc, subsystem, %{key => value}, &Map.put(&1, key, value)), orphans}

          {:error, reason} ->
            raise CorruptValueError, subsystem: subsystem, key: key, reason: reason
        end

      {:error, _reason} ->
        {acc, [{subsystem, key} | orphans]}
    end
  end

  defp report_orphans([]), do: :ok

  defp report_orphans(orphans) do
    Enum.each(orphans, fn {subsystem, key} ->
      Log.error(
        "runtime config key is not in Maxio.Config.Schema; the stored override is IGNORED. " <>
          "This usually means the node was rolled back to a binary that no longer knows this " <>
          "key. Nothing silently falls back — the key is reported by mix maxio.config.status.",
        action: "config_orphan_key",
        reason: "config_key_not_in_schema",
        code: "OrphanConfigKey",
        resource: "#{subsystem}.#{key}"
      )
    end)
  end

  # 整体重载里绝大多数子系统的 map 是逐字不变的，而 `:persistent_term.put/2` 的**真**写要触发
  # 一次全局 GC（扫所有进程）。"改一个子系统 = 一次子系统 term 写"这条代价约束（V-C1）因此
  # 成立——但它成立**不是**因为下面这段代码：见 `put_term/2`。
  defp put_subsystem(subsystem, map) when map != %{} do
    put_term({@pt_namespace, subsystem}, map)
  end

  defp put_subsystem(subsystem, _empty), do: :persistent_term.erase({@pt_namespace, subsystem})

  # 与 **ERTS 自身的等值跳过完全重合**，本函数只是把这条依赖写在明处。
  # `:persistent_term.put/2` 在新值与旧值相同时本就直接返回、不做全局 GC（实测 OTP 29、
  # 200 个持大堆进程：300 次等值 put 102 µs，300 次异值 put 302 182 µs，约 3000×），且它用的是
  # **精确相等**（`put 1` 之后 `put 1.0`，`get` 得 `1.0`），与这里的 `===` 同语义。
  # 保留它的价值是文档性的：代价论证依赖的是一条 ERTS 行为，写在明处才能被审查、被定位——
  # 若哪天那条行为变了，只改这一个函数即可，不必重读整个装载器。
  defp put_term(key, value) do
    if :persistent_term.get(key, :"$maxio_absent") === value do
      false
    else
      :persistent_term.put(key, value)
    end
  end

  defp put_meta(meta), do: :persistent_term.put(@pt_meta, meta)

  defp repo(opts), do: Keyword.get(opts, :repo, Maxio.Repo)

  defp store_config, do: Application.get_env(:maxio, __MODULE__, [])

  defp refresh_interval_ms do
    Keyword.get(store_config(), :refresh_interval_ms, @default_refresh_interval_ms)
  end

  defp load_on_boot?, do: Keyword.get(store_config(), :load_on_boot, true)

  defp subscribe?, do: Keyword.get(store_config(), :subscribe, true)
end
