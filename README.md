# Hermes All-in-One v2 (thin image + official install flow)

> What makes this fundamentally different from v1: **the image only carries the orchestration
> logic (1.36 GB); the Hermes and WebUI sources and their dependencies are installed online on the
> container's first boot.** The install step *is* the official `install.sh` (it honors
> `HERMES_HOME` / `HERMES_INSTALL_DIR`), so `hermes update`, the WebUI update button and the
> Dashboard update button all behave exactly like they do on a bare-metal install.

```
image       1.36 GB (Ubuntu 24.04 + toolchain + 5 orchestration scripts)
first boot  installs hermes + WebUI + hindsight plugin online, ~8-15 minutes
disk        ~4.5 GB per deployment (src 1.6 GB + hermes-data 2.9 GB, all on data volumes)
```

---

## 1. Layout

```
hermes-aio/
├── docker-compose.yml          # layout, ports and mounts only
├── init.sh                     # one-shot deploy (dependency checks, port preflight, -pw password change)
├── config/
│   ├── Dockerfile              # thin image
│   ├── Dockerfile.dockerignore # excludes src/, hermes-data/, workspace/ (multi-GB after deploy)
│   ├── .env.example            # configuration template -> copy to config/.env
│   └── buildCMD/
│       ├── entrypoint.sh       # credentials -> first-boot bootstrap -> supervisor
│       ├── bootstrap.sh        # official install.sh + WebUI source/deps + plugin (idempotent)
│       ├── supervisor.sh       # systemd replacement: auto-restart + agent revision watcher
│       └── updater.sh          # scheduled updates (48h default): hermes update -> restart WebUI -> update WebUI
└── docs/DESIGN.md              # why it is built this way, and the pitfalls hit along the way
```

## 2. Quick start

```bash
cd hermes-aio
./init.sh -p 'your-password'                 # minimal usage; everything else comes from config/.env
# common variants:
./init.sh -p 'password' -src /data/src -hdd /data/hermes -wsd /data/workspace \
          -wport 8787 -hdash 0 -y
./init.sh -pw 'new-password'                 # change the WebUI / Dashboard password of a deployed instance
./init.sh -n                                 # dry run: print the plan, write nothing
```

| Flag | Meaning | Default |
|---|---|---|
| `-p` | Master password (shared by WebUI and Dashboard) | empty = generated on first boot and printed to `docker logs` |
| `-src` | Source directory (hermes + webui; `hermes update` writes here) | `./src` |
| `-hdd` | `HERMES_HOME` (dependency environments, tools, config, sessions) | `./hermes-data` |
| `-wsd` | Default agent workspace | `./workspace` |
| `-hdash` | Dashboard on/off, `0` or `1` | `0` |
| `-wport` | WebUI port | `8787` |
| `-oport` | Published test port range | `3111-3113` |
| `-pw` | Change the password of an existing deployment (no redeploy) | — |
| `-y` / `-n` / `--skip-build` / `--force` | auto-install deps / dry run / skip build / force redeploy | — |

⚠ **Every `docker compose` command must pass `--env-file config/.env`.** The configuration lives in
`config/`, while Compose only auto-reads a project-root `.env` for `${VAR}` interpolation (`init.sh`
takes care of this for you).

> **A real incident from a manual `down` / `up`** (measured): if you forget `--env-file`, every
> interpolation falls back to its default — the volumes become `./src`, `./hermes-data` and
> `./workspace` (**freshly created empty directories**), the ports revert to 8787 / 9119 and
> `HERMES_DASHBOARD_ON` reverts to `0`. The container then mounts an empty `HERMES_HOME`, the
> bootstrap decides "not installed" and **reinstalls python/npm/plugin dependencies from scratch**,
> while your real data directory sits untouched on the side.
> Guard: `init.sh` creates a root-level `.env → config/.env` symlink, so afterwards even a bare
> `docker compose up -d` reads the same configuration (re-run `init.sh` once on an older deployment
> to get that symlink).

## 3. What happens on first boot

`entrypoint.sh` walks the same path a bare-metal install would, fully idempotent (already-done steps
are skipped in milliseconds):

1. **Credentials**: master password + API key (`API_SERVER_KEY` must be ≥16 chars; when the master
   is shorter, a separate key is generated automatically).
2. **Official installer** (download → `--channel stable --non-interactive`) → source tree + pm
   dependency environment.
3. **WebUI**: `git clone` of the official repo + **tag pre-warm** (the WebUI update check runs
   `git fetch --tags` with a hard-coded 15s timeout, and a shallow clone's first fetch of 1800+ tags
   always exceeds it).
4. **WebUI runtime**: `$INSTALL_DIR/venv` (`uv sync --locked` + `pip install -e WebUI`), aligned with
   the `<agent_dir>/venv/bin/python` that WebUI auto-discovers.
5. **hindsight plugin**: `hermes plugins install hindsight` first (clones the source only), then
   `hermes plugins enable hindsight` to build the dependency environment
   (`hindsight-client` / `hindsight-embed`, ~400 MB). **The plugin is enabled, but
   `memory.provider` is left unset** — choosing the provider is still up to you in the Dashboard.
   > ⚠ Why two steps: measured, `plugins install --yes-deps` does **not** install Python
   > dependencies; they are created under `installs/<key>/environments/<hash>/venv` by
   > `plugins enable`. Passing `--no-enable` leaves the Dashboard showing
   > "Install provider dependencies" forever.
   > To skip those 400 MB, set `HINDSIGHT_PREPARE=0` and install them later with that Dashboard button.
6. Write `.bootstrap-done` and hand over to `supervisor.sh`.

First boot takes **8-15 minutes** (network speed and whether browser components are installed).
`HERMES_SKIP_BROWSER=1` saves the ~167 MB browser download.

## 4. Update semantics (the important part)

### Scheduled updates (48 hours by default, configurable)
`UPDATE_AGENT_TIME` / `UPDATE_WEBUI_TIME` (hours, `0` = disabled):

```
hermes update --yes
  └─ commit really changed -> restart WebUI     <- on bare metal the WebUI "opens but cannot chat"
      └─ then run the WebUI's own update           after an agent update; systemd's Restart=always
         (git + dependencies)                      covers it there, the supervisor covers it here
```

### Button-driven updates (WebUI / Dashboard)
Both buttons run the **same code path**. A container has no systemd to restart services for you, so
`supervisor.sh` **watches the HEAD of `$INSTALL_DIR`**: whenever the commit changes — no matter who
changed it — it automatically

1. runs `uv sync --locked` to refresh the WebUI environment's dependencies (in the background, under
   a lock, so the main loop keeps running);
2. restarts the WebUI, and restarts the gateway (otherwise the process still holds the old agent
   modules).

Measured: noticed in **6 seconds**, dependencies refreshed in **1 second**, WebUI `/health` = 200
after the restart, container `restart=0`.

### The WebUI "update channel" (stable / experimental)
**It only applies to the WebUI itself**, never to the Hermes agent. The agent's channel is decided by
`HERMES_CHANNEL` (build/install time) and by the `stable` channel of `hermes update`.

### Keeping both update legs aligned: `WEBUI_IGNORE_AGENT_UPDATES` (default `1`)

Upstream first: **the WebUI exposes no environment variable for the agent's update channel** (the
only related knob in `api/config.py` is `HERMES_WEBUI_SETTINGS_FILE`, which just relocates the
settings file). And its agent leg works like this:

```python
elif target == 'agent':
    channel = DEFAULT_UPDATE_CHANNEL      # upstream comment: "Channel is WebUI-only"
...
compare_ref = _select_apply_compare_ref(path, 'stable', 'agent')
#   -> for the agent repo this falls through to the branch, i.e. origin/main,
#      even though the agent's own channel is stable
```

In other words: **clicking the WebUI update button drags the agent onto the `origin/main`
development line**, bypassing the agent's own `stable` channel setting (measured: `v0.22.2` jumped to
`rc.5-v0.22.3-1-g69c7d677a1`, 3017 commits ahead). Making it "follow Hermes' release line" would
require patching vendor code (`api/updates.py`), which the next WebUI update overwrites — not
sustainable.

So v2 **disables the agent leg by default** and keeps the two legs fully decoupled:

| Variable | Default | Behaviour |
|---|---|---|
| `WEBUI_IGNORE_AGENT_UPDATES` | `1` | WebUI only checks/updates itself; the agent is driven exclusively by `hermes update` (stable, `UPDATE_AGENT_TIME`) |
| | `0` | Restore upstream behaviour: the WebUI also checks the agent (pulls `main` — use with care) |

Implementation: on every container start the entrypoint idempotently writes the
`ignore_agent_updates` key into the WebUI settings file `$HERMES_HOME/webui/settings.json`
(equivalent to the **Ignore Agent updates** toggle in the Settings UI). Note that **the variable wins
at container creation time**; flipping only the UI toggle is overwritten on the next container start.

Verification (measured on a test host):

```
/api/updates/check {"force":true}   3.1s
  webui  behind=0  latest_tag=v0.52.492  error=None     <- still checks itself
  agent  behind=0  ignored=True          error=None     <- no longer fetches the agent
```

## 5. Data volumes, upgrades and reinstalls

| Mount | Contents | After recreating the container |
|---|---|---|
| `src/` → `/app/src` | hermes source + WebUI source (`.git` included) | preserved, no reinstall |
| `hermes-data/` → `/app/hermes-agent` | `HERMES_HOME`: pm environments, tools, `config.yaml`, sessions, logs, **`home/` (HOME)** | preserved |
| `workspace/` → `/workspace` | agent workspace | preserved |

`docker compose up -d --force-recreate` (i.e. upgrade the image / reinstall) restores the WebUI in
**14 seconds** as measured, and the bootstrap takes the "already ready" fast path throughout — nothing
is downloaded again.

### What each operation actually does (measured)

| Operation | Data | Reinstall / upgrade? | Ports and switches |
|---|---|---|---|
| `docker stop` / `docker start` | intact (all on volumes) | **no reinstall**, just process restart | container-creation env is reused |
| `docker restart` | intact | no reinstall | **does not re-read `.env`** (edits have no effect) |
| `down` → `up -d` (with `--env-file`) | intact | **no reinstall** (bootstrap fast path: hermes installed / WebUI ready / plugin deps present) | re-interpolated from `.env` |
| `down` → `up -d` (**forgetting** `--env-file`) | ⚠ real data left behind | **full reinstall** (empty `HERMES_HOME`) | everything reverts to defaults (8787 / dashboard off / `./hermes-data`) |
| `up -d` after editing `.env` | intact | no reinstall | applied (the container is recreated) |
| `up` again N days later (volumes still there) | intact | **no reinstall and no automatic upgrade** ¹ | from `.env` |
| When you do want an upgrade | intact | manual `hermes update`, or wait for the `UPDATE_AGENT_TIME` schedule | — |

¹ Upgrades only happen through two paths: `hermes update` inside the container (scheduled job /
manual / the WebUI-Dashboard buttons), and the WebUI updating itself. **Recreating the container
alone never pulls a new version.**

## 6. Ports

| Port | Purpose |
|---|---|
| `HERMES_WEBUI_PORT` (8787) | WebUI |
| `HERMES_DASHBOARD_PORT` (9119) | Dashboard (only started when `HERMES_DASHBOARD_ON=1`) |
| `API_SERVER_PORT` (8642) | OpenAI-compatible API (`/v1/models`, `/v1/chat/completions`), Bearer key required |
| `OPEN_PORT` (3111-3113) | ad-hoc services / test ports |

## 7. Troubleshooting

```bash
docker logs -f hermes-allinone                    # entrypoint + supervisor + first-boot install (streamed)
docker exec hermes-allinone tail -f /app/hermes-agent/logs/bootstrap.log
docker exec hermes-allinone tail -f /app/hermes-agent/logs/webui.log
docker exec hermes-allinone tail -f /app/hermes-agent/logs/gateway.log
docker exec -it hermes-allinone bash              # inside the container (hermes is on PATH)
docker logs hermes-allinone | grep -A7 "login credentials"   # where the password is printed
```

## 8. Differences from v1

| | v1 | v2 |
|---|---|---|
| Image | 7.53 GB (sources and venv baked in) | **1.36 GB** (orchestration only) |
| Install method | hand-rolled `uv sync` + a hand-written version stamp | **the official `install.sh`** (pm owns environments and facts) |
| Updates | relied on a WebUI tag pre-warm | official path; WebUI/Dashboard buttons + 48h schedule + HEAD watcher |
| First boot | fast (dependencies already in the image) | 8-15 minutes (installed online, always the latest) |
| First network access | plugin/tools only | everything (sources + dependencies + plugin) |

> When migrating a host that already runs v1, `docker compose down` v1 first to avoid a 8642/9119
> port clash; v1's data volumes can be kept as a backup.
