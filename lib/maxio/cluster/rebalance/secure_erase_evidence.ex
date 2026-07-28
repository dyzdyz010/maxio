defmodule Maxio.Cluster.Rebalance.SecureEraseEvidence do
  @moduledoc """
  Operator-attested secure erase evidence for physical purge workflows.

  This module validates evidence only. It never performs device sanitize,
  cryptographic erase, filesystem deletion, topology mutation, or scheduler
  automation. The goal is to make secure-erase evidence auditable and
  fail-closed when an operator explicitly requires it before quarantine purge.
  """

  alias Maxio.Cluster.Rebalance.Job

  @allowed_methods ~w(cryptographic_erase ata_secure_erase nvme_sanitize vendor_sanitize external_attestation)
  @hex64 ~r/\A[0-9a-f]{64}\z/
  @atom_keys %{
    "certificate_hash" => :certificate_hash,
    "drive" => :drive,
    "endpoints" => :endpoints,
    "evidence_id" => :evidence_id,
    "issued_at" => :issued_at,
    "job_id" => :job_id,
    "manifest_hash" => :manifest_hash,
    "method" => :method,
    "node" => :node,
    "operator" => :operator,
    "quarantine_id" => :quarantine_id,
    "serial" => :serial,
    "serial_hash" => :serial_hash,
    "wwid" => :wwid,
    "wwid_hash" => :wwid_hash
  }

  @spec prepare(Job.t(), map(), keyword()) :: {:ok, map()} | {:error, term(), map()}
  def prepare(%Job{} = job, %{} = preflight, opts \\ []) do
    required? = Keyword.get(opts, :require_secure_erase_evidence, false)

    case Keyword.get(opts, :secure_erase_evidence) do
      nil when required? ->
        summary = summary("missing", required?, %{errors: ["secure_erase_evidence_missing"]})
        {:error, :secure_erase_evidence_missing, summary}

      nil ->
        {:ok, summary("not_collected", required?)}

      source ->
        with {:ok, certificate} <- load(source),
             {:ok, normalized} <- validate_certificate(certificate, job, preflight) do
          {:ok, summary("ok", required?, normalized)}
        else
          {:error, reason} ->
            invalid_result(reason, required?)
        end
    end
  end

  defp invalid_result(reason, true) do
    summary = summary("invalid", true, %{errors: [inspect(reason)]})
    {:error, reason, summary}
  end

  defp invalid_result(reason, false) do
    summary = summary("invalid", false, %{errors: [inspect(reason)]})
    {:ok, summary}
  end

  defp load(%{} = certificate), do: {:ok, certificate}

  defp load(path) when is_binary(path) do
    with {:ok, json} <- File.read(path),
         {:ok, certificate} <- Jason.decode(json),
         true <- is_map(certificate) do
      {:ok, certificate}
    else
      {:error, reason} -> {:error, {:secure_erase_evidence_file_error, reason}}
      false -> {:error, :secure_erase_evidence_not_object}
    end
  end

  defp load(_source), do: {:error, :invalid_secure_erase_evidence_source}

  defp validate_certificate(certificate, %Job{} = job, preflight) do
    expected_endpoints = expected_endpoints(preflight)
    endpoints = value(certificate, "endpoints", [])

    normalized = %{
      method: value(certificate, "method"),
      issued_at: value(certificate, "issued_at"),
      operator: value(certificate, "operator"),
      job_id: value(certificate, "job_id"),
      quarantine_id: value(certificate, "quarantine_id"),
      manifest_hash: value(certificate, "manifest_hash"),
      endpoints: endpoints
    }

    with :ok <- require_equal(normalized.job_id, job.id, :job_id_mismatch),
         :ok <-
           require_equal(
             normalized.quarantine_id,
             preflight.quarantine_id,
             :quarantine_id_mismatch
           ),
         :ok <-
           require_equal(
             normalized.manifest_hash,
             preflight.manifest_hash,
             :manifest_hash_mismatch
           ),
         :ok <- require_allowed_method(normalized.method),
         :ok <- require_non_empty(normalized.operator, :operator_required),
         {:ok, issued_at} <- parse_issued_at(normalized.issued_at),
         {:ok, endpoint_summaries} <- validate_endpoints(endpoints, expected_endpoints) do
      {:ok,
       %{
         method: normalized.method,
         issued_at: DateTime.to_iso8601(issued_at),
         operator: normalized.operator,
         certificate_hash: certificate_hash(certificate),
         endpoints: length(endpoint_summaries),
         samples: endpoint_summaries,
         errors: []
       }}
    end
  end

  defp expected_endpoints(%{} = preflight) do
    preflight
    |> Map.get(:physical_removal_preflight, %{})
    |> Map.get(:target_endpoints, %{})
    |> Map.get("endpoints", [])
    |> Enum.map(fn %{} = endpoint ->
      %{
        "node" => value(endpoint, "node"),
        "drive" => value(endpoint, "drive")
      }
    end)
    |> Enum.sort_by(&{&1["node"], &1["drive"]})
  end

  defp validate_endpoints(endpoints, expected) when is_list(endpoints) and expected != [] do
    with {:ok, actual} <- normalize_endpoint_evidence(endpoints),
         true <- Enum.map(actual, &Map.take(&1, ["node", "drive"])) == expected do
      {:ok, actual}
    else
      false -> {:error, :endpoint_manifest_mismatch}
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_endpoints(_endpoints, []), do: {:error, :missing_expected_endpoints}
  defp validate_endpoints(_endpoints, _expected), do: {:error, :invalid_endpoint_evidence}

  defp normalize_endpoint_evidence(endpoints) do
    endpoints
    |> Enum.reduce_while({:ok, []}, fn
      %{} = endpoint, {:ok, acc} ->
        case normalize_endpoint(endpoint) do
          {:ok, normalized} -> {:cont, {:ok, [normalized | acc]}}
          {:error, reason} -> {:halt, {:error, reason}}
        end

      _endpoint, _acc ->
        {:halt, {:error, :invalid_endpoint_evidence}}
    end)
    |> case do
      {:ok, normalized} -> {:ok, Enum.sort_by(normalized, &{&1["node"], &1["drive"]})}
      {:error, reason} -> {:error, reason}
    end
  end

  defp normalize_endpoint(endpoint) do
    node = value(endpoint, "node")
    drive = value(endpoint, "drive")
    serial_hash = value(endpoint, "serial_hash")
    wwid_hash = value(endpoint, "wwid_hash")
    evidence_id = value(endpoint, "evidence_id")

    cond do
      value(endpoint, "serial") != nil or value(endpoint, "wwid") != nil ->
        {:error, :raw_hardware_identifier_present}

      not non_empty?(node) or not non_empty?(drive) ->
        {:error, :endpoint_identity_required}

      not hash_or_nil?(serial_hash) ->
        {:error, :invalid_serial_hash}

      not hash_or_nil?(wwid_hash) ->
        {:error, :invalid_wwid_hash}

      not evidence_id_or_nil?(evidence_id) ->
        {:error, :invalid_evidence_id}

      not (non_empty?(serial_hash) or non_empty?(wwid_hash) or non_empty?(evidence_id)) ->
        {:error, :endpoint_evidence_identifier_required}

      true ->
        {:ok,
         %{"node" => node, "drive" => drive}
         |> maybe_put("serial_hash", serial_hash)
         |> maybe_put("wwid_hash", wwid_hash)
         |> maybe_put("evidence_id_hash", hash_identifier(evidence_id))}
    end
  end

  defp require_equal(value, expected, _reason) when value == expected, do: :ok
  defp require_equal(_value, _expected, reason), do: {:error, reason}

  defp require_allowed_method(method) when method in @allowed_methods, do: :ok
  defp require_allowed_method(_method), do: {:error, :unsupported_secure_erase_method}

  defp require_non_empty(value, _reason) when is_binary(value) and value != "", do: :ok
  defp require_non_empty(_value, reason), do: {:error, reason}

  defp parse_issued_at(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> {:ok, datetime}
      {:error, reason} -> {:error, {:invalid_issued_at, reason}}
    end
  end

  defp parse_issued_at(_value), do: {:error, :issued_at_required}

  defp certificate_hash(certificate) do
    :sha256
    |> :crypto.hash(:erlang.term_to_binary(canonicalize(certificate)))
    |> Base.encode16(case: :lower)
  end

  defp canonicalize(%{} = map) do
    map
    |> Enum.reject(fn {key, _value} -> key in ["serial", :serial, "wwid", :wwid] end)
    |> Enum.map(fn {key, value} -> {to_string(key), canonicalize(value)} end)
    |> Enum.sort_by(&elem(&1, 0))
  end

  defp canonicalize(values) when is_list(values), do: Enum.map(values, &canonicalize/1)
  defp canonicalize(value), do: value

  defp summary(status, required?, attrs \\ %{}) do
    %{
      "enabled" => status != "not_collected" or required?,
      "required" => required?,
      "status" => status,
      "secure_erase_gate" => required?,
      "destructive_gate?" => required?,
      "method" => Map.get(attrs, :method),
      "issued_at" => Map.get(attrs, :issued_at),
      "operator" => Map.get(attrs, :operator),
      "certificate_hash" => Map.get(attrs, :certificate_hash),
      "endpoints" => Map.get(attrs, :endpoints, 0),
      "errors" => Map.get(attrs, :errors, []),
      "samples" => Map.get(attrs, :samples, [])
    }
  end

  defp value(%{} = map, key, default \\ nil),
    do: Map.get(map, key, atom_value(map, key, default))

  defp atom_value(map, key, default) do
    case Map.fetch(@atom_keys, key) do
      {:ok, atom_key} -> Map.get(map, atom_key, default)
      :error -> default
    end
  end

  defp non_empty?(value), do: is_binary(value) and value != ""
  defp hash_or_nil?(nil), do: true

  defp hash_or_nil?(value) when is_binary(value),
    do: String.match?(String.downcase(value), @hex64)

  defp hash_or_nil?(_value), do: false

  defp evidence_id_or_nil?(nil), do: true
  defp evidence_id_or_nil?(""), do: true
  defp evidence_id_or_nil?(value), do: is_binary(value)

  defp hash_identifier(nil), do: nil
  defp hash_identifier(""), do: nil

  defp hash_identifier(value),
    do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, ""), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
