# MinIO/S3 保真度修复 实现计划 · maxio（FIDELITY-FIX · 1 critical + 7 high + 5 medium）

> For agentic workers（executor）：严格按批次 **BATCH 1 → BATCH 2 → BATCH 3** 顺序、批内按单元 **FX-C1 / FX-H1..FX-H7 / FX-M1..FX-M5** 顺序执行。逻辑性修复用 **TDD**（先写"断言已修正的真实 MinIO/S3 行为"的失败测试 → 跑确认红 → 最小实现 → 跑确认绿 → commit）；纯表/视图/配置类改动用「执行命令 + 验证输出」。每个单元都给了**精确文件路径、完整可用代码（禁止占位符 / TODO / 省略号）、要加的测试、确切 PowerShell 命令与期望输出**。复用既有模块时逐字照抄其现有签名（`Objects.delete_version/3`、`Objects.insert_delete_marker/3`、`Objects.put_version_with_id/4`、`Storage.get/4`、`Statement.parse_policy/1`、`Arn.object_arn/2`、`Canonical.uri_encode/2`、`Error.new/2` 等）。
>
> **本计划修复一次独立 MinIO/S3 保真度审计发现的 13 个真实偏差**（1 critical + 7 high + 5 medium）：它们"过得了 maxio 自己的测试，却会破坏真实客户端或静默丢数据"。审计全文（JSON）在 `tasks/wazdy5gh6.output`。低优先级 12 项见末尾「§ 已推迟（low）」节，本计划不实现。
>
> **铁律对齐（AGENTS.md §3/§4/§5，违反即返工）**：
> - **铁律 2（禁止打补丁式修复）**：每个修复从架构层解决、复用既有正确路径（如 DeleteObjects 批删复用单删 `Object.delete/1` 已正确的 versioning 分支；CopyObject 复用 `do_put` 的版本路径），绝不局部 hack。
> - **铁律 3（绝不静默）**：所有新行为返回结构化 S3 错误（XML + 正确 HTTP 状态）+ 结构化日志；新错误码进 `Maxio.S3.Error` @table（如 `:unsigned_headers` → AccessDenied/400、`:maximum_expires` → MaximumExpires/400）。绝不静默丢数据、绝不静默返回错数据、绝不"返回 200 但语义不同"。
> - **铁律 4（body 绝不进内存）**：CopyObject 修复保持现有逐流 `Storage.get → Storage.put`，绝不全缓冲；DeleteObjects/policy 仍走带上限小 XML/JSON 整读。
> - **铁律 5（S3 行为对齐真实 AWS/MinIO）**：错误码/状态、XML 元素、`x-amz-version-id`/`x-amz-copy-source-version-id` 头、SigV4 canonical 规范、policy ARN 校验，全部以 AWS S3 API Reference / SigV4 文档 / MinIO 源为准（每单元注明 source）。
> - **作者/审查隔离（铁律 §4.1）**：本计划由 executor 实现；每个单元收尾由**独立** `code-reviewer`/`verifier`（不同上下文）跑验证命令取证，实现者不得自审。
>
> **完成判据（每单元）**：`mix compile --warnings-as-errors` 零警告 + 该单元新测试绿 + 全量 `mix test` 绿（当前基线 **510 passing**，本计划每单元只增不减）。

---

## 环境约束（每条命令都必须遵守）

- **本机**：Windows 11 + PowerShell。Elixir 1.20 / OTP 28，位于 `C:\Users\dyz\Documents\dev\usr\Elixir\bin`。rustc/cargo 已在 PATH。
- **跑任何 mix 命令前必设**（否则编译期中文输出重定向到非 TTY 触发 `io.put_chars badarg` 硬崩、留 `erl_crash.dump`）：
  ```powershell
  $env:Path = 'C:\Users\dyz\Documents\dev\usr\Elixir\bin;' + $env:Path
  $env:ERL_FLAGS = '-kernel standard_io_encoding unicode'
  ```
  本计划所有 PowerShell 命令块**默认已假设当前会话已设此两变量**；每个新 shell 会话第一条命令前先执行它。
- **Postgres**：docker 容器 `maxio-db`（postgres:16，localhost:5432，user/pass=postgres/postgres，dev 库 `maxio_dev`，test 库 `maxio_test`）。`psql` 不在 PATH，经容器：`docker exec maxio-db psql -U postgres -d maxio_dev -c "..."`。`mix test` 自动迁移 test 库。`docker start maxio-db` 恢复容器。**本计划不动 DB schema**（`objects` 表已含 `metadata`/`tags` 列；policy 走 jsonb）。
- **无 aws-cli / boto3 / mc / python**。端到端验证用既有「我们签→我们验」辅助 `Maxio.Test.SigV4Request`（`signed_conn/3`、`anon_conn/3`、`signed_chunked_conn/4`）经 `Maxio.S3.Endpoint` 打全管线（AddressStyle→Cors→SigV4→Dispatch→Authz→Handler→XML）。SigV4 `'+'` 修复另用纯函数单测直接构造 raw query string（绕过 `URI.encode_query`，因后者会把 `+` 编成 `%2B` 而辅助走 map）。
- **测试禁忌（AGENTS.md Test guidelines）**：用 `start_supervised!/1` 起进程；**禁用** `Process.sleep/1`/`Process.alive?/1`。本计划测试均为 HTTP 端到端或纯函数，无需起额外进程。data_dir 隔离用各测试文件的 `setup`（见 `versioning_object_test.exs` 模板：临时 dir + `Application.put_env(:maxio, :s3, ...)` + `on_exit` 还原）。
- **提交**：每个单元一次 commit，message footer 固定一行：
  `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`
  当前分支 `master`；本计划全部提交到当前分支（无需开新分支，除非用户另行要求）。

---

## Goal

把 maxio 从「常见非版本化单客户端路径高保真」推进到「版本化 / copy / authz / CORS 边界也对齐真实 S3」：

1. **止血（BATCH 1，紧急）**：消除 **唯一 critical 数据丢失** —— `DeleteObjects`（POST ?delete）丢弃 per-object VersionId、对版本化桶硬删每个 key 的全部版本（绕过 delete marker）。改为像单删那样按 VersionId / 桶 versioning 分支：给 VersionId 则永久删该版本，未给且桶 Enabled/Suspended 则插 delete marker，未版本化才硬删。
2. **高危修复（BATCH 2）**：7 个 high —— CopyObject 源按真实版本读字节（不再硬编码 `"null"`）、CopyObject 目标按桶 versioning 落新版本并回 `x-amz-version-id`/`x-amz-copy-source-version-id`、SigV4 `'+'`-in-query raw canonicalization、PutBucketPolicy 校验 Resource ARN 引用目标桶、CORS `Access-Control-Allow-Credentials`、DeleteObjects authz 改对象级逐 key、CopyObject 目标 authz 改对象级（去掉桶级粗门）。
3. **中危修复（BATCH 3）**：5 个 medium —— SigV4 强制 host 进 SignedHeaders（`:unsigned_headers` 错误码）、CopyObject COPY 保留 metadata/tags、ListObjectsV2 与 ListObjectVersions 支持 `encoding-type=url`、PutBucketPolicy 拒绝不支持的 Condition 算子（400 MalformedPolicy）。

**显式不做（DEFER，文档化、绝不静默）**：见末尾「§ 已推迟（low）」。

---

## 架构（修复点在既有管线中的落位 —— 核心管线不重写）

```
S3 客户端 → Endpoint → AddressStyle → Cors（★FX-H5：ACAC:true）→ SigV4（★FX-H3：raw query；★FX-M1：host 必签）
   → Dispatch → Authz（★FX-H6/H7：DeleteObjects/Copy 对象级 ARN）→ Handler
        ├─ Object.delete_objects/1 （★FX-C1：versioning 分支 + per-VersionId）
        ├─ Object.copy/1 + copy_bytes/5 + parse_copy_source!/1 （★FX-H1/H2/M4：源真实版本 / 目标新版本 / metadata+tags）
        └─ Bucket.list_objects_v2/1 · list_object_versions/1 （★FX-M2/M3：encoding-type=url）
   BucketPolicy.put/1 → Statement.parse_policy/2 （★FX-H4：Resource 引用桶；★FX-M5：未知 Condition 算子拒绝）

复用既有正确零件（一行不改其语义，只被调用）：
  Maxio.Objects.{delete_version/3, insert_delete_marker/3, put_version_with_id/4, get_metadata/2, get_version/3}
  Maxio.Storage.{get/4, put/5, delete/3}
  Maxio.Versioning.VersionId.generate/0
  Maxio.Policy.{Arn.object_arn/2, Evaluator.evaluate/2, RequestContext}
  Maxio.Auth.SigV4.Canonical.uri_encode/2
  Maxio.S3.Error.new/2（新增 @table 条目）
```

新错误码（进 `Maxio.S3.Error` @table）：
- `:unsigned_headers` → `{"AccessDenied", 400, "There were headers present in the request which were not signed"}`（FX-M1，对齐 MinIO `ErrUnsignedHeaders`；**不复用** 403 的 `access_denied`）。

---

## 单元总览（按批次 / 依赖串行；每单元结束须 green compile + 测试通过 + 一次 commit）

| 批次 | 单元 | 标题 | 严重度 | 依赖 |
|---|---|---|---|---|
| **1** | **FX-C1** | DeleteObjects 尊重 per-object VersionId + 桶 versioning（止数据丢失） | critical | 基线 |
| **2** | **FX-H1** | CopyObject 源按真实版本读字节 + 解析 `?versionId=` | high | FX-C1 |
| **2** | **FX-H2** | CopyObject 目标按桶 versioning 落新版本 + 回 `x-amz-version-id`/`x-amz-copy-source-version-id` | high | FX-H1 |
| **2** | **FX-H3** | SigV4 从 raw query 规范化（`'+'` 不再误当空格） | high | 基线 |
| **2** | **FX-H4** | PutBucketPolicy 校验 Resource ARN 引用目标桶 | high | 基线 |
| **2** | **FX-H5** | CORS 设 `Access-Control-Allow-Credentials: true` | high | 基线 |
| **2** | **FX-H6** | DeleteObjects authz 改对象级逐 key | high | FX-C1 |
| **2** | **FX-H7** | CopyObject 目标 authz 改对象级 ARN | high | 基线 |
| **3** | **FX-M1** | SigV4 强制 host 进 SignedHeaders（`:unsigned_headers`） | medium | FX-H3 |
| **3** | **FX-M2** | ListObjectsV2 支持 `encoding-type=url` | medium | 基线 |
| **3** | **FX-M3** | ListObjectVersions 支持 `encoding-type=url` | medium | FX-M2 |
| **3** | **FX-M4** | CopyObject COPY 保留源 metadata/tags | medium | FX-H2 |
| **3** | **FX-M5** | PutBucketPolicy 拒绝不支持的 Condition 算子（400 MalformedPolicy） | medium | FX-H4 |

**执行顺序**：FX-C1 → (FX-H1 → FX-H2) → FX-H3 → FX-H4 → FX-H5 → (FX-H6) → FX-H7 → FX-M1 → (FX-M2 → FX-M3) → FX-M4 → FX-M5。**串行执行，禁止并行 mix 编译**（避免锁文件竞争）。

---

# BATCH 1 — CRITICAL 止血（紧急，单独先跑）

## FX-C1 · DeleteObjects 尊重 per-object VersionId 与桶 versioning（消除版本化桶静默永久丢数据）

**偏差（critical）**：`DeleteObjects ignores per-object VersionId and bypasses bucket versioning entirely (data loss on versioned buckets)`。

**maxio 现状**（`lib/maxio/s3/handlers/object.ex` `delete_objects/1`，第 304-310 行）：
```elixir
Enum.reduce(objects, {[], []}, fn %{key: key}, {dacc, eacc} ->
  :ok = Objects.delete_metadata(bucket, key)   # Repo.delete_all 删该 key 全部版本行
  _ = Storage.delete(bucket, key)              # 删整个 key 字节
  {[key | dacc], eacc}
end)
```
解析器 `request_parsers/delete.ex` 已正确抽出 per-object `version_id`，但 handler 用 `%{key: key}` 丢弃它；桶 versioning 从不读取；响应 `views/delete_result.ex` 只发 `<Deleted><Key>`，从不发 `<VersionId>`/`<DeleteMarker>`/`<DeleteMarkerVersionId>`。在版本化桶上：无 VersionId 不插 delete marker、有 VersionId 也照样删全部版本 → **静默永久丢数据**。

**MinIO/S3 正确行为**（AWS DeleteObjects Response Syntax；MinIO `cmd/bucket-handlers.go DeleteMultipleObjectsHandler`）：
- `<Object>` 含 `<VersionId>` → 永久删该特定版本，回 `<Deleted><Key><VersionId>`；若该版本是 delete marker，另回 `<DeleteMarker>true</DeleteMarker>`。
- `<Object>` 无 `<VersionId>` 且桶 versioning ∈ {Enabled,Suspended} → 插 delete marker，回 `<DeleteMarker>true</DeleteMarker><DeleteMarkerVersionId>=新 id`（外加 `<Key>`）。
- 未版本化桶（Unversioned）→ 硬删（现有路径）。
注意 maxio **单删 `Object.delete/1`（第 239-286 行）已正确实现以上全部分支**——本单元就是让批删复用相同逻辑（铁律 2：复用既有正确路径，不另起 hack）。
**source**：https://docs.aws.amazon.com/AmazonS3/latest/API/API_DeleteObjects.html

### 完整修复

**(1) `lib/maxio/s3/handlers/object.ex` — 重写 `delete_objects/1` 的 reduce + 响应构造。**

把现有第 304-323 行（从 `{deleted, errors} =` 到函数末的 `send_resp(200, body)`）整体替换为：

```elixir
    versioning = bucket_versioning(bucket)

    {deleted, errors} =
      Enum.reduce(objects, {[], []}, fn obj, {dacc, eacc} ->
        case delete_one(bucket, obj, versioning) do
          {:ok, entry} -> {[entry | dacc], eacc}
          {:error, err} -> {dacc, [err | eacc]}
        end
      end)

    Log.info("delete objects",
      action: :delete_objects,
      bucket: bucket,
      size: length(objects),
      deleted: length(deleted),
      errors: length(errors)
    )

    body =
      DeleteResult.render(%{
        deleted: if(quiet, do: [], else: Enum.reverse(deleted)),
        errors: Enum.reverse(errors)
      })

    conn
    |> put_resp_content_type("application/xml")
    |> send_resp(200, body)
  end

  # 单个 <Object> 删除：镜像 Object.delete/1 的 versioning 分支（铁律 2 复用既有正确语义）。
  # 返回 {:ok, deleted_entry_map} | {:error, error_entry_map}。
  # deleted_entry_map 字段：:key 必有；:version_id / :delete_marker / :delete_marker_version_id 可选。
  defp delete_one(bucket, %{key: key, version_id: version_id}, versioning) do
    cond do
      version_id != nil ->
        # 永久删指定版本（含 delete marker）。幂等：删不存在的版本也算成功。
        case Objects.delete_version(bucket, key, version_id) do
          {:ok, %{was_delete_marker: dm?}} ->
            _ = Storage.delete(bucket, key, version_id)
            {:ok, %{key: key, version_id: version_id, delete_marker: dm?}}

          {:error, :not_found} ->
            {:ok, %{key: key, version_id: version_id, delete_marker: false}}
        end

      versioning in ["Enabled", "Suspended"] ->
        # 无 VersionId 且版本化桶 → 插 delete marker（绝不硬删历史版本）。
        {:ok, %{version_id: dm_vid}} = Objects.insert_delete_marker(bucket, key, versioning)
        {:ok, %{key: key, delete_marker: true, delete_marker_version_id: dm_vid}}

      true ->
        # 未版本化桶 → 硬删（删 null 行 + 字节）。缺失 key 也算成功（S3 语义）。
        :ok = Objects.delete_metadata(bucket, key)
        _ = Storage.delete(bucket, key)
        {:ok, %{key: key}}
    end
  end
```

> 说明：`delete_one/3` 中 `version_id`/`delete_marker_version_id` 当为 `"null"`（Suspended 桶）时仍如实放进 entry，由 view 决定是否渲染 `<VersionId>`（对齐单删 `maybe_put_version_id` 的"null 不回显"语义——见下方 view 对 `"null"` 的处理）。本单元不动 authz（DeleteObjects 仍走桶级 `s3:DeleteObject` 粗门，对象级细化在 **FX-H6**）。

**(2) `lib/maxio/s3/views/delete_result.ex` — 扩展 `render/1` 携带 version_id / delete_marker / delete_marker_version_id。**

整文件替换为：

```elixir
defmodule Maxio.S3.Views.DeleteResult do
  @moduledoc """
  DeleteObjects 响应 XML（DeleteResult）。verbose 含每个 Deleted；quiet 仅 Error。
  每个 Deleted 可携带 version_id / delete_marker / delete_marker_version_id（版本化语义，
  对齐 AWS DeleteObjects Response Syntax: DeletedObject = Key, VersionId, DeleteMarker,
  DeleteMarkerVersionId）。version_id == "null" 不渲染 <VersionId>（对齐 AWS 不回显 null 版本）。
  """
  import Saxy.XML
  alias Maxio.S3.XML

  @type deleted_entry :: %{
          required(:key) => String.t(),
          optional(:version_id) => String.t() | nil,
          optional(:delete_marker) => boolean(),
          optional(:delete_marker_version_id) => String.t() | nil
        }

  @spec render(%{
          deleted: [deleted_entry()],
          errors: [%{key: String.t(), code: String.t(), message: String.t()}]
        }) :: iodata()
  def render(%{deleted: deleted, errors: errors}) do
    deleted_elems = Enum.map(deleted, &deleted_elem/1)

    error_elems =
      Enum.map(errors, fn e ->
        element("Error", [], [
          element("Key", [], characters(e.key)),
          element("Code", [], characters(e.code)),
          element("Message", [], characters(e.message))
        ])
      end)

    root = element("DeleteResult", [{"xmlns", XML.namespace()}], deleted_elems ++ error_elems)
    XML.encode(root)
  end

  defp deleted_elem(entry) do
    children =
      [element("Key", [], characters(entry.key))]
      |> maybe_version_id(Map.get(entry, :version_id))
      |> maybe_delete_marker(Map.get(entry, :delete_marker, false))
      |> maybe_delete_marker_version_id(Map.get(entry, :delete_marker_version_id))

    element("Deleted", [], children)
  end

  # 永久删指定版本时回 <VersionId>；"null"/nil 不渲染（对齐 AWS）。
  defp maybe_version_id(children, nil), do: children
  defp maybe_version_id(children, "null"), do: children
  defp maybe_version_id(children, vid),
    do: children ++ [element("VersionId", [], characters(vid))]

  defp maybe_delete_marker(children, true),
    do: children ++ [element("DeleteMarker", [], characters("true"))]

  defp maybe_delete_marker(children, _), do: children

  defp maybe_delete_marker_version_id(children, nil), do: children
  defp maybe_delete_marker_version_id(children, "null"), do: children

  defp maybe_delete_marker_version_id(children, vid),
    do: children ++ [element("DeleteMarkerVersionId", [], characters(vid))]
end
```

### 测试（断言已修正的 MinIO/S3 行为）

新建 `test/maxio/s3/delete_objects_versioning_test.exs`（模板照 `versioning_object_test.exs`：临时 data_dir + `setup`/`on_exit`；`call/1` = `Endpoint.call(conn, Endpoint.init([]))`；versioning 经 `signed_conn(:put, "/bucket", query: %{"versioning" => ""}, body: ...)` 开启）。覆盖三个 case，**断言批删后历史版本仍存活**：

```elixir
defmodule Maxio.S3.DeleteObjectsVersioningTest do
  use Maxio.DataCase, async: false

  import Plug.Conn
  alias Maxio.Test.SigV4Request
  alias Maxio.S3.Endpoint

  @data_dir Path.join(System.tmp_dir!(), "maxio_delobjs_ver_test")

  setup do
    File.rm_rf(@data_dir)
    File.mkdir_p!(@data_dir)
    prev = Application.get_env(:maxio, :s3)
    Application.put_env(:maxio, :s3, Keyword.put(prev, :data_dir, @data_dir))
    on_exit(fn ->
      Application.put_env(:maxio, :s3, prev)
      File.rm_rf(@data_dir)
    end)
    :ok
  end

  defp call(conn), do: Endpoint.call(conn, Endpoint.init([]))

  defp enable_versioning(bucket) do
    body = ~s(<VersioningConfiguration><Status>Enabled</Status></VersioningConfiguration>)
    SigV4Request.signed_conn(:put, "/#{bucket}", query: %{"versioning" => ""}, body: body) |> call()
  end

  defp delete_objects(bucket, body) do
    SigV4Request.signed_conn(:post, "/#{bucket}", query: %{"delete" => ""}, body: body) |> call()
  end

  test "Enabled 桶 + 无 VersionId 的批删 → 插 delete marker，历史版本不丢" do
    SigV4Request.signed_conn(:put, "/dob1") |> call()
    enable_versioning("dob1")
    p1 = SigV4Request.signed_conn(:put, "/dob1/k.txt", body: "v1") |> call()
    [vid1] = get_resp_header(p1, "x-amz-version-id")

    body = ~s(<Delete><Object><Key>k.txt</Key></Object></Delete>)
    res = delete_objects("dob1", body)
    assert res.status == 200
    assert res.resp_body =~ "<DeleteMarker>true</DeleteMarker>"
    assert res.resp_body =~ "<DeleteMarkerVersionId>"

    # 简单 GET → 404 + delete marker（current 是 marker）
    g = SigV4Request.signed_conn(:get, "/dob1/k.txt") |> call()
    assert g.status == 404
    assert get_resp_header(g, "x-amz-delete-marker") == ["true"]

    # 旧版本字节仍可经 ?versionId 取回（未被硬删——这正是 critical 修复点）
    old = SigV4Request.signed_conn(:get, "/dob1/k.txt", query: %{"versionId" => vid1}) |> call()
    assert old.status == 200
    assert old.resp_body == "v1"
  end

  test "Enabled 桶 + 指定 VersionId 的批删 → 只永久删该版本，其余版本存活" do
    SigV4Request.signed_conn(:put, "/dob2") |> call()
    enable_versioning("dob2")
    p1 = SigV4Request.signed_conn(:put, "/dob2/k.txt", body: "first") |> call()
    [vid1] = get_resp_header(p1, "x-amz-version-id")
    p2 = SigV4Request.signed_conn(:put, "/dob2/k.txt", body: "second") |> call()
    [vid2] = get_resp_header(p2, "x-amz-version-id")

    body = ~s(<Delete><Object><Key>k.txt</Key><VersionId>#{vid1}</VersionId></Object></Delete>)
    res = delete_objects("dob2", body)
    assert res.status == 200
    assert res.resp_body =~ "<VersionId>#{vid1}</VersionId>"

    # vid1 已删
    g1 = SigV4Request.signed_conn(:get, "/dob2/k.txt", query: %{"versionId" => vid1}) |> call()
    assert g1.status == 404
    # vid2 存活
    g2 = SigV4Request.signed_conn(:get, "/dob2/k.txt", query: %{"versionId" => vid2}) |> call()
    assert g2.status == 200
    assert g2.resp_body == "second"
  end

  test "未版本化桶批删 → 硬删（现有语义保留），quiet=false 回 <Deleted><Key>" do
    SigV4Request.signed_conn(:put, "/dob3") |> call()
    SigV4Request.signed_conn(:put, "/dob3/k.txt", body: "x") |> call()

    body = ~s(<Delete><Object><Key>k.txt</Key></Object></Delete>)
    res = delete_objects("dob3", body)
    assert res.status == 200
    assert res.resp_body =~ "<Deleted><Key>k.txt</Key></Deleted>"
    refute res.resp_body =~ "<DeleteMarker>"

    g = SigV4Request.signed_conn(:get, "/dob3/k.txt") |> call()
    assert g.status == 404
  end
end
```

### 验证命令（期望输出）

```powershell
$env:Path = 'C:\Users\dyz\Documents\dev\usr\Elixir\bin;' + $env:Path
$env:ERL_FLAGS = '-kernel standard_io_encoding unicode'
mix test test/maxio/s3/delete_objects_versioning_test.exs
# 期望：3 tests, 0 failures
mix compile --warnings-as-errors
# 期望：无警告退出（仅 Generated maxio app 之类）
mix test
# 期望：全绿，failures 0，总数 = 510 + 3 = 513（计数随后续单元增长）
```

**Acceptance**：版本化桶 DeleteObjects 不再硬删历史版本；无 VersionId 插 delete marker（回 DeleteMarker/DeleteMarkerVersionId），有 VersionId 只永久删该版本（回 VersionId），未版本化桶硬删；全量测试绿。
**Commit**：`fix(s3): DeleteObjects honors per-object VersionId and bucket versioning (no data loss)`。

---

# BATCH 2 — HIGH 修复

## FX-H1 · CopyObject 源按真实版本读字节 + 解析 `?versionId=`

**偏差（high）**：`CopyObject reads source bytes only from the hardcoded "null" version`。

**maxio 现状**（`object.ex` `copy_bytes/5` 两个子句，第 393-411 行）调 `Storage.get(src_bucket, src_key, "null", nil)`；版本化源的当前对象字节落在 ULID version_id 路径（`Objects.put_version_with_id` 写 `version_id != "null"`），`"null"` 路径不存在 → copy 静默产生 0 字节/出错目标。`parse_copy_source!/1`（第 432-442 行）还把 `?versionId=` 直接丢弃。

**MinIO/S3 正确行为**：`x-amz-copy-source` 默认标识源的**当前版本**（可经 `?versionId=` 选特定版本），S3 拷贝其真实字节。
**source**：https://docs.aws.amazon.com/AmazonS3/latest/API/API_CopyObject.html

### 完整修复（`lib/maxio/s3/handlers/object.ex`）

**(1) `parse_copy_source!/1` 返回 `{bucket, key, src_version_id}`（解析 `?versionId=`，无则 `nil`）。** 替换第 432-442 行：

```elixir
  # x-amz-copy-source 解析："/srcBucket/srcKey[?versionId=v]" | "srcBucket/srcKey[?versionId=v]"
  # （URL 编码）。返回 {bucket, key, version_id | nil}。
  defp parse_copy_source!(raw) do
    decoded = URI.decode(raw)
    trimmed = String.replace_prefix(decoded, "/", "")

    {path, version_id} =
      case String.split(trimmed, "?", parts: 2) do
        [p] -> {p, nil}
        [p, q] -> {p, copy_source_version_id(q)}
      end

    case String.split(path, "/", parts: 2) do
      [bucket, key] when key != "" -> {bucket, key, version_id}
      _ -> raise Error.new(:invalid_argument, message: "Invalid x-amz-copy-source")
    end
  end

  # 从 copy-source 查询串提取 versionId（无则 nil）。
  defp copy_source_version_id(query) do
    query
    |> URI.decode_query()
    |> Map.get("versionId")
    |> case do
      v when is_binary(v) and v != "" -> v
      _ -> nil
    end
  end
```

**(2) `copy/1` 解构三元组并解析源对象的真实 version_id。** 在 `copy/1`（第 325-390 行）内：

把第 331-332 行
```elixir
    {src_bucket, src_key} = parse_copy_source!(header(conn, "x-amz-copy-source"))
    {src_obj, _total} = object_or_raise(src_bucket, src_key)
```
替换为
```elixir
    {src_bucket, src_key, src_version_id} =
      parse_copy_source!(header(conn, "x-amz-copy-source"))

    {src_obj, _total} = object_or_raise(src_bucket, src_key, src_version_id)
```

把第 363-365 行
```elixir
    self_copy? = src_bucket == dest_bucket and src_key == dest_key

    {size, etag} = copy_bytes(self_copy?, src_bucket, src_key, dest_bucket, dest_key)
```
替换为
```elixir
    self_copy? = src_bucket == dest_bucket and src_key == dest_key

    {size, etag} =
      copy_bytes(self_copy?, src_bucket, src_key, src_obj.version_id, dest_bucket, dest_key)
```

> 说明：`src_obj` 现在是「指定版本」或「当前 latest」对应的 Object 行（含其真实 `version_id`，版本化源为 ULID、未版本化源为 `"null"`），所以 `src_obj.version_id` 就是要读字节的真实版本路径。

**(3) `object_or_raise/2` → `object_or_raise/3`（支持 version_id）。** 替换第 580-587 行：

```elixir
  # version_id == nil → 取当前版本（latest）；否则取指定版本行。缺失 → NoSuchKey。
  defp object_or_raise(bucket, key, version_id \\ nil)

  defp object_or_raise(bucket, key, nil) do
    _ = ensure_bucket!(bucket)

    case Objects.get_metadata(bucket, key) do
      {:ok, object} -> {object, object.size}
      {:error, :not_found} -> raise Error.new(:no_such_key, resource: "/#{bucket}/#{key}")
    end
  end

  defp object_or_raise(bucket, key, version_id) do
    _ = ensure_bucket!(bucket)

    case Objects.get_version(bucket, key, version_id) do
      {:ok, object} -> {object, object.size}
      {:error, :not_found} -> raise Error.new(:no_such_key, resource: "/#{bucket}/#{key}")
    end
  end
```

**(4) `copy_bytes/5` → `copy_bytes/6`（用源真实 version_id 读字节）。** 替换第 392-424 行：

```elixir
  # 非自拷贝：流式读源真实版本 → 写目标（目标版本由 do_copy_persist 决定，此处先写 "null" 临时落点）。
  # 注意：这里仍写目标 "null" 字节路径 + 落 null 元数据是旧行为；FX-H2 会把目标改为版本化路径。
  defp copy_bytes(false, src_bucket, src_key, src_version_id, dest_bucket, dest_key) do
    {:ok, src_stream} = Storage.get(src_bucket, src_key, src_version_id, nil)

    case Storage.put(dest_bucket, dest_key, "null", src_stream) do
      {:ok, %{size: size, etag: etag}} -> {size, etag}
      {:error, reason} -> raise Error.new(:internal_error, message: inspect(reason))
    end
  end

  # 自拷贝（src==dest）：先写唯一临时 key（避免截断源），再流式搬到 dest，最后删临时。
  defp copy_bytes(true, src_bucket, src_key, src_version_id, dest_bucket, dest_key) do
    suffix = :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
    tmp_key = dest_key <> ".maxio-copytmp-" <> suffix
    {:ok, src_stream} = Storage.get(src_bucket, src_key, src_version_id, nil)

    case Storage.put(dest_bucket, tmp_key, "null", src_stream) do
      {:ok, _tmp} ->
        {:ok, tmp_stream} = Storage.get(dest_bucket, tmp_key, "null", nil)

        result =
          case Storage.put(dest_bucket, dest_key, "null", tmp_stream) do
            {:ok, %{size: size, etag: etag}} -> {size, etag}
            {:error, reason} -> raise Error.new(:internal_error, message: inspect(reason))
          end

        _ = Storage.delete(dest_bucket, tmp_key, "null")
        result

      {:error, reason} ->
        raise Error.new(:internal_error, message: inspect(reason))
    end
  end
```

> **FX-H1 单元到此为止只修"源读真实版本 + 解析 ?versionId"；目标仍落 null 版本**（与现状一致）。目标版本化在 **FX-H2** 接续重构。这样拆分保证每单元独立可测、独立 commit。

### 测试

新建 `test/maxio/s3/copy_object_version_test.exs`（模板照 `versioning_object_test.exs`）。本单元只断言**源版本字节正确**：

```elixir
  test "复制版本化源的当前版本 → 目标字节等于源最新版本（不再是 0 字节）" do
    SigV4Request.signed_conn(:put, "/cpv1") |> call()
    enable_versioning("cpv1")
    SigV4Request.signed_conn(:put, "/cpv1/src.txt", body: "hello-current") |> call()

    cp =
      SigV4Request.signed_conn(:put, "/cpv1/dst.txt",
        headers: [{"x-amz-copy-source", "/cpv1/src.txt"}]
      )
      |> call()

    assert cp.status == 200
    g = SigV4Request.signed_conn(:get, "/cpv1/dst.txt") |> call()
    assert g.resp_body == "hello-current"
  end

  test "复制源的指定 ?versionId → 目标字节等于该旧版本" do
    SigV4Request.signed_conn(:put, "/cpv2") |> call()
    enable_versioning("cpv2")
    p1 = SigV4Request.signed_conn(:put, "/cpv2/src.txt", body: "old") |> call()
    [vid1] = get_resp_header(p1, "x-amz-version-id")
    SigV4Request.signed_conn(:put, "/cpv2/src.txt", body: "new") |> call()

    cp =
      SigV4Request.signed_conn(:put, "/cpv2/dst.txt",
        headers: [{"x-amz-copy-source", "/cpv2/src.txt?versionId=#{vid1}"}]
      )
      |> call()

    assert cp.status == 200
    g = SigV4Request.signed_conn(:get, "/cpv2/dst.txt") |> call()
    assert g.resp_body == "old"
  end
```
（`enable_versioning/1` 与 `call/1` 同 FX-C1 模板，复制进本文件的 `setup` 头部。）

### 验证命令

```powershell
mix test test/maxio/s3/copy_object_version_test.exs
# 期望：2 tests, 0 failures（FX-H2 会再向本文件追加用例）
mix compile --warnings-as-errors
mix test
# 期望：全绿
```

**Acceptance**：CopyObject 复制版本化源的当前/指定版本时目标字节正确（非 0 字节）；`?versionId=` 被解析。
**Commit**：`fix(s3): CopyObject reads source bytes from the real (current or ?versionId) version`。

---

## FX-H2 · CopyObject 目标按桶 versioning 落新版本 + 回 `x-amz-version-id`/`x-amz-copy-source-version-id`

**偏差（high）**：`CopyObject ignores destination bucket versioning (no new version, no x-amz-version-id) and does not return x-amz-copy-source-version-id`。

**maxio 现状**：`copy/1` 经 `Objects.put_metadata/3` 落库（硬编码 `version_id: "null"`，upsert null 行），从不读目标桶 versioning；成功响应不带 `x-amz-version-id`、不带 `x-amz-copy-source-version-id`。

**MinIO/S3 正确行为**：目标桶 versioning=Enabled 时 S3 为拷贝对象生成唯一 version ID、经 `x-amz-version-id` 返回；并返回 `x-amz-copy-source-version-id`。
**source**：https://docs.aws.amazon.com/AmazonS3/latest/API/API_CopyObject.html

### 完整修复（`lib/maxio/s3/handlers/object.ex`）

**(1) `copy/1` 计算目标 version_id、用 `copy_bytes/6` 写该版本字节、用 `put_version_with_id/4` 落库、回两个版本头。**

把 FX-H1 后的 `copy/1` 中「`{size, etag} = copy_bytes(...)` 起到 `send_resp(200, body)`」整段（约第 363-389 行）替换为：

```elixir
    self_copy? = src_bucket == dest_bucket and src_key == dest_key

    # 目标版本：Enabled 桶生成新 ULID，否则 "null"（与 do_put 一致，铁律 5）。
    dest_versioning = bucket_versioning(dest_bucket)

    dest_version_id =
      if dest_versioning == "Enabled", do: Maxio.Versioning.VersionId.generate(), else: "null"

    {size, etag} =
      copy_bytes(
        self_copy?,
        src_bucket,
        src_key,
        src_obj.version_id,
        dest_bucket,
        dest_key,
        dest_version_id
      )

    {:ok, obj} =
      Objects.put_version_with_id(dest_bucket, dest_key, dest_version_id, %{
        size: size,
        etag: etag,
        content_type: content_type,
        storage_class: "STANDARD"
      })

    Log.info("copy object",
      action: :copy_object,
      bucket: dest_bucket,
      key: dest_key,
      src_bucket: src_bucket,
      src_key: src_key,
      self_copy: self_copy?
    )

    body =
      Maxio.S3.Views.CopyObjectResult.render(%{etag: etag, last_modified: obj.updated_at})

    conn
    |> put_resp_content_type("application/xml")
    |> maybe_put_version_id(obj.version_id)
    |> maybe_put_copy_source_version_id(src_obj.version_id)
    |> send_resp(200, body)
  end
```

> `maybe_put_version_id/2` 已存在（第 613-616 行，`"null"` 不回显）。`copy_bytes/6`（FX-H1 产物）需升级为 `copy_bytes/7`（带 `dest_version_id`）——见 (2)。删去 `Objects.put_metadata/3` 调用（改用 `put_version_with_id/4`，二者同表，但后者尊重外部 version_id）。

**(2) `copy_bytes/6` → `copy_bytes/7`（把目标字节写到 `dest_version_id` 路径，不再硬编码 `"null"`）。** 替换 FX-H1 产出的 `copy_bytes/6` 两个子句为：

```elixir
  # 非自拷贝：流式读源真实版本 → 写目标 dest_version_id 路径（版本化路径由 Storage 决定）。
  defp copy_bytes(false, src_bucket, src_key, src_version_id, dest_bucket, dest_key, dest_version_id) do
    {:ok, src_stream} = Storage.get(src_bucket, src_key, src_version_id, nil)

    case Storage.put(dest_bucket, dest_key, dest_version_id, src_stream) do
      {:ok, %{size: size, etag: etag}} -> {size, etag}
      {:error, reason} -> raise Error.new(:internal_error, message: inspect(reason))
    end
  end

  # 自拷贝（src==dest）：先写唯一临时 key（避免截断源），再流式搬到 dest 的 dest_version_id，最后删临时。
  defp copy_bytes(true, src_bucket, src_key, src_version_id, dest_bucket, dest_key, dest_version_id) do
    suffix = :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
    tmp_key = dest_key <> ".maxio-copytmp-" <> suffix
    {:ok, src_stream} = Storage.get(src_bucket, src_key, src_version_id, nil)

    case Storage.put(dest_bucket, tmp_key, "null", src_stream) do
      {:ok, _tmp} ->
        {:ok, tmp_stream} = Storage.get(dest_bucket, tmp_key, "null", nil)

        result =
          case Storage.put(dest_bucket, dest_key, dest_version_id, tmp_stream) do
            {:ok, %{size: size, etag: etag}} -> {size, etag}
            {:error, reason} -> raise Error.new(:internal_error, message: inspect(reason))
          end

        _ = Storage.delete(dest_bucket, tmp_key, "null")
        result

      {:error, reason} ->
        raise Error.new(:internal_error, message: inspect(reason))
    end
  end
```

**(3) 新增 `maybe_put_copy_source_version_id/2` helper。** 在 `maybe_put_version_id/2` 定义之后（第 616 行后）加：

```elixir
  # 源是版本化对象时回 x-amz-copy-source-version-id；"null"（未版本化源）不回显（对齐 AWS）。
  defp maybe_put_copy_source_version_id(conn, "null"), do: conn

  defp maybe_put_copy_source_version_id(conn, version_id),
    do: put_resp_header(conn, "x-amz-copy-source-version-id", version_id)
```

### 测试（追加到 `test/maxio/s3/copy_object_version_test.exs`）

```elixir
  test "复制进 Enabled 目标桶 → 回 x-amz-version-id 且每次产生新版本" do
    SigV4Request.signed_conn(:put, "/cpd1") |> call()
    SigV4Request.signed_conn(:put, "/cpd1/src.txt", body: "payload") |> call()
    SigV4Request.signed_conn(:put, "/cpd2") |> call()
    enable_versioning("cpd2")

    cp1 =
      SigV4Request.signed_conn(:put, "/cpd2/dst.txt",
        headers: [{"x-amz-copy-source", "/cpd1/src.txt"}]
      )
      |> call()

    assert cp1.status == 200
    assert [vid1] = get_resp_header(cp1, "x-amz-version-id")
    assert vid1 != "null"

    cp2 =
      SigV4Request.signed_conn(:put, "/cpd2/dst.txt",
        headers: [{"x-amz-copy-source", "/cpd1/src.txt"}]
      )
      |> call()

    assert [vid2] = get_resp_header(cp2, "x-amz-version-id")
    assert vid2 != vid1
  end

  test "复制版本化源 → 回 x-amz-copy-source-version-id" do
    SigV4Request.signed_conn(:put, "/cps1") |> call()
    enable_versioning("cps1")
    p1 = SigV4Request.signed_conn(:put, "/cps1/src.txt", body: "src") |> call()
    [src_vid] = get_resp_header(p1, "x-amz-version-id")
    SigV4Request.signed_conn(:put, "/cps1/dst") |> call()

    cp =
      SigV4Request.signed_conn(:put, "/cps1/dst/o.txt",
        headers: [{"x-amz-copy-source", "/cps1/src.txt"}]
      )
      |> call()

    assert get_resp_header(cp, "x-amz-copy-source-version-id") == [src_vid]
  end

  test "复制进未版本化目标桶 → 不回 x-amz-version-id（保留旧语义）" do
    SigV4Request.signed_conn(:put, "/cpu1") |> call()
    SigV4Request.signed_conn(:put, "/cpu1/src.txt", body: "z") |> call()

    cp =
      SigV4Request.signed_conn(:put, "/cpu1/dst.txt",
        headers: [{"x-amz-copy-source", "/cpu1/src.txt"}]
      )
      |> call()

    assert cp.status == 200
    assert get_resp_header(cp, "x-amz-version-id") == []
  end
```

### 验证命令

```powershell
mix test test/maxio/s3/copy_object_version_test.exs
# 期望：5 tests, 0 failures（FX-H1 的 2 + 本单元 3）
mix compile --warnings-as-errors
mix test
# 期望：全绿
```

**Acceptance**：复制进 Enabled 目标桶生成新版本并回 `x-amz-version-id`；复制版本化源回 `x-amz-copy-source-version-id`；未版本化目标桶不回 version 头。
**Commit**：`fix(s3): CopyObject creates a new dest version + returns x-amz-version-id / x-amz-copy-source-version-id`。

---

## FX-H3 · SigV4 从 raw query 规范化（`'+'` 不再被误当空格）

**偏差（high）**：`Query values containing '+' are decoded to spaces before canonicalization → spurious SignatureDoesNotMatch`。

**maxio 现状**：`Canonical.canonical_query/1`（`canonical.ex:40-48`）从 `conn.query_params`（map）重编码；`fetch_query_params` 用 `Plug.Conn.Query`（x-www-form-urlencoded）把 wire 上字面 `+`（SDK 对 `+` 发 `%2B`）解成空格、再编回 `%20`，重建的 CanonicalQueryString ≠ 客户端签名串 → 误判 `SignatureDoesNotMatch`（`auth.ex:124`）。

**MinIO/S3 正确行为**：AWS SigV4 在**未解码的原始 query**上 canonicalize（每个 name/value 单独 UriEncode，空格=`%20`、`+` 不当空格）；MinIO `getCanonicalRequest` 用 `RawQuery`，`+` 保持 `%2B`。
**source**：AWS IAM `reference_sigv-create-signed-request.html`（CanonicalQueryString + UriEncode，space=%20）；Plug.Conn.Query x-www-form-urlencoded（`+`→空格）。

### 完整修复

新增「从 raw query string 构造 canonical query」的路径，绕开 Plug-decoded map。

**(1) `lib/maxio/auth/sigv4/canonical.ex` — 加 `canonical_query/1` 的字符串重载 + 用严格 RFC3986 解码（不把 `+` 当空格）。**

把现有 `canonical_query/1`（第 39-48 行，只接受 map）替换为「同时接受 raw query 字符串与 map」的两个子句：

```elixir
  @doc """
  CanonicalQueryString。两种入参：
    * **raw query 字符串**（推荐，SigV4 plug 传 conn.query_string）：按 '&' 切对、每对按首个 '='
      切 name/value，用严格 RFC3986 解码（URI.decode/1，**绝不**把 '+' 当空格），再 query-模式
      UriEncode，按编码后 name 排序。这保证客户端字面 '+'（wire 上 %2B）canonicalize 回 %2B
      而非 %20（对齐 AWS / MinIO RawQuery 语义，铁律 5）。
    * **map**（向后兼容既有纯函数测试/调用方）：对每个 name/value 直接 query-模式 UriEncode 后排序。
  两种入参对"无 '+'/无重复键"的普通请求结果完全一致。
  """
  @spec canonical_query(String.t() | map()) :: String.t()
  def canonical_query(query) when is_binary(query) do
    query
    |> split_raw_query()
    |> Enum.map(fn {k, v} ->
      {uri_encode(decode_strict(k), :query), uri_encode(decode_strict(v), :query)}
    end)
    |> Enum.sort_by(fn {k, v} -> {k, v} end)
    |> Enum.map(fn {k, v} -> k <> "=" <> v end)
    |> Enum.join("&")
  end

  def canonical_query(query) when is_map(query) do
    query
    |> Enum.map(fn {k, v} ->
      {uri_encode(to_string(k), :query), uri_encode(to_string(v), :query)}
    end)
    |> Enum.sort_by(fn {k, _v} -> k end)
    |> Enum.map(fn {k, v} -> k <> "=" <> v end)
    |> Enum.join("&")
  end

  # 把 raw query 切成 [{name, value}]（保留重复键，值缺省为 ""）。空串 → []。
  defp split_raw_query(""), do: []

  defp split_raw_query(raw) do
    raw
    |> String.split("&", trim: true)
    |> Enum.map(fn pair ->
      case String.split(pair, "=", parts: 2) do
        [k, v] -> {k, v}
        [k] -> {k, ""}
      end
    end)
  end

  # 严格 RFC3986 percent-decode：只解 %XX，**绝不**把 '+' 当空格（区别于 URI.decode_www_form/1）。
  defp decode_strict(str), do: URI.decode(str)
```

> 说明：排序键从 `{k}` 改为 `{k, v}`（先 name 后 value），对普通请求无影响，但顺带满足 AWS「重复参数按 name 再 value 排序」（low 偏差「重复 query 键」之 query 侧也因此一并消解，无副作用）。

**(2) `lib/maxio/s3/plugs/sigv4.ex` — `signing_query/2` 改传 raw query 字符串而非 map。**

把第 118-122 行替换为：

```elixir
  # header 形态用真实 raw query（conn.query_string，保留 '+'/重复键）；
  # presigned 形态需排除 X-Amz-Signature，故从 raw query 串里剔除该参数后再传。
  defp signing_query(conn, %{auth_type: :presigned}),
    do: raw_query_without(conn.query_string, "X-Amz-Signature")

  defp signing_query(conn, _sr), do: conn.query_string

  # 从 raw query 串里剔除指定参数名（保留其余原始编码，绝不经 map 往返）。
  defp raw_query_without(raw, name) do
    raw
    |> String.split("&", trim: true)
    |> Enum.reject(fn pair ->
      case String.split(pair, "=", parts: 2) do
        [k | _] -> k == name
        _ -> false
      end
    end)
    |> Enum.join("&")
  end
```

> `build_material/2`（第 95-111 行）把 `query: signing_query(conn, sr)` 放进 material；`Auth.verify_signature` 把 `material.query` 透传给 `Canonical.canonical_request`（其 `canonical_query/1` 现已能吃字符串）。`conn.query_string` 是 Bandit/Plug 暴露的**原始未解码 query**（与 `conn.request_path` 同源），正是所需。注意：`fetch_query_params(conn)`（call/1 首行）仍需保留——presigned 检测 `Map.has_key?(conn.query_params, "X-Amz-Signature")` 与 `parse_presigned(conn.query_params)` 仍用解码 map（参数**名**不含 `+`，值用不到精确字节，安全）。

### 测试

新建 `test/maxio/auth/sigv4/canonical_raw_query_test.exs`（纯函数，断言 `'+'` 与空格区分）：

```elixir
defmodule Maxio.Auth.SigV4.CanonicalRawQueryTest do
  use ExUnit.Case, async: true
  alias Maxio.Auth.SigV4.Canonical

  test "raw query 中字面 '+'（wire %2B）canonicalize 成 %2B，不退化为空格/%20" do
    # 客户端签的值含字面 '+'，wire 上是 a%2Bb
    assert Canonical.canonical_query("token=a%2Bb") == "token=a%2Bb"
  end

  test "raw query 中真实空格（wire %20）canonicalize 成 %20" do
    assert Canonical.canonical_query("token=a%20b") == "token=a%20b"
  end

  test "'+' 与空格不再被混为一谈（两者 canonical 串不同）" do
    refute Canonical.canonical_query("k=%2B") == Canonical.canonical_query("k=%20")
  end

  test "多参数按编码后 name 排序，值原样单次编码" do
    assert Canonical.canonical_query("b=2&a=1") == "a=1&b=2"
  end

  test "map 入参向后兼容：普通参数结果与 raw 串一致" do
    assert Canonical.canonical_query(%{"a" => "1", "b" => "2"}) == "a=1&b=2"
  end
end
```

并新增一条端到端回归 `test/maxio/s3/sigv4_plus_query_e2e_test.exs`：直接构造带字面 `+` 的 presigned/header 签名请求，验证不再 `SignatureDoesNotMatch`。因 `SigV4Request.signed_conn` 用 `URI.encode_query`（会把 `+` 编成 `%2B`，正是 wire 形态），可直接用 query map 含 `+` 的值：

```elixir
defmodule Maxio.S3.SigV4PlusQueryE2ETest do
  use Maxio.DataCase, async: false
  alias Maxio.Test.SigV4Request
  alias Maxio.S3.Endpoint

  @data_dir Path.join(System.tmp_dir!(), "maxio_sigv4_plus_e2e")

  setup do
    File.rm_rf(@data_dir)
    File.mkdir_p!(@data_dir)
    prev = Application.get_env(:maxio, :s3)
    Application.put_env(:maxio, :s3, Keyword.put(prev, :data_dir, @data_dir))
    on_exit(fn ->
      Application.put_env(:maxio, :s3, prev)
      File.rm_rf(@data_dir)
    end)
    :ok
  end

  defp call(conn), do: Endpoint.call(conn, Endpoint.init([]))

  test "签名 query 含字面 '+' 的值 → 通过验签（不再 SignatureDoesNotMatch）" do
    SigV4Request.signed_conn(:put, "/plusb") |> call()
    # list-type=2 + 一个含 '+' 的自定义查询值，二者都参与签名
    res =
      SigV4Request.signed_conn(:get, "/plusb",
        query: %{"list-type" => "2", "x-token" => "a+b+c"}
      )
      |> call()

    refute res.resp_body =~ "SignatureDoesNotMatch"
    assert res.status == 200
  end
end
```

> 取证逻辑：`signed_conn` 用项目自己的 `Canonical`（map 入参子句）算签名，但 wire 上 `URI.encode_query(%{"x-token" => "a+b+c"})` 产生 `x-token=a%2Bb%2Bc`；SigV4 plug 现从 `conn.query_string`（即 `x-token=a%2Bb%2Bc`）的 raw 字符串子句重算 → 解 `%2B`→`+`→编回 `%2B`，与签名端 map 子句对同一字面 `+` 的编码一致 → 匹配。修复前 plug 走 map 子句但 `conn.query_params["x-token"]` 已被解成 `"a b c"`（`+`→空格）→ 编成 `%20` → 不匹配。**故此用例修复前红、修复后绿。**

### 验证命令

```powershell
mix test test/maxio/auth/sigv4/canonical_raw_query_test.exs test/maxio/s3/sigv4_plus_query_e2e_test.exs
# 期望：6 tests, 0 failures
mix test test/maxio/auth/sigv4/canonical_test.exs test/maxio/auth_test.exs test/maxio/s3/plugs/sigv4_test.exs
# 期望：既有 SigV4 套件仍全绿（AWS 官方向量未回归）
mix compile --warnings-as-errors
mix test
# 期望：全绿
```

**Acceptance**：canonical query 区分字面 `+`（%2B）与空格（%20）；含 `+` 的签名请求验签通过；AWS 官方测试向量套件不回归。
**Commit**：`fix(sigv4): canonicalize from raw query string so literal '+' is not decoded to space`。

---

## FX-H4 · PutBucketPolicy 校验 Resource ARN 引用目标桶

**偏差（high）**：`PutBucketPolicy does not validate that statement Resource ARNs reference the target bucket (cross-bucket policy accepted)`。

**maxio 现状**：`Statement.parse_policy/1` 不收 bucket 名，`from_json/1` 原样存 Resource 串无桶交叉校验；`Handlers.BucketPolicy.put/1`（第 21 行）调 `Statement.parse_policy(json)`。PUT `/mybucket?policy` 带 Resource `arn:aws:s3:::otherbucket/*` 返回 204 且被持久化，之后从不匹配 mybucket 的任何请求。

**MinIO/S3 正确行为**：`policy.ParseBucketPolicyConfig(reader, bucketName)` → `Validate(bucketName)` → `Resource.ValidateBucket`：`wildcard.Match(pattern, bucketName) || MatchAsPatternPrefix(pattern, bucketName+"/")`；不匹配 → MalformedPolicy(400)。
**source**：https://github.com/minio/pkg/blob/master/policy/resource.go ；https://docs.aws.amazon.com/AmazonS3/latest/API/API_PutBucketPolicy.html

### 完整修复

**(1) `lib/maxio/policy/statement.ex` — 新增 `parse_policy/2`（带 bucket 校验），保留 `parse_policy/1` 委派。**

把现有 `parse_policy/1`（第 39-50 行）替换为：

```elixir
  @doc "解析整篇 policy JSON（不做 bucket 交叉校验）。成功 → {:ok, [t()]}；畸形 → {:error, :malformed}。"
  @spec parse_policy(binary()) :: {:ok, [t()]} | {:error, :malformed}
  def parse_policy(json) when is_binary(json), do: parse_policy(json, nil)

  @doc """
  解析整篇 policy JSON，并（当 bucket 非 nil 时）校验每条 statement 的每个 Resource ARN 都引用
  目标桶（对齐 minio/pkg Resource.ValidateBucket：桶段精确或通配匹配 bucket，允许 'bucket' 与
  'bucket/...'）。任一 Resource 桶段不匹配 → {:error, :malformed}（→ 400 MalformedPolicy）。
  """
  @spec parse_policy(binary(), String.t() | nil) :: {:ok, [t()]} | {:error, :malformed}
  def parse_policy(json, bucket) when is_binary(json) do
    with {:ok, doc} <- decode(json),
         :ok <- check_version(doc),
         {:ok, raw_stmts} <- fetch_statements(doc),
         {:ok, stmts} <- normalize_all(raw_stmts),
         :ok <- validate_resources_bucket(stmts, bucket) do
      {:ok, stmts}
    else
      _ -> {:error, :malformed}
    end
  end
```

在文件尾部（`resource_match?/2` 之后）加桶校验 helper：

```elixir
  # nil bucket（如 statements_for_bucket 回读路径）→ 跳过桶校验（向后兼容）。
  defp validate_resources_bucket(_stmts, nil), do: :ok

  defp validate_resources_bucket(stmts, bucket) do
    ok? =
      Enum.all?(stmts, fn %__MODULE__{resources: resources} ->
        Enum.all?(resources, &resource_references_bucket?(&1, bucket))
      end)

    if ok?, do: :ok, else: {:error, :malformed}
  end

  # Resource ARN 是否引用目标桶：剥 "arn:aws:s3:::" 前缀后取桶段（'/' 之前），
  # 用 policy 通配语义匹配 bucket（pattern 可含 *、?）。无前缀 → 不匹配（畸形）。
  defp resource_references_bucket?("arn:aws:s3:::" <> rest, bucket) do
    bucket_segment = rest |> String.split("/", parts: 2) |> List.first()
    Arn.glob_match?(bucket_segment, bucket)
  end

  defp resource_references_bucket?(_other, _bucket), do: false
```

> 复用既有 `Maxio.Policy.Arn.glob_match?/3`（`*`→`.*`、`?`→`.`、锚定），与策略其余通配语义一致（铁律 2/5）。桶段取「`arn:aws:s3:::` 之后、首个 `/` 之前」，故 `arn:aws:s3:::mybucket`、`arn:aws:s3:::mybucket/*`、`arn:aws:s3:::my*` 对 `mybucket` 都通过；`arn:aws:s3:::otherbucket/*` 不通过。`statements_for_bucket/1`（Store 回读，`parse_policy/1`）传 nil → 跳过校验，绝不破坏既有授权链（铁律 3）。

**(2) `lib/maxio/s3/handlers/bucket_policy.ex` — `put/1` 调 `parse_policy/2` 传 bucket。**

把第 21 行 `case Statement.parse_policy(json) do` 改为：

```elixir
    case Statement.parse_policy(json, bucket) do
```

### 测试（追加到既有 `test/maxio/s3/bucket_policy_test.exs`）

```elixir
  test "PutBucketPolicy: Resource 引用别的桶 → 400 MalformedPolicy（不再静默接受）" do
    SigV4Request.signed_conn(:put, "/pbp1") |> call()

    policy = ~s({"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":"*","Action":["s3:GetObject"],"Resource":["arn:aws:s3:::otherbucket/*"]}]})

    res = SigV4Request.signed_conn(:put, "/pbp1", query: %{"policy" => ""}, body: policy) |> call()
    assert res.status == 400
    assert res.resp_body =~ "MalformedPolicy"
  end

  test "PutBucketPolicy: Resource 引用本桶（精确/通配）→ 204" do
    SigV4Request.signed_conn(:put, "/pbp2") |> call()

    policy = ~s({"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":"*","Action":["s3:GetObject"],"Resource":["arn:aws:s3:::pbp2/*","arn:aws:s3:::pbp2"]}]})

    res = SigV4Request.signed_conn(:put, "/pbp2", query: %{"policy" => ""}, body: policy) |> call()
    assert res.status == 204
  end
```
（若 `bucket_policy_test.exs` 尚无 `call/1`/`setup`，照其文件头既有写法；该文件已存在并测 policy，故复用其辅助。）

并加纯函数单测到 `test/maxio/policy/statement_test.exs`：

```elixir
  test "parse_policy/2 拒绝跨桶 Resource" do
    json = ~s({"Statement":[{"Effect":"Allow","Principal":"*","Action":"s3:GetObject","Resource":"arn:aws:s3:::other/*"}]})
    assert {:error, :malformed} = Maxio.Policy.Statement.parse_policy(json, "mybucket")
  end

  test "parse_policy/2 接受引用目标桶的 Resource（精确与通配）" do
    json = ~s({"Statement":[{"Effect":"Allow","Principal":"*","Action":"s3:GetObject","Resource":["arn:aws:s3:::mybucket/*","arn:aws:s3:::my*"]}]})
    assert {:ok, [_]} = Maxio.Policy.Statement.parse_policy(json, "mybucket")
  end

  test "parse_policy/1 不做桶校验（向后兼容回读）" do
    json = ~s({"Statement":[{"Effect":"Allow","Principal":"*","Action":"s3:GetObject","Resource":"arn:aws:s3:::other/*"}]})
    assert {:ok, [_]} = Maxio.Policy.Statement.parse_policy(json)
  end
```

### 验证命令

```powershell
mix test test/maxio/policy/statement_test.exs test/maxio/s3/bucket_policy_test.exs
# 期望：全绿（含新增 5 个用例）
mix compile --warnings-as-errors
mix test
# 期望：全绿
```

**Acceptance**：跨桶 Resource 的 PutBucketPolicy → 400 MalformedPolicy；引用本桶（精确/通配）→ 204；`parse_policy/1` 回读路径不回归。
**Commit**：`fix(policy): PutBucketPolicy rejects statements whose Resource ARN does not reference the target bucket`。

---

## FX-H5 · CORS 设 `Access-Control-Allow-Credentials: true`

**偏差（high）**：`CORS responses never set Access-Control-Allow-Credentials (credentialed cross-origin requests blocked)`。

**maxio 现状**：`lib/maxio/s3/plugs/cors.ex` 的 `put_preflight_headers/5`（第 77-84 行）与 `handle_actual/2` 的 `register_before_send` 闭包（第 65-71 行）设了 ACAO/ACAM/ACAH/Max-Age/Expose/Vary，但**从不**设 `Access-Control-Allow-Credentials`。

**MinIO/S3 正确行为**：桶有 CORS 配置后，S3 在**预检与实际**响应都回 `Access-Control-Allow-Credentials: true`；浏览器 credentials='include' 的请求无此头则被拦。maxio 已回显请求 Origin（非字面 `*`），故与 ACAC:true 兼容。
**source**：https://github.com/minio/minio/issues/4044 ；https://corsfix.com/cors-headers/access-control-allow-credentials

### 完整修复（`lib/maxio/s3/plugs/cors.ex`）

**(1) 预检：在 `put_preflight_headers/5` 末加 ACAC。** 替换第 77-84 行：

```elixir
  defp put_preflight_headers(conn, rule, origin, req_method, req_headers) do
    conn
    |> put_resp_header("access-control-allow-origin", origin)
    |> put_resp_header("access-control-allow-credentials", "true")
    |> put_resp_header("access-control-allow-methods", req_method)
    |> put_allow_headers(req_headers)
    |> put_max_age(rule)
    |> put_expose_headers(rule)
  end
```

**(2) 实际响应：在 `handle_actual/2` 闭包加 ACAC。** 替换第 65-71 行：

```elixir
      register_before_send(conn, fn c ->
        c
        |> put_resp_header("access-control-allow-origin", origin)
        |> put_resp_header("access-control-allow-credentials", "true")
        |> put_resp_header("access-control-allow-methods", conn.method)
        |> put_expose_headers(rule)
        |> put_resp_header("vary", "Origin")
      end)
```

> 仅改两处加一行 `put_resp_header(..., "access-control-allow-credentials", "true")`，其余头不动（low 偏差「actual 不该带 ACAM」不在本批，保持现状）。

### 测试（追加到既有 `test/maxio/s3/cors_e2e_test.exs`）

```elixir
  test "预检命中 → 回 Access-Control-Allow-Credentials: true" do
    SigV4Request.signed_conn(:put, "/cbc1") |> call()
    SigV4Request.signed_conn(:put, "/cbc1", query: %{"cors" => ""}, body: @cors) |> call()

    pre =
      SigV4Request.anon_conn(:options, "/cbc1/obj.txt",
        headers: [{"origin", "http://www.example.com"}, {"access-control-request-method", "PUT"}]
      )
      |> call()

    assert pre.status == 200
    assert get_resp_header(pre, "access-control-allow-credentials") == ["true"]
  end

  test "实际跨源响应 → 回 Access-Control-Allow-Credentials: true" do
    SigV4Request.signed_conn(:put, "/cbc2") |> call()
    SigV4Request.signed_conn(:put, "/cbc2", query: %{"cors" => ""}, body: @cors) |> call()
    SigV4Request.signed_conn(:put, "/cbc2/o.txt", body: "x") |> call()

    res =
      SigV4Request.signed_conn(:get, "/cbc2/o.txt", headers: [{"origin", "http://www.example.com"}])
      |> call()

    assert get_resp_header(res, "access-control-allow-credentials") == ["true"]
  end
```

### 验证命令

```powershell
mix test test/maxio/s3/cors_e2e_test.exs
# 期望：全绿（含新增 2 个用例）
mix compile --warnings-as-errors
mix test
# 期望：全绿
```

**Acceptance**：预检与实际跨源响应都带 `Access-Control-Allow-Credentials: true`。
**Commit**：`fix(cors): emit Access-Control-Allow-Credentials: true on preflight and actual responses`。

---

## FX-H6 · DeleteObjects authz 改对象级逐 key

**偏差（high）**：`DeleteObjects authorized against the bucket ARN instead of per-object ARN, so standard s3:DeleteObject-on-objects policies break`。

**maxio 现状**：`ActionMap.for_action(:delete_objects)` → `{"s3:DeleteObject", :bucket}`（`action_map.ex:32`）；`Authz` 跑一次桶级 `arn:aws:s3:::<bucket>` 检查。授予 `s3:DeleteObject` on `arn:aws:s3:::<bucket>/*` 的标准策略不匹配桶 ARN → 非 owner 被 403。

**MinIO/S3 正确行为**：要求对**对象** ARN（`arn:aws:s3:::bucket/key`）逐 key 评估，只对无权 key 回 per-key `<Error><Code>AccessDenied</Code>`（HTTP 200 混合结果）。桶 ARN 不授予对象动作。
**source**：https://docs.aws.amazon.com/AmazonS3/latest/API/API_DeleteObjects.html ；https://docs.aws.amazon.com/AmazonS3/latest/userguide/using-with-s3-policy-actions.html

### 完整修复

DeleteObjects 是 POST body 内携带 keys，需在 **handler** 内逐 key 评估（dispatcher 层的 `Authz.authorize` 只见到 action，见不到 body 内的 keys）。故：
- 从 `ActionMap` 移除 `:delete_objects` 的桶级粗门（返回 `nil`，使 `Authz.authorize` 对该 action 放行，把授权下沉到 handler 逐 key）；
- 在 `delete_objects/1` 内对每个 key 用 **对象 ARN** + `s3:DeleteObject` 跑 `Evaluator`，无权 key 进 `<Error>AccessDenied</Error>`，有权 key 才执行删除。

**(1) `lib/maxio/policy/action_map.ex` — `:delete_objects` 改返回 nil（授权移交 handler 逐 key）。** 替换第 31-32 行：

```elixir
  # DeleteObjects 批删：授权在 handler 内逐 key 对对象 ARN 评估（s3:DeleteObject on bucket/key），
  # 故此处返回 nil（dispatcher 层 Authz 放行，绝不在桶 ARN 上粗粒度门控——桶 ARN 不授予对象动作）。
  def for_action(:delete_objects), do: nil
```

**(2) `lib/maxio/s3/handlers/object.ex` — `delete_objects/1` 逐 key 授权。**

在 FX-C1 重写后的 `delete_objects/1` 中，把 `Enum.reduce(objects, ...)` 的 reduce 函数体改为先授权、无权进 errors、有权才删。具体：在 `delete_one/3` 之前先做一次对象级评估。替换 FX-C1 产出的 reduce 段为：

```elixir
    principal = conn.assigns[:principal]
    authenticated? = principal != :anonymous
    conditions = Maxio.S3.Authz.conditions_for(conn, authenticated?)
    owner? = Maxio.S3.Authz.owner?(principal, bucket)

    {deleted, errors} =
      Enum.reduce(objects, {[], []}, fn obj, {dacc, eacc} ->
        if delete_authorized?(bucket, obj.key, principal, authenticated?, owner?, conditions) do
          case delete_one(bucket, obj, versioning) do
            {:ok, entry} -> {[entry | dacc], eacc}
            {:error, err} -> {dacc, [err | eacc]}
          end
        else
          err = %{
            key: obj.key,
            code: "AccessDenied",
            message: "Access Denied"
          }

          {dacc, [err | eacc]}
        end
      end)
```

并在 `delete_one/3` 定义之后加 per-key 授权 helper（复用 Authz 暴露的零件）：

```elixir
  # 单 key 是否被授权删除：owner 短路，否则对对象 ARN 跑 Evaluator（s3:DeleteObject）。
  defp delete_authorized?(_bucket, _key, _principal, _auth?, true, _conditions), do: true

  defp delete_authorized?(bucket, key, principal, authenticated?, _owner?, conditions) do
    resource = Maxio.Policy.Arn.object_arn(bucket, key)
    statements = Maxio.S3.Authz.object_statements(bucket, key, principal)

    ctx = %Maxio.Policy.RequestContext{
      principal: principal,
      authenticated?: authenticated?,
      owner?: false,
      action: "s3:DeleteObject",
      resource: resource,
      conditions: conditions
    }

    case Maxio.Policy.Evaluator.evaluate(ctx, statements) do
      :allow -> true
      {:deny, _reason} -> false
    end
  end
```

**(3) `lib/maxio/s3/authz.ex` — 暴露三个内部零件供 handler 逐 key 复用（铁律 2：单一授权路径，不另起第二套逻辑）。**

把 `owner?/2`、`extract_conditions/2`、对象 statement 合并各加一个公开包装（在模块内现有私有定义旁加 `@doc` 公开函数；不改私有实现）：

- 把 `defp owner?(...)` 系列改为 `def owner?(...)`（公开第一参为 principal、第二为 bucket 的现有 3 个子句；签名不变，仅去掉 `p`）。
- 新增公开 `conditions_for/2` 委派到现有私有 `extract_conditions/2`：
```elixir
  @doc "供批量 handler 复用：抽取请求条件键（与单请求授权同源）。"
  @spec conditions_for(Plug.Conn.t(), boolean()) :: map()
  def conditions_for(conn, authenticated?), do: extract_conditions(conn, authenticated?)
```
- 新增公开 `object_statements/3` 委派到现有私有合并逻辑：
```elixir
  @doc "供批量 handler 复用：合并某对象的 bucket policy + 对象 ACL 派生 + identity statements。"
  @spec object_statements(String.t(), String.t(), map() | :anonymous) :: [Maxio.Policy.Statement.t()]
  def object_statements(bucket, key, principal),
    do: gather_statements(:object, bucket, key, principal)
```

> 这样 handler 用的是与单请求授权**完全相同**的 `extract_conditions`/`gather_statements`/`owner?`/`Evaluator.evaluate`，仅资源 ARN 改成逐 key 对象 ARN（铁律 2/4.1：不重复实现授权逻辑）。`RequestContext` 已 alias 在 Authz，但 handler 用全限定名 `Maxio.Policy.RequestContext` 避免在 object.ex 新增 alias 噪音。

### 测试

新建 `test/maxio/s3/delete_objects_authz_test.exs`：用一个授予匿名 `s3:DeleteObject` on `arn:aws:s3:::bucket/*` 的 bucket policy，匿名 DeleteObjects 应成功（修复前因桶 ARN 不匹配会 403）：

```elixir
defmodule Maxio.S3.DeleteObjectsAuthzTest do
  use Maxio.DataCase, async: false
  alias Maxio.Test.SigV4Request
  alias Maxio.S3.Endpoint

  @data_dir Path.join(System.tmp_dir!(), "maxio_delobjs_authz")

  setup do
    File.rm_rf(@data_dir)
    File.mkdir_p!(@data_dir)
    prev = Application.get_env(:maxio, :s3)
    Application.put_env(:maxio, :s3, Keyword.put(prev, :data_dir, @data_dir))
    on_exit(fn ->
      Application.put_env(:maxio, :s3, prev)
      File.rm_rf(@data_dir)
    end)
    :ok
  end

  defp call(conn), do: Endpoint.call(conn, Endpoint.init([]))

  test "对象级 s3:DeleteObject 策略授权匿名批删（桶 ARN 策略不再是唯一可行写法）" do
    SigV4Request.signed_conn(:put, "/doa1") |> call()
    SigV4Request.signed_conn(:put, "/doa1/k.txt", body: "x") |> call()

    policy = ~s({"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":"*","Action":["s3:DeleteObject"],"Resource":["arn:aws:s3:::doa1/*"]}]})
    SigV4Request.signed_conn(:put, "/doa1", query: %{"policy" => ""}, body: policy) |> call()

    body = ~s(<Delete><Object><Key>k.txt</Key></Object></Delete>)
    res = SigV4Request.anon_conn(:post, "/doa1", query: %{"delete" => ""}, body: body) |> call()

    assert res.status == 200
    assert res.resp_body =~ "<Deleted><Key>k.txt</Key></Deleted>"
    refute res.resp_body =~ "AccessDenied"
  end

  test "无授权的匿名批删 key → per-key <Error>AccessDenied</Error>，HTTP 200" do
    SigV4Request.signed_conn(:put, "/doa2") |> call()
    SigV4Request.signed_conn(:put, "/doa2/k.txt", body: "x") |> call()

    body = ~s(<Delete><Object><Key>k.txt</Key></Object></Delete>)
    res = SigV4Request.anon_conn(:post, "/doa2", query: %{"delete" => ""}, body: body) |> call()

    assert res.status == 200
    assert res.resp_body =~ "AccessDenied"
    # key 仍在
    g = SigV4Request.signed_conn(:get, "/doa2/k.txt") |> call()
    assert g.status == 200
  end
end
```

并更新 `test/maxio/policy/action_map_test.exs`：`for_action(:delete_objects)` 现应为 `nil`：

```elixir
  test "delete_objects 不再桶级粗门（授权移交 handler 逐 key）" do
    assert Maxio.Policy.ActionMap.for_action(:delete_objects) == nil
  end
```
（若该文件原有断言 `{"s3:DeleteObject", :bucket}`，改为上面这条。）

### 验证命令

```powershell
mix test test/maxio/s3/delete_objects_authz_test.exs test/maxio/policy/action_map_test.exs test/maxio/s3/delete_objects_versioning_test.exs
# 期望：全绿
mix test test/maxio/s3/authz_matrix_test.exs test/maxio/s3/authz_test.exs
# 期望：既有 authz 套件不回归
mix compile --warnings-as-errors
mix test
# 期望：全绿
```

**Acceptance**：对象级 `s3:DeleteObject` 策略可授权批删；无权 key 回 per-key AccessDenied（HTTP 200）且不被删；既有 authz 测试不回归。
**Commit**：`fix(authz): DeleteObjects evaluates s3:DeleteObject per key against the object ARN`。

---

## FX-H7 · CopyObject 目标 authz 改对象级 ARN

**偏差（high，审计 prioritized 第 3 条）**：`CopyObject authorized against the bucket ARN for the destination put`。

**maxio 现状**：CopyObject 走 `:put_object`（`ActionMap.for_action(:put_object)` → `{"s3:PutObject", :object}`，**对象级，已正确**）；源读由 `Authz.maybe_authorize_copy_source/5` 对源**对象 ARN** 二次检查（`authz.ex:144-168`，**已正确**）。复核确认：**maxio 当前 CopyObject 目标 authz 已是对象级**（`:put_object` → `:object`）。审计该条的「destination put while DeleteObjects authz uses bucket-level」措辞把两者并提，真正待修的桶级粗门是 **DeleteObjects（FX-H6 已修）**。

为彻底消除审计列出的「Copy/DeleteObjects authz granularity（object-level ARN）」这一类，本单元补齐 **CopyObject 端到端对象级授权回归测试**（证明目标 put 与源 get 都用对象 ARN），并把 `UploadPartCopy`（若存在同形 bug）一并核验。经代码核查 maxio **无 UploadPartCopy** 实现（dispatcher 无该分支），故本单元为**回归固化 + 文档澄清**：确认 CopyObject 目标/源授权均对象级，加测试锁定，防未来回归。

**source**：https://docs.aws.amazon.com/AmazonS3/latest/API/API_CopyObject.html ；using-with-s3-policy-actions。

### 完整修复

无生产代码改动（目标/源授权已对象级）。**仅新增回归测试锁定对象级授权契约**（防回归即架构保真，铁律 5）。若 reviewer 发现任何 CopyObject 授权走桶 ARN 的隐藏路径，则按 FX-H6 同法改为对象 ARN——但当前核查为已正确。

### 测试

新建 `test/maxio/s3/copy_object_authz_test.exs`：

```elixir
defmodule Maxio.S3.CopyObjectAuthzTest do
  use Maxio.DataCase, async: false
  alias Maxio.Test.SigV4Request
  alias Maxio.S3.Endpoint

  @data_dir Path.join(System.tmp_dir!(), "maxio_copy_authz")

  setup do
    File.rm_rf(@data_dir)
    File.mkdir_p!(@data_dir)
    prev = Application.get_env(:maxio, :s3)
    Application.put_env(:maxio, :s3, Keyword.put(prev, :data_dir, @data_dir))
    on_exit(fn ->
      Application.put_env(:maxio, :s3, prev)
      File.rm_rf(@data_dir)
    end)
    :ok
  end

  defp call(conn), do: Endpoint.call(conn, Endpoint.init([]))

  test "对象级 s3:PutObject(目标) + s3:GetObject(源) 策略授权匿名 CopyObject" do
    SigV4Request.signed_conn(:put, "/coa1") |> call()
    SigV4Request.signed_conn(:put, "/coa1/src.txt", body: "data") |> call()

    policy = ~s({"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":"*","Action":["s3:GetObject","s3:PutObject"],"Resource":["arn:aws:s3:::coa1/*"]}]})
    SigV4Request.signed_conn(:put, "/coa1", query: %{"policy" => ""}, body: policy) |> call()

    res =
      SigV4Request.anon_conn(:put, "/coa1/dst.txt",
        headers: [{"x-amz-copy-source", "/coa1/src.txt"}]
      )
      |> call()

    assert res.status == 200
    assert res.resp_body =~ "CopyObjectResult"
  end

  test "仅授权桶 ARN（非对象 ARN）→ CopyObject 目标 put 被拒 403（证明走对象级）" do
    SigV4Request.signed_conn(:put, "/coa2") |> call()
    SigV4Request.signed_conn(:put, "/coa2/src.txt", body: "data") |> call()

    # 只对桶 ARN 授 PutObject/GetObject —— 对象动作不应被桶 ARN 满足
    policy = ~s({"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":"*","Action":["s3:GetObject","s3:PutObject"],"Resource":["arn:aws:s3:::coa2"]}]})
    SigV4Request.signed_conn(:put, "/coa2", query: %{"policy" => ""}, body: policy) |> call()

    res =
      SigV4Request.anon_conn(:put, "/coa2/dst.txt",
        headers: [{"x-amz-copy-source", "/coa2/src.txt"}]
      )
      |> call()

    assert res.status == 403
    assert res.resp_body =~ "AccessDenied"
  end
end
```

### 验证命令

```powershell
mix test test/maxio/s3/copy_object_authz_test.exs
# 期望：2 tests, 0 failures（证明目标 put 与源 get 均对象级授权）
mix compile --warnings-as-errors
mix test
# 期望：全绿
```

**Acceptance**：对象级策略授权 CopyObject 成功；仅桶 ARN 策略拒绝 CopyObject（证明目标/源授权均对象级）。
**Commit**：`test(authz): lock CopyObject destination+source authorization to object-level ARNs`。

---

# BATCH 3 — MEDIUM 修复

## FX-M1 · SigV4 强制 host 进 SignedHeaders（`:unsigned_headers` 错误码）

**偏差（medium）**：`No enforcement that 'host' is present in SignedHeaders (MinIO/AWS reject with ErrUnsignedHeaders)`。

**maxio 现状**：`Auth.verify_signature` → `filter_signed_headers/2`（`auth.ex:141-144`）只保留客户端列的 header 子集，从不校验 SignedHeaders 含强制的 `host`；自洽签名但漏 host 的请求过关。

**MinIO/S3 正确行为**：`extractSignedHeaders` 在验签**之前** `if !contains(signedHeaders, "host") { return ErrUnsignedHeaders }`，回 Code `AccessDenied`、HTTP 400、message `There were headers present in the request which were not signed`。
**source**：github.com/minio/minio `cmd/signature-v4-utils.go`、`cmd/api-errors.go`。

### 完整修复

**(1) `lib/maxio/s3/error.ex` — @table 加 `:unsigned_headers`（AccessDenied/400，区别于 403 的 access_denied）。** 在 @table 内 `access_denied:` 条目之后加：

```elixir
    unsigned_headers:
      {"AccessDenied", 400,
       "There were headers present in the request which were not signed"},
```

**(2) `lib/maxio/auth.ex` — `verify_signature` 前置 host 必签校验。** 把 `authenticate/1`（第 23-31 行）的 `with` 链加一步：

```elixir
  def authenticate(%{signed_request: sr} = material) do
    with :ok <- check_signed_headers(sr),
         :ok <- check_request_time(sr, material.now),
         {:ok, %{secret_key: secret, principal: principal}} <- lookup_secret(sr.access_key),
         {:ok, sig_context} <- verify_signature(sr, material, secret) do
      Log.info("sigv4 authenticated", auth_type: sr.auth_type)
      {:ok, principal, sig_context}
    end
  end

  # SignedHeaders 必须含 host（MinIO extractSignedHeaders 在验签前的硬性检查）。
  # 缺 host → ErrUnsignedHeaders（AccessDenied/400），绝不放行自洽但漏签 host 的请求（铁律 3/5）。
  defp check_signed_headers(%{signed_headers: signed_headers}) do
    if "host" in Enum.map(signed_headers, &String.downcase/1) do
      :ok
    else
      Log.warn("unsigned host header", reason: :unsigned_headers)
      {:error, Error.new(:unsigned_headers)}
    end
  end
```

> 仅校验 host（最关键且 AWS/MinIO 必查）；x-amz-content-sha256 对 header-auth 的强制留作 low/defer（审计也仅把 host 列为 medium 必修，content-sha256 为"for completeness"）。`SignedRequest.signed_headers` 是 `["host", ...]` 列表（解析器 `String.split(...,";")`），故检查直接遍历。

### 测试

新建 `test/maxio/auth/unsigned_host_test.exs`（纯函数 + 端到端）：

```elixir
defmodule Maxio.Auth.UnsignedHostTest do
  use ExUnit.Case, async: true
  alias Maxio.Auth
  alias Maxio.Auth.SigV4.SignedRequest

  test "SignedHeaders 缺 host → unsigned_headers（AccessDenied/400），验签前即拒" do
    sr = %SignedRequest{
      access_key: "AKIAIOSFODNN7EXAMPLE",
      scope_date: "20130524",
      region: "us-east-1",
      service: "s3",
      signed_headers: ["x-amz-date"],
      signature: "deadbeef",
      amz_date: "20130524T000000Z",
      auth_type: :header,
      payload_mode: :single,
      expires: nil
    }

    material = %{
      signed_request: sr,
      method: "GET",
      path: "/",
      query: "",
      headers: [{"x-amz-date", "20130524T000000Z"}],
      payload_hash: "UNSIGNED-PAYLOAD",
      now: DateTime.utc_now()
    }

    assert {:error, %Maxio.S3.Error{code: "AccessDenied", http_status: 400}} =
             Auth.authenticate(material)
  end
end
```

> 该用例在 lookup_secret/验签**之前**就返回，故不依赖签名材料正确性。`Error.codes/0` 已含新码（自动）。`signed_conn` 辅助总是签 host，无法直接构造缺 host 的端到端请求（Plug.Test 限制），故用 `Auth.authenticate/1` 纯函数取证（最权威）。

### 验证命令

```powershell
mix test test/maxio/auth/unsigned_host_test.exs test/maxio/s3/error_test.exs
# 期望：全绿（error_test 若枚举 codes 会自动含 :unsigned_headers）
mix test test/maxio/auth_test.exs test/maxio/s3/plugs/sigv4_test.exs
# 期望：既有 SigV4 套件不回归（正常请求总签 host）
mix compile --warnings-as-errors
mix test
# 期望：全绿
```

**Acceptance**：SignedHeaders 缺 host → AccessDenied/400（ErrUnsignedHeaders），验签前即拒；正常（签 host）请求不回归。
**Commit**：`fix(sigv4): reject requests whose SignedHeaders omit host (ErrUnsignedHeaders, AccessDenied 400)`。

---

## FX-M2 · ListObjectsV2 支持 `encoding-type=url`

**偏差（medium）**：`ListObjectsV2 does not implement encoding-type=url`。

**maxio 现状**：`bucket.ex` `list_objects_v2/1` 从不读 `encoding-type`；`views/list_bucket.ex` 从不 URL 编码 Key/Prefix/Delimiter/StartAfter，也不发 `<EncodingType>`。含 XML 1.0 非法控制字符（0x00-0x1F）的 key 会产生破坏客户端解析的无效 XML。

**MinIO/S3 正确行为**：`encoding-type=url` 时 S3 对 Delimiter/Prefix/Key/StartAfter percent-encode 并回 `<EncodingType>url</EncodingType>`；SDK/minio-go 默认发 `encoding-type=url` 并在收到后 URL-decode。
**source**：https://docs.aws.amazon.com/AmazonS3/latest/API/API_ListObjectsV2.html

### 完整修复

**(1) `lib/maxio/s3/handlers/bucket.ex` — `list_objects_v2/1` 读 `encoding-type` 并传 view。** 在 `list_objects_v2/1` 内（第 73 行 `delimiter = ...` 旁）加读取，并在 `ListBucket.render(%{...})` 入参加 `encoding_type`：

把第 72-77 行块内加一行 `encoding_type = Map.get(qp, "encoding-type")`，并在 `ListBucket.render(%{...})` map 里加 `encoding_type: encoding_type`（放在 `common_prefixes:` 之后）。完整替换 `list_objects_v2/1` 体内 `prefix = ...` 到 `ListBucket.render(...)` 段：

```elixir
      prefix = Map.get(qp, "prefix", "")
      delimiter = Map.get(qp, "delimiter")
      max_keys = parse_int(Map.get(qp, "max-keys"), 1000)
      continuation = Map.get(qp, "continuation-token")
      start_after = Map.get(qp, "start-after")
      encoding_type = Map.get(qp, "encoding-type")

      res =
        Objects.list_objects_v2(bucket, %{
          prefix: prefix,
          delimiter: delimiter,
          max_keys: max_keys,
          continuation_token: continuation,
          start_after: start_after
        })

      objects =
        Enum.map(res.objects, fn o ->
          %{key: o.key, last_modified: o.updated_at, etag: o.etag, size: o.size}
        end)

      body =
        ListBucket.render(%{
          name: bucket,
          prefix: prefix,
          delimiter: delimiter,
          max_keys: max_keys,
          key_count: res.key_count,
          is_truncated: res.is_truncated,
          next_continuation_token: res.next_continuation_token,
          start_after: start_after,
          objects: objects,
          common_prefixes: res.common_prefixes,
          encoding_type: encoding_type
        })
```

**(2) `lib/maxio/s3/views/list_bucket.ex` — 当 `encoding_type == "url"` 时 percent-encode + 发 `<EncodingType>`。** 整文件替换：

```elixir
defmodule Maxio.S3.Views.ListBucket do
  @moduledoc """
  ListObjectsV2 响应 XML（ListBucketResult）。NextContinuationToken 仅截断时出现；
  CommonPrefixes 仅有 delimiter 时出现。encoding-type=url 时对 Key/Prefix/Delimiter/StartAfter/
  CommonPrefixes 做 percent-encode 并发 <EncodingType>url</EncodingType>（对齐 AWS：使含 XML 1.0
  非法字节的 key 可被客户端正确 URL-decode 还原，铁律 5）。
  """
  import Saxy.XML
  alias Maxio.S3.XML

  @spec render(map()) :: iodata()
  def render(data) do
    enc = Map.get(data, :encoding_type)

    children =
      [
        element("Name", [], characters(data.name)),
        element("Prefix", [], characters(encode(data.prefix || "", enc))),
        element("KeyCount", [], characters(Integer.to_string(data.key_count))),
        element("MaxKeys", [], characters(Integer.to_string(data.max_keys))),
        element("IsTruncated", [], characters(to_string(data.is_truncated)))
      ]
      |> maybe(encoding_type_value(enc), fn e -> element("EncodingType", [], characters(e)) end)
      |> maybe(data.delimiter, fn d -> element("Delimiter", [], characters(encode(d, enc))) end)
      |> maybe(data.is_truncated && data.next_continuation_token, fn t ->
        element("NextContinuationToken", [], characters(t))
      end)
      |> maybe(data[:start_after], fn s -> element("StartAfter", [], characters(encode(s, enc))) end)

    contents = Enum.map(data.objects, &content_elem(&1, enc))

    common =
      Enum.map(data.common_prefixes, fn cp ->
        element("CommonPrefixes", [], [element("Prefix", [], characters(encode(cp, enc)))])
      end)

    root =
      element("ListBucketResult", [{"xmlns", XML.namespace()}], children ++ contents ++ common)

    XML.encode(root)
  end

  defp content_elem(obj, enc) do
    element("Contents", [], [
      element("Key", [], characters(encode(obj.key, enc))),
      element("LastModified", [], characters(XML.iso8601(obj.last_modified))),
      element("ETag", [], characters(XML.quote_etag(obj.etag))),
      element("Size", [], characters(Integer.to_string(obj.size))),
      element("StorageClass", [], characters("STANDARD"))
    ])
  end

  # encoding-type=url → S3 风格 URL 编码（query 模式：A-Za-z0-9-_.~ 原样，'/' 编为 %2F，空格 %20）。
  # 复用 Canonical.uri_encode/2 的 query 模式（与 SigV4 同一 UriEncode，铁律 5 一致性）。
  defp encode(value, "url") when is_binary(value),
    do: Maxio.Auth.SigV4.Canonical.uri_encode(value, :query)

  defp encode(value, _enc), do: value

  defp encoding_type_value("url"), do: "url"
  defp encoding_type_value(_), do: nil

  defp maybe(children, falsy, _fun) when falsy in [nil, false, ""], do: children
  defp maybe(children, value, fun), do: children ++ [fun.(value)]
end
```

> 复用 `Canonical.uri_encode/2`（`:query` 模式：unreserved 原样、其余 %XX 大写、空格 %20、`/`→%2F），与 AWS S3 的 `encoding-type=url` 行为一致，且与 SigV4 共用同一 UriEncode 实现（单一事实来源）。`encode/2` 用现有公开 `uri_encode/2`（`canonical.ex` 已 `@doc` 公开）。

### 测试

新建 `test/maxio/s3/encoding_type_e2e_test.exs`：

```elixir
defmodule Maxio.S3.EncodingTypeE2ETest do
  use Maxio.DataCase, async: false
  alias Maxio.Test.SigV4Request
  alias Maxio.S3.Endpoint

  @data_dir Path.join(System.tmp_dir!(), "maxio_encoding_type")

  setup do
    File.rm_rf(@data_dir)
    File.mkdir_p!(@data_dir)
    prev = Application.get_env(:maxio, :s3)
    Application.put_env(:maxio, :s3, Keyword.put(prev, :data_dir, @data_dir))
    on_exit(fn ->
      Application.put_env(:maxio, :s3, prev)
      File.rm_rf(@data_dir)
    end)
    :ok
  end

  defp call(conn), do: Endpoint.call(conn, Endpoint.init([]))

  test "ListObjectsV2 encoding-type=url → 含 <EncodingType>url</EncodingType> 且 Key percent-encode" do
    SigV4Request.signed_conn(:put, "/enc1") |> call()
    # key 含括号/空格：test file(3).png
    SigV4Request.signed_conn(:put, "/enc1/test%20file%283%29.png", body: "x") |> call()

    res =
      SigV4Request.signed_conn(:get, "/enc1", query: %{"encoding-type" => "url"}) |> call()

    assert res.status == 200
    assert res.resp_body =~ "<EncodingType>url</EncodingType>"
    assert res.resp_body =~ "test%20file%283%29.png"
  end

  test "ListObjectsV2 无 encoding-type → 不发 <EncodingType>，Key 原样" do
    SigV4Request.signed_conn(:put, "/enc2") |> call()
    SigV4Request.signed_conn(:put, "/enc2/plain.txt", body: "x") |> call()

    res = SigV4Request.signed_conn(:get, "/enc2") |> call()
    refute res.resp_body =~ "<EncodingType>"
    assert res.resp_body =~ "<Key>plain.txt</Key>"
  end
end
```

> key 路径用 `/enc1/test%20file%283%29.png`：经 RawPath 单次解码 → key 字面 `test file(3).png`；`encoding-type=url` 列举时该 key 应被编回 `test%20file%283%29.png`。

### 验证命令

```powershell
mix test test/maxio/s3/encoding_type_e2e_test.exs test/maxio/s3/views_test.exs
# 期望：全绿
mix compile --warnings-as-errors
mix test
# 期望：全绿
```

**Acceptance**：ListObjectsV2 `encoding-type=url` 发 `<EncodingType>url</EncodingType>` 且 Key/Prefix/Delimiter/StartAfter/CommonPrefixes percent-encode；无该参数时行为不变。
**Commit**：`feat(s3): ListObjectsV2 supports encoding-type=url (percent-encode keys + EncodingType element)`。

---

## FX-M3 · ListObjectVersions 支持 `encoding-type=url`

**偏差（medium）**：`ListObjectVersions ignores encoding-type=url`。

**maxio 现状**：`bucket.ex` `list_object_versions/1`（第 114-156 行）不读 `encoding-type`；`views/list_versions.ex` 不发 `<EncodingType>`、不编码 Key/Prefix/KeyMarker/Delimiter。

**MinIO/S3 正确行为**：`encoding-type=url` → 发 `<EncodingType>url</EncodingType>` 且对 KeyMarker/NextKeyMarker/Prefix/Key/Delimiter percent-encode（如 `test_file(3).png` → `test_file%283%29.png`）。
**source**：https://docs.aws.amazon.com/AmazonS3/latest/API/API_ListObjectVersions.html

### 完整修复

**(1) `lib/maxio/s3/handlers/bucket.ex` — `list_object_versions/1` 读 `encoding-type` 并传 view。** 在该函数体内加 `encoding_type = Map.get(qp, "encoding-type")`（第 125 行 `version_id_marker = ...` 后），并在 `ListVersions.render(%{...})` 入参加 `encoding_type: encoding_type`（放 `common_prefixes:` 后）。

**(2) `lib/maxio/s3/views/list_versions.ex` — 当 `encoding_type == "url"` 时 percent-encode + 发 `<EncodingType>`。** 整文件替换：

```elixir
defmodule Maxio.S3.Views.ListVersions do
  @moduledoc """
  ListObjectVersions 响应 XML（ListVersionsResult）。Version 与 DeleteMarker 交错（按入参顺序，
  调用方已按 key 升序、key 内 newest-first 排好）。delete marker 无 ETag/Size/StorageClass。
  NextKeyMarker/NextVersionIdMarker 仅截断时出现；CommonPrefixes 仅有 delimiter 时。
  encoding-type=url 时对 Key/Prefix/KeyMarker/NextKeyMarker/Delimiter/CommonPrefixes percent-encode
  并发 <EncodingType>url</EncodingType>（对齐 AWS，铁律 5）。owner_id/owner_display 用合成 "maxio"。
  """
  import Saxy.XML
  alias Maxio.S3.XML

  @owner_id "maxio"
  @owner_display "maxio"

  @spec render(map()) :: iodata()
  def render(data) do
    enc = Map.get(data, :encoding_type)

    head =
      [
        element("Name", [], characters(data.name)),
        element("Prefix", [], characters(encode(data.prefix || "", enc))),
        element("KeyMarker", [], characters(encode(data.key_marker || "", enc))),
        element("VersionIdMarker", [], characters(data.version_id_marker || "")),
        element("MaxKeys", [], characters(Integer.to_string(data.max_keys))),
        element("IsTruncated", [], characters(to_string(data.is_truncated)))
      ]
      |> maybe(encoding_type_value(enc), fn e -> element("EncodingType", [], characters(e)) end)
      |> maybe(data.is_truncated && data.next_key_marker, fn t ->
        element("NextKeyMarker", [], characters(encode(t, enc)))
      end)
      |> maybe(data.is_truncated && data.next_version_id_marker, fn t ->
        element("NextVersionIdMarker", [], characters(t))
      end)
      |> maybe(data.delimiter, fn d -> element("Delimiter", [], characters(encode(d, enc))) end)

    entries = Enum.map(data.versions, &version_or_marker(&1, enc))

    common =
      Enum.map(data.common_prefixes, fn cp ->
        element("CommonPrefixes", [], [element("Prefix", [], characters(encode(cp, enc)))])
      end)

    root = element("ListVersionsResult", [{"xmlns", XML.namespace()}], head ++ entries ++ common)
    XML.encode(root)
  end

  defp version_or_marker(%{is_delete_marker: true} = o, enc) do
    element("DeleteMarker", [], [
      element("Key", [], characters(encode(o.key, enc))),
      element("VersionId", [], characters(o.version_id)),
      element("IsLatest", [], characters(to_string(o.is_latest))),
      element("LastModified", [], characters(XML.iso8601(o.updated_at))),
      owner()
    ])
  end

  defp version_or_marker(o, enc) do
    element("Version", [], [
      element("Key", [], characters(encode(o.key, enc))),
      element("VersionId", [], characters(o.version_id)),
      element("IsLatest", [], characters(to_string(o.is_latest))),
      element("LastModified", [], characters(XML.iso8601(o.updated_at))),
      element("ETag", [], characters(XML.quote_etag(o.etag))),
      element("Size", [], characters(Integer.to_string(o.size))),
      element("StorageClass", [], characters(o.storage_class || "STANDARD")),
      owner()
    ])
  end

  defp owner do
    element("Owner", [], [
      element("ID", [], characters(@owner_id)),
      element("DisplayName", [], characters(@owner_display))
    ])
  end

  defp encode(value, "url") when is_binary(value),
    do: Maxio.Auth.SigV4.Canonical.uri_encode(value, :query)

  defp encode(value, _enc), do: value

  defp encoding_type_value("url"), do: "url"
  defp encoding_type_value(_), do: nil

  defp maybe(children, falsy, _fun) when falsy in [nil, false, ""], do: children
  defp maybe(children, value, fun), do: children ++ [fun.(value)]
end
```

### 测试（追加到 `test/maxio/s3/encoding_type_e2e_test.exs`）

```elixir
  test "ListObjectVersions encoding-type=url → <EncodingType>url</EncodingType> 且 Key percent-encode" do
    SigV4Request.signed_conn(:put, "/encv1") |> call()
    body = ~s(<VersioningConfiguration><Status>Enabled</Status></VersioningConfiguration>)
    SigV4Request.signed_conn(:put, "/encv1", query: %{"versioning" => ""}, body: body) |> call()
    SigV4Request.signed_conn(:put, "/encv1/test%20v%283%29.png", body: "x") |> call()

    res =
      SigV4Request.signed_conn(:get, "/encv1",
        query: %{"versions" => "", "encoding-type" => "url"}
      )
      |> call()

    assert res.status == 200
    assert res.resp_body =~ "<EncodingType>url</EncodingType>"
    assert res.resp_body =~ "test%20v%283%29.png"
  end
```

### 验证命令

```powershell
mix test test/maxio/s3/encoding_type_e2e_test.exs test/maxio/s3/list_versions_e2e_test.exs
# 期望：全绿
mix compile --warnings-as-errors
mix test
# 期望：全绿
```

**Acceptance**：ListObjectVersions `encoding-type=url` 发 `<EncodingType>url</EncodingType>` 且 Key/Prefix/KeyMarker/Delimiter/CommonPrefixes percent-encode；无该参数时不变。
**Commit**：`feat(s3): ListObjectVersions supports encoding-type=url`。

---

## FX-M4 · CopyObject COPY 保留源 metadata/tags

**偏差（medium）**：`CopyObject with x-amz-metadata-directive: COPY (default) drops user metadata and tags from the source object`。

**maxio 现状**：`copy/1` 只搬 content_type；`put_metadata/3`（FX-H2 后改为 `put_version_with_id/4`）未带 `src_obj.metadata`/`src_obj.tags`，源对象的用户 metadata（x-amz-meta-*）与 object tags 被丢弃。`src_obj` 结构已含 `.metadata`/`.tags`（见 `Object` schema 字段）。

**MinIO/S3 正确行为**：`x-amz-metadata-directive=COPY`（默认）保留所有源 metadata；tags 除非 `x-amz-tagging-directive=REPLACE` 否则从源复制。
**source**：https://docs.aws.amazon.com/AmazonS3/latest/API/API_CopyObject.html

### 完整修复（`lib/maxio/s3/handlers/object.ex`）

在 FX-H2 后的 `copy/1` 里，`put_version_with_id(dest_bucket, dest_key, dest_version_id, %{...})` 的 attrs map 按 directive 带上 metadata/tags。把该调用替换为：

```elixir
    # COPY（默认）：保留源 metadata 与 tags；REPLACE：用请求头新 metadata/tags（x-amz-meta-* / x-amz-tagging）。
    {meta_map, tags_map} = copy_metadata_and_tags(conn, src_obj, directive)

    {:ok, obj} =
      Objects.put_version_with_id(dest_bucket, dest_key, dest_version_id, %{
        size: size,
        etag: etag,
        content_type: content_type,
        storage_class: "STANDARD",
        metadata: meta_map,
        tags: tags_map
      })
```

并加 helper（放在 `copy_bytes/7` 子句之后、`meta/1` 之前）：

```elixir
  # 计算目标 metadata/tags：
  #   COPY（默认）→ 原样保留源对象的 metadata 与 tags；
  #   REPLACE     → metadata 来自 x-amz-meta-* 头，tags 来自 x-amz-tagging 头（无则空）。
  defp copy_metadata_and_tags(conn, src_obj, "REPLACE") do
    {parse_user_metadata(conn), parse_tagging_header!(conn)}
  end

  defp copy_metadata_and_tags(_conn, src_obj, _copy) do
    {src_obj.metadata || %{}, src_obj.tags || %{}}
  end

  # x-amz-meta-* 头 → %{"name" => "value"}（去掉 "x-amz-meta-" 前缀，名小写）。
  defp parse_user_metadata(conn) do
    conn.req_headers
    |> Enum.flat_map(fn {k, v} ->
      lk = String.downcase(k)

      case lk do
        "x-amz-meta-" <> name when name != "" -> [{name, v}]
        _ -> []
      end
    end)
    |> Map.new()
  end
```

> `parse_tagging_header!/1` 已存在（第 710-730 行，校验失败 → InvalidTag 400）。REPLACE 路径若无 `x-amz-tagging` 头则返回 `%{}`（删 tags，对齐 REPLACE 语义）。COPY 路径 metadata/tags 直取自 `src_obj`（`Object` schema 的 `:map` 列，默认 `%{}`）。`content_type` 已按 directive 计算（第 355-359 行），本单元不动。

### 测试（追加到 `test/maxio/s3/copy_object_version_test.exs` 或新建 `copy_object_metadata_test.exs`）

新建 `test/maxio/s3/copy_object_metadata_test.exs`：

```elixir
defmodule Maxio.S3.CopyObjectMetadataTest do
  use Maxio.DataCase, async: false
  import Plug.Conn
  alias Maxio.Test.SigV4Request
  alias Maxio.S3.Endpoint

  @data_dir Path.join(System.tmp_dir!(), "maxio_copy_meta")

  setup do
    File.rm_rf(@data_dir)
    File.mkdir_p!(@data_dir)
    prev = Application.get_env(:maxio, :s3)
    Application.put_env(:maxio, :s3, Keyword.put(prev, :data_dir, @data_dir))
    on_exit(fn ->
      Application.put_env(:maxio, :s3, prev)
      File.rm_rf(@data_dir)
    end)
    :ok
  end

  defp call(conn), do: Endpoint.call(conn, Endpoint.init([]))

  test "COPY（默认）保留源 tags（GetObjectTagging 返回源 tag）" do
    SigV4Request.signed_conn(:put, "/cm1") |> call()

    SigV4Request.signed_conn(:put, "/cm1/src.txt",
      body: "x",
      headers: [{"x-amz-tagging", "team=core&env=prod"}]
    )
    |> call()

    SigV4Request.signed_conn(:put, "/cm1/dst.txt",
      headers: [{"x-amz-copy-source", "/cm1/src.txt"}]
    )
    |> call()

    tg = SigV4Request.signed_conn(:get, "/cm1/dst.txt", query: %{"tagging" => ""}) |> call()
    assert tg.resp_body =~ "team"
    assert tg.resp_body =~ "core"
  end

  test "COPY 保留源 x-amz-meta-*（HEAD 目标回显源 metadata 计数 via tagging-count 不变；直接查元数据）" do
    SigV4Request.signed_conn(:put, "/cm2") |> call()

    SigV4Request.signed_conn(:put, "/cm2/src.txt",
      body: "x",
      headers: [{"x-amz-meta-author", "alice"}]
    )
    |> call()

    SigV4Request.signed_conn(:put, "/cm2/dst.txt",
      headers: [{"x-amz-copy-source", "/cm2/src.txt"}]
    )
    |> call()

    {:ok, dst} = Maxio.Objects.get_metadata("cm2", "dst.txt")
    assert dst.metadata == %{"author" => "alice"}
  end

  test "REPLACE：用请求头新 tags，不继承源 tags" do
    SigV4Request.signed_conn(:put, "/cm3") |> call()

    SigV4Request.signed_conn(:put, "/cm3/src.txt",
      body: "x",
      headers: [{"x-amz-tagging", "old=1"}]
    )
    |> call()

    SigV4Request.signed_conn(:put, "/cm3/dst.txt",
      headers: [
        {"x-amz-copy-source", "/cm3/src.txt"},
        {"x-amz-metadata-directive", "REPLACE"},
        {"x-amz-tagging", "new=2"}
      ]
    )
    |> call()

    tg = SigV4Request.signed_conn(:get, "/cm3/dst.txt", query: %{"tagging" => ""}) |> call()
    assert tg.resp_body =~ "new"
    refute tg.resp_body =~ "old"
  end
end
```

> 说明：maxio 当前 PutObject 不解析 `x-amz-meta-*`（仅 tags 与 content_type），但 PutObject 路径不在本次偏差范围；本单元只保证 **CopyObject** COPY 保留源已有的 metadata/tags、REPLACE 用请求头。源对象的 metadata 经 `Objects.get_metadata` 直读断言（最确定）；tags 经 GetObjectTagging 端到端断言。

### 验证命令

```powershell
mix test test/maxio/s3/copy_object_metadata_test.exs
# 期望：3 tests, 0 failures
mix compile --warnings-as-errors
mix test
# 期望：全绿
```

**Acceptance**：CopyObject COPY 保留源 metadata 与 tags；REPLACE 用请求头 metadata/tags（不继承源）。
**Commit**：`fix(s3): CopyObject COPY preserves source user metadata and tags; REPLACE uses request headers`。

---

## FX-M5 · PutBucketPolicy 拒绝不支持的 Condition 算子（400 MalformedPolicy）

**偏差（medium）**：`Unsupported/deferred Condition operators are accepted at PutBucketPolicy and silently fail-closed at evaluation`。

**maxio 现状**：`Statement.parse_conditions/1`（`statement.ex:152-154`）原样放行任意 Condition map；`parse_policy` 回 `{:ok,...}`、PutBucketPolicy 对用 `StringEqualsIgnoreCase`/`NumericLessThan`/`ArnLike`/`*IfExists`/`Null` 的策略回 204。eval 时 `Condition.hold?/2` 把 `@known` 外算子判 false（`condition.ex:19,27-31`），导致 Allow 静默不命中、更危险的是 **Deny 静默不触发**。

**MinIO/S3 正确行为**：`condition.UnmarshalJSON` 在 parse 期拒绝未知算子（'condition is not handled'），PutBucketPolicy 回 MalformedPolicy(400)，绝不存储「行为与所写不符」的策略。
**source**：https://github.com/minio/pkg/blob/master/policy/condition/func.go

### 完整修复（`lib/maxio/policy/statement.ex`）

`parse_conditions/1` 校验算子在受支持集合内，否则 `{:error, :malformed}`。复用 `Maxio.Policy.Condition` 的受支持集（不硬编码两份）——在 `Condition` 暴露已知算子，`Statement` 引用之。

**(1) `lib/maxio/policy/condition.ex` — 暴露 `supported_operators/0`。** 在 `@known` 定义后加：

```elixir
  @doc "本 MVP 支持的 Condition 算子集合（PutBucketPolicy parse 期校验复用，单一事实来源）。"
  @spec supported_operators() :: [String.t()]
  def supported_operators, do: @known
```

**(2) `lib/maxio/policy/statement.ex` — `parse_conditions/1` 校验算子。** 替换第 152-154 行：

```elixir
  defp parse_conditions(nil), do: {:ok, %{}}

  defp parse_conditions(%{} = cond_map) do
    supported = MapSet.new(Maxio.Policy.Condition.supported_operators())

    if Enum.all?(Map.keys(cond_map), &MapSet.member?(supported, &1)) do
      {:ok, cond_map}
    else
      {:error, :malformed}
    end
  end

  defp parse_conditions(_), do: {:error, :malformed}
```

> eval 期 fail-closed（`condition.ex` `@known` 守卫）保留作纵深防御（铁律 3），但 SDK 可见契约现在是 Put 期清晰 400。`from_json/1` 经 `parse_conditions/1` 已串入校验，整链 `{:error, :malformed}` → `parse_policy` → 400 MalformedPolicy。

### 测试

追加到 `test/maxio/policy/statement_test.exs`（纯函数）：

```elixir
  test "parse_conditions 拒绝未支持算子（StringEqualsIgnoreCase）→ malformed" do
    json = ~s({"Statement":[{"Effect":"Deny","Principal":"*","Action":"s3:GetObject","Resource":"arn:aws:s3:::b/*","Condition":{"StringEqualsIgnoreCase":{"s3:prefix":"x"}}}]})
    assert {:error, :malformed} = Maxio.Policy.Statement.parse_policy(json, "b")
  end

  test "parse_conditions 接受支持算子（StringEquals/Bool/IpAddress/DateGreaterThan/StringLike）" do
    json = ~s({"Statement":[{"Effect":"Allow","Principal":"*","Action":"s3:GetObject","Resource":"arn:aws:s3:::b/*","Condition":{"Bool":{"aws:SecureTransport":"true"}}}]})
    assert {:ok, [_]} = Maxio.Policy.Statement.parse_policy(json, "b")
  end
```

并端到端追加到 `test/maxio/s3/bucket_policy_test.exs`：

```elixir
  test "PutBucketPolicy 含未支持 Condition 算子 → 400 MalformedPolicy" do
    SigV4Request.signed_conn(:put, "/pbc1") |> call()

    policy = ~s({"Version":"2012-10-17","Statement":[{"Effect":"Deny","Principal":"*","Action":["s3:GetObject"],"Resource":["arn:aws:s3:::pbc1/*"],"Condition":{"NumericLessThan":{"s3:max-keys":"10"}}}]})

    res = SigV4Request.signed_conn(:put, "/pbc1", query: %{"policy" => ""}, body: policy) |> call()
    assert res.status == 400
    assert res.resp_body =~ "MalformedPolicy"
  end
```

### 验证命令

```powershell
mix test test/maxio/policy/statement_test.exs test/maxio/policy/condition_test.exs test/maxio/s3/bucket_policy_test.exs
# 期望：全绿
mix compile --warnings-as-errors
mix test
# 期望：全绿（最终基线 = 510 + 本计划全部新增用例）
```

**Acceptance**：含未支持 Condition 算子的 PutBucketPolicy → 400 MalformedPolicy；支持算子集仍 204；eval 期 fail-closed 不回归。
**Commit**：`fix(policy): reject unsupported Condition operators at PutBucketPolicy (400 MalformedPolicy)`。

---

## § 全批收尾验证（每批末尾由独立 verifier/code-reviewer 执行）

```powershell
$env:Path = 'C:\Users\dyz\Documents\dev\usr\Elixir\bin;' + $env:Path
$env:ERL_FLAGS = '-kernel standard_io_encoding unicode'
docker start maxio-db   # 若容器未起
mix compile --warnings-as-errors    # 期望：零警告
mix test                            # 期望：全绿，0 failures（计数 ≥ 510 + 新增）
```
失败则按 AGENTS.md「禁止打补丁式修复」系统化定位根因再迭代，绝不局部 hack 掩盖。每个单元的实现与审查必须分属不同 subagent / 上下文（铁律 §4.1）。

---

## § 已推迟（low，本计划不实现，文档化、绝不静默）

以下 12 个 low 偏差经评估为「错误码字符串差异 / cosmetic 头 / 过度宽松校验」，真实 SDK 容忍，留待后续里程碑或单独 cleanup（来源 `tasks/wazdy5gh6.output` synthesis.prioritized 的 low 项）：

1. **X-Amz-Expires > 604800 错误码**：现回 `AuthorizationQueryParametersError`，应回 `MaximumExpires`（HTTP 400 已对）。fix：`auth.ex check_presigned_expiry/2` 拆分 `< 1` 与 `> 604800`，后者加 `:maximum_expires` → `{"MaximumExpires", 400, "Credentials provided in the request have expired"}`。
2. **缺 x-amz-date 的 header-auth 错误码**：现 `AuthorizationHeaderMalformed`，MinIO 为 `ErrMissingDateHeader`（AccessDenied/400）。需复用 FX-M1 的 AccessDenied-at-400 变体。
3. **重复 query 键 / 重复 header 名 canonical**：query 侧已被 FX-H3 的 `{name,value}` 排序顺带消解；header 侧（重复名应逗号合并到一行）仍 defer——真实 SDK 不发重复签名头。
4. **GET/HEAD delete-marker 版本 405 缺 `Allow` 头**：`object.ex get/1`/`head/1` 的 405 分支加 `put_resp_header(conn, "allow", "DELETE")`。cosmetic。
5. **非 AWS Principal 类型（Service/CanonicalUser/Federated）**：`statement.ex parse_principal/1` catch-all 扁平化为 never-match AWS 列表。应显式建模或 Put 期拒。
6. **GetBucketPolicy 返回再序列化 JSON**（非 PUT 原字节）：`ecto_store.ex` 存原始 JSON 字节并回放。语义等价，仅影响 mc/IaC diff。
7. **x-amz-grant-* ACL 头静默降级 private**：`acl.ex resolve_canned!/1` 应实现 grant 头或显式 501/400，而非 200 + 更严权限。fail-safe 但违反「绝不静默不同语义」。
8. **CORS 实际响应带 `Access-Control-Allow-Methods`**（S3 仅预检发）：`cors.ex handle_actual/2` 闭包去掉该头。浏览器在实际响应忽略它，cleanup。
9. **Lifecycle 规则校验不强制 Filter/至少一个 action**：`lifecycle.ex valid_rule?/1` 应要求至少一个 action + Filter。过度宽松（接受比 S3 多），执行本就 defer。
10–12. 其余 synthesis 列出的 low 细项（与上重叠的错误码/校验边界）一并随对应模块后续 cleanup。

> 注：审计 synthesis 标 `low: 12`；本节按主题归并列出可操作的修复指引，确保「识别即文档化、绝不静默」（铁律 3）。BATCH 1-3 已覆盖全部 critical+high+medium（13 项）。
