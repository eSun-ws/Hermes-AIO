#!/bin/bash
# =============================================================================
# 进程监督（替代真机的 systemd 单元）
#   · hermes-gateway.service  → 本脚本 start_gateway（Restart=always / RestartSec=5）
#   · hermes-webui.service    → 本脚本 start_webui（After=gateway，同样自动拉起）
#   · 更新后重启 WebUI：updater 写标记 $HERMES_HOME/logs/.restart_webui，主循环检测即重启
#     （真机是因为 `hermes update` 后 WebUI 进程仍持有旧模块，表现为“能打开但不能对话”）
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

# ── agent 代码变更监视 ──────────────────────────────────────────────────────
# 真机上 `hermes update` 只负责换代码，是 systemd 的 Restart=always 顺手把 WebUI
# 重拉起来；否则进程里仍是旧模块 → “WebUI 能打开但不能对话”。
# 容器里没有 systemd，所以由这里盯 HEAD：无论是 updater 还是用户在 WebUI/Dashboard
# 里点更新，只要 $INSTALL_DIR 的 commit 变了，就刷新依赖并重启 WebUI / 网关。
agent_head() { git -C "$INSTALL_DIR" rev-parse HEAD 2>/dev/null || echo ''; }

refresh_webui_env() {
    local uv_bin
    uv_bin="$(command -v uv || ls -d "$HERMES_HOME"/tools/uv-*/bin/uv "$HERMES_HOME"/tools/uv-*/uv 2>/dev/null | head -1 || true)"
    [ -x "$uv_bin" ] || { log "WARNING: 找不到 uv，跳过依赖刷新"; touch "$RESTART_FLAG"; return 0; }
    log "刷新 WebUI 依赖（uv sync --locked，agent 代码已变更）"
    if ( cd "$INSTALL_DIR" && UV_PROJECT_ENVIRONMENT="${HERMES_INSTALL_DIR:-/app/src/Hermes}/venv" "$uv_bin" sync --locked --python 3.14 \
            $(python3 -c "import tomllib;o=tomllib.load(open('pyproject.toml','rb'))['project'].get('optional-dependencies',{});w=['all','messaging','otlp','anthropic','bedrock','azure-identity','matrix'];print(' '.join('--extra '+e for e in w if e in o))") >> "$LOG_DIR/deps.log" 2>&1 ); then
        log "依赖刷新完成 → 重启 WebUI"
    else
        log "WARNING: 依赖刷新失败（详见 deps.log），仍重启 WebUI"
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
    log "检测到 agent 代码变更 ${prev:0:8} → ${cur:0:8}（可能来自 WebUI/Dashboard 的更新按钮）"
    # 放到子 shell 里做，避免 uv sync 阻塞主循环（加锁防止并发）
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
    log "收到退出信号，清理子进程 …"
    stop_webui
    [ -n "${DASH_PID:-}" ] && kill -TERM "$DASH_PID" 2>/dev/null || true
    [ -n "${GW_PID:-}" ] && kill -TERM "$GW_PID" 2>/dev/null || true
    [ -n "${UPD_PIDS:-}" ] && kill -TERM $UPD_PIDS 2>/dev/null || true
    exit 0
}
trap cleanup TERM INT

# ── gateway（对应 hermes-gateway.service）────────────────────────────────────
start_gateway() {
    if [ "${HERMES_API_GW:-1}" != "1" ]; then return 0; fi
    if port_open "${API_SERVER_PORT:-8642}"; then
        log "网关 :${API_SERVER_PORT:-8642} 已在服务"; GW_PID=""; return 0
    fi
    local _key="${API_SERVER_KEY:-}"
    local key_len=${#_key}
    [ "$key_len" -ge 16 ] || log "ERROR: API_SERVER_KEY 仅 ${key_len} 位（官方要求 ≥16）→ api_server 不会启动"
    log "启动网关（bind=${API_SERVER_HOST:-0.0.0.0}:${API_SERVER_PORT:-8642}）"
    hermes gateway run --no-supervise --external-supervisor >> "$LOG_DIR/gateway.log" 2>&1 &
    GW_PID=$!
    log "网关 pid=$GW_PID"
    # api_server 需要预热（实测 10-120s），只做尽力探测，不阻塞
    local i code
    for i in $(seq 1 15); do
        code="$(curl -s -o /dev/null -w '%{http_code}' -m 2 -H "Authorization: Bearer ${API_SERVER_KEY:-}" \
            "http://127.0.0.1:${API_SERVER_PORT:-8642}/v1/models" 2>/dev/null || true)"
        case "$code" in 200|401) log "网关 :${API_SERVER_PORT:-8642} 就绪（/v1/models HTTP ${code}）"; return 0 ;; esac
        sleep 2
    done
    log "网关 :${API_SERVER_PORT:-8642} 启动中（api_server 预热通常 <2 分钟）"
}

# ── WebUI（对应 hermes-webui.service）───────────────────────────────────────
start_webui() {
    rm -f "$RESTART_FLAG"
    [ -x "$VENV" ] || { log "ERROR: WebUI python 不存在：$VENV"; return 0; }
    log "启动 WebUI（$VENV server.py，端口 ${HERMES_WEBUI_PORT:-8787}）"
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

# ── Dashboard（可选）────────────────────────────────────────────────────────
start_dashboard() {
    [ "${HERMES_DASHBOARD_ON:-0}" = "1" ] || return 0
    port_open "${HERMES_DASHBOARD_PORT:-9119}" && { DASH_PID=""; return 0; }
    log "启动 Dashboard :${HERMES_DASHBOARD_PORT:-9119}"
    hermes dashboard --host "${HERMES_DASHBOARD_HOST:-0.0.0.0}" \
        --port "${HERMES_DASHBOARD_PORT:-9119}" --skip-build --no-open \
        >> "$LOG_DIR/dashboard.log" 2>&1 &
    DASH_PID=$!
}

start_gateway
start_webui
start_dashboard

# 定时更新（对应真机的 48h 任务计划）
if [ "${UPDATE_AGENT_TIME:-0}" -gt 0 ] 2>/dev/null || [ "${UPDATE_WEBUI_TIME:-0}" -gt 0 ] 2>/dev/null; then
    /app/scripts/updater.sh >> "$LOG_DIR/updater.log" 2>&1 &
    UPD_PIDS=$!
    log "定时更新已启动（agent=${UPDATE_AGENT_TIME:-0}h webui=${UPDATE_WEBUI_TIME:-0}h）"
fi

WEBUI_READY_LOGGED=0
check_agent_head   # 记录基线 commit，避免首轮误判
while true; do
    check_agent_head
    if [ -f "$GW_RESTART_FLAG" ]; then
        rm -f "$GW_RESTART_FLAG"
        log "重启网关（agent 代码已变更）"
        [ -n "$GW_PID" ] && kill -TERM "$GW_PID" 2>/dev/null || true
        sleep 2; start_gateway
    fi
    if [ -f "$DASH_RESTART_FLAG" ]; then
        rm -f "$DASH_RESTART_FLAG"
        if [ "${HERMES_DASHBOARD_ON:-0}" = "1" ]; then
            log "重启 Dashboard（agent 代码已变更：它同样在进程内加载 agent 模块，不重启会显示旧版本/跑旧代码）"
            [ -n "$DASH_PID" ] && kill -TERM "$DASH_PID" 2>/dev/null || true
            pkill -f "dashboard --host" 2>/dev/null || true
            sleep 2; DASH_PID=""; start_dashboard
        fi
    fi
    if [ -f "$RESTART_FLAG" ]; then
        log "检测到更新重启标记 → 重启 WebUI"
        stop_webui; sleep 1; start_webui; continue
    fi
    if [ -n "$WEBUI_PID" ] && ! kill -0 "$WEBUI_PID" 2>/dev/null; then
        log "WARNING: WebUI 进程退出，5s 后重启（Restart=always）"
        sleep 5; start_webui; continue
    fi
    if [ -z "$WEBUI_PID" ]; then sleep 5; start_webui; continue; fi
    if [ "$WEBUI_READY_LOGGED" = "0" ] && port_open "${HERMES_WEBUI_PORT:-8787}"; then
        log "WebUI :${HERMES_WEBUI_PORT:-8787} 已就绪"; WEBUI_READY_LOGGED=1
    fi
    if [ "${HERMES_API_GW:-1}" = "1" ] && [ -n "$GW_PID" ] && ! kill -0 "$GW_PID" 2>/dev/null; then
        log "WARNING: 网关进程退出，5s 后重启（Restart=always）"
        sleep 5; start_gateway
    fi
    if [ "${HERMES_DASHBOARD_ON:-0}" = "1" ] && [ -n "$DASH_PID" ] && ! kill -0 "$DASH_PID" 2>/dev/null; then
        log "WARNING: Dashboard 进程退出，5s 后重启"
        sleep 5; start_dashboard
    fi
    sleep 2
done
