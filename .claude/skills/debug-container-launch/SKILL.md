---
name: debug-container-launch
description: Use this skill when Resonite fails to launch, crashes on startup, freezes, shows a black/blank window, or has no audio in the container. Maps the common failure modes to their root causes (X11, GPU, shared memory, audio, user namespaces, drive-letter resolution) and the setting that fixes each.
---

# Debug Container Launch

Most failures here are host-integration issues, not Resonite bugs. Start with `./run.sh logs -f`, then match the symptom below.

## Symptom → Cause → Fix

- **Crashes/hangs randomly, or `X_ShmPutImage` / `BadValue`** — the X MIT-SHM extension can't share SysV shm across the IPC namespace. Fix: `ipc: host` in `compose.yaml` (also needed for the engine↔renderer `/dev/shm` IPC). Verify it wasn't removed.

- **"Bootstrapper messaging timeout" / renderer never starts** — engine↔renderer IPC (`Cloudtoid.Interprocess`) needs a large `/dev/shm`. `ipc: host` provides the host's `/dev/shm`; Docker's default 64 MB is too small. Don't combine `shm_size` with `ipc: host` (mutually exclusive).

- **Freeze at first-run onboarding "Audio" step / no sound** — the native Linux audio backend (`libpulse`) can't reach the host. Check: image installs `libpulse0`, the host PulseAudio/PipeWire socket is mounted, and `PULSE_SERVER=unix:/tmp/pulse-native` is set. `-SkipIntroTutorial` (in the Dockerfile CMD) sidesteps the onboarding freeze but real audio still needs the socket.

- **`Can't find session bus` / `dbus-launch: No such file`** — Steam Linux Runtime's launcher needs a session bus. Fix: `dbus-x11` must be installed in the image.

- **Black window / no display / `cannot open display` / exits silently with no window** — X auth or display targeting is wrong. `init.sh` writes `DISPLAY` and `XAUTHORITY_HOST` to `.env`; the latter points at a generated `.xauth` whose cookie is rewritten to **FamilyWild (`ffff`)** so it authenticates despite the container's random hostname. Check: `.env` `XAUTHORITY_HOST` exists and `.xauth` is non-empty (`xauth -f .xauth list`), `compose.yaml` mounts `${XAUTHORITY_HOST}:/tmp/.Xauthority` (not the old hardcoded `gdm/Xauthority` path), `DISPLAY` points at a **user-owned** X socket, and `/tmp/.X11-unix` is mounted. Re-run `./init.sh` — the cookie path/name is session-specific and changes on re-login.

- **Wayland host (`XDG_SESSION_TYPE=wayland`)** — rendering still goes through **X11 via Xwayland**, not native Wayland (the renderer is a Proton/Wine `.exe`). Xwayland must be running so a `DISPLAY` (e.g. `:1`) and `/tmp/.X11-unix/X*` socket exist; `init.sh` prefers the socket owned by the current user (the display manager's root-owned `:0` greeter socket has no usable cookie). The old code hardcoded a gdm Xorg cookie path that doesn't exist under KDE/SDDM or Wayland — that was the silent-exit cause this setup fixes.

- **Pressure-vessel / namespace errors at startup** — host `kernel.apparmor_restrict_unprivileged_userns` must be `0`, and the service needs `seccomp=unconfined` + `apparmor=unconfined`. `init.sh` warns when the sysctl is wrong.

- **`EACCES` / permission denied on first rsync or umu unpack** — a named-volume mount point became root-owned. The `Dockerfile` must pre-create `/opt/resonite`, `~/.local/share`, `~/.cache`, `~/prefix` as `resonite`-owned **before** the volumes mount. Also confirm `.env` UID/GID match the host user.

- **Wrong GPU drives rendering / nothing on the connected monitor (multi-GPU)** — `init.sh` resolves the monitor's GPU UUID into `NVIDIA_GPU_UUID`; if empty it falls back to `all`. Re-run `./init.sh` after changing monitor/GPU wiring.

- **Paths like `/dev/shm` resolve to the wrong Wine drive** — the writable install must stay **outside `$HOME`** (`/opt/resonite`). Inside `$HOME` (itself a mount), umu makes the parent the `S:` gamedrive and absolute paths misresolve. Don't move it under `$HOME`.

- **Startup splash logo renders as corrupted color bars / test-card (SMPTE bars + noise)** — the Resonite logo texture mis-renders under the default Proton. The Renderer is a `.exe` running under Proton, so the splash rendering depends on the Proton build. umu defaults to UMU-Proton (Valve-based) when `PROTONPATH` is unset, which has this bug; GE-Proton fixes it (the Resonite-on-Linux community's recommended variant). Fix: `PROTONPATH=GE-Proton` in the `Dockerfile` so umu auto-downloads GE-Proton (cached in the `resonite-share` volume under `~/.local/share/Steam/compatibilitytools.d`). Avoid Proton 11 / Experimental / any 11-based build — those won't launch Resonite at all.

## Notes

- The AMD overlay is **unverified on real hardware**; treat AMD-only failures as suspect-the-config first.
- When you find and fix a new failure mode, add a comment at the relevant setting explaining what it prevents — that's the house style.
