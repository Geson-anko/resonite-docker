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

{
  printf 'HOST_UID=%s\n' "$(id -u)"
  printf 'HOST_GID=%s\n' "$(id -g)"
  # X11 出力先ディスプレイ(SSH からでも検出)
  printf 'DISPLAY=%s\n' "$DISPLAY_DETECTED"
  # bind mount(ro) する Resonite の実体パス
  printf 'RESONITE_DIR=%s\n' "$RESONITE_DIR"
} > .env

echo "generated .env:"
cat .env

if [ ! -e "$RESONITE_DIR/Resonite.exe" ]; then
  echo "warning: $RESONITE_DIR/Resonite.exe が見つかりません。" \
       "RESONITE_DIR=... ./init.sh で場所を指定できます。" >&2
fi
