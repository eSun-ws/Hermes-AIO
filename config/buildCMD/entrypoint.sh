#!/bin/bash
# =============================================================================
# Entrypoint: credentials -> first-boot bootstrap (online install) -> supervisor
#   modes: up (default) / bootstrap / webui / gateway / dashboard / bash
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

# ── Credentials: master password (shared by WebUI/Dashboard) + API key (>=16 chars)
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
        log "First run: generated a master password"
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
            log "Master password is ${#master} chars (< 16): the API gateway needs a key of at least 16, so a separate API key was generated"
        fi
    fi

    upsert_env HERMES_WEBUI_PASSWORD "$master" "$env_file"
    upsert_env HERMES_DASHBOARD_BASIC_AUTH_PASSWORD "$master" "$env_file"
    upsert_env API_SERVER_KEY "$api_key" "$env_file"
    chmod 600 "$env_file" 2>/dev/null || true
    export HERMES_WEBUI_PASSWORD="$master" HERMES_DASHBOARD_BASIC_AUTH_PASSWORD="$master" API_SERVER_KEY="$api_key"

    echo ""
    echo "================================================================"
    echo " [entrypoint] login credentials:"
    echo "   WebUI      http://<host>:${HERMES_WEBUI_PORT:-8787}    password: ${master}"
    if [ "${HERMES_DASHBOARD_ON:-0}" = "1" ]; then
        echo "   Dashboard  http://<host>:${HERMES_DASHBOARD_PORT:-9119} user: ${DASH_BASIC_AUTH_USER:-hermes}  password: ${master}"
    fi
    if [ "$api_key" = "$master" ]; then
        echo "   API gateway http://<host>:${API_SERVER_PORT:-8642}/v1   key: ${api_key} (= master password)"
    else
        echo "   API gateway http://<host>:${API_SERVER_PORT:-8642}/v1   key: ${api_key} (separate key; master password under 16 chars)"
    fi
    echo "   persisted to $env_file"
    echo "================================================================"
    echo ""
}

# A Dashboard bound to 0.0.0.0 needs BOTH a username and a password_hash in
# config.yaml. WARNING: writing only the username makes the agent refuse to start
# ("neither password_hash nor password is configured") and the WebUI will not open.
# So they are always written as a pair, through the official `hermes config set`
# (never by hand-editing YAML, which would disturb the existing structure/comments).
ensure_dashboard_auth() {
    [ "${HERMES_DASHBOARD_ON:-0}" = "1" ] || return 0
    [ -f "$HERMES_HOME/config.yaml" ] || return 0
    grep -qE "^[[:space:]]+password_hash:[[:space:]]*[^[:space:]]" "$HERMES_HOME/config.yaml" 2>/dev/null && return 0
    local user="${DASH_BASIC_AUTH_USER:-hermes}"
    local pass="${HERMES_DASHBOARD_BASIC_AUTH_PASSWORD:-${HERMES_WEBUI_PASSWORD:-}}"
    [ -n "$pass" ] || { log "WARNING: no usable password, skipping the dashboard auth write"; return 0; }
    local hash
    hash="$("$VENV" -c 'import sys; from plugins.dashboard_auth.basic import hash_password; print(hash_password(sys.argv[1]))' "$pass" 2>/dev/null || true)"
    [ -n "$hash" ] || { log "WARNING: could not compute password_hash (skipping)"; return 0; }
    hermes config set dashboard.basic_auth.username "$user" >>"$LOG_DIR/dashboard-auth.log" 2>&1 || true
    hermes config set dashboard.basic_auth.password_hash "$hash" >>"$LOG_DIR/dashboard-auth.log" 2>&1 || true
    if grep -qE "^[[:space:]]+password_hash:[[:space:]]*[^[:space:]]" "$HERMES_HOME/config.yaml"; then
        log "dashboard.basic_auth written (user=$user)"
    else
        log "WARNING: writing dashboard.basic_auth failed (see $LOG_DIR/dashboard-auth.log)"
    fi
}

# Markers/locks left behind by an interrupted update: with no update process running
# they are stale and removed. WARNING: if they are left in place, an interrupted
# WebUI/Dashboard update (network loss, container restart) can make later `hermes`
# commands hang on "waiting for ... lock" or keep resuming, which shows up as
# "the WebUI opens but cannot chat".
heal_update_markers() {
    pgrep -fa "hermes update" >/dev/null 2>&1 && return 0
    local f removed=0
    for f in "$HERMES_HOME/.hermes-update-in-progress" "$HERMES_HOME/.hermes-update-in-progress.lock"; do
        if [ -e "$f" ]; then rm -f "$f"; removed=$((removed + 1)); fi
    done
    [ "$removed" -gt 0 ] && log "Removed $removed stale update marker(s) (no update process running)"
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
        log "First-boot check (the first run installs hermes + webui online, 5-15 minutes; progress below)"
        /app/scripts/bootstrap.sh || { log "ERROR: first-boot bootstrap failed; keeping the container alive for inspection (docker exec -it <container> bash)"; exec sleep infinity; }
        ensure_dashboard_auth   # config.yaml is created by the installer, so write once more afterwards
        case "$MODE" in
            up)         log "Starting the supervisor (gateway + webui + scheduled updates)"; exec /app/scripts/supervisor.sh ;;
            webui)      log "Starting the WebUI only"; exec /app/scripts/supervisor.sh ;;   # the supervisor trims services by switches
            gateway)    log "Starting the gateway only"; exec hermes gateway run --external-supervisor ;;
            dashboard)  log "Starting the Dashboard"; exec hermes dashboard --host 0.0.0.0 --port "${HERMES_DASHBOARD_PORT:-9119}" --skip-build --no-open ;;
            *)          log "Unknown mode: $MODE (available: up/bootstrap/webui/gateway/dashboard/bash)"; exec sleep infinity ;;
        esac
        ;;
esac
