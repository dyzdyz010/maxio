defmodule Maxio.S3.TempFile do
  @moduledoc """
  Helpers for short-lived S3 temp files that may contain object bytes.
  """

  @attempts 8

  @spec stage!(String.t(), String.t(), (IO.device() -> map())) :: map()
  def stage!(prefix, suffix, fun)
      when is_binary(prefix) and is_binary(suffix) and is_function(fun, 1) do
    do_stage(prefix, suffix, fun, @attempts)
  end

  defp do_stage(_prefix, _suffix, _fun, 0) do
    raise File.Error, reason: :eexist, action: "open", path: System.tmp_dir!()
  end

  defp do_stage(prefix, suffix, fun, attempts_left) do
    dir = temp_dir(prefix)

    case run_with_dir(dir, suffix, fun) do
      {:ok, result} -> result
      :collision -> do_stage(prefix, suffix, fun, attempts_left - 1)
    end
  end

  defp run_with_dir(dir, suffix, fun) do
    case File.mkdir(dir) do
      :ok ->
        restrict_dir!(dir)
        path = Path.join(dir, "payload" <> suffix)
        run_with_path(dir, path, fun)

      {:error, :eexist} ->
        :collision

      {:error, reason} ->
        raise File.Error, reason: reason, action: "make directory", path: dir
    end
  rescue
    err ->
      cleanup_dir(dir)
      reraise(err, __STACKTRACE__)
  catch
    kind, reason ->
      cleanup_dir(dir)
      :erlang.raise(kind, reason, __STACKTRACE__)
  end

  defp run_with_path(dir, path, fun) do
    case File.open(path, [:write, :binary, :exclusive], fn io ->
           :ok = restrict_file!(path)
           result = fun.(io)
           Map.merge(result, %{path: path, cleanup: cleanup_fun(dir, path)})
         end) do
      {:ok, result} ->
        {:ok, result}

      {:error, :eexist} ->
        cleanup_dir(dir)
        :collision

      {:error, reason} ->
        raise File.Error, reason: reason, action: "open", path: path
    end
  rescue
    err ->
      _ = File.rm(path)
      reraise(err, __STACKTRACE__)
  catch
    kind, reason ->
      cleanup_dir(dir)
      :erlang.raise(kind, reason, __STACKTRACE__)
  end

  defp restrict_dir!(path) do
    case File.chmod(path, 0o700) do
      :ok -> :ok
      {:error, reason} -> raise File.Error, reason: reason, action: "chmod", path: path
    end
  end

  defp restrict_file!(path) do
    case File.chmod(path, 0o600) do
      :ok -> :ok
      {:error, reason} -> raise File.Error, reason: reason, action: "chmod", path: path
    end
  end

  defp cleanup_fun(dir, path) do
    fn ->
      _ = File.rm(path)
      cleanup_dir(dir)
      :ok
    end
  end

  defp cleanup_dir(dir) do
    _ = File.rm_rf(dir)
    :ok
  end

  defp temp_dir(prefix) do
    token =
      16
      |> :crypto.strong_rand_bytes()
      |> Base.url_encode64(padding: false)

    Path.join(System.tmp_dir!(), prefix <> token)
  end
end
