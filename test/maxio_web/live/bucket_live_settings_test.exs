defmodule MaxioWeb.BucketLiveSettingsTest do
  use MaxioWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  setup %{conn: conn} do
    {:ok, _b} = Maxio.Buckets.create("cfg-bucket", "arn:aws:iam:::root")
    {:ok, conn: log_in_console(conn)}
  end

  test "挂载 tabs 与默认版本化表单", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/buckets/cfg-bucket/settings")
    assert has_element?(view, "#settings-tabs")
    assert has_element?(view, "#versioning-form")
    assert has_element?(view, "#tab-policy")
  end

  test "12 个 tab 链接全部存在", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/buckets/cfg-bucket/settings")
    assert has_element?(view, "#tab-versioning")
    assert has_element?(view, "#tab-policy")
    assert has_element?(view, "#tab-acl")
    assert has_element?(view, "#tab-tags")
    assert has_element?(view, "#tab-cors")
    assert has_element?(view, "#tab-lifecycle")
    assert has_element?(view, "#tab-encryption")
    assert has_element?(view, "#tab-public_access_block")
    assert has_element?(view, "#tab-quota")
    assert has_element?(view, "#tab-object_lock")
    assert has_element?(view, "#tab-replication")
    assert has_element?(view, "#tab-notification")
  end

  test "无效 tab 回退 versioning", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/buckets/cfg-bucket/settings?tab=bogus")
    assert has_element?(view, "#versioning-form")
    refute has_element?(view, "#policy-form")
  end

  test "不存在的桶重定向回 /buckets", %{conn: conn} do
    assert {:error, {:live_redirect, %{to: "/buckets", flash: %{"error" => "桶不存在"}}}} =
             live(conn, ~p"/buckets/no-such/settings")
  end

  test "启用版本化", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/buckets/cfg-bucket/settings")
    view |> form("#versioning-form", versioning: %{status: "Enabled"}) |> render_submit()
    {:ok, b} = Maxio.Buckets.lookup("cfg-bucket")
    assert b.versioning == "Enabled"
  end

  test "Unversioned 映射为 Suspended", %{conn: conn} do
    :ok = Maxio.Buckets.put_versioning("cfg-bucket", "Enabled", nil)
    {:ok, view, _html} = live(conn, ~p"/buckets/cfg-bucket/settings")
    view |> form("#versioning-form", versioning: %{status: "Unversioned"}) |> render_submit()
    {:ok, b} = Maxio.Buckets.lookup("cfg-bucket")
    assert b.versioning == "Suspended"
  end

  test "Object Lock bucket 不能经 Console 暂停版本化", %{conn: conn} do
    create_object_lock_bucket("lock-versioning-settings")
    {:ok, view, _html} = live(conn, ~p"/buckets/lock-versioning-settings/settings")

    html =
      view
      |> form("#versioning-form", versioning: %{status: "Suspended"})
      |> render_submit()

    assert html =~ "Object Lock bucket 不能暂停版本化"
    {:ok, bucket} = Maxio.Buckets.lookup("lock-versioning-settings")
    assert bucket.versioning == "Enabled"

    html =
      view
      |> form("#versioning-form", versioning: %{status: "Unversioned"})
      |> render_submit()

    assert html =~ "Object Lock bucket 不能暂停版本化"
    {:ok, bucket} = Maxio.Buckets.lookup("lock-versioning-settings")
    assert bucket.versioning == "Enabled"
  end

  test "policy tab 保存合法 JSON", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/buckets/cfg-bucket/settings?tab=policy")

    json =
      ~s({"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":"*","Action":"s3:GetObject","Resource":"arn:aws:s3:::cfg-bucket/*"}]})

    view |> form("#policy-form", policy: %{json: json}) |> render_submit()
    assert {:ok, _stored} = Maxio.Policy.Store.get_bucket_policy("cfg-bucket")
  end

  test "policy tab 空 = 删除策略", %{conn: conn} do
    :ok =
      Maxio.Policy.Store.put_bucket_policy(
        "cfg-bucket",
        ~s({"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":"*","Action":"s3:GetObject","Resource":"arn:aws:s3:::cfg-bucket/*"}]})
      )

    {:ok, view, _html} = live(conn, ~p"/buckets/cfg-bucket/settings?tab=policy")
    view |> form("#policy-form", policy: %{json: "   "}) |> render_submit()
    assert :none = Maxio.Policy.Store.get_bucket_policy("cfg-bucket")
  end

  test "policy tab 非法 JSON 报 MalformedPolicy", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/buckets/cfg-bucket/settings?tab=policy")
    html = view |> form("#policy-form", policy: %{json: "{not json"}) |> render_submit()
    assert html =~ "MalformedPolicy"
  end

  test "acl tab 设 public-read", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/buckets/cfg-bucket/settings?tab=acl")
    view |> form("#acl-form", acl: %{canned: "public-read"}) |> render_submit()
    {:ok, b} = Maxio.Buckets.lookup("cfg-bucket")
    assert b.acl_canned == "public-read"
  end

  test "tags tab 保存合法标签", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/buckets/cfg-bucket/settings?tab=tags")
    view |> form("#bucket-tags-form", tags: %{raw: "env=prod\nteam=platform"}) |> render_submit()
    assert {:ok, tags} = Maxio.Buckets.get_tags("cfg-bucket")
    assert {"env", "prod"} in tags
    assert {"team", "platform"} in tags
  end

  test "tags tab aws: 前缀被拒", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/buckets/cfg-bucket/settings?tab=tags")
    html = view |> form("#bucket-tags-form", tags: %{raw: "aws:foo=bar"}) |> render_submit()
    assert html =~ "标签非法"
    assert {:ok, []} = Maxio.Buckets.get_tags("cfg-bucket")
  end

  test "cors tab 保存合法 JSON", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/buckets/cfg-bucket/settings?tab=cors")
    json = ~s([{"allowed_origins":["*"],"allowed_methods":["GET"]}])
    view |> form("#cors-form", cors: %{json: json}) |> render_submit()
    assert {:ok, [%{"allowed_origins" => ["*"]}]} = Maxio.BucketConfigs.get("cfg-bucket", :cors)
  end

  test "cors tab 空 = 删除", %{conn: conn} do
    :ok = Maxio.BucketConfigs.put("cfg-bucket", :cors, [%{"allowed_origins" => ["*"]}])
    {:ok, view, _html} = live(conn, ~p"/buckets/cfg-bucket/settings?tab=cors")
    view |> form("#cors-form", cors: %{json: ""}) |> render_submit()
    assert :none = Maxio.BucketConfigs.get("cfg-bucket", :cors)
  end

  test "cors tab 非法 JSON 报错", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/buckets/cfg-bucket/settings?tab=cors")
    html = view |> form("#cors-form", cors: %{json: "[not json"}) |> render_submit()
    assert html =~ "JSON 非法"
  end

  test "cors tab 拒绝 S3 PutBucketCors 会拒的规则", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/buckets/cfg-bucket/settings?tab=cors")
    json = ~s([{"allowed_origins":["*"],"allowed_methods":["TRACE"]}])
    html = view |> form("#cors-form", cors: %{json: json}) |> render_submit()

    assert html =~ "CORS 规则非法"
    assert :none = Maxio.BucketConfigs.get("cfg-bucket", :cors)
  end

  test "lifecycle tab shows execution options and remaining transition defer + saves JSON", %{
    conn: conn
  } do
    {:ok, view, html} = live(conn, ~p"/buckets/cfg-bucket/settings?tab=lifecycle")
    assert has_element?(view, "#lifecycle-defer-alert")
    assert html =~ "mix maxio.lifecycle.run"
    assert html =~ "config :maxio, :lifecycle_scheduler"
    assert html =~ "Transition"
    assert html =~ "storage_class 元数据"
    json = ~s([{"id":"expire-30","status":"Enabled","has_filter":true,"expiration_days":30}])
    view |> form("#lifecycle-form", lifecycle: %{json: json}) |> render_submit()
    assert {:ok, [%{"id" => "expire-30"}]} = Maxio.BucketConfigs.get("cfg-bucket", :lifecycle)
  end

  test "lifecycle tab 拒绝缺少 Filter 或 legacy Prefix 的规则", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/buckets/cfg-bucket/settings?tab=lifecycle")
    json = ~s([{"status":"Enabled","expiration_days":30}])
    html = view |> form("#lifecycle-form", lifecycle: %{json: json}) |> render_submit()

    assert html =~ "生命周期 规则非法"
    assert :none = Maxio.BucketConfigs.get("cfg-bucket", :lifecycle)
  end

  test "lifecycle tab 拒绝没有 action 的空壳规则", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/buckets/cfg-bucket/settings?tab=lifecycle")
    json = ~s([{"status":"Enabled","filter_prefix":"tmp/"}])
    html = view |> form("#lifecycle-form", lifecycle: %{json: json}) |> render_submit()

    assert html =~ "生命周期 规则非法"
    assert :none = Maxio.BucketConfigs.get("cfg-bucket", :lifecycle)
  end

  test "lifecycle tab 拒绝 S3 PutBucketLifecycle 会拒的规则", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/buckets/cfg-bucket/settings?tab=lifecycle")
    json = ~s([{"status":"Enabled","expiration_days":0}])
    html = view |> form("#lifecycle-form", lifecycle: %{json: json}) |> render_submit()

    assert html =~ "生命周期 规则非法"
    assert :none = Maxio.BucketConfigs.get("cfg-bucket", :lifecycle)
  end

  test "lifecycle tab 拒绝 ExpiredObjectDeleteMarker=false 与 Days 共存", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/buckets/cfg-bucket/settings?tab=lifecycle")

    json =
      ~s([{"status":"Enabled","expiration_days":7,"expired_object_delete_marker":false}])

    html = view |> form("#lifecycle-form", lifecycle: %{json: json}) |> render_submit()

    assert html =~ "生命周期 规则非法"
    assert :none = Maxio.BucketConfigs.get("cfg-bucket", :lifecycle)
  end

  test "lifecycle tab 拒绝 ExpiredObjectDeleteMarker=false 与 Date 共存", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/buckets/cfg-bucket/settings?tab=lifecycle")

    json =
      ~s([{"status":"Enabled","expiration_date":"2026-12-31T00:00:00Z","expired_object_delete_marker":false}])

    html = view |> form("#lifecycle-form", lifecycle: %{json: json}) |> render_submit()

    assert html =~ "生命周期 规则非法"
    assert :none = Maxio.BucketConfigs.get("cfg-bucket", :lifecycle)
  end

  test "lifecycle tab 拒绝非 string 标量字段，避免 runner 后续崩溃", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/buckets/cfg-bucket/settings?tab=lifecycle")
    json = ~s([{"status":"Enabled","filter_prefix":5,"expiration_days":1}])
    html = view |> form("#lifecycle-form", lifecycle: %{json: json}) |> render_submit()

    assert html =~ "生命周期 规则非法"
    assert :none = Maxio.BucketConfigs.get("cfg-bucket", :lifecycle)
  end

  test "encryption tab saves AES256 and aws:kms", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/buckets/cfg-bucket/settings?tab=encryption")
    view |> form("#encryption-form", encryption: %{algorithm: "AES256"}) |> render_submit()
    assert {:ok, %{"algorithm" => "AES256"}} = Maxio.BucketConfigs.get("cfg-bucket", :encryption)

    view |> form("#encryption-form", encryption: %{algorithm: "aws:kms"}) |> render_submit()

    assert {:ok, config} = Maxio.BucketConfigs.get("cfg-bucket", :encryption)
    assert config["algorithm"] == "aws:kms"
    assert config["kms_key_id"] == Maxio.KMS.default_key_id()
  end

  test "encryption tab none = 关闭加密", %{conn: conn} do
    :ok = Maxio.BucketConfigs.put("cfg-bucket", :encryption, %{"algorithm" => "AES256"})
    {:ok, view, _html} = live(conn, ~p"/buckets/cfg-bucket/settings?tab=encryption")
    view |> form("#encryption-form", encryption: %{algorithm: "none"}) |> render_submit()
    assert :none = Maxio.BucketConfigs.get("cfg-bucket", :encryption)
  end

  test "public access block tab 保存四布尔项并可删除", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/buckets/cfg-bucket/settings?tab=public_access_block")
    assert has_element?(view, "#public-access-block-form")
    assert has_element?(view, "#public-access-block-context")
    assert html =~ "bucket-level PublicAccessBlock"

    view
    |> form("#public-access-block-form",
      public_access_block: %{
        block_public_acls: "true",
        ignore_public_acls: "false",
        block_public_policy: "true",
        restrict_public_buckets: "true"
      }
    )
    |> render_submit()

    assert {:ok,
            %{
              "BlockPublicAcls" => true,
              "IgnorePublicAcls" => false,
              "BlockPublicPolicy" => true,
              "RestrictPublicBuckets" => true
            }} = Maxio.BucketConfigs.get("cfg-bucket", :public_access_block)

    view |> element("#public-access-block-delete") |> render_click()
    assert :none = Maxio.BucketConfigs.get("cfg-bucket", :public_access_block)
  end

  test "quota tab saves hard quota and can delete it", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/buckets/cfg-bucket/settings?tab=quota")
    assert has_element?(view, "#quota-form")
    assert has_element?(view, "#quota-context")
    assert html =~ "当前 PG usage"

    view
    |> form("#quota-form", quota: %{enabled: "true", size_bytes: "12345"})
    |> render_submit()

    assert {:ok, %{"type" => "hard", "size_bytes" => 12_345}} =
             Maxio.BucketQuota.get("cfg-bucket")

    html =
      view
      |> form("#quota-form", quota: %{enabled: "true", size_bytes: "0"})
      |> render_submit()

    assert html =~ "Bucket quota 必须是正整数 bytes"

    view |> element("#quota-delete") |> render_click()
    assert :none = Maxio.BucketQuota.get("cfg-bucket")
  end

  test "public access block tab 回显已保存配置", %{conn: conn} do
    :ok =
      Maxio.BucketConfigs.put("cfg-bucket", :public_access_block, %{
        "BlockPublicAcls" => true,
        "IgnorePublicAcls" => true,
        "BlockPublicPolicy" => false,
        "RestrictPublicBuckets" => true
      })

    {:ok, view, _html} = live(conn, ~p"/buckets/cfg-bucket/settings?tab=public_access_block")
    assert has_element?(view, "#public_access_block_block_public_acls:checked")
    assert has_element?(view, "#public_access_block_ignore_public_acls:checked")
    refute has_element?(view, "#public_access_block_block_public_policy:checked")
    assert has_element?(view, "#public_access_block_restrict_public_buckets:checked")
  end

  test "object lock tab 对未启用 bucket 只显示禁用提示", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/buckets/cfg-bucket/settings?tab=object_lock")

    assert has_element?(view, "#object-lock-context")
    assert has_element?(view, "#object-lock-disabled")
    refute has_element?(view, "#object-lock-form")
    assert html =~ "不提供后置启用/关闭 Object Lock"
  end

  test "object lock tab 可保存默认 GOVERNANCE Days retention", %{conn: conn} do
    create_object_lock_bucket("lock-default-days")
    {:ok, view, _html} = live(conn, ~p"/buckets/lock-default-days/settings?tab=object_lock")

    assert has_element?(view, "#object-lock-form")

    view
    |> form("#object-lock-form",
      object_lock: %{mode: "GOVERNANCE", duration_type: "Days", duration_value: "7"}
    )
    |> render_submit()

    assert {:ok,
            %{
              "ObjectLockEnabled" => "Enabled",
              "Rule" => %{"DefaultRetention" => %{"Mode" => "GOVERNANCE", "Days" => 7}}
            }} = Maxio.BucketConfigs.get("lock-default-days", :object_lock)
  end

  test "object lock tab 可保存 COMPLIANCE Years 并清除默认 retention rule", %{conn: conn} do
    create_object_lock_bucket("lock-default-years")
    {:ok, view, _html} = live(conn, ~p"/buckets/lock-default-years/settings?tab=object_lock")

    view
    |> form("#object-lock-form",
      object_lock: %{mode: "COMPLIANCE", duration_type: "Years", duration_value: "1"}
    )
    |> render_submit()

    assert {:ok,
            %{
              "ObjectLockEnabled" => "Enabled",
              "Rule" => %{"DefaultRetention" => %{"Mode" => "COMPLIANCE", "Years" => 1}}
            }} = Maxio.BucketConfigs.get("lock-default-years", :object_lock)

    view
    |> form("#object-lock-form",
      object_lock: %{mode: "", duration_type: "Days", duration_value: ""}
    )
    |> render_submit()

    assert {:ok, %{"ObjectLockEnabled" => "Enabled"} = config} =
             Maxio.BucketConfigs.get("lock-default-years", :object_lock)

    refute Map.has_key?(config, "Rule")
  end

  test "object lock tab 拒绝非法默认 retention 且不覆盖旧配置", %{conn: conn} do
    create_object_lock_bucket("lock-default-invalid")

    original = %{
      "ObjectLockEnabled" => "Enabled",
      "Rule" => %{"DefaultRetention" => %{"Mode" => "GOVERNANCE", "Days" => 9}}
    }

    :ok = Maxio.S3.ObjectLock.put_config("lock-default-invalid", original)

    {:ok, view, _html} = live(conn, ~p"/buckets/lock-default-invalid/settings?tab=object_lock")

    html =
      view
      |> form("#object-lock-form",
        object_lock: %{mode: "GOVERNANCE", duration_type: "Days", duration_value: "0"}
      )
      |> render_submit()

    assert html =~ "Object Lock 配置非法"
    assert {:ok, ^original} = Maxio.BucketConfigs.get("lock-default-invalid", :object_lock)
  end

  test "object lock tab 在 versioning 非 Enabled 的历史坏状态下拒绝保存", %{conn: conn} do
    create_object_lock_bucket("lock-default-suspended")

    original = %{
      "ObjectLockEnabled" => "Enabled",
      "Rule" => %{"DefaultRetention" => %{"Mode" => "GOVERNANCE", "Days" => 3}}
    }

    :ok = Maxio.S3.ObjectLock.put_config("lock-default-suspended", original)
    :ok = Maxio.Buckets.put_versioning("lock-default-suspended", "Suspended", nil)

    {:ok, view, html} = live(conn, ~p"/buckets/lock-default-suspended/settings?tab=object_lock")

    assert html =~ "versioning 不是 Enabled"
    assert has_element?(view, "#object-lock-versioning-disabled")
    refute has_element?(view, "#object-lock-form")
    assert {:ok, ^original} = Maxio.BucketConfigs.get("lock-default-suspended", :object_lock)
  end

  test "object lock tab 回显已保存默认 retention", %{conn: conn} do
    create_object_lock_bucket("lock-default-echo")

    :ok =
      Maxio.S3.ObjectLock.put_config("lock-default-echo", %{
        "ObjectLockEnabled" => "Enabled",
        "Rule" => %{"DefaultRetention" => %{"Mode" => "GOVERNANCE", "Days" => 9}}
      })

    {:ok, view, _html} = live(conn, ~p"/buckets/lock-default-echo/settings?tab=object_lock")

    assert has_element?(view, "#object_lock_mode option[selected][value='GOVERNANCE']")
    assert has_element?(view, "#object_lock_duration_type option[selected][value='Days']")
    assert has_element?(view, "#object_lock_duration_value[value='9']")
  end

  test "replication tab requires source bucket versioning enabled before save", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/buckets/cfg-bucket/settings?tab=replication")

    assert has_element?(view, "#replication-form")
    assert has_element?(view, "#replication-context")
    assert has_element?(view, "#replication-versioning-disabled")
    assert html =~ "versioning 为 Enabled"

    html =
      view
      |> form("#replication-form", replication: %{json: replication_json()})
      |> render_submit()

    assert html =~ "Replication 要求 bucket versioning 为 Enabled"
    assert :none = Maxio.BucketConfigs.get("cfg-bucket", :replication)
  end

  test "replication tab saves normalized config, echoes pretty JSON, and empty form deletes", %{
    conn: conn
  } do
    :ok = Maxio.Buckets.put_versioning("cfg-bucket", "Enabled", nil)
    {:ok, view, _html} = live(conn, ~p"/buckets/cfg-bucket/settings?tab=replication")

    view
    |> form("#replication-form", replication: %{json: replication_json()})
    |> render_submit()

    assert {:ok,
            %{
              "Role" => "arn:aws:iam::000000000000:role/replication",
              "Rules" => [
                %{
                  "ID" => "images",
                  "Priority" => 10,
                  "Filter" => %{"Prefix" => "images/"},
                  "DeleteMarkerReplication" => %{"Status" => "Disabled"},
                  "Destination" => %{
                    "Bucket" => "arn:aws:s3:::replica-dest",
                    "StorageClass" => "STANDARD_IA"
                  }
                }
              ]
            }} = Maxio.BucketConfigs.get("cfg-bucket", :replication)

    {:ok, view, html} = live(conn, ~p"/buckets/cfg-bucket/settings?tab=replication")
    assert has_element?(view, "#replication_json")
    assert html =~ "replica-dest"
    assert html =~ "DeleteMarkerReplication"

    view |> form("#replication-form", replication: %{json: "   "}) |> render_submit()
    assert :none = Maxio.BucketConfigs.get("cfg-bucket", :replication)
  end

  test "replication tab delete button works even when versioning is not enabled", %{conn: conn} do
    :ok = Maxio.S3.Replication.put_config("cfg-bucket", Jason.decode!(replication_json()))

    {:ok, view, _html} = live(conn, ~p"/buckets/cfg-bucket/settings?tab=replication")
    assert has_element?(view, "#replication-versioning-disabled")

    view |> element("#replication-delete") |> render_click()
    assert :none = Maxio.BucketConfigs.get("cfg-bucket", :replication)
  end

  test "replication tab empty form deletes even when versioning is not enabled", %{conn: conn} do
    :ok = Maxio.S3.Replication.put_config("cfg-bucket", Jason.decode!(replication_json()))

    {:ok, view, _html} = live(conn, ~p"/buckets/cfg-bucket/settings?tab=replication")

    view |> form("#replication-form", replication: %{json: "   "}) |> render_submit()
    assert :none = Maxio.BucketConfigs.get("cfg-bucket", :replication)
  end

  test "replication tab disabled versioning save keeps existing config", %{conn: conn} do
    :ok = Maxio.S3.Replication.put_config("cfg-bucket", Jason.decode!(replication_json()))
    assert {:ok, original} = Maxio.BucketConfigs.get("cfg-bucket", :replication)

    {:ok, view, _html} = live(conn, ~p"/buckets/cfg-bucket/settings?tab=replication")

    replacement =
      ~s({"Role":"arn:aws:iam::000000000000:role/other-replication","Rules":[{"ID":"logs","Status":"Enabled","Priority":20,"Filter":{"Prefix":"logs/"},"DeleteMarkerReplication":{"Status":"Disabled"},"Destination":{"Bucket":"arn:aws:s3:::logs-replica"}}]})

    html =
      view |> form("#replication-form", replication: %{json: replacement}) |> render_submit()

    assert html =~ "Replication 要求 bucket versioning 为 Enabled"
    assert {:ok, ^original} = Maxio.BucketConfigs.get("cfg-bucket", :replication)
  end

  test "replication tab rejects invalid JSON and invalid shapes without overwriting", %{
    conn: conn
  } do
    :ok = Maxio.Buckets.put_versioning("cfg-bucket", "Enabled", nil)
    :ok = Maxio.S3.Replication.put_config("cfg-bucket", Jason.decode!(replication_json()))
    assert {:ok, original} = Maxio.BucketConfigs.get("cfg-bucket", :replication)

    {:ok, view, _html} = live(conn, ~p"/buckets/cfg-bucket/settings?tab=replication")

    html =
      view |> form("#replication-form", replication: %{json: "[not json"}) |> render_submit()

    assert html =~ "复制配置 JSON 非法"
    assert {:ok, ^original} = Maxio.BucketConfigs.get("cfg-bucket", :replication)

    html = view |> form("#replication-form", replication: %{json: "[]"}) |> render_submit()
    assert html =~ "复制配置必须是 JSON 对象"
    assert {:ok, ^original} = Maxio.BucketConfigs.get("cfg-bucket", :replication)

    invalid_replication =
      ~s({"Role":"arn:aws:iam::000000000000:role/replication","Rules":[{"Status":"Enabled","Filter":{"Prefix":"images/"},"Destination":{"Bucket":"arn:aws:s3:::replica-dest"}}]})

    html =
      view
      |> form("#replication-form", replication: %{json: invalid_replication})
      |> render_submit()

    assert html =~ "复制配置非法"
    assert {:ok, ^original} = Maxio.BucketConfigs.get("cfg-bucket", :replication)
  end

  test "notification tab saves EventBridge-only config without destination validation", %{
    conn: conn
  } do
    {:ok, view, html} = live(conn, ~p"/buckets/cfg-bucket/settings?tab=notification")
    assert has_element?(view, "#notification-form")
    assert has_element?(view, "#notification-context")
    assert html =~ "EventBridge-only"

    json = ~s({"EventBridgeConfiguration":{}})

    view
    |> form("#notification-form", notification: %{json: json})
    |> render_submit()

    assert {:ok, %{"EventBridgeConfiguration" => %{}}} =
             Maxio.BucketConfigs.get("cfg-bucket", :notification)
  end

  test "notification tab rejects direct destinations without validator or explicit skip", %{
    conn: conn
  } do
    :ok =
      Maxio.BucketConfigs.put("cfg-bucket", :notification, %{
        "EventBridgeConfiguration" => %{}
      })

    {:ok, view, _html} = live(conn, ~p"/buckets/cfg-bucket/settings?tab=notification")

    html =
      view
      |> form("#notification-form", notification: %{json: queue_notification_json()})
      |> render_submit()

    assert html =~ "通知目的地验证器未配置"

    assert {:ok, %{"EventBridgeConfiguration" => %{}}} =
             Maxio.BucketConfigs.get("cfg-bucket", :notification)
  end

  test "notification tab can explicitly skip direct destination validation", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/buckets/cfg-bucket/settings?tab=notification")

    view
    |> form("#notification-form",
      notification: %{
        json: queue_notification_json(),
        skip_destination_validation: "true"
      }
    )
    |> render_submit()

    assert {:ok, %{"QueueConfigurations" => [%{"Id" => "images"}]} = config} =
             Maxio.BucketConfigs.get("cfg-bucket", :notification)

    assert [
             %{
               type: "Queue",
               arn: "arn:aws:sqs:us-east-1:000000000000:images",
               id: "images"
             }
           ] =
             Maxio.S3.Notification.matching_destinations(
               config,
               "s3:ObjectCreated:Put",
               "images/cat.jpg"
             )
  end

  test "notification tab saves direct destinations when validator is configured", %{conn: conn} do
    previous_validator_env = Application.fetch_env(:maxio, :notification_destination_validator)

    on_exit(fn ->
      case previous_validator_env do
        {:ok, value} -> Application.put_env(:maxio, :notification_destination_validator, value)
        :error -> Application.delete_env(:maxio, :notification_destination_validator)
      end
    end)

    Application.put_env(:maxio, :notification_destination_validator,
      validator: {Maxio.Test.NotificationDestinationValidator, self()}
    )

    {:ok, view, _html} = live(conn, ~p"/buckets/cfg-bucket/settings?tab=notification")

    view
    |> form("#notification-form", notification: %{json: queue_notification_json()})
    |> render_submit()

    assert_receive {:maxio_notification_destination_validation, "cfg-bucket",
                    %{"QueueConfigurations" => [%{"Id" => "images"}]}}

    assert {:ok, %{"QueueConfigurations" => [%{"Id" => "images"}]}} =
             Maxio.BucketConfigs.get("cfg-bucket", :notification)
  end

  test "notification tab echoes saved config as pretty JSON", %{conn: conn} do
    :ok =
      Maxio.BucketConfigs.put("cfg-bucket", :notification, %{
        "QueueConfigurations" => [
          %{
            "Id" => "images",
            "Queue" => "arn:aws:sqs:us-east-1:000000000000:images",
            "Events" => ["s3:ObjectCreated:Put"],
            "Filter" => %{
              "S3Key" => %{
                "FilterRules" => [
                  %{"Name" => "prefix", "Value" => "images/"},
                  %{"Name" => "suffix", "Value" => ".jpg"}
                ]
              }
            }
          }
        ]
      })

    {:ok, view, html} = live(conn, ~p"/buckets/cfg-bucket/settings?tab=notification")
    assert has_element?(view, "#notification_json")
    assert html =~ "QueueConfigurations"
    assert html =~ "arn:aws:sqs:us-east-1:000000000000:images"
  end

  test "notification tab empty form or delete button removes config", %{conn: conn} do
    :ok =
      Maxio.BucketConfigs.put("cfg-bucket", :notification, %{
        "EventBridgeConfiguration" => %{}
      })

    {:ok, view, _html} = live(conn, ~p"/buckets/cfg-bucket/settings?tab=notification")

    view |> form("#notification-form", notification: %{json: "   "}) |> render_submit()
    assert :none = Maxio.BucketConfigs.get("cfg-bucket", :notification)

    :ok =
      Maxio.BucketConfigs.put("cfg-bucket", :notification, %{
        "EventBridgeConfiguration" => %{}
      })

    view |> element("#notification-delete") |> render_click()
    assert :none = Maxio.BucketConfigs.get("cfg-bucket", :notification)
  end

  test "notification tab rejects invalid JSON and invalid notification shapes", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/buckets/cfg-bucket/settings?tab=notification")

    html =
      view |> form("#notification-form", notification: %{json: "[not json"}) |> render_submit()

    assert html =~ "通知配置 JSON 非法"

    html = view |> form("#notification-form", notification: %{json: "[]"}) |> render_submit()
    assert html =~ "通知配置必须是 JSON 对象"

    html =
      view
      |> form("#notification-form",
        notification: %{
          json:
            ~s({"QueueConfigurations":[{"Queue":"arn:aws:sqs:us-east-1:000000000000:images","Events":["s3:ObjectCreated:Unknown"]}]})
        }
      )
      |> render_submit()

    assert html =~ "通知配置非法"
    assert :none = Maxio.BucketConfigs.get("cfg-bucket", :notification)

    html =
      view
      |> form("#notification-form",
        notification: %{
          json:
            ~s({"QueueConfigurations":[{"Queue":"arn:aws:sqs:us-east-1:000000000000:images.fifo","Events":["s3:ObjectCreated:Put"]}]})
        }
      )
      |> render_submit()

    assert html =~ "通知配置非法"
    assert :none = Maxio.BucketConfigs.get("cfg-bucket", :notification)

    html =
      view
      |> form("#notification-form",
        notification: %{
          json:
            ~s({"QueueConfigurations":[{"Queue":"not-an-arn","Events":["s3:ObjectCreated:Put"]}]})
        }
      )
      |> render_submit()

    assert html =~ "通知配置非法"
    assert :none = Maxio.BucketConfigs.get("cfg-bucket", :notification)

    html =
      view
      |> form("#notification-form",
        notification: %{
          json:
            ~s({"QueueConfigurations":[{"Queue":"arn:aws:sqs:us-east-1:000000000000:images","Events":["s3:ObjectCreated:Put","s3:ObjectCreated:Put"]}]})
        }
      )
      |> render_submit()

    assert html =~ "通知配置非法"
    assert :none = Maxio.BucketConfigs.get("cfg-bucket", :notification)
  end

  defp queue_notification_json do
    ~s({
      "QueueConfigurations": [
        {
          "Id": "images",
          "Queue": "arn:aws:sqs:us-east-1:000000000000:images",
          "Events": ["s3:ObjectCreated:Put"],
          "Filter": {
            "S3Key": {
              "FilterRules": [
                {"Name": "prefix", "Value": "images/"},
                {"Name": "suffix", "Value": ".jpg"}
              ]
            }
          }
        }
      ]
    })
  end

  defp replication_json do
    ~s({
      "Role": "arn:aws:iam::000000000000:role/replication",
      "Rules": [
        {
          "ID": "images",
          "Status": "Enabled",
          "Priority": 10,
          "Filter": {"Prefix": "images/"},
          "DeleteMarkerReplication": {"Status": "Disabled"},
          "Destination": {
            "Bucket": "arn:aws:s3:::replica-dest",
            "StorageClass": "STANDARD_IA"
          }
        }
      ]
    })
  end

  defp create_object_lock_bucket(bucket) do
    {:ok, _bucket} = Maxio.Buckets.create(bucket, "arn:aws:iam:::root")
    :ok = Maxio.S3.ObjectLock.enable_bucket!(bucket)
  end
end
