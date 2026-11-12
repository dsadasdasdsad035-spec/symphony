defmodule SymphonyElixir.ZcodeMcpIntegrationTest do
  @moduledoc """
  用真实 `zcode` 运行时验证 Symphony 的 MCP 接线。

  和 cursor 版本不同，ZCode 没有 `mcp list-tools` 这类只做握手的子命令，
  因此这里必须真的跑一轮模型调用，会消耗模型额度。
  默认跳过，设 `SYMPHONY_ZCODE_INTEGRATION=1` 才执行：

      SYMPHONY_ZCODE_INTEGRATION=1 mix test test/symphony_elixir/zcode_mcp_integration_test.exs
  """

  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Agent.Zcode
  alias SymphonyElixir.HttpServer

  @enabled System.get_env("SYMPHONY_ZCODE_INTEGRATION") == "1"

  @skip_reason (if @enabled do
                  false
                else
                  "设置 SYMPHONY_ZCODE_INTEGRATION=1 才跑真实 zcode 调用（会消耗模型额度）"
                end)

  setup do
    token = "symphony-zcode-mcp-#{System.unique_integer([:positive])}"
    root = Path.join(System.tmp_dir!(), token)
    workspaces = Path.join(root, "workspaces")
    workspace = Path.join(workspaces, "MT-1")
    File.mkdir_p!(workspace)

    user_config = Path.join(System.user_home!(), ".zcode/cli/config.json")
    backup = Path.join(root, "zcode-config-backup.json")

    if File.exists?(user_config), do: File.cp!(user_config, backup)

    on_exit(fn ->
      # 适配器会改用户级配置，跑完必须还原，避免污染开发机
      if File.exists?(backup) do
        File.cp!(backup, user_config)
      else
        File.rm(user_config)
      end

      File.rm_rf(root)
    end)

    %{root: root, workspaces: workspaces, workspace: workspace}
  end

  @tag skip: @skip_reason
  @tag timeout: 600_000
  test "真实 zcode 能连上 Symphony 的 MCP 并发现 linear_graphql", %{
    workspaces: workspaces,
    workspace: workspace
  } do
    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: workspaces,
      agent_kind: "zcode",
      server_port: 0
    )

    start_supervised!({HttpServer, port: 0, orchestrator: SymphonyElixir.Orchestrator})
    wait_for_port()

    assert {:ok, session} = Zcode.start_session(workspace, [])
    on_exit(fn -> Zcode.stop_session(session) end)

    assert session.mcp_url == "http://127.0.0.1:#{HttpServer.bound_port()}/mcp"

    issue = %Issue{id: "issue-z", identifier: "MT-Z", title: "ZCode MCP", state: "In Progress"}

    prompt = """
    列出你的工具列表中所有名字里含有 linear 的工具，原样逐字输出工具名。
    如果一个都没有，只回答 UNAVAILABLE。不要调用任何工具，也不要解释。
    """

    assert {:ok, turn} = Zcode.run_turn(session, prompt, issue, on_message: fn _ -> :ok end)

    refute turn.result =~ "UNAVAILABLE"
    # ZCode 会给 MCP 工具加 `mcp__<server>__` 前缀，所以只校验包含关系
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
