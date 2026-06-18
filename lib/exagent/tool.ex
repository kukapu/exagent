defmodule ExAgent.Tool do
  @moduledoc """
  A tool the model may call.

  `ExAgent.Tool` bundles everything: the serialisable `ToolDefinition`
  (name, description, JSON-Schema parameters) **and** the actual callable that
  runs when the model invokes it. Use `definition/1` to project the shape a
  provider sends to the model.

  Tools are normally built via the `deftool` macro (see `ExAgent.Tools`),
  which derives the JSON-Schema from the function's `@spec`. They can also be
  built by hand with `new/1`.
  """

  @type kind :: :function | :output | :external | :unapproved

  defstruct name: nil,
            description: nil,
            parameters_json_schema: %{},
            kind: :function,
            takes_ctx: true,
            call: nil,
            max_retries: 1

  @type t :: %__MODULE__{
          name: String.t(),
          description: String.t() | nil,
          parameters_json_schema: map(),
          kind: kind(),
          takes_ctx: boolean(),
          call: (ExAgent.RunContext.t(), map() -> term()) | (map() -> term()) | nil,
          max_retries: non_neg_integer()
        }

  @doc "Serialisable projection sent to the model: name + description + params."
  @spec definition(t()) :: map()
  def definition(%__MODULE__{} = tool) do
    %{
      name: tool.name,
      description: tool.description,
      parameters: tool.parameters_json_schema
    }
  end

  @doc "Build a tool by hand."
  @spec new(keyword()) :: t()
  def new(opts) when is_list(opts) do
    struct!(__MODULE__, opts)
  end
end
