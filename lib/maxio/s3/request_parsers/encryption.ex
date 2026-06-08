defmodule Maxio.S3.RequestParsers.Encryption do
  @moduledoc """
  PutBucketEncryption 的 XML body 解析（saxy SAX）：
  ServerSideEncryptionConfiguration>Rule>ApplyServerSideEncryptionByDefault>(SSEAlgorithm,KMSMasterKeyID)
  + Rule>BucketKeyEnabled。返回 {:ok, %{algorithm, kms_key_id, bucket_key_enabled}} | {:error, :malformed_xml}。
  """
  @behaviour Saxy.Handler

  @spec parse(binary()) ::
          {:ok,
           %{
             algorithm: String.t() | nil,
             kms_key_id: String.t() | nil,
             bucket_key_enabled: boolean()
           }}
          | {:error, :malformed_xml}
  def parse(xml) when is_binary(xml) do
    init = %{algorithm: nil, kms_key_id: nil, bucket_key_enabled: false, in: nil, text: nil}

    case Saxy.parse_string(xml, __MODULE__, init) do
      {:ok, %{algorithm: a, kms_key_id: k, bucket_key_enabled: bk}} ->
        {:ok, %{algorithm: a, kms_key_id: k, bucket_key_enabled: bk}}

      {:error, _} ->
        {:error, :malformed_xml}
    end
  end

  @impl true
  def handle_event(:start_document, _p, s), do: {:ok, s}

  @impl true
  def handle_event(:start_element, {name, _attrs}, s) do
    case local(name) do
      "SSEAlgorithm" -> {:ok, %{s | in: :alg, text: ""}}
      "KMSMasterKeyID" -> {:ok, %{s | in: :kms, text: ""}}
      "BucketKeyEnabled" -> {:ok, %{s | in: :bk, text: ""}}
      _ -> {:ok, %{s | in: nil}}
    end
  end

  @impl true
  def handle_event(:characters, c, %{text: t} = s) when is_binary(t),
    do: {:ok, %{s | text: t <> c}}

  def handle_event(:characters, _c, s), do: {:ok, s}

  @impl true
  def handle_event(:end_element, name, s) do
    case local(name) do
      "SSEAlgorithm" ->
        {:ok, %{s | algorithm: trim(s.text), in: nil, text: nil}}

      "KMSMasterKeyID" ->
        {:ok, %{s | kms_key_id: trim(s.text), in: nil, text: nil}}

      "BucketKeyEnabled" ->
        {:ok, %{s | bucket_key_enabled: trim(s.text) == "true", in: nil, text: nil}}

      _ ->
        {:ok, %{s | in: nil, text: nil}}
    end
  end

  @impl true
  def handle_event(:end_document, _d, s), do: {:ok, s}

  defp trim(nil), do: nil
  defp trim(t), do: String.trim(t)

  defp local(name) do
    case String.split(name, ":") do
      [_ns, l] -> l
      [l] -> l
    end
  end
end
