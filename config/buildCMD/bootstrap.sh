#!/bin/bash
# =============================================================================
# First-boot bootstrap (idempotent): reproduces the bare-metal install flow inside
# the container
# -----------------------------------------------------------------------------
# Same order as bare metal:
#   1) official installer (honors HERMES_HOME / HERMES_INSTALL_DIR) -> sources + pm env
#   2) WebUI: git clone the official repo (+ tag pre-warm, so the "check for updates"
#      15-second timeout never triggers)
#   3) WebUI runtime: $INSTALL_DIR/venv (uv sync --locked, aligned with the path the
#      WebUI auto-discovers: <agent_dir>/venv/bin/python), then install the WebUI into
#      that same venv
#   4) write the WebUI .env (paths / port / password matching hermes)
#   5) hindsight plugin (installed on demand, provider not activated)
# When everything is done we write .bootstrap-done; later starts only run existence
# checks and pass in milliseconds.
#
# Why the WebUI gets its own venv: pm keeps its environments under
# $HERMES_HOME/installs and `hermes update` runs `uv sync` (without --inexact), which
# prunes extraneous packages -- WebUI dependencies placed in the pm environment would
# be deleted.
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

# ── 1) Official installer (sources + pm dependency environment) ────────────────
if [ -d "$INSTALL_DIR/.git" ] && command -v hermes >/dev/null 2>&1; then
    ok "hermes is already installed, skipping the official installer ($(hermes --version 2>/dev/null | head -1))"
else
    log "Running the official installer (channel=$CHANNEL, HERMES_HOME=$HERMES_HOME, INSTALL_DIR=$INSTALL_DIR)"
    local_args=(--channel "$CHANNEL" --non-interactive)
    [ "${HERMES_SKIP_BROWSER:-0}" = "1" ] && local_args+=(--skip-browser)
    [ "${HERMES_SKIP_COMPUTER_USE:-0}" = "1" ] && local_args+=(--skip-computer-use)

    SCRIPT=/tmp/hermes-install.sh
    for i in 1 2 3; do
        if curl -fsSL -m 60 "$INSTALLER_URL" -o "$SCRIPT" && [ -s "$SCRIPT" ]; then break; fi
        warn "Downloading the installer failed (attempt $i), retrying in 5s"; sleep 5
        [ "$i" = 3 ] && die "Cannot download the official installer: $INSTALLER_URL"
    done

    log "Installer size: $(wc -c <"$SCRIPT") bytes; starting the install (5-10 minutes on first run)"
    if ! HERMES_HOME="$HERMES_HOME" HERMES_INSTALL_DIR="$INSTALL_DIR" \
            bash "$SCRIPT" "${local_args[@]}" 2>&1 | tee -a "$LOG" | sed -u "s/^/[install] /"; then
        die "The official installer failed (full log: $LOG)"
    fi
    command -v hermes >/dev/null 2>&1 || export PATH="${HOME:-/root}/.local/bin:$PATH"
    command -v hermes >/dev/null 2>&1 || die "Install finished but hermes is not on PATH (check $HOME/.local/bin)"
    ok "hermes installed: $(hermes --version 2>/dev/null | head -1)"
fi

# pm-managed python (used to create the WebUI venv so both share one interpreter version)
PM_PY="$(ls -d "$HERMES_HOME"/tools/python-3.*-linux-*/bin/python3 2>/dev/null | head -1 || true)"
[ -n "$PM_PY" ] || die "Cannot find the pm-managed Python ($HERMES_HOME/tools); the install looks incomplete"

# Pre-warm the agent repo's refs as well: the WebUI's "check for updates" applies the
# same hard-coded 15s timeout to the agent leg. Measured: the first fetch after first
# boot takes 16.1s (just over the limit), the second 1.3s. Running it here means the
# user's first button click is already warm (failure is not fatal).
if [ -d "$INSTALL_DIR/.git" ]; then
    log "Pre-warming agent repo refs (first fetch takes ~15s)"
    git -C "$INSTALL_DIR" fetch --quiet --tags --force >/dev/null 2>&1 \
        && log "agent refs pre-warmed" || warn "agent refs pre-warm failed (harmless; the first update click will be slow once)"
fi

# ── 2) WebUI sources (+ tag pre-warm) ─────────────────────────────────────────
if [ -d "$WEBUI_DIR/.git" ]; then
    ok "WebUI sources already present: $(git -C "$WEBUI_DIR" rev-parse --short HEAD 2>/dev/null)"
else
    log "Cloning WebUI sources -> $WEBUI_DIR"
    rm -rf "$WEBUI_DIR"; mkdir -p "$WEBUI_DIR"
    for i in 1 2 3; do
        git clone --depth 1 https://github.com/nesquena/hermes-webui.git "$WEBUI_DIR" && break
        warn "clone failed (attempt $i), retrying in 5s"; sleep 5
        [ "$i" = 3 ] && die "WebUI clone failed"
    done
    ok "WebUI cloned: $(git -C "$WEBUI_DIR" rev-parse --short HEAD)"
fi
# Tag pre-warm: the WebUI's "check for updates" runs git fetch --tags with a 15s
# timeout (hard-coded upstream); a shallow clone's first fetch of 1800+ tags needs
# 38s, so it always times out. After the pre-warm the runtime fetch takes ~1s.
if [ "$(git -C "$WEBUI_DIR" tag 2>/dev/null | wc -l)" -lt 100 ]; then
    log "Pre-warming WebUI tags (30-60s)"
    for i in 1 2 3; do
        git -C "$WEBUI_DIR" fetch --tags --depth 1 origin >/dev/null 2>&1 && break
        warn "tag pre-warm failed (attempt $i)"; sleep 5
    done
    log "WebUI tags: $(git -C "$WEBUI_DIR" tag | wc -l)"
fi

# ── 3) WebUI runtime ($INSTALL_DIR/venv, matching the WebUI's auto-discovery) ──
# The probe must cover both sides: checking run_agent alone misses the WebUI's own
# runtime libraries (fastapi / uvicorn / ruamel.yaml), and the symptom is server.py
# dying on startup with an empty log.
webui_env_ok() {
    "$VENV/bin/python" -c "import run_agent, fastapi, uvicorn, ruamel.yaml" >/dev/null 2>&1
}
if [ -x "$VENV/bin/python" ] && webui_env_ok; then
    ok "WebUI runtime already ready ($VENV)"
else
    log "Building the WebUI runtime (uv sync --locked, includes the python-olm source build, 3-6 minutes)"
    UV_BIN="$(command -v uv || ls -d "$HERMES_HOME"/tools/uv-*/bin/uv "$HERMES_HOME"/tools/uv-*/uv 2>/dev/null | head -1 || true)"
    [ -x "$UV_BIN" ] || die "Cannot find uv (the official installer should place it in ~/.local/bin)"
    [ -x "$VENV/bin/python" ] || "$PM_PY" -m venv "$VENV"
    (
        cd "$INSTALL_DIR"
        UV_PROJECT_ENVIRONMENT="$VENV" "$UV_BIN" sync --locked --python 3.14 \
            $(python3 -c "import tomllib;o=tomllib.load(open('pyproject.toml','rb'))['project'].get('optional-dependencies',{});w=['all','messaging','otlp','anthropic','bedrock','azure-identity','matrix'];print(' '.join('--extra '+e for e in w if e in o))") \
            || { warn "uv sync failed, falling back to pip"; "$VENV/bin/python" -m pip install --quiet -e "$INSTALL_DIR"; }
        "$VENV/bin/python" -m pip install --quiet -e "$WEBUI_DIR" || warn "Installing WebUI dependencies failed (the local venv covers it later)"
    ) 2>&1 | tee -a "$LOG" | sed -u "s/^/[venv]    /"
    "$VENV/bin/python" -c "import run_agent, cryptography" >/dev/null 2>&1 \
        && ok "WebUI runtime ready" || die "Building the WebUI runtime failed (log: $LOG)"
fi

# ── 4) WebUI .env (paths / port / password matching hermes) ───────────────────
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
ok "WebUI configuration ready: $ENV_FILE"


# ── 4.5) WebUI settings: do not let it check/update the agent by default ──────
# Why this has to happen here:
#   * The upstream WebUI update button pins the agent leg to the stable channel, but
#     `_select_apply_compare_ref()` then falls through to
#     `git pull --ff-only origin/main` -- i.e. it pulls the development line and
#     completely bypasses the agent's own channel setting (measured: v0.22.2 jumps to
#     rc.5-v0.22.3-1-g69c7d677a1, 3017 commits ahead).
#   * Making it "follow Hermes' release line" requires patching vendor code
#     (`api/updates.py`), which the next WebUI update overwrites -- not sustainable.
#   * Upstream exposes no environment switch; the only supported one is
#     `ignore_agent_updates` in settings.json (called "Ignore Agent updates" in Settings).
# So we turn it on by default: the WebUI only checks/updates itself and the agent is
# driven exclusively by `hermes update` (stable, 48h schedule).
# WEBUI_IGNORE_AGENT_UPDATES=1 enables it (default); =0 restores upstream behaviour
# where the WebUI also checks the agent.
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
    print("[bootstrap] WebUI setting already is ignore_agent_updates=%s" % want)
    sys.exit(0)
data["ignore_agent_updates"] = want
tmp = p.with_name(p.name + ".tmp")
tmp.write_text(json.dumps(data, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
os.replace(tmp, p)
print("[bootstrap] Wrote WebUI setting ignore_agent_updates=%s -> %s" % (want, p))
PYSEED
}

seed_webui_settings

# ── 5) hindsight plugin (source and dependencies handled separately) ──────────
# WARNING -- measured facts:
#   1) `hermes plugins install` only clones the plugin source and does **not** install
#      Python dependencies. The declared hindsight-client / hindsight-embed (~400 MB)
#      are created under installs/<key>/environments/<hash>/venv only when
#      `hermes plugins enable` runs. Passing --no-enable leaves the Dashboard showing
#      "Install provider dependencies" forever.
#   2) Do not use `installs/*/environments` to decide "already installed" -- that is
#      the agent's own environment and always exists. Correct probe: can some
#      environment `import hindsight_client`.
#   3) `plugins enable` only enables the plugin and never writes memory.provider; the
#      provider is still chosen by the user in the Dashboard (stays "installed but not
#      activated").
hindsight_deps_ready() {
    local py
    for py in "$HERMES_HOME"/installs/*/environments/*/venv/bin/python; do
        [ -x "$py" ] || continue
        "$py" -c 'import hindsight_client' >/dev/null 2>&1 && return 0
    done
    return 1
}

if [ "${HINDSIGHT_PLUGIN:-on}" = "off" ]; then
    log "HINDSIGHT_PLUGIN=off, skipping the hindsight plugin"
else
    if [ -d "$HERMES_HOME/plugins/hindsight" ]; then
        ok "hindsight plugin source already present"
    else
        log "Installing the hindsight plugin source (clone only)"
        if hermes plugins install hindsight --yes-deps --no-enable >>"$LOG" 2>&1; then
            ok "hindsight plugin source in place"
        else
            warn "hindsight plugin install failed (retry later: hermes plugins install hindsight)"
        fi
    fi

    # Dependencies: HINDSIGHT_PREPARE (legacy name HINDSIGHT_ENABLE still honored),
    # default 1 = install them during first boot
    PREPARE="${HINDSIGHT_PREPARE:-${HINDSIGHT_ENABLE:-1}}"
    if hindsight_deps_ready; then
        ok "hindsight dependencies already present"
    elif [ "$PREPARE" = "1" ]; then
        log "Preparing hindsight dependencies (plugins enable, ~400MB / a few minutes)"
        if hermes plugins enable hindsight >>"$LOG" 2>&1 && hindsight_deps_ready; then
            ok "hindsight dependencies ready"
        else
            warn "hindsight dependencies are not ready: click \"Install provider dependencies\" in the Dashboard, or run hermes plugins enable hindsight"
        fi
    else
        log "HINDSIGHT_PREPARE=0: skipping dependency install (the Dashboard offers it on first enable)"
    fi
fi

date '+%F %T' > "$DONE_FLAG"
ok "First-boot bootstrap complete (marker: $DONE_FLAG)"
