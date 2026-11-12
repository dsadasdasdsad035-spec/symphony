defmodule SymphonyElixir.Shanzhi.AgentTool do
  @moduledoc """
  暴露给 agent 的善治 Bug 工具。

  只开放读详情、读历史、加备注、解决这四件事：善治的「提 Bug」和「删除」
  都是人工动作，自动化里不该出现，所以刻意不提供。

  凭证只存在 Symphony 进程内，agent 拿不到账号密码。
  """

  alias SymphonyElixir.Shanzhi.Client

  @get_bug "shanzhi_get_bug"
  @bug_history "shanzhi_bug_history"
  @confirm_bug "shanzhi_confirm_bug"
  @remark_bug "shanzhi_remark_bug"
  @resolve_bug "shanzhi_resolve_bug"

  @bug_id_schema %{
    "type" => "object",
    "additionalProperties" => false,
    "required" => ["bug_id"],
    "properties" => %{
      "bug_id" => %{
        "type" => ["integer", "string"],
        "description" => "善治 Bug 编号，例如 83204。"
      }
    }
  }

  @spec tool_specs() :: [map()]
  def tool_specs do
    [
      %{
        "name" => @get_bug,
        "description" => "读取善治 Bug 的完整详情（含复现步骤、备注、处理人）。",
        "inputSchema" => @bug_id_schema
      },
      %{
        "name" => @bug_history,
        "description" => "读取善治 Bug 的操作历史，包含每次状态变更与备注。",
        "inputSchema" => @bug_id_schema
      },
      %{
        "name" => @confirm_bug,
        "description" =>
          "确认善治 Bug，把「确认」字段置为是。未确认的 Bug 不会被 Symphony 派发，除非用它确认。\n\n" <>
            "注意：确认代表「这确实是有效缺陷」，属于评审动作。只有当你在真实环境复现成功、" <>
            "确信不是误报时才调用；如果无法复现或判断是误报，改用 shanzhi_remark_bug 说明原因，不要确认。",
        "inputSchema" => %{
          "type" => "object",
          "additionalProperties" => false,
          "required" => ["bug_id"],
          "properties" => %{
            "bug_id" => %{"type" => ["integer", "string"], "description" => "善治 Bug 编号。"},
            "assignee" => %{
              "type" => "string",
              "description" => "确认后指派给谁（姓名或手机号）。留空沿用 Bug 当前指派人。"
            },
            "comment" => %{"type" => "string", "description" => "确认备注，例如复现结论，支持 HTML。"}
          }
        }
      },
      %{
        "name" => @remark_bug,
        "description" => "给善治 Bug 追加一条备注。自动化过程中用它把进展写回 Bug（会进入操作历史）。",
        "inputSchema" => %{
          "type" => "object",
          "additionalProperties" => false,
          "required" => ["bug_id", "comment"],
          "properties" => %{
            "bug_id" => %{"type" => ["integer", "string"], "description" => "善治 Bug 编号。"},
            "comment" => %{"type" => "string", "description" => "备注内容，支持 HTML。"}
          }
        }
      },
      %{
        "name" => @resolve_bug,
        "description" => "解决善治 Bug，状态置为「已解决」。这是交付的终点动作；解决后 Symphony 会停止该 Bug 的 agent。",
        "inputSchema" => %{
          "type" => "object",
          "additionalProperties" => false,
          "required" => ["bug_id"],
          "properties" => %{
            "bug_id" => %{"type" => ["integer", "string"], "description" => "善治 Bug 编号。"},
            "resolution" => %{
              "type" => "string",
              "description" => "解决方案：fixed 已解决（默认）、bydesign 设计如此、duplicate 重复、notrepro 无法重现、postponed 延期、willnotfix 不予处理、external 外部原因、tostory 转为需求。"
            },
            "comment" => %{"type" => "string", "description" => "解决说明，支持 HTML。"}
          }
        }
      }
    ]
  end

  @spec execute(String.t() | nil, term(), keyword()) :: map()
  def execute(tool, arguments, opts) do
    case tool do
      @get_bug ->
        run(opts, fn settings, args -> Client.get_bug(arg(args, "bug_id"), settings) end, arguments)

      @bug_history ->
        run(opts, fn settings, args -> Client.bug_history(arg(args, "bug_id"), settings) end, arguments)

      @confirm_bug ->
        run(
          opts,
          fn settings, args ->
            Client.confirm_bug(
              arg(args, "bug_id"),
              arg(args, "assignee"),
              to_string(arg(args, "comment") || ""),
              settings
            )
          end,
          arguments
        )

      @remark_bug ->
        run(
          opts,
          fn settings, args ->
            Client.remark_bug(arg(args, "bug_id"), to_string(arg(args, "comment") || ""), settings)
          end,
          arguments
        )

      @resolve_bug ->
        run(
          opts,
          fn settings, args ->
            Client.resolve_bug(
              arg(args, "bug_id"),
              to_string(arg(args, "resolution") || "fixed"),
              to_string(arg(args, "comment") || ""),
              settings
            )
          end,
          arguments
        )

      other ->
        unsupported_tool_response(other)
    end
  end

  defp run(opts, fun, arguments) do
    tracker_settings = Keyword.get_lazy(opts, :tracker_settings, fn -> SymphonyElixir.Config.settings!().tracker end)

    with {:ok, settings} <- Client.settings(tracker_settings),
         {:ok, result} <- fun.(settings, arguments) do
      dynamic_tool_response(true, encode_payload(result))
    else
      {:error, reason} -> dynamic_tool_response(false, encode_payload(error_payload(reason)))
      other -> dynamic_tool_response(false, encode_payload(error_payload(other)))
    end
  end

  defp arg(arguments, key) when is_map(arguments), do: Map.get(arguments, key)
  defp arg(_arguments, _key), do: nil

  defp error_payload(:auth) do
    %{
      "error" => %{
        "message" => "善治鉴权失败。检查 `tracker.provider.username` / `password` 或 SF_USERNAME / SF_PASSWORD。"
      }
    }
  end

  defp error_payload(:empty_comment), do: %{"error" => %{"message" => "备注内容不能为空。"}}

  defp error_payload(:missing_shanzhi_username),
    do: %{"error" => %{"message" => "缺少善治账号。设置 `tracker.provider.username` 或 SF_USERNAME。"}}

  defp error_payload(:missing_shanzhi_password),
    do: %{"error" => %{"message" => "缺少善治密码。设置 `tracker.provider.password` 或 SF_PASSWORD。"}}

  defp error_payload(:missing_shanzhi_product_id),
    do: %{"error" => %{"message" => "缺少善治产品 ID。设置 `tracker.provider.product_id`。"}}

  defp error_payload({:invalid_shanzhi_bug_id, value}),
    do: %{"error" => %{"message" => "`bug_id` 不是合法编号: #{inspect(value)}"}}

  defp error_payload(reason), do: %{"error" => %{"message" => "善治接口调用失败。", "reason" => inspect(reason)}}

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
    dynamic_tool_response(
      false,
      %{
        "error" => %{
          "message" => "Unsupported dynamic tool: #{inspect(tool)}.",
          "supportedTools" => Enum.map(tool_specs(), & &1["name"])
        }
      }
      |> encode_payload()
    )
  end
end
