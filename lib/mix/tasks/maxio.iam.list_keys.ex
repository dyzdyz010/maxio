defmodule Mix.Tasks.Maxio.Iam.ListKeys do
  @shortdoc "列出全部 S3 access key（不显示 secret）"
  @moduledoc "列出访问密钥（铁律 4）。用法：mix maxio.iam.list_keys"
  use Mix.Task

  @impl true
  def run(_argv) do
    Mix.Task.run("app.start")

    Maxio.IAM.list_access_keys()
    |> Enum.each(fn k ->
      IO.puts("#{k.access_key_id}\t#{k.type}\t#{k.status}\t#{k.principal_arn}")
    end)
  end
end
