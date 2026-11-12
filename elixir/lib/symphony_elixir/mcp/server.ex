defmodule SymphonyElixir.Mcp.Server do
  @moduledoc """
  最小可用的 MCP（Model Context Protocol）服务端逻辑，传输层无关。

  存在的意义：Codex 通过 app-server 的 `item/tool/call` 反向请求使用 Symphony
  在本地注册的 tracker 工具（如 `linear_graphql`），而 Cursor CLI 之类的单向
  CLI 没有这个通道。这里把这套工具按 MCP 协议重新暴露一次，于是任何支持 MCP
  的 agent 都能以"原生工具"的方式调用它们，prompt 完全不用改。

  工具来源不是硬编码的 Linear，而是取当前 tracker adapter 的 `agent_tool_specs/0`：
  换成 GitLab / GitHub / Jira 时，暴露出去的工具集自动跟着变。

  协议要点：
    * `initialize` 返回协议版本与 tools 能力；
    * `tools/list` 直接返回 adapter 的 specs（MCP 与 Symphony 的字段同名同义）；
    * `tools/call` 走 `Tracker.execute_bound_agent_tool/4`，把
      `{success, output, contentItems}` 转成 MCP 的 `{content, isError}`；
    * 通知（无 `id`）不产生响应。
  """

  require Logger

  alias SymphonyElixir.Tracker

  @protocol_version "2025-06-18"
  @server_name "symphony"

  # JSON-RPC 2.0 标准错误码
  @invalid_request -32_600
  @method_not_found -32_601

  @type json_rpc_response :: %{String.t() => term()}

  @doc """
  处理单条 JSON-RPC 报文，返回响应 map；通知类报文返回 `:no_response`。
  """
  @spec handle(term()) :: json_rpc_response() | :no_response
  def handle(%{"method" => method} = request) do
    if is_nil(Map.get(request, "id")) do
      handle_notification(method)
    else
      {:reply, dispatch(method, Map.get(request, "params") || %{}, request["id"])}
    end
  end

  def handle(%{"id" => id} = request) do
    {:reply, error_response(id, @invalid_request, "Invalid Request: missing method", %{"request" => request})}
  end

  def handle(other) do
    {:reply, error_response(nil, @invalid_request, "Invalid Request", %{"request" => other})}
  end

  # ---------------------------------------------------------------- 方法分发

  defp dispatch("initialize", params, id) do
    success(id, %{
      "protocolVersion" => negotiate_version(params),
      "capabilities" => %{"tools" => %{"listChanged" => false}},
      "serverInfo" => %{"name" => @server_name, "version" => version()}
    })
  end

  defp dispatch("ping", _params, id), do: success(id, %{})

  defp dispatch("tools/list", _params, id) do
    success(id, %{"tools" => tool_specs()})
  end

  defp dispatch("tools/call", params, id) do
    tool_name = Map.get(params, "name")
    arguments = Map.get(params, "arguments") || %{}

    result =
      tool_name
      |> execute_tool(arguments)
      |> to_mcp_result()

    success(id, result)
  end

  defp dispatch(method, _params, id) do
    error_response(id, @method_not_found, "Method not found: #{inspect(method)}", nil)
  end

  defp handle_notification("notifications/initialized"), do: :no_response
  defp handle_notification(_method), do: :no_response

  # ---------------------------------------------------------------- 工具执行

  defp tool_specs do
    Tracker.bind_agent_tools().tool_specs
  rescue
    error ->
      Logger.warning("MCP 取工具清单失败: #{inspect(error)}")
      []
  end

  defp execute_tool(tool_name, arguments) when is_binary(tool_name) do
    binding = Tracker.bind_agent_tools()
    Tracker.execute_bound_agent_tool(binding, tool_name, arguments)
  rescue
    error ->
      %{
        "success" => false,
        "output" => "Symphony 执行工具 #{tool_name} 失败: #{inspect(error)}"
      }
  catch
    # HTTP 客户端进程不在或崩了会以 :exit 抛出，rescue 抓不到；
    # 这里兜住，避免整个 MCP 调用变成 500。
    :exit, reason ->
      %{
        "success" => false,
        "output" => "Symphony 执行工具 #{tool_name} 时底层进程退出: #{inspect(reason)}"
      }
  end

  defp execute_tool(tool_name, _arguments) do
    %{"success" => false, "output" => "MCP tools/call 缺少工具名: #{inspect(tool_name)}"}
  end

  defp to_mcp_result(%{"contentItems" => items} = result) when is_list(items) do
    content =
      Enum.map(items, fn
        %{"type" => "inputText", "text" => text} -> %{"type" => "text", "text" => to_string(text)}
        %{"text" => text} -> %{"type" => "text", "text" => to_string(text)}
        other -> %{"type" => "text", "text" => encode(other)}
      end)

    %{"content" => content, "isError" => result["success"] == false}
  end

  defp to_mcp_result(%{"success" => success, "output" => output}) do
    %{
      "content" => [%{"type" => "text", "text" => to_string(output)}],
      "isError" => success == false
    }
  end

  defp to_mcp_result(other) do
    %{"content" => [%{"type" => "text", "text" => encode(other)}], "isError" => true}
  end

  # ---------------------------------------------------------------- 响应构造

  defp success(id, result) do
    %{"jsonrpc" => "2.0", "id" => id, "result" => result}
  end

  defp error_response(id, code, message, data) do
    error = %{"code" => code, "message" => message}
    error = if is_nil(data), do: error, else: Map.put(error, "data", data)
    %{"jsonrpc" => "2.0", "id" => id, "error" => error}
  end

  # 客户端声明了受支持的版本就沿用，否则用服务端默认版本。
  defp negotiate_version(%{"protocolVersion" => version}) when is_binary(version), do: version
  defp negotiate_version(_params), do: @protocol_version

  defp version do
    case Application.spec(:symphony_elixir, :vsn) do
      nil -> "0.0.0"
      vsn -> to_string(vsn)
    end
  end

  defp encode(value) do
    case Jason.encode(value, pretty: true) do
      {:ok, encoded} -> encoded
      _ -> inspect(value)
    end
  end
end
