defmodule Maxio.Storage.MutationBackupTest do
  use ExUnit.Case, async: true

  alias Maxio.Storage.{MutationBackup, ObjectEpoch}

  @id "00000000-0000-0000-0000-000000000001"
  @id_prev "00000000-0000-0000-0000-000000000000"

  defp target do
    {:ok, target} = ObjectEpoch.object_target("backup-test", "photos/a.bin", "null")
    target
  end

  defp token(gen \\ 3, id \\ @id) do
    {:ok, token} = ObjectEpoch.token(gen, id)
    token
  end

  test "manifest 编解码 round-trip（含 previous_token 与空 entries）" do
    {:ok, previous} = ObjectEpoch.token(2, @id_prev)

    {:ok, manifest} =
      MutationBackup.manifest(target(), token(), previous, [
        %{"name" => "part.0"},
        %{"name" => "meta.json"}
      ])

    assert {:ok, bytes} = MutationBackup.encode(manifest)
    assert {:ok, decoded} = MutationBackup.decode(bytes)
    assert decoded == manifest
    assert MutationBackup.entry_names(decoded) == ["part.0", "meta.json"]

    # fresh put：previous_token=nil + entries=[] 合法（final 原本不存在）。
    {:ok, fresh} = MutationBackup.manifest(target(), token(), nil, [])
    assert {:ok, fresh_bytes} = MutationBackup.encode(fresh)
    assert {:ok, ^fresh} = MutationBackup.decode(fresh_bytes)

    # atom :name entry 规范化为字符串键。
    {:ok, atom_keyed} = MutationBackup.manifest(target(), token(), nil, [%{name: "part.0"}])
    assert MutationBackup.entry_names(atom_keyed) == ["part.0"]
  end

  test "相对路径固定为 .maxio-object-mutations/<mutation_id>（UUID 规范小写）" do
    assert MutationBackup.relative_dir(@id) == ".maxio-object-mutations/#{@id}"
    assert MutationBackup.relative_dir(String.upcase(@id)) == ".maxio-object-mutations/#{@id}"
    assert MutationBackup.manifest_rel(@id) == ".maxio-object-mutations/#{@id}/manifest.json"
    assert MutationBackup.root() == ".maxio-object-mutations"

    # mutation_id 会成为盘上路径段：任何非 UUID 形态（含穿越）立即拒绝。
    assert_raise ArgumentError, fn -> MutationBackup.relative_dir("../escape") end
    assert_raise ArgumentError, fn -> MutationBackup.relative_dir("not-a-uuid") end
    assert {:error, :invalid_mutation_id} = MutationBackup.validate_mutation_id(nil)
  end

  test "严格解码：未知格式 / 多余键 / 缺键 / 非对象 payload 全部拒绝" do
    {:ok, manifest} = MutationBackup.manifest(target(), token(), nil, [%{"name" => "part.0"}])
    {:ok, bytes} = MutationBackup.encode(manifest)
    payload = Jason.decode!(bytes)

    assert {:error, {:unsupported_backup_format, "maxio/object-mutation-backup/99"}} =
             payload
             |> Map.put("format", "maxio/object-mutation-backup/99")
             |> Jason.encode!()
             |> MutationBackup.decode()

    assert {:error, :invalid_backup_payload} =
             payload |> Map.put("extra", true) |> Jason.encode!() |> MutationBackup.decode()

    assert {:error, :invalid_backup_payload} =
             payload
             |> Map.delete("previous_token")
             |> Jason.encode!()
             |> MutationBackup.decode()

    assert {:error, :invalid_backup_payload} = MutationBackup.decode("[1,2,3]")
    assert {:error, :invalid_backup_format} = MutationBackup.decode(~s({"no":"format"}))
    assert {:error, _reason} = MutationBackup.decode("{not json")
  end

  test "entry 名严格校验（路径穿越/保留名/重复全部拒绝）" do
    build = fn entries -> MutationBackup.manifest(target(), token(), nil, entries) end

    assert {:error, {:invalid_entry_name, _}} = build.([%{"name" => "a/b"}])
    assert {:error, {:invalid_entry_name, _}} = build.([%{"name" => "a\\b"}])
    assert {:error, {:invalid_entry_name, _}} = build.([%{"name" => ".."}])
    assert {:error, {:invalid_entry_name, _}} = build.([%{"name" => ""}])
    assert {:error, {:invalid_entry_name, _}} = build.([%{"name" => "manifest.json"}])

    assert {:error, :duplicate_entry_name} =
             build.([%{"name" => "part.0"}, %{"name" => "part.0"}])

    assert {:error, {:invalid_entry, _}} = build.([%{"name" => "x", "extra" => 1}])
    assert {:error, {:invalid_entry, _}} = build.(["part.0"])
    assert {:error, :invalid_entries} = MutationBackup.manifest(target(), token(), nil, :nope)
  end

  test "token / previous_token / target 完整重验" do
    assert {:error, :invalid_token} =
             MutationBackup.manifest(
               target(),
               %{"generation" => -1, "mutation_id" => @id},
               nil,
               []
             )

    assert {:error, :invalid_token} =
             MutationBackup.manifest(target(), token(), %{"bogus" => true}, [])

    assert {:error, {:invalid_target, _}} =
             MutationBackup.manifest(%{"kind" => "object_version"}, token(), nil, [])
  end
end
