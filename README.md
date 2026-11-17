# ITP Bern — AI setup

Docker-based setup for using the LLMs hosted at CSCS (Swiss AI Services):

- **OpenCode** — terminal AI coding agent (TUI) in a container.
- **OpenWebUI** — browser chat interface to the same models.

Both use the API at `https://api.swissai.svc.cscs.ch/v1` and a Swiss AI API key.

---

## 1. Prerequisites

- Docker Engine running on the host (Linux or macOS).
  Check with `docker info`.
- `git`, and permission to use Docker as your user. If `docker info` fails with
  "permission denied", add yourself to the `docker` group once and re-login:

  ```bash
  sudo usermod -aG docker "$USER"
  ```

- A Swiss AI API key for the CSCS endpoint. Keep it for the next step.
- On MacOS: `colima`. You can run `setup_macos.sh`, which will check for both
  docker and colima, and install them if necessary. This script also checks if
  `colima` is running and starts it if required. Thus, run this script every
  time before you use the tools below.

## 2. Put your API key in `.env` (once)

The key lives in **exactly one file**, `.env`, in the root of this repository.
It is gitignored and never committed.

```bash
git clone https://github.com/simone-romiti/ITP_Bern-AI_setup.git
# or, with SSH keys set up for GitHub:
# git clone git@github.com:simone-romiti/ITP_Bern-AI_setup.git
cd ITP_Bern-AI_setup

cp .env.example .env
$EDITOR .env          # set SWISSAI_RESEARCH_API_KEY=your-key
```

Both launchers read the key from there. You do not need to edit any script.

> Never commit `.env`. It is listed in `.gitignore`; check with
> `git check-ignore -v .env` if in doubt.
> If a key is ever committed or shared, rotate it.

## 3. OpenCode (terminal)

```bash
./run-opencode.sh
```

This drops you into a shell inside the container; start the agent with
`opencode`.

- First run builds the image (a few minutes); later runs are instant.
- The **current working directory** is mounted as the agent's workspace. To work
  on a project, run the script from that project directory:

  ```bash
  cd ~/my-project
  ~/ITP_Bern-AI_setup/run-opencode.sh
  ```

- Sessions and state are stored in `.opencode_data/` inside the directory you
  launch from, so they survive container rebuilds.
- Config: [`config/opencode.json`](config/opencode.json) is mounted at
  `~/.config/opencode` in the container. It lists the available models and sets
  the default. Edit it in the repository to change models or permissions.
- **Clipboard**: on Linux with Wayland or X11, the launcher forwards the host
  display socket, so `wl-copy`/`wl-paste` and `xclip` inside the container use
  your host clipboard (both packages are in the image). This works automatically
  when `WAYLAND_DISPLAY` or `DISPLAY` is set; it is a no-op on headless machines
  and on macOS.
- Exit the TUI (`Ctrl+C` / `/exit`) to leave; the container keeps running in the
  background. Re-run the script to reconnect.

The published ports are `4096` (OpenCode server) plus `3001 5173 8080` for dev
servers started inside the workspace. Override with `OPENCODE_PORT` and
`EXTRA_PORTS`.

## 4. OpenWebUI (browser)

Run on the host, from anywhere:

```bash
./run-openwebui.sh
```

- Pulls/updates `ghcr.io/open-webui/open-webui:main`, creates the container and
  waits until the UI is actually ready.
- Docker port forwarding: `-p 0.0.0.0:3000:8080`. Open
  <http://localhost:3000> on the machine, or `http://<host-ip>:3000` from the
  network.
- The directory you run the script from is bind-mounted read-write at
  `/workspace` inside the container (override with `OPENWEBUI_WORKSPACE` and
  `OPENWEBUI_WORKSPACE_DIR`), so tools running in the container can access the
  same files as OpenCode.
- From a remote machine, an SSH tunnel is the simplest and safest option:

  ```bash
  ssh -L 3000:localhost:3000 you@itp-host
  # then open http://localhost:3000 locally
  ```

- Chats and settings live in the Docker volume `open-webui`; they are not lost
  when the container is recreated. On a recreate the SQLite database is backed
  up to `~/.local/share/open-webui/backups/`.
- If you change `.env`, the launcher detects the new key and recreates the
  container automatically. To force it: `OPENWEBUI_RESET=1 ./run-openwebui.sh`.

## Files

```
.
├── .env.example              # template for .env (tracked)
├── .env                      # your API key (gitignored)
├── config/opencode.json      # models + default model for OpenCode
├── docker_setup/
│   ├── Dockerfile.opencode   # opencode container image
│   ├── build_image-opencode.sh
│   ├── env.sh                # shared .env loader
│   └── run-opencode.sh       # OpenCode launcher
├── setup_macos.sh            # MacOS setup helper
├── run-opencode.sh           # symlink -> docker_setup/run-opencode.sh
└── run-openwebui.sh          # OpenWebUI launcher
```

## Troubleshooting

- **`docker: permission denied`** — see step 1 (`docker` group, re-login).
- **Port already in use** — another container/service owns `3000` (OpenWebUI) or
  one of the OpenCode ports. Stop it, or use
  `OPENWEBUI_HOST_PORT=3010 ./run-openwebui.sh` /
  `OPENCODE_PORT=4100 ./run-opencode.sh`.
- **Model missing / 404** — the model list is in `config/opencode.json` (and is
  configured in OpenWebUI through the same API). Make sure the model ID exists
  on the CSCS endpoint; ask your local admin for the current list.
- **Rebuild the OpenCode image** after changing `docker_setup/Dockerfile.opencode`:

  ```bash
  ./docker_setup/build_image-opencode.sh
  ./run-opencode.sh          # detects the new image and recreates the container
  ```

- **OpenWebUI stuck on an old version** — the launcher pulls `:main` on every
  run and recreates the container when the image changes. Use
  `OPENWEBUI_RESET=1 ./run-openwebui.sh` to force a fresh container (data volume
  kept, database backed up first).

## Links

- Swiss AI platform (model list): https://serving.swissai.svc.cscs.ch/
- CSCS AI Slack channel: https://swissai-initiative.slack.com/archives/C07DHJFRE2X
