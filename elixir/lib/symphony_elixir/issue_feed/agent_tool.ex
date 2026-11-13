defmodule SymphonyElixir.IssueFeed.AgentTool do
  @moduledoc """
  面向 Agent 的 Symphony Tracker REST 工具，用于更新工单状态与评论。
  """

  alias SymphonyElixir.IssueFeed.Client

  @tracker_api_tool "tracker_api"
  @allowed_methods ["GET", "POST", "PATCH", "PUT"]
  @api_path_pattern ~r/^\/api\/v1\//

  @tracker_api_description """
  调用本机 Symphony Tracker REST API（改状态、留言、读详情）。
  路径示例：`/api/v1/issues/{{ issue.id }}`、`/api/v1/issues/{{ issue.id }}/comments`。
  """

  @tracker_api_input_schema %{
    "type" => "object",
    "additionalProperties" => false,
    "required" => ["method", "path"],
    "properties" => %{
      "method" => %{
        "type" => "string",
        "enum" => @allowed_methods,
        "description" => "HTTP 方法。"
      },
      "path" => %{
        "type" => "string",
        "description" => "Tracker 路径，须以 /api/v1/ 开头。"
      },
      "params" => %{
        "type" => ["object", "null"],
        "description" => "可选查询参数。",
        "additionalProperties" => true
      },
      "body" => %{
        "description" => "可选 JSON 请求体。"
      }
    }
  }

  @spec execute(String.t() | nil, term(), keyword()) :: map()
  def execute(tool, arguments, opts) do
    case tool do
      @tracker_api_tool -> execute_tracker_api(arguments, opts)
      other -> unsupported_tool_response(other)
    end
  end

  @spec tool_specs() :: [map()]
  def tool_specs do
    [
      %{
        "name" => @tracker_api_tool,
        "description" => @tracker_api_description,
        "inputSchema" => @tracker_api_input_schema
      }
    ]
  end

  defp execute_tracker_api(arguments, opts) do
    client = Keyword.get(opts, :issue_feed_client, &Client.request/5)
    client_opts = Keyword.take(opts, [:tracker_settings])

    with {:ok, method, path, params, body} <- normalize_arguments(arguments),
         {:ok, %{status: status, body: response_body}} <-
           client.(method, path, params, body, client_opts),
         true <- is_integer(status) do
      rest_response(status, response_body)
    else
      {:error, reason} -> failure_response(tool_error_payload(reason))
      _ -> failure_response(tool_error_payload(:issue_feed_unknown_payload))
    end
  end

  defp normalize_arguments(arguments) when is_map(arguments) do
    with {:ok, method} <- normalize_method(Map.get(arguments, "method")),
         {:ok, path} <- normalize_path(Map.get(arguments, "path")),
         {:ok, params} <- normalize_params(Map.get(arguments, "params")) do
      {:ok, method, path, params, Map.get(arguments, "body")}
    end
  end

  defp normalize_arguments(_arguments), do: {:error, :invalid_arguments}

  defp normalize_method(method) when is_binary(method) do
    normalized = method |> String.trim() |> String.upcase()
    if normalized in @allowed_methods, do: {:ok, normalized}, else: {:error, :invalid_method}
  end

  defp normalize_method(_method), do: {:error, :invalid_method}

  defp normalize_path(path) when is_binary(path) do
    trimmed = String.trim(path)

    cond do
      not String.starts_with?(trimmed, "/") ->
        {:error, :invalid_path}

      String.contains?(trimmed, ["://", "\n", "\r", <<0>>]) ->
        {:error, :invalid_path}

      not Regex.match?(@api_path_pattern, trimmed) ->
        {:error, :invalid_tracker_api_path}

      true ->
        {:ok, trimmed}
    end
  end

  defp normalize_path(_path), do: {:error, :invalid_path}

  defp normalize_params(nil), do: {:ok, %{}}
  defp normalize_params(params) when is_map(params), do: {:ok, params}
  defp normalize_params(_params), do: {:error, :invalid_params}

  defp rest_response(status, body) do
    dynamic_tool_response(status in 200..299, encode_payload(%{"status" => status, "body" => body}))
  end

  defp failure_response(payload), do: dynamic_tool_response(false, encode_payload(payload))

  defp dynamic_tool_response(success, output) do
    %{
      "success" => success,
      "output" => output,
      "contentItems" => [%{"type" => "inputText", "text" => output}]
    }
  end

  defp encode_payload(payload) do
    case Jason.encode(payload, pretty: true) do
      {:ok, output} -> output
      {:error, _reason} -> inspect(payload)
    end
  end

  defp unsupported_tool_response(tool) do
    failure_response(%{
      "error" => %{
        "message" => "Unsupported dynamic tool: #{inspect(tool)}.",
        "supportedTools" => supported_tool_names()
      }
    })
  end

  defp tool_error_payload(:invalid_arguments) do
    %{"error" => %{"message" => "`tracker_api` 需要包含 `method` 与 `path` 的对象。"}}
  end

  defp tool_error_payload(:invalid_method) do
    %{"error" => %{"message" => "`tracker_api.method` 须为 GET、POST、PATCH 或 PUT。"}}
  end

  defp tool_error_payload(:invalid_path) do
    %{"error" => %{"message" => "`tracker_api.path` 须为以 `/` 开头的相对路径。"}}
  end

  defp tool_error_payload(:invalid_tracker_api_path) do
    %{
      "error" => %{
        "message" => "`tracker_api.path` 仅限 Symphony Tracker 的 `/api/v1/...` 接口（不可调 /api/symphony 轮询端点）。"
      }
    }
  end

  defp tool_error_payload(:invalid_params) do
    %{"error" => %{"message" => "`tracker_api.params` 须为 JSON 对象。"}}
  end

  defp tool_error_payload(:missing_issue_feed_project) do
    %{"error" => %{"message" => "WORKFLOW.md 中缺少 Tracker 项目配置（provider.project）。"}}
  end

  defp tool_error_payload({:issue_feed_api_request, reason}) do
    %{
      "error" => %{
        "message" => "Tracker API 请求失败。",
        "reason" => inspect(reason)
      }
    }
  end

  defp tool_error_payload(reason) do
    %{"error" => %{"message" => "Tracker API 工具执行失败。", "reason" => inspect(reason)}}
  end

  defp supported_tool_names, do: Enum.map(tool_specs(), & &1["name"])
end
