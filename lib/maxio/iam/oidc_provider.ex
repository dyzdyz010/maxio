defmodule Maxio.IAM.OIDCProvider do
  @moduledoc "Persisted IAM OpenID Connect provider metadata for STS WebIdentity."

  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "iam_oidc_providers" do
    field :provider_arn, :string
    field :issuer_url, :string
    field :issuer_host_path, :string
    field :client_ids, {:array, :string}, default: []
    field :thumbprints, {:array, :string}, default: []
    field :jwks, :map, default: %{}
    field :jwks_fetched_at, :utc_datetime_usec
    field :discovery_document, :map, default: %{}
    field :status, :string, default: "active"
    field :tags, :map, default: %{}

    timestamps(type: :utc_datetime_usec)
  end

  @required [:provider_arn, :issuer_url, :issuer_host_path, :client_ids, :thumbprints, :jwks]
  @optional [:jwks_fetched_at, :discovery_document, :status, :tags]
  @status_values ~w(active disabled)
  @thumbprint_pattern ~r/\A[0-9A-Fa-f]{40}\z/
  @private_jwk_fields ~w(k d p q dp dq qi oth)

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(provider, attrs) do
    attrs = normalize_attrs(attrs)

    provider
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> validate_length(:provider_arn, min: 1, max: 512)
    |> validate_length(:issuer_url, min: 8, max: 2_048)
    |> validate_length(:issuer_host_path, min: 1, max: 2_048)
    |> validate_inclusion(:status, @status_values)
    |> validate_client_ids()
    |> validate_thumbprints()
    |> validate_jwks()
    |> validate_discovery_document()
    |> validate_tags()
    |> unique_constraint(:provider_arn, name: :iam_oidc_providers_provider_arn_index)
    |> unique_constraint(:issuer_host_path, name: :iam_oidc_providers_issuer_host_path_index)
  end

  defp normalize_attrs(attrs) when is_map(attrs) do
    attrs
    |> stringify_keys()
    |> normalize_issuer()
    |> normalize_string_list("client_ids")
    |> normalize_string_list("thumbprints")
    |> normalize_map("jwks")
    |> normalize_map("discovery_document")
    |> normalize_map("tags")
  end

  defp normalize_attrs(_attrs), do: %{}

  defp normalize_issuer(%{"issuer_url" => issuer_url} = attrs) when is_binary(issuer_url) do
    issuer_url = String.trim(issuer_url) |> String.trim_trailing("/")

    with {:ok, issuer_host_path} <- Maxio.STS.WebIdentity.issuer_host_path(issuer_url),
         {:ok, provider_arn} <- Maxio.STS.WebIdentity.oidc_provider_arn(issuer_url) do
      attrs
      |> Map.put("issuer_url", issuer_url)
      |> Map.put("issuer_host_path", issuer_host_path)
      |> Map.put("provider_arn", Map.get(attrs, "provider_arn") || provider_arn)
      |> reject_provider_arn_mismatch(provider_arn)
    else
      _error ->
        attrs
    end
  end

  defp normalize_issuer(attrs), do: attrs

  defp reject_provider_arn_mismatch(%{"provider_arn" => provider_arn} = attrs, provider_arn),
    do: attrs

  defp reject_provider_arn_mismatch(attrs, _derived_provider_arn),
    do: Map.put(attrs, "provider_arn", "__invalid_provider_arn_for_issuer__")

  defp normalize_string_list(attrs, key) do
    case Map.get(attrs, key) do
      nil ->
        attrs

      values when is_list(values) ->
        Map.put(attrs, key, Enum.map(values, &normalize_string/1))

      value when is_binary(value) ->
        Map.put(attrs, key, [normalize_string(value)])

      _other ->
        attrs
    end
  end

  defp normalize_map(attrs, key) do
    case Map.get(attrs, key) do
      nil -> attrs
      value when is_map(value) -> Map.put(attrs, key, stringify_keys(value))
      _other -> attrs
    end
  end

  defp normalize_string(value) when is_binary(value), do: String.trim(value)
  defp normalize_string(value), do: value

  defp validate_client_ids(changeset) do
    validate_change(changeset, :client_ids, fn :client_ids, client_ids ->
      cond do
        not is_list(client_ids) or client_ids == [] ->
          [client_ids: "must contain at least one client id"]

        length(client_ids) > 100 ->
          [client_ids: "must contain at most 100 client ids"]

        not Enum.all?(client_ids, &(is_binary(&1) and byte_size(&1) in 1..255)) ->
          [client_ids: "must contain non-empty string values of at most 255 bytes"]

        length(Enum.uniq(client_ids)) != length(client_ids) ->
          [client_ids: "must not contain duplicates"]

        true ->
          []
      end
    end)
  end

  defp validate_thumbprints(changeset) do
    validate_change(changeset, :thumbprints, fn :thumbprints, thumbprints ->
      cond do
        not is_list(thumbprints) or thumbprints == [] ->
          [thumbprints: "must contain at least one thumbprint"]

        length(thumbprints) > 5 ->
          [thumbprints: "must contain at most 5 thumbprints"]

        not Enum.all?(thumbprints, &(is_binary(&1) and Regex.match?(@thumbprint_pattern, &1))) ->
          [thumbprints: "must contain SHA1 thumbprint hex strings"]

        length(Enum.uniq(Enum.map(thumbprints, &String.downcase/1))) != length(thumbprints) ->
          [thumbprints: "must not contain duplicates"]

        true ->
          []
      end
    end)
  end

  defp validate_jwks(changeset) do
    validate_change(changeset, :jwks, fn :jwks, jwks ->
      case jwks do
        %{"keys" => keys} when is_list(keys) and keys != [] ->
          if Enum.all?(keys, &valid_public_jwk?/1) do
            []
          else
            [jwks: "must contain valid public JWK key objects"]
          end

        _other ->
          [jwks: "must be a JWKS object with non-empty keys"]
      end
    end)
  end

  defp validate_discovery_document(changeset) do
    validate_change(changeset, :discovery_document, fn :discovery_document, value ->
      if is_map(value), do: [], else: [discovery_document: "must be a map"]
    end)
  end

  defp validate_tags(changeset) do
    validate_change(changeset, :tags, fn :tags, value ->
      if is_map(value) do
        case value |> Maxio.Tags.map_to_list() |> Maxio.Tags.validate(:bucket) do
          :ok -> []
          {:error, :invalid_tag} -> [tags: "must contain valid IAM tag keys and values"]
        end
      else
        [tags: "must be a map"]
      end
    end)
  end

  defp stringify_keys(%_struct{} = value), do: value

  defp stringify_keys(%{} = map) do
    Map.new(map, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), stringify_keys(value)}
      {key, value} -> {key, stringify_keys(value)}
    end)
  end

  defp stringify_keys(list) when is_list(list), do: Enum.map(list, &stringify_keys/1)
  defp stringify_keys(value), do: value

  @doc false
  @spec public_jwks(map()) :: map()
  def public_jwks(%{"keys" => keys}) when is_list(keys) do
    keys =
      keys
      |> Enum.flat_map(fn key ->
        case public_jwk(key) do
          {:ok, public_key} -> [public_key]
          :error -> []
        end
      end)

    %{"keys" => keys}
  end

  def public_jwks(_jwks), do: %{"keys" => []}

  defp valid_public_jwk?(%{} = jwk) do
    case public_jwk(jwk) do
      {:ok, _public_key} -> true
      :error -> false
    end
  end

  defp valid_public_jwk?(_jwk), do: false

  defp public_jwk(%{} = jwk) do
    jwk = stringify_keys(jwk)

    with :ok <- reject_private_jwk_fields(jwk),
         :ok <- require_public_jwk_members(jwk) do
      _jwk = JOSE.JWK.from_map(jwk)
      {:ok, jwk}
    else
      :error -> :error
    end
  rescue
    _error -> :error
  catch
    _class, _reason -> :error
  end

  defp public_jwk(_jwk), do: :error

  defp reject_private_jwk_fields(jwk) do
    if Enum.any?(@private_jwk_fields, &Map.has_key?(jwk, &1)) do
      :error
    else
      :ok
    end
  end

  defp require_public_jwk_members(%{"kty" => "RSA"} = jwk) do
    require_jwk_members(jwk, ~w(n e))
  end

  defp require_public_jwk_members(%{"kty" => "EC"} = jwk) do
    require_jwk_members(jwk, ~w(crv x y))
  end

  defp require_public_jwk_members(%{"kty" => "OKP"} = jwk) do
    require_jwk_members(jwk, ~w(crv x))
  end

  defp require_public_jwk_members(_jwk), do: :error

  defp require_jwk_members(jwk, fields) do
    if Enum.all?(fields, &(is_binary(Map.get(jwk, &1)) and Map.get(jwk, &1) != "")) do
      :ok
    else
      :error
    end
  end
end
