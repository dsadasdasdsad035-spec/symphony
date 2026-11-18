#!/usr/bin/env bash
# 开发环境（app-test，:30669）的【接口层】冒烟。
#
# 为什么要有这个脚本：
#   修完 Bug 不能只凭「代码看起来对」——必须有一次对开发环境真实后端的调用证据。
#   Agent 手写 curl 时最容易踩的三个坑都封在这里：
#     1. 登录口令必须是 base64，明文会得到 -32602「用户名或密码错误」；
#     2. RPC 的 app 必须是真实应用名（如 sie-iidp-app-store），
#        填模型名会得到「No app info in local and remote」；
#     3. tag 必须是 master，缺省时服务端找不到应用行。
#
# 用法：
#   ./smoke_api.sh                                   # 只验登录（连通性基线）
#   ./smoke_api.sh --model app_market --service search \
#       --app sie-iidp-app-store --args '{"filter":[["name","=","x"]],"limit":10}'
#   ./smoke_api.sh --list-hints                      # 打印参数组合提示
#   ./smoke_api.sh --model x --service y --app z --expect-error   # 断言必然失败
#
# 退出码：
#   0 断言通过（PASS）｜1 断言失败（FAIL）｜2 参数错｜3 环境不可达/登录失败

set -uo pipefail

DEV_BASE_DEFAULT="http://192.168.181.104:30669"
RPC_TAG_DEFAULT="master"

log()  { printf '\033[36m[smoke-api]\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[33m[smoke-api]\033[0m %s\n' "$*" >&2; }
die()  { local code=$1; shift; printf '\033[31m[smoke-api]\033[0m %s\n' "$*" >&2; exit "$code"; }

# ---------------------------------------------------------------- 参数
BASE="${IIDP_BASE:-$DEV_BASE_DEFAULT}"
LOGIN_USER="${IIDP_USER:-implementer}"
PASSWORD="${IIDP_PASSWORD:-}"
MODEL=""
SERVICE=""
APP=""
TAG="$RPC_TAG_DEFAULT"
ARGS_JSON=""
TIMEOUT=120
EXPECT_ERROR=0
LIST_HINTS=0
JSON_OUT=""
MIN_ROWS=""

usage() {
  cat <<'EOF'
用法: smoke_api.sh [选项]

目标环境:
  --base <URL>        开发环境地址（默认 $IIDP_BASE 或 http://192.168.181.104:30669）
  --user <NAME>       登录用户（默认 $IIDP_USER）
  --password <PWD>    登录口令明文（默认取 $IIDP_PASSWORD；脚本内部转 base64，不要自己转）

业务调用（不带这些参数时只验登录）:
  --model <M>         RPC 模型名，如 app_market
  --service <S>       RPC 服务名，如 search
  --app <A>           真实应用名，如 sie-iidp-app-store（不要填模型名）
  --tag <T>           应用行 tag，默认 master
  --args <JSON>       服务入参，如 '{"filter":[["name","=","x"]],"limit":10}'
  --expect-error      反向断言：要求服务端返回 error（用于验证错误分支）
  --min-rows <N>      断言 result.data 至少 N 行。查询类冒烟建议带上：
                      空数组也返回 200，不校验行数的"通过"几乎没有说服力
  --timeout <秒>      单次请求超时，默认 120
  --json-out <文件>   把最后一次业务调用的原始响应体落盘（供 smoke_test.sh 校验版本等机器判读）

其他:
  --list-hints        打印常用参数组合
  --help              显示本帮助

结果格式（可直接粘贴进善治备注）:
  类型 / 目标 / 场景 / 结果 / 证据
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --base)        BASE="${2:-}"; shift 2 ;;
    --base=*)      BASE="${1#*=}"; shift ;;
    --user)        LOGIN_USER="${2:-}"; shift 2 ;;
    --user=*)      LOGIN_USER="${1#*=}"; shift ;;
    --password)    PASSWORD="${2:-}"; shift 2 ;;
    --password=*)  PASSWORD="${1#*=}"; shift ;;
    --model)       MODEL="${2:-}"; shift 2 ;;
    --model=*)     MODEL="${1#*=}"; shift ;;
    --service)     SERVICE="${2:-}"; shift 2 ;;
    --service=*)   SERVICE="${1#*=}"; shift ;;
    --app)         APP="${2:-}"; shift 2 ;;
    --app=*)       APP="${1#*=}"; shift ;;
    --tag)         TAG="${2:-}"; shift 2 ;;
    --tag=*)       TAG="${1#*=}"; shift ;;
    --args)        ARGS_JSON="${2:-}"; shift 2 ;;
    --args=*)      ARGS_JSON="${1#*=}"; shift ;;
    --timeout)     TIMEOUT="${2:-}"; shift 2 ;;
    --timeout=*)   TIMEOUT="${1#*=}"; shift ;;
    --expect-error) EXPECT_ERROR=1; shift ;;
    --list-hints)  LIST_HINTS=1; shift ;;
    --json-out)    JSON_OUT="${2:-}"; shift 2 ;;
    --json-out=*)  JSON_OUT="${1#*=}"; shift ;;
    --min-rows)    MIN_ROWS="${2:-}"; shift 2 ;;
    --min-rows=*)  MIN_ROWS="${1#*=}"; shift ;;
    --help|-h)     usage; exit 0 ;;
    *)             die 2 "未知参数: $1（--help 看用法）" ;;
  esac
done

BASE="${BASE%/}"

show_hints() {
  cat <<'EOF'
常用参数组合（复制后改 filter / 服务名即可）:
  # 1) 只验登录与连通性
  smoke_api.sh

  # 2) 查应用市场行（发版、版本校验都靠它）
  #    注意 properties 不能省：search 不带 properties 时服务端恒回空数组
  smoke_api.sh --model meta_app_store --service search --app sie-iidp-app-store \
    --min-rows 1 \
    --args '{"useDisplayForModel":true,"filter":[["name","=","sie-iidp-app-store"]],
             "limit":10,"offset":0,"order":"","properties":["name","version","state"]}'

  # 3) 查已安装应用（同上，properties 必带）
  smoke_api.sh --model meta_app --service search --app sie-iidp-app-store \
    --min-rows 1 \
    --args '{"useDisplayForModel":true,"filter":[["name","=","sie-iidp-app-store"]],
             "limit":10,"offset":0,"order":"","properties":["name","version","state"]}'

已知可用的 app 名（必须用真实应用名，写模型名会报 No app info in local and remote）:
  sie-iidp-app-store  sie-iidp-iam  sie-iidp-de-tool  sie-iidp-de-skill
  sie-iidp-digitalemployee  sie-iidp-employee-implementer  sie-iidp-employee-tenant-admin

完整应用清单: 见 deploy/publish_dev.sh 顶部的 FRONT_APPS / BACK_APPS / STORE_APPS / IAM_APPS。
EOF
}

[ "$LIST_HINTS" = "1" ] && { show_hints; exit 0; }

# ---------------------------------------------------------------- 结果输出
# 证据统一压成单行并截断，保证能整段贴进善治备注而不会撑爆字段长度。
squeeze() {
  local text="$1" limit="${2:-600}"
  text="$(printf '%s' "$text" | tr '\n\t\r' '   ' | tr -s ' ')"
  if [ "${#text}" -gt "$limit" ]; then
    printf '%s…(截断)' "${text:0:$limit}"
  else
    printf '%s' "$text"
  fi
}

emit_result() {
  printf '\n== 冒烟结果 ==\n'
  printf '类型: API\n'
  printf '目标: %s\n' "$2"
  printf '场景: %s\n' "$3"
  printf '结果: %s\n' "$1"
  printf '证据: %s\n' "$4"
}

# ---------------------------------------------------------------- HTTP
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

# post_json <url> <payload> [token] -> 打印 HTTP 状态码，响应体落到 $TMP_DIR/body
post_json() {
  local url="$1" payload="$2" token="${3:-}" code
  local -a headers=(-H 'Content-Type: application/json' -H 'Accept: application/json')
  [ -n "$token" ] && headers+=(-H "Authorization: Bearer ${token}")
  code="$(curl -sS --noproxy '*' --max-time "$TIMEOUT" \
            -o "$TMP_DIR/body" -w '%{http_code}' \
            -X POST "${headers[@]}" -d "$payload" "$url" 2>"$TMP_DIR/err")" || {
    printf '000'
    return 0
  }
  printf '%s' "$code"
}

curl_error() { [ -s "$TMP_DIR/err" ] && squeeze "$(cat "$TMP_DIR/err")" 200; }

body_snippet() { [ -s "$TMP_DIR/body" ] && squeeze "$(cat "$TMP_DIR/body")" 600; }

# --json-out：把响应体原样留档，供调用方（如 smoke_test.sh 的版本校验）用 jq 判读。
dump_body() {
  [ -n "$JSON_OUT" ] || return 0
  [ -s "$TMP_DIR/body" ] || return 0
  mkdir -p "$(dirname "$JSON_OUT")"
  cp "$TMP_DIR/body" "$JSON_OUT"
}

[ -n "$PASSWORD" ] || die 2 "缺少口令：设 \$IIDP_PASSWORD 或用 --password 传入"
command -v jq >/dev/null 2>&1 || die 2 "缺少 jq（镜像内应自带；本地跑请先安装）"

# ---------------------------------------------------------------- 1. 登录
LOGIN_URL="${BASE}/api/root/rpc/login/master"
log "登录 ${BASE}（用户 ${LOGIN_USER}）"

# 口令 base64：明文直传会被判 -32602 用户名或密码错误。这里替调用方做掉，避免踩坑。
PWD_B64="$(printf '%s' "$PASSWORD" | base64 | tr -d '\n')"
LOGIN_PAYLOAD="$(jq -nc \
  --arg app "base" --arg login "$LOGIN_USER" --arg password "$PWD_B64" --arg tag "$TAG" \
  '{id:"1",jsonrpc:"2.0",method:"login",
    params:{app:$app,args:{},login:$login,password:$password,remember:true,tag:$tag}}')"

CODE="$(post_json "$LOGIN_URL" "$LOGIN_PAYLOAD")"
if [ "$CODE" = "000" ]; then
  emit_result "FAIL" "POST ${LOGIN_URL}" "登录" "环境不可达：$(curl_error)"
  exit 3
fi
if [ "$CODE" != "200" ]; then
  emit_result "FAIL" "POST ${LOGIN_URL}" "登录" "HTTP ${CODE}：$(body_snippet)"
  exit 3
fi

# token 路径兼容 result.data.token（当前实现）与前缀多包一层的旧响应
TOKEN="$(jq -r '(.result.data.token // .result.result.data.token // .data.token // .result.token) // empty' \
           "$TMP_DIR/body" 2>/dev/null)"
if [ -z "$TOKEN" ]; then
  emit_result "FAIL" "POST ${LOGIN_URL}" "登录" "响应缺少 token：$(body_snippet)"
  exit 3
fi
log "登录成功（token 长度 ${#TOKEN}，不回显）"

# 只验登录：登录成功即算一次可粘贴的证据
if [ -z "$MODEL" ] && [ -z "$SERVICE" ]; then
  emit_result "PASS" "POST ${LOGIN_URL}" "登录（连通性基线）" \
    "HTTP 200，token 已取得（长度 ${#TOKEN}）"
  printf '\n提示: 未指定 --model/--service，本次只验了登录。要验业务接口请加参数：\n' >&2
  show_hints >&2
  exit 0
fi

[ -n "$MODEL" ]   || die 2 "--model 与 --service 需同时给出（当前缺 --model）"
[ -n "$SERVICE" ] || die 2 "--model 与 --service 需同时给出（当前缺 --service）"
[ -n "$APP" ]     || die 2 "缺少 --app：RPC 必须带真实应用名，写模型名会报 No app info in local and remote"

# args 缺省给空对象；给了就必须是合法 JSON，否则服务端只会回一个含糊的 400
if [ -n "$ARGS_JSON" ]; then
  printf '%s' "$ARGS_JSON" | jq -e . >/dev/null 2>&1 \
    || die 2 "--args 不是合法 JSON：${ARGS_JSON}"
else
  ARGS_JSON='{}'
fi

# ---------------------------------------------------------------- 2. 业务调用
RPC_URL="${BASE}/api/root/rpc/service/?model=${MODEL}&service=${SERVICE}"
RPC_PAYLOAD="$(jq -nc \
  --arg model "$MODEL" --arg service "$SERVICE" --arg app "$APP" --arg tag "$TAG" \
  --argjson args "$ARGS_JSON" \
  '{id:"guid",jsonrpc:"2.0",method:"service",
    params:{args:$args,context:{uid:"",timeZone:"UTC+8",lang:"zh-CN"},
            model:$model,tag:$tag,service:$service,app:$app}}')"

log "调用 ${MODEL}.${SERVICE}（app=${APP} tag=${TAG}）"

# search 不带 properties 时服务端恒回空数组（实测），预先提醒比事后对着空结果发愣好。
if [ "$SERVICE" = "search" ] && ! printf '%s' "$ARGS_JSON" | jq -e 'has("properties")' >/dev/null 2>&1; then
  warn "search 通常需要 properties 字段，否则服务端会返回空数组；建议加 --min-rows 断言行数"
fi

CODE="$(post_json "$RPC_URL" "$RPC_PAYLOAD" "$TOKEN")"
dump_body

TARGET="POST ${RPC_URL}（app=${APP} tag=${TAG}）"
SCENARIO="${MODEL}.${SERVICE} args=${ARGS_JSON}"

if [ "$CODE" = "000" ]; then
  emit_result "FAIL" "$TARGET" "$SCENARIO" "请求失败：$(curl_error)"
  exit 1
fi
if [ "$CODE" != "200" ]; then
  emit_result "FAIL" "$TARGET" "$SCENARIO" "HTTP ${CODE}：$(body_snippet)"
  exit 1
fi

HAS_ERROR="$(jq -r 'if .error then "yes" else "no" end' "$TMP_DIR/body" 2>/dev/null)"
if [ -z "$HAS_ERROR" ]; then
  emit_result "FAIL" "$TARGET" "$SCENARIO" "响应非 JSON：$(body_snippet)"
  exit 1
fi

if [ "$EXPECT_ERROR" = "1" ]; then
  if [ "$HAS_ERROR" = "yes" ]; then
    emit_result "PASS" "$TARGET" "$SCENARIO" "按要求返回错误：$(body_snippet)"
    exit 0
  fi
  emit_result "FAIL" "$TARGET" "$SCENARIO" "预期报错但调用成功：$(body_snippet)"
  exit 1
fi

if [ "$HAS_ERROR" = "yes" ]; then
  emit_result "FAIL" "$TARGET" "$SCENARIO" "$(body_snippet)"
  exit 1
fi

# 成功还要看一眼 result 不是 null：接口回 200 但 result 为空，多半是 model/app 对不上
RESULT_NULL="$(jq -r 'if (.result == null) then "yes" else "no" end' "$TMP_DIR/body" 2>/dev/null)"
if [ "$RESULT_NULL" = "yes" ]; then
  emit_result "FAIL" "$TARGET" "$SCENARIO" "返回 200 但 result 为 null（检查 model/app/tag）：$(body_snippet)"
  exit 1
fi

# 查询类调用要校验行数：实测 app 写错、filter 不匹配时服务端同样回 200 + data:[]，
# 只看「没有 error」会把空结果当成通过，这种证据没有任何说服力。
ROWS="$(jq -r 'if (.result.data | type) == "array" then (.result.data | length) else 0 end' "$TMP_DIR/body" 2>/dev/null)"
ROWS="${ROWS:-0}"

if [ -n "$MIN_ROWS" ]; then
  case "$MIN_ROWS" in
    ''|*[!0-9]*) die 2 "--min-rows 需要非负整数，收到：${MIN_ROWS}" ;;
  esac
  if [ "$ROWS" -lt "$MIN_ROWS" ]; then
    emit_result "FAIL" "$TARGET" "$SCENARIO" \
      "data 行数 ${ROWS} < 期望 ${MIN_ROWS}（空结果通常是 app/filter 不对）：$(body_snippet)"
    exit 1
  fi
  emit_result "PASS" "$TARGET" "$SCENARIO" "data ${ROWS} 行（≥${MIN_ROWS}）：$(body_snippet)"
  exit 0
fi

if [ "$ROWS" = "0" ]; then
  emit_result "PASS" "$TARGET" "$SCENARIO" \
    "data 为空数组——断言偏弱，若预期有数据请改用 --min-rows：$(body_snippet)"
  exit 0
fi

emit_result "PASS" "$TARGET" "$SCENARIO" "data ${ROWS} 行：$(body_snippet)"
exit 0
