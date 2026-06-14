defmodule Maxio.S3.MFADelete do
  @moduledoc """
  MFA Delete gate for the two S3 operations it protects:

    * changing bucket versioning state when MFA Delete is enabled
    * permanently deleting object versions

  This module enforces the S3 protocol boundary (`x-amz-mfa` presence/shape and
  root-only MFADelete configuration). Token validation is delegated to the
  configured verifier and fails closed when no verifier is configured.
  """
  import Plug.Conn

  alias Maxio.Buckets.Bucket
  alias Maxio.S3.{Error, Log}
  alias Maxio.S3.MFADelete.Verifier

  @mfa_header "x-amz-mfa"
  @mfa_re ~r/^(?<serial>\S+) (?<code>[0-9]{6})$/

  @spec require_for_versioning_put!(
          Plug.Conn.t(),
          Bucket.t(),
          String.t() | nil,
          String.t() | nil
        ) :: :ok | no_return()
  def require_for_versioning_put!(conn, %Bucket{} = bucket, status, mfa_delete) do
    cond do
      is_binary(mfa_delete) ->
        require_status_with_mfa_delete!(conn, bucket.name, status)
        require_root_account!(conn, bucket.name)
        require_mfa_header!(conn, bucket.name, :configure_mfa_delete)

      bucket.mfa_delete == "Enabled" and versioning_state_change?(bucket.versioning, status) ->
        require_root_account!(conn, bucket.name)
        require_mfa_header!(conn, bucket.name, :change_versioning_state)

      true ->
        :ok
    end
  end

  @spec require_for_delete_version!(Plug.Conn.t(), Bucket.t()) :: :ok | no_return()
  def require_for_delete_version!(conn, %Bucket{mfa_delete: "Enabled", name: bucket}) do
    require_root_account!(conn, bucket)
    require_mfa_header!(conn, bucket, :delete_object_version)
  end

  def require_for_delete_version!(_conn, %Bucket{}), do: :ok

  @spec require_for_delete_marker!(Plug.Conn.t(), Bucket.t()) :: :ok | no_return()
  def require_for_delete_marker!(
        conn,
        %Bucket{mfa_delete: "Enabled", versioning: versioning, name: bucket}
      )
      when versioning != "Enabled" do
    require_root_account!(conn, bucket)
    require_mfa_header!(conn, bucket, :delete_null_version)
  end

  def require_for_delete_marker!(_conn, %Bucket{}), do: :ok

  @spec validate_batch_delete!(Plug.Conn.t(), Bucket.t(), [%{version_id: String.t() | nil}]) ::
          :ok | no_return()
  def validate_batch_delete!(conn, %Bucket{mfa_delete: "Enabled", name: bucket} = meta, objects) do
    version_delete? = Enum.any?(objects, &version_delete_entry?(meta, &1))
    supplied = mfa_header(conn)

    cond do
      version_delete? ->
        require_root_account!(conn, bucket)
        require_mfa_header!(conn, bucket, :delete_objects_version)

      supplied != nil ->
        verify_mfa_header!(conn, bucket, supplied, :invalid_mfa_header_for_delete_objects)

      true ->
        :ok
    end
  end

  def validate_batch_delete!(_conn, %Bucket{}, _objects), do: :ok

  defp version_delete_entry?(%Bucket{versioning: "Suspended"}, %{version_id: nil}), do: true
  defp version_delete_entry?(_bucket, object), do: Map.get(object, :version_id) != nil

  defp require_status_with_mfa_delete!(conn, bucket, nil) do
    Log.warn("mfa delete rejected",
      action: conn.assigns[:s3_action],
      bucket: bucket,
      reason: :mfa_delete_without_status
    )

    raise Error.new(:malformed_xml,
            message: "Status is required when MfaDelete is provided."
          )
  end

  defp require_status_with_mfa_delete!(_conn, _bucket, _status), do: :ok

  defp require_root_account!(conn, bucket) do
    case conn.assigns[:principal] do
      %{type: :root} ->
        :ok

      _other ->
        Log.warn("mfa delete rejected",
          action: conn.assigns[:s3_action],
          bucket: bucket,
          reason: :mfa_delete_requires_root
        )

        raise Error.new(:access_denied,
                message: "Only the root account can perform MFA Delete protected operations."
              )
    end
  end

  defp require_mfa_header!(conn, bucket, reason) do
    case mfa_header(conn) do
      value when is_binary(value) ->
        verify_mfa_header!(conn, bucket, value, reason)

      nil ->
        reject!(conn, bucket, reason)
    end
  end

  defp verify_mfa_header!(conn, bucket, value, reason) do
    with {:ok, serial, code} <- parse_mfa(value),
         :ok <- require_signed_mfa_header(conn),
         :ok <- require_https(conn),
         :ok <- Verifier.verify(conn.assigns[:principal], serial, code) do
      :ok
    else
      {:error, verify_reason} -> reject!(conn, bucket, verify_reason)
      :error -> reject!(conn, bucket, reason)
    end
  end

  defp require_https(%Plug.Conn{scheme: :https}), do: :ok
  defp require_https(_conn), do: {:error, :mfa_requires_https}

  defp require_signed_mfa_header(conn) do
    signed_headers =
      conn.assigns
      |> Map.get(:sigv4_signed_headers, [])
      |> Enum.map(&String.downcase/1)

    if @mfa_header in signed_headers do
      :ok
    else
      {:error, :unsigned_mfa_header}
    end
  end

  defp reject!(conn, bucket, reason) do
    Log.warn("mfa delete rejected",
      action: conn.assigns[:s3_action],
      bucket: bucket,
      reason: reason
    )

    case reason do
      :mfa_requires_https ->
        raise Error.new(:invalid_request,
                message: "Requests that include x-amz-mfa must use HTTPS."
              )

      _other ->
        raise Error.new(:access_denied,
                message: "MFA Delete requires a valid x-amz-mfa header."
              )
    end
  end

  defp mfa_header(conn) do
    conn
    |> get_req_header(@mfa_header)
    |> List.first()
    |> normalize_header()
  end

  defp normalize_header(nil), do: nil

  defp normalize_header(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp parse_mfa(value) when is_binary(value) do
    case Regex.named_captures(@mfa_re, value) do
      %{"serial" => serial, "code" => code} -> {:ok, serial, code}
      _ -> :error
    end
  end

  defp versioning_state_change?(_current, nil), do: false
  defp versioning_state_change?(current, requested), do: current != requested
end
