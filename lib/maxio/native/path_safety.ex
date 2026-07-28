defmodule Maxio.Native.PathSafety do
  @moduledoc """
  Fail-closed static path-component detector backed by the shared Rust NIF.

  On Windows every `FILE_ATTRIBUTE_REPARSE_POINT` is rejected by callers, including junctions
  and symbolic links. On Unix the detector reports symbolic links from `symlink_metadata`.

  This is one layer in the controlled Maxio data-drive proof: callers must also compare opened
  handle and path metadata before and after reading. Those checks do not claim protection from a
  hostile local process performing a carefully timed junction/symlink ABA swap.
  """

  @type error_code ::
          :enoent
          | :eacces
          | :enotdir
          | :eloop
          | :einval
          | :etimedout
          | :ebusy
          | :estale
          | :eio
          | :nif_not_loaded
          | :native_unavailable

  @spec reparse_point(String.t()) :: {:ok, boolean()} | {:error, error_code()}
  def reparse_point(path) do
    reparse_point(path, &Maxio.Native.native_path_reparse_point/1)
  end

  @doc false
  @spec reparse_point(String.t(), (String.t() -> term())) ::
          {:ok, boolean()} | {:error, error_code()}
  def reparse_point(path, native) when is_binary(path) and is_function(native, 1) do
    native.(path)
    |> normalize_native_result()
  rescue
    error in ErlangError ->
      if error.original == :nif_not_loaded,
        do: {:error, :nif_not_loaded},
        else: {:error, :native_unavailable}

    UndefinedFunctionError ->
      {:error, :nif_not_loaded}

    _error ->
      {:error, :native_unavailable}
  catch
    _kind, _reason -> {:error, :native_unavailable}
  end

  def reparse_point(_path, _native), do: {:error, :einval}

  defp normalize_native_result({:ok, value}) when is_boolean(value), do: {:ok, value}
  defp normalize_native_result({:error, "enoent"}), do: {:error, :enoent}
  defp normalize_native_result({:error, "eacces"}), do: {:error, :eacces}
  defp normalize_native_result({:error, "enotdir"}), do: {:error, :enotdir}
  defp normalize_native_result({:error, "eloop"}), do: {:error, :eloop}
  defp normalize_native_result({:error, "einval"}), do: {:error, :einval}
  defp normalize_native_result({:error, "etimedout"}), do: {:error, :etimedout}
  defp normalize_native_result({:error, "ebusy"}), do: {:error, :ebusy}
  defp normalize_native_result({:error, "estale"}), do: {:error, :estale}
  defp normalize_native_result({:error, "eio"}), do: {:error, :eio}
  defp normalize_native_result(_other), do: {:error, :native_unavailable}
end
