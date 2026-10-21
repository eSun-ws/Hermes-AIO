# syntax=docker/dockerfile:1
# =============================================================================
# Hermes All-in-One v2 — “按真机流程装”的薄镜像
# -----------------------------------------------------------------------------
# 设计口径（按用户要求）：
#   · 镜像【不装】hermes、不装 webui、不装任何 Python 依赖 —— 只放运行期流程脚本
#     与系统工具链；源码与依赖在【容器首次启动】时在线安装（永远拿到最新版）。
#   · 首启调用官方安装脚本（尊重 HERMES_HOME / HERMES_INSTALL_DIR），由 pm 负责
#     依赖环境 —— 这样 `hermes update` 的行为与真机完全一致。
#   · 数据面全部落在数据卷：
#       /app/src          ← hermes 源码 + webui 源码（升级改这里，重建容器不丢）
#       /app/hermes-agent ← HERMES_HOME（env/installs/tools/config/sessions）
#       /workspace        ← Agent 默认工作区
#   · 没有 systemd：supervisor 复刻 systemd 单元语义（Restart=always / RestartSec=5
#     / After=gateway），并在更新的正确时机重启 WebUI（真机靠 unit 的 Restart=always）。
# =============================================================================
FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

# 系统依赖：官方安装脚本所需（git/curl/xz/tar）+ 编译 python-olm 等源码包所需
# （build-essential + libolm-dev）+ 运行期排障工具。刻意不装 python 生态与 node，
# 它们由官方安装脚本在首启时自举到 /app/hermes-agent/tools。
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates curl git openssh-client \
        xz-utils gzip bzip2 tar unzip zip rsync \
        build-essential pkg-config cmake \
        python3 python3-venv python3-pip \
        libolm-dev libatomic1 \
        ffmpeg procps jq less tzdata openssl \
    && rm -rf /var/lib/apt/lists/*

# 布局与默认值（compose 会按 .env 覆盖）
#
# ⚠ HOME 为什么要改：官方安装把 `hermes` 垫片放在 ~/.local/bin、uv 的 Python 放在
#   ~/.local/share/uv。若 HOME 仍是 /root（镜像层），容器一旦重建（= 重装/升级）垫片
#   与解释器全丢 → /app/src/Hermes/venv 立刻失效 → WebUI 起不来。所以 HOME 必须
#   落在数据卷 /app/hermes-agent 里，和 HERMES_HOME 一起持久化。
ENV HERMES_HOME=/app/hermes-agent \
    HERMES_INSTALL_DIR=/app/src/Hermes \
    HERMES_WEBUI_DIR=/app/src/WebUI \
    HERMES_CHANNEL=stable \
    HERMES_WEBUI_HOST=0.0.0.0 \
    HERMES_WEBUI_PORT=8787 \
    HERMES_WEBUI_BOT_NAME=Hermes \
    HERMES_DASHBOARD_ON=0 \
    HERMES_DASHBOARD_HOST=0.0.0.0 \
    HERMES_DASHBOARD_PORT=9119 \
    HERMES_DASHBOARD_BASIC_AUTH_USERNAME=hermes \
    HERMES_API_GW=1 \
    API_SERVER_HOST=0.0.0.0 \
    API_SERVER_PORT=8642 \
    HINDSIGHT_PLUGIN=on \
    HINDSIGHT_ENABLE=0 \
    UPDATE_AGENT_TIME=48 \
    UPDATE_WEBUI_TIME=48 \
    # uv 托管的 Python 在 sysconfig 里把 CC/CXX 记成 clang，镜像没有 clang；
    # python-olm 等包在 3.14 上要源码编译 → 统一用系统 g++
    CC=gcc \
    CXX=g++ \
    HOME=/app/hermes-agent/home \
    PATH=/app/hermes-agent/home/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

COPY config/buildCMD/ /app/scripts/
RUN chmod +x /app/scripts/*.sh \
    && mkdir -p "$HERMES_HOME" "$HERMES_INSTALL_DIR" "$HERMES_WEBUI_DIR" "$HOME/.local/bin" /workspace

WORKDIR /workspace
EXPOSE 8787 9119 8642 3111-3113

HEALTHCHECK --interval=30s --timeout=8s --start-period=120s --retries=3 \
    CMD curl -fsS "http://localhost:${HERMES_WEBUI_PORT:-8787}/health" >/dev/null 2>&1 || exit 1

ENTRYPOINT ["/app/scripts/entrypoint.sh"]
CMD ["up"]
