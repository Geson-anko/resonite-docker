#!/usr/bin/env bash
# Detect the GPU (NVIDIA/AMD/Intel) and launch Resonite with the matching overlay.
#   ./init.sh          # generate .env first (host UID/GID, DISPLAY, GPU UUID, ...)
#   ./run.sh           # docker compose up --build with the detected GPU overlay
#   ./run.sh down      # extra args are forwarded to docker compose
#   ./run.sh logs -f
set -euo pipefail
cd "$(dirname "$0")"

# Without .env we can't resolve host-specific values (RESONITE_DIR, etc.).
if [ ! -f .env ]; then
  echo "error: .env is missing. Run ./init.sh first." >&2
  exit 1
fi

# Detect the GPU vendor.
#  1) NVIDIA: via nvidia-container-toolkit (nvidia-smi) or the device node.
#  2) Otherwise: the DRM card's PCI vendor ID
#     (0x10de=NVIDIA, 0x1002=AMD, 0x8086=Intel).
#     A laptop's Intel iGPU may land on card0 or card1, so scan all card[0-9].
detect_gpu() {
  if command -v nvidia-smi >/dev/null 2>&1 || ls /dev/nvidia0 >/dev/null 2>&1; then
    echo nvidia; return
  fi
  local v
  for v in /sys/class/drm/card[0-9]/device/vendor; do
    [ -r "$v" ] || continue
    case "$(cat "$v")" in
      0x10de) echo nvidia; return ;;
      0x1002) echo amd;    return ;;
      0x8086) echo intel;  return ;;
    esac
  done
  echo unknown
}

GPU="$(detect_gpu)"
case "$GPU" in
  nvidia) OVERLAY=compose.nvidia.yml ;;
  amd)    OVERLAY=compose.amd.yml ;;
  intel)  OVERLAY=compose.intel.yml ;;
  *)
    echo "error: could not detect a supported GPU (NVIDIA/AMD/Intel)." >&2
    echo "  Check /sys/class/drm/card*/device/vendor." >&2
    exit 1
    ;;
esac

echo "detected GPU: $GPU  ->  compose.yaml + $OVERLAY"

# Run the given subcommand if args were passed; otherwise default to up --build.
if [ "$#" -gt 0 ]; then
  exec docker compose -f compose.yaml -f "$OVERLAY" "$@"
fi
exec docker compose -f compose.yaml -f "$OVERLAY" up --build
