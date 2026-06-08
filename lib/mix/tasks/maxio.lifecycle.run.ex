defmodule Mix.Tasks.Maxio.Lifecycle.Run do
  @shortdoc "（占位）生命周期过期执行——M4 未实现，仅打印 defer 说明"
  @moduledoc """
  生命周期后台执行 stub。M4 只存储/校验/出站生命周期配置；**实际过期/中止 MPU 删除未实现**（defer）。
  本任务存在仅为诚实暴露该 defer（铁律 3：绝不假装已生效）。后续里程碑实现真实 sweeper。
  """
  use Mix.Task

  @impl true
  def run(_args) do
    IO.puts("""
    [maxio lifecycle] Lifecycle expiration execution is NOT implemented in M4 (deferred).
    Lifecycle configurations are stored, validated, and served byte-faithfully for S3 client
    compatibility (aws-cli / SDK round-trip), but NO objects are expired and NO incomplete
    multipart uploads are aborted by maxio. Transition/NoncurrentVersionTransition are inert
    (single-tier storage). See README "Lifecycle (config-only)" section.
    """)
  end
end
