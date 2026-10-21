# v2 设计说明：把"真机安装流程"搬进容器

## 1. 为什么这么做

v1 的做法是"构建期把源码和 venv 烤进镜像"，代价是 7.53 GB、上游一变就构建失败、
且 `hermes update` 的语义与真机不同（自建版本戳、pm 不认这套布局）。

v2 反过来：**镜像只提供 OS + 工具链 + 流程脚本（1.36 GB），hermes 与 WebUI 在首启时用官方脚本在线安装。**
好处是每次装机拿到的就是最新版、升级路径与真机完全一致（`hermes update` / 两个更新按钮都能用）。

## 2. 官方安装后的真实布局（决定了全部设计）

```
$INSTALL_DIR/.hermes/bin/hermes      → 垫片：exec $HERMES_HOME/tools/python-3.x/bin/python3 -I -c '...'
$HERMES_HOME/tools/                  → uv 托管的 Python、uv、node 等
$HERMES_HOME/installs/<key>/         → pm 的依赖环境（environments/<key>/venv）+ facts.json
$HOME/.local/bin/hermes              → 同上（PATH 入口）
$HOME/.local/share/uv/               → uv 的 Python 解释器本体
```

由此推出三件事（都是实测出来的）：

1. **`HERMES_HOME` 不能是空数据卷**。垫片里是写死的绝对路径，卷为空时直接
   `exec: ...python3: not found`，**不会自举**。所以首启必须先跑安装脚本。
2. **`HOME` 必须进数据卷**。垫片与 uv 的 Python 都在 `$HOME/.local` 下——留在 `/root`
   （镜像层）时，容器一重建就全丢，`$INSTALL_DIR/venv` 里的 python 变悬空链接，WebUI 起不来。
   这就是本项目的 `HOME=/app/hermes-agent/home`。
3. **WebUI 需要自己的环境**。pm 的 `uv sync` 不带 `--inexact`，会把不在 lock 里的包**修剪掉**，
   所以 WebUI 的依赖（fastapi/uvicorn/ruamel/PyYAML）不能塞进 pm 环境，否则下次 `hermes update`
   就被删了。v2 用 `$INSTALL_DIR/venv`（`uv sync --locked` + `pip install -e WebUI`），
   正好命中 WebUI 的自动发现优先级 2（`<agent_dir>/venv/bin/python`）。

## 3. 进程模型（等价真机的两个 systemd 单元）

| 真机 | 容器 |
|---|---|
| `hermes-gateway.service` | `supervisor.sh` → `hermes gateway run --no-supervise --external-supervisor` |
| `hermes-webui.service`（`After=hermes-gateway`、`Restart=always`、`RestartSec=5`） | 先起网关、再起 WebUI；进程退出 5 秒后重拉 |
| 48h 任务计划 | `updater.sh`（`UPDATE_AGENT_TIME` / `UPDATE_WEBUI_TIME`） |
| 更新后"能打开但不能对话" | supervisor **盯 HEAD**：commit 变了就刷依赖 + 重启 WebUI/网关 |

`--external-supervisor` 是必须的：否则 `hermes gateway run` 会 detach 成守护后前台退出，
supervisor 会误判崩溃并陷入重启循环。

## 4. 踩过的坑（都已在代码里兜住）

| 坑 | 现象 | 修法 |
|---|---|---|
| `HOME` 在镜像层 | 重建容器后 `venv/bin/python` 悬空、WebUI 起不来、重新走安装 | `HOME` 指向数据卷 `home/` |
| `HERMES_DASHBOARD_BASIC_AUTH_USERNAME` 进容器环境 | agent 报 `neither password_hash nor password is configured` **直接拒绝启动** | 用自有变量 `DASH_BASIC_AUTH_USER`；启用 Dashboard 时用 `hermes config set` 成对写 username+hash |
| `[ 条件 ] \|\| return` + `set -e` | 条件不成立时 `return` 继承状态 1 → PID 1 退出 → 容器 exit 0 重启循环 | 所有提前返回都写 `return 0` |
| WebUI 依赖判据只看 `run_agent` | 走"已就绪"快路径 → `server.py` 启动即死、日志空白 | 判据补齐 `fastapi, uvicorn, ruamel.yaml` |
| 首启日志 `tee \| tail -n 40` | 安装 10 分钟期间 `docker logs` 一片空白 | 改 `sed -u` 流式输出 |
| 浅克隆只有 1 个 tag | WebUI 检测更新 `git fetch --tags` 超过硬编码 15s → 报超时 | 首启预热 tags（~30s），运行时 ~1s |
| WebUI 的 agent 更新腿 | 上游把 channel 钉成 stable，但 `_select_apply_compare_ref()` 对 agent 会"分支兜底"到 `origin/main` → 点一次更新就把 agent 拉到开发线（实测 v0.22.2 → rc.5-v0.22.3-1，+3017 提交），与 WebUI 版本线错位；且没有 env 开关 | 默认写 `ignore_agent_updates: true`（`WEBUI_IGNORE_AGENT_UPDATES=1`），两条腿解耦：agent 只由 `hermes update`（stable）驱动 |
| 重复运行 init.sh | 两个实例互相 `up -d` → 容器反复重建（SIGTERM） | 用 `-pw`/检查步避免并发；`--force` 才重建 |
| hindsight 依赖"装完了"的假象 | `plugins install --yes-deps` **只拉插件源码**；配 `--no-enable` 时依赖永不安装 → Dashboard 永久显示 “Install provider dependencies / Python dependencies”（后端 `pm.venv_is_current()` 为假） | 先 `install` 拿源码，再 `plugins enable`（≈400 MB）建隔离环境装依赖；判据用「某环境能否 `import hindsight_client`」，**不能**用 `installs/*/environments`（那是 agent 自己的环境，恒存在） |

## 5. 已知限制

- **API/WebUI 的"更新"仍受网速约束**：WebUI 的 `git fetch` 超时 15 秒是上游**硬编码**（`api/updates.py` 三处），
  没有环境变量可调。线路到 GitHub 超过 15 秒的机器（实测某机房 22–36 s）会报 `timed out`；
  这是网络问题，官方安装流程同样会遇到，不是本项目引入的。可给该容器配代理或改用 CLI `hermes update`。
- **无 GPU 支持**：v2 目前是 CPU-only（v1 的 `config/hwaccel.yaml` 可移植过来）。
- **无 systemd**：用 supervisor 复刻语义；容器内不要执行 `systemctl` 相关命令。
