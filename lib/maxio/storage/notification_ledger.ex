defmodule Maxio.Storage.NotificationLedger do
  @moduledoc """
  Disk representation helpers for retained bucket notification ledgers.

  The retained ledger is a small replicated metadata record, not an object body.
  It uses the same JSON `meta.json` encoding as object sidecars so all backends
  can reuse their existing temp-dir, sidecar write, and quorum commit machinery.
  """

  @format "maxio-notification-ledger/1"
  @uuid_re ~r/\A[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\z/

  @doc "Wrap one retained ledger entry for disk storage."
  @spec sidecar(map()) :: map()
  def sidecar(entry) when is_map(entry) do
    %{
      "format" => @format,
      "entry" => stringify_keys(entry)
    }
  end

  @doc "Extract a retained ledger entry from a disk sidecar."
  @spec entry(map()) :: {:ok, map()} | {:error, :invalid_format}
  def entry(%{"format" => @format, "entry" => entry}) when is_map(entry),
    do: {:ok, stringify_keys(entry)}

  def entry(_meta), do: {:error, :invalid_format}

  @doc "Return a stable id from an entry, accepting atom or string keys."
  @spec id(map()) :: String.t() | nil
  def id(entry) when is_map(entry) do
    value(entry, "id")
  end

  @doc "Validate retained ledger ids before using them as path components."
  @spec validate_id(term()) :: {:ok, String.t()} | {:error, :invalid_notification_ledger_id}
  def validate_id(id) when is_binary(id) do
    if Regex.match?(@uuid_re, id),
      do: {:ok, String.downcase(id)},
      else: {:error, :invalid_notification_ledger_id}
  end

  def validate_id(_id), do: {:error, :invalid_notification_ledger_id}

  @doc "Build an invalid evidence placeholder that fails replay classification."
  @spec invalid_entry(String.t() | nil, String.t(), keyword()) :: map()
  def invalid_entry(id, reason, attrs \\ []) do
    %{
      "id" => id || "invalid",
      "bucket" => Keyword.get(attrs, :bucket),
      "key" => Keyword.get(attrs, :key),
      "invalid_retained_ledger" => true,
      "reason" => reason,
      "read_quorum" => Keyword.get(attrs, :read_quorum),
      "replicas" => Keyword.get(attrs, :replicas),
      "signature_groups" => Keyword.get(attrs, :signature_groups)
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  @doc "Return the original object key from an entry, accepting atom or string keys."
  @spec key(map()) :: String.t() | nil
  def key(entry) when is_map(entry), do: value(entry, "key")

  @doc "Return the bucket from an entry, accepting atom or string keys."
  @spec bucket(map()) :: String.t() | nil
  def bucket(entry) when is_map(entry), do: value(entry, "bucket")

  @doc """
  Choose canonical retained ledger entries from replicated sidecars.

  Replicas are grouped by id and content signature. A signature group that
  reaches read quorum is returned. Evidence that exists but cannot reach quorum
  is returned as an invalid placeholder so overwrite preflight and scanners fail
  closed instead of treating partial/corrupt evidence as absence.
  """
  @spec canonical_entries([{String.t(), map()}], pos_integer()) :: [map()]
  def canonical_entries(replicas, read_quorum)
      when is_list(replicas) and is_integer(read_quorum) and read_quorum > 0 do
    replicas
    |> Enum.group_by(fn {id, _entry} -> id end)
    |> Enum.flat_map(fn {_id, entries} ->
      entries
      |> Enum.group_by(fn {_id, entry} -> signature(entry) end)
      |> Map.values()
      |> canonical_group_or_invalid(read_quorum)
    end)
    |> Enum.sort_by(fn entry -> {bucket(entry) || "", key(entry) || "", id(entry) || ""} end)
  end

  defp canonical_group_or_invalid(groups, read_quorum) do
    winning_groups = Enum.filter(groups, fn group -> length(group) >= read_quorum end)
    [{id, entry} | _] = List.first(groups)

    cond do
      length(winning_groups) == 1 and length(groups) == 1 ->
        [[{_id, entry} | _]] = winning_groups
        [entry]

      length(winning_groups) >= 1 ->
        [
          invalid_entry(id, "divergent_replicas",
            bucket: bucket(entry),
            key: key(entry),
            read_quorum: read_quorum,
            replicas: Enum.reduce(groups, 0, fn group, acc -> acc + length(group) end),
            signature_groups: length(groups)
          )
        ]

      true ->
        [
          invalid_entry(id, "read_quorum_not_met",
            bucket: bucket(entry),
            key: key(entry),
            read_quorum: read_quorum,
            replicas: Enum.reduce(groups, 0, fn group, acc -> acc + length(group) end),
            signature_groups: length(groups)
          )
        ]
    end
  end

  @doc "Content signature used for quorum grouping."
  @spec signature(map()) :: binary()
  def signature(entry) when is_map(entry) do
    :crypto.hash(:sha256, :erlang.term_to_binary(stringify_keys(entry)))
  end

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), stringify_value(value)}
      {key, value} when is_binary(key) -> {key, stringify_value(value)}
      {key, value} -> {to_string(key), stringify_value(value)}
    end)
  end

  defp stringify_value(value) when is_map(value), do: stringify_keys(value)
  defp stringify_value(value) when is_list(value), do: Enum.map(value, &stringify_value/1)
  defp stringify_value(value), do: value

  defp value(map, key) do
    Map.get(map, key) || Map.get(map, atom_key(key))
  end

  defp atom_key("id"), do: :id
  defp atom_key("bucket"), do: :bucket
  defp atom_key("key"), do: :key
  defp atom_key(_key), do: :__maxio_unknown_key__
end
