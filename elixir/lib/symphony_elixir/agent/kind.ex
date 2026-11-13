defmodule SymphonyElixir.Agent.Kind do
  @moduledoc """
  根据工单项上的关键字（善治 `keywords`、Linear/Jira 标签等）解析要使用的 agent CLI。

  约定：测试在 keywords/标签里写 CLI 名称，例如 `codex`、`cursor cli`、`zcode`、`claude`。
  空白或未识别时默认 `codex`。
  """

  require Logger

  alias SymphonyElixir.Tracker.Issue

  @default_kind "codex"

  @kind_to_module %{
    "codex" => SymphonyElixir.Agent.Codex,
    "cursor_cli" => SymphonyElixir.Agent.CursorCli,
    "zcode" => SymphonyElixir.Agent.Zcode,
    "claude_cli" => SymphonyElixir.Agent.ClaudeCli
  }

  @token_to_kind %{
    "codex" => "codex",
    "codex cli" => "codex",
    "cursor" => "cursor_cli",
    "cursor cli" => "cursor_cli",
    "zcode" => "zcode",
    "zcode cli" => "zcode",
    "claude" => "claude_cli",
    "claude cli" => "claude_cli",
    "claude code" => "claude_cli"
  }

  @remote_kinds MapSet.new(["codex"])

  @spec default_kind() :: String.t()
  def default_kind, do: @default_kind

  @spec resolve(Issue.t()) :: String.t()
  def resolve(%Issue{} = issue) do
    {kind, _} = resolve_with_reason(issue)
    kind
  end

  @spec resolve_with_reason(Issue.t()) :: {String.t(), :default | :matched | {:unknown_tokens, [String.t()]}}
  def resolve_with_reason(%Issue{} = issue) do
    {keywords, label_tokens} = agent_hint_tokens(issue)
    all = keywords ++ label_tokens

    case first_known_kind(all) do
      nil ->
        if Enum.any?(keywords, &(String.trim(&1) != "")) do
          {:default, {:unknown_tokens, keywords}}
        else
          {@default_kind, :default}
        end

      {kind, _token} ->
        {kind, :matched}
    end
    |> case do
      {:default, {:unknown_tokens, tokens}} ->
        Logger.warning(
          "工单项 keywords 未识别任何 agent CLI，回退到 codex issue_identifier=#{issue.identifier} tokens=#{inspect(tokens)}"
        )

        {@default_kind, {:unknown_tokens, tokens}}

      other ->
        other
    end
  end

  @spec impl_for(Issue.t()) :: {String.t(), module()}
  def impl_for(%Issue{} = issue) do
    {kind, _} = resolve_with_reason(issue)
    {kind, module_for_kind(kind)}
  end

  @spec module_for_kind(String.t()) :: module()
  def module_for_kind(kind) when is_binary(kind) do
    Map.get(@kind_to_module, kind, @kind_to_module[@default_kind])
  end

  @spec remote_capable?(String.t()) :: boolean()
  def remote_capable?(kind) when is_binary(kind), do: MapSet.member?(@remote_kinds, kind)
  def remote_capable?(_kind), do: false

  @display_labels %{
    "codex" => "Codex",
    "cursor_cli" => "Cursor CLI",
    "zcode" => "ZCode",
    "claude_cli" => "Claude CLI"
  }

  @doc "看板/API 展示用的短标签。"
  @spec display_label(String.t() | nil) :: String.t()
  def display_label(kind) when is_binary(kind) do
    Map.get(@display_labels, kind, kind)
  end

  def display_label(_kind), do: display_label(@default_kind)

  @doc false
  @spec known_tokens() :: MapSet.t(String.t())
  def known_tokens do
    MapSet.new(Map.keys(@token_to_kind))
  end

  defp agent_hint_tokens(%Issue{} = issue) do
    keyword_tokens = keywords_tokens(issue)
    label_tokens = label_agent_tokens(issue.labels)
    {keyword_tokens, label_tokens}
  end

  defp keywords_tokens(%Issue{attributes: %{keywords: keywords}}) when is_binary(keywords) do
    expand_keyword_corpus(keywords)
  end

  defp keywords_tokens(%Issue{attributes: %{"keywords" => keywords}}) when is_binary(keywords) do
    expand_keyword_corpus(keywords)
  end

  defp keywords_tokens(_issue), do: []

  defp expand_keyword_corpus(keywords) when is_binary(keywords) do
    trimmed = String.trim(keywords)

    if trimmed == "" do
      []
    else
      segments =
        trimmed
        |> String.split(~r/[,，;；\n]+/, trim: true)
        |> Enum.flat_map(&segments_with_cli_pairs/1)

      [normalize_token(trimmed) | segments]
      |> Enum.uniq()
      |> Enum.reject(&(&1 == ""))
    end
  end

  defp segments_with_cli_pairs(segment) when is_binary(segment) do
    normalized = normalize_token(segment)
    words = String.split(normalized, ~r/\s+/, trim: true)

    pairs =
      words
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.map(fn
        [left, "cli"] -> "#{left} cli"
        [left, "code"] -> "#{left} code"
        _ -> nil
      end)
      |> Enum.reject(&is_nil/1)

    [normalized | pairs]
  end

  defp label_agent_tokens(labels) when is_list(labels) do
    labels
    |> Enum.map(&normalize_token/1)
    |> Enum.filter(&MapSet.member?(known_tokens(), &1))
  end

  defp label_agent_tokens(_labels), do: []

  defp first_known_kind(tokens) when is_list(tokens) do
    Enum.find_value(tokens, fn token ->
      case Map.get(@token_to_kind, token) do
        nil -> nil
        kind -> {kind, token}
      end
    end)
  end

  @spec normalize_token(String.t()) :: String.t()
  def normalize_token(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.downcase()
    |> String.replace(~r/\s+/, " ")
  end
end
