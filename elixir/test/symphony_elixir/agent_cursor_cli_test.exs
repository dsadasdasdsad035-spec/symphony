defmodule SymphonyElixir.AgentCursorCliTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Agent
  alias SymphonyElixir.Agent.CursorCli
  alias SymphonyElixir.Config.Schema

  setup do
    test_root = Path.join(System.tmp_dir!(), "symphony-cursor-cli-#{System.unique_integer([:positive])}")
    workspace_root = Path.join(test_root, "workspaces")
    workspace = Path.join(workspace_root, "MT-1")
    File.mkdir_p!(workspace)

    on_exit(fn -> File.rm_rf(test_root) end)

    %{test_root: test_root, workspace_root: workspace_root, workspace: workspace}
  end

  test "按 agent.kind 解析后端模块", %{workspace_root: workspace_root} do
    write_workflow_file!(Workflow.workflow_file_path(), workspace_root: workspace_root)
    assert Agent.impl() == SymphonyElixir.Agent.Codex

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: workspace_root,
      agent_kind: "cursor_cli"
    )

    assert Agent.impl() == CursorCli
  end

  test "拒绝非法的 agent.kind" do
    assert {:error, {:invalid_workflow_config, message}} =
             Schema.parse(%{"agent" => %{"kind" => "not_a_real_agent"}})

    assert message =~ "agent.kind is invalid"
  end

  test "run_turn 把 stream-json 事件映射成 Codex 语义并保留 chat id", %{
    test_root: test_root,
    workspace_root: workspace_root,
    workspace: workspace
  } do
    args_log = Path.join(test_root, "args.log")
    stub = write_stub_cli(test_root, args_log)

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: workspace_root,
      agent_kind: "cursor_cli",
      agent_cursor_command: stub
    )

    parent = self()

    on_message = fn message -> send(parent, {:agent_event, message}) end

    assert {:ok, session} = CursorCli.start_session(workspace, [])
    assert :ok = CursorCli.stop_session(session)

    assert {:ok, session} = CursorCli.start_session(workspace, [])
    on_exit(fn -> CursorCli.stop_session(session) end)

    issue = %Issue{id: "issue-1", identifier: "MT-1", title: "Cursor 冒烟", state: "In Progress"}

    assert {:ok, first_turn} =
             CursorCli.run_turn(session, "第一个任务", issue, on_message: on_message)

    assert first_turn.result =~ "已完成"
    assert first_turn.session_id == "chat-abc"
    assert first_turn.turn_id == 1

    events = collect_events()
    assert :session_started in events
    assert :turn_completed in events
    refute :startup_failed in events
    refute :turn_failed in events

    assert {:ok, second_turn} =
             CursorCli.run_turn(session, "第二个任务", issue, on_message: on_message)

    assert second_turn.turn_id == 2

    invocations = File.read!(args_log) |> String.split("\n", trim: true)
    assert length(invocations) == 2

    [first_args, second_args] = invocations
    refute first_args =~ "--resume"
    assert second_args =~ "--resume chat-abc"
    assert second_args =~ "第二个任务"
  end

  test "turn 收到 error 事件时返回失败", %{
    test_root: test_root,
    workspace_root: workspace_root,
    workspace: workspace
  } do
    args_log = Path.join(test_root, "args-err.log")
    stub = write_stub_cli(test_root, args_log, mode: "error")

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: workspace_root,
      agent_kind: "cursor_cli",
      agent_cursor_command: stub
    )

    assert {:ok, session} = CursorCli.start_session(workspace, [])
    on_exit(fn -> CursorCli.stop_session(session) end)

    issue = %Issue{id: "issue-2", identifier: "MT-2", title: "失败路径", state: "In Progress"}

    assert {:error, {:turn_failed, _span}} =
             CursorCli.run_turn(session, "会失败的任务", issue, on_message: fn _ -> :ok end)
  end

  test "拒绝工作区根目录与外部目录", %{workspace_root: workspace_root} do
    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: workspace_root,
      agent_kind: "cursor_cli"
    )

    outside = Path.join(Path.dirname(workspace_root), "outside-#{System.unique_integer([:positive])}")
    File.mkdir_p!(outside)
    on_exit(fn -> File.rm_rf(outside) end)

    assert {:error, {:invalid_workspace_cwd, :workspace_root, _path}} =
             CursorCli.start_session(workspace_root, [])

    assert {:error, {:invalid_workspace_cwd, :outside_workspace_root, _path, _root}} =
             CursorCli.start_session(outside, [])
  end

  test "远程 worker 未支持时明确报错", %{workspace_root: workspace_root, workspace: workspace} do
    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: workspace_root,
      agent_kind: "cursor_cli"
    )

    assert {:error, {:cursor_cli_remote_worker_unsupported, "build-host"}} =
             CursorCli.start_session(workspace, worker_host: "build-host")
  end

  test "start_session 把 Symphony MCP 端点写进 .cursor/mcp.json 并与已有配置合并", %{
    workspace_root: workspace_root,
    workspace: workspace
  } do
    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: workspace_root,
      agent_kind: "cursor_cli",
      server_port: 4599
    )

    cursor_dir = Path.join(workspace, ".cursor")
    File.mkdir_p!(cursor_dir)

    File.write!(
      Path.join(cursor_dir, "mcp.json"),
      Jason.encode!(%{"mcpServers" => %{"existing" => %{"type" => "http", "url" => "http://example.test/mcp"}}})
    )

    assert {:ok, session} = CursorCli.start_session(workspace, [])
    on_exit(fn -> CursorCli.stop_session(session) end)

    assert session.mcp_url == "http://127.0.0.1:4599/mcp"

    decoded = Path.join(cursor_dir, "mcp.json") |> File.read!() |> Jason.decode!()

    assert decoded["mcpServers"]["symphony"] == %{
             "type" => "http",
             "url" => "http://127.0.0.1:4599/mcp"
           }

    # 已有 MCP server 必须保留
    assert decoded["mcpServers"]["existing"]["url"] == "http://example.test/mcp"
  end

  test "写 mcp.json 时同步把路径加入 .git/info/exclude，避免被提交", %{
    workspace_root: workspace_root,
    workspace: workspace
  } do
    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: workspace_root,
      agent_kind: "cursor_cli",
      server_port: 4599
    )

    File.mkdir_p!(Path.join(workspace, ".git/info"))

    assert {:ok, session} = CursorCli.start_session(workspace, [])
    on_exit(fn -> CursorCli.stop_session(session) end)

    exclude = Path.join(workspace, ".git/info/exclude") |> File.read!()
    assert exclude =~ ".cursor/mcp.json"

    # 重复启动不应重复追加
    assert {:ok, session2} = CursorCli.start_session(workspace, [])
    CursorCli.stop_session(session2)

    assert exclude == Path.join(workspace, ".git/info/exclude") |> File.read!()
  end

  test "没有 HTTP 端口时不写 mcp.json", %{workspace_root: workspace_root, workspace: workspace} do
    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: workspace_root,
      agent_kind: "cursor_cli"
    )

    assert {:ok, session} = CursorCli.start_session(workspace, [])
    on_exit(fn -> CursorCli.stop_session(session) end)

    assert session.mcp_url == nil
    refute File.exists?(Path.join(workspace, ".cursor/mcp.json"))
  end

  test "cursor_model 配置会传给 --model，留空则不传", %{
    test_root: test_root,
    workspace_root: workspace_root,
    workspace: workspace
  } do
    args_log = Path.join(test_root, "args-model.log")
    stub = write_stub_cli(test_root, args_log)

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: workspace_root,
      agent_kind: "cursor_cli",
      agent_cursor_command: stub,
      agent_cursor_model: "deepseek-v41-flash-1017-medium"
    )

    issue = %Issue{id: "issue-m", identifier: "MT-M", title: "模型参数", state: "In Progress"}

    assert {:ok, session} = CursorCli.start_session(workspace, [])
    on_exit(fn -> CursorCli.stop_session(session) end)

    assert session.model == "deepseek-v41-flash-1017-medium"

    assert {:ok, _} = CursorCli.run_turn(session, "任务", issue, on_message: fn _ -> :ok end)

    # stub 用 "$*" 记录参数，会丢掉引号，这里只校验值与位置
    assert File.read!(args_log) =~ "--model deepseek-v41-flash-1017-medium"
  end

  test "未配置 cursor_model 时不传 --model", %{
    test_root: test_root,
    workspace_root: workspace_root,
    workspace: workspace
  } do
    args_log = Path.join(test_root, "args-nomodel.log")
    stub = write_stub_cli(test_root, args_log)

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: workspace_root,
      agent_kind: "cursor_cli",
      agent_cursor_command: stub
    )

    issue = %Issue{id: "issue-n", identifier: "MT-N", title: "无模型", state: "In Progress"}

    assert {:ok, session} = CursorCli.start_session(workspace, [])
    on_exit(fn -> CursorCli.stop_session(session) end)

    assert session.model == nil

    assert {:ok, _} = CursorCli.run_turn(session, "任务", issue, on_message: fn _ -> :ok end)

    refute File.read!(args_log) =~ "--model"
  end

  test "子进程异常退出时上报 turn_ended_with_error 而不是沉默", %{
    test_root: test_root,
    workspace_root: workspace_root,
    workspace: workspace
  } do
    args_log = Path.join(test_root, "args-crash.log")
    stub = write_stub_cli(test_root, args_log, mode: "crash")

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: workspace_root,
      agent_kind: "cursor_cli",
      agent_cursor_command: stub
    )

    parent = self()
    on_message = fn message -> send(parent, {:agent_event, message}) end

    assert {:ok, session} = CursorCli.start_session(workspace, [])
    on_exit(fn -> CursorCli.stop_session(session) end)

    issue = %Issue{id: "issue-c", identifier: "MT-C", title: "崩溃", state: "In Progress"}

    assert {:error, {:port_exit, 1, output}} =
             CursorCli.run_turn(session, "会崩", issue, on_message: on_message)

    assert output =~ "额度" or output =~ "quota" or output =~ "limit"

    events = collect_events()
    assert :session_started in events
    assert :turn_ended_with_error in events
  end

  # ------------------------------------------------------------------ helpers

  defp collect_events(acc \\ []) do
    receive do
      {:agent_event, %{event: event}} -> collect_events([event | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp write_stub_cli(test_root, args_log, opts \\ []) do
    path = Path.join(test_root, "fake-cursor-agent")
    mode = Keyword.get(opts, :mode, "success")

    body =
      case mode do
        "error" ->
          """
          echo '{"type":"system","subtype":"init","session_id":"chat-abc","model":"stub"}'
          echo '{"type":"error","message":"模型额度不足"}'
          exit 0
          """

        "crash" ->
          """
          echo '{"type":"system","subtype":"init","session_id":"chat-abc","model":"stub"}'
          echo 'b: weekly usage limit reached, quota exhausted' >&2
          exit 1
          """

        _ ->
          """
          echo '{"type":"system","subtype":"init","session_id":"chat-abc","model":"stub"}'
          echo '{"type":"thinking","subtype":"delta","text":"先看看仓库结构"}'
          echo '{"type":"tool_call","subtype":"started","call_id":"call-1","tool_call":{"shellToolCall":{"command":"ls"}}}'
          echo '{"type":"tool_call","subtype":"completed","call_id":"call-1","tool_call":{"shellToolCall":{"command":"ls"}}}'
          echo '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"已完成"}]}}'
          echo '{"type":"result","subtype":"success","is_error":false,"duration_ms":1234,"result":"已完成第一个任务","session_id":"chat-abc","usage":{"inputTokens":120,"outputTokens":30,"cacheReadTokens":0,"cacheWriteTokens":0}}'
          """
      end

    File.write!(path, """
    #!/bin/sh
    printf '%s\\n' "$*" >> #{shell_quote(args_log)}
    #{body}
    """)

    File.chmod!(path, 0o755)
    path
  end

  defp shell_quote(value), do: "'" <> String.replace(value, "'", "'\\''") <> "'"
end
