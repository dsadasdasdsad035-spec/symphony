defmodule SymphonyElixir.Shanzhi.AdapterTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Shanzhi.{Adapter, AgentTool, Client}
  alias SymphonyElixir.Tracker.Issue

  @login_url "https://sf.test/api/base/base-user/login"
  @list_url "https://sf.test/iot-zt/zt-bug/find-page-list"
  @detail_url "https://sf.test/iot-zt/zt-bug/get-by-id"
  @resolve_url "https://sf.test/iot-zt/zt-bug/resolveBug"
  @confirm_url "https://sf.test/iot-zt/zt-bug/confirmBug"
  @members_url "https://sf.test/api/base/base-person/find-pagination-dept-sf"

  defmodule FakeHttp do
    @moduledoc false
    # 用 Agent 而不是进程字典：详情补全跑在 Task 里，队列必须跨进程共享。
    @name __MODULE__

    def start do
      stop()
      {:ok, _pid} = Agent.start_link(fn -> %{responses: [], requests: []} end, name: @name)
    end

    def stop do
      case Process.whereis(@name) do
        nil ->
          :ok

        pid ->
          # 队列进程链接在测试进程上，可能已经随测试结束退出，这里只做尽力清理。
          try do
            Agent.stop(pid)
          catch
            :exit, _reason -> :ok
          end
      end
    end

    def push(responses) when is_list(responses) do
      Agent.update(@name, &%{&1 | responses: &1.responses ++ responses})
    end

    def requests, do: Agent.get(@name, &Enum.reverse(&1.requests))

    def request(opts) do
      Agent.get_and_update(@name, fn state ->
        {response, rest} =
          case state.responses do
            [head | tail] -> {head, tail}
            [] -> {default_response(), []}
          end

        {response, %{state | responses: rest, requests: [opts | state.requests]}}
      end)
    end

    defp default_response do
      {:ok, %{status: 200, body: %{"code" => 800, "data" => %{}}}}
    end
  end

  defmodule FakeClient do
    @moduledoc false
    def fetch_issues_by_states(states) do
      send(self(), {:shanzhi_states, states})
      {:ok, []}
    end

    def fetch_issues_by_ids(ids) do
      send(self(), {:shanzhi_ids, ids})
      {:ok, []}
    end
  end

  setup do
    previous = Application.get_env(:symphony_elixir, :shanzhi_http_client)
    previous_client = Application.get_env(:symphony_elixir, :shanzhi_client_module)
    Application.put_env(:symphony_elixir, :shanzhi_http_client, FakeHttp)
    FakeHttp.start()

    on_exit(fn ->
      FakeHttp.stop()

      if is_nil(previous) do
        Application.delete_env(:symphony_elixir, :shanzhi_http_client)
      else
        Application.put_env(:symphony_elixir, :shanzhi_http_client, previous)
      end

      if is_nil(previous_client) do
        Application.delete_env(:symphony_elixir, :shanzhi_client_module)
      else
        Application.put_env(:symphony_elixir, :shanzhi_client_module, previous_client)
      end
    end)

    :ok
  end

  test "adapter validates shanzhi config and rejects unknown states" do
    settings = tracker_settings()

    assert :ok = Adapter.validate_config(settings)

    assert {:error, :missing_shanzhi_active_states} =
             Adapter.validate_config(%{settings | active_states: nil})

    assert {:error, :missing_shanzhi_terminal_states} =
             Adapter.validate_config(%{settings | terminal_states: nil})

    assert {:error, :invalid_shanzhi_states} =
             Adapter.validate_config(%{settings | active_states: ["resolved"]})

    assert {:error, :invalid_shanzhi_states} =
             Adapter.validate_config(%{settings | terminal_states: ["active"]})

    assert {:error, :missing_shanzhi_username} =
             Adapter.validate_config(put_provider(settings, %{"username" => ""}))

    assert {:error, :missing_shanzhi_password} =
             Adapter.validate_config(put_provider(settings, %{"password" => ""}))

    assert {:error, :missing_shanzhi_product_id} =
             Adapter.validate_config(put_provider(settings, %{"product_id" => "not-a-number"}))

    assert {:error, :invalid_shanzhi_base_url} =
             Adapter.validate_config(put_provider(settings, %{"base_url" => "ftp://sf.test"}))
  end

  test "adapter delegates reads to the client module and advertises bug tools" do
    Application.put_env(:symphony_elixir, :shanzhi_client_module, FakeClient)

    assert {:ok, []} = Adapter.fetch_issues_by_states(["active"])
    assert_receive {:shanzhi_states, ["active"]}

    assert {:ok, []} = Adapter.fetch_issues_by_ids(["83204"])
    assert_receive {:shanzhi_ids, ["83204"]}

    assert [
             %{"name" => "shanzhi_get_bug"},
             %{"name" => "shanzhi_bug_history"},
             %{"name" => "shanzhi_confirm_bug"},
             %{"name" => "shanzhi_remark_bug"},
             %{"name" => "shanzhi_resolve_bug"}
           ] = Adapter.agent_tool_specs()

    assert Adapter.active_states() == ["active"]
    assert Adapter.terminal_states() == ["closed"]

    assert "SF_PASSWORD" in Adapter.secret_environment_names(tracker_settings())
  end

  test "fetch_issues_by_states queries active bugs and normalizes them into issues" do
    settings = tracker_settings()
    FakeHttp.push([login_ok(), list_ok([raw_bug(83_204, "active", steps: "<p>复现步骤</p>")])])

    assert {:ok, [%Issue{} = issue]} = Client.fetch_issues_by_states(["active"], settings)

    assert issue.id == "83204"
    assert issue.identifier == "SF-83204"
    assert issue.title == "【对话列表】切换后产物丢失"
    assert issue.state == "active"
    assert issue.priority == 2
    assert issue.assignee_id == "陈昌稳"
    assert issue.dispatchable
    assert issue.description =~ "复现步骤"
    assert issue.url == "http://sf.sieiot.com/cooperation/bug?id=83204"
    assert "severity:2" in issue.labels
    assert "env:test" in issue.labels
    assert issue.attributes == %{"keywords" => ""}

    assert request_urls() == [@login_url, @list_url]

    list_opts = find_request(@list_url)
    assert list_opts[:method] == :post
    assert list_opts[:json]["params"]["productId"] == 419
    assert list_opts[:json]["params"]["depId"] == "491919451030089984"
    assert list_opts[:json]["params"]["statusList"] == ["active"]
  end

  test "fetch_issues_by_states enriches rows that have no steps" do
    settings = tracker_settings()

    FakeHttp.push([
      login_ok(),
      list_ok([raw_bug(83_205, "active")]),
      {:ok,
       %{
         status: 200,
         body: %{"code" => 800, "data" => raw_bug(83_205, "active", steps: "<p>详情里的步骤</p>")}
       }}
    ])

    assert {:ok, [%Issue{} = issue]} = Client.fetch_issues_by_states(["active"], settings)
    assert issue.description =~ "详情里的步骤"

    assert request_urls() == [@login_url, @list_url, @detail_url]
    assert find_request(@detail_url)[:params] == %{"id" => 83_205}
  end

  test "re-logins once and retries when the token expires" do
    settings = tracker_settings()

    FakeHttp.push([
      login_ok(),
      {:ok, %{status: 200, body: %{"code" => 401, "msg" => "token 失效"}}},
      login_ok("fresh-token"),
      list_ok([raw_bug(83_206, "active", steps: "<p>x</p>")])
    ])

    assert {:ok, [%Issue{} = issue]} = Client.fetch_issues_by_states(["active"], settings)
    assert issue.id == "83206"

    urls = request_urls()
    assert Enum.count(urls, &(&1 == @login_url)) == 2
    assert Enum.count(urls, &(&1 == @list_url)) == 2
    assert List.last(urls) == @list_url
  end

  test "fetch_issues_by_ids fetches details by bug id" do
    settings = tracker_settings()

    FakeHttp.push([
      login_ok(),
      {:ok, %{status: 200, body: %{"code" => 800, "data" => raw_bug(83_207, "active", steps: "<p>单条</p>")}}}
    ])

    assert {:ok, [%Issue{} = issue]} = Client.fetch_issues_by_ids(["83207"], settings)
    assert issue.identifier == "SF-83207"

    assert request_urls() == [@login_url, @detail_url]
    assert find_request(@detail_url)[:params] == %{"id" => 83_207}
  end

  test "resolve_bug posts a resolve payload and maps the result" do
    settings = tracker_settings()

    FakeHttp.push([
      login_ok(),
      {:ok, %{status: 200, body: %{"code" => 800, "data" => raw_bug(83_208, "active")}}},
      {:ok, %{status: 200, body: %{"code" => 800, "data" => %{"id" => 83_208}}}}
    ])

    assert {:ok, result} = Client.resolve_bug(83_208, "已解决", "<p>修好了</p>", settings)
    assert result["status"] == "resolved"
    assert result["resolution"] == "fixed"

    assert request_urls() == [@login_url, @detail_url, @resolve_url]

    resolve = find_request(@resolve_url)
    assert resolve[:json]["params"]["id"] == 83_208
    assert resolve[:json]["params"]["status"] == "resolved"
    assert resolve[:json]["params"]["comment"] == "<p>修好了</p>"
  end

  test "remark_bug rejects empty comments before touching the API" do
    assert {:error, :empty_comment} = Client.remark_bug(83_209, "   ", tracker_settings())
    assert FakeHttp.requests() == []
  end

  test "assignee filter resolves a member name to a mobile before querying" do
    settings = tracker_settings(%{"assignee" => "米久业", "dep_id" => unique_dep_id()})

    FakeHttp.push([
      login_ok(),
      members_ok([%{"psnName" => "米久业", "loginAccount" => "mijy", "mobile" => "13900000000"}]),
      list_ok([])
    ])

    assert {:ok, []} = Client.fetch_issues_by_states(["active"], settings)

    assert request_urls() == [@login_url, @members_url, @list_url]
    assert find_request(@list_url)[:json]["params"]["assignedToList"] == ["13900000000"]
  end

  test "assignee filter accepts a mobile directly and fails loudly on unknown names" do
    settings = tracker_settings(%{"assignee" => "13911112222", "dep_id" => unique_dep_id()})
    FakeHttp.push([login_ok(), list_ok([])])

    assert {:ok, []} = Client.fetch_issues_by_states(["active"], settings)
    assert request_urls() == [@login_url, @list_url]
    assert find_request(@list_url)[:json]["params"]["assignedToList"] == ["13911112222"]

    unknown_settings = tracker_settings(%{"assignee" => "查无此人", "dep_id" => unique_dep_id()})

    FakeHttp.push([
      login_ok(),
      members_ok([%{"psnName" => "米久业", "loginAccount" => "mijy", "mobile" => "13900000000"}])
    ])

    assert {:error, {:shanzhi_unknown_person, "查无此人"}} =
             Client.fetch_issues_by_states(["active"], unknown_settings)
  end

  test "schema applies shanzhi default states and keeps explicit ones" do
    assert {:ok, settings} =
             SymphonyElixir.Config.Schema.parse(%{
               "tracker" => %{
                 "kind" => "shanzhi",
                 "provider" => %{"base_url" => "https://sf.test", "product_id" => 419}
               }
             })

    assert settings.tracker.kind == "shanzhi"
    assert settings.tracker.active_states == ["active"]
    assert settings.tracker.terminal_states == ["closed"]
    assert settings.tracker.provider["product_id"] == 419

    assert {:ok, overridden} =
             SymphonyElixir.Config.Schema.parse(%{
               "tracker" => %{
                 "kind" => "shanzhi",
                 "provider" => %{"base_url" => "https://sf.test", "product_id" => 419},
                 "active_states" => ["active"],
                 "terminal_states" => ["closed", "suspended"]
               }
             })

    assert overridden.tracker.terminal_states == ["closed", "suspended"]
  end

  test "fetch_issues_by_states skips bugs that are not confirmed" do
    settings = tracker_settings()

    FakeHttp.push([
      login_ok(),
      list_ok([
        raw_bug(83_301, "active", steps: "<p>已确认</p>", confirmed: true),
        raw_bug(83_302, "active", steps: "<p>未确认</p>", confirmed: false),
        raw_bug(83_303, "active", steps: "<p>无字段</p>", confirmed: :absent)
      ])
    ])

    assert {:ok, [%Issue{} = issue]} = Client.fetch_issues_by_states(["active"], settings)
    assert issue.identifier == "SF-83301"
  end

  test "require_confirmed false disables the confirmed filter" do
    settings = tracker_settings(%{"require_confirmed" => false})

    FakeHttp.push([
      login_ok(),
      list_ok([
        raw_bug(83_311, "active", steps: "<p>a</p>", confirmed: true),
        raw_bug(83_312, "active", steps: "<p>b</p>", confirmed: false)
      ])
    ])

    assert {:ok, issues} = Client.fetch_issues_by_states(["active"], settings)
    assert Enum.map(issues, & &1.identifier) == ["SF-83311", "SF-83312"]
  end

  test "fetch_issues_by_ids drops unconfirmed bugs so running agents get stopped" do
    settings = tracker_settings()

    FakeHttp.push([
      login_ok(),
      {:ok, %{status: 200, body: %{"code" => 800, "data" => raw_bug(83_321, "active", steps: "x", confirmed: false)}}}
    ])

    assert {:ok, []} = Client.fetch_issues_by_ids(["83321"], settings)
  end

  test "confirm_bug sends assignedTo because the API silently ignores it otherwise" do
    settings = tracker_settings()

    FakeHttp.push([
      login_ok(),
      {:ok, %{status: 200, body: %{"code" => 800, "data" => raw_bug(83_331, "active")}}},
      {:ok, %{status: 200, body: %{"code" => 800, "data" => %{}}}}
    ])

    assert {:ok, result} = Client.confirm_bug(83_331, nil, "<p>已复现</p>", settings)
    assert result["confirmed"] == true
    assert result["assignee"] == "13800000000"

    assert request_urls() == [@login_url, @detail_url, @confirm_url]

    confirm = find_request(@confirm_url)
    assert confirm[:json]["params"]["id"] == 83_331
    assert confirm[:json]["params"]["confirmed"] == true
    assert confirm[:json]["params"]["assignedTo"] == "13800000000"
    assert confirm[:json]["params"]["comment"] == "<p>已复现</p>"
  end

  test "confirmed? accepts the shapes the API returns" do
    assert Client.confirmed?(true)
    assert Client.confirmed?("true")
    assert Client.confirmed?("是")
    refute Client.confirmed?(false)
    refute Client.confirmed?(nil)
    refute Client.confirmed?("false")
  end

  test "agent tool returns structured success and failure responses" do
    settings = tracker_settings()

    FakeHttp.push([
      login_ok(),
      {:ok, %{status: 200, body: %{"code" => 800, "data" => raw_bug(83_210, "active")}}}
    ])

    response = AgentTool.execute("shanzhi_get_bug", %{"bug_id" => 83_210}, tracker_settings: settings)
    assert response["success"] == true
    assert response["output"] =~ "83210"

    failure = AgentTool.execute("shanzhi_get_bug", %{"bug_id" => "abc"}, tracker_settings: settings)
    assert failure["success"] == false
    assert failure["output"] =~ "bug_id"

    unsupported = AgentTool.execute("shanzhi_delete_bug", %{}, tracker_settings: settings)
    assert unsupported["success"] == false
    assert unsupported["output"] =~ "Unsupported dynamic tool"
  end

  test "normalize_status accepts Chinese and English statuses" do
    assert Client.normalize_status("激活") == "active"
    assert Client.normalize_status("已解决") == "resolved"
    assert Client.normalize_status("已关闭") == "closed"
    assert Client.normalize_status(" Suspended ") == "suspended"
    assert Client.normalize_status(nil) == nil
  end

  defp request_urls, do: Enum.map(FakeHttp.requests(), & &1[:url])

  defp find_request(url_suffix) do
    Enum.find(FakeHttp.requests(), &(&1[:url] == url_suffix))
  end

  defp login_ok(token \\ "test-token") do
    {:ok,
     %{
       status: 200,
       body: %{"code" => 800, "data" => %{"authorization" => token, "refresh-authorization" => token}}
     }}
  end

  defp list_ok(rows) do
    {:ok,
     %{
       status: 200,
       body: %{
         "code" => 800,
         "data" => %{"data" => rows, "count" => length(rows), "curIndex" => 1, "pageSize" => 100}
       }
     }}
  end

  defp members_ok(rows) do
    {:ok, %{status: 200, body: %{"code" => 800, "data" => %{"data" => rows, "count" => length(rows)}}}}
  end

  defp unique_dep_id, do: "dep-#{System.unique_integer([:positive])}"

  defp raw_bug(id, status, opts \\ []) do
    base = %{
      "id" => id,
      "title" => "【对话列表】切换后产物丢失",
      "status" => status,
      "type" => "codeerror",
      "severity" => 2,
      "pri" => 2,
      "confirmed" => true,
      "assignedTo" => "13800000000",
      "assignedToName" => "陈昌稳",
      "openedByName" => "米久业",
      "environment" => "test",
      "openedDate" => "2026-11-12 10:30:00"
    }

    base =
      case Keyword.get(opts, :steps) do
        nil -> base
        steps -> Map.put(base, "steps", steps)
      end

    case Keyword.get(opts, :confirmed, :default) do
      :default -> base
      # :absent 用来模拟接口不返回该字段的情况
      :absent -> Map.delete(base, "confirmed")
      value -> Map.put(base, "confirmed", value)
    end
  end

  defp tracker_settings(provider_overrides \\ %{}) do
    unique = System.unique_integer([:positive])

    %{
      kind: "shanzhi",
      provider:
        Map.merge(
          %{
            "base_url" => "https://sf.test",
            "username" => "user#{unique}",
            "password" => "secret",
            "product_id" => 419,
            "project_id" => 428,
            "dep_id" => "491919451030089984",
            "web_url" => "http://sf.sieiot.com"
          },
          provider_overrides
        ),
      active_states: ["active"],
      terminal_states: ["closed"]
    }
  end

  defp put_provider(settings, overrides) do
    %{settings | provider: Map.merge(settings.provider, overrides)}
  end
end
