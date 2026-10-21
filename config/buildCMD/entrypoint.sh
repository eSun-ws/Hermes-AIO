#!/bin/bash
# =============================================================================
# 入口：凭据 → 首启引导（在线安装）→ 交给 supervisor
#   模式：up（默认）/ bootstrap / webui / gateway / dashboard / bash
# =============================================================================
set -euo pipefail

HERMES_HOME="${HERMES_HOME:-/app/hermes-agent}"
INSTALL_DIR="${HERMES_INSTALL_DIR:-/app/src/Hermes}"
WEBUI_DIR="${HERMES_WEBUI_DIR:-/app/src/WebUI}"
VENV="${HERMES_WEBUI_PYTHON:-$INSTALL_DIR/venv/bin/python}"
LOG_DIR="$HERMES_HOME/logs"
export PATH="${HOME:-/root}/.local/bin:$PATH"

log() { echo "[entrypoint] $*"; }
mkdir -p "$HERMES_HOME" "$INSTALL_DIR" "$WEBUI_DIR" "$LOG_DIR"

upsert_env() {  # upsert_env KEY VALUE [FILE]
    local k="$1" v="$2" f="${3:-$HERMES_HOME/.env}"
    touch "$f"
    if grep -qE "^[[:space:]]*${k}=" "$f"; then
        sed -i "s|^[[:space:]]*${k}=.*|${k}=${v}|" "$f"
    else
        printf '%s=%s\n' "$k" "$v" >> "$f"
    fi
}

# ── 凭据：主密码（WebUI/Dashboard 共用）+ API key（官方要求 ≥16 位）──────────
ensure_credentials() {
    local env_file="$HERMES_HOME/.env" master="" val api_key=""
    val="${HERMES_WEBUI_PASSWORD:-}"
    [ -n "$val" ] && master="$val"
    if [ -z "$master" ] && [ -f "$env_file" ]; then
        val="$(grep -m1 '^HERMES_WEBUI_PASSWORD=' "$env_file" 2>/dev/null | cut -d= -f2- || true)"
        [ -n "$val" ] && master="$val"
    fi
    if [ -z "$master" ]; then
        master="$(openssl rand -hex 16 2>/dev/null || tr -dc 'a-f0-9' </dev/urandom | head -c 32)"
        log "首次运行：已自动生成主密码"
    fi

    api_key="${API_SERVER_KEY:-}"
    if [ "${#api_key}" -lt 16 ] && [ -f "$env_file" ]; then
        api_key="$(grep -m1 '^API_SERVER_KEY=' "$env_file" 2>/dev/null | cut -d= -f2- || true)"
    fi
    if [ "${#api_key}" -lt 16 ]; then
        if [ "${#master}" -ge 16 ]; then
            api_key="$master"
        else
            api_key="$(openssl rand -hex 16 2>/dev/null || tr -dc 'a-f0-9' </dev/urandom | head -c 32)"
            log "主密码 ${#master} 位 < 16：API 网关要求 key ≥16 位，已单独生成 API key"
        fi
    fi

    upsert_env HERMES_WEBUI_PASSWORD "$master" "$env_file"
    upsert_env HERMES_DASHBOARD_BASIC_AUTH_PASSWORD "$master" "$env_file"
    upsert_env API_SERVER_KEY "$api_key" "$env_file"
    chmod 600 "$env_file" 2>/dev/null || true
    export HERMES_WEBUI_PASSWORD="$master" HERMES_DASHBOARD_BASIC_AUTH_PASSWORD="$master" API_SERVER_KEY="$api_key"

    echo ""
    echo "================================================================"
    echo " [entrypoint] 登录凭据："
    echo "   WebUI      http://<host>:${HERMES_WEBUI_PORT:-8787}    密码: ${master}"
    if [ "${HERMES_DASHBOARD_ON:-0}" = "1" ]; then
        echo "   Dashboard  http://<host>:${HERMES_DASHBOARD_PORT:-9119} 用户: ${HERMES_DASHBOARD_BASIC_AUTH_USERNAME:-hermes}  密码: ${master}"
    fi
    if [ "$api_key" = "$master" ]; then
        echo "   API 网关   http://<host>:${API_SERVER_PORT:-8642}/v1   Key: ${api_key}（= 主密码）"
    else
        echo "   API 网关   http://<host>:${API_SERVER_PORT:-8642}/v1   Key: ${api_key}（独立 key，主密码不足 16 位）"
    fi
    echo "   已持久化到 $env_file"
    echo "================================================================"
    echo ""
}

# Dashboard 绑定 0.0.0.0 需要 config.yaml 里【同时】有 username 与 password_hash。
# ⚠ 只写 username 会让 agent 拒绝启动（"neither password_hash nor password is
#   configured"）→ WebUI 打不开。所以一律成对写入，并且走官方 `hermes config set`，
#   不手改 YAML（避免破坏既有结构与注释）。
ensure_dashboard_auth() {
    [ "${HERMES_DASHBOARD_ON:-0}" = "1" ] || return 0
    [ -f "$HERMES_HOME/config.yaml" ] || return 0
    grep -qE "^[[:space:]]+password_hash:[[:space:]]*[^[:space:]]" "$HERMES_HOME/config.yaml" 2>/dev/null && return 0
    local user="${DASH_BASIC_AUTH_USER:-hermes}"
    local pass="${HERMES_DASHBOARD_BASIC_AUTH_PASSWORD:-${HERMES_WEBUI_PASSWORD:-}}"
    [ -n "$pass" ] || { log "WARNING: 没有可用密码，跳过 dashboard 鉴权写入"; return 0; }
    local hash
    hash="$("$VENV" -c 'import sys; from plugins.dashboard_auth.basic import hash_password; print(hash_password(sys.argv[1]))' "$pass" 2>/dev/null || true)"
    [ -n "$hash" ] || { log "WARNING: 无法计算 password_hash（跳过）"; return 0; }
    hermes config set dashboard.basic_auth.username "$user" >>"$LOG_DIR/dashboard-auth.log" 2>&1 || true
    hermes config set dashboard.basic_auth.password_hash "$hash" >>"$LOG_DIR/dashboard-auth.log" 2>&1 || true
    if grep -qE "^[[:space:]]+password_hash:[[:space:]]*[^[:space:]]" "$HERMES_HOME/config.yaml"; then
        log "dashboard.basic_auth 已写入（user=$user）"
    else
        log "WARNING: dashboard.basic_auth 写入失败（见 $LOG_DIR/dashboard-auth.log）"
    fi
}

# 更新中断留下的标记/锁：没有 update 进程在跑就是脏数据，直接清掉。
# ⚠ 不清的话，WebUI/Dashboard 的更新按钮一旦中断（断网、容器重启），后续
#   `hermes` 子命令可能卡在 "waiting for ... lock" 或反复续做，表现就是
#   “WebUI 能打开但不能对话”。
heal_update_markers() {
    pgrep -fa "hermes update" >/dev/null 2>&1 && return 0
    local f removed=0
    for f in "$HERMES_HOME/.hermes-update-in-progress" "$HERMES_HOME/.hermes-update-in-progress.lock"; do
        if [ -e "$f" ]; then rm -f "$f"; removed=$((removed + 1)); fi
    done
    [ "$removed" -gt 0 ] && log "已清理 $removed 个更新残留标记（无 update 进程在运行）"
    return 0
}

MODE="${1:-up}"
shift || true

case "$MODE" in
    bash|shell) exec bash -l "$@" ;;
    bootstrap)
        exec /app/scripts/bootstrap.sh ;;
    *)
        heal_update_markers
        ensure_credentials
        ensure_dashboard_auth
        log "首启引导检查（首次会在线安装 hermes + webui，约 5-15 分钟，进度见下方）"
        /app/scripts/bootstrap.sh || { log "ERROR: 首启引导失败，容器保持运行以便排查（docker exec -it <容器> bash）"; exec sleep infinity; }
        ensure_dashboard_auth   # config.yaml 由安装脚本生成，装完再写一次
        case "$MODE" in
            up)         log "启动 supervisor（gateway + webui + 定时更新）"; exec /app/scripts/supervisor.sh ;;
            webui)      log "仅启动 WebUI"; exec /app/scripts/supervisor.sh ;;   # supervisor 内部按开关裁剪
            gateway)    log "仅启动网关"; exec hermes gateway run --external-supervisor ;;
            dashboard)  log "启动 Dashboard"; exec hermes dashboard --host 0.0.0.0 --port "${HERMES_DASHBOARD_PORT:-9119}" --skip-build --no-open ;;
            *)          log "未知模式：$MODE（可用 up/bootstrap/webui/gateway/dashboard/bash）"; exec sleep infinity ;;
        esac
        ;;
esac
