defmodule SymphonyElixir.IssueFeed.Client do
  @moduledoc """
  HTTP client for the Symphony Tracker issue feed API.
  """

  require Logger

  alias SymphonyElixir.Config
  alias SymphonyElixir.Tracker.Issue

  @default_base_url "http://127.0.0.1:4780"

  @spec validate_settings(map()) :: :ok | {:error, term()}
  def validate_settings(tracker_settings) do
    with {:ok, _settings} <- settings(tracker_settings), do: :ok
  end

  @spec secret_environment_names(map()) :: [String.t()]
  def secret_environment_names(tracker_settings) do
    provider = provider_settings(tracker_settings)
    ["TRACKER_API_TOKEN" | env_reference_names([provider["api_token"]])]
    |> Enum.uniq()
  end

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_states(state_names) when is_list(state_names) do
    fetch_issues_by_states(state_names, Config.settings!().tracker, &perform_request/5)
  end

  @spec fetch_issues_by_ids([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_ids(issue_ids) when is_list(issue_ids) do
    fetch_issues_by_ids(issue_ids, Config.settings!().tracker, &perform_request/5)
  end

  @doc """
  Symphony Tracker REST 请求（供 `tracker_api` Agent 工具使用），返回 HTTP 状态与 body。
  """
  @spec request(String.t(), String.t(), map(), term(), keyword()) ::
          {:ok, %{status: integer(), body: term()}} | {:error, term()}
  def request(method, path, params, body, opts \\ [])
      when is_binary(method) and is_binary(path) and is_map(params) and is_list(opts) do
    tracker_settings = Keyword.get_lazy(opts, :tracker_settings, fn -> Config.settings!().tracker end)
    request_fun = Keyword.get(opts, :request_fun, &perform_agent_request/5)

    with {:ok, settings} <- settings(tracker_settings) do
      request_fun.(method, path, params, body, settings)
    end
  end

  @doc false
  @spec fetch_issues_by_states_for_test([String.t()], map(), function()) ::
          {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_states_for_test(state_names, tracker_settings, request_fun)
      when is_list(state_names) and is_map(tracker_settings) and is_function(request_fun, 5) do
    fetch_issues_by_states(state_names, tracker_settings, request_fun)
  end

  @doc false
  @spec fetch_issues_by_ids_for_test([String.t()], map(), function()) ::
          {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_ids_for_test(issue_ids, tracker_settings, request_fun)
      when is_list(issue_ids) and is_map(tracker_settings) and is_function(request_fun, 5) do
    fetch_issues_by_ids(issue_ids, tracker_settings, request_fun)
  end

  defp fetch_issues_by_states(state_names, tracker_settings, request_fun) do
    normalized_states =
      state_names
      |> Enum.map(&normalize_state/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()

    if normalized_states == [] do
      {:ok, []}
    else
      with {:ok, assignee_filter} <- routing_assignee_filter(),
           {:ok, settings} <- settings(tracker_settings),
           {:ok, body} <-
             request_fun.(
               :get,
               "/api/symphony/issues",
               %{
                 "project" => settings.project,
                 "states" => Enum.join(normalized_states, ","),
                 "label" => settings.poll_label
               },
               nil,
               settings
             ),
           true <- is_map(body) or {:error, :issue_feed_unknown_payload} do
        issues =
          body
          |> Map.get("issues", [])
          |> normalize_issue_list(normalized_states, assignee_filter)

        {:ok, issues}
      end
    end
  end

  defp fetch_issues_by_ids(issue_ids, tracker_settings, request_fun) do
    ids = issue_ids |> Enum.map(&to_string/1) |> Enum.uniq()

    case ids do
      [] ->
        {:ok, []}

      ids ->
        with {:ok, assignee_filter} <- routing_assignee_filter(),
             {:ok, settings} <- settings(tracker_settings),
             {:ok, body} <-
               request_fun.(:post, "/api/symphony/issues/batch", %{}, %{"ids" => ids}, settings),
             true <- is_map(body) or {:error, :issue_feed_unknown_payload} do
          issues =
            body
            |> Map.get("issues", [])
            |> normalize_issue_list(nil, assignee_filter)

          {:ok, issues}
        end
    end
  end

  defp normalize_issue_list(list, requested_states, assignee_filter) when is_list(list) do
    state_set =
      case requested_states do
        nil -> nil
        states -> MapSet.new(states)
      end

    list
    |> Enum.map(&normalize_issue(&1, assignee_filter))
    |> Enum.reject(&is_nil/1)
    |> then(fn issues ->
      case state_set do
        nil -> issues
        set -> Enum.filter(issues, &MapSet.member?(set, &1.state))
      end
    end)
  end

  defp normalize_issue_list(_list, _requested_states, _assignee_filter), do: []

  defp normalize_issue(issue, assignee_filter) when is_map(issue) do
    id = issue["id"] |> presence_string()
    identifier = issue["identifier"] |> presence_string()
    title = issue["title"] |> presence_string()
    state = issue["state"] |> normalize_state()

    if Enum.all?([id, identifier, title, state], &present_string?/1) do
      blockers = extract_blockers(issue)
      assignee_match = assignee_match_value(issue)

      %Issue{
        id: id,
        native_ref: %{"id" => id, "identifier" => identifier},
        identifier: identifier,
        title: title,
        description: issue["description"],
        priority: parse_priority(issue["priority"]),
        state: state,
        branch_name: branch_name_field(issue),
        url: issue["url"],
        assignee_id: assignee_match,
        labels: extract_labels(issue),
        blocked_by: blockers,
        dispatchable: dispatchable?(state, blockers, assignee_match, assignee_filter),
        created_at: parse_datetime(issue["created_at"]),
        updated_at: parse_datetime(issue["updated_at"])
      }
    end
  end

  defp normalize_issue(_issue, _assignee_filter), do: nil

  @doc false
  @spec normalize_issue_for_test(map(), String.t() | nil) :: Issue.t() | nil
  def normalize_issue_for_test(issue, assignee \\ nil) when is_map(issue) do
    assignee_filter =
      case assignee do
        value when is_binary(value) ->
          case build_assignee_filter(value) do
            {:ok, filter} -> filter
            {:error, _reason} -> nil
          end

        _ ->
          nil
      end

    normalize_issue(issue, assignee_filter)
  end

  defp extract_labels(%{"labels" => labels}) when is_list(labels) do
    labels
    |> Enum.map(&to_string/1)
    |> Enum.map(&(String.trim(&1) |> String.downcase()))
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp extract_labels(_issue), do: []

  defp parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} ->
        datetime

      _ ->
        case NaiveDateTime.from_iso8601(String.replace(value, " ", "T") <> "Z") do
          {:ok, naive} -> DateTime.from_naive!(naive, "Etc/UTC")
          _ -> nil
        end
    end
  end

  defp parse_datetime(_value), do: nil

  defp perform_request(method, path, params, body, settings) do
    with {:ok, request_method} <- request_method(method),
         {:ok, response} <- do_req(request_method, path, params, body, settings) do
      case response.status do
        status when status in 200..299 ->
          {:ok, response.body}

        status ->
          Logger.error("Issue feed request failed status=#{status} path=#{path}")
          {:error, {:issue_feed_api_status, status}}
      end
    end
  end

  defp do_req(method, path, params, body, settings) do
    url = settings.base_url <> path

    request_opts = [
      method: method,
      url: url,
      params: params,
      headers: headers(settings),
      connect_options: [timeout: 30_000]
    ]

    request_opts = if is_nil(body), do: request_opts, else: Keyword.put(request_opts, :json, body)

    case Req.request(request_opts) do
      {:ok, response} -> {:ok, response}
      {:error, reason} -> {:error, {:issue_feed_api_request, reason}}
    end
  end

  defp headers(settings) do
    case settings.api_token do
      token when is_binary(token) and token != "" ->
        [{"authorization", "Bearer " <> token}]

      _ ->
        []
    end
  end

  defp perform_agent_request(method, path, params, body, settings) do
    with {:ok, request_method} <- request_method(method),
         {:ok, response} <- do_req(request_method, path, params, body, settings) do
      {:ok, %{status: response.status, body: response.body}}
    end
  end

  defp request_method(:get), do: {:ok, :get}
  defp request_method(:post), do: {:ok, :post}
  defp request_method(:patch), do: {:ok, :patch}
  defp request_method(:put), do: {:ok, :put}
  defp request_method(:delete), do: {:ok, :delete}
  defp request_method("GET"), do: {:ok, :get}
  defp request_method("POST"), do: {:ok, :post}
  defp request_method("PATCH"), do: {:ok, :patch}
  defp request_method("PUT"), do: {:ok, :put}
  defp request_method("DELETE"), do: {:ok, :delete}
  defp request_method(_other), do: {:error, :invalid_issue_feed_method}

  defp settings(tracker_settings) when is_map(tracker_settings) do
    provider = provider_settings(tracker_settings)

    base_url =
      resolve_setting(provider["base_url"], tracker_settings.endpoint) ||
        resolve_setting(nil, System.get_env("TRACKER_BASE_URL")) ||
        @default_base_url

    project =
      resolve_setting(provider["project"], tracker_settings.project_slug) ||
        resolve_setting(nil, System.get_env("TRACKER_PROJECT"))

    api_token =
      resolve_setting(provider["api_token"], System.get_env("TRACKER_API_TOKEN"))

    poll_label = normalize_poll_label(provider["poll_label"])

    cond do
      not valid_base_url?(base_url) -> {:error, :invalid_issue_feed_base_url}
      not present_string?(project) -> {:error, :missing_issue_feed_project}
      true ->
        {:ok,
         %{
           base_url: String.trim_trailing(base_url, "/"),
           project: project,
           api_token: api_token,
           poll_label: poll_label
         }}
    end
  end

  defp normalize_poll_label(nil), do: ""
  defp normalize_poll_label(""), do: ""
  defp normalize_poll_label(label) when is_binary(label), do: String.trim(label)
  defp normalize_poll_label(_), do: ""

  defp provider_settings(%{provider: provider}) when is_map(provider), do: provider
  defp provider_settings(_tracker_settings), do: %{}

  defp resolve_setting(nil, fallback), do: normalize_string(fallback)

  defp resolve_setting("$" <> env_name, fallback) do
    if valid_env_name?(env_name) do
      normalize_string(System.get_env(env_name) || fallback)
    else
      nil
    end
  end

  defp resolve_setting(value, _fallback), do: normalize_string(value)

  defp normalize_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_string(_value), do: nil

  defp presence_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp presence_string(value) when is_integer(value), do: Integer.to_string(value)
  defp presence_string(_value), do: nil

  defp present_string?(value) when is_binary(value), do: String.trim(value) != ""
  defp present_string?(_value), do: false

  defp normalize_state(state) when is_binary(state) do
    state |> String.trim() |> String.downcase()
  end

  defp normalize_state(_state), do: ""

  defp valid_base_url?(url) when is_binary(url) do
    case URI.parse(String.trim(url)) do
      %URI{scheme: scheme, host: host} when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        true

      _ ->
        false
    end
  end

  defp valid_base_url?(_url), do: false

  defp env_reference_names(values) when is_list(values) do
    values
    |> Enum.flat_map(fn
      "$" <> env_name when is_binary(env_name) ->
        if valid_env_name?(env_name), do: [env_name], else: []

      _ ->
        []
    end)
  end

  defp valid_env_name?(name) when is_binary(name) do
    name != "" and Regex.match?(~r/^[A-Za-z_][A-Za-z0-9_]*$/, name)
  end

  defp assignee_match_value(%{"assignee" => assignee}) when is_binary(assignee),
    do: normalize_assignee_match_value(assignee)

  defp assignee_match_value(%{"assignee" => %{"id" => id}}) when is_binary(id),
    do: normalize_assignee_match_value(id)

  defp assignee_match_value(%{"assignee" => %{"login" => login}}) when is_binary(login),
    do: normalize_assignee_match_value(login)

  defp assignee_match_value(%{"assignee_id" => assignee_id}),
    do: normalize_assignee_match_value(assignee_id)

  defp assignee_match_value(_issue), do: nil

  defp branch_name_field(%{"branch_name" => branch}) when is_binary(branch) do
    case String.trim(branch) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp branch_name_field(_issue), do: nil

  defp extract_blockers(%{"blocked_by" => blockers}) when is_list(blockers) do
    blockers
    |> Enum.flat_map(fn
      %{} = blocker ->
        id = blocker["id"] |> presence_string()
        identifier = blocker["identifier"] |> presence_string()
        state = blocker["state"] |> presence_string()

        if Enum.all?([id, identifier, state], &present_string?/1) do
          [%{id: id, identifier: identifier, state: state}]
        else
          []
        end

      _ ->
        []
    end)
  end

  defp extract_blockers(_issue), do: []

  defp dispatchable?(state_name, blockers, assignee_match, assignee_filter) do
    assigned_to_worker?(assignee_match, assignee_filter) and
      not blocked_before_dispatch?(state_name, blockers)
  end

  defp blocked_before_dispatch?(state_name, blockers)
       when is_binary(state_name) and is_list(blockers) do
    normalize_state(state_name) == "todo" and
      Enum.any?(blockers, fn
        %{state: blocker_state} when is_binary(blocker_state) ->
          not terminal_state?(blocker_state)

        _ ->
          true
      end)
  end

  defp blocked_before_dispatch?(_state_name, _blockers), do: false

  defp terminal_state?(state_name) when is_binary(state_name) do
    terminal_states =
      Config.settings!().tracker.terminal_states
      |> Enum.map(&normalize_state/1)
      |> MapSet.new()

    MapSet.member?(terminal_states, normalize_state(state_name))
  end

  defp assigned_to_worker?(_assignee_match, nil), do: true

  defp assigned_to_worker?(assignee_match, %{match_values: match_values})
       when is_struct(match_values, MapSet) do
    case assignee_match do
      nil ->
        false

      value ->
        MapSet.member?(match_values, value)
    end
  end

  defp assigned_to_worker?(_assignee_match, _assignee_filter), do: false

  defp routing_assignee_filter do
    case Config.settings!().tracker.assignee do
      nil ->
        {:ok, nil}

      assignee ->
        build_assignee_filter(assignee)
    end
  end

  defp build_assignee_filter(assignee) when is_binary(assignee) do
    case normalize_assignee_match_value(assignee) do
      nil ->
        {:ok, nil}

      "me" ->
        resolve_me_assignee_filter()

      normalized ->
        {:ok, %{configured_assignee: assignee, match_values: MapSet.new([normalized])}}
    end
  end

  defp resolve_me_assignee_filter do
    case normalize_assignee_match_value(System.get_env("TRACKER_ASSIGNEE")) do
      nil ->
        {:error, :missing_issue_feed_assignee}

      normalized ->
        {:ok, %{configured_assignee: "me", match_values: MapSet.new([normalized])}}
    end
  end

  defp normalize_assignee_match_value(value) when is_binary(value) do
    case value |> String.trim() |> String.downcase() do
      "" -> nil
      normalized -> normalized
    end
  end

  defp normalize_assignee_match_value(_value), do: nil

  defp parse_priority(priority) when is_integer(priority) and priority in 1..4, do: priority
  defp parse_priority(_priority), do: nil
end
