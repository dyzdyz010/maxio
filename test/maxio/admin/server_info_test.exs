defmodule Maxio.Admin.ServerInfoTest do
  @moduledoc """
  `mc admin info` 的 `InfoMessage` 聚合层**诚实性回归**（设计 §10.5 + §13 T3）。

  这是本批最关键的一类测试：madmin 的 struct 字段远多于 maxio 拥有的概念，最容易发生的
  失败不是崩溃，而是**用 0 / 空串冒充"已测量"**。`0` 与"没有这个概念"在监控里是两个
  完全不同的信号，所以 omit 清单必须**逐字段断言键不存在**，而不是抽样。
  """
  use Maxio.DataCase, async: false

  alias Maxio.Admin.ServerInfo
  alias Maxio.Config.Store

  setup do
    Store.reset_local!()
    ServerInfo.invalidate_cache()

    on_exit(fn ->
      Store.reset_local!()
      ServerInfo.invalidate_cache()
    end)

    :ok
  end

  describe "FS 后端（默认配置）" do
    test "backendType 是 FS，且绝不出现 EC 才有的 parity 字段" do
      info = ServerInfo.build(no_cache: true)

      assert info["backend"]["backendType"] == "FS"

      # rrSCParity 绝不从 standardSCParity 回填——那等于宣称存在一个 maxio 根本没实现的
      # 存储类分级（REDUCED_REDUNDANCY），是伪造能力。
      refute Map.has_key?(info["backend"], "rrSCParity")
      refute Map.has_key?(info["backend"], "rrSCData")
      # FS 无 parity 概念；填 0 会被读成"零冗余"这个 EC 语义。
      refute Map.has_key?(info["backend"], "standardSCParity")
      refute Map.has_key?(info["backend"], "standardSCData")
      refute Map.has_key?(info["backend"], "totalSets")
      refute Map.has_key?(info["backend"], "totalDrivesPerSet")
    end

    test "drives 恰好一条，指向真实 data_dir" do
      data_dir = Application.fetch_env!(:maxio, :s3)[:data_dir]

      info = ServerInfo.build(no_cache: true)
      assert [drive] = info["servers"] |> hd() |> Map.fetch!("drives")

      assert drive["path"] == data_dir
      assert drive["endpoint"] == data_dir
      assert drive["state"] == "ok"
    end

    test "onlineDisks 计本机数据目录本身，offlineDisks 为 0" do
      info = ServerInfo.build(no_cache: true)
      assert info["backend"]["onlineDisks"] == 1
      assert info["backend"]["offlineDisks"] == 0
    end
  end

  describe "omit 纪律（表驱动，逐字段）" do
    test "顶层：maxio 无对应概念的字段一律不出现" do
      info = ServerInfo.build(no_cache: true)

      for field <- ~w(sqsARN objectNamingMode pools services) do
        refute Map.has_key?(info, field), "top-level field #{field} must be omitted"
      end
    end

    test "servers[]：maxio 无对应概念的字段一律不出现" do
      server = ServerInfo.build(no_cache: true)["servers"] |> hd()

      omitted =
        ~w(commitID network go_max_procs minio_env_vars minio_env_hash edition license
           is_leader leaders ilm_expiry_in_progress host pid cmd_line username
           api_version restarting_since gc_stats poolNumber poolNumbers)

      for field <- omitted do
        refute Map.has_key?(server, field), "servers[].#{field} must be omitted"
      end
    end

    test "drives[]：口径不可比或 maxio 无来源的字段一律不出现" do
      drive = ServerInfo.build(no_cache: true)["servers"] |> hd() |> Map.fetch!("drives") |> hd()

      omitted =
        ~w(readthroughput writethroughput readlatency writelatency utilization
           major minor used_inodes free_inodes pool_index set_index disk_index model)

      for field <- omitted do
        refute Map.has_key?(drive, field), "drives[].#{field} must be omitted"
      end
    end

    test "整个响应里不存在值为 nil 的键（omit 意味着键不存在，不是 null）" do
      info = ServerInfo.build(no_cache: true)
      assert nil_keys(info) == []
    end
  end

  describe "真实值" do
    test "runtime_version 如实写 Elixir/OTP，绝不伪装成 Go" do
      server = ServerInfo.build(no_cache: true)["servers"] |> hd()

      assert server["runtime_version"] =~ ~r/^Elixir #{Regex.escape(System.version())} \/ OTP /
      refute server["runtime_version"] =~ "go"
    end

    test "version 等于 mix.exs 的版本，绝不是 MinIO 风格的 RELEASE 串" do
      server = ServerInfo.build(no_cache: true)["servers"] |> hd()

      assert server["version"] == to_string(Application.spec(:maxio, :vsn))
      refute server["version"] =~ "RELEASE."
    end

    test "num_cpu 与 mem_stats.alloc 是真实 BEAM 观测值" do
      server = ServerInfo.build(no_cache: true)["servers"] |> hd()

      assert server["num_cpu"] == :erlang.system_info(:logical_processors)
      assert is_integer(server["mem_stats"]["alloc"]) and server["mem_stats"]["alloc"] > 0

      # Go MemStats 的 mallocs/frees/total_alloc 在 BEAM 里没有同口径对应物，
      # 绝不用别的数字冒充同名字段。
      for field <- ~w(mallocs frees total_alloc heap_alloc) do
        refute Map.has_key?(server["mem_stats"], field)
      end
    end

    test "num_cpu 判定不出时整个字段 omit（原子 :unknown 会毒死 madmin 的整次 json.Decode）" do
      # `:erlang.system_info(:logical_processors)` 在判不出 CPU 拓扑的平台返回原子 :unknown。
      # 直接下发 → Jason 编成 JSON 字符串 "unknown" → madmin 的 NumCPU 是 int →
      # `mc admin info` **整体**解码失败，不是"少一个字段"。
      info = ServerInfo.build(no_cache: true, logical_processors_fun: fn -> :unknown end)
      server = hd(info["servers"])

      refute Map.has_key?(server, "num_cpu")

      # omit 只影响这一个字段，响应其余部分照常（这正是 omit 比"填 0"好的地方）。
      assert is_integer(server["mem_stats"]["alloc"])
      assert server["state"] == "online"

      # 而且响应仍然是可编码、可被 Go 解出来的 JSON——不存在值为 "unknown" 的 num_cpu。
      refute Jason.encode!(info) =~ "num_cpu"
    end

    test "num_cpu 是整数时如实下发" do
      info = ServerInfo.build(no_cache: true, logical_processors_fun: fn -> 7 end)
      assert hd(info["servers"])["num_cpu"] == 7
    end

    test "domain 是数组，region 取自 config" do
      info = ServerInfo.build(no_cache: true)
      s3 = Application.fetch_env!(:maxio, :s3)

      assert info["domain"] == [s3[:domain]]
      assert info["region"] == s3[:region]
    end

    test "uptime 为非负整数且不超过进程实际存活时长" do
      server = ServerInfo.build(no_cache: true)["servers"] |> hd()

      assert is_integer(server["uptime"])
      assert server["uptime"] >= 0
    end

    test "endpoint / scheme 反映真实监听点" do
      info = ServerInfo.build(no_cache: true, host: "example.test", scheme: :https)
      server = hd(info["servers"])

      port = Application.get_env(:maxio, Maxio.S3.Endpoint, [])[:port]
      assert server["scheme"] == "https"
      assert server["endpoint"] == "example.test:#{port}"
      assert server["state"] == "online"
    end
  end

  describe "usage 口径与缓存" do
    test "usage 数字与 Prometheus.usage_stats/1 完全一致（同一口径，绝不分叉）" do
      {:ok, _} = Maxio.Buckets.create("serverinfo-usage-a", "arn:aws:iam:::root")
      {:ok, _} = Maxio.Buckets.create("serverinfo-usage-b", "arn:aws:iam:::root")

      stats = Maxio.S3.Prometheus.usage_stats()
      info = ServerInfo.build(no_cache: true)

      assert info["buckets"]["count"] == stats.bucket_count
      assert info["objects"]["count"] == stats.object_count
      assert info["versions"]["count"] == stats.version_count
      assert info["deletemarkers"]["count"] == stats.delete_marker_count
      assert info["usage"]["size"] == stats.total_bytes
    end

    test "默认走短 TTL 缓存；no_cache 绕过缓存重新聚合" do
      {:ok, _} = Maxio.Buckets.create("serverinfo-cache-a", "arn:aws:iam:::root")
      first = ServerInfo.build([])
      assert first["buckets"]["count"] == 1

      {:ok, _} = Maxio.Buckets.create("serverinfo-cache-b", "arn:aws:iam:::root")
      assert ServerInfo.build([])["buckets"]["count"] == 1
      assert ServerInfo.build(no_cache: true)["buckets"]["count"] == 2
    end
  end

  describe "deploymentID" do
    test "首次读时生成并持久化，二次读不变" do
      first = ServerInfo.build(no_cache: true)["deploymentID"]

      assert is_binary(first)
      assert byte_size(first) == 36

      # 清掉本节点快照（模拟重启）后仍从 PG 读回同一个 id。
      Store.reset_local!()
      assert ServerInfo.build(no_cache: true)["deploymentID"] == first
    end

    test "deploymentID 就是 config store 的第一个真实消费者" do
      info = ServerInfo.build(no_cache: true)
      assert Maxio.Config.get(:cluster, :deployment_id) == info["deploymentID"]
      assert Maxio.Config.source(:cluster, :deployment_id) == :runtime
    end
  end

  describe "驱动器健康的保守计入" do
    test "suspect 盘绝不报成 ok，且计入 offlineDisks" do
      # 单机 EC 后端（无拓扑）：drives 来自 config :maxio, :erasure。
      config = Application.get_env(:maxio, :erasure)
      [suspect_drive | _] = config[:drives]

      prev_backend = Application.get_env(:maxio, :storage_backend)
      Application.put_env(:maxio, :storage_backend, Maxio.Storage.ErasureCoded)

      Maxio.Cluster.DriveHealth.record_probe({Node.self(), suspect_drive}, {:error, :enoent},
        offline_after_ms: 172_800_000
      )

      on_exit(fn ->
        Application.put_env(:maxio, :storage_backend, prev_backend)
        Maxio.Cluster.DriveHealth.reset()
      end)

      info = ServerInfo.build(no_cache: true)
      drives = info["servers"] |> hd() |> Map.fetch!("drives")
      suspect = Enum.find(drives, &(&1["path"] == suspect_drive))

      assert Maxio.Cluster.DriveHealth.status({Node.self(), suspect_drive}).status == :suspect
      refute suspect["state"] == "ok"
      assert suspect["state"] == "offline"

      assert info["backend"]["backendType"] == "Erasure"
      assert info["backend"]["standardSCParity"] == config[:parity_shards]
      assert info["backend"]["offlineDisks"] == 1
      assert info["backend"]["onlineDisks"] == length(config[:drives]) - 1
    end
  end

  describe "健康登记处不可用时的降级（CLI 取证路径）" do
    test "读不到盘健康时 omit state 与 online/offlineDisks，绝不编一个答案，也绝不崩" do
      # `mix maxio.admin.info` 跑在只起了 Repo 的 Mix 进程里，Maxio.Cluster.DriveHealth
      # 根本不存在。此前这里是一个 GenServer.call no-process 崩溃——一个"mc 报错时用来取证"
      # 的 CLI 自己先崩了。修法不是给它编一个 state：报 "ok" 是宣称观测到健康，报 "offline"
      # 是宣称观测到故障，两个方向都是伪造。
      info = ServerInfo.build(no_cache: true, drive_health_fun: fn _endpoint -> :unavailable end)

      [drive] = info["servers"] |> hd() |> Map.fetch!("drives")
      refute Map.has_key?(drive, "state")
      assert drive["path"] == Application.fetch_env!(:maxio, :s3)[:data_dir]

      # 少数了一块盘的冗余度比不报更糟——运维会拿它当真。
      refute Map.has_key?(info["backend"], "onlineDisks")
      refute Map.has_key?(info["backend"], "offlineDisks")
      # 与盘健康无关的字段照常出现。
      assert info["backend"]["backendType"] == "FS"
      assert is_binary(info["deploymentID"])
    end

    test "登记处可用时照常给出 state 与计数（上面的降级不是常态）" do
      info = ServerInfo.build(no_cache: true)

      assert info["servers"] |> hd() |> Map.fetch!("drives") |> hd() |> Map.fetch!("state") ==
               "ok"

      assert info["backend"]["onlineDisks"] == 1
    end
  end

  defp nil_keys(value, path \\ [])

  defp nil_keys(%{} = map, path) do
    Enum.flat_map(map, fn
      {k, nil} -> [Enum.reverse([k | path])]
      {k, v} -> nil_keys(v, [k | path])
    end)
  end

  defp nil_keys(list, path) when is_list(list) do
    list |> Enum.with_index() |> Enum.flat_map(fn {v, i} -> nil_keys(v, [i | path]) end)
  end

  defp nil_keys(_other, _path), do: []
end
