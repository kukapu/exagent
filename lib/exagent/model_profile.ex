defmodule ExAgent.ModelProfile do
  @moduledoc """
  **Advisory** declaration of what a given model/provider supports, so callers
  and future capabilities can negotiate gracefully per model — e.g. whether the
  provider can do native JSON-schema output, forced tool calls, or extended
  thinking.

  Every model returns one via the optional `c:ExAgent.Model.profile/1`
  callback; providers that don't implement it get a permissive default.

  > **Status:** declarative for now. The core loop currently always uses the
  > `:tool` output mode and doesn't yet downgrade based on these flags. The
  > profile is exposed so external code can branch on it today, and so upcoming
  > work (native/prompted output, `Thinking` capability) can consult it without
  > a new API.
  """

  @type output_mode :: :text | :tool | :native | :prompted | :auto

  defstruct supports_tools: true,
            supports_json_schema_output: true,
            supports_json_object_output: true,
            supports_thinking: false,
            default_output_mode: :tool

  @type t :: %__MODULE__{
          supports_tools: boolean(),
          supports_json_schema_output: boolean(),
          supports_json_object_output: boolean(),
          supports_thinking: boolean(),
          default_output_mode: output_mode()
        }
end
