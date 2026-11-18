#!/usr/bin/env bash
# 开发环境（:30669）的冒烟入口：UI 与 API 两层都跑 iidp_uitest 仓库里的 pytest 用例。
#
# 为什么统一到一个仓库，而不是自己维护 scenario JSON 或 curl 脚本：
#   · 元素定位统一维护在 data/<栈>/elements（实测 1957 条），改版式只改一处；
#   · 页面方法库按域拆分（iam / meta_app / workflow / tenant…），Agent 写用例是拼装不是造轮子；
#   · pytest 原生断言 + Allure + 失败 trace/DOM/GIF 留证，评审能复跑同一条命令；
#   · 用例可提交复用，下一轮同类缺陷直接跑现成的，不必每次重写验证逻辑。
#
# 两层怎么分（用例放哪由框架的路径前缀决定，脚本按路径自动判定）：
#   · 接口层：testcase/api/<产品>/test_*.py，加 @pytest.mark.api。纯 requests 直连 RPC，
#     不启动浏览器（conftest 的 _is_non_ui_test 会跳过浏览器/trace/截图钩子），秒级出结果。
#   · 界面层：testcase/<栈>/<产品>/test_*.py，走 drivers fixture 起无头浏览器，
#     用于点击/渲染/路由/微前端挂载等只能在界面上看到的行为。
#   界面类缺陷不得只用接口层替代：接口 200 只说明后端逻辑通，界面上该渲染的没渲染、
#   按钮该亮还是灰的，这些不会出现在接口响应里。
#
# 本脚本负责把 Agent 从容易踩空的地方抬出来，共四件事：
#   1. 找到（必要时浅克隆）uitest 仓库，仓库 1.1G，克隆完缓存在工作区根下跨 issue 复用；
#   2. 按环境变量生成 conf/active.ini 与 config.local.ini（口令只落 0600 临时文件，退出即删）；
#   3. 开跑前校验环境里跑的是不是待验版本（--expect-version），避免"验了旧代码"；
#   4. 跑完把 junit 结论 + 截图/Allure/trace 的绝对路径打出来，直接贴进善治备注。
#
# 用法：
#   smoke_test.sh --case testcase/api/iidp/test_xxx_smoke.py            # 接口层
#   smoke_test.sh --case testcase/iidp/iidp/test_xxx_smoke.py           # 界面层
#   smoke_test.sh --case ...::Test_X::test_y --expect-version 1.0.1
#
# 退出码：
#   0 PASS｜1 验收失败｜2 参数/依赖缺失｜3 版本等待超时

set -uo pipefail

DEV_URL_DEFAULT="http://192.168.181.104:30669"
FRONT_HOST_DEFAULT="${DEV_URL_DEFAULT}/iidp/"
RPC_APP_FOR_MARKET="sie-iidp-app-store"
UITEST_REPO_DEFAULT="http://192.168.175.55:9888/xuchunxia/iidp_uitest.git"

log()  { printf '\033[36m[smoke-test]\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[33m[smoke-test]\033[0m %s\n' "$*" >&2; }
die()  { local code=$1; shift; printf '\033[31m[smoke-test]\033[0m %s\n' "$*" >&2; exit "$code"; }

# ---------------------------------------------------------------- 参数
# 层级按路径判定，与框架的 conftest._is_non_ui_test 保持一致：
# testcase/api/ 前缀 = 纯 API（不启浏览器），其余 = 界面层。
# 判定错了后果不小——界面缺陷被当成接口层验完，等于没验，所以这里核对一次并在结果里写明。
LAYER=""
# 只按路径判层：版本门禁在定位仓库之前就要输出结论，所以这一步不能依赖 REPO。
resolve_layer_path() {
  case "$CASE_FILE" in
    testcase/api/*) LAYER="API" ;;
    *)              LAYER="UI"  ;;
  esac
}

# marker 与路径的一致性核对：两者不一致时框架行为跟直觉相反，提前说清比事后猜错好。
check_layer_marker() {
  local file="$REPO/$CASE_FILE" marker_api=0
  [ -f "$REPO/$CASE_FILE" ] || file="$CASE_FILE"
  [ -f "$file" ] && grep -qE "pytest\.mark\.api" "$file" 2>/dev/null && marker_api=1
  if [ "$LAYER" = "API" ] && [ "$marker_api" = "0" ]; then
    warn "接口层用例建议加 @pytest.mark.api（pytest.ini 已注册该 marker，便于 -m api 批量跑）"
  fi
  if [ "$LAYER" = "UI" ] && [ "$marker_api" = "1" ]; then
    warn "该用例标了 @pytest.mark.api 但不在 testcase/api/ 下：conftest 仍会启动浏览器（慢且可能因登录时序失败）"
  fi
}

CASE=""
REPO=""
STACK="${SMOKE_UITEST_STACK:-iidp}"
PRODUCT="${SMOKE_UITEST_PRODUCT:-iidp}"
HOST="${IIDP_UITEST_HOST:-$FRONT_HOST_DEFAULT}"
REPO_URL="${IIDP_UITEST_REPO:-$UITEST_REPO_DEFAULT}"
CACHE_DIR="${IIDP_UITEST_DIR:-${SYMPHONY_WORKSPACE_ROOT:-$HOME/.cache}/.uitest}"
ALLOW_CLONE=1
PYTHON="${SMOKE_PYTHON:-}"
OUTPUT=""
EXTRA_ARGS=()
SCREENCAST=0
ATTEMPTS=1
# 版本先行校验：发版是异步的（上传 → 上架 → 更新 → 前端资源生效），
# 跑早了验到的还是旧代码，会得到"改了却没变化"的假结论。
EXPECT_VERSION=""
VERSION_APP=""
VERSION_TIMEOUT=300
POLL_INTERVAL=15
FALLBACK_WAIT=60

usage() {
  cat <<'EOF'
用法: smoke_test.sh --case <pytest 用例> [选项]

必填:
  --case <NODEID>          uitest 仓库内的用例，文件或 nodeid 都行
                           接口层：testcase/api/iidp/test_xxx_smoke.py（纯 requests，不启浏览器）
                           界面层：testcase/iidp/iidp/test_xxx_smoke.py::Test_X::test_y

环境:
  --repo <DIR>             uitest 仓库路径；不给则在缓存目录找，找不到就浅克隆
  --no-clone               允许找不到就报错退出（离线/禁止拉仓库时用）
  --repo-url <URL>         克隆地址，默认 $IIDP_UITEST_REPO
  --cache-dir <DIR>        仓库缓存目录，默认 ${SYMPHONY_WORKSPACE_ROOT}/.uitest
  --stack <栈>             默认 iidp（写进 conf/active.ini）
  --product <产品线>       默认 iidp（决定读 conf/<栈>/<产品>/config.ini）
  --host <URL>             前端地址，默认 http://192.168.181.104:30669/iidp/
  --python <解释器>        默认优先用仓库内 .venv/bin/python，否则 python3
  --output <DIR>           证据目录，默认 ./smoke-test-<时间戳>
  --screencast             开启过程动图（仅界面层有效；默认关闭，无头下帧洪峰会拖慢/拖崩浏览器）
  --attempts <N>           失败重试次数，默认 1（不做重试）

版本先行校验:
  --expect-version <VER>   期望环境上运行的版本；不一致则轮询等待
  --version-app <APP>      校验哪个应用，默认 sie-iidp-de-tool
                           （sie-iidp-app-store 的 version 恒为 null，别拿它校验）
  --version-timeout <秒>   等待版本就绪上限，默认 300
  --poll-interval <秒>     轮询间隔，默认 15
  --fallback-wait <秒>     版本接口读不到时的固定等待，默认 60（结论会注明"版本未经校验"）

其他:
  -- <args...>             其余参数原样透传给 pytest（如 -k、--maxfail）
  --help                   显示本帮助

账号: 取容器内 $IIDP_USER / $IIDP_PASSWORD（默认 implementer），不落盘、不回显。
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --case)             CASE="${2:-}"; shift 2 ;;
    --case=*)           CASE="${1#*=}"; shift ;;
    --repo)             REPO="${2:-}"; shift 2 ;;
    --repo=*)           REPO="${1#*=}"; shift ;;
    --repo-url)         REPO_URL="${2:-}"; shift 2 ;;
    --repo-url=*)       REPO_URL="${1#*=}"; shift ;;
    --cache-dir)        CACHE_DIR="${2:-}"; shift 2 ;;
    --cache-dir=*)      CACHE_DIR="${1#*=}"; shift ;;
    --stack)            STACK="${2:-}"; shift 2 ;;
    --stack=*)          STACK="${1#*=}"; shift ;;
    --product)          PRODUCT="${2:-}"; shift 2 ;;
    --product=*)        PRODUCT="${1#*=}"; shift ;;
    --host)             HOST="${2:-}"; shift 2 ;;
    --host=*)           HOST="${1#*=}"; shift ;;
    --python)           PYTHON="${2:-}"; shift 2 ;;
    --python=*)         PYTHON="${1#*=}"; shift ;;
    --output)           OUTPUT="${2:-}"; shift 2 ;;
    --output=*)         OUTPUT="${1#*=}"; shift ;;
    --no-clone)         ALLOW_CLONE=0; shift ;;
    --screencast)       SCREENCAST=1; shift ;;
    --attempts)         ATTEMPTS="${2:-}"; shift 2 ;;
    --attempts=*)       ATTEMPTS="${1#*=}"; shift ;;
    --expect-version)   EXPECT_VERSION="${2:-}"; shift 2 ;;
    --expect-version=*) EXPECT_VERSION="${1#*=}"; shift ;;
    --version-app)      VERSION_APP="${2:-}"; shift 2 ;;
    --version-app=*)    VERSION_APP="${1#*=}"; shift ;;
    --version-timeout)  VERSION_TIMEOUT="${2:-}"; shift 2 ;;
    --version-timeout=*) VERSION_TIMEOUT="${1#*=}"; shift ;;
    --poll-interval)    POLL_INTERVAL="${2:-}"; shift 2 ;;
    --poll-interval=*)  POLL_INTERVAL="${1#*=}"; shift ;;
    --fallback-wait)    FALLBACK_WAIT="${2:-}"; shift 2 ;;
    --fallback-wait=*)  FALLBACK_WAIT="${1#*=}"; shift ;;
    --help|-h)          usage; exit 0 ;;
    --)                 shift; EXTRA_ARGS=("$@"); break ;;
    *)                  die 2 "未知参数: $1（--help 看用法）" ;;
  esac
done

[ -n "$CASE" ] || { usage >&2; die 2 "缺少 --case：必须显式指定要跑的用例，脚本不会替你猜验什么"; }
[ -n "${IIDP_USER:-}" ] || die 2 "缺少 \$IIDP_USER（应由 entrypoint 从环境注入）"
[ -n "${IIDP_PASSWORD:-}" ] || die 2 "缺少 \$IIDP_PASSWORD（应由 entrypoint 从环境注入）"
# jq 用于生成 RPC 请求与读版本号；缺了会在版本校验处静默降级，不如现在就说清楚。
command -v jq >/dev/null 2>&1 || die 2 "缺少 jq（镜像内应自带；本地跑请先安装）"

CASE_FILE="${CASE%%::*}"
resolve_layer_path

# ---------------------------------------------------------------- 0. 临时文件登记
# 这里会写两个含敏感值的文件（config.local.ini 里的口令、junit 临时文件），
# 统一登记、退出即清，避免密码在工作区里留痕。
CLEANUP_PATHS=()
ACTIVE_INI_BACKUP=""
cleanup() {
  local p
  # 先还原再删备份：备份文件本身也在待清理清单里，顺序反了会把备份删掉导致还原失败。
  if [ -n "$ACTIVE_INI_BACKUP" ] && [ -f "$ACTIVE_INI_BACKUP" ] && [ -n "$REPO" ]; then
    cp "$ACTIVE_INI_BACKUP" "$REPO/conf/active.ini" 2>/dev/null || true
  fi
  for p in ${CLEANUP_PATHS[@]+"${CLEANUP_PATHS[@]}"}; do
    [ -n "$p" ] && rm -rf "$p"
  done
}
trap cleanup EXIT

# ---------------------------------------------------------------- 1. 解释器与依赖
# 依赖预检失败必须立刻停：让 pytest 抛 ModuleNotFoundError 的堆栈
# 既难读也容易误导（会被当成用例失败，实际上环境没装好）。
check_python_deps() {
  local py="$1" missing
  missing="$("$py" - <<'PY' 2>/dev/null
import importlib.util
mods = [('pytest','pytest'), ('allure','allure_pytest'), ('selenium','selenium'),
        ('ruamel.yaml','ruamel.yaml'), ('PIL','pillow'), ('pixelmatch','pixelmatch'),
        ('playwright','playwright')]
print(' '.join(pkg for mod, pkg in mods if importlib.util.find_spec(mod) is None))
PY
)"
  [ -z "$missing" ] && return 0
  {
    printf '\033[31m[smoke-ui]\033[0m 缺少 Python 依赖: %s\n' "$missing"
    printf '  镜像内应已预装；本地跑请执行:\n'
    printf '    %s -m pip install -r <uitest>/requirements.txt\n' "$py"
  } >&2
  return 1
}

# ---------------------------------------------------------------- 2. 仓库
repo_looks_valid() { [ -n "$1" ] && [ -f "$1/conftest.py" ] && [ -d "$1/stacks" ]; }

# 用例路径按 '::' 截断后再判存在：nodeid 形式的用例也要给出"文件不存在"而不是
# 让 pytest 抛一堆 collect 错误。
case_file_missing() {
  [ -f "$REPO/$CASE_FILE" ] && return 1
  [ -f "$CASE_FILE" ] && return 1
  return 0
}

resolve_repo() {
  [ -n "$REPO" ] && { repo_looks_valid "$REPO" && return 0; return 1; }

  local -a candidates=()
  # 跨 issue 复用的缓存目录优先：克隆一次 1.1G，不该每个 bug 重拉。
  [ -n "$CACHE_DIR" ] && candidates+=("${CACHE_DIR%/}/iidp_uitest")
  [ -n "${WORKSPACE:-}" ] && candidates+=("${WORKSPACE}/iidp_uitest")
  [ -n "${SYMPHONY_WORKSPACE_ROOT:-}" ] && candidates+=("${SYMPHONY_WORKSPACE_ROOT%/}/iidp_uitest")
  candidates+=("${PWD}/iidp_uitest" "/opt/iidp_uitest")

  local cand
  for cand in "${candidates[@]}"; do
    if repo_looks_valid "$cand"; then REPO="$cand"; return 0; fi
  done
  return 1
}

clone_repo() {
  [ "$ALLOW_CLONE" = "1" ] || die 2 "找不到 uitest 仓库，且指定了 --no-clone。请用 --repo 指定路径，或移除 --no-clone"
  local dest="${CACHE_DIR%/}/iidp_uitest"
  mkdir -p "$CACHE_DIR" || die 2 "无法创建缓存目录: $CACHE_DIR"

  # 只拉 master 一层历史：全量克隆对每个 issue 都是浪费。
  #
  # 认证方式实测过三种，只有一种能用（2026-11-17）：
  #   · `http.extraHeader=PRIVATE-TOKEN: <token>`  → 失败。PRIVATE-TOKEN 是 GitLab
  #     REST API 的头，git 的 HTTP 传输不认它，会退化成交互式问用户名，容器里直接
  #     "could not read Username ... No such device or address"。
  #   · token 拼进 URL（http://oauth2:TOKEN@host/...）→ 能用，但 token 会出现在
  #     ps 输出、git 报错和 .git/config 的 remote 里，容易泄漏。
  #   · `Authorization: Basic base64(oauth2:TOKEN)` → 能用，且 token 不落盘不进 URL。
  #     这里用第三种；base64 用 `| tr -d '\n'` 而不是 GNU 的 -w0，BSD/GNU 都兼容。
  local -a auth=()
  local token="${GITLAB_TOKEN:-${GIT_TOKEN:-}}"
  if [ -n "$token" ]; then
    local basic
    basic="$(printf 'oauth2:%s' "$token" | base64 | tr -d '\n')"
    auth=(-c "http.extraHeader=Authorization: Basic ${basic}")
  fi

  log "首次使用，浅克隆 uitest 仓库（约 1.1G，需要 1~2 分钟）: $REPO_URL"
  # git 的 stderr 先落到临时文件：失败时要把真实原因（多半是认证）告诉调用方，
  # 但原始输出里可能带凭证，所以只回显过滤后的尾部几行。
  local err_log="$CACHE_DIR/.clone-err.$$"
  if ! git ${auth[@]+"${auth[@]}"} clone --depth 1 --single-branch -b master --no-tags \
        "$REPO_URL" "$dest" >/dev/null 2>"$err_log"; then
    rm -rf "$dest"
    local reason
    reason="$(grep -vE 'Username|Password|token' "$err_log" 2>/dev/null | tail -3)"
    rm -f "$err_log"
    if [ -z "$token" ]; then
      die 2 "克隆 uitest 仓库失败：$REPO_URL
  该仓库不允许匿名读，需要凭证：设置 \$GITLAB_TOKEN（或 \$GIT_TOKEN）后重试。
  ${reason}"
    fi
    die 2 "克隆 uitest 仓库失败：$REPO_URL（已带 token）
  检查 token 是否过期、是否对该仓库有 read_repository 权限。
  ${reason}"
  fi
  rm -f "$err_log"
  REPO="$dest"
}

# ---------------------------------------------------------------- 3. 配置
# uitest 的宿主/账号来自 conf/<栈>/<产品>/config.local.ini（该文件被 .gitignore 拦截）。
# 这里按容器里的环境变量生成，等价于"本机开发者手工填一次"的那一步。
prepare_config() {
  local cfgdir="$REPO/conf/$STACK/$PRODUCT"
  mkdir -p "$cfgdir" || die 2 "无法创建配置目录: $cfgdir"

  # active.ini 是入库文件（产品线开关），改之前备份，退出时还原。
  ACTIVE_INI_BACKUP="$(mktemp)"
  CLEANUP_PATHS+=("$ACTIVE_INI_BACKUP")
  [ -f "$REPO/conf/active.ini" ] && cp "$REPO/conf/active.ini" "$ACTIVE_INI_BACKUP"
  printf '[active]\n# 由 smoke_test.sh 临时写入，退出时还原\nstack = %s\nproduct = %s\n' \
    "$STACK" "$PRODUCT" > "$REPO/conf/active.ini"

  # 口令明文落盘（框架就是这么读配置的），所以：0600 + 退出即删，不回显。
  local local_ini="$cfgdir/config.local.ini"
  CLEANUP_PATHS+=("$local_ini")
  {
    printf '# 由 smoke_test.sh 生成，退出即删；不要提交。\n'
    printf '[ENV]\nenv = %s\n\n' "$PRODUCT"
    printf '[%s]\nhost = %s\nusername = %s\npasswd = %s\n' \
      "$PRODUCT" "$HOST" "$IIDP_USER" "$IIDP_PASSWORD"
  } > "$local_ini"
  chmod 600 "$local_ini"

  # 过程动图默认关：无头模式没有 vsync 节流，长会话里 screencast 帧洪峰
  # 会把浏览器进程拖死（仓库注释记录过 TargetClosedError 实证），冒烟不需要动图。
  local browser_ini="$REPO/conf/local_browser.ini"
  CLEANUP_PATHS+=("$browser_ini")
  { printf '[browser]\nheadless = 1\nscreencast = %s\n' "$SCREENCAST"; } > "$browser_ini"

  log "环境配置: host=${HOST} 栈=${STACK} 产品线=${PRODUCT} 用户=${IIDP_USER}"
}

# ---------------------------------------------------------------- 4. 版本先行校验
read_env_version() {
  local app="$1" json="$2" ver model
  local api="${SMOKE_API_SH:-$(dirname "$0")/smoke_api.sh}"
  [ -f "$api" ] || return 1
  # 先读市场行（meta_app_store），读不到再读已安装行（meta_app）：
  # 实测两者都带 version，但少数应用（如 sie-iidp-app-store）app.json 没有 version，
  # 市场行会是 null——两个都读不到时交给调用方降级，不要假装校验过。
  for model in meta_app_store meta_app; do
    "$api" \
      --json-out "$json" \
      --model "$model" --service search --app "$RPC_APP_FOR_MARKET" \
      --args "$(jq -nc --arg name "$app" \
        '{useDisplayForModel:true,filter:[["name","=",$name]],limit:5,
          properties:["name","version","state","md5","app_market","is_delete"]}')" \
      >/dev/null 2>&1 || continue
    [ -s "$json" ] || continue
    ver="$(jq -r '(.result.data // [])[0].version // empty' "$json" 2>/dev/null)"
    [ -n "$ver" ] && { printf '%s' "$ver"; return 0; }
  done
  return 1
}

VERSION_NOTE="未校验（未指定 --expect-version）"
if [ -n "$EXPECT_VERSION" ]; then
  VER_JSON="$(mktemp)"
  CLEANUP_PATHS+=("$VER_JSON")
  [ -n "$VERSION_APP" ] || VERSION_APP="sie-iidp-de-tool"

  log "校验环境版本: 期望 ${VERSION_APP}@${EXPECT_VERSION}"
  CURRENT="$(read_env_version "$VERSION_APP" "$VER_JSON")"
  if [ -z "$CURRENT" ]; then
    # 降级而不是中断：读不到版本的原因很多（行还没生成、market 行被复位），
    # 这时按固定时长等待，并在结论里明确写"版本未经校验"，让复核的人知道风险在哪。
    warn "读不到 ${VERSION_APP} 的版本号，降级为固定等待 ${FALLBACK_WAIT}s"
    warn "若该应用本来就没有版本号，请用 --version-app 指定有版本的应用（如 sie-iidp-de-tool、sie-iidp-iam）"
    sleep "$FALLBACK_WAIT"
    VERSION_NOTE="版本未经校验（版本接口不可读，已固定等待 ${FALLBACK_WAIT}s）"
  else
    WAITED=0
    while [ "$CURRENT" != "$EXPECT_VERSION" ]; do
      if [ "$WAITED" -ge "$VERSION_TIMEOUT" ]; then
        {
          printf '\n== 冒烟结果 ==\n'
          printf '类型: %s（iidp_uitest / pytest）\n' "$LAYER"
          printf '目标: %s\n' "$HOST"
          printf '场景: %s\n' "$CASE"
          printf '结果: FAIL\n'
          printf '证据: 环境版本未就绪——期望 %s@%s，实际 %s（已等待 %ss）\n' \
            "$VERSION_APP" "$EXPECT_VERSION" "$CURRENT" "$WAITED"
          printf '说明: 未进入用例执行，避免验到旧代码得出假结论。\n'
        }
        exit 3
      fi
      log "当前版本 ${CURRENT}，等待 ${EXPECT_VERSION}（已等 ${WAITED}/${VERSION_TIMEOUT}s）"
      sleep "$POLL_INTERVAL"
      WAITED=$((WAITED + POLL_INTERVAL))
      NEW="$(read_env_version "$VERSION_APP" "$VER_JSON")"
      [ -n "$NEW" ] && CURRENT="$NEW"
    done
    log "版本已就绪: ${VERSION_APP}@${CURRENT}"
    VERSION_NOTE="已校验 ${VERSION_APP}@${CURRENT}"
  fi
fi

# ---------------------------------------------------------------- 5. 定位仓库
# 缓存仓库是跨 issue 共享的（1.1G，每个 bug 重拉不现实），多个 Agent 并发跑同一份检出
# 会互相切分支、改配置。容器里有 flock 就用它串行化，等不到就明确报错，
# 而不是让两个用例在一个工作区里互相踩。
if command -v flock >/dev/null 2>&1; then
  mkdir -p "$CACHE_DIR" 2>/dev/null || true
  exec 9>"$CACHE_DIR/.smoke.lock" || true
  if ! flock -w 300 9; then
    die 2 "等不到用例仓库的使用锁（${CACHE_DIR}/.smoke.lock，已等 300s）：可能另一个冒烟正在跑，稍后重试"
  fi
fi

resolve_repo || clone_repo
repo_looks_valid "$REPO" || die 2 "指定的仓库不像 iidp_uitest（缺 conftest.py 或 stacks/）: $REPO"
check_layer_marker
case_file_missing && die 2 "用例文件不存在: ${CASE_FILE}（仓库 ${REPO}）
  接口层用例放 testcase/api/${STACK}/test_<缺陷>_smoke.py（纯 requests，加 @pytest.mark.api）
  界面层用例放 testcase/${STACK}/${PRODUCT}/test_<缺陷>_smoke.py（用 drivers + page_api 方法）"
log "用例仓库: $REPO"

# 解释器：优先仓库自带 venv（本地开发常见），否则系统 python3（镜像内依赖装在系统解释器上）。
if [ -z "$PYTHON" ]; then
  if [ -x "$REPO/.venv/bin/python" ]; then PYTHON="$REPO/.venv/bin/python"; else PYTHON="python3"; fi
fi
command -v "$PYTHON" >/dev/null 2>&1 || die 2 "找不到 Python 解释器: $PYTHON"
check_python_deps "$PYTHON" || die 2 "Python 依赖不齐，无法跑 UI 冒烟"

# ---------------------------------------------------------------- 6. 证据目录
[ -n "$OUTPUT" ] || OUTPUT="${PWD}/smoke-test-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$OUTPUT" || die 2 "无法创建证据目录: $OUTPUT"
OUTPUT="$(cd "$OUTPUT" && pwd)"
JUNIT="$OUTPUT/junit.xml"
RUN_LOG="$OUTPUT/pytest.log"
log "证据目录: $OUTPUT"

prepare_config

# ---------------------------------------------------------------- 7. 跑用例
# `report/` 下的截图/trace/DOM 是仓库自己的产物目录（gitignored），
# 它们会跨次累积，所以开跑前先落一个时间戳标记文件，事后用 `find -newer` 只捞本次的。
# （不用 `-newermt @epoch`：BSD find 与 GNU find 对 @ 前缀的解析不一致，会静默捞不到。）
REPO_REPORT="$REPO/report"
RUN_MARKER="$OUTPUT/.run-start"
: > "$RUN_MARKER"

# ---------------------------------------------------------------- 6.5 用例自检
# 界面层用例先用 uitest 自带的 selfcheck.py 扫一遍：它能客观抓到原生 locator
# （page.locator / .fill / .text_content）、test_ 方法里没有 assert、行内按钮方法误用
# 这几类问题。这类问题照样能把用例跑到"绿"，但验的不是页面上真实发生的事，
# 所以有风险点就不放行——先修用例，不改断言。
#
# 只跑界面层：纯 API 用例不碰页面，selfcheck 的原生操作检查对它们没有意义。
# selfcheck 是仓库自带工具，随缓存仓库一起在；仓库若删掉它，降级为告警而非阻断，
# 免得框架变动直接把冒烟堵死。
run_selfcheck() {
  [ "$LAYER" = "UI" ] || return 0
  local tool="$REPO/stacks/$STACK/selfcheck.py"
  local log_file="$OUTPUT/selfcheck.log"
  if [ ! -f "$tool" ]; then
    warn "未找到 $tool，跳过用例自检（框架版本差异，不阻断）"
    return 0
  fi
  log "用例自检: stacks/$STACK/selfcheck.py $CASE_FILE"
  local rc=0
  ( cd "$REPO" && "$PYTHON" "$tool" "$CASE_FILE" ) > "$log_file" 2>&1 || rc=$?
  # selfcheck.py 用退出码表达结论：0=通过，非 0=有风险点。
  if [ "$rc" != "0" ]; then
    printf '\n== 冒烟结果 ==\n'
    printf '类型: %s（iidp_uitest / pytest）\n' "$LAYER"
    printf '目标: %s\n' "$HOST"
    printf '场景: %s\n' "$CASE"
    printf '结果: FAIL\n'
    printf '证据: 用例自检未通过（selfcheck.py 退出码 %s）\n' "$rc"
    printf '报告: %s\n' "$log_file"
    printf '说明: 未执行 pytest。自检命中项多为原生定位或缺少断言，\n'
    printf '      这类用例即使跑绿也不能证明缺陷已修好。按日志逐个修改用例后重跑。\n'
    sed -n '1,40p' "$log_file" >&2
    exit 1
  fi
  log "用例自检通过"
}

run_selfcheck

run_pytest() {
  local label="$1"
  log "${label}运行${LAYER}层用例: $CASE"
  ( cd "$REPO" && "$PYTHON" -m pytest \
      -v -s --tb=short --color=no -p no:cacheprovider \
      --junitxml="$JUNIT" \
      --alluredir="$OUTPUT/allure-results" --clean-alluredir \
      "$CASE" ${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"} ) 2>&1 | tee "$RUN_LOG"
  return "${PIPESTATUS[0]}"
}

ATTEMPT=0
RC=1
while : ; do
  ATTEMPT=$((ATTEMPT + 1))
  run_pytest "第 ${ATTEMPT}/${ATTEMPTS} 次"
  RC=$?
  [ "$RC" -eq 0 ] && break
  [ "$ATTEMPT" -ge "$ATTEMPTS" ] && break
  warn "用例未通过，重试（已尝试 ${ATTEMPT}/${ATTEMPTS}）"
done

# ---------------------------------------------------------------- 8. 解析结论
# junit 是唯一可信的结论来源：pytest 退出码会被 collect 阶段的告警干扰，
# 而 stdout 里既有 live log 又有用例自打日志，正则捞"passed"很容易捞错。
STATS="$(mktemp)"
CLEANUP_PATHS+=("$STATS")
if [ -f "$JUNIT" ]; then
  "$PYTHON" - "$JUNIT" > "$STATS" 2>/dev/null <<'PY'
import sys, xml.etree.ElementTree as ET, re
root = ET.parse(sys.argv[1]).getroot()
suites = [root] if root.tag == 'testsuite' else root.findall('testsuite')
tests = failures = errors = skipped = 0
dur = 0.0
first = ''
for s in suites:
    tests += int(s.get('tests', 0) or 0)
    failures += int(s.get('failures', 0) or 0)
    errors += int(s.get('errors', 0) or 0)
    skipped += int(s.get('skipped', 0) or 0)
    dur += float(s.get('time', 0) or 0)
    if not first:
        for tc in s.iter('testcase'):
            node = tc.find('failure')
            if node is None:
                node = tc.find('error')
            if node is not None:
                text = (node.get('message') or (node.text or '')).strip()
                first = re.sub(r'\s+', ' ', text)[:400]
                break
ok = 1 if (tests > 0 and failures == 0 and errors == 0) else 0
print('OK=%d' % ok)
print('TESTS=%d' % tests)
print('FAILURES=%d' % failures)
print('ERRORS=%d' % errors)
print('SKIPPED=%d' % skipped)
print('DURATION=%.1f' % dur)
print('FIRST=%s' % first)
PY
else
  printf 'OK=0\nTESTS=0\nFAILURES=0\nERRORS=0\nSKIPPED=0\nDURATION=0\nFIRST=%s\n' \
    "未生成 junit 报告（多半是 collect 阶段就失败了，见 pytest.log）" > "$STATS"
fi

jget() { grep -m1 "^$1=" "$STATS" 2>/dev/null | cut -d= -f2-; }
OK="$(jget OK)"; TESTS="$(jget TESTS)"; FAILURES="$(jget FAILURES)"
ERRORS="$(jget ERRORS)"; SKIPPED="$(jget SKIPPED)"; DURATION="$(jget DURATION)"; FIRST_FAIL="$(jget FIRST)"

# 把本次新增的截图收进证据目录（仓库自己的 report/screenshot 会跨次累积）
SHOT_DIR="$OUTPUT/screenshots"
if [ -d "$REPO_REPORT/screenshot" ]; then
  mkdir -p "$SHOT_DIR"
  find "$REPO_REPORT/screenshot" -maxdepth 1 -type f -newer "$RUN_MARKER" \
    -exec cp {} "$SHOT_DIR/" \; 2>/dev/null
fi
SHOT_COUNT="$(ls -1 "$SHOT_DIR" 2>/dev/null | wc -l | tr -d ' ')"

# 失败留证：trace/DOM 是仓库的取证产物，路径直接写进结论，复核者不用重跑。
TRACE_HINT=""
if [ -d "$REPO_REPORT/trace" ] && \
   [ "$(find "$REPO_REPORT/trace" -maxdepth 1 -type f -newer "$RUN_MARKER" 2>/dev/null | wc -l | tr -d ' ')" != "0" ]; then
  TRACE_HINT="$REPO_REPORT/trace"
fi

print_result() {
  local verdict="$1" evidence="$2"
  printf '\n== 冒烟结果 ==\n'
  printf '类型: %s（iidp_uitest / pytest）\n' "$LAYER"
  printf '目标: %s\n' "$HOST"
  printf '场景: %s\n' "$CASE"
  printf '结果: %s\n' "$verdict"
  printf '证据: %s\n' "$evidence"
  printf '版本: %s\n' "$VERSION_NOTE"
  printf '报告: %s\n' "$JUNIT"
  [ -d "$OUTPUT/allure-results" ] && printf '报告JSON: %s\n' "$OUTPUT/allure-results"
  [ "$SHOT_COUNT" != "0" ] && printf '截图目录: %s（%s 张）\n' "$SHOT_DIR" "$SHOT_COUNT"
  [ -n "$TRACE_HINT" ] && printf '失败trace: %s\n' "$TRACE_HINT"
  printf '运行日志: %s\n' "$RUN_LOG"
}

if [ "$OK" = "1" ]; then
  print_result "PASS" "pytest 通过：${TESTS} 条用例全绿，耗时 ${DURATION}s（junit 判定，不依赖日志正则）"
  exit 0
fi

# 失败时把最关键的一行放在证据位：复核的人只想先知道"哪一步断言炸了"。
SUMMARY="${FAILURES} 失败 / ${ERRORS} 错误 / ${TESTS} 总数，耗时 ${DURATION}s"
[ -n "$FIRST_FAIL" ] && SUMMARY="${SUMMARY}；首个失败: ${FIRST_FAIL}"
if [ "$TESTS" = "0" ]; then
  SUMMARY="用例未执行成功（collect 阶段失败？）：$FIRST_FAIL"
fi
print_result "FAIL" "$SUMMARY"
exit 1
