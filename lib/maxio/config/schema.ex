defmodule Maxio.Config.Schema do
  @moduledoc """
  运行时配置**白名单**：哪些键可以被运行时改、类型是什么、改了什么时候生效（设计 D3 / §4）。

  ## 为什么白名单在代码里而不是 DB 里

  schema 的正确性由代码决定——一个键"真的被读"这件事只有 `lib/` 说了算。把白名单放进 DB
  会立刻产生漂移：DB 说有这个键、代码却不读它，于是 `mix maxio.config.set` 成功、版本递增、
  审计有行，而配置**永远不会生效**。那是教科书级的静默失败（铁律 3）。放在代码里，
  `Maxio.Config.SchemaTest` 就能**静态断言**每个白名单键在 `lib/` 里确有经门面的读取点。

  ## 为什么这里没有 `default`

  设计草案的示例带 `default:`。落地时刻意去掉：编译期默认的**唯一**事实来源是
  `config/*.exs`。在这里再写一份默认值，就有了两个都自称权威的地方，而它们只会在
  某次改 `config.exs` 时悄悄分叉——正是本模块存在的意义所要防的那种漂移。缺省值一律经
  `Maxio.Config.get/3` 的调用方默认或 `fetch!/2` 的硬失败表达。

  ## `apply` 只有三个值，且必须诚实

    * `:hot`        —— 下一次读即生效；
    * `:next_cycle` —— 下一轮 scheduler tick 生效；
    * `:restart`    —— 已持久化，但要重启进程/节点才生效。

  写路径把这个值原样回传给运维（`{:ok, %{applied: ...}}`）。**写成功 ≠ 生效**，两者绝不能
  混为一谈——这是铁律 3 在配置面的具体形态。

  ## 禁止清单（§4）

  禁止清单的判据是五条硬规则，任一命中即**不得**运行时可写：

    1. 是密钥 / 根信任材料；
    2. 是模块名（behaviour 绑定）——写它等价于把配置写权限升级成代码执行权限；
    3. 改它会让**既有已落盘数据**的解释方式改变；
    4. 它是 config store 自身的自举依赖；
    5. 它是 `Application.compile_env`（编译期语义）。

  禁止判定**先于**未知判定：密钥类键必须得到 403 `forbidden`，而不是 400 `unknown`——
  后者会让运维以为"换个键名就能写"。
  """

  @type subsystem :: atom()
  @type key :: atom()
  @type apply_mode :: :hot | :next_cycle | :restart
  @type type :: :boolean | :string | {:integer, integer(), integer()}
  @type entry :: %{
          type: type(),
          apply: apply_mode(),
          env_var: String.t() | nil,
          doc: String.t()
        }

  # ── 白名单（第一批只放低风险键；其余键仍走 Application env，门面 fallback 行为零变化）──
  @entries %{
    {:cluster, :deployment_id} => %{
      type: :string,
      apply: :hot,
      env_var: "MAXIO_DEPLOYMENT_ID",
      doc:
        "本部署的稳定标识（madmin ServerInfo 的 deploymentID）。首次被读取时自动生成 UUIDv4 " <>
          "并持久化；运维可用 MAXIO_DEPLOYMENT_ID 在部署期钉住，或用 config store 在运行期覆盖。" <>
          "apply 是 hot 而非 restart：ServerInfo 每次经门面重读，改完下一次 mc admin info 就是新值。"
    },
    {:prometheus_metrics, :public} => %{
      type: :boolean,
      apply: :hot,
      env_var: nil,
      doc:
        "Prometheus 抓取端点是否免鉴权公开。读点在 plug 内，下一个请求即生效。" <>
          "只在可信网络/代理后面开启。"
    },
    {:listing, :sql_hard_limit} => %{
      type: {:integer, 1, 10_000_000},
      apply: :hot,
      env_var: nil,
      doc: "LIST 类操作单次 SQL 取数行数的硬上限（DoS 闸门）。下一次 LIST 即生效。"
    },
    {:s3, :clock_skew_ms} => %{
      type: {:integer, 0, 3_600_000},
      apply: :hot,
      env_var: nil,
      doc: "SigV4 header 形态签名允许的最大时钟偏移（毫秒）。下一次验签即生效。"
    }
  }

  # ── 禁止清单：整个子系统都不得运行时可写 ──
  # storage_backend / credential_store / policy_store / mfa_delete_verifier / shard_transport
  # 都是 behaviour 绑定（判据 2），且切后端会让既有对象的物理布局解释权瞬间改变（判据 3）。
  # authoritative_source / topology_source 是分阶段 cutover 开关（判据 3）。
  # Maxio.Repo 是 config store 自身的自举依赖（判据 4）——改错就再也读不到配置来改回去。
  # dev_routes 是 compile_env（判据 5）。
  @forbidden_subsystems [
    :storage_backend,
    :credential_store,
    :policy_store,
    :mfa_delete_verifier,
    :shard_transport,
    :authoritative_source,
    :topology_source,
    :read_prefer_index,
    :dev_routes,
    Maxio.Repo
  ]

  # ── 禁止清单：子系统内的单键（该子系统还有别的键是允许的，故必须逐键列举）──
  @forbidden_keys [
    # 判据 1：密钥 / 根信任材料。
    {:sse, :master_key},
    {:kms, :master_key},
    {:kms, :provider},
    {:access_key_secret, :secret_key},
    {:access_key_secret, :keyring},
    {:access_key_secret, :keyring_file},
    {:mfa, :secret_key},
    # 判据 1：root 凭据可运行时改 = 提权路径。
    {:s3, :root_user},
    {:s3, :root_password},
    # 判据 3：改这三项会让既有对象的 shard 布局解释错误。
    {:erasure, :drives},
    {:erasure, :data_shards},
    {:erasure, :parity_shards}
  ]

  @doc "白名单全表。"
  @spec entries() :: %{{subsystem(), key()} => entry()}
  def entries, do: @entries

  @doc "白名单键，按字典序（CLI 输出稳定）。"
  @spec keys() :: [{subsystem(), key()}]
  def keys do
    @entries |> Map.keys() |> Enum.sort_by(fn {s, k} -> {to_string(s), to_string(k)} end)
  end

  @doc "§4 禁止清单里逐键列举的键。"
  @spec forbidden_keys() :: [{subsystem(), key()}]
  def forbidden_keys, do: @forbidden_keys

  @doc "§4 禁止清单里整体禁止的子系统。"
  @spec forbidden_subsystems() :: [subsystem()]
  def forbidden_subsystems, do: @forbidden_subsystems

  @doc "该键是否落在 §4 禁止清单上。"
  @spec forbidden?(subsystem(), key()) :: boolean()
  def forbidden?(subsystem, key) do
    subsystem in @forbidden_subsystems or {subsystem, key} in @forbidden_keys
  end

  @doc """
  查白名单。禁止判定先于未知判定（密钥类键要 403 而不是 400）。
  """
  @spec fetch(subsystem(), key()) ::
          {:ok, entry()}
          | {:error, {:forbidden_config_key, subsystem(), key()}}
          | {:error, {:unknown_config_key, subsystem(), key()}}
  def fetch(subsystem, key) do
    cond do
      forbidden?(subsystem, key) -> {:error, {:forbidden_config_key, subsystem, key}}
      entry = Map.get(@entries, {subsystem, key}) -> {:ok, entry}
      true -> {:error, {:unknown_config_key, subsystem, key}}
    end
  end

  @doc "查白名单，未知/禁止即 raise（内部调用点用；对外一律用 `fetch/2` 拿结构化错误）。"
  @spec fetch!(subsystem(), key()) :: entry()
  def fetch!(subsystem, key) do
    case fetch(subsystem, key) do
      {:ok, entry} -> entry
      {:error, reason} -> raise ArgumentError, "config schema lookup failed: #{inspect(reason)}"
    end
  end

  @doc "该键声明的 apply 模式。"
  @spec apply_mode(subsystem(), key()) :: apply_mode()
  def apply_mode(subsystem, key), do: fetch!(subsystem, key).apply

  @doc "该键声明的环境变量名（nil 表示 runtime.exs 未为它接线 env 覆盖）。"
  @spec env_var(subsystem(), key()) :: String.t() | nil
  def env_var(subsystem, key) do
    case fetch(subsystem, key) do
      {:ok, entry} -> entry.env_var
      {:error, _reason} -> nil
    end
  end

  @doc """
  校验一个**已经是 Elixir 项**的配置值。类型不符或范围越界一律结构化报错，
  绝不悄悄裁剪或回落默认值。
  """
  @spec cast(subsystem(), key(), term()) ::
          {:ok, term()} | {:error, {:invalid_config_value, subsystem(), key(), String.t()}}
  def cast(subsystem, key, value) do
    with {:ok, entry} <- fetch(subsystem, key) do
      case cast_type(entry.type, value) do
        {:ok, casted} -> {:ok, casted}
        {:error, reason} -> {:error, {:invalid_config_value, subsystem, key, reason}}
      end
    end
  end

  @doc """
  把 CLI 传进来的字符串按声明类型解析。CLI 是**字符串**通道，与 `cast/3` 的
  "已是 Elixir 项"通道刻意分开——混在一起就会出现 `"false"` 被当成真值这类经典陷阱。
  """
  @spec parse(subsystem(), key(), String.t()) ::
          {:ok, term()} | {:error, {:invalid_config_value, subsystem(), key(), String.t()}}
  def parse(subsystem, key, raw) when is_binary(raw) do
    with {:ok, entry} <- fetch(subsystem, key) do
      case parse_type(entry.type, raw) do
        {:ok, value} -> cast(subsystem, key, value)
        {:error, reason} -> {:error, {:invalid_config_value, subsystem, key, reason}}
      end
    end
  end

  @doc """
  把 jsonb 里存的 `%{"v" => ...}` 解回 Elixir 项并按类型校验。

  失败**不是**"用默认值继续跑"的场景：它说明写路径的校验被绕过了（有人直接改了 DB），
  是完整性问题，由调用方 fail-fast（见 `Maxio.Config.Store`）。
  """
  @spec decode_stored(subsystem(), key(), map()) :: {:ok, term()} | {:error, String.t()}
  def decode_stored(subsystem, key, %{"v" => raw}) do
    case cast(subsystem, key, decode_json_term(raw)) do
      {:ok, value} -> {:ok, value}
      {:error, {:invalid_config_value, _s, _k, reason}} -> {:error, reason}
      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  def decode_stored(_subsystem, _key, other) do
    {:error, "stored value is not wrapped as %{\"v\" => value}, got: #{inspect(other)}"}
  end

  @doc "把 Elixir 项包成 jsonb 存储形态。"
  @spec encode_stored(term()) :: map()
  def encode_stored(value), do: %{"v" => value}

  @doc "类型的人类可读描述（CLI / 错误信息用）。"
  @spec describe_type(type()) :: String.t()
  def describe_type(:boolean), do: "boolean"
  def describe_type(:string), do: "string"
  def describe_type({:integer, min, max}), do: "integer in #{min}..#{max}"

  # 目前白名单只需要三种标量类型。刻意不预置列表/map 类型：没有键在用的分支既无法
  # 活体验证，也会给"任意结构都能塞进配置"开口子（铁律 5：不实现无法取证的分支）。
  defp cast_type(:boolean, value) when is_boolean(value), do: {:ok, value}
  defp cast_type(:boolean, value), do: {:error, "expected boolean, got: #{inspect(value)}"}

  defp cast_type(:string, value) when is_binary(value) do
    if String.valid?(value) do
      {:ok, value}
    else
      {:error, "expected a valid UTF-8 string"}
    end
  end

  defp cast_type(:string, value), do: {:error, "expected string, got: #{inspect(value)}"}

  defp cast_type({:integer, min, max}, value) when is_integer(value) do
    if value >= min and value <= max do
      {:ok, value}
    else
      {:error, "expected integer in #{min}..#{max}, got: #{value}"}
    end
  end

  defp cast_type({:integer, min, max}, value) do
    {:error, "expected integer in #{min}..#{max}, got: #{inspect(value)}"}
  end

  defp parse_type(:boolean, "true"), do: {:ok, true}
  defp parse_type(:boolean, "false"), do: {:ok, false}

  defp parse_type(:boolean, raw),
    do: {:error, "expected boolean literal \"true\" or \"false\", got: #{inspect(raw)}"}

  defp parse_type(:string, raw), do: {:ok, raw}

  defp parse_type({:integer, min, max}, raw) do
    case Integer.parse(raw) do
      {value, ""} -> {:ok, value}
      _other -> {:error, "expected integer in #{min}..#{max}, got: #{inspect(raw)}"}
    end
  end

  # jsonb 只认 JSON 标量；本白名单的三种类型与 JSON 标量一一对应，无需二次转换。
  defp decode_json_term(raw), do: raw
end
