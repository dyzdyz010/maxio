defmodule Maxio.Storage.MutationContextTest do
  use ExUnit.Case, async: true

  alias Maxio.ObjectMutation.Journal
  alias Maxio.Storage.{MutationContext, ObjectEpoch}

  @id "00000000-0000-0000-0000-000000000001"

  defp journal(attrs) do
    struct!(
      %Journal{
        id: @id,
        target_kind: "object_version",
        bucket_name: "ctx-test",
        object_key: "photos/a.bin",
        version_id: "null",
        generation: 7,
        operation: "put",
        authority_mode: "pg",
        backend: "fs",
        placement_snapshot: %{"set_id" => "s0"},
        previous_epoch: nil,
        published_fingerprint: %{
          "etag" => "abc",
          "size" => 3,
          "sidecar_sha256" => String.duplicate("0", 64)
        }
      },
      attrs
    )
  end

  test "object_version journal → target/token/final_rel 确定性重建" do
    assert {:ok, ctx} = MutationContext.from_journal(journal(%{}))

    assert ctx.mutation_id == @id
    assert ctx.token == %{"generation" => 7, "mutation_id" => @id}
    assert {:ok, ctx.target} == ObjectEpoch.object_target("ctx-test", "photos/a.bin", "null")
    assert ctx.final_rel == "ctx-test/photos/a.bin"
    assert ctx.operation == "put"
    assert ctx.authority_mode == "pg"
    assert ctx.backend == "fs"
    assert ctx.placement_snapshot == %{"set_id" => "s0"}
    assert ctx.published_fingerprint["etag"] == "abc"
  end

  test "multipart part / upload journal → 对应 target 与相对路径" do
    part =
      journal(%{
        target_kind: "multipart_part",
        version_id: nil,
        upload_id: "up-1",
        part_number: 3
      })

    assert {:ok, ctx} = MutationContext.from_journal(part)
    assert ctx.target["kind"] == "multipart_part"
    assert ctx.final_rel == ".uploads/ctx-test/up-1/3"

    upload =
      journal(%{target_kind: "multipart_upload", version_id: nil, upload_id: "up-1"})

    assert {:ok, ctx} = MutationContext.from_journal(upload)
    assert ctx.target["kind"] == "multipart_upload"
    assert ctx.final_rel == ".uploads/ctx-test/up-1"
  end

  test "非法 journal 结构化拒绝（不静默构造半上下文）" do
    assert {:error, {:invalid_target_kind, "bogus"}} =
             MutationContext.from_journal(journal(%{target_kind: "bogus"}))

    assert {:error, _reason} = MutationContext.from_journal(journal(%{object_key: ""}))

    assert {:error, :invalid_mutation_id} =
             MutationContext.from_journal(journal(%{id: "not-a-uuid"}))
  end
end
