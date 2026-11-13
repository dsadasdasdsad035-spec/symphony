defmodule SymphonyElixir.SessionTranscript do
  @moduledoc """
  按 Session ID 定位并解析 agent 的完整执行轨迹（transcript）。

  Claude Code 会把会话的完整事件流逐行写成 JSONL：

      ~/.claude/projects/<工作区编码>/<session_id>.jsonl

  文件名就是 `session_id`，所以只要拿到仪表盘上的 Session ID 就能反查出
  agent 每一步的思考、工具调用与工具输出。工作区目录名是把绝对路径里的
  非字母数字字符替换成 `-` 得到的（例如 `/private/tmp/cc-final` →
  `-private-tmp-cc-final`），但这种编码不可逆（`/` 和 `-` 都会变成 `-`），
  因此这里直接按文件名全局匹配，避免猜测规则出错。
  """

  @session_id_pattern ~r/\A[A-Za-z0-9_-]{1,128}\z/
  # 单条文本（尤其是工具输出）可能几十 KB，截断后再放进页面，避免渲染卡死。
  @text_limit 1_500
  # 一次最多返回的步骤数，取最新的这些；更早的折叠成一条提示。
  @default_max_steps 400
  @claude_root "~/.claude/projects"

  @typedoc "一条可展示的执行步骤"
  @type step :: %{
          index: non_neg_integer(),
          at: String.t() | nil,
          role: String.t(),
          kind: String.t(),
          tool: String.t() | nil,
          status: String.t() | nil,
          text: String.t() | nil,
          truncated: boolean()
        }

  @doc """
  定位 transcript 文件。

  返回 `{:ok, path}` 或 `{:error, :not_found}` / `{:error, :invalid_session_id}`。
  """
  @spec locate(String.t(), keyword()) :: {:ok, Path.t()} | {:error, :not_found | :invalid_session_id}
  def locate(session_id, opts \\ [])

  def locate(session_id, _opts) when is_binary(session_id) do
    if Regex.match?(@session_id_pattern, session_id) do
      case candidates(session_id) do
        [] -> {:error, :not_found}
        [path | _] -> {:ok, path}
      end
    else
      {:error, :invalid_session_id}
    end
  end

  def locate(_session_id, _opts), do: {:error, :invalid_session_id}

  @doc """
  读取并解析某个会话的执行轨迹。

  选项：

    * `:max_steps` - 最多返回多少步（默认 #{@default_max_steps}，取最新的）
  """
  @spec load(String.t(), keyword()) ::
          {:ok, map()} | {:error, :not_found | :invalid_session_id | :unreadable}
  def load(session_id, opts \\ []) do
    with {:ok, path} <- locate(session_id, opts) do
      try do
        {steps, stats} =
          path
          |> File.stream!([], :line)
          |> Stream.map(&String.trim_trailing(&1, "\n"))
          |> Stream.reject(&(&1 == ""))
          |> Enum.reduce({[], initial_state()}, &accumulate/2)
          |> then(fn {reversed, state} -> {Enum.reverse(reversed), state} end)

        max_steps = Keyword.get(opts, :max_steps, @default_max_steps)
        total = length(steps)
        visible = if total > max_steps, do: Enum.take(steps, -max_steps), else: steps

        {:ok,
         %{
           session_id: session_id,
           path: path,
           steps: visible,
           step_count: total,
           dropped_count: total - length(visible),
           tool_call_count: stats.tool_call_count,
           error_count: stats.error_count,
           started_at: stats.started_at,
           finished_at: stats.finished_at,
           cwd: stats.cwd,
           model: stats.model,
           # 会话级用量：同一个 assistant message 会按内容块拆成多行，
           # 因此 usage 必须按 message.id 去重后再累加。
           input_tokens: stats.input_tokens,
           output_tokens: stats.output_tokens,
           total_tokens: stats.input_tokens + stats.output_tokens,
           # 真实用户输入次数（不含 tool_result），近似 agent 的回合数。
           prompt_count: stats.prompt_count
         }}
      rescue
        _ -> {:error, :unreadable}
      end
    end
  end

  defp candidates(session_id) do
    [claude_root(), env_claude_root()]
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.flat_map(&Path.wildcard(Path.join(&1, "*/#{session_id}.jsonl")))
    |> Enum.uniq()
    |> Enum.sort_by(&mtime/1, :desc)
  end

  defp claude_root, do: Path.expand(@claude_root)

  # 允许测试或非默认布局覆盖根目录。
  defp env_claude_root do
    case System.get_env("SYMPHONY_CLAUDE_PROJECTS_DIR") do
      root when is_binary(root) and root != "" -> Path.expand(root)
      _ -> nil
    end
  end

  defp mtime(path) do
    case File.stat(path, time: :posix) do
      {:ok, %{mtime: mtime}} -> mtime
      _ -> 0
    end
  end

  defp initial_state do
    %{
      tool_names: %{},
      tool_call_count: 0,
      error_count: 0,
      index: 0,
      started_at: nil,
      finished_at: nil,
      cwd: nil,
      model: nil,
      # 已计入的 assistant message id，用于 usage 去重。
      counted_messages: MapSet.new(),
      input_tokens: 0,
      output_tokens: 0,
      prompt_count: 0
    }
  end

  # 逐行累积：只认 user / assistant 两类记录，其余（api-request、attachment 等）
  # 属于客户端内部埋点，对"执行过程"没有价值。
  defp accumulate(line, {steps, state}) do
    case Jason.decode(line) do
      {:ok, %{"type" => type} = record} when type in ["user", "assistant"] ->
        {new_steps, state} = record_steps(record, state)
        # record_steps 返回的已是「新→旧」，直接接到累积器头部即可。
        {new_steps ++ steps, state}

      _ ->
        {steps, state}
    end
  end

  defp record_steps(%{"type" => "user", "message" => %{"content" => content}} = record, state) do
    case content do
      text when is_binary(text) ->
        {step, state} = build_step(record, state, "user", "prompt", nil, nil, text)
        {[step], count_prompt(state)}

      blocks when is_list(blocks) ->
        Enum.reduce(blocks, {[], state}, fn block, {acc, state} ->
          case block do
            %{"type" => "tool_result"} = result ->
              tool_use_id = result["tool_use_id"]
              tool = Map.get(state.tool_names, tool_use_id)
              error? = result["is_error"] == true
              status = if error?, do: "error", else: "ok"

              {step, state} =
                build_step(record, state, "user", "tool_result", tool, status, extract_content(result["content"]))

              state = if error?, do: Map.update!(state, :error_count, &(&1 + 1)), else: state
              {[step | acc], state}

            %{"type" => "text", "text" => text} when is_binary(text) and text != "" ->
              {step, state} = build_step(record, state, "user", "prompt", nil, nil, text)
              {[step | acc], count_prompt(state)}

            _ ->
              {acc, state}
          end
        end)

      _ ->
        {[], state}
    end
  end

  defp record_steps(%{"type" => "assistant", "message" => %{"content" => blocks}} = record, state)
       when is_list(blocks) do
    # usage 挂在 message 上，同一 message 的多个内容块会重复出现，先按 id 计一次。
    state = accumulate_usage(state, record)

    Enum.reduce(blocks, {[], state}, fn block, {acc, state} ->
      case block do
        %{"type" => "thinking", "thinking" => text} when is_binary(text) and text != "" ->
          {step, state} = build_step(record, state, "assistant", "thinking", nil, nil, text)
          {[step | acc], state}

        %{"type" => "text", "text" => text} when is_binary(text) and text != "" ->
          {step, state} = build_step(record, state, "assistant", "text", nil, nil, text)
          {[step | acc], state}

        %{"type" => "tool_use", "id" => id, "name" => name} = tool_use ->
          state = %{
            state
            | tool_names: Map.put(state.tool_names, id, name),
              tool_call_count: state.tool_call_count + 1
          }

          {step, state} =
            build_step(record, state, "assistant", "tool_use", name, "started", tool_input_summary(tool_use["input"]))

          {[step | acc], state}

        _ ->
          {acc, state}
      end
    end)
  end

  defp record_steps(_record, state), do: {[], state}

  defp count_prompt(state), do: Map.update!(state, :prompt_count, &(&1 + 1))

  # 同一 message 的 usage 只计一次：内容块被拆成多行时 usage 是重复的。
  defp accumulate_usage(state, %{"message" => message}) when is_map(message) do
    usage = message["usage"]
    message_id = message["id"]

    cond do
      not is_map(usage) ->
        state

      is_binary(message_id) and MapSet.member?(state.counted_messages, message_id) ->
        state

      true ->
        %{
          state
          | counted_messages:
              if(is_binary(message_id),
                do: MapSet.put(state.counted_messages, message_id),
                else: state.counted_messages
              ),
            input_tokens: state.input_tokens + int(usage["input_tokens"]),
            output_tokens: state.output_tokens + int(usage["output_tokens"])
        }
    end
  end

  defp accumulate_usage(state, _record), do: state

  defp int(value) when is_integer(value), do: value
  defp int(_value), do: 0

  # 返回 {步骤, 新状态}：步骤序号和会话级元信息（首末时间、cwd、模型）都要靠状态累积。
  defp build_step(record, state, role, kind, tool, status, raw_text) do
    state = advance_meta(record, state)
    {text, truncated} = truncate(raw_text)

    step = %{
      index: state.index - 1,
      at: record && record["timestamp"],
      role: role,
      kind: kind,
      tool: tool,
      status: status,
      text: text,
      truncated: truncated
    }

    {step, state}
  end

  defp advance_meta(record, state) do
    index = state.index + 1
    timestamp = record && record["timestamp"]
    cwd = (record && record["cwd"]) || state.cwd
    model = get_in(record || %{}, ["message", "model"]) || state.model

    %{
      state
      | index: index,
        started_at: state.started_at || timestamp,
        finished_at: timestamp || state.finished_at,
        cwd: cwd,
        model: if(is_binary(model), do: model, else: state.model)
    }
  end

  defp truncate(nil), do: {nil, false}

  defp truncate(text) when is_binary(text) do
    if String.length(text) > @text_limit do
      {String.slice(text, 0, @text_limit), true}
    else
      {text, false}
    end
  end

  # 兜底：万一结构里混进非字符串，转成文本而不是崩掉整个页面。
  defp truncate(other), do: truncate(to_string(other))

  defp extract_content(content) when is_binary(content), do: content

  defp extract_content(content) when is_list(content) do
    content
    |> Enum.map(fn
      %{"type" => "text", "text" => text} when is_binary(text) -> text
      %{"type" => "tool_reference", "tool_name" => name} -> "[tool] #{name}"
      %{"type" => type} when is_binary(type) -> "[#{type}]"
      other when is_binary(other) -> other
      _ -> ""
    end)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
  end

  defp extract_content(_content), do: nil

  # 工具入参压成单行摘要：命令、路径、查询词这些才是人关心的部分。
  @summary_keys ["command", "file_path", "path", "pattern", "query", "url", "description", "prompt"]
  @summary_limit 240

  defp tool_input_summary(input) when is_map(input) do
    detail =
      Enum.find_value(@summary_keys, fn key ->
        case Map.get(input, key) do
          value when is_binary(value) ->
            trimmed = value |> String.replace(~r/\s+/, " ") |> String.trim()
            if trimmed == "", do: nil, else: trimmed

          _ ->
            nil
        end
      end)

    case detail do
      nil -> Jason.encode!(input)
      detail -> String.slice(detail, 0, @summary_limit)
    end
  end

  defp tool_input_summary(_input), do: nil
end
