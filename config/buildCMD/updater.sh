#!/bin/bash
# =============================================================================
# Scheduled updates (equivalent of the bare-metal 48-hour task)
#   agent: hermes update --yes -> if HEAD really changed -> restart the WebUI (on bare
#          metal the WebUI opens but cannot chat after an update, because the process
#          still holds the old modules); immediately afterwards run the WebUI's own
#          update (bare-metal order: update hermes, then update the webui)
#   webui: git fetch + fast-forward -> reinstall WebUI dependencies -> restart WebUI
# The interval is controlled by UPDATE_AGENT_TIME / UPDATE_WEBUI_TIME
# (hours, 0 = disabled, default 48)
# =============================================================================
set -uo pipefail

HERMES_HOME="${HERMES_HOME:-/app/hermes-agent}"
INSTALL_DIR="${HERMES_INSTALL_DIR:-/app/src/Hermes}"
WEBUI_DIR="${HERMES_WEBUI_DIR:-/app/src/WebUI}"
VENV="${HERMES_WEBUI_PYTHON:-$INSTALL_DIR/venv/bin/python}"
LOG_DIR="$HERMES_HOME/logs"
RESTART_FLAG="$LOG_DIR/.restart_webui"
mkdir -p "$LOG_DIR"

AGENT_H="${UPDATE_AGENT_TIME:-0}"
WEBUI_H="${UPDATE_WEBUI_TIME:-0}"
case "$AGENT_H" in ''|*[!0-9]*) AGENT_H=0 ;; esac
case "$WEBUI_H" in ''|*[!0-9]*) WEBUI_H=0 ;; esac

log() { echo "[updater] $(date '+%F %T') $*"; }

net_ok() { curl -fsS --connect-timeout 8 --max-time 15 -o /dev/null https://github.com 2>/dev/null; }

update_webui() {
    local before after
    before="$(git -C "$WEBUI_DIR" rev-parse HEAD 2>/dev/null || echo '')"
    log "Updating the WebUI sources (currently ${before:0:8})"
    if ! git -C "$WEBUI_DIR" fetch --tags --force >>"$LOG_DIR/update-webui.log" 2>&1; then
        log "WARNING: WebUI git fetch failed (network?), skipping this round"; return
    fi
    git -C "$WEBUI_DIR" merge --ff-only origin/HEAD >>"$LOG_DIR/update-webui.log" 2>&1 \
        || git -C "$WEBUI_DIR" reset --hard origin/HEAD >>"$LOG_DIR/update-webui.log" 2>&1 || true
    after="$(git -C "$WEBUI_DIR" rev-parse HEAD 2>/dev/null || echo '')"
    if [ "$before" = "$after" ]; then
        log "WebUI has no new commits"; return
    fi
    log "WebUI ${before:0:8} -> ${after:0:8}, reinstalling dependencies"
    "$VENV" -m pip install --quiet -e "$WEBUI_DIR" >>"$LOG_DIR/update-webui.log" 2>&1 \
        || log "WARNING: reinstalling WebUI dependencies failed (see update-webui.log)"
    touch "$RESTART_FLAG"
    log "Requested a WebUI restart to load the new code"
}

update_agent() {
    local before after
    before="$(git -C "$INSTALL_DIR" rev-parse HEAD 2>/dev/null || echo '')"
    log "Running hermes update --yes (currently ${before:0:8})"
    if hermes update --yes >>"$LOG_DIR/update-agent.log" 2>&1; then
        after="$(git -C "$INSTALL_DIR" rev-parse HEAD 2>/dev/null || echo '')"
        log "hermes update finished (${before:0:8} -> ${after:0:8})"
        if [ -n "$before" ] && [ -n "$after" ] && [ "$before" != "$after" ]; then
            log "Agent code was updated -> restarting the WebUI (otherwise the process keeps the old modules: opens but cannot chat)"
            touch "$RESTART_FLAG"
            sleep 20   # give the supervisor time to finish the restart
            update_webui
        fi
    else
        log "WARNING: hermes update failed (see update-agent.log); retrying next round"
    fi
}

[ "$AGENT_H" = "0" ] && [ "$WEBUI_H" = "0" ] && { log "Both intervals are 0, the updater exits"; exit 0; }

# Wait 5 minutes before the first run so it does not compete with the first-boot install
sleep 300

next_agent=$(( $(date +%s) + AGENT_H * 3600 ))
next_webui=$(( $(date +%s) + WEBUI_H * 3600 ))

while true; do
    now=$(date +%s)
    if [ "$AGENT_H" != "0" ] && [ "$now" -ge "$next_agent" ]; then
        if net_ok; then update_agent; else log "Network unreachable, skipping this agent update round"; fi
        next_agent=$(( $(date +%s) + AGENT_H * 3600 ))
    fi
    if [ "$WEBUI_H" != "0" ] && [ "$now" -ge "$next_webui" ]; then
        if net_ok; then update_webui; else log "Network unreachable, skipping this webui update round"; fi
        next_webui=$(( $(date +%s) + WEBUI_H * 3600 ))
    fi
    sleep 60
done
