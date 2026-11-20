defmodule SymphonyElixir.Smoke.ResolveGate do
  @moduledoc """
  在调用善治 resolve 之前校验工作区内的冒烟通行证与分层要求。

  凭证由 `smoke_test.sh` 写入，Agent 不得伪造；关不掉时设 `SMOKE_RESOLVE_GATE=0`。
  """

  alias SymphonyElixir.Config
  alias SymphonyElixir.Shanzhi.Client
  alias SymphonyElixir.Workspace

  @gate_env "SMOKE_RESOLVE_GATE"
  @requirement_rel "smoke/smoke-requirement.json"
  @pass_rel "smoke/smoke-pass.json"

  @spec enabled?() :: boolean()
  def enabled?, do: System.get_env(@gate_env, "1") not in ["0", "false", "FALSE", "off"]

  @spec check(term(), String.t(), keyword()) :: :ok | {:error, map()}
  def check(bug_id, comment, opts \\ []) when is_binary(comment) do
    if enabled?() do
      with {:ok, workspace} <- workspace_for(bug_id, opts),
           {:ok, requirement} <- read_requirement(workspace),
           {:ok, pass} <- read_pass(workspace),
           :ok <- identifier_match(pass, bug_id, opts),
           :ok <- layers_satisfied(requirement, pass),
           :ok <- comment_has_report(comment, pass),
           :ok <- comment_has_evidence_sections(comment) do
        :ok
      else
        {:error, reason} when is_map(reason) -> {:error, reason}
        {:error, reason} -> {:error, gate_error(inspect(reason), remediation_default())}
      end
    else
      :ok
    end
  end

  defp workspace_for(bug_id, opts) do
    with_ws =
      case Keyword.get(opts, :workspace) do
        ws when is_binary(ws) and ws != "" ->
          if File.dir?(ws),
            do: {:ok, ws},
            else: {:error, gate_error("工作区不存在: #{ws}", remediation_default())}

        _ ->
          :continue
      end

    case with_ws do
      {:ok, _} = ok ->
        ok

      {:error, _} = err ->
        err

      :continue ->
        case Keyword.get(opts, :issue) do
          %{identifier: id} = issue when is_binary(id) ->
            path = Path.join(Config.local_workspace_root(), Workspace.workspace_key(issue))

            if File.dir?(path),
              do: {:ok, path},
              else: missing_workspace(path)

          _ ->
            identifier = Client.identifier(bug_id)
            path = Path.join(Config.local_workspace_root(), Workspace.workspace_key(identifier))

            if File.dir?(path),
              do: {:ok, path},
              else: missing_workspace(path)
        end
    end
  end

  defp missing_workspace(path) do
    {:error,
     gate_error(
       "找不到缺陷工作区 #{path}，无法校验冒烟通行证。",
       "确认在 issue 工作区内完成发版与 smoke_test.sh --publish-report。"
     )}
  end

  defp read_requirement(workspace) do
    path = Path.join(workspace, @requirement_rel)

    case File.read(path) do
      {:ok, body} ->
        with {:ok, map} <- Jason.decode(body),
             layers when layers in ["API", "UI", "BOTH"] <- map["required_layers"] do
          {:ok, map}
        else
          _ ->
            {:error,
             gate_error(
               "缺少或无效的 #{@requirement_rel}（需要 required_layers: API|UI|BOTH）。",
               "开工后先写入 smoke/smoke-requirement.json，见 WORKFLOW「冒烟分层判定」。"
             )}
        end

      {:error, _} ->
        {:error,
         gate_error(
           "未找到 #{@requirement_rel}。",
           "根据善治复现步骤判定 UI/API/BOTH，写入 smoke/smoke-requirement.json 后再 resolve。"
         )}
    end
  end

  defp read_pass(workspace) do
    path = Path.join(workspace, @pass_rel)

    case File.read(path) do
      {:ok, body} ->
        with {:ok, map} <- Jason.decode(body) do
          if pass_valid?(map), do: {:ok, map}, else: invalid_pass()
        else
          _ -> invalid_pass()
        end

      {:error, _} ->
        {:error,
         gate_error(
           "未找到 #{@pass_rel}。",
           "发版后执行 smoke_test.sh --issue <SF-xxx> --publish-report --mr-dir ... --mr ...，且须 pytest 通过并成功发 MR 评论。"
         )}
    end
  end

  defp pass_valid?(%{"verdict" => "PASS", "report_url" => url}) when is_binary(url) and url != "",
    do: true

  defp pass_valid?(%{"passes" => passes}) when is_list(passes) do
    Enum.any?(passes, fn
      %{"verdict" => "PASS", "report_url" => url} when is_binary(url) and url != "" -> true
      _ -> false
    end)
  end

  defp pass_valid?(_), do: false

  defp invalid_pass() do
    {:error,
     gate_error(
       "冒烟通行证无效：需要 verdict=PASS 且非空 report_url（须带 --publish-report）。",
       "重跑 smoke_test.sh，确保 MR 评论链接已生成。"
     )}
  end

  defp identifier_match(pass, bug_id, opts) do
    expected =
      cond do
        id = Keyword.get(opts, :issue) |> issue_identifier() -> id
        true -> Client.identifier(bug_id)
      end

    actual = Map.get(pass, "issue_identifier")

    passes = Map.get(pass, "passes", [])
    identifiers = Enum.map(passes, &Map.get(&1, "issue_identifier")) ++ [actual]

    if expected in Enum.filter(identifiers, &is_binary/1) do
      :ok
    else
      {:error,
       gate_error(
         "通行证 issue 与当前缺陷不一致（期望 #{expected}）。",
         "在缺陷工作区内重跑 smoke_test.sh --issue #{expected}。"
       )}
    end
  end

  defp issue_identifier(%{identifier: id}) when is_binary(id), do: id
  defp issue_identifier(_), do: nil

  defp layers_satisfied(%{"required_layers" => required}, pass) do
    layers = collect_layers(pass)

    case required do
      "API" ->
        if "API" in layers, do: :ok, else: layer_missing("API")

      "UI" ->
        if "UI" in layers, do: :ok, else: layer_missing("UI")

      "BOTH" ->
        if "API" in layers and "UI" in layers,
          do: :ok,
          else: layer_missing("API 与 UI（各跑一次 smoke_test.sh 或 passes[] 含两层）")
    end
  end

  defp collect_layers(%{"layer" => layer}), do: [layer]
  defp collect_layers(%{"passes" => passes}) when is_list(passes) do
    passes |> Enum.map(& &1["layer"]) |> Enum.reject(&is_nil/1)
  end
  defp collect_layers(_), do: []

  defp layer_missing(need) do
    {:error,
     gate_error(
       "冒烟层不满足要求：还需要 #{need} 层 PASS 凭证。",
       "界面类缺陷不能只用 API 冒充；对照 smoke-requirement.json 补跑对应层用例。"
     )}
  end

  defp comment_has_report(comment, pass) do
    url = primary_report_url(pass)

    cond do
      not is_binary(url) or url == "" ->
        {:error,
         gate_error(
           "通行证缺少 report_url。",
           "重跑 smoke_test.sh --publish-report。"
         )}

      String.contains?(comment, url) ->
        :ok

      String.contains?(comment, "data-smoke-report") and String.contains?(comment, url) ->
        :ok

      Regex.match?(~r/data-smoke-report\s*=\s*["']#{Regex.escape(url)}["']/u, comment) ->
        :ok

      true ->
        {:error,
         gate_error(
           "解决说明未包含冒烟报告链接（须与通行证 report_url 一致，或 data-smoke-report 属性）。",
           "将 MR 评论链接粘贴进 comment，或使用 evidence.html 中的报告链接。"
         )}
    end
  end

  defp primary_report_url(%{"report_url" => url}) when is_binary(url), do: url

  defp primary_report_url(%{"passes" => passes}) when is_list(passes) do
    passes
    |> Enum.find_value(fn
      %{"report_url" => url} when is_binary(url) and url != "" -> url
      _ -> nil
    end)
  end

  defp primary_report_url(_), do: nil

  defp comment_has_evidence_sections(comment) do
    cond do
      not String.contains?(comment, "测试边界") ->
        {:error,
         gate_error(
           "解决说明缺少「测试边界」段落。",
           "在 comment 中写明验什么/不验什么（见 WORKFLOW 八段式证据）。"
         )}

      not String.contains?(comment, "步骤对应") ->
        {:error,
         gate_error(
           "解决说明缺少「步骤对应」段落。",
           "说明善治复现步骤与 pytest 用例步骤的对应关系。"
         )}

      true ->
        :ok
    end
  end

  defp gate_error(message, remediation) do
    %{
      "error" => %{
        "message" => message,
        "remediation" => remediation,
        "gate" => "smoke_resolve"
      }
    }
  end

  defp remediation_default do
    "见 WORKFLOW「冒烟：在开发环境验过才能 resolve」与硬闸门一节。"
  end
end