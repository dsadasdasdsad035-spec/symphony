defmodule SymphonyElixir.McpEndpointTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.HttpServer

  setup do
    root = Path.join(System.tmp_dir!(), "symphony-mcp-endpoint-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)

    # 指向一个必然连不上的端点：用来验证"工具执行失败"被正确映射成 MCP 错误，
    # 而不是变成 500。真实 Linear 往返由 linear 既有测试覆盖。
    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: Path.join(root, "workspaces"),
      tracker_endpoint: "http://127.0.0.1:1/graphql"
    )

    start_supervised!({HttpServer, port: 0, orchestrator: SymphonyElixir.Orchestrator})
    port = wait_for_port()
    %{url: "http://127.0.0.1:#{port}/mcp"}
  end

  test "initialize / tools/list / tools/call 走通 HTTP 传输", %{url: url} do
    init =
      post_json(url, %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "initialize",
        "params" => %{"protocolVersion" => "2025-06-18", "capabilities" => %{}}
      })

    assert init.status == 200
    assert init.body["result"]["serverInfo"]["name"] == "symphony"
    assert init.body["result"]["capabilities"]["tools"]["listChanged"] == false

    list = post_json(url, %{"jsonrpc" => "2.0", "id" => 2, "method" => "tools/list"})
    assert list.status == 200
    assert Enum.any?(list.body["result"]["tools"], &(&1["name"] == "linear_graphql"))

    call =
      post_json(url, %{
        "jsonrpc" => "2.0",
        "id" => 3,
        "method" => "tools/call",
        "params" => %{"name" => "linear_graphql", "arguments" => %{"query" => "{ viewer { name } }"}}
      })

    assert call.status == 200
    # Linear 不可达时应返回结构化的工具错误，而不是 500
    assert call.body["result"]["isError"] == true
    assert [%{"type" => "text", "text" => text} | _] = call.body["result"]["content"]
    assert text =~ "error" or text =~ "失败" or text =~ "message"
  end

  test "通知返回 202 且无响应体", %{url: url} do
    response =
      Req.post!(url,
        json: %{"jsonrpc" => "2.0", "method" => "notifications/initialized"}
      )

    assert response.status == 202
    assert response.body in ["", nil]
  end

  test "GET / DELETE 返回 405", %{url: url} do
    get_response = Req.get!(url)
    assert get_response.status == 405

    delete_response = Req.delete!(url)
    assert delete_response.status == 405
  end

  test "非法 JSON 被 Plug.Parsers 拦下，返回 400", %{url: url} do
    response =
      Req.post!(url,
        headers: [{"content-type", "application/json"}],
        body: "not json"
      )

    assert response.status == 400
  end

  test "控制器把无法解码的报文映射成 JSON-RPC -32700" do
    conn =
      Plug.Test.conn(:post, "/mcp", "not json")
      |> Plug.Conn.assign(:raw_body, "not json")
      |> SymphonyElixirWeb.McpController.handle(%{})

    assert conn.status == 400
    assert Jason.decode!(conn.resp_body)["error"]["code"] == -32_700
  end

  test "非回环来源被拒绝" do
    conn =
      Plug.Test.conn(:post, "/mcp", ~s({"jsonrpc":"2.0","id":1,"method":"ping"}))
      |> Plug.Conn.assign(:raw_body, ~s({"jsonrpc":"2.0","id":1,"method":"ping"}))
      |> Map.put(:remote_ip, {10, 1, 2, 3})
      |> SymphonyElixirWeb.McpController.handle(%{})

    assert conn.status == 403
    assert Jason.decode!(conn.resp_body)["error"]["code"] == -32_000
  end

  defp post_json(url, payload) do
    Req.post!(url, json: payload, headers: [{"accept", "application/json, text/event-stream"}])
  end

  defp wait_for_port(attempts \\ 100) do
    case HttpServer.bound_port() do
      port when is_integer(port) and port > 0 ->
        port

      _ when attempts > 0 ->
        Process.sleep(20)
        wait_for_port(attempts - 1)

      _ ->
        flunk("HTTP 端点未在预期时间内绑定端口")
    end
  end
end
