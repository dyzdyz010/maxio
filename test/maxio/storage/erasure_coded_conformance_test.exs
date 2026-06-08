defmodule Maxio.Storage.ErasureCodedConformanceTest do
  use ExUnit.Case, async: true
  @backend Maxio.Storage.ErasureCoded

  setup do
    base = Path.join(System.tmp_dir!(), "maxio_ec_conf_#{System.unique_integer([:positive])}")
    drives = for i <- 0..5, do: Path.join(base, "d#{i}")
    Enum.each(drives, &File.mkdir_p!/1)
    on_exit(fn -> File.rm_rf(base) end)
    {:ok, drives: drives}
  end

  defp opts(ctx), do: [drives: ctx.drives, data_shards: 4, parity_shards: 2, block_size: 1024]

  use Maxio.Test.StorageConformance
end
