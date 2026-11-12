defmodule SymphonyElixir.Agent.Zcode do
  @moduledoc """
  `SymphonyElixir.Agent` 的 ZCode CLI 实现。

  ZCode 是 Z.ai 基于 GLM 的编程 Agent，它的 CLI 与 Cursor CLI 的交互方式高度一致：
  每个 turn 启动一次 `zcode -p --output-format stream-json`，读取 NDJSON 事件流，
  再映射成 Codex 语义通过 `on_message` 上报，因此看板、编排器与多轮续跑逻辑无需改动。

  与 Cursor CLI 的差异：

    * ZCode 没有 `--model` 参数，模型由 `~/.zcode/v2/provider_config.json` 决定，
      所以这里不传模型，默认沿用 ZCode 里已配置的模型（例如 `deepseek-flash`）；
    * 终止记录是 `{"type": "result", ...}`，其前的 `turn.completed` 携带更完整的结果；
    * MCP 走项目级 `<workspace>/zcode.json` 的 `mcp.servers`，传输类型为 `http`。

  多轮对话复用同一个 session：事件顶层的 `sessionId`（`sess_...`）会被记住，
  后续 turn 通过 `--resume <sessionId>` 续接。
  """

  @behaviour SymphonyElixir.Agent

  require Logger

  alias SymphonyElixir.{Config, PathSafety}

  @default_command "zcode"
  @mcp_server_name "symphony"
  @line_bytes 1_048_576
  @plain_output_preview_bytes 400

  # ZCode 桌面版自带的 CLI 运行时。发行包里的 `zcode` 命令从这个目录取 provider 配置，
  # 但实际文件放在 `Resources/config/provider/` 下，直接执行会报
  # 「无法定位 CLI ZCode Built-in Provider Config」。因此需要做一层 shim：
  # 把运行时和 provider 配置复制到同一目录，再执行副本。
  @bundled_runtime "/Applications/ZCode.app/Contents/Resources/glm/zcode.cjs"
  @bundled_provider "/Applications/ZCode.app/Contents/Resources/config/provider/zcode-builtin.json"

  @type context :: %{
          on_message: (map() -> any()),
          state: :ets.tid(),
          metadata: map(),
          session_id: String.t() | nil,
          turn_id: non_neg_integer(),
          started?: boolean(),
          turn_completed: map() | nil,
          tools: %{optional(String.t()) => String.t() | nil},
          last_plain: String.t()
        }

  @impl true
  @spec start_session(Path.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def start_session(workspace, opts \\ []) do
    case Keyword.get(opts, :worker_host) do
      host when is_binary(host) ->
        {:error, {:zcode_remote_worker_unsupported, host}}

      _ ->
        with {:ok, expanded_workspace} <- validate_workspace_cwd(workspace) do
          state = :ets.new(__MODULE__, [:set])
          :ets.insert(state, {:session_id, nil})
          :ets.insert(state, {:turn_count, 0})
          mcp_url = ensure_mcp_config(expanded_workspace)

          {:ok,
           %{
             workspace: expanded_workspace,
             worker_host: nil,
             command: zcode_command(),
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
      turn_completed: nil,
      tools: %{},
      last_plain: ""
    }

    launch = build_launch_command(command, workspace, session_id, prompt, secret_names)

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
        Logger.error("启动 zcode 失败: #{inspect(reason)} issue=#{issue_identifier(issue)}")
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

      {:ok, %{"type" => "turn.completed"} = payload} ->
        # turn.completed 比 result 早一行，且带更完整的结果（resultType、toolCallCount 等）。
        # 先缓存，等 result 到达时一起上报。
        context = %{context | turn_completed: payload["payload"]}
        receive_loop(port, track_session(context, payload), "", timeout_ms())

      {:ok, %{"type" => "turn.failed"} = payload} ->
        fail_turn(context, payload["payload"] || payload, line)

      {:ok, %{"type" => "error"} = payload} ->
        fail_turn(context, payload, line)

      {:ok, %{"type" => type} = payload} when is_binary(type) ->
        context = track_session(context, payload)
        receive_loop(port, handle_event(context, type, payload, line), "", timeout_ms())

      {:ok, payload} ->
        emit(context.on_message, :other_message, %{payload: payload, raw: line}, context.metadata)
        receive_loop(port, context, "", timeout_ms())

      {:error, _reason} ->
        log_plain_output(line)
        receive_loop(port, %{context | last_plain: String.slice(line, 0, @plain_output_preview_bytes)}, "", timeout_ms())
    end
  end

  # ZCode 把 sessionId 放在每条事件的顶层，用它做续跑依据。
  defp track_session(context, payload) do
    session_id = payload["sessionId"] || context.session_id
    session_id = if is_binary(session_id) and session_id != "", do: session_id, else: context.session_id

    context = %{context | session_id: session_id}
    remember_session_id(context.state, session_id)

    if context.started? or not is_binary(session_id) do
      context
    else
      emit(
        context.on_message,
        :session_started,
        %{session_id: session_id, thread_id: session_id, turn_id: context.turn_id, model: nil},
        context.metadata
      )

      %{context | started?: true}
    end
  end

  defp handle_event(context, "model.streaming", %{"payload" => %{"kind" => kind} = payload}, _line) do
    context = remember_tool(context, payload)

    case kind do
      "text_delta" ->
        case to_text(payload["delta"]) do
          "" -> context
          text -> notify(context, "item/agentMessage/delta", %{"delta" => text})
        end

      "reasoning_delta" ->
        case to_text(payload["delta"]) do
          "" -> context
          text -> notify(context, "item/reasoning/textDelta", %{"delta" => text})
        end

      "tool_input_start" ->
        notify(context, "item/started", %{"item" => tool_item(context, payload, "in_progress")})

      "tool_call" ->
        # tool_input_start 已经报过，避免重复
        if is_nil(context.tools[payload["toolCallId"]]) do
          notify(context, "item/started", %{"item" => tool_item(context, payload, "in_progress")})
        else
          context
        end

      _ ->
        context
    end
  end

  defp handle_event(context, "tool.updated", %{"payload" => %{"kind" => "started"} = payload}, _line) do
    remember_tool(context, payload)
  end

  defp handle_event(context, "tool.updated", %{"payload" => %{"kind" => "result"} = payload}, _line) do
    notify(context, "item/completed", %{"item" => tool_item(context, payload, tool_status(payload))})
    context
  end

  defp handle_event(context, _type, _payload, _line), do: context

  defp finish_turn(context, payload, line) do
    session_id = payload["sessionId"] || context.session_id
    remember_session_id(context.state, session_id)

    completed = context.turn_completed || %{}
    result = to_text(payload["response"])
    result = if result == "", do: to_text(completed["response"]), else: result

    usage = usage_map(payload["usage"] || completed["usage"])
    metadata = put_usage(context.metadata, usage) |> Map.put(:session_id, session_id)

    if failure_result_type?(completed["resultType"]) do
      emit(
        context.on_message,
        :turn_failed,
        %{
          payload: %{"method" => "turn/failed", "params" => %{"usage" => usage}},
          raw: line,
          details: Map.put(completed, "response", result)
        },
        metadata
      )

      {:error, {:turn_failed, result}}
    else
      params =
        %{"usage" => usage}
        |> maybe_put("toolCallCount", completed["toolCallCount"])
        |> maybe_put("duration", completed["duration"])

      emit(
        context.on_message,
        :turn_completed,
        %{payload: %{"method" => "turn/completed", "params" => params}, raw: line, details: completed},
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

  defp failure_result_type?(value) when is_binary(value) do
    value not in ["success", "completed", ""]
  end

  defp failure_result_type?(_value), do: false

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

  defp build_launch_command(command, workspace, session_id, prompt, secret_names) do
    base = [
      command,
      "-p",
      shell_escape(prompt),
      "--output-format",
      "stream-json",
      # -p 的默认模式本来就是 yolo，这里显式声明，避免上游改默认值后卡在审批上
      "--mode",
      "yolo",
      "--cwd",
      shell_escape(workspace)
    ]

    resume =
      if is_binary(session_id) and String.trim(session_id) != "" do
        ["--resume", shell_escape(session_id)]
      else
        []
      end

    [unset_prefix(secret_names), Enum.join(base ++ resume, " ")]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" && ")
  end

  defp zcode_command do
    case configured_command() do
      nil -> detect_command()
      command -> command
    end
  end

  defp configured_command do
    case Config.settings!().agent.zcode_command do
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

  defp detect_command do
    case System.find_executable("zcode") do
      nil -> bundled_command()
      path -> path
    end
  end

  # ZCode 桌面版自带的运行时不能直接执行（provider 配置路径不匹配），
  # 因此把它和 provider 配置复制到同一个缓存目录再执行。
  defp bundled_command do
    with true <- File.exists?(@bundled_runtime),
         {:ok, shim_dir} <- ensure_bundled_shim() do
      node = System.find_executable("node") || "node"
      "#{node} #{shell_escape(Path.join(shim_dir, "zcode.cjs"))}"
    else
      _ -> @default_command
    end
  end

  defp ensure_bundled_shim do
    shim_dir = shim_dir()
    runtime_copy = Path.join(shim_dir, "zcode.cjs")
    provider_copy = Path.join([shim_dir, "provider", "zcode-builtin.json"])

    File.mkdir_p!(Path.dirname(provider_copy))

    with :ok <- sync_file(@bundled_runtime, runtime_copy),
         :ok <- sync_file(@bundled_provider, provider_copy) do
      {:ok, shim_dir}
    end
  rescue
    error ->
      Logger.warning("zcode 运行时 shim 准备失败: #{inspect(error)}")
      {:error, {:shim_failed, error}}
  end

  defp shim_dir do
    Path.join(System.user_home!(), ".cache/symphony/zcode-runtime")
  end

  # 源文件比副本新（或副本不存在）时重新复制，兼顾 ZCode 升级后的自动跟随。
  defp sync_file(source, target) do
    case File.stat(source) do
      {:ok, %File.Stat{} = source_stat} ->
        needs_copy? =
          case File.stat(target) do
            {:ok, %File.Stat{} = target_stat} ->
              target_stat.size != source_stat.size or
                NaiveDateTime.compare(target_stat.mtime, source_stat.mtime) == :lt

            _ ->
              true
          end

        if needs_copy? do
          File.cp!(source, target)
          :ok
        else
          :ok
        end

      _ ->
        {:error, {:source_missing, source}}
    end
  end

  # ---------------------------------------------------------------- MCP 接线

  # 把 Symphony 的 MCP 端点（/mcp）写进工作区的 zcode.json，
  # 让 zcode 以原生工具的方式拿到 linear_graphql 等 tracker 工具。
  # 同时把该文件加入 .git/info/exclude，避免被 agent 的 git add -A 提交进仓库。
  defp ensure_mcp_config(workspace) do
    case mcp_endpoint_url() do
      nil ->
        Logger.warning("zcode 未检测到 Symphony HTTP 端口，跳过 MCP 注册；线性工具将不可用")
        nil

      url ->
        if write_mcp_config(workspace, url) == :error do
          Logger.warning("zcode 写入 MCP 配置失败，线性工具可能不可用")
        else
          exclude_from_git(workspace)
        end

        url
    end
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
    path = Path.join(workspace, "zcode.json")

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

    features = Map.get(existing, "features")
    features = if is_map(features), do: features, else: %{}

    mcp = Map.get(existing, "mcp")
    mcp = if is_map(mcp), do: mcp, else: %{}

    servers = Map.get(mcp, "servers")
    servers = if is_map(servers), do: servers, else: %{}

    entry = %{"type" => "http", "url" => url, "enabled" => true, "timeoutMs" => 30_000}

    updated =
      existing
      |> Map.put("features", Map.put(features, "mcp", true))
      |> Map.put("mcp", Map.put(mcp, "servers", Map.put(servers, @mcp_server_name, entry)))

    File.write!(path, Jason.encode!(updated, pretty: true))
    :ok
  rescue
    error ->
      Logger.warning("写入 zcode.json 失败: #{inspect(error)}")
      :error
  end

  defp exclude_from_git(workspace) do
    exclude_path = Path.join([workspace, ".git", "info", "exclude"])

    if File.dir?(Path.dirname(exclude_path)) do
      append_exclude_entry(exclude_path, "zcode.json")
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

  defp remember_tool(context, payload) do
    case {payload["toolCallId"], payload["toolName"]} do
      {id, name} when is_binary(id) and is_binary(name) ->
        %{context | tools: Map.put(context.tools, id, name)}

      _ ->
        context
    end
  end

  defp tool_item(context, payload, status) do
    id = payload["toolCallId"]

    %{
      "type" => "tool_call",
      "id" => id,
      "name" => payload["toolName"] || (is_binary(id) && Map.get(context.tools, id)) || "tool",
      "status" => status
    }
  end

  defp tool_status(%{"result" => %{"success" => true}}), do: "completed"
  defp tool_status(%{"result" => %{}}), do: "failed"
  defp tool_status(_payload), do: "completed"

  defp usage_map(%{} = usage) do
    input = integer_value(usage["inputTokens"]) || 0
    output = integer_value(usage["outputTokens"]) || 0

    %{
      "inputTokens" => input,
      "outputTokens" => output,
      "totalTokens" => integer_value(usage["totalTokens"]) || input + output,
      "cachedInputTokens" => integer_value(usage["cacheReadTokens"]) || 0
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
    Logger.debug("zcode 上报: #{inspect(message[:event])}")
    :ok
  end

  defp log_plain_output(line) do
    trimmed = String.trim(line)

    if trimmed != "" do
      Logger.debug("zcode 非 JSON 输出: #{String.slice(trimmed, 0, @plain_output_preview_bytes)}")
    end
  end

  defp issue_identifier(%{identifier: identifier}) when is_binary(identifier), do: identifier
  defp issue_identifier(_issue), do: "unknown"
end
