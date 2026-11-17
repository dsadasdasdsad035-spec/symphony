defmodule SymphonyElixir.Agent.ModelTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.Agent.Model
  alias SymphonyElixir.Tracker.Issue
  alias SymphonyElixir.Workflow

  defp issue(attrs \\ []) do
    %Issue{
      id: "83324",
      identifier: "SF-83324",
      title: Keyword.get(attrs, :title, "列表页翻页后数据重复"),
      description: Keyword.get(attrs, :description, "复现步骤：进入列表，翻到第二页"),
      state: "active",
      labels: [],
      attributes: %{"keywords" => ""},
      blocked_by: [],
      dispatchable: true
    }
  end

  describe "vision_signals/1" do
    test "OSS 截图链接命中" do
      issue = issue(description: "截图：https://sieiotoss.oss-cn-shanghai.aliyuncs.com/file/updata/abc.png")
      assert Model.multimodal?(issue)
      assert [signal | _] = Model.vision_signals(issue)
      assert signal =~ "image_url"
    end

    test "带查询串的图片链接也命中" do
      issue = issue(description: "见 https://cdn.example.com/a/b.JPEG?x-oss-process=image/resize,w_800")
      assert Model.multimodal?(issue)
    end

    test "Markdown 图片与 img 标签命中" do
      assert Model.multimodal?(issue(description: "![步骤](https://x.com/shot)"))
      assert Model.multimodal?(issue(description: ~s(<img src="https://x.com/shot" />)))
    end

    test "纯文字工单不命中" do
      refute Model.multimodal?(issue())
    end

    test "非 Issue 结构不炸" do
      refute Model.multimodal?(%{title: "x"})
      assert Model.vision_signals(nil) == []
    end
  end

  describe "resolve/1" do
    test "带图工单切多模态模型" do
      write_workflow_file!(Workflow.workflow_file_path(),
        agent_model: "local-glm5.3",
        agent_multimodal_model: "local-glm5.3-flash"
      )

      decision = Model.resolve(issue(description: "截图 https://x.com/a.png"))
      assert decision.model == "local-glm5.3-flash"
      assert decision.reason == :multimodal
    end

    test "纯文字工单用默认文本模型" do
      write_workflow_file!(Workflow.workflow_file_path(),
        agent_model: "local-glm5.3",
        agent_multimodal_model: "local-glm5.3-flash"
      )

      decision = Model.resolve(issue())
      assert decision.model == "local-glm5.3"
      assert decision.reason == :text
    end

    test "带图但没配多模态模型时退回文本模型" do
      write_workflow_file!(Workflow.workflow_file_path(), agent_model: "local-glm5.3")

      decision = Model.resolve(issue(description: "截图 https://x.com/a.png"))
      assert decision.model == "local-glm5.3"
      assert decision.reason == :text
    end

    test "两个模型都不配时不覆盖，由 CLI 自身配置决定" do
      write_workflow_file!(Workflow.workflow_file_path())

      assert %{model: nil, reason: :default} = Model.resolve(issue())
      assert %{model: nil} = Model.resolve(issue(description: "https://x.com/a.png"))
    end
  end
end
