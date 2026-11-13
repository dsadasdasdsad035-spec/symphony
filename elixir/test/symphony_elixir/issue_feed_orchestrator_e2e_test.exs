defmodule SymphonyElixir.IssueFeed.OrchestratorE2ETest do
  @moduledoc """
  全链路：Tracker HTTP → issue_feed 轮询 → Orchestrator 派发 → fake codex 跑完一轮。
  由 tracker/scripts/e2e-test.sh --full-chain 启动，需环境变量：
  - SYMPHONY_RUN_ISSUE_FEED_E2E=1
  - TRACKER_BASE_URL
  - E2E_ISSUE_ID
  - E2E_ISSUE_IDENTIFIER（可选，用于断言工作区目录名）
  """
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Tracker.Issue
  alias SymphonyElixir.Workflow

  @moduletag :issue_feed_e2e
  @moduletag timeout: 120_000

  setup_all do
    if System.get_env("SYMPHONY_RUN_ISSUE_FEED_E2E") != "1" do
      {:skip, "set SYMPHONY_RUN_ISSUE_FEED_E2E=1（由 e2e-test.sh --full-chain 设置）"}
    else
      :ok
    end
  end

  test "orchestrator 从 Tracker 拉取工单并派发 fake agent 完成工作区创建" do
    base_url = required_env!("TRACKER_BASE_URL") |> String.trim_trailing("/")
    issue_id = required_env!("E2E_ISSUE_ID")
    issue_identifier = System.get_env("E2E_ISSUE_IDENTIFIER") || "COMIC-1"

    run_suffix = System.unique_integer([:positive])
    test_root = Path.join(System.tmp_dir!(), "symphony-issue-feed-e2e-#{run_suffix}")
    workflow_file = Path.join(test_root, "WORKFLOW.md")
    workspace_root = Path.join(test_root, "workspaces")
    template_repo = Path.join(test_root, "source")
    codex_binary = Path.join(test_root, "fake-codex")
    fixture_codex =
      Path.expand("../../../tracker/scripts/fixtures/fake-codex-app-server.sh", __DIR__)

    orchestrator_name = Module.concat(__MODULE__, "Orchestrator#{run_suffix}")
    task_supervisor_name = Module.concat(__MODULE__, "TaskSupervisor#{run_suffix}")
    runtime_supervisor_name = Module.concat(__MODULE__, "Runtime#{run_suffix}")

    previous_runtime = Process.whereis(SymphonyElixir.AgentRuntimeSupervisor)

    on_exit(fn ->
      case Process.whereis(runtime_supervisor_name) do
        pid when is_pid(pid) ->
          if Process.alive?(pid) do
            try do
              Supervisor.stop(pid, :normal, 5_000)
            catch
              :exit, _ -> :ok
            end
          end

        _ ->
          :ok
      end

      restart_default_runtime!()
      File.rm_rf(test_root)
    end)

    File.mkdir_p!(test_root)
    File.mkdir_p!(workspace_root)
    File.mkdir_p!(template_repo)
    File.write!(Path.join(template_repo, "README.md"), "# e2e\n")
    File.cp!(fixture_codex, codex_binary)
    File.chmod!(codex_binary, 0o755)

    after_create = "cp \"#{Path.join(template_repo, "README.md")}\" README.md"

    write_workflow!(
      workflow_file,
      base_url,
      workspace_root,
      after_create,
      codex_binary
    )

    Workflow.set_workflow_file_path(workflow_file)
    :ok = SymphonyElixir.WorkflowStore.force_reload()
    :ok = Config.validate!()

    stop_agent_runtime!(previous_runtime)

    assert {:ok, _pid} =
             SymphonyElixir.AgentRuntimeSupervisor.start_link(
               name: runtime_supervisor_name,
               task_supervisor_name: task_supervisor_name,
               orchestrator_name: orchestrator_name
             )

    orchestrator_pid = Process.whereis(orchestrator_name)
    assert is_pid(orchestrator_pid)

    assert_dispatched!(orchestrator_pid, issue_id, issue_identifier, workspace_root, 60_000)

    workspace = Path.join(workspace_root, issue_identifier)
    assert File.dir?(workspace), "工作区目录应已创建"
    assert File.exists?(Path.join(workspace, "README.md"))

    assert {:ok, issues} = SymphonyElixir.IssueFeed.Client.fetch_issues_by_ids([issue_id])
    assert [%Issue{id: ^issue_id}] = issues
  end

  defp write_workflow!(path, base_url, workspace_root, after_create, codex_binary) do
    content = """
    ---
    tracker:
      kind: issue_feed
      endpoint: #{base_url}
      project_slug: comic
      required_labels:
        - symphony
      active_states:
        - backlog
        - todo
        - in_progress
        - in_review
      terminal_states:
        - done
        - cancelled
      provider:
        base_url: #{base_url}
        project: comic
        poll_label: symphony
    polling:
      interval_ms: 300
    workspace:
      root: #{workspace_root}
    hooks:
      after_create: |
        #!/bin/sh
        set -e
        #{after_create}
      before_run: |
        #!/bin/sh
        true
    agent:
      kind: codex
      max_concurrent_agents: 2
      max_turns: 3
    codex:
      command: #{codex_binary} app-server
      approval_policy: never
      thread_sandbox: workspace-write
    ---

    E2E issue {{ issue.identifier }}
    """

    File.write!(path, content)
  end

  defp stop_agent_runtime!(nil), do: :ok

  defp stop_agent_runtime!(pid) when is_pid(pid) do
    if Process.alive?(pid) do
      _ =
        Supervisor.terminate_child(
          SymphonyElixir.Supervisor,
          SymphonyElixir.AgentRuntimeSupervisor
        )
    end

    :ok
  end

  defp restart_default_runtime! do
    case Process.whereis(SymphonyElixir.AgentRuntimeSupervisor) do
      nil ->
        case SymphonyElixir.AgentRuntimeSupervisor.start_link(name: SymphonyElixir.AgentRuntimeSupervisor) do
          {:ok, _} -> :ok
          {:error, {:already_started, _}} -> :ok
          {:error, _} -> :ok
        end

      _ ->
        :ok
    end
  end

  defp assert_dispatched!(orchestrator_pid, issue_id, identifier, workspace_root, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    workspace = Path.join(workspace_root, identifier)

    do_wait = fn ->
      saw_running =
        case GenServer.call(orchestrator_pid, :snapshot) do
          %{running: running} when is_list(running) ->
            Enum.any?(running, fn entry ->
              entry_id = Map.get(entry, :issue_id) || Map.get(entry, "issue_id")
              entry_ident = Map.get(entry, :identifier) || Map.get(entry, "identifier")
              to_string(entry_id) == issue_id or entry_ident == identifier
            end)

          _ ->
            false
        end

      cond do
        File.dir?(workspace) -> {:ok, :workspace}
        saw_running -> {:ok, :running}
        System.monotonic_time(:millisecond) >= deadline -> {:error, :timeout}
        true -> :retry
      end
    end

    case poll_until(do_wait, 150) do
      {:ok, _} -> :ok
      {:error, :timeout} -> flunk("超时：未见派发或工作区 issue_id=#{issue_id} path=#{workspace}")
    end
  end

  defp poll_until(fun, sleep_ms) do
    case fun.() do
      :retry ->
        Process.sleep(sleep_ms)
        poll_until(fun, sleep_ms)

      other ->
        other
    end
  end

  defp required_env!(name) do
    case System.get_env(name) do
      value when is_binary(value) and value != "" -> value
      _ -> flunk("missing env #{name}")
    end
  end
end
