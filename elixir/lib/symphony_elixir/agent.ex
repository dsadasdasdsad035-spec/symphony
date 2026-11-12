defmodule SymphonyElixir.Agent do
  @moduledoc """
  编码 agent 后端的抽象层。

  Symphony 的编排逻辑（认领 issue、建工作区、多轮续跑、看板统计）只依赖这里定义的
  三个回调，不直接依赖某一家 CLI：

    * `start_session/2` —— 在指定工作区准备一次 agent 会话；
    * `run_turn/4` —— 跑一轮对话，并通过 `on_message` 回调上报事件；
    * `stop_session/1` —— 释放会话占用的资源。

  内置实现：

    * `SymphonyElixir.Agent.Codex` —— Codex app-server（JSON-RPC over stdio，默认）
    * `SymphonyElixir.Agent.CursorCli` —— Cursor CLI 的 `stream-json` 输出
    * `SymphonyElixir.Agent.Zcode` —— ZCode CLI 的 `stream-json` 输出

  由 `agent.kind` 配置选择，取值 `codex` / `cursor_cli` / `zcode`。

  `on_message` 收到的事件沿用 Codex 的语义（`:session_started`、`:agent_message`、
  `:notification`、`:turn_completed`、`:turn_failed`、`:turn_ended_with_error`、
  `:startup_failed`），因此看板与编排器无需感知后端差异。
  """

  require Logger

  @type session :: map()
  @type message :: map()

  @callback start_session(workspace :: Path.t(), opts :: keyword()) ::
              {:ok, session()} | {:error, term()}

  @callback run_turn(session(), prompt :: String.t(), issue :: map(), opts :: keyword()) ::
              {:ok, map()} | {:error, term()}

  @callback stop_session(session()) :: :ok

  @doc """
  按 `agent.kind` 解析当前使用的后端模块。配置缺失或非法时回退到 Codex。
  """
  @spec impl() :: module()
  def impl do
    settings = SymphonyElixir.Config.settings!()

    case settings.agent.kind do
      "cursor_cli" -> SymphonyElixir.Agent.CursorCli
      "zcode" -> SymphonyElixir.Agent.Zcode
      _ -> SymphonyElixir.Agent.Codex
    end
  rescue
    error ->
      Logger.warning("解析 agent 后端失败，回退到 Codex: #{inspect(error)}")
      SymphonyElixir.Agent.Codex
  end
end
