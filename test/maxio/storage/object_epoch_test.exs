defmodule Maxio.Storage.ObjectEpochTest do
  use ExUnit.Case, async: true

  alias Maxio.Storage.ObjectEpoch

  @now ~U[2026-07-10 06:00:00.000000Z]
  @id_a "00000000-0000-0000-0000-000000000001"
  @id_b "00000000-0000-0000-0000-000000000002"

  test "tokens have a generation-first total order with UUID tie-break" do
    {:ok, low_uuid} = ObjectEpoch.token(8, @id_a)
    {:ok, high_uuid} = ObjectEpoch.token(8, @id_b)
    {:ok, next_generation} = ObjectEpoch.token(9, @id_a)

    assert ObjectEpoch.compare_tokens(low_uuid, low_uuid) == {:ok, :eq}
    assert ObjectEpoch.compare_tokens(low_uuid, high_uuid) == {:ok, :lt}
    assert ObjectEpoch.compare_tokens(high_uuid, low_uuid) == {:ok, :gt}
    assert ObjectEpoch.compare_tokens(high_uuid, next_generation) == {:ok, :lt}

    assert {:error, :invalid_token} =
             ObjectEpoch.compare_tokens(%{generation: 8, mutation_id: @id_a}, low_uuid)

    assert {:error, :invalid_token} =
             ObjectEpoch.compare_tokens(Map.put(low_uuid, "extra", true), high_uuid)

    assert {:error, :invalid_token} = ObjectEpoch.token(-1, @id_a)
    assert {:error, :invalid_mutation_id} = ObjectEpoch.token(1, "not-a-uuid")
  end

  test "fingerprint binds etag, byte size and the exact serialized sidecar" do
    fingerprint = ObjectEpoch.fingerprint("\"etag\"", 42, "{}")

    assert fingerprint == %{
             "etag" => "\"etag\"",
             "size" => 42,
             "sidecar_sha256" =>
               "44136fa355b3678a1146ad16f7e8649e94fb4fc21fe77e8310c060f61caaff8a"
           }

    refute ObjectEpoch.fingerprint_matches?(
             fingerprint,
             ObjectEpoch.fingerprint("\"etag\"", 42, "{ }")
           )

    invalid = %{"etag" => "same", "size" => 1, "sidecar_sha256" => "not-a-sha256"}
    refute ObjectEpoch.fingerprint_matches?(invalid, invalid)
    refute ObjectEpoch.fingerprint_matches?(nil, nil)
  end

  test "published epoch JSON round-trips without weakening its contract" do
    {:ok, target} = ObjectEpoch.object_target("epoch-test", "photos/meta.json", "null")
    {:ok, token} = ObjectEpoch.token(12, String.upcase(@id_b))
    {:ok, previous} = ObjectEpoch.token(11, @id_a)
    fingerprint = ObjectEpoch.fingerprint("abc", 3, ~s({"etag":"abc"}))

    assert {:ok, epoch} =
             ObjectEpoch.new(target, token, %{
               operation: "put_object",
               phase: "published",
               value_type: "object",
               fingerprint: fingerprint,
               previous_token: previous,
               updated_at: @now
             })

    assert {:ok, encoded} = ObjectEpoch.encode(epoch)
    assert {:ok, decoded} = ObjectEpoch.decode(encoded)
    assert decoded == epoch
    assert decoded.token["mutation_id"] == @id_b
  end

  test "published and committed phases require a final fingerprint" do
    {:ok, target} = ObjectEpoch.object_target("epoch-test", "object.bin", "null")
    {:ok, token} = ObjectEpoch.token(1, @id_a)

    assert {:error, :missing_published_fingerprint} =
             ObjectEpoch.new(target, token, %{
               operation: "put_object",
               phase: "published",
               value_type: "object",
               updated_at: @now
             })

    assert {:ok, claimed} =
             ObjectEpoch.new(target, token, %{
               operation: "put_object",
               phase: "claimed",
               value_type: "object",
               updated_at: @now
             })

    assert is_nil(claimed.fingerprint)

    assert {:error, {:invalid_field, :operation}} =
             ObjectEpoch.new(target, token, %{
               operation: "   ",
               phase: "claimed",
               value_type: "object",
               updated_at: @now
             })
  end

  test "decoder rejects unknown formats and non-object JSON" do
    {:ok, target} = ObjectEpoch.object_target("epoch-test", "object.bin", "null")
    {:ok, token} = ObjectEpoch.token(1, @id_a)

    {:ok, epoch} =
      ObjectEpoch.new(target, token, %{
        operation: "put_object",
        phase: "claimed",
        value_type: "object",
        updated_at: @now
      })

    {:ok, bytes} = ObjectEpoch.encode(epoch)
    payload = bytes |> Jason.decode!() |> Map.put("format", "maxio/object-epoch/99")

    assert {:error, {:unsupported_epoch_format, "maxio/object-epoch/99"}} =
             payload |> Jason.encode!() |> ObjectEpoch.decode()

    assert {:error, :invalid_epoch_payload} = ObjectEpoch.decode("[]")
  end

  test "relative paths encode user layout names and add structural separators" do
    {:ok, target} = ObjectEpoch.object_target("epoch-test", "photos/meta.json", "null")

    assert {:ok, path} = ObjectEpoch.relative_path(target)

    assert {:ok, digest} = ObjectEpoch.target_digest(target)

    assert path ==
             ".maxio-object-epochs/v1/epoch-test/object_version/#{binary_part(digest, 0, 2)}/#{digest}/epoch.json"

    assert digest == String.downcase(digest)

    {:ok, adversarial} =
      ObjectEpoch.object_target(
        "epoch-test",
        "photos/meta.json/.versions/bnVsbA/epoch.json",
        "null"
      )

    assert {:ok, other_path} = ObjectEpoch.relative_path(adversarial)
    refute other_path == path
    assert other_path == String.downcase(other_path)
  end

  test "multipart target paths include key, upload identity and part identity" do
    {:ok, upload} = ObjectEpoch.upload_target("epoch-test", "a/b", "upload/opaque")
    {:ok, part} = ObjectEpoch.part_target("epoch-test", "a/b", "upload/opaque", 17)

    assert {:ok, upload_path} = ObjectEpoch.relative_path(upload)
    assert {:ok, part_path} = ObjectEpoch.relative_path(part)

    assert upload_path =~ "/multipart_upload/"
    assert part_path =~ "/multipart_part/"
    refute upload_path == part_path
    refute upload_path =~ "upload/opaque"
  end

  test "target constructors reject traversal and ambiguous part numbers" do
    assert {:error, :invalid_key} =
             ObjectEpoch.object_target("epoch-test", "../escape", "null")

    assert {:error, :invalid_bucket_name} =
             ObjectEpoch.object_target("../bucket", "safe", "null")

    assert {:error, :invalid_part_number} =
             ObjectEpoch.part_target("epoch-test", "safe", "u", 0)

    assert {:error, :invalid_part_number} =
             ObjectEpoch.part_target("epoch-test", "safe", "u", 10_001)
  end

  test "canonical target digests avoid Windows path aliases" do
    keys = ["CON", "con", "trail. ", "nul\\0byte"]

    paths =
      Enum.map(keys, fn key ->
        {:ok, target} = ObjectEpoch.object_target("epoch-test", key, "null")
        {:ok, bytes} = ObjectEpoch.canonical_target_bytes(target)
        {:ok, path} = ObjectEpoch.relative_path(target)
        assert bytes =~ key
        assert path == String.downcase(path)
        refute path =~ key
        path
      end)

    assert length(Enum.uniq(paths)) == length(keys)
  end

  test "decoder rejects extra payload fields and non-normalized UUID case" do
    {:ok, target} = ObjectEpoch.object_target("epoch-test", "strict", "null")
    {:ok, token} = ObjectEpoch.token(1, @id_a)

    {:ok, epoch} =
      ObjectEpoch.new(target, token, %{
        operation: "put",
        phase: "claimed",
        value_type: "object",
        updated_at: @now
      })

    {:ok, bytes} = ObjectEpoch.encode(epoch)
    extra = bytes |> Jason.decode!() |> Map.put("ignored", true) |> Jason.encode!()
    assert {:error, :invalid_epoch_payload} = ObjectEpoch.decode(extra)

    letter_id = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
    {:ok, lower} = ObjectEpoch.token(1, letter_id)
    upper = %{"generation" => 1, "mutation_id" => String.upcase(letter_id)}
    assert {:error, :invalid_token} = ObjectEpoch.compare_tokens(upper, lower)
  end
end
