defmodule Maxio.Auth.SigV4.PostPolicy do
  @moduledoc """
  SigV4 POST Object policy form generator.

  POST Object signs the base64-encoded policy document, not a canonical HTTP
  request. This module is intentionally transport-free; callers provide the
  externally visible S3 base URL, bucket/key, credentials, and limits.
  """

  alias Maxio.Auth.SigV4.Signer

  @algorithm "AWS4-HMAC-SHA256"
  @service "s3"
  @max_expires 604_800
  @max_object_size 5_368_709_120
  @success_statuses ~w(200 201 204)
  @field_order ~w(key x-amz-algorithm x-amz-credential x-amz-date x-amz-security-token success_action_status)
  @tail_field_order ~w(policy x-amz-signature)
  @reserved_extra_fields MapSet.new(
                           ~w(bucket file key policy x-amz-signature x-amz-algorithm x-amz-credential x-amz-date x-amz-security-token success_action_status)
                         )

  @type credentials :: %{
          required(:access_key) => String.t(),
          required(:secret_key) => String.t(),
          optional(:session_token) => String.t() | nil
        }

  @type key_policy ::
          String.t()
          | {:starts_with, prefix :: String.t(), form_key :: String.t()}

  @type form :: %{
          required(:url) => String.t(),
          required(:fields) => [{String.t(), String.t()}],
          required(:policy) => String.t(),
          required(:signature) => String.t(),
          required(:expires_at) => DateTime.t(),
          required(:max_size) => non_neg_integer(),
          required(:success_action_status) => String.t()
        }

  @spec build_form(String.t(), String.t(), key_policy(), credentials(), keyword()) ::
          {:ok, form()} | {:error, term()}
  def build_form(base_url, bucket, key_policy, credentials, opts \\ []) do
    with {:ok, uri} <- base_uri(base_url),
         {:ok, access_key} <- credential(credentials, :access_key),
         {:ok, secret_key} <- credential(credentials, :secret_key),
         {:ok, expires} <- expires(opts),
         {:ok, max_size} <- max_size(opts),
         {:ok, success_status} <- success_action_status(opts),
         {:ok, extra_fields} <- extra_fields(opts),
         {:ok, key_policy} <- key_policy(bucket, key_policy) do
      now = Keyword.get(opts, :now, DateTime.utc_now())
      region = Keyword.get(opts, :region, region())
      session_token = session_token(credentials)

      amz_date = Calendar.strftime(now, "%Y%m%dT%H%M%SZ")
      scope_date = Calendar.strftime(now, "%Y%m%d")
      scope = "#{scope_date}/#{region}/#{@service}/aws4_request"
      credential = "#{access_key}/#{scope}"
      expires_at = DateTime.add(now, expires, :second) |> DateTime.truncate(:second)

      core_fields =
        %{
          "key" => key_policy.form_key,
          "x-amz-algorithm" => @algorithm,
          "x-amz-credential" => credential,
          "x-amz-date" => amz_date,
          "success_action_status" => success_status
        }
        |> maybe_put_session_token(session_token)

      fields = Map.merge(core_fields, Map.new(extra_fields))

      policy =
        policy_document(bucket, key_policy, core_fields, extra_fields, expires_at, max_size)

      policy_b64 = policy |> Jason.encode!() |> Base.encode64()
      signing_key = Signer.derive_signing_key(secret_key, scope_date, region, @service)
      signature = Signer.signature(signing_key, policy_b64)

      fields =
        fields
        |> Map.put("policy", policy_b64)
        |> Map.put("x-amz-signature", signature)
        |> ordered_fields(extra_fields)

      {:ok,
       %{
         url: bucket_url(uri, bucket),
         fields: fields,
         policy: policy_b64,
         signature: signature,
         expires_at: expires_at,
         max_size: max_size,
         success_action_status: success_status
       }}
    end
  end

  @spec max_expires() :: pos_integer()
  def max_expires, do: @max_expires

  @spec max_object_size() :: pos_integer()
  def max_object_size, do: @max_object_size

  defp policy_document(bucket, key_policy, core_fields, extra_fields, expires_at, max_size) do
    conditions =
      [
        %{"bucket" => bucket},
        key_policy.condition,
        ["content-length-range", 0, max_size]
      ] ++
        Enum.map(extra_fields, fn {name, value} -> %{name => value} end) ++
        (core_fields
         |> Map.delete("key")
         |> Enum.map(fn {name, value} -> %{name => value} end))

    %{
      "expiration" => DateTime.to_iso8601(expires_at),
      "conditions" => conditions
    }
  end

  defp base_uri(base_url) when is_binary(base_url) do
    uri = URI.parse(String.trim_trailing(base_url, "/"))

    cond do
      uri.scheme not in ["http", "https"] -> {:error, :invalid_base_url}
      is_nil(uri.host) or uri.host == "" -> {:error, :invalid_base_url}
      not is_nil(uri.userinfo) -> {:error, :invalid_base_url}
      is_binary(uri.path) and uri.path not in ["", "/"] -> {:error, :invalid_base_url}
      not is_nil(uri.query) -> {:error, :invalid_base_url}
      not is_nil(uri.fragment) -> {:error, :invalid_base_url}
      true -> {:ok, %{uri | path: nil}}
    end
  end

  defp base_uri(_base_url), do: {:error, :invalid_base_url}

  defp credential(credentials, field) when is_map(credentials) do
    case Map.get(credentials, field) || Map.get(credentials, Atom.to_string(field)) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _other -> {:error, {:missing_credential, field}}
    end
  end

  defp credential(_credentials, field), do: {:error, {:missing_credential, field}}

  defp expires(opts) do
    value = Keyword.get(opts, :expires, 900)

    cond do
      is_integer(value) and value in 1..@max_expires ->
        {:ok, value}

      is_binary(value) ->
        case Integer.parse(value) do
          {integer, ""} when integer in 1..@max_expires -> {:ok, integer}
          _other -> {:error, :invalid_expires}
        end

      true ->
        {:error, :invalid_expires}
    end
  end

  defp max_size(opts) do
    value = Keyword.get(opts, :max_size, @max_object_size)

    cond do
      is_integer(value) and value in 1..@max_object_size ->
        {:ok, value}

      is_binary(value) ->
        case Integer.parse(value) do
          {integer, ""} when integer in 1..@max_object_size -> {:ok, integer}
          _other -> {:error, :invalid_max_size}
        end

      true ->
        {:error, :invalid_max_size}
    end
  end

  defp success_action_status(opts) do
    value = Keyword.get(opts, :success_action_status, "201") |> to_string()

    if value in @success_statuses do
      {:ok, value}
    else
      {:error, :invalid_success_action_status}
    end
  end

  defp extra_fields(opts) do
    opts
    |> Keyword.get(:fields, [])
    |> normalize_extra_fields()
  end

  defp normalize_extra_fields(fields) when is_list(fields) do
    Enum.reduce_while(fields, {:ok, [], MapSet.new()}, fn field, {:ok, acc, seen} ->
      with {:ok, name, value} <- normalize_extra_field(field),
           :ok <- validate_extra_field(name, value),
           false <- MapSet.member?(seen, name) do
        {:cont, {:ok, [{name, value} | acc], MapSet.put(seen, name)}}
      else
        true -> {:halt, {:error, :invalid_field}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, fields, _seen} -> {:ok, Enum.reverse(fields)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp normalize_extra_fields(_fields), do: {:error, :invalid_field}

  defp normalize_extra_field({name, value}) when is_binary(name) and is_binary(value),
    do: {:ok, name, value}

  defp normalize_extra_field(_field), do: {:error, :invalid_field}

  defp validate_extra_field(name, value) do
    cond do
      name == "" or value == "" ->
        {:error, :invalid_field}

      MapSet.member?(@reserved_extra_fields, name) ->
        {:error, :invalid_field}

      String.starts_with?(name, "x-ignore-") ->
        {:error, :invalid_field}

      String.contains?(name, ["\0", "\r", "\n", "\""]) ->
        {:error, :invalid_field}

      String.contains?(value, ["\0", "\r", "\n"]) ->
        {:error, :invalid_field}

      true ->
        :ok
    end
  end

  defp key_policy(bucket, key)
       when is_binary(bucket) and bucket != "" and is_binary(key) and key != "" do
    if String.contains?(key, "${filename}") do
      {:error, :invalid_bucket_key}
    else
      {:ok, %{form_key: key, condition: %{"key" => key}}}
    end
  end

  defp key_policy(bucket, {:starts_with, prefix, form_key})
       when is_binary(bucket) and bucket != "" and is_binary(prefix) and is_binary(form_key) and
              form_key != "" do
    cond do
      String.contains?(prefix, "${filename}") ->
        {:error, :invalid_bucket_key}

      not String.starts_with?(form_key, prefix) ->
        {:error, :invalid_bucket_key}

      true ->
        {:ok, %{form_key: form_key, condition: ["starts-with", "$key", prefix]}}
    end
  end

  defp key_policy(_bucket, _key_policy), do: {:error, :invalid_bucket_key}

  defp session_token(credentials) do
    case Map.get(credentials, :session_token) || Map.get(credentials, "session_token") do
      token when is_binary(token) and token != "" -> token
      _other -> nil
    end
  end

  defp maybe_put_session_token(fields, nil), do: fields
  defp maybe_put_session_token(fields, token), do: Map.put(fields, "x-amz-security-token", token)

  defp ordered_fields(fields, extra_fields) do
    ordered_names =
      @field_order ++ Enum.map(extra_fields, &elem(&1, 0)) ++ @tail_field_order

    ordered_names
    |> Enum.flat_map(fn name ->
      case Map.fetch(fields, name) do
        {:ok, value} -> [{name, value}]
        :error -> []
      end
    end)
  end

  defp bucket_url(%URI{} = uri, bucket) do
    %URI{uri | path: "/" <> URI.encode(bucket), query: nil, fragment: nil}
    |> URI.to_string()
  end

  defp region do
    Application.fetch_env!(:maxio, :s3)
    |> Keyword.fetch!(:region)
  end
end
