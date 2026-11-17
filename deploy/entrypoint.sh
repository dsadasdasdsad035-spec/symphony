#!/usr/bin/env bash
# Symphony 容器入口脚本。
#
# 职责：
#   1. 以 root 启动时修正挂载目录属主，然后降权到普通用户 symphony
#      （Claude Code 的 --dangerously-skip-permissions 拒绝以 root 运行）；
#   2. 根据环境变量生成 git 凭据与提交身份，让 Agent 能 clone / push 内网 GitLab；
#   3. 把 .env 里的 OpenAI 兼容网关配置展开到 codex / claude / zcode 三个 CLI；
#   4. 生成善治 MCP 服务的凭证配置，并注册到 codex / claude；
#   5. 校验 WORKFLOW.md 与 Agent CLI 是否就绪，出错时给出可读的日志；
#   6. exec 启动 Symphony（escript），保证信号能直达主进程。
set -euo pipefail

APP_USER="${APP_USER:-symphony}"
APP_HOME="/home/${APP_USER}"
WORKFLOW_PATH="${WORKFLOW_PATH:-/app/WORKFLOW.md}"
WORKSPACE_ROOT="${SYMPHONY_WORKSPACE_ROOT:-/data/workspaces}"
LOGS_ROOT="${LOGS_ROOT:-/data}"
SYMPHONY_PORT="${SYMPHONY_PORT:-4567}"
APP_REPO_URL="${APP_REPO_URL:-}"

log() { printf '[entrypoint] %s\n' "$*"; }
die() { printf '[entrypoint] 错误: %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# 1. root -> symphony 降权
# ---------------------------------------------------------------------------
if [ "$(id -u)" = "0" ]; then
  mkdir -p \
    "${WORKSPACE_ROOT}" \
    "${LOGS_ROOT}" \
    "${APP_HOME}"
  for dir in .codex .claude .cursor .zcode .config .local .ssh; do
    mkdir -p "${APP_HOME}/${dir}"
  done

  # 挂载进来的目录可能属于宿主的其它 uid，统一改回运行用户。
  # 部分文件系统（如某些 NFS/只读挂载）不允许 chown，失败不阻塞启动。
  # 工作区可能累积几十万文件，只改目录本身；日志和凭据目录体量小，可以递归。
  chown "${APP_USER}:${APP_USER}" /data "${WORKSPACE_ROOT}" "${APP_HOME}" 2>/dev/null || true
  # Symphony 会在 logs-root 下再建一层 log/，这里一并递归（只含轮转日志，体积小）。
  mkdir -p "${LOGS_ROOT}/log"
  chown -R "${APP_USER}:${APP_USER}" "${LOGS_ROOT}/log" 2>/dev/null || true
  for dir in .codex .claude .cursor .zcode .config .local .ssh; do
    chown -R "${APP_USER}:${APP_USER}" "${APP_HOME}/${dir}" 2>/dev/null || true
  done

  exec gosu "${APP_USER}" "$0" "$@"
fi

log "以用户 $(id -un) (uid=$(id -u)) 启动"

# ---------------------------------------------------------------------------
# 2. git 凭据与身份
# ---------------------------------------------------------------------------
if [ -n "${GIT_USERNAME:-}" ] && [ -n "${GIT_TOKEN:-}" ]; then
  if [ -n "${APP_REPO_URL}" ]; then
    # 从仓库地址里抽出 scheme 与 host[:port]，凭据按 host 生效，
    # 不把 token 写进 WORKFLOW.md（Agent 能读到工作区里的工作流文件）。
    repo_scheme="$(printf '%s' "${APP_REPO_URL}" | sed -E 's#^([A-Za-z][A-Za-z0-9+.-]*)://.*#\1#')"
    repo_host="$(printf '%s' "${APP_REPO_URL}" | sed -E 's#^[A-Za-z][A-Za-z0-9+.-]*://([^/]+).*#\1#')"
    case "${repo_scheme}" in
      http|https) ;;
      *) repo_scheme="" ;;
    esac
    if [ -z "${repo_host}" ] || [ -z "${repo_scheme}" ] || [ "${repo_host}" = "${APP_REPO_URL}" ]; then
      log "警告: 无法从 APP_REPO_URL 解析 scheme/host，跳过 git 凭据写入"
    else
      printf '%s://%s:%s@%s\n' "${repo_scheme}" "${GIT_USERNAME}" "${GIT_TOKEN}" "${repo_host}" \
        > "${APP_HOME}/.git-credentials"
      chmod 600 "${APP_HOME}/.git-credentials"
      git config --global credential.helper store
      log "已为 ${repo_scheme}://${repo_host} 配置 git 凭据（用户 ${GIT_USERNAME}）"
    fi
  else
    log "警告: 未设置 APP_REPO_URL，跳过 git 凭据写入"
  fi
else
  log "未设置 GIT_USERNAME / GIT_TOKEN，假定仓库可以匿名访问或已挂载 SSH key"
fi

# 凭据不对时直接失败，避免 hook 卡在交互式密码提示上直到超时
export GIT_TERMINAL_PROMPT=0

# Agent 建 MR / 拉评审意见走 GitLab REST API，认的是 GITLAB_TOKEN。
# 部署里只配了 GIT_TOKEN（git 推送用），这里映射一份，让提示词里的
# `$GITLAB_TOKEN` 直接可用；显式给了 GITLAB_TOKEN 就以它为准。
if [ -z "${GITLAB_TOKEN:-}" ] && [ -n "${GIT_TOKEN:-}" ]; then
  export GITLAB_TOKEN="${GIT_TOKEN}"
fi

git config --global user.name "${GIT_AUTHOR_NAME:-Symphony Agent}"
git config --global user.email "${GIT_AUTHOR_EMAIL:-symphony-agent@localhost}"
git config --global init.defaultBranch main
# 工作区由容器内不同步骤创建，避免 git 报 dubious ownership。
git config --global --add safe.directory '*'

# ---------------------------------------------------------------------------
# 3. Agent CLI 模型配置（OpenAI 兼容网关）
# ---------------------------------------------------------------------------
# 统一从 .env 里的 OPENAI_BASE_URL / OPENAI_API_KEY / AGENT_MODEL 展开到各 CLI，
# 这样换网关只改一处，不用逐个改 CLI 的配置文件。
LLM_BASE_URL="${OPENAI_BASE_URL:-}"
LLM_API_KEY="${OPENAI_API_KEY:-}"
LLM_MODEL="${AGENT_MODEL:-local-glm5.3}"
LLM_LITE_MODEL="${AGENT_LITE_MODEL:-${LLM_MODEL}}"

# Claude Code 与 ZCode 自己会拼 /v1/messages，因此根地址要剥掉结尾的 /v1
llm_root_url() { printf '%s' "$1" | sed -E 's#/+$##; s#/v1$##'; }

# 目标文件已存在且不是 Symphony 生成的时候，先备份成 *.user-backup，
# 避免宿主上手工调过的配置被无声覆盖。
backup_unmanaged() {
  local file="$1" marker="$2" label="$3"
  if [ -f "${file}" ] && [ ! -f "${marker}" ]; then
    cp -f "${file}" "${file}.user-backup" 2>/dev/null || true
    log "已备份原有 ${label} 配置到 ${file}.user-backup"
  fi
}

configure_codex() {
  local base_url="$1" model="$2"
  local dir="${CODEX_HOME:-${APP_HOME}/.codex}"
  local file="${dir}/config.toml"
  mkdir -p "${dir}"
  backup_unmanaged "${file}" "${dir}/.symphony-managed" codex

  {
    printf '# 由 Symphony 托管：容器每次启动都会重写本文件。\n'
    printf '# 自定义请改 .env 里的 OPENAI_* / AGENT_*；MCP 等追加配置写进 config.toml.extra。\n'
    printf 'model = "%s"\n' "${model}"
    printf 'model_provider = "oneapi"\n'
    if [ -n "${AGENT_MODEL_CONTEXT_WINDOW:-}" ]; then
      printf 'model_context_window = %s\n' "${AGENT_MODEL_CONTEXT_WINDOW}"
    fi
    printf '\n[model_providers.oneapi]\n'
    printf 'name = "One API"\n'
    printf 'base_url = "%s"\n' "${base_url}"
    # 密钥只从环境变量读，不落盘
    printf 'env_key = "OPENAI_API_KEY"\n'
    # codex 0.169 起只支持 responses 协议，chat 已移除
    printf 'wire_api = "responses"\n'
  } > "${file}"

  if [ -f "${file}.extra" ]; then
    printf '\n' >> "${file}"
    cat "${file}.extra" >> "${file}"
    log "已追加 ${file}.extra 里的自定义 codex 配置"
  fi

  touch "${dir}/.symphony-managed"
  log "codex 已指向 ${base_url}（模型 ${model}，配置 ${file}）"
}

configure_claude() {
  local base_url="$1" model="$2" lite="$3"
  export ANTHROPIC_BASE_URL="${base_url}"
  export ANTHROPIC_AUTH_TOKEN="${LLM_API_KEY}"
  export ANTHROPIC_MODEL="${model}"
  export ANTHROPIC_SMALL_FAST_MODEL="${lite}"

  # 网关不返回模型元数据，Claude Code 会按 1M 窗口估算；把自动压缩边界
  # 钉到真实窗口，避免上下文真超限才报错。
  if [ -n "${AGENT_MODEL_CONTEXT_WINDOW:-}" ]; then
    export CLAUDE_CODE_AUTO_COMPACT_WINDOW="${AGENT_MODEL_CONTEXT_WINDOW}"
  fi

  log "claude 已指向 ${base_url}（模型 ${model}）"

  # settings.json 里的 env 优先级高于进程环境，写死了就会盖掉这里的配置
  local settings="${APP_HOME}/.claude/settings.json"
  if [ -f "${settings}" ] && grep -q 'ANTHROPIC_BASE_URL' "${settings}"; then
    log "警告: ${settings} 里写死了 ANTHROPIC_BASE_URL，会覆盖本次配置；" \
        "请删掉该字段，或清空挂载目录 auth/claude"
  fi
}

configure_zcode() {
  local base_url="$1" model="$2" lite="$3"
  local dir="${APP_HOME}/.zcode/cli"
  local file="${dir}/custom.env"
  mkdir -p "${dir}"
  backup_unmanaged "${file}" "${dir}/.symphony-managed" zcode

  # ZCode 只从 custom.env 读自定义 provider，进程环境变量不生效
  cat > "${file}" <<EOF
ZCODE_PROVIDER_ID=oneapi
ZCODE_PROVIDER_NAME=One API
ZCODE_PROVIDER_KIND=anthropic
ZCODE_BASE_URL=${base_url}
ZCODE_API_KEY=${LLM_API_KEY}
ZCODE_MAIN_MODEL=${model}
ZCODE_LITE_MODEL=${lite}
EOF
  chmod 600 "${file}"
  touch "${dir}/.symphony-managed"
  log "zcode provider 已写入 ${file}（模型 ${model}）"
}

if [ -n "${LLM_BASE_URL}" ] && [ -n "${LLM_API_KEY}" ]; then
  LLM_ANTHROPIC_BASE_URL="$(llm_root_url "${LLM_BASE_URL}")"
  configure_codex "${LLM_BASE_URL}" "${LLM_MODEL}"
  configure_claude "${LLM_ANTHROPIC_BASE_URL}" "${LLM_MODEL}" "${LLM_LITE_MODEL}"
  configure_zcode "${LLM_ANTHROPIC_BASE_URL}" "${LLM_MODEL}" "${LLM_LITE_MODEL}"

  if [ -z "${CURSOR_API_KEY:-}" ]; then
    log "提示: cursor-agent 走 Cursor 私有协议，接不了 OpenAI 兼容网关；" \
        "要用 cursor 通道请提供 CURSOR_API_KEY"
  fi
else
  log "未设置 OPENAI_BASE_URL / OPENAI_API_KEY，跳过模型配置，沿用各 CLI 已有登录态"
fi

# ---------------------------------------------------------------------------
# 4. 善治 MCP 服务（stdio，由 Agent CLI 按需拉起）
# ---------------------------------------------------------------------------
# Symphony 自己已经通过 /mcp 暴露了 shanzhi_get_bug / shanzhi_remark_bug 等
# 受控子集（凭证留在 Symphony 进程内）。这个独立 MCP 服务补的是查询类能力：
# find_bugs 搜索同类缺陷、list_members 姓名⇄手机号、list_projects 取产品 ID。
#
# 默认只开放只读工具：善治的「提 Bug / 确认」是对生产数据的写操作，
# 让自治 Agent 随手建 Bug 会污染真实缺陷库，需要时把 SHANZHI_MCP_TOOLS 改成 all。
SHANZHI_MCP_LAUNCHER="/opt/shanzhi-mcp/bin/shanzhi-mcp"
SHANZHI_MCP_READONLY_TOOLS="find_bugs get_bug get_bug_history list_members list_projects"

configure_shanzhi_mcp() {
  local dir="${APP_HOME}/.config/shanzhi-mcp"
  local file="${dir}/config.json"

  if [ "${SHANZHI_MCP_ENABLED:-1}" = "0" ]; then
    log "SHANZHI_MCP_ENABLED=0，跳过善治 MCP 配置"
    return 0
  fi

  if [ ! -x "${SHANZHI_MCP_LAUNCHER}" ]; then
    log "善治 MCP 未安装（缺少 ${SHANZHI_MCP_LAUNCHER}），跳过注册"
    return 0
  fi

  if [ -z "${SF_USERNAME:-}" ] || [ -z "${SF_PASSWORD:-}" ]; then
    log "未设置 SF_USERNAME / SF_PASSWORD，跳过善治 MCP 注册"
    return 0
  fi

  mkdir -p "${dir}"
  # token 缓存也放这里，避免每次容器重建都重新登录
  cat > "${file}" <<EOF
{
  "base_url": "${SF_BASE_URL:-https://api.gushen.sieiot.com}",
  "username": "${SF_USERNAME}",
  "password": "${SF_PASSWORD}",
  "system_code": "governance",
  "default_project": "谷神工业数字平台",
  "deep_id": "${SF_DEP_ID:-491919451030089984}",
  "token_file": "${dir}/auth.json",
  "timeout": 30
}
EOF
  chmod 600 "${file}"

  # codex：写进生成的 config.toml（该文件每次启动重写，所以直接追加）
  local codex_config="${CODEX_HOME:-${APP_HOME}/.codex}/config.toml"
  touch "${codex_config}"
  {
    printf '\n# 由 Symphony 托管：善治 Bug 协作 MCP（stdio，按需拉起）\n'
    printf '[mcp_servers.shanzhi_bug]\n'
    printf 'command = "%s"\n' "${SHANZHI_MCP_LAUNCHER}"
    printf 'env = { SF_MCP_CONFIG = "%s" }\n' "${file}"
    # Symphony 用 approval_policy=never 跑无头 agent，而 codex 默认只放行标注
    # readOnlyHint 的 MCP 工具；善治服务没有这些标注，会被判成「需要审批」而拒绝，
    # 报错 "MCP tool call requires approval, but approval policy is never"。
    # 用 default_tools_approval_mode=approve 明确放行该服务（配合上面的工具白名单）。
    printf 'default_tools_approval_mode = "approve"\n'
    printf 'startup_timeout_sec = 30\n'
    printf 'tool_timeout_sec = 120\n'
    if [ "${SHANZHI_MCP_TOOLS:-readonly}" != "all" ]; then
      printf 'enabled_tools = ['
      local sep=""
      for tool in ${SHANZHI_MCP_READONLY_TOOLS}; do
        printf '%s"%s"' "${sep}" "${tool}"
        sep=", "
      done
      printf ']\n'
    fi
  } >> "${codex_config}"

  # claude：Symphony 用 --mcp-config 内联 JSON + --strict-mcp-config 注入自己的
  # MCP，这里把额外服务通过环境变量交给适配器合并（见 claude_cli.ex）。
  export SYMPHONY_EXTRA_MCP_SERVERS
  SYMPHONY_EXTRA_MCP_SERVERS="$(printf '{"shanzhi_bug":{"type":"stdio","command":"%s","args":[],"env":{"SF_MCP_CONFIG":"%s"}}}' \
    "${SHANZHI_MCP_LAUNCHER}" "${file}")"

  # claude 没有 codex 那种 enabled_tools 白名单，只能反过来禁用写操作，
  # 否则 codex 只读、claude 全量，换 agent 就等于换了一套权限。
  # 工具名形态是 mcp__<服务名>__<工具名>。
  #
  # 其中 confirm_bug 最关键：善治的「确认」是人工评审门槛，
  # agent 一旦能自我确认，require_confirmed 就形同虚设。
  if [ "${SHANZHI_MCP_TOOLS:-readonly}" != "all" ]; then
    export SYMPHONY_MCP_DISALLOWED_TOOLS="\
mcp__shanzhi_bug__confirm_bug \
mcp__shanzhi_bug__create_bug \
mcp__shanzhi_bug__resolve_bug \
mcp__shanzhi_bug__remark_bug \
mcp__shanzhi_bug__bug_login"
  fi

  local scope="只读"
  [ "${SHANZHI_MCP_TOOLS:-readonly}" = "all" ] && scope="全部"
  log "善治 MCP 已注册到 codex / claude（工具范围: ${scope}，配置 ${file}）"
}

configure_shanzhi_mcp

# ---------------------------------------------------------------------------
# 5. 预检
# ---------------------------------------------------------------------------
[ -f "${WORKFLOW_PATH}" ] || die "找不到工作流文件: ${WORKFLOW_PATH}（检查 compose 的 WORKFLOW.md 挂载）"

available=""
for cli in codex claude cursor-agent zcode; do
  if command -v "${cli}" >/dev/null 2>&1; then
    available="${available} ${cli}"
  fi
done
log "可用 Agent CLI:${available:- 无}"
case " ${available} " in
  *" codex "*) ;;
  *) log "警告: codex 不在 PATH，善治 Bug 未写 keywords 时会派发失败" ;;
esac

if [ -z "${APP_REPO_URL}" ]; then
  log "警告: APP_REPO_URL 为空，after_create 钩子无法克隆业务仓库"
fi

# ---------------------------------------------------------------------------
# 6. 启动 Symphony
# ---------------------------------------------------------------------------
log "工作流: ${WORKFLOW_PATH}"
log "工作区: ${WORKSPACE_ROOT}"
log "日志目录: ${LOGS_ROOT}"
log "看板端口: ${SYMPHONY_PORT}（http://<主机>:${SYMPHONY_PORT}/）"

# 只生成配置不启动，排查模型接不上时用：SYMPHONY_CONFIG_ONLY=1 docker compose run ...
# 带参数时改为执行该命令（此时 claude 的 ANTHROPIC_* 已在环境里），供 model-check 用。
if [ "${SYMPHONY_CONFIG_ONLY:-0}" = "1" ]; then
  if [ "$#" -gt 0 ]; then
    log "配置已生成，改用外部命令启动（SYMPHONY_CONFIG_ONLY=1）"
    exec "$@"
  fi

  log "SYMPHONY_CONFIG_ONLY=1，配置已生成，跳过启动"
  exit 0
fi

exec /app/symphony \
  --i-understand-that-this-will-be-running-without-the-usual-guardrails \
  --logs-root "${LOGS_ROOT}" \
  --port "${SYMPHONY_PORT}" \
  "${WORKFLOW_PATH}"
