# Design

## Context

动机见 `proposal.md` — Why。这里只记录影响方案的现状约束（均为 2026-11-17 在运行环境实测）：

| 约束 | 实测结果 | 对方案的影响 |
|---|---|---|
| `resolved` 状态会停 agent | `reconcile_issue_state` 走 `true ->` 分支 `terminate_running_issue`，轮询 30s | 发版必须在 resolve 前完成 |
| 现有锁 | `WS/out/.publish.lock`，每个工作区一把 | 跨 agent 不互斥，需另建全局锁 |
| 副本数 | `replicas=1`，所有工作区同在 PVC `symphony-workspaces`（`/data2`） | 同节点 `flock` 可行 |
| 构建工具 | JDK 21.0.12、mvn 3.9.16、npm 10.9.9；**无 JDK 8** | IAM 无法构建 |
| 前端依赖 | 所有工作区**均无 `node_modules`** | 前端发版需先安装依赖 |
| PG 驱动 | 无 `psql`、无 `pg8000`、无 `pip` | 运行时不能读库取 token |
| 子仓状态 | 全部 `detached HEAD` | 发版前需显式 checkout 分支 |
| 开发环境 | `:30669`，15 个 app，凭据 `implementer` 有效 | 可作为发版目标 |
| `ai-demo-web` | 该环境无市场行 | 必须排除 |

## Goals / Non-Goals

**Goals**
- 让"修完即验证"闭环：发版到开发环境成为 agent 可自主完成的动作
- 把并发、误发、漏代码三类事故在脚本层拦住，而不是依赖 agent 自觉
- 发版耗时可控（只发受影响的应用），以适配 agent 的 turn 上限

**Non-Goals**
- 不发布到演示环境，也不改动演示环境的任何现有行为
- 不发布引擎（`sie-snest`），它有自己的流程
- 不改 `publish_apps_to_env.py` 的主体逻辑，只作为被调用方
- 不做回滚/下线；发布失败就是不发，不引入逆向操作

## Decisions

### D1 脚本放 Symphony `deploy/` 并挂载，不放业务仓库

`scripts/publish_apps_to_env.py` 在业务仓库里，新增脚本若也放业务仓 `scripts/`，它本身就得先走一次 MR 才能生效——发版脚本要靠发版上线，形成循环依赖。

**选择**：脚本放 `deploy/publish_dev.sh`，随 ConfigMap 挂载进容器。
**代价**：偏离"跨仓库脚本归工作区 `scripts/`"的既有约定。可在脚本头部注明原因，后续稳定后再迁回。

### D2 全局锁放 `/data2/locks/`，而不是工作区 `out/`

现有锁按工作区分片，两个 agent 各持一把，都会认为自己获得了独占权。
**选择**：`/data2/locks/publish-apptest.lock`，`flock -n` 非阻塞获取，拿不到就明确报错退出。
**为什么可行**：`/data2` 是共享 PVC 且 `replicas=1`，所有 agent 在同一文件系统上，`flock` 语义成立。
**限制**：若将来扩到多 pod，`flock` 不再跨节点有效，需换成基于环境的分布式锁。

### D3 用 `merge` 而非 `rebase` 合并跟踪分支

两者都能补齐代码。`rebase` 会改写已推送的提交，必须 force push；一旦 agent 判断失误，评审历史被重写且不可恢复。
**选择**：`git merge origin/<跟踪分支>`，冲突即中止发版并报告冲突文件。
**代价**：MR 上会多出 merge commit。这是可接受的——正确性优先于 history 整洁。

### D4 目标推导用 `git diff origin/<跟踪分支>...HEAD`

三种候选：对比跟踪分支、只看最后一个提交、由 agent 自己声明。只看最后提交会漏掉本分支更早的提交；由 agent 声明则把正确性托付给模型遵守 prompt。
**选择**：三点 diff（`...`）对比跟踪分支，得到改动文件后按路径前缀映射到应用（前端按 `apps/<comp>/`，后端按模块目录）。三点语法以合并基为基准，避免把跟踪分支自己的新提交误判为本次改动。
**兜底**：diff 为空或映射结果为空时，不发版并明确报告，不静默成功。

### D5 复用 `publish_apps_to_env.py`，不另写发布逻辑

该脚本已经解决了七个真实断点（上传≠发布、bind 复位 `noUp`、授权闸门、内置应用恢复通道、引擎底座单独调用、终态复核、zip 目录项）。重写等于把这些问题重新踩一遍。
**选择**：`publish_dev.sh` 只做编排（闸门、锁、分支合并、依赖安装、参数拼装），发布语义全部委托给已有脚本。
**依据**：`--env=apptest --base=http://192.168.181.104:30669` 已实测可用，无需改主体。

### D6 superuser token 用固定值注入，不做运行时读库

内置应用（`source=base`）更新必须走恢复通道，校验的是 `rbac_token` 表中 `rbac_token_superuser` 那行。运行环境既无 `psql` 也无 PG 驱动，无法读库。
**选择**：从 `app-test` 引擎 pod 的 `dbcp.properties` 确认库地址后，用 pod 自带 JDBC 驱动一次性取出该固定 token，经 k8s secret 注入为 `IIDP_SUPERUSER_TOKEN`。已用 `id=-1` 探针验证该 token 在 `:30669` 上有效（返回业务错误而非 `code:7100 token无效`）。
**代价**：环境重置后该值可能失效，需要重新获取；这属于可接受的人工介入点。

### D7 前端发版前按需 `npm install`

pod 内所有工作区都没有 `node_modules`，`npm run build:apps` 必然失败。
**选择**：脚本检测 `node_modules` 缺失时才安装，存在则跳过。
**代价**：首次发版较慢，且依赖网络可达。这也是 D4「只发受影响应用」的重要动因——把一次安装的代价摊到确实需要前端的场景上。

## Risks / Trade-offs

- **[发版耗时超过 agent turn 上限]** → 只发受影响应用；脚本输出阶段进度便于判断卡点；`mvn` 与 `npm` 日志落盘，中断后可复用产物续跑。
- **[agent 忘记先合并跟踪分支就发版]** → 合并动作放在脚本内部而非 prompt 里，即使 agent 漏了也会被脚本强制执行。
- **[两个 agent 同时发版]** → 全局 `flock` 非阻塞失败；提示明确，不静默排队。
- **[误发演示环境]** → 地址硬闸，在任何构建/网络写入之前终止。
- **[merge 提交污染 MR 历史]** → 接受；正确性优先。冲突时中止并报告，不自动解决。
- **[token 失效]** → 内置应用更新失败并标为 fail，脚本其余应用照常发布，不连坐；报错提示如何补。
- **[`npm install` 引入不可复现的依赖版本]** → 使用仓库既有 lock 文件安装；若 lock 文件缺失则报告而不是放任漂移。

## Migration Plan

1. 先在单个 bug 上手动跑通一次 `publish_dev.sh`（`--dry-run` 与 `--only=preflight` 各一次，再全链），确认锁、闸门、目标推导行为符合预期。
2. 挂载脚本与 secret，验证容器内可执行、agent 只看到命令而看不到凭据。
3. 更新 `WORKFLOW.md`，把顺序约束写入交付章节；先在一条 bug 上验证「发版→核对→resolve」完整闭环。
4. 回滚方式：移除挂载与 WORKFLOW 章节即可，业务仓库与演示环境均无改动，不存在需要清理的发布状态。

## Open Questions

- 挂载方式选 ConfigMap 还是打进镜像：ConfigMap 便于热改，但脚本大于 1MB 时受 ConfigMap 大小限制；实现阶段按脚本实际体积决定。
- 是否需要对发版本身设超时上限并自动放弃：取决于实测耗时，先用日志与 turn 上限观察，不预先设死。
