defmodule Maxio.Storage.Erasure.Config do
  @moduledoc """
  纠删码参数（单机多盘 = 一个 erasure set）：N 个本地盘目录、K 个数据分片、M 个校验分片、
  block_size 流式块大小，以及由此推出的 read/write quorum。

  load!/1 合并调用方 opts 与 `config :maxio, :erasure`，做启动期校验：
    * length(drives) == K + M
    * M >= 1 且 M <= N/2（parity 至多半数）
  并计算：read_quorum = K；write_quorum = if M == div(N,2)（脑裂边界 K==M）, do: K+1, else: K；
  epoch_quorum = max(write_quorum, div(N,2)+1)——ObjectMutation 协议 D4：write_quorum = K 且
  K <= N/2 时两个 write quorum 可能不相交，epoch 的 claim/publish/restore/finalize/读裁决一律
  按多数派下界钳制，保证任意两个 epoch quorum 必有交集（交集不变量与 EC 参数解耦）。
  非法配置 raise ArgumentError（铁律 3：绝不带病启动）。
  """
  alias __MODULE__

  @type t :: %Config{
          drives: [String.t()],
          data_shards: pos_integer(),
          parity_shards: pos_integer(),
          block_size: pos_integer(),
          read_quorum: pos_integer(),
          write_quorum: pos_integer(),
          epoch_quorum: pos_integer()
        }

  defstruct [
    :drives,
    :data_shards,
    :parity_shards,
    :block_size,
    :read_quorum,
    :write_quorum,
    :epoch_quorum
  ]

  @default_block_size 1_048_576

  @doc "由 opts（覆盖）+ config 加载并校验 EC 参数。"
  @spec load!(keyword()) :: t()
  def load!(opts \\ []) do
    env = Application.get_env(:maxio, :erasure, [])
    drives = Keyword.get(opts, :drives) || Keyword.get(env, :drives) || []
    k = Keyword.get(opts, :data_shards) || Keyword.get(env, :data_shards)
    m = Keyword.get(opts, :parity_shards) || Keyword.get(env, :parity_shards)

    block_size =
      Keyword.get(opts, :block_size) || Keyword.get(env, :block_size) || @default_block_size

    validate!(drives, k, m, block_size)

    n = k + m
    read_quorum = k
    write_quorum = if m == div(n, 2), do: k + 1, else: k

    # ObjectMutation 协议 D4：epoch 破坏性 quorum 的多数派下界钳制（两个 quorum 必有交集）。
    epoch_quorum = max(write_quorum, div(n, 2) + 1)

    %Config{
      drives: drives,
      data_shards: k,
      parity_shards: m,
      block_size: block_size,
      read_quorum: read_quorum,
      write_quorum: write_quorum,
      epoch_quorum: epoch_quorum
    }
  end

  @doc "分片总数 N = K + M = length(drives)。"
  @spec total(t()) :: pos_integer()
  def total(%Config{data_shards: k, parity_shards: m}), do: k + m

  defp validate!(drives, k, m, block_size) do
    cond do
      not (is_list(drives) and length(drives) > 0) ->
        raise ArgumentError, "erasure: drives must be a non-empty list (got #{inspect(drives)})"

      not (is_integer(k) and k > 0) ->
        raise ArgumentError, "erasure: data_shards must be a positive integer (got #{inspect(k)})"

      not (is_integer(m) and m >= 1) ->
        raise ArgumentError, "erasure: parity_shards must be >= 1 (got #{inspect(m)})"

      length(drives) != k + m ->
        raise ArgumentError,
              "erasure: length(drives)=#{length(drives)} must equal data_shards+parity_shards=#{k + m}"

      m > div(k + m, 2) ->
        raise ArgumentError,
              "erasure: parity_shards=#{m} must be <= N/2 (N=#{k + m}); parity cannot exceed half the set"

      not (is_integer(block_size) and block_size > 0) ->
        raise ArgumentError,
              "erasure: block_size must be a positive integer (got #{inspect(block_size)})"

      true ->
        :ok
    end
  end
end
