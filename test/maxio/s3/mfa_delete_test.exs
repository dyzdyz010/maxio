defmodule Maxio.S3.MFADeleteTest do
  use Maxio.DataCase, async: false

  import Plug.Conn

  alias Maxio.Auth.CredentialStore
  alias Maxio.Policy.Store
  alias Maxio.S3.Endpoint
  alias Maxio.Test.SigV4Request

  @data_dir Path.join(System.tmp_dir!(), "maxio_mfa_delete_test")
  @mfa_serial "arn:aws:iam::123456789012:mfa/root-account-mfa-device"
  @mfa_code "123456"
  @mfa_header {"x-amz-mfa", "#{@mfa_serial} #{@mfa_code}"}
  @alice_ak "AKIAMFADELETE000001"
  @alice_secret "mfamfamfamfamfamfamfamfa12"
  @alice_arn "arn:aws:iam:::user/" <> @alice_ak

  setup do
    %{user_arn: @alice_arn} =
      create_user_with_access_key!(
        user_name: @alice_ak,
        access_key_id: @alice_ak,
        secret_key: @alice_secret
      )

    File.rm_rf(@data_dir)
    File.mkdir_p!(@data_dir)
    prev = Application.get_env(:maxio, :s3)
    prev_mfa_verifier = Application.fetch_env(:maxio, :mfa_delete_verifier)
    Application.put_env(:maxio, :s3, Keyword.put(prev, :data_dir, @data_dir))
    Application.put_env(:maxio, :mfa_delete_verifier, &verify_test_mfa/3)

    :ok =
      CredentialStore.put_access_key(%{
        access_key: @alice_ak,
        secret_key: @alice_secret,
        principal: %{type: :iam_user, access_key: @alice_ak, arn: @alice_arn}
      })

    on_exit(fn ->
      Application.put_env(:maxio, :s3, prev)
      restore_mfa_verifier(prev_mfa_verifier)
      File.rm_rf(@data_dir)
    end)

    :ok
  end

  defp call(conn), do: Endpoint.call(conn, Endpoint.init([]))
  defp https(conn), do: %{conn | scheme: :https}

  defp verify_test_mfa(_principal, @mfa_serial, @mfa_code), do: :ok
  defp verify_test_mfa(_principal, _serial, _code), do: {:error, :invalid_mfa}

  defp restore_mfa_verifier({:ok, value}),
    do: Application.put_env(:maxio, :mfa_delete_verifier, value)

  defp restore_mfa_verifier(:error), do: Application.delete_env(:maxio, :mfa_delete_verifier)

  defp alice(method, path, opts) do
    SigV4Request.signed_conn(
      method,
      path,
      Keyword.merge([access_key: @alice_ak, secret: @alice_secret], opts)
    )
  end

  defp put_bucket(bucket), do: SigV4Request.signed_conn(:put, "/#{bucket}") |> call()

  defp put_policy(bucket, policy) do
    SigV4Request.signed_conn(:put, "/#{bucket}",
      query: %{"policy" => ""},
      body: policy,
      headers: [{"content-type", "application/json"}]
    )
    |> call()
  end

  defp enable_versioning(bucket) do
    body = ~s(<VersioningConfiguration><Status>Enabled</Status></VersioningConfiguration>)

    SigV4Request.signed_conn(:put, "/#{bucket}",
      query: %{"versioning" => ""},
      body: body
    )
    |> call()
  end

  defp enable_mfa_delete(bucket) do
    body =
      ~s(<VersioningConfiguration><Status>Enabled</Status><MfaDelete>Enabled</MfaDelete></VersioningConfiguration>)

    SigV4Request.signed_conn(:put, "/#{bucket}",
      query: %{"versioning" => ""},
      body: body,
      headers: [@mfa_header]
    )
    |> https()
    |> call()
  end

  defp suspend_mfa_delete(bucket) do
    body = ~s(<VersioningConfiguration><Status>Suspended</Status></VersioningConfiguration>)

    SigV4Request.signed_conn(:put, "/#{bucket}",
      query: %{"versioning" => ""},
      body: body,
      headers: [@mfa_header]
    )
    |> https()
    |> call()
  end

  defp get_versioning(bucket) do
    SigV4Request.signed_conn(:get, "/#{bucket}", query: %{"versioning" => ""}) |> call()
  end

  test "PutBucketVersioning with MfaDelete requires x-amz-mfa and leaves config unchanged" do
    put_bucket("mfav1")

    body =
      ~s(<VersioningConfiguration><Status>Enabled</Status><MfaDelete>Enabled</MfaDelete></VersioningConfiguration>)

    rejected =
      SigV4Request.signed_conn(:put, "/mfav1", query: %{"versioning" => ""}, body: body)
      |> call()

    assert rejected.status == 403
    assert rejected.resp_body =~ "<Code>AccessDenied</Code>"

    unchanged = get_versioning("mfav1")
    refute unchanged.resp_body =~ "<Status>"
    refute unchanged.resp_body =~ "<MfaDelete>"

    accepted =
      SigV4Request.signed_conn(:put, "/mfav1",
        query: %{"versioning" => ""},
        body: body,
        headers: [@mfa_header]
      )
      |> https()
      |> call()

    assert accepted.status == 200

    saved = get_versioning("mfav1")
    assert saved.resp_body =~ "<Status>Enabled</Status>"
    assert saved.resp_body =~ "<MfaDelete>Enabled</MfaDelete>"
  end

  test "MfaDelete element requires Status in the same PutBucketVersioning request" do
    put_bucket("mfav2")

    body = ~s(<VersioningConfiguration><MfaDelete>Enabled</MfaDelete></VersioningConfiguration>)

    rejected =
      SigV4Request.signed_conn(:put, "/mfav2",
        query: %{"versioning" => ""},
        body: body,
        headers: [@mfa_header]
      )
      |> https()
      |> call()

    assert rejected.status == 400
    assert rejected.resp_body =~ "<Code>MalformedXML</Code>"

    unchanged = get_versioning("mfav2")
    refute unchanged.resp_body =~ "<MfaDelete>"
  end

  test "non-root principal cannot configure MFA Delete even with PutBucketVersioning permission" do
    put_bucket("mfav3")

    policy =
      ~s({"Version":"2012-10-17","Statement":{"Effect":"Allow","Action":"s3:PutBucketVersioning","Resource":"arn:aws:s3:::mfav3"}})

    assert :ok = Store.put_principal_policy(@alice_arn, "put-versioning", policy)

    body =
      ~s(<VersioningConfiguration><Status>Enabled</Status><MfaDelete>Enabled</MfaDelete></VersioningConfiguration>)

    rejected =
      alice(:put, "/mfav3",
        query: %{"versioning" => ""},
        body: body,
        headers: [@mfa_header]
      )
      |> https()
      |> call()

    assert rejected.status == 403
    assert rejected.resp_body =~ "<Code>AccessDenied</Code>"

    unchanged = get_versioning("mfav3")
    refute unchanged.resp_body =~ "<MfaDelete>"
  end

  test "non-root principal cannot permanently delete versions even with DeleteObjectVersion and valid MFA" do
    put_bucket("mfav6")
    assert enable_mfa_delete("mfav6").status == 200

    put = SigV4Request.signed_conn(:put, "/mfav6/k.txt", body: "v") |> call()
    [version_id] = get_resp_header(put, "x-amz-version-id")

    delete_version =
      ~s({"Version":"2012-10-17","Statement":{"Effect":"Allow","Principal":{"AWS":"#{@alice_arn}"},"Action":"s3:DeleteObjectVersion","Resource":"arn:aws:s3:::mfav6/k.txt"}})

    put_policy("mfav6", delete_version)

    rejected =
      alice(:delete, "/mfav6/k.txt",
        query: %{"versionId" => version_id},
        headers: [@mfa_header]
      )
      |> https()
      |> call()

    assert rejected.status == 403
    assert rejected.resp_body =~ "<Code>AccessDenied</Code>"

    still_there =
      SigV4Request.signed_conn(:get, "/mfav6/k.txt", query: %{"versionId" => version_id})
      |> call()

    assert still_there.status == 200
  end

  test "MFA Delete protected requests fail closed when verifier is not configured" do
    Application.delete_env(:maxio, :mfa_delete_verifier)
    put_bucket("mfav5")

    body =
      ~s(<VersioningConfiguration><Status>Enabled</Status><MfaDelete>Enabled</MfaDelete></VersioningConfiguration>)

    rejected =
      SigV4Request.signed_conn(:put, "/mfav5",
        query: %{"versioning" => ""},
        body: body,
        headers: [@mfa_header]
      )
      |> https()
      |> call()

    assert rejected.status == 403
    assert rejected.resp_body =~ "<Code>AccessDenied</Code>"
  end

  test "MFA Delete enabled bucket requires MFA to change versioning state" do
    put_bucket("mfav4")
    assert enable_mfa_delete("mfav4").status == 200

    suspend = ~s(<VersioningConfiguration><Status>Suspended</Status></VersioningConfiguration>)

    rejected =
      SigV4Request.signed_conn(:put, "/mfav4", query: %{"versioning" => ""}, body: suspend)
      |> call()

    assert rejected.status == 403

    still_enabled = get_versioning("mfav4")
    assert still_enabled.resp_body =~ "<Status>Enabled</Status>"

    accepted =
      SigV4Request.signed_conn(:put, "/mfav4",
        query: %{"versioning" => ""},
        body: suspend,
        headers: [@mfa_header]
      )
      |> https()
      |> call()

    assert accepted.status == 200
    assert get_versioning("mfav4").resp_body =~ "<Status>Suspended</Status>"
  end

  test "DELETE versionId requires MFA when MFA Delete is enabled and preserves version on rejection" do
    put_bucket("mfao1")
    assert enable_mfa_delete("mfao1").status == 200

    put = SigV4Request.signed_conn(:put, "/mfao1/k.txt", body: "v1") |> call()
    [version_id] = get_resp_header(put, "x-amz-version-id")

    rejected =
      SigV4Request.signed_conn(:delete, "/mfao1/k.txt", query: %{"versionId" => version_id})
      |> call()

    assert rejected.status == 403
    assert rejected.resp_body =~ "<Code>AccessDenied</Code>"

    still_there =
      SigV4Request.signed_conn(:get, "/mfao1/k.txt", query: %{"versionId" => version_id})
      |> call()

    assert still_there.status == 200
    assert still_there.resp_body == "v1"

    deleted =
      SigV4Request.signed_conn(:delete, "/mfao1/k.txt",
        query: %{"versionId" => version_id},
        headers: [@mfa_header]
      )
      |> https()
      |> call()

    assert deleted.status == 204

    gone =
      SigV4Request.signed_conn(:get, "/mfao1/k.txt", query: %{"versionId" => version_id})
      |> call()

    assert gone.status == 404
  end

  test "x-amz-mfa must be covered by SigV4 SignedHeaders" do
    put_bucket("mfasigned")
    assert enable_mfa_delete("mfasigned").status == 200

    put = SigV4Request.signed_conn(:put, "/mfasigned/k.txt", body: "v1") |> call()
    [version_id] = get_resp_header(put, "x-amz-version-id")

    rejected =
      SigV4Request.signed_conn(:delete, "/mfasigned/k.txt", query: %{"versionId" => version_id})
      |> put_req_header("x-amz-mfa", "#{@mfa_serial} #{@mfa_code}")
      |> https()
      |> call()

    assert rejected.status == 403
    assert rejected.resp_body =~ "<Code>AccessDenied</Code>"

    still_there =
      SigV4Request.signed_conn(:get, "/mfasigned/k.txt", query: %{"versionId" => version_id})
      |> call()

    assert still_there.status == 200
  end

  test "ordinary delete marker insertion does not require MFA" do
    put_bucket("mfao2")
    assert enable_mfa_delete("mfao2").status == 200

    put = SigV4Request.signed_conn(:put, "/mfao2/k.txt", body: "v1") |> call()
    [version_id] = get_resp_header(put, "x-amz-version-id")

    deleted = SigV4Request.signed_conn(:delete, "/mfao2/k.txt") |> call()
    assert deleted.status == 204
    assert get_resp_header(deleted, "x-amz-delete-marker") == ["true"]

    old =
      SigV4Request.signed_conn(:get, "/mfao2/k.txt", query: %{"versionId" => version_id})
      |> call()

    assert old.status == 200
    assert old.resp_body == "v1"
  end

  test "non-root principal cannot replace null version in suspended MFA Delete buckets" do
    put_bucket("mfasusp3")
    assert enable_mfa_delete("mfasusp3").status == 200
    assert suspend_mfa_delete("mfasusp3").status == 200
    SigV4Request.signed_conn(:put, "/mfasusp3/k.txt", body: "null-live") |> call()

    delete_object =
      ~s({"Version":"2012-10-17","Statement":{"Effect":"Allow","Principal":{"AWS":"#{@alice_arn}"},"Action":"s3:DeleteObject","Resource":"arn:aws:s3:::mfasusp3/k.txt"}})

    put_policy("mfasusp3", delete_object)

    rejected =
      alice(:delete, "/mfasusp3/k.txt", headers: [@mfa_header])
      |> https()
      |> call()

    assert rejected.status == 403

    current = SigV4Request.signed_conn(:get, "/mfasusp3/k.txt") |> call()
    assert current.status == 200
    assert current.resp_body == "null-live"
  end

  test "ordinary DELETE in an MFA Delete suspended bucket requires MFA for the null version" do
    put_bucket("mfasusp1")
    assert enable_mfa_delete("mfasusp1").status == 200
    assert suspend_mfa_delete("mfasusp1").status == 200

    put = SigV4Request.signed_conn(:put, "/mfasusp1/k.txt", body: "null-live") |> call()
    assert put.status == 200

    rejected = SigV4Request.signed_conn(:delete, "/mfasusp1/k.txt") |> call()

    assert rejected.status == 403
    assert rejected.resp_body =~ "<Code>AccessDenied</Code>"

    current = SigV4Request.signed_conn(:get, "/mfasusp1/k.txt") |> call()
    assert current.status == 200
    assert current.resp_body == "null-live"

    deleted =
      SigV4Request.signed_conn(:delete, "/mfasusp1/k.txt", headers: [@mfa_header])
      |> https()
      |> call()

    assert deleted.status == 204

    gone = SigV4Request.signed_conn(:get, "/mfasusp1/k.txt") |> call()
    assert gone.status == 404
  end

  test "DeleteObjects with any VersionId fails the whole request without MFA" do
    put_bucket("mfab1")
    assert enable_mfa_delete("mfab1").status == 200

    p1 = SigV4Request.signed_conn(:put, "/mfab1/k1.txt", body: "v1") |> call()
    [version_id] = get_resp_header(p1, "x-amz-version-id")
    SigV4Request.signed_conn(:put, "/mfab1/k2.txt", body: "v2") |> call()

    body =
      ~s(<Delete><Object><Key>k1.txt</Key><VersionId>#{version_id}</VersionId></Object><Object><Key>k2.txt</Key></Object></Delete>)

    rejected =
      SigV4Request.signed_conn(:post, "/mfab1", query: %{"delete" => ""}, body: body)
      |> call()

    assert rejected.status == 403
    assert rejected.resp_body =~ "<Code>AccessDenied</Code>"
    refute rejected.resp_body =~ "<DeleteResult"

    old =
      SigV4Request.signed_conn(:get, "/mfab1/k1.txt", query: %{"versionId" => version_id})
      |> call()

    current = SigV4Request.signed_conn(:get, "/mfab1/k2.txt") |> call()
    assert old.status == 200
    assert current.status == 200
  end

  test "DeleteObjects with verifier-rejected MFA fails even without VersionId" do
    put_bucket("mfab2")
    assert enable_mfa_delete("mfab2").status == 200
    SigV4Request.signed_conn(:put, "/mfab2/k.txt", body: "v") |> call()

    body = ~s(<Delete><Object><Key>k.txt</Key></Object></Delete>)

    rejected =
      SigV4Request.signed_conn(:post, "/mfab2",
        query: %{"delete" => ""},
        body: body,
        headers: [{"x-amz-mfa", "#{@mfa_serial} 000000"}]
      )
      |> https()
      |> call()

    assert rejected.status == 403

    current = SigV4Request.signed_conn(:get, "/mfab2/k.txt") |> call()
    assert current.status == 200
  end

  test "non-root principal cannot run protected DeleteObjects even with valid MFA" do
    put_bucket("mfab4")
    assert enable_mfa_delete("mfab4").status == 200

    put = SigV4Request.signed_conn(:put, "/mfab4/k.txt", body: "v") |> call()
    [version_id] = get_resp_header(put, "x-amz-version-id")

    delete_version =
      ~s({"Version":"2012-10-17","Statement":{"Effect":"Allow","Principal":{"AWS":"#{@alice_arn}"},"Action":"s3:DeleteObjectVersion","Resource":"arn:aws:s3:::mfab4/k.txt"}})

    put_policy("mfab4", delete_version)

    body =
      ~s(<Delete><Object><Key>k.txt</Key><VersionId>#{version_id}</VersionId></Object></Delete>)

    rejected =
      alice(:post, "/mfab4",
        query: %{"delete" => ""},
        body: body,
        headers: [@mfa_header]
      )
      |> https()
      |> call()

    assert rejected.status == 403
    refute rejected.resp_body =~ "<DeleteResult"

    still_there =
      SigV4Request.signed_conn(:get, "/mfab4/k.txt", query: %{"versionId" => version_id})
      |> call()

    assert still_there.status == 200
  end

  test "DeleteObjects without VersionId requires MFA in suspended MFA Delete buckets" do
    put_bucket("mfasusp2")
    assert enable_mfa_delete("mfasusp2").status == 200
    assert suspend_mfa_delete("mfasusp2").status == 200
    SigV4Request.signed_conn(:put, "/mfasusp2/k.txt", body: "null-live") |> call()

    body = ~s(<Delete><Object><Key>k.txt</Key></Object></Delete>)

    rejected =
      SigV4Request.signed_conn(:post, "/mfasusp2", query: %{"delete" => ""}, body: body)
      |> call()

    assert rejected.status == 403
    refute rejected.resp_body =~ "<DeleteResult"

    current = SigV4Request.signed_conn(:get, "/mfasusp2/k.txt") |> call()
    assert current.status == 200
    assert current.resp_body == "null-live"

    deleted =
      SigV4Request.signed_conn(:post, "/mfasusp2",
        query: %{"delete" => ""},
        body: body,
        headers: [@mfa_header]
      )
      |> https()
      |> call()

    assert deleted.status == 200
    assert deleted.resp_body =~ "<DeleteMarker>true</DeleteMarker>"

    gone = SigV4Request.signed_conn(:get, "/mfasusp2/k.txt") |> call()
    assert gone.status == 404
  end

  test "DeleteObjects with valid MFA can permanently delete a version" do
    put_bucket("mfab3")
    assert enable_mfa_delete("mfab3").status == 200

    put = SigV4Request.signed_conn(:put, "/mfab3/k.txt", body: "v") |> call()
    [version_id] = get_resp_header(put, "x-amz-version-id")

    body =
      ~s(<Delete><Object><Key>k.txt</Key><VersionId>#{version_id}</VersionId></Object></Delete>)

    deleted =
      SigV4Request.signed_conn(:post, "/mfab3",
        query: %{"delete" => ""},
        body: body,
        headers: [@mfa_header]
      )
      |> https()
      |> call()

    assert deleted.status == 200
    assert deleted.resp_body =~ "<VersionId>#{version_id}</VersionId>"

    gone =
      SigV4Request.signed_conn(:get, "/mfab3/k.txt", query: %{"versionId" => version_id})
      |> call()

    assert gone.status == 404
  end

  test "single DELETE versionId requires s3:DeleteObjectVersion rather than s3:DeleteObject" do
    put_bucket("mfaa1")
    assert enable_versioning("mfaa1").status == 200

    put = SigV4Request.signed_conn(:put, "/mfaa1/k.txt", body: "v") |> call()
    [version_id] = get_resp_header(put, "x-amz-version-id")

    only_delete_object =
      ~s({"Version":"2012-10-17","Statement":{"Effect":"Allow","Principal":{"AWS":"#{@alice_arn}"},"Action":"s3:DeleteObject","Resource":"arn:aws:s3:::mfaa1/k.txt"}})

    put_policy("mfaa1", only_delete_object)

    denied =
      alice(:delete, "/mfaa1/k.txt", query: %{"versionId" => version_id})
      |> call()

    assert denied.status == 403
    assert denied.resp_body =~ "<Code>AccessDenied</Code>"

    delete_version =
      ~s({"Version":"2012-10-17","Statement":{"Effect":"Allow","Principal":{"AWS":"#{@alice_arn}"},"Action":"s3:DeleteObjectVersion","Resource":"arn:aws:s3:::mfaa1/k.txt"}})

    put_policy("mfaa1", delete_version)

    allowed =
      alice(:delete, "/mfaa1/k.txt", query: %{"versionId" => version_id})
      |> call()

    assert allowed.status == 204
  end

  test "DeleteObjects VersionId entries require s3:DeleteObjectVersion per key" do
    put_bucket("mfaa2")
    assert enable_versioning("mfaa2").status == 200

    put = SigV4Request.signed_conn(:put, "/mfaa2/k.txt", body: "v") |> call()
    [version_id] = get_resp_header(put, "x-amz-version-id")

    body =
      ~s(<Delete><Object><Key>k.txt</Key><VersionId>#{version_id}</VersionId></Object></Delete>)

    only_delete_object =
      ~s({"Version":"2012-10-17","Statement":{"Effect":"Allow","Principal":{"AWS":"#{@alice_arn}"},"Action":"s3:DeleteObject","Resource":"arn:aws:s3:::mfaa2/k.txt"}})

    put_policy("mfaa2", only_delete_object)

    denied = alice(:post, "/mfaa2", query: %{"delete" => ""}, body: body) |> call()
    assert denied.status == 200
    assert denied.resp_body =~ "<Code>AccessDenied</Code>"

    still_there =
      SigV4Request.signed_conn(:get, "/mfaa2/k.txt", query: %{"versionId" => version_id})
      |> call()

    assert still_there.status == 200

    delete_version =
      ~s({"Version":"2012-10-17","Statement":{"Effect":"Allow","Principal":{"AWS":"#{@alice_arn}"},"Action":"s3:DeleteObjectVersion","Resource":"arn:aws:s3:::mfaa2/k.txt"}})

    put_policy("mfaa2", delete_version)

    allowed = alice(:post, "/mfaa2", query: %{"delete" => ""}, body: body) |> call()
    assert allowed.status == 200
    assert allowed.resp_body =~ "<VersionId>#{version_id}</VersionId>"
  end
end
