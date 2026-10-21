# syntax=docker/dockerfile:1
# =============================================================================
# Hermes All-in-One v2 — a thin image that installs "the bare-metal way"
# -----------------------------------------------------------------------------
# Design rules:
#   * The image installs NO hermes, NO webui and NO Python dependencies -- it only
#     carries the orchestration scripts and the system toolchain. Sources and
#     dependencies are installed online on the container's FIRST BOOT (so every
#     deployment gets the current release).
#   * First boot runs the official installer (it honors HERMES_HOME /
#     HERMES_INSTALL_DIR) and lets pm own the dependency environments, which makes
#     `hermes update` behave exactly like a bare-metal install.
#   * All state lives on data volumes:
#       /app/src          <- hermes source + webui source (upgrades write here, survives recreation)
#       /app/hermes-agent <- HERMES_HOME (env/installs/tools/config/sessions)
#       /workspace        <- default agent workspace
#   * There is no systemd: the supervisor reproduces the unit semantics
#     (Restart=always / RestartSec=5 / After=gateway) and restarts the WebUI at the
#     right moment after an update (bare metal relies on the unit's Restart=always).
# =============================================================================
FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

# System dependencies: what the official installer needs (git/curl/xz/tar), what
# compiling source packages such as python-olm needs (build-essential + libolm-dev),
# and runtime troubleshooting tools. Python ecosystems and node are deliberately NOT
# installed here -- the official installer bootstraps them into
# /app/hermes-agent/tools on first boot.
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates curl git openssh-client \
        xz-utils gzip bzip2 tar unzip zip rsync \
        build-essential pkg-config cmake \
        python3 python3-venv python3-pip \
        libolm-dev libatomic1 \
        ffmpeg procps jq less tzdata openssl \
    && rm -rf /var/lib/apt/lists/*

# Layout and defaults (compose overrides them from .env)
#
# WARNING -- why HOME is moved: the official installer puts the `hermes` shim in
#   ~/.local/bin and uv's Python in ~/.local/share/uv. If HOME stayed at /root (the
#   image layer), recreating the container (= reinstall/upgrade) would wipe both the
#   shim and the interpreters, /app/src/Hermes/venv would immediately break and the
#   WebUI would not start. HOME must therefore live on the data volume
#   /app/hermes-agent so it persists together with HERMES_HOME.
#
# NOTE: HERMES_DASHBOARD_BASIC_AUTH_USERNAME is deliberately NOT set anywhere in the
#   container environment. The dashboard gate needs a username AND a password hash;
#   exporting only the username makes the agent refuse to start ("username is set but
#   neither password_hash nor password is configured"). The entrypoint writes the pair
#   into config.yaml (via `hermes config set`) when the Dashboard is enabled.
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
    HERMES_API_GW=1 \
    API_SERVER_HOST=0.0.0.0 \
    API_SERVER_PORT=8642 \
    HINDSIGHT_PLUGIN=on \
    HINDSIGHT_PREPARE=1 \
    UPDATE_AGENT_TIME=48 \
    UPDATE_WEBUI_TIME=48 \
    # uv-managed Python records CC/CXX as clang in sysconfig and the image has no
    # clang; packages such as python-olm must be compiled from source on 3.14, so
    # use the system g++ everywhere.
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
