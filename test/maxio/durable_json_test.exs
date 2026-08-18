defmodule Maxio.DurableJSONTest do
  use ExUnit.Case, async: true

  # --- Task 3 / G1-FIX-R2：共享 durable JSON 契约的独立能力 RED ---
  #
  # 正式 design D6「Durable JSON 是 JSONB 严格回读契约」与 adjudication §2/§3 冻结了唯一
  # 中立纯函数边界：
  #
  #   Maxio.DurableJSON.validate(value,
  #     max_depth: non_neg_integer(),
  #     max_encoded_bytes: pos_integer()
  #   )
  #   # => {:ok, encoded_binary} | {:error, :invalid_durable_json}
  #
  # root term 深度从 0 开始；只接受 string-key map、list、binary、boolean、nil 与 integer；
  # 所有 key/value binary 必须是 valid UTF-8 且不含 U+0000；struct 与所有 float 一律拒绝；
  # 每个 integer 的 `byte_size(Integer.to_string/1) <= 1_024`（负号计入 token bytes）。
  # 随后依次证明 caller depth、`Jason.encode/1`、exact encoded bytes ≤ caller 上限、对这些
  # exact bytes 的 `Jason.decode/1`，以及 decoded term 与输入严格 `===`。
  # 缺失/额外/类型错误的 options 与任何异常统一返回 `{:error, :invalid_durable_json}`，
  # helper 绝不 raise。
  #
  # 本文件只经 `apply/3` capability seam 调用尚未存在的 helper，绝不做 source-regex 断言，
  # 也绝不与 PublishedProof / Journal / ObjectMutation 的公共边界共用失败签名：
  # 缺失 `Maxio.DurableJSON` 只会让本文件失败，不会掩盖那三个公共边界是否真的被行使。

  @published_proof_profile [max_depth: 6, max_encoded_bytes: 61_440]
  @journal_profile [max_depth: 15, max_encoded_bytes: 65_536]
  @error {:error, :invalid_durable_json}

  defp durable_json!() do
    assert Code.ensure_loaded?(Maxio.DurableJSON),
           "T3-G1-FIX-R2: Maxio.DurableJSON 尚未实现（正式 design D6 / plan Task 3 Step 2）"

    assert function_exported?(Maxio.DurableJSON, :validate, 2),
           "T3-G1-FIX-R2: Maxio.DurableJSON.validate/2 尚未实现" <>
             "（正式 design D6 / plan Task 3 Step 2）"
  end

  # 冻结的公共内部 API 只经 apply/3 调用：既避免 undefined-function 编译警告，也避免
  # 故意错误类型的调用触发 incompatible-types 诊断。
  defp validate(value, opts) do
    durable_json!()
    apply(Maxio.DurableJSON, :validate, [value, opts])
  end

  # 「非法 options 必须返回结构化错误而不是 raise」：能力断言留在 try 之外，
  # 否则 capability RED 自身会被 rescue 吞掉。
  defp validate_without_raising(value, opts) do
    durable_json!()

    try do
      apply(Maxio.DurableJSON, :validate, [value, opts])
    rescue
      error -> {:raised, error}
    catch
      kind, reason -> {:caught, kind, reason}
    end
  end

  # m 层嵌套 map，leaf 字符串恰好落在 depth m（root map 在 depth 0）。
  defp nested_maps(0), do: "leaf"
  defp nested_maps(depth) when depth > 0, do: %{"level" => nested_maps(depth - 1)}

  # 按 `byte_size(Jason.encode!/1)` 精确校准的 codec-roundtrippable 纯字符串 payload。
  defp string_payload_of_bytes!(total) do
    value = %{"pad" => String.duplicate("x", total - 10)}
    assert byte_size(Jason.encode!(value)) == total
    value
  end

  defp assert_accepted!(value, opts) do
    assert {:ok, encoded} = validate(value, opts)
    assert is_binary(encoded)
    assert encoded == Jason.encode!(value)
    assert Jason.decode!(encoded) === value
    encoded
  end

  # --- A1 普通接受形态 ---

  @tag :task3_g1_review_red
  test "durable json accepts ordinary nested string-key JSON and returns its exact bytes" do
    value = %{
      "authority_mode" => "pg",
      "stage" => "verify_published",
      "counts" => %{"required" => 3, "verified" => 3, "debt" => 0},
      "flags" => [true, false, nil],
      "details" => [%{"endpoint" => "ordinal:0", "owned" => true}]
    }

    for profile <- [@published_proof_profile, @journal_profile] do
      assert_accepted!(value, profile)
    end
  end

  # --- A2 四个整数 token 边缘（负号精确计入 token bytes）---

  @tag :task3_g1_review_red
  test "durable json accepts a positive 1,024-digit integer" do
    value = Integer.pow(10, 1_023)
    assert byte_size(Integer.to_string(value)) == 1_024

    assert_accepted!(%{"counter" => value}, @published_proof_profile)
    assert_accepted!(%{"counter" => value}, @journal_profile)
  end

  @tag :task3_g1_review_red
  test "durable json rejects a positive 1,025-digit integer" do
    value = Integer.pow(10, 1_024)
    assert byte_size(Integer.to_string(value)) == 1_025

    # 该 term 仍可被 Jason 编码：拒绝只能来自 durable integer-token 门。
    assert match?({:ok, _bytes}, Jason.encode(%{"counter" => value}))

    assert validate(%{"counter" => value}, @published_proof_profile) == @error
    assert validate(%{"counter" => value}, @journal_profile) == @error
  end

  @tag :task3_g1_review_red
  test "durable json accepts a negative sign plus 1,023 digits" do
    value = -Integer.pow(10, 1_022)
    assert byte_size(Integer.to_string(value)) == 1_024

    assert_accepted!(%{"counter" => value}, @published_proof_profile)
    assert_accepted!(%{"counter" => value}, @journal_profile)
  end

  @tag :task3_g1_review_red
  test "durable json rejects a negative sign plus 1,024 digits" do
    value = -Integer.pow(10, 1_023)
    assert byte_size(Integer.to_string(value)) == 1_025

    assert match?({:ok, _bytes}, Jason.encode(%{"counter" => value}))

    assert validate(%{"counter" => value}, @published_proof_profile) == @error
    assert validate(%{"counter" => value}, @journal_profile) == @error
  end

  # --- A3 所有 float 一律拒绝（含 PostgreSQL 归一化 witness 1.0e20）---

  @tag :task3_g1_review_red
  test "durable json rejects every float including the PostgreSQL-normalizing 1.0e20" do
    for float <- [0.0, 1.0, -0.5, 3.0, 1.0e20] do
      assert is_float(float)
      assert match?({:ok, _bytes}, Jason.encode(%{"value" => float}))

      assert validate(%{"value" => float}, @journal_profile) == @error,
             "float 必须被拒绝：#{inspect(float)}"

      assert validate([float], @journal_profile) == @error
      assert validate(float, @journal_profile) == @error
    end
  end

  # --- A4 struct 拒绝 ---

  @tag :task3_g1_review_red
  test "durable json rejects structs at the root and nested" do
    for struct <- [~D[2026-07-29], ~U[2026-07-29 06:00:00.000000Z], 1..2] do
      assert is_struct(struct)
      assert validate(struct, @journal_profile) == @error
      assert validate(%{"value" => struct}, @journal_profile) == @error
      assert validate([struct], @journal_profile) == @error
    end
  end

  # --- A5 invalid UTF-8 key/value 拒绝 ---

  @tag :task3_g1_review_red
  test "durable json rejects invalid UTF-8 in a map key and in a binary value" do
    invalid = <<0xFF, 0xFE>>
    refute String.valid?(invalid)

    assert validate(%{invalid => "v"}, @journal_profile) == @error
    assert validate(%{"k" => invalid}, @journal_profile) == @error
    assert validate([invalid], @journal_profile) == @error
    assert validate(invalid, @journal_profile) == @error
  end

  # --- A6 U+0000 key 与 value 分别拒绝 ---

  @tag :task3_g1_review_red
  test "durable json rejects a U+0000 map key" do
    key = "nul" <> <<0>> <> "key"
    assert String.valid?(key)
    # Jason 可以编码/解码它：拒绝只能来自 durable NUL 门，而不是 codec。
    assert match?({:ok, _bytes}, Jason.encode(%{key => "v"}))

    assert validate(%{key => "v"}, @journal_profile) == @error
    assert validate(%{key => "v"}, @published_proof_profile) == @error
  end

  @tag :task3_g1_review_red
  test "durable json rejects a U+0000 binary value" do
    value = "nul" <> <<0>> <> "value"
    assert String.valid?(value)
    assert match?({:ok, _bytes}, Jason.encode(%{"k" => value}))

    assert validate(%{"k" => value}, @journal_profile) == @error
    assert validate([value], @journal_profile) == @error
    assert validate(value, @journal_profile) == @error
  end

  # --- A7 缺失/额外/类型错误的 options 一律结构化拒绝且不 raise ---

  @tag :task3_g1_review_red
  test "durable json rejects missing, extra and wrongly typed options without raising" do
    value = %{"k" => "v"}

    invalid_options = [
      # 缺失
      [],
      [max_depth: 6],
      [max_encoded_bytes: 61_440],
      # 额外
      [max_depth: 6, max_encoded_bytes: 61_440, extra: true],
      # 类型错误
      [max_depth: -1, max_encoded_bytes: 61_440],
      [max_depth: "6", max_encoded_bytes: 61_440],
      [max_depth: 6.0, max_encoded_bytes: 61_440],
      [max_depth: nil, max_encoded_bytes: 61_440],
      [max_depth: 6, max_encoded_bytes: 0],
      [max_depth: 6, max_encoded_bytes: -1],
      [max_depth: 6, max_encoded_bytes: 61_440.0],
      [max_depth: 6, max_encoded_bytes: "61440"],
      # 重复 key 与非 keyword 形态
      [max_depth: 6, max_depth: 7, max_encoded_bytes: 61_440],
      %{max_depth: 6, max_encoded_bytes: 61_440},
      nil,
      :proof
    ]

    for opts <- invalid_options do
      assert validate_without_raising(value, opts) == @error,
             "非法 options 必须返回结构化错误且不 raise：#{inspect(opts)}"
    end
  end

  # --- A8 root-zero 深度语义（两个冻结 profile 的精确边界）---

  @tag :task3_g1_review_red
  test "durable json counts depth from zero at the root for both frozen profiles" do
    # root 标量本身位于 depth 0：max_depth: 0 也必须接受。
    assert_accepted!("leaf", max_depth: 0, max_encoded_bytes: 61_440)
    assert validate(%{"k" => "v"}, max_depth: 0, max_encoded_bytes: 61_440) == @error

    # PublishedProof profile：depth 6 接受，depth 7 拒绝。
    assert_accepted!(nested_maps(6), @published_proof_profile)
    assert validate(nested_maps(7), @published_proof_profile) == @error

    # Journal profile：depth 15 接受，depth 16 拒绝——与既有 root-one、
    # reject-when-greater-than-16 的遍历完全等价，不得暗中扩缩。
    assert_accepted!(nested_maps(15), @journal_profile)
    assert validate(nested_maps(16), @journal_profile) == @error

    # 同一个 depth-15 term 在 PublishedProof profile 上必须被 depth 门拒绝。
    assert validate(nested_maps(15), @published_proof_profile) == @error
  end

  # --- A9 PublishedProof profile 的 exact 61,440 / 61,441 编码尺寸门 ---

  @tag :task3_g1_review_red
  test "durable json isolates the exact 61,440-byte published-proof encoded-size boundary" do
    at_limit = string_payload_of_bytes!(61_440)
    over_limit = string_payload_of_bytes!(61_441)

    assert byte_size(Jason.encode!(at_limit)) == 61_440
    assert byte_size(Jason.encode!(over_limit)) == 61_441

    # 两个 fixture 都是 codec-roundtrippable 的纯字符串 payload：语义完全同构，
    # 唯一能区分它们的谓词就是编码尺寸门。
    assert Jason.decode!(Jason.encode!(at_limit)) === at_limit
    assert Jason.decode!(Jason.encode!(over_limit)) === over_limit

    encoded = assert_accepted!(at_limit, @published_proof_profile)
    assert byte_size(encoded) == 61_440

    assert validate(over_limit, @published_proof_profile) == @error

    # 同一个超限 term 在 Journal 的 65,536-byte profile 下是合法的：两个上限互相独立。
    assert_accepted!(over_limit, @journal_profile)
  end
end
