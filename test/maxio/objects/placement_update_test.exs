defmodule Maxio.Objects.PlacementUpdateTest do
  use Maxio.DataCase, async: true

  alias Maxio.{Buckets, Objects}

  @owner "arn:aws:iam:::root"

  test "update_placement_if_current switches only placement and preserves updated_at" do
    bucket = bucket_name("placement-update")
    {:ok, _bucket} = Buckets.create(bucket, @owner)

    {:ok, object} =
      Objects.put_version_with_id(bucket, "k", "v1", %{
        size: 7,
        etag: "etag-7",
        content_type: "text/plain",
        metadata: %{"m" => "v"},
        tags: %{"t" => "1"},
        placement_set_id: 0,
        placement_topology_hash: "topo-a"
      })

    assert {:ok, updated} =
             Objects.update_placement_if_current(object, %{
               placement_set_id: 1,
               placement_topology_hash: "topo-a"
             })

    assert updated.placement_set_id == 1
    assert updated.placement_topology_hash == "topo-a"
    assert updated.updated_at == object.updated_at
    assert updated.etag == object.etag
    assert updated.size == object.size
    assert updated.metadata == object.metadata
    assert updated.tags == object.tags

    assert {:error, :stale} =
             Objects.update_placement_if_current(object, %{
               placement_set_id: 2,
               placement_topology_hash: "topo-a"
             })
  end

  defp bucket_name(prefix) do
    suffix =
      System.unique_integer([:positive])
      |> Integer.to_string()
      |> String.replace("-", "")

    "#{prefix}-#{suffix}"
  end
end
