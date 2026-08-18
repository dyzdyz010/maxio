defmodule Maxio.S3.ReservedNamespace do
  @moduledoc """
  MinIO 保留路径命名空间（`/minio/...`）的单一事实来源：**认领规则表 `@claims`**。

  ## 为什么必须只有一张表

  path-style 寻址下 `GET /minio/<key>` 与"桶 `minio` + key `<key>`"逐字重合：任何被
  health / admin / metrics plug 认领并 halt 的路径，都会让同名桶下对应 key 在该寻址
  方式下不可达。因此"哪些路径被认领"必须由**一个**结构说了算——三个 plug 的认领判定、
  启动期审计的扫描面、审计 SQL 的过滤条件全部由 `@claims` 派生，绝不各写一份，否则
  审计会漏报影子化的 key，那正是最恶劣的静默失败（铁律 3）。

  ## 认领的两个必要条件

  1. **路径匹配**：一律整段精确，绝不用 `String.starts_with?("/minio")` 粗匹配——
     `/minioxyz` 是合法桶名的路径，绝不能被误吞。`:prefix` 规则一律以 `/` 结尾。
  2. **寻址结果指向服务器根命名空间**（`server_root_addressed?/1`）：virtual-host 寻址下
     `Host: <bucket>.<domain>` + `GET /minio/health/live` 说的是**桶 `<bucket>` 里 key 为
     `minio/health/live` 的对象**，与保留面毫无关系。只看 `conn.request_path` 就认领会把
     任意桶的这批 key 劫持成 200 空 body——备份/同步工具会把它当成一个合法的空对象，
     比直接报错危险得多（铁律 3）。故认领方必须同时约束寻址结果。

  ## 这是对 MinIO 的**已知、刻意**偏离（复审 I-2）

  MinIO 把 health / admin / metrics 注册在顶层 mux，**不看 Host**：无论请求走
  `minio.example.com` 还是 `s3.example.com`，`/minio/health/live`、`/minio/admin/v3/info`、
  `/minio/v2/metrics` 都命中保留面。maxio 要求 `s3_address_style == :path`，因此当
  `config :maxio, :s3, :domain` 配成真实域名、且客户端用 **vhost 形式的 Host** 访问时，
  这些路径会落回 S3 数据面，返回 `NoSuchBucket` / `AccessDenied`。

  这是**故意**的：不这样做就等于允许保留面劫持任意桶下 `minio/...` 的真实对象（见上），
  数据完整性优先于与 MinIO 的行为等价。但代价必须被运维看见，因此：

    * 运维后果与规避方式写在设计 spec（`docs/superpowers/specs/2026-08-18-minio-admin-surface-design.md`
      D8 回写第 4 条）：探针 / `mc admin` / Prometheus 抓取一律用 **path-style endpoint**；
    * 每当一条**被认领的路径**仅仅因为寻址方式而被跳过时，`claimed?/2` 打一条结构化日志
      （`reason: "reserved_surface_skipped_non_path_addressing"`）——否则运维只能看到一个
      毫无线索的 `NoSuchBucket`，那正是铁律 3 禁止的"没有诊断的失败"。
  """

  alias Maxio.S3.{Log, PipelineOrderError}
  alias Plug.Conn

  @bucket "minio"

  # ── 认领规则表（唯一事实来源）──
  # {surface, :exact | :prefix, path}；prefix 一律以 "/" 结尾以保证整段匹配。
  # metrics 三条对齐 MinIO 的 `/minio/v2/metrics[...]` 与 `/minio/metrics/v3[...]`，
  # 由 `Maxio.S3.Prometheus.metrics_path?/1` 委派本表（它曾自持一份，已收归此处）。
  @claims [
    {:health, :exact, "/minio/health/live"},
    {:health, :exact, "/minio/health/ready"},
    {:admin, :prefix, "/minio/admin/"},
    {:metrics, :exact, "/minio/v2/metrics"},
    {:metrics, :prefix, "/minio/v2/metrics/"},
    {:metrics, :exact, "/minio/metrics/v3"},
    {:metrics, :prefix, "/minio/metrics/v3/"}
  ]

  @surfaces @claims |> Enum.map(&elem(&1, 0)) |> Enum.uniq()

  # 认领规则在**对象命名空间**里的投影：`/<bucket>/<key>` 与对象逐字重合，故每条规则
  # 唯一确定一组 (bucket, key)。编译期解析——规则写错（缺 key 段）直接构建失败。
  @shadowed_targets @claims
                    |> Enum.map(fn {_surface, kind, path} ->
                      ["", bucket, key] = String.split(path, "/", parts: 3)
                      {bucket, kind, key}
                    end)
                    |> Enum.uniq()

  @type surface :: :health | :admin | :metrics
  @type shadowed_target :: {String.t(), :exact | :prefix, String.t()}

  @doc "保留桶名（MinIO 的 minioReservedBucket）。"
  @spec bucket() :: String.t()
  def bucket, do: @bucket

  @doc "被保留、禁止**新建**的桶名集合（存量同名桶仍是合法可读写的桶，见 `Maxio.Buckets`）。"
  @spec reserved_bucket_names() :: [String.t()]
  def reserved_bucket_names, do: [@bucket]

  @doc "保留面枚举。"
  @spec surfaces() :: [surface()]
  def surfaces, do: @surfaces

  @doc "认领规则表原文（供测试守护派生物与规则的一致性）。"
  @spec claims() :: [{surface(), :exact | :prefix, String.t()}]
  def claims, do: @claims

  @doc "本批已实现的健康探针路径（只有这两条被认领；其余 /minio/health/* 仍落 S3 面）。"
  @spec health_paths() :: [String.t()]
  def health_paths do
    for {:health, :exact, path} <- @claims, do: path
  end

  @spec health_path?(String.t()) :: boolean()
  def health_path?(path), do: path_claimed?(path, :health)

  @doc "admin 面路径（`/minio/admin/` 前缀，`/minioadmin`、`/minio/adminxyz` 都不命中）。"
  @spec admin_path?(String.t()) :: boolean()
  def admin_path?(path), do: path_claimed?(path, :admin)

  @doc "Prometheus 面路径（`Maxio.S3.Prometheus.metrics_path?/1` 委派本函数）。"
  @spec metrics_path?(String.t()) :: boolean()
  def metrics_path?(path), do: path_claimed?(path, :metrics)

  @doc "该**路径**是否落在某个保留面上（不含寻址判定，见 `claimed?/2`）。"
  @spec claimed_path?(String.t()) :: boolean()
  def claimed_path?(path) when is_binary(path) do
    Enum.any?(@surfaces, &path_claimed?(path, &1))
  end

  @doc "该路径是否落在指定保留面上。"
  @spec path_claimed?(String.t(), surface()) :: boolean()
  def path_claimed?(path, surface) when is_binary(path) and surface in @surfaces do
    Enum.any?(@claims, fn
      {^surface, :exact, claim} -> path == claim
      {^surface, :prefix, claim} -> String.starts_with?(path, claim)
      _other -> false
    end)
  end

  @doc """
  指定保留面是否认领**这个请求**：路径匹配 **且** 寻址结果指向服务器根命名空间。
  这是三个保留面 plug 唯一允许使用的认领判定。
  """
  @spec claimed?(Conn.t(), surface()) :: boolean()
  def claimed?(%Conn{} = conn, surface) do
    path = conn.request_path || ""

    # 先判路径：路径本来就不相干的请求不该因为管线顺序问题而炸（也避免无谓的 assigns 读取）。
    cond do
      not path_claimed?(path, surface) -> false
      server_root_addressed?(conn) -> true
      true -> log_addressing_skip(conn, surface, path)
    end
  end

  # 路径确实落在保留面上，却因为**寻址方式**（vhost / website）被放行到 S3 数据面。
  # 这是与 MinIO 的已知偏离（见 moduledoc），对运维表现为一个毫无线索的 NoSuchBucket——
  # 必须留下可检索的归因，否则就是"没有诊断的失败"（铁律 3）。返回 false（不认领）。
  defp log_addressing_skip(%Conn{} = conn, surface, path) do
    Log.warn(
      "reserved #{surface} surface not claimed: request is #{conn.assigns[:s3_address_style]}-addressed, " <>
        "not path-style. maxio only serves the MinIO reserved surfaces on the server root namespace " <>
        "(MinIO itself ignores Host here — known, deliberate deviation). Use a path-style endpoint " <>
        "(e.g. https://<s3-domain>/minio/... with no bucket in the Host) for probes, mc admin and " <>
        "Prometheus scrapes.",
      action: "reserved_surface_skipped",
      surface: surface,
      resource: path,
      bucket: conn.assigns[:s3_bucket],
      address_style: conn.assigns[:s3_address_style],
      reason: "reserved_surface_skipped_non_path_addressing"
    )

    false
  end

  @doc """
  请求是否指向**服务器根命名空间**——即桶名不来自 Host（path-style），
  而是来自路径首段（或根本没有桶）。

  assign 由 `Maxio.S3.Plugs.AddressStyle` 写入；缺失即说明保留面 plug 被挂到了
  AddressStyle **之前**，此时无法判定寻址方式。绝不默认"是"（会重演 vhost 劫持）
  也绝不默认"否"（探针会静默失效），而是硬失败——管线顺序错了必须立刻可见（铁律 3）。
  """
  @spec server_root_addressed?(Conn.t()) :: boolean()
  def server_root_addressed?(%Conn{assigns: assigns}) do
    case Map.fetch(assigns, :s3_address_style) do
      {:ok, style} ->
        style == :path

      :error ->
        raise PipelineOrderError,
              "reserved namespace claim requires assigns.s3_address_style; mount " <>
                "Maxio.S3.Plugs.AddressStyle before the health / admin / metrics plugs"
    end
  end

  @doc """
  该 (bucket, key) 在 path-style 下是否被保留面影子化（读写都到不了对象）。
  判定方式是把它还原成 path-style 请求路径再问 `claimed_path?/1`——与实际认领逻辑同源。
  """
  @spec shadowed?(String.t(), String.t()) :: boolean()
  def shadowed?(bucket, key) when is_binary(bucket) and is_binary(key) do
    claimed_path?("/" <> bucket <> "/" <> key)
  end

  @doc """
  认领规则在对象命名空间的投影：`[{bucket, :exact | :prefix, key}]`。
  审计的 SQL 条件由本函数逐条派生，故**扫描面恒等于认领面**——增删保留端点时
  审计自动跟随，不会漏报，也不会把没被认领的 key 误报成"已丢失"。
  """
  @spec shadowed_targets() :: [shadowed_target()]
  def shadowed_targets, do: @shadowed_targets
end
