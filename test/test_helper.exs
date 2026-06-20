# Start the Postgres test repo once for the :postgres-tagged tests, linked to the
# suite runner (so it survives across tests). Gracefully skipped (the whole
# :postgres tag is excluded) when the database isn't available — the rest of the
# suite is unaffected.
pg_ready =
  try do
    {:ok, _} = Application.ensure_all_started(:ecto_sql)
    {:ok, _} = Application.ensure_all_started(:postgrex)

    case ExAgent.TestRepo.start_link() do
      {:ok, _} ->
        :ok = ExAgent.Store.Postgres.migrate(ExAgent.TestRepo)
        true

      {:error, {:already_started, _}} ->
        true

      {:error, _} ->
        false
    end
  rescue
    _ -> false
  end

# Build the exclude list:
#   * :postgres — auto-skip when no DB
#   * :integration — real-provider calls (opt in with --include integration)
#   * :mcp_e2e — real stdio MCP server spawn (auto-skip when python3 is absent)
exclude = [:integration]
exclude = if pg_ready, do: exclude, else: [:postgres | exclude]

exclude =
  if System.find_executable("python3") == nil, do: [:mcp_e2e | exclude], else: exclude

ExUnit.start(exclude: exclude)
