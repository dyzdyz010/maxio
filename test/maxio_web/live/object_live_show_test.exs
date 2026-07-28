defmodule MaxioWeb.ObjectLiveShowTest do
  use MaxioWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Maxio.S3.Endpoint
  alias Maxio.Test.SigV4Request

  defmodule CapturingDeleteBackend do
    @behaviour Maxio.Storage.Backend

    defp capture_pid, do: Application.get_env(:maxio, :object_live_show_capture_pid)

    @impl true
    def put(b, k, v, c, o), do: Maxio.Storage.FS.put(b, k, v, c, o)
    @impl true
    def get(b, k, v, r, o), do: Maxio.Storage.FS.get(b, k, v, r, o)
    @impl true
    def stat(b, k, v, o), do: Maxio.Storage.FS.stat(b, k, v, o)

    @impl true
    def delete(b, k, v, o) do
      if pid = capture_pid(), do: send(pid, {:delete, b, k, v, o})
      Maxio.Storage.FS.delete(b, k, v, o)
    end

    @impl true
    def put_bucket(b), do: Maxio.Storage.FS.put_bucket(b)
    @impl true
    def delete_bucket(b), do: Maxio.Storage.FS.delete_bucket(b)
    @impl true
    def put_part(b, k, u, n, c, o), do: Maxio.Storage.FS.put_part(b, k, u, n, c, o)
    @impl true
    def get_part_stream(b, k, u, n, o), do: Maxio.Storage.FS.get_part_stream(b, k, u, n, o)
    @impl true
    def assemble(b, k, u, ns, o), do: Maxio.Storage.FS.assemble(b, k, u, ns, o)
    @impl true
    def abort_upload(b, k, u, o), do: Maxio.Storage.FS.abort_upload(b, k, u, o)
    @impl true
    def put_delete_marker(b, k, v, eo, o), do: Maxio.Storage.FS.put_delete_marker(b, k, v, eo, o)
    @impl true
    def delete_version(b, k, v, o), do: Maxio.Storage.FS.delete_version(b, k, v, o)
    @impl true
    def put_notification_ledgers(b, k, entries, o),
      do: Maxio.Storage.FS.put_notification_ledgers(b, k, entries, o)

    @impl true
    def list_notification_ledgers(b, k, o),
      do: Maxio.Storage.FS.list_notification_ledgers(b, k, o)

    @impl true
    def delete_notification_ledgers(b, k, ids, o),
      do: Maxio.Storage.FS.delete_notification_ledgers(b, k, ids, o)

    @impl true
    def claim_epoch(t, tok, op, o), do: Maxio.Storage.FS.claim_epoch(t, tok, op, o)
    @impl true
    def current_epoch(t, o), do: Maxio.Storage.FS.current_epoch(t, o)
    @impl true
    def restore_if_current(ctx, o), do: Maxio.Storage.FS.restore_if_current(ctx, o)
    @impl true
    def finalize_if_current(ctx, o), do: Maxio.Storage.FS.finalize_if_current(ctx, o)

    @impl true
    def verify_published(ctx, o), do: Maxio.Storage.FS.verify_published(ctx, o)
  end

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
    {:ok, _b} = Maxio.Buckets.create("show-bucket", "arn:aws:iam:::root")
    :ok = Maxio.Storage.put_bucket("show-bucket")

    {:ok, _o} =
      Maxio.Objects.put_version_with_id("show-bucket", "doc.txt", "null", %{size: 9, etag: "e9"})

    {:ok, conn: log_in_console(conn)}
  end

  test "挂载详情、tags 表单、版本表", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/buckets/show-bucket/object/doc.txt")
    assert has_element?(view, "#object-detail")
    assert has_element?(view, "#tags-form")
    assert has_element?(view, "#presign-form")
    assert has_element?(view, "#post-object-policy-form")
    assert has_element?(view, ~s(input[name="post_policy[sse_customer_key]"]))
    assert has_element?(view, ~s(textarea[name="post_policy[raw_amz_fields]"]))
    assert has_element?(view, "#versions")
    assert has_element?(view, "#object-preview-panel")
    assert html =~ "doc.txt"
    assert html =~ "e9"
  end

  test "preview panel renders allowlisted image objects as images", %{conn: conn} do
    {:ok, _object} =
      create_preview_object("preview-image-bucket", "cat.png", %{
        size: 4,
        etag: "img-etag",
        content_type: "image/png"
      })

    {:ok, view, html} = live(conn, ~p"/buckets/preview-image-bucket/object/cat.png")

    assert has_element?(view, "#object-preview-panel")
    assert has_element?(view, "#object-preview-image")
    refute has_element?(view, "#object-preview-frame")
    refute has_element?(view, "#object-preview-unavailable")
    assert html =~ "/buckets/preview-image-bucket/preview/cat.png"
  end

  test "preview panel pins non-null object versions in preview URLs", %{conn: conn} do
    {:ok, _bucket} = Maxio.Buckets.create("preview-version-bucket", "arn:aws:iam:::root")
    :ok = Maxio.Buckets.put_versioning("preview-version-bucket", "Enabled", nil)

    {:ok, object} =
      Maxio.Objects.put_version("preview-version-bucket", "cat.png", "Enabled", %{
        size: 4,
        etag: "versioned-img-etag",
        content_type: "image/png"
      })

    {:ok, view, html} = live(conn, ~p"/buckets/preview-version-bucket/object/cat.png")

    assert has_element?(view, "#object-preview-image")

    assert html =~
             "/buckets/preview-version-bucket/preview/cat.png?versionId=#{object.version_id}"
  end

  test "preview panel renders allowlisted text objects in sandboxed frame", %{conn: conn} do
    {:ok, _object} =
      create_preview_object("preview-text-bucket", "notes.txt", %{
        size: 12,
        etag: "txt-etag",
        content_type: "text/plain; charset=utf-8"
      })

    {:ok, view, html} = live(conn, ~p"/buckets/preview-text-bucket/object/notes.txt")

    assert has_element?(view, "#object-preview-panel")
    assert has_element?(view, "#object-preview-frame[sandbox]")
    refute has_element?(view, "#object-preview-image")
    refute has_element?(view, "#object-preview-unavailable")
    assert html =~ "/buckets/preview-text-bucket/preview/notes.txt"
  end

  test "preview panel keeps unsafe content types download-only", %{conn: conn} do
    {:ok, _object} =
      create_preview_object("preview-html-bucket", "index.html", %{
        size: 15,
        etag: "html-etag",
        content_type: "text/html"
      })

    {:ok, view, html} = live(conn, ~p"/buckets/preview-html-bucket/object/index.html")

    assert has_element?(view, "#object-preview-unavailable")
    assert has_element?(view, "#object-preview-download")
    refute has_element?(view, "#object-preview-image")
    refute has_element?(view, "#object-preview-frame")
    assert html =~ "/buckets/preview-html-bucket/download/index.html"
  end

  test "preview panel keeps oversized objects download-only", %{conn: conn} do
    {:ok, _object} =
      create_preview_object("preview-huge-bucket", "huge.txt", %{
        size: MaxioWeb.ObjectPreview.max_bytes() + 1,
        etag: "huge-etag",
        content_type: "text/plain"
      })

    {:ok, view, _html} = live(conn, ~p"/buckets/preview-huge-bucket/object/huge.txt")

    assert has_element?(view, "#object-preview-unavailable")
    assert has_element?(view, "#object-preview-state", "Too large")
    refute has_element?(view, "#object-preview-frame")
  end

  test "生成当前对象 GET 预签名分享 URL", %{conn: conn} do
    put_console_s3_public_url("http://localhost:9900")
    {:ok, view, _html} = live(conn, ~p"/buckets/show-bucket/object/doc.txt")

    html =
      view
      |> form("#presign-form", presign: %{expires_in: "600"})
      |> render_submit()

    assert html =~ "预签名 GET URL 已生成"
    assert has_element?(view, "#presign-url")

    url = presign_url_from_html(html)
    uri = URI.parse(url)
    query = URI.decode_query(uri.query)

    assert uri.scheme == "http"
    assert uri.host == "localhost"
    assert uri.port == 9900
    assert uri.path == "/show-bucket/doc.txt"
    assert query["X-Amz-Algorithm"] == "AWS4-HMAC-SHA256"
    assert query["X-Amz-Expires"] == "600"
    assert query["X-Amz-SignedHeaders"] == "host"
    assert is_binary(query["X-Amz-Signature"])
    refute Map.has_key?(query, "versionId")
    refute html =~ "wJalrXUtnFEMI"
  end

  test "生成当前对象 PUT 预签名上传 URL 时不签入 GET-only 参数", %{conn: conn} do
    put_console_s3_public_url("http://localhost:9900")
    {:ok, view, _html} = live(conn, ~p"/buckets/show-bucket/object/doc.txt")

    view
    |> form("#presign-form", presign: %{method: "PUT", expires_in: "600"})
    |> render_change()

    refute has_element?(view, "#presign_version_id")
    refute has_element?(view, "#presign_response_content_type")

    html =
      render_submit(view, "create_presigned_url", %{
        "presign" => %{
          "method" => "PUT",
          "expires_in" => "600",
          "version_id" => "null",
          "response_content_type" => "text/plain",
          "response_cache_control" => "no-store"
        }
      })

    assert html =~ "预签名 PUT URL 已生成"

    query =
      html
      |> presign_url_from_html()
      |> URI.parse()
      |> Map.fetch!(:query)
      |> URI.decode_query()

    assert query["X-Amz-Algorithm"] == "AWS4-HMAC-SHA256"
    assert query["X-Amz-Expires"] == "600"
    assert query["X-Amz-SignedHeaders"] == "host"
    assert is_binary(query["X-Amz-Signature"])
    refute Map.has_key?(query, "versionId")
    refute Map.has_key?(query, "response-content-type")
    refute Map.has_key?(query, "response-cache-control")
    refute html =~ "wJalrXUtnFEMI"
  end

  test "预签名 URL method 非法时不生成 URL", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/buckets/show-bucket/object/doc.txt")

    html =
      render_submit(view, "create_presigned_url", %{
        "presign" => %{"method" => "DELETE", "expires_in" => "600"}
      })

    assert html =~ "预签名 Method 必须是 GET 或 PUT"
    refute has_element?(view, "#presign-url")
  end

  test "生成预签名 GET URL 时可签入响应头覆盖参数", %{conn: conn} do
    put_console_s3_public_url("http://localhost:9900")
    {:ok, view, _html} = live(conn, ~p"/buckets/show-bucket/object/doc.txt")

    html =
      view
      |> form("#presign-form",
        presign: %{
          expires_in: "600",
          response_cache_control: "no-store",
          response_content_disposition: ~s(attachment; filename="doc.txt"),
          response_content_encoding: "identity",
          response_content_language: "zh-CN",
          response_content_type: "text/plain",
          response_expires: "Wed, 21 Oct 2037 07:28:00 GMT"
        }
      )
      |> render_submit()

    query =
      html
      |> presign_url_from_html()
      |> URI.parse()
      |> Map.fetch!(:query)
      |> URI.decode_query()

    assert query["response-cache-control"] == "no-store"
    assert query["response-content-disposition"] == ~s(attachment; filename="doc.txt")
    assert query["response-content-encoding"] == "identity"
    assert query["response-content-language"] == "zh-CN"
    assert query["response-content-type"] == "text/plain"
    assert query["response-expires"] == "Wed, 21 Oct 2037 07:28:00 GMT"
    assert is_binary(query["X-Amz-Signature"])
    refute html =~ "wJalrXUtnFEMI"
  end

  test "生成指定版本对象 GET 预签名分享 URL", %{conn: conn} do
    put_console_s3_public_url("http://localhost:9900")
    {:ok, _b} = Maxio.Buckets.create("presign-version-bucket", "arn:aws:iam:::root")
    :ok = Maxio.Buckets.put_versioning("presign-version-bucket", "Enabled", nil)

    {:ok, v1} =
      Maxio.Objects.put_version("presign-version-bucket", "doc.txt", "Enabled", %{
        size: 3,
        etag: "v1"
      })

    {:ok, _v2} =
      Maxio.Objects.put_version("presign-version-bucket", "doc.txt", "Enabled", %{
        size: 4,
        etag: "v2"
      })

    {:ok, view, _html} = live(conn, ~p"/buckets/presign-version-bucket/object/doc.txt")
    assert has_element?(view, ~s(#presign_version_id option[value="#{v1.version_id}"]))

    html =
      view
      |> form("#presign-form",
        presign: %{expires_in: "600", version_id: v1.version_id}
      )
      |> render_submit()

    url = presign_url_from_html(html)
    uri = URI.parse(url)
    query = URI.decode_query(uri.query)

    assert uri.path == "/presign-version-bucket/doc.txt"
    assert query["versionId"] == v1.version_id
    assert is_binary(query["X-Amz-Signature"])
    refute html =~ "wJalrXUtnFEMI"
  end

  test "临时凭据 principal 会把 session token 签入预签名 URL", %{conn: conn} do
    previous_store = Application.fetch_env!(:maxio, :credential_store)
    Application.put_env(:maxio, :credential_store, SessionCredentialBackend)
    put_console_s3_public_url("http://localhost:9900")

    on_exit(fn ->
      Application.put_env(:maxio, :credential_store, previous_store)
    end)

    {:ok, view, _html} =
      conn
      |> log_in_console("SESSIONCONSOLE")
      |> live(~p"/buckets/show-bucket/object/doc.txt")

    html =
      view
      |> form("#presign-form", presign: %{expires_in: "600"})
      |> render_submit()

    query =
      html
      |> presign_url_from_html()
      |> URI.parse()
      |> Map.fetch!(:query)
      |> URI.decode_query()

    assert query["X-Amz-Security-Token"] == "console-session-token"
    assert query["X-Amz-Credential"] =~ "SESSIONCONSOLE/"
  end

  test "预签名版本选择不接受伪造或 delete marker 版本", %{conn: conn} do
    {:ok, _b} = Maxio.Buckets.create("presign-marker-bucket", "arn:aws:iam:::root")
    :ok = Maxio.Buckets.put_versioning("presign-marker-bucket", "Enabled", nil)

    {:ok, v1} =
      Maxio.Objects.put_version("presign-marker-bucket", "doc.txt", "Enabled", %{
        size: 3,
        etag: "v1"
      })

    {:ok, marker} =
      Maxio.Objects.insert_delete_marker("presign-marker-bucket", "doc.txt", "Enabled")

    {:ok, view, _html} = live(conn, ~p"/buckets/presign-marker-bucket/object/doc.txt")
    assert has_element?(view, "#tags-unavailable")
    refute has_element?(view, "#tags-form")
    assert has_element?(view, ~s(#presign_version_id option[value="#{v1.version_id}"]))
    refute has_element?(view, ~s(#presign_version_id option[value="#{marker.version_id}"]))

    render_submit(view, "create_presigned_url", %{
      "presign" => %{"expires_in" => "600", "version_id" => "bad/../version"}
    })

    refute has_element?(view, "#presign-url")

    html = render_submit(view, "save_tags", %{"tags" => %{"raw" => "env=prod"}})
    assert html =~ "不能编辑标签"
  end

  test "未配置 public URL 时提示使用派生 S3 Endpoint 地址", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/buckets/show-bucket/object/doc.txt")

    html =
      view
      |> form("#presign-form", presign: %{expires_in: "60"})
      |> render_submit()

    assert html =~ "未配置 S3 public URL"
    assert has_element?(view, "#presign-url")
  end

  test "public URL 配置非法时不生成预签名 URL", %{conn: conn} do
    put_console_s3_public_url("http://localhost:9900/proxy")
    {:ok, view, _html} = live(conn, ~p"/buckets/show-bucket/object/doc.txt")

    html =
      view
      |> form("#presign-form", presign: %{expires_in: "60"})
      |> render_submit()

    assert html =~ "S3 public URL 配置非法"
    refute has_element?(view, "#presign-url")
  end

  test "生成 POST Object HTML form and policy for current object key", %{conn: conn} do
    put_console_s3_public_url("http://localhost:9900")
    {:ok, view, _html} = live(conn, ~p"/buckets/show-bucket/object/doc.txt")

    html =
      view
      |> form("#post-object-policy-form",
        post_policy: %{expires_in: "600", max_size: "64", success_action_status: "201"}
      )
      |> render_submit()

    assert html =~ "POST Object form generated"
    assert has_element?(view, "#post-object-html")

    snippet = post_object_html_from_html(html)
    fields = post_object_fields_from_html(snippet)
    policy = fields["policy"] |> Base.decode64!() |> Jason.decode!()

    assert snippet =~ ~s(<form action="http://localhost:9900/show-bucket" method="post")
    assert snippet =~ ~s(enctype="multipart/form-data")
    assert snippet =~ ~s(<input type="file" name="file" />)
    assert snippet =~ ~r/<input type="file" name="file" \/>\n<\/form>\z/
    assert fields["key"] == "doc.txt"
    assert fields["success_action_status"] == "201"
    assert fields["x-amz-algorithm"] == "AWS4-HMAC-SHA256"
    assert fields["x-amz-credential"] =~ "AKIAIOSFODNN7EXAMPLE/"
    assert is_binary(fields["x-amz-signature"])
    assert %{"bucket" => "show-bucket"} in policy["conditions"]
    assert %{"key" => "doc.txt"} in policy["conditions"]
    assert ["content-length-range", 0, 64] in policy["conditions"]
    refute html =~ "wJalrXUtnFEMI"
  end

  test "Console generated POST Object form can be redeemed by S3 endpoint", %{conn: conn} do
    put_console_s3_public_url("http://localhost:9900")
    {:ok, view, _html} = live(conn, ~p"/buckets/show-bucket/object/doc.txt")

    html =
      view
      |> form("#post-object-policy-form",
        post_policy: %{expires_in: "600", max_size: "64", success_action_status: "201"}
      )
      |> render_submit()

    fields =
      html
      |> post_object_html_from_html()
      |> post_object_fields_from_html()

    post = post_object_form_conn("show-bucket", fields, "console post body") |> s3_call()

    assert post.status == 201
    assert post.resp_body =~ "<PostResponse"

    get = SigV4Request.signed_conn(:get, "/show-bucket/doc.txt") |> s3_call()
    assert get.status == 200
    assert get.resp_body == "console post body"
  end

  test "Console generated POST Object form signs and applies advanced fields", %{conn: conn} do
    put_console_s3_public_url("http://localhost:9900")
    body = "console advanced body"
    content_md5 = md5_b64(body)
    checksum = sha256_b64(body)
    kms_key_id = "alias/maxio-console-post"
    kms_context = Base.encode64(~s({"purpose":"console-post","bucket":"show-bucket"}))
    {:ok, view, _html} = live(conn, ~p"/buckets/show-bucket/object/doc.txt")

    html =
      view
      |> form("#post-object-policy-form",
        post_policy: %{
          expires_in: "600",
          max_size: "128",
          success_action_status: "201",
          acl: "bucket-owner-full-control",
          content_md5: content_md5,
          content_type: "text/plain",
          cache_control: "no-store",
          content_disposition: ~s(attachment; filename="doc.txt"),
          content_encoding: "identity",
          expires: "Wed, 21 Oct 2037 07:28:00 GMT",
          metadata: "origin=Console\nteam=storage",
          tagging: "env=prod\nteam=storage",
          sse_algorithm: "aws:kms",
          sse_kms_key_id: kms_key_id,
          sse_context: kms_context,
          sse_bucket_key: "true",
          request_payer: "true",
          checksum_algorithm: "SHA256",
          checksum_value: checksum,
          raw_amz_fields:
            "x-amz-storage-class=STANDARD_IA\nx-amz-website-redirect-location=/landing.html"
        }
      )
      |> render_submit()

    fields =
      html
      |> post_object_html_from_html()
      |> post_object_fields_from_html()

    policy = fields["policy"] |> Base.decode64!() |> Jason.decode!()

    assert fields["acl"] == "bucket-owner-full-control"
    assert fields["Content-MD5"] == content_md5
    assert fields["Content-Type"] == "text/plain"
    assert fields["Cache-Control"] == "no-store"
    assert fields["Content-Disposition"] == ~s(attachment; filename="doc.txt")
    assert fields["Content-Encoding"] == "identity"
    assert fields["Expires"] == "Wed, 21 Oct 2037 07:28:00 GMT"
    assert fields["x-amz-meta-origin"] == "Console"
    assert fields["x-amz-meta-team"] == "storage"
    assert fields["x-amz-server-side-encryption"] == "aws:kms"
    assert fields["x-amz-server-side-encryption-aws-kms-key-id"] == kms_key_id
    assert fields["x-amz-server-side-encryption-context"] == kms_context
    assert fields["x-amz-server-side-encryption-bucket-key-enabled"] == "true"
    assert fields["x-amz-request-payer"] == "requester"
    assert fields["x-amz-sdk-checksum-algorithm"] == "SHA256"
    assert fields["x-amz-checksum-sha256"] == checksum
    assert fields["x-amz-storage-class"] == "STANDARD_IA"
    assert fields["x-amz-website-redirect-location"] == "/landing.html"
    assert fields["tagging"] =~ "<Tagging"
    assert %{"acl" => "bucket-owner-full-control"} in policy["conditions"]
    assert %{"Content-MD5" => content_md5} in policy["conditions"]
    assert %{"Content-Type" => "text/plain"} in policy["conditions"]
    assert %{"x-amz-meta-origin" => "Console"} in policy["conditions"]
    assert %{"x-amz-meta-team" => "storage"} in policy["conditions"]
    assert %{"x-amz-server-side-encryption" => "aws:kms"} in policy["conditions"]
    assert %{"x-amz-server-side-encryption-aws-kms-key-id" => kms_key_id} in policy["conditions"]
    assert %{"x-amz-server-side-encryption-context" => kms_context} in policy["conditions"]

    assert %{"x-amz-server-side-encryption-bucket-key-enabled" => "true"} in policy[
             "conditions"
           ]

    assert %{"x-amz-request-payer" => "requester"} in policy["conditions"]
    assert %{"x-amz-checksum-sha256" => checksum} in policy["conditions"]
    assert %{"x-amz-storage-class" => "STANDARD_IA"} in policy["conditions"]
    assert %{"x-amz-website-redirect-location" => "/landing.html"} in policy["conditions"]

    post = post_object_form_conn("show-bucket", fields, body) |> s3_call()

    assert post.status == 201
    assert get_resp_header(post, "content-md5") == []
    assert get_resp_header(post, "x-amz-server-side-encryption") == ["aws:kms"]
    assert get_resp_header(post, "x-amz-server-side-encryption-aws-kms-key-id") == [kms_key_id]
    assert get_resp_header(post, "x-amz-server-side-encryption-bucket-key-enabled") == ["true"]
    assert get_resp_header(post, "x-amz-checksum-sha256") == [checksum]

    assert {:ok, object} = Maxio.Objects.get_metadata("show-bucket", "doc.txt")
    assert object.acl_canned == "bucket-owner-full-control"
    assert object.content_type == "text/plain"
    assert object.cache_control == "no-store"
    assert object.content_disposition == ~s(attachment; filename="doc.txt")
    assert object.content_encoding == "identity"
    assert object.expires == "Wed, 21 Oct 2037 07:28:00 GMT"
    assert object.storage_class == "STANDARD_IA"
    assert object.website_redirect_location == "/landing.html"
    assert object.metadata == %{"origin" => "Console", "team" => "storage"}
    assert object.sse_algorithm == "aws:kms"
    assert object.sse_envelope["kms_key_id"] == kms_key_id
    assert object.sse_envelope["kms_encryption_context_b64"] == kms_context
    assert object.sse_envelope["bucket_key_enabled"] == true
    assert object.checksum == %{"ChecksumSHA256" => checksum, "ChecksumType" => "FULL_OBJECT"}
    assert {:ok, tags} = Maxio.Objects.get_tags("show-bucket", "doc.txt")
    assert Map.new(tags) == %{"env" => "prod", "team" => "storage"}

    get = SigV4Request.signed_conn(:get, "/show-bucket/doc.txt") |> s3_call()
    assert get.status == 200
    assert get.resp_body == body
    assert get_resp_header(get, "x-amz-meta-origin") == ["Console"]
    assert get_resp_header(get, "x-amz-meta-team") == ["storage"]
    assert get_resp_header(get, "x-amz-server-side-encryption") == ["aws:kms"]
    assert get_resp_header(get, "x-amz-server-side-encryption-aws-kms-key-id") == [kms_key_id]
    assert get_resp_header(get, "x-amz-storage-class") == ["STANDARD_IA"]
    assert get_resp_header(get, "x-amz-website-redirect-location") == ["/landing.html"]
  end

  test "Console generated POST Object form signs and applies SSE-C fields", %{conn: conn} do
    put_console_s3_public_url("http://localhost:9900")
    body = "console sse-c body"
    customer_key = :binary.copy(<<11>>, 32)
    customer_key_b64 = Base.encode64(customer_key)
    key_md5_b64 = :crypto.hash(:md5, customer_key) |> Base.encode64()
    {:ok, view, _html} = live(conn, ~p"/buckets/show-bucket/object/doc.txt")

    html =
      view
      |> form("#post-object-policy-form",
        post_policy: %{
          expires_in: "600",
          max_size: "128",
          success_action_status: "201",
          sse_customer_key: customer_key_b64
        }
      )
      |> render_submit()

    fields =
      html
      |> post_object_html_from_html()
      |> post_object_fields_from_html()

    policy = fields["policy"] |> Base.decode64!() |> Jason.decode!()

    assert fields["x-amz-server-side-encryption-customer-algorithm"] == "AES256"
    assert fields["x-amz-server-side-encryption-customer-key"] == customer_key_b64
    assert fields["x-amz-server-side-encryption-customer-key-md5"] == key_md5_b64

    assert %{"x-amz-server-side-encryption-customer-key" => customer_key_b64} in policy[
             "conditions"
           ]

    post = post_object_form_conn("show-bucket", fields, body) |> s3_call()

    assert post.status == 201

    assert get_resp_header(post, "x-amz-server-side-encryption-customer-algorithm") == [
             "AES256"
           ]

    assert get_resp_header(post, "x-amz-server-side-encryption-customer-key-md5") == [
             key_md5_b64
           ]

    assert {:ok, object} = Maxio.Objects.get_metadata("show-bucket", "doc.txt")
    assert object.sse_algorithm == "SSE-C"
    refute inspect(object.sse_envelope) =~ customer_key_b64

    missing = SigV4Request.signed_conn(:get, "/show-bucket/doc.txt") |> s3_call()
    assert missing.status == 400

    get =
      SigV4Request.signed_conn(:get, "/show-bucket/doc.txt", headers: sse_c_headers(customer_key))
      |> s3_call()

    assert get.status == 200
    assert get.resp_body == body
  end

  test "Console generated POST Object max size fails closed at S3 endpoint", %{conn: conn} do
    put_console_s3_public_url("http://localhost:9900")
    {:ok, view, _html} = live(conn, ~p"/buckets/show-bucket/object/doc.txt")

    html =
      view
      |> form("#post-object-policy-form",
        post_policy: %{expires_in: "600", max_size: "3", success_action_status: "201"}
      )
      |> render_submit()

    fields =
      html
      |> post_object_html_from_html()
      |> post_object_fields_from_html()

    post = post_object_form_conn("show-bucket", fields, "toolong") |> s3_call()

    assert post.status == 400
    assert post.resp_body =~ "EntityTooLarge"
  end

  test "临时凭据 principal 会把 session token 加入 POST Object form", %{conn: conn} do
    previous_store = Application.fetch_env!(:maxio, :credential_store)
    Application.put_env(:maxio, :credential_store, SessionCredentialBackend)
    put_console_s3_public_url("http://localhost:9900")

    on_exit(fn ->
      Application.put_env(:maxio, :credential_store, previous_store)
    end)

    {:ok, view, _html} =
      conn
      |> log_in_console("SESSIONCONSOLE")
      |> live(~p"/buckets/show-bucket/object/doc.txt")

    html =
      view
      |> form("#post-object-policy-form",
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

  test "POST Object form rejects invalid inputs and public URL", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/buckets/show-bucket/object/doc.txt")

    html =
      view
      |> form("#post-object-policy-form",
        post_policy: %{expires_in: "0", max_size: "64", success_action_status: "201"}
      )
      |> render_submit()

    assert html =~ "POST form expiration must be"
    refute has_element?(view, "#post-object-html")

    html =
      view
      |> form("#post-object-policy-form",
        post_policy: %{expires_in: "600", max_size: "0", success_action_status: "201"}
      )
      |> render_submit()

    assert html =~ "POST form max size must be"
    refute has_element?(view, "#post-object-html")

    sse_customer_key = Base.encode64(:binary.copy(<<1>>, 32))

    html =
      view
      |> form("#post-object-policy-form",
        post_policy: %{
          expires_in: "600",
          max_size: "64",
          success_action_status: "201",
          sse_customer_key: sse_customer_key,
          sse_algorithm: "aws:kms"
        }
      )
      |> render_submit()

    assert html =~ "POST form SSE settings are invalid"
    refute html =~ sse_customer_key
    refute has_element?(view, "#post-object-html")

    put_console_s3_public_url("http://localhost:9900/proxy")
    {:ok, view, _html} = live(conn, ~p"/buckets/show-bucket/object/doc.txt")

    html =
      view
      |> form("#post-object-policy-form",
        post_policy: %{expires_in: "600", max_size: "64", success_action_status: "201"}
      )
      |> render_submit()

    assert html =~ "S3 public URL is invalid"
    refute has_element?(view, "#post-object-html")

    html =
      view
      |> form("#post-object-policy-form",
        post_policy: %{
          expires_in: "600",
          max_size: "64",
          success_action_status: "201",
          checksum_value: "abc"
        }
      )
      |> render_submit()

    assert html =~ "POST form checksum settings are invalid"
    refute has_element?(view, "#post-object-html")
  end

  test "POST Object form clears stale HTML when generation later fails", %{conn: conn} do
    put_console_s3_public_url("http://localhost:9900")
    {:ok, view, _html} = live(conn, ~p"/buckets/show-bucket/object/doc.txt")

    html =
      view
      |> form("#post-object-policy-form",
        post_policy: %{expires_in: "600", max_size: "64", success_action_status: "201"}
      )
      |> render_submit()

    assert html =~ "POST Object form generated"
    assert has_element?(view, "#post-object-html")

    put_console_s3_public_url("http://localhost:9900/proxy")

    html =
      view
      |> form("#post-object-policy-form",
        post_policy: %{expires_in: "600", max_size: "64", success_action_status: "201"}
      )
      |> render_submit()

    assert html =~ "S3 public URL is invalid"
    refute has_element?(view, "#post-object-html")
  end

  test "预签名 URL 有效期非法时不生成 URL", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/buckets/show-bucket/object/doc.txt")

    html =
      view
      |> form("#presign-form", presign: %{expires_in: "0"})
      |> render_submit()

    assert html =~ "有效期必须是"
    refute has_element?(view, "#presign-url")
  end

  test "详情展示元数据字段", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/buckets/show-bucket/object/doc.txt")
    assert html =~ "ETag"
    assert html =~ "Content-Type"
    assert html =~ "Storage Class"
    assert html =~ "Version ID"
    # storage_class 默认 STANDARD，version_id 默认 null
    assert html =~ "STANDARD"
    assert html =~ "null"
  end

  test "版本表行带 delete marker badge（Enabled 桶 DELETE 产生 marker）", %{conn: conn} do
    {:ok, _b} = Maxio.Buckets.create("ver-bucket", "arn:aws:iam:::root")
    :ok = Maxio.Buckets.put_versioning("ver-bucket", "Enabled", nil)

    {:ok, _o} =
      Maxio.Objects.put_version("ver-bucket", "v.txt", "Enabled", %{size: 3, etag: "v1"})

    {:ok, _dm} = Maxio.Objects.insert_delete_marker("ver-bucket", "v.txt", "Enabled")

    {:ok, view, html} = live(conn, ~p"/buckets/ver-bucket/object/v.txt")
    assert html =~ "delete marker"
    assert has_element?(view, "#tags-unavailable")
    refute has_element?(view, "#tags-form")
  end

  test "不存在对象重定向到 browse", %{conn: conn} do
    # mount/3 用 push_navigate/2 离开缺失资源 → LiveView 产生 :live_redirect（非 :redirect），
    # flash 携带「对象不存在」错误（不静默）。断言准确的框架输出形态。
    assert {:error,
            {:live_redirect, %{to: "/buckets/show-bucket/browse", flash: %{"error" => "对象不存在"}}}} =
             live(conn, ~p"/buckets/show-bucket/object/nope.txt")
  end

  test "保存合法标签", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/buckets/show-bucket/object/doc.txt")
    view |> form("#tags-form", tags: %{raw: "env=prod\nteam=storage"}) |> render_submit()
    assert {:ok, tags} = Maxio.Objects.get_tags("show-bucket", "doc.txt")
    assert {"env", "prod"} in tags
    assert {"team", "storage"} in tags
  end

  test "非法标签（aws: 前缀）报错", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/buckets/show-bucket/object/doc.txt")
    html = view |> form("#tags-form", tags: %{raw: "aws:foo=bar"}) |> render_submit()
    assert html =~ "标签非法"
    # 校验拒绝后未写入
    assert {:ok, tags} = Maxio.Objects.get_tags("show-bucket", "doc.txt")
    refute {"aws:foo", "bar"} in tags
  end

  test "删除版本后 stream 重取（Enabled 桶）", %{conn: conn} do
    {:ok, _b} = Maxio.Buckets.create("del-bucket", "arn:aws:iam:::root")
    :ok = Maxio.Buckets.put_versioning("del-bucket", "Enabled", nil)
    {:ok, v1} = Maxio.Objects.put_version("del-bucket", "k.txt", "Enabled", %{size: 1, etag: "a"})

    {:ok, _v2} =
      Maxio.Objects.put_version("del-bucket", "k.txt", "Enabled", %{size: 2, etag: "b"})

    {:ok, view, _html} = live(conn, ~p"/buckets/del-bucket/object/k.txt")

    view
    |> element(~s([phx-value-vid="#{v1.version_id}"]))
    |> render_click()

    assert {:error, :not_found} =
             Maxio.Objects.get_version("del-bucket", "k.txt", v1.version_id)
  end

  test "删除最后普通版本后导航回 bucket browse 且不保留旧详情", %{conn: conn} do
    bucket = "delete-last-object-bucket"
    key = "last.txt"
    browse_path = ~p"/buckets/#{bucket}/browse"

    {:ok, _bucket} = Maxio.Buckets.create(bucket, "arn:aws:iam:::root")
    :ok = Maxio.Buckets.put_versioning(bucket, "Enabled", nil)

    {:ok, version} =
      Maxio.Objects.put_version(bucket, key, "Enabled", %{size: 1, etag: "last-object"})

    {:ok, view, _html} = live(conn, ~p"/buckets/#{bucket}/object/#{key}")
    assert has_element?(view, "#object-detail")
    assert has_element?(view, "#tags-form")

    view
    |> element(~s(button[phx-click="delete_version"][phx-value-vid="#{version.version_id}"]))
    |> render_click()

    assert_redirect(view, browse_path)
    assert {:ok, browse_view, _html} = live(conn, browse_path)
    assert has_element?(browse_view, "#breadcrumb")
    refute has_element?(browse_view, "#object-detail")
    refute has_element?(browse_view, "#tags-form")
    refute has_element?(browse_view, "#object-lock-panel")
  end

  test "删除最后 delete marker 后导航回 bucket browse 且不保留旧详情", %{conn: conn} do
    bucket = "delete-last-marker-bucket"
    key = "marker.txt"
    browse_path = ~p"/buckets/#{bucket}/browse"

    {:ok, _bucket} = Maxio.Buckets.create(bucket, "arn:aws:iam:::root")
    :ok = Maxio.Buckets.put_versioning(bucket, "Enabled", nil)
    {:ok, marker} = Maxio.Objects.insert_delete_marker(bucket, key, "Enabled")

    {:ok, view, _html} = live(conn, ~p"/buckets/#{bucket}/object/#{key}")
    assert has_element?(view, "#object-detail")
    assert has_element?(view, "#tags-unavailable")

    view
    |> element(~s(button[phx-click="delete_version"][phx-value-vid="#{marker.version_id}"]))
    |> render_click()

    assert_redirect(view, browse_path)
    assert {:ok, browse_view, _html} = live(conn, browse_path)
    assert has_element?(browse_view, "#breadcrumb")
    refute has_element?(browse_view, "#object-detail")
    refute has_element?(browse_view, "#tags-unavailable")
    refute has_element?(browse_view, "#object-lock-panel")
  end

  test "删除版本时按对象持久化 placement 清理存储层", %{conn: conn} do
    prev_backend = Application.get_env(:maxio, :storage_backend)
    prev_capture_pid = Application.get_env(:maxio, :object_live_show_capture_pid)

    Application.put_env(:maxio, :storage_backend, CapturingDeleteBackend)
    Application.put_env(:maxio, :object_live_show_capture_pid, self())

    on_exit(fn ->
      Application.put_env(:maxio, :storage_backend, prev_backend)

      if is_nil(prev_capture_pid) do
        Application.delete_env(:maxio, :object_live_show_capture_pid)
      else
        Application.put_env(:maxio, :object_live_show_capture_pid, prev_capture_pid)
      end
    end)

    {:ok, _b} = Maxio.Buckets.create("placed-show-bucket", "arn:aws:iam:::root")
    version_id = Maxio.Versioning.VersionId.generate()

    {:ok, _object} =
      Maxio.Objects.put_version_with_id("placed-show-bucket", "k.txt", version_id, %{
        size: 1,
        etag: "a",
        placement_set_id: 7,
        placement_pool_id: 0,
        placement_topology_hash: "topo-a"
      })

    {:ok, view, _html} = live(conn, ~p"/buckets/placed-show-bucket/object/k.txt")

    view
    |> element(~s([phx-value-vid="#{version_id}"]))
    |> render_click()

    assert_receive {:delete, "placed-show-bucket", "k.txt", ^version_id, opts}
    assert Keyword.fetch!(opts, :placement_set_id) == 7
    assert Keyword.fetch!(opts, :placement_pool_id) == 0
    assert Keyword.fetch!(opts, :placement_topology_hash) == "topo-a"
  end

  test "未启用 Object Lock 的 bucket 只显示禁用提示", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/buckets/show-bucket/object/doc.txt")

    assert has_element?(view, "#object-lock-panel")
    assert has_element?(view, "#object-lock-disabled")
    refute has_element?(view, "#legal-hold-form")
    refute has_element?(view, "#retention-form")
  end

  test "Object Detail 可更新当前版本 Legal Hold", %{conn: conn} do
    {:ok, object} = create_object_lock_object("lock-hold-bucket", "hold.txt")
    {:ok, view, _html} = live(conn, ~p"/buckets/lock-hold-bucket/object/hold.txt")

    assert has_element?(view, "#legal-hold-form")

    view
    |> form("#legal-hold-form",
      legal_hold: %{version_id: object.version_id, status: "ON"}
    )
    |> render_submit()

    assert {:ok, updated} =
             Maxio.Objects.get_version("lock-hold-bucket", "hold.txt", object.version_id)

    assert updated.object_lock_legal_hold == "ON"
    assert has_element?(view, "#legal-hold-current", "ON")

    view
    |> form("#legal-hold-form",
      legal_hold: %{version_id: object.version_id, status: "OFF"}
    )
    |> render_submit()

    assert {:ok, updated} =
             Maxio.Objects.get_version("lock-hold-bucket", "hold.txt", object.version_id)

    assert updated.object_lock_legal_hold == "OFF"
  end

  test "Object Detail 可更新当前版本 Retention", %{conn: conn} do
    {:ok, object} = create_object_lock_object("lock-retention-bucket", "retain.txt")
    {:ok, view, _html} = live(conn, ~p"/buckets/lock-retention-bucket/object/retain.txt")

    view
    |> form("#retention-form",
      retention: %{
        version_id: object.version_id,
        mode: "GOVERNANCE",
        retain_until: "2035-01-02T03:04:05Z"
      }
    )
    |> render_submit()

    assert {:ok, updated} =
             Maxio.Objects.get_version("lock-retention-bucket", "retain.txt", object.version_id)

    assert updated.object_lock_mode == "GOVERNANCE"
    assert DateTime.compare(updated.object_lock_retain_until, ~U[2035-01-02 03:04:05Z]) == :eq
    assert has_element?(view, "#retention-current", "GOVERNANCE")
  end

  test "Object Detail 可清除已过期 Retention", %{conn: conn} do
    {:ok, object} = create_object_lock_object("lock-retention-clear-bucket", "clear.txt")
    expired_until = ~U[2020-01-01 00:00:00Z]

    {:ok, _retained} =
      Maxio.Objects.put_object_lock(
        "lock-retention-clear-bucket",
        "clear.txt",
        object.version_id,
        %{
          object_lock_mode: "GOVERNANCE",
          object_lock_retain_until: expired_until
        }
      )

    {:ok, view, _html} = live(conn, ~p"/buckets/lock-retention-clear-bucket/object/clear.txt")

    assert has_element?(view, "#retention-clear-form")

    view
    |> form("#retention-clear-form", retention_clear: %{version_id: object.version_id})
    |> render_submit()

    assert {:ok, updated} =
             Maxio.Objects.get_version(
               "lock-retention-clear-bucket",
               "clear.txt",
               object.version_id
             )

    assert is_nil(updated.object_lock_mode)
    assert is_nil(updated.object_lock_retain_until)
    assert has_element?(view, "#retention-current", "未设置")
    refute has_element?(view, "#retention-clear-form")
  end

  test "Object Detail 可选择历史版本更新 Legal Hold", %{conn: conn} do
    {old, latest} = create_object_lock_versions("lock-history-hold-bucket", "hold.txt")
    {:ok, view, _html} = live(conn, ~p"/buckets/lock-history-hold-bucket/object/hold.txt")

    assert has_element?(view, "#object-lock-target-version", latest.version_id)

    view
    |> element(
      ~s(button[phx-click="select_object_lock_version"][phx-value-vid="#{old.version_id}"])
    )
    |> render_click()

    assert has_element?(view, "#object-lock-target-version", old.version_id)

    html =
      render_submit(view, "save_legal_hold", %{
        "legal_hold" => %{"version_id" => latest.version_id, "status" => "ON"}
      })

    assert html =~ "对象锁编辑版本已变化"

    assert {:ok, unchanged_old} =
             Maxio.Objects.get_version("lock-history-hold-bucket", "hold.txt", old.version_id)

    assert {:ok, unchanged_latest} =
             Maxio.Objects.get_version("lock-history-hold-bucket", "hold.txt", latest.version_id)

    assert is_nil(unchanged_old.object_lock_legal_hold)
    assert is_nil(unchanged_latest.object_lock_legal_hold)

    view
    |> form("#legal-hold-form",
      legal_hold: %{version_id: old.version_id, status: "ON"}
    )
    |> render_submit()

    assert {:ok, old_updated} =
             Maxio.Objects.get_version("lock-history-hold-bucket", "hold.txt", old.version_id)

    assert {:ok, latest_updated} =
             Maxio.Objects.get_version("lock-history-hold-bucket", "hold.txt", latest.version_id)

    assert old_updated.object_lock_legal_hold == "ON"
    assert is_nil(latest_updated.object_lock_legal_hold)
    assert has_element?(view, "#object-lock-target-version", old.version_id)
    assert has_element?(view, "#legal-hold-current", "ON")
  end

  test "Object Detail 可选择历史版本清除 Retention", %{conn: conn} do
    {old, latest} = create_object_lock_versions("lock-history-retention-bucket", "retain.txt")
    expired_until = ~U[2020-01-01 00:00:00Z]
    latest_until = ~U[2036-01-01 00:00:00Z]

    {:ok, _old_retained} =
      Maxio.Objects.put_object_lock(
        "lock-history-retention-bucket",
        "retain.txt",
        old.version_id,
        %{
          object_lock_mode: "GOVERNANCE",
          object_lock_retain_until: expired_until
        }
      )

    {:ok, _latest_retained} =
      Maxio.Objects.put_object_lock(
        "lock-history-retention-bucket",
        "retain.txt",
        latest.version_id,
        %{
          object_lock_mode: "GOVERNANCE",
          object_lock_retain_until: latest_until
        }
      )

    {:ok, view, _html} = live(conn, ~p"/buckets/lock-history-retention-bucket/object/retain.txt")

    assert has_element?(view, "#object-lock-target-version", latest.version_id)

    view
    |> element(
      ~s(button[phx-click="select_object_lock_version"][phx-value-vid="#{old.version_id}"])
    )
    |> render_click()

    assert has_element?(view, "#object-lock-target-version", old.version_id)
    assert has_element?(view, "#retention-clear-form")

    view
    |> form("#retention-clear-form", retention_clear: %{version_id: old.version_id})
    |> render_submit()

    assert {:ok, old_updated} =
             Maxio.Objects.get_version(
               "lock-history-retention-bucket",
               "retain.txt",
               old.version_id
             )

    assert {:ok, latest_updated} =
             Maxio.Objects.get_version(
               "lock-history-retention-bucket",
               "retain.txt",
               latest.version_id
             )

    assert is_nil(old_updated.object_lock_mode)
    assert is_nil(old_updated.object_lock_retain_until)
    assert latest_updated.object_lock_mode == "GOVERNANCE"
    assert DateTime.compare(latest_updated.object_lock_retain_until, latest_until) == :eq
    assert has_element?(view, "#object-lock-target-version", old.version_id)
    refute has_element?(view, "#retention-clear-form")
  end

  test "Object Detail 不为 delete marker 版本提供 Object Lock 编辑入口", %{conn: conn} do
    {:ok, _bucket} = Maxio.Buckets.create("lock-history-marker-bucket", "arn:aws:iam:::root")
    :ok = Maxio.S3.ObjectLock.enable_bucket!("lock-history-marker-bucket")

    {:ok, _old} =
      Maxio.Objects.put_version("lock-history-marker-bucket", "doc.txt", "Enabled", %{
        size: 1,
        etag: "old-marker"
      })

    {:ok, marker} =
      Maxio.Objects.insert_delete_marker("lock-history-marker-bucket", "doc.txt", "Enabled")

    {:ok, latest} =
      Maxio.Objects.put_version("lock-history-marker-bucket", "doc.txt", "Enabled", %{
        size: 2,
        etag: "latest-marker"
      })

    {:ok, view, _html} = live(conn, ~p"/buckets/lock-history-marker-bucket/object/doc.txt")

    refute has_element?(
             view,
             ~s(button[phx-click="select_object_lock_version"][phx-value-vid="#{marker.version_id}"])
           )

    render_click(view, "select_object_lock_version", %{"vid" => marker.version_id})

    assert has_element?(view, "#object-lock-target-version", latest.version_id)
  end

  test "Object Detail latest 为 delete marker 时选历史非 marker 版本编辑 Object Lock", %{
    conn: conn
  } do
    {:ok, _bucket} = Maxio.Buckets.create("lock-latest-marker-bucket", "arn:aws:iam:::root")
    :ok = Maxio.S3.ObjectLock.enable_bucket!("lock-latest-marker-bucket")

    {:ok, old} =
      Maxio.Objects.put_version("lock-latest-marker-bucket", "doc.txt", "Enabled", %{
        size: 1,
        etag: "old-latest-marker"
      })

    {:ok, marker} =
      Maxio.Objects.insert_delete_marker("lock-latest-marker-bucket", "doc.txt", "Enabled")

    {:ok, view, _html} = live(conn, ~p"/buckets/lock-latest-marker-bucket/object/doc.txt")

    assert has_element?(view, "#tags-unavailable")
    refute has_element?(view, "#tags-form")
    assert has_element?(view, "#object-lock-target-version", old.version_id)

    refute has_element?(
             view,
             ~s(button[phx-click="select_object_lock_version"][phx-value-vid="#{marker.version_id}"])
           )

    view
    |> form("#legal-hold-form",
      legal_hold: %{version_id: old.version_id, status: "ON"}
    )
    |> render_submit()

    assert {:ok, updated} =
             Maxio.Objects.get_version("lock-latest-marker-bucket", "doc.txt", old.version_id)

    assert updated.object_lock_legal_hold == "ON"
  end

  test "Object Detail 只有 delete marker 时不渲染 Object Lock 编辑表单", %{conn: conn} do
    {:ok, _bucket} = Maxio.Buckets.create("lock-only-marker-bucket", "arn:aws:iam:::root")
    :ok = Maxio.S3.ObjectLock.enable_bucket!("lock-only-marker-bucket")

    {:ok, _marker} =
      Maxio.Objects.insert_delete_marker("lock-only-marker-bucket", "doc.txt", "Enabled")

    {:ok, view, _html} = live(conn, ~p"/buckets/lock-only-marker-bucket/object/doc.txt")

    assert has_element?(view, "#tags-unavailable")
    refute has_element?(view, "#tags-form")
    assert has_element?(view, "#object-lock-no-target")
    assert has_element?(view, "#object-lock-target-version", "无可编辑对象版本")
    refute has_element?(view, "#legal-hold-form")
    refute has_element?(view, "#retention-form")
  end

  test "Retention 非法日期不写入对象锁元数据", %{conn: conn} do
    {:ok, object} = create_object_lock_object("lock-retention-invalid-bucket", "bad.txt")
    {:ok, view, _html} = live(conn, ~p"/buckets/lock-retention-invalid-bucket/object/bad.txt")

    html =
      view
      |> form("#retention-form",
        retention: %{
          version_id: object.version_id,
          mode: "GOVERNANCE",
          retain_until: "not-a-date"
        }
      )
      |> render_submit()

    assert html =~ "Retention 需要"

    assert {:ok, updated} =
             Maxio.Objects.get_version(
               "lock-retention-invalid-bucket",
               "bad.txt",
               object.version_id
             )

    assert is_nil(updated.object_lock_mode)
    assert is_nil(updated.object_lock_retain_until)
  end

  test "Console 允许有效 COMPLIANCE retention 同 mode 延长", %{conn: conn} do
    {:ok, object} = create_object_lock_object("lock-compliance-bucket", "compliance.txt")
    retain_until = ~U[2035-01-01 00:00:00Z]
    extended_until = ~U[2036-01-01 00:00:00Z]

    {:ok, _locked} =
      Maxio.Objects.put_object_lock(
        "lock-compliance-bucket",
        "compliance.txt",
        object.version_id,
        %{
          object_lock_mode: "COMPLIANCE",
          object_lock_retain_until: retain_until
        }
      )

    {:ok, view, _html} = live(conn, ~p"/buckets/lock-compliance-bucket/object/compliance.txt")

    html =
      view
      |> form("#retention-form",
        retention: %{
          version_id: object.version_id,
          mode: "COMPLIANCE",
          retain_until: "2036-01-01T00:00:00Z"
        }
      )
      |> render_submit()

    assert html =~ "Retention 已更新"

    assert {:ok, updated} =
             Maxio.Objects.get_version(
               "lock-compliance-bucket",
               "compliance.txt",
               object.version_id
             )

    assert updated.object_lock_mode == "COMPLIANCE"
    assert DateTime.compare(updated.object_lock_retain_until, extended_until) == :eq
  end

  test "Console 允许有效 GOVERNANCE retention 同 mode 延长", %{conn: conn} do
    {:ok, object} = create_object_lock_object("lock-governance-bucket", "governance.txt")
    retain_until = ~U[2035-02-01 00:00:00Z]
    extended_until = ~U[2036-02-01 00:00:00Z]

    {:ok, _locked} =
      Maxio.Objects.put_object_lock(
        "lock-governance-bucket",
        "governance.txt",
        object.version_id,
        %{
          object_lock_mode: "GOVERNANCE",
          object_lock_retain_until: retain_until
        }
      )

    {:ok, view, _html} = live(conn, ~p"/buckets/lock-governance-bucket/object/governance.txt")

    html =
      view
      |> form("#retention-form",
        retention: %{
          version_id: object.version_id,
          mode: "GOVERNANCE",
          retain_until: "2036-02-01T00:00:00Z"
        }
      )
      |> render_submit()

    assert html =~ "Retention 已更新"

    assert {:ok, updated} =
             Maxio.Objects.get_version(
               "lock-governance-bucket",
               "governance.txt",
               object.version_id
             )

    assert updated.object_lock_mode == "GOVERNANCE"
    assert DateTime.compare(updated.object_lock_retain_until, extended_until) == :eq
  end

  test "Console 不绕过有效 GOVERNANCE retention 清除", %{conn: conn} do
    {:ok, object} = create_object_lock_object("lock-governance-clear-bucket", "governance.txt")
    retain_until = ~U[2035-02-01 00:00:00Z]

    {:ok, _locked} =
      Maxio.Objects.put_object_lock(
        "lock-governance-clear-bucket",
        "governance.txt",
        object.version_id,
        %{
          object_lock_mode: "GOVERNANCE",
          object_lock_retain_until: retain_until
        }
      )

    {:ok, view, _html} =
      live(conn, ~p"/buckets/lock-governance-clear-bucket/object/governance.txt")

    html =
      view
      |> form("#retention-clear-form", retention_clear: %{version_id: object.version_id})
      |> render_submit()

    assert html =~ "Console 不允许修改 Retention"

    assert {:ok, updated} =
             Maxio.Objects.get_version(
               "lock-governance-clear-bucket",
               "governance.txt",
               object.version_id
             )

    assert updated.object_lock_mode == "GOVERNANCE"
    assert DateTime.compare(updated.object_lock_retain_until, retain_until) == :eq
  end

  test "Console 不绕过有效 COMPLIANCE retention 清除", %{conn: conn} do
    {:ok, object} = create_object_lock_object("lock-compliance-clear-bucket", "compliance.txt")
    retain_until = ~U[2035-01-01 00:00:00Z]

    {:ok, _locked} =
      Maxio.Objects.put_object_lock(
        "lock-compliance-clear-bucket",
        "compliance.txt",
        object.version_id,
        %{
          object_lock_mode: "COMPLIANCE",
          object_lock_retain_until: retain_until
        }
      )

    {:ok, view, _html} =
      live(conn, ~p"/buckets/lock-compliance-clear-bucket/object/compliance.txt")

    html =
      view
      |> form("#retention-clear-form", retention_clear: %{version_id: object.version_id})
      |> render_submit()

    assert html =~ "Console 不允许修改 Retention"

    assert {:ok, updated} =
             Maxio.Objects.get_version(
               "lock-compliance-clear-bucket",
               "compliance.txt",
               object.version_id
             )

    assert updated.object_lock_mode == "COMPLIANCE"
    assert DateTime.compare(updated.object_lock_retain_until, retain_until) == :eq
  end

  test "Legal Hold ON 与过期 Retention 独立且允许清除 Retention", %{conn: conn} do
    {:ok, object} = create_object_lock_object("lock-hold-clear-bucket", "held.txt")
    expired_until = ~U[2020-01-01 00:00:00Z]

    {:ok, _held} =
      Maxio.Objects.put_object_lock(
        "lock-hold-clear-bucket",
        "held.txt",
        object.version_id,
        %{
          object_lock_mode: "GOVERNANCE",
          object_lock_retain_until: expired_until,
          object_lock_legal_hold: "ON"
        }
      )

    {:ok, view, _html} = live(conn, ~p"/buckets/lock-hold-clear-bucket/object/held.txt")

    html =
      view
      |> form("#retention-clear-form", retention_clear: %{version_id: object.version_id})
      |> render_submit()

    assert html =~ "Retention 已清除"

    assert {:ok, updated} =
             Maxio.Objects.get_version(
               "lock-hold-clear-bucket",
               "held.txt",
               object.version_id
             )

    assert is_nil(updated.object_lock_mode)
    assert is_nil(updated.object_lock_retain_until)
    assert updated.object_lock_legal_hold == "ON"
  end

  test "Legal Hold ON 与 Retention 独立且允许新增 Retention", %{conn: conn} do
    {:ok, object} = create_object_lock_object("lock-hold-retention-bucket", "held.txt")
    retain_until = ~U[2035-03-01 00:00:00Z]

    {:ok, _held} =
      Maxio.Objects.put_object_lock(
        "lock-hold-retention-bucket",
        "held.txt",
        object.version_id,
        %{object_lock_legal_hold: "ON"}
      )

    {:ok, view, _html} = live(conn, ~p"/buckets/lock-hold-retention-bucket/object/held.txt")

    html =
      view
      |> form("#retention-form",
        retention: %{
          version_id: object.version_id,
          mode: "GOVERNANCE",
          retain_until: "2035-03-01T00:00:00Z"
        }
      )
      |> render_submit()

    assert html =~ "Retention 已更新"

    assert {:ok, updated} =
             Maxio.Objects.get_version(
               "lock-hold-retention-bucket",
               "held.txt",
               object.version_id
             )

    assert updated.object_lock_legal_hold == "ON"
    assert updated.object_lock_mode == "GOVERNANCE"
    assert DateTime.compare(updated.object_lock_retain_until, retain_until) == :eq
  end

  defp create_object_lock_object(bucket, key) do
    {:ok, _bucket} = Maxio.Buckets.create(bucket, "arn:aws:iam:::root")
    :ok = Maxio.S3.ObjectLock.enable_bucket!(bucket)
    Maxio.Objects.put_version(bucket, key, "Enabled", %{size: 1, etag: "etag-#{bucket}"})
  end

  defp create_object_lock_versions(bucket, key) do
    {:ok, _bucket} = Maxio.Buckets.create(bucket, "arn:aws:iam:::root")
    :ok = Maxio.S3.ObjectLock.enable_bucket!(bucket)

    {:ok, old} =
      Maxio.Objects.put_version(bucket, key, "Enabled", %{size: 1, etag: "old-#{bucket}"})

    {:ok, latest} =
      Maxio.Objects.put_version(bucket, key, "Enabled", %{size: 2, etag: "latest-#{bucket}"})

    {old, latest}
  end

  defp create_preview_object(bucket, key, attrs) do
    {:ok, _bucket} = Maxio.Buckets.create(bucket, "arn:aws:iam:::root")
    Maxio.Objects.put_version_with_id(bucket, key, "null", attrs)
  end

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

  defp presign_url_from_html(html) do
    [_, url] = Regex.run(~r/<textarea[^>]*id="presign-url"[^>]*>(.*?)<\/textarea>/s, html)

    url
    |> String.trim()
    |> String.replace("&amp;", "&")
  end

  defp post_object_html_from_html(html) do
    [_, snippet] =
      Regex.run(~r/<textarea[^>]*id="post-object-html"[^>]*>(.*?)<\/textarea>/s, html)

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

  defp post_object_form_conn(bucket, fields, file_body) do
    boundary = "----maxio-console-post-#{System.unique_integer([:positive])}"
    body = multipart_body(boundary, fields, file_body)

    SigV4Request.anon_conn(:post, "/#{bucket}",
      body: body,
      headers: [
        {"content-type", "multipart/form-data; boundary=#{boundary}"},
        {"content-length", Integer.to_string(byte_size(body))}
      ]
    )
  end

  defp multipart_body(boundary, fields, file_body) do
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
      "\r\ncontent-disposition: form-data; name=\"file\"; filename=\"console-upload.txt\"\r\n",
      "content-type: application/octet-stream\r\n\r\n",
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

  defp sha256_b64(body), do: :crypto.hash(:sha256, body) |> Base.encode64()
  defp md5_b64(body), do: :crypto.hash(:md5, body) |> Base.encode64()

  defp sse_c_headers(customer_key) do
    [
      {"x-amz-server-side-encryption-customer-algorithm", "AES256"},
      {"x-amz-server-side-encryption-customer-key", Base.encode64(customer_key)},
      {"x-amz-server-side-encryption-customer-key-md5",
       :crypto.hash(:md5, customer_key) |> Base.encode64()}
    ]
  end
end
