# ─────────────────────────────────────────────────────────────────────────────
# Recipe: wrap an agent run in an Oban job in YOUR app.
#
# This file is documentation, not a runnable example: it sketches a durable
# Oban wrapper for agent execution. It requires `:oban` + Postgres in your app
# (not in this library — the framework stays DB-free on purpose; durability is
# an application concern you opt into).
#
# Add to your app:
#
#   # mix.exs
#   {:oban, "~> 2.18"}
#
#   # config/config.exs
#   config :my_app, Oban,
#     repo: MyApp.Repo,
#     queues: [agents: 10]
#
#   # lib/my_app/application.ex — start Oban in your supervisor tree:
#   children = [..., {Oban, Application.fetch_env!(:my_app, Oban)}]
# ─────────────────────────────────────────────────────────────────────────────

# ── 1. A checkpoint store (PG column `history text`): ────────────────────────
#
#   defmodule MyApp.AgentRun do
#     use Ecto.Schema
#     schema "agent_runs" do
#       field :key, :string            # unique run key
#       field :history, :string        # Message.to_json([...]) best-effort checkpoint
#       field :output, :string         # optional final text output
#       field :status, :string, default: "running"
#       timestamps()
#     end
#   end
#
#   # migration excerpt:
#   create unique_index(:agent_runs, [:key])
#
# ── 2. The durable worker. It skips completed runs, loads any saved history,
#       runs the agent, then persists final history/output. This does not
#       checkpoint before every side effect; make tools idempotent or guard
#       them with your own DB uniqueness/locking. ─────────────────────────────
#
#   defmodule MyApp.AgentWorker do
#     use Oban.Worker, queue: :agents, max_attempts: 5
#
#     alias ExAgent.{Message}
#
#     @impl true
#     def perform(%Oban.Job{args: %{"key" => key, "prompt" => prompt}}) do
#       # In production, fetch/lock this row in a transaction if duplicate jobs
#       # can run concurrently. Side-effectful tools need their own idempotency keys.
#       run = MyApp.Repo.get_by!(MyApp.AgentRun, key: key)
#
#       if run.status == "done" do
#         :ok
#       else
#         history =
#           case run.history do
#             nil -> []
#             json -> {:ok, msgs} = Message.from_json(json); msgs
#           end
#
#         agent = ExAgent.new(model: "openai:gpt-4o", tools: MyApp.Tools.tools())
#
#         case ExAgent.run(agent, prompt, message_history: history) do
#           {:ok, %{output: output, messages: messages}} ->
#             # persist final history for audit/replay; this is not per-tool checkpointing
#             run
#             |> Ecto.Changeset.change(
#               history: Message.to_json(messages),
#               status: "done",
#               output: output
#             )
#             |> MyApp.Repo.update!()
#             :ok
#
#           {:error, reason} ->
#             # re-raise so Oban retries with backoff; checkpoint kept as-is
#             raise "agent failed: #{inspect(reason)}"
#         end
#       end
#     end
#   end
#
# ── 3. Enqueue (Oban unique reduces duplicates; keep the DB unique index): ───
#
#   %{key: "support-#{ticket_id}", prompt: "Help with order ##{order_id}"}
#   |> Oban.Job.new(worker: MyApp.AgentWorker, unique: [period: 60])
#   |> Oban.insert(MyApp.Repo)
#
# ── Human-in-the-loop workflows ──────────────────────────────────────────────
#   ExAgent.run/3 runs to completion and capability callbacks do not suspend.
#   Manage approvals as application state instead: persist the conversation with
#   Message.to_json/1, record a pending approval in your own tables, and enqueue
#   a new job with the restored `history` when the human responds.
#
# ── Why this lives in YOUR app, not in the library ───────────────────────────
#   - Keeps the framework dependency-light (no forced Postgres).
#   - You own idempotency keys, retry policy, queue sizing and the schema.
#   - The library only needs to provide (de)serialization — which it does via
#     `Message.to_json/1` and `Message.from_json/1`.

IO.puts("""
This is a documentation recipe (see the source). It shows an Oban wrapper plus
best-effort history persistence with ExAgent.Message.to_json/from_json. The
framework itself stays DB-free.
""")

# Sanity-check the (de)serialization primitives the recipe relies on:
alias ExAgent.Message, as: M
alias ExAgent.Message.Part

conv = [
  M.new_request([%Part.User{content: "hello"}], timestamp: nil),
  M.new_response([%Part.Text{content: "hi back"}], model_name: "m", timestamp: nil)
]

{:ok, decoded} = M.from_json(M.to_json(conv))

IO.puts(
  "Checkpoint round-trip OK: #{length(decoded)} messages decoded back to #{inspect(hd(hd(decoded).parts).__struct__)}."
)
