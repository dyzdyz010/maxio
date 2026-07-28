defmodule MaxioWeb.BucketLiveIndexTest do
  use MaxioWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  setup %{conn: conn} do
    {:ok, conn: log_in_console(conn)}
  end

  test "挂载列表与创建表单", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/buckets")
    assert has_element?(view, "#buckets")
    assert has_element?(view, "#create-bucket-form")
    assert has_element?(view, "#bucket_object_lock_enabled")
    assert has_element?(view, "#buckets-empty")
  end

  test "提交合法桶名后出现在列表中", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/buckets")

    html =
      view
      |> form("#create-bucket-form", bucket: %{name: "test-bucket"})
      |> render_submit()

    assert html =~ "test-bucket"
    assert has_element?(view, "#delete-bucket-test-bucket")
    assert {:ok, %{versioning: "Unversioned"}} = Maxio.Buckets.lookup("test-bucket")
    assert Maxio.S3.ObjectLock.get_config("test-bucket") == :none
  end

  test "创建桶时可以启用 Object Lock", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/buckets")

    html =
      view
      |> form("#create-bucket-form",
        bucket: %{name: "console-lock-bucket", object_lock_enabled: "true"}
      )
      |> render_submit()

    assert html =~ "console-lock-bucket"
    assert html =~ "已启用 Object Lock"
    assert has_element?(view, "#delete-bucket-console-lock-bucket")
    assert {:ok, %{versioning: "Enabled"}} = Maxio.Buckets.lookup("console-lock-bucket")

    assert {:ok, %{"ObjectLockEnabled" => "Enabled"}} =
             Maxio.S3.ObjectLock.get_config("console-lock-bucket")

    {:ok, settings_view, _html} =
      live(conn, ~p"/buckets/console-lock-bucket/settings?tab=object_lock")

    assert has_element?(settings_view, "#object-lock-form")
  end

  test "创建桶启用 Object Lock 失败时显式报错且保留已创建桶", %{conn: conn} do
    previous = Application.get_env(:maxio, :console_object_lock_enabler, :__unset__)

    Application.put_env(:maxio, :console_object_lock_enabler, fn bucket ->
      :ok = Maxio.Buckets.put_versioning(bucket, "Enabled", nil)
      raise "forced object lock failure"
    end)

    on_exit(fn -> restore_console_object_lock_enabler(previous) end)

    {:ok, view, _html} = live(conn, ~p"/buckets")

    html =
      view
      |> form("#create-bucket-form",
        bucket: %{name: "console-lock-failed", object_lock_enabled: "true"}
      )
      |> render_submit()

    assert html =~ "已创建，但启用 Object Lock 失败"
    assert html =~ "删除该桶后重新创建"
    assert has_element?(view, "#delete-bucket-console-lock-failed")
    assert {:ok, %{versioning: "Enabled"}} = Maxio.Buckets.lookup("console-lock-failed")
    assert Maxio.S3.ObjectLock.get_config("console-lock-failed") == :none
  end

  test "非法桶名报错误 flash", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/buckets")

    html =
      view
      |> form("#create-bucket-form", bucket: %{name: "X"})
      |> render_submit()

    assert html =~ "命名规则"
  end

  test "重名桶报已存在", %{conn: conn} do
    {:ok, _b} = Maxio.Buckets.create("dup-bucket", "arn:aws:iam:::root")
    {:ok, view, _html} = live(conn, ~p"/buckets")

    html =
      view
      |> form("#create-bucket-form", bucket: %{name: "dup-bucket"})
      |> render_submit()

    assert html =~ "已存在"
  end

  test "删除空桶移除行", %{conn: conn} do
    {:ok, _b} = Maxio.Buckets.create("doomed-bucket", "arn:aws:iam:::root")
    {:ok, view, _html} = live(conn, ~p"/buckets")
    assert has_element?(view, "#delete-bucket-doomed-bucket")

    view |> element("#delete-bucket-doomed-bucket") |> render_click()
    refute has_element?(view, "#delete-bucket-doomed-bucket")
  end

  test "删除非空桶报错误，行保留", %{conn: conn} do
    {:ok, _b} = Maxio.Buckets.create("full-bucket", "arn:aws:iam:::root")

    {:ok, _o} =
      Maxio.Objects.put_version_with_id("full-bucket", "k.txt", "null", %{size: 1, etag: "e"})

    {:ok, view, _html} = live(conn, ~p"/buckets")

    html = view |> element("#delete-bucket-full-bucket") |> render_click()
    assert html =~ "非空"
    assert has_element?(view, "#delete-bucket-full-bucket")
  end

  defp restore_console_object_lock_enabler(:__unset__),
    do: Application.delete_env(:maxio, :console_object_lock_enabler)

  defp restore_console_object_lock_enabler(previous),
    do: Application.put_env(:maxio, :console_object_lock_enabler, previous)
end
