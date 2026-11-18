#!/usr/bin/env bash
# Symphony 部署脚本（Docker Compose）。
#
# 常用流程：
#   ./deploy.sh init       # 首次：生成 .env、创建目录、提示登录态怎么放
#   ./deploy.sh deploy     # 构建镜像并启动（= build + up）
#   ./deploy.sh status     # 看容器状态与看板
#   ./deploy.sh logs       # 跟日志
#   ./deploy.sh update     # 拉最新代码后重建重启
#
# 所有可调参数都在 deploy/.env 里，见 env.example。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

ENV_FILE=".env"
ENV_EXAMPLE="env.example"

log()  { printf '\033[36m[deploy]\033[0m %s\n' "$*"; }
warn() { printf '\033[33m[deploy]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[31m[deploy]\033[0m %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
用法: ./deploy.sh <命令>

命令:
  init         首次初始化：生成 .env、创建数据/登录态目录
  build        构建镜像（PULL=1 强制拉基础镜像，NO_CACHE=1 禁用缓存）
  up           启动容器（不重新构建）
  deploy       构建并启动，最常用
  restart      重启容器（改 .env 后需要）
  down         停止并删除容器（data/ 数据保留）
  update       git pull + 重新构建 + 重启
  logs         跟随容器日志
  status       查看容器状态、健康检查与看板摘要
  shell        进入容器内的 bash
  cli-check    打印镜像内各 Agent CLI 版本
  model-check  用 .env 里的网关配置实跑一次 codex / claude / zcode
  mcp-check    实跑一次善治 MCP：codex 注册情况 + MCP 协议探测
  push         推送镜像到 registry（IMAGE_NAME 需带仓库地址）
  help         显示本帮助

环境变量:
  SYMPHONY_PORT   看板端口（默认取 .env，4567）
  PULL=1          build 时 --pull
  NO_CACHE=1      build 时 --no-cache
  FOLLOW=1        up 之后自动跟随日志
EOF
}

require_docker() {
  command -v docker >/dev/null 2>&1 || die "未找到 docker，请先安装 Docker Engine/Desktop"
  docker info >/dev/null 2>&1 || die "Docker 守护进程不可用（检查 dockerd 或 Docker Desktop）"
  docker compose version >/dev/null 2>&1 || die "缺少 docker compose 插件（docker compose version 失败）"
}

require_env() {
  [ -f "${ENV_FILE}" ] || die "缺少 ${ENV_FILE}，先执行 ./deploy.sh init"
}

# 只解析 .env 里简单的 KEY=VALUE，够用来取端口/镜像名，避免引入 source 的副作用
load_env() {
  require_env
  local key value
  while IFS='=' read -r key value; do
    case "${key}" in
      ''|'#'*) continue ;;
    esac
    key="$(printf '%s' "${key}" | tr -d '[:space:]')"
    [[ "${key}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
    # 去掉了引号后判断当前是否已有非空值
    value="${value%\"}"; value="${value#\"}"
    value="${value%\'}"; value="${value#\'}"
    # 已显式导出的环境变量优先于 .env：命令行传参能盖过 .env 里的旧值
    # （否则 `TARGET_PLATFORM=linux/amd64 ./deploy.sh build` 会被 .env 的 arm64 悄悄吃掉）
    if [ -z "$(eval "printf '%s' \"\${${key}:-}\"")" ]; then
      export "${key}=${value}"
    fi
  done < "${ENV_FILE}"
}

apply_platform() {
  if [ -n "${TARGET_PLATFORM:-}" ]; then
    export DOCKER_DEFAULT_PLATFORM="${TARGET_PLATFORM}"
    log "目标平台: ${TARGET_PLATFORM}"
  fi
}

compose() {
  docker compose -f docker-compose.yml "$@"
}

check_required_vars() {
  local missing=()
  [ -n "${APP_REPO_URL:-}" ]  || missing+=("APP_REPO_URL")
  [ -n "${SF_USERNAME:-}" ]   || missing+=("SF_USERNAME")
  [ -n "${SF_PASSWORD:-}" ]   || missing+=("SF_PASSWORD")
  [ -n "${SF_PRODUCT_ID:-}" ] || missing+=("SF_PRODUCT_ID")
  if [ "${#missing[@]}" -gt 0 ]; then
    warn "以下变量还没填: ${missing[*]}（不填服务会启动失败或无法派发 Bug）"
  fi
  if [ -z "${GIT_USERNAME:-}" ] || [ -z "${GIT_TOKEN:-}" ]; then
    warn "未配置 GIT_USERNAME / GIT_TOKEN，私有仓库克隆/推送会失败"
  fi
}

cmd_init() {
  mkdir -p data auth/codex auth/claude auth/cursor auth/zcode auth/ssh

  if [ -f "${ENV_FILE}" ]; then
    log "${ENV_FILE} 已存在，跳过生成"
  else
    cp "${ENV_EXAMPLE}" "${ENV_FILE}"
    chmod 600 "${ENV_FILE}"
    log "已生成 ${ENV_FILE}，请填写善治账号、产品 ID 与 GitLab 凭据"
  fi

  cat <<EOF

下一步：
  1. 编辑 deploy/${ENV_FILE}：
       OPENAI_BASE_URL / OPENAI_API_KEY / AGENT_MODEL   （模型网关，已预填）
       SF_USERNAME / SF_PASSWORD / SF_PRODUCT_ID        （善治渠道）
       GIT_USERNAME / GIT_TOKEN                         （GitLab 拉取与推送）
  2. 模型网关由 entrypoint 自动展开到 codex / claude / zcode，无需再拷登录态；
     只有 cursor 通道需要 auth/cursor/cli-config.json 或 CURSOR_API_KEY。
  3. ./deploy.sh deploy

验证模型是否接通（只生成配置不启动）：
  docker compose run --rm -e SYMPHONY_CONFIG_ONLY=1 symphony

EOF
}

cmd_build() {
  require_docker
  load_env
  apply_platform
  local args=()
  [ "${PULL:-0}" = "1" ] && args+=(--pull)
  [ "${NO_CACHE:-0}" = "1" ] && args+=(--no-cache)
  log "构建镜像 ${IMAGE_NAME:-symphony-agent}:${IMAGE_TAG:-latest}"
  # set -u 下空数组展开在 bash 3.2（macOS 自带）会报 unbound variable，
  # 用 ${arr[@]+...} 兼容写法，避免「不加 --pull 就构建失败」。
  compose build ${args[@]+"${args[@]}"}
  log "构建完成"
}

cmd_up() {
  require_docker
  load_env
  apply_platform
  check_required_vars
  log "启动容器"
  compose up -d --remove-orphans
  print_access
  if [ "${FOLLOW:-0}" = "1" ]; then
    cmd_logs
  fi
}

cmd_deploy() {
  cmd_build
  cmd_up
}

cmd_restart() {
  require_docker
  load_env
  compose restart
  print_access
}

cmd_down() {
  require_docker
  load_env
  compose down
  log "容器已停止（data/ 与 auth/ 保留）"
}

cmd_logs() {
  require_docker
  load_env
  compose logs -f --tail=200
}

cmd_status() {
  require_docker
  load_env
  compose ps
  echo

  local port="${SYMPHONY_PORT:-4567}"
  local body
  if body="$(curl -s --max-time 5 "http://127.0.0.1:${port}/api/v1/state")" && [ -n "${body}" ]; then
    if command -v jq >/dev/null 2>&1; then
      printf '%s' "${body}" | jq -r '
        "运行中: \(.running | length // 0) 个\n" +
        ((.running // []) | map("  - \(.identifier // "?") \(.state // "")") | join("\n"))
      ' 2>/dev/null || printf '%s\n' "${body}"
    else
      printf '%s\n' "${body}"
    fi
  else
    warn "看板接口不可达：http://127.0.0.1:${port}/api/v1/state"
    warn "看容器日志：./deploy.sh logs"
  fi
}

cmd_shell() {
  require_docker
  load_env
  compose exec symphony bash
}

cmd_cli_check() {
  require_docker
  load_env
  local image="${IMAGE_NAME:-symphony-agent}:${IMAGE_TAG:-latest}"
  log "镜像内 Agent CLI 版本"
  docker run --rm --entrypoint /bin/bash "${image}" -lc '
    for cli in codex claude cursor-agent zcode; do
      if command -v "$cli" >/dev/null 2>&1; then
        printf "%-14s %s\n" "$cli" "$("$cli" --version 2>&1 | head -n 1)"
      else
        printf "%-14s %s\n" "$cli" "未安装"
      fi
    done
    printf "%-14s %s\n" "node" "$(node --version)"
    printf "%-14s %s\n" "java" "$(java -version 2>&1 | head -n 1)"
    printf "%-14s %s\n" "mvn" "$(mvn --version 2>&1 | head -n 1)"
  '
}

cmd_update() {
  require_docker
  load_env
  log "拉取最新代码"
  git -C .. pull --ff-only
  cmd_deploy
}

cmd_push() {
  require_docker
  load_env
  local image="${IMAGE_NAME:-symphony-agent}:${IMAGE_TAG:-latest}"
  case "${image}" in
    */*|*.*:*) ;;
    *) die "IMAGE_NAME 需要带仓库地址（如 registry.local:5000/symphony-agent）才能 push" ;;
  esac
  log "推送 ${image}"
  docker push "${image}"
}

cmd_model_check() {
  require_docker
  load_env
  local image="${IMAGE_NAME:-symphony-agent}:${IMAGE_TAG:-latest}"
  [ -n "${OPENAI_BASE_URL:-}" ] || die "未配置 OPENAI_BASE_URL，先在 .env 里填写模型网关"
  [ -n "${OPENAI_API_KEY:-}" ] || die "未配置 OPENAI_API_KEY"

  log "探测模型 ${AGENT_MODEL:-local-glm5.3} @ ${OPENAI_BASE_URL}"
  # 先让 entrypoint 生成 codex / zcode 配置并导出 claude 环境，再在同一个进程里跑 CLI，
  # 因此这里验证的就是容器启动后的真实配置。
  docker run --rm \
    --env-file "${ENV_FILE}" \
    -e SYMPHONY_CONFIG_ONLY=1 \
    --entrypoint /usr/local/bin/symphony-entrypoint \
    "${image}" \
    bash -lc '
      set -u
      cd "$(mktemp -d)" && git init -q .
      probe() {
        local name="$1"; shift
        printf "\n=== %s ===\n" "$name"
        timeout 180 "$@" 2>&1 | tail -n 4
      }
      probe codex codex exec --skip-git-repo-check "回复 exactly: OK"
      probe claude claude -p "回复 exactly: OK" --output-format text
      # 按适配器的原始参数调用，顺带验证 --output-format 兼容层
      probe zcode zcode -p "回复 exactly: OK" --output-format stream-json --mode yolo --cwd "$PWD"
      printf "\n（zcode 输出一行 result NDJSON 即表示兼容层正常）\n"
    '
}

cmd_mcp_check() {
  require_docker
  load_env
  local image="${IMAGE_NAME:-symphony-agent}:${IMAGE_TAG:-latest}"
  [ -n "${SF_USERNAME:-}" ] || die "未配置 SF_USERNAME，善治 MCP 无法登录"
  [ -n "${SF_PASSWORD:-}" ] || die "未配置 SF_PASSWORD"

  log "探测善治 MCP（server / 工具列表 / list_projects 实调用）"
  # 走同一个 entrypoint 生成凭证配置，验证的就是容器启动后的真实状态
  docker run --rm \
    --env-file "${ENV_FILE}" \
    -e SYMPHONY_CONFIG_ONLY=1 \
    --entrypoint /usr/local/bin/symphony-entrypoint \
    "${image}" \
    bash -lc '
      set -u
      printf "\n=== codex 注册情况 ===\n"
      codex mcp list 2>&1 | sed -n "1,3p"
      printf "\n=== stdio 协议探测 ===\n"
      python3 /opt/shanzhi-mcp/bin/mcp-probe
    '
}

print_access() {
  local port="${SYMPHONY_PORT:-4567}"
  local host_ip
  host_ip="$(hostname -I 2>/dev/null | awk '{print $1}')" || host_ip=""
  [ -n "${host_ip}" ] || host_ip="127.0.0.1"
  printf '\n看板: http://%s:%s/      API: http://%s:%s/api/v1/state\n\n' \
    "${host_ip}" "${port}" "${host_ip}" "${port}"
  log "首次启动约 30~60 秒后看板可用，可用 ./deploy.sh logs 观察"
}

main() {
  case "${1:-help}" in
    init)      cmd_init ;;
    build)     cmd_build ;;
    up)        cmd_up ;;
    deploy)    cmd_deploy ;;
    restart)   cmd_restart ;;
    down)      cmd_down ;;
    logs)      cmd_logs ;;
    status)    cmd_status ;;
    shell)     cmd_shell ;;
    cli-check) cmd_cli_check ;;
    model-check) cmd_model_check ;;
    mcp-check) cmd_mcp_check ;;
    update)    cmd_update ;;
    push)      cmd_push ;;
    help|-h|--help) usage ;;
    *) usage; die "未知命令: $1" ;;
  esac
}

main "$@"
