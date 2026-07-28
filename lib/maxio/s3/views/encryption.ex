defmodule Maxio.S3.Views.Encryption do
  @moduledoc "GetBucketEncryption 响应 XML（ServerSideEncryptionConfiguration，带 xmlns）。MVP 仅 AES256。"
  import Saxy.XML
  alias Maxio.S3.XML

  @spec render(%{
          required(:algorithm) => String.t(),
          optional(:kms_key_id) => String.t() | nil,
          required(:bucket_key_enabled) => boolean()
        }) :: iodata()
  def render(%{algorithm: alg} = data) do
    apply_default_children =
      [element("SSEAlgorithm", [], characters(alg))]
      |> maybe_add_kms_key_id(alg, Map.get(data, :kms_key_id))

    apply_default =
      element("ApplyServerSideEncryptionByDefault", [], apply_default_children)

    rule_children =
      [apply_default]
      |> then(fn c ->
        if Map.get(data, :bucket_key_enabled, false),
          do: c ++ [element("BucketKeyEnabled", [], characters("true"))],
          else: c
      end)

    root =
      element("ServerSideEncryptionConfiguration", [{"xmlns", XML.namespace()}], [
        element("Rule", [], rule_children)
      ])

    XML.encode(root)
  end

  defp maybe_add_kms_key_id(children, alg, key_id)
       when alg in ["aws:kms", "aws:kms:dsse"] and is_binary(key_id) and key_id != "" do
    children ++ [element("KMSMasterKeyID", [], characters(key_id))]
  end

  defp maybe_add_kms_key_id(children, _alg, _key_id), do: children
end
