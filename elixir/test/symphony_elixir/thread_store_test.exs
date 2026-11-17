defmodule SymphonyElixir.ThreadStoreTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.ThreadStore

  setup do
    dir = Path.join(System.tmp_dir!(), "symphony-threads-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    file = Path.join(dir, "threads.json")

    previous = System.get_env("SYMPHONY_THREADS_FILE")
    System.put_env("SYMPHONY_THREADS_FILE", file)

    on_exit(fn ->
      if previous do
        System.put_env("SYMPHONY_THREADS_FILE", previous)
      else
        System.delete_env("SYMPHONY_THREADS_FILE")
      end

      File.rm_rf(dir)
    end)

    SymphonyElixir.ThreadStore.reset_for_test()

    {:ok, threads_file: file}
  end

  describe "无记录时" do
    test "get/1 返回 nil，不会抛错" do
      assert ThreadStore.get("SF-99999") == nil
      assert ThreadStore.get(nil) == nil
      assert ThreadStore.get("") == nil
    end
  end

  describe "写入与读取" do
    test "put/3 后 get/1 能取回线程与累计轮数" do
      assert :ok = ThreadStore.put("SF-83323", "thread-abc", 7)
      # cast 是异步的，等映射落到 ETS
      _ = ThreadStore.all()

      assert %{thread_id: "thread-abc", turns: 7} = ThreadStore.get("SF-83323")
    end

    test "同一工单项再次 put 会覆盖为最新线程" do
      ThreadStore.put("SF-83324", "thread-old", 3)
      ThreadStore.put("SF-83324", "thread-new", 9)

      # 等待最后一次 cast 生效
      wait_until(fn ->
        case ThreadStore.get("SF-83324") do
          %{thread_id: "thread-new", turns: 9} -> true
          _ -> false
        end
      end)

      assert %{thread_id: "thread-new", turns: 9} = ThreadStore.get("SF-83324")
    end

    test "空线程 id 不写入，避免下一轮拿空值去续接" do
      assert :ok = ThreadStore.put("SF-1", "", 5)
      assert :ok = ThreadStore.put("SF-1", nil, 5)
      assert ThreadStore.get("SF-1") == nil
    end

    test "非法轮数归零而不是报错" do
      ThreadStore.put("SF-2", "thread-2", -3)
      wait_until(fn -> match?(%{turns: 0}, ThreadStore.get("SF-2")) end)
      assert %{thread_id: "thread-2", turns: 0} = ThreadStore.get("SF-2")
    end
  end

  describe "删除" do
    test "delete/1 之后 get/1 返回 nil" do
      ThreadStore.put("SF-3", "thread-3", 1)
      wait_until(fn -> ThreadStore.get("SF-3") != nil end)

      assert :ok = ThreadStore.delete("SF-3")
      wait_until(fn -> ThreadStore.get("SF-3") == nil end)

      assert ThreadStore.get("SF-3") == nil
    end
  end

  describe "落盘" do
    test "映射写进 JSON 文件，重启后仍能读回", %{threads_file: file} do
      ThreadStore.put("SF-83323", "thread-persist", 12)
      wait_until(fn -> File.exists?(file) && file_contains?(file, "thread-persist") end)

      assert {:ok, body} = File.read(file)
      assert {:ok, decoded} = Jason.decode(body)
      assert %{"thread_id" => "thread-persist", "turns" => 12} = decoded["SF-83323"]
    end

    test "文件损坏时退化成空映射，不抛异常", %{threads_file: file} do
      File.write!(file, "{ 这不是 JSON")

      # 进程未启动路径会读文件；损坏时必须退化成「没有记录」而不是崩掉。
      assert ThreadStore.get("SF-anything") == nil
    end
  end

  defp wait_until(fun, attempts \\ 60) do
    cond do
      fun.() ->
        :ok

      attempts <= 0 ->
        :ok

      true ->
        Process.sleep(10)
        wait_until(fun, attempts - 1)
    end
  end

  defp file_contains?(file, needle) do
    case File.read(file) do
      {:ok, body} -> String.contains?(body, needle)
      _ -> false
    end
  end
end
