# Tasks

## 1. 发版脚本骨架与环境闸门

- [x] 1.1 新建 `deploy/publish_dev.sh`，解析 `--apps` / `--dry-run` / `--issue` 等参数，并实现硬闸：目标地址必须含 `30669`，否则 `exit 1`。验证：`./publish_dev.sh --base=http://192.168.181.104:30680` 立即非零退出，且 `curl`/`mvn`/`npm` 一次都没被调用。
- [x] 1.2 实现全局排它锁：`exec 9>/data2/locks/publish-apptest.lock` + `flock -n 9`，拿不到锁时输出"已有发版在进行（含持锁工作区）"并退出。验证：`flock` 占住锁后另开一个进程运行脚本，立即失败并打印该提示。
- [x] 1.3 锁目录缺失时自动 `mkdir -p /data2/locks`，并确保锁文件不随工作区清理消失。验证：删掉目录后重跑脚本，能自建并正常加锁。

## 2. 代码准备：跟踪分支合并与目标推导

- [x] 2.1 从 `.gitmodules` 解析各子仓的跟踪分支（`branch` 键），准备 `origin/<tracking>` 引用；对 `sie-iidp-base-inner-web` 这类无写权限仓只读不推。验证：打印解析结果与 `.gitmodules` 声明逐条一致。
- [x] 2.2 实现 `git checkout symphony/<issue>` + `git merge origin/<tracking>`，冲突即中止整个发版并列出冲突文件，不产出任何包。验证：人为制造冲突后运行，确认非零退出且 `target/` 无新 jar。
- [x] 2.3 实现目标推导：`git diff --name-only origin/<tracking>...HEAD` 得到改动文件，按路径前缀映射到应用（前端 `apps/<comp>/`，后端模块目录，市场仓与 IAM 各自规则）。验证：在真实工作区核对映射结果与设计预期一致。
- [x] 2.4 实现排除规则并给出原因：`sie-iidp-iam`（pod 无 JDK 8）、`sie-iidp-ai-demo-web`（该环境无市场行）。验证：让 diff 命中这两类路径，输出里明确写出"已排除 + 原因"，其余目标不受影响。

## 3. 构建前提与参数拼装

- [x] 3.1 检测 `node_modules` 缺失时执行 `npm install`（有 lock 文件则按 lock 安装），存在则跳过。验证：删掉 `node_modules` 跑一次能装成功；再跑一次确认不重复安装。
- [x] 3.2 拼装并调用既有脚本：`--env=apptest --base=http://192.168.181.104:30669 --apps=<推导结果> --no-iam --yes`，透传 `--dry-run`。验证：`--dry-run` 输出的目标清单与第 2 组推导结果完全一致，且 `iam` 不在其中。

## 4. 凭据注入与容器部署

- [x] 4.1 在 `deploy/entrypoint.sh` 中注入 `IIDP_USER` / `IIDP_PASSWORD` / `IIDP_SUPERUSER_TOKEN`（沿用 GIT_TOKEN → GITLAB_TOKEN 的映射惯例，缺省不覆盖已设值）。验证：容器内 `env | grep IIDP_` 可见三项；agent 提示词与脚本内均不含明文口令。
- [x] 4.2 在 `deploy/k8s/` 增加 secret 与脚本挂载：脚本体积小于 1MiB 用 ConfigMap（便于热改），否则打进镜像；挂载到固定路径并 `chmod +x`。验证：`kubectl exec` 进容器能直接执行该脚本并打印 `--help`。
- [x] 4.3 更新 `deploy/.env`、`deploy/env.example`、`deploy/README.md`，说明新键（开发环境地址、用户、口令、superuser token、锁路径）。验证：照文档从零配置一遍能跑通 preflight。

## 5. agent 交付流程与顺序约束

- [x] 5.1 `deploy/WORKFLOW.md` 新增"发布到开发环境"章节：脚本用法、只发改动应用、以及**必须先发版再 resolve**，并写明原因（`resolved` 会让 orchestrator 在 30 秒轮询内 `terminate_running_issue`）。验证：章节含该因果说明与失败时只 `remark` 不 `resolve` 的明确要求。
- [x] 5.2 把交付顺序写进交付章节的分步流程：合并跟踪分支 → 发版 → 核对环境 → `shanzhi_resolve_bug`。验证：Codex 与 Claude 两条通道都能读到同一份内容（MCP 与 CLI 的提示词注入路径一致）。

## 6. 集成验证

- [ ] 6.1 在一条真实 bug 上跑完整闭环：改代码 → 合并跟踪分支 → 发版 → 回读环境 → resolve。验证：环境市场行与已安装行的 version+md5 均与本地构建产物一致，且 bug 状态为已解决、解决说明含环境与结论。
- [x] 6.2 并发场景：两个工作区同时对开发环境发版。验证：后启动的一方在构建前失败，提示明确；先启动的一方正常完成。
- [ ] 6.3 演示环境零影响：记录操作前后 `:30680` 各应用版本与 md5。验证：两次快照完全一致。
- [ ] 6.4 失败路径：让一次发版在校验阶段失败。验证：bug 未被 resolve，仅追加失败备注，日志路径在备注中可查。

## Workflow follow-up

- 归档本 change（`openspec archive`），确认 `specs/dev-env-release/spec.md` 落入正式 specs。
- 脚本稳定并经过若干轮真实发版后，评估迁回业务仓 `scripts/`，届时需先人工合入一次。
- **前端发版的前置：先合 `iidp-aios` 的 MR !8**（`.gitmodules` 里 `sie-iidp-ai-agent-web`
  的 `branch` 从已删除的 `dev` 改为 `test`）。未合并时脚本会以 exit 8 拒绝，提示
  「跟踪分支 origin/dev 不存在」——这是有意的，不是故障。
- **entrypoint 的改动需重建镜像才生效**。当前线上镜像 `v4` 里的
  `/usr/local/bin/symphony-entrypoint` 仍是旧版，`IIDP_*` 由 Secret 直接注入可用，
  但 `PUBLISH_DEV_SH` 不会被导出；因此 WORKFLOW.md 用
  `${PUBLISH_DEV_SH:-/opt/symphony-release/publish_dev.sh}` 兜底。下次构建镜像后自动切换。
- **GitLab 是 11.3.0，用旧式 URL**：commit 链接是 `/<project-path>/commit/<sha>`，
  **不能带 `/-/`**（带 `/-/` 会 302 到登录页，看起来像"链接打不开"）。MR 同理。
  WORKFLOW.md 已修正。
- **情况一补了「环境产物验证」硬闸门（2b）**：由 SF-83343 暴露——提交在跟踪分支上，
  但环境 `/apps/modules/` 里的 jar 仍是修复前构建，Bug 照样复现。现在要求用 `javap`
  反编译确认改动确实在产物里，并比对 Pod 启动时间与 jar 时间，产物不含修复就不许 resolve。
