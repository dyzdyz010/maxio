defmodule Maxio.ObjectsLimitTest do
  @moduledoc """
  ROUTE B B1-3 SQL LIST 临时硬 LIMIT 闸回归。

  PG 权威期三处 LIST（list_objects_v2 / list_object_versions / Multipart.list_uploads）原本无界
  `Repo.all` —— 大桶 = 全表拉进内存 DoS。本单元给 SQL 加有界 `limit(min(sql_hard_limit, max_keys*4+1000))`。
  本测试临时把 `config :maxio, :listing, sql_hard_limit` 调到极小值，证明取数确实被封顶在 SQL 层
  （候选行数 <= hard_limit），而非应用层事后裁剪。

  `async: false`：临时改全局 `:maxio, :listing` app env（进程全局），不与并发 async 模块的列举共享脏读。
  """
  use Maxio.DataCase, async: false

  alias Maxio.{Buckets, Multipart, Objects}

  setup do
    {:ok, _} = Buckets.create("limit-test", "arn:aws:iam:::root")

    prev = Application.get_env(:maxio, :listing)
    on_exit(fn -> restore_listing(prev) end)
    :ok
  end

  defp restore_listing(nil), do: Application.delete_env(:maxio, :listing)
  defp restore_listing(prev), do: Application.put_env(:maxio, :listing, prev)

  defp pad(i), do: String.pad_leading(Integer.to_string(i), 4, "0")

  defp put(key),
    do: Objects.put_metadata("limit-test", key, %{size: 1, etag: "e", content_type: "text/plain"})

  test "list_objects_v2：sql_hard_limit 封顶 SQL 取数行数（< max_keys 也只取到 hard_limit）" do
    Application.put_env(:maxio, :listing, sql_hard_limit: 10)

    for i <- 1..30, do: put("obj/" <> pad(i))

    # max_keys=20 -> fetch_limit = min(10, 20*4+1000) = 10；SQL 只取 10 行，折叠后 <= 10。
    res = Objects.list_objects_v2("limit-test", %{prefix: "obj/", max_keys: 20})
    assert length(res.objects) == 10
  end

  test "list_object_versions：sql_hard_limit 封顶 SQL 取数行数" do
    Application.put_env(:maxio, :listing, sql_hard_limit: 10)

    for i <- 1..30, do: put("ver/" <> pad(i))

    res = Objects.list_object_versions("limit-test", %{prefix: "ver/", max_keys: 20})
    assert length(res.versions) == 10
  end

  test "Multipart.list_uploads：sql_hard_limit 封顶 SQL 取数行数" do
    Application.put_env(:maxio, :listing, sql_hard_limit: 10)

    for i <- 1..30, do: {:ok, _} = Multipart.initiate("limit-test", "mpu/" <> pad(i))

    res = Multipart.list_uploads("limit-test", %{prefix: "mpu/", max_uploads: 20})
    assert length(res.uploads) == 10
  end

  test "默认 sql_hard_limit 下大量行仍正确截断（行为对客户端不变）" do
    # 不改 env，用默认 100_000。300 行同 prefix，max_keys=50 -> fetch_limit=1200，足以折叠/截断。
    for i <- 1..300, do: put("big/" <> pad(i))

    res = Objects.list_objects_v2("limit-test", %{prefix: "big/", max_keys: 50})
    assert length(res.objects) == 50
    assert res.is_truncated == true
    assert res.next_continuation_token == "big/0050"
  end
end
