defmodule Maxio.Config do
  @moduledoc """
  运行时配置的**统一读写门面**（设计 D2 / D4）。

  ## 优先级（自高而低，硬规定）

      1. runtime override —— runtime_configs 表里该键的行（经 :persistent_term 快照读）
      2. env var          —— config/runtime.exs 已注入 Application env 的值
      3. compile default  —— config/*.exs 的值

  **为什么 runtime > env**：运维在 `mix maxio.config.set` 之后期望立刻看到效果；如果 env
  反过来压住 runtime，操作会静默无效（铁律 3 禁止）。env var 在容器编排里是"部署时意图"，
  runtime override 是"运维时意图"，后者更新更晚、更具体——与 `kubectl set env` 覆盖镜像
  默认值同构。

  第 2 层与第 3 层在**解析**上是同一次读取（`config/runtime.exs` 本来就把 env var 写进了
  Application env），区别只在**归因**：`source/2` 通过 Schema 声明的 `env_var` 是否存在来
  分辨两者。绝不靠猜——一个 `source/2` 说不清来源的配置面，等于没有取证能力。

  ## 迁移策略：门面第一版 fallback 到 `Application.get_env`

  未命中运行时覆盖时直接回落 Application env，语义与改造前**逐字相同**。于是第一批只需要
  接线少量键，不必一次改 160 个读取点。但有一条硬约束（D2）：**一旦某键进了
  `Maxio.Config.Schema` 白名单，它的所有读取点必须同批换成门面**——留一个直读点就会出现
  "CLI 说生效了、热路径却仍读旧值"的分歧。`Maxio.Config.SchemaTest` 静态守卫这一点。

  ## 写路径：写成功 ≠ 生效

  `set/4` 返回 `{:ok, %{applied: :hot | :next_cycle | :restart, version: n}}`。`applied` 是
  Schema 声明值的**诚实回传**：对 `:restart` 类键，返回值明确告诉运维"已持久化，但需要重启
  才生效"。CLI 与 Console 必须原样显示这句话。
  """

  import Ecto.Query

  alias Maxio.Config.{Coordinator, RuntimeConfig, RuntimeConfigAudit, Schema, Store}
  alias Maxio.S3.Log

  @no_default :"$maxio_config_no_default"
  @test_env Mix.env() == :test

  @type subsystem :: atom()
  @type key :: atom()
  @type source :: :runtime | :env | :compile | :default
  @type write_error ::
          {:unknown_config_key, subsystem(), key()}
          | {:forbidden_config_key, subsystem(), key()}
          | {:invalid_config_value, subsystem(), key(), String.t()}
          | {:invalid_config_source, String.t()}
          | :config_version_conflict
          | {:config_store_unavailable, term()}

  # ── 读 ─────────────────────────────────────────────────────────────────────

  @doc """
  读一个配置键的**生效值**：runtime override → Application env → 调用方默认。

  无默认值且三层都没有时返回 `nil`（与 `Application.get_env/2` 的既有语义一致）。
  """
  @spec get(subsystem(), key(), term()) :: term()
  def get(subsystem, key, default \\ @no_default) do
    case Store.lookup(subsystem, key) do
      {:ok, value} -> value
      :error -> app_env_get(subsystem, key, default)
    end
  end

  @doc "读一个配置键，三层都没有即 raise（fail-fast 的读取点用）。"
  @spec fetch!(subsystem(), key()) :: term()
  def fetch!(subsystem, key) do
    case Store.lookup(subsystem, key) do
      {:ok, value} ->
        value

      :error ->
        case app_env_fetch(subsystem, key) do
          {:ok, value} ->
            value

          :error ->
            raise KeyError,
              key: key,
              term: {:maxio_config, subsystem},
              message:
                "runtime config #{subsystem}.#{key} has no runtime override, no env var and " <>
                  "no compile-time default"
        end
    end
  end

  @doc """
  某个子系统的全部配置（keyword），运行时覆盖叠在 Application env 之上。
  兼容现有 `Keyword.get(config, :key)` 风格的读取点。
  """
  @spec get_all(subsystem()) :: keyword()
  def get_all(subsystem) do
    base =
      case Application.get_env(:maxio, subsystem) do
        value when is_list(value) -> value
        %{} = map -> Map.to_list(map)
        _other -> []
      end

    Enum.reduce(Store.snapshot(subsystem), base, fn {key, value}, acc ->
      Keyword.put(acc, key, value)
    end)
  end

  @doc """
  该键**实际生效的来源**。定位"我改了怎么没生效"的核心工具，绝不猜。

    * `:runtime` —— 本节点快照里有覆盖值；
    * `:env`     —— Schema 声明了 env_var 且该环境变量存在（runtime.exs 已把它写进 app env）；
    * `:compile` —— 值来自 Application env，但不是 env var 注入的；
    * `:default` —— 三层都没有，读到的是调用方默认。
  """
  @spec source(subsystem(), key()) :: source()
  def source(subsystem, key) do
    cond do
      match?({:ok, _}, Store.lookup(subsystem, key)) -> :runtime
      env_value(subsystem, key) != :error -> :env
      match?({:ok, _}, app_env_fetch(subsystem, key)) -> :compile
      true -> :default
    end
  end

  @doc """
  单键三层取证：生效值 + 来源 + apply 模式 + 版本 + 每层各自的值。

  `mix maxio.config.get` 与 Console 直接消费本函数——运维必须能一眼看到"生效值是哪一层给的"，
  而不是只看到一个数字。
  """
  @spec effective(subsystem(), key(), keyword()) :: map()
  def effective(subsystem, key, opts \\ []) do
    runtime = Store.lookup(subsystem, key)

    %{
      subsystem: subsystem,
      key: key,
      value: get(subsystem, key),
      source: source(subsystem, key),
      apply: schema_apply_mode(subsystem, key),
      version: version(subsystem, key, opts),
      runtime_value: unwrap(runtime),
      env_value: unwrap(env_value(subsystem, key)),
      app_env_value: unwrap(app_env_fetch(subsystem, key)),
      doc: schema_doc(subsystem, key)
    }
  end

  @doc "Synchronously reconcile the runtime snapshot before returning ordered effective values."
  @spec authoritative_effective(subsystem(), [key()], keyword()) ::
          {:ok, [map()]} | {:error, {:config_store_unavailable, atom()}}
  def authoritative_effective(subsystem, keys, opts \\ [])

  def authoritative_effective(subsystem, keys, opts)
      when is_atom(subsystem) and is_list(keys) and is_list(opts) do
    %{repo: repo, store: store} = authoritative_dependencies(opts)

    case store.reconcile!(repo: repo) do
      %{reloaded?: reloaded?} when is_boolean(reloaded?) ->
        versions = authoritative_version_index(repo)

        {:ok,
         Enum.map(keys, fn key ->
           effective(subsystem, key, versions: versions)
         end)}

      _unexpected ->
        {:error, {:config_store_unavailable, :reconcile_failed}}
    end
  rescue
    _error -> {:error, {:config_store_unavailable, :reconcile_failed}}
  catch
    :exit, _reason -> {:error, {:config_store_unavailable, :reconcile_exited}}
    _kind, _reason -> {:error, {:config_store_unavailable, :reconcile_failed}}
  end

  def authoritative_effective(_subsystem, _keys, _opts),
    do: {:error, {:config_store_unavailable, :invalid_request}}

  @doc "Read an explicit set of registered paths from one authoritative database snapshot."
  @spec authoritative_snapshot([{subsystem(), key()}], keyword()) ::
          {:ok,
           %{
             required({subsystem(), key()}) => %{
               value: term(),
               source: :runtime | :fallback,
               version: non_neg_integer() | nil
             }
           }}
          | {:error, term()}
  def authoritative_snapshot(paths, opts \\ []) do
    Coordinator.authoritative_snapshot(paths, opts)
  end

  @doc "白名单全量的三层取证视图（`mix maxio.config.list` / Console 用）。"
  @spec list(keyword()) :: [map()]
  def list(opts \\ []) do
    rows = version_index(opts)

    Schema.keys()
    |> filter_subsystem(Keyword.get(opts, :subsystem))
    |> Enum.map(fn {subsystem, key} ->
      effective(subsystem, key, versions: rows)
    end)
  end

  # ── 写 ─────────────────────────────────────────────────────────────────────

  @doc """
  写一个运行时覆盖值。

  `opts`：
    * `:source` —— `"admin_api" | "cli" | "console" | "system"`（必填，审计通道可枚举）
    * `:expected_version` —— 乐观并发；给了就必须与当前版本相符（首次覆盖用 `nil`）
    * `:principal_arn` / `:access_key_id` / `:request_id` —— 审计归属
    * `:repo` —— 测试/多 Repo 场景

  失败一律结构化错误（见 `t:write_error/0`），且**绝不部分生效**。
  """
  @spec set(subsystem(), key(), term(), keyword()) ::
          {:ok, map()} | {:error, write_error()}
  def set(subsystem, key, value, opts \\ []) do
    mutate_single(subsystem, key, {:set, key, value}, opts)
  end

  @doc """
  删除运行时覆盖值，回落 env / 编译期默认。

  重复 reset 不是错误，但**必须显式报告** `changed?: false`——静默的"成功"会让运维
  以为刚才那次 reset 干了什么事。
  """
  @spec reset(subsystem(), key(), keyword()) :: {:ok, map()} | {:error, write_error()}
  def reset(subsystem, key, opts \\ []) do
    mutate_single(subsystem, key, {:reset, key}, opts)
  end

  @doc "Atomically mutate one subsystem through the shared advisory-lock coordinator."
  @spec mutate_subsystem(subsystem(), [Coordinator.operation()], keyword()) ::
          {:ok, map()} | {:error, term()}
  def mutate_subsystem(subsystem, operations, opts \\ []) do
    Coordinator.mutate_subsystem(subsystem, operations, opts)
  end

  @doc "Atomically mutate one or more subsystems through the shared advisory-lock coordinator."
  @spec mutate_many([{subsystem(), [Coordinator.operation()]}], keyword()) ::
          {:ok, map()} | {:error, term()}
  def mutate_many(groups, opts \\ []) do
    Coordinator.mutate_many(groups, opts)
  end

  @doc "该键的变更审计流水，最近的在前。"
  @spec history(subsystem(), key(), keyword()) :: [RuntimeConfigAudit.t()]
  def history(subsystem, key, opts \\ []) do
    repo = repo(opts)
    limit = Keyword.get(opts, :limit, 20)
    subsystem_name = to_string(subsystem)
    key_name = to_string(key)

    repo.all(
      from a in RuntimeConfigAudit,
        where: a.subsystem == ^subsystem_name and a.key == ^key_name,
        order_by: [desc: a.inserted_at, desc: a.to_version],
        limit: ^limit
    )
  end

  # ── 内部：写适配 ───────────────────────────────────────────────────────────

  defp mutate_single(subsystem, key, operation, opts) do
    coordinator_opts = translate_expected_version(opts, key)

    case mutate_subsystem(subsystem, [operation], coordinator_opts) do
      {:ok, %{outcomes: outcomes}} -> {:ok, Map.fetch!(outcomes, key)}
      {:error, reason} -> log_write_rejection(subsystem, key, reason)
    end
  end

  defp translate_expected_version(opts, key) do
    case Keyword.fetch(opts, :expected_version) do
      :error ->
        Keyword.delete(opts, :expected_versions)

      {:ok, expected} ->
        opts
        |> Keyword.delete(:expected_version)
        |> Keyword.delete(:expected_versions)
        |> Keyword.put(:expected_versions, %{key => expected})
    end
  end

  defp log_write_rejection(subsystem, key, reason) do
    Log.warn("runtime config write rejected",
      action: "config_write_rejected",
      config_subsystem: to_string(subsystem),
      config_key: to_string(key),
      reason: inspect(reason),
      code: rejection_code(reason)
    )

    {:error, reason}
  end

  defp rejection_code({:unknown_config_key, _s, _k}), do: "UnknownConfigKey"
  defp rejection_code({:forbidden_config_key, _s, _k}), do: "ForbiddenConfigKey"
  defp rejection_code({:invalid_config_value, _s, _k, _r}), do: "InvalidConfigValue"
  defp rejection_code({:invalid_config_source, _s}), do: "InvalidConfigSource"
  defp rejection_code(_other), do: "ConfigWriteRejected"

  # ── 内部：三层读取 ─────────────────────────────────────────────────────────

  defp app_env_get(subsystem, key, default) do
    case app_env_fetch(subsystem, key) do
      {:ok, value} -> value
      :error when default == @no_default -> nil
      :error -> default
    end
  end

  defp app_env_fetch(subsystem, key) do
    case Application.get_env(:maxio, subsystem) do
      value when is_list(value) -> keyword_fetch(value, key)
      %{} = map -> Map.fetch(map, key)
      _other -> :error
    end
  end

  defp keyword_fetch(list, key) do
    if Keyword.keyword?(list), do: Keyword.fetch(list, key), else: :error
  end

  # env var 只做**归因**，不参与解析：runtime.exs 已经把它写进 Application env 了。
  # 这里再解析一次就会出现两套解析规则，两者一旦分叉，source/2 就在撒谎。
  defp env_value(subsystem, key) do
    case Schema.env_var(subsystem, key) do
      nil ->
        :error

      var ->
        case System.get_env(var) do
          nil -> :error
          value -> {:ok, value}
        end
    end
  end

  defp unwrap({:ok, value}), do: value
  defp unwrap(:error), do: nil

  defp schema_apply_mode(subsystem, key) do
    case Schema.fetch(subsystem, key) do
      {:ok, entry} -> entry.apply
      {:error, _reason} -> nil
    end
  end

  defp schema_doc(subsystem, key) do
    case Schema.fetch(subsystem, key) do
      {:ok, entry} -> entry.doc
      {:error, _reason} -> nil
    end
  end

  defp version(subsystem, key, opts) do
    case Keyword.fetch(opts, :versions) do
      {:ok, index} -> Map.get(index, {subsystem, key})
      :error -> lookup_version(subsystem, key, opts)
    end
  end

  defp lookup_version(subsystem, key, opts) do
    repo = repo(opts)
    subsystem_name = to_string(subsystem)
    key_name = to_string(key)

    repo.one(
      from r in RuntimeConfig,
        where: r.subsystem == ^subsystem_name and r.key == ^key_name,
        select: r.version
    )
  rescue
    # 版本号只是取证信息，DB 不可达时不该让"读一个配置"整体失败——生效值本身来自
    # 本地快照/Application env，与 PG 可达性无关。
    _e -> nil
  catch
    # Ecto 连接池 checkout 超时 / Repo 未起时是 exit 而不是 raise，rescue 接不住。
    _kind, _reason -> nil
  end

  defp version_index(opts) do
    repo = repo(opts)

    repo.all(from r in RuntimeConfig, select: {r.subsystem, r.key, r.version})
    |> Map.new(fn {subsystem, key, version} ->
      {{safe_atom(subsystem), safe_atom(key)}, version}
    end)
  rescue
    _e -> %{}
  catch
    _kind, _reason -> %{}
  end

  defp authoritative_version_index(repo) do
    repo.all(from r in RuntimeConfig, select: {r.subsystem, r.key, r.version})
    |> Map.new(fn {subsystem, key, version} ->
      {{safe_atom(subsystem), safe_atom(key)}, version}
    end)
  end

  defp safe_atom(name) do
    String.to_existing_atom(name)
  rescue
    ArgumentError -> :"$unknown"
  end

  defp filter_subsystem(keys, nil), do: keys

  defp filter_subsystem(keys, subsystem) do
    Enum.filter(keys, fn {s, _k} -> to_string(s) == to_string(subsystem) end)
  end

  defp authoritative_dependencies(opts) do
    if @test_env do
      %{repo: Keyword.get(opts, :repo, Maxio.Repo), store: Keyword.get(opts, :store, Store)}
    else
      %{repo: Maxio.Repo, store: Store}
    end
  end

  defp repo(opts) do
    if @test_env, do: Keyword.get(opts, :repo, Maxio.Repo), else: Maxio.Repo
  end
end
