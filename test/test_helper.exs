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

exclude = if pg_ready, do: [], else: [:postgres]
ExUnit.start(exclude: exclude)
