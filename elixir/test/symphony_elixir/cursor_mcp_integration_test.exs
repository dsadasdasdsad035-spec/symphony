defmodule SymphonyElixir.CursorMcpIntegrationTest do
  @moduledoc """
  用真实 `cursor-agent` 验证 Symphony 的 MCP 接线。

  这里刻意不触达模型推理：`cursor-agent mcp list-tools` 只做 MCP 握手，
  因此不消耗模型额度，也能在没有周额度时校验工具是否正确暴露。
  """

  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Agent.CursorCli
  alias SymphonyElixir.HttpServer

  @cursor_agent System.find_executable("cursor-agent")

  @skip_reason (if @cursor_agent == nil do
                  "未安装 cursor-agent，跳过真实 CLI 集成测试"
                else
                  nil
                end)

  setup do
    root = Path.join(System.tmp_dir!(), "symphony-cursor-mcp-#{System.unique_integer([:positive])}")
    workspaces = Path.join(root, "workspaces")
    workspace = Path.join(workspaces, "MT-1")
    File.mkdir_p!(workspace)
    File.mkdir_p!(Path.join(workspace, ".git/info"))
    on_exit(fn -> File.rm_rf(root) end)

    %{root: root, workspaces: workspaces, workspace: workspace}
  end

  @tag skip: @skip_reason
  test "真实 cursor-agent 能连上 Symphony 的 MCP 并发现 linear_graphql", %{
    workspaces: workspaces,
    workspace: workspace
  } do
    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: workspaces,
      agent_kind: "cursor_cli",
      server_port: 0
    )

    start_supervised!({HttpServer, port: 0, orchestrator: SymphonyElixir.Orchestrator})
    wait_for_port()

    assert {:ok, session} = CursorCli.start_session(workspace, [])
    on_exit(fn -> CursorCli.stop_session(session) end)

    assert session.mcp_url == "http://127.0.0.1:#{HttpServer.bound_port()}/mcp"

    {list_out, list_code} = run_cursor(workspace, ["mcp", "list"])
    assert list_code == 0
    assert list_out =~ "symphony: ready"

    {tools_out, tools_code} = run_cursor(workspace, ["mcp", "list-tools", "symphony"])
    assert tools_code == 0
    assert tools_out =~ "linear_graphql"

    # 工具签名必须带 query / variables，否则 agent 无法构造调用
    assert tools_out =~ "query"
    assert tools_out =~ "variables"
  end

  defp run_cursor(workspace, args) do
    System.cmd("cursor-agent", args,
      cd: workspace,
      stderr_to_stdout: true,
      env: [{"TERM", "dumb"}]
    )
  end

  defp wait_for_port(attempts \\ 100) do
    case HttpServer.bound_port() do
      port when is_integer(port) and port > 0 ->
        port

      _ when attempts > 0 ->
        Process.sleep(30)
        wait_for_port(attempts - 1)

      _ ->
        flunk("HTTP 端点未能在预期时间内就绪")
    end
  end
end
