# smoke-verification

## Purpose

规定界面/API 分层强制、结构化证据与 resolve 硬闸门行为（由变更 `smoke-hard-gate-ui-mandatory` 合并）。

## Requirements

### Requirement: 界面缺陷须 UI 层通行证

界面类或含界面操作的缺陷 MUST 以界面层冒烟通过作为 resolve 的必要条件；MUST NOT 仅以接口层 pytest、
编译、单测或大模型叙述替代界面层证据。

#### Scenario: 缺陷为界面交互问题

- **WHEN** 缺陷表现为点击、切换、弹窗、渲染、样式、按钮可见性等用户可见行为异常
- **THEN** MUST 有界面层冒烟通过凭证，且 MR 报告中含界面层证据（截图或 trace 引用）

#### Scenario: 用 API 冒充 UI

- **WHEN** 该缺陷已标记要求层为 `UI` 或 `BOTH`，但通行证仅含 `API` 层
- **THEN** MUST NOT 允许 `shanzhi_resolve_bug` 成功

#### Scenario: 缺陷为数据或接口问题

- **WHEN** 缺陷表现为数据或接口问题且不依赖界面呈现，且要求层为 `API`
- **THEN** 接口层冒烟 PASS 凭证 SHALL 满足 resolve 条件

#### Scenario: 前后端兼有

- **WHEN** 缺陷同时涉及接口与界面
- **THEN** 要求层为 `BOTH`，须分别具备 API 与 UI 的 PASS 凭证，或单一 UI 用例覆盖端到端断言

### Requirement: 结构化冒烟证据（含边界与步骤）

解决说明 MUST 含：冒烟类型、目标地址、场景描述、结果、证据引用、报告链接、测试用例来源、测试过程、
测试边界、步骤对应。仅凭自然语言「认为已通过」而无报告链接与通行证 MUST 视为无效。

#### Scenario: 提交通过证据

- **WHEN** resolve 被允许
- **THEN** 解决说明含上述字段，且报告链接与通行证 `report_url` 一致

#### Scenario: 证据缺少报告链接

- **WHEN** 解决说明无 MR 冒烟报告链接
- **THEN** resolve 硬闸门 MUST 拒绝

#### Scenario: 证据缺少边界说明

- **WHEN** 解决说明未说明测试边界
- **THEN** resolve 硬闸门 MUST 拒绝

### Requirement: 通行证先于解决（硬闸门）

未留下有效 PASS 通行证且未走合规豁免流程的修复 MUST NOT 置为已解决。

#### Scenario: 有通行证且层匹配

- **WHEN** 工作区存在当前缺陷的有效 PASS 通行证且层满足要求
- **THEN** `shanzhi_resolve_bug` MAY 继续（仍须满足发版等政策）

#### Scenario: 无通行证

- **WHEN** 未执行冒烟或通行证缺失/层不匹配
- **THEN** `shanzhi_resolve_bug` MUST 失败并返回可操作的错误信息

### Requirement: 豁免不得用 API 替代 UI

对主要为界面操作的缺陷，MUST NOT 以「接口已测」作为豁免理由；豁免路径 MUST NOT 绕过硬闸门（本变更不实现人工 override）。

#### Scenario: 试图用 API 豁免 UI 缺陷

- **WHEN** 要求层为 `UI`，Agent 仅提供 API 结果并声明豁免
- **THEN** resolve MUST 被拒绝

### Requirement: 缺陷要求层声明

每个缺陷工作区 MUST 存在 `smoke-requirement.json`，记录 `required_layers`（`API` | `UI` | `BOTH`）及判据。

#### Scenario: 界面操作为主

- **WHEN** 复现步骤包含页面、点击、按钮、弹窗、显示等
- **THEN** `required_layers` MUST 为 `UI` 或 `BOTH`

#### Scenario: 纯接口错误

- **WHEN** 复现步骤无界面操作
- **THEN** `required_layers` MAY 为 `API`

### Requirement: resolve 硬闸门

Symphony 在执行 `shanzhi_resolve_bug` 前 MUST 校验通行证与要求层；失败 MUST NOT 调用善治 resolve API。

#### Scenario: 闸门通过

- **WHEN** 通行证有效、层匹配、`report_url` 存在且 comment 含该链接
- **THEN** 允许调用善治 resolve

#### Scenario: 闸门失败

- **WHEN** 任一校验项失败
- **THEN** 工具返回错误，Bug 保持处理中