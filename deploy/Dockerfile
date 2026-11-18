# Symphony 一体化部署镜像：把 Symphony 本体和全部 Agent CLI 打进同一个镜像。
#
# 镜像内含：
#   * Symphony（Elixir escript，编译期把 Phoenix LiveView 看板和静态资源一起打包）
#   * Node.js 22（codex / claude / zcode 运行时）
#   * codex CLI（@openai/codex）
#   * Claude Code CLI（@anthropic-ai/claude-code，命令名 claude）
#   * Cursor CLI（cursor-agent）
#   * ZCode CLI（命令名 zcode）
#   * JDK 21 + Maven + git + ssh + ripgrep 等 Agent 干活必需的工具
#
# 构建上下文是仓库根目录（不是 elixir/），这样部署脚本和工作流文件也能一起用：
#   docker build -f deploy/Dockerfile -t symphony-agent:latest .
#
# 可选构建参数见下方 ARG 段，全部可以通过 docker compose 的 .env 覆盖。

ARG ELIXIR_IMAGE=hexpm/elixir:1.19.5-erlang-28.2-debian-bookworm-20260824-slim
ARG NODE_IMAGE=node:22-bookworm-slim
ARG MAVEN_IMAGE=maven:3.9-eclipse-temurin-21

# COPY --from 不支持变量展开，所以把外部镜像先声明成具名阶段，后面按名字引用。
FROM ${NODE_IMAGE} AS node_runtime
FROM ${MAVEN_IMAGE} AS maven_tools

# ---------------------------------------------------------------------------
# 阶段 1：编译 Symphony escript
# ---------------------------------------------------------------------------
# 这个阶段固定跑在「构建机」架构上（--platform=$BUILDPLATFORM），不是目标架构。
#
# 原因：Elixir/Erlang 在 QEMU 用户态模拟下起不来——编译 escript 时会崩在
# prim_tty 的 NIF（nif_error undef），导致跨平台构建直接失败。
# 而 escript 只是把 BEAM 字节码打包成单个可执行文件，本身与 CPU 架构无关，
# 所以用本机原生架构编译、在运行阶段用目标架构即可，产物完全等价。
ARG BUILDPLATFORM
FROM --platform=${BUILDPLATFORM} ${ELIXIR_IMAGE} AS builder

ENV MIX_ENV=prod \
    LANG=C.UTF-8

RUN apt-get -o Acquire::Retries=5 update \
 && apt-get install -y --no-install-recommends \
      build-essential \
      ca-certificates \
      git \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /src

RUN mix local.hex --force && mix local.rebar --force

# 先只拷依赖清单，利用镜像层缓存：业务代码改动不会重新拉依赖。
COPY elixir/mix.exs elixir/mix.lock ./
RUN mix deps.get --only prod

COPY elixir/ ./

# escript.build 会把 lib/ 与 priv/ 一起塞进单个可执行文件，
# 因此看板 CSS / favicon 不需要额外挂载静态资源目录。
RUN mix deps.compile \
 && mix escript.build \
 && test -x bin/symphony

# ---------------------------------------------------------------------------
# 阶段 2：运行时镜像
# ---------------------------------------------------------------------------
FROM ${ELIXIR_IMAGE} AS runtime

ARG NPM_REGISTRY=https://mirrors.huaweicloud.com/repository/npm
ARG CODEX_VERSION=latest
ARG CLAUDE_CODE_VERSION=latest
ARG ZCODE_CLI_PKG=https://github.com/xhqing/zcode-cli/releases/download/v3.8.1-32/zcode-cli-3.8.1-32.tgz
ARG CURSOR_INSTALL_URL=https://cursor.com/install
# 善治 Bug 协作 MCP 服务（独立仓库，stdio 传输）。置空跳过安装。
ARG SHANZHI_MCP_REPO=http://192.168.175.55:9888/mijiuye/shanzhi_mcp.git
ARG SHANZHI_MCP_REF=master
ARG APP_UID=1000
ARG APP_GID=1000
ARG APP_USER=symphony

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    TZ=Asia/Shanghai \
    HOME=/home/${APP_USER} \
    PATH=/home/${APP_USER}/.local/bin:/usr/local/bin:/usr/local/sbin:/usr/sbin:/usr/bin:/sbin:/bin \
    JAVA_HOME=/opt/java/openjdk \
    SYMPHONY_PORT=4567 \
    WORKFLOW_PATH=/app/WORKFLOW.md \
    SYMPHONY_WORKSPACE_ROOT=/data/workspaces \
    LOGS_ROOT=/data

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# 基础工具链。git / ssh 是 Agent 拉取与推送代码的前提；
# gosu 用来在 entrypoint 里从 root 降权到普通用户（Claude Code 的
# --dangerously-skip-permissions 不允许以 root 运行）。
RUN apt-get -o Acquire::Retries=5 update \
 && apt-get install -y --no-install-recommends \
      bash \
      ca-certificates \
      curl \
      git \
      gosu \
      jq \
      less \
      openssh-client \
      procps \
      python3 \
      python3-venv \
      ripgrep \
      tar \
      tini \
      unzip \
      xz-utils \
 && rm -rf /var/lib/apt/lists/*

# UI 冒烟（无头 chromium）依赖。单独一段是为了让上面那层基础工具链保持可复用缓存。
# 下面的 16 个 lib* 是 chromium 运行所需的系统库，按 ldd 实测得出（容器里原本一个都不在）；
# 加上 2 个字体包共 18 个，一个都不能少——缺库时 chromium 起不来，缺 CJK 字体则截图全是方框。
# 字体不可省：善治 Bug 的界面截图全是中文，缺 CJK 字体只会拍到一片方框，
# 那样即便断言通过也看不出界面对不对。
# 用文泉驿正黑而不是 fonts-noto-cjk：后者 56MB，实测在这台构建机上反复下载失败
# （Connection failed），而截图只要求中文可读，4MB 的文泉驿完全够用。
RUN apt-get -o Acquire::Retries=5 update \
 && apt-get install -y --no-install-recommends \
      fonts-liberation \
      fonts-wqy-zenhei \
      libasound2 \
      libatk-bridge2.0-0 \
      libatk1.0-0 \
      libatspi2.0-0 \
      libcairo2 \
      libcups2 \
      libdrm2 \
      libgbm1 \
      libnspr4 \
      libnss3 \
      libpango-1.0-0 \
      libxcomposite1 \
      libxdamage1 \
      libxfixes3 \
      libxkbcommon0 \
      libxrandr2 \
 && rm -rf /var/lib/apt/lists/*

# UI 冒烟用的 Python 依赖。直接装进系统 python3，而不是单独建 venv：
#   · 任务要求 `python3 -c "from playwright.sync_api import sync_playwright"` 能直接跑通，
#     agent 不会记得去翻某个 venv 路径；
#   · Debian 12 的 python3 是 externally-managed，必须显式 --break-system-packages，
#     否则 pip 拒绝安装（这里是唯一往系统装包的地方，不存在互相污染的竞争）。
#
# 版本跟着 iidp_uitest 的 requirements.txt 走：那边 playwright 是 1.55.0，
# 浏览器与库版本必须配套，否则 chromium.launch() 会因为找不到对应 build 直接失败。
# 升级 uitest 依赖时记得同步这里，否则冒烟会在 launch 阶段报 "Executable doesn't exist"。
#
# PIP_INDEX_URL 默认走清华源：直连 files.pythonhosted.org 实测会读超时（amd64 构建
# 连续挂过两次），镜像源在本机直连稳定。私有化部署可换成内网源。
ARG PIP_INDEX_URL=https://pypi.tuna.tsinghua.edu.cn/simple
ARG PLAYWRIGHT_VERSION=1.55.0
# uitest 框架的依赖（已剔除 faster-whisper / edge-tts / jmeter 等与 UI 冒烟无关的重包）。
# 名单来源：iidp_uitest 的 requirements.txt 去掉视频/ASR/手册链路；另补 xlrd（stacks/iidp/
# page_api/api.py 顶层 import，缺了 conftest 直接导入失败）、paho-mqtt、pymssql 同理。
ARG UITEST_DEPS="pytest==8.0.0 pytest-xdist==3.6.1 allure-pytest==2.13.2 selenium==4.18.1 ruamel.yaml==0.18.5 pillow==10.4.0 requests==2.31.0 PyYAML==6.0.2 openpyxl==3.1.2 xlrd==2.0.1 numpy==1.26.4 pixelmatch==0.3.0 oracledb==26.1.0 PyMySQL==1.1.0 psycopg2-binary==2.9.10 JayDeBeApi==1.2.3 cryptography==50.0.2 paho-mqtt==2.1.0 tornado==6.4.2 python-docx==1.1.2 python-pptx==1.0.2"
RUN apt-get -o Acquire::Retries=5 update \
 && apt-get install -y --no-install-recommends python3-pip \
 && rm -rf /var/lib/apt/lists/* \
 && python3 -m pip install --no-cache-dir --disable-pip-version-check \
      --break-system-packages \
      --index-url "${PIP_INDEX_URL}" --retries 5 --timeout 60 \
      "playwright==${PLAYWRIGHT_VERSION}" ${UITEST_DEPS} \
 && python3 -c "from playwright.sync_api import sync_playwright; print('playwright 就绪')" \
 && python3 -c "import pytest, allure, selenium, pixelmatch, ruamel.yaml, xlrd, yaml, openpyxl; print('uitest 依赖就绪')"

# Node.js 22：直接从官方镜像搬二进制，避免在 Debian 上再拉一次 NodeSource。
COPY --from=node_runtime /usr/local/lib/node_modules /usr/local/lib/node_modules
COPY --from=node_runtime /usr/local/bin/node /usr/local/bin/node
COPY --from=node_runtime /opt/yarn-v1.22.22 /opt/yarn-v1.22.22
# 官方镜像里的 npm/npx/corepack 是指向 lib/node_modules 的相对软链，
# COPY 会把软链解引用成普通文件导致 require 失败，所以这里重新建软链。
RUN ln -sf /usr/local/bin/node /usr/local/bin/nodejs \
 && ln -sf ../lib/node_modules/npm/bin/npm-cli.js /usr/local/bin/npm \
 && ln -sf ../lib/node_modules/npm/bin/npx-cli.js /usr/local/bin/npx \
 && ln -sf ../lib/node_modules/corepack/dist/corepack.js /usr/local/bin/corepack \
 && ln -sf /opt/yarn-v1.22.22/bin/yarn /usr/local/bin/yarn \
 && ln -sf /opt/yarn-v1.22.22/bin/yarnpkg /usr/local/bin/yarnpkg

# JDK 21 + Maven：目标项目（iidp-aios）是 Java/Maven 工程，Agent 需要能编译验证。
COPY --from=maven_tools /opt/java/openjdk /opt/java/openjdk
COPY --from=maven_tools /usr/share/maven /usr/share/maven
RUN ln -sf /usr/share/maven/bin/mvn /usr/local/bin/mvn \
 && ln -sf /opt/java/openjdk/bin/java /usr/local/bin/java

ENV PATH=${JAVA_HOME}/bin:${PATH}

# ---------------------------------------------------------------------------
# Agent CLI
# ---------------------------------------------------------------------------
RUN npm config set registry "${NPM_REGISTRY}" \
 && npm config set fund false \
 && npm config set audit false \
 && node --version \
 && npm --version

# codex：Symphony 的默认 agent（codex app-server 协议）。
# claude：Claude Code CLI，命令名 claude。
#
# ⚠️ codex 的坑（2026-11-17 实测栽过一次）：它的原生二进制不是装在主包里，而是通过
# optionalDependency 分发——`@openai/codex-linux-x64`（别名到 `@openai/codex@<ver>-linux-x64`，
# 上百 MB）。npm 对 optional 依赖的下载失败是**静默**的：install 照样 exit 0、只装 2 个包，
# 错误要等到下次跑 `codex --version` 才报 "Missing optional dependency @openai/codex-linux-x64"。
# 本网络下这个包会断流，于是这里做三件事：拉长超时 + 重试、装完当场验二进制、缺失就整层失败。
RUN set -euo pipefail; \
    platform_pkg() { ls -d /usr/local/lib/node_modules/@openai/codex/node_modules/@openai/codex-linux-* 2>/dev/null; }; \
    ok=0; \
    for attempt in 1 2 3; do \
      echo "第 ${attempt} 次安装 codex / claude…"; \
      if npm install --global --no-fund --no-audit \
           --fetch-retries=5 --fetch-retry-mintimeout=2000 \
           --fetch-retry-maxtimeout=120000 --fetch-timeout=600000 \
           "@openai/codex@${CODEX_VERSION}" \
           "@anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}" \
         && codex --version >/dev/null 2>&1; then \
        ok=1; break; \
      fi; \
      echo "警告: codex 平台二进制缺失或不可执行（optional 依赖下载失败），清理后重试" >&2; \
      rm -rf /usr/local/lib/node_modules/@openai/codex; \
    done; \
    if [ "$ok" != "1" ]; then \
      echo "错误: codex 原生二进制装不上（@openai/codex-linux-x64 缺失）。" >&2; \
      echo "      多为到 registry.npmjs.org 的网络断流；可换 NPM_REGISTRY 镜像后重试。" >&2; \
      exit 1; \
    fi; \
    echo "codex 平台二进制: $(platform_pkg)"; \
    codex --version; claude --version

# zcode：Z.ai 的 CLI。官方只发桌面版，这里装社区整理的「官方运行时 + 安装器」
# 发布包（只依赖 Node，无 postinstall 编译）。置空该参数即可跳过安装。
RUN if [ -n "${ZCODE_CLI_PKG}" ]; then \
      npm install --global --no-fund --no-audit "${ZCODE_CLI_PKG}"; \
    else \
      echo "跳过 zcode 安装（ZCODE_CLI_PKG 为空）"; \
    fi

# 社区 zcode-cli 不认识 Symphony 适配器用的 --output-format stream-json，
# 因此把真 CLI 改名，用 shim 顶替 zcode（见 deploy/zcode-stream-shim.sh）：
# shim 把 stream-json 调用翻译成 --json，再转成适配器认的 NDJSON。
COPY deploy/zcode-stream-shim.sh /tmp/zcode-stream-shim.sh
RUN if [ -n "${ZCODE_CLI_PKG}" ] && [ -e /usr/local/bin/zcode ]; then \
      mv /usr/local/bin/zcode /usr/local/bin/zcode-cli-real \
      && install -m 0755 /tmp/zcode-stream-shim.sh /usr/local/bin/zcode; \
    fi \
 && rm -f /tmp/zcode-stream-shim.sh

# cursor-agent：官方安装脚本会把带内置 Node 的运行时装到 $HOME/.local，
# 这里把 HOME 指到 /opt 下，避免装进 /root（/root 是 700，运行用户读不到）。
# .curlrc 里强制 HTTP/1.1：安装脚本内部用 curl 拉 130MB 的包，实测本网络下
# HTTP/2 会在 19% 处报 "stream 1 was not closed cleanly" 截断，换成 1.1 才能拉完。
# 该文件只在这个 RUN 里生效，装完即删，不影响运行期的 curl 行为。
#
# 两处让构建不被它拖死的设计（都是被实测逼出来的）：
#   · 置空 CURSOR_INSTALL_URL 直接跳过，不下载；
#   · 下载失败（网络截断，实测同一层连续挂两次）只告警不中断构建。
#     cursor-agent 缺席时 Symphony 派不了 cursor 渠道的单，但 codex / claude
#     两个渠道照常工作，值得换一次成功构建。
RUN if [ -z "${CURSOR_INSTALL_URL}" ]; then \
      echo "跳过 cursor-agent 安装（CURSOR_INSTALL_URL 为空）"; \
    else \
      mkdir -p /opt/cursor-agent \
      && printf -- '--http1.1\n' > /opt/cursor-agent/.curlrc \
      && if HOME=/opt/cursor-agent bash -c "curl -fsSL --retry 5 --retry-all-errors --retry-delay 2 '${CURSOR_INSTALL_URL}' | bash"; then \
           ln -sf /opt/cursor-agent/.local/bin/cursor-agent /usr/local/bin/cursor-agent \
           && ln -sf /opt/cursor-agent/.local/bin/agent /usr/local/bin/agent \
           && chmod -R a+rX /opt/cursor-agent; \
         else \
           echo "警告: cursor-agent 下载/安装失败，跳过（cursor 渠道不可用，codex/claude 不受影响）" >&2; \
           rm -rf /opt/cursor-agent; \
         fi; \
      rm -f /opt/cursor-agent/.curlrc; \
    fi

# 安装结果自检：codex / claude 是硬要求（缺席时容器起来也没法干活）；
# cursor-agent 只在确实装上时才校验，跳过安装不算失败。
RUN set -euo pipefail; \
    for cli in codex claude; do \
      command -v "$cli" >/dev/null 2>&1 || { echo "缺少 CLI: $cli" >&2; exit 1; }; \
    done; \
    if [ -n "${ZCODE_CLI_PKG}" ]; then \
      command -v zcode >/dev/null 2>&1 || { echo "缺少 CLI: zcode" >&2; exit 1; }; \
    fi; \
    codex --version; claude --version; \
    if command -v cursor-agent >/dev/null 2>&1; then \
      cursor-agent --version; \
    else \
      echo "cursor-agent 未安装（构建时跳过或下载失败），cursor 渠道不可用" >&2; \
    fi; \
    if [ -n "${ZCODE_CLI_PKG}" ]; then zcode --version || true; fi

# ---------------------------------------------------------------------------
# 善治 MCP 服务
# ---------------------------------------------------------------------------
# 独立仓库（善治 Bug 协作 MCP），stdio 传输，由 Agent CLI 按需拉起。
# 装到独立 venv：Debian 的 python3 是 externally-managed，直接 pip install 会被拒；
# 用 venv 也避免与系统包互相污染。凭证不在这里，由 entrypoint 生成到用户目录。
COPY deploy/shanzhi-mcp /opt/shanzhi-mcp-launcher
COPY deploy/shanzhi-mcp-probe.py /opt/shanzhi-mcp-probe.py
RUN if [ -n "${SHANZHI_MCP_REPO}" ]; then \
      git clone --quiet --depth 1 --branch "${SHANZHI_MCP_REF}" "${SHANZHI_MCP_REPO}" /opt/shanzhi-mcp/app \
      && rm -rf /opt/shanzhi-mcp/app/.git \
      && python3 -m venv /opt/shanzhi-mcp/venv \
      && printf 'mcp<2\n' > /tmp/mcp-constraints.txt \
      && /opt/shanzhi-mcp/venv/bin/pip install --no-cache-dir --disable-pip-version-check \
           -r /opt/shanzhi-mcp/app/requirements.txt -c /tmp/mcp-constraints.txt \
      && install -D -m 0755 /opt/shanzhi-mcp-launcher /opt/shanzhi-mcp/bin/shanzhi-mcp \
      && install -D -m 0755 /opt/shanzhi-mcp-probe.py /opt/shanzhi-mcp/bin/mcp-probe \
      && /opt/shanzhi-mcp/venv/bin/python -c "from mcp.server.fastmcp import FastMCP; import httpx" \
      && chmod -R a+rX /opt/shanzhi-mcp \
      && echo "善治 MCP 已安装（$(/opt/shanzhi-mcp/venv/bin/python --version 2>&1)）"; \
    else \
      echo "跳过善治 MCP 安装（SHANZHI_MCP_REPO 为空）"; \
    fi \
 && rm -rf /tmp/mcp-constraints.txt /opt/shanzhi-mcp-launcher

# ---------------------------------------------------------------------------
# 运行用户与目录
# ---------------------------------------------------------------------------
RUN groupadd --gid "${APP_GID}" "${APP_USER}" 2>/dev/null || true \
 && useradd --uid "${APP_UID}" --gid "${APP_GID}" \
      --create-home --home-dir "/home/${APP_USER}" --shell /bin/bash "${APP_USER}" \
 && mkdir -p /app /data/workspaces /data/log "/home/${APP_USER}/.codex" \
      "/home/${APP_USER}/.claude" "/home/${APP_USER}/.cursor" "/home/${APP_USER}/.zcode" \
 && chown -R "${APP_USER}:${APP_USER}" /app /data "/home/${APP_USER}"

# chromium 浏览器本体。三处讲究，都是为了不加没用的体积：
#   1. 装在运行用户家目录下：运行期是 uid 1000，只有自己家目录可写；与
#      PLAYWRIGHT_BROWSERS_PATH 对齐后，agent 不需要任何额外环境变量就能找到它。
#   2. 用 gosu 以运行用户身份安装，省掉 `chown -R`——对 300MB+ 的目录跑 chown
#      会把每个文件复制进新层，白白多涨一份体积。
#   3. `--only-shell`：冒烟只跑无头，完整 chromium（542MB）用不上，
#      无头 shell（304MB）足够；需要 headed 调试时在容器里单独装即可。
# 这一步必须放在用户创建之后，否则目录归属会错。
ENV PLAYWRIGHT_BROWSERS_PATH=/home/${APP_USER}/.cache/ms-playwright
RUN gosu "${APP_USER}" python3 -m playwright install --only-shell chromium \
 && du -sh "${PLAYWRIGHT_BROWSERS_PATH}"

COPY --from=builder /src/bin/symphony /app/symphony
COPY deploy/entrypoint.sh /usr/local/bin/symphony-entrypoint
COPY deploy/WORKFLOW.md /app/WORKFLOW.md
# 冒烟用例 skill：三个 CLI 各自有独立的 skill 搜索路径，同一份内容放三处。
# （不放仓库根 .codex/ —— 那是开发机的目录，镜像里 agent 读的是 $HOME 下的。）
COPY deploy/skills/iidp-smoke /home/${APP_USER}/.codex/skills/iidp-smoke
COPY deploy/skills/iidp-smoke /home/${APP_USER}/.claude/skills/iidp-smoke
COPY deploy/skills/iidp-smoke /home/${APP_USER}/.cursor/skills/iidp-smoke

RUN chmod 0755 /app/symphony /usr/local/bin/symphony-entrypoint \
 && chown "${APP_USER}:${APP_USER}" /app/WORKFLOW.md \
 && chown -R "${APP_USER}:${APP_USER}" \
      "/home/${APP_USER}/.codex/skills" \
      "/home/${APP_USER}/.claude/skills" \
      "/home/${APP_USER}/.cursor/skills"

WORKDIR /app

EXPOSE 4567

HEALTHCHECK --interval=30s --timeout=5s --start-period=60s --retries=3 \
  CMD curl -fsS "http://127.0.0.1:${SYMPHONY_PORT}/api/v1/state" >/dev/null || exit 1

# tini 负责回收 Agent 派生的僵尸进程，entrypoint 负责降权与凭据准备。
ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/symphony-entrypoint"]
CMD []
