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
#   4. 跑完出人可读报告（report.md），可发到代码仓库的 MR 评论，并生成
#      evidence.html 供善治备注（remark_bug 只收 HTML，没有附件接口）。
#
# 用法：
#   smoke_test.sh --case testcase/api/iidp/test_xxx_smoke.py            # 接口层
#   smoke_test.sh --case ... --publish-report --mr-dir sie-snest --mr 12
#                                                                     # 报告发到改动子仓库的 MR 评论
#   smoke_test.sh --case testcase/iidp/iidp/test_xxx_smoke.py           # 界面层
#   smoke_test.sh --case ...::Test_X::test_y --expect-version 1.0.1
#
# 退出码：
#   0 PASS｜1 验收失败｜2 参数/依赖缺失｜3 版本等待超时
#   4 报告目的地被拒（结论已产出，但没落到应发的 MR，需按提示改目标重发）

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
# 1 时把 report.md + 截图提交进 uitest 当前分支：善治备注只能写 HTML 文本，
# 不能传附件，所以报告必须落到一个能贴链接的地方（与 MR 同源最省事）。
# 1 时生成发布产物：本地 report.md（人看）+ evidence.html（贴善治备注用），
# 给了 --mr-dir（或 --gl-project）与 --mr 就直接发到代码仓库的 MR 评论上。
PUBLISH=0
# 报告目的地被拒时置 1：结论已经产出，但这次冒烟不能算作已交付证据，所以非 0 退出。
PUBLISH_REFUSED=0
GL_PROJECT=""
# 改动所在的子目录。工作区根目录是聚合仓库，子仓库各自独立成库；
# 让调用方指目录、由脚本读该目录自己的 remote，比手填项目路径少一次猜错的机会。
MR_DIR=""
MR_IID=""
# GitLab 站点地址：优先 $GITLAB_URL，其次从 APP_REPO_URL 推导（代码仓库就在那台），
# 最后退回 uitest 仓库的 host——内网这几样通常同一台。
GL_BASE=""
MR_WEB_URL=""
EVIDENCE_TEXT=""
# 报告路径、MR 评论链接，以及给善治备注用的 HTML 片段。
REPORT_MD=""
REPORT_URL=""
REPORT_VERDICT=""
EVIDENCE_HTML=""
# 版本先行校验：发版是异步的（上传 → 上架 → 更新 → 前端资源生效），
# 跑早了验到的还是旧代码，会得到"改了却没变化"的假结论。
EXPECT_VERSION=""
VERSION_APP=""
VERSION_TIMEOUT=300
POLL_INTERVAL=15
FALLBACK_WAIT=60
# 善治缺陷号（SF-83221），用于把通行证写到对应工作区；resolve 硬闸门会读该文件。
ISSUE="${SYMPHONY_ISSUE_IDENTIFIER:-}"
SMOKE_SCOPE=""
SMOKE_OUT_OF_SCOPE=""
STEPS_MAP=""

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
  --publish-report         生成可发布的报告：贴到 MR 评论需要给 --mr-dir 或 --gl-project，
                           并与 --mr 配对；不给就只产出本地 report.md 与 evidence.html
  --mr-dir <子目录>        改动所在的子目录（如 sie-snest、sie-iidp-ai-agent-web），
                           从该目录的 git origin 推导项目路径。与 --gl-project 二选一，
                           同时给出时以本参数为准。推荐用它：不会顺着聚合仓库的手感填错
  --gl-project <PATH>      代码仓库的 GitLab 项目路径（如 ipaas/sie-snest 或 URL 编码形式）
  --mr <IID>               代码仓库 MR 序号；给了就把报告作为评论发到该 MR
  --issue <SF-xxxxx>       善治缺陷标识，写入 smoke/smoke-pass.json（也可用环境变量 SYMPHONY_ISSUE_IDENTIFIER）
  --scope <文本>           测试边界：本次验证覆盖什么（写入报告与 evidence.html）
  --out-of-scope <文本>    测试边界：明确不验证什么
  --steps-map <文件>       善治复现步骤与用例步骤的对应说明（markdown 文本文件）
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
    --publish-report)   PUBLISH=1; shift ;;
    --gl-project)       GL_PROJECT="${2:-}"; shift 2 ;;
    --gl-project=*)     GL_PROJECT="${1#*=}"; shift ;;
    --mr-dir)           MR_DIR="${2:-}"; shift 2 ;;
    --mr-dir=*)         MR_DIR="${1#*=}"; shift ;;
    --issue)            ISSUE="${2:-}"; shift 2 ;;
    --issue=*)          ISSUE="${1#*=}"; shift ;;
    --scope)            SMOKE_SCOPE="${2:-}"; shift 2 ;;
    --scope=*)          SMOKE_SCOPE="${1#*=}"; shift ;;
    --out-of-scope)     SMOKE_OUT_OF_SCOPE="${2:-}"; shift 2 ;;
    --out-of-scope=*)   SMOKE_OUT_OF_SCOPE="${1#*=}"; shift ;;
    --steps-map)        STEPS_MAP="${2:-}"; shift 2 ;;
    --steps-map=*)      STEPS_MAP="${1#*=}"; shift ;;
    --mr)               MR_IID="${2:-}"; shift 2 ;;
    --mr=*)             MR_IID="${1#*=}"; shift ;;
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

# GitLab 站点地址：$GITLAB_URL 优先，其次从 APP_REPO_URL 的 scheme://host 推导，
# 最后退回 uitest 仓库 host。发 MR 评论和拼链接都用它。
if [ -z "$GL_BASE" ]; then
  if [ -n "${GITLAB_URL:-}" ]; then
    GL_BASE="${GITLAB_URL%/}"
  elif [ -n "${APP_REPO_URL:-}" ]; then
    GL_BASE="$(printf '%s' "$APP_REPO_URL" | sed -E 's#^([A-Za-z][A-Za-z0-9+.-]*)://([^/]+).*#\1://\2#')"
  else
    GL_BASE="$(printf '%s' "$REPO_URL" | sed -E 's#^([A-Za-z][A-Za-z0-9+.-]*)://([^/]+).*#\1://\2#')"
  fi
fi
# 从子目录的 origin 推导 GitLab 项目路径（sie-snest -> ipaas/sie-snest）。
# 兼容 http(s)://host/group/proj.git 与 git@host:group/proj.git 两种写法。
project_from_dir() {
  local dir="$1" url
  [ -d "$dir" ] || return 1
  url="$(git -C "$dir" -c http.proxy= -c https.proxy= remote get-url origin 2>/dev/null)" || return 1
  [ -n "$url" ] || return 1
  printf '%s' "$url" \
    | sed -E 's#^[A-Za-z][A-Za-z0-9+.-]*://[^/]+/##; s#^[^@/]+@[^:]+:##; s#\.git$##; s#/+$##'
}

# --mr-dir 优先：调用方指了改动所在的子目录，就用该目录自己的 remote，
# 不再信任手填的 --gl-project（手填时最容易顺着 cwd 填成聚合仓库）。
if [ -n "$MR_DIR" ]; then
  DERIVED_PROJECT="$(project_from_dir "$MR_DIR" || true)"
  if [ -z "$DERIVED_PROJECT" ]; then
    die 2 "--mr-dir 推导不出项目路径：${MR_DIR}
  该目录必须存在、且本身是独立 git 仓库（有 origin 远端）。
  若是聚合仓库里尚未初始化的子模块，先执行 git submodule update --init ${MR_DIR}。"
  fi
  if [ -n "$GL_PROJECT" ]; then
    warn "--mr-dir 与 --gl-project 同时给出，以 --mr-dir 推导结果为准：忽略 ${GL_PROJECT}，采用 ${DERIVED_PROJECT}"
  fi
  GL_PROJECT="$DERIVED_PROJECT"
fi

# 项目路径去掉可能带的 .git 与首尾斜杠，后面按 path 编码。
GL_PROJECT="${GL_PROJECT%.git}"
GL_PROJECT="${GL_PROJECT#/}"
GL_PROJECT="${GL_PROJECT%/}"

# 用例仓库的项目路径（从 REPO_URL 推导，如 xuchunxia/iidp_uitest）。
# 用来挡一个很自然的错误：用例在 uitest，顺手就把 --gl-project 也填成 uitest。
# 报告必须贴着**代码**走——发到用例仓库，评审看 diff 时根本看不到它。
UITEST_PROJECT="$(printf '%s' "$REPO_URL" | sed -E 's#^[A-Za-z][A-Za-z0-9+.-]*://[^/]+/##; s#\.git$##; s#/+$##')"
if [ -n "$GL_PROJECT" ] && [ "$GL_PROJECT" = "$UITEST_PROJECT" ]; then
  die 2 "报告目标指向了用例仓库 ${UITEST_PROJECT}。
  报告要发到**本次修复代码所在的子仓库**（如 ipaas/sie-snest、mijiuye/iidp-aios），
  否则评审看该仓库的 MR 时找不到冒烟证据。"
fi

[ -n "$MR_IID" ] && [ -n "$GL_PROJECT" ] \
  && MR_WEB_URL="${GL_BASE}/${GL_PROJECT}/merge_requests/${MR_IID}"

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

# 发布的前置检查放在跑用例之前：参数不全时应该立刻失败，
# 而不是让人等完几十秒的界面用例才被通知参数写错了。
preflight_publish() {
  [ "$PUBLISH" = "1" ] || return 0
  if [ -n "$MR_IID" ] || [ -n "$GL_PROJECT" ]; then
    [ -n "$MR_IID" ] && [ -n "$GL_PROJECT" ] \
      || die 2 "--mr-dir/--gl-project 与 --mr 必须成对给出（只给一个无法定位评论目标）"
    case "$MR_IID" in
      ''|*[!0-9]*) die 2 "--mr 需要 MR 序号（纯数字），收到: $MR_IID" ;;
    esac
    [ -n "${GITLAB_TOKEN:-${GIT_TOKEN:-}}" ] \
      || die 2 "发 MR 评论需要 \$GITLAB_TOKEN（或 \$GIT_TOKEN）"
  else
    log "未给 --mr-dir/--gl-project 与 --mr：只生成本地报告与 evidence.html，不发送到 MR"
  fi
}

preflight_publish

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
  [ -n "${REPORT_MD:-}" ] && printf '冒烟报告: %s\n' "$REPORT_MD"
  [ -n "${EVIDENCE_HTML:-}" ] && printf '善治备注: %s（内容直接作为 shanzhi_remark_bug 的 comment）\n' "$EVIDENCE_HTML"
  [ -n "${REPORT_URL:-}" ] && printf 'MR评论: %s\n' "$REPORT_URL"
}

# ------------------------------------------------------- 9. 生成人可读报告
# junit 是给机器看的（CI 消费），善治备注里贴的必须是给人看的：结论、场景、版本、
# 每一步的耗时、失败原文、截图。所以另出一份 report.md。
#
# 用 Markdown 而不是 HTML：GitLab 的 blob 页会把 .html 当源码展示（带 nosniff），
# 打开看到的是标签；.md 则直接渲染，图片按相对路径内嵌，评审点开就是图文。
write_report() {
  local verdict="$1" evidence="$2"
  local img_dir="$OUTPUT/img"
  mkdir -p "$img_dir"
  # 截图重排成 01-xx.png：markdown 里的顺序要稳定，不能依赖文件系统返回顺序。
  if [ -d "$SHOT_DIR" ]; then
    local n=0 f
    for f in "$SHOT_DIR"/*; do
      [ -f "$f" ] || continue
      n=$((n + 1))
      cp "$f" "$img_dir/$(printf '%02d' "$n")-$(basename "$f")" 2>/dev/null || true
    done
  fi
  REPORT_MD="$OUTPUT/report.md"
  SMOKE_VERDICT="$verdict" SMOKE_EVIDENCE="$evidence" \
  SMOKE_LAYER="$LAYER" SMOKE_HOST="$HOST" SMOKE_CASE="$CASE" \
  SMOKE_VERSION="$VERSION_NOTE" SMOKE_JUNIT="$JUNIT" SMOKE_RUNLOG="$RUN_LOG" \
  SMOKE_IMG_DIR="$img_dir" SMOKE_STACK="$STACK" SMOKE_PRODUCT="$PRODUCT" \
  SMOKE_TESTS="$TESTS" SMOKE_DURATION="$DURATION" \
  SMOKE_SCOPE_TEXT="$SMOKE_SCOPE" SMOKE_OOS_TEXT="$SMOKE_OUT_OF_SCOPE" \
  SMOKE_STEPS_MAP="$STEPS_MAP" \
  "$PYTHON" - "$REPORT_MD" <<'PY' || warn "生成 report.md 失败（不影响冒烟结论）"
import html
import os
import re
import xml.etree.ElementTree as ET

env = os.environ
out = os.sys.argv[1]
verdict = env.get("SMOKE_VERDICT", "")
evidence = env.get("SMOKE_EVIDENCE", "")
img_dir = env.get("SMOKE_IMG_DIR", "")
junit = env.get("SMOKE_JUNIT", "")
runlog = env.get("SMOKE_RUNLOG", "")

lines = []
add = lines.append
add("# 冒烟报告：%s" % env.get("SMOKE_CASE", ""))
add("")
add("| 项 | 值 |")
add("|---|---|")
add("| 结论 | **%s** |" % verdict)
add("| 类型 | %s 层（iidp_uitest / pytest） |" % env.get("SMOKE_LAYER", ""))
add("| 目标环境 | %s |" % env.get("SMOKE_HOST", ""))
add("| 版本校验 | %s |" % env.get("SMOKE_VERSION", ""))
add("| 用例 | `%s` |" % env.get("SMOKE_CASE", ""))
add("| 耗时 | %ss |" % env.get("SMOKE_DURATION", ""))
add("")
add("证据：%s" % evidence)
add("")

# 逐条用例结果：评审要看的是"验了哪几条断言"，不是一行 PASS。
rows = []
if junit and os.path.exists(junit):
    try:
        root = ET.parse(junit).getroot()
        suites = [root] if root.tag == "testsuite" else root.findall("testsuite")
        for s in suites:
            for tc in s.iter("testcase"):
                status = "通过"
                detail = ""
                for tag in ("failure", "error", "skipped"):
                    node = tc.find(tag)
                    if node is not None:
                        status = {"failure": "失败", "error": "报错", "skipped": "跳过"}[tag]
                        raw = (node.get("message") or node.text or "").strip()
                        detail = re.sub(r"\s+", " ", raw)[:300]
                        break
                rows.append((tc.get("name", ""), tc.get("time", ""), status, detail))
    except Exception as exc:  # 报告不能因为解析失败就整个没
        add("> junit 解析失败：%s" % exc)
        add("")

if rows:
    add("## 用例明细")
    add("")
    add("| 用例 | 耗时 | 结果 | 失败信息 |")
    add("|---|---|---|---|")
    for name, t, status, detail in rows:
        add("| `%s` | %ss | %s | %s |" % (name, t, status, detail.replace("|", "\\|")))
    add("")

scope = os.environ.get("SMOKE_SCOPE_TEXT", "").strip()
oos = os.environ.get("SMOKE_OOS_TEXT", "").strip()
steps_map = os.environ.get("SMOKE_STEPS_MAP", "").strip()
if scope or oos or steps_map:
    add("## 测试边界与步骤")
    add("")
if scope:
    add("- **测试边界**（验证）：%s" % scope)
if oos:
    add("- **测试边界**（不验证）：%s" % oos)
if steps_map:
    add("- **步骤对应**：")
    if os.path.isfile(steps_map):
        with open(steps_map, encoding="utf-8") as fh:
            add("")
            add(fh.read().strip())
    else:
        add("  %s" % steps_map)
    add("")
elif scope or oos:
    add("")

# 截图：相对路径，发布时 img/ 一起提交，GitLab 里直接渲染。
if img_dir and os.path.isdir(img_dir):
    shots = sorted(f for f in os.listdir(img_dir) if f.lower().endswith((".png", ".jpg", ".jpeg", ".gif")))
    if shots:
        add("## 截图")
        add("")
        for f in shots:
            add("### %s" % f)
            add("")
            add("![%s](img/%s)" % (f, f))
            add("")

# 失败时贴日志尾部：评审不用重跑就能看到断言原文。
if verdict != "PASS" and runlog and os.path.exists(runlog):
    try:
        with open(runlog, encoding="utf-8", errors="replace") as fh:
            tail = "".join(fh.readlines()[-120:])
        add("## 运行日志（尾部 120 行）")
        add("")
        add("```")
        add(tail.rstrip())
        add("```")
        add("")
    except Exception:
        pass

add("---")
add("")
add("由 `smoke_test.sh` 自动生成，用例来自 iidp_uitest 仓库，可复跑同一命令。")

with open(out, "w", encoding="utf-8") as fh:
    fh.write("\n".join(lines) + "\n")
PY
  [ -f "$REPORT_MD" ] || REPORT_MD=""
}

# ------------------------------------------------ 10. 发布：MR 评论 + 善治备注
# 报告的去处不是 uitest 仓库：验证逻辑（用例）在 uitest，验证结果应该贴着**代码**
# 走——也就是修复那个 bug 的 MR。评审看 diff 的地方就能看到这次冒烟到底验了什么。
#
# 善治的 remark_bug 只收 HTML 文本、没有附件接口，所以另出一份 evidence.html：
# 里面有结论、版本、证据和 MR 评论链接，直接作为 comment 传给 shanzhi_remark_bug。

# GitLab 项目路径要按 path 编码；入参可能是 a/b，也可能是已编码的 a%2Fb，
# 先 unquote 再 quote，两种形态都能接受。
gl_project_enc() {
  "$PYTHON" -c 'import sys,urllib.parse;print(urllib.parse.quote(urllib.parse.unquote(sys.argv[1]),safe=""))' "$1"
}

gl_api() { printf '%s/api/v4%s' "$GL_BASE" "$1"; }

# 判断目标 MR 的改动是「只推进子模块指针」还是含真实代码改动。
# 依据：聚合仓库的指针 MR 里每条 diff 都只有 -/+ Subproject commit 两行，
# 这类 MR 收冒烟报告没有意义——评审要看的是子仓库那份 diff。
# 输出（第一列）：pointer <子模块路径> / code <改动文件> / unknown。
# unknown 表示读不到或解析不了：调用方降级放行，不能因为校验不可用就卡住交付。
mr_diff_kind() {
  local resp enc
  enc="$(gl_project_enc "$GL_PROJECT")"
  resp="$(curl -sS --max-time 30 --noproxy '*' \
      -H "PRIVATE-TOKEN: ${GL_TOKEN}" \
      "$(gl_api "/projects/${enc}/merge_requests/${MR_IID}/changes")" 2>/dev/null || true)"
  [ -n "$resp" ] || { printf 'unknown\t'; return; }
  printf '%s' "$resp" | "$PYTHON" -c '
import json, re, sys

try:
    data = json.loads(sys.stdin.read())
except ValueError:
    print("unknown\t"); raise SystemExit

changes = data.get("changes")
if not isinstance(changes, list) or not changes:
    print("unknown\t"); raise SystemExit

pointer = re.compile(r"^[+-]Subproject commit [0-9a-fA-F]+\s*$")
real, subs = [], []
for ch in changes:
    path = ch.get("new_path") or ch.get("old_path") or "?"
    dirty = False
    for line in (ch.get("diff") or "").splitlines():
        # 空行、hunk 头、以及 diff 尾部的换行提示都不算改动内容。
        if not line.strip() or line.startswith("@@") or line.startswith("\\ No newline"):
            continue
        if pointer.match(line):
            continue
        dirty = True
        break
    (real if dirty else subs).append(path)

if real:
    print("code\t" + ",".join(real))
elif subs:
    print("pointer\t" + ",".join(subs))
else:
    print("unknown\t")
'
}

# 把截图上传到项目，换成 GitLab 的 markdown 图片引用。
# 不能直接用本地路径或 raw 链接：raw 需要登录态，评论里会显示成破图。
publish_images() {
  local dir="$1" out="$2" f
  : > "$out"
  [ -d "$dir" ] || return 0
  for f in "$dir"/*; do
    [ -f "$f" ] || continue
    case "${f##*.}" in
      png|PNG|jpg|JPG|jpeg|JPEG|gif|GIF) ;;
      *) continue ;;
    esac
    local resp
    resp="$(curl -sS --max-time 60 --request POST \
        -H "PRIVATE-TOKEN: ${GL_TOKEN}" \
        --form "file=@${f}" \
        "$(gl_api "/projects/${GL_PROJECT_ENC}/uploads")" 2>/dev/null || true)"
    local md
    md="$(printf '%s' "$resp" | sed -n 's/.*"markdown":"\([^"]*\)".*/\1/p')"
    if [ -z "$md" ]; then
      warn "截图上传失败（$(basename "$f")），评论里会缺这张图"
      continue
    fi
    # JSON 里的 markdown 是转义过的，反转义 \" 和 \/
    md="$(printf '%s' "$md" | sed -e 's/\\"/"/g' -e 's#\\/#/#g')"
    printf '%s\n\n' "$md" >> "$out"
  done
}

publish_report() {
  [ -n "$REPORT_MD" ] || return 0
  GL_TOKEN="${GITLAB_TOKEN:-${GIT_TOKEN:-}}"

  # 没给 MR 时，发布就到此为止：报告留在本地，由 Agent 自己贴到 MR / 善治。
  [ -n "$MR_IID" ] || return 0

  local body_file="$OUTPUT/mr-comment.md"
  GL_PROJECT_ENC="$(gl_project_enc "$GL_PROJECT")"

  # 目的地核对：报告的落点必须是承载真实代码改动的 MR。
  # 放在这一段而不是更早，是因为此时用例已经跑完、report.md 已经落盘——
  # 就算目的地判错，本次冒烟的证据也不能跟着丢。
  local verdict kind paths
  verdict="$(mr_diff_kind)"
  kind="${verdict%%$'\t'*}"
  paths="${verdict#*$'\t'}"
  case "$kind" in
    pointer)
      PUBLISH_REFUSED=1
      warn "拒绝发布：MR !${MR_IID}（${GL_PROJECT}）只推进了子模块指针，没有代码改动。"
      warn "该指针指向：${paths}"
      warn "报告应发到承载改动的那份 MR，用子目录推导目标即可："
      warn "  --mr-dir ${paths%%,*} --mr <该子仓库的 MR 序号>"
      warn "本地报告仍已产出：${REPORT_MD}"
      return 0
      ;;
    code)
      log "目的地核对通过：MR !${MR_IID} 含真实代码改动（${paths}）"
      ;;
    *)
      warn "读不到 MR !${MR_IID} 的改动内容（权限/接口/网络），跳过目的地核对，仍按给定目标发布"
      ;;
  esac

  local img_md="$OUTPUT/.img-markdown"
  publish_images "$OUTPUT/img" "$img_md"

  # 评论正文就是报告本身，但图片要换成上传后的 markdown 引用。
  "$PYTHON" - "$REPORT_MD" "$body_file" "$img_md" <<'PY' 2>/dev/null || cp "$REPORT_MD" "$body_file"
import os
import sys

src, dst, img = sys.argv[1], sys.argv[2], sys.argv[3]
with open(src, encoding="utf-8") as fh:
    text = fh.read()
imgs = ""
if os.path.exists(img):
    with open(img, encoding="utf-8") as fh:
        imgs = fh.read().strip()
if imgs:
    # 本地报告里的图片是 img/xx.png，评论里换成 GitLab 上传后的地址。
    head = text.split("## 截图")[0].rstrip()
    tail = ""
    if "## 运行日志" in text:
        tail = "## 运行日志" + text.split("## 运行日志", 1)[1]
    text = head + "\n\n## 截图\n\n" + imgs + "\n" + (("\n" + tail) if tail else "")
with open(dst, "w", encoding="utf-8") as fh:
    fh.write(text)
PY

  local resp note_id
  resp="$(curl -sS --max-time 90 --request POST \
      -H "PRIVATE-TOKEN: ${GL_TOKEN}" \
      --data-urlencode "body@${body_file}" \
      "$(gl_api "/projects/${GL_PROJECT_ENC}/merge_requests/${MR_IID}/notes")" 2>/dev/null || true)"
  # 取第一个 "id"：note 响应里 id 在首位，但后面还有 author_id / award 的 id，
  # 用 sed 的贪婪 .* 会吃到最后一个，导致链接指错评论。
  note_id="$(printf '%s' "$resp" | grep -o '"id":[0-9]\{1,\}' | head -1 | cut -d: -f2)"
  if [ -z "$note_id" ]; then
    warn "发 MR 评论失败，报告只在本地：$REPORT_MD"
    warn "接口返回：$(printf '%s' "$resp" | head -c 300)"
    return 0
  fi

  # GitLab 11.3 用旧式路由（没有 /- 前缀），分支/MR 链接都按这个拼。
  local web
  web="$(printf '%s' "$GL_BASE")"
  REPORT_URL="${web}/${GL_PROJECT}/merge_requests/${MR_IID}#note_${note_id}"
  log "报告已发到 MR !${MR_IID}：${REPORT_URL}"
}

# 善治备注用的 HTML 片段。remark_bug 只收 HTML 文本、没有附件接口，
# 所以这里给一段可直接当 comment 传进去的内容，含结论、版本、证据与 MR 链接。
# 生成时机放在 MR 评论之后：这样 HTML 里能带上评论链接。
write_evidence_html() {
  EVIDENCE_HTML="$OUTPUT/evidence.html"
  SMOKE_VERDICT="$REPORT_VERDICT" SMOKE_LAYER="$LAYER" SMOKE_HOST="$HOST" \
  SMOKE_CASE="$CASE" SMOKE_VERSION="$VERSION_NOTE" SMOKE_TESTS="$TESTS" \
  SMOKE_DURATION="$DURATION" SMOKE_EVIDENCE="$EVIDENCE_TEXT" \
  SMOKE_URL="${REPORT_URL:-}" SMOKE_MR_URL="${MR_WEB_URL:-}" \
  local uitest_ref=""
  if [ -n "${REPO:-}" ] && [ -d "$REPO/.git" ]; then
    uitest_ref="$("$PYTHON" -c '
import subprocess, os, json
repo = os.environ.get("R", "")
try:
    b = subprocess.check_output(["git","-C",repo,"rev-parse","--abbrev-ref","HEAD"], text=True).strip()
    s = subprocess.check_output(["git","-C",repo,"rev-parse","--short","HEAD"], text=True).strip()
    print(json.dumps({"branch": b, "sha": s}, ensure_ascii=False))
except Exception:
    print("{}")
' R="$REPO" 2>/dev/null || echo '{}')"
  fi
  SMOKE_IMAGES="$SHOT_COUNT" SMOKE_SCOPE="$SMOKE_SCOPE" SMOKE_OOS="$SMOKE_OUT_OF_SCOPE" \
  SMOKE_UITEST_REF="$uitest_ref" \
  "$PYTHON" - "$EVIDENCE_HTML" <<'PY' 2>/dev/null || warn "生成 evidence.html 失败"
import html
import os

env = os.environ
verdict = env.get("SMOKE_VERDICT", "")
color = "#1f883d" if verdict == "PASS" else "#cf222e"

parts = []
parts.append("<p><b>冒烟结果：<span style=\"color:%s\">%s</span></b>（%s 层 · iidp_uitest / pytest）</p>"
             % (color, html.escape(verdict), html.escape(env.get("SMOKE_LAYER", ""))))
parts.append("<ul>")
parts.append("<li>目标环境：%s</li>" % html.escape(env.get("SMOKE_HOST", "")))
parts.append("<li>用例：<code>%s</code></li>" % html.escape(env.get("SMOKE_CASE", "")))
uitest_raw = env.get("SMOKE_UITEST_REF", "").strip()
if uitest_raw and uitest_raw != "{}":
    try:
        import json
        ref = json.loads(uitest_raw)
        if ref.get("branch"):
            parts.append("<li>iidp_uitest：<code>%s</code> @ <code>%s</code></li>"
                         % (html.escape(ref.get("branch", "")), html.escape(ref.get("sha", ""))))
    except Exception:
        pass
parts.append("<li>版本校验：%s</li>" % html.escape(env.get("SMOKE_VERSION", "")))
parts.append("<li>用例数/耗时：%s 条 / %ss</li>" % (html.escape(env.get("SMOKE_TESTS", "")),
                                                html.escape(env.get("SMOKE_DURATION", ""))))
parts.append("<li>证据：%s</li>" % html.escape(env.get("SMOKE_EVIDENCE", "")))
scope = env.get("SMOKE_SCOPE", "")
oos = env.get("SMOKE_OOS", "")
if scope:
    parts.append("<li><b>测试边界</b>（验证）：%s</li>" % html.escape(scope))
if oos:
    parts.append("<li><b>测试边界</b>（不验证）：%s</li>" % html.escape(oos))
parts.append("<li><b>步骤对应</b>：见报告正文「测试边界与步骤」或 --steps-map 文件</li>")
url = env.get("SMOKE_URL", "")
mr = env.get("SMOKE_MR_URL", "")
if url:
    parts.append("<li>冒烟报告：<a href=\"%s\">MR 评论里的完整报告（含截图）</a></li>"
                 % html.escape(url))
elif env.get("SMOKE_IMAGES", "0") != "0":
    # 没有评论链接就明说截图在这次运行的证据目录里，别让人以为没留证。
    parts.append("<li>说明：截图共 %s 张，随本次冒烟的证据目录留档</li>"
                 % html.escape(env.get("SMOKE_IMAGES", "")))
if mr:
    parts.append("<li>MR：<a href=\"%s\">%s</a></li>" % (html.escape(mr), html.escape(mr)))
parts.append("</ul>")
with open(os.sys.argv[1], "w", encoding="utf-8") as fh:
    fh.write("\n".join(parts) + "\n")
PY
}

smoke_workspace_root() {
  local id="${ISSUE:-}"
  if [ -z "$id" ]; then
    id="$(basename "$(pwd)")"
    case "$id" in SF-*|M*) : ;; *) id="" ;; esac
  fi
  local root="${SYMPHONY_WORKSPACE_ROOT:-}"
  if [ -n "$id" ] && [ -n "$root" ] && [ -d "$root/$id" ]; then
    printf '%s' "$root/$id"
  elif [ -d "$(pwd)/.git" ]; then
    pwd
  elif [ -n "$root" ] && [ -n "$id" ]; then
    printf '%s' "$root/$id"
  else
    pwd
  fi
}

write_smoke_fail_credential() {
  local ws dir
  ws="$(smoke_workspace_root)"
  dir="$ws/smoke"
  mkdir -p "$dir" || return 0
  id="${ISSUE:-$(basename "$ws")}"
  "$PYTHON" - "$dir/smoke-fail.json" <<PY || return 0
import json, os, datetime
out = {
    "schema_version": 1,
    "issue_identifier": """${id}""",
    "verdict": "FAIL",
    "layer": """${LAYER}""",
    "case": """${CASE}""",
    "finished_at": datetime.datetime.now(datetime.timezone(datetime.timedelta(hours=8))).isoformat(),
    "report_md": """${REPORT_MD:-}""",
}
with open(os.sys.argv[1], "w", encoding="utf-8") as fh:
    json.dump(out, fh, ensure_ascii=False, indent=2)
PY
}

write_smoke_pass_credential() {
  [ "$REPORT_VERDICT" = "PASS" ] || return 0
  [ "$PUBLISH" = "1" ] || { warn "未带 --publish-report，不写 PASS 通行证（resolve 硬闸门会拒绝）"; return 0; }
  [ -n "$REPORT_URL" ] || { warn "无 MR 报告链接，不写 PASS 通行证"; return 0; }
  [ "$PUBLISH_REFUSED" = "1" ] && return 0
  local ws dir id uitest_dir
  ws="$(smoke_workspace_root)"
  dir="$ws/smoke"
  mkdir -p "$dir" || return 0
  id="${ISSUE:-$(basename "$ws")}"
  uitest_dir="${REPO:-}"
  UITEST_DIR="$uitest_dir" ISSUE_ID="$id" LAYER_NAME="$LAYER" CASE_NAME="$CASE" \
  HOST_NAME="$HOST" VERSION_NOTE_TEXT="$VERSION_NOTE" REPORT_URL_TEXT="$REPORT_URL" \
  REPORT_MD_PATH="$REPORT_MD" SMOKE_SCOPE_TEXT="$SMOKE_SCOPE" SMOKE_OOS_TEXT="$SMOKE_OUT_OF_SCOPE" \
  "$PYTHON" - "$dir/smoke-pass.json" <<'PY' || warn "写入 smoke-pass.json 失败"
import json, os, subprocess, datetime

def uitest_ref(repo):
    if not repo or not os.path.isdir(os.path.join(repo, ".git")):
        return {}
    try:
        branch = subprocess.check_output(
            ["git", "-C", repo, "rev-parse", "--abbrev-ref", "HEAD"], text=True
        ).strip()
        sha = subprocess.check_output(
            ["git", "-C", repo, "rev-parse", "--short", "HEAD"], text=True
        ).strip()
        return {"branch": branch, "sha": sha}
    except Exception:
        return {}

path = os.sys.argv[1]
env = os.environ
entry = {
    "verdict": "PASS",
    "layer": env.get("LAYER_NAME", ""),
    "case": env.get("CASE_NAME", ""),
    "host": env.get("HOST_NAME", ""),
    "version_note": env.get("VERSION_NOTE_TEXT", ""),
    "report_url": env.get("REPORT_URL_TEXT", ""),
    "report_md": env.get("REPORT_MD_PATH", ""),
    "scope": env.get("SMOKE_SCOPE_TEXT", ""),
    "out_of_scope": env.get("SMOKE_OOS_TEXT", ""),
    "issue_identifier": env.get("ISSUE_ID", ""),
    "finished_at": datetime.datetime.now(datetime.timezone(datetime.timedelta(hours=8))).isoformat(),
    "runner": "smoke_test.sh",
    "uitest_ref": uitest_ref(env.get("UITEST_DIR", "")),
}
doc = {"schema_version": 1, "issue_identifier": env.get("ISSUE_ID", ""), "passes": []}
if os.path.isfile(path):
    try:
        with open(path, encoding="utf-8") as fh:
            doc = json.load(fh)
    except Exception:
        doc = {"schema_version": 1, "issue_identifier": env.get("ISSUE_ID", ""), "passes": []}
passes = [p for p in doc.get("passes", []) if p.get("layer") != entry["layer"]]
passes.append(entry)
doc["passes"] = passes
doc["issue_identifier"] = env.get("ISSUE_ID", doc.get("issue_identifier", ""))
# 最新一层作为主字段，供简易读取
doc.update({k: entry[k] for k in ("verdict", "layer", "case", "report_url", "report_md") if entry.get(k)})
doc["report_url"] = entry["report_url"]
with open(path, "w", encoding="utf-8") as fh:
    json.dump(doc, fh, ensure_ascii=False, indent=2)
print(path)
PY
  log "冒烟通行证已写入：$dir/smoke-pass.json"
}

# 收尾：先出报告（人看），再按需发布（MR 评论 / 善治备注），最后打印五字段。
finish() {
  local verdict="$1" evidence="$2"
  REPORT_VERDICT="$verdict"
  EVIDENCE_TEXT="$evidence"
  write_report "$verdict" "$evidence"
  if [ "$PUBLISH" = "1" ]; then
    publish_report
    write_evidence_html
  fi
  print_result "$verdict" "$evidence"
  if [ "$verdict" = "PASS" ]; then
    write_smoke_pass_credential
  else
    write_smoke_fail_credential
  fi
  # 目的地被拒：报告没落到该落的地方，本轮不能当作已交付证据。
  # 用独立退出码，好和"用例失败(1)""版本超时(3)"区分开。
  [ "$PUBLISH_REFUSED" = "1" ] && exit 4
  return 0
}

if [ "$OK" = "1" ]; then
  finish "PASS" "pytest 通过：${TESTS} 条用例全绿，耗时 ${DURATION}s（junit 判定，不依赖日志正则）"
  exit 0
fi

# 失败时把最关键的一行放在证据位：复核的人只想先知道"哪一步断言炸了"。
SUMMARY="${FAILURES} 失败 / ${ERRORS} 错误 / ${TESTS} 总数，耗时 ${DURATION}s"
[ -n "$FIRST_FAIL" ] && SUMMARY="${SUMMARY}；首个失败: ${FIRST_FAIL}"
if [ "$TESTS" = "0" ]; then
  SUMMARY="用例未执行成功（collect 阶段失败？）：$FIRST_FAIL"
fi
finish "FAIL" "$SUMMARY"
exit 1
