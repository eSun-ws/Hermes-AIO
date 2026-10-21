#!/bin/bash
# =============================================================================
# 首次启动引导（幂等）：把「真机安装流程」原样搬到容器里
# -----------------------------------------------------------------------------
# 顺序与真机一致：
#   1) 官方安装脚本（尊重 HERMES_HOME / HERMES_INSTALL_DIR）→ 源码 + pm 环境
#   2) WebUI：git clone 官方仓库（+ 预热 tags，避免“检测更新”15 秒超时）
#   3) WebUI 运行环境：$INSTALL_DIR/venv（uv sync --locked，与 WebUI 的自动发现路径
#      <agent_dir>/venv/bin/python 对齐），再把它装进同一个 venv
#   4) 写 WebUI 的 .env（对齐 hermes 的路径/端口/密码）
#   5) hindsight 插件（按需安装，不启用）
# 全部完成后写 .bootstrap-done；之后每次启动只做“存在性检查”，秒过。
#
# 为什么 WebUI 单独一个 venv：pm 的依赖环境在 $HERMES_HOME/installs 下，`hermes update`
# 会 `uv sync`（无 --inexact）修剪多余包 —— 把 WebUI 的依赖塞进 pm 环境会被剪掉。
# =============================================================================
set -euo pipefail

HERMES_HOME="${HERMES_HOME:-/app/hermes-agent}"
INSTALL_DIR="${HERMES_INSTALL_DIR:-/app/src/Hermes}"
WEBUI_DIR="${HERMES_WEBUI_DIR:-/app/src/WebUI}"
CHANNEL="${HERMES_CHANNEL:-stable}"
INSTALLER_URL="${HERMES_INSTALLER_URL:-https://hermes-agent.nousresearch.com/install.sh}"
VENV="$INSTALL_DIR/venv"
DONE_FLAG="$HERMES_HOME/.bootstrap-done"

log()  { echo "[bootstrap] $*"; }
ok()   { echo "[bootstrap] ✅ $*"; }
warn() { echo "[bootstrap] ⚠️  $*"; }
die()  { echo "[bootstrap] ❌ $*" >&2; exit 1; }

mkdir -p "$HERMES_HOME" "$INSTALL_DIR" "$WEBUI_DIR" "$HERMES_HOME/logs"
LOG="$HERMES_HOME/logs/bootstrap.log"

# ── 1) 官方安装脚本（源码 + pm 依赖环境）──────────────────────────────────────
if [ -d "$INSTALL_DIR/.git" ] && command -v hermes >/dev/null 2>&1; then
    ok "hermes 已安装，跳过官方安装（$(hermes --version 2>/dev/null | head -1)）"
else
    log "运行官方安装脚本（channel=$CHANNEL，HERMES_HOME=$HERMES_HOME，INSTALL_DIR=$INSTALL_DIR）"
    local_args=(--channel "$CHANNEL" --non-interactive)
    [ "${HERMES_SKIP_BROWSER:-0}" = "1" ] && local_args+=(--skip-browser)
    [ "${HERMES_SKIP_COMPUTER_USE:-0}" = "1" ] && local_args+=(--skip-computer-use)

    SCRIPT=/tmp/hermes-install.sh
    for i in 1 2 3; do
        if curl -fsSL -m 60 "$INSTALLER_URL" -o "$SCRIPT" && [ -s "$SCRIPT" ]; then break; fi
        warn "下载安装脚本失败（第 $i 次），5s 后重试"; sleep 5
        [ "$i" = 3 ] && die "无法下载官方安装脚本：$INSTALLER_URL"
    done

    log "安装脚本大小：$(wc -c <"$SCRIPT") 字节；开始安装（首次约 5-10 分钟）"
    if ! HERMES_HOME="$HERMES_HOME" HERMES_INSTALL_DIR="$INSTALL_DIR" \
            bash "$SCRIPT" "${local_args[@]}" 2>&1 | tee -a "$LOG" | sed -u "s/^/[install] /"; then
        die "官方安装脚本执行失败（完整日志：$LOG）"
    fi
    command -v hermes >/dev/null 2>&1 || export PATH="${HOME:-/root}/.local/bin:$PATH"
    command -v hermes >/dev/null 2>&1 || die "安装完成但找不到 hermes（检查 $HOME/.local/bin）"
    ok "hermes 安装完成：$(hermes --version 2>/dev/null | head -1)"
fi

# pm 托管 python（用于创建 WebUI 的 venv，保证与 agent 同一解释器版本）
PM_PY="$(ls -d "$HERMES_HOME"/tools/python-3.*-linux-*/bin/python3 2>/dev/null | head -1 || true)"
[ -n "$PM_PY" ] || die "找不到 pm 托管的 Python（$HERMES_HOME/tools），安装可能不完整"

# agent 仓库也预热一次 refs：WebUI 的「检测更新」对 agent 腿同样是 15s 硬超时，
# 首启后第一次 fetch 实测 16.1s（刚好越界）、第二次 1.3s。这里先跑一次，让用户
# 第一次点按钮就是热的（失败不阻断）。
if [ -d "$INSTALL_DIR/.git" ]; then
    log "预热 agent 仓库 refs（首次 fetch 约 15s）"
    git -C "$INSTALL_DIR" fetch --quiet --tags --force >/dev/null 2>&1 \
        && log "agent refs 已预热" || warn "agent refs 预热失败（不影响安装，之后点更新会慢一次）"
fi

# ── 2) WebUI 源码（+ tags 预热）──────────────────────────────────────────────
if [ -d "$WEBUI_DIR/.git" ]; then
    ok "WebUI 源码已存在：$(git -C "$WEBUI_DIR" rev-parse --short HEAD 2>/dev/null)"
else
    log "克隆 WebUI 源码 → $WEBUI_DIR"
    rm -rf "$WEBUI_DIR"; mkdir -p "$WEBUI_DIR"
    for i in 1 2 3; do
        git clone --depth 1 https://github.com/nesquena/hermes-webui.git "$WEBUI_DIR" && break
        warn "clone 失败（第 $i 次），5s 后重试"; sleep 5
        [ "$i" = 3 ] && die "WebUI 克隆失败"
    done
    ok "WebUI 克隆完成：$(git -C "$WEBUI_DIR" rev-parse --short HEAD)"
fi
# tags 预热：WebUI 的「检测更新」用 git fetch --tags，超时 15s（上游硬编码），
# 浅克隆首次拉 1800+ tags 要 38s → 必然超时；预热后运行时 fetch ~1s。
if [ "$(git -C "$WEBUI_DIR" tag 2>/dev/null | wc -l)" -lt 100 ]; then
    log "预热 WebUI tags（约 30-60s）"
    for i in 1 2 3; do
        git -C "$WEBUI_DIR" fetch --tags --depth 1 origin >/dev/null 2>&1 && break
        warn "tags 预热失败（第 $i 次）"; sleep 5
    done
    log "WebUI tags：$(git -C "$WEBUI_DIR" tag | wc -l)"
fi

# ── 3) WebUI 运行环境（$INSTALL_DIR/venv，与 WebUI 自动发现路径一致）─────────
# 判据要同时覆盖两侧依赖：只看 run_agent 会漏掉 WebUI 自己的运行库
# （fastapi / uvicorn / ruamel.yaml），现象是 server.py 启动即死、日志空白。
webui_env_ok() {
    "$VENV/bin/python" -c "import run_agent, fastapi, uvicorn, ruamel.yaml" >/dev/null 2>&1
}
if [ -x "$VENV/bin/python" ] && webui_env_ok; then
    ok "WebUI 运行环境已就绪（$VENV）"
else
    log "构建 WebUI 运行环境（uv sync --locked，含 python-olm 源码编译，约 3-6 分钟）"
    UV_BIN="$(command -v uv || ls -d "$HERMES_HOME"/tools/uv-*/bin/uv "$HERMES_HOME"/tools/uv-*/uv 2>/dev/null | head -1 || true)"
    [ -x "$UV_BIN" ] || die "找不到 uv（官方安装应把它放到 ~/.local/bin）"
    [ -x "$VENV/bin/python" ] || "$PM_PY" -m venv "$VENV"
    (
        cd "$INSTALL_DIR"
        UV_PROJECT_ENVIRONMENT="$VENV" "$UV_BIN" sync --locked --python 3.14 \
            $(python3 -c "import tomllib;o=tomllib.load(open('pyproject.toml','rb'))['project'].get('optional-dependencies',{});w=['all','messaging','otlp','anthropic','bedrock','azure-identity','matrix'];print(' '.join('--extra '+e for e in w if e in o))") \
            || { warn "uv sync 失败，回退为 pip 安装"; "$VENV/bin/python" -m pip install --quiet -e "$INSTALL_DIR"; }
        "$VENV/bin/python" -m pip install --quiet -e "$WEBUI_DIR" || warn "WebUI 依赖安装失败（稍后由本地 venv 兜底）"
    ) 2>&1 | tee -a "$LOG" | sed -u "s/^/[venv]    /"
    "$VENV/bin/python" -c "import run_agent, cryptography" >/dev/null 2>&1 \
        && ok "WebUI 运行环境就绪" || die "WebUI 运行环境构建失败（日志：$LOG）"
fi

# ── 4) WebUI 的 .env（对齐 hermes 路径/端口/密码）────────────────────────────
ENV_FILE="$WEBUI_DIR/.env"
touch "$ENV_FILE"; chmod 600 "$ENV_FILE"
upsert() {  # upsert KEY VALUE
    local k="$1" v="$2"
    if grep -qE "^[[:space:]]*${k}=" "$ENV_FILE"; then
        sed -i "s|^[[:space:]]*${k}=.*|${k}=${v}|" "$ENV_FILE"
    else
        printf '%s=%s\n' "$k" "$v" >> "$ENV_FILE"
    fi
}
upsert HERMES_WEBUI_AGENT_DIR  "$INSTALL_DIR"
upsert HERMES_WEBUI_PYTHON     "$VENV/bin/python"
upsert HERMES_WEBUI_HOST       "${HERMES_WEBUI_HOST:-0.0.0.0}"
upsert HERMES_WEBUI_PORT       "${HERMES_WEBUI_PORT:-8787}"
upsert HERMES_WEBUI_BOT_NAME   "${HERMES_WEBUI_BOT_NAME:-Hermes}"
upsert HERMES_CONFIG_PATH      "$HERMES_HOME/config.yaml"
upsert HERMES_HOME             "$HERMES_HOME"
[ -n "${HERMES_WEBUI_PASSWORD:-}" ] && upsert HERMES_WEBUI_PASSWORD "$HERMES_WEBUI_PASSWORD"
ok "WebUI 配置就绪：$ENV_FILE"


# ── 4.5) WebUI 设置：默认不让它去检测/更新 agent ─────────────────────────────
# 为什么必须在这里做：
#   · 上游 WebUI 的更新按钮对 agent 腿把 channel 强制成 stable，但随后的
#     `_select_apply_compare_ref()` 会“分支兜底”到 `git pull --ff-only origin/main`
#     —— 即按开发线拉，完全绕过 agent 自己的通道设置（实测会从 v0.22.2 跳到
#     rc.5-v0.22.3-1-g69c7d677a1，领先 3017 个提交）。
#   · 想让它“跟随 Hermes 的版本线”必须改 vendor 代码（`api/updates.py`），会在
#     WebUI 自身升级时被覆盖，不可持续。
#   · 上游没有提供 env 开关，唯一受支持的开关是 settings.json 的
#     `ignore_agent_updates`（Settings 里叫 “Ignore Agent updates”）。
# 所以默认打开它：WebUI 只检查/更新自己，agent 一律由 `hermes update`（stable，48h 定时）驱动。
# 变量 WEBUI_IGNORE_AGENT_UPDATES=1 开启（默认），=0 则恢复 WebUI 也会检查 agent。
seed_webui_settings() {
    local want="${WEBUI_IGNORE_AGENT_UPDATES:-1}"
    local dir="${HERMES_WEBUI_STATE_DIR:-$HERMES_HOME/webui}"
    local file="$dir/settings.json"
    mkdir -p "$dir"
    python3 - "$file" "$want" <<'PYSEED'
import json, os, pathlib, sys

path, want_raw = sys.argv[1], sys.argv[2]
want = str(want_raw).strip().lower() not in ("0", "false", "no", "off", "")
p = pathlib.Path(path)
data = {}
if p.exists():
    try:
        loaded = json.loads(p.read_text(encoding="utf-8"))
        if isinstance(loaded, dict):
            data = loaded
    except Exception:
        data = {}
if data.get("ignore_agent_updates") is want:
    print("[bootstrap] WebUI 设置已是 ignore_agent_updates=%s" % want)
    sys.exit(0)
data["ignore_agent_updates"] = want
tmp = p.with_name(p.name + ".tmp")
tmp.write_text(json.dumps(data, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
os.replace(tmp, p)
print("[bootstrap] 已写入 WebUI 设置 ignore_agent_updates=%s → %s" % (want, p))
PYSEED
}

seed_webui_settings

# ── 5) hindsight 插件（源码 + 依赖分开处理）──────────────────────────────────
# ⚠ 实测关键事实：
#   1) `hermes plugins install` 只克隆插件源码，**不装 Python 依赖**；插件声明的
#      hindsight-client / hindsight-embed（约 400 MB）是在 `hermes plugins enable`
#      时才被创建到 installs/<key>/environments/<hash>/venv。传 --no-enable 会让
#      Dashboard 永远显示 "Install provider dependencies"。
#   2) 不能用 `installs/*/environments` 判断"已安装"——那是 agent 自己的环境，恒存在。
#      正确判据：某个环境里能否 import hindsight_client。
#   3) `plugins enable` 只启用插件，不写 memory.provider；provider 仍由用户在
#      Dashboard 里选择（保持"装好但不激活"）。
hindsight_deps_ready() {
    local py
    for py in "$HERMES_HOME"/installs/*/environments/*/venv/bin/python; do
        [ -x "$py" ] || continue
        "$py" -c 'import hindsight_client' >/dev/null 2>&1 && return 0
    done
    return 1
}

if [ "${HINDSIGHT_PLUGIN:-on}" = "off" ]; then
    log "HINDSIGHT_PLUGIN=off，跳过 hindsight 插件"
else
    if [ -d "$HERMES_HOME/plugins/hindsight" ]; then
        ok "hindsight 插件源码已存在"
    else
        log "安装 hindsight 插件源码（仅克隆）"
        if hermes plugins install hindsight --yes-deps --no-enable >>"$LOG" 2>&1; then
            ok "hindsight 插件源码就位"
        else
            warn "hindsight 插件安装失败（稍后可重试：hermes plugins install hindsight）"
        fi
    fi

    # 依赖：HINDSIGHT_PREPARE（旧名 HINDSIGHT_ENABLE 仍兼容），默认 1 = 首启就装好
    PREPARE="${HINDSIGHT_PREPARE:-${HINDSIGHT_ENABLE:-1}}"
    if hindsight_deps_ready; then
        ok "hindsight 依赖已就绪"
    elif [ "$PREPARE" = "1" ]; then
        log "准备 hindsight 依赖（plugins enable，约 400MB / 数分钟）"
        if hermes plugins enable hindsight >>"$LOG" 2>&1 && hindsight_deps_ready; then
            ok "hindsight 依赖就绪"
        else
            warn "hindsight 依赖未装好：可在 Dashboard 点 “Install provider dependencies”，或执行 hermes plugins enable hindsight"
        fi
    else
        log "HINDSIGHT_PREPARE=0：跳过依赖安装（首次启用时由 Dashboard 提示安装）"
    fi
fi

date '+%F %T' > "$DONE_FLAG"
ok "首次引导完成（标记：$DONE_FLAG）"
