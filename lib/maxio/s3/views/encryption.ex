defmodule Maxio.S3.Views.Encryption do
  @moduledoc "GetBucketEncryption 响应 XML（ServerSideEncryptionConfiguration，带 xmlns）。MVP 仅 AES256。"
  import Saxy.XML
  alias Maxio.S3.XML

  @spec render(%{algorithm: String.t(), bucket_key_enabled: boolean()}) :: iodata()
  def render(%{algorithm: alg} = data) do
    apply_default =
      element("ApplyServerSideEncryptionByDefault", [], [element("SSEAlgorithm", [], characters(alg))])

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
end
