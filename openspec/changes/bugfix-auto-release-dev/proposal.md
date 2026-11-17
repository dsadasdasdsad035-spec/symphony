# Proposal

## Why

善治 Bug 修完后，agent 只提了 MR 就调用 `shanzhi_resolve_bug`。开发环境（app-test）里跑的仍是旧包，验证的人看不到修复；而人工发版时，agent 分支的基线往往落后于跟踪分支，直接打包会把别人的代码漏掉。

更关键的是一个时间约束：善治状态变成「已解决」后，它既不属于 `active_states` 也不属于 `terminal_states`，orchestrator 的 `reconcile_issue_state` 会走 `true ->` 分支 `terminate_running_issue`，轮询间隔默认 30 秒。也就是说 **resolve 之后 agent 最多活 30 秒**，而一次 `mvn` 全 reactor 构建是分钟级。发版动作必须发生在 resolve 之前，否则必然被中途杀掉。

## What Changes

- 新增开发环境发版脚本 `deploy/publish_dev.sh`（挂载进容器，不放业务仓库，避免"脚本要先发版才能用"的先有鸡还是先有蛋问题）
  - 硬闸：目标地址必须含 `30669`，否则 `exit 1`，物理上不可能误发演示环境（`:30680`）
  - 全局排它锁 `/data2/locks/publish-apptest.lock`：现有 `out/.publish.lock` 是每个工作区一把，跨 agent 不互斥，两个 agent 同时 bind 会把 `app_market` 复位成 `noUp`
  - 发版前 `git checkout symphony/<issue>` + `git merge origin/<跟踪分支>`，补齐其他分支代码
  - 用 `git diff --name-only origin/<跟踪分支>...HEAD` 推导改动文件并映射到 app，只发受影响的 app
  - 缺 `node_modules` 时先 `npm install`（pod 内所有工作区都没有）
  - 调既有 `scripts/publish_apps_to_env.py --env=apptest --base=:30669 --no-iam`，不改该脚本主体
  - 排除 `sie-iidp-iam`（pod 只有 JDK 21，无 JDK 8）与 `sie-iidp-ai-demo-web`（该环境无市场行）
- 交付顺序固定为 **发版 → 核对环境 → resolve**；发版失败只 `remark`，不 resolve
- `deploy/entrypoint.sh` 注入 `IIDP_USER` / `IIDP_PASSWORD` / `IIDP_SUPERUSER_TOKEN`，agent 只调脚本，拿不到明文凭据
- `deploy/WORKFLOW.md` 新增发版章节，并写明"先 resolve 会被 30s 轮询杀掉"的原因

## Capabilities

### New Capabilities

- `dev-env-release`: 把缺陷修复发布到开发环境（app-test）的完整契约——环境隔离、跨 agent 互斥、发版目标推导、跟踪分支合并、发布后一致性校验，以及与 `resolve` 的先后顺序

### Modified Capabilities

无。项目此前没有任何 spec（`openspec list --specs` 为空），本次是该能力的首次定义。

## Impact

**Symphony 仓库**
- `deploy/publish_dev.sh`（新增）
- `deploy/entrypoint.sh`（注入凭据）
- `deploy/WORKFLOW.md`（发版流程与顺序约束）
- `deploy/.env`、`deploy/env.example`、`deploy/k8s/deployment.yaml`（新配置项）
- `deploy/k8s/`：脚本挂载与 secret 引用

**业务仓库（只消费，不修改）**
- `scripts/publish_apps_to_env.py`：作为被调用方，不改其主体；`--env=apptest --base=` 已实测可用
- 各子模块 git 分支操作：`checkout` + `merge` 会改变工作区状态，需在发版前完成

**外部系统**
- 开发环境 `http://192.168.181.104:30669`（`implementer` 凭据已实测有效）
- 开发库 `192.168.184.120:5432/new_apptest`（仅用于一次性取固定的 superuser token，运行时不再读库：pod 内无 psql / pg8000 / pip）
- 演示环境 `http://192.168.181.104:30680` **不受任何影响**

**已知限制**
- 内置应用（`source=base`）更新依赖固定的 superuser token，该值已从环境取出并验证；若环境重置需重新获取
- 引擎（`sie-snest`）不在本脚本范围，仍走各自发布流程
- agent 有 turn 上限，发版耗时需控制；只发改动 app 就是为此
