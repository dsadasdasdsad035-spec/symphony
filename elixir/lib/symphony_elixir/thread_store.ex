defmodule SymphonyElixir.ThreadStore do
  @moduledoc """
  把「工单项 → 会话线程」的映射持久化到磁盘，用于跨 run 续接会话。

  ## 为什么需要它

  跑满 `agent.max_turns` 后控制权回到调度器，约 1 秒后重新派发。此前每次
  `start_session` 都新建会话（Codex 发 `thread/start`，其余 CLI 的 `session_id`
  初始化为空），于是新一轮从零开始——上一轮探索过的路径、排除过的假设全部丢失。
  实测 SF-83323 / SF-83324 各被派发 24 次、累计 1026 万 input token，产出为 0。

  Codex app-server 支持 `thread/resume`（按 `threadId` 从磁盘加载线程），
  其余 CLI 支持 `--resume <session_id>`。所以这里记住线程 id，下一轮改成续接。

  ## 为什么和会话文件同生命周期

  会话文件在 `~/.codex/sessions`、`~/.claude/projects`（容器 overlay 层），
  Pod 重建后一起消失。这个映射也放在 overlay 层（`~/.config/symphony/`），
  两者同生同灭，避免留下指向已消失会话的陈旧映射。

  即便如此仍需容错：会话文件可能被手工清理、CLI 升级后格式不兼容等。
  调用方在续接失败时**必须**回退到新建会话，不能让整轮跑不起来。

  文件位置：`~/.config/symphony/threads.json`（可用 `SYMPHONY_THREADS_FILE` 覆盖）。
  """

  use GenServer

  require Logger

  @table :symphony_thread_store
  @max_entries 200

  # ---------------------------------------------------------------- 客户端 API

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "映射文件的绝对路径。"
  @spec path() :: Path.t()
  def path do
    case System.get_env("SYMPHONY_THREADS_FILE") do
      value when is_binary(value) and value != "" -> Path.expand(value)
      _ -> Path.expand("~/.config/symphony/threads.json")
    end
  end

  @doc """
  取某个工单项上次的线程信息。

  返回 `%{thread_id: String.t(), turns: non_neg_integer()}`，没有记录时返回 `nil`。
  `turns` 是这条线程里已经累积跑过的轮数，用于判断续接后是否需要压缩上下文。

  进程未启动时退化成读文件；任何异常都返回 `nil`——续接只是优化，
  不能因为读映射失败就让整轮跑不起来。
  """
  @spec get(String.t() | nil) :: %{thread_id: String.t(), turns: non_neg_integer()} | nil
  def get(identifier) when is_binary(identifier) and identifier != "" do
    case lookup(identifier) do
      {:ok, thread_id, turns} -> %{thread_id: thread_id, turns: turns}
      :error -> nil
    end
  rescue
    _ -> nil
  end

  def get(_identifier), do: nil

  @doc """
  记住某个工单项当前线程，`turns` 为这条线程累计跑过的轮数。

  写入失败只记日志，不影响主流程。
  """
  @spec put(String.t() | nil, String.t() | nil, non_neg_integer()) :: :ok
  def put(identifier, thread_id, turns \\ 0), do: do_put(identifier, thread_id, turns)

  defp do_put(identifier, thread_id, turns)
       when is_binary(identifier) and identifier != "" and is_binary(thread_id) and
              thread_id != "" do
    turns = if is_integer(turns) and turns >= 0, do: turns, else: 0

    if Process.whereis(__MODULE__) do
      # 同步写入：调用方紧接着可能会读回（下一轮派发就是这么用的），
      # 异步 cast 会出现读到旧值的竞态。文件很小，开销可忽略。
      GenServer.call(__MODULE__, {:put, identifier, thread_id, turns}, 5_000)
    else
      persist_direct(Map.put(read_file(), identifier, entry(thread_id, turns)))
    end
  catch
    _, _ -> :ok
  end

  defp do_put(_identifier, _thread_id, _turns), do: :ok

  @doc "忘掉某个工单项的线程（会话已失效或已交付时调用）。"
  @spec delete(String.t() | nil) :: :ok
  def delete(identifier) when is_binary(identifier) and identifier != "" do
    if Process.whereis(__MODULE__) do
      GenServer.call(__MODULE__, {:delete, identifier}, 5_000)
    else
      persist_direct(Map.delete(read_file(), identifier))
    end
  catch
    _, _ -> :ok
  end

  def delete(_identifier), do: :ok

  @doc "当前全部映射，主要给测试与排查用。"
  @spec all() :: %{optional(String.t()) => %{thread_id: String.t(), turns: non_neg_integer()}}
  def all do
    if :ets.whereis(@table) == :undefined do
      read_file()
    else
      @table
      |> :ets.tab2list()
      |> Map.new(fn {identifier, thread_id, turns, _updated_at} ->
        {identifier, %{thread_id: thread_id, turns: turns}}
      end)
    end
  rescue
    _ -> %{}
  end

  @doc false
  # 仅测试用：清空内存与文件。测试共用同一个应用实例，线程映射会跨用例残留，
  # 导致后一个用例莫名其妙去「续接」前一个用例的假线程。
  @spec reset_for_test() :: :ok
  def reset_for_test do
    if Process.whereis(__MODULE__) do
      GenServer.call(__MODULE__, :reset, 5_000)
    else
      File.rm(path())
      :ok
    end
  catch
    _, _ -> :ok
  end

  # ---------------------------------------------------------------- GenServer

  @impl true
  def init(_opts) do
    table =
      case :ets.whereis(@table) do
        :undefined -> :ets.new(@table, [:set, :public, :named_table, read_concurrency: true])
        _existing -> @table
      end

    Enum.each(read_file(), fn {identifier, %{thread_id: thread_id, turns: turns}} ->
      :ets.insert(table, {identifier, thread_id, turns, unix_now()})
    end)

    {:ok, %{table: table}}
  end

  @impl true
  def handle_call({:put, identifier, thread_id, turns}, _from, state) do
    :ets.insert(state.table, {identifier, thread_id, turns, unix_now()})
    persist_from_table(state.table)
    {:reply, :ok, state}
  end

  def handle_call({:delete, identifier}, _from, state) do
    :ets.delete(state.table, identifier)
    persist_from_table(state.table)
    {:reply, :ok, state}
  end

  def handle_call(:reset, _from, state) do
    :ets.delete_all_objects(state.table)
    File.rm(path())
    {:reply, :ok, state}
  end

  def handle_call(_message, _from, state), do: {:reply, :ok, state}

  # ---------------------------------------------------------------- 内部

  defp lookup(identifier) do
    case :ets.whereis(@table) do
      :undefined ->
        case Map.get(read_file(), identifier) do
          %{thread_id: thread_id, turns: turns} -> {:ok, thread_id, turns}
          _ -> :error
        end

      _existing ->
        case :ets.lookup(@table, identifier) do
          [{^identifier, thread_id, turns, _updated_at}] -> {:ok, thread_id, turns}
          _ -> :error
        end
    end
  end

  defp entry(thread_id, turns) do
    %{thread_id: thread_id, turns: turns, updated_at: unix_now()}
  end

  defp persist_direct(entries) when is_map(entries) do
    entries
    |> Map.new(fn {identifier, value} -> {identifier, entry(value.thread_id, value.turns)} end)
    |> write_file()
  end

  defp persist_from_table(table) do
    entries =
      table
      |> :ets.tab2list()
      |> Enum.map(fn {identifier, thread_id, turns, updated_at} ->
        {identifier, %{thread_id: thread_id, turns: turns, updated_at: updated_at}}
      end)
      |> Map.new()
      |> prune()

    write_file(entries)
  end

  # 映射很小，但长期运行会积累已交付工单；超上限时按最后更新时间丢最早的。
  defp prune(entries) when map_size(entries) <= @max_entries, do: entries

  defp prune(entries) do
    entries
    |> Enum.sort_by(fn {_identifier, value} -> value.updated_at end, :desc)
    |> Enum.take(@max_entries)
    |> Map.new()
  end

  defp read_file do
    with {:ok, body} <- File.read(path()),
         {:ok, decoded} <- Jason.decode(body),
         true <- is_map(decoded) do
      decoded
      |> Enum.flat_map(fn
        {identifier, %{"thread_id" => thread_id} = value} when is_binary(thread_id) and thread_id != "" ->
          turns = value["turns"]
          updated = value["updated_at"]

          [
            {identifier,
             %{
               thread_id: thread_id,
               turns: if(is_integer(turns) and turns >= 0, do: turns, else: 0),
               updated_at: if(is_integer(updated), do: updated, else: 0)
             }}
          ]

        _other ->
          []
      end)
      |> Map.new()
    else
      _ -> %{}
    end
  rescue
    _ -> %{}
  end

  defp write_file(entries) when is_map(entries) do
    target = path()
    tmp = target <> ".tmp"

    payload =
      entries
      |> Enum.map(fn {identifier, value} ->
        {identifier,
         %{
           "thread_id" => value.thread_id,
           "turns" => value.turns,
           "updated_at" => value.updated_at
         }}
      end)
      |> Map.new()

    with :ok <- File.mkdir_p(Path.dirname(target)),
         :ok <- File.write(tmp, Jason.encode!(payload, pretty: true)),
         :ok <- File.rename(tmp, target) do
      :ok
    else
      {:error, reason} ->
        File.rm(tmp)
        Logger.warning("写入 thread 映射失败: #{inspect(reason)}")
        :ok
    end
  end

  defp unix_now, do: System.os_time(:second)
end
