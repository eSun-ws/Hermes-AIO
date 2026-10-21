#!/bin/bash
# =============================================================================
# Process supervision (replaces the bare-metal systemd units)
#   * hermes-gateway.service  -> start_gateway here (Restart=always / RestartSec=5)
#   * hermes-webui.service    -> start_webui here (After=gateway, also auto-restarted)
#   * restart after an update: the updater writes $HERMES_HOME/logs/.restart_webui and
#     the main loop restarts on seeing it (on bare metal the WebUI process still holds
#     the old modules after `hermes update`, i.e. "opens but cannot chat")
# =============================================================================
set -euo pipefail

HERMES_HOME="${HERMES_HOME:-/app/hermes-agent}"
INSTALL_DIR="${HERMES_INSTALL_DIR:-/app/src/Hermes}"
WEBUI_DIR="${HERMES_WEBUI_DIR:-/app/src/WebUI}"
VENV="${HERMES_WEBUI_PYTHON:-$INSTALL_DIR/venv/bin/python}"
LOG_DIR="$HERMES_HOME/logs"
mkdir -p "$LOG_DIR"

log() { echo "[supervisor] $(date '+%F %T') $*"; }
port_open() { (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null; }

GW_PID=""; WEBUI_PID=""; DASH_PID=""
RESTART_FLAG="$LOG_DIR/.restart_webui"
GW_RESTART_FLAG="$LOG_DIR/.restart_gateway"
DASH_RESTART_FLAG="$LOG_DIR/.restart_dashboard"
AGENT_HEAD_FILE="$LOG_DIR/.agent-head"

# ── agent revision watcher ────────────────────────────────────────────────────
# On bare metal `hermes update` only swaps the code; systemd's Restart=always is what
# brings the WebUI back up. Otherwise the process still holds the old modules ->
# "the WebUI opens but cannot chat".
# There is no systemd in a container, so we watch HEAD here: whether the updater ran
# or the user clicked an update button in the WebUI/Dashboard, as soon as the commit in
# $INSTALL_DIR changes we refresh dependencies and restart the WebUI / gateway.
agent_head() { git -C "$INSTALL_DIR" rev-parse HEAD 2>/dev/null || echo ''; }

refresh_webui_env() {
    local uv_bin
    uv_bin="$(command -v uv || ls -d "$HERMES_HOME"/tools/uv-*/bin/uv "$HERMES_HOME"/tools/uv-*/uv 2>/dev/null | head -1 || true)"
    [ -x "$uv_bin" ] || { log "WARNING: uv not found, skipping the dependency refresh"; touch "$RESTART_FLAG"; return 0; }
    log "Refreshing WebUI dependencies (uv sync --locked; the agent code changed)"
    if ( cd "$INSTALL_DIR" && UV_PROJECT_ENVIRONMENT="${HERMES_INSTALL_DIR:-/app/src/Hermes}/venv" "$uv_bin" sync --locked --python 3.14 \
            $(python3 -c "import tomllib;o=tomllib.load(open('pyproject.toml','rb'))['project'].get('optional-dependencies',{});w=['all','messaging','otlp','anthropic','bedrock','azure-identity','matrix'];print(' '.join('--extra '+e for e in w if e in o))") >> "$LOG_DIR/deps.log" 2>&1 ); then
        log "Dependency refresh finished -> restarting the WebUI"
    else
        log "WARNING: dependency refresh failed (see deps.log); restarting the WebUI anyway"
    fi
    touch "$RESTART_FLAG"
    touch "$GW_RESTART_FLAG"
    if [ "${HERMES_DASHBOARD_ON:-0}" = "1" ]; then touch "$DASH_RESTART_FLAG"; fi
    return 0
}

check_agent_head() {
    local cur prev
    cur="$(agent_head)"; [ -n "$cur" ] || return 0
    if [ ! -f "$AGENT_HEAD_FILE" ]; then printf '%s\n' "$cur" > "$AGENT_HEAD_FILE"; return 0; fi
    prev="$(cat "$AGENT_HEAD_FILE" 2>/dev/null || true)"
    [ "$prev" = "$cur" ] && return 0
    printf '%s\n' "$cur" > "$AGENT_HEAD_FILE"
    log "Detected an agent code change ${prev:0:8} -> ${cur:0:8} (possibly from the WebUI/Dashboard update button)"
    # Run it in a subshell so uv sync never blocks the main loop (a lock prevents overlaps)
    ( flock -n 9 || exit 0; refresh_webui_env ) 9>"$LOG_DIR/.deps.lock" &
}

stop_webui() {
    if [ -n "$WEBUI_PID" ] && kill -0 "$WEBUI_PID" 2>/dev/null; then
        kill -TERM "$WEBUI_PID" 2>/dev/null || true
        for _ in $(seq 1 20); do kill -0 "$WEBUI_PID" 2>/dev/null || break; sleep 0.5; done
        kill -KILL "$WEBUI_PID" 2>/dev/null || true
        wait "$WEBUI_PID" 2>/dev/null || true
    fi
    WEBUI_PID=""
}

cleanup() {
    log "Exit signal received, cleaning up child processes ..."
    stop_webui
    [ -n "${DASH_PID:-}" ] && kill -TERM "$DASH_PID" 2>/dev/null || true
    [ -n "${GW_PID:-}" ] && kill -TERM "$GW_PID" 2>/dev/null || true
    [ -n "${UPD_PIDS:-}" ] && kill -TERM $UPD_PIDS 2>/dev/null || true
    exit 0
}
trap cleanup TERM INT

# ── gateway (equivalent of hermes-gateway.service) ───────────────────────────
start_gateway() {
    if [ "${HERMES_API_GW:-1}" != "1" ]; then return 0; fi
    if port_open "${API_SERVER_PORT:-8642}"; then
        log "gateway :${API_SERVER_PORT:-8642} is already being served"; GW_PID=""; return 0
    fi
    local _key="${API_SERVER_KEY:-}"
    local key_len=${#_key}
    [ "$key_len" -ge 16 ] || log "ERROR: API_SERVER_KEY is only ${key_len} chars (upstream requires >=16) -> api_server will not start"
    log "Starting the gateway (bind=${API_SERVER_HOST:-0.0.0.0}:${API_SERVER_PORT:-8642})"
    hermes gateway run --no-supervise --external-supervisor >> "$LOG_DIR/gateway.log" 2>&1 &
    GW_PID=$!
    log "gateway pid=$GW_PID"
    # api_server needs a warm-up (measured 10-120s); probe best-effort, never block
    local i code
    for i in $(seq 1 15); do
        code="$(curl -s -o /dev/null -w '%{http_code}' -m 2 -H "Authorization: Bearer ${API_SERVER_KEY:-}" \
            "http://127.0.0.1:${API_SERVER_PORT:-8642}/v1/models" 2>/dev/null || true)"
        case "$code" in 200|401) log "gateway :${API_SERVER_PORT:-8642} ready (/v1/models HTTP ${code})"; return 0 ;; esac
        sleep 2
    done
    log "gateway :${API_SERVER_PORT:-8642} still starting (api_server warm-up is usually under 2 minutes)"
}

# ── WebUI (equivalent of hermes-webui.service) ───────────────────────────────
start_webui() {
    rm -f "$RESTART_FLAG"
    [ -x "$VENV" ] || { log "ERROR: WebUI python missing: $VENV"; return 0; }
    log "Starting the WebUI ($VENV server.py, port ${HERMES_WEBUI_PORT:-8787})"
    (
        cd "$WEBUI_DIR"
        set -a
        # shellcheck disable=SC1091
        [ -f .env ] && . ./.env
        set +a
        exec "$VENV" server.py
    ) >> "$LOG_DIR/webui.log" 2>&1 &
    WEBUI_PID=$!
    log "WebUI pid=$WEBUI_PID"
}

# ── Dashboard (optional) ─────────────────────────────────────────────────────
start_dashboard() {
    [ "${HERMES_DASHBOARD_ON:-0}" = "1" ] || return 0
    port_open "${HERMES_DASHBOARD_PORT:-9119}" && { DASH_PID=""; return 0; }
    log "Starting the Dashboard :${HERMES_DASHBOARD_PORT:-9119}"
    hermes dashboard --host "${HERMES_DASHBOARD_HOST:-0.0.0.0}" \
        --port "${HERMES_DASHBOARD_PORT:-9119}" --skip-build --no-open \
        >> "$LOG_DIR/dashboard.log" 2>&1 &
    DASH_PID=$!
}

start_gateway
start_webui
start_dashboard

# Scheduled updates (equivalent of the bare-metal 48h task)
if [ "${UPDATE_AGENT_TIME:-0}" -gt 0 ] 2>/dev/null || [ "${UPDATE_WEBUI_TIME:-0}" -gt 0 ] 2>/dev/null; then
    /app/scripts/updater.sh >> "$LOG_DIR/updater.log" 2>&1 &
    UPD_PIDS=$!
    log "Scheduled updates started (agent=${UPDATE_AGENT_TIME:-0}h webui=${UPDATE_WEBUI_TIME:-0}h)"
fi

WEBUI_READY_LOGGED=0
check_agent_head   # record the baseline commit so the first iteration is not a false positive
while true; do
    check_agent_head
    if [ -f "$GW_RESTART_FLAG" ]; then
        rm -f "$GW_RESTART_FLAG"
        log "Restarting the gateway (agent code changed)"
        [ -n "$GW_PID" ] && kill -TERM "$GW_PID" 2>/dev/null || true
        sleep 2; start_gateway
    fi
    if [ -f "$DASH_RESTART_FLAG" ]; then
        rm -f "$DASH_RESTART_FLAG"
        if [ "${HERMES_DASHBOARD_ON:-0}" = "1" ]; then
            log "Restarting the Dashboard (agent code changed: it also loads agent modules in-process, so without a restart it shows an old version and runs old code)"
            [ -n "$DASH_PID" ] && kill -TERM "$DASH_PID" 2>/dev/null || true
            pkill -f "dashboard --host" 2>/dev/null || true
            sleep 2; DASH_PID=""; start_dashboard
        fi
    fi
    if [ -f "$RESTART_FLAG" ]; then
        log "Update restart flag found -> restarting the WebUI"
        stop_webui; sleep 1; start_webui; continue
    fi
    if [ -n "$WEBUI_PID" ] && ! kill -0 "$WEBUI_PID" 2>/dev/null; then
        log "WARNING: WebUI process exited, restarting in 5s (Restart=always)"
        sleep 5; start_webui; continue
    fi
    if [ -z "$WEBUI_PID" ]; then sleep 5; start_webui; continue; fi
    if [ "$WEBUI_READY_LOGGED" = "0" ] && port_open "${HERMES_WEBUI_PORT:-8787}"; then
        log "WebUI :${HERMES_WEBUI_PORT:-8787} is ready"; WEBUI_READY_LOGGED=1
    fi
    if [ "${HERMES_API_GW:-1}" = "1" ] && [ -n "$GW_PID" ] && ! kill -0 "$GW_PID" 2>/dev/null; then
        log "WARNING: gateway process exited, restarting in 5s (Restart=always)"
        sleep 5; start_gateway
    fi
    if [ "${HERMES_DASHBOARD_ON:-0}" = "1" ] && [ -n "$DASH_PID" ] && ! kill -0 "$DASH_PID" 2>/dev/null; then
        log "WARNING: Dashboard process exited, restarting in 5s"
        sleep 5; start_dashboard
    fi
    sleep 2
done
