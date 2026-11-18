# Proposal

## Why

善治 Bug 的「解决」目前只证明代码进了开发环境，不证明问题真的消失了。`publish_dev.sh` 的收尾校验只核对市场行与已安装行的 version + md5，属于「装上了」而非「好了」；提示词里的验证要求是「编译、单测或可复现步骤至少跑通一项」，而「编译通过」即可满足。实测印证：`SF-83432` 的验证段只有 `node --check` 语法检查与源码级自检，没有任何针对真实环境的执行证据。

后果是「已解决」这个状态的可信度无法区分：一个真正修好的 Bug 和一个只是发版成功的 Bug，在善治里看起来一模一样。

## What Changes

- 交付流程在「发版」与 `shanzhi_resolve_bug` 之间插入**冒烟**一环，顺序固定为：改代码 → 推分支 → 发版 → **冒烟** → resolve。冒烟失败时不 resolve，只用 `shanzhi_remark_bug` 记录。
- 冒烟一律针对**开发环境** `http://192.168.181.104:30669`，不针对本地 dev server：本地跑通不能证明环境里的产物是好的。
- 定义两层冒烟及其适用边界：
  - **API 层**：打 `:30669` 的 JSON-RPC（登录 → token → service 调用），验证数据、接口返回与状态流转。
  - **UI 层**：用 playwright 驱动 `:30669/iidp/`（wujie 微前端壳），按 `frontend-smoke.json` 显式场景验证点击、切换、弹窗、渲染。
- 镜像新增 UI 冒烟运行能力：chromium 运行所需的 16 个系统库、`playwright` Python 包、chromium 浏览器本体，全部在构建期烘进镜像。
- 确立**软闸门**：闸门强度为提示词层，不新增 Symphony 代理工具、不改 `resolve_bug` 的 schema。要求 resolve 的 `comment` 包含固定格式的冒烟证据段落。
- 定义豁免机制：两层都测不到时，必须在 `comment` 写明 `未覆盖原因`（枚举值）与所用替代验证，不得沉默跳过。
- 明确「发版后宿主需先确认新版本可见再跑 UI 冒烟」这一前置校验，避免测到旧组件产出假 PASS。

## Capabilities

### New Capabilities

- `smoke-verification`: 缺陷修复在置为「已解决」之前必须留下针对开发环境的冒烟证据；覆盖两层冒烟（API / UI）的适用边界、执行契约、证据格式，以及无法覆盖时的豁免与披露要求

### Modified Capabilities

无。`openspec list --specs` 为空，项目此前没有任何 spec；本次是该能力的首次定义。

## Impact

**Symphony 仓库**
- `deploy/Dockerfile`：新增 chromium 系统库、playwright、chromium 浏览器（镜像体积显著增大，构建变慢）
- `deploy/WORKFLOW.md`：新增冒烟章节；改写「工作方式」第 5 条的验证要求；改写「交付方式」与「发布到开发环境」两节的收尾顺序，插入冒烟环节与失败分支
- `deploy/k8s/deployment.yaml`：镜像 tag 升级

**业务仓库（只消费，不修改）**
- `iidp_uitest`（`xuchunxia/iidp_uitest`）：UI 与 API 两层的唯一执行入口。Agent 按缺陷写 pytest 用例并提交分支/MR，不再自维护场景 JSON 或 curl 组合
- `scripts/publish_apps_to_env.py`：不改；其登录与 RPC 调用方式作为 API 层冒烟的参考实现

**外部系统**
- 开发环境 `:30669`：新增冒烟流量，只读为主
- 演示环境 `:30680`：不受影响

**已知限制**
- 软闸门意味着证据可信度依赖 agent 自觉；证据格式设计为可解析，为将来升级硬闸门留出空间
- 冒烟会消耗轮次预算（`max_turns` 为 30），UI 冒烟尤其明显
- 界面类 Bug 若其界面只在宿主内可达（无独立 URL），仍可能落到豁免
