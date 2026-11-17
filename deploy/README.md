# Symphony 一体化部署

把 Symphony 和它需要的全部 Agent CLI 打成一个镜像，用善治（SF 软件工厂）作为工作渠道，
Agent 的工作区克隆内网 GitLab 的业务仓库（默认 `iidp-aios`）。

## 镜像里有什么

| 组件 | 说明 |
|---|---|
| Symphony | Elixir escript，看板 LiveView 与静态资源编译进包内 |
| `codex` | `@openai/codex`，Symphony 的默认 Agent（`codex app-server`） |
| `claude` | `@anthropic-ai/claude-code`，Claude Code CLI |
| `cursor-agent` | Cursor CLI（官方安装脚本，自带运行时） |
| `zcode` | ZCode CLI（Node 运行时，安装包可替换） |
| 工具链 | Node.js 22、JDK 21、Maven、git、openssh、ripgrep、jq、python3 |

Agent 选择规则由 Symphony 的 `SymphonyElixir.Agent.Kind` 决定：善治 Bug 的 **keywords** 字段
写 `codex` / `cursor cli` / `zcode` / `claude`，留空默认 `codex`。

## 目录

```
deploy/
├── Dockerfile           # 多阶段构建：escript 编译 + 运行时 + 四个 CLI
├── docker-compose.yml   # 单容器部署，挂载 data/ 与各 CLI 登录态
├── WORKFLOW.md          # 部署用工作流（善治 + GitLab 仓库），热加载
├── entrypoint.sh        # 降权、git 凭据、预检、启动
├── deploy.sh            # 构建/启动/日志/状态等命令
├── env.example          # 配置模板
├── .env                 # 实际配置（已 gitignore）
├── data/                # 工作区 + 日志（已 gitignore）
└── auth/                # 各 CLI 登录态（已 gitignore）
```

## 快速开始

```bash
cd deploy
./deploy.sh init          # 生成 .env 和目录
vi .env                   # 填善治账号、产品 ID、GitLab 凭据
./deploy.sh deploy        # 构建并启动
./deploy.sh status        # 看状态
```

看板默认在 `http://<主机>:4567/`。

## 必填配置

| 变量 | 说明 |
|---|---|
| `APP_REPO_URL` | 业务仓库，默认 `http://192.168.175.55:9888/mijiuye/iidp-aios.git` |
| `GIT_USERNAME` / `GIT_TOKEN` | 内网 GitLab 凭据（PAT 即可）。entrypoint 会写入 `~/.git-credentials`，Agent 才能 clone/push |
| `SF_USERNAME` / `SF_PASSWORD` | 善治登录账号 |
| `SF_PRODUCT_ID` | 善治产品 ID（整数，必填） |
| `SF_PROJECT_ID` | 善治项目 ID（可选） |
| `SF_DEP_ID` | 部门 ID（可选，缺省用客户端默认值） |
| `SF_ASSIGNEE` | 只看指派给某人的 Bug（姓名或 11 位手机） |

`SF_PASSWORD` 等敏感变量只会留在 Symphony 进程里：派发 Agent 时 Symphony 会把这些环境变量
从子进程里剔除，Agent 通过 `shanzhi_*` 工具间接读写 Bug。

## 模型配置（OpenAI 兼容网关）

`.env` 里填这几项就够了，entrypoint 会把同一套网关配置展开到各 CLI，换网关不用逐个改文件：

```bash
OPENAI_BASE_URL=https://one-api.sd.sieiot.com/v1
OPENAI_API_KEY=sk-xxxxxxxx
AGENT_MODEL=local-glm5.3
AGENT_LITE_MODEL=local-glm5.3
```

| CLI | 生效方式 | 落盘位置 |
|---|---|---|
| codex | `model_provider = oneapi`，`wire_api = "responses"` | `~/.codex/config.toml`（每次启动重写） |
| claude | `ANTHROPIC_BASE_URL` + `ANTHROPIC_AUTH_TOKEN` + `ANTHROPIC_MODEL` | 仅环境变量 |
| zcode | provider `kind = anthropic`，指向同一网关 | `~/.zcode/cli/custom.env` |
| cursor | **不支持** | Cursor 私有协议，只能用 `CURSOR_API_KEY` |

zcode 通道还有一层兼容：社区 `zcode-cli` 不认识适配器的 `--output-format stream-json`，
镜像里用 `deploy/zcode-stream-shim.sh` 顶替 `zcode` 命令，把调用翻译成 `--json`，
再把结果转成适配器认的 NDJSON。代价是**没有流式增量与工具调用明细**，一轮结束才上报最终文本。

要点：

- codex 0.169 起只支持 `wire_api = "responses"`，网关必须实现 `/v1/responses`。
  one-api 的模型 `supported_endpoint_types` 里要有 `openai-response`。
- 密钥不写进 `config.toml`（用 `env_key = "OPENAI_API_KEY"` 从环境变量取）；
  zcode 的 `custom.env` 因为格式限制只能内联，已 `chmod 600`。
- Claude Code 的 `~/.claude/settings.json` 里如果写了 `env.ANTHROPIC_BASE_URL`，
  优先级高于 `.env`，会盖掉本次配置；entrypoint 启动时会告警。
- `AGENT_MODEL_CONTEXT_WINDOW` 影响两处：codex 的 `model_context_window`，
  以及 claude 的 `CLAUDE_CODE_AUTO_COMPACT_WINDOW`（决定何时自动压缩）。
  网关不返回模型元数据，不确定就留空，让 CLI 用兜底值。
- 生成的文件旁边会有 `.symphony-managed` 标记；宿主上自己写过同名文件时，
  会先备份成 `*.user-backup` 再覆盖。
- codex 想追加 MCP 等配置，写进 `auth/codex/config.toml.extra`，启动时追加到生成配置末尾。

`local-glm5.3` 之外，网关还提供 `local-glm5.3-flash`、`local-glm5.2-fp8`、
`local-qwen3.5`、`local-qwen3-32b`、`local-qwen3-vl-30b` 等，改 `AGENT_MODEL` 即可切换。

## 善治 MCP 服务

镜像里除了 Symphony 内置的 `/mcp` 端点，还装了独立的
[shanzhi_mcp](http://192.168.175.55:9888/mijiuye/shanzhi_mcp.git) 服务，
用 stdio 传输，由 Agent CLI 按需拉起。

两者的分工：

| 来源 | 传输 | 工具 |
|---|---|---|
| Symphony `/mcp` | HTTP | `shanzhi_get_bug`、`shanzhi_bug_history`、`shanzhi_remark_bug`、`shanzhi_resolve_bug` |
| 独立 MCP 服务 | stdio | `find_bugs`、`get_bug`、`get_bug_history`、`list_members`、`list_projects`（`create_bug` 等写操作默认不开放） |

配置方式（`.env`）：

```bash
SHANZHI_MCP_ENABLED=1
SHANZHI_MCP_TOOLS=readonly      # readonly | all
SHANZHI_MCP_REPO=http://192.168.175.55:9888/mijiuye/shanzhi_mcp.git
SHANZHI_MCP_REF=master
```

启动时 entrypoint 做三件事：

1. 用 `SF_*` 生成 `~/.config/shanzhi-mcp/config.json`（600），token 缓存也落在同目录；
2. 往 codex 的 `config.toml` 追加 `[mcp_servers.shanzhi_bug]`；
3. 通过 `SYMPHONY_EXTRA_MCP_SERVERS` 把这个 stdio 服务合并进 claude 的 `--mcp-config`
   （Symphony 用 `--strict-mcp-config` 屏蔽用户级 MCP，所以必须从这边注入）。

为什么默认只读：善治的「提 Bug / 确认」是对生产缺陷库的写操作。Symphony 内置工具
本来就刻意不提供 `create_bug`，独立服务也保持一致；确实需要时把
`SHANZHI_MCP_TOOLS` 改成 `all`。

凭证放在服务自己的配置文件里，只把路径传给 MCP 服务，agent 的进程环境里不出现账号密码。

## 部署到线上（Kubernetes / Rancher）

`deploy/k8s/` 是同一份镜像在集群里的部署清单，目标集群 `rancher-gky.sie.iidp.cn`，
命名空间 `symphony`。

```bash
export KUBECONFIG=~/.rancher/gky-kubeconfig
cd deploy/k8s && ./apply.sh
```

`apply.sh` 会依次做：

1. 建命名空间 `symphony`；
2. 从集群已有的 `authmcp/harbor-regcred` 复制 Harbor 拉取凭证（不再存一份账号密码）；
3. 从 `deploy/.env` 过滤出运行期变量，写成 `Secret symphony-env`；
4. 生成看板登录 `Secret symphony-basic-auth`，**首次运行会打印随机密码**，请保存；
5. 把 `deploy/WORKFLOW.md` 同步成 `ConfigMap symphony-workflow`；
6. `kubectl apply -k` 应用清单并等待滚动完成。

改工作流不用重新部署，热加载即可：

```bash
./apply.sh --workflow-only
```

### 与本地 compose 的差异

| 关注点 | compose | K8s |
|---|---|---|
| 持久化 | 宿主 `./data` | PVC `symphony-data`（longhorn-retain，30Gi） |
| 端口 | 4599（宿主占用） | 4567，Service + Ingress |
| WORKFLOW.md | 挂载宿主文件 | ConfigMap 挂到 `/config`，`WORKFLOW_PATH` 指过去 |
| 入口 | 直连 `host:4599` | `https://symphony.dev.sie.iidp.cn` + basic-auth |
| 副本 | 1 | 1（Recreate，RWO 卷 + 状态在本地） |

两个容易踩的坑：

- **ConfigMap 必须目录挂载，不能用 subPath**。subPath 的内容不随 ConfigMap 更新刷新，
  而 Symphony 靠热加载 `WORKFLOW.md` 改派发规则。
- **镜像要 amd64**。集群节点全是 amd64，Apple Silicon 上必须
  `docker buildx build --platform linux/amd64`，否则 Pod 起不来（exec format error）。

### 发布新版本

```bash
cd /Users/mjy/symphony
docker buildx build --platform linux/amd64 --target runtime -f deploy/Dockerfile \
  -t harbor.devcenter.gushen.sieiot.com/iidp/symphony-agent:v2 --push .
export KUBECONFIG=~/.rancher/gky-kubeconfig
kubectl set image deployment/symphony -n symphony \
  symphony=harbor.devcenter.gushen.sieiot.com/iidp/symphony-agent:v2
```

### 集群侧依赖（已实测连通）

| 目标 | 用途 |
|---|---|
| `192.168.175.55:9888` | 内网 GitLab（业务仓库 + 善治 MCP 仓库） |
| `192.168.168.156:8081` | Maven 私服 |
| `https://one-api.sd.sieiot.com` | 模型网关 |
| `https://api.gushen.sieiot.com` | 善治 Bug 接口 |

## CLI 登录态

走上面的网关之后，codex / claude / zcode 都不需要交互登录；只有 cursor 通道需要登录。
推荐在任意一台机器上登录一次，把配置拷进 `deploy/auth/`：

| CLI | 宿主机路径 | 容器内 |
|---|---|---|
| codex | 一般无需挂载（配置由 entrypoint 生成） | `/home/symphony/.codex/` |
| claude | 一般无需挂载（注意别带写死 `ANTHROPIC_BASE_URL` 的 `settings.json`） | `/home/symphony/.claude/` |
| cursor | `~/.cursor/cli-config.json`（或 `CURSOR_API_KEY`） | `/home/symphony/.cursor/` |
| zcode | 一般无需挂载（配置由 entrypoint 生成） | `/home/symphony/.zcode/` |
| ssh | `~/.ssh/id_ed25519` 等 | `/home/symphony/.ssh/`（只读） |

也可以不进容器交互登录，直接在 `.env` 里给 `CURSOR_API_KEY` 这类变量——
Symphony 会把环境变量透传给子进程。

> 注意：`cursor-agent login` 会把凭据写在 `~/.cursor`，`claude` 写在 `~/.claude`，
> 以 root 身份登录会写进 `/root`，容器里读不到，所以本镜像统一用普通用户 `symphony`。

## 工作流与路由

`deploy/WORKFLOW.md` 以只读方式挂进容器，Symphony 每秒热加载一次，改完保存即生效，
**不需要重建镜像**。它做了三件事：

1. `tracker.kind: shanzhi`，状态映射 `active -> 开工`、`resolved -> 停下等评审`、`closed -> 收尾清理`；
2. `hooks.after_create` 用 `APP_REPO_URL` 克隆业务仓库；
3. 提示词要求 Agent 复现 → 最小改动 → 编译/单测验证 → 推 `fix/SF-<id>` 分支 → 备注 → 置为已解决。

改工作流别把 token 写进去：Agent 能读到工作区里的 `WORKFLOW.md`，凭据统一走环境变量或挂载文件。

## 常用命令

```bash
./deploy.sh build        # 只构建
./deploy.sh up           # 只启动（不重建）
./deploy.sh deploy       # 构建 + 启动
./deploy.sh logs         # 跟日志
./deploy.sh status       # 容器状态 + 看板摘要
./deploy.sh cli-check    # 打印镜像内各 CLI 版本
./deploy.sh model-check  # 用 .env 的网关配置实跑一次 codex / claude / zcode
./deploy.sh shell        # 进容器
./deploy.sh restart      # 改 .env 后重启
./deploy.sh update       # git pull + 重建 + 重启
./deploy.sh push         # 推镜像到私有 registry
```

## 在服务器上部署

1. 服务器装好 Docker 与 compose 插件，能访问 `192.168.175.55:9888`、善治 API 与 npm/下载源；
2. 把仓库（或至少 `elixir/` + `deploy/`）拷到服务器；
3. `cd deploy && ./deploy.sh init && vi .env && ./deploy.sh deploy`。

镜像内默认按 `.env` 的 `TARGET_PLATFORM` 构建（默认 `linux/amd64`）。**在目标服务器上直接构建**
可以避开跨架构模拟，速度最快；如果一定要在 Apple Silicon 上构建 x86 镜像，把
`TARGET_PLATFORM` 留空可得到本机架构镜像，但服务器上跑不了。

### 构建资源

镜像里同时装了 JDK 21、Node.js 和四个 CLI，成品约 **4~5 GB**（JDK 约 300 MB，Claude Code 的
`node_modules` 和 Cursor 自带运行时各占几百 MB，加上 Erlang/Elixir 运行时）。构建过程峰值需要
**10 GB 以上空闲磁盘** 和 4 GB 以上内存；磁盘不足时 BuildKit 会在最后的 `exporting to image`
阶段报 `input/output error`，这不是 Dockerfile 的问题，清出空间后重试即可。

### 数据目录

容器内的 `/data` 挂到宿主的 `deploy/data/`：

```
data/
├── log/symphony.log      # Symphony 运行日志（自动轮转，10MB × 5）
└── workspaces/<SF-id>/   # 每个 Bug 一个独立工作区
```

## 常见问题

- **`docker` 命令全部挂住 / 报 `unmarshaling start request: unexpected EOF`**：这是 Docker Desktop 的
  fork/exec 助手损坏（常见于长时间运行或强制 kill 后端之后），不是本仓库的问题。
  `docker.sock` 不会响应，重启 Docker Desktop 也只会拉起一个立刻崩溃的后端。
  处理办法：**重启 macOS**；仍不行则重新安装 Docker Desktop。
- **构建时 npm 拉不动**：把 `NPM_REGISTRY` 换成内网/国内镜像，例如 `https://registry.npmmirror.com`。
- **preview 构建要可复现**：把 `CODEX_VERSION`、`CLAUDE_CODE_VERSION`、`ZCODE_CLI_PKG` 钉到具体版本。
- **不想要 ZCode**：把 `ZCODE_CLI_PKG` 置空，Dockerfile 会跳过安装。
- **看板打不开**：`./deploy.sh logs` 看是否卡在 `shanzhi` 登录或工作流解析失败；
  `/api/v1/state` 不可达通常是 `server.port` 没生效或进程还没起。
- **Agent 一直不派发**：善治要求 `状态=激活` **且** `确认=是`；另外 `SF_ASSIGNEE` 填了但没匹配到人也不会派发。
- **Agent 改了代码却推不上去**：检查 `GIT_USERNAME` / `GIT_TOKEN` 是否对该仓库有 write 权限，
  以及 `git-credentials` 里的 host 是否和 `APP_REPO_URL` 一致。
- **Agent 报 401 / model not found**：`OPENAI_BASE_URL` 按 OpenAI 习惯写成带 `/v1` 的地址
  （例如 `https://one-api.sd.sieiot.com/v1`）；entrypoint 会自动给 claude/zcode 剥成根地址，
  它们自己拼 `/v1/messages`。再用
  `curl -H "Authorization: Bearer $OPENAI_API_KEY" $OPENAI_BASE_URL/models` 核对模型 id。
- **claude 仍走官方地址**：`auth/claude/settings.json` 里的 `env.ANTHROPIC_BASE_URL` 优先级最高，
  删掉该字段或清空该目录；启动日志会打印告警。
- **codex 报 `wire_api = "chat" is no longer supported`**：0.169 起只支持 `responses`，
  不要手工改 `~/.codex/config.toml`，它每次启动都会被 entrypoint 重写。
- **zcode 通道没有流式输出 / 看不到工具调用**：这是已知取舍。社区 `zcode-cli` 不支持
  Symphony 适配器使用的 `--output-format stream-json`，镜像里用 `deploy/zcode-stream-shim.sh`
  把调用翻译成 `--json` 再转成适配器认的 `result` 事件，因此一轮只在结束时上报最终文本与 usage。
  要用完整协议请换成 ZCode 桌面版自带运行时，并把 `ZCODE_REAL_BIN` 指过去。
