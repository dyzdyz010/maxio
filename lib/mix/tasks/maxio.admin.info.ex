defmodule Mix.Tasks.Maxio.Admin.Info do
  @shortdoc "Recompute the madmin ServerInfo payload locally, without going through HTTP"
  @moduledoc """
  在本机 BEAM 内直接复算 `GET /minio/admin/v3/info` 的响应体，**不经 HTTP、不经签名**。

      mix maxio.admin.info
      mix maxio.admin.info --json
      mix maxio.admin.info --no-cache

  ## 为什么这个任务必须存在

  当 `mc admin info` 报错时，它把排查空间**对半砍**：

    * 本任务输出正常 → 数据聚合层是好的，问题在 HTTP / SigV4 / 线格式那一侧
      （接着用 `mix maxio.sigv4.debug` 复算签名）；
    * 本任务就已经报错 → 与 mc、与签名、与 JSON 都无关，是数据源坏了。

  这是 AGENTS.md §4.4「CLI + 结构化日志优先」在管控面的具体落实：管控面必须能在没有任何
  外部客户端的情况下被完整观测。
  """

  use Mix.Task

  alias Maxio.Admin.ServerInfo
  alias Maxio.Config.CLI

  @impl true
  def run(args) do
    {opts, rest, invalid} = OptionParser.parse(args, strict: [json: :boolean, no_cache: :boolean])

    if rest != [] or invalid != [] do
      Mix.raise("usage: mix maxio.admin.info [--json] [--no-cache]")
    end

    case CLI.boot() do
      :ok -> :ok
      {:error, reason} -> Mix.raise(reason)
    end

    info = ServerInfo.build(no_cache: Keyword.get(opts, :no_cache, false))

    if Keyword.get(opts, :json, false) do
      IO.puts(Jason.encode!(info))
    else
      print(info)
    end
  end

  defp print(info) do
    IO.puts(
      "[maxio admin.info] mode=#{fetch(info, "mode")} region=#{fetch(info, "region")} " <>
        "domain=#{format(Map.get(info, "domain"))} deployment_id=#{fetch(info, "deploymentID")}"
    )

    IO.puts(
      "[maxio admin.info.usage] buckets=#{count(info, "buckets")} " <>
        "objects=#{count(info, "objects")} versions=#{count(info, "versions")} " <>
        "delete_markers=#{count(info, "deletemarkers")} " <>
        "logical_bytes=#{get_in(info, ["usage", "size"])}"
    )

    backend = Map.get(info, "backend", %{})

    IO.puts(
      "[maxio admin.info.backend] type=#{fetch(backend, "backendType")} " <>
        "online_disks=#{fetch(backend, "onlineDisks")} " <>
        "offline_disks=#{fetch(backend, "offlineDisks")} " <>
        "standard_sc_parity=#{fetch(backend, "standardSCParity")}"
    )

    Enum.each(Map.get(info, "servers", []), &print_server/1)
  end

  defp print_server(server) do
    IO.puts(
      "[maxio admin.info.server] state=#{fetch(server, "state")} " <>
        "endpoint=#{fetch(server, "endpoint")} scheme=#{fetch(server, "scheme")} " <>
        "uptime_s=#{fetch(server, "uptime")} version=#{fetch(server, "version")} " <>
        "runtime=#{fetch(server, "runtime_version")} num_cpu=#{fetch(server, "num_cpu")}"
    )

    Enum.each(Map.get(server, "drives", []), fn drive ->
      IO.puts(
        "[maxio admin.info.drive] state=#{fetch(drive, "state")} path=#{fetch(drive, "path")} " <>
          "uuid=#{fetch(drive, "uuid")} total=#{fetch(drive, "totalspace")} " <>
          "used=#{fetch(drive, "usedspace")} avail=#{fetch(drive, "availspace")}"
      )
    end)
  end

  defp count(info, key), do: get_in(info, [key, "count"]) |> format()

  # 缺失的字段打成 "omitted"，绝不打成 0 或空——CLI 的读者和 JSON 的读者必须得到
  # 同一个结论："maxio 没有这个概念"，而不是"测得为零"。
  defp fetch(map, key), do: map |> Map.get(key) |> format()

  defp format(nil), do: "omitted"
  defp format(value) when is_list(value), do: Enum.join(value, ",")
  defp format(value), do: to_string(value)
end
