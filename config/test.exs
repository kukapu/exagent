import Config

# Test repo for ExAgent.Store.Postgres tests. Skipped automatically when the
# database is unreachable (see test/exagent/store/postgres_test.exs).
config :exagent, ExAgent.TestRepo,
  username: "postgres",
  password: "postgres",
  database: "exagent_test",
  hostname: System.get_env("EXAGENT_PG_HOST", "127.0.0.1"),
  port: String.to_integer(System.get_env("EXAGENT_PG_PORT", "5432")),
  pool_size: 10

config :exagent, :ecto_repos, [ExAgent.TestRepo]
