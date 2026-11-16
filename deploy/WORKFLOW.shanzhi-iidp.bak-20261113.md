---
tracker:
  kind: shanzhi
  provider:
    base_url: https://api.gushen.sieiot.com
    # 账号从 ~/.config/symphony/start.sh 注入（读取 ~/善治mcp/config.json）
    username: $SF_USERNAME
    password: $SF_PASSWORD
    product_id: 419          # 谷神工业数字平台
    project_id: 428
    dep_id: "491919451030089984"
    assignee: 米久业          # 只处理指派给米久业的激活 Bug
    web_url: http://sf.sieot.com
  # SF_PASSWORD 由 shanzhi 适配器自动从 agent 子进程剥离。
  # 注意 GITLAB_TOKEN 不能列进来——agent 要用它建 MR。
  required_labels: []
  active_states:
    - active
  terminal_states:
    - closed
polling:
  interval_ms: 15000
workspace:
  root: ~/code/symphony-workspaces
hooks:
  after_create: |
    #!/bin/sh
    set -e

    # Aggregate repo with submodule shell. Reference base clone shares git objects,
    # so a workspace is ready in a few seconds instead of minutes.
    REPO_URL="${SOURCE_REPO_URL:-http://192.168.175.55:9888/mijiuye/iidp-aios.git}"
    BASE="${SYMPHONY_BASE_REPO:-$HOME/code/symphony-base/iidp-aios}"

    # The LAN GitLab must not go through the local http proxy.
    export no_proxy="192.168.0.0/16,localhost,127.0.0.1"
    export NO_PROXY="$no_proxy"

    if [ -d "$BASE/.git" ]; then
      echo "[hook] clone with reference base: $BASE"
      git clone --quiet --reference "$BASE" -c submodule.alternateLocation=superproject "$REPO_URL" . \
        || git clone --quiet "$REPO_URL" .
    else
      echo "[hook] no base repo, plain clone"
      git clone --quiet "$REPO_URL" .
    fi

    # Proxy override is scoped to this workspace only.
    git config http.proxy ""
    git config https.proxy ""

    # Submodules need full history: a shallow fetch is rejected for some pinned commits.
    git -c http.proxy= -c https.proxy= submodule update --init --jobs 4 || true

    # Pin every submodule to the commit recorded by the superproject.
    git config -f .gitmodules --get-regexp '\.path$' | while read -r key path; do
      name="${key#submodule.}"
      name="${name%.path}"

      want="$(git rev-parse ":$path" 2>/dev/null)" || continue
      [ -n "$want" ] || continue

      if [ ! -d "$path/.git" ] && [ ! -f "$path/.git" ]; then
        git -c http.proxy= submodule update --init --force "$path" || true
      fi
      [ -d "$path" ] || continue

      have="$(git -C "$path" rev-parse HEAD 2>/dev/null || echo none)"
      [ "$have" = "$want" ] && continue

      echo "[hook] fix submodule $path: $have -> $want"
      git -C "$path" config http.proxy ""
      git -C "$path" config https.proxy ""

      if ! git -C "$path" -c http.proxy= fetch --quiet origin "$want" >/dev/null 2>&1; then
        branches="$(git config -f .gitmodules --get "submodule.$name.branch" 2>/dev/null || true)"
        branches="$branches $(git -C "$path" -c http.proxy= ls-remote --heads origin 2>/dev/null | awk '{print $2}' | sed 's|refs/heads/||' | tr '\n' ' ')"
        for b in $branches; do
          git -C "$path" -c http.proxy= fetch --quiet origin "$b" >/dev/null 2>&1 || continue
          git -C "$path" cat-file -e "$want^{commit}" 2>/dev/null && break
        done
      fi

      git -C "$path" checkout --quiet "$want" 2>/dev/null \
        || echo "[hook] warn: cannot checkout $want in $path"
    done

    echo "[hook] workspace ready: $(pwd)"
    git submodule status || true
  # 工作区被复用时（典型场景：MR 打回后把 Bug 改回激活）同步一次远端。
  # 只 fetch 不 rebase：是否合入目标分支最新提交交给 agent 判断，
  # 避免在子模块 + 未提交改动的情况下自动 rebase 把 agent 卡死。
  before_run: |
    #!/bin/sh
    export no_proxy="192.168.0.0/16,localhost,127.0.0.1"
    export NO_PROXY="$no_proxy"

    git -c http.proxy= -c https.proxy= fetch --quiet origin 2>/dev/null || true

    git config -f .gitmodules --get-regexp '\.path$' 2>/dev/null | while read -r _ path; do
      if [ -d "$path/.git" ]; then
        git -C "$path" -c http.proxy= -c https.proxy= fetch --quiet origin 2>/dev/null || true
      fi
    done

    true
agent:
  # 后端选择: codex(默认) | claude_cli(Claude Code) | cursor_cli(Cursor CLI) | zcode
  kind: claude_cli
  # claude_cli 使用的命令（默认 claude）与模型（留空则跟随
  # ~/.claude/settings.json，目前是 deepseek-flash[1M]）
  claude_command: claude
  claude_model: deepseek-flash[1M]
  # 切到 cursor_cli 时使用的命令前缀
  cursor_command: cursor-agent
  # Cursor CLI 的模型; 留空用账号默认(auto)。用 cursor-agent --list-models 查可用值。
  # 善治 keywords 路由到 cursor_cli 时走此项（走 Cursor 套餐额度，不用 DeepSeek credits）。
  cursor_model: composer-2.5
  max_concurrent_agents: 2
  max_turns: 20
codex:
  command: codex app-server
  approval_policy: never
  thread_sandbox: workspace-write
  turn_sandbox_policy:
    type: workspaceWrite
    networkAccess: true
---

你正在 iidp-aios 多工程聚合工作区中处理一个善治（SF 软件工厂）Bug。

## 任务

- 编号: {{ issue.identifier }}
- 标题: {{ issue.title }}

{{ issue.description }}

如果上面的描述缺少复现步骤或备注，先用 `shanzhi_get_bug` 读取完整详情，再看 `shanzhi_bug_history` 了解历史处理过程。

## 开工前必须先确认问题真实存在

Symphony 只会把「状态=激活 且 确认=是」的 Bug 派给你，所以这个 Bug 已有人确认过。
但**动手改代码之前，仍要先对照代码核实问题是否真的存在**：

- 能定位到问题：正常修复并交付。
- 定位不到、或看代码发现根本不是 Bug（例如已被别的改动修好、属于需求变更、环境/数据问题）：
  **不要臆造改动**。用 `shanzhi_remark_bug` 写清楚你的判断依据和结论，然后直接结束本次任务。
  这种 Bug 由人工决定后续状态，你不要调用 `shanzhi_resolve_bug`。
- `shanzhi_confirm_bug` 是评审动作（把「确认」置为是），只有当你在真实环境复现成功、
  确信是有效缺陷时才用；如果无法复现，用备注说明，不要用它蒙过去。

## 工作区说明

- 当前目录是聚合仓库(submodule 壳),子工程代码在各子目录中独立成库。
- 动手前先读根目录 `AGENTS.md`,其中有多仓协作铁律(规格隔离、SDK 变更链、引擎联调)。
- 子工程改动提交到对应子仓库;根仓库只提交工作区级文件(`AGENTS.md`、`openspec/`、`docs/`)与子模块指针。
- 单工程规格写进该工程的 `openspec/`;跨仓库变更写进根 `openspec/changes/`,tasks 按仓库分节。

## 续改模式：MR 被打回后重新派发

如果工作区里**已经存在** `symphony/{{ issue.identifier }}` 分支（用
`git branch --list 'symphony/*'` 和 `git log --oneline -5` 判断），说明这不是首次处理，
而是上一轮提交的 MR 被要求返工。此时**必须走续改流程**：

1. 先看历史，搞清楚上一轮做了什么、评审要求改什么：

   - `shanzhi_bug_history` 读取上一轮的改动清单与 MR 链接。
   - 有 `GITLAB_TOKEN` 时，用 GitLab API 拉评审意见（**必须带 `--noproxy '*'`**）：

     ```bash
     curl -s --noproxy '*' -H "PRIVATE-TOKEN: $GITLAB_TOKEN" \
       "http://192.168.175.55:9888/api/v4/projects/<url-encoded-path>/merge_requests/<iid>/discussions"
     ```

2. **切回原分支，不要重新 clone，也不要重建分支**：

   ```bash
   git checkout symphony/{{ issue.identifier }}
   git merge origin/<跟踪分支>    # 有冲突就解决冲突，不要 reset 掉已有提交
   ```

   子仓库同理：先 `git -C <子目录> checkout symphony/{{ issue.identifier }}`，再 merge 目标分支。

3. 只在已有改动上**增量修改**，不要回退上一轮已经评审过的内容。

4. 改完推送**同一个分支名** `symphony/{{ issue.identifier }}`——GitLab 会自动更新原 MR。
   **严禁再建新 MR**，否则评审历史会被割裂。

5. 结论里写清楚「本轮针对哪条评审意见做了什么修改」，并复用原 MR 链接。

如果工作区里找不到该分支（例如分支已被清理），才按首次流程重新创建。

## 交付方式:推分支 + 开 MR

本节是本次自动化运行的交付约定,**覆盖 `AGENTS.md` §5 中"不推送"的默认规则**:

- 对每个发生改动的仓库(根仓库与相关子仓库)分别创建分支 `symphony/{{ issue.identifier }}` 并推送:

  ```bash
  git push -u origin symphony/{{ issue.identifier }}
  ```

- **该 GitLab 实例不支持 `merge_request.create` 推送选项**,已实测:推送后只返回 `merge_requests/new?...` 链接,不会自动建 MR。因此 MR 分两种情况:
  - 环境变量 `GITLAB_TOKEN` 存在 → 用 GitLab REST API 直接建 MR(见下),这样才有可评审的 MR。
  - `GITLAB_TOKEN` 不存在 → 不要臆造,把 GitLab 返回的 MR 创建链接原样记录到结论里。
- 用 API 建 MR 的写法(target 用该仓库自己的跟踪分支:子仓库见 `.gitmodules` 的 `branch`,根仓库用 `master`):

  ```bash
  curl -s --noproxy '*' --request POST \
    -H "PRIVATE-TOKEN: $GITLAB_TOKEN" \
    -H "Content-Type: application/json" \
    --data '{"source_branch":"symphony/{{ issue.identifier }}","target_branch":"<跟踪分支>","title":"{{ issue.identifier }}: <简短标题>","remove_source_branch":true}' \
    "http://192.168.175.55:9888/api/v4/projects/<url-encoded-path>/merge_requests"
  ```

  `<url-encoded-path>` 例:`mijiuye%2Fiidp-aios`。**任何访问 `192.168.175.55` 的 curl/git 都必须绕过本机代理**——curl 一律加 `--noproxy '*'`,git 一律用 `-c http.proxy= -c https.proxy=`。
- 子仓库改动先在各子仓库提交并推分支,再回根仓库 `git add <子模块路径>` 推进指针、提交并推根仓库分支。
- 全部完成后，先用 `shanzhi_remark_bug` 把「改动清单 + 各仓库 MR 链接」写回该 Bug 的操作历史。
- **最后调用 `shanzhi_resolve_bug` 把 Bug 置为「已解决」**（`resolution` 默认 `fixed`，并在 `comment` 里写明 MR 链接），不要置为「已关闭」。
  「已解决」在 Symphony 里等价于 `In Review`：agent 会停下、工作区保留，等待人工验收；
  「已关闭」是终止状态，会立即停止 agent 并删除工作区（未推送的改动会一并丢失）。

## 各仓库的 GitLab 项目路径

| 目录 | GitLab project path（URL 编码后） | 跟踪分支 |
|---|---|---|
| `.`（根） | `mijiuye%2Fiidp-aios` | `master` |
| `sie-snest/` | `ipaas%2Fsie-snest` | `feat_sse` |
| `sie-snest-sdk/` | `ipaas%2Fsie-snest-sdk` | `feat-aios` |
| `iidp-backend-demo-ai/` | `mijiuye%2Fiidp-backend-demo-ai` | `aios-test-lj` |
| `sie-iidp-app-store/` | `appDev%2Fsie-iidp-app-store` | `v3.0.1-HOTFIX.001-jdk21` |
| `sie-iidp-ai-agent-web/` | `TECH%2Ffunctional-app%2Fsie-iidp-ai-agent-web` | `dev` |
| `sie-iidp-iam/` | `appDev%2Fsie-iidp-iam` | `demo/iter2-aios-compat` |

## 硬约束

- 严禁直接推 `master` / `dev` 等跟踪分支,只推 `symphony/<issue>` 分支。
- 严禁在 `/Users/mjy`(home 目录)执行任何 git add / commit / push。
- 不提交编译与部署产物(`target/`、`node_modules/`、`*.class`、`*.zip`、`logs/`、`out/`)。
- 不要为 app 新字段手工书写 `ALTER TABLE` 或迁移 SQL,也不要手工重启容器。
- `sie-iidp-base-inner-web` 你对它没有推送权限:不要修改该子模块;若任务必须改它,停下来在 issue 里评论说明后结束。
- commit message 说明改了什么、为什么;回复里给出改动清单与 MR 链接。
