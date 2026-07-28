defmodule MaxioWeb.ObjectLiveIndexTest do
  use MaxioWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Maxio.BucketConfigs
  alias Maxio.Console.DirectMultipartUpload
  alias Maxio.Console.DirectMultipartUpload.Cors, as: DirectMultipartCors
  alias Maxio.Multipart
  alias Maxio.S3.Endpoint
  alias Maxio.Test.SigV4Request

  defmodule SessionCredentialBackend do
    @behaviour Maxio.Auth.CredentialStore

    @access_key "SESSIONCONSOLE"
    @issuer_key "ISSUERCONSOLE"
    @secret "session-secret"
    @token "console-session-token"

    @principal %{
      type: :iam_user,
      access_key: @issuer_key,
      session_access_key: @access_key,
      session_token: @token,
      arn: "arn:aws:iam:::user/session-console"
    }

    @impl true
    def get_secret(@access_key), do: {:ok, %{secret_key: @secret, principal: @principal}}
    def get_secret(_access_key), do: :error

    @impl true
    def get_secret(@access_key, []), do: {:ok, %{secret_key: @secret, principal: @principal}}

    def get_secret(@access_key, session_token: @token),
      do: {:ok, %{secret_key: @secret, principal: @principal}}

    def get_secret(@access_key, _opts), do: {:error, :missing_session_token}
    def get_secret(_access_key, _opts), do: :error

    @impl true
    def put_access_key(_attrs), do: :ok

    @impl true
    def list_keys, do: []

    @impl true
    def invalidate(_scope), do: :ok
  end

  setup %{conn: conn} do
    {:ok, _b} = Maxio.Buckets.create("obj-bucket", "arn:aws:iam:::root")
    :ok = Maxio.Storage.put_bucket("obj-bucket")
    {:ok, conn: log_in_console(conn)}
  end

  test "挂载列表与上传/文件夹表单", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/buckets/obj-bucket/browse")
    assert has_element?(view, "#objects")

    assert has_element?(
             view,
             ~s(#direct-multipart-upload-panel[phx-hook="DirectMultipartUpload"])
           )

    assert has_element?(view, ~s(#direct-multipart-upload-panel[data-file-concurrency="2"]))
    assert has_element?(view, "#direct-multipart-cors-helper")
    assert has_element?(view, "#direct-multipart-cors-state")
    assert has_element?(view, "#direct-multipart-apply-cors")
    assert has_element?(view, "#direct-multipart-cors-settings")
    assert has_element?(view, "#direct-multipart-file-input[multiple]")
    assert has_element?(view, "#direct-multipart-start")
    assert has_element?(view, "#direct-multipart-pause")
    assert has_element?(view, "#direct-multipart-resume")
    assert has_element?(view, "#direct-multipart-abort")
    assert has_element?(view, "#direct-multipart-advanced")
    assert has_element?(view, ~s(#direct-multipart-storage-class[data-role="storage-class"]))
    assert has_element?(view, ~s(#direct-multipart-sse-algorithm[data-role="sse-algorithm"]))

    assert has_element?(
             view,
             ~s(#direct-multipart-sse-customer-key[data-role="sse-customer-key"])
           )

    assert has_element?(
             view,
             ~s(#direct-multipart-sse-customer-key-md5[data-role="sse-customer-key-md5"])
           )

    assert has_element?(view, ~s(#direct-multipart-request-payer[data-role="request-payer"]))
    assert has_element?(view, ~s(#direct-multipart-checksum-type[data-role="checksum-type"]))
    assert has_element?(view, ~s(#direct-multipart-metadata[data-role="metadata"]))
    assert has_element?(view, ~s(#direct-multipart-tagging[data-role="tagging"]))
    assert has_element?(view, "#direct-multipart-operations")
    assert has_element?(view, "#direct-multipart-filter-form")
    assert has_element?(view, "#direct-multipart-history-export")
    refute has_element?(view, "#direct-multipart-active-uploads")
    assert has_element?(view, "#upload-form")
    assert has_element?(view, "#prefix-post-object-policy-form")
    assert has_element?(view, ~s(input[name="post_policy[sse_customer_key]"]))
    assert has_element?(view, ~s(textarea[name="post_policy[raw_amz_fields]"]))
    assert has_element?(view, "#create-folder-form")
    assert has_element?(view, "#objects-empty")
  end

  test "direct multipart CORS helper applies an idempotent owned rule", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/buckets/obj-bucket/browse")

    html =
      view
      |> element("#direct-multipart-apply-cors")
      |> render_click()

    assert html =~ "Direct upload CORS updated"
    assert {:ok, [rule]} = BucketConfigs.get("obj-bucket", :cors)
    assert rule["id"] == DirectMultipartCors.rule_id()
    assert rule["allowed_origins"] == ["http://www.example.com"]
    assert DirectMultipartCors.configured?([rule], "http://www.example.com")

    html =
      view
      |> element("#direct-multipart-apply-cors")
      |> render_click()

    assert html =~ "Direct upload CORS already ready"
    assert {:ok, [^rule]} = BucketConfigs.get("obj-bucket", :cors)
  end

  test "direct multipart CORS helper preserves user rules and places owned rule first", %{
    conn: conn
  } do
    user_rule = %{
      "id" => "user-rule",
      "allowed_origins" => ["https://other-console.test"],
      "allowed_methods" => ["GET"],
      "allowed_headers" => ["*"],
      "expose_headers" => [],
      "max_age_seconds" => 60
    }

    :ok = BucketConfigs.put("obj-bucket", :cors, [user_rule])

    {:ok, view, _html} = live(conn, ~p"/buckets/obj-bucket/browse")

    view
    |> element("#direct-multipart-apply-cors")
    |> render_click()

    assert {:ok, [owned, ^user_rule]} = BucketConfigs.get("obj-bucket", :cors)
    assert owned["id"] == DirectMultipartCors.rule_id()
    assert owned["allowed_origins"] == ["http://www.example.com"]
  end

  test "direct multipart completion event refreshes current prefix stream", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/buckets/obj-bucket/browse?prefix=docs/")

    {:ok, _object} =
      Maxio.Objects.put_version_with_id("obj-bucket", "docs/browser-direct.txt", "null", %{
        size: 6,
        etag: "etag"
      })

    html = render_hook(view, "direct_multipart_uploaded", %{"key" => "docs/browser-direct.txt"})

    assert html =~ "browser-direct.txt"
  end

  test "direct multipart completion refreshes object count when replacing a key", %{
    conn: conn
  } do
    {:ok, _object} =
      Maxio.Objects.put_version_with_id("obj-bucket", "docs/existing.txt", "null", %{
        size: 3,
        etag: "old"
      })

    {:ok, view, html} = live(conn, ~p"/buckets/obj-bucket/browse?prefix=docs/")
    assert html =~ "1 个对象"

    {:ok, _object} =
      Maxio.Objects.put_version_with_id("obj-bucket", "docs/existing.txt", "null", %{
        size: 6,
        etag: "new"
      })

    html = render_hook(view, "direct_multipart_uploaded", %{"key" => "docs/existing.txt"})

    assert html =~ "1 个对象"
    refute html =~ "2 个对象"
  end

  test "lists and aborts unfinished direct multipart uploads for the current prefix", %{
    conn: conn
  } do
    {:ok, upload} =
      Multipart.initiate("obj-bucket", "docs/inflight.bin", %{
        owner: "arn:aws:iam:::root",
        content_type: "application/octet-stream"
      })

    {:ok, registry} =
      DirectMultipartUpload.register(upload, %{
        principal_arn: "arn:aws:iam:::root",
        access_key: "AKIAIOSFODNN7EXAMPLE",
        file_name: "inflight.bin",
        file_size: 9,
        file_last_modified: 1_710_000_000_000,
        part_size: 3
      })

    {:ok, view, _html} = live(conn, ~p"/buckets/obj-bucket/browse?prefix=docs/")

    assert has_element?(view, "#direct-multipart-active-uploads")
    assert has_element?(view, "#direct-multipart-upload-#{registry.id}")
    assert has_element?(view, "#direct-multipart-bulk-form")
    assert has_element?(view, "#direct-multipart-select-#{registry.id}")
    assert render(view) =~ "inflight.bin"

    view
    |> element("#abort-direct-multipart-upload-#{registry.id}")
    |> render_click()

    refute has_element?(view, "#direct-multipart-upload-#{registry.id}")
    assert Multipart.list_uploads("obj-bucket", %{}).uploads == []
    assert has_element?(view, "#direct-multipart-history")
    assert render(view) =~ "aborted"
  end

  test "bulk aborts selected unfinished direct multipart uploads and records history", %{
    conn: conn
  } do
    {:ok, upload_a} =
      Multipart.initiate("obj-bucket", "docs/bulk-a.bin", %{
        owner: "arn:aws:iam:::root",
        content_type: "application/octet-stream"
      })

    {:ok, upload_b} =
      Multipart.initiate("obj-bucket", "docs/bulk-b.bin", %{
        owner: "arn:aws:iam:::root",
        content_type: "application/octet-stream"
      })

    {:ok, registry_a} =
      DirectMultipartUpload.register(upload_a, %{
        principal_arn: "arn:aws:iam:::root",
        access_key: "AKIAIOSFODNN7EXAMPLE",
        file_name: "bulk-a.bin",
        file_size: 9,
        file_last_modified: 1_710_000_000_001,
        part_size: 3
      })

    {:ok, registry_b} =
      DirectMultipartUpload.register(upload_b, %{
        principal_arn: "arn:aws:iam:::root",
        access_key: "AKIAIOSFODNN7EXAMPLE",
        file_name: "bulk-b.bin",
        file_size: 9,
        file_last_modified: 1_710_000_000_002,
        part_size: 3
      })

    {:ok, view, _html} = live(conn, ~p"/buckets/obj-bucket/browse?prefix=docs/")

    html =
      view
      |> form("#direct-multipart-bulk-form",
        direct_multipart_bulk: %{upload_ids: [registry_a.id, registry_b.id]}
      )
      |> render_submit()

    assert html =~ "2 aborted"
    refute has_element?(view, "#direct-multipart-upload-#{registry_a.id}")
    refute has_element?(view, "#direct-multipart-upload-#{registry_b.id}")
    assert has_element?(view, "#direct-multipart-history")
    assert has_element?(view, ~s(#direct-multipart-history-count))
    assert render(view) =~ "bulk-a.bin"
    assert render(view) =~ "bulk-b.bin"
    assert Multipart.list_uploads("obj-bucket", %{}).uploads == []
  end

  test "renders completed direct multipart upload history for the current prefix", %{conn: conn} do
    {:ok, upload} =
      Multipart.initiate("obj-bucket", "docs/history.bin", %{
        owner: "arn:aws:iam:::root",
        content_type: "text/plain"
      })

    {:ok, _registry} =
      DirectMultipartUpload.register(upload, %{
        principal_arn: "arn:aws:iam:::root",
        access_key: "AKIAIOSFODNN7EXAMPLE",
        file_name: "history.bin",
        file_size: 3,
        file_last_modified: 1_710_000_000_003,
        part_size: 3
      })

    {:ok, _history} =
      DirectMultipartUpload.record_completed(upload, %{
        etag: "900150983cd24fb0d6963f7d28e17f72-1",
        version_id: "null",
        size: 3
      })

    {:ok, view, _html} = live(conn, ~p"/buckets/obj-bucket/browse?prefix=docs/")

    assert has_element?(view, "#direct-multipart-history")
    assert render(view) =~ "history.bin"
    assert render(view) =~ "completed"
  end

  test "direct multipart scope filter switches current folder to recursive prefix", %{conn: conn} do
    {_upload_top, registry_top} = start_direct_upload("docs/top.bin")
    {_upload_deep, registry_deep} = start_direct_upload("docs/nested/deep.bin")

    {:ok, view, _html} = live(conn, ~p"/buckets/obj-bucket/browse?prefix=docs/")

    assert has_element?(view, "#direct-multipart-upload-#{registry_top.id}")
    refute has_element?(view, "#direct-multipart-upload-#{registry_deep.id}")

    html =
      view
      |> form("#direct-multipart-filter-form",
        direct_multipart_filters: %{
          scope: "recursive",
          state: "all",
          query: "",
          limit: "50"
        }
      )
      |> render_submit()

    assert html =~ "Prefix subtree"
    assert has_element?(view, "#direct-multipart-upload-#{registry_top.id}")
    assert has_element?(view, "#direct-multipart-upload-#{registry_deep.id}")
    assert render(view) =~ "nested/deep.bin"
    assert render(view) =~ "mpu_scope=recursive"
  end

  test "direct multipart history filters by state and search query", %{conn: conn} do
    {completed, _registry} = start_direct_upload("docs/keep-completed.bin")
    assert {:ok, _history} = DirectMultipartUpload.record_completed(completed, %{size: 3})

    {_aborted, abort_registry} = start_direct_upload("docs/keep-aborted.bin")
    assert :ok = DirectMultipartUpload.abort(abort_registry.id, "arn:aws:iam:::root")

    {other, _registry} = start_direct_upload("docs/other-completed.bin")
    assert {:ok, _history} = DirectMultipartUpload.record_completed(other, %{size: 3})

    {:ok, view, _html} =
      live(
        conn,
        ~p"/buckets/obj-bucket/browse?prefix=docs/&mpu_scope=recursive&mpu_state=aborted&mpu_q=keep&mpu_limit=50"
      )

    html = render(view)
    assert html =~ "keep-aborted.bin"
    assert html =~ "aborted"
    refute has_element?(view, "#direct-multipart-active-uploads")
    refute html =~ "keep-completed.bin"
    refute html =~ "other-completed.bin"
    assert html =~ "mpu_state=aborted"
    assert html =~ "mpu_q=keep"
  end

  test "bulk abort ignores forged ids outside the current direct multipart scope", %{conn: conn} do
    {_visible_upload, visible_registry} = start_direct_upload("docs/visible-bulk.bin")
    {hidden_upload, hidden_registry} = start_direct_upload("docs/nested/hidden-bulk.bin")

    {:ok, view, _html} = live(conn, ~p"/buckets/obj-bucket/browse?prefix=docs/")

    assert has_element?(view, "#direct-multipart-upload-#{visible_registry.id}")
    refute has_element?(view, "#direct-multipart-upload-#{hidden_registry.id}")

    html =
      render_submit(view, "abort_direct_multipart_uploads", %{
        "direct_multipart_bulk" => %{
          "upload_ids" => [visible_registry.id, hidden_registry.id]
        }
      })

    assert html =~ "1 aborted"
    assert html =~ "1 already gone"
    refute has_element?(view, "#direct-multipart-upload-#{visible_registry.id}")

    assert {:ok, _upload} =
             Multipart.get_upload(
               "obj-bucket",
               "docs/nested/hidden-bulk.bin",
               hidden_upload.upload_id
             )
  end

  test "recursive bulk abort can select nested uploads without touching sibling prefix", %{
    conn: conn
  } do
    {_top_upload, top_registry} = start_direct_upload("docs/bulk-top.bin")
    {_nested_upload, nested_registry} = start_direct_upload("docs/nested/bulk-deep.bin")
    {sibling_upload, _sibling_registry} = start_direct_upload("other/bulk-sibling.bin")

    {:ok, view, _html} =
      live(conn, ~p"/buckets/obj-bucket/browse?prefix=docs/&mpu_scope=recursive")

    assert has_element?(view, "#direct-multipart-upload-#{top_registry.id}")
    assert has_element?(view, "#direct-multipart-upload-#{nested_registry.id}")

    html =
      view
      |> form("#direct-multipart-bulk-form",
        direct_multipart_bulk: %{upload_ids: [top_registry.id, nested_registry.id]}
      )
      |> render_submit()

    assert html =~ "2 aborted"
    refute has_element?(view, "#direct-multipart-upload-#{top_registry.id}")
    refute has_element?(view, "#direct-multipart-upload-#{nested_registry.id}")

    assert {:ok, _upload} =
             Multipart.get_upload(
               "obj-bucket",
               "other/bulk-sibling.bin",
               sibling_upload.upload_id
             )
  end

  test "不存在的桶重定向到 /buckets", %{conn: conn} do
    # mount/3 用 push_navigate/2 离开缺失资源 → LiveView 产生 :live_redirect（非 :redirect），
    # flash 携带「桶不存在」错误（不静默）。断言准确的框架输出形态与重定向目标 + flash。
    assert {:error, {:live_redirect, %{to: "/buckets", flash: %{"error" => "桶 no-such 不存在"}}}} =
             live(conn, ~p"/buckets/no-such/browse")
  end

  test "已有对象渲染在列表中", %{conn: conn} do
    {:ok, _o} =
      Maxio.Objects.put_version_with_id("obj-bucket", "hello.txt", "null", %{size: 5, etag: "e"})

    {:ok, view, html} = live(conn, ~p"/buckets/obj-bucket/browse")
    assert html =~ "hello.txt"
    refute has_element?(view, "#objects-empty[style]")
  end

  test "上传文件写入对象元数据和字节", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/buckets/obj-bucket/browse")

    upload =
      file_input(view, "#upload-form", :object, [
        %{name: "live-upload.txt", content: "hello live", type: "text/plain"}
      ])

    render_upload(upload, "live-upload.txt")
    view |> form("#upload-form") |> render_submit()

    assert {:ok, object} = Maxio.Objects.get_metadata("obj-bucket", "live-upload.txt")
    assert object.content_type == "text/plain"
    assert object.size == 10

    assert {:ok, stream} =
             Maxio.Storage.get("obj-bucket", "live-upload.txt", object.version_id, nil)

    assert IO.iodata_to_binary(Enum.to_list(stream)) == "hello live"
  end

  test "为当前 prefix 生成 POST Object HTML form and starts-with policy", %{conn: conn} do
    put_console_s3_public_url("http://localhost:9900")
    {:ok, view, _html} = live(conn, ~p"/buckets/obj-bucket/browse?prefix=docs/")

    html =
      view
      |> form("#prefix-post-object-policy-form",
        post_policy: %{expires_in: "600", max_size: "64", success_action_status: "201"}
      )
      |> render_submit()

    assert html =~ "POST Object form generated"
    assert has_element?(view, "#prefix-post-object-html")

    snippet = post_object_html_from_html(html)
    fields = post_object_fields_from_html(snippet)
    policy = fields["policy"] |> Base.decode64!() |> Jason.decode!()

    assert snippet =~ ~s(<form action="http://localhost:9900/obj-bucket" method="post")
    assert snippet =~ ~s(enctype="multipart/form-data")
    assert snippet =~ ~r/<input type="file" name="file" \/>\n<\/form>\z/
    assert fields["key"] == "docs/${filename}"
    assert fields["success_action_status"] == "201"
    assert fields["x-amz-algorithm"] == "AWS4-HMAC-SHA256"
    assert fields["x-amz-credential"] =~ "AKIAIOSFODNN7EXAMPLE/"
    assert is_binary(fields["x-amz-signature"])
    assert %{"bucket" => "obj-bucket"} in policy["conditions"]
    assert ["starts-with", "$key", "docs/"] in policy["conditions"]
    refute %{"key" => "docs/${filename}"} in policy["conditions"]
    assert ["content-length-range", 0, 64] in policy["conditions"]
    refute html =~ "wJalrXUtnFEMI"
  end

  test "Console prefix POST Object form can be redeemed by S3 endpoint", %{conn: conn} do
    put_console_s3_public_url("http://localhost:9900")
    {:ok, view, _html} = live(conn, ~p"/buckets/obj-bucket/browse?prefix=docs/")

    html =
      view
      |> form("#prefix-post-object-policy-form",
        post_policy: %{expires_in: "600", max_size: "64", success_action_status: "201"}
      )
      |> render_submit()

    fields =
      html
      |> post_object_html_from_html()
      |> post_object_fields_from_html()

    post =
      post_object_form_conn("obj-bucket", fields, "browser body", filename: "upload.txt")
      |> s3_call()

    assert post.status == 201
    assert post.resp_body =~ "<Key>docs/upload.txt</Key>"

    get = SigV4Request.signed_conn(:get, "/obj-bucket/docs/upload.txt") |> s3_call()
    assert get.status == 200
    assert get.resp_body == "browser body"
  end

  test "prefix POST Object form supports signed success redirect", %{conn: conn} do
    put_console_s3_public_url("http://localhost:9900")
    body = "redirect body"
    content_md5 = md5_b64(body)
    {:ok, view, _html} = live(conn, ~p"/buckets/obj-bucket/browse?prefix=docs/")

    html =
      view
      |> form("#prefix-post-object-policy-form",
        post_policy: %{
          expires_in: "600",
          max_size: "64",
          success_action_status: "201",
          success_action_redirect: "https://example.test/uploaded?source=maxio",
          content_md5: content_md5,
          metadata: "origin=prefix\nteam=storage",
          content_type: "text/plain"
        }
      )
      |> render_submit()

    fields =
      html
      |> post_object_html_from_html()
      |> post_object_fields_from_html()

    policy = fields["policy"] |> Base.decode64!() |> Jason.decode!()

    assert fields["key"] == "docs/${filename}"
    assert fields["success_action_redirect"] == "https://example.test/uploaded?source=maxio"
    assert fields["Content-MD5"] == content_md5
    assert fields["x-amz-meta-origin"] == "prefix"
    assert fields["x-amz-meta-team"] == "storage"
    assert fields["Content-Type"] == "text/plain"
    assert ["starts-with", "$key", "docs/"] in policy["conditions"]

    assert %{"success_action_redirect" => "https://example.test/uploaded?source=maxio"} in policy[
             "conditions"
           ]

    assert %{"Content-MD5" => content_md5} in policy["conditions"]
    assert %{"x-amz-meta-origin" => "prefix"} in policy["conditions"]
    assert %{"x-amz-meta-team" => "storage"} in policy["conditions"]
    assert %{"Content-Type" => "text/plain"} in policy["conditions"]

    post =
      post_object_form_conn("obj-bucket", fields, body, filename: "redirect.txt")
      |> s3_call()

    assert post.status == 303

    [location] = get_resp_header(post, "location")
    uri = URI.parse(location)
    query = URI.decode_query(uri.query)

    assert uri.scheme == "https"
    assert uri.host == "example.test"
    assert uri.path == "/uploaded"
    assert query["source"] == "maxio"
    assert query["bucket"] == "obj-bucket"
    assert query["key"] == "docs/redirect.txt"
    assert is_binary(query["etag"])

    get = SigV4Request.signed_conn(:get, "/obj-bucket/docs/redirect.txt") |> s3_call()
    assert get.status == 200
    assert get.resp_body == body
    assert get_resp_header(get, "content-type") == ["text/plain"]
    assert get_resp_header(get, "x-amz-meta-origin") == ["prefix"]
    assert get_resp_header(get, "x-amz-meta-team") == ["storage"]
  end

  test "临时凭据 principal 会把 session token 加入 prefix POST Object form", %{conn: conn} do
    previous_store = Application.fetch_env!(:maxio, :credential_store)
    Application.put_env(:maxio, :credential_store, SessionCredentialBackend)
    put_console_s3_public_url("http://localhost:9900")

    on_exit(fn ->
      Application.put_env(:maxio, :credential_store, previous_store)
    end)

    {:ok, view, _html} =
      conn
      |> log_in_console("SESSIONCONSOLE")
      |> live(~p"/buckets/obj-bucket/browse?prefix=docs/")

    html =
      view
      |> form("#prefix-post-object-policy-form",
        post_policy: %{expires_in: "600", max_size: "64", success_action_status: "201"}
      )
      |> render_submit()

    fields =
      html
      |> post_object_html_from_html()
      |> post_object_fields_from_html()

    policy = fields["policy"] |> Base.decode64!() |> Jason.decode!()

    assert fields["x-amz-security-token"] == "console-session-token"
    assert %{"x-amz-security-token" => "console-session-token"} in policy["conditions"]
    assert fields["x-amz-credential"] =~ "SESSIONCONSOLE/"
  end

  test "prefix POST Object form rejects invalid inputs and public URL", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/buckets/obj-bucket/browse")

    html =
      view
      |> form("#prefix-post-object-policy-form",
        post_policy: %{expires_in: "0", max_size: "64", success_action_status: "201"}
      )
      |> render_submit()

    assert html =~ "POST form expiration must be"
    refute has_element?(view, "#prefix-post-object-html")

    html =
      view
      |> form("#prefix-post-object-policy-form",
        post_policy: %{expires_in: "600", max_size: "0", success_action_status: "201"}
      )
      |> render_submit()

    assert html =~ "POST form max size must be"
    refute has_element?(view, "#prefix-post-object-html")

    put_console_s3_public_url("http://localhost:9900/proxy")
    {:ok, view, _html} = live(conn, ~p"/buckets/obj-bucket/browse")

    html =
      view
      |> form("#prefix-post-object-policy-form",
        post_policy: %{expires_in: "600", max_size: "64", success_action_status: "201"}
      )
      |> render_submit()

    assert html =~ "S3 public URL is invalid"
    refute has_element?(view, "#prefix-post-object-html")
  end

  test "prefix POST Object form clears stale HTML when generation later fails", %{conn: conn} do
    put_console_s3_public_url("http://localhost:9900")
    {:ok, view, _html} = live(conn, ~p"/buckets/obj-bucket/browse?prefix=docs/")

    html =
      view
      |> form("#prefix-post-object-policy-form",
        post_policy: %{expires_in: "600", max_size: "64", success_action_status: "201"}
      )
      |> render_submit()

    assert html =~ "POST Object form generated"
    assert has_element?(view, "#prefix-post-object-html")

    put_console_s3_public_url("http://localhost:9900/proxy")

    html =
      view
      |> form("#prefix-post-object-policy-form",
        post_policy: %{expires_in: "600", max_size: "64", success_action_status: "201"}
      )
      |> render_submit()

    assert html =~ "S3 public URL is invalid"
    refute has_element?(view, "#prefix-post-object-html")
  end

  test "上传文件超过 Console multipart 阈值时走 multipart 路径", %{conn: conn} do
    configure_console_multipart!(threshold: 4, part_size: 3, min_part_size: 1)

    {:ok, view, _html} = live(conn, ~p"/buckets/obj-bucket/browse")

    upload =
      file_input(view, "#upload-form", :object, [
        %{name: "live-multipart.bin", content: "AAABBBCC", type: "application/octet-stream"}
      ])

    render_upload(upload, "live-multipart.bin")
    view |> form("#upload-form") |> render_submit()

    assert {:ok, object} = Maxio.Objects.get_metadata("obj-bucket", "live-multipart.bin")
    assert object.size == 8
    assert String.ends_with?(object.etag, "-3")
    assert object.object_parts["PartsCount"] == 3
    assert Maxio.Multipart.list_uploads("obj-bucket", %{}).uploads == []

    assert {:ok, stream} =
             Maxio.Storage.get("obj-bucket", "live-multipart.bin", object.version_id, nil)

    assert IO.iodata_to_binary(Enum.to_list(stream)) == "AAABBBCC"
  end

  test "前缀导航展示文件夹", %{conn: conn} do
    {:ok, _o} =
      Maxio.Objects.put_version_with_id("obj-bucket", "docs/a.txt", "null", %{size: 1, etag: "e"})

    {:ok, _view, html} = live(conn, ~p"/buckets/obj-bucket/browse")
    assert html =~ "docs"
    # 进入文件夹后看到对象
    {:ok, _v2, html2} = live(conn, ~p"/buckets/obj-bucket/browse?prefix=docs/")
    assert html2 =~ "a.txt"
  end

  test "创建文件夹写零字节占位对象", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/buckets/obj-bucket/browse")
    view |> form("#create-folder-form", folder: %{folder: "reports"}) |> render_submit()
    assert {:ok, _obj} = Maxio.Objects.get_metadata("obj-bucket", "reports/")
  end

  test "删除对象移除行（unversioned）", %{conn: conn} do
    {:ok, _o} =
      Maxio.Objects.put_version_with_id("obj-bucket", "del.txt", "null", %{size: 1, etag: "e"})

    {:ok, view, _html} = live(conn, ~p"/buckets/obj-bucket/browse")
    view |> element(~s([phx-value-key="del.txt"])) |> render_click()
    assert {:error, :not_found} = Maxio.Objects.get_metadata("obj-bucket", "del.txt")
  end

  defp start_direct_upload(key, opts \\ []) do
    {:ok, upload} =
      Multipart.initiate("obj-bucket", key, %{
        owner: "arn:aws:iam:::root",
        content_type: Keyword.get(opts, :content_type, "application/octet-stream")
      })

    {:ok, registry} =
      DirectMultipartUpload.register(upload, %{
        principal_arn: "arn:aws:iam:::root",
        access_key: "AKIAIOSFODNN7EXAMPLE",
        file_name: Path.basename(key),
        file_size: Keyword.get(opts, :file_size, 3),
        file_last_modified: Keyword.get(opts, :file_last_modified, 1_710_000_000_000),
        part_size: Keyword.get(opts, :part_size, 3)
      })

    {upload, registry}
  end

  defp configure_console_multipart!(opts) do
    previous_console = Application.get_env(:maxio, :console, :__unset__)
    previous_min_part_size = Application.get_env(:maxio, :multipart_min_part_size, :__unset__)

    console_config =
      previous_console
      |> console_keyword()
      |> Keyword.put(:multipart_threshold, Keyword.fetch!(opts, :threshold))
      |> Keyword.put(:multipart_part_size, Keyword.fetch!(opts, :part_size))

    Application.put_env(:maxio, :console, console_config)
    Application.put_env(:maxio, :multipart_min_part_size, Keyword.fetch!(opts, :min_part_size))

    on_exit(fn ->
      restore_env(:console, previous_console)
      restore_env(:multipart_min_part_size, previous_min_part_size)
    end)
  end

  defp console_keyword(value) when is_list(value), do: value
  defp console_keyword(_value), do: []

  defp restore_env(key, :__unset__), do: Application.delete_env(:maxio, key)
  defp restore_env(key, value), do: Application.put_env(:maxio, key, value)

  defp put_console_s3_public_url(url) do
    previous = Application.get_env(:maxio, :console, :__unset__)
    Application.put_env(:maxio, :console, s3_public_url: url)

    on_exit(fn ->
      case previous do
        :__unset__ -> Application.delete_env(:maxio, :console)
        value -> Application.put_env(:maxio, :console, value)
      end
    end)
  end

  defp post_object_html_from_html(html) do
    [_, snippet] =
      Regex.run(~r/<textarea[^>]*id="prefix-post-object-html"[^>]*>(.*?)<\/textarea>/s, html)

    snippet
    |> String.trim()
    |> html_decode()
  end

  defp post_object_fields_from_html(snippet) do
    ~r/<input\b[^>]*type="hidden"[^>]*>/s
    |> Regex.scan(snippet)
    |> Enum.map(fn [input] ->
      {html_attr(input, "name"), html_attr(input, "value")}
    end)
    |> Map.new()
  end

  defp post_object_form_conn(bucket, fields, file_body, opts) do
    filename = Keyword.get(opts, :filename, "console-upload.txt")
    boundary = "----maxio-console-prefix-post-#{System.unique_integer([:positive])}"
    body = multipart_body(boundary, fields, file_body, filename)

    SigV4Request.anon_conn(:post, "/#{bucket}",
      body: body,
      headers: [
        {"content-type", "multipart/form-data; boundary=#{boundary}"},
        {"content-length", Integer.to_string(byte_size(body))}
      ]
    )
  end

  defp multipart_body(boundary, fields, file_body, filename) do
    fields =
      Enum.map(fields, fn {name, value} ->
        [
          "--",
          boundary,
          "\r\ncontent-disposition: form-data; name=\"",
          name,
          "\"\r\n\r\n",
          value,
          "\r\n"
        ]
      end)

    file = [
      "--",
      boundary,
      "\r\ncontent-disposition: form-data; name=\"file\"; filename=\"",
      filename,
      "\"\r\ncontent-type: application/octet-stream\r\n\r\n",
      file_body,
      "\r\n"
    ]

    IO.iodata_to_binary([fields, file, "--", boundary, "--\r\n"])
  end

  defp html_attr(input, attr) do
    pattern = ~r/\b#{Regex.escape(attr)}="([^"]*)"/

    case Regex.run(pattern, input) do
      [_, value] -> html_decode(value)
      nil -> flunk("missing #{attr} attribute in #{input}")
    end
  end

  defp html_decode(value) do
    value
    |> String.replace("&quot;", "\"")
    |> String.replace("&#39;", "'")
    |> String.replace("&lt;", "<")
    |> String.replace("&gt;", ">")
    |> String.replace("&amp;", "&")
  end

  defp s3_call(conn), do: Endpoint.call(conn, Endpoint.init([]))
  defp md5_b64(body), do: :crypto.hash(:md5, body) |> Base.encode64()
end
