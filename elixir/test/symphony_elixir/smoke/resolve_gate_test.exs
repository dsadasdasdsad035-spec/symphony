defmodule SymphonyElixir.Smoke.ResolveGateTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Smoke.ResolveGate

  @comment_base """
  <p>测试边界：验搜索框回显，不测导出。</p>
  <p>步骤对应：善治步骤 3 对应 test_search_after_fix。</p>
  <p><a href="http://gitlab.example.com/proj/-/merge_requests/1#note_9">报告</a></p>
  """

  setup do
    tmp = System.tmp_dir!() |> Path.join("resolve_gate_#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(tmp, "smoke"))
    on_exit(fn -> File.rm_rf!(tmp) end)
    %{workspace: tmp}
  end

  defp write!(path, map), do: File.write!(path, Jason.encode!(map))

  defp requirement!(workspace, layers) do
    write!(
      Path.join(workspace, "smoke/smoke-requirement.json"),
      %{"required_layers" => layers, "rationale" => "单测", "repro_keywords" => ["点击"]}
    )
  end

  defp pass!(workspace, opts) do
    layers = Keyword.get(opts, :layers, ["UI"])
    issue = Keyword.get(opts, :issue, "SF-TEST")
    url = Keyword.get(opts, :url, "http://gitlab.example.com/proj/-/merge_requests/1#note_9")

    passes =
      Enum.map(layers, fn layer ->
        %{
          "verdict" => "PASS",
          "layer" => layer,
          "report_url" => url,
          "issue_identifier" => issue
        }
      end)

    write!(
      Path.join(workspace, "smoke/smoke-pass.json"),
      %{"schema_version" => 1, "issue_identifier" => issue, "verdict" => "PASS", "report_url" => url, "passes" => passes}
    )
  end

  defp comment(url), do: String.replace(@comment_base, "http://gitlab.example.com/proj/-/merge_requests/1#note_9", url)

  test "缺 requirement 时拒绝", %{workspace: workspace} do
    pass!(workspace, layers: ["UI"])
    url = "http://gitlab.example.com/proj/-/merge_requests/1#note_9"

    assert {:error, %{"error" => %{"gate" => "smoke_resolve"}}} =
             ResolveGate.check(1, comment(url), workspace: workspace, issue: %{identifier: "SF-TEST"})
  end

  test "UI requirement 仅 API pass 时拒绝", %{workspace: workspace} do
    requirement!(workspace, "UI")
    pass!(workspace, layers: ["API"])
    url = "http://gitlab.example.com/proj/-/merge_requests/1#note_9"

    assert {:error, %{"error" => %{"message" => msg}}} =
             ResolveGate.check(1, comment(url), workspace: workspace, issue: %{identifier: "SF-TEST"})

    assert msg =~ "UI"
  end

  test "comment 无 report_url 时拒绝", %{workspace: workspace} do
    requirement!(workspace, "UI")
    pass!(workspace, layers: ["UI"])

    comment = """
    <p>测试边界：验搜索框回显，不测导出。</p>
    <p>步骤对应：善治步骤 3 对应 test_search_after_fix。</p>
  <p>无 MR 链接</p>
    """

    assert {:error, %{"error" => %{"message" => msg}}} =
             ResolveGate.check(1, comment, workspace: workspace, issue: %{identifier: "SF-TEST"})

    assert msg =~ "报告链接"
  end

  test "BOTH 缺一层时拒绝", %{workspace: workspace} do
    requirement!(workspace, "BOTH")
    pass!(workspace, layers: ["UI"])
    url = "http://gitlab.example.com/proj/-/merge_requests/1#note_9"

    assert {:error, %{"error" => %{"message" => msg}}} =
             ResolveGate.check(1, comment(url), workspace: workspace, issue: %{identifier: "SF-TEST"})

    assert msg =~ "API"
  end

  test "完整 BOTH + 八段式 comment 通过", %{workspace: workspace} do
    requirement!(workspace, "BOTH")
    pass!(workspace, layers: ["API", "UI"])
    url = "http://gitlab.example.com/proj/-/merge_requests/1#note_9"

    assert :ok = ResolveGate.check(1, comment(url), workspace: workspace, issue: %{identifier: "SF-TEST"})
  end

  test "data-smoke-report 属性可代替纯链接子串", %{workspace: workspace} do
    requirement!(workspace, "API")
    url = "http://gitlab.example.com/proj/-/merge_requests/2#note_42"
    pass!(workspace, layers: ["API"], url: url)

    html = """
    <p>测试边界：RPC 返回行数。</p>
    <p>步骤对应：步骤 1 → test_rpc。</p>
    <p data-smoke-report=\"#{url}\">详见报告</p>
    """

    assert :ok = ResolveGate.check(1, html, workspace: workspace, issue: %{identifier: "SF-TEST"})
  end

  test "SMOKE_RESOLVE_GATE=0 时跳过", %{workspace: workspace} do
    previous = System.get_env("SMOKE_RESOLVE_GATE")
    System.put_env("SMOKE_RESOLVE_GATE", "0")

    on_exit(fn ->
      case previous do
        nil -> System.delete_env("SMOKE_RESOLVE_GATE")
        v -> System.put_env("SMOKE_RESOLVE_GATE", v)
      end
    end)

    assert :ok = ResolveGate.check(1, "无文件", workspace: workspace)
  end
end