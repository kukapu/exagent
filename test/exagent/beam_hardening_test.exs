defmodule ExAgent.BeamHardeningTest do
  use ExUnit.Case, async: true
  import ExUnit.CaptureLog

  alias ExAgent.{Tool}
  alias ExAgent.Message.Part

  describe "ExAgent.Finch is supervised" do
    test "the dedicated Finch pool is started" do
      assert is_pid(Process.whereis(ExAgent.Finch))
    end
  end

  describe "parallel tool execution" do
    test "a batch of tool calls all execute, preserving order" do
      # two distinct tools called in one response
      add =
        Tool.new(
          name: "add",
          description: "add",
          parameters_json_schema: %{type: "object"},
          takes_ctx: false,
          call: fn %{"a" => a, "b" => b} -> {:ok, a + b} end
        )

      dup =
        Tool.new(
          name: "dup",
          description: "dup",
          parameters_json_schema: %{type: "object"},
          takes_ctx: false,
          call: fn %{"x" => x} -> {:ok, x * 2} end
        )

      model = %ExAgent.Models.Test{
        script: [
          {:tool_calls,
           [
             %Part.ToolCall{tool_name: "add", args: %{"a" => 1, "b" => 2}},
             %Part.ToolCall{tool_name: "dup", args: %{"x" => 5}}
           ]},
          "done"
        ]
      }

      agent = ExAgent.new(model: model, tools: [add, dup])

      assert {:ok, %{messages: messages}} = ExAgent.run(agent, "x")

      returns =
        messages
        |> Enum.flat_map(fn
          %ExAgent.Message.Request{parts: parts} ->
            Enum.filter(parts, &match?(%Part.ToolReturn{}, &1))

          _ ->
            []
        end)
        |> Enum.map(&{&1.tool_name, &1.content})

      assert returns == [{"add", 3}, {"dup", 10}]
    end

    test "a tool that exceeds tool_timeout is killed and turned into a retry" do
      slow =
        Tool.new(
          name: "slow",
          description: "sleeps",
          parameters_json_schema: %{type: "object"},
          takes_ctx: false,
          call: fn _ ->
            Process.sleep(2_000)
            {:ok, "never"}
          end
        )

      model = %ExAgent.Models.Test{
        script: [
          {:tool_calls, [%Part.ToolCall{tool_name: "slow", args: %{}}]},
          "recovered"
        ]
      }

      agent = ExAgent.new(model: model, tools: [slow], tool_timeout: 100, output_retries: 3)

      assert {:ok, %{output: "recovered", messages: messages}} = ExAgent.run(agent, "x")

      # the timed-out tool produced a retry prompt (model was asked to try again)
      assert Enum.any?(
               messages,
               fn
                 %ExAgent.Message.Request{parts: parts} ->
                   Enum.any?(parts, &match?(%Part.Retry{tool_name: "slow"}, &1))

                 _ ->
                   false
               end
             )
    end
  end

  describe "telemetry" do
    test "emits run start/stop and tool stop events" do
      parent = self()
      ref = make_ref()

      :telemetry.attach_many(
        "test-#{inspect(ref)}",
        [[:exagent, :run, :start], [:exagent, :run, :stop], [:exagent, :tool, :stop]],
        fn event, measurements, metadata, _ ->
          send(parent, {ref, event, measurements, metadata})
        end,
        nil
      )

      add =
        Tool.new(
          name: "add",
          description: "add",
          parameters_json_schema: %{type: "object"},
          takes_ctx: false,
          call: fn %{"a" => a, "b" => b} -> {:ok, a + b} end
        )

      model = %ExAgent.Models.Test{
        script: [
          {:tool_calls, [%Part.ToolCall{tool_name: "add", args: %{"a" => 1, "b" => 2}}]},
          "done"
        ]
      }

      agent = ExAgent.new(model: model, tools: [add], name: "t")

      capture_log(fn ->
        {:ok, %{usage: usage}} = ExAgent.run(agent, "go")

        # telemetry is global: keep only THIS run's events (agent == "t") so
        # concurrently-running tests' emissions don't pollute the assertions.
        mine =
          receive_all(ref)
          |> Enum.filter(fn {^ref, _e, _m, meta} -> Map.get(meta, :agent) == "t" end)

        events = Enum.map(mine, fn {^ref, e, _m, _meta} -> e end)

        assert [:exagent, :run, :start] in events
        assert [:exagent, :run, :stop] in events
        assert [:exagent, :tool, :stop] in events

        {_, %{usage: ^usage}} =
          Enum.find(mine, fn
            {^ref, [:exagent, :run, :stop], _m, _meta} -> true
            _ -> false
          end)
          |> then(fn {^ref, [:exagent, :run, :stop], _m, meta} -> {:run, meta} end)
      end)

      :telemetry.detach("test-#{inspect(ref)}")
    end
  end

  defp receive_all(ref), do: receive_all(ref, [])

  defp receive_all(ref, acc) do
    receive do
      {^ref, _, _, _} = msg -> receive_all(ref, [msg | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end
