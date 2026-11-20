# Design

## Context

见 `proposal.md`。执行侧已有 `smoke_test.sh`（层按路径判定、selfcheck、版本门、MR 报告发布、`mr_diff_kind`）。
编排侧 `shanzhi_resolve_bug` 目前零校验。`smoke-before-resolve/design.md` 曾明确软闸门是为快速落地；
现用户要求**强脚本门禁**，须在 Symphony 进程内 enforce。

**约束**

- 善治 `comment` 仍是 HTML 字符串；校验以「结构化段落 + 链接 + 本地 JSON」组合完成，不指望善治新字段。
- resolve 后工作区销毁：通行证必须在 resolve **之前**存在且可读。
- 单副本 Symphony；通行证文件 per-workspace，无中央 DB。

## Goals / Non-Goals

**Goals**

- UI 类 Bug 无 UI 层 pytest PASS + MR 报告时，**稳定无法 resolve**。
- 证据链：uitest 用例 → `smoke_test.sh` → MR 报告 → `smoke-pass.json` → resolve comment。
- 失败时 Agent 收到可执行 remediation（缺哪层、缺哪文件、缺哪链接）。

**Non-Goals**

- 自动 NLP 分类 Bug（v1 人工/Agent 写 `smoke-requirement.json`）。
- CI 集成、多租户通行证共享。
- 豁免时仍自动 resolve（豁免继续只走 remark，不开放 bypass API）。

## Decisions

### 决策 1：双层 JSON 文件落在工作区根

| 文件 | 写入方 | 用途 |
|---|---|---|
| `smoke-requirement.json` | Agent（首轮） | `required_layers`, `rationale`, `linked_steps[]` |
| `smoke-pass.json` | **仅** `smoke_test.sh` | 脚本产出的 PASS/FAIL 凭证 |

路径：`$WORKSPACE/smoke/smoke-requirement.json` 与 `$WORKSPACE/smoke/smoke-pass.json`（目录固定，避免与代码子模块混淆）。

**理由**：requirement 允许 Agent 写；pass 必须脚本写，防伪造。Symphony 读两者做 conjunctive 校验。

### 决策 2：`smoke-pass.json` 最小 schema（v1）

```json
{
  "schema_version": 1,
  "issue_identifier": "SF-83221",
  "verdict": "PASS",
  "layer": "UI",
  "case": "testcase/iidp/iidp/test_xxx.py::Test_X::test_y",
  "host": "http://192.168.181.104:30669/iidp/",
  "version_note": "sie-iidp-de-tool=1.0.0",
  "report_url": "http://192.168.175.55:9888/.../merge_requests/62#note_123",
  "report_md": "/data2/workspaces/SF-83221/smoke-run-20261120/report.md",
  "uitest_ref": { "branch": "smoke/SF-83221-xxx", "sha": "abc1234" },
  "finished_at": "2026-11-20T09:00:00+08:00",
  "runner": "smoke_test.sh"
}
```

- `report_url` 必填（resolve 硬闸门）；未 `--publish-report` 成功则不写 PASS。
- BOTH：允许多个文件 `smoke-pass-api.json` / `smoke-pass-ui.json`，或数组 `passes[]`——**v1 选 `passes[]` 单文件**，减少碎片。

**防伪造（v1 务实）**：pass 文件内增加 `content_hash`（对 junit + case + layer + issue 的 sha256），由脚本写入；Symphony 可选二次读 junit 路径验证文件存在。完整 HMAC 留给 v2（需 Symphony 给脚本注入 nonce）。

### 决策 3：Elixir 在 `AgentTool.execute(@resolve_bug, ...)` 内校验

新增模块 `SymphonyElixir.Smoke.ResolveGate`：

1. 从 `opts` 取 `workspace_path`、`issue_identifier`（需编排层传入——查 `agent_tool` 调用链，若无则在 orchestrator 填 `Keyword`）。
2. 读 `smoke-requirement.json` → `required_layers`。
3. 读 `smoke-pass.json` → 校验 `issue_identifier`、`verdict==PASS`、`report_url` 非空。
4. 层覆盖：UI 需要 passes 中至少一条 `layer==UI`；API 需要 `API`；BOTH 需要两条或一条 UI 且用例标记 `e2e`（v1：两条 pass 简单可靠）。
5. 解析 `comment` HTML：必须包含 `report_url` 子串（或 `data-smoke-report` 属性，WORKFLOW 模板统一）。
6. 失败返回 `%{"error" => "...", "remediation" => "..."}` 形态 map，不调用 `Client.resolve_bug`。

**替代**：hook MCP launcher——拒绝对称性差；在 Client.resolve_bug 前拦截更清晰。

### 决策 4：`smoke_test.sh` 参数扩展

- `--issue SF-xxxxx`：写入通行证（缺则从 `basename $PWD` 推断，不可靠则必填）。
- `--require-publish`：与 resolve 硬闸门联动的默认模式（由 WORKFLOW 要求 Agent 总是带 `--publish-report`）。
- 成功路径末尾写 JSON；失败写 `smoke-fail.json`（可选）。

报告 `write_report` 增加章节（Python 段）：

- **测试边界**：从环境变量 `SMOKE_SCOPE` / `SMOKE_OUT_OF_SCOPE` 或由 Agent 通过 `--scope "..." --out-of-scope "..."` 传入。
- **步骤对应**：`--steps-map` 指向工作区内的 markdown 或内联 heredoc 路径。

若未提供边界/步骤，脚本 **warn 且退出码 0 仍写 PASS**，但 resolve 闸门检查 comment 模板——**v1 闸门查 comment HTML 必含 `<h4>测试边界</h4>` 等标记**，倒逼 Agent 填写；脚本侧可选 `--strict-evidence` 未来再强制。

### 决策 5：WORKFLOW 分类决策树（提示词）

```
读善治复现步骤
  |-- 无页面/点击/弹窗/渲染描述 -> required_layers=API
  |-- 主要为界面 -> UI
  |-- 接口+列表/页面联动 -> BOTH
写 smoke-requirement.json + remark 首条备注
发版 -> smoke_test.sh (层匹配) -> publish-report -> smoke-pass.json
resolve comment 必须粘贴 evidence.html + 边界/步骤段落 + 报告链接
```

界面类 **禁止** `smoke_api.sh` 作为交付冒烟。

### 决策 6：与既有软闸门变更的关系

- 不修改 `smoke-before-resolve` 历史 artifact；本变更 supersede 其「软闸门」决策说明。
- `openspec/archive` 或 tasks 5.x 可在实现后更新 `smoke-before-resolve/design.md` 风险表「已升级硬闸门」。

## Risks / Trade-offs

| 风险 | 缓解 |
|---|---|
| Agent 错标 `API` 逃避 UI | WORKFLOW 强调；人工评审 requirement 文件；后续可从善治标签只读 |
| BOTH 双倍 turn 成本 | 接受；或合并为一条 UI e2e 用例（文档推荐） |
| 凭证路径与工作区不一致 | 编排必须传 `workspace_path`；单测覆盖 gate |
| 合并后 MR 评论删不了导致重复发 | 沿用 report 链接更新策略；闸门只验 URL 存在 |
| 旧 Bug 在途无 requirement 文件 | 首次 resolve 失败 → Agent 补写 requirement 并重跑 |

## Migration

1. 先上脚本写 JSON + WORKFLOW（软提示 requirement 文件）。
2. 上 Elixir gate（可环境变量 `SMOKE_RESOLVE_GATE=1` 灰度，默认开）。
3. ConfigMap 同步 scripts + 重建镜像含 Elixir gate。

## Open Questions

- `issue_identifier` 注入 tool opts 的准确调用点（实现 tasks 中首个 spike 确认）。
- BOTH 是否允许「仅 UI e2e」单凭证（产品决策：v1 要求两条更严）。