defmodule SymphonyElixir.Agent.CursorCli do
  @moduledoc """
  `SymphonyElixir.Agent` 的 Cursor CLI 实现。

  每个 turn 启动一次
  `cursor-agent -p --output-format stream-json --force --trust`，
  读取它的 NDJSON 事件流，并把事件映射成 Codex 语义后通过 `on_message` 上报，
  这样看板、编排器与多轮续跑逻辑都无需改动。

  多轮对话复用同一个 chat：首个 `system/init` 事件里的 `session_id` 会被记住，
  后续 turn 通过 `--resume <session_id>` 续接，避免每轮从零开始。

  会话状态（chat id、turn 计数）存放在一张私有 ETS 表里，因为
  `SymphonyElixir.AgentRunner` 在多轮之间传的是同一个不可变 session 结构。
  """

  @behaviour SymphonyElixir.Agent

  require Logger

  alias SymphonyElixir.{Config, PathSafety}

  @default_command "cursor-agent"
  @mcp_server_name "symphony"
  @line_bytes 1_048_576
  @plain_output_preview_bytes 400

  @type context :: %{
          on_message: (map() -> any()),
          state: :ets.tid(),
          metadata: map(),
          session_id: String.t() | nil,
          turn_id: non_neg_integer(),
          last_plain: String.t()
        }

  @impl true
  @spec start_session(Path.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def start_session(workspace, opts \\ []) do
    case Keyword.get(opts, :worker_host) do
      host when is_binary(host) ->
        {:error, {:cursor_cli_remote_worker_unsupported, host}}

      _ ->
        with {:ok, expanded_workspace} <- validate_workspace_cwd(workspace) do
          state = :ets.new(__MODULE__, [:set])
          :ets.insert(state, {:chat_id, nil})
          :ets.insert(state, {:turn_count, 0})
          mcp_url = ensure_mcp_config(expanded_workspace)

          {:ok,
           %{
             workspace: expanded_workspace,
             worker_host: nil,
             command: cursor_command(),
             model: cursor_model(),
             mcp_url: mcp_url,
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
      secret_environment_names: secret_names
    } = session

    on_message = Keyword.get(opts, :on_message, &default_on_message/1)
    session_id = fetch_state(state, :chat_id)
    turn_id = bump_turn_count(state)

    context = %{
      on_message: on_message,
      state: state,
      metadata: %{},
      session_id: session_id,
      turn_id: turn_id,
      last_plain: ""
    }

    launch = build_launch_command(command, session_id, prompt, secret_names, model)

    case start_port(workspace, launch, context.metadata, secret_names) do
      {:ok, port, metadata} ->
        result =
          try do
            receive_loop(port, %{context | metadata: metadata}, "", timeout_ms())
          after
            close_port(port)
          end

        # 子进程非正常退出（额度耗尽、崩溃、认证失效）时必须发事件，
        # 否则看板上只显示"running"，排障时看不到任何线索。
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
        Logger.error("启动 cursor-agent 失败: #{inspect(reason)} issue=#{issue_identifier(issue)}")
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
        receive_loop(port, handle_event(context, type, payload, line), "", timeout_ms())

      {:ok, payload} ->
        emit(context.on_message, :other_message, %{payload: payload, raw: line}, context.metadata)
        receive_loop(port, context, "", timeout_ms())

      {:error, _reason} ->
        log_plain_output(line)
        receive_loop(port, %{context | last_plain: String.slice(line, 0, @plain_output_preview_bytes)}, "", timeout_ms())
    end
  end

  defp handle_event(context, "system", %{"subtype" => "init"} = payload, _line) do
    session_id = payload["session_id"] || context.session_id
    remember_chat_id(context.state, session_id)

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

    %{context | session_id: session_id}
  end

  defp handle_event(context, "assistant", payload, _line) do
    case assistant_text(payload) do
      nil ->
        context

      text ->
        notify(context, "item/agentMessage/delta", %{"delta" => text})
        context
    end
  end

  defp handle_event(context, "thinking", %{"subtype" => "delta", "text" => text}, _line)
       when is_binary(text) do
    notify(context, "item/reasoning/textDelta", %{"delta" => text})
    context
  end

  defp handle_event(context, "tool_call", %{"subtype" => "started"} = payload, _line) do
    notify(context, "item/started", %{"item" => tool_item(payload)})
    context
  end

  defp handle_event(context, "tool_call", %{"subtype" => "completed"} = payload, _line) do
    notify(context, "item/completed", %{"item" => tool_item(payload)})
    context
  end

  defp handle_event(context, "user", _payload, _line), do: context

  defp handle_event(context, type, payload, line) do
    Logger.debug("cursor-cli 事件: #{type}")
    emit(context.on_message, :notification, %{payload: payload, raw: line}, context.metadata)
    context
  end

  defp finish_turn(context, payload, line) do
    session_id = payload["session_id"] || context.session_id
    remember_chat_id(context.state, session_id)

    result = to_text(payload["result"])
    usage = usage_map(payload["usage"])
    metadata = put_usage(context.metadata, usage)

    if payload["is_error"] == true do
      emit(
        context.on_message,
        :turn_failed,
        %{payload: %{"method" => "turn/failed", "params" => %{"usage" => usage}}, raw: line, details: payload},
        metadata
      )

      {:error, {:turn_failed, result}}
    else
      emit(
        context.on_message,
        :turn_completed,
        %{payload: %{"method" => "turn/completed", "params" => %{"usage" => usage}}, raw: line, details: payload},
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
    span = payload["message"] || payload["error"] || payload

    emit(
      context.on_message,
      :turn_failed,
      %{payload: %{"method" => "turn/failed", "params" => payload}, raw: line, details: payload},
      context.metadata
    )

    {:error, {:turn_failed, span}}
  end

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
  # 工具调用统一走 Symphony 自己的 MCP 端点，agent 不需要、也拿不到 token。
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

  defp build_launch_command(command, session_id, prompt, secret_names, model) do
    base = [
      command,
      "-p",
      "--output-format",
      "stream-json",
      "--force",
      "--trust",
      # 自动批准 .cursor/mcp.json 里注册的 Symphony MCP server，否则每轮都会卡在审批
      "--approve-mcps"
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

    resume =
      if is_binary(session_id) and String.trim(session_id) != "" do
        ["--resume", shell_escape(session_id)]
      else
        []
      end

    [unset_prefix(secret_names), Enum.join(base ++ model_args ++ resume ++ [shell_escape(prompt)], " ")]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" && ")
  end

  defp cursor_model do
    case Config.settings!().agent.cursor_model do
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

  defp cursor_command do
    case Config.settings!().agent.cursor_command do
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

  # ---------------------------------------------------------------- MCP 接线

  # 把 Symphony 的 MCP 端点（/mcp）写进工作区的 .cursor/mcp.json，
  # 让 cursor-agent 以原生工具的方式拿到 linear_graphql 等 tracker 工具。
  # 同时把该文件加入 .git/info/exclude，避免被 agent 的 git add -A 提交进仓库。
  defp ensure_mcp_config(workspace) do
    case mcp_endpoint_url() do
      nil ->
        Logger.warning("cursor-cli 未检测到 Symphony HTTP 端口，跳过 MCP 注册；线性工具将不可用")
        nil

      url ->
        if write_mcp_config(workspace, url) == :error do
          Logger.warning("cursor-cli 写入 MCP 配置失败，线性工具可能不可用")
        else
          approve_mcp_server(workspace)
        end

        exclude_from_git(workspace)
        url
    end
  end

  # cursor-agent 的 MCP 批准记录是「按工作区 + 按 server 配置哈希」存的
  # （~/.cursor/projects/<工作区>/mcp-approvals.json），URL 一变（例如端口随机）
  # 哈希就变，需要重新批准。启动参数 --approve-mcps 在部分子命令下不生效，
  # 因此这里显式调用 mcp enable 做一次幂等批准，避免工具静默不可用。
  defp approve_mcp_server(workspace) do
    binary = cursor_command() |> String.split() |> List.first()

    if is_binary(binary) and binary != "" do
      case System.cmd(binary, ["mcp", "enable", @mcp_server_name],
             cd: workspace,
             stderr_to_stdout: true,
             env: [{"TERM", "dumb"}]
           ) do
        {_output, 0} ->
          :ok

        {output, code} ->
          Logger.warning("cursor-cli 预批准 MCP server 失败(#{code}): #{String.trim(output)}")
          :error
      end
    else
      :error
    end
  rescue
    error ->
      Logger.warning("cursor-cli 预批准 MCP server 异常: #{inspect(error)}")
      :error
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

  defp write_mcp_config(workspace, url) do
    dir = Path.join(workspace, ".cursor")
    path = Path.join(dir, "mcp.json")
    File.mkdir_p!(dir)

    existing =
      case File.read(path) do
        {:ok, content} ->
          case Jason.decode(content) do
            {:ok, %{} = decoded} -> decoded
            _ -> %{}
          end

        _ ->
          %{}
      end

    servers = Map.get(existing, "mcpServers")
    servers = if is_map(servers), do: servers, else: %{}

    entry = %{"type" => "http", "url" => url}
    updated = Map.put(existing, "mcpServers", Map.put(servers, @mcp_server_name, entry))

    File.write!(path, Jason.encode!(updated, pretty: true))
    :ok
  rescue
    error ->
      Logger.warning("写入 .cursor/mcp.json 失败: #{inspect(error)}")
      :error
  end

  defp exclude_from_git(workspace) do
    exclude_path = Path.join([workspace, ".git", "info", "exclude"])

    if File.dir?(Path.dirname(exclude_path)) do
      append_exclude_entry(exclude_path, ".cursor/mcp.json")
    end

    :ok
  rescue
    error ->
      Logger.warning("写入 .git/info/exclude 失败: #{inspect(error)}")
      :error
  end

  defp append_exclude_entry(exclude_path, entry) do
    existing = if File.exists?(exclude_path), do: File.read!(exclude_path), else: ""

    if String.contains?(existing, entry) do
      :ok
    else
      separator = if existing == "" or String.ends_with?(existing, "\n"), do: "", else: "\n"
      File.write!(exclude_path, existing <> separator <> "\n# Symphony 注入的 MCP 配置，不要提交\n" <> entry <> "\n")
    end
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

  defp remember_chat_id(_state, nil), do: :ok

  defp remember_chat_id(state, chat_id) when is_binary(chat_id) do
    :ets.insert(state, {:chat_id, chat_id})
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

  defp assistant_text(%{"message" => %{"content" => content}}) when is_list(content) do
    text =
      Enum.map_join(content, "", fn
        %{"type" => "text", "text" => value} -> to_text(value)
        _ -> ""
      end)

    if text == "", do: nil, else: text
  end

  defp assistant_text(_payload), do: nil

  defp tool_item(payload) do
    %{
      "type" => "tool_call",
      "id" => payload["call_id"],
      "name" => tool_name(payload)
    }
  end

  defp tool_name(%{"tool_call" => %{} = tool_call}) do
    case Map.keys(tool_call) |> List.first() do
      nil -> nil
      key -> key
    end
  end

  defp tool_name(_payload), do: nil

  defp usage_map(%{} = usage) do
    input = integer_value(usage["inputTokens"]) || 0
    output = integer_value(usage["outputTokens"]) || 0

    %{
      "inputTokens" => input,
      "outputTokens" => output,
      "totalTokens" => input + output
    }
  end

  defp usage_map(_usage), do: nil

  defp put_usage(metadata, nil), do: metadata

  defp put_usage(metadata, usage) do
    Map.put(metadata, :usage, %{"tokenUsage" => %{"total" => usage}})
  end

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
    Logger.debug("cursor-cli 上报: #{inspect(message[:event])}")
    :ok
  end

  defp log_plain_output(line) do
    trimmed = String.trim(line)

    if trimmed != "" do
      Logger.debug("cursor-cli 非 JSON 输出: #{String.slice(trimmed, 0, @plain_output_preview_bytes)}")
    end
  end

  defp issue_identifier(%{identifier: identifier}) when is_binary(identifier), do: identifier
  defp issue_identifier(_issue), do: "unknown"
end
