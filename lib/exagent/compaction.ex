defmodule ExAgent.Compaction do
  @moduledoc """
  Behaviour for shrinking a conversation history when it grows too large, so a
  long-running session stays within a model's context window.

  A compactor takes the current `[Message.t()]` and returns either a compacted
  list, `{:no_change}` (leave it alone), or an error. The built-in
  `ExAgent.Compaction.Summary` replaces older messages with an LLM-generated
  summary while keeping the most recent ones verbatim.

  Compaction is wired into a run as a **capability** (see
  `ExAgent.Compaction.Capability`) that fires on the `before_model_request`
  hook. That keeps it opt-in and composable with other capabilities.
  """

  alias ExAgent.Message

  @type messages :: [Message.t()]
  @type opts :: keyword()

  @callback compact(messages(), opts()) ::
              {:ok, messages()} | {:no_change} | {:error, term()}

  @doc """
  A rough token estimate for a message history: total characters of all text
  content, divided by 4. Good enough to decide *when* to compact; it intentionally
  over-estimates slightly so compaction triggers a little early (safe side).
  """
  @spec estimate_tokens(messages()) :: non_neg_integer()
  def estimate_tokens(messages) do
    messages
    |> Message.parts()
    |> Enum.map_join(&part_text/1)
    |> String.length()
    |> div(4)
  end

  defp part_text(%ExAgent.Message.Part.Text{content: c}), do: c
  defp part_text(%ExAgent.Message.Part.User{content: c}) when is_binary(c), do: c
  defp part_text(%ExAgent.Message.Part.System{content: c}) when is_binary(c), do: c
  defp part_text(_), do: ""
end

defmodule ExAgent.Compaction.Summary do
  @moduledoc """
  A compactor that summarizes older messages and keeps a recent window verbatim.

  When the history exceeds `:threshold_tokens` (estimated via
  `ExAgent.Compaction.estimate_tokens/1` by default), everything older than the
  last `:keep_recent` messages is replaced by a single system message produced by
  the caller-supplied `:summarize` function — typically an `ExAgent.run/3` call
  to a cheap summarizer model.

  ## Options

    * `:threshold_tokens` — compact once the estimate exceeds this (default `4000`).
    * `:keep_recent` — number of trailing messages kept verbatim (default `6`).
    * `:summarize` — `(old_messages -> summary_text)`. Required to compact; if
      absent, the history is left untouched.
    * `:token_counter` — `(messages -> non_neg_integer())`, default
      `ExAgent.Compaction.estimate_tokens/1`.

  ## Wiring

      compaction = %ExAgent.Compaction.Capability{
        compactor: ExAgent.Compaction.Summary,
        opts: [
          threshold_tokens: 6000,
          keep_recent: 8,
          summarize: fn old ->
            {:ok, %{output: text}} = ExAgent.run(summarizer_agent, summarize_prompt(old))
            text
          end
        ]
      }

      ExAgent.new(model: "anthropic:claude-3-5-haiku", capabilities: [compaction])
  """

  @behaviour ExAgent.Compaction

  alias ExAgent.Compaction
  alias ExAgent.Message
  alias ExAgent.Message.{Part, Request}

  @impl true
  def compact(messages, opts) do
    threshold = opts[:threshold_tokens] || 4000
    keep = opts[:keep_recent] || 6
    summarize = opts[:summarize]
    counter = opts[:token_counter] || (&Compaction.estimate_tokens/1)

    cond do
      is_nil(summarize) ->
        {:no_change}

      length(messages) <= keep ->
        {:no_change}

      counter.(messages) <= threshold ->
        {:no_change}

      true ->
        {old, recent} = split_keep_recent(messages, keep)
        summary_text = summarize.(old)
        summary_req = summary_request(summary_text)
        {:ok, [summary_req | recent]}
    end
  end

  # Keep the last `keep` messages verbatim; everything before them is summarized.
  defp split_keep_recent(messages, keep) do
    split_at = max(length(messages) - keep, 0)
    Enum.split(messages, split_at)
  end

  defp summary_request(text) do
    %Request{
      parts: [%Part.System{content: "Summary of earlier conversation:\n#{text}"}],
      timestamp: DateTime.utc_now()
    }
  end
end

defmodule ExAgent.Compaction.Capability do
  @moduledoc """
  A capability that runs a compactor on `before_model_request`, shrinking the
  canonical history (and the request about to be sent) when it grows too large.

  Add it to an agent's `:capabilities`:

      %ExAgent.Compaction.Capability{
        compactor: ExAgent.Compaction.Summary,
        opts: [threshold_tokens: 6000, keep_recent: 8, summarize: &my_summarize/1]
      }
  """

  use ExAgent.Capability

  defstruct [:compactor, :opts]

  @impl true
  def before_model_request(%__MODULE__{compactor: mod, opts: opts} = _cap, state) do
    case mod.compact(state.messages, opts || []) do
      {:ok, compacted} ->
        %{state | messages: compacted, request_messages: compacted}

      _ ->
        state
    end
  end
end
