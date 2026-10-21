#!/usr/bin/env bash
# =============================================================================
# Hermes All-in-One v2 安装脚本（镜像只含流程；hermes/webui 首启在线安装）
# -----------------------------------------------------------------------------
# 用法:
#   ./init.sh [-p 密码] [-hdd HERMES_HOME路径] [-src 源码路径] [-wsd 工作区]
#             [-hdash 0|1] [-wport WebUI端口] [-oport 开放端口段]
#             [-y] [-n|--dry-run] [--skip-build] [--force]
#   ./init.sh -pw 新密码        # 改已部署实例的 WebUI / Dashboard 密码
#
# 缺省值一律来自 config/.env（首次由 config/.env.example 复制），不做隐式改动。
# 退出码: 0 成功 / 1 参数或环境错误 / 2 已存在容器（未部署）
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
        -p)      [ $# -ge 2 ] || die "-p 需要密码"; OPT_PASS="$2"; shift 2 ;;
        -pw)     [ $# -ge 2 ] || die "-pw 需要新密码"; OPT_PW="$2"; shift 2 ;;
        -hdd)    [ $# -ge 2 ] || die "-hdd 需要目录"; OPT_HDD="$2"; shift 2 ;;
        -src)    [ $# -ge 2 ] || die "-src 需要目录"; OPT_SRC="$2"; shift 2 ;;
        -wsd)    [ $# -ge 2 ] || die "-wsd 需要目录"; OPT_WSD="$2"; shift 2 ;;
        -hdash)  [ $# -ge 2 ] || die "-hdash 需要 0/1"; case "$2" in 0|1) ;; *) die "-hdash 只接受 0 或 1";; esac; OPT_HDASH="$2"; shift 2 ;;
        -wport)  [ $# -ge 2 ] || die "-wport 需要端口"; case "$2" in ''|*[!0-9]*) die "-wport 必须是数字";; esac; OPT_WPORT="$2"; shift 2 ;;
        -oport)  [ $# -ge 2 ] || die "-oport 需要端口段"; case "$2" in *[!0-9-]*) die "-oport 格式非法";; esac; OPT_OPORT="$2"; shift 2 ;;
        -y|--yes) ASSUME_YES=1; shift ;;
        -n|--dry-run) DRY_RUN=1; shift ;;
        --skip-build) SKIP_BUILD=1; shift ;;
        --force) FORCE=1; shift ;;
        -h|--help) usage ;;
        *) die "未知参数: $1（-h 查看用法）" ;;
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
[ -f "$SRC_ENV" ] || die "找不到 config/.env.example，请在项目根目录运行"

SRC_DIR="$(abspath "${OPT_SRC:-$(env_get HOST_SRC_DIR "$SRC_ENV")}")"
DATA_DIR="$(abspath "${OPT_HDD:-$(env_get HOST_HERMES_HOME "$SRC_ENV")}")"
WS_DIR="$(abspath "${OPT_WSD:-$(env_get HOST_WORKSPACE "$SRC_ENV")}")"
WEBUI_PORT="${OPT_WPORT:-$(env_get HERMES_WEBUI_PORT "$SRC_ENV")}"; WEBUI_PORT="${WEBUI_PORT:-8787}"
DASH_ON="${OPT_HDASH:-$(env_get HERMES_DASHBOARD_ON "$SRC_ENV")}"; DASH_ON="${DASH_ON:-0}"
DASH_PORT="$(env_get HERMES_DASHBOARD_PORT "$SRC_ENV")"; DASH_PORT="${DASH_PORT:-9119}"
API_PORT="$(env_get API_SERVER_PORT "$SRC_ENV")"; API_PORT="${API_PORT:-8642}"
OPEN_PORT="${OPT_OPORT:-$(env_get OPEN_PORT "$SRC_ENV")}"; OPEN_PORT="${OPEN_PORT:-3111-3113}"

# ── 依赖探测 ────────────────────────────────────────────────────────────────
step "探测依赖"
command -v docker >/dev/null 2>&1 || die "未安装 docker"
docker info >/dev/null 2>&1 || die "docker 守护进程不可用"
ok "docker: $(docker --version | awk '{print $3}' | tr -d ,)"
if docker compose version >/dev/null 2>&1; then COMPOSE_CMD="docker compose"
elif command -v docker-compose >/dev/null 2>&1; then COMPOSE_CMD="docker-compose"
else die "未找到 compose"; fi
ok "compose: $($COMPOSE_CMD version 2>/dev/null | head -1)"
if ! docker buildx version >/dev/null 2>&1; then
    if [ "$ASSUME_YES" = 1 ] && command -v apt-get >/dev/null 2>&1; then
        warn "缺少 buildx，按 -y 自动安装"; [ "$DRY_RUN" = 1 ] || apt-get install -y docker-buildx >/dev/null
    else die "缺少 buildx 插件：apt-get install -y docker-buildx（或加 -y）"; fi
fi
ok "buildx: $(docker buildx version 2>/dev/null | awk '{print $2}')"

compose() {
    if [ -f "$ENV_FILE" ]; then ( cd "$PROJECT_DIR" && $COMPOSE_CMD --env-file "$ENV_FILE" "$@" )
    else ( cd "$PROJECT_DIR" && $COMPOSE_CMD "$@" ); fi
}

# 老布局（根目录 .env）自动迁移
if [ -f "$PROJECT_DIR/.env" ] && [ ! -f "$ENV_FILE" ]; then
    mkdir -p "$(dirname "$ENV_FILE")"; mv "$PROJECT_DIR/.env" "$ENV_FILE"
    ok "已把根目录 .env 迁移到 config/.env"
fi

LEAK="$(env | grep -oE '^HERMES_[A-Z_]+' | paste -sd' ' || true)"
if [ -n "$LEAK" ]; then
    err "当前 shell 导出了 HERMES_* 变量，会覆盖 .env：$LEAK"
    echo "  用干净环境运行： env -i PATH=\$PATH HOME=\$HOME bash $0 $*"
    exit 1
fi
ok "无 HERMES_* 环境变量泄漏"

# ── -pw 模式：改已部署实例的密码 ────────────────────────────────────────────
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
    [ -n "$newpw" ] || die "-pw 需要新密码"
    docker ps -a --filter "name=^${CONTAINER_NAME}$" --format '{{.Names}}' | grep -qx "$CONTAINER_NAME" \
        || die "未找到容器 ${CONTAINER_NAME}：-pw 只用于已部署实例；首次部署用 -p"
    data_dir="$(docker inspect "$CONTAINER_NAME" --format '{{range .Mounts}}{{if eq .Destination "/app/hermes-agent"}}{{.Source}}{{end}}{{end}}' 2>/dev/null || true)"
    [ -n "$data_dir" ] || die "无法从容器反查 HERMES_HOME 挂载"
    [ -f "$data_dir/.env" ] || die "$data_dir 内没有 .env"
    ok "数据目录（来自容器挂载）：$data_dir"
    oldpw="$(grep -m1 '^HERMES_WEBUI_PASSWORD=' "$data_dir/.env" | cut -d= -f2- || true)"
    cp -a "$data_dir/.env" "$data_dir/.env.bak-pw-$(date +%Y%m%d-%H%M%S)"
    upsert_env HERMES_WEBUI_PASSWORD "$newpw" "$data_dir/.env"
    upsert_env HERMES_DASHBOARD_BASIC_AUTH_PASSWORD "$newpw" "$data_dir/.env"
    upsert_env API_SERVER_KEY "$newpw" "$data_dir/.env"
    chmod 600 "$data_dir/.env" 2>/dev/null || true
    if [ -f "$ENV_FILE" ]; then
        upsert_env HERMES_WEBUI_PASSWORD "$newpw"
        upsert_env HERMES_DASHBOARD_BASIC_AUTH_PASSWORD "$newpw"
        ok "已同步 config/.env（compose 注入优先级更高）"
    fi
    ok "容器重建以加载新密码（restart 不会重读 compose 环境变量）"
    compose up -d --force-recreate >/dev/null
    code="$(wait_webui "$WEBUI_PORT" 180)"
    [ "$code" = "200" ] && ok "WebUI 就绪 :$WEBUI_PORT" || warn "WebUI :$WEBUI_PORT 未就绪（查 docker logs）"
    json_new="$(python3 -c 'import json,sys;print(json.dumps({"password":sys.argv[1]}))' "$newpw")"
    n_code="$(curl -s -o /dev/null -w '%{http_code}' -m 8 -X POST "http://127.0.0.1:${WEBUI_PORT}/api/auth/login" -H 'Content-Type: application/json' -d "$json_new" || true)"
    [ "$n_code" = "200" ] && ok "WebUI：新密码登录成功" || warn "WebUI：新密码登录返回 $n_code"
    if [ -n "$oldpw" ]; then
        json_old="$(python3 -c 'import json,sys;print(json.dumps({"password":sys.argv[1]}))' "$oldpw")"
        o_code="$(curl -s -o /dev/null -w '%{http_code}' -m 8 -X POST "http://127.0.0.1:${WEBUI_PORT}/api/auth/login" -H 'Content-Type: application/json' -d "$json_old" || true)"
        [ "$o_code" = "401" ] && ok "WebUI：旧密码已失效" || warn "WebUI：旧密码返回 $o_code（期望 401）"
    fi
    step "密码修改完成"; echo "  WebUI http://<host>:${WEBUI_PORT}  密码已更新"; exit 0
}

if [ -n "$OPT_PW" ]; then step "-pw 模式"; change_password "$OPT_PW"; fi

# ── 重复部署保护 ────────────────────────────────────────────────────────────
step "检查是否已部署"
if docker ps -a --filter "name=^${CONTAINER_NAME}$" --format '{{.Names}}' | grep -qx "$CONTAINER_NAME"; then
    STATUS="$(docker ps -a --filter "name=^${CONTAINER_NAME}$" --format '{{.Status}}')"
    if [ "$FORCE" != 1 ]; then
        err "容器 ${CONTAINER_NAME} 已存在（$STATUS），本次不部署。"
        echo "  沿用：cd $PROJECT_DIR && $COMPOSE_CMD --env-file config/.env up -d"
        echo "  凭据：docker logs ${CONTAINER_NAME} | grep -A6 登录凭据"
        echo "  重装：$0 --force"
        exit 2
    fi
    warn "已存在（$STATUS）且指定 --force：先停止并移除"
    [ "$DRY_RUN" = 1 ] || compose down
fi
ok "无同名容器"

# ── 端口/磁盘 ───────────────────────────────────────────────────────────────
step "资源检查"
expand_ports() { case "$1" in *-*) local a="${1%-*}" b="${1#*-}"; seq "$a" "$b" ;; *) printf '%s\n' "$1" ;; esac; }
PORTS="$(printf '%s\n' "$WEBUI_PORT" "$DASH_PORT" "$API_PORT" | cat - <(expand_ports "$OPEN_PORT") | sort -un)"
LISTENING="$(ss -ltnH 2>/dev/null | awk '{print $4}' | sed -E 's/.*:([0-9]+)$/\1/' | sort -un)"
BUSY=""
for p in $PORTS; do if printf '%s\n' "$LISTENING" | grep -qx "$p"; then BUSY="$BUSY $p"; fi; done
[ -z "$BUSY" ] || die "端口已被占用:$BUSY"
ok "端口可用: $(printf '%s' "$PORTS" | tr '\n' ' ')"
AVAIL_GB="$(df -Pk "$PROJECT_DIR" | awk 'NR==2{printf "%d", $4/1024/1024}')"
[ "${AVAIL_GB:-0}" -ge 20 ] || warn "磁盘可用 ${AVAIL_GB} GB（首启装 agent+webui+插件约需 8-10 GB）"
ok "磁盘可用: ${AVAIL_GB} GB"
[ "$DRY_RUN" = 1 ] || mkdir -p "$SRC_DIR" "$DATA_DIR" "$WS_DIR"
ok "源码目录: $SRC_DIR"
ok "数据目录: $DATA_DIR"
ok "工作区:   $WS_DIR"

step "部署计划"
cat <<EOF
  镜像      hermes-allinone-v2（薄镜像，首启在线安装 hermes + webui）
  WebUI     :$WEBUI_PORT    Dashboard: :$DASH_PORT（$([ "$DASH_ON" = 1 ] && echo 启用 || echo 未启用)）
  API 网关  :$API_PORT     开放端口: $OPEN_PORT
  源码      $SRC_DIR   （hermes + webui，hermes update 改这里）
  数据      $DATA_DIR  （HERMES_HOME：依赖环境/工具/配置/会话）
  工作区    $WS_DIR
  主密码    $([ -n "$OPT_PASS" ] && echo 使用参数 || echo 留空＝首启随机生成并打印到 docker logs)
  首次启动  在线安装，约 5-15 分钟（下载 agent 依赖 + webui + hindsight 插件）
EOF
if [ "$DRY_RUN" = 1 ]; then echo; ok "dry-run 结束（未写文件、未构建、未启动）"; exit 0; fi

# ── 写 config/.env ──────────────────────────────────────────────────────────
step "写入 config/.env"
if [ ! -f "$ENV_FILE" ]; then cp "$EXAMPLE_ENV" "$ENV_FILE"; ok "已由 config/.env.example 创建"; else ok "沿用现有 config/.env"; fi
[ -n "$OPT_PASS"  ] && upsert_env HERMES_WEBUI_PASSWORD "$OPT_PASS"
[ -n "$OPT_SRC"   ] && upsert_env HOST_SRC_DIR "$SRC_DIR"
[ -n "$OPT_HDD"   ] && upsert_env HOST_HERMES_HOME "$DATA_DIR"
[ -n "$OPT_WSD"   ] && upsert_env HOST_WORKSPACE "$WS_DIR"
[ -n "$OPT_HDASH" ] && upsert_env HERMES_DASHBOARD_ON "$OPT_HDASH"
[ -n "$OPT_WPORT" ] && upsert_env HERMES_WEBUI_PORT "$OPT_WPORT"
[ -n "$OPT_OPORT" ] && upsert_env OPEN_PORT "$OPT_OPORT"
chmod 600 "$ENV_FILE" 2>/dev/null || true

# ── 根目录 .env 符号链接（防"裸 up"事故）──────────────────────────────────────
# compose 的 ${VAR} 插值只自动读【项目根 .env】。用户手动 `docker-compose down/up`
# 时若忘了 --env-file，所有路径都会退回默认值：卷变成 ./src、./hermes-data、./workspace
# → 空 HERMES_HOME → bootstrap 判定"未安装"→ 从头再装一遍（python/npm/插件依赖全重来），
# 而旧数据目录被晾在一边。实测事故现场：配置里是 HermesAgent/ndisk 路径，容器却挂了
# 新建的 hermes-data（2.4 G 白装）。
# 这里建一个指向 config/.env 的符号链接，让裸 compose 命令也能读到同一份配置。
if [ ! -e "$PROJECT_DIR/.env" ] && [ ! -L "$PROJECT_DIR/.env" ]; then
    ln -s config/.env "$PROJECT_DIR/.env" && ok "已创建根 .env → config/.env 符号链接（手动 docker compose 也不会再走错路径）"
else
    ok "根 .env 已存在（保留）"
fi

compose config >/dev/null || die "compose 配置渲染失败"
ok "compose 配置渲染通过"

# ── 构建并启动 ──────────────────────────────────────────────────────────────
if [ "$SKIP_BUILD" = 1 ] && docker image inspect hermes-allinone-v2:latest >/dev/null 2>&1; then
    step "跳过构建（--skip-build）"
else
    step "构建镜像（薄镜像，通常 2-4 分钟）"
    mkdir -p "$LOG_DIR"
    compose build 2>&1 | tee "$LOG_DIR/build-$(date +%Y%m%d-%H%M%S).log" | tail -5
fi
step "启动容器（首次启动会在线安装，日志会持续输出进度）"
compose up -d
ok "容器已启动"

step "等待 WebUI 就绪（首次安装可能 5-15 分钟，最多等 20 分钟）"
CODE="$(wait_webui "$WEBUI_PORT" 1200)"
if [ "$CODE" = "200" ]; then ok "WebUI /health = 200"; else warn "WebUI 未就绪（$CODE）：docker logs -f $CONTAINER_NAME"; fi

# API 网关探测（401 = 已监听）
api_state="未启用"
if [ "$(env_get HERMES_API_GW "$ENV_FILE")" = "1" ]; then
    n=0; acode="000"
    while [ "$n" -lt 60 ]; do
        acode="$(curl -s -o /dev/null -w '%{http_code}' -m 3 "http://127.0.0.1:${API_PORT}/v1/models" 2>/dev/null || true)"
        case "$acode" in 200|401) break ;; esac
        n=$((n + 3)); sleep 3
    done
    case "$acode" in
        200|401) ok "API 网关已监听 :${API_PORT}（HTTP ${acode}）"; api_state="就绪" ;;
        *)       warn "API 网关 :${API_PORT} 未就绪（$acode）：确认 API_SERVER_KEY ≥16 位、API_SERVER_HOST=0.0.0.0" ;;
    esac
fi

IP="$(hostname -I 2>/dev/null | awk '{print $1}')"; IP="${IP:-127.0.0.1}"
step "部署完成"
echo "  WebUI      http://${IP}:${WEBUI_PORT}"
echo "  Dashboard  $([ "$DASH_ON" = 1 ] && echo "http://${IP}:${DASH_PORT}" || echo 未启用)"
echo "  API 网关   $([ "$api_state" = "未启用" ] && echo 未启用 || echo "http://${IP}:${API_PORT}/v1  ${api_state}")"
echo "  源码       ${SRC_DIR}"
echo "  数据       ${DATA_DIR}"
CREDS="$(docker logs "$CONTAINER_NAME" 2>&1 | grep -A7 '登录凭据' || true)"
if [ -n "$CREDS" ]; then echo; echo "$CREDS" | sed 's/^/  /'; else
    echo "  密码：docker logs ${CONTAINER_NAME} | grep -A7 登录凭据"; fi
echo
echo "  日志： docker logs -f ${CONTAINER_NAME}"
echo "  停止： cd $PROJECT_DIR && $COMPOSE_CMD --env-file config/.env down"
echo "  重装： $0 --force"
