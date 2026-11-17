#!/usr/bin/env bash
# 把 Symphony 部署到 Rancher 托管的 K8s 集群。
#
# 用法：
#   export KUBECONFIG=~/.rancher/gky-kubeconfig   # 或集群管理员给你的 kubeconfig
#   ./apply.sh                 # 建 ns + 凭证 + 资源，等待滚动完成
#   ./apply.sh --workflow-only # 只更新 WORKFLOW.md（热加载，不重启）
#
# 凭证不落仓库：Secret 每次从 ../.env 生成，namespace 里已存在则覆盖。
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="${ENV_FILE:-${HERE}/../.env}"
NS="${NS:-symphony}"
DOMAIN="${DOMAIN:-symphony.dev.sie.iidp.cn}"
IMAGE="${IMAGE:-harbor.devcenter.gushen.sieiot.com/iidp/symphony-agent:v2}"
PULL_SECRET_SOURCE="${PULL_SECRET_SOURCE:-authmcp/harbor-regcred}"

log() { printf '[deploy] %s\n' "$*"; }
die() { printf '[deploy] 错误: %s\n' "$*" >&2; exit 1; }

command -v kubectl >/dev/null 2>&1 || die "未找到 kubectl"
kubectl version --request-timeout=10s >/dev/null 2>&1 || die "kubectl 连不上集群（检查 KUBECONFIG）"

# WORKFLOW.md 以 ConfigMap 目录方式挂到 /config，Symphony 每秒重读一次。
# 更新不需要重启 Pod，改完重新 apply 即可。
apply_workflow() {
  kubectl create namespace "${NS}" 2>/dev/null || true
  kubectl create configmap symphony-workflow -n "${NS}" \
    --from-file=WORKFLOW.md="${HERE}/../WORKFLOW.md" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  log "WORKFLOW.md 已同步到 ConfigMap（Symphony 1 秒内热加载）"
}

# 开发环境发版脚本也走 ConfigMap：19K，远低于 1MiB 的上限，且改脚本不用重建镜像。
# 挂载用目录方式（非 subPath）才能随 ConfigMap 更新刷新；只读卷靠
# deployment.yaml 里的 defaultMode: 0755 拿到可执行位，不依赖 chmod。
apply_release_script() {
  local script="${HERE}/../publish_dev.sh"
  [ -f "${script}" ] || die "缺少 ${script}"
  kubectl create namespace "${NS}" 2>/dev/null || true
  kubectl create configmap symphony-release -n "${NS}" \
    --from-file=publish_dev.sh="${script}" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  log "publish_dev.sh 已同步到 ConfigMap symphony-release（挂到 /opt/symphony-release）"
}

if [ "${1:-}" = "--workflow-only" ]; then
  apply_workflow
  exit 0
fi

if [ "${1:-}" = "--release-only" ]; then
  apply_release_script
  exit 0
fi

[ -f "${ENV_FILE}" ] || die "缺少 ${ENV_FILE}（从 deploy/env.example 复制后填写）"

# ---------------------------------------------------------------------------
# 1. 命名空间与镜像拉取凭证
# ---------------------------------------------------------------------------
kubectl create namespace "${NS}" 2>/dev/null || log "命名空间 ${NS} 已存在"
kubectl label namespace "${NS}" app=symphony --overwrite >/dev/null

# 直接复用集群里已有的 Harbor 凭证，避免再存一份账号密码。
if ! kubectl get secret harbor-regcred -n "${NS}" >/dev/null 2>&1; then
  log "从 ${PULL_SECRET_SOURCE} 复用 Harbor 拉取凭证"
  src_ns="${PULL_SECRET_SOURCE%%/*}"
  src_name="${PULL_SECRET_SOURCE##*/}"
  kubectl get secret "${src_name}" -n "${src_ns}" -o jsonpath='{.data.\.dockerconfigjson}' \
    | base64 -d \
    | kubectl create secret generic harbor-regcred -n "${NS}" \
        --from-file=.dockerconfigjson=/dev/stdin \
        --type=kubernetes.io/dockerconfigjson 2>/dev/null \
    || die "复用 Harbor 凭证失败，改用 kubectl create secret docker-registry 手工创建"
fi

# ---------------------------------------------------------------------------
# 2. 运行期环境变量（来自 .env）
# ---------------------------------------------------------------------------
# 只把运行期需要的键放进 Secret：构建参数（CODEX_VERSION 等）和本机端口
# 与线上无关，混进去会让「改了 .env 却行为不变」变得难以排查。
TMP_ENV="$(mktemp)"
trap 'rm -f "${TMP_ENV}"' EXIT
SKIP_KEYS='^(IMAGE_NAME|IMAGE_TAG|CONTAINER_NAME|TARGET_PLATFORM|NPM_REGISTRY|CODEX_VERSION|CLAUDE_CODE_VERSION|ZCODE_CLI_PKG|CURSOR_INSTALL_URL|SHANZHI_MCP_REPO|SHANZHI_MCP_REF|SYMPHONY_PORT|TZ|HOME|LOGS_ROOT|SYMPHONY_WORKSPACE_ROOT|WORKFLOW_PATH)$'

while IFS= read -r line; do
  case "${line}" in ''|'#'*) continue ;; esac
  key="${line%%=*}"
  key="$(printf '%s' "${key}" | tr -d '[:space:]')"
  [ -z "${key}" ] && continue
  if printf '%s' "${key}" | grep -Eq "${SKIP_KEYS}"; then continue; fi
  printf '%s\n' "${line}" >> "${TMP_ENV}"
done < "${ENV_FILE}"

[ -s "${TMP_ENV}" ] || die "${ENV_FILE} 里没有可用的运行期变量"
kubectl create secret generic symphony-env -n "${NS}" \
  --from-env-file="${TMP_ENV}" \
  --dry-run=client -o yaml | kubectl apply -f -
log "运行期环境变量已写入 Secret symphony-env（$(grep -c . "${TMP_ENV}") 项）"

# ---------------------------------------------------------------------------
# 3. 看板 basic-auth
# ---------------------------------------------------------------------------
# 看板能指挥 Agent 干活，必须挡一道。密码只在这里生成一次并打印，
# 想换密码：删掉 Secret 重新跑本脚本。
if ! kubectl get secret symphony-basic-auth -n "${NS}" >/dev/null 2>&1; then
  BASIC_USER="${BASIC_USER:-admin}"
  # 不用 `tr < /dev/urandom | head -c N`：head 提前关管道会让 tr 收到 SIGPIPE，
  # 在 pipefail 下整条命令失败，`set -e` 直接把脚本带走。
  BASIC_PASS="${BASIC_PASS:-$(openssl rand -base64 24 | tr -d '/+=' | cut -c1-16)}"
  htpasswd_line="${BASIC_USER}:$(openssl passwd -apr1 "${BASIC_PASS}")"
  kubectl create secret generic symphony-basic-auth -n "${NS}" \
    --from-literal=auth="${htpasswd_line}" >/dev/null
  log "已生成看板登录：${BASIC_USER} / ${BASIC_PASS}（请自行保存）"
else
  log "看板 basic-auth 已存在，沿用旧密码"
fi

# ---------------------------------------------------------------------------
# 4. 工作负载
# ---------------------------------------------------------------------------
apply_workflow
apply_release_script
kubectl apply -k "${HERE}" -n "${NS}"

log "等待滚动完成（首次需要拉取约 1.6GB 镜像）"
kubectl rollout status deployment/symphony -n "${NS}" --timeout=900s

log "部署完成：https://${DOMAIN}/"
kubectl get pods -n "${NS}" -l app.kubernetes.io/name=symphony
