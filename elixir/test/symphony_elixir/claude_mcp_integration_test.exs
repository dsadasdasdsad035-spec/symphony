defmodule SymphonyElixir.ClaudeMcpIntegrationTest do
  @moduledoc """
  用真实 `claude` 验证 Symphony 的 MCP 接线。

  Claude Code 没有只做握手、不跑模型的自查子命令，因此这里必须真的跑一轮
  模型调用，会消耗额度。默认跳过，设 `SYMPHONY_CLAUDE_INTEGRATION=1` 才执行：

      SYMPHONY_CLAUDE_INTEGRATION=1 mix test test/symphony_elixir/claude_mcp_integration_test.exs
  """

  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Agent.ClaudeCli
  alias SymphonyElixir.HttpServer

  @claude System.find_executable("claude")

  @skip_reason (cond do
                  @claude == nil ->
                    "未安装 claude，跳过真实 CLI 集成测试"

                  System.get_env("SYMPHONY_CLAUDE_INTEGRATION") != "1" ->
                    "设置 SYMPHONY_CLAUDE_INTEGRATION=1 才跑真实 claude 调用（会消耗额度）"

                  true ->
                    false
                end)

  setup do
    token = "symphony-claude-mcp-#{System.unique_integer([:positive])}"
    root = Path.join(System.tmp_dir!(), token)
    workspaces = Path.join(root, "workspaces")
    workspace = Path.join(workspaces, "MT-1")
    File.mkdir_p!(workspace)

    on_exit(fn -> File.rm_rf(root) end)

    %{root: root, workspaces: workspaces, workspace: workspace}
  end

  @tag skip: @skip_reason
  @tag timeout: 600_000
  test "真实 claude 能连上 Symphony 的 MCP 并发现 linear_graphql", %{
    workspaces: workspaces,
    workspace: workspace
  } do
    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: workspaces,
      agent_kind: "claude_cli",
      server_port: 0
    )

    start_supervised!({HttpServer, port: 0, orchestrator: SymphonyElixir.Orchestrator})
    wait_for_port()

    assert {:ok, session} = ClaudeCli.start_session(workspace, [])
    on_exit(fn -> ClaudeCli.stop_session(session) end)

    assert session.mcp_url == "http://127.0.0.1:#{HttpServer.bound_port()}/mcp"

    issue = %Issue{id: "issue-c", identifier: "MT-C", title: "Claude MCP", state: "In Progress"}

    # 不在提示里写出工具名，避免自我实现预言：只有真的注入了才会答出来
    prompt = """
    列出你的工具列表中所有名字里含有 linear 的工具，原样逐字输出工具名。
    如果一个都没有，只回答 UNAVAILABLE。不要调用任何工具，也不要解释。
    """

    assert {:ok, turn} = ClaudeCli.run_turn(session, prompt, issue, on_message: fn _ -> :ok end)

    refute turn.result =~ "UNAVAILABLE"
    # Claude Code 会给 MCP 工具加 `mcp__<server>__` 前缀
    assert turn.result =~ "linear_graphql"
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
