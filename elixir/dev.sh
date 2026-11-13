#!/usr/bin/env bash
# Symphony 开发模式：监听源码改动 → 重新构建 escript → 重启守护进程。
#
# 用法:
#   ./dev.sh                 监听并自动重建重启
#   ./dev.sh --build-only    只监听并构建，不重启
#   ./dev.sh --restart-only  只重启一次，不监听
#
# 环境变量:
#   DEV_POLL_SECONDS    轮询间隔，默认 1 秒
#   DEV_IDLE_TIMEOUT    等 agent 空闲的最长秒数，默认 600
#   DEV_FORCE_RESTART=1 即使有 agent 在跑也立刻重启（会中断任务）
#   SYMPHONY_PORT       看板端口，默认 4567
#   SYMPHONY_START_SCRIPT 启动脚本，默认 ~/.config/symphony/start.sh
#
# 说明: escript 是自包含静态包，代码与 CSS 都编译进包里，
# 因此改 lib/ 或 priv/ 必须重建并重启进程才能生效（WORKFLOW.md 例外，它由
# WorkflowStore 每秒热加载）。
set -uo pipefail

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
START_SCRIPT="${SYMPHONY_START_SCRIPT:-$HOME/.config/symphony/start.sh}"
RUN_LOG="${HOME}/.config/symphony/symphony-run.log"
SCREEN_NAME="${SYMPHONY_SCREEN_NAME:-symphony}"
PORT="${SYMPHONY_PORT:-4567}"
POLL_SECONDS="${DEV_POLL_SECONDS:-1}"
IDLE_TIMEOUT="${DEV_IDLE_TIMEOUT:-600}"

WATCH_PATHS=("$REPO_DIR/lib" "$REPO_DIR/priv" "$REPO_DIR/config" "$REPO_DIR/mix.exs" "$REPO_DIR/mix.lock")

log() { printf '[dev %s] %s\n' "$(date +%H:%M:%S)" "$*"; }

# 用「mtime + 文件名」的哈希当签名：比逐字节比对便宜，又比只看 mtime 精确。
signature() {
  find "${WATCH_PATHS[@]}" -type f \
    \( -name '*.ex' -o -name '*.exs' -o -name '*.css' -o -name '*.js' -o -name '*.heex' \) \
    -exec stat -f '%m %N' {} + 2>/dev/null |
    sort | shasum -a 256 | awk '{print $1}'
}

stop_daemon() {
  screen -S "$SCREEN_NAME" -X quit >/dev/null 2>&1 || true
  pkill -f "bin/symphony" >/dev/null 2>&1 || true

  for _ in $(seq 1 20); do
    pgrep -f "bin/symphony" >/dev/null 2>&1 || return 0
    sleep 0.5
  done

  log "进程未在 10 秒内退出，强制结束"
  pkill -9 -f "bin/symphony" >/dev/null 2>&1 || true
  sleep 1
}

start_daemon() {
  if [ ! -x "$START_SCRIPT" ]; then
    log "找不到启动脚本: $START_SCRIPT"
    return 1
  fi

  screen -dmS "$SCREEN_NAME" zsh -lc "exec '$START_SCRIPT' 2>&1 | tee -a '$RUN_LOG'"
}

# 返回 0 / 正数 / unknown（进程在但接口不可达，按忙处理，宁可多等）。
running_count() {
  local body
  if ! body="$(curl -s --max-time 3 "http://127.0.0.1:${PORT}/api/v1/state" 2>/dev/null)" || [ -z "$body" ]; then
    if pgrep -f "bin/symphony" >/dev/null 2>&1; then
      echo unknown
    else
      echo 0
    fi
    return 0
  fi

  printf '%s' "$body" |
    python3 -c 'import json,sys; print(len(json.load(sys.stdin).get("running") or []))' 2>/dev/null ||
    echo unknown
}

# 有 agent 在跑时重启会中断任务，先等它们跑完。
wait_for_idle() {
  local waited=0
  local next_notice=0

  while :; do
    local count
    count="$(running_count)"

    if [ "$count" = "0" ]; then
      return 0
    fi

    if [ "${DEV_FORCE_RESTART:-0}" = "1" ]; then
      log "DEV_FORCE_RESTART=1，跳过等待直接重启（进行中的任务会被中断）"
      return 0
    fi

    if [ "$waited" -ge "$IDLE_TIMEOUT" ]; then
      log "已等待 ${IDLE_TIMEOUT}s 仍未空闲，跳过重启；新包已构建，可稍后手动重启"
      return 1
    fi

    if [ "$waited" -ge "$next_notice" ]; then
      log "仍有 ${count} 个 agent 在跑，等其结束再重启（DEV_FORCE_RESTART=1 可强制）"
      next_notice=$((waited + 30))
    fi

    sleep 5
    waited=$((waited + 5))
  done
}

rebuild() {
  log "检测到改动，开始构建"
  local out

  if ! out="$(cd "$REPO_DIR" && mix compile 2>&1)"; then
    printf '%s\n' "$out" | tail -n 25
    log "编译失败，保留旧进程继续运行"
    return 1
  fi

  if ! out="$(cd "$REPO_DIR" && mix escript.build 2>&1)"; then
    printf '%s\n' "$out" | tail -n 25
    log "escript 构建失败，保留旧进程继续运行"
    return 1
  fi

  log "构建完成"
  return 0
}

restart() {
  log "重启服务（端口 ${PORT}）"
  stop_daemon

  if ! start_daemon; then
    return 1
  fi

  local waited=0
  while [ "$waited" -lt 45 ]; do
    if curl -s -o /dev/null --max-time 2 "http://127.0.0.1:${PORT}/"; then
      log "服务已就绪: http://127.0.0.1:${PORT}/"
      return 0
    fi
    sleep 1
    waited=$((waited + 1))
  done

  log "45 秒内未就绪，查看日志: $RUN_LOG"
  return 1
}

watch_loop() {
  local last
  last="$(signature)"
  log "监听中: ${WATCH_PATHS[*]}（轮询 ${POLL_SECONDS}s，Ctrl-C 退出，服务保持运行）"

  while :; do
    sleep "$POLL_SECONDS"
    local now
    now="$(signature)"
    [ "$now" = "$last" ] && continue

    # 防抖：编辑器保存常常连着写多个文件，等签名稳定再动手。
    sleep 0.5
    now="$(signature)"
    last="$now"

    if rebuild; then
      if [ "${BUILD_ONLY:-0}" = "1" ]; then
        log "仅构建模式，未重启"
      elif wait_for_idle; then
        restart || log "重启失败，旧进程可能已被停止，请检查 $RUN_LOG"
      fi
    fi
  done
}

main() {
  case "${1:-}" in
    --restart-only)
      restart
      exit $?
      ;;
    --build-only)
      BUILD_ONLY=1
      rebuild || exit 1
      watch_loop
      ;;
    --help|-h)
      sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    "")
      rebuild || log "首次构建失败，仍进入监听"
      restart || log "启动失败，请检查 $RUN_LOG"
      watch_loop
      ;;
    *)
      echo "未知参数: $1（可用: --build-only / --restart-only）" >&2
      exit 1
      ;;
  esac
}

main "$@"
