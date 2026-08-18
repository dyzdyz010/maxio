defmodule Maxio.DurableJSON do
  @moduledoc """
  journal JSONB 值的**唯一**中立纯函数 durable 边界（design D6「Durable JSON 是 JSONB
  严格回读契约」）。

  「Jason 可编码」不足以证明数据可持久化：Jason 默认只解码至多 1,024 个十进制 token bytes
  的整数，PostgreSQL JSONB 会归一化某些 float，并以 SQLSTATE `22P05` 拒绝 U+0000。本模块
  因此只证明一件事——**给定 term 在冻结的 JSONB-safe domain 内稳定**：

      Maxio.DurableJSON.validate(value,
        max_depth: non_neg_integer(),
        max_encoded_bytes: pos_integer()
      )
      # => {:ok, encoded_binary} | {:error, :invalid_durable_json}

  它既不是 PublishedProof 也不是 Journal 的 schema：list/map/key/string 长度、phase、detail、
  witness 等语义规则仍属各自 semantic layer，不下沉成本模块的可配置选项。调用方保留既有
  public error taxonomy，本模块只返回单一结构化错误，绝不 raise，也绝不泄漏 Jason reason。

  冻结的调用 profile：

  - `Maxio.Storage.PublishedProof`：`max_depth: 6, max_encoded_bytes: 61_440`
  - `Maxio.ObjectMutation.Journal`：`max_depth: 15, max_encoded_bytes: 65_536`
  """

  # Jason 的全局 integer 解码上限；本模块只做本地判定，绝不提高该全局解析器安全阈值。
  @max_integer_token_bytes 1_024
  @error {:error, :invalid_durable_json}

  @doc """
  证明 `value` 在 caller profile 下可严格回读，成功时返回**编码字节本身**。

  依次判定：options 契约 → term domain 与 root-zero 深度 → `Jason.encode/1` →
  exact encoded bytes ≤ 上限 → 对**同一批字节**的 `Jason.decode/1` → decoded 与输入严格
  `===`。任何一步失败、任何异常/throw/exit 都收敛为 `{:error, :invalid_durable_json}`。

  返回的永远是原始编码字节，绝不是 decode 后的替代 term。
  """
  @spec validate(term(), keyword()) :: {:ok, binary()} | {:error, :invalid_durable_json}
  def validate(value, opts) do
    with {:ok, max_depth, max_encoded_bytes} <- profile(opts),
         true <- durable?(value, 0, max_depth),
         {:ok, encoded} <- Jason.encode(value),
         true <- byte_size(encoded) <= max_encoded_bytes,
         {:ok, decoded} <- Jason.decode(encoded),
         true <- decoded === value do
      {:ok, encoded}
    else
      _invalid -> @error
    end
  rescue
    _error -> @error
  catch
    _kind, _reason -> @error
  end

  # --- options 契约：恰好一个 :max_depth 与一个 :max_encoded_bytes，顺序不限 ---

  defp profile(opts) when is_list(opts) do
    with true <- Keyword.keyword?(opts),
         [max_depth] <- Keyword.get_values(opts, :max_depth),
         [max_encoded_bytes] <- Keyword.get_values(opts, :max_encoded_bytes),
         # 恰好两项：缺失、额外与重复 key 一律在此被拒。
         2 <- length(opts),
         true <- is_integer(max_depth) and max_depth >= 0,
         true <- is_integer(max_encoded_bytes) and max_encoded_bytes > 0 do
      {:ok, max_depth, max_encoded_bytes}
    else
      _invalid -> :error
    end
  end

  defp profile(_opts), do: :error

  # --- term domain 与 root-zero 深度 ---
  #
  # root term 位于 depth 0；`depth > max_depth` 时拒绝**当前节点**。map value 与 list
  # element 以 `depth + 1` 递归；map key 不单独占用一层。

  defp durable?(_value, depth, max_depth) when depth > max_depth, do: false

  defp durable?(value, _depth, _max_depth) when is_boolean(value) or is_nil(value), do: true

  defp durable?(value, _depth, _max_depth) when is_integer(value),
    do: byte_size(Integer.to_string(value)) <= @max_integer_token_bytes

  defp durable?(value, _depth, _max_depth) when is_binary(value), do: durable_binary?(value)

  defp durable?(value, depth, max_depth) when is_map(value) do
    not is_struct(value) and durable_pairs?(Map.to_list(value), depth + 1, max_depth)
  end

  defp durable?(value, depth, max_depth) when is_list(value),
    do: durable_elements?(value, depth + 1, max_depth)

  # float、struct、非 boolean/nil 的 atom、tuple、pid、reference、function 与非字节
  # bitstring 全部落到这里。
  defp durable?(_value, _depth, _max_depth), do: false

  defp durable_pairs?([], _depth, _max_depth), do: true

  defp durable_pairs?([{key, value} | rest], depth, max_depth) do
    is_binary(key) and durable_binary?(key) and durable?(value, depth, max_depth) and
      durable_pairs?(rest, depth, max_depth)
  end

  defp durable_elements?([], _depth, _max_depth), do: true

  defp durable_elements?([head | tail], depth, max_depth) do
    durable?(head, depth, max_depth) and durable_elements?(tail, depth, max_depth)
  end

  # improper list 的尾部不是 list：显式拒绝，绝不让 Jason 抛异常来表达它。
  defp durable_elements?(_improper, _depth, _max_depth), do: false

  # valid UTF-8 且不含 U+0000。Jason 能编解码 U+0000，PostgreSQL JSONB 不能，因此
  # codec 往返不足以定义 JSONB-safe domain。
  defp durable_binary?(value),
    do: String.valid?(value) and :binary.match(value, <<0>>) == :nomatch
end
