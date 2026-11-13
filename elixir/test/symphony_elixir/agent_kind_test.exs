defmodule SymphonyElixir.AgentKindTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Agent
  alias SymphonyElixir.Agent.Kind
  alias SymphonyElixir.Agent.CursorCli
  alias SymphonyElixir.Tracker.Issue

  defp issue(overrides \\ %{}) do
    struct!(
      %Issue{
        id: "1",
        identifier: "SF-1",
        title: "t",
        state: "active",
        dispatchable: true
      },
      overrides
    )
  end

  test "keywords 空白时默认 codex" do
    assert Kind.resolve(issue(%{attributes: %{"keywords" => ""}})) == "codex"
    assert Kind.resolve(issue(%{labels: ["severity:2"]})) == "codex"
  end

  test "display_label 供看板展示" do
    assert Kind.display_label("cursor_cli") == "Cursor CLI"
    assert Kind.display_label("zcode") == "ZCode"
    assert Kind.display_label(nil) == "Codex"
  end

  test "善治 keywords 指定 CLI" do
    assert Kind.resolve(issue(%{attributes: %{"keywords" => "cursor cli"}})) == "cursor_cli"
    assert Kind.resolve(issue(%{attributes: %{"keywords" => "zcode"}})) == "zcode"
    assert {kind, CursorCli} = Agent.impl_for(issue(%{attributes: %{"keywords" => "cursor"}}))
    assert kind == "cursor_cli"
  end

  test "Linear/Jira 风格标签" do
    assert Kind.resolve(issue(%{labels: ["cursor cli", "bug"]})) == "cursor_cli"
    assert Kind.resolve(issue(%{labels: ["claude code"]})) == "claude_cli"
  end

  test "keywords 优先于标签" do
    assert Kind.resolve(issue(%{attributes: %{"keywords" => "zcode"}, labels: ["cursor cli"]})) == "zcode"
  end

  test "未识别的 keywords 回退 codex" do
    assert Kind.resolve(issue(%{attributes: %{"keywords" => "not-a-cli"}})) == "codex"

    assert {_kind, reason} = Kind.resolve_with_reason(issue(%{attributes: %{"keywords" => "not-a-cli"}}))
    assert match?({:unknown_tokens, _}, reason)
  end
end
