defmodule Maxio.S3.DeleteObjectsCrossMatrixTest do
  use Maxio.DataCase, async: false

  import Plug.Conn

  alias Maxio.Auth.CredentialStore
  alias Maxio.Policy.Store
  alias Maxio.S3.Endpoint
  alias Maxio.S3.RequestParsers.XMLTree
  alias Maxio.Test.SigV4Request

  @data_dir Path.join(System.tmp_dir!(), "maxio_delete_objects_cross_matrix")
  @alice_ak "AKIADELOBJSCROSS01"
  @alice_secret "deleteobjectscrossmatrix123"
  @alice_arn "arn:aws:iam:::user/" <> @alice_ak
  @bucket_owner "000000000000"
  @other_owner "999999999999"

  @requester """
  <RequestPaymentConfiguration xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
    <Payer>Requester</Payer>
  </RequestPaymentConfiguration>
  """

  @legal_hold_on """
  <LegalHold xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
    <Status>ON</Status>
  </LegalHold>
  """

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
    Application.put_env(:maxio, :s3, Keyword.put(prev, :data_dir, @data_dir))

    :ok =
      CredentialStore.put_access_key(%{
        access_key: @alice_ak,
        secret_key: @alice_secret,
        principal: %{type: :iam_user, access_key: @alice_ak, arn: @alice_arn}
      })

    on_exit(fn ->
      Application.put_env(:maxio, :s3, prev)
      File.rm_rf(@data_dir)
    end)

    :ok
  end

  defp call(conn), do: Endpoint.call(conn, Endpoint.init([]))

  defp alice(method, path, opts) do
    SigV4Request.signed_conn(
      method,
      path,
      Keyword.merge([access_key: @alice_ak, secret: @alice_secret], opts)
    )
  end

  defp create_bucket(bucket, headers \\ []) do
    SigV4Request.signed_conn(:put, "/#{bucket}", headers: headers) |> call()
  end

  defp put_object(bucket, key, body) do
    SigV4Request.signed_conn(:put, "/#{bucket}/#{key}", body: body) |> call()
  end

  defp get_object(bucket, key, opts \\ []) do
    SigV4Request.signed_conn(:get, "/#{bucket}/#{key}",
      query: Keyword.get(opts, :query, %{}),
      headers: Keyword.get(opts, :headers, [])
    )
    |> call()
  end

  defp enable_versioning(bucket) do
    body = ~s(<VersioningConfiguration><Status>Enabled</Status></VersioningConfiguration>)

    SigV4Request.signed_conn(:put, "/#{bucket}", query: %{"versioning" => ""}, body: body)
    |> call()
  end

  defp put_request_payment(bucket) do
    SigV4Request.signed_conn(:put, "/#{bucket}",
      query: %{"requestPayment" => ""},
      body: @requester,
      headers: [{"content-md5", content_md5(@requester)}]
    )
    |> call()
  end

  defp delete_object(bucket, key, opts \\ []) do
    SigV4Request.signed_conn(:delete, "/#{bucket}/#{key}",
      query: Keyword.get(opts, :query, %{}),
      headers: Keyword.get(opts, :headers, [])
    )
    |> call()
  end

  defp delete_objects(bucket, body, opts \\ []) do
    SigV4Request.signed_conn(:post, "/#{bucket}",
      query: %{"delete" => ""},
      body: body,
      headers: Keyword.get(opts, :headers, [])
    )
    |> call()
  end

  defp alice_delete_objects(bucket, body, opts \\ []) do
    alice(:post, "/#{bucket}",
      query: %{"delete" => ""},
      body: body,
      headers: Keyword.get(opts, :headers, [])
    )
    |> call()
  end

  defp put_legal_hold(bucket, key, version_id) do
    SigV4Request.signed_conn(:put, "/#{bucket}/#{key}",
      query: %{"legal-hold" => "", "versionId" => version_id},
      body: @legal_hold_on,
      headers: [{"content-md5", content_md5(@legal_hold_on)}]
    )
    |> call()
  end

  defp allow_alice_delete_object(bucket, key) do
    policy =
      %{
        "Version" => "2012-10-17",
        "Statement" => %{
          "Effect" => "Allow",
          "Action" => "s3:DeleteObject",
          "Resource" => "arn:aws:s3:::#{bucket}/#{key}"
        }
      }
      |> Jason.encode!()

    Store.put_principal_policy(@alice_arn, "delete-#{bucket}-#{key}", policy)
  end

  defp content_md5(body), do: :crypto.hash(:md5, body) |> Base.encode64()

  defp assert_charged(conn),
    do: assert(get_resp_header(conn, "x-amz-request-charged") == ["requester"])

  defp refute_charged(conn), do: assert(get_resp_header(conn, "x-amz-request-charged") == [])

  defp delete_result_entries(body) do
    {:ok, {"DeleteResult", _attrs, children}} = XMLTree.parse(body)

    children
    |> XMLTree.structural_children()
    |> Enum.map(fn
      {"Deleted", _attrs, children} -> {:deleted, xml_fields(children)}
      {"Error", _attrs, children} -> {:error, xml_fields(children)}
    end)
  end

  defp xml_fields(children) do
    children
    |> XMLTree.structural_children()
    |> Map.new(fn {name, _attrs, children} ->
      {:ok, value} = XMLTree.text(children)
      {name, value}
    end)
  end

  defp assert_entry(entries, type, fields) do
    assert Enum.any?(entries, fn
             {^type, entry} ->
               Enum.all?(fields, fn {key, value} -> Map.get(entry, key) == value end)

             _other ->
               false
           end),
           "expected #{inspect(type)} entry with #{inspect(fields)} in #{inspect(entries)}"
  end

  defp refute_entry(entries, type) do
    refute Enum.any?(entries, fn {entry_type, _entry} -> entry_type == type end)
  end

  test "Requester Pays and expected owner are request-level gates before per-key quiet results" do
    bucket = "delcrossrp"
    allowed_key = "allowed.txt"
    denied_key = "denied.txt"

    assert create_bucket(bucket).status == 200
    assert put_object(bucket, allowed_key, "allowed").status == 200
    assert put_object(bucket, denied_key, "denied").status == 200
    assert put_request_payment(bucket).status == 200
    assert :ok = allow_alice_delete_object(bucket, allowed_key)

    body = """
    <Delete>
      <Quiet>true</Quiet>
      <Object><Key>#{allowed_key}</Key></Object>
      <Object><Key>#{denied_key}</Key></Object>
    </Delete>
    """

    missing_payer = alice_delete_objects(bucket, body)
    assert missing_payer.status == 403
    refute missing_payer.resp_body =~ "<DeleteResult"
    refute_charged(missing_payer)
    assert get_object(bucket, allowed_key).resp_body == "allowed"
    assert get_object(bucket, denied_key).resp_body == "denied"

    wrong_owner =
      alice_delete_objects(bucket, body,
        headers: [
          {"x-amz-request-payer", "requester"},
          {"x-amz-expected-bucket-owner", @other_owner}
        ]
      )

    assert wrong_owner.status == 403
    refute wrong_owner.resp_body =~ "<DeleteResult"
    refute_charged(wrong_owner)
    assert get_object(bucket, allowed_key).resp_body == "allowed"
    assert get_object(bucket, denied_key).resp_body == "denied"

    mixed =
      alice_delete_objects(bucket, body,
        headers: [
          {"x-amz-request-payer", "requester"},
          {"x-amz-expected-bucket-owner", @bucket_owner}
        ]
      )

    assert mixed.status == 200
    assert_charged(mixed)
    entries = delete_result_entries(mixed.resp_body)
    refute_entry(entries, :deleted)
    assert_entry(entries, :error, %{"Key" => denied_key, "Code" => "AccessDenied"})
    assert get_object(bucket, allowed_key).status == 404
    assert get_object(bucket, denied_key).resp_body == "denied"
  end

  test "DeleteObjects returns DeleteMarkerVersionId when deleting a delete marker version" do
    bucket = "delcrossdm"
    key = "doc.txt"

    assert create_bucket(bucket).status == 200
    assert enable_versioning(bucket).status == 200

    put = put_object(bucket, key, "v1")
    assert put.status == 200
    [version_id] = get_resp_header(put, "x-amz-version-id")

    marker = delete_object(bucket, key)
    assert marker.status == 204
    [delete_marker_version_id] = get_resp_header(marker, "x-amz-version-id")

    current = get_object(bucket, key)
    assert current.status == 404
    assert get_resp_header(current, "x-amz-delete-marker") == ["true"]

    body = """
    <Delete>
      <Object>
        <Key>#{key}</Key>
        <VersionId>#{delete_marker_version_id}</VersionId>
      </Object>
    </Delete>
    """

    deleted = delete_objects(bucket, body)
    assert deleted.status == 200

    entries = delete_result_entries(deleted.resp_body)

    assert_entry(entries, :deleted, %{
      "Key" => key,
      "VersionId" => delete_marker_version_id,
      "DeleteMarker" => "true",
      "DeleteMarkerVersionId" => delete_marker_version_id
    })

    latest = get_object(bucket, key)
    assert latest.status == 200
    assert latest.resp_body == "v1"

    old = get_object(bucket, key, query: %{"versionId" => version_id})
    assert old.status == 200
    assert old.resp_body == "v1"
  end

  test "Object Lock allows delete marker insertion but blocks protected version delete per key" do
    bucket = "delcrosslock"
    protected_key = "protected.txt"
    open_key = "open.txt"

    assert create_bucket(bucket, [{"x-amz-bucket-object-lock-enabled", "true"}]).status == 200

    protected_put = put_object(bucket, protected_key, "protected")
    assert protected_put.status == 200
    [protected_version_id] = get_resp_header(protected_put, "x-amz-version-id")
    assert put_legal_hold(bucket, protected_key, protected_version_id).status == 200

    open_put = put_object(bucket, open_key, "open")
    assert open_put.status == 200
    [open_version_id] = get_resp_header(open_put, "x-amz-version-id")

    body = """
    <Delete>
      <Object><Key>#{protected_key}</Key></Object>
      <Object><Key>#{protected_key}</Key><VersionId>#{protected_version_id}</VersionId></Object>
      <Object><Key>#{open_key}</Key><VersionId>#{open_version_id}</VersionId></Object>
    </Delete>
    """

    result = delete_objects(bucket, body)
    assert result.status == 200

    entries = delete_result_entries(result.resp_body)

    assert_entry(entries, :deleted, %{
      "Key" => protected_key,
      "DeleteMarker" => "true"
    })

    assert_entry(entries, :deleted, %{
      "Key" => open_key,
      "VersionId" => open_version_id
    })

    assert_entry(entries, :error, %{
      "Key" => protected_key,
      "VersionId" => protected_version_id,
      "Code" => "AccessDenied"
    })

    protected_latest = get_object(bucket, protected_key)
    assert protected_latest.status == 404
    assert get_resp_header(protected_latest, "x-amz-delete-marker") == ["true"]

    protected_version =
      get_object(bucket, protected_key, query: %{"versionId" => protected_version_id})

    assert protected_version.status == 200
    assert protected_version.resp_body == "protected"

    deleted_open_version = get_object(bucket, open_key, query: %{"versionId" => open_version_id})
    assert deleted_open_version.status == 404
  end
end
