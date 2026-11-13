defmodule SymphonyElixir.SessionHistoryTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.SessionHistory

  setup do
    dir = Path.join(System.tmp_dir!(), "symphony-history-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    file = Path.join(dir, "history.json")

    previous = System.get_env("SYMPHONY_HISTORY_FILE")
    System.put_env("SYMPHONY_HISTORY_FILE", file)

    on_exit(fn ->
      if previous do
        System.put_env("SYMPHONY_HISTORY_FILE", previous)
      else
        System.delete_env("SYMPHONY_HISTORY_FILE")
      end

      File.rm_rf(dir)
    end)

    {:ok, history_file: file}
  end

  defp entry(overrides \\ []) do
    Map.merge(
      %{
        issue_id: "issue-1",
        identifier: "SF-1",
        issue_url: "http://sf.sieot.com/bug/1",
        state: "激活",
        session_id: "sess-1",
        worker_host: nil,
        workspace_path: "/tmp/ws/SF-1",
        outcome: :completed,
        error: nil,
        started_at: ~U[2026-02-01 10:00:00Z],
        finished_at: ~U[2026-02-01 10:10:00Z],
        runtime_seconds: 600,
        turn_count: 4,
        codex_input_tokens: 100,
        codex_output_tokens: 20,
        codex_total_tokens: 120,
        trace: [
          %{
            at: ~U[2026-02-01 10:00:05Z],
            event: "item/completed",
            message: %{
              event: :notification,
              message: %{
                "method" => "item/completed",
                "params" => %{"item" => %{"type" => "tool_call", "name" => "Bash", "detail" => "ls"}}
              }
            }
          }
        ]
      },
      Map.new(overrides)
    )
  end

  test "round-trips entries through disk" do
    assert :ok = SessionHistory.save([entry()])

    assert [loaded] = SessionHistory.load()

    assert loaded.issue_id == "issue-1"
    assert loaded.identifier == "SF-1"
    assert loaded.outcome == :completed
    assert loaded.session_id == "sess-1"
    assert loaded.turn_count == 4
    assert loaded.codex_total_tokens == 120

    # 时间必须还原成 DateTime，否则 presenter 的 iso8601 会拿到 nil
    assert %DateTime{} = loaded.started_at
    assert DateTime.compare(loaded.started_at, ~U[2026-02-01 10:00:00Z]) == :eq

    # 轨迹的 message 要还原成原子键，humanize 才能解析出内容
    assert [trace] = loaded.trace
    assert trace.event == "item/completed"
    assert %DateTime{} = trace.at
    assert trace.message.event == :notification
    assert %{"method" => "item/completed"} = trace.message.message
  end

  test "restores trace descriptions via the dashboard humanizer" do
    assert :ok = SessionHistory.save([entry()])
    assert [loaded] = SessionHistory.load()

    assert [trace] = loaded.trace

    assert SymphonyElixir.StatusDashboard.humanize_codex_message(trace.message) =~
             "tool call Bash"
  end

  test "truncates to the configured limit" do
    entries = for i <- 1..30, do: entry(issue_id: "issue-#{i}")

    assert :ok = SessionHistory.save(entries, limit: 25)
    assert length(SessionHistory.load(limit: 25)) == 25

    # 落盘时就已截断，不会无限增长
    assert length(SessionHistory.load(limit: 100)) == 25
  end

  test "treats missing or corrupt files as empty history" do
    File.rm(SessionHistory.path())
    assert SessionHistory.load() == []

    File.write!(SessionHistory.path(), "{ this is not json")
    assert SessionHistory.load() == []

    File.write!(SessionHistory.path(), Jason.encode!(%{"unexpected" => "shape"}))
    assert SessionHistory.load() == []
  end

  test "writes atomically and leaves no temp file behind" do
    assert :ok = SessionHistory.save([entry()])
    refute File.exists?(SessionHistory.path() <> ".tmp")

    file = SessionHistory.path()
    assert {:ok, body} = File.read(file)
    assert {:ok, _} = Jason.decode(body)
  end

  test "unwritable target reports an error instead of crashing" do
    # 把历史文件指到一个不可创建的路径下
    System.put_env("SYMPHONY_HISTORY_FILE", "/dev/null/nested/history.json")
    assert {:error, _} = SessionHistory.save([entry()])
  end
end
