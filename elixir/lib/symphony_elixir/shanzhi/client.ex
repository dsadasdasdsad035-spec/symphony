defmodule SymphonyElixir.Shanzhi.Client do
  @moduledoc """
  善治（SF 软件工厂）Bug 平台的 HTTP 客户端。

  对齐 `shanzhi_mcp/sf_client.py` 的实际行为：

    * 用手机号 + 密码登录换 JWT，之后所有请求都带一组前端要求的头；
    * 业务成功码是 `800`，`data` 字段才是真正的返回体；
    * token 失效时自动重新登录并重试一次。

  与 Python 版的差异：token 只缓存在进程内（`:persistent_term`），
  不落盘到 `~/.sf-mcp/auth.json`。Symphony 是常驻服务，内存缓存足够，
  少一个存密码派生凭证的文件。

  配置来自 `tracker.provider`，全部支持 `$ENV_VAR` 引用：

      tracker:
        kind: shanzhi
        provider:
          base_url: https://api.gushen.sieiot.com
          username: $SF_USERNAME
          password: $SF_PASSWORD
          product_id: 419
          project_id: 428
          dep_id: "491919451030089984"
  """

  require Logger

  alias SymphonyElixir.Config
  alias SymphonyElixir.Tracker.Issue

  @default_base_url "https://api.gushen.sieiot.com"
  @default_dep_id "491919451030089984"
  @success_code 800
  @page_size 100
  @max_pages 20
  # 列表接口不一定回填描述，缺字段时按需补详情；并发拉取但限制并发数，
  # 避免一次轮询打爆善治接口。
  @detail_concurrency 6
  @detail_timeout_ms 20_000
  # 列表接口不回填 steps，需要逐条取详情。Bug 描述极少变，缓存一会，
  # 否则 15s 轮询 × 几十个 Bug 会把善治接口打成筛子。
  @detail_cache_ttl_ms 120_000
  @members_cache_ttl_ms 300_000

  @status_alias %{
    "激活" => "active",
    "激活中" => "active",
    "未解决" => "active",
    "已解决" => "resolved",
    "待验证" => "resolved",
    "已关闭" => "closed",
    "关闭" => "closed",
    "已挂起" => "suspended",
    "挂起" => "suspended"
  }

  @type settings :: %{
          base_url: String.t(),
          username: String.t(),
          password: String.t(),
          product_id: integer(),
          project_id: integer() | nil,
          dep_id: String.t() | nil,
          system_code: String.t(),
          menu_id: String.t(),
          menu_url: String.t(),
          page_name: String.t(),
          web_url: String.t() | nil,
          assignee: String.t() | nil,
          require_confirmed: boolean()
        }

  # ---------------------------------------------------------------- 配置

  @spec validate_settings(map()) :: :ok | {:error, term()}
  def validate_settings(tracker_settings) do
    with {:ok, _settings} <- settings(tracker_settings), do: :ok
  end

  @spec secret_environment_names(map()) :: [String.t()]
  def secret_environment_names(tracker_settings) do
    provider = provider_settings(tracker_settings)

    ["SF_PASSWORD" | env_reference_names([provider["password"]])]
    |> Enum.uniq()
  end

  @spec settings(map()) :: {:ok, settings()} | {:error, term()}
  def settings(tracker_settings) when is_map(tracker_settings) do
    provider = provider_settings(tracker_settings)
    base_url = resolve_setting(provider["base_url"], System.get_env("SF_BASE_URL")) || @default_base_url
    username = resolve_setting(provider["username"], System.get_env("SF_USERNAME"))
    password = resolve_setting(provider["password"], System.get_env("SF_PASSWORD"))
    product_id = resolve_integer(provider["product_id"], System.get_env("SF_PRODUCT_ID"))

    cond do
      not valid_url?(base_url) ->
        {:error, :invalid_shanzhi_base_url}

      is_nil(username) ->
        {:error, :missing_shanzhi_username}

      is_nil(password) ->
        {:error, :missing_shanzhi_password}

      is_nil(product_id) ->
        {:error, :missing_shanzhi_product_id}

      true ->
        {:ok,
         %{
           base_url: String.trim_trailing(base_url, "/"),
           username: username,
           password: password,
           product_id: product_id,
           project_id: resolve_integer(provider["project_id"], System.get_env("SF_PROJECT_ID")),
           dep_id: resolve_setting(provider["dep_id"], System.get_env("SF_DEP_ID")) || @default_dep_id,
           system_code: resolve_setting(provider["system_code"], nil) || "governance",
           menu_id: resolve_setting(provider["menu_id"], nil) || "358311202",
           menu_url: resolve_setting(provider["menu_url"], nil) || "/cooperation/bug",
           page_name: resolve_setting(provider["page_name"], nil) || "Bug管理",
           web_url: resolve_setting(provider["web_url"], System.get_env("SF_WEB_URL")),
           assignee: resolve_setting(provider["assignee"], System.get_env("SF_ASSIGNEE")),
           require_confirmed: resolve_boolean(provider["require_confirmed"], true)
         }}
    end
  end

  def settings(_tracker_settings), do: {:error, :invalid_shanzhi_settings}

  # 公开 API 既接受 workflow 的 tracker 配置，也接受已解析的 settings。
  # 前者含 `provider`，后者含 `base_url`，据此区分，避免内部调用重复解析。
  defp ensure_settings(%{provider: _provider} = tracker_settings), do: settings(tracker_settings)

  defp ensure_settings(%{base_url: base_url} = settings) when is_binary(base_url), do: {:ok, settings}

  defp ensure_settings(other), do: settings(other)

  # ---------------------------------------------------------------- 查询

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_states(state_names) when is_list(state_names) do
    fetch_issues_by_states(state_names, Config.settings!().tracker)
  end

  @spec fetch_issues_by_states([String.t()], map()) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_states(state_names, tracker_settings) do
    statuses = state_names |> Enum.map(&normalize_status/1) |> Enum.reject(&is_nil/1) |> Enum.uniq()

    with {:ok, settings} <- settings(tracker_settings) do
      case statuses do
        [] ->
          {:ok, []}

        statuses ->
          with {:ok, rows} <- collect_rows(settings, statuses, 1, []) do
            {:ok, rows_to_issues(settings, rows)}
          end
      end
    end
  end

  @spec fetch_issues_by_ids([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_ids(issue_ids) when is_list(issue_ids) do
    fetch_issues_by_ids(issue_ids, Config.settings!().tracker)
  end

  @spec fetch_issues_by_ids([String.t()], map()) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_ids(issue_ids, tracker_settings) do
    ids =
      issue_ids
      |> Enum.map(&to_bug_id/1)
      |> Enum.flat_map(fn
        {:ok, id} -> [id]
        _error -> []
      end)
      |> Enum.uniq()

    with {:ok, settings} <- settings(tracker_settings) do
      case ids do
        [] ->
          {:ok, []}

        ids ->
          results = Enum.map(ids, &fetch_one_issue(settings, &1))

          case Enum.find(results, &match?({:error, _}, &1)) do
            nil ->
              {:ok,
               Enum.flat_map(results, fn
                 {:ok, issue} -> [issue]
                 :skip -> []
               end)}

            error ->
              error
          end
      end
    end
  end

  defp collect_rows(_settings, _statuses, page, acc) when page > @max_pages, do: {:ok, Enum.reverse(acc)}

  defp collect_rows(settings, statuses, page, acc) do
    with {:ok, payload} <- find_page(settings, statuses, page) do
      rows = list_rows(payload)
      total = if is_map(payload), do: integer_or_zero(payload["count"]), else: 0
      fetched = length(acc) + length(rows)

      acc = Enum.reverse(rows, acc)

      cond do
        rows == [] ->
          {:ok, Enum.reverse(acc)}

        fetched >= total ->
          {:ok, Enum.reverse(acc)}

        length(rows) < @page_size ->
          {:ok, Enum.reverse(acc)}

        true ->
          collect_rows(settings, statuses, page + 1, acc)
      end
    end
  end

  # 善治的「确认」是 Bug 上的独立布尔字段（不是状态）。未确认的 Bug 通常是
  # 待评审的原始反馈，不该直接开工，所以在读取层就滤掉。
  defp rows_to_issues(settings, rows) do
    rows
    |> Enum.filter(&dispatchable_row?(&1, settings))
    |> enrich_and_normalize(settings)
  end

  defp dispatchable_row?(row, %{require_confirmed: false}), do: is_map(row)

  defp dispatchable_row?(row, _settings) when is_map(row), do: confirmed?(row["confirmed"])
  defp dispatchable_row?(_row, _settings), do: false

  @doc false
  def confirmed?(value) when value in [true, 1], do: true
  def confirmed?("true"), do: true
  def confirmed?("True"), do: true
  def confirmed?("是"), do: true
  def confirmed?("Y"), do: true
  def confirmed?("y"), do: true
  def confirmed?(_value), do: false

  # 列表接口不一定回填 `steps`；缺失时按需补详情，否则 prompt 里没有复现步骤。
  # 并发补，并保证任何一个请求失败/超时都退回原始行，不丢候选。
  defp enrich_and_normalize(rows, settings) do
    enriched =
      rows
      |> Enum.with_index()
      |> Task.async_stream(
        fn {row, index} -> {index, enrich_row(settings, row)} end,
        max_concurrency: @detail_concurrency,
        timeout: @detail_timeout_ms,
        on_timeout: :kill_task,
        ordered: false
      )
      |> Enum.reduce(%{}, fn
        {:ok, {index, row}}, acc -> Map.put(acc, index, row)
        _failed, acc -> acc
      end)

    rows
    |> Enum.with_index()
    |> Enum.map(fn {row, index} -> Map.get(enriched, index, row) end)
    |> Enum.reject(fn
      %{"id" => nil} -> true
      row when not is_map(row) -> true
      _row -> false
    end)
    |> Enum.map(&normalize_issue(&1, settings))
    |> Enum.reject(fn
      %Issue{title: title} when not is_binary(title) -> true
      _issue -> false
    end)
  end

  defp enrich_row(_settings, row) when not is_map(row), do: row

  defp enrich_row(settings, row) do
    if present?(row["steps"]) do
      row
    else
      case cached_detail(settings, row["id"]) do
        nil ->
          case get_bug(row["id"], settings) do
            {:ok, detail} when is_map(detail) ->
              cache_detail(settings, row["id"], detail)
              Map.merge(row, detail)

            _error ->
              row
          end

        detail ->
          Map.merge(row, detail)
      end
    end
  end

  defp detail_cache_key(settings, bug_id),
    do: {__MODULE__, :bug_detail, settings.base_url, to_string(bug_id)}

  defp cached_detail(settings, bug_id) do
    case :persistent_term.get(detail_cache_key(settings, bug_id), nil) do
      {detail, expires_at} ->
        if System.monotonic_time(:millisecond) < expires_at, do: detail, else: nil

      nil ->
        nil
    end
  end

  defp cache_detail(settings, bug_id, detail) do
    :persistent_term.put(
      detail_cache_key(settings, bug_id),
      {detail, System.monotonic_time(:millisecond) + @detail_cache_ttl_ms}
    )
  end

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(_value), do: false

  defp find_page(settings, statuses, page) do
    with {:ok, params} <- build_params(settings, statuses) do
      body = %{
        "orderByBean" => %{"attributeName" => "id", "sortType" => "desc"},
        "pageIndex" => page,
        "pageRows" => @page_size,
        "params" => params
      }

      request("POST", "/iot-zt/zt-bug/find-page-list", body, settings)
    end
  end

  defp build_params(settings, statuses) do
    params =
      %{
        "productId" => settings.product_id,
        "depId" => settings.dep_id,
        "statusList" => statuses
      }
      |> reject_nil_values()

    case settings.assignee do
      nil ->
        {:ok, params}

      assignee ->
        with {:ok, mobile} <- resolve_assignee_mobile(settings, assignee) do
          {:ok, Map.put(params, "assignedToList", [mobile])}
        end
    end
  end

  # 可选：只处理指派给某人的 Bug。姓名会先换成接口要求的手机号。
  defp resolve_assignee_mobile(settings, person) do
    person = String.trim(person)

    cond do
      person == "" ->
        {:ok, nil}

      mobile?(person) ->
        {:ok, person}

      true ->
        with {:ok, members} <- members(settings) do
          match_member(members, person)
        end
    end
  end

  defp match_member(members, person) do
    exact =
      Enum.filter(members, fn member ->
        member["psnName"] == person or member["loginAccount"] == person
      end)

    matches =
      if exact == [] do
        Enum.filter(members, fn member ->
          String.contains?(to_string(member["psnName"]), person) or
            String.contains?(to_string(member["loginAccount"]), person)
        end)
      else
        exact
      end

    case matches do
      [%{"mobile" => mobile} | _rest] when is_binary(mobile) and mobile != "" ->
        {:ok, mobile}

      [] ->
        {:error, {:shanzhi_unknown_person, person}}

      _ambiguous ->
        {:error, {:shanzhi_ambiguous_person, person}}
    end
  end

  defp members(settings) do
    key = {__MODULE__, :members, settings.base_url, settings.dep_id}
    now = System.monotonic_time(:millisecond)

    case :persistent_term.get(key, nil) do
      {members, expires_at} when now < expires_at ->
        {:ok, members}

      _stale ->
        with {:ok, rows} <- fetch_members(settings) do
          :persistent_term.put(key, {rows, now + @members_cache_ttl_ms})
          {:ok, rows}
        end
    end
  end

  defp fetch_members(settings) do
    body = %{
      "pageIndex" => 1,
      "pageRows" => 1000,
      "params" => %{"depId" => settings.dep_id}
    }

    case request("POST", "/api/base/base-person/find-pagination-dept-sf", body, settings) do
      {:ok, payload} -> {:ok, list_rows(payload)}
      error -> error
    end
  end

  defp mobile?(value) when is_binary(value), do: String.match?(value, ~r/^\d{11}$/)
  defp mobile?(_value), do: false

  defp fetch_one_issue(settings, bug_id) do
    case get_bug(bug_id, settings) do
      {:ok, %{} = bug} ->
        # 未确认时返回 :skip 而不是错误：orchestrator 只在列表里"看不见"该 issue
        # 时才会终止正在跑的 agent；返回错误反而会保留 worker。
        if dispatchable_row?(bug, settings), do: {:ok, normalize_issue(bug, settings)}, else: :skip

      {:ok, other} ->
        {:error, {:shanzhi_unexpected_bug_payload, other}}

      error ->
        error
    end
  end

  @spec get_bug(term(), map()) :: {:ok, map()} | {:error, term()}
  def get_bug(bug_id, tracker_or_settings) do
    with {:ok, settings} <- ensure_settings(tracker_or_settings),
         {:ok, id} <- to_bug_id(bug_id) do
      case request("GET", "/iot-zt/zt-bug/get-by-id", %{"id" => id}, settings) do
        {:ok, %{} = bug} -> {:ok, bug}
        {:ok, other} -> {:error, {:shanzhi_unexpected_bug_payload, other}}
        error -> error
      end
    end
  end

  @spec bug_history(term(), map()) :: {:ok, [map()]} | {:error, term()}
  def bug_history(bug_id, tracker_or_settings) do
    with {:ok, settings} <- ensure_settings(tracker_or_settings),
         {:ok, id} <- to_bug_id(bug_id) do
      case request("GET", "/iot-zt/sfActionController/getActionById", %{"ObjectId" => id, "ObjectName" => "bug"}, settings) do
        {:ok, rows} when is_list(rows) -> {:ok, rows}
        {:ok, _other} -> {:ok, []}
        error -> error
      end
    end
  end

  # ---------------------------------------------------------------- 写入

  @doc """
  确认 Bug，把「确认」字段置为是。

  善治接口要求 `params` 必须带 `assignedTo`，缺省会静默不生效（返回成功但字段不变），
  所以这里显式沿用 Bug 当前的指派人，没有再退回登录账号。
  """
  @spec confirm_bug(term(), String.t() | nil, String.t(), map()) :: {:ok, map()} | {:error, term()}
  def confirm_bug(bug_id, assignee, comment, tracker_or_settings) do
    with {:ok, settings} <- ensure_settings(tracker_or_settings),
         {:ok, bug} <- get_bug(bug_id, settings),
         {:ok, id} <- to_bug_id(bug["id"] || bug_id) do
      with {:ok, mobile} <- confirm_assignee(settings, assignee, bug, id) do
        payload =
          %{"id" => id, "confirmed" => true, "assignedTo" => mobile}
          |> maybe_put_comment(comment)

        case request("POST", "/iot-zt/zt-bug/confirmBug", %{"params" => payload}, settings) do
          {:ok, _} ->
            {:ok,
             %{
               "id" => id,
               "confirmed" => true,
               "assignee" => mobile,
               "comment" => comment || "",
               "msg" => "确认成功"
             }}

          error ->
            error
        end
      end
    end
  end

  defp confirm_assignee(settings, assignee, bug, _id) do
    cond do
      present?(assignee) ->
        with {:ok, mobile} <- resolve_assignee_mobile(settings, assignee) do
          {:ok, mobile}
        end

      present?(bug["assignedTo"]) ->
        {:ok, bug["assignedTo"]}

      true ->
        # 善治的登录账号本身就是手机号，兜底用它。
        {:ok, settings.username}
    end
  end

  defp maybe_put_comment(payload, comment) do
    if present?(comment), do: Map.put(payload, "comment", comment), else: payload
  end

  @spec remark_bug(term(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  def remark_bug(bug_id, comment, tracker_or_settings) when is_binary(comment) do
    if String.trim(comment) == "" do
      {:error, :empty_comment}
    else
      with {:ok, settings} <- ensure_settings(tracker_or_settings),
           {:ok, bug} <- get_bug(bug_id, settings) do
        # 善治没有独立备注接口：前端是「取详情 -> 改 comment -> 全量提交」，
        # 备注会写进操作历史。
        payload = bug |> Map.put("comment", comment) |> Map.put("id", bug["id"] || bug_id)

        case request("POST", "/iot-zt/zt-bug/update-bug", %{"params" => payload}, settings) do
          {:ok, _} -> {:ok, %{"id" => bug["id"] || bug_id, "comment" => comment, "msg" => "备注成功"}}
          error -> error
        end
      end
    end
  end

  @spec resolve_bug(term(), String.t(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  def resolve_bug(bug_id, resolution, comment, tracker_or_settings) do
    with {:ok, settings} <- ensure_settings(tracker_or_settings),
         {:ok, bug} <- get_bug(bug_id, settings),
         {:ok, id} <- to_bug_id(bug["id"] || bug_id) do
      resolved_date = Calendar.strftime(DateTime.utc_now(), "%Y-%m-%d %H:%M:%S")

      payload =
        %{
          "id" => id,
          "assignedTo" => bug["assignedTo"] || "",
          "environment" => bug["environment"] || "test",
          "resolvedDate" => resolved_date,
          "resolution" => normalize_resolution(resolution),
          "comment" => comment || "",
          "sfProjectId" => bug["project"],
          "resolvedAttachUrl" => "",
          "status" => "resolved"
        }

      case request("POST", "/iot-zt/zt-bug/resolveBug", %{"params" => payload}, settings) do
        {:ok, _} ->
          {:ok,
           %{
             "id" => id,
             "status" => "resolved",
             "resolution" => payload["resolution"],
             "resolved_date" => resolved_date,
             "msg" => "解决成功"
           }}

        error ->
          error
      end
    end
  end

  # ---------------------------------------------------------------- 请求与鉴权

  @spec request(String.t(), String.t(), term(), settings()) :: {:ok, term()} | {:error, term()}
  def request(method, path, payload, settings) do
    do_request(method, path, payload, settings, true)
  end

  defp do_request(method, path, payload, settings, retry?) do
    with {:ok, token} <- fetch_token(settings),
         {:ok, response} <- send_request(method, path, payload, settings, token) do
      case decode(response) do
        {:ok, data} ->
          {:ok, data}

        {:error, :auth} when retry? ->
          Logger.info("善治 token 失效，重新登录后重试 path=#{path}")
          clear_token(settings)
          do_request(method, path, payload, settings, false)

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp send_request(method, path, payload, settings, token) do
    url = settings.base_url <> path
    headers = request_headers(token, settings)

    opts =
      [headers: headers, connect_options: [timeout: 30_000], receive_timeout: 60_000]
      |> Keyword.merge(method_opts(method, payload))

    case http_request(Keyword.put(opts, :url, url) |> Keyword.put(:method, method_atom(method))) do
      {:ok, response} -> {:ok, %{status: response.status, body: response.body}}
      {:error, reason} -> {:error, {:shanzhi_request_failed, reason}}
    end
  end

  # 统一入口：测试注入 `:shanzhi_http_client`（实现 request/1）即可替换网络层。
  defp http_request(opts) do
    http_client = Application.get_env(:symphony_elixir, :shanzhi_http_client, Req)

    if Code.ensure_loaded?(http_client) and function_exported?(http_client, :request, 1) do
      http_client.request(opts)
    else
      {:error, :shanzhi_http_client_missing}
    end
  end

  defp method_opts("GET", payload), do: [params: payload || %{}]
  defp method_opts(_method, payload), do: [json: payload || %{}]

  defp method_atom("GET"), do: :get
  defp method_atom(_method), do: :post

  defp request_headers(token, settings) do
    [
      {"Content-Type", "application/json;charset=utf-8"},
      {"Accept", "application/json, text/plain, */*"},
      {"authorization", token},
      {"refresh-authorization", token},
      {"language", "zh#CN"},
      {"systemCode", b64(settings.system_code)},
      {"menuId", settings.menu_id},
      {"pageName", b64(settings.page_name)},
      {"requestMenuUrl", b64(settings.menu_url)}
    ]
  end

  defp fetch_token(settings) do
    case :persistent_term.get(token_key(settings), nil) do
      token when is_binary(token) and token != "" -> {:ok, token}
      _ -> login(settings)
    end
  end

  defp login(settings) do
    # 并发轮询时只允许一个进程真正登录，其余复用结果。
    result =
      :global.trans({__MODULE__, settings.username}, fn ->
        case :persistent_term.get(token_key(settings), nil) do
          token when is_binary(token) and token != "" -> {:ok, token}
          _ -> do_login(settings)
        end
      end)

    case result do
      {:aborted, reason} -> {:error, {:shanzhi_login_aborted, reason}}
      other -> other
    end
  end

  defp do_login(settings) do
    body = %{
      "params" => %{
        "requestData" => %{
          "username" => settings.username,
          "password" => settings.password,
          "loginFrom" => "PC",
          "loginType" => 1,
          "systemCode" => settings.system_code,
          "validatorCode" => "",
          "captcha" => "",
          "encryption" => "RSA"
        }
      }
    }

    case http_request(
           method: :post,
           url: settings.base_url <> "/api/base/base-user/login",
           json: body,
           headers: [{"Content-Type", "application/json"}],
           connect_options: [timeout: 30_000],
           receive_timeout: 60_000
         ) do
      {:ok, %{status: status, body: payload}} when status in 200..299 ->
        case payload do
          %{"code" => @success_code, "data" => %{"authorization" => token}} when is_binary(token) ->
            :persistent_term.put(token_key(settings), token)
            {:ok, token}

          %{"code" => code, "msg" => msg} ->
            {:error, {:shanzhi_login_failed, code, msg}}

          other ->
            {:error, {:shanzhi_login_failed, other}}
        end

      {:ok, %{status: status}} ->
        {:error, {:shanzhi_login_http_status, status}}

      {:error, reason} ->
        {:error, {:shanzhi_login_request_failed, reason}}
    end
  end

  defp clear_token(settings), do: :persistent_term.erase(token_key(settings))

  defp token_key(settings), do: {__MODULE__, :token, settings.base_url, settings.username}

  @doc false
  # 供测试清理缓存的 token
  def clear_cached_token(settings), do: clear_token(settings)

  defp decode(%{status: 401}), do: {:error, :auth}
  defp decode(%{status: 403}), do: {:error, :auth}
  defp decode(%{status: status}) when status not in 200..299, do: {:error, {:shanzhi_http_status, status}}

  defp decode(%{body: %{"code" => @success_code, "data" => data}}), do: {:ok, data}

  defp decode(%{body: %{"code" => code} = payload}) when code in [401, 403] do
    Logger.info("善治返回鉴权失败 code=#{inspect(code)} msg=#{inspect(payload["msg"])}")
    {:error, :auth}
  end

  defp decode(%{body: %{"code" => code, "msg" => msg} = payload}) do
    if auth_error_message?(msg) do
      Logger.info("善治返回鉴权失败 code=#{inspect(code)} msg=#{inspect(msg)}")
      {:error, :auth}
    else
      {:error, {:shanzhi_api_error, code, msg, payload}}
    end
  end

  defp decode(%{body: %{} = body}), do: {:ok, body}
  defp decode(%{body: body}), do: {:error, {:shanzhi_unexpected_payload, body}}

  defp auth_error_message?(msg) when is_binary(msg) do
    downcased = String.downcase(msg)
    String.contains?(downcased, "token") or String.contains?(msg, "登录")
  end

  defp auth_error_message?(_msg), do: false

  # ---------------------------------------------------------------- 归一化

  @doc false
  def normalize_issue(%{} = bug, %{} = settings) do
    bug_id = bug["id"]

    %Issue{
      id: to_string(bug_id),
      identifier: identifier(bug_id),
      title: bug["title"],
      description: description(bug),
      priority: integer_or_nil(bug["pri"]),
      state: normalize_status(bug["status"]),
      url: issue_url(settings, bug_id),
      assignee_id: bug["assignedToName"] || bug["assignedTo"],
      labels: issue_labels(bug),
      blocked_by: [],
      dispatchable: true,
      created_at: parse_datetime(bug["openedDate"]),
      updated_at: parse_datetime(bug["lastEditedDate"] || bug["editedDate"] || bug["openedDate"])
    }
  end

  @doc false
  def identifier(nil), do: nil
  def identifier(bug_id), do: "SF-#{bug_id}"

  @doc false
  def normalize_status(status) when is_binary(status) do
    trimmed = String.trim(status)

    case Map.get(@status_alias, trimmed) || trimmed do
      "" -> nil
      value -> String.downcase(value)
    end
  end

  def normalize_status(_status), do: nil

  @doc false
  def normalize_resolution(resolution) when is_binary(resolution) do
    case resolution |> String.trim() |> String.downcase() do
      "" -> "fixed"
      "已解决" -> "fixed"
      "设计如此" -> "bydesign"
      "重复" -> "duplicate"
      "重复bug" -> "duplicate"
      "无法重现" -> "notrepro"
      "延期处理" -> "postponed"
      "不予处理" -> "willnotfix"
      "外部原因" -> "external"
      "转为需求" -> "tostory"
      other -> other
    end
  end

  def normalize_resolution(_resolution), do: "fixed"

  defp description(bug) do
    steps = bug["steps"]
    comment = bug["comment"]

    meta =
      [
        {"严重程度", bug["severity"]},
        {"优先级", bug["pri"]},
        {"类型", bug["type"]},
        {"环境", bug["environment"]},
        {"模块", bug["modulePath"] || bug["module"]},
        {"提交人", bug["openedByName"]},
        {"所属项目", bug["productName"] || bug["projectName"]}
      ]
      |> Enum.reject(fn {_key, value} -> is_nil(value) or value == "" end)
      |> Enum.map_join("\n", fn {key, value} -> "- #{key}: #{value}" end)

    [
      if(meta == "", do: nil, else: "## 基本信息\n\n" <> meta),
      section("复现步骤", steps),
      section("备注", comment)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n\n")
  end

  defp section(_title, value) when value in [nil, ""], do: nil
  defp section(title, value), do: "## #{title}\n\n#{value}"

  defp issue_url(%{web_url: nil}, _bug_id), do: nil

  defp issue_url(%{web_url: web_url}, bug_id),
    do: "#{String.trim_trailing(web_url, "/")}/cooperation/bug?id=#{bug_id}"

  defp issue_labels(bug) do
    [
      label("type", bug["type"]),
      label("severity", bug["severity"]),
      label("pri", bug["pri"]),
      label("env", bug["environment"]),
      label("resolution", bug["resolution"])
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp label(_prefix, value) when value in [nil, ""], do: nil

  defp label(prefix, value) do
    "#{prefix}:" <> (value |> to_string() |> String.trim() |> String.downcase())
  end

  defp list_rows(%{"data" => rows}) when is_list(rows), do: rows
  defp list_rows(rows) when is_list(rows), do: rows
  defp list_rows(_payload), do: []

  # ---------------------------------------------------------------- 小工具

  defp b64(text), do: Base.encode64(to_string(text), padding: true)

  defp to_bug_id(%{id: id}), do: to_bug_id(id)

  defp to_bug_id(id) when is_integer(id), do: {:ok, id}

  defp to_bug_id(id) when is_binary(id) do
    case Integer.parse(String.trim(id)) do
      {parsed, ""} -> {:ok, parsed}
      _ -> {:error, {:invalid_shanzhi_bug_id, id}}
    end
  end

  defp to_bug_id(other), do: {:error, {:invalid_shanzhi_bug_id, other}}

  defp parse_datetime(value) when is_binary(value) do
    value = String.trim(value)

    cond do
      value == "" ->
        nil

      match?({:ok, _datetime, _offset}, DateTime.from_iso8601(value)) ->
        {:ok, datetime, _offset} = DateTime.from_iso8601(value)
        datetime

      match?({:ok, _naive}, NaiveDateTime.from_iso8601(value)) ->
        {:ok, naive} = NaiveDateTime.from_iso8601(value)
        DateTime.from_naive!(naive, "Etc/UTC")

      true ->
        # 善治部分字段是 "2026-11-12 10:30:00" 这种空格分隔格式
        case NaiveDateTime.from_iso8601(String.replace(value, " ", "T", global: false)) do
          {:ok, naive} -> DateTime.from_naive!(naive, "Etc/UTC")
          _ -> nil
        end
    end
  rescue
    _ -> nil
  end

  defp parse_datetime(_value), do: nil

  defp integer_or_zero(value) when is_integer(value), do: value

  defp integer_or_zero(value) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, _} -> parsed
      _ -> 0
    end
  end

  defp integer_or_zero(_value), do: 0

  defp integer_or_nil(value) when is_integer(value), do: value

  defp integer_or_nil(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, _} -> parsed
      _ -> nil
    end
  end

  defp integer_or_nil(_value), do: nil

  defp reject_nil_values(map) do
    Map.reject(map, fn {_key, value} -> is_nil(value) or value == "" end)
  end

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

  defp resolve_integer(value, _fallback) when is_binary(value) do
    case String.trim(value) do
      "" ->
        nil

      trimmed ->
        case Integer.parse(trimmed) do
          {parsed, ""} -> parsed
          # 显式配了非法值就报错，不要悄悄退回环境变量
          _ -> nil
        end
    end
  end

  defp resolve_integer(value, _fallback) when is_integer(value), do: value

  defp resolve_integer(nil, fallback) when is_binary(fallback) do
    case Integer.parse(String.trim(fallback)) do
      {parsed, ""} -> parsed
      _ -> nil
    end
  end

  defp resolve_integer(_value, _fallback), do: nil

  defp resolve_boolean(value, default) do
    case value do
      nil -> default
      true -> true
      false -> false
      "true" -> true
      "false" -> false
      other when is_binary(other) -> String.downcase(String.trim(other)) not in ["false", "0", "no", "off"]
      _other -> default
    end
  end

  defp env_reference_names(values) do
    Enum.flat_map(values, fn
      "$" <> env_name -> if valid_env_name?(env_name), do: [env_name], else: []
      _value -> []
    end)
  end

  defp valid_env_name?(name), do: is_binary(name) and String.match?(name, ~r/^[A-Za-z_][A-Za-z0-9_]*$/)

  defp normalize_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_string(_value), do: nil

  defp valid_url?(value) when is_binary(value) do
    case URI.parse(value) do
      %URI{scheme: scheme, host: host} when scheme in ["http", "https"] and is_binary(host) -> true
      _ -> false
    end
  end

  defp valid_url?(_value), do: false
end
