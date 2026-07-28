defmodule Maxio.Storage.MutationBackup do
  @moduledoc """
  对象变更备份的纯数据契约（协议 §3.2，实现计划 B1/D3）。

  协议化写入的旧值备份不再放 `.tmp/<uuid>`（进程死后 recovery 无法定位），改落
  `<drive>/.maxio-object-mutations/<mutation_id>/`，并带 durable manifest
  （target/token/previous_token/entries）——recovery 仅凭 journal（mutation_id +
  placement_snapshot）+ 磁盘即可定位并恢复，generic `.tmp` 清理不会误删。
  本模块只做 manifest 编解码与相对路径构造，不读写磁盘。
  """

  alias Maxio.Storage.ObjectEpoch

  @format "maxio/object-mutation-backup/1"
  @root ".maxio-object-mutations"
  @manifest_file "manifest.json"
  @uuid ~r/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i
  @payload_keys ~w(entries format previous_token target token)
  # 备份 entry 是 final 目录内的单层文件名（part.0/meta.json），沿用盘上单段 255 字节硬限。
  @max_entry_bytes 255

  @enforce_keys [:target, :token, :entries]
  defstruct format: @format, target: nil, token: nil, previous_token: nil, entries: []

  @type entry :: %{required(String.t()) => String.t()}
  @type t :: %__MODULE__{}

  @doc "备份根目录名（Paths 保留名 / ShardServer list_dir 跳过名单同源常量）。"
  @spec root() :: String.t()
  def root, do: @root

  @doc "manifest 文件名（备份目录内固定名；entry 名不得与之冲突）。"
  @spec manifest_name() :: String.t()
  def manifest_name, do: @manifest_file

  @doc "校验 mutation_id（UUID，规范为小写）。"
  @spec validate_mutation_id(term()) :: {:ok, String.t()} | {:error, :invalid_mutation_id}
  def validate_mutation_id(id) when is_binary(id) do
    if Regex.match?(@uuid, id),
      do: {:ok, String.downcase(id)},
      else: {:error, :invalid_mutation_id}
  end

  def validate_mutation_id(_id), do: {:error, :invalid_mutation_id}

  @doc """
  备份目录相对路径 `.maxio-object-mutations/<mutation_id>`（Unix 风格，相对 drive 根）。
  非法 mutation_id 立即 ArgumentError——该值会成为盘上路径段，绝不放行穿越形态。
  """
  @spec relative_dir(String.t()) :: String.t()
  def relative_dir(mutation_id) do
    case validate_mutation_id(mutation_id) do
      {:ok, id} -> @root <> "/" <> id
      {:error, _reason} -> raise ArgumentError, "invalid mutation_id: #{inspect(mutation_id)}"
    end
  end

  @doc "manifest 相对路径 `.maxio-object-mutations/<mutation_id>/manifest.json`。"
  @spec manifest_rel(String.t()) :: String.t()
  def manifest_rel(mutation_id), do: relative_dir(mutation_id) <> "/" <> @manifest_file

  @doc """
  构造并校验 manifest。entries 每项 `%{"name" => 备份目录内文件名}`（也接受 `:name`），
  restore 按名单把备份文件 rename 回 final；previous_token 为被覆盖值的 token（fresh put
  为 nil）。
  """
  @spec manifest(ObjectEpoch.target(), ObjectEpoch.token(), map() | nil, [map()]) ::
          {:ok, t()} | {:error, term()}
  def manifest(target, token, previous_token, entries) when is_list(entries) do
    with {:ok, target} <- validate_target(target),
         {:ok, token} <- validate_token(token),
         {:ok, previous_token} <- validate_previous_token(previous_token),
         {:ok, entries} <- validate_entries(entries) do
      {:ok,
       %__MODULE__{
         target: target,
         token: token,
         previous_token: previous_token,
         entries: entries
       }}
    end
  end

  def manifest(_target, _token, _previous_token, _entries), do: {:error, :invalid_entries}

  @doc "编码稳定版本标识的 JSON payload。"
  @spec encode(t()) :: {:ok, binary()} | {:error, term()}
  def encode(%__MODULE__{format: @format} = manifest) do
    with {:ok, manifest} <-
           manifest(manifest.target, manifest.token, manifest.previous_token, manifest.entries) do
      Jason.encode(%{
        "format" => manifest.format,
        "target" => manifest.target,
        "token" => manifest.token,
        "previous_token" => manifest.previous_token,
        "entries" => manifest.entries
      })
    end
  end

  def encode(%__MODULE__{format: format}), do: {:error, {:unsupported_backup_format, format}}

  @doc "解码并完整重验 manifest；未知格式/多余键不被静默接受（同 ObjectEpoch.decode 风格）。"
  @spec decode(binary()) :: {:ok, t()} | {:error, term()}
  def decode(bytes) when is_binary(bytes) do
    with {:ok, payload} when is_map(payload) <- Jason.decode(bytes),
         @format <- Map.get(payload, "format"),
         :ok <- validate_payload_keys(payload),
         {:ok, manifest} <-
           manifest(
             Map.get(payload, "target"),
             Map.get(payload, "token"),
             Map.get(payload, "previous_token"),
             Map.get(payload, "entries")
           ) do
      {:ok, manifest}
    else
      {:ok, _non_map} -> {:error, :invalid_backup_payload}
      nil -> {:error, :invalid_backup_format}
      format when is_binary(format) -> {:error, {:unsupported_backup_format, format}}
      {:error, reason} -> {:error, reason}
      _other -> {:error, :invalid_backup_format}
    end
  end

  @doc "manifest 内 entry 文件名列表（restore 逐个 rename 回 final 的名单）。"
  @spec entry_names(t()) :: [String.t()]
  def entry_names(%__MODULE__{entries: entries}), do: Enum.map(entries, & &1["name"])

  defp validate_target(target) do
    case ObjectEpoch.relative_path(target) do
      {:ok, _rel} -> {:ok, target}
      {:error, reason} -> {:error, {:invalid_target, reason}}
    end
  end

  defp validate_token(token) do
    case ObjectEpoch.compare_tokens(token, token) do
      {:ok, :eq} -> {:ok, token}
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_previous_token(nil), do: {:ok, nil}
  defp validate_previous_token(token), do: validate_token(token)

  # manifest 中 entries 缺失/非列表由 manifest/4 的第二个子句兜底为 :invalid_entries。
  defp validate_entries(entries) do
    entries
    |> Enum.reduce_while({:ok, []}, fn entry, {:ok, acc} ->
      case validate_entry(entry) do
        {:ok, normalized} -> {:cont, {:ok, [normalized | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, normalized} ->
        normalized = Enum.reverse(normalized)
        names = Enum.map(normalized, & &1["name"])

        if length(Enum.uniq(names)) == length(names),
          do: {:ok, normalized},
          else: {:error, :duplicate_entry_name}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # entry 名是盘上直接子文件名：拒绝空名、点段、路径分隔与 manifest 自身（穿越/自噬防线）。
  defp validate_entry(%{} = entry) do
    name = Map.get(entry, "name", Map.get(entry, :name))

    cond do
      map_size(entry) != 1 -> {:error, {:invalid_entry, entry}}
      not is_binary(name) -> {:error, {:invalid_entry, entry}}
      name in ["", ".", "..", @manifest_file] -> {:error, {:invalid_entry_name, name}}
      String.contains?(name, ["/", "\\"]) -> {:error, {:invalid_entry_name, name}}
      byte_size(name) > @max_entry_bytes -> {:error, {:invalid_entry_name, name}}
      true -> {:ok, %{"name" => name}}
    end
  end

  defp validate_entry(entry), do: {:error, {:invalid_entry, entry}}

  defp validate_payload_keys(payload) do
    if Map.keys(payload) |> Enum.sort() == @payload_keys,
      do: :ok,
      else: {:error, :invalid_backup_payload}
  end
end
