#!/bin/sh
set -e

# machine-id はコンテナごとに一意であるべきなので、起動の都度生成する。
# (ビルド時に焼くと全コンテナで同じIDになってしまう)
# /etc/machine-id はビルド時に resonite 所有にしてあるので非rootでも書ける。
tr -d - < /proc/sys/kernel/random/uuid > /etc/machine-id

# Resonite はインストールディレクトリに書き込む(ログ等)ため ro では起動できない。
# ホストのインストール(/resonite, ro)を書き込み可能な専用 volume(APP_DIR)へ
# rsync で差分同期し、そこから実行する。ホスト側のインストールは一切変更しない。
#
# APP_DIR は HOME の外( /opt )に置く。HOME(/home/resonite)は named volume の
# マウントポイントなので、その配下に install を置くと umu が親マウントを
# gamedrive(S:)にしてしまい、CWD の現在ドライブが S: になって絶対パスが壊れる。
# /opt 配下なら install の親はマウントで無くなり CWD が Z:(→/)で正しく解決される。
#
# rsync は size+mtime で差分を検出し、変化したファイルだけ転送する
# (初回フルコピー、以降は更新/MOD分のみ)。--delete でホスト側の削除も追従、
# --itemize-changes で実際に変わったものだけ報告(差分が無ければ何もしない)。
APP_DIR=/opt/resonite
mkdir -p "$APP_DIR"
echo "syncing Resonite -> $APP_DIR (rsync; first run copies ~2GB)..."
changed="$(rsync -a --delete --itemize-changes /resonite/ "$APP_DIR/")"
if [ -z "$changed" ]; then
  echo "no changes; $APP_DIR is up to date."
else
  n=$(printf '%s\n' "$changed" | wc -l)
  [ "$n" -le 20 ] && printf '%s\n' "$changed" | sed 's/^/  /'
  echo "synced $n changed item(s) -> $APP_DIR"
fi

# ResoBoot はゲームファイルを CWD 相対で読み書きするので、コピー先を CWD にする。
# APP_DIR(/opt/resonite)は HOME 外なので CWD の現在ドライブは Z:(→/)になり、
# ResoBoot/レンダラが渡す絶対 Unix パス(/dev/shm, /opt/resonite/Renderer 等)が
# 正しく解決される。これによりエンジン↔ResoBoot の共有メモリIPC(Cloudtoid)も
# 同じ /dev/shm を指して成立し、レンダラが起動できる(ホストと同じ挙動)。
cd "$APP_DIR"

exec "$@"
