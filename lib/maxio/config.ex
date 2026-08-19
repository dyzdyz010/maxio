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

  alias Maxio.Config.{RuntimeConfig, RuntimeConfigAudit, Schema, Store}
  alias Maxio.Cluster.Notify
  alias Maxio.S3.Log

  @no_default :"$maxio_config_no_default"

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
    with {:ok, entry} <- Schema.fetch(subsystem, key),
         {:ok, casted} <- Schema.cast(subsystem, key, value),
         {:ok, source} <- validate_source(opts) do
      write(subsystem, key, {:set, casted}, entry, source, opts)
    else
      {:error, reason} -> log_write_rejection(subsystem, key, reason)
    end
  end

  @doc """
  删除运行时覆盖值，回落 env / 编译期默认。

  重复 reset 不是错误，但**必须显式报告** `changed?: false`——静默的"成功"会让运维
  以为刚才那次 reset 干了什么事。
  """
  @spec reset(subsystem(), key(), keyword()) :: {:ok, map()} | {:error, write_error()}
  def reset(subsystem, key, opts \\ []) do
    with {:ok, entry} <- Schema.fetch(subsystem, key),
         {:ok, source} <- validate_source(opts) do
      write(subsystem, key, :reset, entry, source, opts)
    else
      {:error, reason} -> log_write_rejection(subsystem, key, reason)
    end
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

  # ── 内部：写事务 ───────────────────────────────────────────────────────────

  defp write(subsystem, key, operation, entry, source, opts) do
    repo = repo(opts)
    apply_mode = Atom.to_string(entry.apply)

    result =
      repo.transaction(fn ->
        current = lock_current(repo, subsystem, key)

        with :ok <- check_expected_version(current, opts) do
          apply_operation(repo, subsystem, key, operation, current, apply_mode, source, opts)
        else
          {:error, reason} -> repo.rollback(reason)
        end
      end)

    case result do
      {:ok, outcome} -> finish_write(subsystem, key, entry, outcome, opts)
      {:error, reason} -> {:error, reason}
    end
  end

  defp lock_current(repo, subsystem, key) do
    subsystem_name = to_string(subsystem)
    key_name = to_string(key)

    repo.one(
      from r in RuntimeConfig,
        where: r.subsystem == ^subsystem_name and r.key == ^key_name,
        lock: "FOR UPDATE"
    )
  end

  defp check_expected_version(current, opts) do
    case Keyword.fetch(opts, :expected_version) do
      :error -> :ok
      {:ok, expected} -> compare_version(current, expected)
    end
  end

  defp compare_version(nil, nil), do: :ok
  defp compare_version(%RuntimeConfig{version: version}, version), do: :ok
  defp compare_version(_current, _expected), do: {:error, :config_version_conflict}

  defp apply_operation(repo, subsystem, key, {:set, value}, current, apply_mode, source, opts) do
    stored = Schema.encode_stored(value)
    next_version = if current, do: current.version + 1, else: 1

    attrs = %{
      subsystem: to_string(subsystem),
      key: to_string(key),
      value: stored,
      previous_value: current && current.value,
      version: next_version,
      apply_mode: apply_mode,
      updated_by: Keyword.get(opts, :principal_arn),
      source: source
    }

    # `FOR UPDATE` 只能锁**已存在**的行；两个进程同时首写同一个键时谁都锁不到东西，
    # 于是双双走 insert，由 (subsystem, key) 唯一索引裁决。输方拿到的不是"内部错误"，
    # 语义上就是一次版本冲突（它以为该键还没有覆盖值，事实上已经有了），因此归一成
    # :config_version_conflict —— 调用方对这个错误已经有重试/重读的处置（见
    # Maxio.Config.DeploymentId）。不能用 bang 版本：那会把一个**预期内**的并发结果
    # 变成穿透事务的异常，写路径"失败一律结构化错误"的承诺就破了。
    row =
      case (current || %RuntimeConfig{})
           |> RuntimeConfig.changeset(attrs)
           |> repo.insert_or_update() do
        {:ok, row} ->
          row

        {:error, %Ecto.Changeset{} = changeset} ->
          if unique_key_conflict?(changeset) do
            repo.rollback(:config_version_conflict)
          else
            # 其它 changeset 错误说明 Schema 校验与 DB 约束不一致（代码 bug），
            # 绝不悄悄归一成并发冲突——那会让一个真 bug 长期伪装成"偶发冲突"。
            raise Ecto.InvalidChangesetError, action: :insert_or_update, changeset: changeset
          end
      end

    insert_audit!(repo, subsystem, key, "set", %{
      old_value: current && current.value,
      new_value: stored,
      from_version: current && current.version,
      to_version: next_version,
      apply_mode: apply_mode,
      source: source,
      opts: opts
    })

    %{operation: :set, changed?: true, version: row.version, value: value}
  end

  defp apply_operation(_repo, _subsystem, _key, :reset, nil, _apply_mode, _source, _opts) do
    %{operation: :reset, changed?: false, version: nil, value: nil}
  end

  defp apply_operation(repo, subsystem, key, :reset, current, apply_mode, source, opts) do
    repo.delete!(current)

    insert_audit!(repo, subsystem, key, "reset", %{
      old_value: current.value,
      new_value: nil,
      from_version: current.version,
      to_version: current.version + 1,
      apply_mode: apply_mode,
      source: source,
      opts: opts
    })

    %{operation: :reset, changed?: true, version: nil, value: nil}
  end

  # 唯一索引冲突由 changeset 的 unique_constraint/3 转成 :subsystem 上的 :unique 错误
  # （见 RuntimeConfig.changeset/2 的 name: :runtime_configs_subsystem_key_index）。
  defp unique_key_conflict?(%Ecto.Changeset{errors: errors}) do
    Enum.any?(errors, fn {_field, {_msg, meta}} ->
      Keyword.get(meta, :constraint) == :unique
    end)
  end

  defp insert_audit!(repo, subsystem, key, operation, fields) do
    %RuntimeConfigAudit{}
    |> RuntimeConfigAudit.changeset(%{
      subsystem: to_string(subsystem),
      key: to_string(key),
      operation: operation,
      old_value: fields.old_value,
      new_value: fields.new_value,
      from_version: fields.from_version,
      to_version: fields.to_version,
      apply_mode: fields.apply_mode,
      principal_arn: Keyword.get(fields.opts, :principal_arn),
      access_key_id: Keyword.get(fields.opts, :access_key_id),
      request_id: Keyword.get(fields.opts, :request_id),
      source: fields.source
    })
    |> repo.insert!()
  end

  # 提交之后才重装快照与广播：事务内重装会让一次回滚留下一份"生效了但没落库"的快照。
  # 本节点走**同步**重装，正确性完全不依赖广播送达（广播是 best-effort，见 Store）。
  defp finish_write(subsystem, key, entry, outcome, opts) do
    if outcome.changed? do
      # 整体重装，不是"只装刚写的那个子系统"：只装一个却记下整表指纹，会把别人刚提交、
      # 本节点没读过的行记成"已核对"，从而抹掉丢广播的漂移证据（见 Store 的 moduledoc
      # 「为什么没有只重装一个子系统的装载器」）。表行数上界 = 白名单键数，代价可忽略。
      Store.load_all!(Keyword.take(opts, [:repo]) ++ [reason: {:write, subsystem, key}])
      Notify.broadcast({:config_changed, subsystem, key})

      Log.info("runtime config changed",
        action: "config_#{outcome.operation}",
        config_subsystem: to_string(subsystem),
        config_key: to_string(key),
        config_version: outcome.version,
        config_apply_mode: to_string(entry.apply),
        config_source: Keyword.get(opts, :source),
        principal_arn: Keyword.get(opts, :principal_arn),
        access_key_id: Keyword.get(opts, :access_key_id),
        request_id: Keyword.get(opts, :request_id)
      )
    end

    {:ok, Map.put(outcome, :applied, entry.apply)}
  end

  defp validate_source(opts) do
    case Keyword.get(opts, :source) do
      source when is_binary(source) ->
        if source in RuntimeConfig.sources() do
          {:ok, source}
        else
          {:error, {:invalid_config_source, source}}
        end

      other ->
        {:error, {:invalid_config_source, inspect(other)}}
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

  defp safe_atom(name) do
    String.to_existing_atom(name)
  rescue
    ArgumentError -> :"$unknown"
  end

  defp filter_subsystem(keys, nil), do: keys

  defp filter_subsystem(keys, subsystem) do
    Enum.filter(keys, fn {s, _k} -> to_string(s) == to_string(subsystem) end)
  end

  defp repo(opts), do: Keyword.get(opts, :repo, Maxio.Repo)
end
