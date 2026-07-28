defmodule Maxio.Native do
  @moduledoc false

  use Rustler, otp_app: :maxio, crate: :maxio_native

  @doc false
  def native_rs_encode(_data_shards, _parity_shards, _data), do: nif_not_loaded()

  @doc false
  def native_rs_reconstruct(_data_shards, _parity_shards, _shards), do: nif_not_loaded()

  @doc false
  def native_blake3(_data), do: nif_not_loaded()

  @doc false
  def native_path_reparse_point(_path), do: nif_not_loaded()

  defp nif_not_loaded, do: :erlang.nif_error(:nif_not_loaded)
end
