defmodule SymphonyElixir.IssueFeed.Adapter do
  @moduledoc """
  Symphony Tracker（HTTP JSON issue feed）适配器。
  """

  @behaviour SymphonyElixir.Tracker

  alias SymphonyElixir.IssueFeed.{AgentTool, Client}
  alias SymphonyElixir.Tracker.Issue

  @allowed_states ~w(backlog todo in_progress in_review done cancelled)

  @spec validate_config(map()) :: :ok | {:error, term()}
  def validate_config(tracker_settings) do
    with :ok <- validate_states(tracker_settings.active_states, :missing_issue_feed_active_states),
         :ok <- validate_states(tracker_settings.terminal_states, :missing_issue_feed_terminal_states) do
      Client.validate_settings(tracker_settings)
    end
  end

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_states(states), do: client_module().fetch_issues_by_states(states)

  @spec fetch_issues_by_ids([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_ids(issue_ids), do: client_module().fetch_issues_by_ids(issue_ids)

  @spec secret_environment_names(map()) :: [String.t()]
  def secret_environment_names(tracker_settings), do: Client.secret_environment_names(tracker_settings)

  @spec agent_tool_specs() :: [map()]
  def agent_tool_specs, do: AgentTool.tool_specs()

  @spec execute_agent_tool(String.t(), term(), keyword()) :: map()
  def execute_agent_tool(tool, arguments, opts), do: AgentTool.execute(tool, arguments, opts)

  defp client_module do
    Application.get_env(:symphony_elixir, :issue_feed_client_module, Client)
  end

  defp validate_states(states, _missing_error) when is_list(states) do
    if Enum.all?(states, &(normalize_state(&1) in @allowed_states)) do
      :ok
    else
      {:error, :invalid_issue_feed_states}
    end
  end

  defp validate_states(_states, missing_error), do: {:error, missing_error}

  defp normalize_state(state) when is_binary(state), do: state |> String.trim() |> String.downcase()
  defp normalize_state(_state), do: ""
end
