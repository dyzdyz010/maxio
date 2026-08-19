defmodule Maxio.S3.ReservedBucketPurgeObjectLockTest do
  @moduledoc """
  C-1 回归 —— `mix maxio.reserved_bucket.purge --confirm-delete` **绝不**销毁被 Object Lock
  保护的版本。

  根因（修复前）：`ReservedBucketAudit.purge/1` 自建了一条删除通路（直接 `Objects.delete_version/3`
  = 无条件 `Repo.delete!`），绕开了 S3 删除路径唯一的提交链
  `Handlers.Object.delete_version!/4`（对象锁 → `reject_locked_version_delete!` →
  权威源分流）。后果：COMPLIANCE 模式、保留期未过、legal hold ON 的版本被静默销毁，
  summary 还报 `deleted: 1, failed: 0`——COMPLIANCE 的 AWS/MinIO 语义是"保留期内任何用户
  （含 root）都不可删除"，这是不可逆的数据销毁 + 合规性破坏（铁律 3 的最恶劣形态）。

  修法：purge 复用同一条提交路径；被拒的版本进 `summary.retained`，逐条带上锁的种类与
  到期时间，CLI 明说"该桶仍然无法清空"。绕过只对 GOVERNANCE 生效（对齐 S3 的
  `x-amz-bypass-governance-retention`），COMPLIANCE 与 legal hold 永不可绕过。
  """
  use Maxio.DataCase, async: false

  alias Maxio.Buckets.Bucket
  alias Maxio.ObjectLockMetadata
  alias Maxio.Objects
  alias Maxio.Objects.Object
  alias Maxio.Repo
  alias Maxio.S3.ReservedBucketAudit
  alias Maxio.Storage

  @owner "arn:aws:iam:::root"

  setup do
    data_dir =
      Path.join(System.tmp_dir!(), "maxio_rb_purge_lock_#{System.unique_integer([:positive])}")

    File.rm_rf(data_dir)
    File.mkdir_p!(data_dir)
    prev_s3 = Application.get_env(:maxio, :s3)
    Application.put_env(:maxio, :s3, Keyword.put(prev_s3, :data_dir, data_dir))

    on_exit(fn ->
      Application.put_env(:maxio, :s3, prev_s3)
      File.rm_rf(data_dir)
    end)

    {:ok, _bucket} =
      %Bucket{}
      |> Bucket.changeset(%{name: "minio", owner: @owner})
      |> Repo.insert()

    :ok
  end

  defp retain_until, do: DateTime.add(DateTime.utc_now(), 3600, :second)

  defp put_version(key, extra) do
    {:ok, _} =
      Objects.put_version_with_id(
        "minio",
        key,
        "null",
        Map.merge(%{size: 1, etag: "etag-#{key}"}, extra)
      )

    :ok
  end

  defp seed_locked_and_free do
    # 复审给出的确切场景：COMPLIANCE + 保留期未过 + legal hold ON。
    :ok =
      put_version("admin/v3/info", %{
        object_lock_mode: "COMPLIANCE",
        object_lock_retain_until: retain_until(),
        object_lock_legal_hold: "ON"
      })

    # 纯 COMPLIANCE + 保留期未过、**无 legal hold**。
    #
    # 为什么必须单列这一条：`ObjectLock.lock_status/2` 先判 legal hold 再判 retention，
    # 所以 "COMPLIANCE + legal hold" 那条版本永远在第一个分支短路——本文件标题主张的
    # 「绕过只对 GOVERNANCE 生效：COMPLIANCE 永不可绕过」在没有这条种子数据时**从未被执行**
    # （已用变异取证：把 bypass 改成同样放行 COMPLIANCE，原来的 8 条测试照样全过）。
    # 有了这条纯 COMPLIANCE 版本，`--bypass-governance` 必须仍然保留它，该路径才真正被走到。
    :ok =
      put_version("admin/v3/compliance", %{
        object_lock_mode: "COMPLIANCE",
        object_lock_retain_until: retain_until(),
        object_lock_legal_hold: "OFF"
      })

    # GOVERNANCE + 保留期未过（可被显式 bypass，对齐 S3）。
    :ok =
      put_version("health/live", %{
        object_lock_mode: "GOVERNANCE",
        object_lock_retain_until: retain_until()
      })

    # 无锁：必须照常清除，锁的存在绝不能把整批清理变成 no-op。
    :ok = put_version("health/ready", %{})
  end

  test "COMPLIANCE + legal hold 的影子版本绝不被 purge 销毁" do
    seed_locked_and_free()

    assert {:ok, summary} = ReservedBucketAudit.purge(confirm_delete: true)

    # ── RED 主张：修复前这三个版本已被 Repo.delete! 无条件销毁 ──
    assert {:ok, _} = Objects.get_version("minio", "admin/v3/info", "null")
    assert {:ok, _} = Objects.get_version("minio", "admin/v3/compliance", "null")
    assert {:ok, _} = Objects.get_version("minio", "health/live", "null")

    # 无锁的那条照常清除
    assert {:error, :not_found} = Objects.get_version("minio", "health/ready", "null")
    assert summary.deleted == 1

    # ── 保留必须**显式列出**，绝不报成成功 ──
    assert summary.failed == 0
    assert summary.retained_count == 3

    retained = Enum.sort_by(summary.retained, & &1.key)

    assert [
             %{
               bucket: "minio",
               key: "admin/v3/compliance",
               version_id: "null",
               reason: :retention,
               mode: "COMPLIANCE",
               bypassable?: false
             },
             %{
               bucket: "minio",
               key: "admin/v3/info",
               version_id: "null",
               reason: :legal_hold,
               mode: "COMPLIANCE",
               bypassable?: false
             },
             %{
               bucket: "minio",
               key: "health/live",
               version_id: "null",
               reason: :retention,
               mode: "GOVERNANCE",
               bypassable?: true
             }
           ] =
             Enum.map(retained, &Map.take(&1, ~w(bucket key version_id reason mode bypassable?)a))

    assert %DateTime{} = Enum.find(retained, &(&1.key == "health/live")).retain_until
    assert %DateTime{} = Enum.find(retained, &(&1.key == "admin/v3/compliance")).retain_until
  end

  test "dry-run 必须预告哪些版本会被保留，而不是假装全部可删" do
    seed_locked_and_free()

    assert {:ok, summary} = ReservedBucketAudit.purge([])

    assert summary.dry_run
    assert summary.versions == 4
    assert summary.retained_count == 3

    assert Enum.map(summary.retained, & &1.key) |> Enum.sort() ==
             ["admin/v3/compliance", "admin/v3/info", "health/live"]

    assert ReservedBucketAudit.shadowed_keys() |> length() == 4
  end

  test "绕过只对 GOVERNANCE 生效：COMPLIANCE 与 legal hold 永不可绕过" do
    seed_locked_and_free()

    assert {:ok, summary} =
             ReservedBucketAudit.purge(confirm_delete: true, bypass_governance: true)

    # 只有 GOVERNANCE 保留期与无锁那条被放行（health/live + health/ready）。
    assert summary.deleted == 2
    assert {:error, :not_found} = Objects.get_version("minio", "health/live", "null")
    assert {:error, :not_found} = Objects.get_version("minio", "health/ready", "null")

    # 两条 COMPLIANCE 都必须留下，且**分别**走两条不同的判定分支：
    #   * admin/v3/compliance —— 纯 retention（无 legal hold 可短路）→ 这一条才真正证明
    #     「COMPLIANCE 单独不可绕过」；
    #   * admin/v3/info —— legal hold（与 bypass 无关的第二道闸）。
    assert [
             %{
               key: "admin/v3/compliance",
               reason: :retention,
               mode: "COMPLIANCE",
               bypassable?: false
             },
             %{key: "admin/v3/info", reason: :legal_hold, mode: "COMPLIANCE", bypassable?: false}
           ] = Enum.map(summary.retained, &Map.take(&1, ~w(key reason mode bypassable?)a))

    assert summary.retained_count == 2
    assert {:ok, _} = Objects.get_version("minio", "admin/v3/info", "null")
    assert {:ok, _} = Objects.get_version("minio", "admin/v3/compliance", "null")
  end

  test "CLI 明说该桶仍然无法清空及原因，并以非零退出（绝不报成成功）" do
    seed_locked_and_free()

    out =
      ExUnit.CaptureIO.capture_io(fn ->
        assert_raise Mix.Error, ~r/still cannot be emptied/, fn ->
          Mix.Tasks.Maxio.ReservedBucket.Purge.run(["--confirm-delete"])
        end
      end)

    assert out =~ "retained=3"
    assert out =~ "retained bucket=minio key=admin/v3/info"
    assert out =~ "legal_hold"
    assert out =~ "retained bucket=minio key=health/live"
    assert out =~ "retention"
    assert out =~ "GOVERNANCE"

    # 纯 COMPLIANCE 保留期那条同样必须被逐条点名（含 mode 与不可绕过标志）。
    assert out =~
             "retained bucket=minio key=admin/v3/compliance version_id=null lock=retention " <>
               "mode=COMPLIANCE"

    assert out =~ "still cannot be emptied"
  end

  test "--json 输出必须能编码 retained（含 DateTime / 原子），绝不在报告阶段崩掉" do
    seed_locked_and_free()

    out =
      ExUnit.CaptureIO.capture_io(fn ->
        assert_raise Mix.Error, ~r/still cannot be emptied/, fn ->
          Mix.Tasks.Maxio.ReservedBucket.Purge.run(["--confirm-delete", "--json"])
        end
      end)

    payload = Jason.decode!(out)

    assert payload["retained_count"] == 3
    assert payload["deleted"] == 1

    assert payload["retained"]
           |> Enum.map(& &1["reason"])
           |> Enum.sort() == ["legal_hold", "retention", "retention"]
  end

  describe "I-1 —— :sidecar 写权威下 purge 必须走写权威介质，绝不只删 PG 派生索引" do
    setup do
      prev_auth = Application.get_env(:maxio, :authoritative_source)

      Application.put_env(
        :maxio,
        :authoritative_source,
        prev_auth |> Keyword.put(:write, :sidecar) |> Keyword.put(:read, :sidecar)
      )

      on_exit(fn -> Application.put_env(:maxio, :authoritative_source, prev_auth) end)
      :ok
    end

    defp object_meta do
      %{
        content_type: "text/plain",
        tags: %{},
        sse: nil,
        acl_canned: "private",
        storage_class: "STANDARD",
        user_metadata: %{}
      }
    end

    # 盘上 sidecar（写权威介质）+ PG 派生索引行，两者都建起来——purge 的扫描面是 PG，
    # 但删除必须由写权威说了算。
    defp seed_sidecar_version(key) do
      {:ok, _} =
        Storage.put("minio", key, "null", ["shadowed bytes"], object_meta: object_meta())

      :ok = put_version(key, %{size: 14})
      :ok
    end

    defp strip_pg_lock_metadata(key) do
      {1, _} =
        Repo.update_all(
          from(o in Object, where: o.key == ^key),
          set: [
            object_lock_mode: nil,
            object_lock_retain_until: nil,
            object_lock_legal_hold: nil
          ]
        )

      :ok
    end

    test "未加锁的影子版本：盘上版本目录与 PG 索引双双清除" do
      :ok = seed_sidecar_version("health/ready")
      assert {:ok, _} = Storage.stat("minio", "health/ready", "null")

      assert {:ok, summary} = ReservedBucketAudit.purge(confirm_delete: true)

      assert summary.deleted == 1
      assert summary.retained == []

      # 盘上（写权威介质）必须真的被清除；只删 PG 行会被 B5-2 扫描器从存活 sidecar 复活。
      assert {:error, :enoent} = Storage.stat("minio", "health/ready", "null")
      assert {:error, :not_found} = Objects.get_version("minio", "health/ready", "null")
    end

    test "锁只写在写权威介质（sidecar）、PG 派生索引已 stale：purge 仍必须拒绝" do
      :ok = seed_sidecar_version("admin/v3/info")

      assert {:ok, _} =
               ObjectLockMetadata.put_legal_hold("minio", "admin/v3/info", "null", %{
                 object_lock_legal_hold: "ON"
               })

      # :sidecar 写权威下 PG 只是**派生索引**，可能 stale（best-effort 镜像失败 / 扫描器未跑）。
      # 这一步正是 I-1 的要害：任何"在 PG 行上再补一道锁检查"的修法在这里都会放行并销毁数据。
      :ok = strip_pg_lock_metadata("admin/v3/info")

      assert {:ok, summary} = ReservedBucketAudit.purge(confirm_delete: true)

      assert summary.deleted == 0

      assert [%{key: "admin/v3/info", reason: :legal_hold, bypassable?: false}] =
               Enum.map(summary.retained, &Map.take(&1, ~w(key reason bypassable?)a))

      # 写权威介质与派生索引都必须原封不动
      assert {:ok, _} = Storage.stat("minio", "admin/v3/info", "null")
      assert {:ok, _} = Objects.get_version("minio", "admin/v3/info", "null")
    end
  end

  test "legal hold 已解除、保留期已过的版本正常清除" do
    :ok =
      put_version("admin/v3/info", %{
        object_lock_mode: "COMPLIANCE",
        object_lock_retain_until: DateTime.add(DateTime.utc_now(), -3600, :second),
        object_lock_legal_hold: "OFF"
      })

    assert {:ok, summary} = ReservedBucketAudit.purge(confirm_delete: true)

    assert summary.deleted == 1
    assert summary.retained == []
    assert ReservedBucketAudit.shadowed_keys() == []
  end
end
