defmodule Maxio.Storage.FSConformanceTest do
  use ExUnit.Case, async: true
  @backend Maxio.Storage.FS

  setup do
    dir = Path.join(System.tmp_dir!(), "maxio_fs_conf_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    {:ok, dir: dir}
  end

  defp opts(ctx), do: [data_dir: ctx.dir]

  use Maxio.Test.StorageConformance
end
