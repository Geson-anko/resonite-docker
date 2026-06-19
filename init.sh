#!/usr/bin/env bash
# Probe the host and write per-machine values to .env, ready for run.sh:
#   ./init.sh   ->  ./run.sh
# If Resonite lives elsewhere: RESONITE_DIR=/path/to/Resonite ./init.sh
set -euo pipefail
cd "$(dirname "$0")"

RESONITE_DIR="${RESONITE_DIR:-$HOME/.steam/steam/steamapps/common/Resonite}"

# Find the X display to render into. Over SSH $DISPLAY is unset, so fall back to
# the active desktop session. On Wayland the renderer (a Wine .exe, an X11 app)
# draws through Xwayland, so what we want here is the Xwayland socket.
detect_display() {
  # 1) Local run: trust the existing $DISPLAY (already Xwayland's value on Wayland).
  if [ -n "${DISPLAY:-}" ]; then
    printf '%s' "$DISPLAY"; return
  fi
  # 2) Pick the logged-in X display (:N) from `who` (visible even over SSH).
  local d
  d="$(who 2>/dev/null | awk '
    $2 ~ /^:[0-9]+(\.[0-9]+)?$/      { print $2; exit }
    $NF ~ /^\(:[0-9]+(\.[0-9]+)?\)$/ { s=$NF; gsub(/[()]/,"",s); print s; exit }')"
  if [ -n "$d" ]; then printf '%s' "$d"; return; fi
  # 3) Infer from the X sockets. Wayland may expose several (e.g. the display
  #    manager's root-owned :0 greeter plus the user's Xwayland :1); the greeter
  #    socket has no usable cookie, so prefer the one owned by the current user.
  local me s n owner
  me="$(id -u)"
  for s in /tmp/.X11-unix/X[0-9]*; do
    [ -S "$s" ] || continue
    owner="$(stat -c '%u' "$s" 2>/dev/null)" || continue
    [ "$owner" = "$me" ] || continue
    n="${s##*/X}"
    printf ':%s' "$n"; return
  done
  # 4) Otherwise the lowest-numbered socket.
  d="$(ls /tmp/.X11-unix/ 2>/dev/null | sed -n 's/^X\([0-9]\+\)$/\1/p' | sort -n | head -n1)"
  if [ -n "$d" ]; then printf ':%s' "$d"; return; fi
  # 5) Last-resort fallback.
  printf ':0'
}

DISPLAY_DETECTED="$(detect_display)"

# Prepare an X auth cookie the container can actually use.
#
# Why: the container's X client (the Wine renderer) authenticates to Xwayland/Xorg
# with MIT-MAGIC-COOKIE-1, which is tied to a hostname. The container's hostname is
# a random container ID, so passing the host's Xauthority verbatim fails to match
# and the connection is refused (window never appears, process exits silently).
#
# Fix: extract the cookie for the current DISPLAY and rewrite its family to ffff
# (FamilyWild = match any host), into a dedicated file (.xauth). This is the standard
# "X11 GUI in Docker" trick and works under both Xorg and Wayland (Xwayland). compose
# mounts this .xauth at /tmp/.Xauthority.
#
# The source Xauthority lives in different places per desktop, so probe in order:
#   $XAUTHORITY                              : explicit (common on KDE/SDDM)
#   ~/.Xauthority                            : classic default
#   /run/user/<uid>/gdm/Xauthority           : GNOME on Xorg (gdm)
#   /run/user/<uid>/xauth_*                  : KDE/SDDM (Xwayland)
#   /run/user/<uid>/.mutter-Xwaylandauth.*   : GNOME on Wayland (Xwayland)
detect_xauthority_src() {
  local f
  if [ -n "${XAUTHORITY:-}" ] && [ -r "${XAUTHORITY}" ]; then
    printf '%s' "$XAUTHORITY"; return
  fi
  for f in \
      "$HOME/.Xauthority" \
      "/run/user/$(id -u)/gdm/Xauthority" \
      /run/user/"$(id -u)"/xauth_* \
      /run/user/"$(id -u)"/.mutter-Xwaylandauth.* ; do
    [ -r "$f" ] && { printf '%s' "$f"; return; }
  done
  return 0  # Not found = empty. Don't let set -e exit silently here.
}

XAUTH_SRC="$(detect_xauthority_src)"
XAUTH_FILE="$PWD/.xauth"   # Generated (gitignored). compose mounts it.
rm -f "$XAUTH_FILE"
if [ -n "$XAUTH_SRC" ] && command -v xauth >/dev/null 2>&1; then
  # Rewrite the source cookie's family to ffff (FamilyWild) into the new file.
  # Guard with `if` so a failure here doesn't abort init; discard an empty result.
  if xauth -f "$XAUTH_SRC" nlist "$DISPLAY_DETECTED" 2>/dev/null \
       | sed -e 's/^..../ffff/' \
       | xauth -f "$XAUTH_FILE" nmerge - >/dev/null 2>&1 && [ -s "$XAUTH_FILE" ]; then
    :
  else
    rm -f "$XAUTH_FILE"
  fi
fi
# Always make the mount target exist (an empty file, never a phantom directory).
# If it's empty, X auth won't pass; we warn about that after writing .env.
[ -e "$XAUTH_FILE" ] || : > "$XAUTH_FILE"

# Identify the GPU the monitor is attached to and pass its UUID to the container.
# On multi-GPU hosts, rendering on the wrong GPU needs a PRIME copy or shows nothing.
# Match a connected DRM connector -> PCI address -> nvidia-smi UUID.
# Note: a bare `return` yields the previous command's exit code; under set -e that
# would make GPU_UUID=$(...) die silently on a miss, so we `return 0` explicitly
# (empty UUID = the container falls back to `all`).
detect_display_gpu() {
  command -v nvidia-smi >/dev/null 2>&1 || return 0
  for s in /sys/class/drm/card*-*/status; do
    [ "$(cat "$s" 2>/dev/null)" = connected ] || continue
    card="$(basename "$(dirname "$s")" | sed 's/-.*//')"
    pci="$(basename "$(readlink -f "/sys/class/drm/$card/device")" 2>/dev/null)"  # 0000:0f:00.0
    short="${pci#0000:}"  # 0f:00.0
    uuid="$(nvidia-smi --query-gpu=gpu_bus_id,uuid --format=csv,noheader 2>/dev/null \
            | awk -F', *' -v b="$short" 'BEGIN{b=toupper(b)} toupper($1) ~ b {print $2; exit}')"
    [ -n "$uuid" ] && { printf '%s' "$uuid"; return 0; }
  done
  return 0  # No matching GPU -> empty UUID, fall back rather than die nonzero.
}

GPU_UUID="$(detect_display_gpu)"

# AMD: identify the rendering GPU (the one with the monitor attached) and emit its
# render node + Mesa device selection. Passing all of /dev/dri to the container on a
# multi-GPU host (e.g. a server's ASPEED BMC display chip + several dGPUs) breaks twice:
#  1) The renderer (Renderite=Unity/Vulkan) grabs a non-display GPU; its render and
#     present targets disagree and it crashes.
#  2) The renderer's video-decode init (GStreamer/Media Foundation) enumerates every
#     DRI node via GBM/EGL and trips over the non-3D BMC chip (ast, driver (null)),
#     crashing the process group (UnityCrashHandler -> Killed).
# Fix is the same "show only the display GPU" as pinning NVIDIA via NVIDIA_GPU_UUID:
#  - Pass only that GPU's render node (AMD_RENDER_NODE; compose.amd.yml sets device).
#  - Also pin Mesa selection (AMD_VK_DEVICE_SELECT for Vulkan, AMD_DRI_PRIME for GL/EGL).
# Pick one monitor-connected amdgpu card (skip the BMC's Virtual/Writeback connectors).
# Output: "<vendor>:<device> <pci-tag> <render-node>"
#   e.g. "1002:7590 pci-0000_c3_00_0 /dev/dri/renderD129" (empty if none found).
detect_amd_render_gpu() {
  local s con card drv vendor device pci tag rnode
  for s in /sys/class/drm/card*-*/status; do
    [ "$(cat "$s" 2>/dev/null)" = connected ] || continue
    con="$(basename "$(dirname "$s")")"                 # e.g. card2-DP-5
    case "$con" in *-Virtual-*|*-Writeback-*) continue ;; esac
    card="${con%%-*}"                                   # card2
    drv="$(basename "$(readlink -f "/sys/class/drm/$card/device/driver" 2>/dev/null)" 2>/dev/null)"
    [ "$drv" = amdgpu ] || continue
    vendor="$(cat "/sys/class/drm/$card/device/vendor" 2>/dev/null)"; vendor="${vendor#0x}"
    device="$(cat "/sys/class/drm/$card/device/device" 2>/dev/null)"; device="${device#0x}"
    pci="$(basename "$(readlink -f "/sys/class/drm/$card/device" 2>/dev/null)")"  # 0000:c3:00.0
    tag="pci-$(printf '%s' "$pci" | tr ':.' '_')"       # pci-0000_c3_00_0
    rnode="$(readlink -f "/dev/dri/by-path/pci-${pci}-render" 2>/dev/null)"  # /dev/dri/renderD129
    [ -n "$vendor" ] && [ -n "$device" ] && [ -n "$rnode" ] \
      && { printf '%s:%s %s %s' "$vendor" "$device" "$tag" "$rnode"; return 0; }
  done
  return 0  # No matching GPU -> empty (compose falls back to all of /dev/dri).
}

AMD_VK_DEVICE_SELECT=""; AMD_DRI_PRIME=""; AMD_RENDER_NODE=""
AMD_RENDER="$(detect_amd_render_gpu)"
if [ -n "$AMD_RENDER" ]; then
  # shellcheck disable=SC2086  # Fields are ids/paths with no spaces (intentional split).
  set -- $AMD_RENDER
  # The trailing ! means "enumerate only this one (hide other GPUs)". Without it Mesa
  # only reorders, and Unity may still pick another AMD GPU by VRAM-size heuristics.
  AMD_VK_DEVICE_SELECT="${1}!"             # 1002:7590!
  AMD_DRI_PRIME="$2"                        # pci-0000_c3_00_0
  AMD_RENDER_NODE="$3"                      # /dev/dri/renderD129
fi

# render/video group GIDs for /dev/dri (GPU). group_add'd onto the non-root user.
RENDER_GID="$(getent group render | cut -d: -f3)"
VIDEO_GID="$(getent group video  | cut -d: -f3)"
[ -n "$RENDER_GID" ] || RENDER_GID="$(stat -c '%g' /dev/dri/renderD128 2>/dev/null || echo 110)"
[ -n "$VIDEO_GID" ]  || VIDEO_GID="$(stat -c '%g' /dev/dri/card0      2>/dev/null || echo 44)"

{
  printf 'HOST_UID=%s\n' "$(id -u)"
  printf 'HOST_GID=%s\n' "$(id -g)"
  # X11 output display (Xwayland on Wayland; detected even over SSH).
  printf 'DISPLAY=%s\n' "$DISPLAY_DETECTED"
  # X auth cookie (rewritten to FamilyWild). compose mounts it at /tmp/.Xauthority.
  printf 'XAUTHORITY_HOST=%s\n' "$XAUTH_FILE"
  # Supplementary group GIDs for /dev/dri access.
  printf 'RENDER_GID=%s\n' "$RENDER_GID"
  printf 'VIDEO_GID=%s\n' "$VIDEO_GID"
  # Rendering GPU (monitor side). Empty -> the container falls back to `all`.
  printf 'NVIDIA_GPU_UUID=%s\n' "$GPU_UUID"
  # AMD: values to pin rendering to the monitor-connected GPU, so on a multi-GPU host
  # the renderer doesn't grab a non-display GPU or BMC chip (crash / video-decode crash).
  # Read by compose.amd.yml:
  #  - AMD_RENDER_NODE: the only render node passed in (devices limited to one GPU).
  #  - AMD_VK_DEVICE_SELECT: Vulkan (Renderite) device select (trailing ! pins one GPU).
  #  - AMD_DRI_PRIME: GL/EGL path device select.
  # All empty -> treated as single-GPU, fall back to all of /dev/dri (legacy behavior).
  printf 'AMD_RENDER_NODE=%s\n' "$AMD_RENDER_NODE"
  printf 'AMD_VK_DEVICE_SELECT=%s\n' "$AMD_VK_DEVICE_SELECT"
  printf 'AMD_DRI_PRIME=%s\n' "$AMD_DRI_PRIME"
  # Path to the host's Resonite install (bind-mounted read-only).
  printf 'RESONITE_DIR=%s\n' "$RESONITE_DIR"
} > .env

echo "generated .env:"
cat .env

# Note the session type. On Wayland, X11 apps (the Wine renderer) still draw through
# Xwayland; if Xwayland is up, $DISPLAY was detected above.
if [ "${XDG_SESSION_TYPE:-}" = "wayland" ]; then
  echo "info: Wayland session detected. X11 (the Wine renderer) draws via Xwayland (DISPLAY=$DISPLAY_DETECTED)."
fi

# Warn if no X auth cookie could be prepared. An empty cookie means no X connection
# and the process exits silently with no window (the most common launch failure).
if [ ! -s "$XAUTH_FILE" ]; then
  echo "warning: could not prepare an X auth cookie (.xauth is empty: $XAUTH_FILE)." >&2
  echo "  Cannot connect to the X display ($DISPLAY_DETECTED); may exit silently." >&2
  echo "  Run inside a graphical session and confirm Xorg or Xwayland is running." >&2
  echo "  X11 apps cannot render on a Wayland-only host without Xwayland." >&2
fi

if [ ! -e "$RESONITE_DIR/Resonite.exe" ]; then
  echo "warning: $RESONITE_DIR/Resonite.exe not found." \
       "Set the location with RESONITE_DIR=... ./init.sh" >&2
fi

# Check for the audio (PulseAudio/PipeWire) socket. compose mounts
# /run/user/<uid>/pulse/native and points PULSE_SERVER=unix:/tmp/pulse-native at it.
# Without it the engine can't open an output device and may freeze at the first-run
# onboarding "Audio" step. CMD's -SkipIntroTutorial sidesteps that freeze, but real
# audio still needs PipeWire (or PulseAudio) running on the host.
PULSE_SOCK="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/pulse/native"
if [ ! -S "$PULSE_SOCK" ]; then
  echo "warning: PulseAudio/PipeWire socket not found: $PULSE_SOCK" >&2
  echo "  No audio; may freeze at first-run onboarding." >&2
  echo "  Confirm PipeWire (or PulseAudio) is running on the host." >&2
fi

# Steam Linux Runtime (pressure-vessel) uses unprivileged user namespaces. Ubuntu 24.04
# restricts these via AppArmor by default, so it must be lowered to 0. This cannot be
# set from inside the container — it's a host setting.
USERNS_KEY=kernel.apparmor_restrict_unprivileged_userns
if [ "$(sysctl -n "$USERNS_KEY" 2>/dev/null || echo 0)" != "0" ]; then
  echo "warning: $USERNS_KEY is not 0. Resonite (pressure-vessel) cannot start." >&2
  echo "  Temporary:  sudo sysctl $USERNS_KEY=0" >&2
  echo "  Persistent: echo '$USERNS_KEY=0' | sudo tee /etc/sysctl.d/99-resonite-userns.conf && sudo sysctl --system" >&2
fi
