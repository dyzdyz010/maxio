defmodule Maxio.Admin.ErrorView do
  @moduledoc """
  把 `%Maxio.S3.Error{}` 渲染为 madmin 期望的 **JSON** 错误体（与 `Maxio.S3.ErrorView`
  的 XML 渲染平行：一个错误契约、两个 view，铁律 1）。

  线格式来自 MinIO 自己的实现事实——admin 面复用 S3 的 `APIErrorResponse` struct，只是
  换成 JSON 编码器（`cmd/api-errors.go` 的 `writeErrorResponseJSON`）：

      {"Code":"NotImplemented","Message":"...","Resource":"/minio/admin/v3/info",
       "RequestId":"...","HostId":""}

  `Code` / `Message` / `Resource` / `RequestId` / `HostId` 五个字段在 Go 侧**没有
  omitempty**，缺省也会以空串出现，因此这里恒发五个字段；`Key` / `BucketName` /
  `Region` 等带 omitempty 的字段 admin 面用不到，省略。

  # VERIFY-AT-IMPL V-A18：字段与 json tag 已对照 minio/cmd/api-errors.go 的
  # APIErrorResponse（Code, Message, Key omitempty, BucketName omitempty, Resource,
  # Region omitempty, RequestId, HostId, ActualObjectSize/RangeRequested omitempty）核实。
  # HostId 恒为空串：maxio 尚无 MinIO 的 deploymentID / host id 概念，绝不编造一个；
  # 待 ServerInfo 批次落地 deploymentID 后再填真实值。
  """

  alias Maxio.S3.Error

  @doc "渲染错误为 {status, json iodata}。"
  @spec render(Error.t()) :: {pos_integer(), iodata()}
  def render(%Error{} = err) do
    body =
      Jason.encode_to_iodata!(%{
        "Code" => err.code,
        "Message" => err.message,
        "Resource" => err.resource || "",
        "RequestId" => err.request_id || "",
        "HostId" => ""
      })

    {err.http_status, body}
  end
end
