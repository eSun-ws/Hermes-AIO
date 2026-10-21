# v2 design notes: bringing the bare-metal install flow into a container

## 1. Why this approach

v1 baked the sources and the venv into the image at build time. That cost 7.53 GB, broke the build
whenever upstream moved, and gave `hermes update` different semantics than a bare-metal install
(a hand-written version stamp that pm did not recognize).

v2 inverts it: **the image only provides the OS, the toolchain and the orchestration scripts
(1.36 GB); hermes and the WebUI are installed online by the official installer on first boot.**
Every deployment therefore gets the current release, and the upgrade path is identical to bare metal
(`hermes update` and both update buttons work).

## 2. The real layout produced by the official installer (this drives every decision)

```
$INSTALL_DIR/.hermes/bin/hermes      -> shim: exec $HERMES_HOME/tools/python-3.x/bin/python3 -I -c '...'
$HERMES_HOME/tools/                  -> uv-managed Python, uv, node, ...
$HERMES_HOME/installs/<key>/         -> pm dependency environments (environments/<key>/venv) + facts.json
$HOME/.local/bin/hermes              -> same shim (the PATH entry point)
$HOME/.local/share/uv/               -> the uv-managed Python interpreters themselves
```

Three consequences follow (all measured):

1. **`HERMES_HOME` cannot be an empty data volume.** The shim contains hard-coded absolute paths; with
   an empty volume it fails outright with `exec: ...python3: not found` and **does not bootstrap
   itself**. That is why first boot has to run the installer.
2. **`HOME` must live on a data volume.** Both the shim and uv's Python live under `$HOME/.local`. If
   `HOME` stays in the image layer (`/root`), recreating the container wipes them, the interpreter
   referenced by `$INSTALL_DIR/venv` becomes a dangling symlink, and the WebUI cannot start. Hence
   this project sets `HOME=/app/hermes-agent/home`.
3. **The WebUI needs its own environment.** pm's `uv sync` runs without `--inexact`, so it **prunes**
   packages that are not in the lock file. WebUI dependencies (fastapi/uvicorn/ruamel/PyYAML)
   therefore cannot live in the pm environment — the next `hermes update` would delete them. v2 uses
   `$INSTALL_DIR/venv` (`uv sync --locked` + `pip install -e WebUI`), which happens to be exactly
   WebUI's auto-discovery priority 2 (`<agent_dir>/venv/bin/python`).

## 3. Process model (equivalent to the two systemd units on bare metal)

| Bare metal | Container |
|---|---|
| `hermes-gateway.service` | `supervisor.sh` → `hermes gateway run --no-supervise --external-supervisor` |
| `hermes-webui.service` (`After=hermes-gateway`, `Restart=always`, `RestartSec=5`) | start the gateway first, then the WebUI; relaunch 5 seconds after a process exits |
| the 48h scheduled task | `updater.sh` (`UPDATE_AGENT_TIME` / `UPDATE_WEBUI_TIME`) |
| "opens but cannot chat" after an update | the supervisor **watches HEAD**: when the commit changes it refreshes dependencies and restarts the WebUI/gateway |

`--external-supervisor` is mandatory: without it `hermes gateway run` detaches into a daemon and the
foreground process exits, so the supervisor would treat that as a crash and loop forever.

## 4. Pitfalls hit (all handled in the code)

| Pitfall | Symptom | Fix |
|---|---|---|
| `HOME` in the image layer | after recreating the container `venv/bin/python` dangles, the WebUI will not start, the installer runs again | point `HOME` at the `home/` directory on the data volume |
| `HERMES_DASHBOARD_BASIC_AUTH_USERNAME` in the container environment | the agent reports `neither password_hash nor password is configured` and **refuses to start** | use our own variable `DASH_BASIC_AUTH_USER`; when enabling the Dashboard, write username+hash as a pair via `hermes config set` |
| `[ cond ] \|\| return` combined with `set -e` | when the condition is false `return` inherits status 1 → PID 1 exits → the container restarts (exit 0) in a loop | every early return is written as `return 0` |
| WebUI readiness probe only checking `run_agent` | the "already ready" fast path is taken → `server.py` dies on startup and the log stays empty | probe `fastapi, uvicorn, ruamel.yaml` as well |
| first-boot logging through `tee \| tail -n 40` | `docker logs` stays blank for the 10 minutes of installation | stream with `sed -u` instead |
| a shallow clone has a single tag | the WebUI update check runs `git fetch --tags`, exceeds the hard-coded 15s and reports a timeout | pre-warm tags on first boot (~30s), then ~1s at runtime |
| the WebUI's agent update leg | upstream pins the channel to stable, but `_select_apply_compare_ref()` falls through to the branch for the agent repo (`origin/main`) → one click drags the agent onto the development line (measured v0.22.2 → rc.5-v0.22.3-1, +3017 commits), out of step with the WebUI; there is no env switch | write `ignore_agent_updates: true` by default (`WEBUI_IGNORE_AGENT_UPDATES=1`) so the two legs are decoupled: the agent is driven only by `hermes update` (stable) |
| running `init.sh` twice concurrently | two instances `up -d` over each other → the container is recreated repeatedly (SIGTERM) | use `-pw`/the check step to avoid concurrency; only `--force` recreates |
| the illusion that hindsight dependencies are "installed" | `plugins install --yes-deps` **only clones the plugin source**; with `--no-enable` the dependencies are never installed → the Dashboard shows "Install provider dependencies / Python dependencies" forever (backend `pm.venv_is_current()` is false) | `install` for the source first, then `plugins enable` (≈400 MB) to create the isolated environment and install dependencies; probe with "can some environment `import hindsight_client`", **never** with `installs/*/environments` (that is the agent's own environment and always exists) |

## 5. Known limitations

- **API/WebUI updates are still bounded by network speed.** The 15-second `git fetch` timeout in the
  WebUI is **hard-coded** upstream (three call sites in `api/updates.py`) with no environment variable
  to tune it. Hosts whose path to GitHub exceeds 15 seconds (measured 22-36 s on one site) report
  `timed out`. This is a network problem that the official install flow hits as well; it is not
  introduced by this project. Options: give that container a proxy, or use the CLI `hermes update`.
- **No GPU support.** v2 is CPU-only for now (v1's `config/hwaccel.yaml` can be ported over).
- **No systemd.** The supervisor reproduces the unit semantics; do not run `systemctl` commands inside
  the container.
