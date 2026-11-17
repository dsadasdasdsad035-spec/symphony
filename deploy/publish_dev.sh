#!/usr/bin/env bash
# 把缺陷修复发布到【开发环境】（app-test，:30669）。
#
# 为什么单独一个脚本、而不是直接调 scripts/publish_apps_to_env.py：
#   1. 环境闸门——任何误传演示环境（:30680）的调用必须在构建前就被拒绝；
#   2. 跨 agent 互斥——publish_apps_to_env.py 的锁是 ${WS}/out/.publish.lock，
#      每个工作区各一把，两个 agent 并发时互不排斥，会把 app_market 复位成 noUp；
#   3. 补齐跟踪分支——修复分支往往落后于跟踪分支，直接打包会漏掉别人的代码；
#   4. 只发改动应用——全量发布是分钟级，会撞 agent 的 turn 上限。
#
# 发布语义（上传≠发布、bind 复位、授权闸门、内置应用恢复通道、终态复核）
# 全部委托给 scripts/publish_apps_to_env.py，本脚本不重复实现。
#
# 用法：
#   ./publish_dev.sh --issue SF-83323                  # 推导致动应用并发布
#   ./publish_dev.sh --issue SF-83323 --dry-run        # 零网络零写入，只看将执行什么
#   ./publish_dev.sh --issue SF-83323 --apps=sie-iidp-de-tool --yes
#   ./publish_dev.sh --workspace /data2/workspaces/SF-83323 --only=preflight
#
# 退出码：
#   0 成功｜1 参数错｜2 环境闸门拒绝（非开发环境）｜3 无可发布应用
#   4 已有发版在进行｜5 跟踪分支合并冲突｜6 工作区状态不干净｜其他 = publish 脚本原样透传

set -euo pipefail

DEV_PORT="30669"
DEV_BASE_DEFAULT="http://192.168.181.104:${DEV_PORT}"
DEMO_PORT="30680"
LOCK_DIR_DEFAULT="/data2/locks"
LOCK_NAME="publish-apptest.lock"

log()  { printf '\033[36m[dev-release]\033[0m %s\n' "$*"; }
warn() { printf '\033[33m[dev-release]\033[0m %s\n' "$*" >&2; }
die()  { local code=$1; shift; printf '\033[31m[dev-release]\033[0m %s\n' "$*" >&2; exit "$code"; }

usage() {
  cat <<'EOF'
用法: publish_dev.sh [选项]

必填（二选一）:
  --issue <ID>          善治编号；工作区默认为 $SYMPHONY_WORKSPACE_ROOT/<ID>
  --workspace <PATH>    直接指定工作区路径

选项:
  --base <URL>          目标环境地址，必须含 30669（默认 http://192.168.181.104:30669）
  --apps <a,b,c>        只发这些 app，跳过 diff 推导
  --only <steps>        透传给 publish 脚本（如 preflight），用于分段验证
  --dry-run             零网络零写入预演（透传）
  --no-merge            跳过"合并跟踪分支"步骤（确知本地即最新时使用）
  --allow-dirty         允许子仓有未提交改动（默认拒绝）
  --yes / --no-yes      写步骤确认（默认 --yes；--no-yes 只跑只读步骤）
  --help                显示本帮助

说明:
  · 只发开发环境。演示环境（:30680）会被闸门直接拒绝。
  · 全局排它锁 /data2/locks/publish-apptest.lock，跨工作区互斥。
  · 发版完成后仍需自行核对环境；发版失败时不要调用 shanzhi_resolve_bug。
EOF
}

# ---------------------------------------------------------------- 参数
ISSUE=""
WORKSPACE=""
BASE="$DEV_BASE_DEFAULT"
APPS=""
ONLY=""
DRY_RUN=0
DO_MERGE=1
ALLOW_DIRTY=0
# publish 脚本对 upload/shelf/update 要求显式 --yes，且是报错而非交互提问。
# 发版脚本本身就是无人值守流程，所以默认带上；--no-yes 可用于只跑只读步骤。
PASS_YES=1

while [ $# -gt 0 ]; do
  case "$1" in
    --issue)      ISSUE="${2:-}"; shift 2 ;;
    --issue=*)    ISSUE="${1#*=}"; shift ;;
    --workspace)  WORKSPACE="${2:-}"; shift 2 ;;
    --workspace=*) WORKSPACE="${1#*=}"; shift ;;
    --base)       BASE="${2:-}"; shift 2 ;;
    --base=*)     BASE="${1#*=}"; shift ;;
    --apps)       APPS="${2:-}"; shift 2 ;;
    --apps=*)     APPS="${1#*=}"; shift ;;
    --only)       ONLY="${2:-}"; shift 2 ;;
    --only=*)     ONLY="${1#*=}"; shift ;;
    --dry-run)    DRY_RUN=1; shift ;;
    --no-merge)   DO_MERGE=0; shift ;;
    --allow-dirty) ALLOW_DIRTY=1; shift ;;
    --yes)        PASS_YES=1; shift ;;
    --no-yes)     PASS_YES=0; shift ;;
    --help|-h)    usage; exit 0 ;;
    *)            usage; die 1 "未知参数: $1" ;;
  esac
done

# ---------------------------------------------------------------- 闸门 1：环境
# 必须在任何构建/网络写入之前判定——这是"不影响演示环境"的唯一硬保证。
case "$BASE" in
  *"$DEV_PORT"*) : ;;
  *)
    if [[ "$BASE" == *"$DEMO_PORT"* ]]; then
      die 2 "拒绝：$BASE 是演示环境（:${DEMO_PORT}）。本脚本只发开发环境（:${DEV_PORT}），演示环境不受影响。"
    fi
    die 2 "拒绝：$BASE 不含 ${DEV_PORT}，不是开发环境。"
    ;;
esac
BASE="${BASE%/}"

# ---------------------------------------------------------------- 定位工作区
if [ -n "$WORKSPACE" ]; then
  WS="$WORKSPACE"
elif [ -n "$ISSUE" ]; then
  ROOT="${SYMPHONY_WORKSPACE_ROOT:-/data2/workspaces}"
  WS="$ROOT/$ISSUE"
else
  # 未显式指定时，若正好站在某个工作区根上就用当前目录
  WS="$PWD"
fi

[ -d "$WS" ] || die 1 "工作区不存在: $WS"
WS="$(cd "$WS" && pwd)"
[ -f "$WS/.gitmodules" ] || die 1 "不是聚合仓库根（缺 .gitmodules）: $WS"

# 从工作区目录名兜底推断编号
if [ -z "$ISSUE" ]; then
  ISSUE="$(basename "$WS")"
fi

PUBLISH_PY="$WS/scripts/publish_apps_to_env.py"
[ -f "$PUBLISH_PY" ] || die 1 "找不到发布脚本: $PUBLISH_PY"

log "工作区  $WS"
log "编号    $ISSUE"
log "环境    $BASE（开发环境）"

# ---------------------------------------------------------------- 闸门 2：全局排它锁
LOCK_DIR="${PUBLISH_LOCK_DIR:-$LOCK_DIR_DEFAULT}"
[ -d "$LOCK_DIR" ] || mkdir -p "$LOCK_DIR" 2>/dev/null || die 4 "无法创建锁目录: $LOCK_DIR"
LOCK_FILE="$LOCK_DIR/$LOCK_NAME"

exec 9>>"$LOCK_FILE"
# 先记下当前持锁者：若拿不到锁，要用这段信息告诉后来者是谁在发版。
# 注意必须用 >> 打开——用 > 会在这里就把持锁者写的内容截断掉，
# 导致并发失败时只能报"未知"（实测踩过）。
HOLDER_INFO="$(cat "$LOCK_FILE" 2>/dev/null | head -1 || true)"

if ! flock -n 9; then
  {
    printf '\n'
    printf '  已有发版在进行（持锁者: %s）\n' "${HOLDER_INFO:-未知}"
    printf '  锁文件: %s\n' "$LOCK_FILE"
    printf '  开发环境的发版必须串行，等它结束后重试。\n'
  } >&2
  exit 4
fi
# 拿到锁后立即登记持锁者，供后来者看清是谁在发版
printf 'workspace=%s pid=%s since=%s\n' "$WS" "$$" "$(date '+%Y-%m-%d %H:%M:%S')" >"$LOCK_FILE"
trap 'printf "" >"$LOCK_FILE" 2>/dev/null || true' EXIT

log "已获取全局排它锁 $LOCK_FILE"

# ---------------------------------------------------------------- .gitmodules → 跟踪分支
# branch 键本来只供 git submodule update 使用，这里借它当"该子仓的跟踪分支"。
declare -A SUB_PATH=()
declare -A SUB_TRACK=()

while IFS=' ' read -r key _val; do
  case "$key" in
    submodule.*.path)
      name="${key#submodule.}"; name="${name%.path}"
      SUB_PATH["$name"]="$(git -C "$WS" config -f .gitmodules "submodule.$name.path")"
      ;;
  esac
done < <(git -C "$WS" config -f .gitmodules --get-regexp '^submodule\..*\.path$')

while IFS=' ' read -r key _val; do
  case "$key" in
    submodule.*.branch)
      name="${key#submodule.}"; name="${name%.branch}"
      # 重复 branch 键时 git config --get 取最后一个，与 git 自身行为一致
      SUB_TRACK["$name"]="$(git -C "$WS" config -f .gitmodules --get "submodule.$name.branch")"
      ;;
  esac
done < <(git -C "$WS" config -f .gitmodules --get-regexp '^submodule\..*\.branch$' || true)

if [ ${#SUB_PATH[@]} -eq 0 ]; then
  die 1 ".gitmodules 里没解析到任何子模块"
fi

log "解析到 ${#SUB_PATH[@]} 个子模块的跟踪分支："
for name in $(printf '%s\n' "${!SUB_PATH[@]}" | sort); do
  printf '    %-32s path=%-30s branch=%s\n' "$name" "${SUB_PATH[$name]}" "${SUB_TRACK[$name]:-<未声明>}"
done

# ---------------------------------------------------------------- 合并跟踪分支
# 修复分支通常建立在旧的跟踪分支上，不合并就会漏掉别人的代码。
#
# 关键语义：一次修复通常只碰 1~2 个子仓，所以"有没有 symphony/<issue> 分支"
# 就是"这个子仓有没有被本次修复改动"的判据。没有分支的子仓一律跳过，
# 不能要求全部子仓都有分支（SF-83192 实测只有前端仓有分支）。
#
# base-inner-web 这类仓 bugfixbot 没有写权限，只做本地合并、不推送。
READONLY_SUBS="${READONLY_SUBS:-sie-iidp-base-inner-web}"

# 跟踪分支失效时的统一说法：既说清原因，也给出下一步动作。
# 必须在 merge_tracking 之前定义——合并阶段会在调用点用到它。
baseline_failure_hint() {
  local name="$1" track="$2" repo="$3"
  {
    printf '\033[31m[dev-release]\033[0m %s 的跟踪分支 origin/%s 不存在。\n' "$name" "$track"
    printf '  .gitmodules 里 branch=%s 已失效（分支被删除或配置未更新）。\n' "$track"
    printf '  没有基线就无法判断本次改动，不能当作"无改动"处理。\n'
    printf '  修法：把 .gitmodules 的 branch 改成现存分支（例如前端仓用 test）后再跑。\n'
    printf '  现存远端分支：git -C %s branch -r\n' "$repo"
  } >&2
}

declare -a TOUCHED=()   # 有 symphony/<issue> 分支的子仓名

discover_touched() {
  local name path repo branch
  for name in $(printf '%s\n' "${!SUB_PATH[@]}" | sort); do
    path="${SUB_PATH[$name]}"
    repo="$WS/$path"
    [ -d "$repo/.git" ] || [ -f "$repo/.git" ] || continue
    branch="symphony/$ISSUE"
    if git -C "$repo" show-ref --verify --quiet "refs/heads/$branch"; then
      TOUCHED+=("$name")
    fi
  done
}

merge_tracking() {
  local name="$1"
  local path="${SUB_PATH[$name]}"
  local track="${SUB_TRACK[$name]:-}"
  local repo="$WS/$path"
  local branch="symphony/$ISSUE"

  if [ -z "$track" ]; then
    warn "  $name: .gitmodules 未声明 branch，跳过合并（无法判断跟踪分支）"
    return 0
  fi

  # 工作区干净性：merge 在脏目录里会失败或留下半合并状态
  local dirty
  dirty="$(git -C "$repo" status --porcelain 2>/dev/null | wc -l | tr -d ' ')"
  if [ "$dirty" != "0" ] && [ "$ALLOW_DIRTY" != "1" ]; then
    die 6 "$name 有 $dirty 处未提交改动。先提交/清理，或加 --allow-dirty。"
  fi

  git -C "$repo" checkout --quiet "$branch"

  if ! git -C "$repo" show-ref --verify --quiet "refs/remotes/origin/$track"; then
    if [ "$DRY_RUN" = "1" ]; then
      # dry-run 不联网，不能 fetch
      warn "  $name: 本地缺少 origin/$track，dry-run 不 fetch，无法判断基线"
      return 0
    fi
    log "  $name: git fetch origin $track"
    git -C "$repo" fetch --quiet origin "$track" 2>/dev/null || true
  fi

  # 跟踪分支在远端不存在 = 配置已失效（典型：分支被删、或 .gitmodules 未更新）。
  # 这种情况绝不能静默跳过：跳过后 diff 会变成空集，被误判成"没有改动"。
  if ! git -C "$repo" show-ref --verify --quiet "refs/remotes/origin/$track"; then
    if [ "$DRY_RUN" = "1" ]; then
      warn "  $name: dry-run 下无法解析基线 origin/$track，跳过合并"
      return 0
    fi
    baseline_failure_hint "$name" "$track" "$repo"
    exit 8
  fi

  if git -C "$repo" merge-base --is-ancestor "origin/$track" HEAD 2>/dev/null; then
    log "  $name: 已包含 origin/$track，无需合并"
    return 0
  fi

  if [ "$DRY_RUN" = "1" ]; then
    log "  $name: 落后 origin/$track（dry-run 不执行合并）"
    return 0
  fi

  log "  $name: 合并 origin/$track ..."
  if ! git -C "$repo" merge --no-edit "origin/$track" >/dev/null 2>&1; then
    {
      printf '\033[31m[dev-release]\033[0m %s 与 origin/%s 合并冲突，冲突文件：\n' "$name" "$track"
      git -C "$repo" diff --name-only --diff-filter=U 2>/dev/null | sed 's/^/      /'
      printf '  本次未产出任何包。解决冲突后重试。\n'
    } >&2
    git -C "$repo" merge --abort >/dev/null 2>&1 || true
    exit 5
  fi
  log "  ✓ $name: 已合并 origin/$track"

  # 合并结果要推上去，否则评审看到的分支与发版所用代码不一致
  case " $READONLY_SUBS " in
    *" $name "*)
      warn "  $name: 已知无写权限，只做本地合并、不推送"
      return 0
      ;;
  esac
  if git -C "$repo" rev-parse --abbrev-ref "@{u}" >/dev/null 2>&1; then
    if git -C "$repo" push --quiet origin "$branch" >/dev/null 2>&1; then
      log "  $name: 合并结果已推送到 $branch"
    else
      warn "  $name: 推送 $branch 失败（MR 可能仍显示旧代码，但本次发版用的是本地已合并代码）"
    fi
  else
    warn "  $name: $branch 无上游，跳过推送"
  fi
}

discover_touched
if [ ${#TOUCHED[@]} -eq 0 ]; then
  die 5 "没有任何子仓存在 symphony/$ISSUE 分支。先按交付流程提交并推送，再发版。"
fi

log "=== 受影响子仓（存在 symphony/$ISSUE 分支）==="
for name in "${TOUCHED[@]}"; do
  printf '    %-32s track=%s\n' "$name" "${SUB_TRACK[$name]:-<未声明>}"
done

if [ "$DO_MERGE" = "1" ]; then
  log "=== 合并跟踪分支 ==="
  for name in "${TOUCHED[@]}"; do
    merge_tracking "$name"
  done
else
  warn "已跳过跟踪分支合并（--no-merge）"
fi

# ---------------------------------------------------------------- 推导发版目标
# 可发布 app 清单（与 scripts/publish_apps_to_env.py 的默认清单保持一致）
FRONT_APPS="sie-iidp-ai-agent-web sie-iidp-ai-demo-web sie-iidp-ai-nsvc-web sie-iidp-ai-post-web sie-iidp-ai-skill-web sie-iidp-ai-tenant-web sie-iidp-ai-tool-web"
BACK_APPS="sie-iidp-digitalemployee sie-iidp-de-post sie-iidp-de-post-dev sie-iidp-de-skill sie-iidp-de-tool sie-iidp-employee-implementer sie-iidp-employee-tenant-admin"
STORE_APPS="sie-iidp-app-store"
IAM_APPS="sie-iidp-iam"

# 排除项及原因（可用 EXCLUDE_SPEC 覆盖，格式 app:原因,app:原因）
EXCLUDE_SPEC="${EXCLUDE_SPEC:-sie-iidp-iam:pod 内只有 JDK 21、缺 JDK 8，该模块无法构建,sie-iidp-ai-demo-web:开发环境没有该应用的市场行，无法发布}"

in_list() { case " $2 " in *" $1 "*) return 0 ;; esac; return 1; }

# 改动文件 → app 名；不映射到任何可发布 app 时输出空
map_path_to_app() {
  local sub="$1" file="$2" seg
  case "$sub" in
    sie-iidp-ai-agent-web)
      case "$file" in
        apps/*/*)
          seg="$(printf '%s' "$file" | cut -d/ -f2)"
          in_list "$seg" "$FRONT_APPS" && printf '%s' "$seg"
          ;;
      esac
      ;;
    iidp-backend-demo-ai)
      case "$file" in
        sie-iidp-demo-apps/*/*)
          seg="$(printf '%s' "$file" | cut -d/ -f2)"
          in_list "$seg" "$BACK_APPS" && printf '%s' "$seg"
          ;;
      esac
      ;;
    sie-iidp-app-store)
      case "$file" in
        sie-iidp-store-apps/sie-iidp-app-store-app/*) printf '%s' "sie-iidp-app-store" ;;
      esac
      ;;
    sie-iidp-iam)
      case "$file" in
        sie-iidp-apps/sie-iidp-iam/*) printf '%s' "sie-iidp-iam" ;;
      esac
      ;;
  esac
}

declare -a DERIVED=()
declare -a IGNORED_FILES=()
BASELINE_UNKNOWN=0

if [ -n "$APPS" ]; then
  log "=== 目标由 --apps 显式指定，跳过推导 ==="
  IFS=',' read -r -a DERIVED <<<"$APPS"
else
  log "=== 从 git diff 推导发版目标 ==="
  for name in "${TOUCHED[@]}"; do
    local_path="${SUB_PATH[$name]}"
    local_track="${SUB_TRACK[$name]:-}"
    repo="$WS/$local_path"
    if [ -z "$local_track" ]; then
      die 8 "$name 没有跟踪分支，无法推导改动。修正 .gitmodules 的 branch 后重试。"
    fi

    # 先确认基线引用存在，避免把 git 的 "ambiguous argument" 直接甩给使用者
    if ! git -C "$repo" show-ref --verify --quiet "refs/remotes/origin/$local_track"; then
      if [ "$DRY_RUN" = "1" ]; then
        # dry-run 承诺不联网，不能 fetch；记下来，最后按"基线未知"报错而不是"无可发布应用"
        warn "  $name: 本地缺少 origin/$local_track，dry-run 不 fetch，无法推导"
        BASELINE_UNKNOWN=$((BASELINE_UNKNOWN + 1))
        continue
      fi
      baseline_failure_hint "$name" "$local_track" "$repo"
      exit 8
    fi

    diff_err="$(mktemp)"
    if ! changed="$(git -C "$repo" diff --name-only "origin/$local_track...HEAD" 2>"$diff_err")"; then
      {
        printf '\033[31m[dev-release]\033[0m %s: git diff 失败，无法确定改动范围（不当作"无改动"处理）\n' "$name"
        sed 's/^/      /' "$diff_err" >&2
      } >&2
      rm -f "$diff_err"
      exit 8
    fi
    rm -f "$diff_err"

    if [ -z "$changed" ]; then
      log "  $name: 相对 origin/$local_track 无改动"
      continue
    fi

    n_total=0
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      n_total=$((n_total + 1))
      app="$(map_path_to_app "$name" "$f")"
      if [ -n "$app" ]; then
        if ! in_list "$app" "${DERIVED[*]+"${DERIVED[*]}"}"; then
          DERIVED+=("$app")
          log "    + $app   （$name/$f）"
        fi
      else
        IGNORED_FILES+=("$name/$f")
      fi
    done <<<"$changed"
    log "  $name: ${n_total} 个改动文件"
  done

  if [ ${#IGNORED_FILES[@]} -gt 0 ]; then
    warn "以下改动不映射到任何可发布 app（不影响发版）："
    printf '    %s\n' "${IGNORED_FILES[@]}" | head -20 >&2
    [ ${#IGNORED_FILES[@]} -gt 20 ] && printf '    ...（共 %d 个）\n' "${#IGNORED_FILES[@]}" >&2
  fi
fi

# ---------------------------------------------------------------- 排除规则
if [ ${#DERIVED[@]} -gt 0 ]; then
  declare -a KEPT=()
  declare -A EXCL_REASON=()
  IFS=',' read -r -a _rules <<<"$EXCLUDE_SPEC"
  for _r in "${_rules[@]}"; do
    [ -n "$_r" ] || continue
    EXCL_REASON["${_r%%:*}"]="${_r#*:}"
  done

  for app in "${DERIVED[@]}"; do
    if [ -n "${EXCL_REASON[$app]:-}" ]; then
      warn "  ✗ 已排除 $app：${EXCL_REASON[$app]}"
    else
      KEPT+=("$app")
    fi
  done
  DERIVED=("${KEPT[@]+"${KEPT[@]}"}")
fi

if [ ${#DERIVED[@]} -eq 0 ] && [ "$BASELINE_UNKNOWN" -gt 0 ]; then
  warn "无法推导发版目标：${BASELINE_UNKNOWN} 个子仓的跟踪分支在本地不可用（dry-run 不 fetch）。"
  warn "  去掉 --dry-run 重试，脚本会先拉取基线再判断；"
  warn "  若实跑仍报跟踪分支不存在，说明 .gitmodules 的 branch 已失效。"
  exit 8
fi

if [ ${#DERIVED[@]} -eq 0 ]; then
  warn "无可发布应用。"
  warn "  本次改动没有落在任何可发布的 app 上，或全部被排除规则拦下。"
  warn "  未执行上传与上架；这不是发布成功，请先确认改动位置。"
  exit 3
fi

TARGETS="$(IFS=','; printf '%s' "${DERIVED[*]}")"
log "=== 发版目标（${#DERIVED[@]} 个）==="
printf '    %s\n' "${DERIVED[@]}"

# ---------------------------------------------------------------- 构建前提
has_front=0
for app in "${DERIVED[@]}"; do
  in_list "$app" "$FRONT_APPS" && has_front=1
done

if [ "$has_front" = "1" ]; then
  FRONT_DIR="$WS/sie-iidp-ai-agent-web"
  if [ "$DRY_RUN" = "1" ]; then
    # dry-run 的承诺是"零网络零写入"，装依赖两者都违反，必须跳过
    if [ ! -d "$FRONT_DIR/node_modules" ]; then
      warn "前端依赖缺失，但 --dry-run 不做安装（实跑时会先 npm ci/install）"
    fi
  elif [ ! -d "$FRONT_DIR/node_modules" ]; then
    log "=== 前端依赖缺失，安装 node_modules ==="
    if [ -f "$FRONT_DIR/package-lock.json" ]; then
      log "npm ci（按 package-lock.json）"
      if ! (cd "$FRONT_DIR" && npm ci --no-audit --no-fund) ; then
        die 7 "npm ci 失败。前端发版需要可复现的依赖，请检查 package-lock.json 与网络。"
      fi
    else
      log "npm install（无 lock 文件）"
      if ! (cd "$FRONT_DIR" && npm install --no-audit --no-fund) ; then
        die 7 "npm install 失败。"
      fi
    fi
    log "✓ 前端依赖就绪"
  else
    log "前端依赖已存在，跳过 npm 安装"
  fi
fi

# ---------------------------------------------------------------- 调用发布脚本
log "=== 调用 publish_apps_to_env.py ==="
set -- --env=apptest --base="$BASE" --apps="$TARGETS" --no-iam --no-engine
[ -n "$ONLY" ] && set -- "$@" --only="$ONLY"
[ "$DRY_RUN" = "1" ] && set -- "$@" --dry-run
[ "$PASS_YES" = "1" ] && set -- "$@" --yes

log "python3 scripts/publish_apps_to_env.py $*"
(cd "$WS" && python3 scripts/publish_apps_to_env.py "$@")
rc=$?
if [ "$rc" -ne 0 ]; then
  warn "发版未通过（退出码 $rc）。"
  warn "  不要调用 shanzhi_resolve_bug：先按报告里的判据修复，再重发。"
  exit "$rc"
fi
log "✓ 发版与一致性校验通过"
log "  下一步：核对环境中的版本后，才调用 shanzhi_resolve_bug。"

