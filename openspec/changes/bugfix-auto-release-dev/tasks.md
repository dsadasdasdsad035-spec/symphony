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
- **entrypoint 的改动已随镜像 `v5` 上线**（2026-11-17）。线上
  `/usr/local/bin/symphony-entrypoint` 为 396 行版本，启动日志可见
  「开发环境发版凭据就绪」「发版脚本已就绪」；Symphony 进程与 codex 子进程环境里
  `PUBLISH_DEV_SH=/opt/symphony-release/publish_dev.sh`。WORKFLOW.md 仍用
  `${PUBLISH_DEV_SH:-/opt/symphony-release/publish_dev.sh}` 兜底——镜像若回退到
  `v4` 及更早，该变量不会被导出，绝对路径仍指向同一个文件，不会失效。
  `v4` 的回滚点：`sha256:86ddf9523ab6f84dc939244958da1d90d85b06353451aa3613c8e533d322aa3b`。
  另注：`deploy/k8s/apply.sh` 里曾有一个从未被使用的 `IMAGE` 默认值（还是 `v2`），
  改它不会生效且易误导，已删除；镜像 tag 只由 `deployment.yaml` 决定。
- **GitLab 是 11.3.0，用旧式 URL**：commit 链接是 `/<project-path>/commit/<sha>`，
  **不能带 `/-/`**（带 `/-/` 会 302 到登录页，看起来像"链接打不开"）。MR 同理。
  WORKFLOW.md 已修正。
- **情况一补了「环境产物验证」硬闸门（2b）**：由 SF-83343 暴露——提交在跟踪分支上，
  但环境 `/apps/modules/` 里的 jar 仍是修复前构建，Bug 照样复现。现在要求用 `javap`
  反编译确认改动确实在产物里，并比对 Pod 启动时间与 jar 时间，产物不含修复就不许 resolve。
- **补回 workpad 机制（跨轮记忆）**（2026-11-17）。由 SF-83323/83324 暴露：两单各被派发
  24 次、跑满 667 个 turn、累计 1026 万 input token，产出为 0（工作区停在 master、从未建
  修复分支）。根因是上游 Symphony 的三个前提在我们这套部署里断了一个：
  1. **撞 `max_turns` 被当成正常完成**——`agent_runner` 返回 `:ok` → 任务 `:normal` 退出 →
     orchestration 走 `delay_type: :continuation`，延迟固定 `@continuation_retry_delay_ms`
     （1 秒）重派。实测重派间隔 1.08~1.35 秒。且调用方传字面量 `attempt=1`，永不升级、
     不退避、不封顶。**这段逻辑与上游 `openai/symphony@be10a1b` 逐字一致，不是本地改坏。**
  2. **上游靠 workpad 兜住**：其 `elixir/WORKFLOW.md` 要求「用一条持久的 Linear 评论当
     进度的唯一真相」，续跑时先读回。我们迁到善治后没建等价物，导致
     `agent_runner.ex:162` 那句 "Resume from ... workpad state" 指向不存在的机制，
     每次重派都是全新线程 + 全新 prompt + 从零开始（实测每个会话首个动作都是重读
     Bug 历史 / `cat AGENTS.md`）。
  3. **任务重量超上游假设**：上游提示词是「单仓库任务」；我们是跨仓库（Vue
     `sie-iidp-ai-agent-web` + Java `de-skill`/`de-post-dev`）、3.6G 聚合工作区、7 个子模块。
     且 `turn` 记的是 assistant 回复次数，实测 30 turn 仅产出 25 次工具调用。
  另注 **状态出口受渠道约束**：善治 `激活/激活中/未解决 → active`，`已解决/待验证 →
  resolved`。`active_states` 只有 `active`，所以唯一出口是 Agent 自己调
  `shanzhi_resolve_bug`；`confirm_bug` 刻意禁用，没有中间态可先退出。Linear 里 Agent 能
  随手拖状态脱离 active，善治不行——**这也是渠道相关的放大因素**。
  修复：`deploy/WORKFLOW.md` 新增「开工第一步：读写 workpad」章节，**双写分层**：
  - **善治备注 = 跨环境兜底 + 人工可见**。写之前实测确认：`remark_bug` 实际是
    「取详情 → 改 comment → `update-bug` 全量提交」（善治无独立备注接口），备注只进
    操作历史，且 `get_bug` 返回的 48 个字段**不含 comment**——读回必须走
    `shanzhi_bug_history`。因此只在 5 个关键节点写（诊断完成 / 定位到根因 / 代码改完 /
    验证发版结果 / resolve 前），每次带 `WORKPAD` 标记便于检索。
    不每阶段写的原因：① 每写一次留一条「编辑了」，会把人工可见历史刷成噪音；
    ② 全量提交在极端并发下有覆盖他人改动的风险。
  - **`out/symphony-workpad.md` = 高频底稿**。`out/` 已 gitignore、在工作区持久卷上、
    不污染 `git status`，每阶段更新，记录已确认事实 / 已排除假设 / 当前进度 / 下一步 /
    关键路径。工作区可能被 `after_create` 钩子或失败清理重建，所以开工顺序定为
    **先读善治历史、再读文件**。
  已验证热加载生效：SF-83324 的新会话工具调用顺序为
  `shanzhi_bug_history` → `cat out/symphony-workpad.md` → 继续干活，
  且不再重复 `cat AGENTS.md`（说明确实接着上一轮干，而非从零开始）。
  **仍未处理**：`max_turns` 仍是 30；撞上限仍按 continuation 1 秒重派（workpad 让每轮
  变成增量推进，但循环本身没有封顶）。后续若单轮仍不够，需再评估调大 `max_turns`
  或在上游代码里加计次封顶。

## 补充：跨 run 续接会话（thread/resume）

**问题**：上面的 workpad 只解决「知道进度」，不解决「上下文没了」。此前每次
`start_session` 都新建会话——Codex 发 `thread/start`，其余 CLI 的 `session_id` 初始化
为 nil——于是每轮仍要从零重读提示词与仓库结构。

**关键发现（推翻了前期结论）**：Codex app-server 协议**本来就有** `thread/resume`，
支持按 `threadId` / history / path 三种方式从磁盘载回线程。在容器内用旧 thread_id
实测：`thread/resume` 返回成功并载回 **30 轮历史**，`cwd`、`approvalPolicy` 一并恢复。
同理 claude / cursor / zcode 的 `--resume <session_id>` 也一直存在，只是 Symphony
从未把上一轮的 id 传回去。

**改动**：
1. 新增 `lib/symphony_elixir/thread_store.ex`：把 `工单项 identifier → {thread_id, turns}`
   持久化到 `~/.config/symphony/threads.json`（可用 `SYMPHONY_THREADS_FILE` 覆盖）。
   与 Codex 会话文件同在容器 overlay 层，Pod 重建时一起消失，避免留下指向已失效
   会话的陈旧映射。
2. `codex/app_server.ex`：`start_session/2` 新增 `resume_thread_id`、`resume_turns`、
   `compact_after_turns`；有 id 时发 `thread/resume`，**任何失败都回退 `thread/start`**
   ——续接只是省时间，不能挡住整轮运行。响应形状兼容 `%{"thread" => %{"id" => ...}}`
   与扁平 `%{"id" => ...}` 两种。
3. 续接会带上整条线程历史，故超过 `agent.compact_after_turns`（默认 40，部署配 30）
   时先发 `thread/compact/start`；压缩成功则轮数计数归零，否则沿用已累计值。
4. `claude_cli` / `cursor_cli` / `zcode`：`resume_thread_id` 作为 `session_id` 种子写进
   ETS，使 `--resume` 生效。
5. `agent_runner.ex`：派发前读映射并传入；**每完成一轮就回写**（`turns` 为累计值），
   保证中途被打断也不丢。
6. 配置：`agent.compact_after_turns`；`deploy/WORKFLOW.md` 设为 30 与 `max_turns` 对齐，
   即「每跑满一轮、下次续接压缩一次」，上下文始终有界。

**测试**：`thread_store_test.exs`（持久化/脏数据/删除）；`app_server_test.exs` 用伪造
`codex app-server` 断言「有 id 走 resume 不发 start」「resume 报错则回退 start」，
以及两种响应形状解析。修复了测试污染真实 `~/.config/symphony` 的问题——
`TestSupport` 现在为每个用例设独立 `SYMPHONY_THREADS_FILE` 并清空映射。

**两层防御的分工**：同 Pod 内（max_turns 循环）靠 resume 保住完整上下文；Pod 重建
（发版）靠 workpad + 善治备注。两者互补，不是替代关系。

### 上线踩到的坑：`thread/compact/start` 是异步的

首次上线（`v6`）后每轮都失败：

```
error: {:response_error, %{"code" => -32603,
  "message" => "failed to submit turn input: ActiveTurnNotSteerable { turn_kind: Compact }"}}
```

原因：`ThreadCompactStartResponse` 是**空对象**，它只表示「压缩已开始」，压缩本身是个
后台 turn。我原来等到这个响应就发 `turn/start`，直接撞上正在跑的 compact turn。

修法：发完 `thread/compact/start` 后继续等 **`thread/compacted` 通知**（或该 turn 的
`turn/completed`）再开工，超时上限取 `min(codex.turn_timeout_ms, 10min)`。
若「开始压缩」这一步就失败（线程仍空闲）→ 记日志后照常跑；若等了却超时（压缩可能仍在
后台）→ **返回错误让整轮失败**，交给调度器重试，下一轮续接时线程已压好。
压缩成功后 `turns_base` 归零，否则下一轮会立刻重复压缩。

`v7` 实测（每约 40 秒一个周期，连续多轮无报错）：

```
14:20:37 Reached agent.max_turns ... returning control to orchestrator
14:20:39 续接既有 codex 线程 thread_id=01a1e828-ddec-...
14:20:40 续接前已压缩上下文 thread_id=01a1e828-ddec-... turns=30
14:21:20 Reached agent.max_turns ...
14:21:22 续接既有 codex 线程 thread_id=01a1e828-ddec-...
```

### 但真正的瓶颈不在上下文

`v7` 上线后复盘会话文件（`~/.codex/sessions/.../rollout-*.jsonl`）：

| 工单 | 轮数 | 工具调用 |
|---|---|---|
| SF-83323 | 1 | 37 |
| SF-83324 | 123 | 4 |

SF-83324 的 assistant 消息只有「我先读善治历史和本地 workpad」「确认是首次处理，我会先看
截图」这类**只表态、不调工具**的话，于是每轮 1 秒结束，30 轮 40 秒烧完。
清掉线程映射、重启 Pod 全新开始后仍然是 123 轮 / 4 次工具——**说明与 resume 无关，
也不只是这一条线程的问题，而是该任务 + `local-glm5.3` 的组合让模型不出工具调用**。

结论：resume + compact 解决了「每轮从零重来」的浪费，但**无法解决模型空转**。
若该工单仍要跑通，需要换更强的模型（或改该单的处理路径）；单纯调大 `max_turns`、
继续调续接策略都只是延长空转。
