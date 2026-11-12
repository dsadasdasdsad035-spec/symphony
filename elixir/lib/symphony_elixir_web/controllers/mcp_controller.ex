defmodule SymphonyElixirWeb.McpController do
  @moduledoc """
  MCP 的 HTTP 传输层（Streamable HTTP 的简化实现）。

  只用 `POST /mcp` + JSON 响应，不开 SSE 流：Symphony 暴露的工具都是同步的
  请求-应答，没有服务端主动推送的需求，客户端按规范也接受 JSON 响应。

  安全边界：这个端点能让调用方以 Symphony 的身份访问 tracker，因此只接受
  回环地址来源；需要跨机使用时再显式放开，绝不默认开放公网。
  """

  use Phoenix.Controller, formats: [:json]

  require Logger

  alias Plug.Conn
  alias SymphonyElixir.Mcp.Server

  @parse_error -32_700
  @transport_error -32_000

  @spec handle(Conn.t(), map()) :: Conn.t()
  def handle(conn, _params) do
    if loopback?(conn) do
      conn
      |> dispatch()
    else
      conn
      |> put_status(403)
      |> json(%{
        jsonrpc: "2.0",
        id: nil,
        error: %{code: @transport_error, message: "MCP endpoint only accepts loopback clients"}
      })
    end
  end

  @doc """
  GET 用于 SSE 服务端推送、DELETE 用于结束会话；本实现两类都不提供，
  按 MCP 规范返回 405，让客户端改用 POST。
  """
  @spec method_not_allowed(Conn.t(), map()) :: Conn.t()
  def method_not_allowed(conn, _params) do
    conn
    |> put_resp_header("allow", "POST")
    |> put_status(405)
    |> json(%{
      jsonrpc: "2.0",
      id: nil,
      error: %{code: @transport_error, message: "Only POST is supported at this endpoint"}
    })
  end

  defp dispatch(conn) do
    case decode(conn) do
      {:ok, request} ->
        case Server.handle(request) do
          {:reply, response} -> send_json(conn, 200, response)
          :no_response -> conn |> put_status(202) |> send_resp(202, "")
        end

      {:error, reason} ->
        send_json(conn, 400, %{
          jsonrpc: "2.0",
          id: nil,
          error: %{code: @parse_error, message: "Parse error", data: inspect(reason)}
        })
    end
  end

  defp decode(conn) do
    body = conn.assigns[:raw_body] || ""

    if String.trim(body) == "" do
      {:error, :empty_body}
    else
      Jason.decode(body)
    end
  end

  defp send_json(conn, status, payload) do
    conn
    |> put_resp_content_type("application/json")
    |> put_status(status)
    |> send_resp(status, Jason.encode!(payload))
  end

  defp loopback?(%Conn{remote_ip: {127, _, _, _}}), do: true
  defp loopback?(%Conn{remote_ip: {0, 0, 0, 0, 0, 0, 0, 1}}), do: true
  defp loopback?(%Conn{remote_ip: {0, 0, 0, 0, 0, 0xFFFF, 0x7F00, _rest}}), do: true
  defp loopback?(_conn), do: false
end
