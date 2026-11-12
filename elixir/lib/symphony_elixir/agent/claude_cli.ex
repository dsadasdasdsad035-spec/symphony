defmodule SymphonyElixir.Agent.ClaudeCli do
  @moduledoc """
  `SymphonyElixir.Agent` 的 Claude Code CLI 实现。

  每个 turn 启动一次
  `claude -p --output-format stream-json --verbose --include-partial-messages`，
  读取它的 NDJSON 事件流，并把事件映射成 Codex 语义后通过 `on_message` 上报，
  这样看板、编排器与多轮续跑逻辑都无需改动。

  与其他两个后端相比，Claude Code 的 MCP 接线最干净：`--mcp-config` 接受
  内联 JSON 字符串，不需要往工作区或用户目录写任何配置文件。

  多轮对话复用同一个 session：`system/init` 事件里的 `session_id` 会被记住，
  后续 turn 通过 `--resume <session_id>` 续接。

  注意 `--output-format stream-json` 必须搭配 `--verbose`，否则 CLI 会直接报错退出。
  """

  @behaviour SymphonyElixir.Agent

  require Logger

  alias SymphonyElixir.{Config, PathSafety}

  @default_command "claude"
  @mcp_server_name "symphony"
  @line_bytes 1_048_576
  @plain_output_preview_bytes 400

  @type context :: %{
          on_message: (map() -> any()),
          state: :ets.tid(),
          metadata: map(),
          session_id: String.t() | nil,
          turn_id: non_neg_integer(),
          started?: boolean(),
          current_message_id: String.t() | nil,
          streamed_messages: MapSet.t(String.t()),
          emitted_tools: MapSet.t(String.t()),
          tool_names: %{optional(String.t()) => String.t()},
          last_plain: String.t()
        }

  @impl true
  @spec start_session(Path.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def start_session(workspace, opts \\ []) do
    case Keyword.get(opts, :worker_host) do
      host when is_binary(host) ->
        {:error, {:claude_cli_remote_worker_unsupported, host}}

      _ ->
        with {:ok, expanded_workspace} <- validate_workspace_cwd(workspace) do
          state = :ets.new(__MODULE__, [:set])
          :ets.insert(state, {:session_id, nil})
          :ets.insert(state, {:turn_count, 0})

          {:ok,
           %{
             workspace: expanded_workspace,
             worker_host: nil,
             command: claude_command(),
             model: claude_model(),
             mcp_url: mcp_endpoint_url(),
             secret_environment_names: secret_environment_names(),
             state: state
           }}
        end
    end
  end

  @impl true
  @spec run_turn(map(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def run_turn(session, prompt, issue, opts \\ []) do
    %{
      workspace: workspace,
      command: command,
      state: state,
      model: model,
      mcp_url: mcp_url,
      secret_environment_names: secret_names
    } = session

    on_message = Keyword.get(opts, :on_message, &default_on_message/1)
    session_id = fetch_state(state, :session_id)
    turn_id = bump_turn_count(state)

    context = %{
      on_message: on_message,
      state: state,
      metadata: %{},
      session_id: session_id,
      turn_id: turn_id,
      started?: false,
      current_message_id: nil,
      streamed_messages: MapSet.new(),
      emitted_tools: MapSet.new(),
      tool_names: %{},
      last_plain: ""
    }

    launch = build_launch_command(command, session_id, prompt, secret_names, model, mcp_url)

    case start_port(workspace, launch, context.metadata, secret_names) do
      {:ok, port, metadata} ->
        result =
          try do
            receive_loop(port, %{context | metadata: metadata}, "", timeout_ms())
          after
            close_port(port)
          end

        # 子进程非正常退出（额度耗尽、崩溃、认证失效）时必须发事件，
        # 否则看板上只显示 running，排障时看不到任何线索。
        case result do
          {:ok, _turn} = ok ->
            ok

          {:error, {:port_exit, status, output}} ->
            emit(
              on_message,
              :turn_ended_with_error,
              %{reason: {:port_exit, status}, output: output},
              Map.put(metadata, :session_id, context.session_id)
            )

            {:error, {:port_exit, status, output}}

          {:error, reason} = error ->
            emit(on_message, :turn_ended_with_error, %{reason: reason}, metadata)
            error
        end

      {:error, reason} ->
        Logger.error("启动 claude 失败: #{inspect(reason)} issue=#{issue_identifier(issue)}")
        emit(on_message, :startup_failed, %{reason: reason}, context.metadata)
        {:error, reason}
    end
  end

  @impl true
  @spec stop_session(map()) :: :ok
  def stop_session(%{state: state}) when is_reference(state) do
    if :ets.info(state) != :undefined, do: :ets.delete(state)
    :ok
  rescue
    ArgumentError -> :ok
  end

  def stop_session(_session), do: :ok

  # ---------------------------------------------------------------- 进程与事件流

  defp receive_loop(port, context, pending, timeout) do
    receive do
      {^port, {:data, {:eol, chunk}}} ->
        handle_line(port, context, pending <> to_string(chunk))

      {^port, {:data, {:noeol, chunk}}} ->
        receive_loop(port, context, pending <> to_string(chunk), timeout)

      {^port, {:exit_status, status}} ->
        {:error, {:port_exit, status, context.last_plain}}
    after
      timeout ->
        {:error, :turn_timeout}
    end
  end

  defp handle_line(port, context, line) do
    case Jason.decode(line) do
      {:ok, %{"type" => "result"} = payload} ->
        finish_turn(context, payload, line)

      {:ok, %{"type" => "error"} = payload} ->
        fail_turn(context, payload, line)

      {:ok, %{"type" => type} = payload} when is_binary(type) ->
        context = handle_event(context, type, payload, line)
        receive_loop(port, context, "", timeout_ms())

      {:ok, payload} ->
        emit(context.on_message, :other_message, %{payload: payload, raw: line}, context.metadata)
        receive_loop(port, context, "", timeout_ms())

      {:error, _reason} ->
        log_plain_output(line)
        receive_loop(port, %{context | last_plain: String.slice(line, 0, @plain_output_preview_bytes)}, "", timeout_ms())
    end
  end

  # system/init 是唯一带 session_id 且只在开头出现一次的事件
  defp handle_event(context, "system", %{"subtype" => "init"} = payload, _line) do
    session_id = payload["session_id"] || context.session_id
    remember_session_id(context.state, session_id)

    emit(
      context.on_message,
      :session_started,
      %{
        session_id: session_id,
        thread_id: session_id,
        turn_id: context.turn_id,
        model: payload["model"]
      },
      context.metadata
    )

    %{context | session_id: session_id, started?: true}
  end

  # 细粒度流式增量（--include-partial-messages 才会出现）
  defp handle_event(context, "stream_event", %{"event" => %{} = event}, _line) do
    case event["type"] do
      "message_start" ->
        %{context | current_message_id: get_in(event, ["message", "id"])}

      "content_block_delta" ->
        context = remember_message(context)
        handle_delta(context, event["delta"])

      _ ->
        context
    end
  end

  # assistant 事件是「同一条消息」的渐进更新：文本已经在 stream_event 里发过，
  # 这里只处理 tool_use，且按 tool id 去重，避免重复上报。
  defp handle_event(context, "assistant", %{"message" => %{} = message}, _line) do
    message_id = message["id"]
    streamed? = is_binary(message_id) and MapSet.member?(context.streamed_messages, message_id)

    Enum.reduce(message["content"] || [], context, fn
      %{"type" => "tool_use", "id" => id, "name" => name}, acc when is_binary(id) and is_binary(name) ->
        acc = %{acc | tool_names: Map.put(acc.tool_names, id, name)}

        if MapSet.member?(acc.emitted_tools, id) do
          acc
        else
          notify(acc, "item/started", %{
            "item" => %{"type" => "tool_call", "id" => id, "name" => name, "status" => "in_progress"}
          })

          %{acc | emitted_tools: MapSet.put(acc.emitted_tools, id)}
        end

      # 没有收到过流式增量的消息，退回用整块文本，保证内容不丢
      %{"type" => "text", "text" => text}, acc when not streamed? and is_binary(text) and text != "" ->
        notify(acc, "item/agentMessage/delta", %{"delta" => text})

      _other, acc ->
        acc
    end)
  end

  # tool_result 回传在 user 事件里
  defp handle_event(context, "user", %{"message" => %{"content" => content}}, _line)
       when is_list(content) do
    Enum.reduce(content, context, fn
      %{"type" => "tool_result", "tool_use_id" => id} = result, acc when is_binary(id) ->
        status = if result["is_error"] == true, do: "failed", else: "completed"
        name = Map.get(acc.tool_names, id, "tool")

        notify(acc, "item/completed", %{
          "item" => %{"type" => "tool_call", "id" => id, "name" => name, "status" => status}
        })

        acc

      _other, acc ->
        acc
    end)
  end

  defp handle_event(context, _type, _payload, _line), do: context

  defp handle_delta(context, %{"type" => "text_delta", "text" => text}) when is_binary(text) and text != "" do
    notify(context, "item/agentMessage/delta", %{"delta" => text})
  end

  defp handle_delta(context, %{"type" => "thinking_delta", "thinking" => text}) when is_binary(text) and text != "" do
    notify(context, "item/reasoning/textDelta", %{"delta" => text})
  end

  defp handle_delta(context, _delta), do: context

  defp remember_message(%{current_message_id: nil} = context), do: context

  defp remember_message(%{current_message_id: id} = context) when is_binary(id) do
    %{context | streamed_messages: MapSet.put(context.streamed_messages, id)}
  end

  defp finish_turn(context, payload, line) do
    session_id = payload["session_id"] || context.session_id
    remember_session_id(context.state, session_id)

    result = to_text(payload["result"])
    usage = usage_map(payload["usage"])
    metadata = put_usage(context.metadata, usage) |> Map.put(:session_id, session_id)

    failed? = payload["is_error"] == true or failure_subtype?(payload["subtype"])

    if failed? do
      emit(
        context.on_message,
        :turn_failed,
        %{payload: %{"method" => "turn/failed", "params" => %{"usage" => usage}}, raw: line, details: payload},
        metadata
      )

      {:error, {:turn_failed, result}}
    else
      params =
        %{"usage" => usage}
        |> maybe_put("numTurns", payload["num_turns"])
        |> maybe_put("totalCostUsd", payload["total_cost_usd"])

      emit(
        context.on_message,
        :turn_completed,
        %{payload: %{"method" => "turn/completed", "params" => params}, raw: line, details: payload},
        metadata
      )

      {:ok,
       %{
         result: result,
         session_id: session_id,
         thread_id: session_id,
         turn_id: context.turn_id
       }}
    end
  end

  defp fail_turn(context, payload, line) do
    message = payload["message"] || payload["error"] || payload

    emit(
      context.on_message,
      :turn_failed,
      %{payload: %{"method" => "turn/failed", "params" => payload}, raw: line, details: payload},
      context.metadata
    )

    {:error, {:turn_failed, message}}
  end

  # Claude Code 用 success / error_max_turns / error_during_execution 这类 subtype
  defp failure_subtype?(subtype) when is_binary(subtype) do
    String.starts_with?(subtype, "error")
  end

  defp failure_subtype?(_subtype), do: false

  # ---------------------------------------------------------------- 进程管理

  defp start_port(workspace, launch_command, metadata, secret_names) do
    case System.find_executable("bash") do
      nil ->
        {:error, :bash_not_found}

      executable ->
        port =
          Port.open(
            {:spawn_executable, String.to_charlist(executable)},
            [
              :binary,
              :exit_status,
              :stderr_to_stdout,
              args: [~c"-lc", String.to_charlist(launch_command)],
              cd: String.to_charlist(workspace),
              env: secret_env(secret_names),
              line: @line_bytes
            ]
          )

        {:ok, port, Map.merge(metadata, port_metadata(port))}
    end
  rescue
    error -> {:error, {:port_open_failed, error}}
  end

  # 和 Codex 后端一致：tracker 密钥不传给 agent 子进程。
  defp secret_env(names) do
    names
    |> valid_env_names()
    |> Enum.map(fn name -> {String.to_charlist(name), false} end)
  end

  defp unset_prefix(names) do
    case names |> valid_env_names() do
      [] -> nil
      valid -> "unset " <> Enum.join(valid, " ")
    end
  end

  defp valid_env_names(names) do
    Enum.filter(names, fn name ->
      is_binary(name) and String.match?(name, ~r/^[A-Za-z_][A-Za-z0-9_]*$/)
    end)
  end

  defp secret_environment_names do
    SymphonyElixir.Tracker.bind_agent_tools().secret_environment_names
  rescue
    _ -> []
  end

  defp port_metadata(port) do
    case :erlang.port_info(port, :os_pid) do
      {:os_pid, os_pid} -> %{codex_app_server_pid: to_string(os_pid)}
      _ -> %{}
    end
  end

  defp close_port(port) do
    case :erlang.port_info(port) do
      :undefined ->
        :ok

      _ ->
        Port.close(port)
        :ok
    end
  rescue
    ArgumentError -> :ok
  end

  # ---------------------------------------------------------------- 命令构造

  defp build_launch_command(command, session_id, prompt, secret_names, model, mcp_url) do
    base = [
      command,
      "-p",
      shell_escape(prompt),
      "--output-format",
      "stream-json",
      # stream-json 必须配 --verbose，否则 CLI 直接报错退出
      "--verbose",
      # 让文本以 content_block_delta 形式流式输出，而不是等整块
      "--include-partial-messages",
      # 无头模式不能交互审批，必须整体放行
      "--dangerously-skip-permissions"
    ]

    model_args =
      case model do
        value when is_binary(value) ->
          case String.trim(value) do
            "" -> []
            trimmed -> ["--model", shell_escape(trimmed)]
          end

        _ ->
          []
      end

    mcp_args =
      case mcp_config_json(mcp_url) do
        nil -> []
        # `--strict-mcp-config` 让 CLI 只认本次注入的 MCP，忽略用户级
        # ~/.claude 里配置的其它 MCP（如 pencil、codegraph）。否则这些无关
        # 服务会一并连上，既拖慢启动，也把无关工具塞进模型的工具列表。
        json -> ["--mcp-config", shell_escape(json), "--strict-mcp-config"]
      end

    resume =
      if is_binary(session_id) and String.trim(session_id) != "" do
        ["--resume", shell_escape(session_id)]
      else
        []
      end

    [unset_prefix(secret_names), claude_command_line(base ++ model_args ++ mcp_args ++ resume)]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" && ")
  end

  # 末尾的 `< /dev/null` 不是可有可无的：Elixir Port 给子进程挂的 stdin 是
  # 一条永远不写、也不关闭的管道，Claude Code 会一直等 stdin 就绪，
  # 连“3 秒无输入就继续”的告警都发不出来，表现为启动即静默卡死
  # （进程空闲、无任何 TCP 连接）。显式接 /dev/null 之后立刻恢复正常。
  # 本适配器从不向 stdin 写数据，因此重定向不会影响任何交互。
  #
  # 这里刻意不用 `--bare` / `CLAUDE_CODE_SIMPLE=1`：它们会把内置工具裁到
  # 只剩 Bash/Edit/Read，连 `Write` 都没有，编码任务直接不可用。
  defp claude_command_line(argv) do
    Enum.join(argv, " ") <> " < /dev/null"
  end

  # --mcp-config 支持内联 JSON，因此不需要写任何文件
  defp mcp_config_json(nil), do: nil

  defp mcp_config_json(url) do
    Jason.encode!(%{
      "mcpServers" => %{
        @mcp_server_name => %{"type" => "http", "url" => url}
      }
    })
  end

  defp claude_model do
    case Config.settings!().agent.claude_model do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> nil
          trimmed -> trimmed
        end

      _ ->
        nil
    end
  rescue
    _ -> nil
  end

  defp claude_command do
    case Config.settings!().agent.claude_command do
      command when is_binary(command) ->
        case String.trim(command) do
          "" -> @default_command
          trimmed -> trimmed
        end

      _ ->
        @default_command
    end
  rescue
    _ -> @default_command
  end

  defp mcp_endpoint_url do
    port =
      case configured_port() do
        configured when is_integer(configured) and configured > 0 -> configured
        # 配成 0 表示随机端口，只能问已启动的端点要实际端口
        0 -> SymphonyElixir.HttpServer.bound_port()
        _ -> nil
      end

    if is_integer(port) and port > 0 do
      "http://127.0.0.1:#{port}/mcp"
    end
  rescue
    _ -> nil
  end

  defp configured_port do
    Config.server_port()
  rescue
    _ -> nil
  end

  defp shell_escape(value) when is_binary(value) do
    "'" <> String.replace(value, "'", "'\\''") <> "'"
  end

  # ---------------------------------------------------------------- 工作区校验

  defp validate_workspace_cwd(workspace) when is_binary(workspace) do
    expanded_workspace = Path.expand(workspace)
    expanded_root = Config.local_workspace_root()
    expanded_root_prefix = expanded_root <> "/"

    with {:ok, canonical_workspace} <- PathSafety.canonicalize(expanded_workspace),
         {:ok, canonical_root} <- PathSafety.canonicalize(expanded_root) do
      canonical_root_prefix = canonical_root <> "/"

      cond do
        canonical_workspace == canonical_root ->
          {:error, {:invalid_workspace_cwd, :workspace_root, canonical_workspace}}

        String.starts_with?(canonical_workspace <> "/", canonical_root_prefix) ->
          {:ok, canonical_workspace}

        String.starts_with?(expanded_workspace <> "/", expanded_root_prefix) ->
          {:error, {:invalid_workspace_cwd, :symlink_escape, expanded_workspace, canonical_root}}

        true ->
          {:error, {:invalid_workspace_cwd, :outside_workspace_root, canonical_workspace, canonical_root}}
      end
    else
      {:error, {:path_canonicalize_failed, path, reason}} ->
        {:error, {:invalid_workspace_cwd, :path_unreadable, path, reason}}
    end
  end

  # ---------------------------------------------------------------- 会话状态

  defp fetch_state(state, key) do
    case :ets.lookup(state, key) do
      [{^key, value}] -> value
      _ -> nil
    end
  rescue
    ArgumentError -> nil
  end

  defp remember_session_id(_state, nil), do: :ok

  defp remember_session_id(state, session_id) when is_binary(session_id) do
    :ets.insert(state, {:session_id, session_id})
    :ok
  rescue
    ArgumentError -> :ok
  end

  defp bump_turn_count(state) do
    next = (fetch_state(state, :turn_count) || 0) + 1
    :ets.insert(state, {:turn_count, next})
    next
  rescue
    ArgumentError -> 1
  end

  # ---------------------------------------------------------------- 输出解析

  defp usage_map(%{} = usage) do
    input = integer_value(usage["input_tokens"]) || 0
    output = integer_value(usage["output_tokens"]) || 0
    cache_read = integer_value(usage["cache_read_input_tokens"]) || 0
    cache_write = integer_value(usage["cache_creation_input_tokens"]) || 0

    %{
      "inputTokens" => input,
      "outputTokens" => output,
      "totalTokens" => input + output,
      "cachedInputTokens" => cache_read,
      "cacheCreationInputTokens" => cache_write
    }
  end

  defp usage_map(_usage), do: nil

  defp put_usage(metadata, nil), do: metadata

  defp put_usage(metadata, usage) do
    Map.put(metadata, :usage, %{"tokenUsage" => %{"total" => usage}})
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp integer_value(value) when is_integer(value), do: value
  defp integer_value(_value), do: nil

  defp to_text(value) when is_binary(value), do: value
  defp to_text(nil), do: ""
  defp to_text(value), do: inspect(value)

  defp timeout_ms do
    Config.settings!().codex.turn_timeout_ms
  rescue
    _ -> 300_000
  end

  # ---------------------------------------------------------------- 事件上报

  defp notify(context, method, params) do
    emit(
      context.on_message,
      :notification,
      %{payload: %{"method" => method, "params" => params}},
      context.metadata
    )

    # 回调的返回值不可信（例如测试里用 send/2），必须显式返回 context
    context
  end

  defp emit(on_message, event, details, metadata) when is_function(on_message, 1) do
    message =
      metadata
      |> Map.merge(details)
      |> Map.put(:event, event)
      |> Map.put(:timestamp, DateTime.utc_now())

    on_message.(message)
  end

  defp default_on_message(message) do
    Logger.debug("claude-cli 上报: #{inspect(message[:event])}")
    :ok
  end

  defp log_plain_output(line) do
    trimmed = String.trim(line)

    if trimmed != "" do
      Logger.debug("claude-cli 非 JSON 输出: #{String.slice(trimmed, 0, @plain_output_preview_bytes)}")
    end
  end

  defp issue_identifier(%{identifier: identifier}) when is_binary(identifier), do: identifier
  defp issue_identifier(_issue), do: "unknown"
end
