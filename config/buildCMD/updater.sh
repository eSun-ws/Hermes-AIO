#!/bin/bash
# =============================================================================
# 定时更新（对应真机的 48 小时任务计划）
#   agent：hermes update --yes → 若 HEAD 真变了 → 重启 WebUI（真机上更新后
#          WebUI 能打开但不能对话，因为进程里还是旧模块）
#          紧接着执行一次 WebUI 自身的更新（真机流程：hermes 更新完再更新 webui）
#   webui：git fetch + 快进 → 重装 WebUI 依赖 → 重启 WebUI
# 间隔由 UPDATE_AGENT_TIME / UPDATE_WEBUI_TIME 控制（小时，0=关闭，默认 48）
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
    log "更新 WebUI 源码（当前 ${before:0:8}）"
    if ! git -C "$WEBUI_DIR" fetch --tags --force >>"$LOG_DIR/update-webui.log" 2>&1; then
        log "WARNING: WebUI git fetch 失败（网络？），本轮跳过"; return
    fi
    git -C "$WEBUI_DIR" merge --ff-only origin/HEAD >>"$LOG_DIR/update-webui.log" 2>&1 \
        || git -C "$WEBUI_DIR" reset --hard origin/HEAD >>"$LOG_DIR/update-webui.log" 2>&1 || true
    after="$(git -C "$WEBUI_DIR" rev-parse HEAD 2>/dev/null || echo '')"
    if [ "$before" = "$after" ]; then
        log "WebUI 无新提交"; return
    fi
    log "WebUI ${before:0:8} → ${after:0:8}，重装依赖"
    "$VENV" -m pip install --quiet -e "$WEBUI_DIR" >>"$LOG_DIR/update-webui.log" 2>&1 \
        || log "WARNING: WebUI 依赖重装失败（详见 update-webui.log）"
    touch "$RESTART_FLAG"
    log "已请求重启 WebUI 以加载新代码"
}

update_agent() {
    local before after
    before="$(git -C "$INSTALL_DIR" rev-parse HEAD 2>/dev/null || echo '')"
    log "执行 hermes update --yes（当前 ${before:0:8}）"
    if hermes update --yes >>"$LOG_DIR/update-agent.log" 2>&1; then
        after="$(git -C "$INSTALL_DIR" rev-parse HEAD 2>/dev/null || echo '')"
        log "hermes update 完成（${before:0:8} → ${after:0:8}）"
        if [ -n "$before" ] && [ -n "$after" ] && [ "$before" != "$after" ]; then
            log "Agent 代码已更新 → 重启 WebUI（否则进程内仍是旧模块，能打开但不能对话）"
            touch "$RESTART_FLAG"
            sleep 20   # 给 supervisor 时间完成重启
            update_webui
        fi
    else
        log "WARNING: hermes update 失败（详见 update-agent.log），下轮重试"
    fi
}

[ "$AGENT_H" = "0" ] && [ "$WEBUI_H" = "0" ] && { log "两个间隔都是 0，更新任务退出"; exit 0; }

# 首次执行前先等 5 分钟，避免和首启安装抢资源
sleep 300

next_agent=$(( $(date +%s) + AGENT_H * 3600 ))
next_webui=$(( $(date +%s) + WEBUI_H * 3600 ))

while true; do
    now=$(date +%s)
    if [ "$AGENT_H" != "0" ] && [ "$now" -ge "$next_agent" ]; then
        if net_ok; then update_agent; else log "网络不可达，跳过本轮 agent 更新"; fi
        next_agent=$(( $(date +%s) + AGENT_H * 3600 ))
    fi
    if [ "$WEBUI_H" != "0" ] && [ "$now" -ge "$next_webui" ]; then
        if net_ok; then update_webui; else log "网络不可达，跳过本轮 webui 更新"; fi
        next_webui=$(( $(date +%s) + WEBUI_H * 3600 ))
    fi
    sleep 60
done
