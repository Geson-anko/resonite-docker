#!/usr/bin/env bash
# 現在のUID/GID・Resonite の場所・X ディスプレイを .env に書き出す。
#   ./init.sh   ->  docker compose up --build
# 別の場所に Resonite がある場合: RESONITE_DIR=/path/to/Resonite ./init.sh
set -euo pipefail
cd "$(dirname "$0")"

RESONITE_DIR="${RESONITE_DIR:-$HOME/.steam/steam/steamapps/common/Resonite}"

# X ディスプレイを検出する。SSH 接続だと $DISPLAY が未設定なので、
# ログイン中のデスクトップセッションから拾う。
# Wayland セッションでも X11 アプリ(Resonite の Wine レンダラ)は Xwayland 経由で
# 描画するので、ここでは「接続すべき X ディスプレイ」= Xwayland のソケットを探す。
detect_display() {
  # 1) ローカル実行なら既存の $DISPLAY をそのまま使う(Wayland 上では Xwayland の値)
  if [ -n "${DISPLAY:-}" ]; then
    printf '%s' "$DISPLAY"; return
  fi
  # 2) who からログイン中の X ディスプレイ(:N)を拾う(SSHでも見える)
  local d
  d="$(who 2>/dev/null | awk '
    $2 ~ /^:[0-9]+(\.[0-9]+)?$/      { print $2; exit }
    $NF ~ /^\(:[0-9]+(\.[0-9]+)?\)$/ { s=$NF; gsub(/[()]/,"",s); print s; exit }')"
  if [ -n "$d" ]; then printf '%s' "$d"; return; fi
  # 3) X ソケットから推定。Wayland では Xwayland のソケットが複数並ぶことがあり
  #    (例: ディスプレイマネージャの :0 は root 所有、ユーザの Xwayland は :1)、
  #    root 所有のグリーター用ソケットに繋ぐと認証クッキーが無く接続できない。
  #    そこで自分(現在UID)が所有するソケットを優先する。
  local me s n owner
  me="$(id -u)"
  for s in /tmp/.X11-unix/X[0-9]*; do
    [ -S "$s" ] || continue
    owner="$(stat -c '%u' "$s" 2>/dev/null)" || continue
    [ "$owner" = "$me" ] || continue
    n="${s##*/X}"
    printf ':%s' "$n"; return
  done
  # 4) それも無ければ最小番号のソケット
  d="$(ls /tmp/.X11-unix/ 2>/dev/null | sed -n 's/^X\([0-9]\+\)$/\1/p' | sort -n | head -n1)"
  if [ -n "$d" ]; then printf ':%s' "$d"; return; fi
  # 5) 最終フォールバック
  printf ':0'
}

DISPLAY_DETECTED="$(detect_display)"

# X 認証クッキー(Xauthority)を、コンテナ内からでも使える形で用意する。
#
# なぜ必要か: コンテナ内の X クライアント(Wine レンダラ)が Xwayland/Xorg へ
# 接続する際 MIT-MAGIC-COOKIE-1 で認証する。クッキーはホスト名に紐づくが、
# コンテナのホスト名はランダムなコンテナIDなので、ホストの Xauthority をそのまま
# 渡しても一致せず接続が拒否される(→ ウィンドウが出ず無言で落ちる)。
# 旧構成は gdm 固定パスのクッキーを直接マウントしていたが、KDE/SDDM や Wayland
# セッションにそのパスは無く、Docker が空ディレクトリを作って X 認証を壊していた。
#
# どう用意するか: 現在の DISPLAY のクッキーを取り出し、family を ffff
# (FamilyWild = 任意ホスト一致)に書き換えた専用ファイル(.xauth)を生成する。
# 「X11 GUI を Docker で動かす」定番手法で、Xorg でも Wayland(Xwayland)でも有効。
# compose はこの .xauth を /tmp/.Xauthority にマウントする。
#
# 取得元(ソース Xauthority)はデスクトップごとに場所が異なるので順に探す:
#   $XAUTHORITY                              : セッションが明示(KDE/SDDM 等で多い)
#   ~/.Xauthority                            : 古典的な既定
#   /run/user/<uid>/gdm/Xauthority           : GNOME on Xorg(gdm)
#   /run/user/<uid>/xauth_*                  : KDE/SDDM(Wayland の Xwayland)
#   /run/user/<uid>/.mutter-Xwaylandauth.*   : GNOME on Wayland(Xwayland)
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
  return 0  # 見つからない=空。set -e 下で無言終了させない。
}

XAUTH_SRC="$(detect_xauthority_src)"
XAUTH_FILE="$PWD/.xauth"   # 生成先(.gitignore 済み)。compose がマウントする。
rm -f "$XAUTH_FILE"
if [ -n "$XAUTH_SRC" ] && command -v xauth >/dev/null 2>&1; then
  # ソースの DISPLAY 用クッキーを ffff(FamilyWild)へ書き換えて新ファイルへ取り込む。
  # 前段が失敗しても init を止めないよう if で受け、空生成なら破棄する。
  if xauth -f "$XAUTH_SRC" nlist "$DISPLAY_DETECTED" 2>/dev/null \
       | sed -e 's/^..../ffff/' \
       | xauth -f "$XAUTH_FILE" nmerge - >/dev/null 2>&1 && [ -s "$XAUTH_FILE" ]; then
    :
  else
    rm -f "$XAUTH_FILE"
  fi
fi
# マウント先は常に存在させる(空でも phantom ディレクトリを作らせない)。
# 中身が空なら X 認証は通らないが、その場合は .env 生成後に警告する。
[ -e "$XAUTH_FILE" ] || : > "$XAUTH_FILE"

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
  # X11 出力先ディスプレイ(Wayland では Xwayland。SSH からでも検出)
  printf 'DISPLAY=%s\n' "$DISPLAY_DETECTED"
  # X 認証クッキー(FamilyWild 化済み)。compose が /tmp/.Xauthority にマウント。
  printf 'XAUTHORITY_HOST=%s\n' "$XAUTH_FILE"
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

# セッション種別を知らせる。Wayland でも X11 アプリ(Resonite の Wine レンダラ)は
# Xwayland 経由で描画する。Xwayland が動いていれば $DISPLAY が立ち上で検出できる。
if [ "${XDG_SESSION_TYPE:-}" = "wayland" ]; then
  echo "info: Wayland セッションを検出。X11(Wine レンダラ)は Xwayland 経由で描画します(DISPLAY=$DISPLAY_DETECTED)。"
fi

# X 認証クッキーを用意できなかった場合の警告。空のままだと X に接続できず、
# ウィンドウが出ないまま無言で終了する(最頻出の起動失敗モード)。
if [ ! -s "$XAUTH_FILE" ]; then
  echo "warning: X 認証クッキーを用意できませんでした(.xauth が空: $XAUTH_FILE)。" >&2
  echo "  X ディスプレイ($DISPLAY_DETECTED)に接続できず、無言で終了する場合があります。" >&2
  echo "  グラフィカルセッション内で実行し、Xorg か Xwayland が動作しているか確認してください。" >&2
  echo "  Wayland のみで Xwayland が無い環境では X11 アプリは描画できません。" >&2
fi

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
