defmodule SymphonyElixir.Agent.Model do
  @moduledoc """
  按工单项决定这一轮用哪个模型。

  ## 为什么需要它

  以前模型由 `.env` 的 `AGENT_MODEL` 统一定死，经 `entrypoint.sh` 写进各 CLI 的配置文件，
  运行时无法按工单调整。实际踩到的坑是：纯文本模型（`local-glm5.3`）不是多模态模型，
  而善治 Bug 的描述里常带截图，Agent 按提示词去 `view_image` 会被网关以
  `not a multimodal model` 拒绝，之后整条线程退化成「只表态、不调工具」的空转。

  这里改成：**默认用推理更强的纯文本模型，只有工单确实带图时才切到多模态模型**。
  判定只看工单自身的文本（描述/标题），不猜测、不调用任何外部接口。

  ## 配置

  `WORKFLOW.md` 的 `agent` 段：

      agent:
        model: local-glm5.3              # 纯文本工单用
        multimodal_model: local-glm5.3-flash  # 带图工单用

  任一留空表示「不覆盖」：Codex 回落到自身配置文件里的模型，其余 CLI 回落到各自
  的 `model` 配置。两个都不配时行为与改造前完全一致。
  """

  require Logger

  alias SymphonyElixir.Config
  alias SymphonyElixir.Tracker.Issue

  # 图片链接：以图片扩展名结尾，允许带查询串
  @image_url ~r/https?:\/\/[^\s"'<>)\]]+\.(?:png|jpe?g|gif|webp|bmp)(?:\?[^\s"'<>)\]]*)?/i
  # 富文本里内嵌的图片标签
  @image_tag ~r/<img\b/i
  # Markdown 图片语法
  @markdown_image ~r/!\[[^\]]*\]\([^)]+\)/

  @type decision :: %{
          model: String.t() | nil,
          reason: :multimodal | :text | :default,
          signals: [String.t()]
        }

  @doc """
  给出该工单这一轮应该使用的模型。

  `model` 为 `nil` 表示不覆盖，由 CLI 自身配置决定。
  """
  @spec resolve(Issue.t() | map()) :: decision()
  def resolve(%Issue{} = issue) do
    settings = settings()

    signals = vision_signals(issue)
    text_model = blank_to_nil(Map.get(settings, :model))
    multimodal_model = blank_to_nil(Map.get(settings, :multimodal_model))

    cond do
      signals != [] and is_binary(multimodal_model) ->
        log_decision(issue, multimodal_model, :multimodal, signals)
        %{model: multimodal_model, reason: :multimodal, signals: signals}

      is_binary(text_model) ->
        log_decision(issue, text_model, :text, signals)
        %{model: text_model, reason: :text, signals: signals}

      true ->
        %{model: nil, reason: :default, signals: signals}
    end
  end

  def resolve(_issue), do: %{model: nil, reason: :default, signals: []}

  @doc """
  工单里出现的「需要看图」的证据。

  只做文本匹配：命中图片链接、`<img>` 标签或 Markdown 图片语法即认为需要视觉能力。
  注意描述里出现 `.png` 文件名（比如代码里的静态资源名）也会命中，这是有意为之：
  误判成多模态的代价只是换一个模型，误判成纯文本则会让整轮跑废。
  """
  @spec vision_signals(Issue.t() | map()) :: [String.t()]
  def vision_signals(%Issue{} = issue) do
    issue
    |> issue_text()
    |> scan_signals()
  end

  def vision_signals(_issue), do: []

  @doc "供文档与测试引用：判定所需的模型是否真的不同。"
  @spec multimodal?(Issue.t() | map()) :: boolean()
  def multimodal?(issue), do: vision_signals(issue) != []

  # ---------------------------------------------------------------- 内部

  defp issue_text(%Issue{} = issue) do
    [issue.title, issue.description]
    |> Enum.filter(&is_binary/1)
    |> Enum.join("\n")
  end

  defp scan_signals(text) when is_binary(text) and text != "" do
    [
      {"image_url", @image_url},
      {"image_tag", @image_tag},
      {"markdown_image", @markdown_image}
    ]
    |> Enum.flat_map(fn {name, regex} ->
      case Regex.run(regex, text) do
        [match | _] -> ["#{name}:#{String.slice(match, 0, 80)}"]
        _ -> []
      end
    end)
  end

  defp scan_signals(_text), do: []

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp blank_to_nil(_value), do: nil

  # 配置缺失时（例如单测直接调 resolve）不炸，退化成「不覆盖」。
  defp settings do
    Config.settings!().agent
  rescue
    _ -> %{model: nil, multimodal_model: nil}
  end

  defp log_decision(%Issue{} = issue, model, reason, signals) do
    Logger.info("选用模型 model=#{model} reason=#{reason} issue_identifier=#{issue.identifier} signals=#{inspect(Enum.take(signals, 2))}")
  end
end
