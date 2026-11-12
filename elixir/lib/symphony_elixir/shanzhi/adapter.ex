defmodule SymphonyElixir.Shanzhi.Adapter do
  @moduledoc """
  善治（SF 软件工厂）Bug 平台适配器。

  状态映射按 Bug 的生命周期来：

      | 善治状态 | Symphony 角色 | 效果 |
      |---|---|---|
      | `active`（激活） | active_states | 被认领、起 agent |
      | `resolved`（已解决） | 二者皆非 | agent 停下，工作区**保留**（等价于 In Review） |
      | `closed`（已关闭） | terminal_states | 停止并清理工作区 |

  `resolved` 落在「非 active、非 terminal」这一档是有意为之：善治的「已解决」
  正好对应人工评审闸门，agent 不再续跑，但工作区和未推送的改动都还在。
  """

  @behaviour SymphonyElixir.Tracker

  alias SymphonyElixir.Shanzhi.{AgentTool, Client}
  alias SymphonyElixir.Tracker.Issue

  @active_states ["active"]
  @terminal_states ["closed"]

  @spec validate_config(map()) :: :ok | {:error, term()}
  def validate_config(tracker_settings) do
    with :ok <- validate_states(tracker_settings.active_states, @active_states, :missing_shanzhi_active_states),
         :ok <-
           validate_states(
             tracker_settings.terminal_states,
             @terminal_states,
             :missing_shanzhi_terminal_states
           ) do
      Client.validate_settings(tracker_settings)
    end
  end

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_states(states), do: client_module().fetch_issues_by_states(states)

  @spec fetch_issues_by_ids([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_ids(issue_ids), do: client_module().fetch_issues_by_ids(issue_ids)

  @spec agent_tool_specs() :: [map()]
  def agent_tool_specs, do: AgentTool.tool_specs()

  @spec execute_agent_tool(String.t(), term(), keyword()) :: map()
  def execute_agent_tool(tool, arguments, opts), do: AgentTool.execute(tool, arguments, opts)

  @spec secret_environment_names(map()) :: [String.t()]
  def secret_environment_names(tracker_settings), do: Client.secret_environment_names(tracker_settings)

  @doc "允许的 active 状态（供文档与测试引用）。"
  def active_states, do: @active_states

  @doc "允许的 terminal 状态（供文档与测试引用）。"
  def terminal_states, do: @terminal_states

  defp client_module do
    Application.get_env(:symphony_elixir, :shanzhi_client_module, Client)
  end

  defp validate_states(states, allowed_states, _missing_error) when is_list(states) do
    if Enum.all?(states, &(normalize_state(&1) in allowed_states)) do
      :ok
    else
      {:error, :invalid_shanzhi_states}
    end
  end

  defp validate_states(_states, _allowed_states, missing_error), do: {:error, missing_error}

  defp normalize_state(state) when is_binary(state), do: state |> String.trim() |> String.downcase()
  defp normalize_state(_state), do: ""
end
