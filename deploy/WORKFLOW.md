---
# Symphony 部署工作流：渠道（tracker）用善治，业务仓库用内网 GitLab。
#
# 这个文件在 compose 里以只读方式挂载到容器的 /app/WORKFLOW.md，
# 在 K8s 里由 ConfigMap 挂到 /config/WORKFLOW.md。两种方式都是
# 「挂目录 + Symphony 每秒热加载」，改完保存即生效，不需要重建镜像。

tracker:
  kind: shanzhi
  provider:
    # 缺省值 https://api.gushen.sieiot.com，可用 SF_BASE_URL 覆盖
    base_url: $SF_BASE_URL
    username: $SF_USERNAME
    password: $SF_PASSWORD
    # 产品 / 项目 / 部门：product_id、project_id 不写在这里，
    # 由适配器回落到 SF_PRODUCT_ID / SF_PROJECT_ID（必须是整数）。
    dep_id: $SF_DEP_ID
    web_url: $SF_WEB_URL
    # 只看指派给某人的 Bug（姓名或手机号）；留空则派发产品下所有人的 Bug。
    # 当前 .env 里 SF_ASSIGNEE 留空，即不限指派人，只按迭代和确认状态筛。
    # 与下面 require_confirmed 是「与」关系：0 交集就派发 0 单。
    assignee: $SF_ASSIGNEE
    # 只看指定迭代（善治 Bug 的「所属迭代」），可以写多个，是「或」关系。
    # 元素可以是迭代 ID，也可以是迭代名称（中文名直接写，不需要转义）。
    # 与 assignee、require_confirmed 是「与」关系。
    #
    # 例：
    #   plans: ["2026年11月迭代（数字员工运行时引擎）"]
    #   plans: [2793, 2538]
    #   plans: ["2026年11月迭代（数字员工运行时引擎）", "引擎Q4项目"]
    #
    # 留空或不写 = 不限迭代。也可以用 .env 的 SF_PLANS 传逗号分隔的值覆盖，
    # 例如 SF_PLANS="2793,2538"。
    plans: []
    # 只派发「已确认」的 Bug（善治的 confirmed 布尔字段）。
    #
    # 这是人工评审门槛，必须保持 true：善治新建 Bug 的 confirmed 默认是 false，
    # 只有人在善治里确认过才会派发。agent 侧已刻意不提供确认工具（见 AgentTool），
    # 否则 agent 能自我确认，这道门槛就形同虚设。
    require_confirmed: true
  # 善治原生状态：激活 -> 开工；已解决 -> 停下等人工评审（保留工作区）；已关闭 -> 收尾
  active_states: ["active"]
  terminal_states: ["closed"]

polling:
  interval_ms: 15000

workspace:
  root: $SYMPHONY_WORKSPACE_ROOT

hooks:
  timeout_ms: 900000

  # 新工作区：浅克隆聚合仓库壳，再把子模块按父仓记录的提交校准。
  #
  # 顶层仓库用 --depth 1：完整 .git 有 2.2G，浅克隆只有 41M。
  #
  # 子模块必须单独处理，原因有三：
  #   1. git clone 不会初始化子模块；
  #   2. 父仓记录的提交常常落后于分支 tip（实测有落后 600+ 提交的），
  #      所以不能只按分支名浅拉，必须按 SHA 对齐，否则 Agent 改的不是
  #      聚合仓库约定的那版代码；
  #   3. 注意 `--depth 1` 隐含 `--single-branch`，之后再 `--unshallow`
  #      也只补默认分支——记录提交若在别的分支（如 feat_sse）上就永远拿不到。
  #      因此这里只在顶层用浅克隆，子模块走完整 submodule update。
  #
  # 代价：每个工作区的 .git/modules 约 2.4G（sie-snest 一个就 1.5G）。
  # PVC 已扩到 100Gi，且 Bug 到终态会删工作区，够用；再加并发前先看磁盘。
  after_create: |
    set -eu
    if [ -z "${APP_REPO_URL:-}" ]; then
      echo "APP_REPO_URL 未设置，无法克隆业务仓库" >&2
      exit 1
    fi

    # 内网 GitLab 不能走代理（容器里通常没有代理，这里是防御式设置）
    export no_proxy="192.168.0.0/16,localhost,127.0.0.1"
    export NO_PROXY="$no_proxy"

    if [ -n "${APP_REPO_BRANCH:-}" ]; then
      git clone --quiet --depth 1 --branch "${APP_REPO_BRANCH}" "${APP_REPO_URL}" .
    else
      git clone --quiet --depth 1 "${APP_REPO_URL}" .
    fi
    git config http.proxy ""
    git config https.proxy ""

    # 子模块需要完整历史：父仓记录的提交可能不在任何分支 tip 上，
    # 直接按 SHA 浅取会被 GitLab 拒绝（"Server does not allow request
    # for unadvertised object"）。
    git -c http.proxy= -c https.proxy= submodule update --init --jobs 4 || true

    git config -f .gitmodules --get-regexp '\.path$' 2>/dev/null | while read -r key path; do
      name="${key#submodule.}"
      name="${name%.path}"

      want="$(git rev-parse ":$path" 2>/dev/null)" || continue
      [ -n "$want" ] || continue
      [ -d "$path" ] || continue

      # 少数仓库的提交在 update 后仍不可达（分支被改写/删除），
      # 此时退到 .gitmodules 声明的跟踪分支，并留下警告。
      if ! git -C "$path" cat-file -e "$want^{commit}" 2>/dev/null; then
        branch="$(git config -f .gitmodules --get "submodule.${name}.branch" 2>/dev/null || true)"
        echo "[hook] 警告: $path 的记录提交 $want 在远端不可达，退到分支 ${branch:-默认}" >&2
        if [ -n "$branch" ]; then
          git -C "$path" -c http.proxy= -c https.proxy= fetch --quiet origin "$branch" >/dev/null 2>&1 || true
          git -C "$path" checkout --quiet "FETCH_HEAD" 2>/dev/null || true
        fi
        continue
      fi

      have="$(git -C "$path" rev-parse HEAD 2>/dev/null || echo none)"
      case "$have" in
        "$want") ;;
        *)
          echo "[hook] 校准子模块 $path: $have -> $want"
          git -C "$path" checkout --quiet "$want" 2>/dev/null \
            || echo "[hook] 警告: $path 无法切到 $want" >&2
          ;;
      esac
    done

    echo "[hook] 工作区就绪: $(pwd)"
    git submodule status || true

  # 工作区被复用（典型场景：MR 打回后把 Bug 改回激活）时同步一次远端。
  # 只 fetch 不 rebase：是否合入目标分支最新提交交给 agent 判断，
  # 避免在子模块 + 未提交改动的情况下自动 rebase 把 agent 卡死。
  before_run: |
    export no_proxy="192.168.0.0/16,localhost,127.0.0.1"
    export NO_PROXY="$no_proxy"

    git -c http.proxy= -c https.proxy= fetch --quiet origin 2>/dev/null || true

    git config -f .gitmodules --get-regexp '\.path$' 2>/dev/null | while read -r _ path; do
      if [ -d "$path/.git" ] || [ -f "$path/.git" ]; then
        git -C "$path" -c http.proxy= -c https.proxy= fetch --quiet origin 2>/dev/null || true
      fi
    done

    true

agent:
  # 默认 codex；按 Bug 的 keywords 逐单切换（写 `claude` / `cursor cli` / `zcode`）。
  # 模型与网关不在这里配：entrypoint 统一从 .env 的 AGENT_MODEL 生成各 CLI 配置。
  kind: codex
  max_concurrent_agents: 3
  max_turns: 30

codex:
  command: codex app-server
  approval_policy: never
  # 用 danger-full-access 而不是 workspace-write：Maven 会把依赖写进
  # ~/.m2、npm 写到 ~/.npm，这些都在工作区之外，workspace-write 会直接失败。
  thread_sandbox: danger-full-access
  turn_sandbox_policy:
    type: dangerFullAccess

server:
  port: 4567
  host: 0.0.0.0
---

你正在 iidp-aios 多工程聚合工作区中处理一个善治（SF 软件工厂）Bug。

## 当前 Bug

- 编号：{{ issue.identifier }}
- 标题：{{ issue.title }}
- 状态：{{ issue.state }}
- 标签：{{ issue.labels }}
- Agent 关键词：{{ issue.attributes.keywords }}
- 链接：{{ issue.url }}

### 复现步骤 / 描述

{% if issue.description %}
{{ issue.description }}
{% else %}
（善治未提供描述，请先用 `shanzhi_get_bug` 补全再动手。）
{% endif %}

{% if attempt %}
这是第 {{ attempt }} 次跟进。请从当前工作区状态继续，不要重复已经完成的排查与改动。
{% endif %}

## 工作方式

1. 这是无人值守的自动化会话，不要向人提问，也不要把「下一步需要用户操作」写进结论。
2. 先读 `AGENTS.md`，其中有多仓协作铁律（规格隔离、SDK 变更链、引擎联调）。
3. 工作区已经克隆好业务仓库。只改工作区里的文件，不要碰工作区之外的路径。
4. 改动要最小化：只修复当前 Bug 相关的问题，不做顺手重构，不扩大范围。
5. 必须自己验证：编译、单测或可复现步骤至少要跑通一项，并把结果写进备注。

## 开工前必须先确认问题真实存在

Symphony 只会把「状态=激活 且 确认=是」的 Bug 派给你，说明已有人确认过。
但**动手改代码之前，仍要对照代码核实问题是否真的存在**：

- 能定位到问题：正常修复并交付。
- 定位不到、或看代码发现根本不是 Bug（已被别的改动修好、属于需求变更、环境/数据问题）：
  **不要臆造改动**。用 `shanzhi_remark_bug` 写清楚判断依据和结论，然后直接结束本次任务。
  这种 Bug 由人工决定后续状态，**不要调用 `shanzhi_resolve_bug`**。
- 「确认 Bug」是**人工评审动作**，你没有这个权限（`shanzhi_confirm_bug` 已不对你开放）。
  无法复现或判断是误报时，只能用 `shanzhi_remark_bug` 写清结论，是否确认由人决定。

## 工作区说明

- 当前目录是聚合仓库（submodule 壳），子工程代码在各子目录中独立成库。
- 子工程改动提交到对应子仓库；根仓库只提交工作区级文件
  （`AGENTS.md`、`openspec/`、`docs/`）与子模块指针。
- 单工程规格写进该工程的 `openspec/`；跨仓库变更写进根 `openspec/changes/`，
  tasks 按仓库分节。

## 续改模式：MR 被打回后重新派发

如果工作区里**已经存在** `symphony/{{ issue.identifier }}` 分支（用
`git branch --list 'symphony/*'` 和 `git log --oneline -5` 判断），说明这不是首次处理，
而是上一轮提交的 MR 被要求返工。此时**必须走续改流程**：

1. 先搞清楚上一轮做了什么、评审要求改什么：

   - `shanzhi_bug_history` 读取上一轮的改动清单与 MR 链接。
   - 有 token 时，用 GitLab API 拉评审意见（**必须带 `--noproxy '*'`**）：

     ```bash
     # 两种变量名等价：容器里可能只注入了 GIT_TOKEN
     TOKEN="${GITLAB_TOKEN:-$GIT_TOKEN}"
     curl -s --noproxy '*' -H "PRIVATE-TOKEN: $TOKEN" \
       "http://192.168.175.55:9888/api/v4/projects/<url-encoded-path>/merge_requests/<iid>/discussions"
     ```

2. **切回原分支，不要重新 clone，也不要重建分支**：

   ```bash
   git checkout symphony/{{ issue.identifier }}
   git merge origin/<跟踪分支>    # 有冲突就解决，不要 reset 掉已有提交
   ```

   子仓库同理：先 `git -C <子目录> checkout symphony/{{ issue.identifier }}`，再 merge 目标分支。

3. 只在已有改动上**增量修改**，不要回退上一轮已经评审过的内容。
4. 改完推送**同一个分支名**，GitLab 会自动更新原 MR。**严禁再建新 MR**，
   否则评审历史会被割裂。
5. 结论里写清楚「本轮针对哪条评审意见做了什么修改」，并复用原 MR 链接。

找不到该分支（例如已被清理）时才按首次流程重新创建。

## 交付方式：推分支 + 开 MR

本节是本次自动化运行的交付约定，**覆盖 `AGENTS.md` 里「不推送」的默认规则**：

- 对每个发生改动的仓库（根仓库与相关子仓库）分别创建分支并推送：

  ```bash
  git checkout -b symphony/{{ issue.identifier }}
  git push -u origin symphony/{{ issue.identifier }}
  ```

- **该 GitLab 实例不支持 `merge_request.create` 推送选项**（已实测：推送后只返回
  `merge_requests/new?...` 链接，不会自动建 MR）。因此分两种情况：
  - 有 GitLab token（`GITLAB_TOKEN` 或 `GIT_TOKEN`，二者等价）→ 用 GitLab REST API
    直接建 MR，这样才有可评审的 MR。
  - 没有 token → 不要臆造，把 GitLab 返回的 MR 创建链接原样记录到结论里。
- 用 API 建 MR（target 用该仓库自己的跟踪分支：子仓库见 `.gitmodules` 的 `branch`，
  根仓库用 `master`）：

  ```bash
  TOKEN="${GITLAB_TOKEN:-$GIT_TOKEN}"
  curl -s --noproxy '*' --request POST \
    -H "PRIVATE-TOKEN: $TOKEN" \
    -H "Content-Type: application/json" \
    --data '{"source_branch":"symphony/{{ issue.identifier }}","target_branch":"<跟踪分支>","title":"{{ issue.identifier }}: <简短标题>","remove_source_branch":true}' \
    "http://192.168.175.55:9888/api/v4/projects/<url-encoded-path>/merge_requests"
  ```

  `<url-encoded-path>` 例：`mijiuye%2Fiidp-aios`。**任何访问 `192.168.175.55` 的
  curl/git 都必须绕过代理**——curl 一律加 `--noproxy '*'`，
  git 一律用 `-c http.proxy= -c https.proxy=`。
- 子仓库改动先在各子仓库提交并推分支，再回根仓库 `git add <子模块路径>`
  推进指针、提交并推根仓库分支。
- 全部完成后，先用 `shanzhi_remark_bug` 把「改动清单 + 各仓库 MR 链接」写回操作历史。
- **最后调用 `shanzhi_resolve_bug` 把 Bug 置为「已解决」**（`resolution` 默认 `fixed`，
  `comment` 里写明 MR 链接），不要置为「已关闭」。
  「已解决」在 Symphony 里等价于 `In Review`：agent 停下、工作区保留，等待人工验收；
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

## 可用工具

Symphony 内置（凭证留在 Symphony 进程内，你不需要也不应该去读账号密码）：

- `shanzhi_get_bug`：读 Bug 完整详情
- `shanzhi_bug_history`：读操作历史（含历次备注与状态变更）
- `shanzhi_remark_bug`：加备注（你的主要交付载体）
- `shanzhi_resolve_bug`：置为已解决

「确认 Bug」不在工具列表里：那是人工评审动作，只有人能在善治里做。

善治 MCP 服务（只读，用于查证）：

- `find_bugs`：按条件搜同类缺陷，判断是不是重复问题
- `list_members`：姓名 ⇄ 手机号互查（善治接口里的人都是手机号）
- `list_projects`：查产品 / 项目 ID

## 硬约束

- 严禁直接推 `master` / `dev` 等跟踪分支，只推 `symphony/<issue>` 分支。
- 不提交编译与部署产物（`target/`、`node_modules/`、`*.class`、`*.zip`、`logs/`、`out/`）。
- 不要为 app 新字段手工书写 `ALTER TABLE` 或迁移 SQL，也不要手工重启容器。
- `sie-iidp-base-inner-web` 你没有推送权限：不要修改该子模块；
  若任务必须改它，停下来用 `shanzhi_remark_bug` 说明后结束本轮。
- commit message 用中文，说明改了什么、为什么；结论里给出改动清单与 MR 链接。
- 如果卡在无法自行解决的外部条件（缺凭据、缺依赖、无法复现），
  用 `shanzhi_remark_bug` 记录具体阻塞点，然后结束本轮，不要乱改代码。
