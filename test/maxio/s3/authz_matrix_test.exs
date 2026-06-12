defmodule Maxio.S3.AuthzMatrixTest do
  use Maxio.DataCase, async: false

  alias Maxio.Test.SigV4Request
  alias Maxio.Auth.CredentialStore
  alias Maxio.S3.Endpoint

  @data_dir Path.join(System.tmp_dir!(), "maxio_authz_matrix_test")
  @alice_ak "AKIAALICEKEY00000001"
  @alice_secret "alicealicealicealicealicealice12"
  @alice_arn "arn:aws:iam:::user/" <> @alice_ak

  setup do
    File.rm_rf(@data_dir)
    File.mkdir_p!(@data_dir)
    prev = Application.get_env(:maxio, :s3)
    Application.put_env(:maxio, :s3, Keyword.put(prev, :data_dir, @data_dir))

    # 注入非 owner 认证 principal（MemoryStore）。
    :ok =
      CredentialStore.put_access_key(%{
        access_key: @alice_ak,
        secret_key: @alice_secret,
        principal: %{
          type: :iam_user,
          access_key: @alice_ak,
          arn: @alice_arn,
          tags: %{"team" => "platform", "department" => "storage"}
        }
      })

    on_exit(fn ->
      Application.put_env(:maxio, :s3, prev)
      File.rm_rf(@data_dir)
    end)

    :ok
  end

  defp call(conn), do: Endpoint.call(conn, Endpoint.init([]))

  defp put_policy(bucket, policy) do
    SigV4Request.signed_conn(:put, "/#{bucket}",
      query: %{"policy" => ""},
      body: policy,
      headers: [{"content-type", "application/json"}]
    )
    |> call()
  end

  defp alice(method, path, opts) do
    SigV4Request.signed_conn(
      method,
      path,
      Keyword.merge([access_key: @alice_ak, secret: @alice_secret], opts)
    )
  end

  test "认证非 owner 无 policy → 403（认证 ≠ 授权）" do
    # root 建桶（owner=root）
    SigV4Request.signed_conn(:put, "/mba") |> call()
    SigV4Request.signed_conn(:put, "/mba/o.txt", body: "x") |> call()

    get = alice(:get, "/mba/o.txt", []) |> call()
    assert get.status == 403
    assert get.resp_body =~ "AccessDenied"
  end

  test "policy 命名该 principal arn → 放行" do
    SigV4Request.signed_conn(:put, "/mb2") |> call()
    SigV4Request.signed_conn(:put, "/mb2/o.txt", body: "yes") |> call()

    pol =
      ~s({"Statement":{"Effect":"Allow","Principal":{"AWS":"#{@alice_arn}"},"Action":"s3:GetObject","Resource":"arn:aws:s3:::mb2/*"}})

    SigV4Request.signed_conn(:put, "/mb2",
      query: %{"policy" => ""},
      body: pol,
      headers: [{"content-type", "application/json"}]
    )
    |> call()

    get = alice(:get, "/mb2/o.txt", []) |> call()
    assert get.status == 200
    assert get.resp_body == "yes"
  end

  test "policy StringLike s3:prefix 限制 ListBucket" do
    SigV4Request.signed_conn(:put, "/mb3") |> call()

    pol =
      ~s({"Statement":{"Effect":"Allow","Principal":{"AWS":"#{@alice_arn}"},"Action":"s3:ListBucket","Resource":"arn:aws:s3:::mb3","Condition":{"StringLike":{"s3:prefix":["home/*"]}}}})

    SigV4Request.signed_conn(:put, "/mb3",
      query: %{"policy" => ""},
      body: pol,
      headers: [{"content-type", "application/json"}]
    )
    |> call()

    ok = alice(:get, "/mb3", query: %{"prefix" => "home/alice/"}) |> call()
    assert ok.status == 200

    denied = alice(:get, "/mb3", query: %{"prefix" => "secret/"}) |> call()
    assert denied.status == 403
  end

  test "policy ForAnyValue:StringLike s3:prefix 在真实 ListBucket 请求中生效" do
    SigV4Request.signed_conn(:put, "/mb3set") |> call()

    pol =
      ~s({"Statement":{"Effect":"Allow","Principal":{"AWS":"#{@alice_arn}"},"Action":"s3:ListBucket","Resource":"arn:aws:s3:::mb3set","Condition":{"ForAnyValue:StringLike":{"s3:prefix":["home/*","public/*"]}}}})

    put_policy("mb3set", pol)

    ok = alice(:get, "/mb3set", query: %{"prefix" => "public/readme/"}) |> call()
    assert ok.status == 200

    denied = alice(:get, "/mb3set", query: %{"prefix" => "secret/"}) |> call()
    assert denied.status == 403
  end

  test "policy ForAnyValue:StringLike 不把空 prefix 当作通配命中" do
    SigV4Request.signed_conn(:put, "/mb3empty") |> call()

    pol =
      ~s({"Statement":{"Effect":"Allow","Principal":{"AWS":"#{@alice_arn}"},"Action":"s3:ListBucket","Resource":"arn:aws:s3:::mb3empty","Condition":{"ForAnyValue:StringLike":{"s3:prefix":"*"}}}})

    put_policy("mb3empty", pol)

    ok = alice(:get, "/mb3empty", query: %{"prefix" => "home/"}) |> call()
    assert ok.status == 200

    denied = alice(:get, "/mb3empty", query: %{"prefix" => ""}) |> call()
    assert denied.status == 403
  end

  test "policy ForAllValues:StringLike 可配 Null:false 阻断空 prefix" do
    SigV4Request.signed_conn(:put, "/mb3allnull") |> call()

    pol =
      ~s({"Statement":{"Effect":"Allow","Principal":{"AWS":"#{@alice_arn}"},"Action":"s3:ListBucket","Resource":"arn:aws:s3:::mb3allnull","Condition":{"ForAllValues:StringLike":{"s3:prefix":"*"},"Null":{"s3:prefix":"false"}}}})

    put_policy("mb3allnull", pol)

    ok = alice(:get, "/mb3allnull", query: %{"prefix" => "home/"}) |> call()
    assert ok.status == 200

    denied = alice(:get, "/mb3allnull", query: %{"prefix" => ""}) |> call()
    assert denied.status == 403
  end

  test "policy NotAction 在真实请求中放行未列动作并排除列出的动作" do
    SigV4Request.signed_conn(:put, "/mb-notaction") |> call()

    pol =
      ~s({"Statement":{"Effect":"Allow","Principal":{"AWS":"#{@alice_arn}"},"NotAction":"s3:DeleteBucket","Resource":"arn:aws:s3:::mb-notaction"}})

    put_policy("mb-notaction", pol)

    list = alice(:get, "/mb-notaction", []) |> call()
    assert list.status == 200

    delete = alice(:delete, "/mb-notaction", []) |> call()
    assert delete.status == 403
  end

  test "policy NotResource 在真实 GetObject 请求中排除指定前缀" do
    SigV4Request.signed_conn(:put, "/mb-notresource") |> call()
    SigV4Request.signed_conn(:put, "/mb-notresource/public.txt", body: "ok") |> call()
    SigV4Request.signed_conn(:put, "/mb-notresource/private/secret.txt", body: "no") |> call()

    pol =
      ~s({"Statement":{"Effect":"Allow","Principal":{"AWS":"#{@alice_arn}"},"Action":"s3:GetObject","NotResource":"arn:aws:s3:::mb-notresource/private/*"}})

    put_policy("mb-notresource", pol)

    allowed = alice(:get, "/mb-notresource/public.txt", []) |> call()
    assert allowed.status == 200
    assert allowed.resp_body == "ok"

    denied = alice(:get, "/mb-notresource/private/secret.txt", []) |> call()
    assert denied.status == 403
  end

  test "policy NotPrincipal Deny 在真实请求中拒绝除指定 principal 外的请求者" do
    SigV4Request.signed_conn(:put, "/mb-notprincipal") |> call()
    SigV4Request.signed_conn(:put, "/mb-notprincipal/o.txt", body: "guarded") |> call()

    pol =
      ~s({"Statement":[{"Effect":"Allow","Principal":"*","Action":"s3:GetObject","Resource":"arn:aws:s3:::mb-notprincipal/*"},{"Effect":"Deny","NotPrincipal":{"AWS":"#{@alice_arn}"},"Action":"s3:GetObject","Resource":"arn:aws:s3:::mb-notprincipal/*"}]})

    put_policy("mb-notprincipal", pol)

    allowed = alice(:get, "/mb-notprincipal/o.txt", []) |> call()
    assert allowed.status == 200
    assert allowed.resp_body == "guarded"

    denied = SigV4Request.anon_conn(:get, "/mb-notprincipal/o.txt") |> call()
    assert denied.status == 403
  end

  test "policy NumericLessThanEquals s3:max-keys 限制 ListBucket" do
    SigV4Request.signed_conn(:put, "/mb5") |> call()

    pol =
      ~s({"Statement":{"Effect":"Allow","Principal":{"AWS":"#{@alice_arn}"},"Action":"s3:ListBucket","Resource":"arn:aws:s3:::mb5","Condition":{"NumericLessThanEquals":{"s3:max-keys":"2"}}}})

    put_policy("mb5", pol)

    ok = alice(:get, "/mb5", query: %{"max-keys" => "2"}) |> call()
    assert ok.status == 200

    too_many = alice(:get, "/mb5", query: %{"max-keys" => "3"}) |> call()
    assert too_many.status == 403

    missing = alice(:get, "/mb5", []) |> call()
    assert missing.status == 403
  end

  test "s3:max-keys 使用 handler 同源默认值和夹取值" do
    SigV4Request.signed_conn(:put, "/mb6") |> call()

    allow_clamped =
      ~s({"Statement":{"Effect":"Allow","Principal":{"AWS":"#{@alice_arn}"},"Action":["s3:ListBucket","s3:ListBucketVersions"],"Resource":"arn:aws:s3:::mb6","Condition":{"NumericLessThanEquals":{"s3:max-keys":"1000"}}}})

    put_policy("mb6", allow_clamped)

    assert (alice(:get, "/mb6", []) |> call()).status == 200
    assert (alice(:get, "/mb6", query: %{"max-keys" => "5000"}) |> call()).status == 200

    assert (alice(:get, "/mb6", query: %{"versions" => "", "max-keys" => "5000"})
            |> call()).status == 200

    SigV4Request.signed_conn(:put, "/mb6deny") |> call()

    deny_default =
      ~s({"Statement":[{"Effect":"Allow","Principal":{"AWS":"#{@alice_arn}"},"Action":"s3:ListBucket","Resource":"arn:aws:s3:::mb6deny"},{"Effect":"Deny","Principal":{"AWS":"#{@alice_arn}"},"Action":"s3:ListBucket","Resource":"arn:aws:s3:::mb6deny","Condition":{"NumericGreaterThan":{"s3:max-keys":"500"}}}]})

    put_policy("mb6deny", deny_default)

    assert (alice(:get, "/mb6deny", query: %{"max-keys" => "500"}) |> call()).status == 200
    assert (alice(:get, "/mb6deny", []) |> call()).status == 403
    assert (alice(:get, "/mb6deny", query: %{"max-keys" => "bad"}) |> call()).status == 403
  end

  test "policy 可用 s3:x-amz-acl 阻止 public ACL 写入" do
    SigV4Request.signed_conn(:put, "/mb7") |> call()

    pol =
      ~s({"Statement":[{"Effect":"Allow","Principal":{"AWS":"#{@alice_arn}"},"Action":"s3:PutObject","Resource":"arn:aws:s3:::mb7/*"},{"Effect":"Deny","Principal":{"AWS":"#{@alice_arn}"},"Action":"s3:PutObject","Resource":"arn:aws:s3:::mb7/*","Condition":{"StringEquals":{"s3:x-amz-acl":"public-read"}}}]})

    put_policy("mb7", pol)

    assert (alice(:put, "/mb7/private.txt", body: "ok") |> call()).status == 200

    denied =
      alice(:put, "/mb7/public.txt",
        body: "no",
        headers: [{"x-amz-acl", "public-read"}]
      )
      |> call()

    assert denied.status == 403
  end

  test "policy Null s3:x-amz-server-side-encryption 要求显式 SSE header" do
    SigV4Request.signed_conn(:put, "/mb8") |> call()

    pol =
      ~s({"Statement":[{"Effect":"Allow","Principal":{"AWS":"#{@alice_arn}"},"Action":"s3:PutObject","Resource":"arn:aws:s3:::mb8/*"},{"Effect":"Deny","Principal":{"AWS":"#{@alice_arn}"},"Action":"s3:PutObject","Resource":"arn:aws:s3:::mb8/*","Condition":{"Null":{"s3:x-amz-server-side-encryption":"true"}}}]})

    put_policy("mb8", pol)

    assert (alice(:put, "/mb8/plain.txt", body: "no") |> call()).status == 403

    encrypted =
      alice(:put, "/mb8/encrypted.txt",
        body: "ok",
        headers: [{"x-amz-server-side-encryption", "AES256"}]
      )
      |> call()

    assert encrypted.status == 200
  end

  test "policy 可用 s3:x-amz-copy-source 约束 CopyObject 来源" do
    SigV4Request.signed_conn(:put, "/mb9") |> call()
    SigV4Request.signed_conn(:put, "/mb9/allowed-src.txt", body: "allowed") |> call()
    SigV4Request.signed_conn(:put, "/mb9/blocked-src.txt", body: "blocked") |> call()

    pol =
      ~s({"Statement":[{"Effect":"Allow","Principal":{"AWS":"#{@alice_arn}"},"Action":["s3:PutObject","s3:GetObject"],"Resource":"arn:aws:s3:::mb9/*"},{"Effect":"Deny","Principal":{"AWS":"#{@alice_arn}"},"Action":"s3:PutObject","Resource":"arn:aws:s3:::mb9/*","Condition":{"StringNotLike":{"s3:x-amz-copy-source":"/mb9/allowed-*"}}}]})

    put_policy("mb9", pol)

    allowed =
      alice(:put, "/mb9/copy-ok.txt", headers: [{"x-amz-copy-source", "/mb9/allowed-src.txt"}])
      |> call()

    assert allowed.status == 200

    denied =
      alice(:put, "/mb9/copy-denied.txt",
        headers: [{"x-amz-copy-source", "/mb9/blocked-src.txt"}]
      )
      |> call()

    assert denied.status == 403
  end

  test "policy ArnEquals aws:PrincipalArn 在真实请求中生效" do
    SigV4Request.signed_conn(:put, "/mb10") |> call()
    SigV4Request.signed_conn(:put, "/mb10/o.txt", body: "public except alice") |> call()

    pol =
      ~s({"Statement":[{"Effect":"Allow","Principal":"*","Action":"s3:GetObject","Resource":"arn:aws:s3:::mb10/*"},{"Effect":"Deny","Principal":"*","Action":"s3:GetObject","Resource":"arn:aws:s3:::mb10/*","Condition":{"ArnEquals":{"aws:PrincipalArn":"#{@alice_arn}"}}}]})

    put_policy("mb10", pol)

    assert (alice(:get, "/mb10/o.txt", []) |> call()).status == 403

    anon = SigV4Request.anon_conn(:get, "/mb10/o.txt") |> call()
    assert anon.status == 200
  end

  test "policy variables and conditions can use aws:PrincipalTag keys" do
    SigV4Request.signed_conn(:put, "/mb-principal-tag") |> call()

    SigV4Request.signed_conn(:put, "/mb-principal-tag/platform/read.txt", body: "team")
    |> call()

    SigV4Request.signed_conn(:put, "/mb-principal-tag/other/read.txt", body: "other")
    |> call()

    pol =
      ~s({"Version":"2012-10-17","Statement":{"Effect":"Allow","Principal":{"AWS":"#{@alice_arn}"},"Action":"s3:GetObject","Resource":"arn:aws:s3:::mb-principal-tag/${aws:PrincipalTag/team}/*","Condition":{"StringEquals":{"aws:PrincipalTag/department":"storage"}}}})

    put_policy("mb-principal-tag", pol)

    allowed = alice(:get, "/mb-principal-tag/platform/read.txt", []) |> call()
    assert allowed.status == 200
    assert allowed.resp_body == "team"

    denied = alice(:get, "/mb-principal-tag/other/read.txt", []) |> call()
    assert denied.status == 403
  end

  test "bucket resource tag condition keys gate bucket actions" do
    SigV4Request.signed_conn(:put, "/mb-bucket-tag") |> call()

    tagging =
      ~s(<Tagging><TagSet><Tag><Key>project</Key><Value>alpha</Value></Tag></TagSet></Tagging>)

    assert (SigV4Request.signed_conn(:put, "/mb-bucket-tag",
              query: %{"tagging" => ""},
              body: tagging
            )
            |> call()).status == 204

    pol =
      ~s({"Version":"2012-10-17","Statement":{"Effect":"Allow","Principal":{"AWS":"#{@alice_arn}"},"Action":"s3:ListBucket","Resource":"arn:aws:s3:::mb-bucket-tag","Condition":{"StringEquals":{"s3:BucketTag/project":"alpha","aws:ResourceTag/project":"alpha"}}}})

    put_policy("mb-bucket-tag", pol)

    allowed = alice(:get, "/mb-bucket-tag", []) |> call()
    assert allowed.status == 200

    SigV4Request.signed_conn(:put, "/mb-bucket-tag-denied") |> call()

    put_policy(
      "mb-bucket-tag-denied",
      String.replace(pol, "mb-bucket-tag", "mb-bucket-tag-denied")
    )

    denied = alice(:get, "/mb-bucket-tag-denied", []) |> call()
    assert denied.status == 403
  end

  test "existing object tags gate reads but not put or delete object grants" do
    SigV4Request.signed_conn(:put, "/mb-existing-tag") |> call()

    SigV4Request.signed_conn(:put, "/mb-existing-tag/prod.txt",
      body: "prod",
      headers: [{"x-amz-tagging", "env=prod"}]
    )
    |> call()

    SigV4Request.signed_conn(:put, "/mb-existing-tag/dev.txt",
      body: "dev",
      headers: [{"x-amz-tagging", "env=dev"}]
    )
    |> call()

    read_policy =
      ~s({"Version":"2012-10-17","Statement":{"Effect":"Allow","Principal":{"AWS":"#{@alice_arn}"},"Action":"s3:GetObject","Resource":"arn:aws:s3:::mb-existing-tag/*","Condition":{"StringEquals":{"s3:ExistingObjectTag/env":"prod","aws:ResourceTag/env":"prod"}}}})

    put_policy("mb-existing-tag", read_policy)

    allowed = alice(:get, "/mb-existing-tag/prod.txt", []) |> call()
    assert allowed.status == 200
    assert allowed.resp_body == "prod"

    denied = alice(:get, "/mb-existing-tag/dev.txt", []) |> call()
    assert denied.status == 403

    write_policy =
      ~s({"Version":"2012-10-17","Statement":{"Effect":"Allow","Principal":{"AWS":"#{@alice_arn}"},"Action":["s3:PutObject","s3:DeleteObject"],"Resource":"arn:aws:s3:::mb-existing-tag/*","Condition":{"StringEquals":{"s3:ExistingObjectTag/env":"prod"}}}})

    put_policy("mb-existing-tag", write_policy)

    denied_put = alice(:put, "/mb-existing-tag/prod.txt", body: "overwrite") |> call()
    assert denied_put.status == 403

    denied_delete = alice(:delete, "/mb-existing-tag/prod.txt", []) |> call()
    assert denied_delete.status == 403
  end

  test "PutObject exposes request object tag condition keys from x-amz-tagging" do
    SigV4Request.signed_conn(:put, "/mb-request-tag") |> call()

    pol =
      ~s({"Version":"2012-10-17","Statement":{"Effect":"Allow","Principal":{"AWS":"#{@alice_arn}"},"Action":"s3:PutObject","Resource":"arn:aws:s3:::mb-request-tag/*","Condition":{"StringEquals":{"s3:RequestObjectTag/department":"finance","aws:RequestTag/department":"finance"},"ForAllValues:StringEquals":{"s3:RequestObjectTagKeys":["department","class"],"aws:TagKeys":["department","class"]},"ForAnyValue:StringEquals":{"s3:RequestObjectTagKeys":"department","aws:TagKeys":"department"}}}})

    put_policy("mb-request-tag", pol)

    allowed =
      alice(:put, "/mb-request-tag/ok.txt",
        body: "ok",
        headers: [{"x-amz-tagging", "department=finance&class=confidential"}]
      )
      |> call()

    assert allowed.status == 200

    wrong_value =
      alice(:put, "/mb-request-tag/wrong-value.txt",
        body: "no",
        headers: [{"x-amz-tagging", "department=engineering"}]
      )
      |> call()

    assert wrong_value.status == 403

    wrong_key =
      alice(:put, "/mb-request-tag/wrong-key.txt",
        body: "no",
        headers: [{"x-amz-tagging", "department=finance&secret=yes"}]
      )
      |> call()

    assert wrong_key.status == 403
  end

  test "PutObjectTagging exposes request object tag condition keys from XML body" do
    SigV4Request.signed_conn(:put, "/mb-tagging-body-request") |> call()

    SigV4Request.signed_conn(:put, "/mb-tagging-body-request/object.txt", body: "tag me")
    |> call()

    pol =
      ~s({"Version":"2012-10-17","Statement":{"Effect":"Allow","Principal":{"AWS":"#{@alice_arn}"},"Action":"s3:PutObjectTagging","Resource":"arn:aws:s3:::mb-tagging-body-request/*","Condition":{"StringEquals":{"s3:RequestObjectTag/department":"finance","aws:RequestTag/department":"finance"},"ForAllValues:StringEquals":{"s3:RequestObjectTagKeys":["department","class"],"aws:TagKeys":["department","class"]},"ForAnyValue:StringEquals":{"s3:RequestObjectTagKeys":"department","aws:TagKeys":"department"}}}})

    put_policy("mb-tagging-body-request", pol)

    ok_body =
      ~s(<Tagging><TagSet><Tag><Key>department</Key><Value>finance</Value></Tag><Tag><Key>class</Key><Value>confidential</Value></Tag></TagSet></Tagging>)

    allowed =
      alice(:put, "/mb-tagging-body-request/object.txt",
        query: %{"tagging" => ""},
        body: ok_body
      )
      |> call()

    assert allowed.status == 200

    get =
      SigV4Request.signed_conn(:get, "/mb-tagging-body-request/object.txt",
        query: %{"tagging" => ""}
      )
      |> call()

    assert get.status == 200
    assert get.resp_body =~ "<Key>department</Key>"
    assert get.resp_body =~ "<Value>finance</Value>"

    wrong_value_body =
      ~s(<Tagging><TagSet><Tag><Key>department</Key><Value>engineering</Value></Tag><Tag><Key>class</Key><Value>confidential</Value></Tag></TagSet></Tagging>)

    wrong_value =
      alice(:put, "/mb-tagging-body-request/object.txt",
        query: %{"tagging" => ""},
        body: wrong_value_body
      )
      |> call()

    assert wrong_value.status == 403

    wrong_key_body =
      ~s(<Tagging><TagSet><Tag><Key>department</Key><Value>finance</Value></Tag><Tag><Key>secret</Key><Value>yes</Value></Tag></TagSet></Tagging>)

    wrong_key =
      alice(:put, "/mb-tagging-body-request/object.txt",
        query: %{"tagging" => ""},
        body: wrong_key_body
      )
      |> call()

    assert wrong_key.status == 403
  end

  test "CopyObject uses source existing tags for source auth and REPLACE tags for target auth" do
    SigV4Request.signed_conn(:put, "/mb-copy-tag") |> call()

    SigV4Request.signed_conn(:put, "/mb-copy-tag/src.txt",
      body: "src",
      headers: [{"x-amz-tagging", "env=prod"}]
    )
    |> call()

    pol =
      ~s({"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"AWS":"#{@alice_arn}"},"Action":"s3:GetObject","Resource":"arn:aws:s3:::mb-copy-tag/src.txt","Condition":{"StringEquals":{"s3:ExistingObjectTag/env":"prod"}}},{"Effect":"Allow","Principal":{"AWS":"#{@alice_arn}"},"Action":"s3:PutObject","Resource":"arn:aws:s3:::mb-copy-tag/*","Condition":{"StringEquals":{"s3:RequestObjectTag/project":"copy"}}}]})

    put_policy("mb-copy-tag", pol)

    allowed =
      alice(:put, "/mb-copy-tag/dst.txt",
        headers: [
          {"x-amz-copy-source", "/mb-copy-tag/src.txt"},
          {"x-amz-tagging-directive", "REPLACE"},
          {"x-amz-tagging", "project=copy"}
        ]
      )
      |> call()

    assert allowed.status == 200

    wrong_tag =
      alice(:put, "/mb-copy-tag/dst-wrong.txt",
        headers: [
          {"x-amz-copy-source", "/mb-copy-tag/src.txt"},
          {"x-amz-tagging-directive", "REPLACE"},
          {"x-amz-tagging", "project=other"}
        ]
      )
      |> call()

    assert wrong_tag.status == 403

    copied_tags_not_request_tags =
      alice(:put, "/mb-copy-tag/dst-copy-directive.txt",
        headers: [
          {"x-amz-copy-source", "/mb-copy-tag/src.txt"},
          {"x-amz-tagging", "project=copy"}
        ]
      )
      |> call()

    assert copied_tags_not_request_tags.status == 403
  end

  test "CopyObject source auth does not inherit target request tag context" do
    SigV4Request.signed_conn(:put, "/mb-src-request-leak") |> call()
    SigV4Request.signed_conn(:put, "/mb-dst-request-leak") |> call()
    SigV4Request.signed_conn(:put, "/mb-src-request-leak/src.txt", body: "src") |> call()

    source_policy =
      ~s({"Version":"2012-10-17","Statement":{"Effect":"Allow","Principal":{"AWS":"#{@alice_arn}"},"Action":"s3:GetObject","Resource":"arn:aws:s3:::mb-src-request-leak/*","Condition":{"StringEquals":{"s3:RequestObjectTag/project":"copy"}}}})

    target_policy =
      ~s({"Version":"2012-10-17","Statement":{"Effect":"Allow","Principal":{"AWS":"#{@alice_arn}"},"Action":"s3:PutObject","Resource":"arn:aws:s3:::mb-dst-request-leak/*","Condition":{"StringEquals":{"s3:RequestObjectTag/project":"copy"}}}})

    put_policy("mb-src-request-leak", source_policy)
    put_policy("mb-dst-request-leak", target_policy)

    denied =
      alice(:put, "/mb-dst-request-leak/dst.txt",
        headers: [
          {"x-amz-copy-source", "/mb-src-request-leak/src.txt"},
          {"x-amz-tagging-directive", "REPLACE"},
          {"x-amz-tagging", "project=copy"}
        ]
      )
      |> call()

    assert denied.status == 403
    assert denied.resp_body =~ "AccessDenied"
  end

  test "policy NotIpAddress aws:SourceIp 支持 IPv6 remote_ip" do
    SigV4Request.signed_conn(:put, "/mb11") |> call()
    SigV4Request.signed_conn(:put, "/mb11/o.txt", body: "ipv6") |> call()

    pol =
      ~s({"Statement":[{"Effect":"Allow","Principal":{"AWS":"#{@alice_arn}"},"Action":"s3:GetObject","Resource":"arn:aws:s3:::mb11/*"},{"Effect":"Deny","Principal":{"AWS":"#{@alice_arn}"},"Action":"s3:GetObject","Resource":"arn:aws:s3:::mb11/*","Condition":{"NotIpAddress":{"aws:SourceIp":"2001:db8:1234::/48"}}}]})

    put_policy("mb11", pol)

    inside =
      alice(:get, "/mb11/o.txt", [])
      |> Map.put(:remote_ip, {0x2001, 0x0DB8, 0x1234, 0, 0, 0, 0, 1})
      |> call()

    assert inside.status == 200

    outside =
      alice(:get, "/mb11/o.txt", [])
      |> Map.put(:remote_ip, {0x2001, 0x0DB8, 0x9999, 0, 0, 0, 0, 1})
      |> call()

    assert outside.status == 403
  end

  test "CopyObject 源读权限：源对象对 alice private → copy 被拒（源 GetObject 二次检查）" do
    SigV4Request.signed_conn(:put, "/mb4") |> call()
    SigV4Request.signed_conn(:put, "/mb4/src.txt", body: "src") |> call()

    # 给 alice 目标 PutObject 权限，但不给源 GetObject → 二次检查应拒。
    pol =
      ~s({"Statement":{"Effect":"Allow","Principal":{"AWS":"#{@alice_arn}"},"Action":"s3:PutObject","Resource":"arn:aws:s3:::mb4/*"}})

    SigV4Request.signed_conn(:put, "/mb4",
      query: %{"policy" => ""},
      body: pol,
      headers: [{"content-type", "application/json"}]
    )
    |> call()

    copy = alice(:put, "/mb4/dst.txt", headers: [{"x-amz-copy-source", "/mb4/src.txt"}]) |> call()
    assert copy.status == 403
  end
end
