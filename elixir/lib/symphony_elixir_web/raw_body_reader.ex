defmodule SymphonyElixirWeb.RawBodyReader do
  @moduledoc """
  把请求体原样保留在 `conn.assigns.raw_body` 里的 body reader。

  MCP 端点是 JSON-RPC，需要拿到未加工的原始报文：Plug.Parsers 默认会把 JSON
  解析成 params map，既丢掉顶层数组（JSON-RPC 批处理），也无法保持字节级原样。
  """

  @spec read_body(Plug.Conn.t(), keyword()) ::
          {:ok, binary(), Plug.Conn.t()} | {:more, binary(), Plug.Conn.t()} | {:error, term()}
  def read_body(conn, opts) do
    case Plug.Conn.read_body(conn, opts) do
      {:ok, body, conn} ->
        {:ok, body, assign_raw_body(conn, body)}

      {:more, partial, conn} ->
        read_rest(conn, opts, partial)

      {:error, _reason} = error ->
        error
    end
  end

  defp read_rest(conn, opts, acc) do
    case Plug.Conn.read_body(conn, opts) do
      {:ok, body, conn} ->
        full = acc <> body
        {:ok, full, assign_raw_body(conn, full)}

      {:more, partial, conn} ->
        read_rest(conn, opts, acc <> partial)

      {:error, _reason} = error ->
        error
    end
  end

  defp assign_raw_body(conn, body), do: Plug.Conn.assign(conn, :raw_body, body)
end
