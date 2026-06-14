defmodule Maxio.Test.StorageConformance do
  @moduledoc """
  存储后端 behaviour 一致性测试套件（铁律 2：FS 与 ErasureCoded 必须满足同一契约）。
  用法：在具体后端的测试模块里先定义 `@backend Mod` 与 `defp opts(ctx)`，再 `use Maxio.Test.StorageConformance`，
  其中 opts/1 接受 setup 上下文返回该后端的 opts（FS -> [data_dir: dir]；EC -> [drives: ..., ...]）。
  """
  defmacro __using__(_opts) do
    quote do
      @backend Module.get_attribute(__MODULE__, :backend) ||
                 raise("set @backend before `use Maxio.Test.StorageConformance`")

      # opts/1：由具体后端测试定义，接受 ctx（含 setup 产物）返回 backend opts。
      test "put/get round-trip + etag/sha256 over 明文", ctx do
        o = opts(ctx)
        :ok = @backend.put_bucket("b", o)
        body = :crypto.strong_rand_bytes(2500)
        {:ok, r} = @backend.put("b", "k", "null", [body], o)
        assert r.size == byte_size(body)
        assert r.etag == :crypto.hash(:md5, body) |> Base.encode16(case: :lower)
        assert r.sha256 == :crypto.hash(:sha256, body) |> Base.encode16(case: :lower)
        {:ok, stream} = @backend.get("b", "k", "null", nil, o)
        assert IO.iodata_to_binary(Enum.to_list(stream)) == body
      end

      test "get Range 含端点", ctx do
        o = opts(ctx)
        :ok = @backend.put_bucket("b", o)
        {:ok, _} = @backend.put("b", "k", "null", ["0123456789"], o)
        {:ok, s} = @backend.get("b", "k", "null", {2, 5}, o)
        assert IO.iodata_to_binary(Enum.to_list(s)) == "2345"
      end

      test "stat / delete / enoent", ctx do
        o = opts(ctx)
        :ok = @backend.put_bucket("b", o)
        {:ok, _} = @backend.put("b", "k", "null", ["abc"], o)
        assert {:ok, %{size: 3}} = @backend.stat("b", "k", "null", o)
        assert :ok = @backend.delete("b", "k", "null", o)
        assert {:error, :enoent} = @backend.stat("b", "k", "null", o)
        assert {:error, :enoent} = @backend.get("b", "k", "null", nil, o)
      end

      test "version 维度物理隔离", ctx do
        o = opts(ctx)
        :ok = @backend.put_bucket("b", o)
        {:ok, _} = @backend.put("b", "k", "null", ["A"], o)
        {:ok, _} = @backend.put("b", "k", "01XYZ", ["B"], o)
        {:ok, s0} = @backend.get("b", "k", "null", nil, o)
        {:ok, s1} = @backend.get("b", "k", "01XYZ", nil, o)
        assert IO.iodata_to_binary(Enum.to_list(s0)) == "A"
        assert IO.iodata_to_binary(Enum.to_list(s1)) == "B"
      end

      test "路径穿越被拒", ctx do
        o = opts(ctx)
        :ok = @backend.put_bucket("b", o)
        assert {:error, :invalid_key} = @backend.put("b", "../x", "null", ["x"], o)
      end

      test "parts: put_part/get_part_stream/assemble/abort", ctx do
        o = opts(ctx)
        :ok = @backend.put_bucket("b", o)
        {:ok, p2} = @backend.put_part("b", "big", "u1", 2, ["DEF"], o)
        {:ok, p1} = @backend.put_part("b", "big", "u1", 1, ["ABC"], o)
        assert p1.size == 3
        assert p1.md5_raw == :crypto.hash(:md5, "ABC")
        assert byte_size(p1.md5_raw) == 16
        assert p2.etag == :crypto.hash(:md5, "DEF") |> Base.encode16(case: :lower)

        {:ok, ps} = @backend.get_part_stream("b", "big", "u1", 1, o)
        assert IO.iodata_to_binary(Enum.to_list(ps)) == "ABC"

        {:ok, %{size: 6}} = @backend.assemble("b", "big", "u1", [1, 2], o)
        {:ok, obj} = @backend.get("b", "big", "null", nil, o)
        assert IO.iodata_to_binary(Enum.to_list(obj)) == "ABCDEF"

        assert :ok = @backend.abort_upload("b", "big", "u1", o)
        assert {:error, :enoent} = @backend.get_part_stream("b", "big", "u1", 1, o)
        assert :ok = @backend.abort_upload("b", "big", "u1", o)
      end

      test "parts: before_part_commit failure does not replace existing part", ctx do
        o = opts(ctx)
        :ok = @backend.put_bucket("b", o)
        {:ok, old} = @backend.put_part("b", "big", "u-precommit", 1, ["OLD"], o)

        hook_opts =
          Keyword.put(o, :before_part_commit, fn part ->
            assert part.size == 3
            assert part.etag == :crypto.hash(:md5, "NEW") |> Base.encode16(case: :lower)
            raise "reject part"
          end)

        assert_raise RuntimeError, "reject part", fn ->
          @backend.put_part("b", "big", "u-precommit", 1, ["NEW"], hook_opts)
        end

        {:ok, stream} = @backend.get_part_stream("b", "big", "u-precommit", 1, o)
        assert IO.iodata_to_binary(Enum.to_list(stream)) == "OLD"

        {:ok, %{size: 3}} = @backend.assemble("b", "big", "u-precommit", [1], o)
        assert old.etag == :crypto.hash(:md5, "OLD") |> Base.encode16(case: :lower)
      end
    end
  end
end
