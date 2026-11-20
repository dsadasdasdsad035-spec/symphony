# Tasks

> 刻意跳过 `design.md`：本次只改一个脚本 + 两份文档，无新依赖、无架构变化；
> 需要定夺的边界情形（混合改动、接口不可用、参数优先级）已作为场景写进 spec。

## 1. 从工作区目录推导目标项目

- [x] 1.1 `smoke_test.sh` 新增 `--mr-dir <子目录>`，从该目录 `git remote get-url origin`
  解析出 `scheme://host/group/project`，得到项目路径（去掉 `.git` 与首尾斜杠）
- [x] 1.2 `--mr-dir` 与 `--gl-project` 二选一：都给时以 `--mr-dir` 为准并输出告警；
  `--mr-dir` 不存在或不是 git 仓库时，在跑用例之前失败退出
- [x] 1.3 保留「目标等于用例仓库则拒绝」的既有校验，作用在推导后的最终项目路径上

## 2. 校验目标 MR 的实质内容

- [x] 2.1 发布前调用 `GET /projects/:id/merge_requests/:iid/changes`（带 `--noproxy '*'`），
  检查所有 `changes[].diff` 是否只由 `Subproject commit` 行构成
- [x] 2.2 只有指针推进 → 拒绝发送，非 0 退出，提示里点名该指针属于哪个子模块，
  以及「真正改动应发到该子仓库的 MR」
- [x] 2.3 含指针以外的文件改动 → 放行（覆盖「缺陷本身只改根仓库」的合法场景）
- [x] 2.4 读取改动失败（权限/接口/网络）→ 告警说明校验未执行并继续发布，不阻断交付
- [x] 2.5 校验放在发评论之前、跑用例之后：用例结果本身要能产出，不能因为目的地判定失败就丢掉报告

## 3. 文档与 skill 同步

- [x] 3.1 `WORKFLOW.md` 删掉把 `mijiuye/iidp-aios` 当合法 `--gl-project` 示例的写法
- [x] 3.2 `WORKFLOW.md` 补判定步骤：先看本次改哪些子仓库 → 用 `--mr-dir` 推导；
  缺陷只改根仓库时才用聚合仓库；并写明聚合仓库的指针 MR 默认不是目标
- [x] 3.3 `deploy/skills/iidp-smoke/SKILL.md` 同步同一条约束与 `--mr-dir` 用法

## 4. 验证

- [x] 4.1 用 `--mr-dir sie-iidp-ai-agent-web --mr <真实修复 MR>` 实跑，确认报告落到子仓库 MR
- [x] 4.2 用 `--mr-dir` 指向聚合仓库、对该聚合仓库的指针 MR 发布，确认被拒绝且提示正确
- [x] 4.3 对只改根仓库的 MR 发布（无指针行），确认放行
- [x] 4.4 模拟 GitLab 改动接口不可用，确认降级为告警且报告仍发出
- [x] 4.5 `apply.sh --release-only` 同步脚本后，在 Pod 内复跑 4.1~4.3

## 5. 收尾

- [x] 5.1 更新 `openspec/changes/smoke-before-resolve/tasks.md` 的 7.19，注明
  「报告去向」已由本变更单独立规
- [x] 5.2 已有错位评论保持不动（本次范围外），如需迁移另开任务
