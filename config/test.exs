import Config

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :maxio, Maxio.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  database: "maxio_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :maxio, MaxioWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "7ut+qsEKNIJnsxefRjJF7XtPxPHYrAMVNKXIhtNuTLGpQgL8SnQHo648mIfBecmr",
  server: false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true

# maxio S3：测试期对象数据目录（每次运行前清理）与监听配置
config :maxio, :s3,
  data_dir: Path.expand("../priv/s3_data/test", __DIR__),
  root_user: "AKIAIOSFODNN7EXAMPLE",
  root_password: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"

config :maxio, Maxio.S3.Endpoint, server: false, port: 0

# 凭据后端：test 用 MemoryStore（ETS，无需 DB 引导，root 从 config :maxio, :s3 引导，
# 与 Maxio.Test.SigV4Request 的 root key 对齐）。EctoStore 由其专属测试单独覆盖。
config :maxio, :credential_store, Maxio.Auth.CredentialStore.MemoryStore

# M7：test 不起 libcluster（进程内 transport 注入即可覆盖分布式逻辑）；:peer 集成测试自行起节点。
config :maxio, Maxio.Cluster, topologies: []

# B1-2：test 默认关 fsync 提速（fsync 单测显式传 opts[:fsync] true 断言 :file.sync 被调用）。
config :maxio, :durability, fsync: false

# M8-3 scrubber test runs are explicit; background scheduling remains disabled.
config :maxio, :scrubber, enabled: false, initial_delay_ms: 0, page_size: 50
