import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/maxio start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if System.get_env("PHX_SERVER") do
  config :maxio, MaxioWeb.Endpoint, server: true
end

config :maxio, MaxioWeb.Endpoint, http: [port: String.to_integer(System.get_env("PORT", "4000"))]

# maxio S3：运行时从环境变量引导 root 凭据 / 数据目录 / S3 端口（缺省回落编译期默认）。
if root_user = System.get_env("MAXIO_ROOT_USER") do
  config :maxio, :s3, root_user: root_user
end

if root_password = System.get_env("MAXIO_ROOT_PASSWORD") do
  if root_password == "" do
    raise """
    environment variable MAXIO_ROOT_PASSWORD must not be empty.
    """
  end

  config :maxio, :s3, root_password: root_password
end

if data_dir = System.get_env("MAXIO_DATA_DIR") do
  config :maxio, :s3, data_dir: data_dir
end

# 部署标识（madmin ServerInfo 的 deploymentID）。不设时首次被读取即自动生成 UUIDv4 并
# 持久化进 runtime_configs；容器编排里想让它跨重建保持稳定就用这个变量在部署期钉住。
# 运行时覆盖（mix maxio.config.set cluster deployment_id ...）优先级仍高于本变量——
# "运维时意图"晚于"部署时意图"，见 Maxio.Config 的优先级说明。
if deployment_id = System.get_env("MAXIO_DEPLOYMENT_ID") do
  if deployment_id == "" do
    raise """
    environment variable MAXIO_DEPLOYMENT_ID must not be empty.
    Unset it to let maxio generate and persist a UUIDv4 on first read.
    """
  end

  config :maxio, :cluster, deployment_id: deployment_id
end

dev_sse_master_key = "bWF4aW8tc3NlLXMzLW1hc3Rlci1rZXktMzJieXRlcyE="
dev_access_key_secret_key = "bWF4aW8tYWNjZXNzLWtleS1zZWNyZXQta2V5LTMyYiE="

validate_prod_secret_env! = fn name, value, purpose ->
  cond do
    value in [nil, ""] ->
      raise """
      environment variable #{name} is missing.
      Provide a base64-encoded 32 byte key for #{purpose}.
      """

    value == dev_sse_master_key ->
      raise """
      environment variable #{name} must not use the committed development SSE master key.
      Generate a unique base64-encoded 32 byte key for production.
      """

    true ->
      case Base.decode64(value) do
        {:ok, raw} when byte_size(raw) == 32 ->
          :ok

        _other ->
          raise """
          environment variable #{name} must be a base64-encoded 32 byte key for #{purpose}.
          """
      end
  end
end

sse_master_key = System.get_env("MAXIO_SSE_MASTER_KEY")
kms_master_key = System.get_env("MAXIO_KMS_MASTER_KEY")
access_key_secret_key = System.get_env("MAXIO_ACCESS_KEY_SECRET_KEY")
access_key_secret_key_id = System.get_env("MAXIO_ACCESS_KEY_SECRET_KEY_ID", "local-default")
access_key_secret_keyring = System.get_env("MAXIO_ACCESS_KEY_SECRET_KEYRING")
access_key_secret_keyring_file = System.get_env("MAXIO_ACCESS_KEY_SECRET_KEYRING_FILE")

validate_access_key_secret_key_id! = fn name, key_id ->
  cond do
    not is_binary(key_id) or key_id == "" ->
      raise """
      environment variable #{name} must be a non-empty key id.
      """

    byte_size(key_id) > 128 or String.contains?(key_id, ["\0", "\r", "\n"]) ->
      raise """
      environment variable #{name} contains an invalid key id.
      Use a stable printable id of at most 128 bytes.
      """

    true ->
      :ok
  end
end

decode_access_key_secret_keyring! = fn value ->
  case value do
    nil ->
      %{}

    "" ->
      %{}

    json ->
      case Jason.decode(json) do
        {:ok, decoded} when is_map(decoded) ->
          decoded

        _other ->
          raise """
          environment variable MAXIO_ACCESS_KEY_SECRET_KEYRING must be a JSON object mapping key ids to base64-encoded 32 byte keys.
          """
      end
  end
end

validate_access_key_secret_keyring_file! = fn path ->
  cond do
    path in [nil, ""] ->
      :ok

    String.contains?(path, ["\0", "\r", "\n"]) ->
      raise """
      environment variable MAXIO_ACCESS_KEY_SECRET_KEYRING_FILE contains an invalid path.
      """

    File.exists?(path) ->
      case Jason.decode(File.read!(path)) do
        {:ok, %{"current_key_id" => current_key_id, "keys" => keys}} when is_map(keys) ->
          validate_access_key_secret_key_id!.(
            "MAXIO_ACCESS_KEY_SECRET_KEYRING_FILE current_key_id",
            current_key_id
          )

          Enum.each(keys, fn {key_id, entry} ->
            key_b64 =
              case entry do
                value when is_binary(value) -> value
                %{"secret_key" => value} when is_binary(value) -> value
                _other -> nil
              end

            validate_access_key_secret_key_id!.(
              "MAXIO_ACCESS_KEY_SECRET_KEYRING_FILE key",
              key_id
            )

            validate_prod_secret_env!.(
              "MAXIO_ACCESS_KEY_SECRET_KEYRING_FILE[#{key_id}]",
              key_b64,
              "IAM access-key and STS session signing secret envelope read key"
            )

            if key_b64 == dev_access_key_secret_key do
              raise """
              environment variable MAXIO_ACCESS_KEY_SECRET_KEYRING_FILE[#{key_id}] must not use the committed development access-key secret key.
              Generate a unique base64-encoded 32 byte key for production.
              """
            end
          end)

        _other ->
          raise """
          environment variable MAXIO_ACCESS_KEY_SECRET_KEYRING_FILE must point to a JSON keyring file with current_key_id and keys.
          """
      end

    true ->
      :ok
  end
end

access_key_secret_keys = decode_access_key_secret_keyring!.(access_key_secret_keyring)

if sse_master_key do
  config :maxio, :sse, master_key: sse_master_key
end

if kms_master_key do
  config :maxio, :kms, master_key: kms_master_key
end

if access_key_secret_key || access_key_secret_keyring || access_key_secret_keyring_file do
  access_key_secret_keys =
    if access_key_secret_key do
      case Map.fetch(access_key_secret_keys, access_key_secret_key_id) do
        {:ok, ^access_key_secret_key} ->
          access_key_secret_keys

        {:ok, _other_key} ->
          raise """
          environment variable MAXIO_ACCESS_KEY_SECRET_KEY conflicts with MAXIO_ACCESS_KEY_SECRET_KEYRING[#{access_key_secret_key_id}].
          """

        :error ->
          Map.put(access_key_secret_keys, access_key_secret_key_id, access_key_secret_key)
      end
    else
      access_key_secret_keys
    end

  config :maxio, :access_key_secret,
    current_key_id: access_key_secret_key_id,
    secret_key: access_key_secret_key,
    keys: access_key_secret_keys,
    keyring_file: access_key_secret_keyring_file
end

if kms_default_key_id = System.get_env("MAXIO_KMS_DEFAULT_KEY_ID") do
  config :maxio, :kms, default_key_id: kms_default_key_id
end

if config_env() == :prod do
  validate_prod_secret_env!.(
    "MAXIO_SSE_MASTER_KEY",
    sse_master_key,
    "SSE-S3 local envelope wrapping"
  )

  validate_prod_secret_env!.(
    "MAXIO_KMS_MASTER_KEY",
    kms_master_key,
    "the local SSE-KMS provider"
  )

  validate_prod_secret_env!.(
    "MAXIO_ACCESS_KEY_SECRET_KEY",
    access_key_secret_key,
    "IAM access-key and STS session signing secret envelopes"
  )

  validate_access_key_secret_key_id!.(
    "MAXIO_ACCESS_KEY_SECRET_KEY_ID",
    access_key_secret_key_id
  )

  if access_key_secret_key == dev_access_key_secret_key do
    raise """
    environment variable MAXIO_ACCESS_KEY_SECRET_KEY must not use the committed development access-key secret key.
    Generate a unique base64-encoded 32 byte key for production.
    """
  end

  Enum.each(access_key_secret_keys, fn {key_id, key_b64} ->
    validate_access_key_secret_key_id!.("MAXIO_ACCESS_KEY_SECRET_KEYRING key", key_id)

    validate_prod_secret_env!.(
      "MAXIO_ACCESS_KEY_SECRET_KEYRING[#{key_id}]",
      key_b64,
      "IAM access-key and STS session signing secret envelope read key"
    )

    if key_b64 == dev_access_key_secret_key do
      raise """
      environment variable MAXIO_ACCESS_KEY_SECRET_KEYRING[#{key_id}] must not use the committed development access-key secret key.
      Generate a unique base64-encoded 32 byte key for production.
      """
    end
  end)

  validate_access_key_secret_keyring_file!.(access_key_secret_keyring_file)
end

if s3_port = System.get_env("MAXIO_S3_PORT") do
  config :maxio, Maxio.S3.Endpoint, port: String.to_integer(s3_port)
end

# S3 监听地址运行时覆盖。dev 默认绑 127.0.0.1（见 config/dev.exs），容器里的真实客户端
# （mc / aws-cli 经 host.docker.internal）连不上——而 CLAUDE.md 要求 S3 行为用真实客户端做
# 端到端活体取证。用 MAXIO_S3_IP=0.0.0.0 临时放开即可取证，默认值不变（绝不把 dev 默认
# 暴露到 0.0.0.0）。绑定 socket 在 Application.start 期建立，本项属"需重启"配置。
if s3_ip = System.get_env("MAXIO_S3_IP") do
  parsed_s3_ip =
    case :inet.parse_address(String.to_charlist(s3_ip)) do
      {:ok, address} ->
        address

      {:error, _reason} ->
        # 绝不静默回落默认地址：静默回落会让运维以为已经放开监听，实际仍绑在 loopback。
        raise """
        environment variable MAXIO_S3_IP must be a literal IP address, got: #{inspect(s3_ip)}.
        Use 0.0.0.0 (all IPv4 interfaces), :: (all IPv6 interfaces) or a concrete address such as
        127.0.0.1. Host names are not resolved here—bind addresses must be unambiguous.
        """
    end

  config :maxio, Maxio.S3.Endpoint, ip: parsed_s3_ip
end

if account_id = System.get_env("MAXIO_ACCOUNT_ID") do
  config :maxio, :sts, account_id: account_id
end

if web_identity_providers = System.get_env("MAXIO_WEB_IDENTITY_PROVIDERS") do
  case Jason.decode(web_identity_providers) do
    {:ok, providers} when is_list(providers) ->
      config :maxio, :web_identity_providers, providers

    _other ->
      raise """
      environment variable MAXIO_WEB_IDENTITY_PROVIDERS must be a JSON array of OIDC provider configs.
      """
  end
end

case System.get_env("MAXIO_MFA_SECRET_KEY") do
  key when is_binary(key) ->
    config :maxio, :mfa, secret_key: key

  nil ->
    if config_env() == :prod do
      raise """
      environment variable MAXIO_MFA_SECRET_KEY is missing.
      Provide a base64-encoded 32 byte key for local MFA TOTP seed envelopes.
      """
    end
end

if topology_source = System.get_env("MAXIO_TOPOLOGY_SOURCE") do
  source =
    case topology_source do
      "config" -> :config
      "db" -> :db
      other -> raise "invalid MAXIO_TOPOLOGY_SOURCE=#{inspect(other)}; expected config or db"
    end

  config :maxio, :topology_source, source
end

if pool_write_policy = System.get_env("MAXIO_POOL_WRITE_POLICY") do
  mode =
    case pool_write_policy do
      "weighted_free_space" ->
        :weighted_free_space

      "hash" ->
        :hash

      other ->
        raise "invalid MAXIO_POOL_WRITE_POLICY=#{inspect(other)}; expected hash or weighted_free_space"
    end

  config :maxio, :pool_write_policy, mode: mode
end

if max_used = System.get_env("MAXIO_POOL_WRITE_MAX_USED_PERCENT_X100") do
  config :maxio, :pool_write_policy, max_used_percent_x100: String.to_integer(max_used)
end

# ── M7 多节点：prod 从 MAXIO_PEERS（逗号分隔 node 名）静态 epmd 组网。──
# 例：MAXIO_PEERS="maxio@10.0.0.1,maxio@10.0.0.2,maxio@10.0.0.3"
# 每节点须以 --name maxio@<ip> --cookie <同一 cookie> 启动（分布式 Erlang 前提）。
if config_env() == :prod do
  peers =
    System.get_env("MAXIO_PEERS", "")
    |> String.split(",", trim: true)
    |> Enum.map(&String.to_atom/1)

  if peers != [] do
    config :maxio, Maxio.Cluster,
      topologies: [
        maxio_epmd: [
          strategy: Cluster.Strategy.Epmd,
          config: [hosts: peers]
        ]
      ]
  end
end

if config_env() == :prod do
  database_url =
    System.get_env("DATABASE_URL") ||
      raise """
      environment variable DATABASE_URL is missing.
      For example: ecto://USER:PASS@HOST/DATABASE
      """

  maybe_ipv6 = if System.get_env("ECTO_IPV6") in ~w(true 1), do: [:inet6], else: []

  config :maxio, Maxio.Repo,
    # ssl: true,
    url: database_url,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10"),
    # For machines with several cores, consider starting multiple pools of `pool_size`
    # pool_count: 4,
    socket_options: maybe_ipv6

  # The secret key base is used to sign/encrypt cookies and other secrets.
  # A default value is used in config/dev.exs and config/test.exs but you
  # want to use a different value for prod and you most likely don't want
  # to check this value into version control, so we use an environment
  # variable instead.
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  host = System.get_env("PHX_HOST") || "example.com"

  config :maxio, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  config :maxio, MaxioWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [
      # Enable IPv6 and bind on all interfaces.
      # Set it to  {0, 0, 0, 0, 0, 0, 0, 1} for local network only access.
      # See the documentation on https://hexdocs.pm/bandit/Bandit.html#t:options/0
      # for details about using IPv6 vs IPv4 and loopback vs public addresses.
      ip: {0, 0, 0, 0, 0, 0, 0, 0}
    ],
    secret_key_base: secret_key_base

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :maxio, MaxioWeb.Endpoint,
  #       https: [
  #         ...,
  #         port: 443,
  #         cipher_suite: :strong,
  #         keyfile: System.get_env("SOME_APP_SSL_KEY_PATH"),
  #         certfile: System.get_env("SOME_APP_SSL_CERT_PATH")
  #       ]
  #
  # The `cipher_suite` is set to `:strong` to support only the
  # latest and more secure SSL ciphers. This means old browsers
  # and clients may not be supported. You can set it to
  # `:compatible` for wider support.
  #
  # `:keyfile` and `:certfile` expect an absolute path to the key
  # and cert in disk or a relative path inside priv, for example
  # "priv/ssl/server.key". For all supported SSL configuration
  # options, see https://hexdocs.pm/plug/Plug.SSL.html#configure/1
  #
  # We also recommend setting `force_ssl` in your config/prod.exs,
  # ensuring no data is ever sent via http, always redirecting to https:
  #
  #     config :maxio, MaxioWeb.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.
end
