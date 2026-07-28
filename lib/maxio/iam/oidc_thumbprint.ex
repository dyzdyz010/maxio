defmodule Maxio.IAM.OIDCThumbprint do
  @moduledoc """
  TLS certificate-chain thumbprint helpers for IAM OIDC provider management.

  This module is only used on management/refresh paths. STS WebIdentity token
  verification must continue to use the persisted provider snapshot without
  network IO.
  """

  @default_timeout_ms 5_000

  @spec thumbprints_for_urls([String.t()], keyword()) :: {:ok, [String.t()]} | {:error, atom()}
  def thumbprints_for_urls(urls, opts \\ [])

  def thumbprints_for_urls(urls, opts) when is_list(urls) do
    urls
    |> Enum.uniq()
    |> Enum.reduce_while({:ok, []}, fn url, {:ok, acc} ->
      case thumbprint_for_url(url, opts) do
        {:ok, thumbprint} -> {:cont, {:ok, acc ++ [thumbprint]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, thumbprints} ->
        {:ok, Enum.uniq_by(thumbprints, &String.downcase/1)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def thumbprints_for_urls(_urls, _opts), do: {:error, :oidc_discovery_tls_thumbprint_failed}

  @spec thumbprint_for_url(String.t(), keyword()) :: {:ok, String.t()} | {:error, atom()}
  def thumbprint_for_url(url, opts \\ [])

  def thumbprint_for_url(url, opts) when is_binary(url) do
    with {:ok, {host, port}} <- https_host_port(url),
         {:ok, certs} <- peer_chain(host, port, opts),
         :ok <- hostname_matches?(certs, host),
         {:ok, selected} <- top_intermediate_or_leaf(certs),
         :ok <- configured_thumbprint_allowed?(selected.der, opts) do
      {:ok, sha1_hex(selected.der)}
    else
      {:error, reason} -> {:error, reason}
      _other -> {:error, :oidc_discovery_tls_thumbprint_failed}
    end
  end

  def thumbprint_for_url(_url, _opts), do: {:error, :oidc_discovery_tls_thumbprint_failed}

  @doc false
  @spec top_intermediate_or_leaf([term()]) ::
          {:ok, %{der: binary(), subject: term(), issuer: term()}} | {:error, atom()}
  def top_intermediate_or_leaf(certs) when is_list(certs) do
    normalized =
      certs
      |> Enum.flat_map(&normalize_cert/1)
      |> Enum.uniq_by(& &1.der)

    cond do
      normalized == [] ->
        {:error, :oidc_discovery_tls_thumbprint_failed}

      true ->
        select_from_chain(normalized)
    end
  end

  def top_intermediate_or_leaf(_certs), do: {:error, :oidc_discovery_tls_thumbprint_failed}

  @doc false
  @spec hostname_matches?([term()], String.t()) :: :ok | {:error, atom()}
  def hostname_matches?(certs, host) when is_list(certs) and is_binary(host) do
    with {:ok, leaf} <- leaf_certificate(certs),
         true <-
           :public_key.pkix_verify_hostname(leaf.der, hostname_reference_ids(host),
             match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
           ) do
      :ok
    else
      {:error, reason} -> {:error, reason}
      _other -> {:error, :oidc_discovery_tls_thumbprint_failed}
    end
  rescue
    _error -> {:error, :oidc_discovery_tls_thumbprint_failed}
  catch
    _kind, _reason -> {:error, :oidc_discovery_tls_thumbprint_failed}
  end

  def hostname_matches?(_certs, _host), do: {:error, :oidc_discovery_tls_thumbprint_failed}

  defp https_host_port(url) do
    uri = URI.parse(url)

    cond do
      uri.scheme != "https" -> {:error, :oidc_discovery_tls_thumbprint_failed}
      not is_binary(uri.host) or uri.host == "" -> {:error, :oidc_discovery_tls_thumbprint_failed}
      true -> {:ok, {uri.host, uri.port || 443}}
    end
  rescue
    _error -> {:error, :oidc_discovery_tls_thumbprint_failed}
  end

  defp peer_chain(host, port, opts) do
    _ = Application.ensure_all_started(:ssl)
    _ = Application.ensure_all_started(:public_key)

    parent = self()
    ref = make_ref()
    thumbprints = configured_thumbprints(opts)
    allow_thumbprint_fallback? = thumbprints != []

    verify_fun = fn cert, event, state ->
      if event in [:valid, :valid_peer] or match?({:bad_cert, _reason}, event) do
        send(parent, {ref, :cert, cert})
      end

      case event do
        {:bad_cert, reason} ->
          if allow_thumbprint_fallback? and thumbprint_trust_fallback_reason?(reason) do
            {:valid, state}
          else
            {:fail, reason}
          end

        {:extension, _extension} ->
          {:unknown, state}

        :valid ->
          {:valid, state}

        :valid_peer ->
          {:valid, state}
      end
    end

    timeout = Keyword.get(opts, :timeout_ms, @default_timeout_ms)
    char_host = String.to_charlist(host)

    ssl_opts = [
      verify: :verify_peer,
      cacerts: Keyword.get(opts, :cacerts, :public_key.cacerts_get()),
      server_name_indication: char_host,
      customize_hostname_check: [
        match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
      ],
      verify_fun: {verify_fun, []}
    ]

    with {:ok, socket} <- :ssl.connect(char_host, port, ssl_opts, timeout) do
      :ssl.close(socket)
      {:ok, collect_certs(ref, [])}
    else
      _error -> {:error, :oidc_discovery_tls_thumbprint_failed}
    end
  rescue
    _error -> {:error, :oidc_discovery_tls_thumbprint_failed}
  catch
    _kind, _reason -> {:error, :oidc_discovery_tls_thumbprint_failed}
  end

  defp collect_certs(ref, acc) do
    receive do
      {^ref, :cert, cert} -> collect_certs(ref, acc ++ [cert])
    after
      0 -> acc
    end
  end

  defp normalize_cert({:OTPCertificate, _tbs, _sig_alg, _sig} = cert) do
    der = :public_key.pkix_encode(:OTPCertificate, cert, :otp)
    decoded = :public_key.pkix_decode_cert(der, :otp)

    case certificate_names(decoded) do
      {:ok, subject, issuer} -> [%{der: der, subject: subject, issuer: issuer}]
      :error -> []
    end
  rescue
    _error -> []
  catch
    _kind, _reason -> []
  end

  defp normalize_cert(cert) when is_binary(cert) do
    decoded = :public_key.pkix_decode_cert(cert, :otp)

    case certificate_names(decoded) do
      {:ok, subject, issuer} -> [%{der: cert, subject: subject, issuer: issuer}]
      :error -> []
    end
  rescue
    _error -> []
  catch
    _kind, _reason -> []
  end

  defp normalize_cert(_cert), do: []

  defp normalize_certs(certs) do
    certs
    |> Enum.flat_map(&normalize_cert/1)
    |> Enum.uniq_by(& &1.der)
  end

  defp certificate_names(
         {:OTPCertificate, {:OTPTBSCertificate, _, _, _, issuer, _, subject, _, _, _, _}, _, _}
       ),
       do: {:ok, subject, issuer}

  defp certificate_names(_cert), do: :error

  defp select_from_chain(certs) do
    case build_leaf_to_root_chain(certs) do
      {:ok, chain} -> select_authority_thumbprint(chain)
      :error -> select_authority_thumbprint(certs)
    end
  end

  defp leaf_certificate(certs) do
    normalized = normalize_certs(certs)

    case build_leaf_to_root_chain(normalized) do
      {:ok, [leaf | _rest]} ->
        {:ok, leaf}

      :error ->
        case Enum.find(normalized, fn cert -> cert.subject != cert.issuer end) ||
               List.first(normalized) do
          nil -> {:error, :oidc_discovery_tls_thumbprint_failed}
          leaf -> {:ok, leaf}
        end
    end
  end

  defp build_leaf_to_root_chain(certs) do
    issuer_subjects = MapSet.new(Enum.map(certs, & &1.issuer))

    leaf =
      Enum.find(certs, fn cert ->
        cert.subject != cert.issuer and not MapSet.member?(issuer_subjects, cert.subject)
      end) || Enum.find(certs, fn cert -> cert.subject != cert.issuer end)

    if leaf do
      chain = walk_to_root(leaf, certs, MapSet.new())
      {:ok, chain}
    else
      :error
    end
  end

  defp walk_to_root(cert, certs, seen_subjects) do
    cond do
      MapSet.member?(seen_subjects, cert.subject) ->
        [cert]

      cert.subject == cert.issuer ->
        [cert]

      true ->
        parent = Enum.find(certs, &(&1.subject == cert.issuer))

        if parent do
          [cert | walk_to_root(parent, certs, MapSet.put(seen_subjects, cert.subject))]
        else
          [cert]
        end
    end
  end

  defp select_authority_thumbprint(chain) do
    non_root = Enum.reject(chain, &(&1.subject == &1.issuer))

    case non_root do
      [] -> List.first(chain)
      [_leaf] -> List.first(non_root)
      _with_intermediate -> List.last(non_root)
    end
    |> case do
      nil -> {:error, :oidc_discovery_tls_thumbprint_failed}
      cert -> {:ok, cert}
    end
  end

  defp configured_thumbprint_allowed?(der, opts) do
    case configured_thumbprints(opts) do
      [] ->
        :ok

      thumbprints ->
        if MapSet.member?(MapSet.new(thumbprints), sha1_hex(der)) do
          :ok
        else
          {:error, :oidc_discovery_thumbprint_mismatch}
        end
    end
  end

  defp configured_thumbprints(opts) do
    opts
    |> Keyword.get(:thumbprints, [])
    |> List.wrap()
    |> Enum.map(&to_string/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(&String.downcase/1)
    |> Enum.uniq()
  end

  defp thumbprint_trust_fallback_reason?({:bad_cert, reason}),
    do: thumbprint_trust_fallback_reason?(reason)

  defp thumbprint_trust_fallback_reason?(reason)
       when reason in [:unknown_ca, :selfsigned_peer, :issuer_not_found, :invalid_issuer],
       do: true

  defp thumbprint_trust_fallback_reason?(_reason), do: false

  defp hostname_reference_ids(host) do
    case :inet.parse_address(String.to_charlist(host)) do
      {:ok, ip} -> [{:ip, ip}]
      {:error, _reason} -> [{:dns_id, host}]
    end
  end

  defp sha1_hex(der), do: :crypto.hash(:sha, der) |> Base.encode16(case: :lower)
end
