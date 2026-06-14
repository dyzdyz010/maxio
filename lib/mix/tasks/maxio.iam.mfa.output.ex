defmodule Mix.Tasks.Maxio.Iam.Mfa.Output do
  @moduledoc false

  @spec reject_invalid!([String.t()], keyword(), String.t()) :: :ok | no_return()
  def reject_invalid!(rest, invalid, usage) do
    if rest != [] or invalid != [] do
      unexpected = rest ++ Enum.map(invalid, &elem(&1, 0))
      Mix.raise("#{usage} (unexpected: #{inspect(unexpected)})")
    end

    :ok
  end

  @spec print_json(term()) :: :ok
  def print_json(payload) do
    payload |> json_value() |> Jason.encode!() |> IO.puts()
  end

  def json_value(%DateTime{} = value), do: DateTime.to_iso8601(value)
  def json_value(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
  def json_value(value) when is_list(value), do: Enum.map(value, &json_value/1)

  def json_value(value) when is_map(value) do
    Map.new(value, fn {key, field_value} ->
      {to_string(key), json_value(field_value)}
    end)
  end

  def json_value(value), do: value
end
