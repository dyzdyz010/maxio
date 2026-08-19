defmodule Maxio.S3.ListQuery do
  @moduledoc """
  列举类请求（ListObjects / ListObjectsV2 / ListObjectVersions / ListMultipartUploads）的
  **query 参数归一化**——HTTP 边界上「空串 vs 缺省」歧义的单一收敛点（铁律 1：请求先 normalize
  成内部契约，下游只认契约）。

  ## 为什么在这一层

  `?delimiter=`（参数存在、值为空）只在 HTTP query 里才可能出现：`Plug.Conn.Query` 把它解析成
  `%{"delimiter" => ""}`，与「完全没带 delimiter」（key 缺席）在 map 上是两种形态，但在 S3 语义上
  是同一件事。内部契约（`Maxio.Objects` / `Maxio.Listing` / `Maxio.Multipart` 的 list opts）只有
  「有 delimiter（非空串）」与「无 delimiter（nil）」两种状态——`""` 从来不是合法契约值：
  它会一路传到各折叠实现的 `:binary.match(rest, "")`，触发
  `ArgumentError: 2nd argument: not a valid pattern` → 500 InternalError。

  故归一化只能做在**入口**（handler 解析 query 处 + 同源读 query 的 authz 条件构造处），而不是在
  下游四份 `common_prefix_of/3` 里各加一个 `""` 特例——后者是把边界歧义泄漏进领域层，且每新增一条
  列举路径就要再补一次特例（AGENTS.md §4.2 禁止的补丁式修复）。

  ## S3 语义依据

  * 空 delimiter 等价于「无 delimiter」：不做任何前缀折叠，递归平铺列举。AWS API Reference 只描述
    「指定 delimiter 时」的分组行为，未明文定义空串（VERIFY-AT-IMPL 已核验：无明文），故对齐 MinIO
    实现——`cmd/metacache-server-pool.go` `listPath/2` 里 `o.Separator == ""` 与缺省同路，
    `o.Recursive = true`（只有 `"/"` 才走非递归分组）。真实 mc 的 `ls/rm/cp --recursive` 发的正是
    `GET /<bucket>?delimiter=&encoding-type=url&fetch-owner=true&list-type=2`。
  * 响应不回显 `<Delimiter>`：ListMultipartUploads 官方文档明确「If you don't specify a delimiter in
    your request, this element is absent from the response.」，四个 API 的官方示例响应同此；MinIO 的
    四个 List* 响应结构体一律 `xml:"Delimiter,omitempty"`（`cmd/api-response.go`），永不产出空
    `<Delimiter></Delimiter>`。本项目四个 view 的 `maybe/3` 同样把 `""` 视为 falsy 而省略该元素，
    归一化为 `nil` 后渲染逐字节不变——这也是最保守的做法。

  非二进制值（如 `?delimiter[]=x` 被解析成 list、或嵌套 map）同样归一为 `nil`：契约只接受
  `String.t() | nil`，其余按「未指定」处理，绝不把不可预期的形态漏给下游 `:binary.match/2`。

  ## 游标参数（`cursor/2`）

  分页游标同属这类边界歧义，但表现出的缺陷与 delimiter 不同类：空串游标不会崩，会**参数遮蔽**。
  `Maxio.Objects.list_objects_v2/2` 里

      cursor = Map.get(opts, :continuation_token) || Map.get(opts, :start_after)

  依赖「未指定 = falsy」，而 Elixir 中 `""` 是 truthy——`?list-type=2&continuation-token=&start-after=dir/`
  会让**空**的 continuation-token 吞掉**非空**的 start-after，静默返回全量而非 `dir/` 之后的一页。
  内部契约里游标同样只有「有（非空串）」与「无（nil）」两种状态，故与 delimiter 同层、同理归一。

  六个游标参数逐个核过，`""` 一律归一为 `nil`：

  | 参数 | API | `""` 归一前的实际行为 | 归一后 |
  |---|---|---|---|
  | `continuation-token` | V2 | **遮蔽 `start-after`**（真 bug） | 等价未指定 |
  | `start-after` | V2 | `key > ""`——S3 key 恒非空故等价 | 同（显式化） |
  | `marker` | V1 | 经 `list_v1_marker_cursor/2` → `key > ""`，等价 | 同（显式化） |
  | `key-marker` | Versions / MPU | `key > ""`，等价 | 同（显式化） |
  | `version-id-marker` | Versions | 与非空 key-marker 并用时 `version_id < ""` 恒假，等价 | 同（显式化） |
  | `upload-id-marker` | MPU | 查不到 marker upload，回落纯 key 游标，等价 | 同（显式化） |

  即只有 `continuation-token` 是行为修复，其余五个是把「碰巧等价」变成「按契约显式」——纵深防御，
  也让六个参数在同一处读同一套规则，不必逐个复推等价性证明。响应 XML 逐字节不变：四个 view 的
  marker 元素一律 `data.x || ""`、`maybe/3` 把 `""` 视为 falsy，`nil` 与 `""` 渲染相同。

  **非空游标的分页语义逐字不变**——本模块只动 `""`。

  ### 为什么 `part-number-marker` 不在这六个之列

  ListParts 的 `part-number-marker` 是**整型**游标，不是字符串游标，故不共享本模块的
  `String.t() | nil` 契约。它在 `s3/handlers/multipart.ex` 经 `parse_int/2` 读取，而
  `Integer.parse("")` 返回 `:error` → 落到 default `0`，即「从第 0 个 part 之后开始」＝未指定；
  同理 `x-amz-part-number-marker`（`s3/handlers/object.ex`）经
  `parse_limited_integer_header!/5` 也归到 `0`。空串在整型游标上既不会崩、也不会遮蔽任何别的
  参数（ListParts 只有这一个游标），所以它**不是**本模块要收敛的那类边界歧义——把它塞进
  `@cursor_params` 反而会让一个整型参数被当成字符串游标处理。

  ### 白名单的强度：运行期守卫，不是编译期检查

  `cursor/2` 的 `name in @cursor_params` 是函数子句守卫，未列举的参数名在**运行期**抛
  `FunctionClauseError`（不是编译期错误，也不是静默放行）。它之所以仍然足以防住"漏审参数"：
  `cursor/2` 的全部调用点（`s3/handlers/bucket.ex`、`s3/handlers/multipart.ex`）传的都是
  **编译期字面量**，参数名从不来自请求数据，故用户输入**不可能**触发这条守卫——它约束的是
  开发者（新增列举路径时必须先把参数补进这张表并核过空串语义），而不是运行期的攻击面。
  真要在编译期挡住漏审，得把 `cursor/2` 改成宏或为每个参数生成具名函数；当前调用点数量下
  这不划算，故明确记为"运行期守卫 + 全字面量调用点"，而不是声称编译期保证。

  ## 空 `continuation-token` 的 S3 语义（VERIFY-AT-IMPL：已核验，结论与既有假设相反）

  * **AWS 官方 API Reference 无明文**：ListObjectsV2 的 `continuation-token` 条目只说
    「`ContinuationToken` indicates to Amazon S3 that the list is being continued on this bucket
    with a token」，无 Length Constraints、无空串说明；Errors 节只列 `NoSuchBucket`。
  * **但真实 AWS 与当前 MinIO 都是拒绝，不是忽略**：minio/minio#5931 报告 AWS S3 对空
    ContinuationToken 返回「The continuation token provided is incorrect」，MinIO 当时忽略；
    PR #5940 起 MinIO 已改为对齐 AWS，`cmd/api-resources.go` `getListObjectsV2Args` 首段即

        // The continuation-token cannot be empty.
        if val, ok := values["continuation-token"]; ok {
            if len(val[0]) == 0 { errCode = ErrIncorrectContinuationToken; return ... } }

    `ErrIncorrectContinuationToken` = `InvalidArgument` / 400 /
    "The continuation token provided is incorrect"（`cmd/api-errors.go`）。
  * 本次**仍取宽松的「忽略」语义**：它无条件优于现状（遮蔽 = 静默返回错误结果），且不新增拒绝路径；
    但「是否改判 400 InvalidArgument」是一个新错误面的设计决策，须由架构侧定夺，故留作
    **VERIFY-AT-IMPL**，不在本次实现里自行落地。
  * 其余五个游标参数无此争议：MinIO 用 Go `url.Values.Get/1`，`""` 与缺席在 Go 里本就无从区分，
    下游一律按「无 marker」处理——空串等价未指定即 MinIO 语义本身。

  分析/清单/指标三类配置列举（`?analytics`/`?inventory`/`?metrics`）自带不透明 token 语义，
  已在各自模块显式处理 `""`（`Analytics.list_configs/2` 的 `"" -> 0` + `blank_to_nil/1`），
  不经本模块。
  """

  # 允许经 `cursor/2` 归一的 query 参数白名单——逐个核过空串语义（见上表）。
  # 未列举的参数名不会被静默放行，而是在 `cursor/2` 的子句守卫上**运行期**抛 FunctionClauseError
  # （非编译期检查）；全部调用点传编译期字面量，故这条守卫只对开发者生效，用户输入到不了它。
  # 新增列举路径须先把参数补进这张表并核语义（见 moduledoc「白名单的强度」）。
  @cursor_params ~w(continuation-token start-after marker key-marker version-id-marker upload-id-marker)

  @doc """
  从 query 参数 map 取归一化后的 delimiter：`nil`（未指定/空串/非法形态）或非空字符串。
  """
  @spec delimiter(map()) :: String.t() | nil
  def delimiter(query_params) when is_map(query_params) do
    query_params |> Map.get("delimiter") |> normalize_delimiter()
  end

  @doc """
  归一化单个 delimiter 值：空串与非二进制值 → `nil`（等价于未指定）。
  """
  @spec normalize_delimiter(term()) :: String.t() | nil
  def normalize_delimiter(""), do: nil
  def normalize_delimiter(value) when is_binary(value), do: value
  def normalize_delimiter(_other), do: nil

  @doc """
  从 query 参数 map 取归一化后的分页游标：`nil`（未指定/空串/非法形态）或非空字符串。

  `name` 必须是 `#{inspect(@cursor_params)}` 之一——白名单即「空串语义已逐个核过」的证据。
  该约束是子句守卫，其余参数名在**运行期**抛 `FunctionClauseError`；因所有调用点传的都是编译期
  字面量，它实际上只是对开发者的护栏（见 moduledoc「白名单的强度：运行期守卫，不是编译期检查」）。
  """
  @spec cursor(map(), String.t()) :: String.t() | nil
  def cursor(query_params, name) when is_map(query_params) and name in @cursor_params do
    query_params |> Map.get(name) |> normalize_cursor()
  end

  @doc """
  归一化单个游标值：空串与非二进制值 → `nil`（等价于未指定）。非空字符串原样透传，
  故**非空游标的分页语义逐字不变**。
  """
  @spec normalize_cursor(term()) :: String.t() | nil
  def normalize_cursor(""), do: nil
  def normalize_cursor(value) when is_binary(value), do: value
  def normalize_cursor(_other), do: nil
end
