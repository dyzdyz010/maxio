defmodule Maxio.ConfigTest do
  @moduledoc """
  运行时配置存储（设计 §第一部分 D1–D5）的门面 / 白名单 / 写路径 / 缓存失效回归。

  这里断言的是三件"绝不静默失败"的事（铁律 3）：
    * 读优先级恒为 runtime > env > compile，且 `source/2` 报告的来源与实际生效值一致；
    * 非法 / 未知 / 禁止的键写入一律结构化报错并**绝不落库**；
    * 写成功 ≠ 生效——`applied` 是 Schema 的诚实回传。
  """
  use Maxio.DataCase, async: false

  import Ecto.Query
  import ExUnit.CaptureLog

  alias Maxio.Config
  alias Maxio.Config.{RuntimeConfig, RuntimeConfigAudit, Schema, Store}

  setup do
    Store.reset_local!()
    on_exit(fn -> Store.reset_local!() end)
    :ok
  end

  describe "读门面与优先级" do
    test "无运行时覆盖时回落 Application env（迁移策略：门面行为与直读 env 逐字相同）" do
      assert Config.get(:listing, :sql_hard_limit) ==
               Application.get_env(:maxio, :listing)[:sql_hard_limit]

      assert Config.source(:listing, :sql_hard_limit) == :compile
    end

    test "运行时覆盖压过 Application env，且 source/2 如实报告 :runtime" do
      assert {:ok, %{applied: :hot, version: 1}} =
               Config.set(:listing, :sql_hard_limit, 4242, source: "cli")

      assert Config.get(:listing, :sql_hard_limit) == 4242
      assert Config.source(:listing, :sql_hard_limit) == :runtime

      # 三层取证：门面必须能同时说出"生效值"与"每层各自的值"，否则运维无法定位
      # "我改了怎么没生效"。
      effective = Config.effective(:listing, :sql_hard_limit)
      assert effective.value == 4242
      assert effective.source == :runtime
      assert effective.runtime_value == 4242
      assert effective.app_env_value == Application.get_env(:maxio, :listing)[:sql_hard_limit]
      assert effective.apply == :hot
      assert effective.version == 1
    end

    test "声明了 env_var 的键在环境变量存在时报告 :env（而不是谎称编译期默认）" do
      # deployment_id 是白名单里唯一声明 env_var 的键（runtime.exs 已接线）。
      assert %{env_var: "MAXIO_DEPLOYMENT_ID"} = Schema.fetch!(:cluster, :deployment_id)

      System.put_env("MAXIO_DEPLOYMENT_ID", "env-pinned-deployment")
      Application.put_env(:maxio, :cluster, deployment_id: "env-pinned-deployment")

      on_exit(fn ->
        System.delete_env("MAXIO_DEPLOYMENT_ID")
        Application.delete_env(:maxio, :cluster)
      end)

      assert Config.get(:cluster, :deployment_id) == "env-pinned-deployment"
      assert Config.source(:cluster, :deployment_id) == :env

      # runtime override 优先级高于 env var（运维时意图晚于部署时意图）。
      assert {:ok, _} = Config.set(:cluster, :deployment_id, "runtime-override", source: "cli")
      assert Config.get(:cluster, :deployment_id) == "runtime-override"
      assert Config.source(:cluster, :deployment_id) == :runtime
      assert Config.effective(:cluster, :deployment_id).env_value == "env-pinned-deployment"
    end

    test "既无覆盖也无 env 也无编译期默认时 source/2 是 :default，fetch!/2 硬失败" do
      assert Config.get(:cluster, :deployment_id) == nil
      assert Config.source(:cluster, :deployment_id) == :default

      assert_raise KeyError, fn -> Config.fetch!(:cluster, :deployment_id) end
    end

    test "get_all/1 返回合并后的 keyword（运行时覆盖叠在 app env 之上）" do
      assert {:ok, _} = Config.set(:listing, :sql_hard_limit, 77, source: "cli")
      assert Keyword.get(Config.get_all(:listing), :sql_hard_limit) == 77
    end
  end

  describe "白名单与禁止清单（D3 / §4）" do
    test "未知键写入返回 {:unknown_config_key, ...} 且绝不落库" do
      assert {:error, {:unknown_config_key, :listing, :nope}} =
               Config.set(:listing, :nope, 1, source: "cli")

      assert Repo.aggregate(RuntimeConfig, :count) == 0
      assert Repo.aggregate(RuntimeConfigAudit, :count) == 0
    end

    test "§4 禁止清单逐键回归（不抽样）：一律 {:forbidden_config_key, ...}" do
      pairs =
        Schema.forbidden_keys() ++
          Enum.map(Schema.forbidden_subsystems(), &{&1, :any_key_at_all})

      # 清单不是空的——否则这条测试会静默通过，等于没有防线。
      assert length(pairs) >= 20

      for {subsystem, key} <- pairs do
        assert {:error, {:forbidden_config_key, ^subsystem, ^key}} =
                 Config.set(subsystem, key, "whatever", source: "cli"),
               "expected #{inspect({subsystem, key})} to be forbidden"
      end

      assert Repo.aggregate(RuntimeConfig, :count) == 0
    end

    test "禁止判定优先于未知判定（密钥类键必须是 403 而不是 400）" do
      # :sse 子系统整体不在白名单里；若先判"未知"就会把根信任材料降级成一个 400，
      # 运维会以为"换个键名就能写"。
      assert {:error, {:forbidden_config_key, :sse, :master_key}} =
               Config.set(:sse, :master_key, "x", source: "cli")
    end

    test "behaviour 绑定所在子系统整体禁止（写模块名 = 把配置写权限升级成代码执行权限）" do
      assert {:error, {:forbidden_config_key, :storage_backend, :module}} =
               Config.set(:storage_backend, :module, "Elixir.Evil", source: "cli")
    end
  end

  describe "值校验（绝不静默回退默认值）" do
    test "类型错返回 {:invalid_config_value, ...} 且绝不落库" do
      assert {:error, {:invalid_config_value, :listing, :sql_hard_limit, reason}} =
               Config.set(:listing, :sql_hard_limit, "not-an-integer", source: "cli")

      assert reason =~ "integer"
      assert Repo.aggregate(RuntimeConfig, :count) == 0
    end

    test "范围越界返回 {:invalid_config_value, ...}" do
      assert {:error, {:invalid_config_value, :s3, :clock_skew_ms, _}} =
               Config.set(:s3, :clock_skew_ms, -1, source: "cli")

      assert {:error, {:invalid_config_value, :listing, :sql_hard_limit, _}} =
               Config.set(:listing, :sql_hard_limit, 10_000_001, source: "cli")
    end

    test "布尔键拒绝非布尔值" do
      assert {:error, {:invalid_config_value, :prometheus_metrics, :public, _}} =
               Config.set(:prometheus_metrics, :public, "yes", source: "cli")
    end

    test "非法 source 通道被拒（审计通道必须可枚举）" do
      assert {:error, {:invalid_config_source, "hackers"}} =
               Config.set(:listing, :sql_hard_limit, 1, source: "hackers")
    end
  end

  describe "写路径：版本、并发与审计" do
    test "单键 set 适配器保留返回字段，等值写显式报告 no-op" do
      # Catches an adapter that loses the old public map shape or turns an equal set into a new
      # version/audit merely because the implementation moved behind the batch coordinator.
      assert {:ok,
              %{
                applied: :hot,
                changed?: true,
                operation: :set,
                value: 10,
                version: 1
              }} = Config.set(:listing, :sql_hard_limit, 10, source: "cli")

      assert {:ok,
              %{
                applied: :hot,
                changed?: false,
                operation: :set,
                value: 10,
                version: 1
              }} = Config.set(:listing, :sql_hard_limit, 10, source: "cli")

      assert [%{to_version: 1}] = Config.history(:listing, :sql_hard_limit)
    end

    test "首次写 version=1，再写 version=2，previous_value 保留上一版" do
      assert {:ok, %{version: 1}} = Config.set(:listing, :sql_hard_limit, 10, source: "cli")
      assert {:ok, %{version: 2}} = Config.set(:listing, :sql_hard_limit, 20, source: "cli")

      row = Repo.one(from r in RuntimeConfig, where: r.subsystem == "listing")
      assert row.value == %{"v" => 20}
      assert row.previous_value == %{"v" => 10}
      assert row.version == 2
      assert row.apply_mode == "hot"
      assert row.source == "cli"
    end

    test "乐观并发：同一 expected_version 写两次，第二次冲突且 DB 版本只 +1" do
      assert {:ok, %{version: 1}} =
               Config.set(:listing, :sql_hard_limit, 10, source: "cli", expected_version: nil)

      assert {:ok, %{version: 2}} =
               Config.set(:listing, :sql_hard_limit, 20, source: "cli", expected_version: 1)

      assert {:error, :config_version_conflict} =
               Config.set(:listing, :sql_hard_limit, 30, source: "cli", expected_version: 1)

      row = Repo.one(from r in RuntimeConfig, where: r.subsystem == "listing")
      assert row.version == 2
      assert row.value == %{"v" => 20}
    end

    test "并发首写同一个键：唯一索引裁决，输方拿到结构化冲突而不是穿透事务的异常" do
      # `FOR UPDATE` 锁不住一行还不存在的记录，所以两个进程同时首写同一个键时双双走
      # INSERT，由 (subsystem, key) 唯一索引裁决。这个竞态在 sandbox 里复现不了
      # （同一事务内直接插的行对 FOR UPDATE 可见，走的是 UPDATE 分支），故用替身 Repo
      # 确定性地覆盖"唯一约束错误 → :config_version_conflict"这条映射。
      assert {:error, :config_version_conflict} =
               Config.set(:listing, :sql_hard_limit, 222,
                 source: "cli",
                 repo: Maxio.Test.ConfigConflictRepo
               )

      # 输方绝不能留下审计行（替身的 insert!/1 会在被调到时炸掉），也绝不写真实 DB。
      assert Repo.aggregate(RuntimeConfig, :count) == 0
      assert Repo.aggregate(RuntimeConfigAudit, :count) == 0
    end

    test "每次 set/reset 恰好一条审计行，含前后值与操作者" do
      assert {:ok, _} =
               Config.set(:listing, :sql_hard_limit, 10,
                 source: "admin_api",
                 principal_arn: "arn:aws:iam:::root",
                 access_key_id: "AKIA-TEST",
                 request_id: "req-1"
               )

      assert {:ok, _} = Config.set(:listing, :sql_hard_limit, 20, source: "cli")

      assert {:ok,
              %{
                applied: :hot,
                changed?: true,
                operation: :reset,
                value: nil,
                version: nil
              }} = Config.reset(:listing, :sql_hard_limit, source: "cli")

      audits =
        Repo.all(from a in RuntimeConfigAudit, order_by: [asc: a.to_version, asc: a.inserted_at])

      assert length(audits) == 3
      [first, second, third] = audits

      assert first.operation == "set"
      assert first.old_value == nil
      assert first.new_value == %{"v" => 10}
      assert first.from_version == nil
      assert first.to_version == 1
      assert first.source == "admin_api"
      assert first.principal_arn == "arn:aws:iam:::root"
      assert first.access_key_id == "AKIA-TEST"
      assert first.request_id == "req-1"
      assert first.apply_mode == "hot"

      assert second.operation == "set"
      assert second.old_value == %{"v" => 10}
      assert second.new_value == %{"v" => 20}

      assert third.operation == "reset"
      assert third.old_value == %{"v" => 20}
      assert third.new_value == nil
    end

    test "reset 删除覆盖行并回落 app env；重复 reset 显式报告 changed?=false" do
      assert {:ok, _} = Config.set(:listing, :sql_hard_limit, 10, source: "cli")
      assert Config.get(:listing, :sql_hard_limit) == 10

      assert {:ok, %{changed?: true}} = Config.reset(:listing, :sql_hard_limit, source: "cli")
      assert Repo.aggregate(RuntimeConfig, :count) == 0

      assert Config.get(:listing, :sql_hard_limit) ==
               Application.get_env(:maxio, :listing)[:sql_hard_limit]

      assert Config.source(:listing, :sql_hard_limit) == :compile

      # 空转的 reset **不写审计行**：审计流水是"发生过的变更"，把一次什么都没做的操作
      # 记进去，会让回滚取证时数不清到底改过几次。
      assert {:ok,
              %{
                applied: :hot,
                changed?: false,
                operation: :reset,
                value: nil,
                version: nil
              }} = Config.reset(:listing, :sql_hard_limit, source: "cli")

      assert Repo.aggregate(RuntimeConfigAudit, :count) == 2
    end

    test "history/2 按时间倒序返回审计流水" do
      assert {:ok, _} = Config.set(:listing, :sql_hard_limit, 10, source: "cli")
      assert {:ok, _} = Config.set(:listing, :sql_hard_limit, 20, source: "cli")

      assert [%{to_version: 2}, %{to_version: 1}] = Config.history(:listing, :sql_hard_limit)
    end
  end

  describe "缓存与失效（D5）" do
    test "写路径同步重装本节点快照，不依赖广播送达" do
      assert {:ok, _} = Config.set(:s3, :clock_skew_ms, 1234, source: "cli")
      assert :persistent_term.get({Maxio.Config, :s3})[:clock_skew_ms] == 1234
    end

    test "丢掉广播后，周期版本对账仍能在一个周期内把落后节点收敛" do
      # 模拟"广播丢失"：直接经 Repo 写行（绕过 Config.set 的本地重装 + 广播）。
      Repo.insert!(%RuntimeConfig{
        subsystem: "listing",
        key: "sql_hard_limit",
        value: %{"v" => 999},
        version: 1,
        apply_mode: "hot",
        source: "cli"
      })

      refute Config.get(:listing, :sql_hard_limit) == 999
      assert Store.drifted?() == true

      # 对账（周期兜底走同一函数）→ 收敛。
      assert %{reloaded?: true} = Store.reconcile!()
      assert Config.get(:listing, :sql_hard_limit) == 999
      assert Store.drifted?() == false
    end

    test "从未装载过时的首次漂移日志仍带 config_local_digest（nil 必须落成显式占位串）" do
      # 本节点从未装载成功过时 `meta().aggregate.digest` 是 `nil`，而 Logger 的 metadata 渲染
      # 会把 nil 值的键**整个丢掉**——于是**第一次**漂移的 warning 正好缺掉"本地指纹"那一半，
      # 而那一半恰恰是区分"丢了广播"与"本节点从没读到过 PG"的唯一线索：前者要查广播通路，
      # 后者要查 PG 可达性/启动期，两条完全不同的排障路径。所以 nil 必须落成显式占位串。
      # setup 的 reset_local!/0 已把本节点置于"从未装载"状态。
      assert Store.meta().aggregate.digest == nil
      assert Store.meta().last_reload_reason == :never_loaded

      Repo.insert!(%RuntimeConfig{
        subsystem: "listing",
        key: "sql_hard_limit",
        value: %{"v" => 999},
        version: 1,
        apply_mode: "hot",
        source: "cli"
      })

      authoritative = Store.authoritative_aggregate()

      log =
        capture_log([level: :warning], fn ->
          assert %{reloaded?: true} = Store.reconcile!()
        end)

      assert log =~ "runtime config snapshot drifted from Postgres"
      assert log =~ "reason=config_snapshot_drift"

      # 权威指纹与本地指纹**两半都必须在**，否则这条日志无法定位根因。
      assert log =~ "config_digest=#{authoritative.digest}"
      assert log =~ "config_local_digest=never_loaded"
    end

    test "删一行 + 插一行（行数与版本和恒等）的分歧必须被对账检出" do
      # 第一版对账用 (行数, 版本和) 当判据，这个形态会让它**永久**看不见分歧：
      # reset 掉一个 v2 的键 + 首次 set 另一个键到 v2，两个数字逐字不变，于是本节点会一直
      # 报出 PG 里早已不存在的值（活体形态就是 mc admin info 报一个已被删掉的 deploymentID）。
      # 判据换成整表内容摘要后，这里必须是 drifted。
      Repo.insert!(%RuntimeConfig{
        subsystem: "cluster",
        key: "deployment_id",
        value: %{"v" => "deployment-from-postgres"},
        version: 2,
        apply_mode: "hot",
        source: "cli"
      })

      assert %{reloaded?: true} = Store.reconcile!()
      assert Config.get(:cluster, :deployment_id) == "deployment-from-postgres"
      assert Store.drifted?() == false

      before = Store.meta().aggregate

      # 删一行 + 插一行：count 恒为 1，version_sum 恒为 2。
      Repo.delete_all(from r in RuntimeConfig, where: r.subsystem == "cluster")

      Repo.insert!(%RuntimeConfig{
        subsystem: "listing",
        key: "sql_hard_limit",
        value: %{"v" => 4242},
        version: 2,
        apply_mode: "hot",
        source: "cli"
      })

      # 碰撞是真的：老判据的两个分量在这里逐字相等——所以它只能靠 digest 分辨。
      authoritative = Store.authoritative_aggregate()
      assert authoritative.count == before.count
      assert authoritative.version_sum == before.version_sum
      assert authoritative.digest != before.digest

      assert Store.drifted?() == true
      assert %{reloaded?: true} = Store.reconcile!()

      # 收敛后：被删掉的键不再被本节点报出，新键生效。
      assert Config.get(:cluster, :deployment_id) == nil
      assert Config.get(:listing, :sql_hard_limit) == 4242
      assert Store.drifted?() == false
    end

    test "set → reset → set 复用同一个版本号：不含 value 的旧摘要恒等，必须靠 value 检出" do
      # `Maxio.Config.reset` 是**删行**，`set` 又是 `if current, do: version + 1, else: 1`
      # —— 于是版本号回到 1。只摘 (subsystem, key, version) 的话，这三步之后摘要**逐字不变**，
      # 而它们全是纯门面操作，不需要任何"直接改库"。丢一次广播即永久静默分歧。
      assert {:ok, %{version: 1}} = Config.set(:listing, :sql_hard_limit, 111, source: "cli")

      before = Store.authoritative_aggregate()
      legacy_before = legacy_digest()

      # 本节点此刻的快照与指纹 = "丢广播前的状态"。之后的 reset + set 当作是**另一个节点**
      # 做的、而本节点丢了那两条广播；由于 set/reset 总会同步重装本节点快照，只能用
      # "做完再把本节点按回原状"来复现。直接写 :persistent_term 是白盒手法，但被复现的
      # 正是这两个 term 的内容。
      stale_snapshot = Store.snapshot(:listing)
      stale_meta = Store.meta()

      assert {:ok, %{changed?: true}} = Config.reset(:listing, :sql_hard_limit, source: "cli")
      assert {:ok, %{version: 1}} = Config.set(:listing, :sql_hard_limit, 999, source: "cli")

      :persistent_term.put({Maxio.Config, :listing}, stale_snapshot)
      :persistent_term.put({Maxio.Config, :__meta__}, stale_meta)

      authoritative = Store.authoritative_aggregate()

      # 老判据的三个分量在这里逐字相等 —— 这就是它漏判的原因，也是本用例的 RED 依据。
      assert legacy_digest() == legacy_before
      assert authoritative.count == before.count
      assert authoritative.version_sum == before.version_sum

      # 含 value 的摘要必须分辨得出，且对账必须真的把节点拉回权威值。
      assert authoritative.digest != before.digest
      assert Config.get(:listing, :sql_hard_limit) == 111
      assert Store.drifted?() == true
      assert %{reloaded?: true} = Store.reconcile!()
      assert Config.get(:listing, :sql_hard_limit) == 999
      assert Store.drifted?() == false
    end

    test "只改 value 不动 version 的分歧必须被对账检出（回滚恢复 / 手工改数据的形态）" do
      assert {:ok, %{version: 1}} =
               Config.set(:cluster, :deployment_id, "id-written-by-this-node", source: "cli")

      assert Store.drifted?() == false

      before = Store.authoritative_aggregate()
      legacy_before = legacy_digest()

      # 直接改库：只换 value，version 原封不动。活体形态就是 `mc admin info` 报的
      # deploymentID 与 PG 完全不同，而 18 次周期对账一条 drift warning 都不打。
      {1, _} =
        Repo.update_all(
          from(r in RuntimeConfig,
            where: r.subsystem == "cluster" and r.key == "deployment_id"
          ),
          set: [value: %{"v" => "id-rewritten-in-postgres"}]
        )

      assert legacy_digest() == legacy_before

      authoritative = Store.authoritative_aggregate()
      assert authoritative.count == before.count
      assert authoritative.version_sum == before.version_sum
      assert authoritative.digest != before.digest

      assert Store.drifted?() == true
      assert %{reloaded?: true} = Store.reconcile!()
      assert Config.get(:cluster, :deployment_id) == "id-rewritten-in-postgres"
      assert Store.drifted?() == false
    end

    test "同一逻辑值的不同书写形式给出同一摘要（jsonb::text 规范化，不引入假漂移）" do
      # 把 value 摘进指纹的代价必须是零假漂移：否则每个周期都会误报一次漂移 + 无谓整体重载，
      # 而"漂移 warning"这个信号一旦变成噪声，真丢广播时就没人看了。
      assert {:ok, _} = Config.set(:listing, :sql_hard_limit, 4242, source: "cli")
      digest = Store.authoritative_aggregate().digest

      Ecto.Adapters.SQL.query!(
        Repo,
        ~s|UPDATE runtime_configs SET value = '{  "v"  :  4242  }'::jsonb|,
        []
      )

      assert Store.authoritative_aggregate().digest == digest
      assert Store.drifted?() == false

      # 指纹赖以成立的那条 PG 性质，就地取证：jsonb 的 text 表示会排键、归一空白。
      assert %{rows: [[true]]} =
               Ecto.Adapters.SQL.query!(
                 Repo,
                 ~s|SELECT md5('{"b":1, "a":2}'::jsonb::text) = md5('{"a":2,"b":1}'::jsonb::text)|,
                 []
               )
    end

    test "一次丢广播 + 一次其它子系统的广播，绝不抹掉漂移证据（兜底对账不许被关掉）" do
      pid =
        start_supervised!(
          {Store, name: :config_store_partial_reload_peer, load_on_boot: false, subscribe: false}
        )

      Ecto.Adapters.SQL.Sandbox.allow(Maxio.Repo, self(), pid)

      # 起点：本节点快照与 PG 一致。
      assert {:ok, _} = Config.set(:s3, :clock_skew_ms, 1111, source: "cli")
      assert Store.drifted?() == false

      # t1：另一节点写了 listing，本节点**丢了**那条广播（经 Repo 直写复现）。
      Repo.insert!(%RuntimeConfig{
        subsystem: "listing",
        key: "sql_hard_limit",
        value: %{"v" => 999},
        version: 1,
        apply_mode: "hot",
        source: "cli"
      })

      assert Store.drifted?() == true
      refute Config.get(:listing, :sql_hard_limit) == 999

      # t2：随后收到一条**别的**子系统的广播。曾经这一步只重装 s3 却记下整表指纹，于是
      # drifted? 被抹成 false，listing 永远停在旧值 —— 一次丢广播 + 一条无关广播就永久
      # 关掉了兜底对账。装载器只剩整体重载之后，记下的指纹恒等于实际装载的范围。
      send(pid, {:config_changed, :s3, :clock_skew_ms})
      _ = :sys.get_state(pid)

      assert Config.get(:listing, :sql_hard_limit) == 999
      assert Store.drifted?() == false

      # t3：周期对账已无救场任务，且值不会退回去 —— 分歧是真的收敛了，不是被抹掉了。
      assert %{reloaded?: false} = Store.reconcile!()
      assert Config.get(:listing, :sql_hard_limit) == 999
    end

    test "内容指纹只在 SQL 里算一次；快照与权威的比对是同一实现的两次取值" do
      # 若哪天有人在 Elixir 侧再实现一份"本地指纹"，排序规则或整数格式化一分叉，
      # 对账就会永久误报漂移（每个周期重载 + 每个周期一条 warning）。这条用例锚死
      # "load_all! 记下的指纹 == 立刻再查一次的权威指纹"。
      assert {:ok, _} = Config.set(:listing, :sql_hard_limit, 31, source: "cli")
      assert {:ok, _} = Config.set(:s3, :clock_skew_ms, 777, source: "cli")

      Store.load_all!()

      assert Store.meta().aggregate == Store.authoritative_aggregate()
      assert Store.meta().aggregate.digest =~ ~r/^[0-9a-f]{32}$/
      assert Store.drifted?() == false
    end

    test "白名单外的 orphan 键被忽略且不进 persistent_term，同时被 status 报告出来" do
      Repo.insert!(%RuntimeConfig{
        subsystem: "listing",
        key: "removed_in_this_version",
        value: %{"v" => 1},
        version: 1,
        apply_mode: "hot",
        source: "cli"
      })

      assert %{orphan_config_keys: [{:listing, :removed_in_this_version}]} = Store.load_all!()
      assert :persistent_term.get({Maxio.Config, :listing}, %{}) == %{}
      assert %{orphan_config_keys: [_]} = Store.status()
    end

    test "白名单内但值无法按 Schema 解码 → 硬失败（说明写路径校验被绕过，是完整性问题）" do
      Repo.insert!(%RuntimeConfig{
        subsystem: "listing",
        key: "sql_hard_limit",
        value: %{"v" => "corrupted"},
        version: 1,
        apply_mode: "hot",
        source: "cli"
      })

      assert_raise Maxio.Config.CorruptValueError, ~r/sql_hard_limit/, fn -> Store.load_all!() end
    end

    test "PubSub 广播能让另一个 Store 实例重装快照" do
      pid =
        start_supervised!(
          {Store, name: :config_store_test_peer, load_on_boot: false, subscribe: true}
        )

      Ecto.Adapters.SQL.Sandbox.allow(Maxio.Repo, self(), pid)

      assert {:ok, _} = Config.set(:s3, :clock_skew_ms, 4321, source: "cli")

      # set/4 自己也会广播；先把 peer 的 mailbox 抽干，否则它那次异步重载可能落在下面的
      # reset_local! **之后**，把快照重新填回去——那样这条用例就会随机失败。
      _ = :sys.get_state(pid)

      # 抹掉本节点快照，模拟一个**尚未**收到失效通知的节点：此时读到的还是编译期默认。
      Store.reset_local!()
      refute Config.get(:s3, :clock_skew_ms) == 4321

      Maxio.Cluster.Notify.broadcast({:config_changed, :s3, :clock_skew_ms})

      # 本地 PubSub 投递是 send，广播消息已在 mailbox 里；:sys.get_state 保证它被处理完。
      _ = :sys.get_state(pid)

      assert Config.get(:s3, :clock_skew_ms) == 4321
    end
  end

  describe "并发整表装载（提交阶段必须原子）" do
    test "交错的两次 load_all! 绝不留下「旧快照 + 新指纹」" do
      # 一次装载的提交**不是**一次原子替换：per-subsystem term、`__subsystems__`、`__meta__`
      # 是好几次各自独立的 `:persistent_term` 写。两个并发 `load_all!` 若交错成
      #
      #     t_新写快照 < t_旧写快照 < t_旧写meta < t_新写meta
      #
      # 终态就是「旧快照 + 新指纹」——而新指纹会让周期对账**永远满意**，旧值被静默固化。
      # 这与「只重装一个子系统的装载器」是同一形态：记录的断言比实际装载的内容更宽/更新。
      assert {:ok, %{version: 1}} = Config.set(:listing, :sql_hard_limit, 111, source: "cli")
      stale_aggregate = Store.authoritative_aggregate()

      # 旧装载：在 PG 还是 111 的时刻读完整表（指纹 + 行都读完了），然后停在提交之前。
      stale = start_loader(:stale, [:queried])
      assert_receive {:stale, :queried}

      # 另一个写入方把 PG 推到 999。下一批的 Admin API 配置写端点就是这个形态：同一 BEAM 内
      # 的并发 HTTP 请求进程，各自在提交后**同步**重装快照（Maxio.Config.finish_write/5）。
      assert {:ok, %{version: 2}} = Config.set(:listing, :sql_hard_limit, 999, source: "cli")
      fresh_aggregate = Store.authoritative_aggregate()
      assert stale_aggregate != fresh_aggregate

      # 新装载：读到 999，写完快照后停住。修复后此刻它**正持有提交锁**——park 在锁里是本用例
      # 刻意要的形态，且安全：loader 是 `spawn_link` 起的，测试进程挂掉即杀 loader，global 经
      # monitor 回收那把锁（已实测），不会把锁泄漏给同一 BEAM 里后续的用例。
      fresh = start_loader(:fresh, [:queried, :snapshot_written])
      assert_receive {:fresh, :queried}
      send(fresh, :continue)
      assert_receive {:fresh, :snapshot_written}

      # 放行旧装载：修复前它把整个提交跑完（旧快照 + 旧指纹都落地），修复后它被挡在提交锁外。
      #
      # 下面这个 receive **不是**互斥的证据，别把它当判据：`:commit_lock_wait` 是在
      # `:global.trans` **之前**发出的，而 `:commit_lock_wait` / `:snapshot_written` / `:done`
      # 由**同一个** loader 进程发给测试进程、消息保序 ⇒ `:commit_lock_wait` 必然排最前，
      # 这个 receive 恒取到它（把 `:global.trans` 整个去掉也一样恒取到）。它只说明"注入点
      # 存在"，作用是决定下面那笔等待预算要不要花。真正的互斥判据是紧接着那句 `refute_receive`。
      send(stale, :continue)

      stale_progress =
        receive do
          {:stale, :done} -> :committed_while_fresh_was_mid_commit
          {:stale, :commit_lock_wait} -> :queued_behind_commit_lock
        end

      # 互斥的**真**判据在这里：此刻 `fresh` 仍持有提交锁、仍停在 `:snapshot_written` 的 park
      # 点，所以 `stale` 的临界区必须一步都还没走。有锁 ⇒ `{:stale, :snapshot_written}` 恒不
      # 发生；把 `:global.trans` 去掉（只留注入点）⇒ 它在 µs 级就发生。
      # 变异验证过：去锁 6 个不同 seed 全部 FAIL，恢复后 6 个不同 seed 全部 PASS。
      refute_receive {:stale, :snapshot_written}, 200

      # 新装载写下它的指纹。修复前这一笔正好盖在旧快照之上——静默固化就发生在这一刻。
      send(fresh, :continue)
      assert_receive {:fresh, :done}

      # 修复后旧装载此刻才拿到锁、才提交；修复前它的 `:done` 早已在上面那个 receive 里收掉了。
      #
      # 这个预算**不是**从 global 推出来的上界——`trans/3` 默认 `Retries = infinity`、等待方
      # 之间无 FIFO，总等待时间原则上无界，任何数字都只是 flake 预算。数字按 global 的退避
      # **阶梯**来定：`random_sleep(Times)` 的 `Tmax = (1 bsl Times) * 1000 div 8`，即依次
      # 250 / 500 / 1000 / 2000 / 4000，`Times > 5` 封顶 8000（核对 kernel-11.0.3 `global.erl`
      # 原文）。关键是上面那句 `refute_receive` 的 200 ms 窗口**排在这段等待前面**，会把等待方
      # 往阶梯深处推：凡是累计睡眠还没超过 200 ms 的，都要再睡下一档。所以真实分布比"第一次
      # 退避 ≤250 ms"宽得多——实测 200 轮：max 1919 ms、>1000 ms 有 3 轮、>500 ms 有 21 轮。
      # 也就是说原来那个 2 秒预算离实测峰值只剩 81 ms，会稳定地漏出约 1% 的假失败。
      # 15 秒要被击穿，得等待方连着 6 次睡眠加起来还不到 200 ms 才能爬到 8000 那一档（~1e-8）。
      # 预算给大不花钱：消息一到 `assert_receive` 就返回，只有**真**失败时才等满。
      if stale_progress == :queued_behind_commit_lock, do: assert_receive({:stale, :done}, 15_000)

      # 终态必须自洽：meta 里的指纹**必须**是"本快照物化自的那次整表状态"的指纹。
      snapshot_value = Config.get(:listing, :sql_hard_limit)
      drifted? = Store.drifted?()

      expected_aggregate =
        case snapshot_value do
          999 -> fresh_aggregate
          111 -> stale_aggregate
        end

      assert Store.meta().aggregate == expected_aggregate,
             "快照在位的是 #{inspect(snapshot_value)}，meta 记的却是另一次表状态的指纹" <>
               "（drifted? = #{drifted?}）：记录的指纹只可能比快照**旧**（自愈方向，最坏" <>
               "多重载一次），绝不能比快照新——那会让对账永远满意，把旧值永久固化"

      # 快照落后时对账必须看得见，而且真能把本节点拉回权威值——这正是修复前做不到的事。
      assert drifted? == (snapshot_value != 999)
      assert %{reloaded?: reloaded?} = Store.reconcile!()
      assert reloaded? == (snapshot_value != 999)
      assert Config.get(:listing, :sql_hard_limit) == 999
      assert Store.drifted?() == false

      # 最后锚一下走的确实是"被挡住"那条分支（`:commit_lock_wait` 注入点存在、且发在加锁之
      # 前）。互斥**本身**由上面那句 `refute_receive` 证明，不是这一句。
      assert stale_progress == :queued_behind_commit_lock
    end
  end

  describe "apply 诚实性（D4 第 8 步）" do
    @samples %{
      {:cluster, :deployment_id} => "sample-deployment-id",
      {:prometheus_metrics, :public} => true,
      {:listing, :sql_hard_limit} => 12_345,
      {:s3, :clock_skew_ms} => 60_000
    }

    test "白名单每个键都有样例值（新增白名单键必须同批补进本表，否则下面的回归会漏掉它）" do
      assert MapSet.new(Map.keys(@samples)) == MapSet.new(Map.keys(Schema.entries()))
    end

    test "白名单每个键的 applied 恒等于 Schema 声明的 apply 模式" do
      for {{subsystem, key}, entry} <- Schema.entries() do
        value = Map.fetch!(@samples, {subsystem, key})
        assert {:ok, %{applied: applied}} = Config.set(subsystem, key, value, source: "cli")
        assert applied == entry.apply
        assert {:ok, _} = Config.reset(subsystem, key, source: "cli")
      end
    end
  end

  # 一次完全受测试编排的整表装载：每到一个注入点就向测试进程报告，并在 `park_phases`
  # 列出的注入点停下等 `:continue`。全程只用消息同步——竞态测试一旦靠 sleep 或靠调度运气，
  # 它既证明不了 bug 存在，也证明不了修复有效。
  defp start_loader(tag, park_phases) do
    test_pid = self()

    spawn_link(fn ->
      checkpoint = fn phase ->
        send(test_pid, {tag, phase})
        if phase in park_phases, do: receive(do: (:continue -> :ok))
        :ok
      end

      Store.load_all!(checkpoint: checkpoint, reason: {:test_loader, tag})
      send(test_pid, {tag, :done})
    end)
  end

  # 修复前的摘要 fragment（只摘 subsystem/key/version，不含 value）。留在测试里当**判据**：
  # 上面两条用例先断言"老判据在这个场景下逐字不变"，再断言新判据能分辨——否则它们只是
  # "现在能过"的用例，说不清自己在防什么。
  defp legacy_digest do
    %{rows: [[digest]]} =
      Ecto.Adapters.SQL.query!(
        Repo,
        """
        SELECT md5(coalesce(string_agg(subsystem || '/' || key || '/' || version::text,
                                       ',' ORDER BY subsystem COLLATE "C", key COLLATE "C"), ''))
        FROM runtime_configs
        """,
        []
      )

    digest
  end
end
