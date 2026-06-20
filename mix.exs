defmodule ExAgent.MixProject do
  use Mix.Project

  @source_url "https://github.com/kukapu/exagent"
  @version "0.3.0"

  def project do
    [
      app: :exagent,
      version: @version,
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps(),
      aliases: aliases(),
      package: package(),
      description: description(),
      # ex_doc
      name: "ExAgent",
      source_url: @source_url,
      docs: docs()
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp description do
    "An agent framework for Elixir — structured output, tool-calling and streaming, powered by the BEAM."
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url},
      files: ~w(lib examples mix.exs README.md LICENSE .formatter.exs)
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {ExAgent.Application, []}
    ]
  end

  defp deps do
    [
      {:req, "~> 0.5"},
      {:finch, "~> 0.22"},
      {:jason, "~> 1.4"},
      {:ecto, "~> 3.12"},
      {:telemetry, "~> 1.0"},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false}
    ]
  end

  defp aliases do
    [
      check: ["compile --warnings-as-errors", "format", "test"]
    ]
  end

  defp docs do
    [
      main: "readme",
      extras: ["README.md", "CHANGELOG.md", "DESIGN.md", "ROADMAP.md", "LICENSE"],
      source_ref: "v#{@version}",
      groups_for_modules: [
        "Agent & Loop": [ExAgent, ExAgent.RunContext, ExAgent.UsageLimits],
        "Stateful Runtime": [ExAgent.Server, ExAgent.AgentSupervisor, ExAgent.Server.Snapshot],
        "Session & Coordination": [
          ExAgent.Session,
          ExAgent.Session.Participant,
          ExAgent.Session.SharedState,
          ExAgent.Session.TurnPolicy,
          ExAgent.Session.TurnPolicy.RoundRobin,
          ExAgent.Session.TurnPolicy.Initiative,
          ExAgent.Session.TurnPolicy.SupervisorPolicy,
          ExAgent.Coordination
        ],
        "Events & PubSub": [ExAgent.Event, ExAgent.PubSub],
        Persistence: [ExAgent.Store, ExAgent.Store.ETS],
        Messages: [ExAgent.Message],
        "Tools & Output": [ExAgent.Tool, ExAgent.Tools, ExAgent.Schema, ExAgent.OutputSchema],
        Models: [
          ExAgent.Model,
          ExAgent.ModelSettings,
          ExAgent.ModelRequestParameters,
          ExAgent.ModelProfile
        ],
        Providers: [
          ExAgent.Models.OpenAI,
          ExAgent.Models.OpenRouter,
          ExAgent.Models.Anthropic,
          ExAgent.Models.Test,
          ExAgent.Providers.OpenAIChat,
          ExAgent.Providers.Anthropic,
          ExAgent.Providers.SSE
        ],
        "Capabilities & Telemetry": [ExAgent.Capability, ExAgent.Capabilities, ExAgent.Telemetry],
        Exceptions: [ExAgent.RequestError, ExAgent.UnexpectedModelBehavior, ExAgent.ModelRetry]
      ]
    ]
  end
end
