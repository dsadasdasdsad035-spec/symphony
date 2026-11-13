defmodule SymphonyElixir.SessionHistory do
  @moduledoc """
  把「最近结束的会话」持久化到磁盘，避免重启后仪表盘的 Recent sessions 清空。

  编排器内存里的 history 只是缓存，进程一重启就没了；而用户往往正是为了
  让新代码生效才重启，结果恰好把想看的记录弄丢。这里在每次会话结束、以及
  orchestrator 启动时读写一个小 JSON 文件。

  文件位置: `~/.config/symphony/history.json`（可用 `SYMPHONY_HISTORY_FILE` 覆盖）
  """

  require Logger

  @default_limit 25
  # trace 里的 message 可能带着完整事件 payload，单条留太多会把文件撑大。
  @max_trace_per_entry 60

  @type entry :: map()

  @doc "历史文件的绝对路径。"
  @spec path() :: Path.t()
  def path do
    case System.get_env("SYMPHONY_HISTORY_FILE") do
      value when is_binary(value) and value != "" -> Path.expand(value)
      _ -> Path.expand("~/.config/symphony/history.json")
    end
  end

  @doc """
  读取历史记录。

  任何异常（文件不存在、JSON 损坏、结构不符）都退化成空列表——历史只是
  观测数据，绝不能因此让编排器起不来。
  """
  @spec load(keyword()) :: [entry()]
  def load(opts \\ []) do
    limit = Keyword.get(opts, :limit, @default_limit)

    with {:ok, body} <- File.read(path()),
         {:ok, decoded} <- Jason.decode(body) do
      decoded
      |> extract_list()
      |> Enum.map(&to_entry/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.take(limit)
    else
      {:error, :enoent} ->
        []

      {:error, reason} ->
        Logger.warning("读取会话历史失败，按空历史处理: #{inspect(reason)}")
        []
    end
  end

  @doc """
  原子写入历史记录。

  先写临时文件再 rename，避免进程在写入中途被杀导致文件被截断成半截 JSON。
  """
  @spec save([entry()], keyword()) :: :ok | {:error, term()}
  def save(entries, opts \\ []) when is_list(entries) do
    limit = Keyword.get(opts, :limit, @default_limit)
    target = path()
    tmp = target <> ".tmp"

    payload =
      entries
      |> Enum.take(limit)
      |> Enum.map(&from_entry/1)

    with :ok <- File.mkdir_p(Path.dirname(target)),
         :ok <- File.write(tmp, Jason.encode!(payload, pretty: true)),
         :ok <- File.rename(tmp, target) do
      :ok
    else
      {:error, reason} = error ->
        File.rm(tmp)
        Logger.warning("写入会话历史失败: #{inspect(reason)}")
        error
    end
  end

  defp extract_list(list) when is_list(list), do: list
  defp extract_list(%{"history" => list}) when is_list(list), do: list
  defp extract_list(_other), do: []

  # ------------------------------------------------------------------ 写入

  # 只持久化已知字段，避免把内部结构（PID、ref 等）写进文件。
  defp from_entry(entry) do
    %{
      "issue_id" => Map.get(entry, :issue_id),
      "identifier" => Map.get(entry, :identifier),
      "issue_url" => Map.get(entry, :issue_url),
      "state" => Map.get(entry, :state),
      "session_id" => Map.get(entry, :session_id),
      "worker_host" => Map.get(entry, :worker_host),
      "workspace_path" => Map.get(entry, :workspace_path),
      "outcome" => encode_atom(Map.get(entry, :outcome)),
      "error" => Map.get(entry, :error),
      "started_at" => encode_datetime(Map.get(entry, :started_at)),
      "finished_at" => encode_datetime(Map.get(entry, :finished_at)),
      "runtime_seconds" => Map.get(entry, :runtime_seconds),
      "turn_count" => Map.get(entry, :turn_count),
      "codex_input_tokens" => Map.get(entry, :codex_input_tokens, 0),
      "codex_output_tokens" => Map.get(entry, :codex_output_tokens, 0),
      "codex_total_tokens" => Map.get(entry, :codex_total_tokens, 0),
      "trace" => entry |> Map.get(:trace, []) |> Enum.take(@max_trace_per_entry) |> Enum.map(&from_trace/1)
    }
  end

  defp from_trace(%{at: at, event: event, message: message}) do
    %{
      "at" => encode_datetime(at),
      "event" => event && to_string(event),
      "message" => from_message(message)
    }
  end

  defp from_trace(other), do: other

  # message 内部混着原子键（:event / :message）和字符串键（"method" / "params"），
  # 统一转成字符串键再入库，读回来时按已知键还原。
  defp from_message(%{} = message) do
    %{
      "event" => message |> Map.get(:event) |> encode_atom(),
      "message" => json_safe(Map.get(message, :message))
    }
  end

  defp from_message(other), do: other

  defp json_safe(value) when is_map(value) do
    Map.new(value, fn {k, v} -> {to_string(k), json_safe(v)} end)
  end

  defp json_safe(value) when is_list(value), do: Enum.map(value, &json_safe/1)
  defp json_safe(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp json_safe(value) when is_atom(value) and not is_boolean(value) and not is_nil(value), do: to_string(value)
  defp json_safe(value), do: value

  # ------------------------------------------------------------------ 读取

  defp to_entry(%{} = raw) do
    started_at = decode_datetime(raw["started_at"])
    finished_at = decode_datetime(raw["finished_at"])

    %{
      issue_id: raw["issue_id"],
      identifier: raw["identifier"],
      issue_url: raw["issue_url"],
      state: raw["state"],
      session_id: raw["session_id"],
      worker_host: raw["worker_host"],
      workspace_path: raw["workspace_path"],
      outcome: decode_atom(raw["outcome"]),
      error: raw["error"],
      started_at: started_at,
      finished_at: finished_at,
      runtime_seconds: raw["runtime_seconds"],
      turn_count: raw["turn_count"],
      codex_input_tokens: raw["codex_input_tokens"] || 0,
      codex_output_tokens: raw["codex_output_tokens"] || 0,
      codex_total_tokens: raw["codex_total_tokens"] || 0,
      trace: raw |> Map.get("trace", []) |> Enum.map(&to_trace/1) |> Enum.reject(&is_nil/1)
    }
  end

  defp to_entry(_raw), do: nil

  defp to_trace(%{} = raw) do
    %{
      at: decode_datetime(raw["at"]),
      event: raw["event"],
      message: to_message(raw["message"])
    }
  end

  defp to_trace(_raw), do: nil

  # humanize_codex_message/1 匹配的是原子键，所以这里必须还原成
  # %{event: ..., message: ...}，否则历史里的轨迹会显示不出内容。
  defp to_message(%{"message" => message} = raw) do
    %{event: decode_atom(raw["event"]), message: message}
  end

  defp to_message(%{message: message} = raw), do: %{event: Map.get(raw, :event), message: message}
  defp to_message(other), do: other

  # ------------------------------------------------------------------ 工具函数

  defp encode_datetime(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp encode_datetime(_value), do: nil

  defp decode_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      _ -> nil
    end
  end

  defp decode_datetime(_value), do: nil

  defp encode_atom(nil), do: nil
  defp encode_atom(value) when is_atom(value), do: to_string(value)
  defp encode_atom(value), do: value

  # 只还原已存在的原子，避免反复重启时不断创建新原子。
  defp decode_atom(value) when is_binary(value) do
    String.to_existing_atom(value)
  rescue
    ArgumentError -> value
  end

  defp decode_atom(value), do: value
end
