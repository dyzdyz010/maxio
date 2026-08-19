defmodule Maxio.Config.DeploymentId do
  @moduledoc """
  部署标识（madmin `ServerInfo.deploymentID`）的惰性引导。

  这是 config store 在第一批的**第一个真实消费者**——把"运行时配置存储"和"Admin API"
  两件事绑在一起的那颗螺丝。

  ## 为什么是"首次读取时生成"而不是"启动时生成"

  启动期写 PG 会给 `Application.start/2` 增加一个新的失败面（DB 未就绪时要么崩、要么
  又得加一层"审计绝不成为启动失败原因"式的兜底），而 deployment id 只有 ServerInfo /
  Console 会读，晚一点生成没有任何代价。惰性引导让"没人问就不写库"成立，也让测试不必
  为一次启动期写入准备 sandbox。

  ## 并发安全

  两个请求同时首次读 → 两边都生成 UUID → `runtime_configs` 的 `(subsystem, key)` 唯一索引
  让其中一个失败（`Maxio.Config.set/4` 把它归一成 `:config_version_conflict`）。失败方
  **不重试写**，而是重读——重试写会在两个进程之间反复互斥；重读拿到的是赢家写下的那个 id，
  语义完全正确。
  """

  alias Maxio.Config
  alias Maxio.S3.Log

  @subsystem :cluster
  @key :deployment_id

  @doc "配置键（供 CLI / 测试引用，绝不各写一份字面量）。"
  @spec config_key() :: {atom(), atom()}
  def config_key, do: {@subsystem, @key}

  @doc """
  读取部署标识；没有就生成一个 UUIDv4 并持久化。

  返回 `{:ok, id}` 或 `{:error, reason}`。**绝不**在写失败时返回一个临时 id——那会让
  同一个集群在不同请求里报出不同的 deploymentID，比没有这个字段更有害（监控会把它当成
  两套部署）。
  """
  @spec get_or_create(keyword()) :: {:ok, String.t()} | {:error, term()}
  def get_or_create(opts \\ []) do
    case current() do
      id when is_binary(id) and id != "" -> {:ok, id}
      _absent -> create(opts)
    end
  end

  # 读取点写成**字面量**（不是 @subsystem/@key 变量）：`Maxio.Config.SchemaTest` 的静态
  # 漂移守卫靠在 lib/ 里 grep `Maxio.Config.get(:cluster, :deployment_id` 来证明这个白名单键
  # 确实有人读。用变量拼出来的调用点守卫看不见，白名单就会退化成一张没人读的许愿单。
  @spec current() :: String.t() | nil
  def current, do: Config.get(:cluster, :deployment_id)

  defp create(opts) do
    generated = Ecto.UUID.generate()

    write_opts =
      opts
      |> Keyword.take([:repo])
      |> Keyword.merge(source: "system", expected_version: nil)

    case Config.set(@subsystem, @key, generated, write_opts) do
      {:ok, _outcome} ->
        Log.info("generated deployment id on first read",
          action: "config_deployment_id_bootstrap",
          config_subsystem: to_string(@subsystem),
          config_key: to_string(@key),
          config_source: "system"
        )

        {:ok, generated}

      {:error, :config_version_conflict} ->
        # 另一个请求刚刚赢了首写。重读（不是重写）——赢家写下的 id 才是权威。
        reread(opts, :config_version_conflict)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp reread(opts, reason) do
    _ =
      Maxio.Config.Store.load_all!(
        Keyword.take(opts, [:repo]) ++ [reason: {:deployment_id_reread, reason}]
      )

    case current() do
      id when is_binary(id) and id != "" ->
        {:ok, id}

      _absent ->
        {:error, {:deployment_id_unavailable, reason}}
    end
  end
end
