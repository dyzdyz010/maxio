defmodule Mix.Tasks.Maxio.Iam.DeleteKey do
  @shortdoc "删除一个 S3 access key（拒绝删最后一个 root）"
  @moduledoc "删除访问密钥（铁律 4）。用法：mix maxio.iam.delete_key --access-key MYKEY"
  use Mix.Task

  @switches [access_key: :string]

  @impl true
  def run(argv) do
    Mix.Task.run("app.start")
    {opts, _, _} = OptionParser.parse(argv, strict: @switches)
    ak = opts[:access_key] || Mix.raise("--access-key required")

    case Maxio.IAM.delete_access_key(ak) do
      :ok -> IO.puts("deleted: #{ak}")
      {:error, :cannot_delete_last_root} -> Mix.raise("refusing to delete the last root key")
    end
  end
end
