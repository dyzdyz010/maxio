defmodule Mix.Tasks.Maxio.Config.Status do
  @shortdoc "Report local config snapshot version vs Postgres, drift and orphan keys"
  @moduledoc """
  本节点配置快照 vs PG 权威的对账取证。

      mix maxio.config.status
      mix maxio.config.status --json
      mix maxio.config.status --reconcile

  三件事必须能一眼看到：

    * **drift** —— 本节点快照与 PG 的**内容指纹**是否一致（判据是 `digest`，不是 count/sum：
      后者会碰撞）。不一致说明失效广播丢了一次（`Cluster.Notify` 是 best-effort），周期对账
      会在下一个周期收敛；
    * **orphan_config_keys** —— PG 里存在但当前 Schema 白名单没有的键。它们被**忽略**，
      绝不静默生效；常见成因是把节点回滚到了不认识这个键的旧版本二进制；
    * **store_unavailable_reason** —— PG 读不到时的原因。此时本节点全部回落
      Application env（即改造前的行为），但这件事必须是**说出来**的，不是猜出来的。
  """

  use Mix.Task

  alias Maxio.Config.{CLI, Store}

  @impl true
  def run(args) do
    {opts, rest, invalid} =
      OptionParser.parse(args, strict: [json: :boolean, reconcile: :boolean])

    if rest != [] or invalid != [] do
      Mix.raise("usage: mix maxio.config.status [--json] [--reconcile]")
    end

    case CLI.boot() do
      :ok -> :ok
      {:error, reason} -> Mix.raise(reason)
    end

    reconciled =
      if Keyword.get(opts, :reconcile, false) do
        Store.reconcile!()
      else
        nil
      end

    status = Store.status()

    if Keyword.get(opts, :json, false) do
      IO.puts(Jason.encode!(json(status, reconciled)))
    else
      print(status, reconciled)
    end
  end

  defp json(status, reconciled) do
    %{
      "node" => status.node,
      "local" => status.local,
      "authoritative" => status.authoritative,
      "drifted" => status.drifted,
      "loaded_at" => status.loaded_at && DateTime.to_iso8601(status.loaded_at),
      "last_reload_reason" => inspect(status.last_reload_reason),
      "orphan_config_keys" =>
        Enum.map(status.orphan_config_keys, fn {subsystem, key} -> "#{subsystem}.#{key}" end),
      "store_unavailable_reason" => status.store_unavailable_reason,
      "reconciled" => reconciled != nil && reconciled.reloaded?
    }
  end

  defp print(status, reconciled) do
    IO.puts(
      "[maxio config.status] node=#{status.node} " <>
        "local_count=#{status.local.count} local_version_sum=#{status.local.version_sum} " <>
        "local_digest=#{format_digest(status.local.digest)} " <>
        "authoritative=#{format_aggregate(status.authoritative)} drifted=#{status.drifted} " <>
        "loaded_at=#{status.loaded_at && DateTime.to_iso8601(status.loaded_at)} " <>
        "last_reload_reason=#{inspect(status.last_reload_reason)}"
    )

    if status.store_unavailable_reason do
      IO.puts(
        "[maxio config.status.blocker] postgres unreachable: #{status.store_unavailable_reason}; " <>
          "this node is serving with its last loaded snapshot (empty snapshot = plain " <>
          "Application env behaviour)"
      )
    end

    Enum.each(status.orphan_config_keys, fn {subsystem, key} ->
      IO.puts(
        "[maxio config.status.orphan] #{subsystem}.#{key} exists in Postgres but not in " <>
          "Maxio.Config.Schema; the override is IGNORED by this binary"
      )
    end)

    if reconciled do
      IO.puts("[maxio config.status.reconcile] reloaded=#{reconciled.reloaded?}")
    end
  end

  defp format_aggregate(nil), do: "unavailable"

  defp format_aggregate(%{count: count, version_sum: sum, digest: digest}) do
    "count=#{count},sum=#{sum},digest=#{format_digest(digest)}"
  end

  # 指纹截断只影响**打印**，判定永远比全值（见 Store.reconcile!/1）。从未装载过的节点
  # 打 "never_loaded" 而不是一串假指纹——"还没比过"和"比过且为空"是两件事。
  defp format_digest(nil), do: "never_loaded"
  defp format_digest(digest) when is_binary(digest), do: binary_part(digest, 0, 12)
end
