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
  """

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
end
