defmodule Maxio.Admin.PolicyEntitiesRequest do
  @moduledoc """
  Raw-query parser for the repeatable builtin policy-entities filters.

  It deliberately operates on `conn.query_string`, rather than Plug's normalized query map,
  because repeated filter values are part of the madmin protocol.
  """

  alias Maxio.S3.Error

  @keys %{
    "user" => {:users, :user},
    "group" => {:groups, :group},
    "policy" => {:policies, :policy}
  }
  @valid_percent ~r/%[0-9A-Fa-f]{2}/

  @spec parse!(binary()) :: map()
  def parse!(query_string) when is_binary(query_string) do
    validate_percent_encoding!(query_string)

    initial = %{users: [], groups: [], policies: [], requested: MapSet.new()}

    parsed =
      query_string
      |> URI.query_decoder()
      |> Enum.reduce(initial, fn {key, value}, acc ->
        case Map.get(@keys, key) do
          {collection, dimension} ->
            acc
            |> Map.update!(collection, &[value | &1])
            |> Map.update!(:requested, &MapSet.put(&1, dimension))

          nil ->
            acc
        end
      end)
      |> Map.update!(:users, &normalize/1)
      |> Map.update!(:groups, &normalize/1)
      |> Map.update!(:policies, &normalize/1)

    Map.put(parsed, :requested_dimensions, parsed.requested)
  rescue
    _error in ArgumentError -> raise Error.new(:admin_invalid_argument)
  end

  def parse!(_query_string), do: raise(Error.new(:admin_invalid_argument))

  defp normalize(values), do: values |> Enum.uniq() |> Enum.sort()

  defp validate_percent_encoding!(query_string) do
    stripped = Regex.replace(@valid_percent, query_string, "")

    if String.contains?(stripped, "%") do
      raise Error.new(:admin_invalid_argument)
    end
  end
end
