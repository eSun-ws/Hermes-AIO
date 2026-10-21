# Hermes All-in-One v2（薄镜像 + 官方安装流程）

> 与 v1 的根本区别：**镜像只放流程逻辑（1.36 GB），hermes 与 WebUI 的源码/依赖在容器首次启动时在线安装**。
> 安装动作就是官方 `install.sh` 本身（尊重 `HERMES_HOME` / `HERMES_INSTALL_DIR`），因此 `hermes update`、
> WebUI 的更新按钮、Dashboard 的更新按钮，行为都与真机一致。

```
镜像   1.36 GB（Ubuntu 24.04 + 工具链 + 5 个流程脚本）
首启   在线安装 hermes + WebUI + hindsight 插件，约 8-15 分钟
磁盘   每套部署约 4.5 GB（src 1.6 GB + hermes-data 2.9 GB，都在数据卷里）
```

---

## 1. 目录结构

```
hermes-allinone-v2/
├── docker-compose.yml          # 只定义布局/端口/挂载
├── init.sh                     # 一键部署（依赖检查、端口预检、-pw 改密）
├── config/
│   ├── Dockerfile              # 薄镜像
│   ├── Dockerfile.dockerignore # 排除 src/、hermes-data/、workspace/（部署后可能有几 GB）
│   ├── .env.example            # 配置模板 → 复制成 config/.env
│   └── buildCMD/
│       ├── entrypoint.sh       # 凭据 → 首启引导 → supervisor
│       ├── bootstrap.sh        # 官方 install.sh + WebUI 源码/依赖 + 插件（幂等）
│       ├── supervisor.sh       # 替代 systemd：gateway/webui 自动重启 + agent 变更监视
│       └── updater.sh          # 定时更新（默认 48h）：hermes update → 重启 WebUI → 更新 WebUI
└── docs/DESIGN.md              # 为什么这样设计、踩过的坑
```

## 2. 快速开始

```bash
cd hermes-allinone-v2
./init.sh -p '你的密码'                      # 最小用法，其余走 config/.env 默认值
# 常用：
./init.sh -p '密码' -src /data/src -hdd /data/hermes -wsd /data/workspace \
          -wport 8787 -hdash 0 -y
./init.sh -pw '新密码'                        # 改已部署实例的 WebUI / Dashboard 密码
./init.sh -n                                  # dry-run：只打印计划，不写文件
```

| 参数 | 含义 | 默认 |
|---|---|---|
| `-p` | 主密码（WebUI 与 Dashboard 共用） | 留空＝首启随机生成并打印到 `docker logs` |
| `-src` | 源码目录（hermes + webui，`hermes update` 改这里） | `./src` |
| `-hdd` | HERMES_HOME（依赖环境/工具/配置/会话） | `./hermes-data` |
| `-wsd` | Agent 默认工作区 | `./workspace` |
| `-hdash` | Dashboard 开关 0/1 | `0` |
| `-wport` | WebUI 端口 | `8787` |
| `-oport` | 开放测试端口段 | `3111-3113` |
| `-pw` | 改已部署实例密码（不重新部署） | — |
| `-y / -n / --skip-build / --force` | 自动装依赖 / dry-run / 跳过构建 / 强制重装 | — |

⚠ **所有 `docker compose` 命令都要带 `--env-file config/.env`**：配置在 `config/`，
而 compose 的 `${VAR}` 插值只自动读项目根 `.env`（init.sh 已自动处理）。

> **手动 `down`/`up` 的真实事故**（已实测）：忘了 `--env-file` 时，插值全部退回默认值 ——
> 卷变成 `./src`、`./hermes-data`、`./workspace`（**新建空目录**），端口变成 8787 / 9119 默认值，
> `HERMES_DASHBOARD_ON` 退回 0。于是容器挂着一个空的 HERMES_HOME，bootstrap 判定"未安装"，
> **从头再装一遍 python/npm/插件依赖**，而你原来的数据目录被晾在一边。
> 防法：init.sh 会在项目根建一个 `.env → config/.env` 的符号链接，之后再裸跑
> `docker compose up -d` 也读同一份配置（老部署升级后重跑一次 init.sh 即可获得该链接）。

## 3. 首次启动发生了什么

`entrypoint.sh` 按真机顺序走一遍，全部幂等（已完成就秒过）：

1. **凭据**：主密码 + API key（`API_SERVER_KEY` 要求 ≥16 位；主密码不足 16 位时自动生成独立 key）；
2. **官方安装脚本**（下载 → `--channel stable --non-interactive`）→ 源码 + pm 依赖环境；
3. **WebUI**：`git clone` 官方仓库 + **预热 tags**（WebUI 的"检测更新"用 `git fetch --tags`，超时硬编码 15 秒，浅克隆首拉 1800+ tags 必超时）；
4. **WebUI 运行环境**：`$INSTALL_DIR/venv`（`uv sync --locked` + `pip install -e WebUI`），与 WebUI 自动发现的 `<agent_dir>/venv/bin/python` 对齐；
5. **hindsight 插件**：先 `hermes plugins install hindsight`（只克隆源码），再 `hermes plugins enable hindsight`
   安装依赖环境（`hindsight-client` / `hindsight-embed`，约 400 MB）。**只启用插件、不写
   `memory.provider`** —— provider 仍由你在 Dashboard 里选择。
   > ⚠ 为什么分两步：实测 `plugins install --yes-deps` **不装 Python 依赖**，依赖是
   > `plugins enable` 时创建到 `installs/<key>/environments/<hash>/venv` 的。若传
   > `--no-enable`，Dashboard 会一直显示 “Install provider dependencies”。
   > 想省这 400 MB 就设 `HINDSIGHT_PREPARE=0`，首次启用时在 Dashboard 点那个按钮安装。
6. 写 `.bootstrap-done`，交给 `supervisor.sh`。

首次约 **8-15 分钟**（取决于网速与是否装浏览器组件）。`HERMES_SKIP_BROWSER=1` 可省 ~167 MB 下载。

## 4. 更新语义（重点）

### 定时更新（默认 48 小时，可配）
`UPDATE_AGENT_TIME` / `UPDATE_WEBUI_TIME`（小时，`0`=关闭）：

```
hermes update --yes
  └─ commit 真变了 → 重启 WebUI            ← 真机上更新后 WebUI "能打开但不能对话"，
      └─ 再执行 WebUI 自身更新（git + 依赖）    靠 systemd 的 Restart=always 兜住；容器里由 supervisor 兜
```

### 点按钮更新（WebUI / Dashboard）
这两个按钮走的是**同一套代码**，容器里没有 systemd 帮你重启服务，所以 `supervisor.sh`
**盯着 `$INSTALL_DIR` 的 HEAD**：只要 commit 变了（不管是谁改的），就自动

1. `uv sync --locked` 刷新 WebUI 环境依赖（后台加锁执行，不阻塞主循环）；
2. 重启 WebUI，并重启网关（否则进程内还是旧的 agent 模块）。

实测：改动后 **6 秒**发现、**1 秒**刷完依赖、WebUI 重启后 `/health`=200、`restart=0`。

### WebUI 的"更新源"（稳定/实验）
**只作用于 WebUI 自身**，与 hermes agent 无关。agent 的通道由 `HERMES_CHANNEL`（构建/安装期）与
`hermes update` 的 stable 通道决定。

### 两条腿的通道对齐：`WEBUI_IGNORE_AGENT_UPDATES`（默认 1）

先说结论：**上游 WebUI 没有提供控制 agent 更新通道的环境变量**（`api/config.py` 里只有
`HERMES_WEBUI_SETTINGS_FILE` 能改设置文件路径）。而且它的 agent 更新腿是这样走的：

```python
elif target == 'agent':
    channel = DEFAULT_UPDATE_CHANNEL      # 注释原文：Channel is WebUI-only
...
compare_ref = _select_apply_compare_ref(path, 'stable', 'agent')
#   → 对 agent 仓库会“分支兜底”到 origin/main，即使它自己的通道是 stable
```

也就是说：**点 WebUI 的更新按钮，agent 会被拉到 `origin/main` 开发线**，绕过 agent 自己的
`stable` 通道设置（实测从 `v0.22.2` 跳到 `rc.5-v0.22.3-1-g69c7d677a1`，领先 3017 个提交）。
想让它"跟随 Hermes 的版本线"只能改 vendor 代码（`api/updates.py`），而 WebUI 自身一升级就会被覆盖，
不可持续。

所以 v2 默认**把 agent 这条腿关掉**，让两条腿彻底解耦：

| 变量 | 默认 | 行为 |
|---|---|---|
| `WEBUI_IGNORE_AGENT_UPDATES` | `1` | WebUI 只检查/更新自己；agent 一律由 `hermes update`（stable，`UPDATE_AGENT_TIME` 定时）驱动 |
| | `0` | 恢复上游行为：WebUI 也会检查 agent（会按 main 拉，慎用） |

实现方式是容器每次启动时幂等写入 WebUI 的设置文件 `$HERMES_HOME/webui/settings.json` 的
`ignore_agent_updates` 键（等价于设置界面里的 **Ignore Agent updates** 开关）。
注意：**该变量在建容器时生效**，仅改界面开关会在下次容器启动时被变量值覆盖回去。

验证（A3 实测）：

```
/api/updates/check {"force":true}   耗时 3.1s
  webui  behind=0  latest_tag=v0.52.492  error=None     ← 仍检查自己
  agent  behind=0  ignored=True          error=None     ← 不再抓取 agent
```


## 5. 数据卷与升级/重装

| 挂载 | 内容 | 重建容器后 |
|---|---|---|
| `src/` → `/app/src` | hermes 源码 + WebUI 源码（`.git` 在内） | 保留，不重装 |
| `hermes-data/` → `/app/hermes-agent` | `HERMES_HOME`：pm 依赖环境、tools、config.yaml、sessions、日志、**`home/`（HOME）** | 保留 |
| `workspace/` → `/workspace` | Agent 工作区 | 保留 |

`docker compose up -d --force-recreate`（= 升级镜像/重装）实测 **14 秒**恢复 WebUI，且
bootstrap 全部走"已就绪"快路径，不会重新下载。

### 各种操作到底会发生什么（实测）

| 操作 | 数据 | 是否重装 / 升级 | 端口与开关 |
|---|---|---|---|
| `docker stop` / `docker start` | 完好（都在卷里） | **不重装**，只拉起进程 | 沿用创建时的环境变量 |
| `docker restart` | 同上 | 不重装 | **不重读 `.env`**（改了也无效） |
| `down` → `up -d`（带 `--env-file`） | 完好 | **不重装**（bootstrap 快路径：hermes 已装 / WebUI 就绪 / 插件依赖在） | 按 `.env` 重新插值 |
| `down` → `up -d`（**忘了** `--env-file`） | ⚠ 旧数据被晾在一边 | **从头装一遍**（空 HERMES_HOME） | 全部退回默认（8787 / dashboard off / `./hermes-data`） |
| 改 `.env` 后 `up -d` | 完好 | 不重装 | 生效（会 recreate 容器） |
| 隔 N 天再 `up`（卷还在） | 完好 | **不重装、也不自动升级** ¹ | 按 `.env` |
| 需要升级时 | 完好 | 手动 `hermes update`，或等 `UPDATE_AGENT_TIME` 定时 | — |

¹ 升级只由两条路径触发：容器内 `hermes update`（定时任务 / 手动 / WebUI-Dashboard 的按钮），
以及 WebUI 自身更新；**重建容器本身不会拉新版本**。

## 6. 端口

| 端口 | 用途 |
|---|---|
| `HERMES_WEBUI_PORT`（8787） | WebUI |
| `HERMES_DASHBOARD_PORT`（9119） | Dashboard（`HERMES_DASHBOARD_ON=1` 才启动） |
| `API_SERVER_PORT`（8642） | OpenAI 兼容 API（`/v1/models`、`/v1/chat/completions`），需 Bearer key |
| `OPEN_PORT`（3111-3113） | 临时服务/测试端口 |

## 7. 排障

```bash
docker logs -f hermes-allinone                    # 入口 + supervisor + 首启安装（流式）
docker exec hermes-allinone tail -f /app/hermes-agent/logs/bootstrap.log
docker exec hermes-allinone tail -f /app/hermes-agent/logs/webui.log
docker exec hermes-allinone tail -f /app/hermes-agent/logs/gateway.log
docker exec -it hermes-allinone bash              # 进容器（hermes 已在 PATH）
docker logs hermes-allinone | grep -A7 登录凭据    # 看密码
```

## 8. 与 v1 的差异

| | v1 | v2 |
|---|---|---|
| 镜像 | 7.53 GB（烤进源码与 venv） | **1.36 GB**（只有流程） |
| 安装方式 | 自建 `uv sync` + 手写版本戳 | **官方 install.sh**（pm 负责环境与 facts） |
| 更新 | 依赖 WebUI tags 预热 | 官方链路；WebUI/Dashboard 按钮 + 48h 定时 + HEAD 监视 |
| 首启 | 快（镜像内已有依赖） | 慢 8-15 分钟（在线装，永远最新） |
| 首次联网 | 只装插件/工具 | 装全套（源码 + 依赖 + 插件） |

> 迁移到已有 v1 部署的机器时，先 `docker compose down` 停掉 v1，避免 8642/9119 端口冲突；
> v1 的数据卷可原样保留作备份。
