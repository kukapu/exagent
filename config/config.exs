import Config

# exAgent is a library: it ships no config (the `config/` dir is excluded from
# the package). This file exists only to load test-only config (e.g. the
# Postgres TestRepo) when running this project's own test suite.
if File.exists?("config/#{config_env()}.exs") do
  import_config "#{config_env()}.exs"
end
