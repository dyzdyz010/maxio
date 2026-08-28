defmodule Maxio.IAM.MinioAccessKey do
  @moduledoc false

  @forbidden_bytes [?,, ?=, ?/, ?\\]
  @ascii_whitespace [0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x20]

  @spec validate(term()) :: :ok | {:error, :invalid_access_key}
  def validate(access_key) when is_binary(access_key) do
    bytes = :binary.bin_to_list(access_key)

    cond do
      byte_size(access_key) not in 3..64 ->
        {:error, :invalid_access_key}

      Enum.any?(bytes, &(&1 not in 0x20..0x7E)) ->
        {:error, :invalid_access_key}

      Enum.any?(bytes, &(&1 in @forbidden_bytes)) ->
        {:error, :invalid_access_key}

      hd(bytes) in @ascii_whitespace or List.last(bytes) in @ascii_whitespace ->
        {:error, :invalid_access_key}

      true ->
        :ok
    end
  end

  def validate(_access_key), do: {:error, :invalid_access_key}
end
