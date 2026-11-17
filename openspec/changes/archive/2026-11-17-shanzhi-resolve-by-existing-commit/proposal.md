# Proposal

## Why

Symphony 的 agent 遇到「代码仓库里已有人提交了修复」的情况时，当前 `deploy/WORKFLOW.md`
明确禁止调用 `shanzhi_resolve_bug`，只能留备注等人工处理。但善治历史里已经出现两次
agent 自行按更合理方式处理的实例（#83178 引用既有提交 `587fdc3e` 解决、#83192 引用
`435b958c` 解决），说明这条约束与实际最佳行为冲突。

后果是已被他人修好的 Bug 长期停留在「激活」状态，每轮轮询都会重新派发、重复排查同一问题，
既浪费算力，也让迭代看板失真。

## What Changes

- 拆分 `deploy/WORKFLOW.md` 中「开工前必须先确认问题真实存在」一节。原文把两类完全不同的
  情况混成一条禁令，现按「能否指出具体提交」分流：
  - **已由既有提交修复**：允许调用 `shanzhi_resolve_bug`，`resolution` 用 `fixed`，
    `comment` 内附提交链接、提交备注、定位依据与核验结论。
  - **需求变更 / 环境问题 / 数据问题 / 误报**：保持原样，只 `shanzhi_remark_bug`，不 resolve。
- 增加硬闸门：必须能指出**一个具体 SHA**，且经 GitLab API 确认该提交**在目标分支上**。
  说不出 SHA 一律不许 resolve。
- 明确检索路径的优先级：操作历史 > 子模块本地 `git log` > GitLab `repository/commits?search=&ref_name=`。
- 明确链接拼接格式为 `http://192.168.175.55:9888/<project-path>/-/commit/<sha>`，
  因为该 GitLab 版本 commit API 的 `web_url` 返回 `null`，不可依赖。
- 补全「各仓库 GitLab 项目路径」表里缺失的 `sie-iidp-base-inner-web` 行。
- **不新增或修改任何 Elixir 代码**，不改变 agent 的工具集（「确认」仍不对 agent 开放）。

## Capabilities

### New Capabilities

无。本次是纯 prompt/配置改动，没有代码面，也不引入新的对外契约。

### Modified Capabilities

无。

## Impact

- `deploy/WORKFLOW.md`：唯一实现载体。该文件以 ConfigMap 目录方式挂载，Symphony 每秒热加载，
  **不需要重打镜像，也不需要重启 Pod**。
- 行为影响：善治 Bug 的 resolve 触发条件与 `comment` 结构。
- 不涉及：Elixir 代码、镜像构建、K8s 资源、MCP 工具权限。

## Non-Goals

- 不把提交链接写入 `resolvedAttachUrl`。该字段在 1722 条历史已解决/已关闭 Bug 中无一非空，
  格式与 UI 渲染均未经验证；`comment` 的 HTML 链接渲染已由 #83178、#83192 证实。
- 不做「派发前的自动预检」。提交与 Bug 的匹配是语义匹配（实测 7 个子模块全历史 0 条提交
  带 Bug 编号），自动化误判风险高于收益，仍由 agent 在会话内判断。
- 不改 `shanzhi_resolve_bug` 的入参结构。
