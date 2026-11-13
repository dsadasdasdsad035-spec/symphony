defmodule SymphonyElixir.SessionTranscriptTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.SessionTranscript

  # 每个用例用独立的临时目录模拟 ~/.claude/projects，避免读到真实 transcript。
  setup do
    root = Path.join(System.tmp_dir!(), "symphony-transcript-#{System.unique_integer([:positive])}")
    workspace_dir = Path.join(root, "-Users-mjy-code-symphony-workspaces-SF-99999")
    File.mkdir_p!(workspace_dir)

    previous = System.get_env("SYMPHONY_CLAUDE_PROJECTS_DIR")
    System.put_env("SYMPHONY_CLAUDE_PROJECTS_DIR", root)

    on_exit(fn ->
      File.rm_rf(root)

      if previous do
        System.put_env("SYMPHONY_CLAUDE_PROJECTS_DIR", previous)
      else
        System.delete_env("SYMPHONY_CLAUDE_PROJECTS_DIR")
      end
    end)

    {:ok, root: root, workspace_dir: workspace_dir}
  end

  defp write_transcript!(dir, session_id, records) do
    path = Path.join(dir, "#{session_id}.jsonl")
    body = records |> Enum.map_join("\n", &Jason.encode!/1)
    File.write!(path, body <> "\n")
    path
  end

  defp sample_records do
    [
      %{
        "type" => "user",
        "timestamp" => "2026-02-01T10:00:00.000Z",
        "cwd" => "/Users/mjy/code/symphony-workspaces/SF-99999",
        "message" => %{"role" => "user", "content" => "修一下批量上传的清理逻辑"}
      },
      # 客户端埋点，解析时必须忽略
      %{"type" => "api-request-blob", "timestamp" => "2026-02-01T10:00:01.000Z", "data" => "xxx"},
      %{
        "type" => "assistant",
        "timestamp" => "2026-02-01T10:00:02.000Z",
        "cwd" => "/Users/mjy/code/symphony-workspaces/SF-99999",
        "message" => %{
          "role" => "assistant",
          "model" => "deepseek-flash",
          "content" => [
            %{"type" => "thinking", "thinking" => "先看工作区状态"},
            %{
              "type" => "tool_use",
              "id" => "call_1",
              "name" => "Bash",
              "input" => %{"command" => "git status --short", "description" => "看改动"}
            }
          ]
        }
      },
      %{
        "type" => "user",
        "timestamp" => "2026-02-01T10:00:03.000Z",
        "message" => %{
          "role" => "user",
          "content" => [
            %{"type" => "tool_result", "tool_use_id" => "call_1", "content" => " M Foo.java\n", "is_error" => false}
          ]
        }
      },
      %{
        "type" => "assistant",
        "timestamp" => "2026-02-01T10:00:04.000Z",
        "message" => %{
          "role" => "assistant",
          "model" => "deepseek-flash",
          "content" => [
            %{"type" => "tool_use", "id" => "call_2", "name" => "Bash", "input" => %{"command" => "false"}}
          ]
        }
      },
      %{
        "type" => "user",
        "timestamp" => "2026-02-01T10:00:05.000Z",
        "message" => %{
          "role" => "user",
          "content" => [
            %{"type" => "tool_result", "tool_use_id" => "call_2", "content" => "boom", "is_error" => true}
          ]
        }
      }
    ]
  end

  test "loads transcript and exposes ordered execution steps", %{workspace_dir: dir} do
    write_transcript!(dir, "sess-abc", sample_records())

    assert {:ok, transcript} = SessionTranscript.load("sess-abc")

    assert transcript.session_id == "sess-abc"
    assert transcript.cwd == "/Users/mjy/code/symphony-workspaces/SF-99999"
    assert transcript.model == "deepseek-flash"
    assert transcript.started_at == "2026-02-01T10:00:00.000Z"
    assert transcript.finished_at == "2026-02-01T10:00:05.000Z"
    assert transcript.tool_call_count == 2
    assert transcript.error_count == 1

    kinds = Enum.map(transcript.steps, & &1.kind)
    assert kinds == ["prompt", "thinking", "tool_use", "tool_result", "tool_use", "tool_result"]

    # 步骤序号必须连续，否则页面上的 Step 顺序不可信
    assert Enum.map(transcript.steps, & &1.index) == [0, 1, 2, 3, 4, 5]

    # 工具调用的入参摘要与工具名要带上，工具结果要能关联回来
    [_prompt, _thinking, bash_use, bash_result, _fail_use, fail_result] = transcript.steps
    assert bash_use.tool == "Bash"
    assert bash_use.text == "git status --short"
    assert bash_use.status == "started"
    assert bash_result.tool == "Bash"
    assert bash_result.status == "ok"
    assert bash_result.text == " M Foo.java\n"
    assert fail_result.status == "error"
  end

  test "drops streaming-only records and blank lines", %{workspace_dir: dir} do
    path = write_transcript!(dir, "sess-noise", sample_records())
    File.write!(path, "\n\n" <> File.read!(path))

    assert {:ok, transcript} = SessionTranscript.load("sess-noise")
    assert transcript.step_count == 6
    refute Enum.any?(transcript.steps, &(&1.kind in ["api-request", "blob"]))
  end

  test "keeps only the newest steps when max_steps is given", %{workspace_dir: dir} do
    write_transcript!(dir, "sess-limit", sample_records())

    assert {:ok, transcript} = SessionTranscript.load("sess-limit", max_steps: 2)
    assert transcript.step_count == 6
    assert transcript.dropped_count == 4
    assert Enum.map(transcript.steps, & &1.kind) == ["tool_use", "tool_result"]
  end

  test "rejects ids that could escape the projects directory", %{workspace_dir: dir} do
    write_transcript!(dir, "sess-safe", sample_records())

    assert {:error, :invalid_session_id} = SessionTranscript.load("../../etc/passwd")
    assert {:error, :invalid_session_id} = SessionTranscript.load("sess/../../x")
    assert {:ok, _} = SessionTranscript.locate("sess-safe")
  end

  test "reports missing transcripts as not found" do
    assert {:error, :not_found} = SessionTranscript.load("does-not-exist")
    assert {:error, :not_found} = SessionTranscript.locate("does-not-exist")
  end
end
