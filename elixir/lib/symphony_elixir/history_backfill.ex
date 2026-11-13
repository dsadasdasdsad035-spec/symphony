defmodule SymphonyElixir.HistoryBackfill do
  @moduledoc """
  从磁盘上的 agent transcript 重建仪表盘的 Recent sessions。

  背景：编排器的会话历史以前只存在内存里，重启就丢。现在虽然会落盘
  （见 `SymphonyElixir.SessionHistory`），但历史上丢失的那批仍然可以找回——
  Claude Code 的 transcript 一直保留在 `~/.claude/projects/<工作区>/<sid>.jsonl`，
  里面有完整的工具调用、时间戳和 token 用量。

  本模块扫描这些文件，重建出与实时记录同结构的条目并合并进历史文件。
  """

  require Logger

  alias SymphonyElixir.{SessionHistory, SessionTranscript}

  # 只认 Symphony 的工作区 transcript，避免把用户自己开的 Claude 会话算进来。
  @workspace_marker "symphony-workspaces"
  # 标识符形如 SF-78185 / MT-123 / MIJ-8。
  @identifier_pattern ~r/([A-Z][A-Z0-9]*-\d+)\s*$/
  # 工具名里出现这些词，说明这一步是在收尾（把任务标记为已解决/已完成）。
  @resolve_markers ["resolve", "complete", "close", "mark_done"]
  @trace_limit 40

  @doc """
  扫描并重建。

  选项：
    * `:dry_run` - 只返回结果不写盘
    * `:limit` - 最多处理多少个 transcript（按最近修改倒序，默认 50）
    * `:max_entries` - 最终保留多少条（默认 25）
  """
  @spec run(keyword()) :: {:ok, map()} | {:error, term()}
  def run(opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)
    max_entries = Keyword.get(opts, :max_entries, 25)
    dry_run? = Keyword.get(opts, :dry_run, false)

    {rebuilt, skipped} =
      claude_root()
      |> transcript_paths()
      |> Enum.take(limit)
      |> Enum.reduce({[], []}, fn path, {ok, skip} ->
        case rebuild_entry(path) do
          {:ok, entry} -> {[entry | ok], skip}
          {:skip, reason} -> {ok, [{path, reason} | skip]}
        end
      end)

    existing = SessionHistory.load(limit: max_entries)
    merged = merge(existing, rebuilt, max_entries)

    result = %{
      rebuilt_count: length(rebuilt),
      skipped_count: length(skipped),
      total_entries: length(merged),
      entries: merged,
      skipped: skipped,
      dry_run: dry_run?
    }

    if dry_run? do
      {:ok, result}
    else
      case SessionHistory.save(merged, limit: max_entries) do
        :ok -> {:ok, result}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp claude_root do
    case System.get_env("SYMPHONY_CLAUDE_PROJECTS_DIR") do
      value when is_binary(value) and value != "" -> Path.expand(value)
      _ -> Path.expand("~/.claude/projects")
    end
  end

  # 按文件修改时间倒序：优先重建最近的会话，快速看到效果。
  defp transcript_paths(root) do
    root
    |> Path.join("*/*.jsonl")
    |> Path.wildcard()
    |> Enum.map(fn path ->
      mtime =
        case File.stat(path, time: :posix) do
          {:ok, %{mtime: mtime}} -> mtime
          _ -> 0
        end

      {path, mtime}
    end)
    |> Enum.sort_by(&elem(&1, 1), :desc)
    |> Enum.map(&elem(&1, 0))
  end

  defp rebuild_entry(path) do
    session_id = Path.basename(path, ".jsonl")
    dir_hint = path |> Path.dirname() |> Path.basename()

    with true <- symphony_workspace?(dir_hint) || {:skip, :not_a_workspace},
         {:ok, transcript} <- SessionTranscript.load(session_id),
         # 加载后才能看到真实 cwd：临时目录里的工作区是测试残留，必须排除。
         true <- not temp_workspace?(transcript.cwd) || {:skip, :temp_workspace},
         true <- transcript.step_count > 0 || {:skip, :empty_transcript},
         true <- meaningful?(transcript) || {:skip, :trivial_session},
         identifier when is_binary(identifier) <- issue_identifier(transcript, dir_hint) do
      {:ok, to_entry(session_id, identifier, transcript)}
    else
      {:skip, reason} -> {:skip, reason}
      {:error, reason} -> {:skip, reason}
      nil -> {:skip, :no_issue_identifier}
    end
  end

  defp symphony_workspace?(dir_hint) do
    String.contains?(dir_hint, @workspace_marker) or
      Regex.match?(@identifier_pattern, dir_hint)
  end

  # 测试用例的工作区落在 /var/folders/... 或 /tmp/... 下，不应当出现在真实历史里。
  defp temp_workspace?(nil), do: false

  defp temp_workspace?(cwd) when is_binary(cwd) do
    String.starts_with?(cwd, "/private/var/folders/") or
      String.starts_with?(cwd, "/var/folders/") or
      String.starts_with?(cwd, Path.expand(System.tmp_dir!()))
  end

  defp temp_workspace?(_cwd), do: false

  # 几秒钟、几百 token 的会话没有观测价值（多为探活或参数校验失败）。
  defp meaningful?(transcript) do
    transcript.tool_call_count > 0 or transcript.total_tokens > 2_000
  end

  # 优先用 transcript 里的真实 cwd（更可信），退化到目录名解码。
  defp issue_identifier(transcript, dir_hint) do
    [transcript.cwd, dir_hint]
    |> Enum.reject(&is_nil/1)
    |> Enum.find_value(fn candidate ->
      case Regex.run(@identifier_pattern, String.trim(candidate)) do
        [_, identifier] -> identifier
        _ -> nil
      end
    end)
  end

  defp to_entry(session_id, identifier, transcript) do
    started_at = parse_datetime(transcript.started_at)
    finished_at = parse_datetime(transcript.finished_at)

    %{
      issue_id: identifier,
      identifier: identifier,
      issue_url: issue_url(identifier),
      state: nil,
      session_id: session_id,
      worker_host: nil,
      workspace_path: transcript.cwd,
      outcome: outcome(transcript),
      error: nil,
      started_at: started_at,
      finished_at: finished_at,
      runtime_seconds: runtime_seconds(started_at, finished_at),
      turn_count: transcript.prompt_count,
      codex_input_tokens: transcript.input_tokens,
      codex_output_tokens: transcript.output_tokens,
      codex_total_tokens: transcript.total_tokens,
      trace: trace(transcript)
    }
  end

  # 善治的 Bug 链接规则；其他来源只填标识符，链接留空避免给错地址。
  defp issue_url(identifier) do
    case Regex.run(~r/^SF-(\d+)$/, identifier) do
      [_, number] -> "http://sf.sieot.com/bug/#{number}"
      _ -> nil
    end
  end

  # 只看最后几步：真正收尾成功说明任务完成；以报错结束则标记为失败。
  defp outcome(transcript) do
    tail = Enum.take(transcript.steps, -8)

    resolved? =
      Enum.any?(tail, fn step ->
        step.kind == "tool_use" and is_binary(step.tool) and
          Enum.any?(@resolve_markers, &String.contains?(String.downcase(step.tool), &1))
      end)

    failed? = Enum.any?(tail, &(&1.status == "error"))

    cond do
      resolved? -> :completed
      failed? -> :failed
      true -> :completed
    end
  end

  defp runtime_seconds(%DateTime{} = started_at, %DateTime{} = finished_at) do
    max(DateTime.diff(finished_at, started_at), 0)
  end

  defp runtime_seconds(_started_at, _finished_at), do: 0

  defp trace(transcript) do
    transcript.steps
    |> Enum.filter(&(&1.kind in ["tool_use", "tool_result"]))
    |> Enum.take(-@trace_limit)
    |> Enum.map(fn step ->
      method = if step.kind == "tool_use", do: "item/started", else: "item/completed"

      status =
        case {step.kind, step.status} do
          {"tool_use", _} -> "in_progress"
          {_, "error"} -> "error"
          {_, other} -> other || "completed"
        end

      %{
        at: parse_datetime(step.at),
        event: method,
        message: %{
          event: :notification,
          message: %{
            "method" => method,
            "params" => %{
              "item" => %{
                "type" => "tool_call",
                "name" => step.tool || "tool",
                "status" => status,
                "detail" => summarize(step.text)
              }
            }
          }
        }
      }
    end)
  end

  defp summarize(nil), do: nil

  defp summarize(text) when is_binary(text) do
    case String.slice(text, 0, 140) |> String.trim() do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp summarize(_text), do: nil

  # 合并策略：同一个 session_id 以新重建的为准；其余保留，按结束时间倒序截断。
  defp merge(existing, rebuilt, max_entries) do
    rebuilt_ids = MapSet.new(rebuilt, & &1.session_id)

    (rebuilt ++ Enum.reject(existing, &MapSet.member?(rebuilt_ids, &1.session_id)))
    |> Enum.sort_by(&sort_key/1, {:desc, DateTime})
    |> Enum.take(max_entries)
  end

  defp sort_key(%{finished_at: %DateTime{} = finished_at}), do: finished_at
  defp sort_key(_entry), do: ~U[1970-01-01 00:00:00Z]

  defp parse_datetime(nil), do: nil

  defp parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      _ -> nil
    end
  end

  defp parse_datetime(%DateTime{} = value), do: value
  defp parse_datetime(_value), do: nil
end
