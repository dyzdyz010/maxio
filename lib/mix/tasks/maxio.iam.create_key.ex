defmodule Mix.Tasks.Maxio.Iam.CreateKey do
  @shortdoc "创建一个 S3 access key（持久化到 access_keys 表）"
  @moduledoc """
  创建访问密钥（铁律 4：CLI 管凭据生命周期）。

  用法（先设 $env:ERL_FLAGS）：
      mix maxio.iam.create_key                       # 随机 ak/sk，type=iam_user
      mix maxio.iam.create_key --access-key MYKEY --secret MYSECRET
      mix maxio.iam.create_key --type root           # 额外 root（谨慎）

  打印新建的 access_key_id / secret_key（secret 仅此一次可见）。
  """
  use Mix.Task

  @switches [access_key: :string, secret: :string, type: :string]

  @impl true
  def run(argv) do
    Mix.Task.run("app.start")
    {opts, _, _} = OptionParser.parse(argv, strict: @switches)

    iam_opts =
      []
      |> put_if(:access_key_id, opts[:access_key])
      |> put_if(:secret_key, opts[:secret])
      |> put_if(:type, opts[:type])

    case Maxio.IAM.create_access_key(iam_opts) do
      {:ok, key} ->
        IO.puts("AccessKeyId : #{key.access_key_id}")
        IO.puts("SecretKey   : #{key.secret_key}")
        IO.puts("PrincipalArn: #{key.principal_arn}")
        IO.puts("Type        : #{key.type}")

      {:error, reason} ->
        Mix.raise("create_access_key failed: #{inspect(reason)}")
    end
  end

  defp put_if(kw, _key, nil), do: kw
  defp put_if(kw, key, val), do: Keyword.put(kw, key, val)
end
