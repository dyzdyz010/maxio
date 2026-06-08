# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :maxio,
  ecto_repos: [Maxio.Repo],
  generators: [timestamp_type: :utc_datetime, binary_id: true]

# Configure the endpoint
config :maxio, MaxioWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: MaxioWeb.ErrorHTML, json: MaxioWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Maxio.PubSub,
  live_view: [signing_salt: "DCOzLD0u"]

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  maxio: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.1.12",
  maxio: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__)
  ]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id, :bucket, :key, :action, :auth_type, :reason, :code, :status]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# 在 Windows 非管理员环境下，LiveView 的 ColocatedJS 无法创建 node_modules 符号链接（:eperm），
# maxio 不使用 colocated hooks/js，关闭该警告以保证 `compile --warnings-as-errors` 干净。
config :phoenix_live_view, :colocated_js, disable_symlink_warning: true

# ── maxio S3 子系统配置（独立于 Console 的 MaxioWeb.Endpoint）──
# 寻址根域名（virtual-host 判定基准）、默认区域、对象数据目录、时钟偏移容忍、root 凭据引导。
config :maxio, :s3,
  domain: "localhost",
  region: "us-east-1",
  clock_skew_ms: 900_000,
  data_dir: Path.expand("../priv/s3_data", __DIR__),
  root_user: "minioadmin",
  root_password: "minioadmin"

# 独立 S3 Endpoint（Bandit child）监听配置。
# prod/默认 9000（对齐 MinIO）；dev 因 Windows 9000–9099 保留段改用 9900（见 dev.exs）；
# 可经 MAXIO_S3_PORT 运行时覆盖（runtime.exs）。
config :maxio, Maxio.S3.Endpoint, port: 9000, ip: :any

# SSE-S3 服务端主密钥（信封加密包裹每对象 DEK）。dev/test 用固定 base64 32B；
# prod 经 MAXIO_SSE_MASTER_KEY env（runtime.exs）。单一静态主密钥=简化密钥管理 MVP（无轮转/KMS，README 已声明）。
config :maxio, :sse,
  master_key: "bWF4aW8tc3NlLXMzLW1hc3Rlci1rZXktMzJieXRlcyE="

# 纠删码后端默认参数（单机多盘 = 一个 erasure set）。默认后端仍为 FS（见下）；
# 切到纠删码：把 storage_backend 改为 Maxio.Storage.ErasureCoded 即可（铁律 2：换后端只改一行）。
# drives = N 个本地盘目录（N = data_shards + parity_shards）；block_size = 流式块（MinIO v2 默认 1 MiB）。
config :maxio, :erasure,
  drives: [
    Path.expand("../priv/s3_data/ec/d0", __DIR__),
    Path.expand("../priv/s3_data/ec/d1", __DIR__),
    Path.expand("../priv/s3_data/ec/d2", __DIR__),
    Path.expand("../priv/s3_data/ec/d3", __DIR__),
    Path.expand("../priv/s3_data/ec/d4", __DIR__),
    Path.expand("../priv/s3_data/ec/d5", __DIR__)
  ],
  data_shards: 4,
  parity_shards: 2,
  block_size: 1_048_576

# 后端 behaviour 绑定（铁律 1/2：换后端只改这里）。
config :maxio, :storage_backend, Maxio.Storage.FS
config :maxio, :credential_store, Maxio.Auth.CredentialStore.EctoStore
config :maxio, :policy_store, Maxio.Policy.Store.EctoStore

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
