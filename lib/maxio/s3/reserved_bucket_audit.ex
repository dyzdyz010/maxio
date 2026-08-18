defmodule Maxio.S3.ReservedBucketAudit do
  @moduledoc """
  保留路径影子化的**取证与清理**：报告哪些对象 key 因为落在 `/minio/...` 保留面上而在
  path-style 下不可达，并提供唯一一条不改 DNS 的清理通路（设计 D8 第 2 条）。

  ## 扫描面由认领规则派生，不写死桶名

  扫描条件逐条来自 `Maxio.S3.ReservedNamespace.shadowed_targets/0`——认领规则在对象命名
  空间上的投影 `{bucket, :exact | :prefix, key}`。因此扫描面**恒等于**认领面：plug 增删
  保留端点时审计自动跟随，既不会漏报被影子化的 key，也不会把没被认领的 key 误报成
  "已丢失"（报假的丢失与漏报真的丢失同样有害）。今天所有规则都根在 `/minio/`，投影出来
  的桶就只有 `minio` 一个；将来若出现别的根，扫描无需改一行。

  ## 影子化的确切范围（已实测收敛）

  只发生在 **path-style** 寻址下的保留桶。virtual-host 寻址（`Host: <bucket>.<domain>`）
  经 `ReservedNamespace.claimed?/2` 明确排除在认领之外，所以**任意桶下形如 `minio/...`
  的 key 都不受影响**——`test/maxio/s3/reserved_namespace_addressing_test.exs` 对三个保留
  面逐一活体取证。曾经写在这里的"vhost 仍可读到这些 key"是对**保留桶自身**的错误断言
  （vhost 下 `minio.<domain>` 确实可达，但那要求配 DNS + `:s3, :domain`，而 path-style
  部署根本没有这条路），已删除，改由 `purge/1` + `mix maxio.reserved_bucket.purge` 给出
  真正可执行的出路。

  ## 纪律

    * `audit/1` **只报告**——不删除、不改名、不阻止启动。数据是运维的，maxio 无权代为处置；
      但运维必须知道**丢了哪些 key**，以及**怎么清理**，否则就是静默失败（铁律 3）。
    * 报告绝不静默截断：总数走精确聚合（不受列举上限影响），逐 key 列举有上限但会
      明说"还有多少条没列出、去哪儿看全量"。
    * `purge/1` 只在显式 `confirm_delete: true` 时才删，默认 dry-run。
    * `purge/1` **不是第二条删除通路**：它逐版本调用 S3 删除的唯一提交入口
      `Maxio.S3.Handlers.Object.delete_version!/4`（见下）。

  ## purge 必须走既有的删除提交路径（复审 C-1 / I-1）

  曾经的实现直接调 `Objects.delete_version/3`（无条件 `Repo.delete!`），等于把删除语义
  复制了第二份，同时丢掉了两件事：

    1. **Object Lock 强制**——COMPLIANCE 模式、保留期未过、legal hold ON 的版本被静默销毁，
       summary 还报 `deleted: 1, failed: 0`。COMPLIANCE 的 AWS/MinIO 语义是"保留期内任何
       用户（含 root）都不可删除"，这是不可逆的数据销毁 + 合规性破坏。
    2. **写权威分流**——`ObjectMeta.authoritative_source(:write) == :sidecar` 时 PG 行只是
       派生索引，删它只是 best-effort 索引维护；盘上 sidecar 仍在 → B5-2 扫描器会把行重新
       upsert，"已清除"的版本**复活**，且 reverse-GC 的"盘上还在就绝不删"不变式让该行永久存在。

  修法不是再补一道并行的锁检查（那正是病根），而是复用同一条链：对象锁 →
  `reject_locked_version_delete!` → 权威源分流 → 字节清理。被拒的版本进
  `summary.retained`，逐条带上锁的种类与到期时间，由 CLI 明说"该桶仍然无法清空，原因是 X"。

  ### 绕过：只对 GOVERNANCE 提供，且必须显式

  `purge(bypass_governance: true)`（CLI `--bypass-governance`）对齐 S3 的
  `x-amz-bypass-governance-retention`：只放行 GOVERNANCE 保留期，**COMPLIANCE 与 legal hold
  永不可绕过**（该语义单点落在 `Maxio.S3.ObjectLock.lock_status/2`，本模块只透传标志）。
  提供它的理由：GOVERNANCE 的设计意图本就是"有权限者可显式覆盖"，而影子化 key 恰恰是
  运维唯一的清理入口——不提供就会把一个本可解开的死局变成永久死局。授权边界：能在服务器上
  执行 mix 任务者即运维主体（对照 HTTP 路径的 `s3:BypassGovernanceRetention`）。
  """

  import Ecto.Query

  alias Maxio.Buckets.Bucket
  alias Maxio.ObjectMeta
  alias Maxio.Objects.Object
  alias Maxio.Repo
  alias Maxio.S3.Handlers.Object, as: ObjectHandler
  alias Maxio.S3.{Error, Log, ObjectLock, ReservedNamespace}

  # 日志单行里最多逐个点名的 key 数；超出只报总数并指向 CLI（日志行不是数据导出通道）。
  @report_limit 50

  @purge_task "mix maxio.reserved_bucket.purge"

  @type shadowed_key :: {String.t(), String.t()}

  @doc """
  被保留面影子化的 `{bucket, key}`（升序去重）。opts：`:repo`（默认 `Maxio.Repo`）、
  `:limit`（默认不限——调用方要全量时不该被悄悄截断）、`:bucket`（只看某个桶）。
  """
  @spec shadowed_keys(keyword()) :: [shadowed_key()]
  def shadowed_keys(opts \\ []) do
    repo = repo(opts)

    Object
    |> where(^shadowed_conditions())
    |> scope_bucket(Keyword.get(opts, :bucket))
    |> select([o], {o.bucket_name, o.key})
    |> distinct(true)
    |> order_by([o], asc: o.bucket_name, asc: o.key)
    |> maybe_limit(Keyword.get(opts, :limit))
    |> repo.all()
  end

  @doc """
  精确统计：`%{total: 去重 key 总数, by_bucket: %{bucket => 去重 key 数}}`。
  聚合在 SQL 侧完成，**不受任何列举上限影响**——报告的总数永远是真数（I1）。
  """
  @spec shadowed_key_counts(keyword()) :: %{total: non_neg_integer(), by_bucket: map()}
  def shadowed_key_counts(opts \\ []) do
    repo = repo(opts)

    by_bucket =
      Object
      |> where(^shadowed_conditions())
      |> group_by([o], o.bucket_name)
      |> select([o], {o.bucket_name, count(o.key, :distinct)})
      |> repo.all()
      |> Map.new()

    %{total: by_bucket |> Map.values() |> Enum.sum(), by_bucket: by_bucket}
  end

  @doc "被影子化的对象**版本行**（每个 key 的所有版本，含 delete marker）。"
  @spec shadowed_objects(keyword()) :: [Object.t()]
  def shadowed_objects(opts \\ []) do
    repo = repo(opts)

    Object
    |> where(^shadowed_conditions())
    |> scope_bucket(Keyword.get(opts, :bucket))
    |> order_by([o], asc: o.bucket_name, asc: o.key, asc: o.version_id)
    |> maybe_limit(Keyword.get(opts, :limit))
    |> repo.all()
  end

  @doc """
  审计并打结构化日志。有影子化 key → error（含精确总数 + 有界列举 + 清理指引）；
  保留桶存在但暂无影子化 key → warning；两者皆无 → 静默。
  永远返回 `:ok`——审计绝不阻止启动。
  """
  @spec audit(keyword()) :: :ok
  def audit(opts \\ []) do
    counts = shadowed_key_counts(opts)
    report_limit = Keyword.get(opts, :report_limit, @report_limit)

    cond do
      counts.total > 0 ->
        report_shadowed(counts, shadowed_keys(Keyword.put(opts, :limit, report_limit)))

      reserved_bucket_exists?(opts) ->
        report_reserved_bucket_present()

      true ->
        :ok
    end
  end

  @doc """
  清理被影子化的 key（C3 出路）。默认 **dry-run**；`confirm_delete: true` 才真删。

  为什么出路是 CLI 而不是"让 plug 放行 DELETE"：保留面认领的是**整个路径命名空间**，
  admin 面下每一条路径都被认领，靠"DELETE 时放行"只能救 health 两条，救不了 admin 前缀；
  而且那会让探针面的行为随数据状态漂移（同一个 DELETE 有时是探针 405、有时是删对象），
  并且 GET 仍被认领——运维能删却读不到自己要删的东西，比现在更糟。CLI 一条通路同时覆盖
  三个面、可先 dry-run 看清楚再删，且不依赖 DNS / vhost（AGENTS §4.4 CLI 优先）。

  opts：`:repo`、`:confirm_delete`（默认 false）、`:bucket`（只清某个桶）、
  `:bypass_governance`（默认 false，只放行 GOVERNANCE 保留期）、`:now`（判定保留期用的时刻）。

  返回 `{:ok, %{dry_run:, matched:, versions:, deleted:, retained:, retained_count:,
  failed:, errors:}}`。`retained` 是**被 Object Lock 拒绝、仍留在桶里**的版本，逐条含
  `reason`（`:legal_hold | :retention`）、`mode`、`retain_until`、`bypassable?`——
  留下没删是本操作最重要的产出之一，绝不允许只体现为 `deleted` 少了一个（铁律 3）。
  """
  @spec purge(keyword()) ::
          {:ok,
           %{
             dry_run: boolean(),
             matched: non_neg_integer(),
             versions: non_neg_integer(),
             deleted: non_neg_integer(),
             retained: [map()],
             retained_count: non_neg_integer(),
             failed: non_neg_integer(),
             errors: [map()]
           }}
  def purge(opts \\ []) do
    confirm? = Keyword.get(opts, :confirm_delete, false)
    lock_opts = lock_opts(opts)
    objects = shadowed_objects(opts)

    matched = objects |> Enum.map(&{&1.bucket_name, &1.key}) |> Enum.uniq() |> length()

    {deleted, retained, errors} =
      if confirm? do
        {deleted, retained, errors} =
          Enum.reduce(objects, {0, [], []}, &purge_version(&1, &2, lock_opts))

        {deleted, Enum.reverse(retained), Enum.reverse(errors)}
      else
        # dry-run 也必须**预告**哪些版本会被保留：一份声称"这些都能删"的预演，等到真删时
        # 才冒出一堆 AccessDenied，比不预演更糟（运维据它规划停机窗口）。预告与执行用的是
        # 同一个 `ObjectLock.lock_status/2`，绝不是第二套判定。
        {0, Enum.flat_map(objects, &List.wrap(retained_entry(&1, lock_opts))), []}
      end

    {:ok,
     %{
       dry_run: not confirm?,
       matched: matched,
       versions: length(objects),
       deleted: deleted,
       retained: retained,
       retained_count: length(retained),
       failed: length(errors),
       errors: errors
     }}
  end

  defp lock_opts(opts) do
    [
      now: Keyword.get(opts, :now) || DateTime.utc_now(),
      bypass_governance?: Keyword.get(opts, :bypass_governance, false) == true
    ]
  end

  # 逐版本走 S3 删除的唯一提交入口（对象锁 + Object Lock 拒绝 + 写权威分流 + 字节清理）。
  # 本函数**只负责归类结果**，绝不自己判定"能不能删"。
  defp purge_version(%Object{} = obj, {deleted, retained, errors}, lock_opts) do
    _target = ObjectHandler.delete_version!(obj.bucket_name, obj.key, obj.version_id, lock_opts)

    Log.info("shadowed key purged",
      bucket: obj.bucket_name,
      key: obj.key,
      version_id: obj.version_id,
      reason: "reserved_path_shadowed_key"
    )

    {deleted + 1, retained, errors}
  rescue
    err in Error ->
      # AccessDenied 是提交链里 `reject_locked_version_delete!` 的**唯一**来源（其余失败分别是
      # SlowDown / RequestTimeout / InternalError），故可无歧义地归为"被 Object Lock 保留"。
      if err.code == "AccessDenied" do
        entry = retained_entry(obj, lock_opts) || unexplained_retained_entry(obj)

        Log.warn("shadowed key retained: object lock forbids deletion",
          bucket: obj.bucket_name,
          key: obj.key,
          version_id: obj.version_id,
          code: err.code,
          reason: "object_lock_#{entry.reason}"
        )

        {deleted, [entry | retained], errors}
      else
        reason = "#{err.code}: #{err.message}"

        Log.error("shadowed key purge failed",
          bucket: obj.bucket_name,
          key: obj.key,
          version_id: obj.version_id,
          code: err.code,
          reason: reason
        )

        {deleted, retained,
         [
           %{
             bucket: obj.bucket_name,
             key: obj.key,
             version_id: obj.version_id,
             reason: reason
           }
           | errors
         ]}
      end
  end

  # 解释"为什么留着"。判定与解释同源（`ObjectLock.lock_status/2`），且读的是**写权威**认可的
  # 那份元数据（`ObjectMeta.get`，与提交链内的拒绝判定读同一个入口），避免 :sidecar 权威下
  # 拿 PG 派生索引去解释一个由盘上 sidecar 作出的拒绝。未锁 → nil。
  defp retained_entry(%Object{} = obj, lock_opts) do
    source =
      case ObjectMeta.get(obj.bucket_name, obj.key, obj.version_id, []) do
        %Object{} = authoritative -> authoritative
        _other -> obj
      end

    case ObjectLock.lock_status(source, lock_opts) do
      :unlocked ->
        nil

      status ->
        Map.merge(
          %{bucket: obj.bucket_name, key: obj.key, version_id: obj.version_id},
          status
        )
    end
  end

  # 提交链拒绝了，但事后复读时锁已解除（并发 PutObjectLegalHold / 保留期恰好到期）。
  # 拒绝是权威的，仍必须记为保留——绝不因为解释不出来就把它从报告里抹掉（铁律 3）。
  defp unexplained_retained_entry(%Object{} = obj) do
    %{
      bucket: obj.bucket_name,
      key: obj.key,
      version_id: obj.version_id,
      reason: :object_lock,
      mode: nil,
      retain_until: nil,
      bypassable?: false
    }
  end

  defp scope_bucket(query, nil), do: query

  defp scope_bucket(query, bucket) when is_binary(bucket),
    do: where(query, [o], o.bucket_name == ^bucket)

  defp reserved_bucket_exists?(opts) do
    repo = repo(opts)
    names = ReservedNamespace.reserved_bucket_names()

    Bucket |> where([b], b.name in ^names) |> repo.exists?()
  end

  defp report_reserved_bucket_present do
    Log.warn(
      "reserved bucket #{inspect(ReservedNamespace.bucket())} already exists (created before the " <>
        "name was reserved); no object key is shadowed by reserved /minio paths right now, but the " <>
        "name can no longer be re-created and keys under " <>
        Enum.map_join(ReservedNamespace.shadowed_targets(), ", ", fn {_b, _kind, key} -> key end) <>
        " would become unreachable in path-style addressing",
      bucket: ReservedNamespace.bucket(),
      reason: "reserved_bucket_present"
    )
  end

  defp report_shadowed(counts, listed) do
    omitted = counts.total - length(listed)

    suffix =
      if omitted > 0,
        do:
          " (+#{omitted} more not listed here; the count above is exact — run " <>
            "`#{@purge_task} --dry-run` for the full list)",
        else: ""

    Log.error(
      "reserved /minio paths shadow #{counts.total} object key(s) " <>
        "(#{format_by_bucket(counts.by_bucket)}): they are unreachable in path-style addressing " <>
        "because the health, admin and prometheus surfaces claim those paths, so they can neither " <>
        "be read nor deleted through the S3 API and their bucket can never be emptied. " <>
        "maxio never deletes them on its own — run `#{@purge_task} --dry-run` to inspect and " <>
        "`#{@purge_task} --confirm-delete` to clean up. Shadowed keys: " <>
        Enum.map_join(listed, ", ", fn {bucket, key} -> bucket <> "/" <> key end) <> suffix,
      bucket: counts.by_bucket |> Map.keys() |> Enum.sort() |> Enum.join(","),
      reason: "reserved_path_shadowed_keys"
    )
  end

  defp format_by_bucket(by_bucket) do
    by_bucket
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map_join(", ", fn {bucket, count} -> "#{bucket}: #{count}" end)
  end

  # 扫描条件逐条派生自认领规则的对象命名空间投影：exact 规则 → 等值匹配，
  # prefix 规则 → 前缀 LIKE。两者与 plug 的认领判定同源，扫描面恒等于认领面。
  defp shadowed_conditions do
    Enum.reduce(ReservedNamespace.shadowed_targets(), dynamic(false), fn
      {bucket, :exact, key}, acc ->
        dynamic([o], ^acc or (o.bucket_name == ^bucket and o.key == ^key))

      {bucket, :prefix, key}, acc ->
        pattern = like_prefix_pattern!(key) <> "%"
        dynamic([o], ^acc or (o.bucket_name == ^bucket and like(o.key, ^pattern)))
    end)
  end

  # 认领前缀是代码里的字面量。万一将来有人写进 LIKE 通配符，粗筛就会悄悄多匹配一批
  # 无辜 key（审计误报、purge 误删）——这里硬失败，绝不带着歧义继续扫（铁律 3）。
  defp like_prefix_pattern!(prefix) do
    if String.contains?(prefix, ["%", "_", "\\"]) do
      raise ArgumentError,
            "reserved namespace prefix #{inspect(prefix)} contains LIKE metacharacters; " <>
              "the audit scan would silently over-match"
    end

    prefix
  end

  defp maybe_limit(query, nil), do: query
  defp maybe_limit(query, limit) when is_integer(limit) and limit > 0, do: limit(query, ^limit)

  defp repo(opts), do: Keyword.get(opts, :repo, Repo)
end
