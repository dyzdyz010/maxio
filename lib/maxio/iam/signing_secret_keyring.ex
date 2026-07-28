defmodule Maxio.IAM.SigningSecretKeyring do
  @moduledoc """
  Local key ring for IAM signing-secret envelopes.

  The legacy `:secret_key` option remains the current write key. Operators can
  add older read keys under `:keys` while moving `:current_key_id` and
  `:secret_key` forward.

  A writable local key ring file can also be configured with `:keyring_file`.
  When the file exists it is authoritative; when it is missing, the static app
  config remains the bootstrap fallback so operators can create the first file
  with the rotation task without taking the node down.
  """

  @default_key_id "local-default"

  @type key_id :: String.t()
  @type raw_key :: binary()
  @type encoded_key :: String.t()

  @type snapshot :: %{
          current_key_id: key_id(),
          current_key_started_at: DateTime.t() | nil,
          keys: %{key_id() => encoded_key()},
          key_metadata: %{key_id() => map()},
          source: :application_env | {:file, Path.t()}
        }

  @spec current_key() :: {:ok, {key_id(), raw_key()}} | {:error, term()}
  def current_key do
    with {:ok, cfg} <- resolved_config(),
         {:ok, key_id} <- current_key_id(cfg),
         {:ok, key} <- key(key_id, cfg) do
      {:ok, {key_id, key}}
    end
  end

  @spec key(key_id()) :: {:ok, raw_key()} | {:error, term()}
  def key(key_id) do
    with {:ok, cfg} <- resolved_config() do
      key(key_id, cfg)
    end
  end

  @spec default_key_id() :: key_id()
  def default_key_id, do: @default_key_id

  @doc """
  Returns the currently effective encoded key ring without exposing raw keys.

  This is intended for operator workflows such as rotation planning. Runtime
  encryption still goes through `current_key/0` and `key/1`.
  """
  @spec snapshot(keyword()) :: {:ok, snapshot()} | {:error, term()}
  def snapshot(opts \\ []) do
    with {:ok, cfg} <- resolved_config(opts),
         {:ok, current_key_id} <- current_key_id(cfg),
         {:ok, encoded_keys} <- configured_encoded_keys(cfg, current_key_id),
         {:ok, key_metadata} <- configured_key_metadata(cfg, current_key_id, encoded_keys) do
      {:ok,
       %{
         current_key_id: current_key_id,
         current_key_started_at: Keyword.get(cfg, :current_key_started_at),
         keys: encoded_keys,
         key_metadata: key_metadata,
         source: Keyword.get(cfg, :source, :application_env)
       }}
    end
  end

  defp key(key_id, cfg) do
    with {:ok, key_id} <- validate_key_id(key_id),
         {:ok, current_key_id} <- current_key_id(cfg),
         {:ok, keys} <- configured_keys(cfg, current_key_id) do
      case Map.fetch(keys, key_id) do
        {:ok, key} -> {:ok, key}
        :error -> {:error, :access_key_secret_key_not_configured}
      end
    end
  end

  defp resolved_config(opts \\ []) do
    cfg = Application.get_env(:maxio, :access_key_secret, [])
    explicit_path = keyring_file(opts)

    case explicit_path || keyring_file(cfg) do
      nil ->
        {:ok, Keyword.put(cfg, :source, :application_env)}

      path ->
        case load_file_config(path) do
          {:ok, file_cfg} -> {:ok, file_cfg}
          {:error, :enoent} -> {:ok, Keyword.put(cfg, :source, :application_env)}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp keyring_file(cfg) do
    Keyword.get(cfg, :keyring_file) || Keyword.get(cfg, :keyring_path)
  end

  defp load_file_config(path) when is_binary(path) and path != "" do
    case File.read(path) do
      {:ok, json} ->
        decode_file_config(path, json)

      {:error, :enoent} ->
        {:error, :enoent}

      {:error, _reason} ->
        {:error, :access_key_secret_keyring_file_unreadable}
    end
  end

  defp load_file_config(_path), do: {:error, :invalid_access_key_secret_keyring_file}

  defp decode_file_config(path, json) do
    with {:ok, decoded} <- Jason.decode(json),
         true <- is_map(decoded),
         true <- Map.get(decoded, "version", 1) == 1,
         keys = Map.get(decoded, "keys", %{}),
         true <- is_map(keys) do
      started_at =
        case Map.get(decoded, "current_key_started_at") do
          nil -> nil
          value when is_binary(value) -> parse_datetime(value)
          _other -> :error
        end

      case started_at do
        :error ->
          {:error, :invalid_access_key_secret_keyring_file}

        value ->
          {:ok,
           [
             source: {:file, path},
             current_key_id: Map.get(decoded, "current_key_id"),
             current_key_started_at: value,
             keys: keys
           ]}
      end
    else
      _other -> {:error, :invalid_access_key_secret_keyring_file}
    end
  end

  defp parse_datetime(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, 0} -> datetime
      _other -> :error
    end
  end

  defp current_key_id(cfg) do
    cfg
    |> Keyword.get(:current_key_id, Keyword.get(cfg, :key_id, @default_key_id))
    |> validate_key_id()
  end

  defp configured_keys(cfg, current_key_id) do
    with {:ok, encoded_keys} <- configured_encoded_keys(cfg, current_key_id),
         {:ok, keys} <- decode_keys(encoded_keys) do
      {:ok, keys}
    end
  end

  defp configured_encoded_keys(cfg, current_key_id) do
    with {:ok, keys} <- normalize_encoded_keys(Keyword.get(cfg, :keys, %{})),
         {:ok, keys} <-
           put_current_encoded_secret(keys, current_key_id, Keyword.get(cfg, :secret_key)) do
      {:ok, keys}
    end
  end

  defp decode_keys(nil), do: {:ok, %{}}

  defp decode_keys(keys) when is_map(keys) or is_list(keys) do
    Enum.reduce_while(keys, {:ok, %{}}, fn
      {key_id, key_b64}, {:ok, acc} ->
        with {:ok, key_id} <- normalize_key_id(key_id),
             {:ok, key} <- decode_key_material(key_b64) do
          case Map.fetch(acc, key_id) do
            {:ok, ^key} -> {:cont, {:ok, acc}}
            {:ok, _other_key} -> {:halt, {:error, :access_key_secret_key_conflict}}
            :error -> {:cont, {:ok, Map.put(acc, key_id, key)}}
          end
        else
          {:error, reason} -> {:halt, {:error, reason}}
        end

      _entry, {:ok, _acc} ->
        {:halt, {:error, :invalid_access_key_secret_keyring}}
    end)
  end

  defp decode_keys(_keys), do: {:error, :invalid_access_key_secret_keyring}

  defp normalize_encoded_keys(nil), do: {:ok, %{}}

  defp normalize_encoded_keys(keys) when is_map(keys) or is_list(keys) do
    Enum.reduce_while(keys, {:ok, %{}}, fn
      {key_id, entry}, {:ok, acc} ->
        with {:ok, key_id} <- normalize_key_id(key_id),
             {:ok, key_b64} <- encoded_key_material(entry),
             {:ok, _raw_key} <- decode_key_material(key_b64) do
          case Map.fetch(acc, key_id) do
            {:ok, ^key_b64} -> {:cont, {:ok, acc}}
            {:ok, _other_key} -> {:halt, {:error, :access_key_secret_key_conflict}}
            :error -> {:cont, {:ok, Map.put(acc, key_id, key_b64)}}
          end
        else
          {:error, reason} -> {:halt, {:error, reason}}
        end

      _entry, {:ok, _acc} ->
        {:halt, {:error, :invalid_access_key_secret_keyring}}
    end)
  end

  defp normalize_encoded_keys(_keys), do: {:error, :invalid_access_key_secret_keyring}

  defp configured_key_metadata(cfg, current_key_id, encoded_keys) do
    with {:ok, metadata} <- normalize_key_metadata(Keyword.get(cfg, :keys, %{})),
         {:ok, metadata} <-
           put_current_key_metadata(metadata, current_key_id, Keyword.get(cfg, :secret_key)) do
      {:ok,
       Map.new(encoded_keys, fn {key_id, key_b64} ->
         entry =
           metadata
           |> Map.get(key_id, %{})
           |> Map.put("secret_key", key_b64)

         {key_id, entry}
       end)}
    end
  end

  defp normalize_key_metadata(nil), do: {:ok, %{}}

  defp normalize_key_metadata(keys) when is_map(keys) or is_list(keys) do
    Enum.reduce_while(keys, {:ok, %{}}, fn
      {key_id, entry}, {:ok, acc} ->
        with {:ok, key_id} <- normalize_key_id(key_id),
             {:ok, key_b64} <- encoded_key_material(entry),
             {:ok, metadata} <- key_metadata(entry, key_b64) do
          {:cont, {:ok, Map.put(acc, key_id, metadata)}}
        else
          {:error, reason} -> {:halt, {:error, reason}}
        end

      _entry, {:ok, _acc} ->
        {:halt, {:error, :invalid_access_key_secret_keyring}}
    end)
  end

  defp normalize_key_metadata(_keys), do: {:error, :invalid_access_key_secret_keyring}

  defp key_metadata(%{} = entry, key_b64) do
    metadata =
      Map.new(entry, fn {key, value} -> {to_string(key), value} end)
      |> Map.put("secret_key", key_b64)

    {:ok, metadata}
  end

  defp key_metadata(_entry, key_b64), do: {:ok, %{"secret_key" => key_b64}}

  defp put_current_key_metadata(metadata, _current_key_id, nil), do: {:ok, metadata}

  defp put_current_key_metadata(metadata, current_key_id, secret_key_b64) do
    with {:ok, _raw_key} <- decode_key_material(secret_key_b64) do
      case Map.get(metadata, current_key_id) do
        %{"secret_key" => ^secret_key_b64} -> {:ok, metadata}
        %{"secret_key" => _other_key} -> {:error, :access_key_secret_key_conflict}
        _missing -> {:ok, Map.put(metadata, current_key_id, %{"secret_key" => secret_key_b64})}
      end
    end
  end

  defp put_current_encoded_secret(keys, _current_key_id, nil), do: {:ok, keys}

  defp put_current_encoded_secret(keys, current_key_id, secret_key_b64) do
    with {:ok, _raw_key} <- decode_key_material(secret_key_b64) do
      case Map.fetch(keys, current_key_id) do
        {:ok, ^secret_key_b64} -> {:ok, keys}
        {:ok, _other_key} -> {:error, :access_key_secret_key_conflict}
        :error -> {:ok, Map.put(keys, current_key_id, secret_key_b64)}
      end
    end
  end

  defp encoded_key_material(key_b64) when is_binary(key_b64), do: {:ok, key_b64}

  defp encoded_key_material(%{"secret_key" => key_b64}) when is_binary(key_b64),
    do: {:ok, key_b64}

  defp encoded_key_material(%{secret_key: key_b64}) when is_binary(key_b64),
    do: {:ok, key_b64}

  defp encoded_key_material(_entry), do: {:error, :invalid_access_key_secret_key}

  defp normalize_key_id(key_id) when is_atom(key_id),
    do: key_id |> Atom.to_string() |> validate_key_id()

  defp normalize_key_id(key_id), do: validate_key_id(key_id)

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
end
