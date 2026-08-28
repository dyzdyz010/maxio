defmodule Maxio.KMS do
  @moduledoc """
  Provider-agnostic local KMS facade used by S3 SSE-KMS.

  The built-in `Maxio.KMS.LocalProvider` is a local compatibility provider. It
  preserves the SSE-KMS envelope contract for development and tests, but it is
  not an AWS KMS, external KMS, or HSM boundary. Production-grade external
  providers must be supplied through the provider behaviour and should expose
  their own operational evidence.
  """

  alias Maxio.S3.Error
  @local_provider Maxio.KMS.LocalProvider

  @spec default_key_id() :: String.t()
  def default_key_id, do: default_key_id(provider())

  @doc """
  Returns non-secret KMS boundary status for operator evidence.

  The status intentionally exposes provider shape and local key configuration
  presence/counts, never raw wrapping keys or data keys.
  """
  @spec status() :: map()
  def status do
    provider = provider()

    %{
      provider: provider,
      provider_name: inspect(provider),
      mode: provider_mode(provider),
      default_key_id: default_key_id(provider),
      local_provider?: provider == @local_provider,
      external_provider?: provider != @local_provider,
      production_hsm?: production_hsm?(provider),
      local_master_key_configured?: local_master_key_configured?(),
      local_named_key_count: local_named_key_count(),
      boundary: boundary(provider)
    }
  end

  defp default_key_id(provider) do
    if callback_exported?(provider, :default_key_id, 0) do
      provider.default_key_id()
    else
      "alias/maxio/default"
    end
  end

  # `function_exported?/3` answers "is this function exported by a **loaded**
  # module", so a provider that has simply never been called yet answers `false`
  # and every optional provider capability below silently degrades to its
  # built-in fallback. Under interactive code loading (`mix run`, `iex -S mix`,
  # every `mix maxio.*` task, `mix test`) that is the normal state of a fresh
  # node, so the first SSE-KMS request would pick `alias/maxio/default` instead
  # of the configured `:default_key_id` — a wrong key with no error and no log
  # (AGENTS.md §3: 绝不静默失败). Probing the pluggable backend must therefore
  # load it first, exactly like every other backend probe in this codebase
  # (`Maxio.Policy.Store.callback_exported?/3`, `Maxio.ObjectMeta`,
  # `Maxio.Cluster.DriveStats`, `Maxio.IAM`).
  defp callback_exported?(provider, function, arity) do
    Code.ensure_loaded?(provider) and function_exported?(provider, function, arity)
  end

  @spec generate_data_key!(String.t() | nil, String.t() | nil) :: Maxio.KMS.Provider.data_key()
  def generate_data_key!(key_id, context_b64) do
    key_id = normalize_key_id(key_id)
    context = context_bytes!(context_b64)

    case provider().generate_data_key(key_id, context) do
      {:ok, %{plaintext_key: plaintext_key} = data_key}
      when is_binary(plaintext_key) and byte_size(plaintext_key) == 32 ->
        data_key

      {:ok, _invalid} ->
        raise Error.new(:internal_error, message: "KMS provider returned an invalid data key")

      {:error, reason} ->
        raise kms_error(reason)
    end
  end

  @spec decrypt_data_key!(map()) :: binary()
  def decrypt_data_key!(%{} = envelope) do
    context = context_bytes!(envelope_value(envelope, :kms_encryption_context_b64))

    case provider().decrypt_data_key(envelope, context) do
      {:ok, plaintext_key} when is_binary(plaintext_key) and byte_size(plaintext_key) == 32 ->
        plaintext_key

      {:ok, _invalid} ->
        raise "SSE-KMS DEK unwrap failed: provider returned an invalid data key"

      {:error, reason} ->
        raise "SSE-KMS DEK unwrap failed: #{inspect(reason)}"
    end
  end

  defp normalize_key_id(nil), do: default_key_id()
  defp normalize_key_id(""), do: default_key_id()
  defp normalize_key_id(key_id) when is_binary(key_id), do: key_id

  defp context_bytes!(nil), do: <<>>
  defp context_bytes!(""), do: <<>>

  defp context_bytes!(context_b64) when is_binary(context_b64) do
    case Base.decode64(context_b64) do
      {:ok, bytes} -> bytes
      :error -> raise "SSE-KMS encryption context is not valid base64"
    end
  end

  defp provider do
    :maxio
    |> Application.get_env(:kms, [])
    |> Keyword.get(:provider, @local_provider)
  end

  defp provider_mode(@local_provider), do: :local_compat
  defp provider_mode(_provider), do: :external_provider

  defp production_hsm?(provider) do
    if callback_exported?(provider, :production_hsm?, 0),
      do: provider.production_hsm?() == true,
      else: false
  end

  defp boundary(@local_provider),
    do: "local compatibility provider; not external KMS/HSM"

  defp boundary(_provider),
    do: "external provider configured; production HSM capability must be proven by provider"

  defp local_master_key_configured? do
    kms = Application.get_env(:maxio, :kms, [])
    sse = Application.get_env(:maxio, :sse, [])

    named_keys_configured?(Keyword.get(kms, :keys)) or
      configured_secret?(Keyword.get(kms, :master_key)) or
      configured_secret?(Keyword.get(sse, :master_key))
  end

  defp local_named_key_count do
    case Application.get_env(:maxio, :kms, []) |> Keyword.get(:keys) do
      keys when is_map(keys) -> map_size(keys)
      _other -> 0
    end
  end

  defp named_keys_configured?(keys) when is_map(keys), do: map_size(keys) > 0
  defp named_keys_configured?(_keys), do: false

  defp configured_secret?(value) when is_binary(value), do: value != ""
  defp configured_secret?(_value), do: false

  defp kms_error(reason)
       when reason in [:unknown_key_id, :missing_master_key, :invalid_master_key] do
    Error.new(:invalid_argument, message: "Invalid SSE-KMS key id or local KMS configuration")
  end

  defp kms_error(_reason),
    do: Error.new(:internal_error, message: "KMS data key generation failed")

  defp envelope_value(envelope, key),
    do: Map.get(envelope, key) || Map.get(envelope, Atom.to_string(key))
end
