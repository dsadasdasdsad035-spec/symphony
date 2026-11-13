#!/usr/bin/env bash
# Symphony Tracker + issue_feed 渠道端到端自测
# 用法:
#   ./scripts/e2e-test.sh              # Tracker API + Elixir 适配器单元测试
#   ./scripts/e2e-test.sh --with-workflow   # 额外校验 ~/.config/symphony/WORKFLOW.md
#   ./scripts/e2e-test.sh --no-elixir       # 仅 Tracker HTTP
#   ./scripts/e2e-test.sh --full-chain      # + Playwright 看板 + Symphony 编排派发
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SYMPHONY_ELIXIR="${SYMPHONY_ELIXIR:-$HOME/symphony/elixir}"
WORKFLOW_FILE="${WORKFLOW_FILE:-$HOME/.config/symphony/WORKFLOW.md}"

WITH_WORKFLOW=0
RUN_ELIXIR=1
FULL_CHAIN=0

VITE_DEV_PORT="${VITE_DEV_PORT:-14781}"
PLAYWRIGHT_MARKER="${ROOT}/scripts/.e2e-playwright-marker.json"

for arg in "$@"; do
  case "$arg" in
    --with-workflow) WITH_WORKFLOW=1 ;;
    --full-chain) FULL_CHAIN=1; RUN_ELIXIR=1 ;;
    --no-elixir) RUN_ELIXIR=0 ;;
    -h|--help)
      sed -n '2,6p' "$0"
      exit 0
      ;;
    *)
      echo "未知参数: $arg" >&2
      exit 2
      ;;
  esac
done

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "❌ 缺少命令: $1" >&2
    exit 1
  }
}

need_cmd curl
need_cmd node
need_cmd npm

TRACKER_PORT="${TRACKER_PORT:-14780}"
TRACKER_HOST="${TRACKER_HOST:-127.0.0.1}"
BASE_URL="http://${TRACKER_HOST}:${TRACKER_PORT}"
TEST_DATA_DIR="$(mktemp -d)"
TEST_DB="${TEST_DATA_DIR}/tracker-e2e.db"
SERVER_PID=""
VITE_PID=""

cleanup() {
  if [[ -n "$VITE_PID" ]] && kill -0 "$VITE_PID" 2>/dev/null; then
    kill "$VITE_PID" 2>/dev/null || true
    wait "$VITE_PID" 2>/dev/null || true
  fi
  if [[ -n "$SERVER_PID" ]] && kill -0 "$SERVER_PID" 2>/dev/null; then
    kill "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
  fi
  rm -f "$PLAYWRIGHT_MARKER"
  rm -rf "$TEST_DATA_DIR"
}
trap cleanup EXIT

pass() { echo "  ✓ $1"; }
fail() { echo "  ✗ $1" >&2; exit 1; }

json_get() {
  local expr="$1"
  node -e "
    const fs = require('fs');
    const j = JSON.parse(fs.readFileSync(0, 'utf8'));
    const v = (function(){
      const path = process.argv[1].split('.');
      let cur = j;
      for (const k of path) cur = cur?.[k];
      return cur;
    })();
    if (v === undefined || v === null) process.exit(2);
    if (typeof v === 'object') console.log(JSON.stringify(v));
    else console.log(String(v));
  " "$expr"
}

assert_http() {
  local method="$1" path="$2" expect_code="$3"
  local body_file="${TEST_DATA_DIR}/body.json"
  local code
  code=$(curl -sS -o "$body_file" -w "%{http_code}" -X "$method" "${BASE_URL}${path}" \
    -H 'Content-Type: application/json' ${4:-})
  [[ "$code" == "$expect_code" ]] || fail "$method $path 期望 HTTP $expect_code 实际 $code"
  echo "$body_file"
}

echo "== Symphony Tracker / issue_feed E2E =="
echo "数据目录: $TEST_DATA_DIR"
echo "API: $BASE_URL"
echo

if [[ ! -d "$ROOT/node_modules" ]]; then
  echo "→ npm install..."
  (cd "$ROOT" && npm install)
fi

echo "→ 启动 Tracker（隔离 SQLite）..."
TRACKER_PORT="$TRACKER_PORT" \
TRACKER_HOST="$TRACKER_HOST" \
TRACKER_DB_PATH="$TEST_DB" \
TRACKER_PUBLIC_URL="$BASE_URL" \
  node "$ROOT/server/src/index.js" >"${TEST_DATA_DIR}/server.log" 2>&1 &
SERVER_PID=$!

ready=0
for _ in $(seq 1 80); do
  if curl -sS -o /dev/null -w "%{http_code}" "$BASE_URL/api/health" 2>/dev/null | grep -q 200; then
    ready=1
    break
  fi
  sleep 0.1
done
[[ "$ready" -eq 1 ]] || fail "Tracker 端口未监听"

curl -sS "$BASE_URL/api/health" | grep -q '"ok":true' || {
  cat "${TEST_DATA_DIR}/server.log" >&2
  fail "Tracker 未在限定时间内就绪"
}
pass "Tracker /api/health"

# --- API 用例 ---
body_file=$(assert_http GET /api/v1/projects 200)
grep -q comic "$body_file" || fail "默认项目 comic"
pass "默认项目 comic"

body_file=$(assert_http GET /api/meta/states 200)
pass "GET /api/meta/states"

TITLE="E2E-$(date +%s)"
CREATE_PAYLOAD=$(printf '{"title":"%s","description":"自动化测试工单","labels":["symphony","e2e"],"state":"todo"}' "$TITLE")
create_code=$(curl -sS -o "${TEST_DATA_DIR}/create.json" -w "%{http_code}" -X POST \
  "$BASE_URL/api/v1/projects/comic/issues" \
  -H 'Content-Type: application/json' \
  -d "$CREATE_PAYLOAD")
[[ "$create_code" == "200" ]] || fail "创建工单 HTTP $create_code"

ISSUE_ID=$(node -e "const j=require('${TEST_DATA_DIR}/create.json'); if(!j.issue?.id) process.exit(1); console.log(j.issue.id)")
IDENT=$(node -e "const j=require('${TEST_DATA_DIR}/create.json'); console.log(j.issue.identifier)")
[[ -n "$ISSUE_ID" ]] || fail "创建工单未返回 id"
pass "POST 创建工单 $IDENT (id=$ISSUE_ID)"

symphony_body="${TEST_DATA_DIR}/symphony.json"
curl -sS "$BASE_URL/api/symphony/issues?project=comic&label=symphony" -o "$symphony_body"
node -e "
  const j=require('$symphony_body');
  const hit=(j.issues||[]).some(i=>String(i.id)==='${ISSUE_ID}');
  if(!hit) process.exit(1);
" || fail "Symphony 轮询列表未包含新工单"
pass "GET /api/symphony/issues 标签过滤"

curl -sS -X PATCH "$BASE_URL/api/v1/issues/${ISSUE_ID}" \
  -H 'Content-Type: application/json' \
  -d '{"state":"in_progress"}' | grep -q '"state":"in_progress"' \
  || fail "PATCH 状态"
pass "PATCH 工单状态"

curl -sS -X POST "$BASE_URL/api/v1/issues/${ISSUE_ID}/comments" \
  -H 'Content-Type: application/json' \
  -d '{"body":"e2e comment","author":"e2e"}' | grep -q '"body":"e2e comment"' \
  || fail "POST 评论"
pass "POST 评论"

detail="${TEST_DATA_DIR}/detail.json"
curl -sS "$BASE_URL/api/v1/issues/${ISSUE_ID}" -o "$detail"
node -e "
  const j=require('$detail');
  if(!j.comments?.length) process.exit(1);
" || fail "GET 详情应含评论"
pass "GET /api/v1/issues/:id"

batch="${TEST_DATA_DIR}/batch.json"
curl -sS -X POST "$BASE_URL/api/symphony/issues/batch" \
  -H 'Content-Type: application/json' \
  -d "{\"ids\":[\"${ISSUE_ID}\"]}" -o "$batch"
node -e "
  const j=require('$batch');
  if((j.issues||[]).length!==1) process.exit(1);
" || fail "batch 按 id 拉取"
pass "POST /api/symphony/issues/batch"

code=$(curl -sS -o /dev/null -w "%{http_code}" "$BASE_URL/api/v1/projects/nope/issues")
[[ "$code" == "404" ]] || fail "未知项目应 404"
pass "404 未知项目"

# 无 symphony 标签的工单不应出现在默认 label=symphony 轮询中
curl -sS -X POST "$BASE_URL/api/v1/projects/comic/issues" \
  -H 'Content-Type: application/json' \
  -d "{\"title\":\"no-label-$(date +%s)\",\"labels\":[\"e2e\"],\"state\":\"todo\"}" \
  -o "${TEST_DATA_DIR}/nolabel.json"
NO_ID=$(node -e "console.log(require('${TEST_DATA_DIR}/nolabel.json').issue.id)")
node -e "
  const j=require('$symphony_body');
  const ids=new Set((j.issues||[]).map(i=>String(i.id)));
  if(ids.has('${NO_ID}')) process.exit(1);
" || fail "无 symphony 标签不应出现在 symphony 列表"
# 重新拉 symphony 列表（可能包含新 todo 但无标签）
curl -sS "$BASE_URL/api/symphony/issues?project=comic&label=symphony" -o "${TEST_DATA_DIR}/symphony2.json"
node -e "
  const j=require('${TEST_DATA_DIR}/symphony2.json');
  if((j.issues||[]).some(i=>String(i.id)==='${NO_ID}')) process.exit(1);
" || fail "无 symphony 标签过滤"
pass "symphony 标签过滤（负例）"

echo
echo "→ Tracker HTTP 用例全部通过"
echo

if [[ "$RUN_ELIXIR" -eq 1 ]]; then
  if [[ ! -d "$SYMPHONY_ELIXIR" ]]; then
    fail "未找到 Symphony Elixir: $SYMPHONY_ELIXIR"
  fi
  need_cmd mix
  echo "→ Elixir issue_feed 适配器单元测试..."
  (cd "$SYMPHONY_ELIXIR" && mix test test/symphony_elixir/issue_feed_adapter_test.exs --color)
  pass "mix test issue_feed_adapter_test.exs"
fi

if [[ "$WITH_WORKFLOW" -eq 1 ]]; then
  if [[ ! -f "$WORKFLOW_FILE" ]]; then
    fail "未找到 WORKFLOW: $WORKFLOW_FILE"
  fi
  echo "→ 校验 WORKFLOW.md（Config.validate!）..."
  WF_EXS="${TEST_DATA_DIR}/validate_workflow.exs"
  cat >"$WF_EXS" <<EXS
SymphonyElixir.Workflow.set_workflow_file_path("$WORKFLOW_FILE")
:ok = SymphonyElixir.WorkflowStore.force_reload()
:ok = SymphonyElixir.Config.validate!()
kind = SymphonyElixir.Config.settings!().tracker.kind
if kind != "issue_feed", do: raise "tracker.kind=\#{kind} 应为 issue_feed"
IO.puts("tracker.kind=issue_feed OK")
EXS
  (cd "$SYMPHONY_ELIXIR" && mix run --no-start "$WF_EXS")
  pass "WORKFLOW 配置合法"
fi

if [[ "$FULL_CHAIN" -eq 1 ]]; then
  echo
  echo "== 全链路：Vite 看板 + Symphony 编排派发 =="
  chmod +x "$ROOT/scripts/fixtures/fake-codex-app-server.sh"

  # 派发验收用工单保持 todo（勿 in_progress 占用后难以断言新派发）
  curl -sS -X PATCH "$BASE_URL/api/v1/issues/${ISSUE_ID}" \
    -H 'Content-Type: application/json' \
    -d '{"state":"todo"}' >/dev/null || true

  echo "→ 启动 Vite 开发服务器 (port ${VITE_DEV_PORT})..."
  VITE_API_PROXY="$BASE_URL" VITE_DEV_PORT="$VITE_DEV_PORT" \
    npm run dev -w @symphony-tracker/web -- --host 127.0.0.1 \
    >"${TEST_DATA_DIR}/vite.log" 2>&1 &
  VITE_PID=$!

  vite_ready=0
  for _ in $(seq 1 100); do
    if curl -sS -o /dev/null "http://127.0.0.1:${VITE_DEV_PORT}/" 2>/dev/null; then
      vite_ready=1
      break
    fi
    sleep 0.2
  done
  [[ "$vite_ready" -eq 1 ]] || {
    cat "${TEST_DATA_DIR}/vite.log" >&2
    fail "Vite 未就绪"
  }
  pass "Vite 看板 http://127.0.0.1:${VITE_DEV_PORT}"

  echo "→ Playwright 看板点选（默认 channel=chrome，可设 PLAYWRIGHT_CHANNEL= 并先 npx playwright install chromium）..."
  if [[ ! -d "$ROOT/web/node_modules/@playwright/test" ]]; then
    (cd "$ROOT" && npm install -w @symphony-tracker/web)
  fi
  if [[ -z "${PLAYWRIGHT_CHANNEL:-chrome}" ]]; then
    if ! (cd "$ROOT/web" && npx playwright install --dry-run chromium 2>/dev/null | grep -qi "already installed"); then
      echo "正在安装 Playwright Chromium（仅首次较慢）..."
      (cd "$ROOT/web" && npx playwright install chromium)
    fi
  fi
  E2E_PLAYWRIGHT_MARKER="$PLAYWRIGHT_MARKER" \
  PLAYWRIGHT_BASE_URL="http://127.0.0.1:${VITE_DEV_PORT}" \
  PLAYWRIGHT_CHANNEL="${PLAYWRIGHT_CHANNEL:-chrome}" \
    npm run test:e2e -w @symphony-tracker/web
  pass "Playwright 新建工单 + 详情弹窗"

  if [[ -f "$PLAYWRIGHT_MARKER" ]]; then
    pass "Playwright marker $(cat "$PLAYWRIGHT_MARKER")"
  fi

  echo "→ Symphony Orchestrator 真实派发（fake codex）..."
  export SYMPHONY_RUN_ISSUE_FEED_E2E=1
  export TRACKER_BASE_URL="$BASE_URL"
  export E2E_ISSUE_ID="$ISSUE_ID"
  export E2E_ISSUE_IDENTIFIER="$IDENT"
  (cd "$SYMPHONY_ELIXIR" && mix test test/symphony_elixir/issue_feed_orchestrator_e2e_test.exs --color)
  pass "Orchestrator 派发 + 工作区创建"
fi

echo
echo "✅ 全部测试通过"
