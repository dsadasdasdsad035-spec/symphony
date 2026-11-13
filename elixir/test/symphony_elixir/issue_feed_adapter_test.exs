defmodule SymphonyElixir.IssueFeed.AdapterTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.IssueFeed.Adapter, as: IssueFeedAdapter
  alias SymphonyElixir.IssueFeed.Client, as: IssueFeedClient
  alias SymphonyElixir.Tracker

  defmodule FakeIssueFeedClient do
    def fetch_issues_by_states(states) do
      send(self(), {:issue_feed_states_called, states})
      {:ok, states}
    end

    def fetch_issues_by_ids(ids) do
      send(self(), {:issue_feed_ids_called, ids})
      {:ok, ids}
    end
  end

  setup do
    client_module = Application.get_env(:symphony_elixir, :issue_feed_client_module)

    on_exit(fn ->
      if is_nil(client_module) do
        Application.delete_env(:symphony_elixir, :issue_feed_client_module)
      else
        Application.put_env(:symphony_elixir, :issue_feed_client_module, client_module)
      end
    end)

    :ok
  end

  test "adapter validates issue_feed config and delegates reads" do
    settings = tracker_settings()

    assert :ok = IssueFeedAdapter.validate_config(settings)

    assert {:error, :missing_issue_feed_active_states} =
             IssueFeedAdapter.validate_config(%{settings | active_states: nil})

    assert {:error, :missing_issue_feed_terminal_states} =
             IssueFeedAdapter.validate_config(%{settings | terminal_states: nil})

    assert :ok = IssueFeedAdapter.validate_config(%{settings | active_states: [], terminal_states: []})

    assert {:error, :invalid_issue_feed_states} =
             IssueFeedAdapter.validate_config(%{settings | active_states: ["open"]})

    Application.put_env(:symphony_elixir, :issue_feed_client_module, FakeIssueFeedClient)

    assert {:ok, ["todo"]} = IssueFeedAdapter.fetch_issues_by_states(["todo"])
    assert_receive {:issue_feed_states_called, ["todo"]}

    assert {:ok, ["1"]} = IssueFeedAdapter.fetch_issues_by_ids(["1"])
    assert_receive {:issue_feed_ids_called, ["1"]}

    assert IssueFeedAdapter.secret_environment_names(settings) == ["TRACKER_API_TOKEN"]

    assert [%{"name" => "tracker_api"}] = IssueFeedAdapter.agent_tool_specs()

    assert IssueFeedAdapter.execute_agent_tool(
             "tracker_api",
             %{
               "method" => "PATCH",
               "path" => "/api/v1/issues/1",
               "body" => %{"state" => "in_review"}
             },
             issue_feed_client: fn _method, _path, _params, _body, _opts ->
               {:ok, %{status: 200, body: %{"issue" => %{"state" => "in_review"}}}}
             end
           )["success"]

    refute IssueFeedAdapter.execute_agent_tool(
             "tracker_api",
             %{"method" => "GET", "path" => "/api/symphony/issues"},
             issue_feed_client: fn _, _, _, _, _ -> {:ok, %{status: 200, body: %{}}} end
           )["success"]
  end

  test "client validates base URL and project" do
    assert :ok = IssueFeedClient.validate_settings(tracker_settings())

    assert {:error, :invalid_issue_feed_base_url} =
             IssueFeedClient.validate_settings(
               tracker_settings(%{"base_url" => "ftp://bad"})
             )

    assert {:error, :missing_issue_feed_project} =
             IssueFeedClient.validate_settings(%{
               tracker_settings()
               | project_slug: nil,
                 provider: %{"base_url" => "http://127.0.0.1:4780", "project" => ""}
             })
  end

  test "client normalizes issue feed payloads" do
    issue =
      IssueFeedClient.normalize_issue_for_test(%{
        "id" => "12",
        "identifier" => "COMIC-12",
        "title" => "导出 PNG",
        "description" => "实现导出",
        "state" => "In_Progress",
        "url" => "http://127.0.0.1:4780/p/comic/issues/12",
        "labels" => ["Symphony", "bug"],
        "assignee" => "mjy",
        "priority" => 2,
        "branch_name" => "feature/export",
        "created_at" => "2026-11-13T12:00:00Z",
        "updated_at" => "2026-11-13 13:05:46"
      })

    assert issue.id == "12"
    assert issue.identifier == "COMIC-12"
    assert issue.state == "in_progress"
    assert issue.labels == ["symphony", "bug"]
    assert issue.dispatchable
    assert %DateTime{} = issue.updated_at
    assert issue.priority == 2
    assert issue.branch_name == "feature/export"
    assert %DateTime{} = issue.created_at
  end

  test "client applies linear-style dispatch rules for assignee and blockers" do
    issue =
      IssueFeedClient.normalize_issue_for_test(
        %{
          "id" => "9",
          "identifier" => "COMIC-9",
          "title" => "Blocked task",
          "state" => "todo",
          "assignee" => "alice",
          "priority" => 2,
          "blocked_by" => [
            %{"id" => "8", "identifier" => "COMIC-8", "state" => "in_progress"}
          ],
          "labels" => ["symphony"]
        },
        "alice"
      )

    refute issue.dispatchable

    assert IssueFeedClient.normalize_issue_for_test(
             %{
               "id" => "10",
               "identifier" => "COMIC-10",
               "title" => "Other assignee",
               "state" => "todo",
               "assignee" => "bob",
               "labels" => ["symphony"]
             },
             "alice"
           ).dispatchable == false

    assert IssueFeedClient.normalize_issue_for_test(
             %{
               "id" => "11",
               "identifier" => "COMIC-11",
               "title" => "In progress blocked",
               "state" => "in_progress",
               "assignee" => "alice",
               "blocked_by" => [
                 %{"id" => "8", "identifier" => "COMIC-8", "state" => "in_progress"}
               ],
               "labels" => ["symphony"]
             },
             "alice"
           ).dispatchable
  end

  test "client fetches issues via injectable request function" do
    settings = tracker_settings()

    request_fun = fn method, path, params, _body, _settings ->
      assert method == :get
      assert path == "/api/symphony/issues"
      assert params["project"] == "comic"
      assert params["states"] == "todo,in_progress"

      {:ok,
       %{
         "issues" => [
           %{
             "id" => "1",
             "identifier" => "COMIC-1",
             "title" => "Task",
             "state" => "todo",
             "labels" => ["symphony"]
           }
         ]
       }}
    end

    assert {:ok, [issue]} =
             IssueFeedClient.fetch_issues_by_states_for_test(
               ["todo", "in_progress"],
               settings,
               request_fun
             )

    assert issue.identifier == "COMIC-1"
  end

  test "workflow accepts issue_feed kind" do
    write_issue_feed_workflow!(Workflow.workflow_file_path())

    assert Config.settings!().tracker.kind == "issue_feed"
    assert Tracker.adapter() == IssueFeedAdapter
    assert :ok = Config.validate!()
  end

  defp tracker_settings(provider_overrides \\ %{}) do
    %{
      kind: "issue_feed",
      endpoint: "http://127.0.0.1:4780",
      project_slug: "comic",
      provider:
        Map.merge(
          %{"base_url" => "http://127.0.0.1:4780", "project" => "comic"},
          provider_overrides
        ),
      active_states: ["todo", "in_progress"],
      terminal_states: ["done", "cancelled"]
    }
  end

  defp write_issue_feed_workflow!(path) do
    File.write!(
      path,
      """
      ---
      tracker:
        kind: issue_feed
        endpoint: http://127.0.0.1:4780
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
          base_url: http://127.0.0.1:4780
          project: comic
      ---

      You are working on {{ issue.identifier }}.
      """
    )

    if Process.whereis(SymphonyElixir.WorkflowStore) do
      assert :ok = SymphonyElixir.WorkflowStore.force_reload()
    end
  end
end
