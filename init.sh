#!/usr/bin/env bash
# 現在のUID/GID・Resonite の場所・X ディスプレイを .env に書き出す。
#   ./init.sh   ->  docker compose up --build
# 別の場所に Resonite がある場合: RESONITE_DIR=/path/to/Resonite ./init.sh
set -euo pipefail
cd "$(dirname "$0")"

RESONITE_DIR="${RESONITE_DIR:-$HOME/.steam/steam/steamapps/common/Resonite}"

# X ディスプレイを検出する。SSH 接続だと $DISPLAY が未設定なので、
# ログイン中のデスクトップセッションから拾う。
detect_display() {
  # 1) ローカル実行なら既存の $DISPLAY をそのまま使う
  if [ -n "${DISPLAY:-}" ]; then
    printf '%s' "$DISPLAY"; return
  fi
  # 2) who からログイン中の X ディスプレイ(:N)を拾う(SSHでも見える)
  local d
  d="$(who 2>/dev/null | awk '
    $2 ~ /^:[0-9]+(\.[0-9]+)?$/      { print $2; exit }
    $NF ~ /^\(:[0-9]+(\.[0-9]+)?\)$/ { s=$NF; gsub(/[()]/,"",s); print s; exit }')"
  if [ -n "$d" ]; then printf '%s' "$d"; return; fi
  # 3) X11 ソケットから推定(最小番号)
  d="$(ls /tmp/.X11-unix/ 2>/dev/null | sed -n 's/^X\([0-9]\+\)$/\1/p' | sort -n | head -n1)"
  if [ -n "$d" ]; then printf ':%s' "$d"; return; fi
  # 4) 最終フォールバック
  printf ':0'
}

DISPLAY_DETECTED="$(detect_display)"

# モニタが接続されている GPU を特定し、その UUID をコンテナへ渡す。
# マルチGPU環境では、表示出力に使う GPU で描画させないと PRIME コピーが要る/映らない。
# connected な DRM コネクタ -> PCI -> nvidia-smi の UUID と突き合わせる。
# 注: 引数なし return は直前コマンドの終了コードを返す。set -e 下で
# GPU_UUID=$(...) がそれを引き継ぎ無言で死ぬのを避けるため、検出失敗時は
# 明示的に return 0 する(UUID 空 = コンテナ側で all にフォールバック)。
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
  return 0  # 該当 GPU 無し -> UUID 空でフォールバック(非ゼロで死なせない)
}

GPU_UUID="$(detect_display_gpu)"

# /dev/dri (GPU) の render/video グループ GID。非rootユーザに group_add する。
RENDER_GID="$(getent group render | cut -d: -f3)"
VIDEO_GID="$(getent group video  | cut -d: -f3)"
[ -n "$RENDER_GID" ] || RENDER_GID="$(stat -c '%g' /dev/dri/renderD128 2>/dev/null || echo 110)"
[ -n "$VIDEO_GID" ]  || VIDEO_GID="$(stat -c '%g' /dev/dri/card0      2>/dev/null || echo 44)"

{
  printf 'HOST_UID=%s\n' "$(id -u)"
  printf 'HOST_GID=%s\n' "$(id -g)"
  # X11 出力先ディスプレイ(SSH からでも検出)
  printf 'DISPLAY=%s\n' "$DISPLAY_DETECTED"
  # /dev/dri アクセス用の補助グループ GID
  printf 'RENDER_GID=%s\n' "$RENDER_GID"
  printf 'VIDEO_GID=%s\n' "$VIDEO_GID"
  # 描画に使う GPU(モニタ接続側)。空ならコンテナ側で all にフォールバック。
  printf 'NVIDIA_GPU_UUID=%s\n' "$GPU_UUID"
  # bind mount(ro) する Resonite の実体パス
  printf 'RESONITE_DIR=%s\n' "$RESONITE_DIR"
} > .env

echo "generated .env:"
cat .env

if [ ! -e "$RESONITE_DIR/Resonite.exe" ]; then
  echo "warning: $RESONITE_DIR/Resonite.exe が見つかりません。" \
       "RESONITE_DIR=... ./init.sh で場所を指定できます。" >&2
fi

# 音声(PulseAudio/PipeWire)ソケットの存在を確認する。compose は
# /run/user/<uid>/pulse/native を mount し PULSE_SERVER=unix:/tmp/pulse-native で指す。
# 無い(音声サーバ未起動)と Resonite のエンジンが出力デバイスを開けず、初回オンボーディングの
# Audio ステップでフリーズすることがある。CMD の -SkipIntroTutorial で回避はしているが、
# 実際の音声出力にはホスト側で PipeWire(または PulseAudio)が動いている必要がある。
PULSE_SOCK="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/pulse/native"
if [ ! -S "$PULSE_SOCK" ]; then
  echo "warning: PulseAudio/PipeWire ソケットが見つかりません: $PULSE_SOCK" >&2
  echo "  音声が出ず、初回オンボーディングでフリーズする場合があります。" >&2
  echo "  ホストで PipeWire(または PulseAudio)が起動しているか確認してください。" >&2
fi

# Steam Linux Runtime(pressure-vessel)は unprivileged user namespace を使う。
# Ubuntu 24.04 は既定でこれを AppArmor で制限しているので 0 に下げる必要がある。
# (コンテナ内からは設定できない=ホスト側で設定する)
USERNS_KEY=kernel.apparmor_restrict_unprivileged_userns
if [ "$(sysctl -n "$USERNS_KEY" 2>/dev/null || echo 0)" != "0" ]; then
  echo "warning: $USERNS_KEY が 0 ではありません。Resonite(pressure-vessel)が起動できません。" >&2
  echo "  一時的に設定:  sudo sysctl $USERNS_KEY=0" >&2
  echo "  永続化:        echo '$USERNS_KEY=0' | sudo tee /etc/sysctl.d/99-resonite-userns.conf && sudo sysctl --system" >&2
fi
