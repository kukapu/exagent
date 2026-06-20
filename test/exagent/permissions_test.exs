defmodule ExAgent.PermissionsTest do
  use ExUnit.Case, async: true

  alias ExAgent.Message
  alias ExAgent.Message.Part
  alias ExAgent.Models.Test
  alias ExAgent.{Permissions, Tool}

  describe "decide/2 (glob rules, last match wins)" do
    test "matches exact names" do
      perms = Permissions.new!(rules: [{"read", :allow}, {"write", :deny}])
      assert Permissions.decide(perms, "read") == :allow
      assert Permissions.decide(perms, "write") == :deny
    end

    test "wildcard * matches a run of characters; last match wins" do
      perms = Permissions.new!(rules: [{"*", :deny}, {"search_*", :allow}, {"bash", :ask}])

      assert Permissions.decide(perms, "write") == :deny
      assert Permissions.decide(perms, "search_web") == :allow
      assert Permissions.decide(perms, "bash") == :ask
    end

    test "falls back to :default when nothing matches" do
      perms = Permissions.new!(rules: [{"read", :allow}], default: :deny)
      assert Permissions.decide(perms, "read") == :allow
      assert Permissions.decide(perms, "anything_else") == :deny
    end

    test "? matches a single character" do
      perms = Permissions.new!(rules: [{"file_?", :allow}], default: :deny)
      assert Permissions.decide(perms, "file_a") == :allow
      assert Permissions.decide(perms, "file_ab") == :deny
    end
  end

  describe "resolve/3 (:ask handling)" do
    test ":allow and :deny pass through" do
      assert Permissions.resolve(:allow, nil, nil) == :allow
      assert Permissions.resolve(:deny, nil, nil) == :deny
    end

    test ":ask without a callback fails closed" do
      assert Permissions.resolve(:ask, %{}, nil) == :deny
    end

    test ":ask with an approving callback becomes :allow" do
      assert Permissions.resolve(:ask, %{}, fn _ -> :approve end) == :allow
    end

    test ":ask with a denying callback becomes :deny" do
      assert Permissions.resolve(:ask, %{}, fn _ -> :nope end) == :deny
    end
  end

  describe "integration with ExAgent.run/3" do
    defp tool(name, result),
      do:
        Tool.new(
          name: name,
          description: name,
          parameters_json_schema: %{type: "object", properties: %{}},
          takes_ctx: false,
          call: fn _ -> {:ok, result} end
        )

    defp find_return(messages, name) do
      Enum.find_value(messages, fn
        %Message.Request{parts: parts} ->
          Enum.find(parts, &match?(%Part.ToolReturn{tool_name: ^name}, &1))

        _ ->
          nil
      end)
    end

    test "a :deny rule blocks execution and tells the model" do
      model = %Test{
        script: [
          {:tool_calls, [%Part.ToolCall{tool_name: "delete", args: %{}}]},
          "done"
        ]
      }

      perms = Permissions.new!(rules: [{"*", :allow}, {"delete", :deny}])
      agent = ExAgent.new(model: model, tools: [tool("delete", "deleted!")])

      assert {:ok, %{messages: messages}} = ExAgent.run(agent, "go", permissions: perms)

      assert %Part.ToolReturn{content: content} = find_return(messages, "delete")
      assert content =~ "not permitted"
      refute content =~ "deleted"
    end

    test "an :ask rule runs the tool when the approve callback approves" do
      model = %Test{
        script: [
          {:tool_calls, [%Part.ToolCall{tool_name: "bash", args: %{}}]},
          "done"
        ]
      }

      perms = Permissions.new!(rules: [{"bash", :ask}])
      agent = ExAgent.new(model: model, tools: [tool("bash", "executed")])

      assert {:ok, %{messages: messages}} =
               ExAgent.run(agent, "go", permissions: perms, approve: fn _call -> :approve end)

      assert find_return(messages, "bash").content == "executed"
    end

    test "an :ask rule fails closed without an approve callback" do
      model = %Test{
        script: [
          {:tool_calls, [%Part.ToolCall{tool_name: "bash", args: %{}}]},
          "done"
        ]
      }

      perms = Permissions.new!(rules: [{"bash", :ask}])
      agent = ExAgent.new(model: model, tools: [tool("bash", "executed")])

      assert {:ok, %{messages: messages}} = ExAgent.run(agent, "go", permissions: perms)
      assert find_return(messages, "bash").content =~ "not permitted"
    end
  end
end
