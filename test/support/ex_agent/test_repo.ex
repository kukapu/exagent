defmodule ExAgent.TestRepo do
  @moduledoc false
  use Ecto.Repo, otp_app: :exagent, adapter: Ecto.Adapters.Postgres
end
