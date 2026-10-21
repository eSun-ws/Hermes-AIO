#!/usr/bin/env bash
# =============================================================================
# Hermes All-in-One v2 installer (the image only carries orchestration; hermes and
# the webui are installed online on first boot)
# -----------------------------------------------------------------------------
# Usage:
#   ./init.sh [-p password] [-hdd HERMES_HOME path] [-src source path] [-wsd workspace]
#             [-hdash 0|1] [-wport WebUI port] [-oport published port range]
#             [-y] [-n|--dry-run] [--skip-build] [--force]
#   ./init.sh -pw new-password   # change the WebUI / Dashboard password of a deployed instance
#
# Defaults always come from config/.env (created from config/.env.example on the first
# run); nothing is changed implicitly.
# Exit codes: 0 success / 1 argument or environment error / 2 container already exists (not deployed)
# =============================================================================
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONTAINER_NAME="hermes-allinone"
ENV_FILE="$PROJECT_DIR/config/.env"
EXAMPLE_ENV="$PROJECT_DIR/config/.env.example"
LOG_DIR="$PROJECT_DIR/config/.logs"

OPT_PASS=""; OPT_HDD=""; OPT_SRC=""; OPT_WSD=""; OPT_HDASH=""; OPT_WPORT=""; OPT_OPORT=""; OPT_PW=""
ASSUME_YES=0; DRY_RUN=0; SKIP_BUILD=0; FORCE=0

C_OK=$'\033[32m'; C_WARN=$'\033[33m'; C_ERR=$'\033[31m'; C_DIM=$'\033[2m'; C_END=$'\033[0m'
ok()   { printf '%s[ ok ]%s %s\n'   "$C_OK"   "$C_END" "$*"; }
warn() { printf '%s[warn]%s %s\n'   "$C_WARN" "$C_END" "$*"; }
err()  { printf '%s[fail]%s %s\n'   "$C_ERR"  "$C_END" "$*" >&2; }
step() { printf '\n%s==> %s%s\n'    "$C_DIM"  "$*" "$C_END"; }
die()  { err "$*"; exit 1; }
usage() { awk 'NR>2 && /^#/ {sub(/^# ?/,""); print; next} NR>2 {exit}' "${BASH_SOURCE[0]}" | sed '/^-\{5,\}$/d; /^=\{5,\}$/d'; exit 0; }

while [ $# -gt 0 ]; do
    case "$1" in
        -p)      [ $# -ge 2 ] || die "-p needs a password"; OPT_PASS="$2"; shift 2 ;;
        -pw)     [ $# -ge 2 ] || die "-pw needs a new password"; OPT_PW="$2"; shift 2 ;;
        -hdd)    [ $# -ge 2 ] || die "-hdd needs a directory"; OPT_HDD="$2"; shift 2 ;;
        -src)    [ $# -ge 2 ] || die "-src needs a directory"; OPT_SRC="$2"; shift 2 ;;
        -wsd)    [ $# -ge 2 ] || die "-wsd needs a directory"; OPT_WSD="$2"; shift 2 ;;
        -hdash)  [ $# -ge 2 ] || die "-hdash needs 0 or 1"; case "$2" in 0|1) ;; *) die "-hdash accepts only 0 or 1";; esac; OPT_HDASH="$2"; shift 2 ;;
        -wport)  [ $# -ge 2 ] || die "-wport needs a port"; case "$2" in ''|*[!0-9]*) die "-wport must be numeric";; esac; OPT_WPORT="$2"; shift 2 ;;
        -oport)  [ $# -ge 2 ] || die "-oport needs a port range"; case "$2" in *[!0-9-]*) die "-oport has an invalid format";; esac; OPT_OPORT="$2"; shift 2 ;;
        -y|--yes) ASSUME_YES=1; shift ;;
        -n|--dry-run) DRY_RUN=1; shift ;;
        --skip-build) SKIP_BUILD=1; shift ;;
        --force) FORCE=1; shift ;;
        -h|--help) usage ;;
        *) die "Unknown argument: $1 (use -h for usage)" ;;
    esac
done

env_get() { grep -m1 -E "^[[:space:]]*$1=" "$2" 2>/dev/null | sed -E "s/^[[:space:]]*$1=//" || true; }
upsert_env() {
    local k="$1" v="$2" f="${3:-$ENV_FILE}"
    [ -f "$f" ] || : > "$f"
    if grep -qE "^[[:space:]]*${k}=" "$f"; then
        awk -v k="$k" -v v="$v" '!d && $0 ~ "^[[:space:]]*"k"=" {print k"="v; d=1; next} {print}' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
    else
        printf '%s=%s\n' "$k" "$v" >> "$f"
    fi
}

abspath() { case "$1" in /*) printf '%s' "$1" ;; *) printf '%s' "$PROJECT_DIR/${1#./}" ;; esac; }
SRC_ENV="$ENV_FILE"; [ -f "$SRC_ENV" ] || SRC_ENV="$EXAMPLE_ENV"
[ -f "$SRC_ENV" ] || die "config/.env.example not found; run this from the project root"

SRC_DIR="$(abspath "${OPT_SRC:-$(env_get HOST_SRC_DIR "$SRC_ENV")}")"
DATA_DIR="$(abspath "${OPT_HDD:-$(env_get HOST_HERMES_HOME "$SRC_ENV")}")"
WS_DIR="$(abspath "${OPT_WSD:-$(env_get HOST_WORKSPACE "$SRC_ENV")}")"
WEBUI_PORT="${OPT_WPORT:-$(env_get HERMES_WEBUI_PORT "$SRC_ENV")}"; WEBUI_PORT="${WEBUI_PORT:-8787}"
DASH_ON="${OPT_HDASH:-$(env_get HERMES_DASHBOARD_ON "$SRC_ENV")}"; DASH_ON="${DASH_ON:-0}"
DASH_PORT="$(env_get HERMES_DASHBOARD_PORT "$SRC_ENV")"; DASH_PORT="${DASH_PORT:-9119}"
API_PORT="$(env_get API_SERVER_PORT "$SRC_ENV")"; API_PORT="${API_PORT:-8642}"
OPEN_PORT="${OPT_OPORT:-$(env_get OPEN_PORT "$SRC_ENV")}"; OPEN_PORT="${OPEN_PORT:-3111-3113}"

# ── Dependency probe ─────────────────────────────────────────────────────────
step "Checking dependencies"
command -v docker >/dev/null 2>&1 || die "docker is not installed"
docker info >/dev/null 2>&1 || die "the docker daemon is not reachable"
ok "docker: $(docker --version | awk '{print $3}' | tr -d ,)"
if docker compose version >/dev/null 2>&1; then COMPOSE_CMD="docker compose"
elif command -v docker-compose >/dev/null 2>&1; then COMPOSE_CMD="docker-compose"
else die "compose not found"; fi
ok "compose: $($COMPOSE_CMD version 2>/dev/null | head -1)"
if ! docker buildx version >/dev/null 2>&1; then
    if [ "$ASSUME_YES" = 1 ] && command -v apt-get >/dev/null 2>&1; then
        warn "buildx is missing, installing it because -y was given"; [ "$DRY_RUN" = 1 ] || apt-get install -y docker-buildx >/dev/null
    else die "the buildx plugin is missing: apt-get install -y docker-buildx (or pass -y)"; fi
fi
ok "buildx: $(docker buildx version 2>/dev/null | awk '{print $2}')"

compose() {
    if [ -f "$ENV_FILE" ]; then ( cd "$PROJECT_DIR" && $COMPOSE_CMD --env-file "$ENV_FILE" "$@" )
    else ( cd "$PROJECT_DIR" && $COMPOSE_CMD "$@" ); fi
}

# Migrate the legacy layout (root-level .env) automatically
if [ -f "$PROJECT_DIR/.env" ] && [ ! -f "$ENV_FILE" ]; then
    mkdir -p "$(dirname "$ENV_FILE")"; mv "$PROJECT_DIR/.env" "$ENV_FILE"
    ok "Moved the root-level .env to config/.env"
fi

LEAK="$(env | grep -oE '^HERMES_[A-Z_]+' | paste -sd' ' || true)"
if [ -n "$LEAK" ]; then
    err "This shell exports HERMES_* variables that would override .env: $LEAK"
    echo "  Run with a clean environment: env -i PATH=\$PATH HOME=\$HOME bash $0 $*"
    exit 1
fi
ok "No HERMES_* environment leak"

# ── -pw mode: change the password of a deployed instance ─────────────────────
wait_webui() {
    local port="$1" limit="${2:-120}" n=0 c="000"
    while [ "$n" -lt "$limit" ]; do
        c="$(curl -s -o /dev/null -w '%{http_code}' -m 3 "http://127.0.0.1:${port}/health" 2>/dev/null || true)"
        [ "$c" = "200" ] && { printf '200'; return 0; }
        n=$((n + 3)); sleep 3
    done
    printf '%s' "${c:-000}"
}
change_password() {
    local newpw="$1" data_dir oldpw code json_new json_old n_code o_code
    [ -n "$newpw" ] || die "-pw needs a new password"
    docker ps -a --filter "name=^${CONTAINER_NAME}$" --format '{{.Names}}' | grep -qx "$CONTAINER_NAME" \
        || die "container ${CONTAINER_NAME} not found: -pw only works on a deployed instance; use -p for the first deploy"
    data_dir="$(docker inspect "$CONTAINER_NAME" --format '{{range .Mounts}}{{if eq .Destination "/app/hermes-agent"}}{{.Source}}{{end}}{{end}}' 2>/dev/null || true)"
    [ -n "$data_dir" ] || die "cannot resolve the HERMES_HOME mount from the container"
    [ -f "$data_dir/.env" ] || die "$data_dir has no .env"
    ok "Data directory (from the container mount): $data_dir"
    oldpw="$(grep -m1 '^HERMES_WEBUI_PASSWORD=' "$data_dir/.env" | cut -d= -f2- || true)"
    cp -a "$data_dir/.env" "$data_dir/.env.bak-pw-$(date +%Y%m%d-%H%M%S)"
    upsert_env HERMES_WEBUI_PASSWORD "$newpw" "$data_dir/.env"
    upsert_env HERMES_DASHBOARD_BASIC_AUTH_PASSWORD "$newpw" "$data_dir/.env"
    upsert_env API_SERVER_KEY "$newpw" "$data_dir/.env"
    chmod 600 "$data_dir/.env" 2>/dev/null || true
    if [ -f "$ENV_FILE" ]; then
        upsert_env HERMES_WEBUI_PASSWORD "$newpw"
        upsert_env HERMES_DASHBOARD_BASIC_AUTH_PASSWORD "$newpw"
        ok "Also synced config/.env (compose-injected values take precedence)"
    fi
    ok "Recreating the container to load the new password (restart does not re-read compose env)"
    compose up -d --force-recreate >/dev/null
    code="$(wait_webui "$WEBUI_PORT" 180)"
    [ "$code" = "200" ] && ok "WebUI ready on :$WEBUI_PORT" || warn "WebUI :$WEBUI_PORT not ready (check docker logs)"
    json_new="$(python3 -c 'import json,sys;print(json.dumps({"password":sys.argv[1]}))' "$newpw")"
    n_code="$(curl -s -o /dev/null -w '%{http_code}' -m 8 -X POST "http://127.0.0.1:${WEBUI_PORT}/api/auth/login" -H 'Content-Type: application/json' -d "$json_new" || true)"
    [ "$n_code" = "200" ] && ok "WebUI: login with the new password succeeded" || warn "WebUI: login with the new password returned $n_code"
    if [ -n "$oldpw" ]; then
        json_old="$(python3 -c 'import json,sys;print(json.dumps({"password":sys.argv[1]}))' "$oldpw")"
        o_code="$(curl -s -o /dev/null -w '%{http_code}' -m 8 -X POST "http://127.0.0.1:${WEBUI_PORT}/api/auth/login" -H 'Content-Type: application/json' -d "$json_old" || true)"
        [ "$o_code" = "401" ] && ok "WebUI: the old password no longer works" || warn "WebUI: the old password returned $o_code (expected 401)"
    fi
    step "Password change complete"; echo "  WebUI http://<host>:${WEBUI_PORT}  password updated"; exit 0
}

if [ -n "$OPT_PW" ]; then step "-pw mode"; change_password "$OPT_PW"; fi

# ── Duplicate-deployment guard ───────────────────────────────────────────────
step "Checking whether this is already deployed"
if docker ps -a --filter "name=^${CONTAINER_NAME}$" --format '{{.Names}}' | grep -qx "$CONTAINER_NAME"; then
    STATUS="$(docker ps -a --filter "name=^${CONTAINER_NAME}$" --format '{{.Status}}')"
    if [ "$FORCE" != 1 ]; then
        err "Container ${CONTAINER_NAME} already exists ($STATUS); nothing was deployed."
        echo "  Reuse:  cd $PROJECT_DIR && $COMPOSE_CMD --env-file config/.env up -d"
        echo "  Creds:  docker logs ${CONTAINER_NAME} | grep -A6 \"login credentials\""
        echo "  Redo:   $0 --force"
        exit 2
    fi
    warn "Already exists ($STATUS) and --force was given: stopping and removing it"
    [ "$DRY_RUN" = 1 ] || compose down
fi
ok "No container with that name"

# ── Ports / disk ─────────────────────────────────────────────────────────────
step "Resource checks"
expand_ports() { case "$1" in *-*) local a="${1%-*}" b="${1#*-}"; seq "$a" "$b" ;; *) printf '%s\n' "$1" ;; esac; }
PORTS="$(printf '%s\n' "$WEBUI_PORT" "$DASH_PORT" "$API_PORT" | cat - <(expand_ports "$OPEN_PORT") | sort -un)"
LISTENING="$(ss -ltnH 2>/dev/null | awk '{print $4}' | sed -E 's/.*:([0-9]+)$/\1/' | sort -un)"
BUSY=""
for p in $PORTS; do if printf '%s\n' "$LISTENING" | grep -qx "$p"; then BUSY="$BUSY $p"; fi; done
[ -z "$BUSY" ] || die "ports already in use:$BUSY"
ok "Ports available: $(printf '%s' "$PORTS" | tr '\n' ' ')"
AVAIL_GB="$(df -Pk "$PROJECT_DIR" | awk 'NR==2{printf "%d", $4/1024/1024}')"
[ "${AVAIL_GB:-0}" -ge 20 ] || warn "Only ${AVAIL_GB} GB free (the first install needs ~8-10 GB for agent + webui + plugin)"
ok "Free disk: ${AVAIL_GB} GB"
[ "$DRY_RUN" = 1 ] || mkdir -p "$SRC_DIR" "$DATA_DIR" "$WS_DIR"
ok "Source directory:   $SRC_DIR"
ok "Data directory:     $DATA_DIR"
ok "Workspace:          $WS_DIR"

step "Deployment plan"
cat <<EOF
  Image       hermes-allinone-v2 (thin image; hermes + webui are installed online on first boot)
  WebUI       :$WEBUI_PORT    Dashboard: :$DASH_PORT ($([ "$DASH_ON" = 1 ] && echo enabled || echo disabled))
  API gateway :$API_PORT     published range: $OPEN_PORT
  Sources     $SRC_DIR   (hermes + webui; hermes update writes here)
  Data        $DATA_DIR  (HERMES_HOME: environments/tools/config/sessions)
  Workspace   $WS_DIR
  Password    $([ -n "$OPT_PASS" ] && echo "from the command line" || echo "empty = generated on first boot and printed to docker logs")
  First boot  online install, about 5-15 minutes (agent dependencies + webui + hindsight plugin)
EOF
if [ "$DRY_RUN" = 1 ]; then echo; ok "dry run finished (no files written, no build, nothing started)"; exit 0; fi

# ── Write config/.env ────────────────────────────────────────────────────────
step "Writing config/.env"
if [ ! -f "$ENV_FILE" ]; then cp "$EXAMPLE_ENV" "$ENV_FILE"; ok "Created from config/.env.example"; else ok "Keeping the existing config/.env"; fi
[ -n "$OPT_PASS"  ] && upsert_env HERMES_WEBUI_PASSWORD "$OPT_PASS"
[ -n "$OPT_SRC"   ] && upsert_env HOST_SRC_DIR "$SRC_DIR"
[ -n "$OPT_HDD"   ] && upsert_env HOST_HERMES_HOME "$DATA_DIR"
[ -n "$OPT_WSD"   ] && upsert_env HOST_WORKSPACE "$WS_DIR"
[ -n "$OPT_HDASH" ] && upsert_env HERMES_DASHBOARD_ON "$OPT_HDASH"
[ -n "$OPT_WPORT" ] && upsert_env HERMES_WEBUI_PORT "$OPT_WPORT"
[ -n "$OPT_OPORT" ] && upsert_env OPEN_PORT "$OPT_OPORT"
chmod 600 "$ENV_FILE" 2>/dev/null || true

# ── Root-level .env symlink (prevents the "bare up" incident) ────────────────
# Compose only auto-reads a PROJECT-ROOT .env for ${VAR} interpolation. If a manual
# `docker-compose down/up` forgets --env-file, every path falls back to its default:
# the volumes become ./src, ./hermes-data and ./workspace -> an empty HERMES_HOME ->
# the bootstrap decides "not installed" and reinstalls everything (python/npm/plugin
# dependencies), leaving the real data directory untouched on the side. Measured
# incident: the config pointed at HermesAgent/ndisk while the container mounted a
# freshly created hermes-data (2.4 GB wasted).
# Create a symlink to config/.env so even a bare compose command reads the same config.
if [ ! -e "$PROJECT_DIR/.env" ] && [ ! -L "$PROJECT_DIR/.env" ]; then
    ln -s config/.env "$PROJECT_DIR/.env" && ok "Created the root .env -> config/.env symlink (manual docker compose now resolves the right paths too)"
else
    ok "Root .env already exists (kept)"
fi

compose config >/dev/null || die "compose config rendering failed"
ok "compose config renders"

# ── Build and start ──────────────────────────────────────────────────────────
if [ "$SKIP_BUILD" = 1 ] && docker image inspect hermes-allinone-v2:latest >/dev/null 2>&1; then
    step "Skipping the build (--skip-build)"
else
    step "Building the image (thin image, usually 2-4 minutes)"
    mkdir -p "$LOG_DIR"
    compose build 2>&1 | tee "$LOG_DIR/build-$(date +%Y%m%d-%H%M%S).log" | tail -5
fi
step "Starting the container (the first start installs online and streams progress in the log)"
compose up -d
ok "Container started"

step "Waiting for the WebUI (the first install can take 5-15 minutes; waiting up to 20)"
CODE="$(wait_webui "$WEBUI_PORT" 1200)"
if [ "$CODE" = "200" ]; then ok "WebUI /health = 200"; else warn "WebUI not ready ($CODE): docker logs -f $CONTAINER_NAME"; fi

# API gateway probe (401 = listening)
api_state="disabled"
if [ "$(env_get HERMES_API_GW "$ENV_FILE")" = "1" ]; then
    n=0; acode="000"
    while [ "$n" -lt 60 ]; do
        acode="$(curl -s -o /dev/null -w '%{http_code}' -m 3 "http://127.0.0.1:${API_PORT}/v1/models" 2>/dev/null || true)"
        case "$acode" in 200|401) break ;; esac
        n=$((n + 3)); sleep 3
    done
    case "$acode" in
        200|401) ok "API gateway listening on :${API_PORT} (HTTP ${acode})"; api_state="ready" ;;
        *)       warn "API gateway :${API_PORT} not ready ($acode): check that API_SERVER_KEY is >=16 chars and API_SERVER_HOST=0.0.0.0" ;;
    esac
fi

IP="$(hostname -I 2>/dev/null | awk '{print $1}')"; IP="${IP:-127.0.0.1}"
step "Deployment complete"
echo "  WebUI       http://${IP}:${WEBUI_PORT}"
echo "  Dashboard   $([ "$DASH_ON" = 1 ] && echo "http://${IP}:${DASH_PORT}" || echo disabled)"
echo "  API gateway $([ "$api_state" = "disabled" ] && echo disabled || echo "http://${IP}:${API_PORT}/v1  ${api_state}")"
echo "  Sources     ${SRC_DIR}"
echo "  Data        ${DATA_DIR}"
CREDS="$(docker logs "$CONTAINER_NAME" 2>&1 | grep -A7 'login credentials' || true)"
if [ -n "$CREDS" ]; then echo; echo "$CREDS" | sed 's/^/  /'; else
    echo "  Password: docker logs ${CONTAINER_NAME} | grep -A7 \"login credentials\""; fi
echo
echo "  Logs:   docker logs -f ${CONTAINER_NAME}"
echo "  Stop:   cd $PROJECT_DIR && $COMPOSE_CMD --env-file config/.env down"
echo "  Redo:   $0 --force"
