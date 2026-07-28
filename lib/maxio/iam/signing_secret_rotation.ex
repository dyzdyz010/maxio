defmodule Maxio.IAM.SigningSecretRotation do
  @moduledoc """
  Operator workflow for rotating IAM signing-secret envelope keys.

  Rotation is intentionally explicit. The service writes a local key ring file,
  updates this node's runtime application environment, and then optionally
  invokes `Maxio.IAM.rewrap_signing_secrets/1` so existing access-key and STS
  session envelopes move to the new current key.
  """

  alias Maxio.IAM.SigningSecretKeyring

  @version 1
  @default_rotate_after_seconds 86_400 * 90
  @keyring_lock_wait_ms 30_000
  @keyring_lock_retry_ms 50

  @type report :: map()

  @spec rotate(keyword()) :: {:ok, report()} | {:error, report()}
  def rotate(opts \\ []) do
    dry_run = Keyword.get(opts, :dry_run, true)

    with {:ok, path} <- keyring_file(opts),
         {:ok, snapshot} <- SigningSecretKeyring.snapshot(keyring_file: path),
         {:ok, key_id} <- rotation_key_id(opts, now(opts)),
         :ok <- ensure_new_key_id(snapshot, key_id),
         {:ok, key_b64} <- rotation_key_material(opts) do
      report = base_report(:planned, dry_run, path, snapshot, key_id)

      if dry_run do
        {:ok, %{report | status: :dry_run}}
      else
        commit_rotation(path, key_id, key_b64, now(opts), opts, report)
      end
    else
      {:error, reason} -> {:error, blocked_report(dry_run, reason)}
    end
  end

  @spec rotate_if_due(keyword()) :: {:ok, report()} | {:error, report()}
  def rotate_if_due(opts \\ []) do
    rotate_after_seconds = Keyword.get(opts, :rotate_after_seconds, @default_rotate_after_seconds)

    with {:ok, rotate_after_seconds} <-
           positive_integer(rotate_after_seconds, :invalid_rotate_after_seconds),
         {:ok, path} <- keyring_file(opts),
         {:ok, snapshot} <- SigningSecretKeyring.snapshot(keyring_file: path) do
      if Keyword.get(opts, :force, false) do
        rotate(Keyword.put(opts, :keyring_file, path))
      else
        case due?(snapshot, rotate_after_seconds, now(opts)) do
          {:ok, true} ->
            rotate(Keyword.put(opts, :keyring_file, path))

          {:ok, false} ->
            {:ok,
             base_report(:not_due, Keyword.get(opts, :dry_run, true), path, snapshot, nil)
             |> Map.put(:rotate_after_seconds, rotate_after_seconds)}

          {:error, reason} ->
            {:error, blocked_report(Keyword.get(opts, :dry_run, true), reason)}
        end
      end
    else
      {:error, reason} -> {:error, blocked_report(Keyword.get(opts, :dry_run, true), reason)}
    end
  end

  defp commit_rotation(path, key_id, key_b64, rotation_time, opts, report) do
    with {:ok, lock} <- acquire_keyring_lock(path) do
      try do
        commit_rotation_locked(path, key_id, key_b64, rotation_time, opts, report)
      after
        release_keyring_lock(lock)
      end
    else
      {:error, reason} -> {:error, report |> Map.put(:status, :blocked) |> add_error(reason)}
    end
  end

  defp commit_rotation_locked(path, key_id, key_b64, rotation_time, opts, report) do
    with {:ok, snapshot} <- SigningSecretKeyring.snapshot(keyring_file: path),
         :ok <- ensure_new_key_id(snapshot, key_id) do
      report = base_report(:planned, false, path, snapshot, key_id)
      write_rotation(path, snapshot, key_id, key_b64, rotation_time, opts, report)
    else
      {:error, reason} -> {:error, report |> Map.put(:status, :blocked) |> add_error(reason)}
    end
  end

  defp write_rotation(path, snapshot, key_id, key_b64, rotation_time, opts, report) do
    key_metadata =
      snapshot.key_metadata
      |> Map.take(Map.keys(snapshot.keys))
      |> Map.new(fn {existing_key_id, entry} ->
        {existing_key_id,
         Map.put(entry, "secret_key", Map.fetch!(snapshot.keys, existing_key_id))}
      end)
      |> Map.put(key_id, %{
        "secret_key" => key_b64,
        "created_at" => DateTime.to_iso8601(rotation_time)
      })

    payload = %{
      "version" => @version,
      "current_key_id" => key_id,
      "current_key_started_at" => DateTime.to_iso8601(rotation_time),
      "keys" => key_metadata
    }

    with :ok <- write_keyring_file(path, payload),
         :ok <- put_runtime_env(path, key_id, key_b64, payload["keys"]),
         {:ok, rewrap_report} <- maybe_rewrap(opts) do
      {:ok,
       report
       |> Map.put(:status, :rotated)
       |> Map.put(:rewrap, summarize_rewrap(rewrap_report))}
    else
      {:error, %{} = rewrap_report} ->
        {:error,
         report
         |> Map.put(:status, :rewrap_blocked)
         |> Map.put(:rewrap, summarize_rewrap(rewrap_report))
         |> add_error(:signing_secret_rewrap_blocked)}

      {:error, reason} ->
        {:error, report |> Map.put(:status, :blocked) |> add_error(reason)}
    end
  end

  defp acquire_keyring_lock(path) do
    lock_path = "#{path}.lock"
    deadline = System.monotonic_time(:millisecond) + @keyring_lock_wait_ms

    with :ok <- File.mkdir_p(Path.dirname(lock_path)) do
      try_acquire_keyring_lock(lock_path, deadline)
    else
      {:error, _reason} -> {:error, :access_key_secret_keyring_file_lock_failed}
    end
  end

  defp try_acquire_keyring_lock(lock_path, deadline) do
    case File.open(lock_path, [:write, :exclusive, :binary]) do
      {:ok, io} ->
        _ =
          IO.binwrite(
            io,
            "pid=#{inspect(self())} acquired_at=#{DateTime.utc_now() |> DateTime.to_iso8601()}\n"
          )

        {:ok, {lock_path, io}}

      {:error, :eexist} ->
        if System.monotonic_time(:millisecond) >= deadline do
          {:error, :access_key_secret_keyring_file_locked}
        else
          Process.sleep(@keyring_lock_retry_ms)
          try_acquire_keyring_lock(lock_path, deadline)
        end

      {:error, _reason} ->
        {:error, :access_key_secret_keyring_file_lock_failed}
    end
  end

  defp release_keyring_lock({lock_path, io}) do
    _ = File.close(io)
    _ = File.rm(lock_path)
    :ok
  end

  defp maybe_rewrap(opts) do
    if Keyword.get(opts, :rewrap, true) do
      Maxio.IAM.rewrap_signing_secrets(dry_run: false)
    else
      {:ok, %{status: :skipped, dry_run: false, totals: %{rewrapped: 0, errors: 0}}}
    end
  end

  defp put_runtime_env(path, key_id, key_b64, keys) do
    encoded_keys =
      Map.new(keys, fn
        {entry_key_id, %{"secret_key" => value}} -> {entry_key_id, value}
        {entry_key_id, value} when is_binary(value) -> {entry_key_id, value}
      end)

    Application.put_env(:maxio, :access_key_secret,
      keyring_file: path,
      current_key_id: key_id,
      secret_key: key_b64,
      keys: encoded_keys
    )

    :ok
  end

  defp write_keyring_file(path, payload) do
    dir = Path.dirname(path)
    tmp = "#{path}.tmp.#{System.unique_integer([:positive])}"

    with :ok <- File.mkdir_p(dir),
         {:ok, json} <- Jason.encode(payload, pretty: true),
         :ok <- write_new_secret_file(tmp, json <> "\n"),
         :ok <- replace_file(tmp, path) do
      :ok
    else
      {:error, _reason} ->
        File.rm(tmp)
        {:error, :access_key_secret_keyring_file_write_failed}
    end
  end

  defp replace_file(tmp, path) do
    case File.rename(tmp, path) do
      :ok ->
        with :ok <- restrict_file(path),
             :ok <- sync_parent_dir_best_effort(path) do
          :ok
        end

      {:error, :eexist} ->
        overwrite_existing_file(tmp, path)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp overwrite_existing_file(tmp, path) do
    with {:ok, contents} <- File.read(tmp),
         :ok <- write_existing_secret_file(path, contents),
         :ok <- File.rm(tmp),
         :ok <- sync_parent_dir_best_effort(path) do
      :ok
    end
  end

  defp write_new_secret_file(path, contents) do
    case File.open(path, [:write, :exclusive, :binary]) do
      {:ok, io} ->
        try do
          with :ok <- restrict_file(path),
               :ok <- write_secret_contents(io, contents),
               :ok <- sync_secret_file(io) do
            :ok
          end
        after
          File.close(io)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp write_existing_secret_file(path, contents) do
    with :ok <- restrict_file(path) do
      case File.open(path, [:write, :binary]) do
        {:ok, io} ->
          try do
            with :ok <- write_secret_contents(io, contents),
                 :ok <- sync_secret_file(io) do
              :ok
            end
          after
            File.close(io)
          end

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp write_secret_contents(io, contents) do
    case IO.binwrite(io, contents) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp sync_secret_file(io) do
    case :file.sync(io) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp restrict_file(path), do: File.chmod(path, 0o600)

  defp sync_parent_dir_best_effort(path) do
    path
    |> Path.dirname()
    |> File.open([:read, :raw])
    |> case do
      {:ok, io} ->
        _ = :file.sync(io)
        _ = File.close(io)
        :ok

      {:error, _reason} ->
        :ok
    end
  end

  defp keyring_file(opts) do
    path =
      Keyword.get(opts, :keyring_file) ||
        Application.get_env(:maxio, :access_key_secret, [])[:keyring_file]

    cond do
      not is_binary(path) or String.trim(path) == "" ->
        {:error, :signing_secret_rotation_requires_keyring_file}

      String.contains?(path, ["\0", "\r", "\n"]) ->
        {:error, :invalid_access_key_secret_keyring_file}

      true ->
        {:ok, path}
    end
  end

  defp rotation_key_id(opts, rotation_time) do
    key_id =
      Keyword.get(opts, :key_id) ||
        "iam-#{Calendar.strftime(rotation_time, "%Y%m%dT%H%M%SZ")}-#{random_suffix()}"

    validate_key_id(key_id)
  end

  defp ensure_new_key_id(snapshot, key_id) do
    if Map.has_key?(snapshot.keys, key_id) do
      {:error, :access_key_secret_key_conflict}
    else
      :ok
    end
  end

  defp rotation_key_material(opts) do
    case Keyword.get(opts, :key_b64) do
      nil ->
        {:ok, :crypto.strong_rand_bytes(32) |> Base.encode64()}

      key_b64 ->
        with {:ok, _raw_key} <- decode_key_material(key_b64), do: {:ok, key_b64}
    end
  end

  defp due?(%{current_key_started_at: nil}, _rotate_after_seconds, _now),
    do: {:error, :missing_current_key_started_at}

  defp due?(%{current_key_started_at: started_at}, rotate_after_seconds, now) do
    {:ok, DateTime.diff(now, started_at, :second) >= rotate_after_seconds}
  end

  defp now(opts) do
    opts
    |> Keyword.get(:now, DateTime.utc_now())
    |> DateTime.truncate(:second)
  end

  defp base_report(status, dry_run, path, snapshot, next_key_id) do
    %{
      status: status,
      dry_run: dry_run,
      keyring_file: path,
      previous_key_id: snapshot.current_key_id,
      next_key_id: next_key_id,
      key_count: map_size(snapshot.keys),
      current_key_started_at: snapshot.current_key_started_at,
      rewrap: nil,
      errors: []
    }
  end

  defp blocked_report(dry_run, reason) do
    %{
      status: :blocked,
      dry_run: dry_run,
      keyring_file: nil,
      previous_key_id: nil,
      next_key_id: nil,
      key_count: 0,
      current_key_started_at: nil,
      rewrap: nil,
      errors: [reason]
    }
  end

  defp add_error(report, reason), do: Map.update!(report, :errors, &(&1 ++ [reason]))

  defp summarize_rewrap(%{status: status, totals: totals}) do
    %{
      status: status,
      scanned: Map.get(totals, :scanned, 0),
      candidates: Map.get(totals, :candidates, 0),
      rewrapped: Map.get(totals, :rewrapped, 0),
      errors: Map.get(totals, :errors, 0)
    }
  end

  defp summarize_rewrap(other), do: %{status: inspect(other)}

  defp validate_key_id(key_id) when is_binary(key_id) do
    cond do
      key_id == "" -> {:error, :invalid_access_key_secret_key_id}
      byte_size(key_id) > 128 -> {:error, :invalid_access_key_secret_key_id}
      String.contains?(key_id, ["\0", "\r", "\n"]) -> {:error, :invalid_access_key_secret_key_id}
      true -> {:ok, key_id}
    end
  end

  defp validate_key_id(_key_id), do: {:error, :invalid_access_key_secret_key_id}

  defp decode_key_material(key_b64) when is_binary(key_b64) do
    case Base.decode64(key_b64) do
      {:ok, key} when byte_size(key) == 32 -> {:ok, key}
      _other -> {:error, :invalid_access_key_secret_key}
    end
  end

  defp decode_key_material(_key_b64), do: {:error, :invalid_access_key_secret_key}

  defp positive_integer(value, _reason) when is_integer(value) and value > 0, do: {:ok, value}
  defp positive_integer(_value, reason), do: {:error, reason}

  defp random_suffix do
    4
    |> :crypto.strong_rand_bytes()
    |> Base.url_encode64(padding: false)
  end
end
