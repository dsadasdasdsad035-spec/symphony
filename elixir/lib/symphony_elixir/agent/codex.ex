defmodule SymphonyElixir.Agent.Codex do
  @moduledoc """
  `SymphonyElixir.Agent` 的 Codex 实现，全部委托给 `SymphonyElixir.Codex.AppServer`。

  这一层只是适配器：Codex 的会话结构、事件语义本来就是 Symphony 的原生形态，
  因此不做任何转换。
  """

  @behaviour SymphonyElixir.Agent

  alias SymphonyElixir.Codex.AppServer

  @impl true
  defdelegate start_session(workspace, opts \\ []), to: AppServer

  @impl true
  defdelegate run_turn(session, prompt, issue, opts \\ []), to: AppServer

  @impl true
  defdelegate stop_session(session), to: AppServer
end
