# Proposal

## Why

`smoke-before-resolve` 已在 `WORKFLOW.md` 写明：界面类缺陷不得仅用接口层替代、resolve 前须有冒烟证据与 MR 报告链接。
但闸门强度仍为**软约束**——`shanzhi_resolve_bug` 不校验 `comment`，Agent 可以不上传 pytest 报告、用自然语言写「自测通过」，或对 UI 缺陷只跑 API 用例后 resolve。
这与「善治上点已解决 = 环境里该问题真的没了」的目标冲突：人工验收无法区分模型主观结论与脚本客观 PASS。

现在 `smoke_test.sh`、报告发 MR、`selfcheck` 等执行侧能力已就绪（含 `fix-smoke-report-target` 的目标路由），
具备把「软提示」升级为**机器可校验硬闸门**的条件。若再拖，会持续出现「备注像测过了、MR 里没有可复跑用例」的交付。

## What Changes

- **缺陷冒烟分层判定**：在工作区落一份机器可读的「本 Bug 要求的冒烟层」（`UI` / `API` / `BOTH`），
  由 Agent 在开工后根据善治复现步骤填写，并受 WORKFLOW 决策树约束；界面操作为主的 Bug 标记为 `UI` 或 `BOTH`。
- **冒烟通行证（pass credential）**：`smoke_test.sh` 在 **pytest 退出码 0** 且（若要求）**已 `--publish-report` 成功发到代码 MR** 时，
  在工作区写入结构化 `smoke-pass.json`（含 `issue_id`、`layer`、`case`、`verdict`、`report_url`、`uitest_ref`、时间戳、校验摘要）。
  失败、层不匹配、或未发布报告时不写 PASS 凭证（可写 FAIL 记录供排查）。
- **resolve 硬闸门（Symphony）**：`shanzhi_resolve_bug` 在调用善治 API 前校验：
  - 工作区存在与当前 `issue_id` 匹配的有效 `smoke-pass.json`；
  - 凭证中的 `layer` 满足该 Bug 的要求层（UI 类不得仅 API）；
  - `comment` 含报告链接且与凭证一致（或凭证中的 `report_url` 非空）。
  不满足则工具返回错误，**不**调用善治 resolve。
- **证据内容加厚（文档 + 报告）**：resolve 备注与 `report.md` 模板增加固定段落：
  **测试用例来源（uitest 分支/MR）**、**与善治复现步骤的逐步对应**、**测试边界（验什么 / 不验什么）**；
  禁止仅凭大模型叙述代替 `smoke_test.sh` 输出与 MR 评论链接。
- **WORKFLOW / skill 同步**：交付顺序、分类决策树、resolve 前自检清单、豁免收紧（有界面操作的一般不得用「接口替代 UI」豁免）。

**明确不做（Non-Goals）**

- 不把冒烟搬进 CI；仍在单次派发内由 Agent 执行。
- 不自动从善治正文 NLP 分类（第一版靠 Agent 声明 + 硬闸门校验层与凭证，避免误判锁死）。
- 不改动善治服务端 schema；拦截发生在 Symphony `agent_tool` 层。

## Capabilities

### New Capabilities

- `smoke-pass-credential`: 冒烟通过后产出的机器可读凭证格式、写入时机、与工作区/缺陷号的绑定，以及 FAIL 侧车记录。

### Modified Capabilities

- `smoke-verification`: 从软闸门升级为硬闸门——界面类 MUST UI 层凭证、纯后端 MUST API 层凭证、证据须含用例/MR/边界/步骤对应；resolve 须凭证与报告链接一致。

## Impact

- `deploy/smoke_test.sh`：写 `smoke-pass.json`；可选 `--issue` / 从环境变量读 `issue_identifier`；报告增加边界与步骤段落（或从用例 docstring 抽取）。
- `deploy/WORKFLOW.md`、`deploy/skills/iidp-smoke/SKILL.md`：分类树、硬闸门说明、resolve 拒绝时的补救步骤。
- `elixir/lib/symphony_elixir/shanzhi/agent_tool.ex`（及必要时小模块）：resolve 前校验凭证与层。
- 编排侧需把当前 issue id / workspace 路径传入 tool 执行上下文（若尚无则在本变更补齐）。
- **BREAKING（对 Agent 行为）**：无有效凭证时 `shanzhi_resolve_bug` 将稳定失败；习惯「口头通过」的流程必须改为先跑脚本再 resolve。
- 依赖：工作区在 resolve 前仍存在（与现网一致）；K8s 无需新镜像能力（playwright 已有）。