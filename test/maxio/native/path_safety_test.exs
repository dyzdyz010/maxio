defmodule Maxio.Native.PathSafetyTest do
  use ExUnit.Case, async: false

  alias Maxio.Native.PathSafety

  test "native metadata detector accepts a normal directory" do
    root = test_root!()
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)

    assert {:ok, false} = PathSafety.reparse_point(root)
  end

  test "native metadata detector rejects a real Unix symbolic link" do
    if match?({:unix, _name}, :os.type()) do
      root = test_root!()
      target = Path.join(root, "target")
      link = Path.join(root, "link")
      File.mkdir_p!(target)
      File.ln_s!(target, link)

      on_exit(fn ->
        File.rm!(link)
        File.rm_rf!(root)
      end)

      assert {:ok, true} = PathSafety.reparse_point(link)
    end
  end

  test "native metadata detector rejects a real Windows junction" do
    if match?({:win32, _name}, :os.type()) do
      root = test_root!()
      target = Path.join(root, "target")
      sentinel = Path.join(target, "sentinel")
      link = Path.join(root, "junction")

      File.mkdir_p!(target)
      File.write!(sentinel, "target-must-survive")
      create_junction!(link, target)

      on_exit(fn ->
        assert {:ok, true} = PathSafety.reparse_point(link)
        assert :ok = File.rmdir(link)
        refute File.exists?(link)
        assert File.read!(sentinel) == "target-must-survive"
        File.rm_rf!(root)
      end)

      assert {:ok, true} = PathSafety.reparse_point(link)
      assert File.read!(sentinel) == "target-must-survive"
    end
  end

  test "fails closed when the NIF is absent or returns an unknown shape" do
    not_loaded = fn _path -> :erlang.nif_error(:nif_not_loaded) end

    assert {:error, :nif_not_loaded} =
             PathSafety.reparse_point("ignored", not_loaded)

    assert {:error, :native_unavailable} =
             PathSafety.reparse_point("ignored", fn _path -> :unexpected end)
  end

  test "maps only the fixed native error-code whitelist" do
    for code <- ~w(enoent eacces enotdir eloop einval etimedout ebusy estale eio) do
      expected = String.to_existing_atom(code)

      assert {:error, ^expected} =
               PathSafety.reparse_point("ignored", fn _path -> {:error, code} end)
    end

    assert {:error, :native_unavailable} =
             PathSafety.reparse_point("ignored", fn _path -> {:error, "private path detail"} end)
  end

  defp test_root! do
    temp_root = Path.expand(System.tmp_dir!())

    owner =
      Path.join(
        temp_root,
        "maxio_path_safety_#{System.unique_integer([:positive, :monotonic])}"
      )
      |> Path.expand()

    unless Path.dirname(owner) == temp_root and
             String.starts_with?(Path.basename(owner), "maxio_path_safety_") do
      raise "unsafe temporary path"
    end

    owner
  end

  defp create_junction!(link, target) do
    validate_cmd_path!(link)
    validate_cmd_path!(target)
    link_native = String.replace(link, "/", "\\")
    target_native = String.replace(target, "/", "\\")

    {output, status} =
      System.cmd(
        "cmd.exe",
        ["/d", "/c", "mklink", "/J", link_native, target_native],
        stderr_to_stdout: true
      )

    if status != 0 or not File.exists?(link) do
      flunk("failed to create Windows junction: status=#{status}, output=#{inspect(output)}")
    end
  end

  defp validate_cmd_path!(path) do
    expanded = Path.expand(path)

    if expanded != path or String.contains?(path, ["\"", "\r", "\n", "&", "|", "<", ">", "^"]) do
      raise "unsafe command path"
    end

    :ok
  end
end
