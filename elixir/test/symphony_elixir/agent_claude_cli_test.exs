defmodule SymphonyElixir.AgentClaudeCliTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Agent
  alias SymphonyElixir.Agent.ClaudeCli
  alias SymphonyElixir.Config.Schema

  setup do
    test_root = Path.join(System.tmp_dir!(), "symphony-claude-cli-#{System.unique_integer([:positive])}")
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
      agent_kind: "claude_cli"
    )

    assert Agent.impl() == ClaudeCli
  end

  test "claude_cli 是合法的 agent.kind" do
    assert {:ok, %Schema{agent: %{kind: "claude_cli"}}} =
             Schema.parse(%{"agent" => %{"kind" => "claude_cli"}})
  end

  test "run_turn 把 stream-json 事件映射成 Codex 语义并保留 session id", %{
    test_root: test_root,
    workspace_root: workspace_root,
    workspace: workspace
  } do
    args_log = Path.join(test_root, "args.log")
    stub = write_stub_cli(test_root, args_log)

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: workspace_root,
      agent_kind: "claude_cli",
      agent_claude_command: stub
    )

    parent = self()
    on_message = fn message -> send(parent, {:agent_event, message}) end

    assert {:ok, session} = ClaudeCli.start_session(workspace, [])
    on_exit(fn -> ClaudeCli.stop_session(session) end)

    issue = %Issue{id: "issue-1", identifier: "MT-1", title: "Claude 冒烟", state: "In Progress"}

    assert {:ok, first_turn} =
             ClaudeCli.run_turn(session, "第一个任务", issue, on_message: on_message)

    assert first_turn.result == "已完成第一个任务"
    assert first_turn.session_id == "sess-claude"
    assert first_turn.turn_id == 1

    messages = collect_messages()
    events = Enum.map(messages, & &1.event)
    assert :session_started in events
    assert :turn_completed in events
    refute :startup_failed in events
    refute :turn_failed in events

    notifications =
      messages |> Enum.filter(&(&1.event == :notification)) |> Enum.map(& &1.payload)

    deltas =
      notifications
      |> Enum.filter(&(&1["method"] == "item/agentMessage/delta"))
      |> Enum.map_join("", &get_in(&1, ["params", "delta"]))

    # 流式增量必须拼出完整文本，且不能因为 assistant 整块重复而上报两遍
    assert deltas == "已完成"

    # 工具名来自 tool_use，completed 事件不能退化成占位名
    started =
      notifications
      |> Enum.filter(&(&1["method"] == "item/started"))
      |> Enum.map(&get_in(&1, ["params", "item", "name"]))

    completed =
      notifications
      |> Enum.filter(&(&1["method"] == "item/completed"))
      |> Enum.map(&get_in(&1, ["params", "item", "name"]))

    assert started == ["Bash"]
    assert completed == ["Bash"]

    assert {:ok, second_turn} =
             ClaudeCli.run_turn(session, "第二个任务", issue, on_message: on_message)

    assert second_turn.turn_id == 2

    invocations = File.read!(args_log) |> String.split("\n", trim: true)
    assert length(invocations) == 2

    [first_args, second_args] = invocations
    refute first_args =~ "--resume"

    # stream-json 必须配 --verbose，否则 CLI 直接报错
    assert second_args =~ "--verbose"
    assert second_args =~ "--output-format stream-json"
    assert second_args =~ "--dangerously-skip-permissions"
    assert second_args =~ "--include-partial-messages"
    # 不能开最小模式：它把内置工具裁到只剩 Bash/Edit/Read，连 Write 都没有
    refute second_args =~ "SIMPLE=1"
    # stdin 必须显式接 /dev/null（字符设备），否则会静默卡死
    assert second_args =~ "STDIN=chardev"
    assert second_args =~ "--resume sess-claude"
  end

  test "没有流式增量时回退用 assistant 整块文本，保证内容不丢", %{
    test_root: test_root,
    workspace_root: workspace_root,
    workspace: workspace
  } do
    args_log = Path.join(test_root, "args-nodelta.log")
    stub = write_stub_cli(test_root, args_log, mode: "no_delta")

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: workspace_root,
      agent_kind: "claude_cli",
      agent_claude_command: stub
    )

    parent = self()
    on_message = fn message -> send(parent, {:agent_event, message}) end

    assert {:ok, session} = ClaudeCli.start_session(workspace, [])
    on_exit(fn -> ClaudeCli.stop_session(session) end)

    issue = %Issue{id: "issue-2", identifier: "MT-2", title: "无增量", state: "In Progress"}

    assert {:ok, _turn} = ClaudeCli.run_turn(session, "任务", issue, on_message: on_message)

    deltas =
      collect_messages()
      |> Enum.filter(&(&1.event == :notification))
      |> Enum.filter(&(&1.payload["method"] == "item/agentMessage/delta"))
      |> Enum.map_join("", &get_in(&1.payload, ["params", "delta"]))

    assert deltas == "整块文本"
  end

  test "is_error 或 error_* subtype 时按失败上报", %{
    test_root: test_root,
    workspace_root: workspace_root,
    workspace: workspace
  } do
    args_log = Path.join(test_root, "args-err.log")
    stub = write_stub_cli(test_root, args_log, mode: "failed")

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: workspace_root,
      agent_kind: "claude_cli",
      agent_claude_command: stub
    )

    parent = self()
    on_message = fn message -> send(parent, {:agent_event, message}) end

    assert {:ok, session} = ClaudeCli.start_session(workspace, [])
    on_exit(fn -> ClaudeCli.stop_session(session) end)

    issue = %Issue{id: "issue-3", identifier: "MT-3", title: "失败路径", state: "In Progress"}

    assert {:error, {:turn_failed, _}} =
             ClaudeCli.run_turn(session, "会失败的任务", issue, on_message: on_message)

    assert :turn_failed in (collect_messages() |> Enum.map(& &1.event))
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
      agent_kind: "claude_cli",
      agent_claude_command: stub
    )

    parent = self()
    on_message = fn message -> send(parent, {:agent_event, message}) end

    assert {:ok, session} = ClaudeCli.start_session(workspace, [])
    on_exit(fn -> ClaudeCli.stop_session(session) end)

    issue = %Issue{id: "issue-4", identifier: "MT-4", title: "崩溃", state: "In Progress"}

    assert {:error, {:port_exit, 1, output}} =
             ClaudeCli.run_turn(session, "会崩", issue, on_message: on_message)

    assert output =~ "auth" or output =~ "required"

    events = collect_messages() |> Enum.map(& &1.event)
    assert :turn_ended_with_error in events
  end

  test "拒绝工作区根目录与外部目录", %{workspace_root: workspace_root} do
    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: workspace_root,
      agent_kind: "claude_cli"
    )

    outside = Path.join(Path.dirname(workspace_root), "outside-#{System.unique_integer([:positive])}")
    File.mkdir_p!(outside)
    on_exit(fn -> File.rm_rf(outside) end)

    assert {:error, {:invalid_workspace_cwd, :workspace_root, _path}} =
             ClaudeCli.start_session(workspace_root, [])

    assert {:error, {:invalid_workspace_cwd, :outside_workspace_root, _path, _root}} =
             ClaudeCli.start_session(outside, [])
  end

  test "远程 worker 未支持时明确报错", %{workspace_root: workspace_root, workspace: workspace} do
    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: workspace_root,
      agent_kind: "claude_cli"
    )

    assert {:error, {:claude_cli_remote_worker_unsupported, "build-host"}} =
             ClaudeCli.start_session(workspace, worker_host: "build-host")
  end

  test "MCP 端点通过 --mcp-config 内联注入，不写任何配置文件", %{
    test_root: test_root,
    workspace_root: workspace_root,
    workspace: workspace
  } do
    args_log = Path.join(test_root, "args-mcp.log")
    stub = write_stub_cli(test_root, args_log)

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: workspace_root,
      agent_kind: "claude_cli",
      agent_claude_command: stub,
      server_port: 4599
    )

    assert {:ok, session} = ClaudeCli.start_session(workspace, [])
    on_exit(fn -> ClaudeCli.stop_session(session) end)

    assert session.mcp_url == "http://127.0.0.1:4599/mcp"

    issue = %Issue{id: "issue-5", identifier: "MT-5", title: "MCP", state: "In Progress"}
    assert {:ok, _} = ClaudeCli.run_turn(session, "任务", issue, on_message: fn _ -> :ok end)

    logged = File.read!(args_log) |> String.split("\n", trim: true) |> List.first()

    assert logged =~ "--mcp-config"
    assert logged =~ "mcpServers"
    assert logged =~ "http://127.0.0.1:4599/mcp"
    # 只认本次注入的 MCP，忽略用户级其它 MCP，避免无关工具混入
    assert logged =~ "--strict-mcp-config"

    # Claude Code 走内联配置，工作区里不应该出现任何 Symphony 写的 MCP 文件
    refute File.exists?(Path.join(workspace, ".claude"))

    # 也不应该碰用户级配置
    refute File.exists?(Path.join(workspace, "zcode.json"))
  end

  test "没有 HTTP 端口时不传 --mcp-config", %{
    test_root: test_root,
    workspace_root: workspace_root,
    workspace: workspace
  } do
    args_log = Path.join(test_root, "args-nomcp.log")
    stub = write_stub_cli(test_root, args_log)

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: workspace_root,
      agent_kind: "claude_cli",
      agent_claude_command: stub
    )

    assert {:ok, session} = ClaudeCli.start_session(workspace, [])
    on_exit(fn -> ClaudeCli.stop_session(session) end)

    assert session.mcp_url == nil

    issue = %Issue{id: "issue-6", identifier: "MT-6", title: "无 MCP", state: "In Progress"}
    assert {:ok, _} = ClaudeCli.run_turn(session, "任务", issue, on_message: fn _ -> :ok end)

    refute File.read!(args_log) =~ "--mcp-config"
    # 没有注入 MCP 时也不该打开 strict，保持与用户原有配置一致
    refute File.read!(args_log) =~ "--strict-mcp-config"
  end

  test "claude_model 配置会传给 --model，留空则不传", %{
    test_root: test_root,
    workspace_root: workspace_root,
    workspace: workspace
  } do
    args_log = Path.join(test_root, "args-model.log")
    stub = write_stub_cli(test_root, args_log)

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: workspace_root,
      agent_kind: "claude_cli",
      agent_claude_command: stub,
      agent_claude_model: "deepseek-flash[1M]"
    )

    issue = %Issue{id: "issue-m", identifier: "MT-M", title: "模型参数", state: "In Progress"}

    assert {:ok, session} = ClaudeCli.start_session(workspace, [])
    on_exit(fn -> ClaudeCli.stop_session(session) end)

    assert session.model == "deepseek-flash[1M]"

    assert {:ok, _} = ClaudeCli.run_turn(session, "任务", issue, on_message: fn _ -> :ok end)

    assert File.read!(args_log) =~ "--model deepseek-flash[1M]"
  end

  test "未配置 claude_model 时不传 --model，交给 Claude 自身配置决定", %{
    test_root: test_root,
    workspace_root: workspace_root,
    workspace: workspace
  } do
    args_log = Path.join(test_root, "args-nomodel.log")
    stub = write_stub_cli(test_root, args_log)

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: workspace_root,
      agent_kind: "claude_cli",
      agent_claude_command: stub
    )

    issue = %Issue{id: "issue-n", identifier: "MT-N", title: "无模型", state: "In Progress"}

    assert {:ok, session} = ClaudeCli.start_session(workspace, [])
    on_exit(fn -> ClaudeCli.stop_session(session) end)

    assert session.model == nil

    assert {:ok, _} = ClaudeCli.run_turn(session, "任务", issue, on_message: fn _ -> :ok end)

    refute File.read!(args_log) =~ "--model"
  end

  # ------------------------------------------------------------------ helpers

  defp collect_messages(acc \\ []) do
    receive do
      {:agent_event, message} -> collect_messages([message | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp write_stub_cli(test_root, args_log, opts \\ []) do
    path = Path.join(test_root, "fake-claude")
    mode = Keyword.get(opts, :mode, "success")

    body =
      case mode do
        "failed" ->
          """
          echo '{"type":"system","subtype":"init","session_id":"sess-claude","model":"stub","tools":[]}'
          echo '{"type":"result","subtype":"error_during_execution","is_error":true,"session_id":"sess-claude","result":"失败","usage":{"input_tokens":10,"output_tokens":0}}'
          """

        "crash" ->
          """
          echo '{"type":"system","subtype":"init","session_id":"sess-claude","model":"stub","tools":[]}'
          echo 'claude: auth required' >&2
          exit 1
          """

        "no_delta" ->
          """
          echo '{"type":"system","subtype":"init","session_id":"sess-claude","model":"stub","tools":[]}'
          echo '{"type":"assistant","message":{"id":"msg-1","role":"assistant","content":[{"type":"text","text":"整块文本"}]},"session_id":"sess-claude"}'
          echo '{"type":"result","subtype":"success","is_error":false,"session_id":"sess-claude","result":"整块文本","usage":{"input_tokens":10,"output_tokens":5}}'
          """

        _ ->
          """
          echo '{"type":"system","subtype":"init","session_id":"sess-claude","model":"stub","tools":["Bash"]}'
          echo '{"type":"stream_event","event":{"type":"message_start","message":{"id":"msg-1","role":"assistant","content":[]}},"session_id":"sess-claude"}'
          echo '{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"先看看"}},"session_id":"sess-claude"}'
          echo '{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"已完成"}},"session_id":"sess-claude"}'
          echo '{"type":"assistant","message":{"id":"msg-1","role":"assistant","content":[{"type":"thinking","thinking":"先看看"},{"type":"text","text":"已完成"},{"type":"tool_use","id":"tool-1","name":"Bash","input":{"command":"ls"}}]},"session_id":"sess-claude"}'
          echo '{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"tool-1","content":"ok","is_error":false}]},"session_id":"sess-claude"}'
          echo '{"type":"result","subtype":"success","is_error":false,"session_id":"sess-claude","result":"已完成第一个任务","num_turns":2,"total_cost_usd":0.01,"usage":{"input_tokens":120,"output_tokens":30,"cache_read_input_tokens":7,"cache_creation_input_tokens":3}}'
          """
      end

    File.write!(path, """
    #!/bin/sh
    if [ -c /dev/fd/0 ]; then STDIN=chardev; else STDIN=other; fi
    printf 'SIMPLE=%s STDIN=%s %s\\n' "${CLAUDE_CODE_SIMPLE:-none}" "$STDIN" "$*" >> #{shell_quote(args_log)}
    #{body}
    """)

    File.chmod!(path, 0o755)
    path
  end

  defp shell_quote(value), do: "'" <> String.replace(value, "'", "'\\''") <> "'"
end
