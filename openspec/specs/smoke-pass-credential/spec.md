# smoke-pass-credential

## Purpose

定义冒烟通过后写入工作区的机器可读凭证，供 resolve 硬闸门客观核实。

## Requirements

### Requirement: 通行证仅在脚本判定通过时写入

系统 SHALL 仅在 `smoke_test.sh` 完成用例执行且 pytest 结论为通过时，才写入状态为通过的冒烟通行证。
Agent 手写 JSON 或复制旧 Bug 的通行证 MUST NOT 被视作有效来源（校验方须核对内容哈希或签名由脚本写入）。

#### Scenario: pytest 全绿后写入 PASS

- **WHEN** `smoke_test.sh` 以退出码 0 结束且 junit 判定通过
- **THEN** 在工作区写入 `smoke-pass.json`，`verdict` 为 `PASS`

#### Scenario: pytest 失败不写入 PASS

- **WHEN** 用例失败或 collect 失败导致退出码 1
- **THEN** MUST NOT 写入 `verdict` 为 `PASS` 的通行证（可写入 `FAIL` 侧车供备注引用）

#### Scenario: 版本等待超时

- **WHEN** 版本校验超时退出码 3
- **THEN** MUST NOT 写入 PASS 通行证

### Requirement: 通行证须绑定缺陷与工作区

通行证 MUST 包含与当前派发缺陷一致的标识（如 `SF-83221` / 善治数字 id），并与本次运行的工作区路径关联，
防止跨 Bug 复用上一张「通行证」。

#### Scenario: issue 一致

- **WHEN** 通行证中的 `issue_identifier` 与当前 Symphony 运行中的缺陷号一致
- **THEN** 校验方视为绑定有效

#### Scenario: issue 不一致

- **WHEN** 通行证属于其他缺陷或缺少 `issue_identifier`
- **THEN** 校验方 MUST 拒绝将其用于当前缺陷的 resolve

### Requirement: 通行证须记录冒烟层与用例

通行证 MUST 记录本次运行的冒烟层（`API` 或 `UI`，由用例路径判定）与执行的 pytest nodeid / 用例文件路径，
以及目标环境地址、版本校验结论摘要。

#### Scenario: 记录 UI 层

- **WHEN** 用例路径属于界面层（非 `testcase/api/` 前缀）
- **THEN** 通行证中 `layer` 为 `UI`

#### Scenario: 记录 API 层

- **WHEN** 用例路径属于接口层
- **THEN** 通行证中 `layer` 为 `API`

### Requirement: 发布报告时通行证须含 MR 报告链接

当调用方使用 `--publish-report` 且评论成功发到代码仓库 MR 时，通行证 MUST 包含 `report_url`（MR 评论锚点）。
发布被拒绝（如退出码 4）时 MUST NOT 写入 PASS 通行证。

#### Scenario: 报告发布成功

- **WHEN** MR 评论创建成功并得到有效 `note_id`
- **THEN** 通行证包含非空的 `report_url`

#### Scenario: 仅本地报告未发布

- **WHEN** 未提供 `--publish-report` 或发布失败
- **THEN** MUST NOT 写入可用于 resolve 硬闸门的 PASS 通行证（允许本地 `report.md` 仍存在）

### Requirement: 通行证含用例仓库引用

通行证 MUST 包含 `uitest_ref`：用例所在分支名、最近一次 commit（短 SHA）或 uitest MR 链接（若已提供），
供 resolve 备注与人工复核追溯。

#### Scenario: 用例在 uitest 分支上

- **WHEN** 冒烟在 `iidp_uitest` 缓存目录执行且该目录为 git 仓库
- **THEN** 通行证记录当前分支与 HEAD 短 SHA