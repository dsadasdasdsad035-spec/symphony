defmodule SymphonyElixir.AgentZcodeTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Agent
  alias SymphonyElixir.Agent.Zcode
  alias SymphonyElixir.Config.Schema

  setup do
    test_root = Path.join(System.tmp_dir!(), "symphony-zcode-#{System.unique_integer([:positive])}")
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
      agent_kind: "zcode"
    )

    assert Agent.impl() == Zcode
  end

  test "zcode 是合法的 agent.kind" do
    assert {:ok, %Schema{agent: %{kind: "zcode"}}} =
             Schema.parse(%{"agent" => %{"kind" => "zcode"}})
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
      agent_kind: "zcode",
      agent_zcode_command: stub
    )

    parent = self()
    on_message = fn message -> send(parent, {:agent_event, message}) end

    assert {:ok, session} = Zcode.start_session(workspace, [])
    on_exit(fn -> Zcode.stop_session(session) end)

    issue = %Issue{id: "issue-1", identifier: "MT-1", title: "ZCode 冒烟", state: "In Progress"}

    assert {:ok, first_turn} =
             Zcode.run_turn(session, "第一个任务", issue, on_message: on_message)

    assert first_turn.result == "已完成第一个任务"
    assert first_turn.session_id == "sess-abc"
    assert first_turn.turn_id == 1

    messages = collect_messages()
    events = Enum.map(messages, & &1.event)
    assert :session_started in events
    assert :turn_completed in events
    refute :startup_failed in events
    refute :turn_failed in events

    # 文本增量与工具事件要转成 Codex 的 item 语义
    notifications =
      messages
      |> Enum.filter(&(&1.event == :notification))
      |> Enum.map(& &1.payload)

    assert Enum.any?(notifications, &(&1["method"] == "item/agentMessage/delta"))
    assert Enum.any?(notifications, &(&1["method"] == "item/started"))
    assert Enum.any?(notifications, &(&1["method"] == "item/completed"))

    assert {:ok, second_turn} =
             Zcode.run_turn(session, "第二个任务", issue, on_message: on_message)

    assert second_turn.turn_id == 2

    invocations = File.read!(args_log) |> String.split("\n", trim: true)
    assert length(invocations) == 2

    [first_args, second_args] = invocations
    refute first_args =~ "--resume"
    assert second_args =~ "--resume sess-abc"
    assert second_args =~ "第二个任务"
    assert second_args =~ "--output-format stream-json"
    assert second_args =~ "--mode yolo"
  end

  test "turn.completed 的 resultType 非 success 时按失败上报", %{
    test_root: test_root,
    workspace_root: workspace_root,
    workspace: workspace
  } do
    args_log = Path.join(test_root, "args-err.log")
    stub = write_stub_cli(test_root, args_log, mode: "failed")

    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: workspace_root,
      agent_kind: "zcode",
      agent_zcode_command: stub
    )

    parent = self()
    on_message = fn message -> send(parent, {:agent_event, message}) end

    assert {:ok, session} = Zcode.start_session(workspace, [])
    on_exit(fn -> Zcode.stop_session(session) end)

    issue = %Issue{id: "issue-2", identifier: "MT-2", title: "失败路径", state: "In Progress"}

    assert {:error, {:turn_failed, _}} =
             Zcode.run_turn(session, "会失败的任务", issue, on_message: on_message)

    assert :turn_failed in collect_events()
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
      agent_kind: "zcode",
      agent_zcode_command: stub
    )

    parent = self()
    on_message = fn message -> send(parent, {:agent_event, message}) end

    assert {:ok, session} = Zcode.start_session(workspace, [])
    on_exit(fn -> Zcode.stop_session(session) end)

    issue = %Issue{id: "issue-3", identifier: "MT-3", title: "崩溃", state: "In Progress"}

    assert {:error, {:port_exit, 1, output}} =
             Zcode.run_turn(session, "会崩", issue, on_message: on_message)

    assert output =~ "provider" or output =~ "auth"

    events = collect_events()
    assert :session_started in events
    assert :turn_ended_with_error in events
  end

  test "拒绝工作区根目录与外部目录", %{workspace_root: workspace_root} do
    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: workspace_root,
      agent_kind: "zcode"
    )

    outside = Path.join(Path.dirname(workspace_root), "outside-#{System.unique_integer([:positive])}")
    File.mkdir_p!(outside)
    on_exit(fn -> File.rm_rf(outside) end)

    assert {:error, {:invalid_workspace_cwd, :workspace_root, _path}} =
             Zcode.start_session(workspace_root, [])

    assert {:error, {:invalid_workspace_cwd, :outside_workspace_root, _path, _root}} =
             Zcode.start_session(outside, [])
  end

  test "远程 worker 未支持时明确报错", %{workspace_root: workspace_root, workspace: workspace} do
    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: workspace_root,
      agent_kind: "zcode"
    )

    assert {:error, {:zcode_remote_worker_unsupported, "build-host"}} =
             Zcode.start_session(workspace, worker_host: "build-host")
  end

  test "start_session 把 Symphony MCP 端点写进 zcode.json 并与已有配置合并", %{
    workspace_root: workspace_root,
    workspace: workspace
  } do
    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: workspace_root,
      agent_kind: "zcode",
      server_port: 4599
    )

    File.write!(
      Path.join(workspace, "zcode.json"),
      Jason.encode!(%{
        "mcp" => %{
          "servers" => %{"existing" => %{"type" => "http", "url" => "http://example.test/mcp"}}
        }
      })
    )

    assert {:ok, session} = Zcode.start_session(workspace, [])
    on_exit(fn -> Zcode.stop_session(session) end)

    assert session.mcp_url == "http://127.0.0.1:4599/mcp"

    decoded = Path.join(workspace, "zcode.json") |> File.read!() |> Jason.decode!()

    # ZCode 要求显式开启 MCP 能力
    assert decoded["features"]["mcp"] == true

    assert decoded["mcp"]["servers"]["symphony"] == %{
             "type" => "http",
             "url" => "http://127.0.0.1:4599/mcp",
             "enabled" => true,
             "timeoutMs" => 30_000
           }

    assert decoded["mcp"]["servers"]["existing"]["url"] == "http://example.test/mcp"
  end

  test "写 zcode.json 时同步加入 .git/info/exclude，避免被提交", %{
    workspace_root: workspace_root,
    workspace: workspace
  } do
    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: workspace_root,
      agent_kind: "zcode",
      server_port: 4599
    )

    File.mkdir_p!(Path.join(workspace, ".git/info"))

    assert {:ok, session} = Zcode.start_session(workspace, [])
    on_exit(fn -> Zcode.stop_session(session) end)

    exclude_path = Path.join(workspace, ".git/info/exclude")
    assert File.read!(exclude_path) =~ "zcode.json"

    # 重复启动不应重复追加
    assert {:ok, session2} = Zcode.start_session(workspace, [])
    Zcode.stop_session(session2)

    assert File.read!(exclude_path) =~ ~r/zcode\.json(?![\s\S]*zcode\.json)/
  end

  test "没有 HTTP 端口时不写 zcode.json", %{workspace_root: workspace_root, workspace: workspace} do
    write_workflow_file!(Workflow.workflow_file_path(),
      workspace_root: workspace_root,
      agent_kind: "zcode"
    )

    assert {:ok, session} = Zcode.start_session(workspace, [])
    on_exit(fn -> Zcode.stop_session(session) end)

    assert session.mcp_url == nil
    refute File.exists?(Path.join(workspace, "zcode.json"))
  end

  # ------------------------------------------------------------------ helpers

  defp collect_messages(acc \\ []) do
    receive do
      {:agent_event, message} -> collect_messages([message | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp collect_events do
    collect_messages() |> Enum.map(& &1.event)
  end

  defp write_stub_cli(test_root, args_log, opts \\ []) do
    path = Path.join(test_root, "fake-zcode")
    mode = Keyword.get(opts, :mode, "success")

    body =
      case mode do
        "failed" ->
          """
          echo '{"type":"session.updated","payload":{"type":"model_request_started"},"seq":1,"sessionId":"sess-abc","turnId":"turn-1"}'
          echo '{"type":"turn.completed","payload":{"response":"","resultType":"error","usage":{"inputTokens":10,"outputTokens":0}},"seq":2,"sessionId":"sess-abc","turnId":"turn-1"}'
          echo '{"type":"result","sessionId":"sess-abc","turnId":"turn-1","response":"","usage":{"inputTokens":10,"outputTokens":0}}'
          exit 0
          """

        "crash" ->
          """
          echo '{"type":"session.updated","payload":{"type":"model_request_started"},"seq":1,"sessionId":"sess-abc","turnId":"turn-1"}'
          echo 'zcode: provider auth failed' >&2
          exit 1
          """

        _ ->
          """
          echo '{"type":"session.updated","payload":{"type":"model_request_started"},"seq":1,"sessionId":"sess-abc","traceId":"trace-1","turnId":"turn-1"}'
          echo '{"type":"turn.started","payload":{"turnNumber":0},"seq":2,"sessionId":"sess-abc","turnId":"turn-1"}'
          echo '{"type":"model.streaming","payload":{"kind":"reasoning_start","delta":"","done":false},"sessionId":"sess-abc"}'
          echo '{"type":"model.streaming","payload":{"kind":"text_delta","delta":"已完成","done":false},"sessionId":"sess-abc"}'
          echo '{"type":"model.streaming","payload":{"kind":"tool_input_start","toolCallId":"call-1","toolName":"Bash","delta":"","done":false},"sessionId":"sess-abc"}'
          echo '{"type":"tool.updated","payload":{"kind":"started","toolCallId":"call-1","toolName":"Bash"},"sessionId":"sess-abc"}'
          echo '{"type":"tool.updated","payload":{"kind":"result","toolCallId":"call-1","result":{"success":true,"content":"ok"},"duration":12},"sessionId":"sess-abc"}'
          echo '{"type":"turn.completed","payload":{"response":"已完成第一个任务","usage":{"inputTokens":120,"outputTokens":30,"totalTokens":150},"toolCallCount":1,"resultType":"success","duration":1234},"seq":9,"sessionId":"sess-abc","turnId":"turn-1"}'
          echo '{"type":"result","sessionId":"sess-abc","traceId":"trace-1","turnId":"turn-1","response":"已完成第一个任务","usage":{"inputTokens":120,"outputTokens":30,"totalTokens":150},"eventCount":8,"projection":{"status":"idle"}}'
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
