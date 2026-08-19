defmodule Maxio.IAM.OIDCThumbprintTest do
  use ExUnit.Case, async: true

  alias Maxio.IAM.OIDCThumbprint

  test "selects the top intermediate certificate when a chain has one" do
    Application.ensure_all_started(:public_key)

    chain =
      :public_key.pkix_test_data(%{
        root: [key: {:rsa, 2048, 65_537}],
        intermediates: [[key: {:rsa, 2048, 65_537}]],
        peer: [key: {:rsa, 2048, 65_537}]
      })

    leaf = Keyword.fetch!(chain, :cert)
    cacerts = Keyword.fetch!(chain, :cacerts)

    intermediate =
      Enum.find(cacerts, fn cert ->
        not self_signed?(cert) and cert != leaf
      end)

    assert is_binary(intermediate)

    assert {:ok, selected} = OIDCThumbprint.top_intermediate_or_leaf([leaf | cacerts])
    assert selected.der == intermediate
    assert sha1_hex(selected.der) == sha1_hex(intermediate)
  end

  test "falls back to the leaf certificate when no intermediate is present" do
    Application.ensure_all_started(:public_key)

    chain =
      :public_key.pkix_test_data(%{
        root: [key: {:rsa, 2048, 65_537}],
        peer: [key: {:rsa, 2048, 65_537}]
      })

    leaf = Keyword.fetch!(chain, :cert)

    assert {:ok, selected} = OIDCThumbprint.top_intermediate_or_leaf([leaf])
    assert selected.der == leaf
  end

  test "selects the top intermediate from unordered multi-intermediate chains" do
    Application.ensure_all_started(:public_key)

    chain =
      :public_key.pkix_test_data(%{
        root: [key: {:rsa, 2048, 65_537}],
        intermediates: [[key: {:rsa, 2048, 65_537}], [key: {:rsa, 2048, 65_537}]],
        peer: [key: {:rsa, 2048, 65_537}]
      })

    leaf = Keyword.fetch!(chain, :cert)
    cacerts = Keyword.fetch!(chain, :cacerts)
    root = Enum.find(cacerts, &self_signed?/1)
    assert is_binary(root)
    assert {:ok, root_subject, _root_issuer} = cert_names(root)

    top_intermediate =
      Enum.find(cacerts, fn cert ->
        case cert_names(cert) do
          {:ok, subject, issuer} -> subject != issuer and issuer == root_subject
          :error -> false
        end
      end)

    assert is_binary(top_intermediate)

    unordered_chain = [leaf | Enum.reverse(cacerts)]
    assert {:ok, selected} = OIDCThumbprint.top_intermediate_or_leaf(unordered_chain)
    assert selected.der == top_intermediate
  end

  test "validates the leaf certificate hostname before accepting a thumbprint" do
    Application.ensure_all_started(:public_key)

    chain =
      :public_key.pkix_test_data(%{
        root: [key: {:rsa, 2048, 65_537}],
        peer: [key: {:rsa, 2048, 65_537}]
      })

    certs = [Keyword.fetch!(chain, :cert) | Keyword.fetch!(chain, :cacerts)]
    hostname = certificate_hostname()

    assert :ok = OIDCThumbprint.hostname_matches?(certs, hostname)

    assert {:error, :oidc_discovery_tls_thumbprint_failed} =
             OIDCThumbprint.hostname_matches?(certs, wrong_hostname(hostname))
  end

  test "thumbprint_for_url refuses non-https and non-binary issuer urls" do
    # 覆盖 `thumbprint_for_url/2` 的 `{:error, reason}` 透传子句（它是这条 `with` 唯一可达的
    # 失败出口）：`https_host_port/1` 拒绝非 https / 无主机名，错误原因必须原样上抛，
    # 不能被吞成成功的指纹。
    assert {:error, :oidc_discovery_tls_thumbprint_failed} =
             OIDCThumbprint.thumbprint_for_url("http://plain.oidc.example.test/tenant")

    assert {:error, :oidc_discovery_tls_thumbprint_failed} =
             OIDCThumbprint.thumbprint_for_url("https:///no-host")

    assert {:error, :oidc_discovery_tls_thumbprint_failed} =
             OIDCThumbprint.thumbprint_for_url(:not_a_url)

    assert {:error, :oidc_discovery_tls_thumbprint_failed} =
             OIDCThumbprint.thumbprints_for_urls(
               ["http://plain.oidc.example.test/tenant"],
               []
             )
  end

  defp self_signed?(der) do
    case cert_names(der) do
      {:ok, subject, issuer} -> subject == issuer
      :error -> false
    end
  end

  defp cert_names(der) do
    case :public_key.pkix_decode_cert(der, :otp) do
      {:OTPCertificate, {:OTPTBSCertificate, _, _, _, issuer, _, subject, _, _, _, _}, _, _} ->
        {:ok, subject, issuer}

      _other ->
        :error
    end
  rescue
    _error -> :error
  end

  defp certificate_hostname, do: :net_adm.localhost() |> to_string()

  defp wrong_hostname("localhost"), do: "127.0.0.1"
  defp wrong_hostname(_certificate_hostname), do: "localhost"

  defp sha1_hex(value), do: :crypto.hash(:sha, value) |> Base.encode16(case: :lower)
end
