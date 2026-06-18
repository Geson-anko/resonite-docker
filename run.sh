#!/usr/bin/env bash
# GPU(NVIDIA/AMD)を検出し、適した compose オーバーレイで Resonite を起動する。
#   ./init.sh          # 先に .env を生成(ホスト UID/GID, DISPLAY, GPU UUID 等)
#   ./run.sh           # 検出した GPU 用 overlay で docker compose up --build
#   ./run.sh down      # 追加引数はそのまま docker compose に渡す
#   ./run.sh logs -f
set -euo pipefail
cd "$(dirname "$0")"

# .env が無いと RESONITE_DIR 等のホスト依存値を解決できないので起動しない。
if [ ! -f .env ]; then
  echo "error: .env がありません。先に ./init.sh を実行してください。" >&2
  exit 1
fi

# GPU ベンダーを検出する。
#  1) NVIDIA は nvidia-container-toolkit(nvidia-smi)かデバイスノードで判定。
#  2) それ以外は DRM カードの PCI ベンダーID で判定(0x10de=NVIDIA, 0x1002=AMD)。
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
    esac
  done
  echo unknown
}

GPU="$(detect_gpu)"
case "$GPU" in
  nvidia) OVERLAY=compose.nvidia.yml ;;
  amd)    OVERLAY=compose.amd.yml ;;
  *)
    echo "error: 対応 GPU(NVIDIA/AMD)を検出できませんでした。" >&2
    echo "  /sys/class/drm/card*/device/vendor を確認してください。" >&2
    exit 1
    ;;
esac

echo "detected GPU: $GPU  ->  compose.yaml + $OVERLAY"

# 追加引数があればそのサブコマンドを、無ければ既定で up --build を実行する。
if [ "$#" -gt 0 ]; then
  exec docker compose -f compose.yaml -f "$OVERLAY" "$@"
fi
exec docker compose -f compose.yaml -f "$OVERLAY" up --build
