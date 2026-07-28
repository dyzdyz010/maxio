defmodule Mix.Tasks.Maxio.Iam.CreateKey do
  @shortdoc "创建一个 S3 access key（持久化到 access_keys 表）"
  @moduledoc """
  创建访问密钥（铁律 4：CLI 管凭据生命周期）。

  用法（先设 $env:ERL_FLAGS）：
      mix maxio.iam.create_key                       # 随机 ak/sk，type=iam_user
      mix maxio.iam.create_key --access-key MYKEY --secret MYSECRET
      mix maxio.iam.create_key --user alice          # 绑定到 arn:aws:iam:::user/alice
      mix maxio.iam.create_key --type root           # 额外 root（谨慎）

  打印新建的 access_key_id / secret_key（secret 仅此一次可见）。
  """
  use Mix.Task

  @usage "usage: mix maxio.iam.create_key [--access-key AK] [--secret SK] [--type root|iam_user] [--user USER | --principal-arn ARN] [--status active|inactive]"
  @switches [
    access_key: :string,
    secret: :string,
    type: :string,
    user: :string,
    principal_arn: :string,
    status: :string
  ]

  @impl true
  def run(argv) do
    Mix.Task.run("app.start")
    {opts, args, invalid} = OptionParser.parse(argv, strict: @switches)

    if args != [] or invalid != [] do
      Mix.raise(@usage)
    end

    if present?(opts[:user]) and present?(opts[:principal_arn]) do
      Mix.raise("--user and --principal-arn are mutually exclusive")
    end

    iam_opts =
      []
      |> put_if(:access_key_id, opts[:access_key])
      |> put_if(:secret_key, opts[:secret])
      |> put_if(:type, opts[:type])
      |> put_if(:user_name, opts[:user])
      |> put_if(:principal_arn, opts[:principal_arn])
      |> put_if(:status, opts[:status])

    case Maxio.IAM.create_access_key(iam_opts) do
      {:ok, key} ->
        IO.puts("AccessKeyId : #{key.access_key_id}")
        IO.puts("SecretKey   : #{key.secret_key}")
        IO.puts("PrincipalArn: #{key.principal_arn}")
        IO.puts("Type        : #{key.type}")
        IO.puts("Status      : #{key.status}")

      {:error, reason} ->
        Mix.raise("create_access_key failed: #{inspect(reason)}")
    end
  end

  defp put_if(kw, _key, nil), do: kw
  defp put_if(kw, key, val), do: Keyword.put(kw, key, val)

  defp present?(value), do: is_binary(value) and String.trim(value) != ""
end
