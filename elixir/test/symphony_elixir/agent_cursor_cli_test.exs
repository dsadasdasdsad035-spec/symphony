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
