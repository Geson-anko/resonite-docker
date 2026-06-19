---
name: run-resonite
description: Use this skill when launching Resonite in the container, setting up the host for the first time, or stopping/inspecting the running container. Covers the init.sh → run.sh flow, host prerequisites (X11, GPU, audio, user namespaces), and the named-volume persistence model.
---

# Run Resonite in the Container

This skill guides launching and operating the containerized Resonite.

## Host Prerequisites

- A running X11 desktop session (the container renders to it; Wayland-only sessions need Xwayland).
- Docker + Docker Compose, and for NVIDIA the `nvidia-container-toolkit`.
- A running **PulseAudio/PipeWire** socket at `/run/user/<uid>/pulse/native` — without it Resonite's engine hangs at the audio onboarding step.
- `kernel.apparmor_restrict_unprivileged_userns=0` on the host (Ubuntu 24.04+ defaults it on, which blocks Steam Linux Runtime's pressure-vessel):
  ```bash
  sudo sysctl kernel.apparmor_restrict_unprivileged_userns=0          # temporary
  echo 'kernel.apparmor_restrict_unprivileged_userns=0' | sudo tee /etc/sysctl.d/99-resonite-userns.conf && sudo sysctl --system   # persistent
  ```

## Launch

```bash
./init.sh        # probe host → write .env (UID/GID, DISPLAY, GPU UUID, render/video GIDs, RESONITE_DIR)
./run.sh         # detect GPU → docker compose up --build with the right overlay
```

If Resonite is not at the default Steam path:
```bash
RESONITE_DIR=/path/to/Resonite ./init.sh
```

`init.sh` prints non-fatal warnings if the audio socket or the userns sysctl are missing — resolve those before expecting a clean launch.

## Operate

`run.sh` forwards extra args to `docker compose` with the overlay already selected:
```bash
./run.sh logs -f     # follow logs
./run.sh up -d       # detached
./run.sh down        # stop and remove
```

First launch is slow: it downloads Proton/Steam Linux Runtime and rsyncs ~2 GB of Resonite into the `resonite-app` volume. Subsequent launches sync only changed files.

## Persistence

Four named volumes survive `down` (everything else regenerates per container): `resonite-app` (install copy), `resonite-share` (Proton/runtime + login & settings), `resonite-cache` (asset/shader cache), `resonite-prefix` (Wine prefix). To fully reset, remove them with `./run.sh down -v` — note this forces a full re-sync and re-login.
