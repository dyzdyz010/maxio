defmodule Maxio.Config.CLI do
  @moduledoc """
  `mix maxio.config.*` 六个任务共用的取证渲染与启动辅助。

  抽出来不是为了少写几行：六个任务如果各自渲染，`source` / `apply` / `version` 三列迟早
  会在其中一个任务里漏掉或改名，而运维恰恰是靠这三列判断"改了到底生不生效"。渲染只有
  一处，才能保证六个入口说的是同一件事（铁律 1）。

  本模块**不依赖 Mix**：启动失败以 `{:error, reason}` 返回，由调用它的 Mix 任务去
  `Mix.raise`。这样同一套渲染也能被 Console / 测试直接复用。
  """

  alias Maxio.Config
  alias Maxio.Config.Schema

  @doc "启动 Repo（Mix 任务里没有 application 树）。"
  @spec start_repo() :: :ok | {:error, term()}
  def start_repo do
    with :ok <- ensure_started(:ecto_sql),
         :ok <- ensure_started(:postgrex) do
      case Process.whereis(Maxio.Repo) do
        nil -> start_repo_process()
        _pid -> :ok
      end
    end
  end

  defp start_repo_process do
    case Maxio.Repo.start_link() do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
      {:error, reason} -> {:error, {:repo_start_failed, reason}}
    end
  end

  defp ensure_started(application) do
    case Application.ensure_all_started(application) do
      {:ok, _apps} -> :ok
      {:error, reason} -> {:error, {:application_start_failed, application, reason}}
    end
  end

  @doc """
  把 CLI 启动流程里"装载本节点快照"这一步做掉。

  没有它，`mix maxio.config.get` 会永远显示 `source=compile`——Mix 任务里没有
  `Maxio.Config.Store` 进程，快照是空的。一个**结构上**读不到运行时覆盖的取证工具，
  比没有工具更危险：它会让运维确信"我的 set 没生效"，然后去改错的东西。
  """
  @spec load_snapshot() :: :ok | {:error, term()}
  def load_snapshot do
    _ = Maxio.Config.Store.load_all!(reason: :cli)
    :ok
  rescue
    e -> {:error, Exception.message(e)}
  catch
    kind, reason -> {:error, Exception.format(kind, reason, [])}
  end

  @doc """
  CLI 统一启动序列：起 Repo + 装载本节点快照。失败返回可直接打给运维的一行原因。
  """
  @spec boot() :: :ok | {:error, String.t()}
  def boot do
    with :ok <- wrap(start_repo(), "failed to start Maxio.Repo"),
         :ok <- wrap(load_snapshot(), "failed to load runtime config snapshot") do
      :ok
    end
  end

  defp wrap(:ok, _prefix), do: :ok
  defp wrap({:error, reason}, prefix), do: {:error, "#{prefix}: #{inspect(reason)}"}

  @doc "单键取证的一行文本（三层值 + 生效来源 + apply 模式 + 版本）。"
  @spec line(map()) :: String.t()
  def line(effective) do
    "[maxio config] subsystem=#{effective.subsystem} key=#{effective.key} " <>
      "value=#{format(effective.value)} source=#{effective.source} " <>
      "apply=#{format(effective.apply)} version=#{format(effective.version)} " <>
      "runtime=#{format(effective.runtime_value)} env=#{format(effective.env_value)} " <>
      "app_env=#{format(effective.app_env_value)}"
  end

  @doc "单键取证的 JSON 形态（键名与文本列一一对应，两个通道绝不分叉）。"
  @spec json_entry(map()) :: map()
  def json_entry(effective) do
    %{
      "subsystem" => to_string(effective.subsystem),
      "key" => to_string(effective.key),
      "value" => jsonable(effective.value),
      "source" => to_string(effective.source),
      "apply" => effective.apply && to_string(effective.apply),
      "version" => effective.version,
      "runtime_value" => jsonable(effective.runtime_value),
      "env_value" => jsonable(effective.env_value),
      "app_env_value" => jsonable(effective.app_env_value),
      "type" => effective.subsystem |> type_of(effective.key) |> jsonable(),
      "doc" => effective.doc
    }
  end

  @doc "审计行的一行文本。"
  @spec audit_line(map() | struct()) :: String.t()
  def audit_line(audit) do
    "[maxio config.history] at=#{format(audit.inserted_at)} operation=#{audit.operation} " <>
      "subsystem=#{audit.subsystem} key=#{audit.key} " <>
      "from_version=#{format(audit.from_version)} to_version=#{audit.to_version} " <>
      "apply=#{audit.apply_mode} source=#{audit.source} " <>
      "old=#{format(unwrap(audit.old_value))} new=#{format(unwrap(audit.new_value))} " <>
      "principal_arn=#{format(audit.principal_arn)} request_id=#{format(audit.request_id)}"
  end

  @doc "审计行的 JSON 形态。"
  @spec audit_json(map() | struct()) :: map()
  def audit_json(audit) do
    %{
      "inserted_at" => audit.inserted_at && DateTime.to_iso8601(audit.inserted_at),
      "operation" => audit.operation,
      "subsystem" => audit.subsystem,
      "key" => audit.key,
      "from_version" => audit.from_version,
      "to_version" => audit.to_version,
      "apply_mode" => audit.apply_mode,
      "source" => audit.source,
      "old_value" => jsonable(unwrap(audit.old_value)),
      "new_value" => jsonable(unwrap(audit.new_value)),
      "principal_arn" => audit.principal_arn,
      "access_key_id" => audit.access_key_id,
      "request_id" => audit.request_id
    }
  end

  @doc """
  把 `{subsystem, key}` 字符串对解析成 atom 对。

  用 `to_existing_atom` 并把失败**归一成 `{:unknown_config_key, ...}`**：CLI 是外部输入面，
  `to_atom` 会让打错的键名无界地泄漏 atom；而单独造一种"这个名字压根不存在"的错误，
  只会让运维看到两种措辞不同、含义相同的失败。
  """
  @spec parse_key(String.t(), String.t()) ::
          {:ok, atom(), atom()} | {:error, {:unknown_config_key, String.t(), String.t()}}
  def parse_key(subsystem, key) when is_binary(subsystem) and is_binary(key) do
    {:ok, String.to_existing_atom(subsystem), String.to_existing_atom(key)}
  rescue
    ArgumentError -> {:error, {:unknown_config_key, subsystem, key}}
  end

  @doc "结构化写错误 → 人类可读的一行（CLI 硬失败文案）。"
  @spec describe_error(term()) :: String.t()
  def describe_error({:unknown_config_key, subsystem, key}) do
    "unknown_config_key: #{subsystem}.#{key} is not in Maxio.Config.Schema. " <>
      "Run `mix maxio.config.list` to see every runtime-settable key."
  end

  def describe_error({:forbidden_config_key, subsystem, key}) do
    "forbidden_config_key: #{subsystem}.#{key} must never be runtime-settable " <>
      "(secret / behaviour binding / on-disk data interpretation / config-store bootstrap / " <>
      "compile-time). See Maxio.Config.Schema for the five rules."
  end

  def describe_error({:invalid_config_value, subsystem, key, reason}) do
    "invalid_config_value: #{subsystem}.#{key}: #{reason}"
  end

  def describe_error({:invalid_config_source, source}) do
    "invalid_config_source: #{source} (expected one of admin_api / cli / console / system)"
  end

  def describe_error(:config_version_conflict) do
    "config_version_conflict: the key changed since you read it. Re-read with " <>
      "`mix maxio.config.get` and retry with the current --expected-version."
  end

  def describe_error(other), do: "config write failed: #{inspect(other)}"

  defp type_of(subsystem, key) do
    case Schema.fetch(subsystem, key) do
      {:ok, entry} -> Schema.describe_type(entry.type)
      {:error, _reason} -> nil
    end
  end

  defp unwrap(%{"v" => value}), do: value
  defp unwrap(other), do: other

  # nil 在文本通道里必须是显式的 "nil" 而不是空字符串：一个 `runtime=` 后面什么都没有
  # 的输出，无法区分"这层没有值"和"这层的值是空串"。
  defp format(nil), do: "nil"
  defp format(value) when is_binary(value), do: value

  # apply / source 这类枚举值渲染成裸串（hot、cli），不是 inspect 的 :hot——CLI 输出会被
  # 运维和脚本一起读，多一个冒号就多一层无谓的解析差异。
  defp format(value) when is_atom(value), do: Atom.to_string(value)
  defp format(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp format(value), do: inspect(value)

  defp jsonable(nil), do: nil
  defp jsonable(value) when is_binary(value) or is_number(value) or is_boolean(value), do: value
  defp jsonable(value) when is_list(value), do: Enum.map(value, &jsonable/1)
  defp jsonable(value), do: inspect(value)

  @doc "供任务共享的默认列表：白名单全量取证视图。"
  @spec list(keyword()) :: [map()]
  def list(opts \\ []), do: Config.list(opts)
end
