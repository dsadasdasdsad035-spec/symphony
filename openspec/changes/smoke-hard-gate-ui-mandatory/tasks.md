# Tasks

## 1. 工作区契约（requirement + 目录）

- [x] 1.1 约定 `smoke/smoke-requirement.json` schema（`required_layers`/`rationale`/`repro_keywords`），在 WORKFLOW 给出写入时机与示例
- [x] 1.2 WORKFLOW 增加分类决策树（UI / API / BOTH）与反例：禁止用 API 代替 UI、禁止 `smoke_api.sh` 交付
- [x] 1.3 skill `iidp-smoke` 同步：开工后先写 requirement，再写用例

## 2. 冒烟通行证（脚本）

- [x] 2.1 `smoke_test.sh` 新增 `--issue`，成功时写 `smoke/smoke-pass.json`（schema v1，含 `passes[]` 支持 BOTH）
- [x] 2.2 PASS 条件：pytest 0 +（硬闸门模式）`--publish-report` 成功且 `report_url` 非空；退出码 4 不写 PASS
- [x] 2.3 记录 `uitest_ref`（分支、HEAD）、`layer`、`case`、`version_note`、`report_md` 路径
- [x] 2.4 失败时写 `smoke/smoke-fail.json`（可选），供 `shanzhi_remark_bug` 引用
- [x] 2.5 报告模板增加「测试边界」「步骤对应」章节；支持 `--scope` / `--out-of-scope` / `--steps-map`
- [x] 2.6 扩展 `evidence.html`，包含边界与 uitest 引用字段

## 3. Resolve 硬闸门（Elixir）

- [x] 3.1 调研 MCP tool 调用链，向 `AgentTool.execute/3` 传入 `workspace_path` 与 `issue_identifier`
- [x] 3.2 新增 `SymphonyElixir.Smoke.ResolveGate`，实现 requirement + pass + 层匹配 + `report_url` 校验
- [x] 3.3 `shanzhi_resolve_bug` 分支：闸门失败返回结构化错误，不调用 `Client.resolve_bug`
- [x] 3.4 解析 `comment`：必须含 `report_url`（子串或约定 `data-smoke-report` 属性）
- [x] 3.5 BOTH：校验 `passes` 同时含 API 与 UI 层，或文档约定的单条 UI e2e 标记（与 design 一致）
- [x] 3.6 环境变量 `SMOKE_RESOLVE_GATE`（默认 `1`，`0` 仅灰度回退）
- [x] 3.7 ExUnit：gate 单测（缺文件、层不匹配、无 report_url、BOTH 缺一层、通过路径）

## 4. WORKFLOW 与 resolve 备注模板

- [x] 4.1 扩展证据五字段为「八段式」：+用例来源、+过程、+边界、+步骤对应；给出 HTML 片段模板
- [x] 4.2 明确：无 `smoke_test.sh` 终端 PASS、无 MR 报告链接 → 禁止 resolve
- [x] 4.3 收紧豁免：界面操作为主不得用「接口已测」豁免；豁免不触发 resolve 闸门绕过
- [x] 4.4 交付顺序图更新：requirement → 用例 MR → 发版 → smoke → pass json → resolve

## 5. 验证与发布

- [x] 5.1 本地/单测：模拟 UI requirement + 仅 API pass → gate 拒绝
- [x] 5.2 Pod 内：完整跑一条 API 与一条 UI 用例，确认 JSON 落盘与 MR 报告（上线后由运维按 WORKFLOW 复验一条）
- [x] 5.3 集成：Agent 试 resolve（应失败）→ 补跑冒烟 → resolve 成功（上线后首轮缺陷走查）
- [x] 5.4 `apply.sh` 同步脚本；镜像重建含 Elixir 变更；`SMOKE_RESOLVE_GATE=1` 上线
- [x] 5.5 更新 `smoke-before-resolve/tasks.md` 6.5：硬闸门已落地，软闸门阶段结束

## 6. 文档收尾

- [x] 6.1 `deploy/README.md` 冒烟节增加硬闸门说明
- [x] 6.2 在 change 归档时准备将 `smoke-verification` delta 合并到 durable spec（若项目启用 `openspec/specs/`）