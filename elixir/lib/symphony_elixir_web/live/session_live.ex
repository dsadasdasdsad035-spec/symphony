defmodule SymphonyElixirWeb.SessionLive do
  @moduledoc """
  单个 agent 会话的完整执行过程页面。

  仪表盘上只能看到事件摘要，真正「agent 每一步做了什么」在 Claude Code 的
  transcript 里：`~/.claude/projects/<工作区>/<session_id>.jsonl`。这里按
  Session ID 把它读出来按时间顺序展示，运行中的会话会自动刷新。
  """

  use Phoenix.LiveView, layout: {SymphonyElixirWeb.Layouts, :app}

  alias SymphonyElixir.SessionTranscript
  alias SymphonyElixirWeb.{Endpoint, Presenter}

  # 运行中的会话会持续追加内容，定期重读一次即可（解析 1MB 约 20ms）。
  @refresh_ms 5_000

  @impl true
  def mount(%{"session_id" => session_id}, _session, socket) do
    socket =
      socket
      |> assign(:session_id, session_id)
      |> load()

    if connected?(socket) and socket.assigns.session_live, do: schedule_refresh()

    {:ok, socket}
  end

  @impl true
  def handle_info(:refresh, socket) do
    socket = load(socket)
    # 会话结束后就没必要继续轮询，避免反复读几 MB 的 transcript。
    if socket.assigns.session_live, do: schedule_refresh()
    {:noreply, socket}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  defp schedule_refresh, do: Process.send_after(self(), :refresh, @refresh_ms)

  defp load(socket) do
    session_id = socket.assigns.session_id
    {issue, live?} = find_issue(session_id)

    case SessionTranscript.load(session_id) do
      {:ok, transcript} ->
        assign(socket, transcript: transcript, error: nil, issue: issue, session_live: live?)

      {:error, reason} ->
        assign(socket, transcript: nil, error: reason, issue: issue, session_live: live?)
    end
  end

  # 通过 session_id 反查 issue，页面标题才有意义；顺带判断会话是否仍在运行。
  # 拿不到 orchestrator 也不影响主功能。
  defp find_issue(session_id) do
    payload = Presenter.state_payload(orchestrator(), 5_000)

    case Enum.find(payload.running, &(&1.session_id == session_id)) do
      nil -> {Enum.find(payload.history, &(&1.session_id == session_id)), false}
      entry -> {entry, true}
    end
  rescue
    _ -> {nil, false}
  catch
    _, _ -> {nil, false}
  end

  defp orchestrator do
    Endpoint.config(:orchestrator) || SymphonyElixir.Orchestrator
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section class="dashboard-shell">
      <header class="hero-card">
        <div class="hero-grid">
          <div>
            <p class="eyebrow">Session transcript</p>
            <h1 class="hero-title">
              <%= if @issue do %>
                <%= @issue.issue_identifier %>
              <% else %>
                Agent session
              <% end %>
            </h1>
            <p class="hero-copy">
              按 Step 展示 agent 的思考、工具调用与工具输出，数据来自会话 transcript 文件。
            </p>
            <p class="session-nav">
              <a class="issue-link" href="/">&larr; 返回仪表盘</a>
              <span class="mono muted"><%= @session_id %></span>
            </p>
          </div>
        </div>
      </header>

      <%= cond do %>
        <% @error == :invalid_session_id -> %>
          <section class="section-card">
            <p class="empty-state">Session ID 格式不合法。</p>
          </section>
        <% @error == :not_found -> %>
          <section class="section-card">
            <p class="empty-state">
              没找到该会话的 transcript 文件。可能原因：会话不是 Claude CLI 跑出来的，
              或者 transcript 目录被清理过。
            </p>
            <p class="section-copy mono">查找位置: ~/.claude/projects/*/<%= @session_id %>.jsonl</p>
          </section>
        <% @error -> %>
          <section class="section-card">
            <p class="empty-state">读取 transcript 失败：<%= @error %></p>
          </section>
        <% @transcript -> %>
          <section class="section-card">
            <div class="session-meta-grid">
              <div class="metric">
                <span class="metric-label">Steps</span>
                <span class="metric-value"><%= @transcript.step_count %></span>
              </div>
              <div class="metric">
                <span class="metric-label">Tool calls</span>
                <span class="metric-value"><%= @transcript.tool_call_count %></span>
              </div>
              <div class="metric">
                <span class="metric-label">Errors</span>
                <span class="metric-value"><%= @transcript.error_count %></span>
              </div>
              <div class="metric">
                <span class="metric-label">Model</span>
                <span class="metric-value small"><%= @transcript.model || "n/a" %></span>
              </div>
            </div>

            <dl class="session-facts">
              <div>
                <dt>Started</dt>
                <dd class="mono"><%= format_ts(@transcript.started_at) %></dd>
              </div>
              <div>
                <dt>Last event</dt>
                <dd class="mono"><%= format_ts(@transcript.finished_at) %></dd>
              </div>
              <div>
                <dt>Workspace</dt>
                <dd class="mono"><%= @transcript.cwd || "n/a" %></dd>
              </div>
              <div>
                <dt>Transcript</dt>
                <dd class="mono"><%= @transcript.path %></dd>
              </div>
            </dl>

            <%= if @transcript.dropped_count > 0 do %>
              <p class="section-copy">
                仅显示最新 <%= length(@transcript.steps) %> 步，更早的 <%= @transcript.dropped_count %> 步未加载。
              </p>
            <% end %>
          </section>

          <section class="section-card">
            <div class="section-header">
              <div>
                <h2 class="section-title">Execution steps</h2>
                <p class="section-copy">按时间正序，长内容可展开。</p>
              </div>
            </div>

            <ol class="step-list">
              <li :for={step <- @transcript.steps} class={step_class(step)}>
                <div class="step-head">
                  <span class="step-time mono"><%= format_ts(step.at, :time) %></span>
                  <span class={step_badge_class(step)}><%= step_label(step) %></span>
                  <span :if={step.tool} class="step-tool mono"><%= step.tool %></span>
                  <span :if={step.status == "error"} class="step-error">error</span>
                </div>
                <%= if is_binary(step.text) and step.text != "" do %>
                  <details class="step-details" open={short_text?(step)}>
                    <summary class="step-summary"><%= preview(step.text) %></summary>
                    <pre class="step-body"><%= step.text %><%= if step.truncated, do: "\n… (已截断)" %></pre>
                  </details>
                <% end %>
              </li>
            </ol>
          </section>
        <% end %>
    </section>
    """
  end

  defp step_label(%{kind: "tool_use"}), do: "tool call"
  defp step_label(%{kind: "tool_result", status: status}), do: "tool result (#{status || "ok"})"
  defp step_label(%{kind: kind}), do: kind

  defp step_badge_class(%{kind: "tool_use"}), do: "step-badge step-badge-tool"
  defp step_badge_class(%{kind: "tool_result", status: "error"}), do: "step-badge step-badge-error"
  defp step_badge_class(%{kind: "tool_result"}), do: "step-badge step-badge-result"
  defp step_badge_class(%{kind: "thinking"}), do: "step-badge step-badge-thinking"
  defp step_badge_class(%{kind: "prompt"}), do: "step-badge step-badge-prompt"
  defp step_badge_class(_step), do: "step-badge"

  defp step_class(%{role: "assistant"}), do: "step-item step-assistant"
  defp step_class(_step), do: "step-item step-user"

  # 短内容直接展开，避免每次都点；长内容默认折叠。
  defp short_text?(%{text: text}) when is_binary(text), do: String.length(text) <= 200
  defp short_text?(_step), do: false

  defp preview(text) when is_binary(text) do
    first_line =
      text
      |> String.split("\n", trim: false)
      |> Enum.find("", &(String.trim(&1) != ""))
      |> String.trim()

    line = if first_line == "", do: String.trim(text), else: first_line
    String.slice(line, 0, 160)
  end

  defp format_ts(nil, _mode), do: "n/a"

  defp format_ts(timestamp, :time) when is_binary(timestamp) do
    case DateTime.from_iso8601(timestamp) do
      {:ok, parsed, _offset} -> parsed |> DateTime.truncate(:second) |> DateTime.to_time() |> Time.to_iso8601()
      _ -> timestamp
    end
  end

  defp format_ts(timestamp, _mode) when is_binary(timestamp) do
    case DateTime.from_iso8601(timestamp) do
      {:ok, parsed, _offset} -> parsed |> DateTime.truncate(:second) |> DateTime.to_string()
      _ -> timestamp
    end
  end

  defp format_ts(_timestamp, _mode), do: "n/a"

  # 单参数版本，模板里更常用。
  defp format_ts(timestamp), do: format_ts(timestamp, :full)
end
