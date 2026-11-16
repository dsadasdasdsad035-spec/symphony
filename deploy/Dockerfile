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

ARG NPM_REGISTRY=https://registry.npmjs.org
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
# 版本用 @latest 保证装得上；需要复现构建时在 .env 里钉死版本号。
RUN npm install --global --no-fund --no-audit \
      "@openai/codex@${CODEX_VERSION}" \
      "@anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}"

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
RUN mkdir -p /opt/cursor-agent \
 && HOME=/opt/cursor-agent bash -c "curl -fsSL '${CURSOR_INSTALL_URL}' | bash" \
 && ln -sf /opt/cursor-agent/.local/bin/cursor-agent /usr/local/bin/cursor-agent \
 && ln -sf /opt/cursor-agent/.local/bin/agent /usr/local/bin/agent \
 && chmod -R a+rX /opt/cursor-agent

# 安装结果自检：缺任何一个都让构建失败，避免部署后才发现 CLI 不在 PATH。
RUN set -euo pipefail; \
    for cli in codex claude cursor-agent; do \
      command -v "$cli" >/dev/null 2>&1 || { echo "缺少 CLI: $cli" >&2; exit 1; }; \
    done; \
    if [ -n "${ZCODE_CLI_PKG}" ]; then \
      command -v zcode >/dev/null 2>&1 || { echo "缺少 CLI: zcode" >&2; exit 1; }; \
    fi; \
    codex --version; claude --version; cursor-agent --version; \
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

COPY --from=builder /src/bin/symphony /app/symphony
COPY deploy/entrypoint.sh /usr/local/bin/symphony-entrypoint
COPY deploy/WORKFLOW.md /app/WORKFLOW.md

RUN chmod 0755 /app/symphony /usr/local/bin/symphony-entrypoint \
 && chown "${APP_USER}:${APP_USER}" /app/WORKFLOW.md

WORKDIR /app

EXPOSE 4567

HEALTHCHECK --interval=30s --timeout=5s --start-period=60s --retries=3 \
  CMD curl -fsS "http://127.0.0.1:${SYMPHONY_PORT}/api/v1/state" >/dev/null || exit 1

# tini 负责回收 Agent 派生的僵尸进程，entrypoint 负责降权与凭据准备。
ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/symphony-entrypoint"]
CMD []
