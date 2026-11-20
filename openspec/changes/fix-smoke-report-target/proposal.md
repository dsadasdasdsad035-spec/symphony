# Proposal

## Why

冒烟报告被系统性地发到了**聚合仓库** `mijiuye/iidp-aios`，而不是真正修复代码的子仓库。
实测 SF-83432：真实修复在 `sie-iidp-ai-agent-web` 的 MR !62（已合并，0 条报告），
而聚合仓库的 MR !11（diff 只有一行 `Subproject commit`）上堆了 8 条报告。
抽查另外 6 个真实修复 MR（agent-web !61/63/64/65/66、sie-snest !3389/3394），报告全部为 0。

后果是评审在改代码的 MR 里看不到任何验证证据，得跳到另一套仓库去翻；聚合仓库的指针 MR
则被大量报告噪声淹没。这个错位不是偶发——根因是 `WORKFLOW.md` 把聚合仓库写进了
`--gl-project` 的示例列表，而 Agent 的 cwd 与 `git remote` 恰好就是聚合仓库，
没有任何一步去核实目标 MR 里是否真含代码改动。

## What Changes

- 冒烟报告的目标仓库由**机械判定**得出，不再依赖 Agent 手填手猜：
  - 新增 `--mr-dir <子目录>`：从该目录的 `git remote origin` 推导 GitLab 项目路径，
    替代手工填写 `--gl-project`。
  - `--gl-project` 与 `--mr-dir` 二选一；同时给出时以 `--mr-dir` 为准并告警。
- 发布前校验目标 MR 的实质内容：若该 MR 的全部改动都是 `Subproject commit` 指针推进，
  拒绝发报告，并指出「本 MR 只推进子模块指针，真正改动在子仓库 X 的 MR」。
  这条判定允许合法场景——当缺陷本身只改根仓库（`openspec/`、`docs/`、`AGENTS.md`）时，
  MR 里没有指针行，校验放行。
- 修正 `WORKFLOW.md` 与 `iidp-smoke` skill 中把聚合仓库列为合法示例的错误描述，
  改为「按改动的子仓库推导」并给出判定步骤。
- 保留既有的「拒绝发到用例仓库」校验，作为同一类错误的另一个分支。

评论迁移不在此次范围内：已错位的 8 条评论保持不动，由后续人工或专门脚本处理。

## Capabilities

### New Capabilities

- `smoke-report-delivery`: 冒烟报告的去向规则——目标必须承载本次真实代码改动，
  如何从工作区目录推导目标仓库，以及在目标只含子模块指针推进时如何拒绝。

### Modified Capabilities

无。既有 `smoke-verification`（见变更 `smoke-before-resolve`）规定的「解 bug 前必须冒烟」
不改变；本次只改报告发到哪里、以及如何判定目的地，属于新增能力边界。

## Impact

- `deploy/smoke_test.sh`：新增 `--mr-dir` 参数；`publish_report` 增加目标 MR 的
  diff 内容校验；复用已有的 GitLab API 调用（`--noproxy '*'`）。
- `deploy/WORKFLOW.md`：修正 `--gl-project` 示例与判定步骤，说明聚合仓库仅在
  「缺陷本身只在根仓库」时才是正确目标。
- `deploy/skills/iidp-smoke/SKILL.md`：同步同一条约束与判定方法。
- 不改变镜像内容：脚本走 ConfigMap 挂载，`apply.sh --release-only` 即可生效。
- 依赖：GitLab 11.3 的 `merge_requests/:iid/changes` 接口；缺少 read_api 权限时降级为
  告警并继续发布（不能因为校验不可用就阻断交付）。
