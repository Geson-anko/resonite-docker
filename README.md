# resonite-docker

Run [Resonite](https://resonite.com/) — the VR social platform — in a Docker container on Linux, rendering to your **host desktop** (X11 or Wayland) with **GPU acceleration** (NVIDIA / AMD / Intel) and **host audio**.

The container does **not** bundle Resonite. It bind-mounts your existing Steam install read-only and launches it through [umu-launcher](https://github.com/Open-Wine-Components/umu-launcher) (Proton/Wine). The hard part isn't Resonite — it's host integration (X11, GPU, audio, shared-memory IPC, user namespaces), and that's what this repo packages.

> 🌐 **日本語版は [README.ja.md](README.ja.md) を参照してください.**

---

Rendering is always over **X11**. Resonite's renderer is a Proton/Wine `.exe` (an X11 app), so even on a Wayland session it draws through **Xwayland**. "Wayland support" here means "connect to the Xwayland display correctly" — there is no native-Wayland rendering.

## How it works (mental model)

When Resonite's Bootstrapper detects Wine, it splits execution:

- **The engine runs natively on Linux** (.NET). Its audio backend connects to your host PipeWire/PulseAudio via `libpulse` — not through Wine.
- **Only the renderer `.exe` runs under Proton/Wine**, drawing to X11 (Xwayland on Wayland).
- **Engine ↔ renderer IPC** uses a memory-mapped file in `/dev/shm` (`Cloudtoid.Interprocess`), which is why the container needs `ipc: host`.

This split drives almost every setting in the repo.

## Requirements

- **Linux** with Docker + Docker Compose.
- A **graphical session** the container can render into. On Wayland, **Xwayland must be running** (so a `DISPLAY` and `/tmp/.X11-unix/X*` socket exist).
- An existing **Resonite install** (Steam). Default path: `~/.steam/steam/steamapps/common/Resonite`.
- A **GPU**:
  | Vendor | Status | Notes |
  | --- | --- | --- |
  | NVIDIA | ✅ Verified | Needs [`nvidia-container-toolkit`](https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/install-guide.html). Driver injected from host. |
  | AMD | ✅ Verified | Mesa/RADV bundled in the image. |
  | Intel | ✅ Verified | iGPU via Mesa (iris/ANV). Runs heavy. |
- A running **PipeWire** (or PulseAudio) socket at `/run/user/<uid>/pulse/native`.
- `kernel.apparmor_restrict_unprivileged_userns=0` on the host (Ubuntu 24.04+ defaults it on, which blocks Steam Linux Runtime's pressure-vessel):
  ```bash
  # temporary
  sudo sysctl kernel.apparmor_restrict_unprivileged_userns=0
  # persistent
  echo 'kernel.apparmor_restrict_unprivileged_userns=0' | sudo tee /etc/sysctl.d/99-resonite-userns.conf && sudo sysctl --system
  ```

## Quick start

```bash
git clone https://github.com/Geson-anko/resonite-docker.git
cd resonite-docker

./init.sh        # 1. probe the host and write .env (UID/GID, DISPLAY, X cookie, GPU, ...)
./run.sh         # 2. detect the GPU and `docker compose up --build` with the right overlay
```

`init.sh` prints non-fatal warnings if the audio socket or the userns sysctl are missing — resolve those before expecting a clean launch.

If Resonite is not at the default Steam path:

```bash
RESONITE_DIR=/path/to/Resonite ./init.sh
```

> **Always run `./init.sh` before `./run.sh`.** `.env` is gitignored and `compose.yaml` fails fast without it. Re-run `./init.sh` after re-login or after changing monitor/GPU wiring (the X cookie path is session-specific).

**First launch is slow:** it downloads GE-Proton + Steam Linux Runtime and rsyncs ~2 GB of Resonite into a volume. Later launches sync only changed files.

## Operating

`run.sh` forwards any extra arguments to `docker compose` (the overlay is already selected):

```bash
./run.sh logs -f     # follow logs
./run.sh up -d       # start detached
./run.sh down        # stop and remove
./run.sh down -v     # also remove the volumes (full reset: re-sync + re-login)
```

## Persistence

Only four named volumes survive `down` — not all of `$HOME`. Disposable state (machine-id, logs, `.dbus`) is regenerated per container.

| Volume | Mount | Holds |
| --- | --- | --- |
| `resonite-app` | `/opt/resonite` | Writable copy of the install (rsynced from the read-only host mount) |
| `resonite-share` | `~/.local/share` | umu/Proton/Steam Linux Runtime + Resonite login & settings |
| `resonite-cache` | `~/.cache` | Asset + shader cache |
| `resonite-prefix` | `~/prefix` | Wine prefix (`WINEPREFIX`) |

## Repository layout

| File | Role |
| --- | --- |
| `init.sh` | Probes the host (run on the **host**) and writes `.env` + the FamilyWild X cookie `.xauth`. |
| `run.sh` | Detects the GPU vendor and runs `docker compose` with the matching overlay. |
| `compose.yaml` | GPU-agnostic base (X11, audio, IPC, volumes, namespaces). |
| `compose.{nvidia,amd,intel}.yml` | GPU-vendor overlays (exactly one is layered on the base). |
| `Dockerfile` | Minimal Debian image: umu-launcher, libpulse, and Mesa only for AMD/Intel. |
| `entrypoint.sh` | rsyncs the install into the writable volume, then launches. |

The value of this repo is the *why* behind each host hack — **read the comment next to a setting before changing it.**

## Troubleshooting

Most failures are host-integration issues, not Resonite bugs. Start with `./run.sh logs -f`, then match the symptom:

| Symptom | Likely cause / fix |
| --- | --- |
| Exits silently, no window / `cannot open display` | X auth or display targeting. Re-run `./init.sh`; confirm `.xauth` is non-empty (`xauth -f .xauth list`) and `DISPLAY` points at a **user-owned** X socket. |
| Random crashes/hangs, `X_ShmPutImage` / `BadValue` | X MIT-SHM can't cross the IPC namespace. `ipc: host` must be present in `compose.yaml`. |
| "Bootstrapper messaging timeout", renderer never starts | Engine↔renderer IPC needs a large `/dev/shm`; `ipc: host` provides it (don't add `shm_size`). |
| Freeze at first-run "Audio" step / no sound | Host audio unreachable. Check `libpulse0` is installed, the PulseAudio/PipeWire socket is mounted, and PipeWire is running. |
| `Can't find session bus` / `dbus-launch: No such file` | `dbus-x11` must be in the image. |
| Startup splash is corrupted color bars / test-card | Default Proton mis-renders the logo. `PROTONPATH=GE-Proton` (set in the `Dockerfile`) fixes it. Avoid Proton 11 / Experimental. |
| `EACCES` on first rsync / umu unpack | A volume mount point became root-owned. The `Dockerfile` pre-creates them as `resonite`-owned; confirm `.env` UID/GID match the host. |
| Wrong GPU renders / nothing on the monitor (multi-GPU) | Re-run `./init.sh` to re-detect the monitor's GPU. |

## Acknowledgments

- [Resonite](https://resonite.com/) by Yellow Dog Man Studios.
- [umu-launcher](https://github.com/Open-Wine-Components/umu-launcher) (Open Wine Components) and [GE-Proton](https://github.com/GloriousEggroll/proton-ge-custom).

## License

[MIT](LICENSE) © Geson-anko
