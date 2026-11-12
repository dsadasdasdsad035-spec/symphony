defmodule SymphonyElixir.McpServerTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Mcp.Server

  setup do
    write_workflow_file!(Workflow.workflow_file_path())
    :ok
  end

  test "initialize 返回协议版本与 tools 能力" do
    assert {:reply, response} =
             Server.handle(%{
               "jsonrpc" => "2.0",
               "id" => 1,
               "method" => "initialize",
               "params" => %{"protocolVersion" => "2025-06-18", "capabilities" => %{}}
             })

    assert response["jsonrpc"] == "2.0"
    assert response["id"] == 1
    assert response["result"]["protocolVersion"] == "2025-06-18"
    assert response["result"]["capabilities"]["tools"] == %{"listChanged" => false}
    assert response["result"]["serverInfo"]["name"] == "symphony"
  end

  test "initialize 沿用客户端声明的协议版本" do
    assert {:reply, response} =
             Server.handle(%{
               "jsonrpc" => "2.0",
               "id" => "abc",
               "method" => "initialize",
               "params" => %{"protocolVersion" => "2024-11-05"}
             })

    assert response["result"]["protocolVersion"] == "2024-11-05"
  end

  test "tools/list 暴露 linear_graphql 与它的 inputSchema" do
    assert {:reply, response} =
             Server.handle(%{"jsonrpc" => "2.0", "id" => 2, "method" => "tools/list"})

    tools = response["result"]["tools"]
    assert is_list(tools)

    linear = Enum.find(tools, &(&1["name"] == "linear_graphql"))
    assert linear, "应暴露 linear_graphql 工具"
    assert is_binary(linear["description"])
    assert linear["inputSchema"]["required"] == ["query"]
    assert linear["inputSchema"]["properties"]["query"]["type"] == "string"
  end

  test "tools/call 把 tracker 工具结果转成 MCP 的 content/isError" do
    assert {:reply, response} =
             Server.handle(%{
               "jsonrpc" => "2.0",
               "id" => 3,
               "method" => "tools/call",
               "params" => %{
                 "name" => "not_a_real_tool",
                 "arguments" => %{}
               }
             })

    result = response["result"]
    assert result["isError"] == true
    assert [%{"type" => "text", "text" => text} | _] = result["content"]
    assert text =~ "not_a_real_tool"
  end

  test "tools/call 缺少 query 时返回错误内容而非崩溃" do
    assert {:reply, response} =
             Server.handle(%{
               "jsonrpc" => "2.0",
               "id" => 4,
               "method" => "tools/call",
               "params" => %{"name" => "linear_graphql", "arguments" => %{}}
             })

    result = response["result"]
    assert result["isError"] == true
    assert [%{"type" => "text", "text" => text} | _] = result["content"]
    assert text =~ "query"
  end

  test "通知不产生响应" do
    assert :no_response ==
             Server.handle(%{"jsonrpc" => "2.0", "method" => "notifications/initialized"})
  end

  test "未知方法返回 -32601" do
    assert {:reply, response} =
             Server.handle(%{"jsonrpc" => "2.0", "id" => 5, "method" => "does/not/exist"})

    assert response["error"]["code"] == -32_601
  end

  test "ping 返回空结果" do
    assert {:reply, %{"result" => %{}} = response} =
             Server.handle(%{"jsonrpc" => "2.0", "id" => 6, "method" => "ping"})

    assert response["id"] == 6
  end

  test "非对象报文返回 -32600" do
    assert {:reply, response} = Server.handle([1, 2, 3])
    assert response["error"]["code"] == -32_600
  end
end
