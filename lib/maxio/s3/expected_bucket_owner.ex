defmodule Maxio.S3.ExpectedBucketOwner do
  @moduledoc """
  Shared S3 bucket owner condition checks.

  maxio is currently single-account; the expected owner is the configured STS
  account id. The helper only enforces the optional request header and leaves
  bucket existence and IAM authorization to the caller's existing flow.
  """

  import Plug.Conn

  alias Maxio.S3.Error

  @local_account_id "000000000000"

  @spec verify!(Plug.Conn.t(), String.t(), keyword()) :: :ok
  def verify!(%Plug.Conn{} = conn, bucket, opts \\ []) when is_binary(bucket) do
    header = Keyword.get(opts, :header, "x-amz-expected-bucket-owner")
    resource = Keyword.get(opts, :resource, "/" <> bucket)

    case get_req_header(conn, header) do
      [] ->
        :ok

      [owner] ->
        if owner == account_id() do
          :ok
        else
          raise Error.new(:access_denied, resource: resource)
        end

      _multiple ->
        raise Error.new(:access_denied, resource: resource)
    end
  end

  @spec account_id() :: String.t()
  def account_id do
    :maxio
    |> Application.get_env(:sts, [])
    |> Keyword.get(:account_id, @local_account_id)
    |> to_string()
  end
end
